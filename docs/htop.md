# htop: CPU, memory and process usage

`htop` is a small full-screen monitor in the spirit of Unix `top`/`htop`. It
shows how busy the CPU is, how much of the program pool is in use, and each
process's share of the CPU, and redraws itself in place about every 2 seconds.

```
cpu [████████████████] 100%
mem [████............]  23%   7/31k
reu [██..............]  12%   56/448k
tasks 4/12  pg 96/125  up 1:23

  pid ppid st  mem cpu% name
    0                 0 idle
    7    3  r    6    0 htop
    5    3  r    1  100 burn
    3    1  s   20    0 sh
    1    0  s    2    0 init

 r refresh  q quit
```

| Key | Effect |
|---|---|
| `r` | redraw now and restart the counters |
| `q` | quit (clears the screen and gives the console back) |

RUN/STOP also ends it, like any foreground program.

## What the screen shows

| Line | Meaning |
|---|---|
| `cpu` | share of the last round's ticks that went to a process (100 − idle) |
| `mem` | the program pool, like `free`: the bar and percentage are the pages in use, the numbers used/total KB (pages / 4) (`SYS_MEMINFO`) |
| `reu` / `geo` | only with an REU or GeoRAM: how full the `/tmp` RAM disk on it is, as a bar and percentage, then used/total KB (`SYS_FSINFO`). The swap area and the drive 8 copy that share the expansion aren't included: the kernel reports no usage for them. Without an expansion this line is empty. |
| `tasks` | processes in use / the maximum (12); `pg` free / total pages of the program pool; `up` the time since boot, h:mm (`SYS_TIME`, the jiffy count divided by 60 three times; it wraps after about 77 hours) |
| `pid 0 idle` | ticks in which no process was ready to run |
| process rows | as `ps`: pid, parent, state (`r` ready, `s` sleeping, `z` zombie, `T` stopped), pages, then `cpu%` and name |

## How it measures CPU use

The kernel keeps no CPU time per process, so `htop` measures it from user
space, without any kernel change. Each turn it reads the clock (`SYS_TIME`),
sleeps one jiffy (1/60 s) and reads the clock again when it wakes:

1. **Woke on time** (1 jiffy passed): when `htop`'s sleep ends, the
   scheduler runs it at once unless another process holds the CPU. So
   nothing else wanted the CPU, and the jiffy counts as **idle** (pid 0).
   The process table isn't read at all.
2. **Woke late** (1 + d jiffies passed): another process held the CPU for
   that time. `htop` reads the process table (`SYS_PROCINFO`) for a process
   in state `r` (running, or waiting for the CPU) and gives it **all** the
   jiffies that passed. With several ready processes they go round robin,
   starting after the one that got the last ones, the way the scheduler
   hands out its slices. If none is ready any more, they count as idle.
3. `htop` never counts itself.

One wake-up counts for at most 32 jiffies (after a long disk transfer,
which runs with interrupts off, it can wake much later).

All counters are **8 bits**. The tick counter is the sum of the others, so no
counter can be larger than it. When it reaches **128** (about 2.1 s at 60 Hz;
at most 159, with the 32-jiffy cap),
`htop` redraws, works out each share and resets every counter to 0. On an idle
machine this is the idle counter reaching 128.

Percentages are `count * 100 / ticks`, rounded:

- `count * 100` is built from shifts: `count*64 + count*32 + count*4`.
- Then `ticks / 2` is added, to round.
- Then a fast 16-by-8-bit divide (`div8`) gives the result in 8 shift-subtract
  steps. The quotient always fits 8 bits because `count <= ticks`.

The `/tmp` line works the same way. Block counts are 16 bits (a big REU has
thousands), so used and total are shifted right together until the total fits
8 bits, and then go through the same 8-bit percentage. The bars are 16 cells:
`(percent * 16 + 50) / 100`, with the same `div8`.

## Limitations

- **Busy time is found by timing.** A late wake-up means another process
  held the CPU; which one is found by looking for a ready process at that
  moment. One that ran and blocked again before `htop` looked counts as idle.
- **Short bursts are invisible.** A process that wakes, works for less than a
  jiffy and blocks again before `htop` is due doesn't delay it, so that jiffy
  counts as idle. Something that does that often (a fast pipe stage, `count`)
  can show 0% while it does use some CPU.
- **Resolution is one jiffy** (one jiffy in a 128-jiffy round is about 0.8%).
- **htop costs a little CPU itself.** On an idle machine it only reads the
  clock and sleeps; it reads the process table only after a late wake-up. Its
  own time isn't shown (it gets 0%).
- **New processes wait a round.** Only the slots seen at the last redraw are
  sampled. A process started mid-round shows 0% until the next redraw (or `r`).
  A slot reused by a new process within a round is not counted.
- **Kernel time goes to the caller.** Time spent in a system call, including
  disk I/O, counts for the process that made the call. The same goes for the
  interrupt work it happens to run during.
- **Disk waits can stretch a round.** Fast-loader and serial-bus transfers run
  with interrupts off, so sleeps (and sampling) are delayed while a drive is
  busy. A round then takes longer than 2 s.
- **Keys:** Breadbin has no non-blocking read, so `htop` peeks at the KERNAL
  keyboard-buffer count (`$C6`, read only) before calling `SYS_READ`. A key
  that raw mode drops (one with no ASCII mapping) leaves `SYS_READ` waiting.
  `htop` then freezes until the next key is pressed.
- **The console only.** On the serial line (`/dev/ttyS0`) it prints
  `htop: needs the console` and exits 1.
- **The bars use reverse video.** In a text dump of the screen (like the VICE
  tests make) the filled part looks blank.
- **The REU line is only `/tmp`.** The swap area and the copy of drive 8 also
  live in the expansion, but the kernel has no call that reports their use.
- **Fixed layout:** 40 columns, at most 12 process rows (the kernel's maximum).
  The process name shows up to 10 characters, and there is no user column,
  because looking up `/etc/passwd` every redraw would mean disk I/O.

## A more accurate way (not done)

Most of these limits go away with a kernel counter. `clk_tick` runs exactly
once per tick, both from the timer interrupt and from the serial-bus waits.
There, an `inc p_cpu,x` for the running slot (`cur`, or a 13th "idle" counter
when `cur = $ff`) would count real CPU ticks. A new `SYS_CPUINFO` call would
copy the counters and clear them, at the cost of about 30 bytes of kernel code,
13 bytes of data and one jump-table entry. `htop` would then only sleep, read
and draw.
