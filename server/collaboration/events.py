"""Closed, inert v1 collaboration event allowlist.

Mirrors lib/core/collaboration/models.dart. Events are data only: there is no
callback, command, provider request, or queue anywhere in this module, and an
event can never name an execution request. Rejections carry a fixed reason
code and never echo submitted values.

Private message text is preserved verbatim (no redaction, no screening).
Descriptive metadata (ids, provider/model labels) is screened for credential
material, local paths, and attachment bytes.
"""

import json
import re

SCHEMA_VERSION = 1
MAX_EVENT_CANONICAL_BYTES = 256 * 1024
MAX_ID_LENGTH = 128
MAX_LABEL_LENGTH = 256
MAX_TOKEN_COUNT = 1_000_000_000_000

# Kinds a client may append. `membership` and `system` are server-emitted.
CLIENT_KINDS = ('message', 'modelStatus', 'usage', 'presence')
SERVER_KINDS = ('membership', 'system')
ALL_KINDS = CLIENT_KINDS + SERVER_KINDS

CLIENT_ENVELOPE_FIELDS = ('schemaVersion', 'eventId', 'kind', 'payload')
SERVER_ENVELOPE_FIELDS = ('sessionId', 'eventSequence', 'senderParticipantId', 'createdAt')

MODEL_STATUSES = ('idle', 'queued', 'running', 'completed', 'failed', 'cancelled', 'interrupted')
PROVENANCES = ('reported', 'estimated', 'unknown')
PRESENCE_STATES = ('online', 'away', 'offline')
MEMBERSHIP_ACTIONS = ('joined', 'left', 'revoked')
ROLES = ('owner', 'participant')
SYSTEM_CODES = ('sessionClosing', 'sessionClosed')


class EventRejected(ValueError):
    """Fixed, non-sensitive rejection. `reason` matches CollaborationWireReason."""

    def __init__(self, reason):
        super().__init__(f'collaboration event rejected: {reason}')
        self.reason = reason


def _reject(reason):
    raise EventRejected(reason)


# ---------------------------------------------------------------------------
# Key / value screening (same lists and order as the Dart client)
# ---------------------------------------------------------------------------

_CREDENTIAL_KEY_PARTS = ('apikey', 'auth', 'cookie', 'token', 'secret', 'password', 'passwd',
                         'grant', 'credential', 'bearer', 'privatekey', 'session')
_EXECUTABLE_KEY_PARTS = ('command', 'cmd', 'tool', 'shell', 'script', 'mcp', 'plugin', 'browser',
                         'exec', 'queue', 'callback', 'process', 'spawn', 'eval', 'invoke',
                         'handler', 'build', 'clone', 'agent')
_PATH_KEY_PARTS = ('path', 'cwd', 'dir', 'workspace', 'folder', 'file')
_ATTACHMENT_KEY_PARTS = ('attach', 'bytes', 'base64', 'blob', 'image', 'binary')
_EXECUTABLE_KIND_PARTS = ('tool', 'exec', 'shell', 'command', 'cmd', 'browser', 'mcp', 'plugin',
                          'run', 'agent', 'process', 'build', 'clone', 'request', 'invoke', 'call',
                          'spawn', 'script')

_CREDENTIAL_VALUES = [re.compile(p, f) for p, f in [
    (r'\bsk-[A-Za-z0-9_\-]{8,}', 0),
    (r'bearer\s', re.IGNORECASE),
    (r'basic\s+[A-Za-z0-9+/=]{8,}', re.IGNORECASE),
    (r'://[^/\s]*@', 0),
    (r'\bgh[pousr]_[A-Za-z0-9]{20,}', 0),
    (r'\bxox[abprs]-[A-Za-z0-9-]{8,}', 0),
    (r'\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.', 0),
    (r'\bAKIA[0-9A-Z]{16}\b', 0),
    (r'\bAIza[0-9A-Za-z_\-]{20,}', 0),
    (r'[?&#](api[_-]?key|key|token|access[_-]?token|secret|sig|signature|password|auth)=',
     re.IGNORECASE),
    (r'-----BEGIN [A-Z ]*KEY-----', 0),
]]
_LOCAL_PATH_VALUES = [re.compile(p, f) for p, f in [
    (r'^\s*/', 0), (r'^\s*~', 0), (r'^\s*[A-Za-z]:[\\/]', 0), (r'^\s*\\\\', 0),
    (r'^\s*file:', re.IGNORECASE), (r'(^|[\\/])\.\.?[\\/]', 0),
]]
_ATTACHMENT_VALUES = [re.compile(r'^\s*data:', re.IGNORECASE), re.compile(r';base64,', re.IGNORECASE)]

_ID = re.compile(r'[A-Za-z0-9._:\-]+')
_CONTROL = re.compile(r'[\x00-\x1F\x7F]')


def _normalize_key(key):
    return re.sub(r'[^a-z0-9]', '', key.lower())


def _reject_unknown_key(key):
    k = _normalize_key(key)
    for parts, reason in ((_CREDENTIAL_KEY_PARTS, 'credentialField'),
                          (_EXECUTABLE_KEY_PARTS, 'executableField'),
                          (_PATH_KEY_PARTS, 'localPath'),
                          (_ATTACHMENT_KEY_PARTS, 'attachment')):
        if any(part in k for part in parts):
            _reject(reason)
    _reject('unknownField')


def _screen_metadata(value):
    if any(p.search(value) for p in _ATTACHMENT_VALUES):
        _reject('attachment')
    if any(p.search(value) for p in _CREDENTIAL_VALUES):
        _reject('credentialValue')
    if any(p.search(value) for p in _LOCAL_PATH_VALUES):
        _reject('localPath')


# ---------------------------------------------------------------------------
# Closed map reader
# ---------------------------------------------------------------------------

class _Closed:
    def __init__(self, raw, allowed, *, server_fields=()):
        if not isinstance(raw, dict):
            _reject('wrongType')
        if any(not isinstance(key, str) for key in raw):
            _reject('wrongType')
        for key in raw:
            if key in allowed:
                continue
            if key in server_fields:
                _reject('serverField')
            _reject_unknown_key(key)
        if any(key not in raw for key in allowed):
            _reject('missingField')
        self.map = raw

    def string(self, key):
        value = self.map[key]
        if not isinstance(value, str):
            _reject('wrongType')
        return value

    def id(self, key):
        value = self.string(key)
        if len(value) > MAX_ID_LENGTH or not _ID.fullmatch(value):
            _reject('invalidValue')
        _screen_metadata(value)
        return value

    def label(self, key):
        value = self.string(key)
        _screen_metadata(value)
        if not value.strip() or len(value) > MAX_LABEL_LENGTH or _CONTROL.search(value):
            _reject('invalidValue')
        return value

    def nullable_label(self, key):
        return None if self.map[key] is None else self.label(key)

    def boolean(self, key):
        value = self.map[key]
        if type(value) is not bool:
            _reject('wrongType')
        return value

    def integer(self, key):
        value = self.map[key]
        if type(value) is not int:  # bool and float are not integers on the wire
            _reject('wrongType')
        return value

    def nullable_count(self, key):
        if self.map[key] is None:
            return None
        value = self.integer(key)
        if not 0 <= value <= MAX_TOKEN_COUNT:
            _reject('invalidValue')
        return value

    def enum(self, key, values):
        value = self.string(key)
        if value not in values:
            _reject('invalidValue')
        return value

    def nullable_enum(self, key, values):
        return None if self.map[key] is None else self.enum(key, values)


# ---------------------------------------------------------------------------
# Payloads
# ---------------------------------------------------------------------------

def _message(raw):
    return {'text': _Closed(raw, ('text',)).string('text')}


def _model_status(raw):
    r = _Closed(raw, ('providerId', 'requestedModel', 'reportedModel', 'displayName',
                      'streaming', 'status'))
    return {'providerId': r.label('providerId'),
            'requestedModel': r.label('requestedModel'),
            'reportedModel': r.nullable_label('reportedModel'),
            'displayName': r.label('displayName'),
            'streaming': r.boolean('streaming'),
            'status': r.enum('status', MODEL_STATUSES)}


def _usage(raw):
    r = _Closed(raw, ('requestId', 'attemptId', 'provenance', 'inputTokens', 'outputTokens'))
    provenance = r.enum('provenance', PROVENANCES)
    input_tokens, output_tokens = r.nullable_count('inputTokens'), r.nullable_count('outputTokens')
    # Unknown usage is never a number (never coerced to zero).
    if provenance == 'unknown' and (input_tokens is not None or output_tokens is not None):
        _reject('invalidValue')
    return {'requestId': r.id('requestId'), 'attemptId': r.id('attemptId'),
            'provenance': provenance, 'inputTokens': input_tokens, 'outputTokens': output_tokens}


def _presence(raw):
    return {'state': _Closed(raw, ('state',)).enum('state', PRESENCE_STATES)}


def _membership(raw):
    r = _Closed(raw, ('action', 'participantId', 'role'))
    action = r.enum('action', MEMBERSHIP_ACTIONS)
    role = r.nullable_enum('role', ROLES)
    if (role != 'participant') if action == 'joined' else (role is not None):
        _reject('invalidValue')
    return {'action': action, 'participantId': r.id('participantId'), 'role': role}


def _system(raw):
    return {'code': _Closed(raw, ('code',)).enum('code', SYSTEM_CODES)}


_PAYLOADS = {'message': _message, 'modelStatus': _model_status, 'usage': _usage,
             'presence': _presence, 'membership': _membership, 'system': _system}


def validate_payload(kind, raw):
    """Validate any v1 payload (client or server kind); returns a normalized copy."""
    if kind not in _PAYLOADS:
        _reject('unknownKind')
    return _PAYLOADS[kind](raw)


def _classify_kind(kind):
    if kind in CLIENT_KINDS:
        return kind
    if kind in SERVER_KINDS:
        _reject('serverKind')
    if any(part in _normalize_key(kind) for part in _EXECUTABLE_KIND_PARTS):
        _reject('executableKind')
    _reject('unknownKind')


def canonical_bytes(value):
    """Canonical UTF-8 JSON: sorted keys, compact separators, no ASCII escaping."""
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'),
                          allow_nan=False).encode('utf-8')
    except (UnicodeEncodeError, ValueError):  # lone surrogates, NaN
        _reject('invalidValue')


def check_size(envelope):
    if len(canonical_bytes(envelope)) > MAX_EVENT_CANONICAL_BYTES:
        _reject('tooLarge')


def validate_client_event(raw):
    """Validate a client-submitted event before any persistence.

    Clients send only schemaVersion/eventId/kind/payload; server-derived fields
    are rejected. Returns a normalized copy containing exactly those fields.
    """
    r = _Closed(raw, CLIENT_ENVELOPE_FIELDS, server_fields=SERVER_ENVELOPE_FIELDS)
    if r.integer('schemaVersion') != SCHEMA_VERSION:
        _reject('invalidValue')
    event_id = r.id('eventId')
    kind = _classify_kind(r.string('kind'))
    event = {'schemaVersion': SCHEMA_VERSION, 'eventId': event_id, 'kind': kind,
             'payload': _PAYLOADS[kind](r.map['payload'])}
    check_size(event)
    return event
