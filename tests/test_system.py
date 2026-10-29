"""End-to-end tests: boot c64os in VICE and drive the shell."""
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from vicetest import Vice  # noqa: E402

IMAGE = os.path.join(ROOT, "build", "c64os.d64")


class Boot(unittest.TestCase):
    """One VICE session for a sequence of checks (booting is the slow part)."""

    @classmethod
    def setUpClass(cls):
        cls.img = os.path.join(ROOT, "build", "test.d64")
        with open(IMAGE, "rb") as f, open(cls.img, "wb") as g:
            g.write(f.read())
        cls.v = Vice(cls.img)
        cls.v.wait_for("/ $", timeout=90)

    @classmethod
    def tearDownClass(cls):
        cls.v.close()

    def run_(self, cmd):
        return self.v.run(cmd)

    def test_01_banner(self):
        s = self.v.screen()
        self.assertIn("c64os", s)

    def test_02_echo(self):
        self.assertEqual(self.run_("echo hello world"), "hello world")

    def test_03_ls_bin(self):
        out = self.run_("ls /bin")
        for name in ["cat", "ls", "sh", "init", "grep"]:
            self.assertIn(name, out.split())

    def test_04_cat(self):
        out = self.run_("cat /etc/motd")
        self.assertIn("welcome to c64os.", out)

    def test_05_pipe_three_stages(self):
        out = self.run_("cat /home/readme | grep unix | wc")
        expect = subprocess.run("grep unix rootfs/home/readme | wc", shell=True, cwd=ROOT,
                                capture_output=True, text=True).stdout.split()
        self.assertEqual(out.split(), expect)

    def test_06_redirect_roundtrip(self):
        self.run_("echo hi there > /home/note")
        self.assertEqual(self.run_("cat /home/note"), "hi there")
        self.run_("echo again >> /home/note")
        self.assertEqual(self.run_("cat /home/note"), "hi there\nagain")

    def test_07_directories(self):
        self.run_("mkdir /home/src")
        self.run_("cd /home/src")
        self.assertEqual(self.run_("pwd"), "/home/src")
        self.run_("echo x > f")
        self.assertEqual(self.run_("ls"), "f")
        self.run_("cd ..")
        self.assertEqual(self.run_("pwd"), "/home")
        self.assertIn("directory not empty", self.run_("rmdir src"))
        self.run_("rm src/f")
        self.assertEqual(self.run_("rmdir src"), "")
        self.assertNotIn("src", self.run_("ls").split())
        self.run_("cd /")

    def test_08_background_and_kill(self):
        out = self.run_("count > /dev/null &")
        pid = out.strip("[]")
        self.assertTrue(pid.isdigit(), out)
        ps = self.run_("ps")
        self.assertIn("count", ps)
        self.run_("kill " + pid)
        ps = self.run_("ps")
        self.assertNotIn("count", ps)

    def test_09_errors(self):
        self.assertIn("no such file", self.run_("cat /nope"))
        self.assertIn("not found", self.run_("nosuchcmd").replace(
            "no such file or directory", "not found"))

    def test_10_mv_cp(self):
        self.run_("cp /etc/motd /home/m2")
        self.run_("mv /home/m2 /home/m3")
        self.assertIn("welcome", self.run_("cat /home/m3"))
        self.assertIn("no such file", self.run_("cat /home/m2"))

    def test_11_head_pipe_early_exit(self):
        out = self.run_("cat /home/readme | head -3 | wc")
        self.assertEqual(out.split()[0], "3")


if __name__ == "__main__":
    unittest.main()
