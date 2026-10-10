"""Provider endpoint validation and canonicalization.

Endpoint values are portable metadata, not arbitrary URLs. ``validate_endpoint``
returns a canonical credential-free endpoint identity or raises
``SyncError('endpoint_rejected')``. It never echoes the input.

The validator is intentionally hand-written over a printable-ASCII grammar
rather than delegating to ``urllib.parse``, whose lenient parsing (backslashes,
missing slashes, whitespace stripping) is a known source of parser confusion.
"""

from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass, field
from typing import Mapping

from server.sync.errors import SyncError

MAX_ENDPOINT_LENGTH = 2048
_SUPPORTED_SCHEMES = {"https": 443, "http": 80}


@dataclass(frozen=True)
class EndpointPolicy:
    """Explicit provider policy.

    ``allowed_schemes`` may only widen ``https`` to ``http``; no other scheme is
    ever an endpoint identity. ``non_secret_query_keys`` lists lower-case,
    percent-decoded query names that the provider policy proves are not secret.
    """

    allowed_schemes: frozenset = frozenset({"https"})
    non_secret_query_keys: frozenset = field(default_factory=frozenset)

    def __post_init__(self):
        if not isinstance(self.allowed_schemes, frozenset) or not self.allowed_schemes:
            raise ValueError("allowed_schemes must be a non-empty frozenset")
        if not self.allowed_schemes <= set(_SUPPORTED_SCHEMES):
            raise ValueError("unsupported scheme in policy")
        if not isinstance(self.non_secret_query_keys, frozenset):
            raise ValueError("non_secret_query_keys must be a frozenset")


DEFAULT_POLICY = EndpointPolicy()

# Printable ASCII minus characters that are never valid unescaped in a URL or
# that enable parser confusion. '#' is excluded so any fragment is rejected.
_FORBIDDEN = set('\\<>"{}|^`#')
_URL = re.compile(r"\A([A-Za-z][A-Za-z0-9+.\-]*)://([^/?]*)([^?]*)(?:\?(.*))?\Z", re.S)
_PORT = re.compile(r"\A[0-9]{1,5}\Z")
_LABEL = re.compile(r"\A[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\Z")
_PCT = re.compile(r"%([0-9A-Fa-f]{2})")
_BAD_PCT = re.compile(r"%(?![0-9A-Fa-f]{2})")
_UNRESERVED = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

# Matched against the percent-decoded, lower-cased name with every
# non-alphanumeric character removed ("API%5FKey" -> "apikey").
_SENSITIVE_NAME_PARTS = (
    "key", "token", "secret", "passw", "pwd", "auth", "sig", "credential",
    "bearer", "jwt", "session", "cookie",
)
_SENSITIVE_EXACT = {"pass", "otp"}

# Well-known credential value shapes, checked in decoded path and query text.
_SECRET_VALUES = re.compile(
    r"sk-[A-Za-z0-9_\-]{16,}"
    r"|AKIA[0-9A-Z]{16}"
    r"|gh[pousr]_[A-Za-z0-9]{20,}"
    r"|AIza[0-9A-Za-z_\-]{30,}"
    r"|xox[abprs]-[A-Za-z0-9\-]{10,}"
    r"|eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"
    r"|(?i:bearer\s)"
)


class _Reject(Exception):
    pass


def validate_endpoint(
    value: object,
    provider_id: str,
    *,
    policy: EndpointPolicy | None = None,
    policies: Mapping[str, EndpointPolicy] | None = None,
) -> str:
    """Return the canonical credential-free identity for ``value``.

    ``policy`` (explicit) wins over ``policies[provider_id]``; otherwise the
    HTTPS-only default applies.
    """
    if policy is None:
        policy = (policies or {}).get(provider_id, DEFAULT_POLICY)
    try:
        result = _canonicalize(value, policy, provider_id)
    except _Reject:
        result = None
    if result is None:
        raise SyncError("endpoint_rejected")
    return result


def _canonicalize(value: object, policy: EndpointPolicy, provider_id: str) -> str:
    if type(value) is not str or not 0 < len(value) <= MAX_ENDPOINT_LENGTH:
        raise _Reject()
    for char in value:
        if not 0x21 <= ord(char) <= 0x7E or char in _FORBIDDEN:
            raise _Reject()
    match = _URL.match(value)
    if match is None:
        raise _Reject()
    scheme, authority, path, query = match.groups()
    scheme = scheme.lower()
    if scheme not in _SUPPORTED_SCHEMES or scheme not in policy.allowed_schemes:
        raise _Reject()
    host, port = _authority(authority, _SUPPORTED_SCHEMES[scheme])
    path = _path(path)
    query = _query(query, policy, provider_id)
    result = f"{scheme}://{host}{port}{path}{query}"
    if len(result) > MAX_ENDPOINT_LENGTH:
        raise _Reject()
    return result


def _authority(authority: str, default_port: int) -> tuple[str, str]:
    if not authority or "@" in authority or "%" in authority:
        raise _Reject()
    if authority.startswith("["):
        close = authority.find("]")
        if close < 0:
            raise _Reject()
        host = _ipv6(authority[1:close])
        rest = authority[close + 1:]
    else:
        if "[" in authority or "]" in authority:
            raise _Reject()
        host_text, sep, port_text = authority.partition(":")
        host = _reg_name(host_text)
        rest = sep + port_text
    if not rest:
        return host, ""
    if not rest.startswith(":") or not _PORT.match(rest[1:]):
        raise _Reject()
    port = int(rest[1:])
    if not 1 <= port <= 65535:
        raise _Reject()
    return host, "" if port == default_port else f":{port}"


def _ipv6(text: str) -> str:
    try:
        address = ipaddress.IPv6Address(text)
    except ValueError:
        raise _Reject() from None
    if address.scope_id is not None:
        raise _Reject()
    return f"[{address.compressed}]"


def _reg_name(text: str) -> str:
    host = text.lower()
    if not 0 < len(host) <= 253:
        raise _Reject()
    labels = host.split(".")
    for label in labels:
        if not _LABEL.match(label):
            raise _Reject()
    if labels[-1].isdigit():
        # Only strict dotted-quad IPv4; refuse octal/hex/short/integer forms.
        if len(labels) != 4:
            raise _Reject()
        for label in labels:
            if not label.isdigit() or (len(label) > 1 and label[0] == "0") or int(label) > 255:
                raise _Reject()
    return host


def _normalize_pct(text: str) -> str:
    """Decode percent-encoded unreserved octets and upper-case remaining escapes."""
    if _BAD_PCT.search(text):
        raise _Reject()

    def replace(match):
        char = chr(int(match.group(1), 16))
        return char if char in _UNRESERVED else "%" + match.group(1).upper()

    return _PCT.sub(replace, text)


def _fully_decode(text: str) -> str:
    """Repeatedly percent-decode (and '+' -> space) to defeat layered encodings."""
    for _ in range(8):
        decoded = _PCT.sub(lambda m: chr(int(m.group(1), 16)), text.replace("+", " "))
        if any(ord(char) < 0x20 or ord(char) >= 0x7f for char in decoded):
            raise _Reject()
        if decoded == text:
            return decoded
        text = decoded
    raise _Reject()


def _sensitive_name(name: str, policy: EndpointPolicy) -> bool:
    decoded = _fully_decode(name).lower()
    if decoded in policy.non_secret_query_keys:
        return False
    collapsed = "".join(char for char in decoded if char.isalnum())
    return collapsed in _SENSITIVE_EXACT or any(part in collapsed for part in _SENSITIVE_NAME_PARTS)


def _check_secret_value(text: str) -> None:
    if _SECRET_VALUES.search(_fully_decode(text)):
        raise _Reject()


def _path(path: str) -> str:
    if "[" in path or "]" in path:
        raise _Reject()
    path = _normalize_pct(path or "/")
    _check_secret_value(path)
    for segment in _fully_decode(path).split("/"):
        for param in segment.split(";")[1:]:
            if _sensitive_name(param.partition("=")[0], DEFAULT_POLICY):
                raise _Reject()
    return _remove_dot_segments(path)


def _remove_dot_segments(path: str) -> str:
    """RFC 3986 section 5.2.4 for an absolute path."""
    output: list[str] = []
    segments = path.split("/")[1:]
    for index, segment in enumerate(segments):
        last = index == len(segments) - 1
        if segment == ".":
            if last:
                output.append("")
        elif segment == "..":
            if output:
                output.pop()
            if last:
                output.append("")
        else:
            output.append(segment)
    return "/" + "/".join(output)


def _query(query: str | None, policy: EndpointPolicy, provider_id: str) -> str:
    if query is None:
        return ""
    if "[" in query or "]" in query:
        raise _Reject()
    pairs = []
    for piece in query.split("&"):
        if not piece:
            continue
        name, sep, item = piece.partition("=")
        if _sensitive_name(name, policy):
            raise _Reject()
        decoded_name = _fully_decode(name).lower()
        provider = re.sub(r"[^a-z0-9]", "", provider_id.lower())
        if (provider in {"azure", "azureopenai"} and
                re.sub(r"[^a-z0-9]", "", decoded_name) == "code" and
                decoded_name not in policy.non_secret_query_keys):
            raise _Reject()
        _check_secret_value(name)
        _check_secret_value(item)
        pairs.append(_normalize_pct(name) + sep + _normalize_pct(item))
    return "?" + "&".join(pairs) if pairs else ""
