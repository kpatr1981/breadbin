# Writing programs for Breadbin

This guide is for people who want to write Breadbin commands, or port Unix tools to it, in 6502 assembly. You'll need to know 6502 assembly. You won't need to know how the kernel works inside.

A Breadbin program is a normal 6502 program with three differences:

1. It talks to the system only through **system calls** (`jsr SYS_READ` and so on), never through the KERNAL ROM or by poking the screen.
2. It is **relocatable**: the kernel loads it at whatever free page it finds, so it can't assume a fixed address.
3. It **shares the machine** with up to 11 other processes. The scheduler can switch away from it at any instruction.

Programs written that way behave like Unix programs. They read standard input and write standard output, they work in pipelines (`ls /bin | grep s | wc`), they can be redirected (`> file`, `< file`), backgrounded (`&`), stopped with CTRL-Z and killed.

## Contents

- [Hello, world (two ways)](#hello-world-two-ways)
- [What a program sees](#what-a-program-sees)
- [Calling the system](#calling-the-system)
- [System call reference](#system-call-reference)
- [Files, pipes and the console](#files-pipes-and-the-console)
- [Processes, signals and job control](#processes-signals-and-job-control)
- [The user library](#the-user-library)
- [Building: ca65 on your computer](#building-ca65-on-your-computer)
- [Building: `as` on the C64](#building-as-on-the-c64)
- [Porting a Unix tool](#porting-a-unix-tool)
- [Limits](#limits)

## Hello, world (two ways)

**On your computer, with cc65.** Save this as `src/bin/hello2.s` in the Breadbin source tree:

```asm
.include "../../include/breadbin.inc"
.import print

.segment "CODE"
        lda #<msg
        ldx #>msg
        jsr print               ; library: print a NUL-terminated string
        lda #0
        jmp SYS_EXIT            ; exit code 0

.segment "RODATA"
msg:    .byte "hello, world", 10, 0
```

Run `make`. The new command lands in `/bin` on `build/breadbin.d64`; boot it and type `hello2`.

**On the C64 itself**, with Breadbin's own assembler. `/home/hello.s` is a ready-made example:

```
/ $ as /home/hello.s /home/hello
/ $ /home/hello
hello, world! (assembled on a c64)
```

## What a program sees

### Memory

| Address | What |
|---|---|
| `$0002–$0007` | `r0`, `r1`, `r2`: system call argument registers (16 bits each) |
| `$0008–$001F` | kernel scratch: **don't use** (the kernel clobbers it during system calls) |
| `$0020–$0021` | `argv`: pointer to the argument pointer array |
| `$0022` | `argc` |
| `$0023–$002F` | **free for your program** (13 bytes) |
| `$0030–$003F` | used by the user library (`lp1`, `lp2`, `lp3`, `lval`); free if you don't link it |
| `$0040–$00FF` | kernel: don't touch |
| `$0100–$01FF` | the stack, shared by all processes: you get up to about 130 bytes of it |
| `$0800–$7FFF` | the user pool: your program is loaded somewhere in here |
| `$8000–$CEFF` | the kernel |
| `$CF00–$CFFF` | the system call jump table |
| `$D000–$DFFF` | I/O |
| `$E000–$FFFF` | KERNAL ROM (the kernel uses parts of it; programs shouldn't) |

Zero page `$02–$3F` and your part of the stack are **saved and restored on every context switch**, so each process has its own copy. Use them freely.

The loader puts your program at the start of a run of free 256-byte pages: code, then data, then BSS (zero-filled), then a copy of the arguments. All of it is yours until you exit. There is no `malloc`. Reserve buffers in BSS, and the kernel allocates exactly the pages you need.

**The stack is small.** About 130 bytes are saved per process. A program that goes deeper is killed with exit code 139 (`128 + 11`, like a segfault). Don't recurse deeply and don't push large buffers.

### Arguments

`argc` is the number of words, including the command name. `argv` points to an array of `argc` pointers, each to a NUL-terminated string, followed by a NULL pointer, the same as C's `main(argc, argv)`. The shell has already expanded wildcards (`*.s`) and removed quotes and redirections. The library function `argn` fetches one:

```asm
        lda #1
        jsr argn                ; A/X = argv[1]; carry set if argc <= 1
        bcs usage
```

### Standard input, output and error

A new process starts with file descriptor 0 (input), 1 (output) and 2 (errors) open. The shell connects them to the console, files or pipes. Write your program as a **filter**: read fd 0, write fd 1, report problems on fd 2. It will then work in pipelines without knowing it.

### Characters

Everything is ASCII. The console translates to and from PETSCII. A line ends with `10` (LF). Upper and lower case both work (the screen uses the lower-case character set).

### Exit

`jmp SYS_EXIT` with the exit code (0–127) in A. Returning with `rts` from the top level also works and exits with 0. The parent's `wait` sees the code. A process killed by a signal exits with `128 + signal`.

## Calling the system

```asm
        lda #<path
        sta r0
        lda #>path
        sta r0+1
        lda #O_RDONLY
        jsr SYS_OPEN            ; A = fd, or carry set and A = errno
        bcs error
```

- Arguments go in **A, X, Y** and the zero-page registers **r0, r1, r2**.
- Results come back in A, X (and sometimes r-registers).
- **Carry clear = success. Carry set = error, with an errno in A** (`ENOENT`, `EBADF` and so on, all in `include/breadbin.inc`).
- Assume A, X and Y are changed by every call. r0–r2 stay as you set them unless the call returns something in them.
- A call that has to wait (reading a key, reading an empty pipe, `wait`, `sleep`) puts your process to sleep, and other processes run in the meantime.

Every system call is a `jsr` into the jump table at `$CF00`. Its addresses are stable: a program built for this version keeps working with newer kernels.

## System call reference

| Call | In | Out | Notes |
|---|---|---|---|
| `SYS_EXIT` | A = code | never returns | closes your files, wakes your parent |
| `SYS_SPAWN` | r0 = path, r1 = argv (or 0), A = stdin fd, X = stdout fd, Y = flags | A = pid | runs a program as a child; stderr is inherited. Flags: `SP_BG` (background job), `SP_IGNINT` (ignore RUN/STOP) |
| `SYS_WAIT` | A = pid or `$FF` (any child), X = flags | A = pid, X = exit code | `W_NOHANG`: don't block (A = 0 if nothing finished). `W_UNTRACED`: also return a child that **stopped** (X = `WSTOPPED`) |
| `SYS_KILL` | A = pid, X = signal | | signal 0 only checks that the pid exists. pid 1 (init) can't be killed |
| `SYS_FG` | A = pid | | makes a job a foreground job and continues it (the shell's `fg`) |
| `SYS_GETPID` | | A = pid | |
| `SYS_YIELD` | | | gives up the rest of your time slice |
| `SYS_SLEEP` | A/X = jiffies (1/60 s) | | |
| `SYS_TIME` | | A/X/Y = jiffies since boot (24 bits) | ticks from a crystal timer, so it works on any C64 |
| `SYS_OPEN` | r0 = path, A = flags | A = fd | `O_RDONLY`, `O_WRONLY`, `O_RDWR`, plus `O_CREAT`, `O_TRUNC`, `O_APPEND` |
| `SYS_CLOSE` | A = fd | | |
| `SYS_READ` | A = fd, r0 = buffer, r1 = max length | r1 = count | r1 = 0 means end of file. From the console it returns one line |
| `SYS_WRITE` | A = fd, r0 = buffer, r1 = length | r1 = count | writing to a pipe nobody reads raises `SIGPIPE` |
| `SYS_PIPE` | | A = read fd, X = write fd | 256-byte kernel buffer; readers and writers block |
| `SYS_ISATTY` | A = fd | carry clear if the console | |
| `SYS_CONMODE` | A = 0 cooked, 1 raw | | raw: one key per read, no echo (see below) |
| `SYS_STAT` | r0 = path, r1 = 8-byte buffer | | type, nlink, size (3 bytes), inode, device, major. Types `T_FILE`, `T_DIR`, `T_CHR` |
| `SYS_MKDIR` / `SYS_RMDIR` / `SYS_UNLINK` | r0 = path | | |
| `SYS_RENAME` | r0 = old, r1 = new | | same device only (`EXDEV`) |
| `SYS_CHDIR` | r0 = path | | |
| `SYS_GETCWD` | r0 = buffer, A = size | | |
| `SYS_FSINFO` | r0 = path, r1 = 8-byte buffer | | free blocks (2), total blocks (2), free inodes, total inodes, device |
| `SYS_MEMINFO` | r0 = 6-byte buffer | | free pages, total pages, RAM-expansion size in 64 KB banks, processes used, max processes, expansion type (0 none, 1 REU, 2 GeoRAM) |
| `SYS_PROCINFO` | A = slot 0–15, r0 = 17-byte buffer | carry set if the slot is empty | pid, ppid, state, flags, pages, name (11), uid. States: 1 ready, 2 sleeping, 3 zombie, 4 stopped |
| `SYS_GETUID` / `SYS_SETUID` | A = uid | | only root (uid 0) may change uid |
| `SYS_MOUNT` | A = drive 9–11, r0 = directory | | |
| `SYS_UMOUNT` | r0 = mounted directory | | |
| `SYS_MNTINFO` | A = entry, r0 = 34-byte buffer | | drive (0 = RAM disk), type, path |
| `SYS_DISKIO` | A = drive 9–11, X = op, r0, r1 | | raw sector access to an **unmounted** drive (used by `format`) |

## Files, pipes and the console

- A process has **8 file descriptors**. The whole system has 24 open files and 4 pipes.
- Paths are Unix paths: `/home/notes`, `../src`, relative to the current directory. A name is at most 14 characters.
- `/dev/console` is the screen and keyboard and `/dev/null` discards. `/tmp` is a RAM disk when an REU or GeoRAM is present.
- Reading fd 0 when it is the console blocks until the user presses RETURN, and returns the line with its `10`. CTRL-D on an empty line is end of file.

**Raw console mode** is for full-screen programs like `edit`. Call `SYS_CONMODE` with A = 1, and each `SYS_READ` then returns one key with no echo. Cursor keys arrive as control codes: `K_UP`, `K_DOWN`, `K_LEFT`, `K_RIGHT`, `K_HOME`, `K_CLR`, `K_DEL`, `K_RET`, F1–F8 as `$85`–`$8C`, CTRL-letters as `$01`–`$1A`. Set mode 0 before you exit. The kernel also drops raw mode when the process that set it exits. In raw mode CTRL-Z is an ordinary key, and RUN/STOP still interrupts.

**Output escapes** (write them to the console like normal bytes):

| Bytes | Effect |
|---|---|
| `ESC = row+32 col+32` | move the cursor (row 0–24, column 0–39) |
| `ESC R` / `ESC r` | reverse video on / off |
| `ESC K` | clear to the end of the line |
| `ESC C fg+32 bg+32 border+32` | set colours (C64 colour numbers 0–15) |
| `12` (form feed) | clear the screen |
| `8` | backspace |

## Processes, signals and job control

`SYS_SPAWN` starts a child and `SYS_WAIT` collects its exit code, like `fork`+`exec` and `waitpid` rolled into two calls. A child keeps its process-table slot as a zombie until it is waited for, so always wait for your children.

```asm
        lda #<path              ; run "ls -l" with our stdin/stdout
        sta r0
        lda #>path
        sta r0+1
        lda #<args
        sta r1
        lda #>args
        sta r1+1
        lda #0                  ; stdin = our fd 0
        ldx #1                  ; stdout = our fd 1
        ldy #0                  ; foreground
        jsr SYS_SPAWN
        bcs error
        ldx #0
        jsr SYS_WAIT            ; A = pid (from spawn), X = exit code
        ...
path:   .byte "/bin/ls", 0
s_l:    .byte "-l", 0
args:   .word path, s_l, 0
```

**Signals have no handlers in Breadbin.** A signal kills the process (exit code `128 + signal`), with three exceptions:

| Signal | Effect |
|---|---|
| `SIGINT` (2) | sent to the foreground job by RUN/STOP |
| `SIGKILL` (9), `SIGTERM` (15) | kill |
| `SIGPIPE` (13) | sent when you write to a pipe whose reader has gone |
| `SIGTSTP` (20) | **stops** the process. CTRL-Z sends it to the foreground job |
| `SIGSTOP` (19) | stops the process |
| `SIGCONT` (18) | continues a stopped process |

A stopped process is not scheduled. `ps` shows it as `T`. The shell commands `fg` and `bg` continue it in the foreground or the background. A background job that reads from the console is stopped too (Unix's `SIGTTIN`), so it can't steal the shell's keys. A program doesn't need to do anything to support job control.

## The user library

Link `build/lib/breadbin.lib` (the Makefile does this) and `.import` what you need. Strings are NUL-terminated and addresses are passed in A (low) / X (high).

| Routine | In | Out |
|---|---|---|
| `print` / `eprint` | A/X = string | writes to stdout / stderr |
| `fprint` | A/X = string, Y = fd | |
| `putc` / `eputc` | A = char | one byte to stdout / stderr |
| `fputc` | A = char, Y = fd | |
| `newline` | | writes `10` to stdout |
| `print_dec` | A/X = 16-bit number | decimal on stdout |
| `print_dec_w` | A/X = number, Y = width | right-aligned decimal |
| `print_hex` | A | two hex digits |
| `parse_dec` | A/X = string | A/X = value; carry set if not a number |
| `strlen` | A/X = string | A = Y = length |
| `strcmp` | `lp1`, `lp2` = strings | Z set if equal |
| `argn` | A = index | A/X = argv[index]; carry set if out of range |
| `basename` | A/X = path | A/X = the part after the last `/` |
| `set_input` | A = fd | selects the fd that `getc` reads |
| `getc` | | A = next byte (buffered 256 at a time); carry set at end of file |
| `open_or_die` | A/X = path, Y = flags | A = fd; on error prints `prog: path: message` and exits 1 |
| `perr` | A = errno, X/Y = extra string (or 0/0) | prints `prog: extra: message` to stderr |
| `errstr` | A = errno | A/X = the message text |
| `exit` | A = code | |
| `pw_find_uid` / `pw_find_name` | A = uid / A/X = name | look up `/etc/passwd` (`pw_name`, `pw_uid`, `pw_home`) |

The library uses zero page `$30–$3F` and about 270 bytes of BSS.

## Building: ca65 on your computer

The easy way is inside the Breadbin tree: put `name.s` in `src/bin/` and run `make`. It is assembled, linked, made relocatable and put on the disk as `/bin/name`.

By hand, for a program that lives elsewhere:

```sh
ca65 prog.s -o prog.o
ld65 -C src/prog.cfg -S 0   -Ln prog.lbl -o prog.0 prog.o build/lib/breadbin.lib
ld65 -C src/prog.cfg -S 256              -o prog.1 prog.o build/lib/breadbin.lib
python3 tools/cx.py prog.0 prog.1 prog.lbl prog
```

To put the result on a disk, copy it into `build/root/bin/` (or `home/`) and run `make` again, or rebuild the image with `tools/mkimage.py`. Breadbin can also read programs from a c64fs disk in drive 9 (`mount 9 /mnt` and `/mnt/prog`).

### How relocation works (and the one rule it imposes)

The program is linked twice, at `$0000` and at `$0100`. Every byte that differs between the two builds by exactly one is the high byte of an address, and its offset goes into the relocation table. When the loader puts the program at page `$xx`, it adds `$xx` to each of those bytes. The executable format (CX) is:

```
"CX"  version(1)  image size(2)  bss size(2)  reloc count(2)  image  reloc offsets(2 each)
```

This catches everything ordinary code does: `jsr`, `jmp`, absolute addressing, `#<label`, `#>label`, `.word label`, and tables of `.lobytes`/`.hibytes`. **The rule:** don't compute something from an address other than its low or high byte. `.byte >(table*2)`, or an address used as a loop count, changes by something other than one between the two builds, and `cx.py` refuses the program with an error that names the offset. Low bytes never change, because the program is always loaded on a page boundary, so `.align 256` tables are fine.

## Building: `as` on the C64

`as source output` is a two-pass assembler that runs on Breadbin itself and writes a CX executable directly.

- Syntax: `label: lda #<msg ; comment`, `name = expr`, `.byte 1, "text", >addr`, `.word expr`, `.res count`.
- Operands: `#imm #<expr #>expr zp abs ,x ,y (zp,x) (zp),y (abs)`. Expressions: `$hex %bin decimal 'c'`, labels, `*`, `+` and `-`.
- Predefined: `sys_exit` … `sys_fg` (every system call), `r0 r1 r2`, `argv argc`, `o_rdonly o_wronly o_rdwr o_creat o_trunc o_append`.
- Limits: 6 KB of output, 180 symbols, no macros or include files. The user library can't be linked, so programs call the system directly (see `/home/hello.s`).

It's a good tool for small utilities written on the machine. For anything big, use ca65.

## Porting a Unix tool

Most classic text tools (`rev`, `tr`, `uniq`, `nl`, `tee`, `cut`, `tail`, `sort` on small files) map directly. The shape is always the same:

1. **No file arguments: filter standard input.** With file arguments, open each in turn (`open_or_die`).
2. **Read bytes with `getc`**, which buffers 256 bytes per system call. Calling `SYS_READ` for every byte is slow.
3. **Write with `putc`/`print`.** Each call is a system call, so for large output collect a line in a buffer and `SYS_WRITE` it at once.
4. **Errors go to fd 2** via `perr`. Exit 0 on success and 1 on error.
5. **Size buffers in BSS.** Every page you reserve is memory another process can't have. The pool is 30 KB for everything that is running.
6. **Stay small on the stack.** Use BSS for anything bigger than a few bytes.

[`docs/examples/rev.s`](examples/rev.s) is a complete port of `rev`: about 60 lines, and 1.4 KB as an executable. Copy it to `src/bin/rev.s`, run `make`, and:

```
/ $ echo hello | rev
olleh
/ $ ls /bin | rev | head -3
```

Things that need more thought on a C64:

- **No floating point and no 32-bit arithmetic.** Keep 16-bit counters, or 24-bit where sizes can exceed 64 KB (`wc` does this).
- **Large inputs.** `sort` can't hold a 30 KB file in memory. Write runs to `/tmp` (fast with an REU or GeoRAM) and merge them.
- **Options.** Parse `-x` flags from `argv` by hand; there is no `getopt`. Look at `src/bin/head.s` or `grep.s`.
- **Regular expressions.** `grep` does fixed strings. A small backtracking matcher (`^ $ . * [...]`) fits in about 1 KB.
- **Time.** `SYS_TIME` gives jiffies since boot. The time of day is in the CIA 1 TOD registers (`$DC08–$DC0B`, BCD, 12-hour with a PM bit). Read hours first and tenths last, and write 12 o'clock with the PM bit inverted: the 6526 flips it. On a C64 without a working TOD input (DC power supplies), the kernel keeps those registers ticking itself.

## Limits

| | |
|---|---|
| Processes | 12 (init, login and the shell use 3) |
| Memory for programs | 30 KB pool, in 256-byte pages |
| Stack per process | about 130 bytes |
| Open files | 8 per process, 24 in total |
| Pipes | 4, 256 bytes each |
| Arguments | 16 words |
| Console line | 79 characters |
| File name | 14 characters |
| File size | 35 KB on c64fs |
| Disk drives | 8 (boot), 9, 10, 11 |
| RAM disk | REU (up to 8 MB detected) or GeoRAM (up to 4 MB); `/tmp` uses the first 512 KB |
