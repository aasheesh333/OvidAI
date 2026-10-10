"""Rejected items must remain safely canonicalizable for request digests."""

import pytest

from server.sync.canonical import canonical_bytes
from server.sync.errors import SyncError
from server.sync.results import RejectedUpload


@pytest.mark.parametrize("encoded", [
    b'{"revision":100000000000000000000}', b'{"revision":1e+308}',
    b'{"revision":{"value":100000000000000000000}}', b'null', b'[]',
])
def test_rejected_item_can_be_rehashed_without_numeric_semantic_loss(encoded):
    item = RejectedUpload("bad", encoded, SyncError("invalid_record"))
    assert canonical_bytes(item.to_wire()) == encoded
    assert item.outcome().status == "rejected"


@pytest.mark.parametrize("encoded", [
    b'{"revision":1,"revision":2}', b'{"revision":1e309}',
    b'{"revision":NaN}', b'{"revision":',
])
def test_rejected_item_decoder_refuses_ambiguous_or_malformed_json(encoded):
    item = RejectedUpload("bad", encoded, SyncError("invalid_record"))
    with pytest.raises(SyncError) as caught:
        item.to_wire()
    assert caught.value.code == "invalid_request"
