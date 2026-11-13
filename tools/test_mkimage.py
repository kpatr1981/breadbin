import os
import re
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import mkimage as M  # noqa: E402
import cx  # noqa: E402


def make_tree(root):
    os.makedirs(os.path.join(root, "bin"))
    os.makedirs(os.path.join(root, "home"))
    os.makedirs(os.path.join(root, "tmp"))
    with open(os.path.join(root, "home", "readme"), "wb") as f:
        f.write(b"hello unix\n" * 100)   # 1100 bytes, 5 blocks
    with open(os.path.join(root, "bin", "big"), "wb") as f:
        f.write(bytes(range(256)) * 20)  # 5120 bytes, uses indirect block


class TestImage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        make_tree(os.path.join(t, "root"))
        self.boot = bytes(range(256)) * 10 + b"end"
        with open(os.path.join(t, "boot.prg"), "wb") as f:
            f.write(self.boot)
        self.out = os.path.join(t, "x.d64")
        M.build(self.out, os.path.join(t, "boot.prg"), os.path.join(t, "root"),
                ["console:1", "null:0"])
        self.img = M.load(self.out)
        self.fs = M.FS(self.img)

    def tearDown(self):
        self.tmp.cleanup()

    def test_size(self):
        self.assertEqual(os.path.getsize(self.out), 174848)

    def test_cbm_directory_has_boot_file(self):
        self.assertEqual(self.img.cbm_files(), [(b"BREADBIN", 0x82)])
        self.assertEqual(self.img.cbm_read(b"BREADBIN"), self.boot)

    def test_cbm_bam_all_allocated(self):
        bam = self.img.block(M.ts_to_block(18, 0))
        self.assertTrue(all(bam[4 * t] == 0 for t in range(1, 36)))

    def test_superblock(self):
        sb = self.img.block(376)
        self.assertEqual(bytes(sb[0:5]), b"C64F2")
        self.assertEqual(sb[8], 128)
        self.assertEqual(sb[9] | sb[10] << 8, 377)

    def test_root_entries(self):
        names = [n for n, _ in self.fs.dir_entries(M.ROOT_INO)]
        self.assertEqual(names[:2], [b".", b".."])
        self.assertEqual(sorted(names[2:]), [b"bin", b"dev", b"home", b"tmp"])

    def test_dotdot(self):
        home = self.fs.lookup("/home")
        d = dict(self.fs.dir_entries(home))
        self.assertEqual(d[b".."], M.ROOT_INO)
        self.assertEqual(d[b"."], home)

    def test_file_roundtrip(self):
        self.assertEqual(self.fs.read_file(self.fs.lookup("/home/readme")),
                         b"hello unix\n" * 100)
        self.assertEqual(self.fs.read_file(self.fs.lookup("/bin/big")),
                         bytes(range(256)) * 20)
        self.assertNotEqual(self.fs.read_inode(self.fs.lookup("/bin/big"))["indirect"], 0)

    def test_devices(self):
        i = self.fs.read_inode(self.fs.lookup("/dev/console"))
        self.assertEqual((i["type"], i["major"]), (M.T_CHR, 1))

    def test_boot_and_dir_track_not_in_free_space(self):
        for b in range(11):
            self.assertTrue(self.fs.is_used(b))
        for b in range(357, 394):
            self.assertTrue(self.fs.is_used(b))

    def test_bits_past_end_marked_used(self):
        self.assertTrue(all(self.fs.is_used(b) for b in range(683, 2048)))

    def test_name_too_long(self):
        with self.assertRaises(OSError):
            self.fs.create(M.ROOT_INO, b"a" * 15, b"x")

    def test_ts_mapping(self):
        self.assertEqual(M.ts_to_block(18, 0), 357)
        self.assertEqual(M.block_to_ts(682), (35, 16))
        self.assertEqual(M.block_to_ts(376), (19, 0))


class TestFormat2(unittest.TestCase):
    """Format 2: 64-byte inodes with mtime/ctime, magic C64F2, last_time."""

    README_TIME = 1700000000          # 2023-11-14 22:13:20 UTC

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.root = os.path.join(t, "root")
        make_tree(self.root)
        for i in range(10):           # enough inodes to fill three v2 inode blocks
            with open(os.path.join(self.root, "home", f"f{i}"), "wb") as f:
                f.write(bytes([i]) * (100 * i))
        os.utime(os.path.join(self.root, "home", "readme"),
                 (self.README_TIME, self.README_TIME))
        self.bootf = os.path.join(t, "boot.prg")
        with open(self.bootf, "wb") as f:
            f.write(bytes(range(256)) * 10 + b"end")
        self.v1 = os.path.join(t, "v1.d64")
        self.v2 = os.path.join(t, "v2.d64")
        M.build(self.v1, self.bootf, self.root, ["console:1", "null:0"], version=1)
        M.build(self.v2, self.bootf, self.root, ["console:1", "null:0"], version=2)
        self.fs1 = M.FS(M.load(self.v1))
        self.fs2 = M.FS(M.load(self.v2))

    def tearDown(self):
        self.tmp.cleanup()

    def test_default_is_format_2(self):
        self.assertEqual(M.DEFAULT_VERSION, 2)
        self.assertEqual(self.fs1.version, 1)
        self.assertEqual(bytes(self.fs1.img.block(376)[0:6]), b"C64FS\x01")

    def test_superblock(self):
        sb = self.fs2.img.block(376)
        self.assertEqual(bytes(sb[0:5]), b"C64F2")
        self.assertEqual(sb[5], 2)
        self.assertEqual(sb[8], 128)               # inodes
        self.assertEqual(sb[11] | sb[12] << 8, 378)
        self.assertEqual(sb[13], 32)               # inode blocks
        self.assertEqual(self.fs2.version, 2)

    def test_inode_table_costs_16_blocks(self):
        self.assertEqual(self.fs2.free_blocks(), self.fs1.free_blocks() - 16)
        for b in range(376, 410):
            self.assertTrue(self.fs2.is_used(b))

    def test_same_contents_as_format_1(self):
        def walk(fs, d, path=""):
            for name, n in fs.dir_entries(d):
                if name in (b".", b".."):
                    continue
                i = fs.read_inode(n)
                p = path + "/" + name.decode()
                yield p, i["type"], i["major"], fs.read_file(n) if i["type"] == M.T_FILE else b""
                if i["type"] == M.T_DIR:
                    yield from walk(fs, n, p)
        self.assertEqual(list(walk(self.fs1, M.ROOT_INO)), list(walk(self.fs2, M.ROOT_INO)))

    def test_inodes_are_64_bytes_four_per_block(self):
        n = self.fs2.lookup("/home/f9")
        self.assertGreater(n, 8)
        blk = self.fs2.img.block(378 + n // 4)
        raw = blk[(n % 4) * 64:(n % 4) * 64 + 64]
        self.assertEqual(raw[0], M.T_FILE)
        self.assertEqual(raw[2] | raw[3] << 8, 900)
        self.assertEqual(bytes(raw[40:64]), bytes(24))   # reserved stays zero

    def test_file_gets_host_mtime_in_local_time(self):
        i = self.fs2.read_inode(self.fs2.lookup("/home/readme"))
        self.assertEqual(i["mtime"], M.local_epoch(self.README_TIME))
        self.assertEqual(i["ctime"], i["mtime"])

    def test_last_time_is_not_older_than_any_inode(self):
        last = self.fs2.last_time()
        for n in range(1, 128):
            i = self.fs2.read_inode(n)
            if i["type"] != M.T_FREE:
                self.assertLessEqual(i["mtime"], last)
                self.assertLessEqual(i["ctime"], last)

    def test_source_date_epoch_is_reproducible(self):
        old = os.environ.get("SOURCE_DATE_EPOCH")
        os.environ["SOURCE_DATE_EPOCH"] = "1600000000"
        try:
            a = os.path.join(self.tmp.name, "a.d64")
            b = os.path.join(self.tmp.name, "b.d64")
            M.build(a, self.bootf, self.root, [], version=2)
            os.utime(os.path.join(self.root, "home", "f1"))
            M.build(b, self.bootf, self.root, [], version=2)
            with open(a, "rb") as fa, open(b, "rb") as fb:
                self.assertEqual(fa.read(), fb.read())
            fs = M.FS(M.load(a))
            self.assertEqual(fs.read_inode(fs.lookup("/home/readme"))["mtime"], 1600000000)
            self.assertEqual(fs.last_time(), 1600000000)
        finally:
            if old is None:
                del os.environ["SOURCE_DATE_EPOCH"]
            else:
                os.environ["SOURCE_DATE_EPOCH"] = old

    def test_ls_date_form(self):
        self.assertEqual(M.fmt_time(1762039500), "25-11-01 23:25")


class TestD81(unittest.TestCase):
    """A 1581 image: 3200 blocks, CBM side on track 40, superblock at 376."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        root = os.path.join(t, "root")
        make_tree(root)
        self.boot = bytes(range(256)) * 10 + b"end"
        bootf = os.path.join(t, "boot.prg")
        with open(bootf, "wb") as f:
            f.write(self.boot)
        self.out = os.path.join(t, "x.d81")
        M.build(self.out, bootf, root, ["console:1", "null:0"])
        self.img = M.load(self.out)
        self.fs = M.FS(self.img)

    def tearDown(self):
        self.tmp.cleanup()

    def test_size_and_geometry(self):
        self.assertEqual(os.path.getsize(self.out), 819200)
        self.assertIs(self.img.geo, M.D81)
        self.assertEqual(M.D81.block_to_ts(376), (10, 16))
        self.assertEqual(M.D81.ts_to_block(40, 0), 1560)

    def test_cbm_side(self):
        self.assertEqual(self.img.cbm_files(), [(b"BREADBIN", 0x82)])
        self.assertEqual(self.img.cbm_read(b"BREADBIN"), self.boot)
        hdr = self.img.block(1560)
        self.assertEqual((hdr[0], hdr[1], hdr[2]), (40, 3, ord("D")))
        self.assertEqual(bytes(hdr[25:27]), b"3D")

    def test_superblock_and_bitmap(self):
        sb = self.img.block(376)
        self.assertEqual(bytes(sb[0:5]), b"C64F2")
        self.assertEqual(sb[6] | sb[7] << 8, 3200)
        self.assertEqual(sb[9] | sb[10] << 8, 377)      # two bitmap blocks
        self.assertEqual(sb[11] | sb[12] << 8, 379)
        for b in list(range(1560, 1600)) + list(range(376, 411)) + list(range(3200, 4096)):
            self.assertTrue(self.fs.is_used(b), b)

    def test_files_beyond_the_first_bitmap_block(self):
        for i in range(18):                             # 18 x 35 KB: past block 2048
            self.fs.create(M.ROOT_INO, b"big%d" % i, bytes([i]) * 35000)
        n = self.fs.lookup("/big17")
        self.assertEqual(self.fs.read_file(n), bytes([17]) * 35000)
        self.assertGreater(self.fs.read_inode(n)["direct"][0], 2048)


class TestUpgrade(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        root = os.path.join(t, "root")
        make_tree(root)
        self.boot = bytes(range(256)) * 10 + b"end"
        self.bootf = os.path.join(t, "boot.prg")
        with open(self.bootf, "wb") as f:
            f.write(self.boot)
        self.v1 = os.path.join(t, "v1.d64")
        self.up = os.path.join(t, "up.d64")
        M.build(self.v1, self.bootf, root, ["console:1", "null:0"], version=1)
        M.upgrade(self.v1, self.up)
        self.old = M.FS(M.load(self.v1))
        self.new = M.FS(M.load(self.up))

    def tearDown(self):
        self.tmp.cleanup()

    def test_is_format_2(self):
        self.assertEqual(self.new.version, 2)
        self.assertEqual(self.new.free_blocks(), self.old.free_blocks() - 16)

    def test_contents_kept(self):
        for p in ("/home/readme", "/bin/big"):
            self.assertEqual(self.new.read_file(self.new.lookup(p)),
                             self.old.read_file(self.old.lookup(p)))
        i = self.new.read_inode(self.new.lookup("/dev/console"))
        self.assertEqual((i["type"], i["major"]), (M.T_CHR, 1))
        self.assertEqual(self.new.read_inode(self.new.lookup("/home"))["nlink"], 2)

    def test_boot_file_copied(self):
        self.assertEqual(self.new.img.cbm_read(b"BREADBIN"), self.boot)

    def test_times_are_the_conversion_time(self):
        i = self.new.read_inode(self.new.lookup("/home/readme"))
        self.assertEqual(i["mtime"], self.new.last_time())

    def test_new_kernel(self):
        newboot = os.path.join(self.tmp.name, "new.prg")
        with open(newboot, "wb") as f:
            f.write(b"v2 kernel")
        out = os.path.join(self.tmp.name, "up2.d64")
        M.upgrade(self.v1, out, newboot)
        self.assertEqual(M.load(out).cbm_read(b"BREADBIN"), b"v2 kernel")

    def test_refuses_format_2(self):
        with self.assertRaises(SystemExit):
            M.upgrade(self.up, os.path.join(self.tmp.name, "again.d64"))


class TestCX(unittest.TestCase):
    def test_relocs(self):
        a = bytes([0xad, 0x10, 0x00, 0xea, 0x20, 0x00, 0xa0])
        b = bytes([0xad, 0x10, 0x01, 0xea, 0x20, 0x00, 0xa0])
        self.assertEqual(cx.relocs(a, b), [2])

    def test_bad_diff(self):
        with self.assertRaises(ValueError):
            cx.relocs(b"\x01", b"\x05")

    def test_header(self):
        out = cx.make_cx(b"\x00\x10", b"\x00\x11", 300)
        self.assertEqual(out[:3], b"CX\x01")
        self.assertEqual(out[3:9], bytes([2, 0, 44, 1, 1, 0]))
        self.assertEqual(out[-2:], b"\x01\x00")

    def test_bss_label(self):
        self.assertEqual(cx.bss_size("al 000123 .__BSS_SIZE__\n"), 0x123)


class TestMagic(unittest.TestCase):
    def test_mkimage_magic_matches_breadbin_inc(self):
        # the kernel, fsck and format take the magic from breadbin.inc
        inc = os.path.join(os.path.dirname(__file__), "..", "include", "breadbin.inc")
        with open(inc) as f:
            m = re.search(r'^\.define\s+C64FS_MAGIC\s+"([^"]*)"', f.read(), re.M)
        self.assertIsNotNone(m, "C64FS_MAGIC not found in breadbin.inc")
        self.assertEqual(M.MAGIC, m.group(1).encode("ascii"))

    def test_mkimage_version_matches_breadbin_inc(self):
        inc = os.path.join(os.path.dirname(__file__), "..", "include", "breadbin.inc")
        with open(inc) as f:
            m = re.search(r'^C64FS_VERSION\s*=\s*(\d+)', f.read(), re.M)
        self.assertIsNotNone(m, "C64FS_VERSION not found in breadbin.inc")
        self.assertEqual(M.VERSION, int(m.group(1)))


if __name__ == "__main__":
    unittest.main()
