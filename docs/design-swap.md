# Swapping to the REU (design)

Item 5 of issue #17. When the program pool runs out of pages, the kernel moves processes that aren't
running into the REU, and moves them back to the same pages when they run again. A shell waiting at its
prompt or for a job, a background job, `init`: none of them needs its pages until the scheduler picks it.

## Why not just "swap the waiting shell"

The shell starts a command first and waits for it afterwards. When the new command needs memory, the
shell is the running process, not a waiting one, and the kernel still reads the command's arguments out
of the shell's memory after the image is loaded. So the process that asks for memory always stays.
Every other process may go.

## Rules

- **A process runs only when its pages are in the pool.** When `sched` picks a ready process that is out,
  `in_core` brings it back first. If its pages are taken, whoever holds them is moved out too. If a page
  is held by something that can't move (a pipe's buffer, or a program being loaded), the process
  waits and `sched` tries another one.
- **Programs are not relocated again:** a process always comes back to the pages it had. Its saved
  context (zero page, stack) is under the KERNAL ROM already, so only its pages move.
- **When an allocation fails** (`alloc_pages`, used by the program loader and `pipe`), the kernel moves
  out the biggest process that isn't the caller, and tries again, until the pages fit or nobody is left.
- **What may move:** a live process (ready, blocked or stopped, not a zombie) other than the caller.
  The kernel never writes into another process's memory: pipes and the console copy into the reader's
  buffer from the reader's own system call, so a blocked process's pages can safely be elsewhere.

## Where things go

| What | Where |
|---|---|
| The swap area | 128 pages (32 KB) at the top of the REU's `/tmp` area: the upper half of bank `rd_banks-1`. `/tmp` is 128 blocks smaller. |
| The swap code and its tables (`sw_map`, `sw_pg`) | The RAM under the KERNAL ROM (`$EC00` on), copied there at boot. Callers switch the ROM out with interrupts off. |
| `PF_OUT` (`$80` in `p_flags`) | Set while the process's pages are in the REU. |
| `sw_on`, `sw_bank`, `in_core`, `alloc_pages` | The resident kernel (about 60 bytes). |

Only with an REU: its DMA moves a page in about 256 cycles, so moving 20 pages takes about 5 ms.
A GeoRAM would need the CPU for every byte, and booting from an REU image (no drive 8) leaves no room,
so in those cases swapping is off and a full pool means `ENOMEM`, as before.

## Costs and limits

- Interrupts are off while pages move: up to about 2 jiffies for the biggest program (125 pages).
- Two ready processes that need the same pages take turns: each switch moves them both. That's slow,
  but they still both run, where before the second one got `ENOMEM`.
- A process that is out and has been killed comes back before it exits.
- At most 128 pages can be out at once.
