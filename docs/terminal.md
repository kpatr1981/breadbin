# The serial terminal: a second user on /dev/ttyS0

With a SwiftLink or Turbo232 cartridge, Breadbin has two terminals:

- **The console:** the C64's screen and keyboard.
- **The serial line:** `/dev/ttyS0`, at 9600 baud, 8N1.

When `/etc/passwd` exists, `init` runs a `login` on each, so two people can work at once: one at the C64 and one at a PC terminal (or over TCP in VICE). Each has their own shell, jobs, CTRL-C and CTRL-Z.

This page covers using it. [design-tty.md](design-tty.md) explains how it works inside.

## What you need

| | |
|---|---|
| Cartridge | SwiftLink or Turbo232 (a 6551 ACIA at `$DE00`, interrupting through NMI) |
| Not at the same time | GeoRAM: it also sits at `$DE00`. An REU (at `$DF00`) is fine. |
| Far end | any ANSI/VT100 terminal |
| Flow control | RTS/CTS, recommended (see [Limits](#limits)) |

At boot the console shows whether the line is on:

```
serial: on, /dev/ttyS0 9600 8n1
```

If Breadbin is using GeoRAM, it shows `serial: off (georam is at $de00)`. With no card, there is no `serial:` line at all.

## Trying it in VICE

VICE emulates the SwiftLink and joins its serial line to a TCP connection. **VICE connects out**, so start the listener first.

1. Start the listener in one terminal window. It becomes the serial terminal:
   ```
   socat -,raw,echo=0 tcp-listen:25232
   ```
   - `raw` sends each key at once.
   - `echo=0` stops your terminal echoing what you type, because Breadbin echoes it itself.
2. Start the C64 in another window:
   ```
   make run-tty
   ```
   or by hand, here with an REU:
   ```
   x64sc +georam -reu -reusize 512 -acia1 -acia1base 0xde00 -acia1irq 1 -acia1mode 1 \
         -myaciadev 0 -rsdev1 127.0.0.1:25232 -rsdev1baud 9600 -autostart build/breadbin.d64
   ```
3. A few seconds after the boot, `breadbin login:` appears in the socat window. Log in as `root` or `user`.

Notes:
- `+georam` makes sure GeoRAM is off even when your saved VICE settings turn it on. With GeoRAM on, VICE never shows the SwiftLink to the C64.
- VICE connects only once, at boot. If it is restarted, restart socat too, and before it.
- socat in raw mode passes CTRL-C on to the C64, so close its window to stop it.

## On a real C64

- **SwiftLink or Turbo232 with a null-modem cable** to a PC serial port. Use a terminal program (PuTTY, minicom, screen) set to 9600 baud, 8N1, RTS/CTS flow control, VT100/ANSI emulation.
- **A WiFi modem** on the cartridge's port gives telnet access from the network.

## What works there

Everything that works with lines of text:
- the shell, with pipes, redirections, `&` jobs, history (cursor up and down) and TAB completion
- `ls`, `cat`, `grep`, `more`, `ps`, `kill`, `passwd`, `basic`, `as` and the rest

`more` reads its keys from `/dev/tty`, the terminal it runs on, so a remote `more` waits for the remote keyboard.

The full-screen programs, `edit` and `htop`, run only on the console. On the serial line they stop at once:

```
/ $ edit notes
edit: needs the console
```

and exit with status 1. They check `isatty`, which tells them which terminal they're on (below). Cursor positioning is still translated for other programs that use it.

### Keys

| On the remote keyboard | Becomes |
|---|---|
| Enter (CR, LF or CR LF) | RETURN |
| Backspace (DEL or BS) | DEL |
| cursor keys (`ESC [ A`/`B`/`C`/`D`) | cursor up / down / right / left |
| CTRL-C | interrupts this terminal's foreground job (SIGINT) |
| CTRL-Z | stops it (SIGTSTP), except in raw mode, where it is an ordinary key, as on the console |
| CTRL-D on an empty line | end of input |
| CTRL-U | throws away the line being typed |
| other `ESC [ …` sequences (Home, End, F-keys, PgUp…) | ignored |
| bytes `$80` and up | ignored (7-bit ASCII) |

RUN/STOP and RESTORE on the C64 only ever affect the console's jobs. CTRL-C on the serial line only affects the serial line's.

### What the screen gets

Programs write the same bytes as on the console. The serial line translates them:

| A program writes | The terminal receives |
|---|---|
| LF | CR LF |
| 8 (backspace) | `\b \b` (erases the character) |
| 12 (form feed, `clear`) | `ESC [ H` `ESC [ 2 J` (cursor home, clear the screen) |
| `ESC = row col` (cursor to row 0–24, column 0–39) | `ESC [ row+1 ; col+1 H` (rows and columns past the screen are clamped, as on the console) |
| `ESC R` / `ESC r` | `ESC [ 7 m` / `ESC [ m` (reverse video on / off) |
| `ESC K` | `ESC [ K` (clear to the end of the line) |
| `ESC C fg bg border` | nothing: colours are dropped (`theme` has no effect remotely) |

## Logging out, hanging up

- **`exit`** in the remote shell ends the session, and `init` shows `login:` again.
- **Losing the carrier** (DCD drops, for example the modem hangs up): every process of the serial line gets SIGHUP, and a new login starts.

## For programs

| | |
|---|---|
| `isatty(fd)` | carry clear for both terminals; **X** says which (0 console, 1 serial line) |
| `conmode` | acts on the terminal of your standard input |
| `/dev/tty` | always the terminal you run on |
| `/dev/ttyS0` | the serial line itself (`ENODEV` without the cartridge) |

See [programming.md](programming.md).

## Limits

- **No file owners or permissions.** Every user can read, change or delete every file. c64fs inodes have no owner field yet.
- **One serial line, 9600 baud.** A full 40×25 screen takes about a second to draw.
- **Typing during disk activity.** While the disk is busy, the serial line is paused for a few jiffies at a time (RTS off) so that its interrupts can't spoil the disk's timing. A terminal with RTS/CTS waits; one without it (VICE's TCP line) can lose characters typed during long disk work. Typing at normal speed is fine; pasting a lot at once while the disk runs is not.
- **RESTORE during a disk transfer** may be ignored. Press it again.
- **Memory:** every logged-in user has a shell, about 20 pages of the 125-page program pool and 2 of the 12 process slots.
- **Not with GeoRAM** (same address as the cartridge).
