"""Regression tests for kernel fixes, run on the test image (tests/progs as /test)."""
import os
import re
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from vicetest import Vice  # noqa: E402

IMAGE = os.path.join(ROOT, "build", "breadbin-test.d64")


class KernelFixes(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.img = os.path.join(ROOT, "build", "fixes-%d.d64" % os.getpid())
        with open(IMAGE, "rb") as f, open(cls.img, "wb") as g:
            g.write(f.read())
        cls.v = Vice(cls.img)
        cls.v.wait_shell()

    @classmethod
    def tearDownClass(cls):
        cls.v.close()

    def run_(self, cmd, timeout=90):
        return self.v.run(cmd, timeout=timeout)

    def wait_file(self, path, timeout=120):
        deadline = time.time() + timeout
        while time.time() < deadline:
            out = self.run_("cat " + path)
            if out and "no such file" not in out:
                return out
            time.sleep(2)
        self.fail(path + " stayed empty")

    def test_unlink_open_file_keeps_data_until_close(self):
        df0 = self.run_("df")
        self.run_("cd /home")
        self.run_("echo hello > u1")
        pid = self.run_("/test/holdread u1 u2 > u1out &").strip("[]")
        self.assertTrue(pid.isdigit(), pid)
        self.run_("sleep 1")
        self.run_("rm u1")
        self.run_("echo other > u2")
        self.assertEqual(self.wait_file("u1out"), "hello")
        self.assertNotIn("holdread", self.run_("ps"))
        self.run_("rm u2")
        self.run_("rm u1out")
        self.run_("cd /")
        self.assertEqual(self.run_("df"), df0)   # the unlinked file's blocks came back

    def test_rmdir_of_a_working_directory_is_busy(self):
        self.run_("mkdir /home/dd")
        self.run_("cd /home/dd")
        self.assertIn("busy", self.run_("rmdir /home/dd"))
        self.run_("cd /")
        self.assertEqual(self.run_("rmdir /home/dd"), "")

    def test_pids_are_not_reused_while_alive(self):
        pid = self.run_("sleep 9999 &").strip("[]")
        self.assertEqual(self.run_("/test/spawnmany 300 " + pid, timeout=600), "ok")
        self.run_("kill " + pid)
        self.assertNotIn("sleep", self.run_("ps"))

    def test_zero_length_pipe_read(self):
        self.assertEqual(self.run_("/test/pipe0"), "ok")

    def test_an_argument_of_255_characters_is_too_long(self):
        self.assertEqual(self.run_("/test/bigarg"), "ok")

    def test_brk_kills_only_the_process(self):
        self.run_("/test/brk", timeout=30)
        self.assertEqual(self.run_("echo alive", timeout=30), "alive")
        self.assertNotIn("brk", self.run_("ps"))

    def test_waiting_shell_does_not_slow_background_jobs(self):
        fg = int(self.run_("/test/spin"))
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v.type("/test/spin &\n")
        got = []

        def printed(lines):
            for l in lines[1:]:
                m = re.match(r"^(?:\S+ \$ )?(\d+)$", l)
                if m:
                    got.append(int(m.group(1)))
                    return True
            return False
        self.v._wait(printed, 180, what="spin result")
        print("\nspin: foreground %d jiffies, background %d" % (fg, got[0]))
        self.assertLessEqual(got[0], fg * 1.05)


if __name__ == "__main__":
    unittest.main()
