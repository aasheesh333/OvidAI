#!/usr/bin/env python3
"""Run the filesystem Flutter inventory in bounded, SDK-serialized batches.

Each invocation has its own process group, timeout, flock, and retained machine
log. Retries are diagnostic: a failure in any attempt keeps the job nonzero.
summary.json is checkpointed after every invocation. Tree snapshots include
tracked/untracked source hashes; concurrent edits are reported, not hidden.
"""
import argparse
from collections import Counter, deque
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def now():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def discover(root):
    return sorted(p.relative_to(root).as_posix()
                  for p in (root / "test").rglob("*_test.dart") if p.is_file())


def tree_snapshot(root):
    def git(*args):
        result = subprocess.run(["git", *args], cwd=root, capture_output=True, timeout=30)
        return result.stdout.decode(errors="replace"), result.returncode

    head, _ = git("rev-parse", "HEAD")
    status, _ = git("status", "--short", "--untracked-files=all")
    names, code = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
    hashes = {}
    for name in sorted(set(names.split("\0")) - {""}) if code == 0 else discover(root):
        path = root / name
        try:
            if path.is_file():
                hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as error:
            hashes[name] = "ERROR: " + str(error)
    return {"captured_at": now(), "head": head.strip(), "status": status,
            "sha256": hashes, "inventory": discover(root)}


def parse_log(path, root, files):
    """Account for load tests, hidden hooks, failures, and interrupted suites."""
    suites, tests, expected = {}, {}, {}
    errors, protocol_errors = [], []
    done = None
    done_seen = False
    for line in path.read_text(errors="replace").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue  # Flutter startup warnings are not machine events.
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        try:
            if kind == "suite":
                suite = event["suite"]
                name = Path(suite["path"])
                if name.is_absolute():
                    name = name.relative_to(root)
                suites[suite["id"]] = name.as_posix()
            elif kind == "group" and event["group"].get("parentID") is None:
                group = event["group"]
                expected[group["suiteID"]] = group["testCount"]
            elif kind == "testStart":
                test = event["test"]
                tests[test["id"]] = {**test, "end": None}
            elif kind == "testDone":
                tests[event["testID"]]["end"] = event
            elif kind == "error":
                errors.append(event)
            elif kind == "done":
                done_seen, done = True, event.get("success")
        except (KeyError, TypeError, ValueError) as error:
            protocol_errors.append(f"Invalid {kind} event: {error}")
    results = {}
    for name in files:
        ids = {sid for sid, path_name in suites.items() if path_name == name}
        entries = [test for test in tests.values() if test["suiteID"] in ids]
        file_errors = [event for event in errors
                       if tests.get(event.get("testID"), {}).get("suiteID") in ids]
        completed = [test for test in entries if test["end"] is not None]
        visible = [test for test in completed if not test["end"].get("hidden", False)]
        counts = Counter("skipped" if test["end"].get("skipped") else
                         "passed" if test["end"].get("result") == "success" else "failed"
                         for test in visible)
        failures = [test for test in completed if test["end"].get("result") != "success"]
        active = [test["name"] for test in entries if test["end"] is None]
        count = sum(expected[sid] for sid in ids if sid in expected)
        has_count = any(sid in expected for sid in ids)
        if file_errors or failures:
            status = "failed"
        elif active:
            status = "incomplete"
        elif entries and has_count and len(visible) >= count:
            status = "passed"
        elif entries and done_seen and done is True:
            status = "passed"
        else:
            status = "unverified" if entries else "not_started"
        results[name] = {"status": status, "counts": dict(counts),
                         "expected_tests": count if has_count else None,
                         "active_tests": active, "errors": file_errors}
    return {"files": results, "done_seen": done_seen, "success": done,
            "errors": errors, "protocol_errors": protocol_errors}


def kill_group(process):
    # SIGKILL also terminates descendants when the wrapper has already exited.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def invoke(args, files, label):
    log = args.output / f"{label}.log"
    command = [args.flutter, "test", "--no-pub", "--concurrency=2", "--machine", *files]
    attempt = {"label": label, "command": command, "log": str(log),
               "started_at": now(), "timed_out": False, "returncode": None,
               "execution_seconds": 0, "lock_wait_seconds": 0, "runner_errors": []}
    wait_start = time.monotonic()
    with log.open("w") as output, args.lock.open("a") as lock:
        acquired = False
        while not acquired:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except BlockingIOError:
                if time.monotonic() - wait_start >= args.lock_timeout:
                    attempt["runner_errors"].append("SDK lock acquisition timed out")
                    break
                time.sleep(0.05)
        attempt["lock_wait_seconds"] = round(time.monotonic() - wait_start, 3)
        if acquired:
            started = time.monotonic()
            process = None
            try:
                process = subprocess.Popen(command, cwd=args.root, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    process.wait(timeout=args.batch_timeout)
                except subprocess.TimeoutExpired:
                    attempt["timed_out"] = True
                    attempt["runner_errors"].append(f"External timeout after {args.batch_timeout}s")
                finally:
                    kill_group(process)
                attempt["returncode"] = process.returncode
            except OSError as error:
                attempt["runner_errors"].append(str(error))
            finally:
                attempt["execution_seconds"] = round(time.monotonic() - started, 3)
                fcntl.flock(lock, fcntl.LOCK_UN)
    attempt.update(parse_log(log, args.root, files))
    attempt["ok"] = (attempt["returncode"] == 0 and not attempt["timed_out"]
                     and attempt["done_seen"] and attempt["success"] is True
                     and not attempt["errors"] and not attempt["protocol_errors"]
                     and not attempt["runner_errors"]
                     and all(item["status"] == "passed" for item in attempt["files"].values()))
    write_json(args.output / f"{label}.json", attempt)
    return attempt


def run(args):
    # Refuse to overwrite previous evidence.
    args.output.mkdir(parents=False, exist_ok=False)
    started = time.monotonic()
    start_tree = tree_snapshot(args.root)
    write_json(args.output / "tree-start.json", start_tree)
    inventory = discover(args.root)
    write_json(args.output / "inventory.json", inventory)
    (args.output / "inventory.txt").write_text("\n".join(inventory) + "\n")
    summary = {"started_at": now(), "finished_at": None, "inventory": inventory,
               "attempts": [], "errors": [], "files": {}, "ok": False}
    failed, recovered = set(), set()

    def checkpoint():
        summary["passed_files"] = sorted(name for name, item in summary["files"].items()
                                         if item["status"] == "passed" and name not in failed)
        summary["failed_files"] = sorted(failed)
        summary["unverified_files"] = sorted(set(inventory) - set(summary["passed_files"]) - failed)
        summary["recovered_files"] = sorted(recovered)
        summary["counts"] = {"inventory": len(inventory), "passed": len(summary["passed_files"]),
                             "failed": len(failed), "unverified": len(summary["unverified_files"]),
                             "attempts": len(summary["attempts"])}
        summary["elapsed_seconds"] = round(time.monotonic() - started, 3)
        write_json(args.output / "summary.json", summary)
        for kind in ("passed", "failed", "unverified", "recovered"):
            (args.output / f"{kind}-files.txt").write_text(
                "".join(name + "\n" for name in summary[f"{kind}_files"]))

    def record(attempt):
        summary["attempts"].append(attempt)
        summary["files"].update(attempt["files"])
        for name, item in attempt["files"].items():
            if item["status"] in ("failed", "incomplete"):
                failed.add(name)
            elif item["status"] == "passed" and name in failed:
                recovered.add(name)
        if not attempt["ok"]:
            summary["errors"].append({"attempt": attempt["label"], "log": attempt["log"],
                                      "returncode": attempt["returncode"],
                                      "timed_out": attempt["timed_out"],
                                      "details": attempt["runner_errors"] + attempt["protocol_errors"]})
        checkpoint()
        print(f'{attempt["label"]}: {"PASS" if attempt["ok"] else "FAIL"} '
              f'{attempt["execution_seconds"]}s; '
              f'{summary["counts"]}; log={attempt["log"]}', flush=True)

    checkpoint()
    queue = deque(inventory[i:i + args.batch_size] for i in range(0, len(inventory), args.batch_size))
    print(f"Discovered {len(inventory)} files; {len(queue)} batches; logs={args.output}", flush=True)
    try:
        if not inventory:
            summary["errors"].append({"message": "No Flutter tests found"})
        batch_number = 0
        while queue:
            batch_number += 1
            files = queue.popleft()
            label = f"batch-{batch_number:04d}"
            print(f"Starting {label}: {len(files)} files", flush=True)
            attempt = invoke(args, files, label)
            record(attempt)
            if not attempt["ok"]:
                # Retry only files with identified failures or unfinished tests.
                retry = [name for name, item in attempt["files"].items()
                         if item["status"] in ("failed", "incomplete", "unverified")]
                for index, name in enumerate(retry, 1):
                    record(invoke(args, [name], f"{label}-retry-{index:02d}"))
                # Tests never reached by an interrupted batch still get a first
                # execution. No progress (e.g. compiler/SDK failure) is bounded.
                untouched = [name for name, item in attempt["files"].items()
                             if item["status"] == "not_started"]
                if untouched and len(untouched) < len(files):
                    queue.appendleft(untouched)
    except (KeyboardInterrupt, Exception) as error:
        summary["errors"].append({"message": f"Runner interrupted: {type(error).__name__}: {error}"})
    finally:
        end_tree = tree_snapshot(args.root)
        write_json(args.output / "tree-end.json", end_tree)
        before, after = start_tree["sha256"], end_tree["sha256"]
        summary["tree_changes"] = sorted(name for name in before.keys() | after.keys()
                                         if before.get(name) != after.get(name))
        summary["added_test_files"] = sorted(set(end_tree["inventory"]) - set(inventory))
        summary["removed_test_files"] = sorted(set(inventory) - set(end_tree["inventory"]))
        if summary["added_test_files"]:
            summary["errors"].append({"message": "New tests appeared after inventory capture",
                                      "files": summary["added_test_files"]})
        summary["finished_at"] = now()
        checkpoint()
        summary["ok"] = bool(inventory) and not summary["errors"] and not summary["unverified_files"]
        checkpoint()
    return 0 if summary["ok"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--flutter", default="/root/flutter/bin/flutter")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--lock", type=Path, default=Path("/tmp/opencode/parallel-flutter.lock"))
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--batch-timeout", type=float, default=300)
    parser.add_argument("--lock-timeout", type=float, default=900)
    args = parser.parse_args()
    if args.batch_size < 1 or args.batch_timeout <= 0 or args.lock_timeout <= 0:
        parser.error("batch size and timeouts must be positive")
    args.root, args.output, args.lock = args.root.resolve(), args.output.resolve(), args.lock.resolve()
    if not args.output.parent.is_dir() or not args.lock.parent.is_dir():
        parser.error("output and lock parent directories must exist")
    def terminate(signum, frame):
        raise KeyboardInterrupt(f"Received signal {signum}")

    signal.signal(signal.SIGTERM, terminate)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
