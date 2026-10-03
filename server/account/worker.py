"""One durable sweep; systemd timer reruns after failures/reboots."""

import logging
from .runtime import build


def sweep(service):
    failed = 0
    for uid in service.store.due(service.clock()):
        try:
            service.finalize(uid, scheduled=True)
        except Exception:
            # No UID/token/credential/SQL exception contents in worker logs.
            logging.error('Account cleanup failed; durable record will be retried')
            failed += 1
    return failed


def main():
    service, _ = build()
    return 1 if sweep(service) else 0


if __name__ == '__main__':
    raise SystemExit(main())
