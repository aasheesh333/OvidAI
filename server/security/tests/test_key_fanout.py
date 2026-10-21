"""Per-key IP fan-out: block, one email per event, admin unblock, mobile use."""

import hashlib
import json

import pytest

from server.security.key_ip_fanout import (
    KeyIpFanoutBlocked,
    KeyIpFanoutGuard,
    MemoryKeyIpStore,
    key_ref,
    network_prefix,
)

KEY = "sk-live-super-secret-key"
UID = "user-1"
WINDOW = 15 * 60
LIMIT = 5


def make_guard(limit=LIMIT, emails=None):
    emails = [] if emails is None else emails
    return KeyIpFanoutGuard(
        MemoryKeyIpStore(), limit=limit, window_seconds=WINDOW,
        block_seconds=3600, email_hook=emails.append), emails


def observe(guard, ip, *, now, key=KEY, uid=UID, platform="android"):
    return guard.observe(key, uid, ip, platform=platform, now=now)


def test_normal_mobile_multi_network_use_is_allowed():
    guard, emails = make_guard()
    # Wi-Fi, carrier CGNAT and a commute hotspot: three /24s, well under 5.
    for i, ip in enumerate(["1.2.3.4", "5.6.7.8", "9.9.9.9"], start=1):
        decision = observe(guard, ip, now=1000 + i * 60)
        assert decision.recorded is True
        assert decision.distinct_prefixes == i
    assert guard.blocked_keys(now=1300) == []
    assert emails == []


def test_many_addresses_inside_one_24_count_once():
    guard, emails = make_guard()
    for i in range(5):
        observe(guard, f"1.2.3.{10 + i}", now=1000 + i)
    observe(guard, "5.6.7.8", now=1010)
    observe(guard, "9.9.9.9", now=1020)
    assert guard.blocked_keys(now=1030) == []
    assert emails == []


def test_more_than_limit_distinct_networks_blocks_the_key():
    guard, emails = make_guard()
    ips = ["1.2.3.4", "5.6.7.8", "9.9.9.9", "11.12.13.14", "15.16.17.18"]
    for i, ip in enumerate(ips):
        observe(guard, ip, now=1000 + i)
    with pytest.raises(KeyIpFanoutBlocked) as caught:
        observe(guard, "19.20.21.22", now=1010)
    error = caught.value
    assert error.code == "key_ip_fanout" and error.status == 403
    assert error.new is True and error.distinct_prefixes == 6
    record = guard.block_for(key_ref(KEY), now=1011)
    assert record["reason"] == "key_ip_fanout"
    assert record["distinct_prefixes"] == 6
    assert "19.20.21.0/24" in record["prefixes"]
    assert len(guard.blocked_keys(now=1012)) == 1
    assert len(emails) == 1


def test_one_email_per_event_even_after_repeated_observations():
    guard, emails = make_guard()
    ips = ["1.2.3.4", "5.6.7.8", "9.9.9.9", "11.12.13.14", "15.16.17.18"]
    for i, ip in enumerate(ips):
        observe(guard, ip, now=1000 + i)
    with pytest.raises(KeyIpFanoutBlocked):
        observe(guard, "19.20.21.22", now=1010)
    # Every later sighting is rejected, but must not create another event.
    for i in range(10):
        with pytest.raises(KeyIpFanoutBlocked) as caught:
            observe(guard, ips[i % len(ips)], now=1011 + i)
        assert caught.value.new is False
    assert len(emails) == 1

    # Admin unblock clears the window; a genuinely new burst is a new event.
    guard.unblock(key_ref(KEY), actor="admin", reason="reviewed", now=1100)
    for i, ip in enumerate(["31.32.33.34", "35.36.37.38", "39.40.41.42",
                            "43.44.45.46", "47.48.49.50"]):
        observe(guard, ip, now=1200 + i)
    with pytest.raises(KeyIpFanoutBlocked):
        observe(guard, "51.52.53.54", now=1210)
    assert len(emails) == 2
    assert emails[0]["event_id"] != emails[1]["event_id"]


def test_email_payload_has_no_raw_key_or_key_hash():
    guard, emails = make_guard()
    for i, ip in enumerate(["1.2.3.4", "5.6.7.8", "9.9.9.9",
                            "11.12.13.14", "15.16.17.18", "19.20.21.22"]):
        try:
            observe(guard, ip, now=1000 + i)
        except KeyIpFanoutBlocked:
            pass
    assert len(emails) == 1
    blob = json.dumps(emails[0], sort_keys=True)
    assert KEY not in blob
    assert hashlib.sha256(KEY.encode()).hexdigest() not in blob
    assert emails[0]["key_ref"] == key_ref(KEY)
    assert emails[0]["distinct_prefixes"] == 6
    assert emails[0]["reason"] == "key_ip_fanout"


def test_admin_unblock_shows_reason_and_lets_the_key_resume():
    guard, emails = make_guard()
    for i, ip in enumerate(["1.2.3.4", "5.6.7.8", "9.9.9.9",
                            "11.12.13.14", "15.16.17.18", "19.20.21.22"]):
        try:
            observe(guard, ip, now=1000 + i)
        except KeyIpFanoutBlocked:
            pass
    ref = key_ref(KEY)
    listed = guard.blocked_keys(now=1010)
    assert [(row["key_ref"], row["reason"]) for row in listed] == [
        (ref, "key_ip_fanout")]
    removed = guard.unblock(ref, actor="admin", reason="user travelling",
                            now=1020)
    assert removed["reason"] == "key_ip_fanout"
    assert guard.block_for(ref, now=1021) is None
    assert guard.blocked_keys(now=1021) == []
    # The observation window was cleared too: the reviewed key can continue
    # from a new network without instantly re-triggering the block.
    decision = observe(guard, "23.24.25.26", now=1030)
    assert decision.recorded is True and decision.distinct_prefixes == 1


def test_observations_outside_the_window_do_not_count():
    guard, emails = make_guard()
    # One new /24 every four minutes: at the sixth, the first has aged out.
    for i, ip in enumerate(["1.2.3.4", "5.6.7.8", "9.9.9.9",
                            "11.12.13.14", "15.16.17.18", "19.20.21.22"]):
        observe(guard, ip, now=1000 + i * 240)
    assert guard.blocked_keys(now=1000 + 5 * 240) == []
    assert emails == []


def test_existing_block_rejects_without_an_ip_or_a_new_email():
    guard, emails = make_guard()
    for i, ip in enumerate(["1.2.3.4", "5.6.7.8", "9.9.9.9",
                            "11.12.13.14", "15.16.17.18", "19.20.21.22"]):
        try:
            observe(guard, ip, now=1000 + i)
        except KeyIpFanoutBlocked:
            pass
    with pytest.raises(KeyIpFanoutBlocked) as caught:
        guard.observe(KEY, UID, "unknown", now=1100)
    assert caught.value.new is False
    assert len(emails) == 1


def test_invalid_address_is_ignored_without_blocking():
    guard, emails = make_guard()
    decision = observe(guard, "not-an-ip", now=1000)
    assert decision.recorded is False and decision.reason == "invalid_address"
    assert guard.blocked_keys(now=1000) == []
    assert emails == []


def test_key_ref_is_a_fingerprint_not_the_key_or_full_hash():
    ref = key_ref(KEY)
    assert ref.startswith("key_") and len(ref) == 4 + 20
    assert KEY not in ref
    assert hashlib.sha256(KEY.encode()).hexdigest() not in ref
    assert key_ref(KEY) == ref
    with pytest.raises(ValueError):
        key_ref("")


def test_network_prefix_is_coarse():
    assert network_prefix("1.2.3.4") == "1.2.3.0/24"
    assert network_prefix("2001:db8::1") == "2001:db8::/48"
    assert network_prefix("::ffff:1.2.3.4") == "1.2.3.0/24"
    with pytest.raises(ValueError):
        network_prefix("")
