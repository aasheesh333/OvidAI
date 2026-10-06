"""Bounded, restartable local expiry sweep; timer owns repeat scheduling."""
import argparse
import json


def sweep(stores, *, batch_size=500, max_batches=4):
    if type(batch_size) is not int or not 1 <= batch_size <= 10000:
        raise ValueError('Invalid retention batch size')
    if type(max_batches) is not int or not 1 <= max_batches <= 100:
        raise ValueError('Invalid retention batch count')
    result = {'images': 0, 'shares': 0, 'failed': []}
    for name in ('images', 'shares'):
        try:
            for _ in range(max_batches):
                count = getattr(stores, name).purge_expired(limit=batch_size)
                result[name] += count
                if count < batch_size:
                    break
        except Exception:
            # No UID, prompt, path or credential-bearing exceptions in logs.
            result['failed'].append(name)
    return result


def main():
    from .stores import StoreConfig, open_stores
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch-size', type=int, default=500)
    parser.add_argument('--max-batches', type=int, default=4)
    args = parser.parse_args()
    result = sweep(open_stores(StoreConfig.load()), batch_size=args.batch_size,
                   max_batches=args.max_batches)
    print(json.dumps(result))
    return int(bool(result['failed']))


if __name__ == '__main__':
    raise SystemExit(main())
