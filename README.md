# Breadbin

A small Unix-like operating system for the Commodore 64 — the "breadbin".

By kpatronas@gmail.com.

It is a real kernel, not a shell that prints canned output:

- **Preemptive multitasking.** A timer interrupt drives a round-robin scheduler, so `cmd &` keeps running in the background while you type. Up to 12 processes.
- **Real programs.** `ls`, `cat`, `grep` and the rest are separate relocatable executables in `/bin`. The shell asks the kernel to `spawn` them and `wait`s for them.
- **Pipes and redirection.** `cat readme | grep unix | wc`, plus `>`, `>>` and `<`. A pipe is a kernel buffer: readers block when it is empty, writers block when it is full, and writing to a closed pipe raises `SIGPIPE`.
- **A Unix filesystem on the 1541.** c64fs has inodes, real directories (`mkdir`, `cd`, `..`), files up to 35 KB, and `/dev/console` and `/dev/null` device nodes.
- **Signals and job control.** RUN/STOP sends `SIGINT` to the foreground job and CTRL-Z stops it; `fg` and `bg` bring it back, `jobs` and `ps` show it as stopped. `kill` sends any signal.
- **REU and GeoRAM support.** If a RAM Expansion Unit (or, without one, a GeoRAM) is present, it is detected at boot, formatted, and mounted at `/tmp` as a fast RAM disk. Neither is required.
- **More drives.** `mount 9 /mnt` attaches drive 9, 10 or 11. A Breadbin disk shows up with its directories. A normal C64 disk shows up as one flat directory that you can read, write (`cp`), `rm` and `mv`; the writes go through the drive's own DOS, so other C64 software can read the results.
- **Users and screen.** There's a `login` with passwords (`passwd`, `whoami`), a full-screen editor (`edit`), colour `theme`s, shell wildcards (`*.bas`) and `jobs`.
- **Stock hardware.** It runs on a stock C64 with a 1541, and the same disk boots with or without an REU. A C128 in C64 mode works too, with a 1541 or 1571. The clock (`date`) keeps time even on C64s powered from a DC supply, whose TOD clock input is dead: the kernel notices and drives it from the timer interrupt.
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
#    for where to put them, or use the free MEGA65 Open ROMs, which
#    Breadbin also runs on)

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
x64sc -georam -georamsize 512 -autostart build/breadbin.d64   # or a GeoRAM
x64sc -drive9type 1541 -9 other.d64 -autostart build/breadbin.d64   # with a drive 9
```

Or attach `build/breadbin.d64` to drive 8 yourself and type `LOAD"*",8,1` and then `RUN`.

### Real hardware

Breadbin has only been tested in VICE so far. On a real machine it should work the same way, with one requirement: the disk is a hybrid (see [How it works](#how-it-works)), and the kernel reads and writes it as raw sectors with the 1541's `U1`, `U2` and `B-P` commands. So it needs a drive that understands them, either a real one or a full 1541 emulation, and the disk must be writable.

| Setup | Status | How |
|-------|--------|-----|
| Real 1541 or 1571 | should work | Write the image to a floppy: from a PC with a ZoomFloppy or XUM1541 and OpenCBM (`d64copy build/breadbin.d64 8`), or on the C64 with a copier such as DraCopy. |
| Ultimate 64, 1541 Ultimate-II+ | should work | Mount `breadbin.d64` on drive 8. Its REU (512 KB or more) gives you `/tmp`. Writes go into the mounted image: save it back, or turn on write-back, to keep them. |
| Pi1541 | should work | It emulates the 1541's hardware, so it behaves like a real drive. |
| SD2IEC | untested | Mount the image (`CD:breadbin.d64`). It depends on the firmware handling the block commands on `.d64` images. |
| Kung Fu Flash, EasyFlash | won't work | Their cartridge ROM sits where the kernel lives (see below). |

Then type `LOAD"*",8,1` and `RUN`, as in VICE.

Things to know:

- **No cartridges.** The kernel runs at `$7D00–$CFFF`, over the area where a cartridge maps its ROM, so Action Replay, Final Cartridge, EasyFlash and the like must be removed or switched off. An REU or a GeoRAM is fine: they only use the I/O area.
- **Disk access is slowish.** Breadbin has its own serial bus driver, and it loads a small routine into the 1541 that sends sectors about twice as fast as the standard protocol (the disk's rotation is the limit after that). Loading a command from a floppy still takes a second or two, and the system pauses while the drive works. A drive that can't run 1541 code (SD2IEC) gets the standard protocol. JiffyDOS doesn't help, but it doesn't get in the way either. With an REU of 256 KB or more, every block read from drive 8 is kept in the REU, so the second load of a command is instant.
- **Handled:** PAL and NTSC, C64s on DC power supplies (whose TOD clock never ticks: the kernel keeps time itself), and a C128 in C64 mode with a 1541 or 1571.
- **Not supported:** the 1581 and 40-track disks.

If you try it on real hardware, a report helps either way, and for a crash a photo of the screen (especially a `kernel panic:` line).

## Try it

Things to type at the `/ $` prompt:

```
ls /bin
cat /home/readme | grep unix | wc
mkdir /home/src ; cd /home/src ; echo hi > f ; ls -l
count > /dev/null &
ps
kill 5                      (use the pid that ps shows)
count                       (then CTRL-Z: it stops)
jobs ; bg ; fg              (resume it; RUN/STOP ends it)
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

[docs/filesystem.md](docs/filesystem.md) explains it all: the on-disk layout of c64fs (superblock, bitmap, inodes, directories), the REU/GeoRAM RAM disk, how normal C64 disks are handled, what `format` does, and the limits.

## Writing programs

[docs/programming.md](docs/programming.md) is the developer guide: the memory map a program sees, every system call, the user library, building with ca65 or with `as` on the C64, and how to port a Unix tool (with a worked example, [docs/examples/rev.s](docs/examples/rev.s)).

## Commands

`sh` `init` `login` `ls [-l] [-a]` `cat` `echo` `grep [-v] [-c]` `wc` `head [-n]` `more` `edit` `cp` `mv` `rm` `mkdir` `rmdir` `pwd` `stat` `hexdump` `ps` `kill [-sig]` `sleep` `free` `df` `mount` `umount` `format` `uptime` `date` `uname [-a]` `version` `whoami` `passwd` `theme` `help` `clear` `count` `basic` `as`

Shell built-ins: `cd`, `exit`, `kill`, `jobs`, `fg`, `bg`. CTRL-Z stops the foreground command.

## Layout

| Path | What |
|------|------|
| `src/kernel/` | the kernel (ca65): `proc.s` scheduler, IRQ, signals · `jtab.s` syscall table at `$CF00` · `exec.s` loader · `file.s` fds, pipes, file syscalls · `fs.s` c64fs · `blk.s` block cache, 1541 and REU · `iec.s` serial bus driver · `drive.s` the sector-sending code that runs in the 1541 · `cbm.s` CBM DOS disks and mount · `con.s` console · `mem.s` page allocator |
| `src/bin/` | user programs |
| `src/lib/` | the user library linked into programs |
| `include/breadbin.inc` | the system-call interface for programs |
| `tools/mkimage.py` | builds and inspects disk images (`ls`, `cat` subcommands) |
| `tools/cx.py` | makes relocatable executables |
| `tools/vicetest.py` | drives VICE for the automated tests |
| `docs/filesystem.md` | disks, mounting, `format`, and the on-disk layout |
| `docs/programming.md` | writing programs: system calls, the library, building, porting Unix tools |
| `docs/superpowers/` | design spec and implementation plan |

## How it works

- **Memory.** BASIC ROM is banked out. The kernel lives at `$8000–$CEFF`, and programs get 256-byte pages from `$0800–$7FFF`.
- **Context switch.** Each process has its own zero page `$02–$3F` and its slice of the stack page; both are saved and restored on every switch.
- **Kernel preemption.** The kernel itself is not preemptible, so disk I/O is a critical section. The serial bus driver is not re-entrant.
- **Executables (CX format).** Each program is linked twice, at `$0000` and at `$0100`. The bytes that differ by one are high bytes of addresses, and their offsets become the relocation table. The loader adds the load page to each of them.
- **Disk.** The `.d64` is a hybrid. Its CBM DOS directory holds only the boot file `BREADBIN` (`LOAD"*",8,1` / `RUN`). The rest of the disk is c64fs (Breadbin's filesystem), starting with its superblock at track 19 sector 0. The kernel reads and writes raw sectors with the drive's `U1`/`U2`/`B-P` commands.

## FAQ

**How much memory does it use?** The kernel is about 20 KB of RAM at `$7D00–$CFFF`, including its tables, its buffers, the system-call jump table at `$CF00` and the user library that every program shares; the process save areas sit in the RAM under the KERNAL ROM. It has no ROM of its own and calls only a few KERNAL routines, for the keyboard and the screen. That leaves 117 pages (29 KB) at `$0800–$7CFF` for programs, and each program gets its own pages. With an REU or a GeoRAM you also get a RAM disk at `/tmp`.

**How can programs run side by side without an MMU?** There is no memory protection and no virtual memory. Every program is relocated when it is loaded (see [How it works](#how-it-works)), so each one runs in its own pages and no two need the same addresses. That is the model of early Unix on machines without an MMU, or of AmigaOS. The cost: a program with a bug can overwrite another program's memory, or the kernel's. The kernel does catch some crashes: a program that hits a `BRK` is killed, and the rest keeps running.

**How does multitasking work on a 6502?** A CIA timer interrupt fires 60 times a second, and every 3 ticks the scheduler switches to the next ready process. The 6502 has a single stack page and a single zero page, so a switch copies the outgoing process's part of both into its save area and copies the next one's back in. A process that waits for a key, a pipe or a child is blocked and gets no CPU time.

**Does it run on a C128?** Yes, in C64 mode, with a 1541 or a 1571. That has been tested in VICE only so far, like everything else (see [Real hardware](#real-hardware)).

**Are there compilers?** Not on the C64 yet. There is a 6502 assembler (`as`) and an integer BASIC (`basic`) that run on it. On a PC, any 6502 toolchain works; Breadbin itself is built with cc65. [docs/programming.md](docs/programming.md) explains how to write programs.

**Why?** For fun, and to see how much of a real Unix fits in a 64 KB machine from 1982: processes, pipes, signals, job control and a filesystem with directories, on a stock C64 and a 1541.

## Related projects

Breadbin is not the first Unix-like system for 6502 machines. It shares no code with these, and they are worth a look:

- [LUnix / LNG](https://github.com/ytmytm/c64-lng): "LUnix Next Generation", a multitasking Unix-like system for the C64, C128 and other 6502 machines, from the 1990s.
- ACE (Advanced Computing Environment): a Unix-like environment for the C64 and C128.
- GeckOS: a multitasking operating system for 6502 computers, including the C64.
- Fuzix: a Unix-like system for 8-bit and other small machines.
- [GordonOS](https://github.com/GordonOS/gordon-os): a preemptive multitasking OS for the C64 that requires an REU.

## Tests

```sh
make test-host   # image builder and relocation tool (fast, no VICE needed)
make test        # boots VICE and drives the shell (slow, ~25 min)
make test-openroms  # the same system tests under the MEGA65 Open ROMs
```

The system tests start `x64sc` (windows open minimized), type commands through VICE's remote monitor, and read the screen back. They need `x64sc` and `c1541` on your `PATH` (or set `X64SC=/path/to/x64sc`). Don't run other VICE instances at the same time: the tests are timing-sensitive under heavy CPU load.

Extract a file from a disk image on the host:

```sh
python3 tools/mkimage.py ls  build/breadbin.d64 /home
python3 tools/mkimage.py cat build/breadbin.d64 /home/readme
```

## License

MIT - see [LICENSE](LICENSE). Copyright (c) 2026 Konstantinos Patronas <kpatronas@gmail.com>.
