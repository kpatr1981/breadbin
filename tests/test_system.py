"""End-to-end tests: boot Breadbin in VICE and drive the shell."""
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from vicetest import Vice  # noqa: E402

IMAGE = os.path.join(ROOT, "build", "breadbin.d64")


class Boot(unittest.TestCase):
    """One VICE session for a sequence of checks (booting is the slow part)."""

    @classmethod
    def setUpClass(cls):
        cls.img = os.path.join(ROOT, "build", "test.d64")
        with open(IMAGE, "rb") as f, open(cls.img, "wb") as g:
            g.write(f.read())
        cls.v = Vice(cls.img)
        cls.v.wait_shell()

    @classmethod
    def tearDownClass(cls):
        cls.v.close()

    def run_(self, cmd):
        return self.v.run(cmd)

    def test_01_banner(self):
        s = self.v.screen()
        self.assertIn("breadbin 0.4", s)
        self.assertIn("kpatronas@gmail.com", s)

    def test_02_echo(self):
        self.assertEqual(self.run_("echo hello world"), "hello world")

    def test_03_ls_bin(self):
        out = self.run_("ls /bin")
        for name in ["cat", "ls", "sh", "init", "grep"]:
            self.assertIn(name, out.split())

    def test_04_cat(self):
        out = self.run_("cat /etc/motd")
        self.assertIn("welcome to breadbin.", out)

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
        # init + sh (login became the shell) + 10 jobs fill the 12-slot table
        pids = []
        for _ in range(10):
            pids.append(self.run_("sleep 9999 &").strip("[]"))
        out = self.v.run("sleep 9999 &", clear=False)
        self.assertIn("too many processes", out)
        self.assertTrue(all(p.isdigit() for p in pids), pids)
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

    def test_19_assembler(self):
        out = self.run_("as /home/hello.s /home/hello")
        self.assertIn("bytes", out)
        self.assertEqual(self.run_("/home/hello"), "hello, world! (assembled on a c64)")

    def test_20_more_pages(self):
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v.type("ls -l /bin | more\n")
        s = self.v.wait_for("--more--")
        self.assertIn("basic", s)
        self.v.type("q\n")
        self.v._wait(lambda ls: ls[-1].endswith(" $") or any(
            l.endswith(" $") for l in ls[-3:]), 60)

    def test_21_many_sleepers_stay_responsive(self):
        pids = [self.run_("sleep 9999 &").strip("[]") for _ in range(6)]
        import time
        t = time.time()
        self.assertEqual(self.run_("echo quick"), "quick")
        self.assertLess(time.time() - t, 30)
        self.v.run("kill " + " ".join(pids), clear=False)

    def test_22_easy_commands(self):
        self.assertEqual(self.run_("whoami"), "root")
        self.assertTrue(self.run_("uptime").startswith("up "))
        self.run_("date 13:45:10")
        self.assertTrue(self.run_("date").startswith("13:4"))
        self.assertEqual(self.run_("version"), "breadbin 0.4 by kpatronas@gmail.com")
        size = os.path.getsize(os.path.join(ROOT, "rootfs", "etc", "motd"))
        self.assertIn("size: %d" % size, self.run_("stat /etc/motd"))
        self.assertIn("0000: 77 65 6c 63", self.run_("hexdump /etc/motd | head -1"))
        self.assertIn("themes:", self.run_("theme nosuch"))
        self.run_("theme green")

    def test_23_wildcards_and_jobs(self):
        self.assertEqual(self.run_("echo /home/*.bas"), "/home/hello.bas")
        self.assertEqual(self.run_("echo /bin/s?"), "/bin/sh")
        self.assertEqual(self.run_("echo /nomatch*"), "/nomatch*")
        pid = self.run_("sleep 999 &").strip("[]")
        self.assertIn("[" + pid + "] running  sleep", self.run_("jobs"))
        self.run_("kill " + pid)

    def test_24_editor(self):
        import time
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v.type("edit /home/e.txt\n")
        self.v.wait_for("edit:", timeout=60)
        self.v.type("hello\nworld")
        time.sleep(2)
        self.v._cmd("keybuf \\x91\\x1d\\x1dX")   # up, right, right, X
        self.v._cmd("x")
        time.sleep(2)
        self.v._cmd("keybuf \\x0f")                  # ^O save
        self.v._cmd("x")
        self.v.wait_for(" saved")
        self.v._cmd("keybuf \\x18")                  # ^X quit
        self.v._cmd("x")
        time.sleep(3)
        self.assertEqual(self.run_("cat /home/e.txt | wc"), "     1      2     12")

    def test_25_login_password(self):
        import time
        self.v.type("clear\npasswd\n")
        self.v.wait_for("new password:")
        self.v.type("secret\n")
        self.v.wait_for("again:")
        self.v.type("secret\n")
        self.v.wait_for("password changed")
        self.v.type("exit\n")                         # log out: back to login
        self.v.wait_for("login:")
        self.v.type("root\n")
        self.v.wait_for("password:")
        self.v.type("wrong\n")
        self.v.wait_for("login incorrect")
        self.v.type("root\n")
        self.v.wait_for("password:")
        self.v.type("secret\n")
        time.sleep(4)
        self.assertEqual(self.run_("whoami"), "root")
        self.assertIn("root:", self.run_("cat /etc/passwd"))

    def ctrl_z(self):
        self.v._cmd("keybuf \\x1a")
        self.v._cmd("x")

    def test_26_job_control(self):
        # CTRL-Z stops the foreground job, fg brings it back, bg resumes it
        self.v.type("clear\n")
        self.v.wait_for("$")
        self.v.type("count > /dev/null\n")
        self.v.wait_for("$ count")
        import time
        time.sleep(2)
        self.ctrl_z()
        s = self.v.wait_for("] stopped")
        pid = s.split("] stopped")[0].split("[")[-1]
        self.assertIn("T&", next(l for l in self.run_("ps aux").splitlines()
                                 if l.endswith("count")))
        self.assertIn("[" + pid + "] stopped  count", self.run_("jobs"))
        self.v.type("clear\nfg\n")
        self.v.wait_for("$ fg")
        time.sleep(2)
        self.ctrl_z()
        self.v.wait_for("] stopped")
        self.assertEqual(self.run_("bg"), "[" + pid + "] running")
        self.assertIn(" s&", next(l for l in self.run_("ps").splitlines()
                                  if l.endswith("count")))
        # a background job that reads the console stops instead of
        # stealing the shell's keys
        cat = self.run_("cat &").strip("[]")
        time.sleep(2)
        self.assertIn("[" + cat + "] stopped  cat", self.run_("jobs"))
        self.run_("kill " + pid + " " + cat)
        self.assertNotIn("count", self.run_("ps"))
        self.assertIn("no such job", self.run_("fg 99"))

    def test_27_date(self):
        for t in ("00:00:00", "12:00:00", "23:59:59"):
            self.assertEqual(self.run_("date " + t), t)
        self.run_("date 11:59:59")
        self.assertTrue(self.run_("date").startswith("12:0"))


class Persistence(unittest.TestCase):
    """Files written by Breadbin survive a reboot and are readable on the host."""

    def test_write_reboot_read(self):
        img = os.path.join(ROOT, "build", "persist.d64")
        with open(IMAGE, "rb") as f, open(img, "wb") as g:
            g.write(f.read())
        with Vice(img) as v:
            v.wait_shell()
            v.run("mkdir /home/keep")
            v.run("echo persistent data > /home/keep/f")
        out = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "mkimage.py"),
                              "cat", img, "/home/keep/f"], capture_output=True, text=True)
        self.assertEqual(out.stdout, "persistent data\n")
        with Vice(img) as v:
            v.wait_shell()
            self.assertEqual(v.run("cat /home/keep/f"), "persistent data")


class REU(unittest.TestCase):
    """With an REU: /tmp is a RAM disk."""

    def test_tmp_ramdisk(self):
        with Vice(IMAGE, reu=True) as v:
            v.wait_shell()
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


class GeoRAM(unittest.TestCase):
    """With a GeoRAM (and no REU): /tmp is a RAM disk too."""

    def test_georam_ramdisk(self):
        with Vice(IMAGE, extra=["-georam", "-georamsize", "512"]) as v:
            v.wait_shell()
            self.assertIn("georam: 8 x 64k", v.screen())
            self.assertIn("georam:    512", v.run("free"))
            v.run("cp /home/readme /tmp/r")
            self.assertEqual(v.run("wc /tmp/r"), v.run("wc /home/readme").replace("/home/readme", "/tmp/r"))
            v.run("mkdir /tmp/d")
            v.run("echo hi > /tmp/d/x")
            self.assertEqual(v.run("cat /tmp/d/x"), "hi")


def c1541_dir(img):
    out = subprocess.run(["c1541", img, "-dir"], capture_output=True, text=True).stdout
    return out


class Drives(unittest.TestCase):
    """mount: normal C64 disks and Breadbin disks on drive 9."""

    def test_cbm_disk(self):
        cbm = os.path.join(ROOT, "build", "t_cbm9.d64")
        if os.path.exists(cbm):
            os.unlink(cbm)
        subprocess.run(["c1541", "-format", "cbmdisk,cb", "d64", cbm,
                        "-write", os.path.join(ROOT, "rootfs", "etc", "motd"), "motd,s",
                        "-write", os.path.join(ROOT, "rootfs", "home", "readme"), "readme,s"],
                       capture_output=True, check=True)
        with Vice(IMAGE, extra=["-drive9type", "1541", "-9", cbm]) as v:
            v.wait_shell()
            self.assertEqual(v.run("mount 9 /mnt"), "")
            self.assertIn("drive 9 on /mnt (cbm dos)", v.run("mount"))
            self.assertEqual(v.run("ls /mnt").split(), ["motd", "readme"])
            self.assertIn("welcome to breadbin.", v.run("cat /mnt/motd"))
            v.run("cp /etc/help /mnt/help")
            v.run("rm /mnt/motd")
            v.run("mv /mnt/help /mnt/h2")
            self.assertEqual(v.run("ls /mnt").split(), ["readme", "h2"])
            self.assertEqual(v.run("touch /mnt/new ; echo $?"), "0")
            self.assertEqual(v.run("touch /mnt/readme ; echo $?"), "0")
            self.assertEqual(sorted(v.run("ls /mnt").split()), ["h2", "new", "readme"])
            self.assertNotEqual(v.run("grep -c unix /mnt/readme"), "0")
            self.assertIn("/mnt", v.run("df"))
            self.assertIn("operation not permitted", v.run("mkdir /mnt/d"))
            v.run("umount /mnt")
        d = c1541_dir(cbm)
        self.assertIn('"h2"', d)
        self.assertIn('"new"', d)
        self.assertNotIn('"motd"', d)
        out = os.path.join(ROOT, "build", "t_h2.txt")
        subprocess.run(["c1541", cbm, "-read", "h2,s", out], capture_output=True)
        with open(out, "rb") as f, open(os.path.join(ROOT, "rootfs", "etc", "help"), "rb") as g:
            self.assertEqual(f.read(), g.read())

    def test_breadbin_disk(self):
        img9 = os.path.join(ROOT, "build", "t_c64fs9.d64")
        with open(IMAGE, "rb") as f, open(img9, "wb") as g:
            g.write(f.read())
        with Vice(IMAGE, extra=["-drive9type", "1541", "-9", img9]) as v:
            v.wait_shell()
            v.run("mount 9 /mnt")
            self.assertIn("drive 9 on /mnt (c64fs)", v.run("mount"))
            v.run("mkdir /mnt/x")
            v.run("echo hi > /mnt/x/f")
            self.assertEqual(v.run("cat /mnt/x/f"), "hi")
            self.assertEqual(v.run("/mnt/bin/echo from drive 9"), "from drive 9")
            v.run("cd /mnt/x")
            self.assertIn("device busy", v.run("umount /mnt"))
            v.run("cd ../..")
            self.assertEqual(v.run("pwd"), "/")
            self.assertEqual(v.run("umount /mnt"), "")
            self.assertIn("no such device", v.run("mount 10 /mnt"))
        out = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "mkimage.py"),
                              "cat", img9, "/x/f"], capture_output=True, text=True)
        self.assertEqual(out.stdout, "hi\n")

    def test_format(self):
        blank = os.path.join(ROOT, "build", "t_blank9.d64")
        with open(blank, "wb") as f:
            f.write(bytes(174848))
        with Vice(IMAGE, extra=["-drive9type", "1541", "-9", blank]) as v:
            v.wait_shell()
            self.assertIn("no such device", v.run("mount 9 /mnt"))
            self.assertIn("only drives 9, 10 and 11", v.run("format 8").replace("\n", " "))
            v.type("clear\nformat 9 c64fs mydisk\n")
            v.wait_for("(y/n)")
            v.type("y\n")
            v.wait_for("done", timeout=400)
            v.run("mount 9 /mnt")
            v.run("mkdir /mnt/src")
            v.run("echo hello > /mnt/src/f")
            self.assertEqual(v.run("cat /mnt/src/f"), "hello")
            v.run("umount /mnt")
            v.type("clear\nformat 9 cbm plain\n")
            v.wait_for("(y/n)")
            v.type("y\n")
            v.wait_for("done", timeout=400)
            v.run("mount 9 /mnt")
            self.assertIn("(cbm dos)", v.run("mount"))
            v.run("echo hi > /mnt/note")
            v.run("umount /mnt")
        d = c1541_dir(blank)
        self.assertIn('"plain', d)
        self.assertIn('"note"', d)


if __name__ == "__main__":
    unittest.main()
