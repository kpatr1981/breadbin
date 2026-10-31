"""Regression tests for the 0.3 review bugs, run on the test image (tests/progs as /test)."""
import os
import re
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from vicetest import Vice  # noqa: E402
import mkimage  # noqa: E402

IMAGE = os.path.join(ROOT, "build", "breadbin-test.d64")
PRG = os.path.join(ROOT, "build", "breadbin.prg")


def copy_image(name):
    img = os.path.join(ROOT, "build", "%s-%d.d64" % (name, os.getpid()))
    with open(IMAGE, "rb") as f, open(img, "wb") as g:
        g.write(f.read())
    return img


class Shell(unittest.TestCase):
    """One session for the shell, signal and file system bugs."""

    @classmethod
    def setUpClass(cls):
        cls.v = Vice(copy_image("bugs"))
        cls.v.wait_shell()

    @classmethod
    def tearDownClass(cls):
        cls.v.close()

    def run_(self, cmd, timeout=90):
        return self.v.run(cmd, timeout=timeout)

    def key(self, code):
        self.v._cmd("keybuf \\x%02x" % code)
        self.v._cmd("x")

    def ps_line(self, name):
        return [l for l in self.run_("ps").splitlines() if l.endswith(name)]

    def stopped(self, name):
        return [l for l in self.ps_line(name) if any(t.startswith("T") for t in l.split())]

    def start_stopped(self, cmd):
        """Run cmd in the foreground and stop it with CTRL-Z; return the job's pid."""
        self.v.type("clear\n" + cmd + "\n")
        self.v.wait_for("$ " + cmd)
        time.sleep(2)
        self.key(0x1a)
        s = self.v.wait_for("] stopped")
        return s.split("] stopped")[0].split("[")[-1]

    def test_bg_continues_the_whole_pipeline(self):
        self.start_stopped("count | grep x")
        self.assertEqual(len(self.stopped("count")) + len(self.stopped("grep")), 2)
        self.run_("bg")
        self.assertEqual(self.stopped("count") + self.stopped("grep"), [])
        self.run_("kill " + " ".join(l.split()[0] for l in self.ps_line("count") + self.ps_line("grep")))

    def test_fg_continues_the_whole_pipeline(self):
        self.start_stopped("count | grep x")
        self.v.type("clear\nfg\n")
        self.v.wait_for("$ fg")
        time.sleep(2)
        self.key(0x03)                        # RUN/STOP: the whole job is in the foreground
        self.v._wait(lambda ls: any(l.endswith(" $") for l in ls[1:]), 60)
        self.assertEqual(self.ps_line("count") + self.ps_line("grep"), [])

    def test_bg_reader_stops_again(self):
        pid = self.start_stopped("cat")
        self.run_("bg")
        time.sleep(2)
        self.assertEqual(self.run_("echo hi"), "hi")     # cat must not eat the shell's keys
        self.assertIn("[" + pid + "] stopped  cat", self.run_("jobs"))
        self.run_("kill " + pid)

    def test_children_of_a_background_job_are_background(self):
        self.run_("echo count > /home/s")
        pid = self.run_("sh /home/s > /dev/null &").strip("[]")
        time.sleep(2)
        self.key(0x03)                        # RUN/STOP at the prompt
        time.sleep(2)
        self.assertEqual(len(self.ps_line("count")), 1)
        self.run_("kill " + " ".join(l.split()[0] for l in self.ps_line("count")))
        self.run_("rm /home/s")

    def test_exiting_shell_does_not_leave_stopped_children(self):
        # a script shell and its child both stop; when the shell dies, the
        # orphaned stopped child must not hang around under init
        self.run_("echo count > /home/s2")
        self.start_stopped("sh /home/s2 > /dev/null")
        sh = [l.split()[0] for l in self.ps_line("sh") if "T" in l]
        self.assertEqual(len(sh), 1)
        self.run_("kill " + sh[0])
        time.sleep(2)
        self.assertEqual(self.ps_line("count"), [])
        self.run_("rm /home/s2")

    def test_pipe_failure_does_not_leak(self):
        self.assertEqual(self.run_("/test/pipeleak"), "ok")

    def test_spawn_ignores_unknown_flags(self):
        pid = self.run_("/test/spawnflags")
        self.assertTrue(pid.isdigit(), pid)
        time.sleep(2)
        self.assertEqual(self.stopped("sleep"), [])
        self.run_("kill " + pid)

    def test_mv_directory_into_itself(self):
        self.run_("mkdir /home/a")
        self.run_("mkdir /home/a/b")
        self.assertIn("invalid argument", self.run_("mv /home/a /home/a/b/c"))
        self.assertIn("a", self.run_("ls /home").split())
        self.run_("rmdir /home/a/b")
        self.run_("rmdir /home/a")

    def test_kill_needs_the_same_user(self):
        pid = self.run_("sleep 999 &").strip("[]")
        self.v.type("clear\nexit\n")
        self.v.wait_for("login:")
        self.v.type("user\n")
        time.sleep(4)
        self.assertEqual(self.run_("whoami"), "user")
        self.assertIn("not permitted", self.run_("kill " + pid))
        self.v.type("clear\nexit\n")
        self.v.wait_for("login:")
        self.v.type("root\n")
        time.sleep(4)
        self.assertEqual(self.run_("whoami"), "root")
        self.run_("kill " + pid)
        self.assertEqual(self.ps_line("sleep"), [])


def tmp_inodes(df):
    line = next(l for l in df.splitlines() if l.endswith("/tmp"))
    return line.split()[3]


class SmallRAMDisk(unittest.TestCase):
    """A 128 KB REU: a /tmp (512 blocks) small enough to fill."""

    def test_full_disk_does_not_leak_inodes(self):
        with Vice(copy_image("reu128"), extra=["-reu", "-reusize", "128"]) as v:
            v.wait_shell()
            v.run("cd /tmp")
            v.run("cp /bin/as a")
            v.run("cat a a a a > b")
            for f in "cde":
                v.run("cat b a > " + f)          # 130 blocks each: the last one fills /tmp
            before = tmp_inodes(v.run("df"))
            self.assertIn("no space", v.run("mkdir x"))
            self.assertEqual(tmp_inodes(v.run("df")), before)


class BigGeoRAM(unittest.TestCase):

    def test_4mb_georam_is_64_banks(self):
        with Vice(copy_image("geo4m"), extra=["-georam", "-georamsize", "4096"]) as v:
            v.wait_shell()
            self.assertIn("georam: 64 x 64k", v.screen())


class GeoRAMRoot(unittest.TestCase):
    """No drive 8, the disk image preloaded into a GeoRAM: it is the root disk."""

    def test_boot_from_georam_image(self):
        with open(IMAGE, "rb") as f:
            d64 = f.read()
        geo = os.path.join(ROOT, "build", "georoot-%d.bin" % os.getpid())
        with open(geo, "wb") as f:
            f.write(d64.ljust(512 * 1024, b"\0"))
        # a file block at the start of a 16 KB GeoRAM block: detection writes there
        fs = mkimage.FS(mkimage.Image(d64))
        target = None
        todo = [("/", mkimage.ROOT_INO)]
        while todo and not target:
            path, d = todo.pop()
            for name, n in fs.dir_entries(d):
                if name in (b".", b".."):
                    continue
                p = path + name.decode()
                ino = fs.read_inode(n)
                if ino["type"] == mkimage.T_DIR:
                    todo.append((p + "/", n))
                elif ino["type"] == mkimage.T_FILE:
                    for i in range((ino["size"] + 255) // 256):
                        if fs.bmap(ino, i) % 64 == 0:
                            target = (p, i, fs.read_file(n))
                            break
        self.assertIsNotNone(target)
        path, i, data = target
        with Vice(PRG, extra=["-drive8type", "0", "-georam", "-georamsize", "512",
                              "-georamimage", geo, "-autostartprgmode", "1"]) as v:
            v.wait_shell()
            d, name = path.rsplit("/", 1)
            v.run("cd " + (d or "/"))
            line = v.run("hexdump %s | grep %04x:" % (name, i * 256))
            got = line.split(":")[1].split()[:8]
            self.assertEqual(got, ["%02x" % b for b in data[i * 256:i * 256 + 8]])


if __name__ == "__main__":
    unittest.main()
