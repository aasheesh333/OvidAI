import json
from pathlib import Path
import unittest

from server.collaboration.events import EventRejected, validate_client_event


FIXTURE = Path(__file__).parents[3] / 'test' / 'fixtures' / 'collaboration' / 'v1.json'


class ContractVectorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vectors = json.loads(FIXTURE.read_text(encoding='utf-8'))

    def test_client_events_normalize_to_frozen_vectors(self):
        for vector in self.vectors['events']:
            with self.subTest(vector=vector['name']):
                if vector['normalizedClient'] is None:
                    with self.assertRaises(EventRejected) as caught:
                        validate_client_event(vector['client'])
                    self.assertEqual(caught.exception.reason, 'serverKind')
                else:
                    self.assertEqual(validate_client_event(vector['client']), vector['normalizedClient'])

    def test_client_errors_use_frozen_reason_codes(self):
        for vector in self.vectors['errors']:
            with self.subTest(vector=vector['name']):
                with self.assertRaises(EventRejected) as caught:
                    validate_client_event(vector['client'])
                self.assertEqual(caught.exception.reason, vector['reason'])


if __name__ == '__main__':
    unittest.main()
