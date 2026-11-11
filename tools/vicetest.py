#!/usr/bin/env python3
"""Drive VICE (x64sc) through its remote monitor for automated tests.

    with Vice("build/breadbin.d64") as v:
        v.wait_for("/ $ ")
        v.type("ls\\n")
        print(v.screen())
"""
import atexit
import os
import re
import socket
import subprocess
import tempfile
import time

X64 = os.environ.get("X64SC", "x64sc")


def scratch_file(path):
    """Delete this run's scratch file (a disk image copy) when the test
    process exits. BB_KEEP=1 keeps them, to look at after a failure."""
    if not os.environ.get("BB_KEEP"):
        atexit.register(lambda: os.path.exists(path) and os.remove(path))
    return path


def screen_to_text(codes):
    out = []
    for c in codes:
        c &= 0x7f
        if c == 0:
            out.append("@")
        elif 1 <= c <= 26:
            out.append(chr(ord("a") + c - 1))
        elif c == 27:
            out.append("[")
        elif c == 28:
            out.append("\\")
        elif c == 29:
            out.append("]")
        elif c == 30:
            out.append("^")
        elif c == 31:
            out.append("<")
        elif 32 <= c <= 63:
            out.append(chr(c))
        elif 65 <= c <= 90:
            out.append(chr(c))
        elif c == 0x5d:
            out.append("|")
        elif c == 0x64:
            out.append("_")
        else:
            out.append("?")
    return "".join(out)


PROMPT = re.compile(r"^\S+ \$$")


def command_output(lines, command):
    """The output of `command` on a screen (40-column rows, right-stripped):
    the rows between the last row the command line ends on and the next
    prompt, or None while that prompt hasn't appeared. A command line longer
    than a row wraps onto the next ones, so rows are joined, padded back to
    40 columns, before matching."""
    want = "$ " + command.strip()
    for end in range(len(lines) - 1, -1, -1):
        for n in range(1, len(want) // 40 + 3):
            start = end - n + 1
            if start < 0:
                break
            text = "".join(l.ljust(40) for l in lines[start:end]) + lines[end]
            if text.endswith(want):
                for j in range(end + 1, len(lines)):
                    if PROMPT.match(lines[j]):
                        return lines[end + 1:j]
                return None
    return None


def free_port():
    """A TCP port nothing listens on now. (A port made from the pid could
    collide: two suites side by side, 9 VICE, and a test drove another's.)"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Vice:
    def __init__(self, image, reu=False, port=None, warp=True, extra=()):
        self.image = image
        self.port = port or free_port()
        args = [X64, "-default", "+sound", "-minimized",
                "-remotemonitor", "-remotemonitoraddress", f"ip4://127.0.0.1:{self.port}"]
        if not os.environ.get("BB_WINDOW"):   # BB_WINDOW=1: show VICE's window
            args.append("-console")
        if warp:
            args.append("-warp")
        if reu:
            args += ["-reu", "-reusize", "512"]
        roms = os.environ.get("OPENROMS")   # directory with the MEGA65 Open ROMs
        if roms:
            args += ["-kernal", os.path.join(roms, "kernal_generic.rom"),
                     "-basic", os.path.join(roms, "basic_generic.rom"),
                     "-chargen", os.path.join(roms, "chargen_openroms.rom")]
        args += list(extra)
        args += os.environ.get("VICEFLAGS", "").split()   # e.g. -ntsc
        args += ["-autostart", image]
        self.log = tempfile.NamedTemporaryFile(prefix="vice", suffix=".log", delete=False)
        self.proc = subprocess.Popen(args, stdout=self.log, stderr=subprocess.STDOUT)
        # a setUpClass that fails skips tearDownClass: don't leave VICE running
        atexit.register(self._reap)
        self.sock = None
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=2)
                break
            except OSError:
                time.sleep(0.3)
        if not self.sock:
            self._reap()
            raise RuntimeError("could not connect to VICE monitor")
        self._cmd("x")

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

    def close(self):
        try:
            self.sock.sendall(b"quit\n")
            time.sleep(0.3)
            self.sock.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def _reap(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()

    def _cmd(self, c, wait=0.15):
        self.sock.sendall((c + "\n").encode())
        time.sleep(wait)
        self.sock.settimeout(0.4)
        out = b""
        try:
            while True:
                d = self.sock.recv(65536)
                if not d:
                    break
                out += d
        except socket.timeout:
            pass
        return out.decode(errors="replace")

    def mem(self, start, end):
        """Read memory through the monitor's save command (retries while
        VICE is still starting up)."""
        for attempt in range(5):
            fd, path = tempfile.mkstemp(suffix=".bin")
            os.close(fd)
            os.unlink(path)
            self._cmd(f'save "{path}" 0 {start:04x} {end:04x}', wait=0.2)
            self._cmd("x")
            for _ in range(50):
                if os.path.exists(path) and os.path.getsize(path) >= end - start + 3:
                    break
                time.sleep(0.05)
            if os.path.exists(path):
                with open(path, "rb") as f:
                    data = f.read()[2:]
                os.unlink(path)
                return list(data[:end - start + 1])
            time.sleep(1)
        raise RuntimeError("VICE monitor did not save memory")

    def screen_lines(self):
        codes = self.mem(0x0400, 0x07e7)
        text = screen_to_text(codes)
        return [text[i:i + 40].rstrip() for i in range(0, len(text), 40)]

    def screen(self):
        return "\n".join(self.screen_lines())

    def type(self, text):
        """Type text; '\\n' is RETURN, '|' is sent as SHIFT+'-' (PETSCII $dd).
        Fed in small pieces so the 10-key KERNAL buffer never overflows."""
        for chunk in re.findall(r"[^\n]{1,8}|\n", text):
            if chunk == "\n":
                esc = "\\x0d"
            else:
                esc = chunk.replace("\\", "\\\\").replace("|", "\\xdd").replace(" ", "\\x20")
            self._cmd("keybuf " + esc)
            self._cmd("x", wait=0.25)

    def wait_shell(self, user="root", timeout=90):
        """Boot to a shell prompt, logging in as `user` if asked."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            s = self.screen()
            if "login:" in s:
                self.type(user + "\n")
                return self.wait_for(" $", timeout=timeout)
            if s.rstrip().endswith("/ $"):
                return s
            time.sleep(0.5)
        self._on_timeout()
        raise TimeoutError("no login or shell prompt:\n" + self.screen())

    def wait_for(self, text, timeout=60, after=None):
        """Wait until `text` is on screen; return the screen."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            s = self.screen()
            if text in s if after is None else text in s.split(after)[-1]:
                return s
            time.sleep(0.5)
        self._on_timeout()
        raise TimeoutError(f"{text!r} not on screen:\n{self.screen()}")

    PROMPT = PROMPT

    def run(self, command, timeout=90, clear=True):
        """Run a command line and return its output (the lines between the
        command and the next prompt). A command line may wrap past 40 columns."""
        if clear:
            self.type("clear\n")
            # job notices ("[5] done") may print above the prompt
            def cleared(ls):
                body = [l for l in ls if l]
                return (bool(body) and self.PROMPT.match(body[-1]) is not None
                        and all(re.match(r"^\[\d+\] done$", l) for l in body[:-1])
                        and not any(ls[ls.index(body[-1]) + 1:]))
            self._wait(cleared, timeout)
        self.type(command + "\n")
        result = []

        def done(lines):
            out = command_output(lines, command)
            if out is None:
                return False
            result[:] = out
            return True
        self._wait(done, timeout, what=command)
        return "\n".join(result)

    def _wait(self, pred, timeout, what="condition"):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if pred(self.screen_lines()):
                return
            time.sleep(0.4)
        self._on_timeout()
        raise TimeoutError(f"timeout waiting for {what}:\n{self.screen()}")

    # Kernel variables worth seeing when the system hangs (all in build/kernel.lbl).
    DUMP_VARS = ["rq_dev", "rq_lo", "rq_hi", "trk", "sct", "cur_drive", "dev_geo",
                 "fl_bad", "fl_up", "cur", "in_kernel", "p_state"]

    def _on_timeout(self):
        """With BB_HANGDUMP=file set, append the C64's registers and recent
        instructions (with the kernel labels they fall in), drives 8 and 9's
        registers, history and command buffer, some kernel variables, and the
        screen after one more RETURN (unchanged: the system is frozen)."""
        path = os.environ.get("BB_HANGDUMP")
        if not path:
            return
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        labels = {}
        with open(os.path.join(root, "build", "kernel.lbl")) as f:
            for line in f:
                _, addr, name = line.split()[:3]
                labels[name.lstrip(".")] = int(addr, 16)
        by_addr = sorted((a, n) for n, a in labels.items())

        def where(addr):
            best = None
            for a, n in by_addr:
                if a > addr:
                    break
                best = "%s+%d" % (n, addr - a)
            return best or ""

        out = ["== HANGDUMP (monitor port %d)" % self.port, self._cmd("r", wait=0.5)]
        for line in self._cmd("chis 60", wait=1.0).splitlines()[-60:]:
            m = re.match(r"\.?C:([0-9a-f]{4})", line.strip(), re.I)
            out.append(line + ("   " + where(int(m.group(1), 16)) if m else ""))
        for d in ("8", "9"):
            out.append("== drive " + d)
            self._cmd("device %s:" % d, wait=0.5)
            out += [self._cmd("r", wait=0.5), self._cmd("chis 40", wait=1.0),
                    self._cmd("m 0200 0230", wait=0.5)]
        self._cmd("device c:", wait=0.5)
        self._cmd("x")
        for n in self.DUMP_VARS:
            if n in labels:
                try:
                    out.append("%s %s" % (n, self.mem(labels[n], labels[n] + 11)))
                except RuntimeError as e:
                    out.append("%s ? %s" % (n, e))
        self.type("\n")
        time.sleep(15)
        out.append("== screen after RETURN\n" + self.screen())
        with open(path, "a") as f:
            f.write("\n".join(out) + "\n")

if __name__ == "__main__":
    import sys
    with Vice(sys.argv[1] if len(sys.argv) > 1 else "build/breadbin.d64") as v:
        time.sleep(float(sys.argv[2]) if len(sys.argv) > 2 else 15)
        print(v.screen())
