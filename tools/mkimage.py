#!/usr/bin/env python3
"""Build and inspect c64os hybrid disk images.

A c64os disk is a normal 35-track .d64 whose CBM DOS directory holds a
single boot file (the kernel), and whose remaining blocks hold a c64fs
filesystem. Every block is marked allocated in the CBM BAM so the drive's
own DOS never writes over c64fs.

Usage:
  mkimage.py build OUT.d64 --boot BOOT.prg --root DIR [--dev NAME:MAJOR ...]
  mkimage.py ls IMG PATH
  mkimage.py cat IMG PATH
"""
import argparse
import os
import sys

# ---- d64 geometry -------------------------------------------------------

NBLOCKS = 683
D64_SIZE = NBLOCKS * 256


def sectors_per_track(t):
    if t <= 17:
        return 21
    if t <= 24:
        return 19
    if t <= 30:
        return 18
    return 17


TRACK_START = {}
_b = 0
for _t in range(1, 36):
    TRACK_START[_t] = _b
    _b += sectors_per_track(_t)


def ts_to_block(t, s):
    return TRACK_START[t] + s


def block_to_ts(b):
    for t in range(35, 0, -1):
        if b >= TRACK_START[t]:
            return t, b - TRACK_START[t]
    raise ValueError(b)


DIR_TRACK = 18

# ---- c64fs layout -------------------------------------------------------

MAGIC = b"C64FS"
VERSION = 1
SUPER_BLOCK = ts_to_block(19, 0)     # 376
BITMAP_BLOCK = SUPER_BLOCK + 1       # 377
INODE_START = SUPER_BLOCK + 2        # 378
INODE_BLOCKS = 16
NINODES = INODE_BLOCKS * 8           # 128, inode 0 unused
ROOT_INO = 1
INODE_SIZE = 32
NDIRECT = 12
DIRENT_SIZE = 16
NAME_MAX = 14

T_FREE, T_FILE, T_DIR, T_CHR = 0, 1, 2, 3


class Image:
    def __init__(self, data=None):
        self.data = bytearray(data) if data is not None else bytearray(D64_SIZE)
        assert len(self.data) == D64_SIZE

    # raw blocks
    def block(self, b):
        return self.data[b * 256:(b + 1) * 256]

    def put_block(self, b, buf):
        assert len(buf) == 256
        self.data[b * 256:(b + 1) * 256] = buf

    # ---- CBM side ----
    def write_cbm(self, boot_name, boot_data, disk_name=b"C64OS", disk_id=b"OS"):
        used = set(range(TRACK_START[18], TRACK_START[19]))
        # boot file: sequential sectors from track 1
        chunks = [boot_data[i:i + 254] for i in range(0, len(boot_data), 254)] or [b""]
        blocks = list(range(len(chunks)))
        if blocks[-1] >= TRACK_START[18]:
            raise SystemExit("boot file too large")
        for i, (blk, chunk) in enumerate(zip(blocks, chunks)):
            buf = bytearray(256)
            if i + 1 < len(blocks):
                buf[0], buf[1] = block_to_ts(blocks[i + 1])
            else:
                buf[0], buf[1] = 0, len(chunk) + 1
            buf[2:2 + len(chunk)] = chunk
            self.put_block(blk, buf)
            used.add(blk)
        # BAM: every block allocated (c64fs owns the rest of the disk)
        bam = bytearray(256)
        bam[0], bam[1], bam[2] = 18, 1, 0x41
        for t in range(1, 36):
            bam[4 * t:4 * t + 4] = b"\x00\x00\x00\x00"
        name = disk_name.upper()[:16].ljust(16, b"\xa0")
        bam[0x90:0xa0] = name
        bam[0xa0:0xa2] = b"\xa0\xa0"
        bam[0xa2:0xa4] = disk_id[:2]
        bam[0xa4] = 0xa0
        bam[0xa5:0xa7] = b"2A"
        bam[0xa7:0xab] = b"\xa0" * 4
        self.put_block(ts_to_block(18, 0), bam)
        d = bytearray(256)
        d[0], d[1] = 0, 0xff
        d[2] = 0x82  # PRG, closed
        d[3], d[4] = block_to_ts(blocks[0])
        d[5:21] = boot_name.upper()[:16].ljust(16, b"\xa0")
        d[30] = len(blocks) & 0xff
        d[31] = len(blocks) >> 8
        self.put_block(ts_to_block(18, 1), d)
        return used

    def cbm_files(self):
        out = []
        t, s = 18, 1
        while t:
            d = self.block(ts_to_block(t, s))
            for e in range(8):
                ent = d[e * 32:(e + 1) * 32]
                if ent[2] & 0x07:
                    out.append((bytes(ent[5:21]).rstrip(b"\xa0"), ent[2]))
            t, s = d[0], d[1]
        return out

    def cbm_read(self, name):
        t, s = 18, 1
        while t:
            d = self.block(ts_to_block(t, s))
            for e in range(8):
                ent = d[e * 32:(e + 1) * 32]
                if ent[2] & 0x07 and bytes(ent[5:21]).rstrip(b"\xa0") == name:
                    out = bytearray()
                    ft, fs = ent[3], ent[4]
                    while ft:
                        blk = self.block(ts_to_block(ft, fs))
                        if blk[0]:
                            out += blk[2:]
                        else:
                            out += blk[2:blk[1] + 1]
                        ft, fs = blk[0], blk[1]
                    return bytes(out)
            t, s = d[0], d[1]
        raise FileNotFoundError(name)


class FS:
    """c64fs on top of an Image."""

    def __init__(self, img):
        self.img = img

    # ---- format ----
    def format(self, reserved):
        sb = bytearray(256)
        sb[0:5] = MAGIC
        sb[5] = VERSION
        sb[6], sb[7] = NBLOCKS & 0xff, NBLOCKS >> 8
        sb[8] = NINODES
        sb[9], sb[10] = BITMAP_BLOCK & 0xff, BITMAP_BLOCK >> 8
        sb[11], sb[12] = INODE_START & 0xff, INODE_START >> 8
        sb[13] = INODE_BLOCKS
        sb[14] = ROOT_INO
        self.img.put_block(SUPER_BLOCK, sb)
        self.img.put_block(BITMAP_BLOCK, bytearray(256))
        for i in range(INODE_BLOCKS):
            self.img.put_block(INODE_START + i, bytearray(256))
        for b in set(reserved) | set(range(SUPER_BLOCK, INODE_START + INODE_BLOCKS)):
            self.set_used(b, True)
        for b in range(NBLOCKS, 2048):   # bitmap bits past the end of the disk
            self.set_used(b, True)
        # inode 0 is never allocated
        ino0 = self.read_inode(0)
        ino0["type"] = 0xff
        self.write_inode(0, ino0)
        root = self.alloc_inode(T_DIR)
        assert root == ROOT_INO
        self.dir_add(root, b".", root)
        self.dir_add(root, b"..", root)
        r = self.read_inode(root)
        r["nlink"] = 2
        self.write_inode(root, r)

    # ---- bitmap ----
    def is_used(self, b):
        bm = self.img.block(BITMAP_BLOCK)
        return bool(bm[b >> 3] & (1 << (b & 7)))

    def set_used(self, b, used):
        bm = self.img.block(BITMAP_BLOCK)
        if used:
            bm[b >> 3] |= 1 << (b & 7)
        else:
            bm[b >> 3] &= ~(1 << (b & 7)) & 0xff
        self.img.put_block(BITMAP_BLOCK, bm)

    def alloc_block(self):
        for b in range(NBLOCKS):
            if not self.is_used(b):
                self.set_used(b, True)
                self.img.put_block(b, bytearray(256))
                return b
        raise OSError("ENOSPC")

    def free_blocks(self):
        return sum(1 for b in range(2048) if not self.is_used(b))

    # ---- inodes ----
    def read_inode(self, n):
        blk = self.img.block(INODE_START + n // 8)
        r = blk[(n % 8) * 32:(n % 8) * 32 + 32]
        return {
            "type": r[0], "nlink": r[1],
            "size": r[2] | r[3] << 8 | r[4] << 16, "major": r[5],
            "direct": [r[6 + 2 * i] | r[7 + 2 * i] << 8 for i in range(NDIRECT)],
            "indirect": r[30] | r[31] << 8,
        }

    def write_inode(self, n, ino):
        r = bytearray(32)
        r[0], r[1] = ino["type"], ino["nlink"]
        r[2], r[3], r[4] = ino["size"] & 0xff, ino["size"] >> 8 & 0xff, ino["size"] >> 16
        r[5] = ino["major"]
        for i, b in enumerate(ino["direct"]):
            r[6 + 2 * i], r[7 + 2 * i] = b & 0xff, b >> 8
        r[30], r[31] = ino["indirect"] & 0xff, ino["indirect"] >> 8
        blk = self.img.block(INODE_START + n // 8)
        blk[(n % 8) * 32:(n % 8) * 32 + 32] = r
        self.img.put_block(INODE_START + n // 8, blk)

    def alloc_inode(self, typ, major=0):
        for n in range(1, NINODES):
            if self.read_inode(n)["type"] == T_FREE:
                self.write_inode(n, {"type": typ, "nlink": 1, "size": 0,
                                     "major": major, "direct": [0] * NDIRECT,
                                     "indirect": 0})
                return n
        raise OSError("no inodes")

    def bmap(self, ino, i, alloc=False):
        """Block number of file block i (0 if a hole and not allocating)."""
        if i < NDIRECT:
            if not ino["direct"][i] and alloc:
                ino["direct"][i] = self.alloc_block()
            return ino["direct"][i]
        i -= NDIRECT
        if i >= 128:
            raise OSError("EFBIG")
        if not ino["indirect"]:
            if not alloc:
                return 0
            ino["indirect"] = self.alloc_block()
        ind = self.img.block(ino["indirect"])
        b = ind[2 * i] | ind[2 * i + 1] << 8
        if not b and alloc:
            b = self.alloc_block()
            ind[2 * i], ind[2 * i + 1] = b & 0xff, b >> 8
            self.img.put_block(ino["indirect"], ind)
        return b

    def read_file(self, n):
        ino = self.read_inode(n)
        out = bytearray()
        for i in range((ino["size"] + 255) // 256):
            b = self.bmap(ino, i)
            out += self.img.block(b) if b else bytes(256)
        return bytes(out[:ino["size"]])

    def write_file(self, n, data):
        ino = self.read_inode(n)
        for i in range(0, len(data), 256):
            b = self.bmap(ino, i // 256, alloc=True)
            self.img.put_block(b, bytearray(data[i:i + 256].ljust(256, b"\0")))
        ino["size"] = len(data)
        self.write_inode(n, ino)

    # ---- directories ----
    def dir_entries(self, n):
        data = self.read_file(n)
        for off in range(0, len(data), DIRENT_SIZE):
            e = data[off:off + DIRENT_SIZE]
            if e[0]:
                yield e[1:].split(b"\0")[0], e[0]

    def dir_add(self, d, name, child):
        if len(name) > NAME_MAX:
            raise OSError("ENAMETOOLONG")
        data = bytearray(self.read_file(d))
        ent = bytes([child]) + name.ljust(15, b"\0")
        for off in range(0, len(data), DIRENT_SIZE):
            if data[off] == 0:
                data[off:off + DIRENT_SIZE] = ent
                break
        else:
            data += ent
        self.write_file(d, bytes(data))

    def lookup(self, path):
        n = ROOT_INO
        for part in [p for p in path.encode().split(b"/") if p]:
            for name, ino in self.dir_entries(n):
                if name == part:
                    n = ino
                    break
            else:
                raise FileNotFoundError(path)
        return n

    def mkdir(self, parent, name):
        n = self.alloc_inode(T_DIR)
        self.dir_add(n, b".", n)
        self.dir_add(n, b"..", parent)
        ino = self.read_inode(n)
        ino["nlink"] = 2
        self.write_inode(n, ino)
        self.dir_add(parent, name, n)
        p = self.read_inode(parent)
        p["nlink"] += 1
        self.write_inode(parent, p)
        return n

    def create(self, parent, name, data, typ=T_FILE, major=0):
        n = self.alloc_inode(typ, major)
        if data:
            self.write_file(n, data)
        self.dir_add(parent, name, n)
        return n

    def add_tree(self, host_dir, ino):
        for entry in sorted(os.listdir(host_dir)):
            if entry.startswith("."):
                continue
            p = os.path.join(host_dir, entry)
            name = entry.encode()
            if os.path.isdir(p):
                self.add_tree(p, self.mkdir(ino, name))
            else:
                with open(p, "rb") as f:
                    self.create(ino, name, f.read())


def build(out, boot, root, devs):
    img = Image()
    with open(boot, "rb") as f:
        boot_data = f.read()
    reserved = img.write_cbm(b"C64OS", boot_data)
    fs = FS(img)
    fs.format(reserved)
    fs.add_tree(root, ROOT_INO)
    if devs:
        try:
            dev = fs.lookup("/dev")
        except FileNotFoundError:
            dev = fs.mkdir(ROOT_INO, b"dev")
        for spec in devs:
            name, major = spec.split(":")
            fs.create(dev, name.encode(), b"", T_CHR, int(major))
    with open(out, "wb") as f:
        f.write(img.data)
    return img


def load(path):
    with open(path, "rb") as f:
        return Image(f.read())


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("out")
    b.add_argument("--boot", required=True)
    b.add_argument("--root", required=True)
    b.add_argument("--dev", action="append", default=[])
    l = sub.add_parser("ls")
    l.add_argument("img")
    l.add_argument("path", nargs="?", default="/")
    c = sub.add_parser("cat")
    c.add_argument("img")
    c.add_argument("path")
    a = ap.parse_args(argv)
    if a.cmd == "build":
        img = build(a.out, a.boot, a.root, a.dev)
        print(f"{a.out}: {FS(img).free_blocks()} blocks free")
    elif a.cmd == "ls":
        fs = FS(load(a.img))
        for name, ino in fs.dir_entries(fs.lookup(a.path)):
            i = fs.read_inode(ino)
            t = {T_FILE: "-", T_DIR: "d", T_CHR: "c"}.get(i["type"], "?")
            print(f"{t} {ino:3} {i['size']:6} {name.decode()}")
    elif a.cmd == "cat":
        fs = FS(load(a.img))
        sys.stdout.buffer.write(fs.read_file(fs.lookup(a.path)))


if __name__ == "__main__":
    main()
