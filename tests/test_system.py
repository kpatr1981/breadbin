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

    def test_12_sigpipe(self):
        out = self.run_("ls /bin | head -2")
        self.assertEqual(len(out.splitlines()), 2)
        self.assertNotIn("ls", self.run_("ps").split()[5:])

    def test_13_ctrl_c_blocked_reader(self):
        # cat with no args blocks reading the console; RUN/STOP kills it
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v.type("cat\n")
        self.v.wait_for("$ cat")
        import time
        time.sleep(3)
        self.v._cmd("keybuf \\x03")
        self.v._cmd("x")
        self.v._wait(lambda ls: any(l.endswith(" $") for l in ls[1:]), 60)
        self.assertNotIn("cat", self.run_("ps").split()[5:])

    def test_14_ctrl_c_busy_foreground(self):
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v.type("count\n")
        self.v.wait_for("3")
        self.v._cmd("keybuf \\x03")
        self.v._cmd("x")
        import time
        time.sleep(3)
        self.assertNotIn("count", self.run_("ps"))

    def test_15_too_many_processes(self):
        # init + sh + 10 jobs fill the 12-slot process table
        pids = []
        for _ in range(10):
            pids.append(self.run_("sleep 9999 &").strip("[]"))
        out = self.v.run("sleep 9999 &", clear=False)
        self.assertIn("too many processes", out)
        self.v.run("kill " + " ".join(pids[:5]), clear=False)
        self.v.run("kill " + " ".join(pids[5:]), clear=False)
        self.assertEqual(self.run_("echo alive"), "alive")
        self.assertNotIn("sleep", self.run_("ps"))

    def test_16_paths(self):
        self.assertIn("cat", self.run_("ls /bin/").split())
        self.run_("cd /..")
        self.assertEqual(self.run_("pwd"), "/")
        self.assertIn("too long", self.run_("echo x > /home/abcdefghijklmnop").replace("\n", ""))
        self.assertIn("not a directory", self.run_("ls /etc/motd/x"))

    def test_17_basic_script(self):
        out = self.run_("basic /home/hello.bas")
        self.assertIn("5 squared is 25", out)
        self.assertIn("fib: 0 1 1 2 3 5 8 13 21 34", out)

    def test_18_basic_pipe(self):
        self.assertEqual(self.run_("echo 'print 6*7' | basic"), "42")
        self.assertIn("division by zero", self.run_("echo 'print 1/0' | basic"))


class Persistence(unittest.TestCase):
    """Files written by c64os survive a reboot and are readable on the host."""

    def test_write_reboot_read(self):
        img = os.path.join(ROOT, "build", "persist.d64")
        with open(IMAGE, "rb") as f, open(img, "wb") as g:
            g.write(f.read())
        with Vice(img) as v:
            v.wait_for("/ $", timeout=90)
            v.run("mkdir /home/keep")
            v.run("echo persistent data > /home/keep/f")
        out = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "mkimage.py"),
                              "cat", img, "/home/keep/f"], capture_output=True, text=True)
        self.assertEqual(out.stdout, "persistent data\n")
        with Vice(img) as v:
            v.wait_for("/ $", timeout=90)
            self.assertEqual(v.run("cat /home/keep/f"), "persistent data")


class REU(unittest.TestCase):
    """With an REU: /tmp is a RAM disk."""

    def test_tmp_ramdisk(self):
        with Vice(IMAGE, reu=True) as v:
            v.wait_for("/ $", timeout=90)
            self.assertIn("reu: 8 x 64k", v.screen())
            self.assertIn("/tmp", v.run("df"))
            v.run("echo hi > /tmp/x")
            self.assertEqual(v.run("cat /tmp/x"), "hi")
            v.run("mkdir /tmp/d")
            v.run("cd /tmp/d")
            v.run("cd ../..")
            self.assertEqual(v.run("pwd"), "/")
            self.assertIn("home", v.run("ls /tmp/..").split())
            self.assertIn("exists", v.run("mkdir /tmp/d"))


if __name__ == "__main__":
    unittest.main()
