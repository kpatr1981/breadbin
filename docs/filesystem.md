# Disks and the filesystem

This explains how Breadbin stores files, how to use more than one disk, and how to make new disks.

## The short version

| You want to… | Do this |
|---|---|
| Use the boot disk | It is mounted at `/` automatically. |
| Use a second disk | Put it in drive 9 (or 10, 11), then `mount 9 /mnt`. |
| Stop using it | `umount /mnt`. Close files and `cd` off it first. |
| Make a new Breadbin disk | `format 9 c64fs mydisk`, then `mount 9 /mnt`. |
| Make a normal C64 disk | `format 9 cbm mydisk`, then `mount 9 /mnt`. |
| See free space | `df` |
| See what is mounted | `mount` |

`format` erases the whole disk and asks first. It only works on drives 9, 10 and 11: drive 8 holds the running system.

## Two kinds of disk

Breadbin understands two disk formats.

**c64fs**, Breadbin's own filesystem. It has real directories (`mkdir`, `cd`, `..`), and programs on it can be run. The boot disk is c64fs. Other C64 software sees a c64fs disk as one file (the boot file) plus a full disk, and can't read the files on it.

**CBM DOS**, the normal C64 disk format. Every C64 program, and tools like `c1541`, can read it. Breadbin shows it as one flat directory: you can `ls`, `cat`, `cp` to and from it, `rm` and `mv`, but not `mkdir`, and programs can't be run from it. Use it to swap files with the rest of the C64 world.

`mount` tells them apart by itself, and `mount` with no arguments shows which kind each drive is:

```
/ $ mount
drive 8 on / (c64fs)
drive 9 on /mnt (cbm dos)
```

## Devices and mount points

| Device | What | Where |
|---|---|---|
| 0 | drive 8, the boot disk | `/` |
| 1 | the RAM disk, if an REU or GeoRAM is fitted | `/tmp` |
| 2, 3, 4 | drives 9, 10 and 11 | wherever you `mount` them |

Mount points are ordinary directories (the boot disk has an empty `/mnt` for this). Up to four mounts can be active at once, `/tmp` included. Path lookup crosses into a mounted disk when it reaches the mount point, and `..` from the top of a mounted disk leads back out, so `cd /mnt/src; cd ../..` ends up at `/`.

`umount` refuses with "device busy" while any process has a file open on that disk or has its working directory there.

## c64fs on disk

A 1541 disk has 683 sectors of 256 bytes: 35 tracks with 17 to 21 sectors each. c64fs numbers them as **blocks 0 to 682** in the usual `.d64` order: track 1 sector 0 is block 0, track 18 sector 0 is block 357, and track 19 sector 0 is block 376.

| Blocks | Contents |
|---|---|
| 357 – 375 (track 18) | the CBM DOS directory and BAM, left for the drive's DOS |
| 376 | c64fs superblock |
| 377 | block bitmap |
| 378 – 409 | inode table (32 blocks, 128 inodes) |
| everything else | file and directory data |

On the boot disk, the CBM directory on track 18 lists a single file, `BREADBIN`: the kernel, which `LOAD"*",8,1` loads. Its sectors start at block 0. Every sector of the disk is marked used in the CBM BAM, so the drive's own DOS never writes over c64fs. That's why other C64 software sees the disk as full.

### Superblock (block 376)

| Offset | Size | Field |
|---|---|---|
| 0 | 5 | magic `C64F2` |
| 5 | 1 | version (2) |
| 6 | 2 | number of blocks (683) |
| 8 | 1 | number of inodes (128) |
| 9 | 2 | bitmap block (377) |
| 11 | 2 | first inode block (378) |
| 13 | 1 | inode blocks (32) |
| 14 | 1 | root directory inode (1) |
| 15 | 4 | `last_time`: the clock, saved (seconds since 1970, local time) |

### Bitmap (block 377)

There is one bit per block, and a set bit means used. A block of 256 bytes covers 2048 blocks, so bits 683 to 2047 are always set. Block 0 is always used too, because block number 0 inside an inode means "no block here".

### Inodes (blocks 378–409)

An inode is 64 bytes, 4 per block. Inode 0 is reserved and inode 1 is the root directory.

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | type: 0 free, 1 file, 2 directory, 3 device |
| 1 | 1 | link count |
| 2 | 3 | size in bytes |
| 5 | 1 | device major number (0 = `/dev/null`, 1 = `/dev/console`) |
| 6 | 24 | 12 direct block numbers, 2 bytes each |
| 30 | 2 | indirect block: a block holding 128 more block numbers |
| 32 | 4 | `mtime`: contents last changed (seconds since 1970, local time; 0 = unknown) |
| 36 | 4 | `ctime`: inode last changed (contents, links, or `touch`) |
| 40 | 24 | reserved, zero |

12 direct blocks plus 128 through the indirect block give a largest file of 140 × 256 = 35,840 bytes, more than a C64 can hold in memory anyway.

### Times

Creating a file sets both times; writing to it or truncating it sets `mtime` and `ctime`; any other change to the inode (its link count, say) sets `ctime`. `touch` sets both. A copy (`cp`) is a new file with the current time; `mv` keeps both times, since only directory entries change. There is no access time: it would cost a disk write on every read.

The C64 has no battery clock. The kernel's clock counts seconds from the timer interrupt and starts, at mount, from the disk's `last_time`. The kernel saves the clock there with the next inode change once its top three bytes have changed (every 256 seconds at most), and at mount moves the clock up to the next 256-second step past `last_time`, so the time never goes backwards across a reboot even without `sync`. `date` sets the clock; `mkimage.py` gives every file the host file's time and sets `last_time` to the build time.

### Directories

A directory is a file of 16-byte entries: 1 byte for the inode number (0 = unused slot) and 15 bytes for the name (up to 14 characters, NUL-padded). Every directory starts with `.` (itself) and `..` (its parent). Names are ASCII and case-sensitive; `/`, `.` and `..` are special.

### On a 1581 (.d81)

A 1581 disk has 3200 sectors: 80 tracks of 40. c64fs numbers them as blocks 0 to 3199 (track 1 sector 0 is block 0, track 40 sector 0 is block 1560), and keeps the superblock at block 376 as on a 1541, which is 10/16 there:

| Blocks | Contents |
|---|---|
| 376 | c64fs superblock (3200 blocks) |
| 377 – 378 | block bitmap (two blocks: 2048 bits each) |
| 379 – 410 | inode table (32 blocks, 128 inodes) |
| 1560 – 1599 (track 40) | the CBM DOS header, BAM and directory, left for the drive's DOS |
| everything else | file and directory data |

The kernel tells the drives apart when it opens one: a 1581 reads track 40 sector 0 and finds its header there (format `D`), while a 1541 refuses the track. A 1581 gets the standard protocol, since the fast routine is 1541 code, and drive 8's blocks are not copied into the REU (that copy is sized for 683 blocks). `make` builds `build/breadbin.d81` next to the `.d64`; `make run-d81` boots it in VICE.

### How the kernel reaches the disk

The kernel reads and writes whole sectors with the 1541's sector commands: `U1` reads a block (on drives 9–11, and on drive 8 when the fast read below isn't available), `B-P` with `U2` writes one. Those go over the serial bus through Breadbin's own IEC driver (`src/kernel/iec.s`), not the KERNAL ROM, on the command channel (15) and a data channel with a drive buffer (`#`). The driver follows the stock KERNAL's protocol and timing, so it works the same under the Commodore ROMs and the MEGA65 Open ROMs. A cache of 6 blocks sits in front of the drive. It is write-back: a changed block reaches the disk when a file written to is closed, when it has been changed for two seconds, on `sync`, on `umount`, or when its buffer is needed for another block. Wait for the drive to stop (or run `sync`) before switching off.

While the disk is busy, every other process waits: the bus transfer can't be interrupted safely. Reads of drive 8 don't use `U1`: at the first read the kernel loads a small routine (`src/kernel/drive.s`) into the drive's memory with `M-W` and starts it with `M-E` for every block; it reads the sector with the drive's job queue and sends the 256 bytes over CLK and DATA at about twice the speed of the standard protocol, so a 1541 reads two to three blocks per second, and loading a 1–3 KB command takes a second or two. If the drive doesn't run the routine (an SD2IEC), the kernel notices the timeout and uses `U1` from then on. Writes always use `B-P`/`U2`. With an REU of four banks (256 KB) or more, the top three banks keep a copy of every drive 8 block read or written, so a block is read from the floppy only once per boot.

## The RAM disk (`/tmp`)

With a RAM Expansion Unit, or a GeoRAM when there is no REU, the kernel formats it as c64fs at every boot and mounts it at `/tmp`. The layout is the same idea with different block numbers: superblock at block 0, the bitmap from block 1 (one bitmap block per 2048 blocks, that is per 8 banks of 64 KB), then 64 inode blocks (255 inodes). Its size is that of the REU, up to 128 banks (32768 blocks, 8 MB), less the three banks that keep the copy of drive 8 when the REU has four or more, and, on an REU (not a GeoRAM), less the 128 blocks at the top that are the swap area ([design-swap.md](design-swap.md)). It is fast, and it is **empty after every reboot**. Without an REU, `/tmp` is an ordinary directory on the boot disk.

## Normal C64 disks (CBM DOS)

When drive 9–11 holds a normal C64 disk, Breadbin handles it like this:

- **Reading** goes straight to the sectors: the directory chain on track 18, then each file's chain of track/sector links. PRG, SEQ and USR files are shown, by name: PETSCII names appear in lowercase, and names longer than 14 characters are cut short.
- **Writing, deleting and renaming** go through the drive's own DOS (`0:name,S,W`, `S0:`, `R0:`), so the BAM stays correct and the disk stays readable everywhere. New files are SEQ files. Writing to an existing name replaces that file. Only one file per drive can be open for writing at a time.
- `ls -l` sizes are estimates (blocks × 254), because the true length is only known after reading the whole file.
- `mkdir` and `rmdir` are refused (the format has no directories), and so is running programs from the disk.

## `format`

```
format drive [cbm|c64fs] [name]
```

`format` erases the disk in drive 9, 10 or 11 and makes a new one. `c64fs` is the default. The name defaults to `breadbin`.

- **`format 9 cbm photos`** sends the drive's own format command (`N0:PHOTOS,BB`). The result is a normal, empty C64 disk.
- **`format 9 c64fs work`** does the same DOS format first, which lays down the sector headers, and then writes a fresh c64fs on top: it marks every sector used in the CBM BAM, writes the superblock, bitmap and inode table, and creates an empty root directory (inode 1, in block 1).

`format` asks `erase everything on drive 9? (y/n)` first. It refuses drive 8 and any drive that is mounted. Formatting takes a while on a real 1541 (about a minute and a half), and the rest of the system pauses meanwhile. Afterwards, `mount 9 /mnt` and the disk is ready to use.

## Making disks on the computer you build on

`tools/mkimage.py` builds and inspects c64fs disk images, which is handy for preparing a data disk or checking what Breadbin wrote:

```sh
# a new disk image holding the contents of a folder
python3 tools/mkimage.py build data.d64 --boot build/breadbin.prg --root myfolder

# look inside an image
python3 tools/mkimage.py ls  build/breadbin.d64 /home
python3 tools/mkimage.py cat build/breadbin.d64 /home/readme
```

### Disks from Breadbin 0.4 and earlier

Those use format 1 (magic `C64FS`, 32-byte inodes without times), which this kernel doesn't mount: as the boot disk it stops with "cannot mount root filesystem", and in drive 9–11 the disk shows up as a normal C64 disk holding only the boot file. Old kernels likewise refuse format 2 disks, because they check only the magic. Convert an old image on the computer you build on; the contents are kept, and every file gets the time of the conversion:

```sh
python3 tools/mkimage.py upgrade old.d64 new.d64 --boot build/breadbin.prg
```

`--boot` puts the new kernel on a boot disk; leave it out for a data disk.

`make` uses the same tool to build `build/breadbin.d64` from `rootfs/` and the compiled programs. For normal C64 disk images, use VICE's `c1541`, for example `c1541 -format "mydisk,md" d64 mydisk.d64`.

## Limits

| Limit | Value |
|---|---|
| file size | 35,840 bytes |
| files and directories per disk | 127 |
| name length | 14 characters |
| path length (working directory) | 47 characters |
| mounts at once | 4 (including `/tmp`) |
| open files, system-wide | 24 |
| open files per process | 8 |
| writable files on a CBM disk | 1 per drive |
