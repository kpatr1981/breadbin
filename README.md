# c64os

A small Unix-like operating system for the Commodore 64.

It is a real kernel, not a shell that prints canned output:

- **Preemptive multitasking.** A timer interrupt drives a round-robin scheduler, so `cmd &` keeps running in the background while you type. Up to 12 processes.
- **Real programs.** `ls`, `cat`, `grep` and the rest are separate relocatable executables in `/bin`. The shell asks the kernel to `spawn` them and `wait`s for them.
- **Pipes and redirection.** `cat readme | grep unix | wc`, plus `>`, `>>` and `<`. A pipe is a kernel buffer: readers block when it is empty, writers block when it is full, and writing to a closed pipe raises `SIGPIPE`.
- **A Unix filesystem on the 1541.** c64fs has inodes, real directories (`mkdir`, `cd`, `..`), files up to 35 KB, and `/dev/console` and `/dev/null` device nodes.
- **Signals.** RUN/STOP sends `SIGINT` to the foreground job. `kill` sends any signal.
- **REU support.** If a RAM Expansion Unit is present, it is detected at boot, formatted, and mounted at `/tmp` as a fast RAM disk.
- **More drives.** `mount 9 /mnt` attaches drive 9, 10 or 11. A c64os disk shows up with its directories. A normal C64 disk shows up as one flat directory that you can read, write (`cp`), `rm` and `mv`; the writes go through the drive's own DOS, so other C64 software can read the results.
- **Users and screen.** There's a `login` with passwords (`passwd`, `whoami`), a full-screen editor (`edit`), colour `theme`s, shell wildcards (`*.bas`) and `jobs`.
- **Stock hardware.** It runs on a stock C64 with a 1541, and the same disk boots with or without an REU.
- **BASIC and an assembler.** Both run *on* the C64: `basic` is an integer BASIC, and `as` is a 6502 assembler that produces new c64os commands.

## Try it

```sh
make            # needs cc65 (ca65/ld65/ar65), python3
make run        # boots build/c64os.d64 in VICE (x64sc)
make run-reu    # same, with a 512K REU (/tmp becomes a RAM disk)
x64sc -drive9type 1541 -9 other.d64 -autostart build/c64os.d64   # with a drive 9
```

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
theme c64
```

At the `login:` prompt, type `root` or `user`; neither has a password until you set one with `passwd`.

On a C64 keyboard, `|` is **SHIFT + `-`**, and RUN/STOP interrupts the running command.

## Commands

`sh` `init` `login` `ls [-l] [-a]` `cat` `echo` `grep [-v] [-c]` `wc` `head [-n]` `more` `edit` `cp` `mv` `rm` `mkdir` `rmdir` `pwd` `stat` `hexdump` `ps` `kill [-sig]` `sleep` `free` `df` `mount` `umount` `uptime` `date` `uname [-a]` `version` `whoami` `passwd` `theme` `help` `clear` `count` `basic` `as`

Shell built-ins: `cd`, `exit`, `kill`, `jobs`.

## Layout

| Path | What |
|------|------|
| `src/kernel/` | the kernel (ca65): `proc.s` scheduler, IRQ, signals · `jtab.s` syscall table at `$CF00` · `exec.s` loader · `file.s` fds, pipes, file syscalls · `fs.s` c64fs · `blk.s` 1541/REU block cache · `con.s` console · `mem.s` page allocator |
| `src/bin/` | user programs |
| `src/lib/` | the user library linked into programs |
| `include/c64os.inc` | the system-call interface for programs |
| `tools/mkimage.py` | builds and inspects disk images (`ls`, `cat` subcommands) |
| `tools/cx.py` | makes relocatable executables |
| `tools/vicetest.py` | drives VICE for the automated tests |
| `docs/superpowers/` | design spec and implementation plan |

## How it works

- **Memory.** BASIC ROM is banked out. The kernel lives at `$8800–$CEFF`, and programs get 256-byte pages from `$0800–$87FF`.
- **Context switch.** Each process has its own zero page `$02–$3F` and its slice of the stack page; both are saved and restored on every switch.
- **Kernel preemption.** The kernel itself is not preemptible, so disk I/O is a critical section. The KERNAL's IEC routines are not re-entrant.
- **Executables (CX format).** Each program is linked twice, at `$0000` and at `$0100`. The bytes that differ by one are high bytes of addresses, and their offsets become the relocation table. The loader adds the load page to each of them.
- **Disk.** The `.d64` is a hybrid. Its CBM DOS directory holds only the boot file `C64OS` (`LOAD"*",8,1` / `RUN`). The rest of the disk is c64fs, starting with its superblock at track 19 sector 0. The kernel reads and writes raw sectors with the drive's `U1`/`U2`/`B-P` commands.

## Tests

```sh
make test-host   # image builder and relocation tool (fast)
make test        # boots VICE and drives the shell (slow, ~20 min)
```

Extract a file from a disk image on the host:

```sh
python3 tools/mkimage.py ls  build/c64os.d64 /home
python3 tools/mkimage.py cat build/c64os.d64 /home/readme
```
