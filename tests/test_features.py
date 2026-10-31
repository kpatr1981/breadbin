"""Tests for 0.4 features, run on the test image (tests/progs as /test)."""
import os
import subprocess
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from vicetest import Vice  # noqa: E402

IMAGE = os.path.join(ROOT, "build", "breadbin-test.d64")


def copy_image(name):
    img = os.path.join(ROOT, "build", "%s-%d.d64" % (name, os.getpid()))
    with open(IMAGE, "rb") as f, open(img, "wb") as g:
        g.write(f.read())
    return img


def host_cat(img, path):
    return subprocess.run([sys.executable, os.path.join(ROOT, "tools", "mkimage.py"), "cat", img, path],
                          capture_output=True).stdout


class WriteBack(unittest.TestCase):

    def test_small_writes_are_fast_and_reach_the_disk_on_close(self):
        img = copy_image("wb")
        with Vice(img) as v:
            v.wait_shell()
            jiffies = int(v.run("/test/smallw /home/w", timeout=600))
            print("\nsmallw: 200 one-byte writes in %d jiffies" % jiffies)
        # write-through (0.3) took 11262 jiffies; write-back ~720, most of
        # it the 2-second flushes while the file is still being written
        self.assertLess(jiffies, 1500)
        want = bytes(0x61 | (n & 15) for n in range(200, 0, -1))
        self.assertEqual(host_cat(img, "/home/w"), want)

    def test_open_file_reaches_the_disk_after_a_few_seconds(self):
        img = copy_image("wbt")
        with Vice(img) as v:
            v.wait_shell()
            v.run("/test/writehold /home/h &")
            v.run("sleep 3")
            v.run("echo tick")
            self.assertEqual(v.run("sync"), "")
        self.assertEqual(host_cat(img, "/home/h"), b"held\n")


if __name__ == "__main__":
    unittest.main()
