"""Bounded, restartable local expiry sweep; timer owns repeat scheduling."""
import argparse
import json


def sweep(stores, *, private_sync=None, live_collaboration=None, batch_size=500, max_batches=4):
    if type(batch_size) is not int or not 1 <= batch_size <= 10000:
        raise ValueError('Invalid retention batch size')
    if type(max_batches) is not int or not 1 <= max_batches <= 100:
        raise ValueError('Invalid retention batch count')
    authorities = {'images': stores.images, 'shares': stores.shares}
    if private_sync is not None:
        authorities['private_sync'] = private_sync
    if live_collaboration is not None:
        from server.collaboration.repository import CollabRepository
        # SQLite has no expiry contract; PostgreSQL retains durable rate rows
        # and supplies bounded housekeeping. Missing PG contracts must fail.
        if not isinstance(live_collaboration, CollabRepository):
            authorities['live_collaboration'] = live_collaboration
    result = {name: 0 for name in authorities}
    result['failed'] = []
    for name, repository in authorities.items():
        try:
            for _ in range(max_batches):
                count = repository.purge_expired(limit=batch_size)
                if type(count) is not int or not 0 <= count <= batch_size:
                    raise ValueError('Invalid retention result')
                result[name] += count
                if count < batch_size:
                    break
        except Exception:
            # No UID, prompt, path or credential-bearing exceptions in logs.
            result['failed'].append(name)
    return result


def main():
    from .runtime import build_retention
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch-size', type=int, default=500)
    parser.add_argument('--max-batches', type=int, default=4)
    args = parser.parse_args()
    try:
        stores, private_sync, collaboration = build_retention()
        result = sweep(stores, private_sync=private_sync, batch_size=args.batch_size,
                       live_collaboration=collaboration, max_batches=args.max_batches)
    except Exception:
        result = {'failed': ['configuration']}
    print(json.dumps(result))
    return int(bool(result['failed']))


if __name__ == '__main__':
    raise SystemExit(main())
