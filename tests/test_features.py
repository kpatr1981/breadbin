"""Tests for 0.4 features, run on the test image (tests/progs as /test)."""
import os
import re
import subprocess
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from vicetest import Vice, scratch_file  # noqa: E402
import mkimage  # noqa: E402

IMAGE = os.path.join(ROOT, "build", "breadbin-test.d64")


def copy_image(name):
    img = scratch_file(os.path.join(ROOT, "build", "%s-%d.d64" % (name, os.getpid())))
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
    """$?, && and ||, 2> and 2>&1, history (cursor up/down), completion."""

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

    def test_pipe_and_underscore_keys(self):
        # a C64 types | as shift+minus ($dd); VICE's symbolic keyboard mapping
        # sends a PC's | as shift+pound ($a9) and _ as the underscore graphic
        # ($a4): the console must take them all
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v._cmd("keybuf echo a\\xa4b \\xa9 wc\\x0d")
        self.v._cmd("x")
        s = self.v.wait_for(" 1 ", after="$ echo a_b | wc")
        self.assertIn("1      1      4", s)

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

    def test_complete(self):
        # CTRL-I (TAB) completes the word before the cursor: a command name
        # from /bin (also after a |), a file name, '/' after a directory;
        # with several matches it types what they share, and a second TAB
        # lists them
        def tab():
            self.v._cmd("keybuf \\x09")
            self.v._cmd("x", wait=0.5)
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v.type("whoa")
        tab()
        self.v.type("\n")
        self.v.wait_for("root", after="$ whoami")
        self.v.type("echo hi | hexd")
        tab()
        self.v.type("\n")
        self.v.wait_for("68 69", after="$ echo hi | hexdump")
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v.type("echo /ho")
        tab()
        self.v.type("\n")
        self.v.wait_for("/home/", after="$ echo /home/\n")
        self.v.type("echo /home/h")
        tab()                                   # hello.bas, hello.s: "hello."
        tab()                                   # lists them
        s = self.v.wait_for("$ echo /home/hello.", after="hello.bas")
        listing = [l for l in s.splitlines() if "hello.bas" in l][-1]
        self.assertEqual(sorted(listing.split()), ["hello.bas", "hello.s"])
        self.v.type("s")
        tab()
        self.v.type("\n")
        self.v.wait_for("$ echo /home/hello.s\n/home/hello.s")

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
        ino["mtime"], ino["ctime"] = 1700000000, 1700000001 # must survive fsck -f
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
        with open(img, "rb") as f:
            after = mkimage.FS(mkimage.Image(f.read())).read_inode(motd)
        self.assertEqual((after["nlink"], after["mtime"], after["ctime"]), (1, 1700000000, 1700000001))


class BigRAMDisk(unittest.TestCase):
    """A 2 MB REU: /tmp gets all of it but the 3 banks that keep a copy of
    drive 8 and the 128 pages of the swap area: 7296 blocks (four bitmap
    blocks)."""

    def test_full_size_tmp(self):
        with Vice(copy_image("reu2m"), extra=["-reu", "-reusize", "2048"]) as v:
            v.wait_shell()
            tmp = next(l for l in v.run("df").splitlines() if l.endswith("/tmp"))
            self.assertEqual(tmp.split()[0], "7296", tmp)
            v.run("cd /tmp")
            v.run("cp /bin/as a")                       # 23 blocks
            v.run("cat a a a a a a a a > b")
            v.run("cat b a > c")
            for i in range(16):                         # 16 x 207 blocks: past block 2048
                v.run("cp c c%d" % i, timeout=180)
            used = int(next(l for l in v.run("df").splitlines() if l.endswith("/tmp")).split()[1])
            self.assertGreater(used, 2200)
            self.assertEqual(v.run("wc c15"), v.run("wc c").replace(" c", " c15"))
            self.assertEqual(v.run("fsck /tmp", timeout=300), "clean")
            v.run("rm c0")
            self.assertEqual(v.run("fsck /tmp", timeout=300), "clean")


class DriveCopyInREU(unittest.TestCase):
    """With an REU, drive 8's blocks are read from the drive once."""

    def test_second_read_comes_from_the_reu(self):
        img = copy_image("dc")
        with Vice(img, reu=True) as v:
            v.wait_shell()
            v.run("cd /bin")
            first = int(v.run("/test/readtime as basic edit", timeout=300))
            second = int(v.run("/test/readtime as basic edit", timeout=300))
            print("\nreadtime: first %d, second %d jiffies" % (first, second))
            self.assertLess(second * 4, first)
            v.run("cp as /home/x")                      # writes reach the copy too
            v.run("cat basic edit > /dev/null")
            self.assertEqual(v.run("wc /home/x"), v.run("wc as").replace(" as", " /home/x"))
            v.run("sync")
        self.assertEqual(host_cat(img, "/home/x"), host_cat(img, "/bin/as"))


class FastLoader(unittest.TestCase):
    """Drive 8 sends sectors with Breadbin's drive code, not the KERNAL protocol."""

    def test_reads_are_faster(self):
        img = copy_image("fast")
        with Vice(img, extra=["-drive9type", "1541", "-9", copy_image("fast9")]) as v:
            v.wait_shell()                              # (a second drive on the bus)
            v.run("cd /bin")
            t = int(v.run("/test/readtime as basic edit", timeout=600))
            print("\nreadtime without an REU: %d jiffies (0.3: 3262)" % t)
            # 0.3 (KERNAL-speed transfer): 3262; drive code: ~1750. The rest is
            # disk rotation: a file's blocks sit on consecutive sectors
            self.assertLess(t, 2200)
            v.run("cp as /home/x")
            self.assertEqual(v.run("wc /home/x"), v.run("wc as").replace(" as", " /home/x"))
            v.run("sync")
        self.assertEqual(host_cat(img, "/home/x"), host_cat(img, "/bin/as"))


class Tools(unittest.TestCase):
    """tee, tail and sort."""

    @classmethod
    def setUpClass(cls):
        cls.v = Vice(copy_image("tools"))
        cls.v.wait_shell()
        with open(os.path.join(ROOT, "rootfs", "etc", "help")) as f:
            cls.help = f.read().splitlines()

    @classmethod
    def tearDownClass(cls):
        cls.v.close()

    def test_tee(self):
        counts = self.v.run("wc /etc/help").replace(" /etc/help", "")
        self.assertEqual(self.v.run("cat /etc/help | tee /home/t1 | wc"), counts)
        self.assertEqual(self.v.run("wc /home/t1"), counts + " /home/t1")
        self.assertEqual(self.v.run("echo more | tee -a /home/t1"), "more")
        self.assertEqual(self.v.run("tail -1 /home/t1"), "more")
        self.v.run("rm /home/t1")

    def test_tail(self):
        self.assertEqual(self.v.run("tail -3 /etc/help").splitlines(), self.help[-3:])
        self.assertEqual(self.v.run("tail /etc/help").splitlines(), self.help[-10:])
        self.assertEqual(self.v.run("cat /etc/help | tail -2").splitlines(), self.help[-2:])

    def test_tail_past_the_ring(self):
        # inputs of 2 KB (the ring) and more: the ring wraps, at its exact size too
        for name in ("lines300", "ring2048", "ring2049"):
            with open(os.path.join(ROOT, "tests", "data", name + ".txt")) as f:
                lines = f.read().splitlines()
            for n in (1, 2, 10):
                path = "/test/%s.txt" % name
                self.assertEqual(self.v.run("tail -%d %s" % (n, path)).splitlines(), lines[-n:],
                                 "tail -%d %s" % (n, path))
            self.assertEqual(self.v.run("cat %s | tail -3" % path).splitlines(), lines[-3:])
        self.assertEqual(self.v.run("echo still here"), "still here")

    def test_seek(self):
        self.v.run("echo abcdefghijklmnop > /home/s")     # 17 bytes with the newline
        self.assertEqual(self.v.run("/test/seek /home/s").splitlines(),
                         ["fgh", "13", "nop", "einval", "einval"])
        self.v.run("rm /home/s")

    def test_sort(self):
        want = sorted(self.help)
        self.assertEqual(self.v.run("sort /etc/help").splitlines(), want)
        self.assertEqual(self.v.run("cat /etc/help | sort -r").splitlines(), want[::-1])


class Touch(unittest.TestCase):
    """touch."""

    @classmethod
    def setUpClass(cls):
        cls.v = Vice(copy_image("touch"))
        cls.v.wait_shell()

    @classmethod
    def tearDownClass(cls):
        cls.v.close()

    def test_new_file(self):
        self.assertEqual(self.v.run("touch /home/t1 ; echo $?"), "0")
        self.assertRegex(self.v.run("ls -l /home/t1"), r"^-     0 \d\d-\d\d-\d\d \d\d:\d\d /home/t1$")
        self.v.run("rm /home/t1")

    def test_several_names(self):
        self.v.run("touch /home/t2 /home/t3")
        self.assertEqual(self.v.run("ls /home/t2"), "/home/t2")
        self.assertEqual(self.v.run("ls /home/t3"), "/home/t3")
        self.v.run("rm /home/t2 /home/t3")

    def test_existing_file_gets_the_time(self):
        self.v.run("date 2030-05-06 07:08:09")
        self.v.run("echo hi > /home/t4")
        self.v.run("date 2031-01-02 03:04:05")
        self.assertIn("30-05-06 07:", self.v.run("ls -l /home/t4"))
        self.assertEqual(self.v.run("touch /home/t4 ; echo $?"), "0")
        self.assertIn("31-01-02 03:", self.v.run("ls -l /home/t4"))
        self.assertEqual(self.v.run("cat /home/t4"), "hi")
        self.v.run("rm /home/t4")

    def test_directory_and_device(self):
        self.assertEqual(self.v.run("touch /home ; echo $?"), "0")
        self.assertEqual(self.v.run("touch /dev/null ; echo $?"), "0")

    def test_bad_path_goes_on(self):
        out = self.v.run("touch /x/y /home/t5 ; echo $?")
        self.assertIn("no such file", out.replace("\n", ""))
        self.assertEqual(out.splitlines()[-1], "1")
        self.assertEqual(self.v.run("ls /home/t5"), "/home/t5")
        self.v.run("rm /home/t5")

    def test_usage(self):
        self.assertEqual(self.v.run("touch ; echo $?"), "usage: touch name...\n1")


class Times(unittest.TestCase):
    """The clock, file times (format 2), date, ls -l and stat. VICE runs in
    warp mode, so emulated time runs faster than the test's: the checks
    allow for minutes passing between commands."""

    @classmethod
    def setUpClass(cls):
        cls.img = copy_image("times")
        cls.v = Vice(cls.img)
        cls.v.wait_shell()
        cls.first_date = cls.v.run("date")

    @classmethod
    def tearDownClass(cls):
        cls.v.close()

    def date_after(self, setting, wait):
        self.v.run("date " + setting)
        time.sleep(wait)
        return self.v.run("date")

    def test_clock_starts_from_the_disk(self):
        # mkimage puts the build time in last_time; the clock starts there
        year = time.localtime().tm_year
        self.assertTrue(Times.first_date.startswith(str(year)), Times.first_date)

    def test_host_times_on_the_image(self):
        st = os.stat(os.path.join(ROOT, "build", "troot.all", "etc", "motd"))   # what the test image was built from
        want = time.strftime("%y-%m-%d %H:%M", time.localtime(st.st_mtime))
        self.assertIn(want, self.v.run("ls -l /etc/motd"))

    def test_leap_day_and_new_month(self):
        self.assertTrue(self.v.run("date 2024-02-29 23:59:58").startswith("2024-02-29 23:59:5"))
        self.assertTrue(self.date_after("2024-02-29 23:59:59", 3).startswith("2024-03-01 00:"))

    def test_new_year(self):
        self.assertTrue(self.date_after("2025-12-31 23:59:59", 3).startswith("2026-01-01 00:"))

    def test_2100_is_not_a_leap_year(self):
        self.assertIn("usage", self.v.run("date 2100-02-29"))
        self.assertTrue(self.date_after("2100-02-28 23:59:59", 3).startswith("2100-03-01 00:"))

    def test_1970_and_bad_input(self):
        self.assertTrue(self.v.run("date 1970-01-01 00:00").startswith("1970-01-01 00:00:0"))
        for bad in ("1969-12-31", "2026-13-01", "2026-04-31", "24:00", "12:60", "12:00:60", "2026-1-1x"):
            self.assertIn("usage", self.v.run("date " + bad), bad)

    def test_date_keeps_the_other_half(self):
        self.v.run("date 2027-03-04 05:06:07")
        self.assertTrue(self.v.run("date 08:09").startswith("2027-03-04 08:09:0"))
        self.assertTrue(self.v.run("date 2028-01-02").startswith("2028-01-02 08:"))

    def test_stat_shows_both_times(self):
        self.v.run("date 2029-08-09 10:11:12")
        self.v.run("echo x > /home/st")
        out = self.v.run("stat /home/st")
        self.assertRegex(out, r"modify: 2029-08-09 10:\d\d:\d\d")
        self.assertRegex(out, r"change: 2029-08-09 10:\d\d:\d\d")
        self.v.run("rm /home/st")

    def test_copy_gets_the_current_time_move_keeps_it(self):
        self.v.run("date 2032-02-03 04:05:06")
        self.v.run("echo y > /home/cm")
        self.v.run("date 2033-03-04 05:06:07")
        self.v.run("cp /home/cm /home/cm2")
        self.v.run("mv /home/cm /home/cm3")
        self.assertIn("33-03-04 05:", self.v.run("ls -l /home/cm2"))
        self.assertIn("32-02-03 04:0", self.v.run("ls -l /home/cm3"))
        self.v.run("rm /home/cm2 /home/cm3")

    def test_ls_line_fits_40_columns(self):
        self.v.run("echo z > /home/abcdefghijklmn")
        line = self.v.run("ls -l /home").splitlines()
        self.assertTrue(all(len(l) <= 40 for l in line), line)
        self.v.run("rm /home/abcdefghijklmn")


class TimeAcrossReboot(unittest.TestCase):
    """last_time keeps the clock from going backwards across a reboot."""

    def test_clock_survives_reboot(self):
        img = copy_image("reboot")
        with Vice(img) as v:
            v.wait_shell()
            v.run("date 2040-06-07 08:09:10")
            v.run("echo t > /home/r")         # an inode change: saves the clock
            v.run("sync")
        with open(img, "rb") as f:
            fs = mkimage.FS(mkimage.Image(f.read()))
        self.assertGreaterEqual(fs.last_time(), fs.read_inode(fs.lookup("/home/r"))["mtime"] - 255)
        with Vice(img) as v:
            v.wait_shell()
            out = v.run("date")[:19]
        # moved up to the next 256 s step past last_time (1 to 256 s later),
        # plus the boot (VICE runs in warp mode: emulated time runs fast)
        self.assertGreaterEqual(out, "2040-06-07 08:09:11")
        self.assertLessEqual(out, "2040-06-07 08:20:00")


class Edit(unittest.TestCase):
    """edit: where the text ends, what a key redraws, files too big, ^K."""

    LINE = b"0123456789" * 5 + b"\n"                   # 51 bytes
    FILES = {
        "ends": LINE * 5 + b"zzz",                      # 258 bytes; 255 after 3 DELs
        "lines": b"one\ntwo\nthree\nfour\n",
        "kill": b"one\ntwo\nthree",
        "big": (b"x" * 99 + b"\n") * 84 + b"y" * 47 + b"\n",   # 8,448: 8 KB and a page
    }

    @classmethod
    def setUpClass(cls):
        img = copy_image("edit")
        with open(img, "rb") as f:
            image = mkimage.Image(f.read())
        fs = mkimage.FS(image)
        home = fs.lookup("/home")
        for name, data in cls.FILES.items():
            fs.create(home, name.encode(), data)
        with open(img, "wb") as f:
            f.write(image.data)
        cls.v = Vice(img)
        cls.v.wait_shell()

    @classmethod
    def tearDownClass(cls):
        cls.v.close()

    def until(self, pred, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            s = self.v.screen_lines()
            if pred(s):
                return s
            time.sleep(0.1)
        self.fail("timed out:\n" + "\n".join(self.v.screen_lines()))

    def setUp(self):
        if "edit:" in self.v.screen_lines()[24]:      # a failed test left edit open
            self.quit()

    def keys(self, *codes):
        self.v._cmd("keybuf " + "".join("\\x%02x" % c for c in codes))
        self.v._cmd("x")

    def open(self, name):
        self.v.type("clear\nedit /home/%s\n" % name)
        return self.until(lambda s: ("/home/" + name) in s[24])

    def quit(self):
        self.keys(0x18)                                 # ^X
        s = self.until(lambda s: Vice.PROMPT.match(s[0]) or "unsaved" in s[24])
        if not Vice.PROMPT.match(s[0]):
            self.keys(0x18)                             # again, to drop the changes
            self.until(lambda s: Vice.PROMPT.match(s[0]))   # edit clears the screen

    def size(self, name):
        return int(self.v.run("ls -l /home/" + name).split()[1])

    def test_nothing_drawn_past_the_end(self):
        # 255 bytes end past a page boundary unless the text starts on one, and
        # the deleted "zzz" stays in memory just past the end.
        self.open("ends")
        self.keys(0x11, 0x11, 0x11, 0x11, 0x11)         # down to "zzz"
        self.keys(0x1D, 0x1D, 0x1D, 0x14, 0x14, 0x14)   # to its end, DEL x3
        s = self.until(lambda s: "*" in s[24] and s[4] and "z" not in s[5])
        self.assertEqual([l for l in s[:24] if l], [self.LINE[:39].decode()] * 5)
        self.quit()

    def test_cursor_keys_redraw_nothing(self):
        self.open("lines")
        self.v._cmd("> 0590 2a")                        # a '*' on row 10, col 0
        self.v._cmd("> 07e6 2a")                        # and at the status line's end
        self.v._cmd("x")
        self.keys(0x1D, 0x11)                           # right, down
        time.sleep(1)
        s = self.v.screen_lines()
        self.assertEqual(s[10], "*")
        self.assertTrue(s[24].endswith("*"), s[24])
        self.keys(ord("A"))                             # typing redraws the text,
        self.until(lambda s: s[10] == "" and "*" in s[24] and not s[24].endswith("*"))
        self.quit()

    def test_ctrl_l_redraws_everything(self):
        # what a background job might print over the screen: gone after ^L
        self.open("lines")
        self.v._cmd("> 0428 2a")                        # over "two" (row 1)
        self.v._cmd("> 0590 2a")                        # an empty row (10)
        self.v._cmd("> 07e6 2a")                        # the status line's end
        self.v._cmd("x")
        self.keys(0x0C)                                 # ^L
        s = self.until(lambda s: s[1] == "two" and s[10] == "" and not s[24].endswith("*"))
        self.assertEqual(s[:4], ["one", "two", "three", "four"])
        self.quit()

    def test_a_file_over_8_kb_is_refused(self):
        self.v.type("clear\nedit /home/big; echo $?\n")
        s = self.until(lambda s: s[2] == "1" or "edit:" in s[24])   # (or it opened)
        self.assertEqual(s[1:3], ["edit: file too big", "1"])
        self.assertEqual(self.size("big"), 8448)

    def test_line_kill(self):
        self.open("kill")
        self.keys(0x11, 0x0B)                           # down, ^K: "two"
        self.until(lambda s: s[1] == "three")
        self.keys(0x0B)                                 # the last line, no newline
        self.until(lambda s: s[1] == "")
        self.keys(0x0B)                                 # an empty last line
        self.keys(0x0F)                                 # ^O
        self.until(lambda s: "saved" in s[24])
        self.quit()
        self.assertEqual(self.v.run("wc /home/kill").split()[:3], ["1", "1", "4"])


class Swap(unittest.TestCase):
    """With an REU, processes that aren't running go to the REU when the
    pool runs out: four 41-page memhogs at once (186 pages with sh and init,
    in a 124-page pool) all keep their memory."""

    def hogs(self, v, n, rounds, out):
        for i in range(1, n + 1):
            v.run("/test/memhog %d > %s/h%d &" % (rounds, out, i))
        self.assertEqual(v.run("ps").count("memhog"), n)     # all alive at once

    def test_more_than_the_pool(self):
        with Vice(copy_image("swap"), reu=True) as v:
            v.wait_shell()
            tmp = next(l for l in v.run("df").splitlines() if l.endswith("/tmp"))
            self.assertEqual(tmp.split()[0], "1152", tmp)    # 5 banks, less 128 blocks
            self.hogs(v, 3, 100, "/tmp")              # (warp: ~1 min)
            self.assertEqual(v.run("/test/memhog", timeout=300).splitlines()[0], "ok")
            end = time.time() + 300
            while time.time() < end:                         # (skip "[n] done" notices)
                out = [w for w in v.run("cat /tmp/h1 /tmp/h2 /tmp/h3").split() if w in ("ok", "bad")]
                if len(out) == 3:
                    break
                time.sleep(2)
            self.assertEqual(out, ["ok"] * 3)
            self.assertEqual(v.run("echo still here"), "still here")
            self.assertEqual(v.run("fsck /tmp", timeout=300), "clean")

    def test_without_an_reu_the_pool_is_the_limit(self):
        with Vice(copy_image("noswap")) as v:
            v.wait_shell()
            self.hogs(v, 2, 100, "/home")
            self.assertIn("out of memory", v.run("/test/memhog 1", timeout=120))


class InodeAlloc(unittest.TestCase):
    """New inodes are looked for after the last one handed out, and the
    search wraps around (#4): a full table still fills to the last inode,
    and one freed behind the search is found again."""

    def test_fill_free_and_wrap(self):
        with Vice(copy_image("inodes"), reu=True) as v:
            v.wait_shell()
            v.run("cd /tmp")
            free = int(next(l for l in v.run("df").splitlines() if l.endswith("/tmp")).split()[3])
            self.assertEqual(v.run("/test/mkfiles a", timeout=600), str(free))
            self.assertEqual(v.run("/test/mkfiles b"), "0")           # full
            v.run("rm a00")                                            # behind the search
            self.assertEqual(v.run("/test/mkfiles c"), "1")
            self.assertEqual(v.run("ls c00"), "c00")
            self.assertEqual(v.run("fsck /tmp", timeout=300), "clean")


if __name__ == "__main__":
    unittest.main()
