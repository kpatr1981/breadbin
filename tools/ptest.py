#!/usr/bin/env python3
"""Run VICE test classes in parallel, one process (one VICE) per class.

  ptest.py                      every test class in tests/
  ptest.py tests.test_bugs      every class of one module
  ptest.py tests.test_bugs.Shell tests.test_bugs.GeoRAMRoot.test_boot_from_georam_image
  ptest.py -j 6 ...             at most 6 at a time (default 4)
  ptest.py --failed             only what failed last time
  ptest.py --logdir build/ntsc  logs (and failed.txt) in another directory

Each class keeps its own VICE session, port and disk image copy, so classes
don't interfere. Logs go to build/ptest/<name>.log.
"""
import argparse
import concurrent.futures
import importlib
import inspect
import os
import subprocess
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def classes_of(module):
    mod = importlib.import_module(module)
    return [f"{module}.{name}" for name, c in inspect.getmembers(mod, inspect.isclass)
            if issubclass(c, unittest.TestCase) and c.__module__ == module]


def expand(names):
    out = []
    for n in names:
        try:
            importlib.import_module(n)
            out += classes_of(n)
        except ModuleNotFoundError:
            out.append(n)
    return out


def run(name, logdir):
    log = os.path.join(logdir, name + ".log")
    t = time.time()
    with open(log, "w") as f:
        r = subprocess.run([sys.executable, "-m", "unittest", "-v", name], cwd=ROOT,
                           stdout=f, stderr=subprocess.STDOUT)
    return name, r.returncode, time.time() - t, log


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", type=int, default=4)
    ap.add_argument("--failed", action="store_true", help="rerun what failed last time")
    ap.add_argument("--logdir", default=os.path.join(ROOT, "build", "ptest"),
                    help="where the logs go (a separate one per run when runs overlap)")
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()
    sys.path.insert(0, ROOT)
    names = a.names or [m for f in sorted(os.listdir(os.path.join(ROOT, "tests")))
                        if f.startswith("test_") and f.endswith(".py")
                        for m in ["tests." + f[:-3]]]
    logdir = a.logdir
    os.makedirs(logdir, exist_ok=True)
    failed_list = os.path.join(logdir, "failed.txt")
    if a.failed:
        with open(failed_list) as f:
            names = f.read().split()
    targets = expand(names)
    failed = []
    with concurrent.futures.ThreadPoolExecutor(a.j) as ex:
        for name, rc, secs, log in ex.map(lambda n: run(n, logdir), targets):
            print(f"{'ok  ' if rc == 0 else 'FAIL'} {name} ({secs:.0f}s)", flush=True)
            if rc:
                failed.append((name, log))
    with open(failed_list, "w") as f:
        f.write("\n".join(name for name, _ in failed))
    for _, log in failed:
        print(f"\n==== {log}")
        with open(log) as f:
            text = f.read()
        i = text.find("\n=====")
        print(text[i:] if i >= 0 else text[-3000:])
    print(f"\n{len(targets) - len(failed)}/{len(targets)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
