#!/usr/bin/env python3
"""Build and inspect Breadbin hybrid disk images.

A Breadbin disk is a normal 35-track .d64 whose CBM DOS directory holds a
single boot file (the kernel), and whose remaining blocks hold a c64fs
filesystem. Every block is marked allocated in the CBM BAM so the drive's
own DOS never writes over c64fs.

Two c64fs formats exist. Format 1 (magic C64FS) has 32-byte inodes and is
what kernels up to 0.4 read. Format 2 (magic C64F2) has 64-byte inodes with
mtime and ctime and a last_time in the superblock; see
docs/design-timestamps-d81.md. Times are seconds since 1970 in local time.

Usage:
  mkimage.py build OUT.d64 --boot BOOT.prg --root DIR [--dev NAME:MAJOR ...]
                           [--format 1|2]
  mkimage.py upgrade IN.d64 OUT.d64 [--boot BOOT.prg]
  mkimage.py ls IMG PATH
  mkimage.py cat IMG PATH

With SOURCE_DATE_EPOCH set, a format 2 build gives every file that time,
so two builds of the same tree are identical.
"""
import argparse
import calendar
import os
import sys
import time

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


class Layout:
    def __init__(self, version, magic, inode_size, inode_blocks):
        self.version = version
        self.magic = magic
        self.inode_size = inode_size
        self.per_block = 256 // inode_size
        self.inode_blocks = inode_blocks
        self.ninodes = inode_blocks * self.per_block


LAYOUTS = {
    1: Layout(1, b"C64FS", 32, 16),   # 128 inodes
    2: Layout(2, b"C64F2", 64, 32),   # 128 inodes, with times
}
DEFAULT_VERSION = 2                   # what the kernel reads

MAGIC = LAYOUTS[DEFAULT_VERSION].magic   # = C64FS_MAGIC in include/breadbin.inc
VERSION = DEFAULT_VERSION
SUPER_BLOCK = ts_to_block(19, 0)     # 376
BITMAP_BLOCK = SUPER_BLOCK + 1       # 377
INODE_START = SUPER_BLOCK + 2        # 378
INODE_BLOCKS = LAYOUTS[DEFAULT_VERSION].inode_blocks
NINODES = LAYOUTS[DEFAULT_VERSION].ninodes   # inode 0 unused
ROOT_INO = 1
INODE_SIZE = LAYOUTS[DEFAULT_VERSION].inode_size
NDIRECT = 12
DIRENT_SIZE = 16
NAME_MAX = 14
SB_LAST_TIME = 15                    # format 2: 4 bytes

T_FREE, T_FILE, T_DIR, T_CHR = 0, 1, 2, 3


def local_epoch(t):
    """Host time t as c64fs stores it: seconds since 1970, local time."""
    return calendar.timegm(time.localtime(t))


def build_time():
    sde = os.environ.get("SOURCE_DATE_EPOCH")
    if sde:
        return int(sde)
    return local_epoch(time.time())


def fmt_time(t):
    """The ls -l form: YY-MM-DD hh:mm."""
    return time.strftime("%y-%m-%d %H:%M", time.gmtime(t))


def le32(v):
    return bytes([v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff])


def get32(b, off):
    return b[off] | b[off + 1] << 8 | b[off + 2] << 16 | b[off + 3] << 24


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
    def write_cbm(self, boot_name, boot_data, disk_name=b"BREADBIN", disk_id=b"BB"):
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

    def cbm_blocks(self):
        """Blocks the CBM side owns: track 18 and every CBM file's sectors."""
        used = set(range(TRACK_START[18], TRACK_START[19]))
        t, s = 18, 1
        while t:
            d = self.block(ts_to_block(t, s))
            for e in range(8):
                ent = d[e * 32:(e + 1) * 32]
                if ent[2] & 0x07:
                    ft, fs = ent[3], ent[4]
                    while ft and len(used) < NBLOCKS:
                        b = ts_to_block(ft, fs)
                        used.add(b)
                        ft, fs = self.block(b)[0], self.block(b)[1]
            t, s = d[0], d[1]
        return used

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
    """c64fs on top of an Image.

    version: the format to write with format(); None reads it from the
    superblock (format 1 if the image has no c64fs yet).
    """

    def __init__(self, img, version=None, now=None):
        self.img = img
        if version is None:
            magic = bytes(img.block(SUPER_BLOCK)[0:5])
            version = next((v for v, lay in LAYOUTS.items() if lay.magic == magic),
                           DEFAULT_VERSION)
        self.lay = LAYOUTS[version]
        self.now = build_time() if now is None else now

    @property
    def version(self):
        return self.lay.version

    # ---- format ----
    def format(self, reserved):
        lay = self.lay
        sb = bytearray(256)
        sb[0:5] = lay.magic
        sb[5] = lay.version
        sb[6], sb[7] = NBLOCKS & 0xff, NBLOCKS >> 8
        sb[8] = lay.ninodes
        sb[9], sb[10] = BITMAP_BLOCK & 0xff, BITMAP_BLOCK >> 8
        sb[11], sb[12] = INODE_START & 0xff, INODE_START >> 8
        sb[13] = lay.inode_blocks
        sb[14] = ROOT_INO
        if lay.version >= 2:
            sb[SB_LAST_TIME:SB_LAST_TIME + 4] = le32(self.now)
        self.img.put_block(SUPER_BLOCK, sb)
        self.img.put_block(BITMAP_BLOCK, bytearray(256))
        for i in range(lay.inode_blocks):
            self.img.put_block(INODE_START + i, bytearray(256))
        for b in set(reserved) | set(range(SUPER_BLOCK, INODE_START + lay.inode_blocks)):
            self.set_used(b, True)
        for b in range(NBLOCKS, 2048):   # bitmap bits past the end of the disk
            self.set_used(b, True)
        # inode 0 is never allocated
        ino0 = self.read_inode(0)
        ino0["type"] = 0xff
        ino0["mtime"] = ino0["ctime"] = 0
        self.write_inode(0, ino0)
        root = self.alloc_inode(T_DIR)
        assert root == ROOT_INO
        self.dir_add(root, b".", root)
        self.dir_add(root, b"..", root)
        r = self.read_inode(root)
        r["nlink"] = 2
        self.write_inode(root, r)

    # ---- superblock times (format 2) ----
    def last_time(self):
        if self.version < 2:
            return None
        return get32(self.img.block(SUPER_BLOCK), SB_LAST_TIME)

    def set_last_time(self, t):
        sb = self.img.block(SUPER_BLOCK)
        sb[SB_LAST_TIME:SB_LAST_TIME + 4] = le32(t)
        self.img.put_block(SUPER_BLOCK, sb)

    def finish(self):
        """Format 2: last_time = the build time or the newest inode time."""
        if self.version < 2:
            return
        newest = self.now
        for n in range(1, self.lay.ninodes):
            i = self.read_inode(n)
            if i["type"] != T_FREE:
                newest = max(newest, i["mtime"], i["ctime"])
        self.set_last_time(newest)

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
    def _inode_at(self, n):
        per = self.lay.per_block
        return INODE_START + n // per, (n % per) * self.lay.inode_size

    def read_inode(self, n):
        b, off = self._inode_at(n)
        r = self.img.block(b)[off:off + self.lay.inode_size]
        ino = {
            "type": r[0], "nlink": r[1],
            "size": r[2] | r[3] << 8 | r[4] << 16, "major": r[5],
            "direct": [r[6 + 2 * i] | r[7 + 2 * i] << 8 for i in range(NDIRECT)],
            "indirect": r[30] | r[31] << 8,
            "mtime": 0, "ctime": 0,
        }
        if self.version >= 2:
            ino["mtime"], ino["ctime"] = get32(r, 32), get32(r, 36)
        return ino

    def write_inode(self, n, ino):
        r = bytearray(self.lay.inode_size)
        r[0], r[1] = ino["type"], ino["nlink"]
        r[2], r[3], r[4] = ino["size"] & 0xff, ino["size"] >> 8 & 0xff, ino["size"] >> 16
        r[5] = ino["major"]
        for i, b in enumerate(ino["direct"]):
            r[6 + 2 * i], r[7 + 2 * i] = b & 0xff, b >> 8
        r[30], r[31] = ino["indirect"] & 0xff, ino["indirect"] >> 8
        if self.version >= 2:
            r[32:36] = le32(ino.get("mtime", 0))
            r[36:40] = le32(ino.get("ctime", 0))
        b, off = self._inode_at(n)
        blk = self.img.block(b)
        blk[off:off + self.lay.inode_size] = r
        self.img.put_block(b, blk)

    def set_times(self, n, t):
        ino = self.read_inode(n)
        ino["mtime"] = ino["ctime"] = t
        self.write_inode(n, ino)

    def alloc_inode(self, typ, major=0):
        for n in range(1, self.lay.ninodes):
            if self.read_inode(n)["type"] == T_FREE:
                self.write_inode(n, {"type": typ, "nlink": 1, "size": 0,
                                     "major": major, "direct": [0] * NDIRECT,
                                     "indirect": 0,
                                     "mtime": self.now, "ctime": self.now})
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

    def host_time(self, path):
        """A host file's time for its inode (SOURCE_DATE_EPOCH wins)."""
        if os.environ.get("SOURCE_DATE_EPOCH"):
            return self.now
        return local_epoch(os.stat(path).st_mtime)

    def add_tree(self, host_dir, ino):
        for entry in sorted(os.listdir(host_dir)):
            if entry.startswith("."):
                continue
            p = os.path.join(host_dir, entry)
            name = entry.encode()
            if os.path.isdir(p):
                d = self.mkdir(ino, name)
                self.add_tree(p, d)
                self.set_times(d, self.host_time(p))
            else:
                with open(p, "rb") as f:
                    n = self.create(ino, name, f.read())
                self.set_times(n, self.host_time(p))

    def copy_tree(self, src, src_dir, dst_dir):
        """Copy a directory tree from another FS; times become self.now."""
        for name, n in src.dir_entries(src_dir):
            if name in (b".", b".."):
                continue
            i = src.read_inode(n)
            if i["type"] == T_DIR:
                self.copy_tree(src, n, self.mkdir(dst_dir, name))
            elif i["type"] == T_CHR:
                self.create(dst_dir, name, b"", T_CHR, i["major"])
            else:
                self.create(dst_dir, name, src.read_file(n))


def build(out, boot, root, devs, version=DEFAULT_VERSION):
    img = Image()
    with open(boot, "rb") as f:
        boot_data = f.read()
    reserved = img.write_cbm(b"BREADBIN", boot_data)
    fs = FS(img, version)
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
    fs.finish()
    with open(out, "wb") as f:
        f.write(img.data)
    return img


def upgrade(src_path, out, boot=None):
    """Rewrite a format 1 image as format 2. Contents are kept; every time
    is the time of the conversion. The CBM side (the boot file) is copied
    as it is, unless boot gives a new kernel."""
    old_img = load(src_path)
    old = FS(old_img)
    if bytes(old_img.block(SUPER_BLOCK)[0:5]) != LAYOUTS[1].magic:
        raise SystemExit(f"{src_path}: not a format 1 c64fs image")
    img = Image()
    if boot:
        with open(boot, "rb") as f:
            reserved = img.write_cbm(b"BREADBIN", f.read())
    else:
        reserved = old_img.cbm_blocks()
        for b in reserved:
            img.put_block(b, old_img.block(b))
    fs = FS(img, 2)
    fs.format(reserved)
    try:
        fs.copy_tree(old, ROOT_INO, ROOT_INO)
    except OSError as e:
        raise SystemExit(f"{src_path}: does not fit in format 2 ({e})")
    fs.finish()
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
    b.add_argument("--format", type=int, choices=sorted(LAYOUTS), default=DEFAULT_VERSION)
    u = sub.add_parser("upgrade")
    u.add_argument("src")
    u.add_argument("out")
    u.add_argument("--boot")
    l = sub.add_parser("ls")
    l.add_argument("img")
    l.add_argument("path", nargs="?", default="/")
    c = sub.add_parser("cat")
    c.add_argument("img")
    c.add_argument("path")
    a = ap.parse_args(argv)
    if a.cmd == "build":
        img = build(a.out, a.boot, a.root, a.dev, a.format)
        print(f"{a.out}: {FS(img).free_blocks()} blocks free")
    elif a.cmd == "upgrade":
        img = upgrade(a.src, a.out, a.boot)
        print(f"{a.out}: format 2, {FS(img).free_blocks()} blocks free")
        if not a.boot and img.cbm_files():
            print("note: the boot file was copied as it is; "
                  "it must be a kernel that reads format 2", file=sys.stderr)
    elif a.cmd == "ls":
        fs = FS(load(a.img))
        for name, ino in fs.dir_entries(fs.lookup(a.path)):
            i = fs.read_inode(ino)
            t = {T_FILE: "-", T_DIR: "d", T_CHR: "c"}.get(i["type"], "?")
            when = f" {fmt_time(i['mtime'])}" if fs.version >= 2 else ""
            print(f"{t} {ino:3} {i['size']:6}{when} {name.decode()}")
    elif a.cmd == "cat":
        fs = FS(load(a.img))
        sys.stdout.buffer.write(fs.read_file(fs.lookup(a.path)))


if __name__ == "__main__":
    main()
