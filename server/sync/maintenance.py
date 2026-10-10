"""Bounded private-sync retention entrypoint sharing account authority configuration."""
import argparse
import json


def sweep(repository, *, batch_size=500, max_batches=4):
    if type(batch_size) is not int or not 1 <= batch_size <= 10000:
        raise ValueError('Invalid retention batch size')
    if type(max_batches) is not int or not 1 <= max_batches <= 100:
        raise ValueError('Invalid retention batch count')
    total = 0
    for _ in range(max_batches):
        count = repository.purge_expired(limit=batch_size)
        if type(count) is not int or not 0 <= count <= batch_size:
            raise ValueError('Invalid retention result')
        total += count
        if count < batch_size:
            break
    return total


def main():
    from server.account.runtime import _shared_repositories
    from server.account.postgres import PostgresStore
    import os
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch-size', type=int, default=500)
    parser.add_argument('--max-batches', type=int, default=4)
    args = parser.parse_args()
    try:
        repository, _ = _shared_repositories(PostgresStore(os.environ['ACCOUNT_DATABASE_URL']))
        if repository is None:
            raise ValueError('Private sync authority is not configured')
        result = {'private_sync': sweep(repository, batch_size=args.batch_size,
                                        max_batches=args.max_batches), 'failed': []}
    except Exception:
        result = {'failed': ['private_sync']}
    print(json.dumps(result))
    return int(bool(result['failed']))


if __name__ == '__main__':
    raise SystemExit(main())
