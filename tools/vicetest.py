#!/usr/bin/env python3
"""Drive VICE (x64sc) through its remote monitor for automated tests.

    with Vice("build/c64os.d64") as v:
        v.wait_for("/ $ ")
        v.type("ls\\n")
        print(v.screen())
"""
import os
import re
import socket
import subprocess
import tempfile
import time

X64 = os.environ.get("X64SC", "x64sc")


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


class Vice:
    def __init__(self, image, reu=False, port=None, warp=True, extra=()):
        self.image = image
        self.port = port or (6510 + os.getpid() % 500)
        args = [X64, "-default", "+sound", "-minimized",
                "-remotemonitor", "-remotemonitoraddress", f"ip4://127.0.0.1:{self.port}"]
        if warp:
            args.append("-warp")
        if reu:
            args += ["-reu", "-reusize", "512"]
        args += list(extra)
        args += ["-autostart", image]
        self.log = tempfile.NamedTemporaryFile(prefix="vice", suffix=".log", delete=False)
        self.proc = subprocess.Popen(args, stdout=self.log, stderr=subprocess.STDOUT)
        self.sock = None
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=2)
                break
            except OSError:
                time.sleep(0.3)
        if not self.sock:
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
        fd, path = tempfile.mkstemp(suffix=".bin")
        os.close(fd)
        os.unlink(path)
        self._cmd(f'save "{path}" 0 {start:04x} {end:04x}', wait=0.2)
        self._cmd("x")
        for _ in range(50):
            if os.path.exists(path) and os.path.getsize(path) >= end - start + 3:
                break
            time.sleep(0.05)
        with open(path, "rb") as f:
            data = f.read()[2:]
        os.unlink(path)
        return list(data[:end - start + 1])

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

    def wait_for(self, text, timeout=60, after=None):
        """Wait until `text` is on screen; return the screen."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            s = self.screen()
            if text in s if after is None else text in s.split(after)[-1]:
                return s
            time.sleep(0.5)
        raise TimeoutError(f"{text!r} not on screen:\n{self.screen()}")

    PROMPT = re.compile(r"^\S+ \$$")

    def run(self, command, timeout=90, clear=True):
        """Run a command line and return its output (the lines between the
        command and the next prompt). Commands must fit on one screen line."""
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
        want = "$ " + command.strip()
        result = []

        def done(lines):
            idx = None
            for i in range(len(lines) - 1, -1, -1):
                if lines[i].endswith(want):
                    idx = i
                    break
            if idx is None:
                return False
            for j in range(idx + 1, len(lines)):
                if self.PROMPT.match(lines[j]):
                    result[:] = lines[idx + 1:j]
                    return True
            return False
        self._wait(done, timeout, what=command)
        return "\n".join(result)

    def _wait(self, pred, timeout, what="condition"):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if pred(self.screen_lines()):
                return
            time.sleep(0.4)
        raise TimeoutError(f"timeout waiting for {what}:\n{self.screen()}")


if __name__ == "__main__":
    import sys
    with Vice(sys.argv[1] if len(sys.argv) > 1 else "build/c64os.d64") as v:
        time.sleep(float(sys.argv[2]) if len(sys.argv) > 2 else 15)
        print(v.screen())
