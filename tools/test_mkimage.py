import os
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
        self.assertEqual(self.img.cbm_files(), [(b"C64OS", 0x82)])
        self.assertEqual(self.img.cbm_read(b"C64OS"), self.boot)

    def test_cbm_bam_all_allocated(self):
        bam = self.img.block(M.ts_to_block(18, 0))
        self.assertTrue(all(bam[4 * t] == 0 for t in range(1, 36)))

    def test_superblock(self):
        sb = self.img.block(376)
        self.assertEqual(bytes(sb[0:5]), b"C64FS")
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


if __name__ == "__main__":
    unittest.main()
