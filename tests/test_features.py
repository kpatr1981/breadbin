"""Tests for 0.4 features, run on the test image (tests/progs as /test)."""
import os
import re
import subprocess
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from vicetest import Vice  # noqa: E402
import mkimage  # noqa: E402

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


class Clock(unittest.TestCase):
    """The jiffy clock keeps time while the serial bus has interrupts off."""

    def test_no_ticks_lost_during_disk_io(self):
        def stopwatch(v):
            out = v._cmd("sw", wait=0.3)
            v._cmd("x")
            return int(re.search(r"Stopwatch:\s*(\d+)", out).group(1))

        with open(os.path.join(ROOT, "build", "kernel.lbl")) as f:
            at = next(int(l.split()[1], 16) for l in f if l.split()[2:] == [".ticks"])

        def ticks(v):
            m = v.mem(at, at + 2)
            return m[0] | m[1] << 8 | m[2] << 16

        with Vice(copy_image("clock")) as v:
            v.wait_shell()
            v.run("cd /bin")
            t0, c0 = ticks(v), stopwatch(v)
            v.run("cat as basic sh > /dev/null", timeout=300)
            t1, c1 = ticks(v), stopwatch(v)
        # CIA 1 timer A: $4025 cycles per jiffy on PAL, $4295 on NTSC
        expected = (c1 - c0) / (0x4295 if "-ntsc" in os.environ.get("VICEFLAGS", "") else 0x4025)
        self.assertGreater((t1 - t0) / expected, 0.99)


class Shell(unittest.TestCase):
    """$?, && and ||, 2> and 2>&1, and history (cursor up/down)."""

    @classmethod
    def setUpClass(cls):
        cls.v = Vice(copy_image("shell"))
        cls.v.wait_shell()

    @classmethod
    def tearDownClass(cls):
        cls.v.close()

    def run_(self, cmd):
        return self.v.run(cmd)

    def test_exit_status(self):
        self.assertEqual(self.run_("echo hi; echo $?"), "hi\n0")
        self.assertTrue(self.run_("cat /nope; echo $?").endswith("\n1"))
        self.assertEqual(self.run_("cd /nope; echo $?").splitlines()[-1], "1")

    def test_and_or(self):
        self.assertEqual(self.run_("echo a && echo b"), "a\nb")
        self.assertNotIn("yes", self.run_("cat /nope && echo yes"))
        self.assertTrue(self.run_("cat /nope || echo no").endswith("no"))
        self.assertEqual(self.run_("echo a || echo b"), "a")
        self.assertTrue(self.run_("cat /x && echo y || echo z").endswith("z"))

    def test_stderr_redirect(self):
        self.assertEqual(self.run_("cat /nope 2> /home/err"), "")
        self.assertIn("no such file", self.run_("cat /home/err"))
        self.assertEqual(self.run_("cat /nope 2>&1 | wc").split()[0], "1")
        self.run_("rm /home/err")

    def test_history(self):
        def keys(*ks):
            for k in ks:
                self.v._cmd("keybuf \\x%02x" % k)
                self.v._cmd("x", wait=0.5)
        UP, DOWN, RET = 0x91, 0x11, 0x0d
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v.type("echo first\n")
        self.v.wait_for("first", after="$ echo first")
        self.v.type("echo second\n")
        self.v.wait_for("second", after="$ echo second")
        keys(UP, UP, RET)                       # newest first: second, first
        self.v.wait_for("first", after="$ echo second\nsecond\n/ $ echo first")
        keys(UP, UP, UP, DOWN, RET)             # first, second, first; down: second
        s = self.v.wait_for("second", after="first\n/ $ echo second")
        self.assertTrue(s.rstrip().endswith("second\n/ $"), s)


class Restore(unittest.TestCase):
    """An NMI (RESTORE) kills a foreground program even with interrupts off."""

    def test_nmi_kills_a_hung_program(self):
        with Vice(copy_image("nmi")) as v:
            v.wait_shell()
            self.assertEqual(v.run("/test/hang; echo $?", timeout=60), "137")   # 128 + SIGKILL
            self.assertEqual(v.run("echo alive"), "alive")
            self.assertNotIn("hang", v.run("ps"))


class Fsck(unittest.TestCase):

    def test_clean_disks(self):
        with Vice(copy_image("fsck0"), reu=True) as v:
            v.wait_shell()
            self.assertEqual(v.run("fsck", timeout=300), "clean")
            self.assertEqual(v.run("fsck /tmp", timeout=300), "clean")

    def test_finds_and_repairs_damage(self):
        img = copy_image("fsck1")
        with open(img, "rb") as f:
            im = mkimage.Image(f.read())
        fs = mkimage.FS(im)
        motd = fs.lookup("/etc/motd")
        ino = fs.read_inode(motd)
        ino["nlink"] = 3                                    # wrong link count
        fs.write_inode(motd, ino)
        orphan = fs.alloc_inode(mkimage.T_FILE)             # in no directory
        fs.write_file(orphan, b"lost data\n")
        leaked = fs.alloc_block()                           # marked used, owned by nothing
        rd = fs.read_inode(fs.lookup("/home/readme"))
        fs.set_used(rd["direct"][0], False)                 # in use, marked free
        home = fs.lookup("/home")
        free_ino = fs.alloc_inode(mkimage.T_FILE)
        fs.dir_add(home, b"ghost", free_ino)                # an entry to a free inode
        g = fs.read_inode(free_ino)
        g["type"] = mkimage.T_FREE
        fs.write_inode(free_ino, g)
        with open(img, "wb") as f:
            f.write(im.data)
        with Vice(img) as v:
            v.wait_shell()
            out = v.run("fsck", timeout=300)
            self.assertIn("inode %d: links 3, should be 1" % motd, out)
            self.assertIn("inode %d: in no directory" % orphan, out)
            self.assertIn("block %d: marked used, not in use" % leaked, out)
            self.assertIn("block %d: in use, marked free" % rd["direct"][0], out)
            self.assertIn("entry ghost -> free inode %d" % free_ino, out)
            self.assertTrue(out.endswith("5 problems"), out)
            self.assertIn("fixed", v.run("fsck -f", timeout=300))
            self.assertEqual(v.run("fsck", timeout=300), "clean")
            self.assertIn("welcome", v.run("cat /etc/motd"))
            self.assertNotIn("ghost", v.run("ls /home"))


class BigRAMDisk(unittest.TestCase):
    """A 2 MB REU: /tmp uses all of it (four bitmap blocks)."""

    def test_full_size_tmp(self):
        with Vice(copy_image("reu2m"), extra=["-reu", "-reusize", "2048"]) as v:
            v.wait_shell()
            tmp = next(l for l in v.run("df").splitlines() if l.endswith("/tmp"))
            self.assertEqual(tmp.split()[0], "8192", tmp)
            v.run("cd /tmp")
            v.run("cp /bin/as a")
            v.run("cat a a a a > b")
            v.run("cat b a > c")
            for i in range(16):                         # 16 x 130 blocks: past block 2048
                v.run("cp c c%d" % i, timeout=180)
            used = int(next(l for l in v.run("df").splitlines() if l.endswith("/tmp")).split()[1])
            self.assertGreater(used, 2200)
            self.assertEqual(v.run("wc c15"), v.run("wc c").replace(" c", " c15"))
            self.assertEqual(v.run("fsck /tmp", timeout=300), "clean")
            v.run("rm c0")
            self.assertEqual(v.run("fsck /tmp", timeout=300), "clean")


if __name__ == "__main__":
    unittest.main()
