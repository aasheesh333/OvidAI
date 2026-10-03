import base64
import io
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

from PIL import Image

from server.images.service import Backend, ImageError, ImageService, Ledger, UpstreamError


def png(w=8, h=8):
    out = io.BytesIO()
    Image.new('RGB', (w, h), 'red').save(out, 'PNG')
    return base64.b64encode(out.getvalue()).decode()


class ImagesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = Ledger(Path(self.tmp.name) / 'images.db')
        self.calls = []
        self.backends = [Backend('fixture-a', ('1024x1024',), True),
                         Backend('fixture-b', ('1024x1024',), False)]
        self.response = {'data': [{'b64_json': png()}], 'usage': {'cost': '0.123456'}}

    def tearDown(self):
        self.tmp.cleanup()

    def service(self, fail=None):
        def send(backend, operation, payload):
            self.calls.append((backend.model, operation, payload))
            if fail and backend.model == 'fixture-a':
                raise fail
            return self.response
        return ImageService(self.backends, self.ledger, send, Decimal('1'))

    def run_job(self, service, **changes):
        body = {'model': 'ovid-image', 'prompt': 'red square', 'size': '1024x1024'}
        body.update(changes)
        return service.execute('user', 'request-12345678', 'generate', body, Decimal('10'))

    def test_discount_actual_cost_and_replay(self):
        service = self.service()
        result = self.run_job(service)
        self.assertEqual(self.run_job(service), result)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.ledger.spent('user'), Decimal('0.0370368'))
        self.assertEqual(set(result), {'model', 'data'})
        self.assertEqual(result['model'], 'ovid-image')
        with self.assertRaises(ImageError):
            self.run_job(service, prompt='different')

    def test_transient_fallback_charges_once(self):
        self.run_job(self.service(UpstreamError(503)))
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.ledger.spent('user'), Decimal('0.0370368'))

    def test_permanent_error_and_uncertain_timeout_never_fallback(self):
        for error in (UpstreamError(400), UpstreamError(401), TimeoutError()):
            with self.subTest(error=error):
                self.calls.clear()
                with self.assertRaises(ImageError):
                    self.service(error).execute('user', type(error).__name__+str(getattr(error, 'status', '')),
                        'generate', {'model': 'ovid-image', 'prompt': 'x', 'size': '1024x1024'}, Decimal('10'))
                self.assertEqual(len(self.calls), 1)

    def test_edit_never_falls_back_to_generation(self):
        with self.assertRaises(ImageError):
            self.service(UpstreamError(503)).execute('user', 'edit-request-1234', 'edit',
                {'model': 'ovid-image', 'prompt': 'x', 'size': '1024x1024',
                 'image': 'data:image/png;base64,' + png()}, Decimal('10'))
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][1], 'edit')

    def test_invalid_input_and_unknown_fields_do_not_call_upstream(self):
        for change in ({'image': 'bad'}, {'model': 'fixture-a'}, {'size': '9000x9000'},
                       {'cost': 0}, {'prompt': ''}):
            with self.subTest(change=change), self.assertRaises(ImageError):
                self.run_job(self.service(), **change)
        self.assertEqual(self.calls, [])

    def test_invalid_response_or_missing_cost_is_not_retried(self):
        for response in ({'data': [{'b64_json': base64.b64encode(b'not png').decode()}], 'usage': {'cost': 1}},
                         {'data': [{'url': 'http://localhost/private'}], 'usage': {'cost': 1}},
                         {'data': [{'b64_json': png()}]},
                         {'data': [{'b64_json': png()}], 'usage': {'cost': '-1'}}):
            with self.subTest(response=response):
                self.response = response
                key = 'response-' + str(len(self.calls))
                service = self.service()
                with self.assertRaises(ImageError):
                    service.execute('user', key, 'generate', {'prompt': 'x', 'model': 'ovid-image', 'size': '1024x1024'}, Decimal('10'))
                count = len(self.calls)
                with self.assertRaises(ImageError):
                    service.execute('user', key, 'generate', {'prompt': 'x', 'model': 'ovid-image', 'size': '1024x1024'}, Decimal('10'))
                self.assertEqual(len(self.calls), count)

    def test_reservation_prevents_overdraw_and_survives_restart(self):
        with self.assertRaises(ImageError):
            self.service().execute('user', 'budget-request', 'generate',
                {'prompt': 'x', 'model': 'ovid-image', 'size': '1024x1024'}, Decimal('0.29'))
        self.assertEqual(self.calls, [])
        self.run_job(self.service())
        other = Ledger(Path(self.tmp.name) / 'images.db')
        self.assertEqual(other.spent('user'), Decimal('0.0370368'))

    def test_catalog_has_no_backend_ids_or_costs(self):
        catalog = self.service().catalog()
        self.assertNotIn('fixture', str(catalog))
        self.assertNotIn('cost', str(catalog))
        self.assertEqual(catalog['model'], 'ovid-image')
        self.assertEqual(catalog['operations'], {'generate': ['1024x1024'], 'edit': ['1024x1024']})

    def test_replay_survives_budget_window_reset(self):
        service = self.service()
        body = {'model': 'ovid-image', 'prompt': 'x', 'size': '1024x1024'}
        first = service.execute('user', 'stable-request', 'generate', body, Decimal('10'), budget_window='october')
        self.assertEqual(service.execute('user', 'stable-request', 'generate', body, Decimal('10'), budget_window='november'), first)
        self.assertEqual(len(self.calls), 1)

    def test_concurrent_idempotency_admits_only_one_paid_job(self):
        from concurrent.futures import ThreadPoolExecutor
        import threading
        started, finish = threading.Event(), threading.Event()

        def send(backend, operation, body):
            started.set()
            finish.wait(5)
            return self.response

        service = ImageService(self.backends, self.ledger, send, Decimal('1'))
        with ThreadPoolExecutor() as pool:
            future = pool.submit(self.run_job, service)
            self.assertTrue(started.wait(5))
            try:
                with self.assertRaises(ImageError) as caught:
                    self.run_job(service)
                self.assertEqual(caught.exception.code, 'image_request_pending')
            finally:
                finish.set()
            future.result()
        self.assertEqual(self.ledger.spent('user'), Decimal('0.0370368'))


if __name__ == '__main__':
    unittest.main()
