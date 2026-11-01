# Design: file timestamps and .d81 support

Status: draft for discussion, 2026-11-01, revised 2026-11-02 after review in issue #4. Nothing here is implemented yet.

## Summary

Two changes are proposed. Files get real modification and change times, stored as 32-bit Unix epoch seconds in 64-byte inodes. Breadbin also learns to boot from and use 1581 disks (.d81 images, e.g. on an Ultimate).

The two are independent: timestamps live inside the c64fs inode, and .d81 changes where blocks sit on the disk. Both change the disk format, so they should share one format bump (superblock `VERSION` 1 → 2) instead of two.

`touch` (merged 2026-11-01) currently only creates empty files, because inodes have no time fields.

## Timestamps

Each inode gets `mtime` (contents last written) and `ctime` (inode last changed), as unsigned 32-bit seconds since 1970-01-01. That range lasts until 2106. There is no `atime`: it would write an inode back to the floppy on every read.

### Inode layout v2

The inode grows from 32 to 64 bytes. The first 32 bytes stay exactly as today, so every existing field offset in `src/kernel/k.inc` keeps working.

| Bytes | Field | Change |
| --- | --- | --- |
| 0 | type | unchanged |
| 1 | nlink | unchanged |
| 2–4 | size (24-bit) | unchanged |
| 5 | major | unchanged |
| 6–29 | 12 direct block pointers | unchanged |
| 30–31 | indirect block pointer | unchanged |
| 32–35 | mtime (epoch, little-endian) | new |
| 36–39 | ctime (epoch, little-endian) | new |
| 40–63 | reserved, zero | new |

The other option, taking 2 of the 12 direct pointers for one 4-byte time, costs no space. But files over 2.5 KB would need the indirect block 512 bytes sooner, which means slower reads. It also leaves no room for `ctime` or later fields.

### Cost

- **Per file:** none. Data blocks and the 16-byte directory entries are unchanged.
- **Per disk:** the inode table goes from 16 to 32 blocks to keep 128 inodes. That's 16 blocks (4 KB) once; free space on the boot image drops from 402 to 386 blocks. Keeping 16 blocks would cut the limit to 64 inodes, and the boot image already uses 59.
- **`/tmp` RAM disk:** `fs_mkfs_reu` (`src/kernel/fs.s`) formats the REU itself, with 255 inodes in 32 blocks (`RD_INOBLK`). With 64-byte inodes that table goes to 64 blocks (16 KB of REU) to keep 255 inodes, the most the 1-byte inode count allows.
- **Kernel RAM:** the working inode `ci` (`src/kernel/fs.s:37`) grows by 32 bytes, plus a 4-byte clock and the code to stamp inodes. The epoch-to-date conversion (32-bit division) stays out of the kernel. The 0.4 link map leaves 561 bytes free between the end of BSS (`$CCCE`) and the jump table (`$CF00`). That space is already the kernel's, so this work should fit there and leave the program pool alone.

### Kernel changes

- **Inode addressing:** 4 inodes per block instead of 8, so `ino / 8`, `(ino % 8) * 32` becomes `ino / 4`, `(ino % 4) * 64`. Same in `tools/mkimage.py`, `fsck` and `format`.
- **Clock:** a 4-byte epoch counter, advanced once a second next to the uptime count in the IRQ.
- **Stamping:** create sets `mtime` and `ctime`. A write that changes data sets `mtime` and `ctime`. Link, unlink and rename set `ctime` only.
- **New syscall `utime(path)`:** sets `mtime` and `ctime` to now. `touch` uses it on existing files.
- **`SYS_STAT`:** its buffer is 8 bytes today (type, nlink, size, inode, device, major). It grows to 16 to carry `mtime` and `ctime`, so `ls` and `stat` change with it.
- **Superblock:** a `last_time` field, written on `sync` and unmount, read at mount.
- **Magic:** v2 disks get a new magic in place of `C64FS`. Released kernels (`mount_dev` in `fs.s`, and the disk check in `cbm.s`) compare only the 5-byte magic and never read `VERSION`, so a 0.4 kernel would mount a v2 disk as v1 and corrupt it. With a new magic it treats the disk as not c64fs. v2 kernels check both the magic and `VERSION`. The magic is defined twice today (`cbm.s:37`, `fs.s:75`); it becomes one shared definition.
- **RAM disk:** `fs_mkfs_reu` writes the v2 magic, `VERSION` 2 and the 64-block inode table.

### Where the time comes from

The C64 has no date and no battery-backed clock. CIA 1's time-of-day clock (used by `date` today) only holds hours, minutes and seconds, and starts from zero at every power-on. (On DC-powered machines the kernel already drives it from the timer interrupt.) The kernel picks its starting time in this order:

1. **Real-time clock hardware**, if present, e.g. the Ultimate's clock through its command interface. This is a later step, not part of the first version.
2. **`last_time` from the boot disk's superblock.** Time is wrong after a reboot but never goes backwards, so "newer than" stays correct.
3. **`date YYYY-MM-DD hh:mm[:ss]`,** typed by the user, possibly prompted at login when the clock came from step 2.

Times are stored as local time with no time zone, since there is nowhere to configure one.

### Programs

| Program | Change |
| --- | --- |
| `touch` | Existing file: call `utime`. Missing file: create it, as today. |
| `ls -l` | Show `mtime`. Lines must fit 40 columns, so a short form such as `26-11-01 23:25`. |
| `stat` | Show `mtime` and `ctime` in full. |
| `date` | Show and set the full date and time from the epoch counter. |
| `cp` | The copy gets the current time. |
| `mv` | Keeps `mtime`, sets `ctime`. |
| `fsck` | Checks v2 inodes; flags times later than `last_time`. |
| `format` | Writes v2 disks with 64-byte inodes. |
| `src/lib` | A shared epoch ↔ calendar routine, linked into `ls`, `stat` and `date` only. |

### Existing disks

The simplest choice is that a v2 kernel mounts only v2 c64fs disks, and the new magic makes a 0.4 kernel refuse them. `mkimage.py` builds v2 images and gives each file the host file's modification time. A host-side `mkimage.py upgrade` would convert a user's existing v1 .d64 with all times set to the conversion time. CBM DOS disks mounted under `/mnt` have no c64fs inodes; `ls -l` shows no time for them.

## .d81 support

Most of the work is mechanical geometry. The two real pieces are keeping the 1541-only fast loader off a 1581, and the REU disk copy, which is sized for 683 blocks. The IEC driver (`src/kernel/iec.s`) needs no change: it uses the standard serial protocol, which the 1581 speaks. Block numbers are already 16-bit, which covers the 1581's 3,200 blocks.

### 1541 vs 1581

| | 1541 (.d64) | 1581 (.d81) |
| --- | --- | --- |
| Tracks | 35 | 80 |
| Sectors per track | 21 / 19 / 18 / 17 by zone | 40 on every track |
| Blocks | 683 | 3,200 |
| CBM DOS directory | track 18 (BAM 18/0, entries from 18/1) | track 40 (header 40/0, BAM 40/1–2, entries from 40/3) |
| Format byte | `A` | `D` |
| c64fs bitmap | 1 block | 2 blocks (already supported) |

### What changes, by file

| File | 1541 assumption | Change |
| --- | --- | --- |
| `src/kernel/blk.s:90` | `trk_lo`/`trk_hi` track table | Per-device geometry. For a 1581, block = (track − 1) × 40 + sector, computed as ×32 + ×8. |
| `src/kernel/drive.s`, `fast_read` in `blk.s` | Code runs inside the 1541 | Mark the drive as unable to fast-read (`fl_bad`) when a 1581 is detected. Today it would upload the code, time out after 1 s and fall back, possibly leaving the drive hung. |
| `src/kernel/blk.s` REU copy (`dc_have`, `DC_BANKS = 3`) | 683 blocks: 86-byte bitmap, 3 banks | Off for 1581 disks in the first version. Covering 3,200 blocks needs a 400-byte bitmap in kernel RAM and 13 banks. |
| `src/kernel/cbm.s` (lines 44, 215, 657, 775) | Directory and BAM on track 18, format `A` | Track 40 layout and format `D`, for 1581 CBM disks under `/mnt`. |
| `src/kernel/file.s:469` | Directory listing starts at 18/1 | Start at 40/3 on a 1581. |
| `src/bin/format.s` | 683 blocks hard-coded | Size from the drive's geometry. |
| `src/bin/fsck.s` (615–652) | Track 18 reserved (blocks 357–375), checks track 36 | Track 40 reserved, 80 tracks. |
| `tools/mkimage.py`, `tools/test_mkimage.py` | `NBLOCKS = 683`, 1541 track table, `DIR_TRACK = 18` | A `--d81` mode. |

### Disk layout on a .d81

Same idea as the .d64: the CBM DOS directory holds only the boot file (the kernel), every block is marked allocated in the CBM BAM, and c64fs uses the rest. Booting needs no kernel change: the C64's own `LOAD"*",8` finds the boot file in the track 40 directory.

The superblock stays at block 376 on both disk types, followed by the bitmap and the inode table. On the .d64 that is 19/0, right after the directory track. On the .d81 it is 10/16, an ordinary block, since the CBM BAM marks the whole disk allocated anyway. The c64fs bitmap marks track 40 (blocks 1,560–1,599, the CBM directory) as used. Block 376 is hard-coded in `fs_mount` (`fs.s`) and twice in the mount code in `cbm.s`; keeping it means none of that changes, and every disk type has its superblock in the same place. The cost is longer head seeks between the inode table and files near the end of the disk, which matters little next to the 1581's speed.

### Telling the drives apart

The kernel learns the drive type once, when it opens the drive (`iec_open`), and stores it per device. Possible checks: read the drive's ROM version string with `M-R`, or try to read 40/0 and look for format byte `D` (a 1541 answers with an illegal-track error). Which check works reliably on VICE, real drives and the Ultimate is an open question.

### Later

- A fast loader for the 1581. Its burst mode needs the C128's fast serial hardware, so it would be another drive-side program like `drive.s`.
- The REU copy for 1581 disks, with its bitmap kept outside kernel RAM.

## Plan, testing and open questions

Both changes ship under one format version 2. The order below keeps every step testable on its own, and the .d81 work can start in parallel once step 1 is merged.

### Order of work

1. **Format v2:** 64-byte inodes with zeroed time fields, the new magic, `VERSION` 2, the superblock's `last_time`, and the matching changes in `mkimage.py`, `fsck`, `format`, the kernel's inode code and the RAM disk format (`fs_mkfs_reu`). Existing tests must pass unchanged, plus a test that a v1 kernel refuses a v2 disk.
2. **Kernel clock and stamping:** the epoch counter, stamping on create, write and inode change, the `utime` syscall, the larger `SYS_STAT` buffer, and `last_time` saved and restored.
3. **Programs:** the `src/lib` date routine, then `date`, `touch`, `ls -l`, `stat`, `mv`, `cp`.
4. **.d81 geometry:** per-device geometry in `blk.s`, `mkimage.py --d81`, drive detection, fast loader and REU copy off on a 1581.
5. **.d81 tools and CBM disks:** `format` and `fsck` on 1581 disks, and 1581 CBM disks under `/mnt` (`cbm.s`, `file.s`).

### Testing

- **Host:** `tools/test_mkimage.py` for v2 inodes, host times copied into images, and .d81 layout.
- **VICE, timestamps:** `touch` changes `mtime` on an existing file. `ls -l` and `stat` show the expected time after `date` sets it. Time does not go backwards across a reboot (restored from `last_time`).
- **VICE, .d81:** boot from a .d81 with drive 8 set to a 1581, plus file I/O, `format` and `fsck`. Also run a 1541 drive 8 with a 1581 as drive 9.
- **Regression:** the full suite on PAL, NTSC and Open ROMs, as for every release. A 1541 must still fast-read after a 1581 has been detected on the bus.
- **Real hardware:** an Ultimate with a .d81 mounted.

### Open questions

- [x] Which kernel RAM budget is acceptable for this? The 561 free bytes below the jump table, so the program pool doesn't shrink. `ci` alone takes 32 of them.
- [x] Should a v2 kernel also mount v1 disks read-only, or only v2? Only v2; the new magic keeps the two apart in both directions.
- [ ] Should the 24 reserved inode bytes become 12 more direct pointers (files up to 24 blocks without an indirect block)?
- [ ] Which drive-type check is reliable on VICE, real 1581s and the Ultimate? `M-R` and the track 40 read to be tried on an Ultimate with its drive set to 1581 (issue #4).
- [ ] Is reading the Ultimate's clock worth adding, and how much code does it take? Being looked into on an Ultimate 64 (issue #4).
- [ ] Short date format for `ls -l` within 40 columns.
- [ ] Who takes which part. Started in issue #4: drive detection and the Ultimate's clock, tested on an Ultimate 64 and Ultimate 64 Elite.
