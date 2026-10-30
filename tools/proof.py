#!/usr/bin/env python3
"""Unscripted check that Breadbin really computes what it shows.

Random data is generated now, so nothing on the disk could anticipate it.
Each answer is checked against something Breadbin didn't produce: Python,
the host's wc, VICE's own c1541 disk tool, and the C64's RAM read through
the VICE monitor.

Run it after `make`: python3 tools/proof.py   (needs x64sc and c1541)
"""
import os, random, shutil, string, struct, subprocess, sys, tempfile, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from vicetest import Vice  # noqa: E402
work = tempfile.mkdtemp(prefix="proof")
img = os.path.join(work, "boot.d64")
shutil.copy(os.path.join(ROOT, "build", "breadbin.d64"), img)
cbm = os.path.join(work, "drive9.d64")
subprocess.run(["c1541", "-format", "proof,pf", "d64", cbm], capture_output=True, check=True)

lbl = {}
for line in open(os.path.join(ROOT, "build", "kernel.lbl")):
    _, addr, name = line.split()
    lbl[name.lstrip(".")] = int(addr, 16)

rnd = random.SystemRandom()
words = ["".join(rnd.choice(string.ascii_lowercase) for _ in range(rnd.randint(4, 7))) for _ in range(3)]
a, b, c = rnd.randint(10, 150), rnd.randint(10, 200), rnd.randint(0, 999)
ok = True


def check(what, got, want):
    global ok
    good = got == want
    ok &= good
    print(f"{'PASS' if good else 'FAIL'}  {what}\n      breadbin: {got!r}\n      expected: {want!r}")


with Vice(img, extra=["-drive9type", "1541", "-9", cbm]) as v:
    v.wait_shell()
    line = " ".join(words)
    v.run(f"echo {line} > /home/p")
    check("cat a file it just wrote", v.run("cat /home/p"), line)
    host_wc = subprocess.run(["wc"], input=line + "\n", capture_output=True, text=True).stdout.split()
    check("wc (vs the host's wc)", v.run("wc /home/p").split()[:3], host_wc)
    check("grep a random word through a pipe", v.run(f"cat /home/p | grep {words[1]}"), line)
    check("grep -c a word that isn't there", v.run("grep -c qqqq /home/p"), "0")

    v.run(f'echo "1 print {a}*{b}+{c}" > /b.bas')
    check(f"BASIC computes {a}*{b}+{c}", v.run("basic /b.bas").strip(), str(a * b + c))

    # a real process: find it in the kernel's process table in RAM
    pid = int(v.run("count > /dev/null &").strip("[]"))
    ps = v.run("ps")
    n = 12
    state = v.mem(lbl["p_state"], lbl["p_state"] + n - 1)
    pids = v.mem(lbl["p_pid"], lbl["p_pid"] + n - 1)
    pages = v.mem(lbl["p_mpage"], lbl["p_mpage"] + n - 1)
    names = v.mem(lbl["p_name"], lbl["p_name"] + n * 11 - 1)
    table = {}
    for s in range(n):
        if state[s]:
            nm = bytes(names[s * 11:(s + 1) * 11]).split(b"\0")[0].decode()
            table[pids[s]] = (nm, pages[s])
    ps_pids = {int(l.split()[0]): l.split()[-1] for l in ps.splitlines()[1:]}
    ps_pids = {p: nm for p, nm in ps_pids.items() if nm != "ps"}   # ps itself has exited by now
    check("every ps row (other than ps itself) is in the kernel's table in RAM",
          {p: nm for p, nm in ps_pids.items() if p in table and table[p][0] == nm}, ps_pids)
    name, page = table[pid]
    check(f"pid {pid} in the kernel table", name, "count")

    # its code in RAM = /bin/count from the disk, relocated to its page
    cx = open(os.path.join(ROOT, "build", "root", "bin", "count"), "rb").read()
    size, bss, nrel = struct.unpack("<HHH", cx[3:9])
    image = bytearray(cx[9:9 + size])
    for i in range(nrel):
        off = struct.unpack("<H", cx[9 + size + 2 * i:11 + size + 2 * i])[0]
        image[off] = (image[off] + page) & 0xff
    ram = v.mem(page * 256, page * 256 + size - 1)
    check(f"count's code at ${page * 256:04x} = the disk file relocated (+{nrel} fixups)",
          bytes(ram) == bytes(image), True)

    def slot_state():
        state = v.mem(lbl["p_state"], lbl["p_state"] + n - 1)
        pids = v.mem(lbl["p_pid"], lbl["p_pid"] + n - 1)
        return next((state[s] for s in range(n) if state[s] and pids[s] == pid), 0)
    check("before kill, it is sleeping in RAM (state 2)", slot_state(), 2)
    v.run(f"kill {pid}")
    time.sleep(1)
    check("after kill, it is a zombie (state 3) or already reaped (0)", slot_state() in (0, 3), True)
    v.run("echo")                       # the shell reaps finished children at its prompt
    check("after the next prompt, its slot is free", slot_state(), 0)

    # write through drive 9's CBM DOS, read back with VICE's c1541
    v.run("mount 9 /mnt")
    v.run("cp /home/p /mnt/proof")
    v.run("umount /mnt")

out = os.path.join(work, "proof.txt")
subprocess.run(["c1541", cbm, "-read", "proof,s", out], capture_output=True)
check("file copied to drive 9, read by c1541 (not Breadbin code)",
      open(out).read() if os.path.exists(out) else None, line + "\n")
print("\nALL PASS" if ok else "\nSOME CHECKS FAILED")
sys.exit(0 if ok else 1)
