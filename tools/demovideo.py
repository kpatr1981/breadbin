#!/usr/bin/env python3
"""Breadbin's YouTube demo: a typed shell session recorded in VICE, 1920 x 1080, 25 fps.

    python3 tools/demovideo.py OPENROMS_DIR build/breadbin.prg build/breadbin.d64 OUT_DIR

Breadbin boots the way the browser demo does (MEGA65 Open ROMs, no drive, the disk preloaded
in the REU), so the video holds no Commodore ROM: the cards use the Open ROMs character set.
VICE stops at every kernel tick; a screenshot is kept each time the cycle counter passes the
next 25 fps frame, and the session is typed into the keyboard buffer at a human pace.

Out: OUT_DIR/breadbin-demo.mp4 (intro card, the session at 3x, end card) and
OUT_DIR/breadbin-demo-thumb.png (1280 x 720).
"""
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vicetest import screen_to_text      # noqa: E402

PAL_CLOCK = 985248
FPS = 25
FRAME = PAL_CLOCK // FPS                 # cycles per video frame
TYPE_EVERY = 3                           # video frames per typed key
HOLD = 30                                # video frames to linger on each result
W, H = 1920, 1080
GW, GH = 1152, 816                       # VICE's 384 x 272 screenshot at 3x
INTRO, OUTRO = 3, 5                      # seconds
PROMPT = re.compile(r"^\S+ \$$")
PALETTE = {"yellow": (0xed, 0xf1, 0x71), "grey": (0xa9, 0xa9, 0xa9)}

SESSION = [
    "ls /bin",
    "cat /home/readme | grep unix | wc",
    "count > /dev/null &",
    "ps",
    "mkdir /home/src ; cd /home/src",
    "echo hello from a c64 > f ; ls -l ; cat f",
    "basic /home/hello.bas",
    "df ; free",
    "theme c64",
    "uname -a",
]


class Vice:
    """x64sc through its text monitor, reading each reply up to the prompt."""
    PROMPT = re.compile(rb"\(C:\$[0-9a-f]{4}\) $")

    def __init__(self, args):
        self.port = random.randint(20000, 40000)
        self.proc = subprocess.Popen(
            ["x64sc", "-console", "-default", "-sounddev", "dummy", "-remotemonitor",
             "-remotemonitoraddress", f"ip4://127.0.0.1:{self.port}", *args],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(200):
            try:
                self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=60)
                break
            except OSError:
                time.sleep(0.05)
        else:
            self.proc.kill()
            raise SystemExit("demovideo: no VICE monitor")

    def read(self, line=False):
        buf = b""
        while True:
            chunk = self.sock.recv(65536)
            if not chunk:
                return buf.decode(errors="replace")
            buf += chunk
            if self.PROMPT.search(buf) and (not line or b"\n" in buf):
                return buf.decode(errors="replace")

    def cmd(self, line, wait_line=False):
        self.sock.sendall(line.encode() + b"\n")
        return self.read(wait_line)

    def cycles(self):
        return int(re.search(r"Stopwatch:\s*(\d+)", self.cmd("sw", True)).group(1))

    def mem(self, addr, n):
        out, a = [], addr
        for line in self.cmd(f"m {addr:04x} {addr + n - 1:04x}", True).splitlines():
            m = re.match(r">C:([0-9a-f]{4})\s+((?:[0-9a-f]{2}\s+)+)", line)
            if m and int(m.group(1), 16) == a:
                bs = [int(x, 16) for x in m.group(2).split()]
                out += bs
                a += len(bs)
        return out[:n]

    def lines(self):
        text = screen_to_text(self.mem(0x0400, 1000))
        return [text[i:i + 40].rstrip() for i in range(0, 1000, 40)]

    def quit(self):
        try:
            self.sock.sendall(b"quit\n")
            self.sock.close()
        except OSError:
            pass
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def key_escape(ch):
    if ch == "\n":
        return "\\x0d"
    if ch == " ":
        return "\\x20"
    if ch == "|":
        return "\\xdd"
    return ch


def record(openroms, prg, reu, frames_dir):
    """Boot, log in, type SESSION -> the PNG frames."""
    irq = int(next(l.split()[1] for l in (prg.parent / "kernel.lbl").read_text().splitlines()
                   if l.endswith(" .irq")), 16)
    v = Vice(["-kernal", str(openroms / "kernal_generic.rom"), "-basic", str(openroms / "basic_generic.rom"),
              "-chargen", str(openroms / "chargen_openroms.rom"), "-drive8type", "0",
              "-reu", "-reusize", "256", "-reuimage", str(reu), "-autostartprgmode", "1",
              "-autostart", str(prg)])
    script = [("wait", "login:"), ("type", "root\n")]
    for c in SESSION:
        script += [("prompt", None), ("hold", HOLD), ("type", c + "\n")]
    script += [("prompt", None), ("hold", 2 * HOLD)]
    pngs, next_t, step, typed, held, tick = [], None, 0, 0, 0, 0
    try:
        v.cmd(f"break {irq:04x}", True)
        while step < len(script):
            v.cmd("x", True)
            if v.mem(0x01, 1)[0] & 1:            # BASIC ROM still in: not Breadbin's IRQ yet
                continue
            now = v.cycles()
            if next_t is None:
                next_t = now
            if now < next_t:
                continue
            next_t += FRAME
            png = frames_dir / f"f{len(pngs):05d}.png"
            v.cmd(f'screenshot "{png}" 2')
            pngs.append(png)
            tick += 1
            if tick % 50 == 0: print(tick, step, script[step], typed, [l for l in v.lines() if l][-1:], flush=True)
            kind, arg = script[step]
            if kind == "wait" and tick % 5 == 0 and arg in "\n".join(v.lines()):
                step += 1
            elif kind == "prompt" and tick % 5 == 0:
                body = [l for l in v.lines() if l]
                if body and PROMPT.match(body[-1]):
                    step += 1
            elif kind == "hold":
                held += 1
                if held >= arg:
                    held, step = 0, step + 1
            elif kind == "type" and tick % TYPE_EVERY == 0:
                v.cmd("keybuf " + key_escape(arg[typed]))
                typed += 1
                if typed == len(arg):
                    typed, step = 0, step + 1
            if len(pngs) > FPS * 40:
                raise SystemExit(f"demovideo: stuck at {script[step]}:\n" + "\n".join(v.lines()))
    finally:
        v.quit()
    time.sleep(0.5)
    return [p for p in pngs if p.exists()]


def font(chargen):
    return chargen.read_bytes()[:2048]           # the upper case / graphics set


def screen_code(ch):
    if "A" <= ch <= "Z":
        return ord(ch) - 64
    if ch == "@":
        return 0
    return ord(ch) if 32 <= ord(ch) < 64 else 32


def draw_text(img, text, y, colour, glyphs, scale):
    x0 = (img.width - len(text) * 8 * scale) // 2
    for i, ch in enumerate(text.upper()):
        g = glyphs[screen_code(ch) * 8:screen_code(ch) * 8 + 8]
        for row, bits in enumerate(g):
            for col in range(8):
                if bits & (0x80 >> col):
                    for dy in range(scale):
                        for dx in range(scale):
                            img.putpixel((x0 + (i * 8 + col) * scale + dx, y + row * scale + dy), colour)


def card(still, title, lines, glyphs):
    """320 x 180: a dimmed crop of the session, the title (3x) and lines, with a drop shadow."""
    crop = still.crop((32, 45, 352, 225)).point(lambda c: c // 5)
    top = (180 - 24 - 6 - 10 * len(lines)) // 2
    rows = [(title, top, "yellow", 3)] + [
        (l, top + 30 + 10 * i, "yellow" if i == 0 else "grey", 1) for i, l in enumerate(lines)]
    for text, y, colour, k in rows:
        layer = Image.new("RGB", (320, 180))
        draw_text(layer, text, y, (255, 255, 255), glyphs, k)
        mask = layer.convert("L").point(lambda c: 255 if c else 0)
        crop.paste((0, 0, 0), (1, 1), mask)
        crop.paste(PALETTE[colour], (0, 0), mask)
    return crop


def main(argv):
    if len(argv) != 4:
        raise SystemExit(__doc__)
    openroms, prg, d64, out = (Path(a).resolve() for a in argv)
    out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="breadbin-video-"))
    try:
        reu = work / "breadbin.reu"
        image = d64.read_bytes()
        reu.write_bytes(image + bytes(256 * 1024 - len(image)))
        frames = work / "frames"
        frames.mkdir()
        pngs = record(openroms, prg, reu, frames)
        if not pngs:
            raise SystemExit("demovideo: no frames")
        glyphs = font(openroms / "chargen_openroms.rom")
        still = Image.open(pngs[len(pngs) // 4]).convert("RGB")
        title, intro = "BREADBIN", ["A UNIX-LIKE OS FOR THE COMMODORE 64"]
        outro = ["PLAY IT IN YOUR BROWSER", "KPATRONAS.ITCH.IO/BREADBIN", "FREE AND OPEN SOURCE"]
        card(still, title, intro, glyphs).resize((1280, 720), Image.NEAREST).save(out / "breadbin-demo-thumb.png")
        card(still, title, intro, glyphs).resize((W, H), Image.NEAREST).save(work / "intro.png")
        card(still, title, outro, glyphs).resize((W, H), Image.NEAREST).save(work / "outro.png")
        silence = ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
        dur = len(pngs) / FPS
        graph = (f"[1:v]scale={GW}:{GH}:flags=neighbor,pad={W}:{H}:{(W - GW) // 2}:{(H - GH) // 2}:black,"
                 "format=yuv420p,setsar=1[mid];"
                 f"[0:v]format=yuv420p,setsar=1,fade=t=out:st={INTRO - 0.5}:d=0.5[i];"
                 f"[2:v]format=yuv420p,setsar=1,fade=t=in:st=0:d=0.5,fade=t=out:st={OUTRO - 1}:d=1[o];"
                 f"[3:a]atrim=0:{INTRO}[ia];[4:a]atrim=0:{dur:.2f}[ma];[5:a]atrim=0:{OUTRO}[oa];"
                 "[i][ia][mid][ma][o][oa]concat=n=3:v=1:a=1[v][a]")
        mp4 = out / "breadbin-demo.mp4"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error",
                        "-loop", "1", "-framerate", str(FPS), "-t", str(INTRO), "-i", str(work / "intro.png"),
                        "-framerate", str(FPS), "-i", str(frames / "f%05d.png"),
                        "-loop", "1", "-framerate", str(FPS), "-t", str(OUTRO), "-i", str(work / "outro.png"),
                        *silence, *silence, *silence,
                        "-filter_complex", graph, "-map", "[v]", "-map", "[a]",
                        "-c:v", "libx264", "-preset", "slow", "-tune", "animation", "-crf", "22",
                        "-r", str(FPS), "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
                        "-movflags", "+faststart", str(mp4)], check=True)
        print(mp4, f"{INTRO + dur + OUTRO:.0f} s, {mp4.stat().st_size / 1e6:.1f} MB")
    except BaseException:
        print("demovideo: work files kept in", work, file=sys.stderr)
        raise
    else:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main(sys.argv[1:])
