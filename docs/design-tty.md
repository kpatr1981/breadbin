# Serial terminal: design

How `/dev/ttyS0` works inside. [terminal.md](terminal.md) is the user's guide. The code is `src/kernel/tty.s`, plus one `jsr` hook in each kernel routine it extends.

## The constraint: memory

Kernel RAM (`$8500-$CEFF`) has about 34 free bytes, and kernel zero page none: version 0.7 gave the space back to programs (125 pages). So the serial line lives almost entirely elsewhere, and touches the existing code only through 3-byte `jsr` hooks.

| Where | Size | What |
|---|---|---|
| Kernel RAM | 33 bytes | 12 `jsr` hooks (one replaces an instruction of the same size), nothing else |
| `LOWDATA`: `$02A7-$02FF` (unused by the KERNAL) | ≤ 89 bytes | variables, `tty_of`, `tty_irqhook`, `tty_athook`, `tty_rdhook` |
| `LOWCODE`: `$0334-$03FF` (the cassette buffer; Breadbin never uses tape) | ≤ 204 bytes | the other hooks |
| `JTCODE`: the end of the `$CF00` jump table page | ≤ 88 bytes | `tcall`, `tty_hold`, `tty_read`/`tty_write` |
| `HICODE` / `TTYBSS` (under the KERNAL ROM) | ~1.6 KB + 355 bytes | the driver, the rings, the line discipline, the ANSI translation |

`LOWCODE` and `LOWDATA` are copied down by `tty_boot` before kmain sets the NMI vector. `JTCODE` is copied up with the jump table page. `HICODE` is copied with the swap code.

The hooks don't change what the code around them does when there is no card:

| Hook | In | Replaces / adds |
|---|---|---|
| `tty_nmihook` | `main.s` `nmi_handler` | first: the ACIA, else RESTORE as before |
| `tty_irqhook` | `proc.s` IRQ | every jiffy: `tty_tick` |
| `tty_sigchk` | `proc.s` `sigint_fg` loop | **replaces** its `lda p_state,x` (same size) |
| `tty_chrhook` | `file.s` open of a device | `/dev/ttyS0`, `/dev/tty` |
| `tty_athook` | `file.s` `sys_isatty` | serial line is a terminal; X = which |
| `tty_rdhook`, `tty_wrhook` | `file.s` `sys_read`, `sys_write` | `FT_TTY` |
| `tty_cmhook` | `con.s` `sys_conmode` | stdin on the serial line: its mode |
| `tty_hold` ×4 | `iec.s` `ie_cmd`, `ie_send`, `iecin`; `blk.s` `fr_recv` | pause the line for the disk |

## Calling code under the ROM: `tcall`

`tcall` takes A/X = the routine and Y = its argument. It runs the routine with interrupts off and the ROM switched out (`MAP_RAM`), and returns its A with Z/N set.

Code there may call kernel code that doesn't use the KERNAL (`wakeup`, `sigint_fg`), and the low hooks. It must never sleep. So `tty_read`/`tty_write` stay in `JTCODE`: they call `tty_rw` for one pass, and if it returns 0 they `block_on CH_TTY` and try again. Their state (`sb4`, `sb5`, `s0`, `s1`) is saved per process.

## Which terminal a process is on: `tty_of`

There is no per-process table: there's no RAM for one.

`tty_of` (X = slot) looks at the process's standard input:
- the serial line means terminal 1
- the console means terminal 0
- anything else (a pipe, a file, closed): it asks the parent, up to `init`, whose parent is `$FF` and means the console

So everything started from the remote shell, pipelines and `&` jobs included, belongs to terminal 1.

**Only live processes are ever followed.** `proc_exit` gives orphans `init` as their parent, so a live process's chain always ends. A free slot's parent number is stale, and two stale slots can point at each other, so callers check `p_state` first.

`tty_of` keeps X on the stack, not in a variable: the NMI (RESTORE) may call it while another call is running.

## Signals

`sigint_fg`, `sigtstp_fg` and `sigkill_fg` act on the terminal in `fg_tty`:
- 0 normally: RUN/STOP, CTRL-Z on the C64, RESTORE.
- `tty_tick` sets it to 1 around the calls for CTRL-C and CTRL-Z typed on the serial line, then back to 0.

`tty_sigchk`, in place of the loop's `lda p_state,x`, makes a process of the other terminal look free, so it is passed over.

RESTORE while a serial-line process is the one running doesn't kill that process. It is deferred to the IRQ like RESTORE in the kernel, and the IRQ only kills console processes.

CTRL-C and CTRL-Z never reach the receive ring: `tty_nmi` turns them into flags, so they work even when nothing reads. In raw mode CTRL-Z is an ordinary key, as on the console.

## Interrupts

The SwiftLink pulls NMI. `tty_nmihook` reads the ACIA status, which releases the chip's line:

- **Bit 7 set:** `tty_nmi` runs under the ROM and serves the chip until bit 7 reads clear. The NMI input reacts to an edge, so leaving an interrupt pending would block every later NMI, RESTORE included. `tty_nmihook` then returns from the NMI itself.
- **Bit 7 clear while a disk hold is on:** a late ACIA NMI (the hold just turned its interrupt off), so it is ignored.
- **Otherwise:** RESTORE, handled by the original code.

An NMI can interrupt the IRQ in the middle of `wakeup`. So `tty_nmi` only raises flags (`tf_wake`, `tf_int`, `tf_stp`, `tf_hup`), and `tty_tick`, from the IRQ, acts on them.

The two 128-byte rings each have one producer and one consumer:

| Ring | Filled by | Emptied by |
|---|---|---|
| receive | `tty_nmi` (`rx_head`) | `tty_rw` (`rx_tail`) |
| send | `tty_rw` (`tx_head`) | `tty_nmi` (`tx_tail`) |

The transmit interrupt is on only while there is something to send.

## Disk transfers: holds

The fast read (`fr_recv`) and the serial bus code are timed to the cycle; an NMI inside them corrupts a transfer or misses a clock edge.

- Before each step, they call `tty_hold`. It sets `hold_cnt = 3` and command `$03`: receive interrupt off and RTS off, so the other side should stop. The chip keeps one received byte.
- `tty_tick` turns the chip back on 3 quiet jiffies after the last step.
- While `hold_cnt` is set, nothing else writes the command register.

A far end without RTS/CTS (VICE's TCP line) can lose bytes sent during disk work.

## Line discipline

**Cooked:**

| Typed | Effect |
|---|---|
| CR, LF, or CR LF | ends the line |
| BS or DEL | erases (echo `\b \b`) |
| CTRL-U | drops the line |
| CTRL-D on an empty line | end of file |

Lines are 79 characters at most. Echo needs room in the send ring; when there is none, the reader waits.

**Raw** (`conmode` with stdin on the serial line): one key per read, no echo.

| Typed | Key |
|---|---|
| CR / LF | `K_RET` |
| DEL | `K_DEL` |
| `ESC [ A-D` | `K_UP`, `K_DOWN`, `K_RIGHT`, `K_LEFT` |
| other `ESC [` sequences | dropped |

Raw mode belongs to the process that set it. When that process is gone (`raw_alive`, checked on every read), the line is cooked again. This replaces a hook in `con_release`.

## Output translation

| Program writes | Sent |
|---|---|
| LF | CR LF |
| 8 | `\b \b` |
| 12 | `ESC[H ESC[2J` |
| `ESC = row col` | `ESC[row+1;col+1H` (clamped to 25×40, like the console) |
| `ESC R` / `r` / `K` | `ESC[7m` / `ESC[m` / `ESC[K` |
| `ESC C fg bg border` | dropped |

One input byte can become up to 8 output bytes (`ESC [ 2 5 ; 4 0 H`), so `tx_room` keeps 8 bytes free.

## Full-screen programs

`edit` and `htop` refuse to run on the serial line: when `isatty(0)` says terminal 1, they print `needs the console` and exit 1. They rely on the C64 keyboard (F-keys, HOME, `htop` peeks at the KERNAL keyboard buffer) and on the 40×25 screen, none of which the far end is guaranteed to have.

## Devices

- **`/dev/ttyS0`:** major 2. `ENODEV` without the cartridge.
- **`/dev/tty`:** major 3, the opener's own terminal. On the console it opens as `/dev/console`.

`mkimage.py` makes both: `--dev ttyS0:2 --dev tty:3`.

## Finding the cartridge

`tty_init` runs after `blk_init`, and not with GeoRAM, whose window is at `$DE00` too. It:
1. writes the control and command registers and reads them back;
2. does a programmed reset (a write to the status register), which clears command bits 0-4.

Plain RAM, or nothing at all, can't do both.

DTR stays off until the end, because VICE opens and closes its TCP line with DTR.

`CTL_SPEED = $1C` is 9600 baud on a SwiftLink (double-speed crystal).

## init

`init` opens `/dev/ttyS0` (only with `/etc/passwd`: the line never gets a shell without a password). It runs `login` on it with `SP_IGNINT | SP_ERR`, and starts it again when it exits. If the open fails, it doesn't try again.

## Not done / not verified

- DCD-based hangup is written but not tested: VICE may not drop DCD when the TCP peer goes away.
- Open ROMs (MEGA65): not checked whether they leave `$02A7-$02FF` and the cassette buffer alone.
- Multi-user safety: c64fs has no owners or permissions.
