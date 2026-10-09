import json
import unittest

from server.collaboration.events import (
    MAX_EVENT_CANONICAL_BYTES, EventRejected, canonical_bytes,
    validate_client_event, validate_payload)


def event(kind='message', payload=None, **extra):
    body = {'schemaVersion': 1, 'eventId': 'evt-1', 'kind': kind,
            'payload': {'text': 'hello'} if payload is None else payload}
    body.update(extra)
    return body


MODEL_STATUS = {'providerId': 'openai', 'requestedModel': 'gpt-x', 'reportedModel': None,
                'displayName': 'GPT X', 'streaming': True, 'status': 'running'}
USAGE = {'requestId': 'req-1', 'attemptId': 'att-1', 'provenance': 'reported',
         'inputTokens': 10, 'outputTokens': 0}


class AcceptTest(unittest.TestCase):
    def test_each_client_kind_accepted(self):
        for kind, payload in [('message', {'text': 'hi'}), ('modelStatus', MODEL_STATUS),
                              ('usage', USAGE), ('presence', {'state': 'away'})]:
            with self.subTest(kind=kind):
                self.assertEqual(validate_client_event(event(kind, payload))['kind'], kind)

    def test_message_text_preserved_verbatim_even_if_secret_like(self):
        text = 'my key is sk-abcdefghijklmnop1234 at /root/.ssh/id_rsa Bearer xyz ```rm -rf /```'
        out = validate_client_event(event('message', {'text': text}))
        self.assertEqual(out['payload']['text'], text)

    def test_server_payload_kinds_validate(self):
        validate_payload('membership', {'action': 'joined', 'participantId': 'p_1', 'role': 'participant'})
        validate_payload('membership', {'action': 'revoked', 'participantId': 'p_1', 'role': None})
        validate_payload('system', {'code': 'sessionClosed'})

    def test_unknown_usage_with_null_counts(self):
        validate_client_event(event('usage', dict(USAGE, provenance='unknown',
                                                  inputTokens=None, outputTokens=None)))

    def test_canonical_bytes_sorted_compact_utf8(self):
        self.assertEqual(canonical_bytes({'b': 1, 'a': 'é'}), '{"a":"é","b":1}'.encode())


class RejectTest(unittest.TestCase):
    def assertRejected(self, body, reason, *, client=True):
        with self.assertRaises(EventRejected) as caught:
            validate_client_event(body)
        self.assertEqual(caught.exception.reason, reason)
        # Fixed, non-sensitive message: never echoes values.
        self.assertNotIn('sk-', str(caught.exception))

    def test_unknown_kind(self):
        self.assertRejected(event('reaction', {}), 'unknownKind')

    def test_execution_kinds(self):
        for kind in ['toolCall', 'shellExec', 'build', 'browserAction', 'mcpInvoke',
                     'pluginRun', 'agentRequest', 'command', 'cloneRepo', 'modelRequest']:
            with self.subTest(kind=kind):
                self.assertRejected(event(kind, {}), 'executableKind')

    def test_server_emitted_kinds_rejected_from_clients(self):
        self.assertRejected(event('membership', {'action': 'joined', 'participantId': 'p_1',
                                                 'role': 'participant'}), 'serverKind')
        self.assertRejected(event('system', {'code': 'sessionClosed'}), 'serverKind')

    def test_server_derived_envelope_fields(self):
        for field in ['sessionId', 'eventSequence', 'senderParticipantId', 'createdAt']:
            with self.subTest(field=field):
                self.assertRejected(event(**{field: 'x'}), 'serverField')

    def test_unknown_envelope_field(self):
        self.assertRejected(event(extra=1), 'unknownField')

    def test_missing_field(self):
        body = event()
        del body['eventId']
        self.assertRejected(body, 'missingField')

    def test_wrong_schema_version(self):
        self.assertRejected(event(schemaVersion=2), 'invalidValue')
        self.assertRejected(event(schemaVersion=True), 'wrongType')

    def test_bad_event_id(self):
        for bad in ['', 'a b', 'x' * 129, 'id\n', 7]:
            with self.subTest(bad=bad):
                body = event()
                body['eventId'] = bad
                with self.assertRaises(EventRejected):
                    validate_client_event(body)

    def test_unknown_payload_field(self):
        self.assertRejected(event('message', {'text': 'x', 'mood': 'ok'}), 'unknownField')

    def test_credential_shaped_keys(self):
        for key in ['apiKey', 'authorization', 'cookie', 'refresh_token', 'password', 'grant']:
            with self.subTest(key=key):
                self.assertRejected(event('message', {'text': 'x', key: 'v'}), 'credentialField')

    def test_execution_keys(self):
        for key in ['command', 'tool', 'shell', 'mcpServer', 'plugin', 'browser', 'build',
                    'callback', 'queue']:
            with self.subTest(key=key):
                self.assertRejected(event('message', {'text': 'x', key: 'v'}), 'executableField')

    def test_path_keys(self):
        self.assertRejected(event('message', {'text': 'x', 'cwd': 'v'}), 'localPath')

    def test_attachment_keys(self):
        self.assertRejected(event('message', {'text': 'x', 'attachment': 'v'}), 'attachment')
        self.assertRejected(event('message', {'text': 'x', 'bytes': 'v'}), 'attachment')

    def test_credential_values_in_metadata(self):
        for value in ['sk-abcdefghijkl', 'Bearer abc', 'https://u:p@host/v1',
                      'https://h/?api_key=1', 'AKIAABCDEFGHIJKLMNOP',
                      'eyJhbGciOi.eyJzdWIi.sig', '-----BEGIN RSA PRIVATE KEY-----']:
            with self.subTest(value=value):
                self.assertRejected(event('modelStatus', dict(MODEL_STATUS, displayName=value)),
                                    'credentialValue')

    def test_local_path_values_in_metadata(self):
        for value in ['/root/models', '~/x', 'C:\\models', 'file:///tmp/x', 'a/../b', '\\\\srv\\s']:
            with self.subTest(value=value):
                self.assertRejected(event('modelStatus', dict(MODEL_STATUS, requestedModel=value)),
                                    'localPath')

    def test_attachment_values_in_metadata(self):
        self.assertRejected(event('modelStatus', dict(MODEL_STATUS, providerId='data:image/png;base64,AAAA')),
                            'attachment')

    def test_wrong_types(self):
        self.assertRejected(event('message', {'text': 5}), 'wrongType')
        self.assertRejected(event('message', ['text']), 'wrongType')
        self.assertRejected(event('message', {'text': {'nested': 'x'}}), 'wrongType')
        self.assertRejected(event('modelStatus', dict(MODEL_STATUS, streaming=1)), 'wrongType')
        self.assertRejected(event('usage', dict(USAGE, inputTokens=True)), 'wrongType')
        self.assertRejected(event('usage', dict(USAGE, inputTokens=1.0)), 'wrongType')
        self.assertRejected('not a map', 'wrongType')

    def test_invalid_enums_and_bounds(self):
        self.assertRejected(event('presence', {'state': 'busy'}), 'invalidValue')
        self.assertRejected(event('modelStatus', dict(MODEL_STATUS, status='exploded')), 'invalidValue')
        self.assertRejected(event('usage', dict(USAGE, inputTokens=-1)), 'invalidValue')
        self.assertRejected(event('usage', dict(USAGE, outputTokens=10 ** 12 + 1)), 'invalidValue')
        self.assertRejected(event('modelStatus', dict(MODEL_STATUS, displayName='  ')), 'invalidValue')
        self.assertRejected(event('modelStatus', dict(MODEL_STATUS, displayName='a\x00b')), 'invalidValue')
        self.assertRejected(event('modelStatus', dict(MODEL_STATUS, displayName='x' * 257)), 'invalidValue')

    def test_unknown_usage_cannot_carry_numbers(self):
        self.assertRejected(event('usage', dict(USAGE, provenance='unknown')), 'invalidValue')

    def test_membership_role_rules(self):
        for payload in [{'action': 'joined', 'participantId': 'p', 'role': 'owner'},
                        {'action': 'left', 'participantId': 'p', 'role': 'participant'}]:
            with self.subTest(payload=payload), self.assertRaises(EventRejected):
                validate_payload('membership', payload)

    def test_oversize_event(self):
        text = 'x' * MAX_EVENT_CANONICAL_BYTES
        self.assertRejected(event('message', {'text': text}), 'tooLarge')

    def test_size_counts_utf8_bytes(self):
        # 3-byte characters: under the limit in code points, over it in bytes.
        text = '€' * (MAX_EVENT_CANONICAL_BYTES // 3 + 10)
        self.assertRejected(event('message', {'text': text}), 'tooLarge')

    def test_non_string_keys_rejected(self):
        self.assertRejected(json.loads('{"x":1}') | {1: 'a'}, 'wrongType')


if __name__ == '__main__':
    unittest.main()
