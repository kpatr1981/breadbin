# Breadbin

A small Unix-like operating system for the Commodore 64 — the "breadbin".

By kpatronas@gmail.com.

It is a real kernel, not a shell that prints canned output:

- **Preemptive multitasking.** A timer interrupt drives a round-robin scheduler, so `cmd &` keeps running in the background while you type. Up to 12 processes.
- **Real programs.** `ls`, `cat`, `grep` and the rest are separate relocatable executables in `/bin`. The shell asks the kernel to `spawn` them and `wait`s for them.
- **Pipes and redirection.** `cat readme | grep unix | wc`, plus `>`, `>>` and `<`. A pipe is a kernel buffer: readers block when it is empty, writers block when it is full, and writing to a closed pipe raises `SIGPIPE`.
- **A Unix filesystem on the 1541.** c64fs has inodes, real directories (`mkdir`, `cd`, `..`), files up to 35 KB, and `/dev/console` and `/dev/null` device nodes.
- **Signals.** RUN/STOP sends `SIGINT` to the foreground job. `kill` sends any signal.
- **REU support.** If a RAM Expansion Unit is present, it is detected at boot, formatted, and mounted at `/tmp` as a fast RAM disk.
- **More drives.** `mount 9 /mnt` attaches drive 9, 10 or 11. A Breadbin disk shows up with its directories. A normal C64 disk shows up as one flat directory that you can read, write (`cp`), `rm` and `mv`; the writes go through the drive's own DOS, so other C64 software can read the results.
- **Users and screen.** There's a `login` with passwords (`passwd`, `whoami`), a full-screen editor (`edit`), colour `theme`s, shell wildcards (`*.bas`) and `jobs`.
- **Stock hardware.** It runs on a stock C64 with a 1541, and the same disk boots with or without an REU.
- **BASIC and an assembler.** Both run *on* the C64: `basic` is an integer BASIC, and `as` is a 6502 assembler that produces new Breadbin commands.

## Building

### What you need

| Tool | Used for | Tested with |
|------|----------|-------------|
| [cc65](https://cc65.github.io/) (`ca65`, `ld65`, `ar65`) | assembling and linking the kernel and programs | 2.19 |
| Python 3 (standard library only) | the disk image builder and relocation tool | 3.15 (3.8 or newer should work) |
| GNU make | the build | 3.81 |
| [VICE](https://vice-emu.sourceforge.io/) (`x64sc`, `c1541`) | running it and the automated tests | 3.10 |

VICE is only needed to run Breadbin and its tests. Building the disk image needs just cc65, Python and make.

Install them:

```sh
# macOS (Homebrew)
brew install cc65 vice python3

# Debian / Ubuntu
sudo apt install cc65 vice python3 make
#   (Debian's VICE package ships without the C64 ROMs; see the VICE docs
#    for where to put them)

# Windows: use WSL with the Debian/Ubuntu commands above, or install the
# cc65 and VICE Windows builds and run make from MSYS2.
```

### Build

```sh
git clone https://github.com/kpatr1981/breadbin.git
cd breadbin
make
```

This assembles the kernel and every program in `src/bin/`, and packs them with the files from `rootfs/` into one disk image:

| Output | What it is |
|--------|------------|
| `build/breadbin.d64` | the bootable disk: put this in drive 8 |
| `build/breadbin.prg` | the kernel alone (the disk's boot file) |
| `build/root/bin/*` | the programs, as relocatable CX executables |

`make clean` removes `build/`. To add a program, drop a new `src/bin/name.s` in and run `make`: it is built automatically and lands in `/bin`.

### Run

```sh
make run        # boots build/breadbin.d64 in VICE
make run-reu    # same, with a 512 KB REU (/tmp becomes a RAM disk)
x64sc -drive9type 1541 -9 other.d64 -autostart build/breadbin.d64   # with a drive 9
```

Or attach `build/breadbin.d64` to drive 8 yourself and type `LOAD"*",8,1` and then `RUN`.

**Real hardware.** Breadbin has only been tested in VICE so far. It needs a drive that understands the 1541's sector commands (`U1`, `U2`, `B-P`): a real 1541 or 1571, or a 1541 emulation such as the Ultimate 64's. To make a real floppy, write the `.d64` with a tool such as OpenCBM's `d64copy`.

## Try it

Things to type at the `/ $` prompt:

```
ls /bin
cat /home/readme | grep unix | wc
mkdir /home/src ; cd /home/src ; echo hi > f ; ls -l
count > /dev/null &
ps
kill 5                      (use the pid that ps shows)
basic /home/hello.bas
as /home/hello.s /home/hello ; /home/hello
df ; free
edit /home/notes            (^O saves, ^X quits)
mount 9 /mnt ; ls /mnt      (needs a disk in drive 9)
format 9 c64fs             (or: format 9 cbm name - erases drive 9)
theme c64
```

At the `login:` prompt, type `root` or `user`; neither has a password until you set one with `passwd`.

On a C64 keyboard, `|` is **SHIFT + `-`**, and RUN/STOP interrupts the running command.

## Disks

The boot disk is mounted at `/`. More drives work too: put a disk in drive 9, 10 or 11 and `mount 9 /mnt`. A Breadbin disk keeps its directories; a normal C64 disk shows up flat and stays readable by other C64 software. To make a new disk, run `format 9 c64fs mydisk` (with directories) or `format 9 cbm mydisk` (a normal C64 disk). Both erase drive 9 and ask first. `df` shows free space, and `umount /mnt` detaches the disk.

[docs/filesystem.md](docs/filesystem.md) explains it all: the on-disk layout of c64fs (superblock, bitmap, inodes, directories), the REU RAM disk, how normal C64 disks are handled, what `format` does, and the limits.

## Commands

`sh` `init` `login` `ls [-l] [-a]` `cat` `echo` `grep [-v] [-c]` `wc` `head [-n]` `more` `edit` `cp` `mv` `rm` `mkdir` `rmdir` `pwd` `stat` `hexdump` `ps` `kill [-sig]` `sleep` `free` `df` `mount` `umount` `format` `uptime` `date` `uname [-a]` `version` `whoami` `passwd` `theme` `help` `clear` `count` `basic` `as`

Shell built-ins: `cd`, `exit`, `kill`, `jobs`.

## Layout

| Path | What |
|------|------|
| `src/kernel/` | the kernel (ca65): `proc.s` scheduler, IRQ, signals · `jtab.s` syscall table at `$CF00` · `exec.s` loader · `file.s` fds, pipes, file syscalls · `fs.s` c64fs · `blk.s` 1541/REU block cache · `con.s` console · `mem.s` page allocator |
| `src/bin/` | user programs |
| `src/lib/` | the user library linked into programs |
| `include/breadbin.inc` | the system-call interface for programs |
| `tools/mkimage.py` | builds and inspects disk images (`ls`, `cat` subcommands) |
| `tools/cx.py` | makes relocatable executables |
| `tools/vicetest.py` | drives VICE for the automated tests |
| `docs/filesystem.md` | disks, mounting, `format`, and the on-disk layout |
| `docs/superpowers/` | design spec and implementation plan |

## How it works

- **Memory.** BASIC ROM is banked out. The kernel lives at `$8000–$CEFF`, and programs get 256-byte pages from `$0800–$7FFF`.
- **Context switch.** Each process has its own zero page `$02–$3F` and its slice of the stack page; both are saved and restored on every switch.
- **Kernel preemption.** The kernel itself is not preemptible, so disk I/O is a critical section. The KERNAL's IEC routines are not re-entrant.
- **Executables (CX format).** Each program is linked twice, at `$0000` and at `$0100`. The bytes that differ by one are high bytes of addresses, and their offsets become the relocation table. The loader adds the load page to each of them.
- **Disk.** The `.d64` is a hybrid. Its CBM DOS directory holds only the boot file `BREADBIN` (`LOAD"*",8,1` / `RUN`). The rest of the disk is c64fs (Breadbin's filesystem), starting with its superblock at track 19 sector 0. The kernel reads and writes raw sectors with the drive's `U1`/`U2`/`B-P` commands.

## Tests

```sh
make test-host   # image builder and relocation tool (fast, no VICE needed)
make test        # boots VICE and drives the shell (slow, ~25 min)
```

The system tests start `x64sc` (windows open minimized), type commands through VICE's remote monitor, and read the screen back. They need `x64sc` and `c1541` on your `PATH` (or set `X64SC=/path/to/x64sc`). Don't run other VICE instances at the same time: the tests are timing-sensitive under heavy CPU load.

Extract a file from a disk image on the host:

```sh
python3 tools/mkimage.py ls  build/breadbin.d64 /home
python3 tools/mkimage.py cat build/breadbin.d64 /home/readme
```

## License

MIT - see [LICENSE](LICENSE). Copyright (c) 2026 Konstantinos Patronas <kpatronas@gmail.com>.
