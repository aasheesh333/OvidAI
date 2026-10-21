"""Systemd/timer entry point for the 24-hour account-deletion expiry job.

This is the same one-durable-sweep contract as ``server.account.worker`` but
uses the product-facing :class:`~server.account.deletion.AccountDeletion`
facade so receipts keep the grace/Play fields. The timer reruns it after
failures and reboots; every due row is durable and independently retried.

Run with the same environment as the account worker::

    python -m server.account.deletion_worker
"""

import logging

from .deletion import AccountDeletion, sweep


def run_once(service):
    """Run one sweep against a composed deletion service; return failure count."""
    if not isinstance(service, AccountDeletion):
        service = AccountDeletion(service)
    return sweep(service)


def main():
    from .runtime import build

    service, _ = build()
    return 1 if run_once(service) else 0


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    raise SystemExit(main())
