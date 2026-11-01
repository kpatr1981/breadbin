# Breadbin: notes for Claude

Breadbin is a small Unix-like OS for the Commodore 64, written in 6502 assembly
(ca65/ld65), shipped as a .d64 and tested in VICE. Read `README.md` for what it
does, `docs/programming.md` for the system calls and memory map, and
`docs/filesystem.md` for c64fs. Planned work: `docs/design-timestamps-d81.md`.

## Layout

- `src/kernel/` the kernel (`k.inc` holds its constants; `KSTART` there is authoritative)
- `src/bin/` one file per command; a new `name.s` is built and put in `/bin` automatically
- `src/lib/` the user library linked into programs
- `include/breadbin.inc` system call numbers and constants for programs
- `rootfs/` files copied onto the boot disk (`/etc/help`, `/etc/passwd`, ...)
- `tools/` `mkimage.py` (builds the disk image), `cx.py` (relocatable executables), `ptest.py` (parallel test runner), `vicetest.py`
- `tests/` VICE system tests (`test_*.py`) and test programs (`progs/`)

## Build and test

- `make` builds `build/breadbin.d64` and prints the blocks free. `make run` / `make run-reu` boot it in VICE.
- After a change, run only the tests for that change:
  `make build/breadbin-test.d64 && python3 -m unittest -v tests.test_features.Touch`
  (or one test: `tests.test_x.Class.test_y`). Each class boots its own VICE.
- The full suite (`make test`, about 40 minutes, parallel) runs once, at the end of a batch of work, not after each fix.
  `python3 tools/ptest.py --failed` reruns only what failed. Release checks also run `make test-ntsc` and `make test-openroms`.
- Don't rebuild `build/` while a full run is going: the tests copy their images from it.
- `make test-host` runs the fast host tests (image builder, relocation), no VICE.

## Rules

- **RAM is the scarce resource, not disk.** Programs need free pages to run (`as`, `edit`, `basic`, `fsck` each need 53-66 pages).
  The kernel must not grow at the expense of the program pool. Find room in RAM under the KERNAL ROM (`$E000-$FFFF`,
  reads need `$01=$35` with `sei`), by shrinking resident programs, or in the REU. After a kernel change, check `free` and that `as` still runs.
  Moving the kernel start means changing `KSTART` in `k.inc` and `KRAM` in `src/kernel.cfg` together.
- **Drive I/O goes through `src/kernel/iec.s`,** Breadbin's own serial bus driver. Never use the KERNAL's
  OPEN/CHKIN/CHKOUT/CHRIN/CHROUT for drives: the MEGA65 Open ROMs get channel I/O wrong
  (CIOUT sends $00 after the first byte, TKSA corrupts the secondary address, OPEN sends EOI early).
  The KERNAL is still used for the screen and keyboard.
- **Fast reads** run code inside the 1541 (`src/kernel/drive.s`, uploaded to `$0500`) and clock bytes out with `fr_recv` in `blk.s`.
  Any change to that handshake must be checked by reading blocks both ways (fast and slow) and comparing: a boot alone
  looks fine with a corrupted last byte. The C64 side must only ever wait longer than needed. The drive code must stay under 256 bytes.
  On a timeout the kernel falls back to `U1` reads, which keeps SD2IEC working.
- **Disk format changes** touch four places that must agree: the kernel, `tools/mkimage.py`, `src/bin/fsck.s` and `src/bin/format.s`.
- **Programs:** zero page `$23-$2F` is the program's own; `$30-$3F` belongs to the user library; `$08-$1F` and `$40+` are the kernel's.
  Errors go to stderr with `perr`, usage lines with `eprint`, and the exit code is non-zero on failure.
  Output must fit a 40-column screen.
- **New commands** also go in the README's command list and in `rootfs/etc/help`, with tests.

## Working together

Two people work on this repo, each with their own Claude session. They share what they know through this file,
`docs/` and the git history, not through Claude's local memory, which stays on each machine.

- Collaborators switch on `tools/claude-sync.sh` in their own `.claude/settings.local.json` (git ignores it, so
  nobody else who clones this public repo runs it). It runs at session start and before every prompt: it fetches,
  fast-forwards the current branch, and prints new commits and, if it changed, the new `CLAUDE.md`. When that
  output appears, the new `CLAUDE.md` text replaces the one loaded at session start. The settings to add:

  ```json
  {
    "hooks": {
      "SessionStart": [
        { "hooks": [ { "type": "command", "command": "sh \"$CLAUDE_PROJECT_DIR/tools/claude-sync.sh\"", "timeout": 30 } ] }
      ],
      "UserPromptSubmit": [
        { "hooks": [ { "type": "command", "command": "sh \"$CLAUDE_PROJECT_DIR/tools/claude-sync.sh\"", "timeout": 30 } ] }
      ]
    }
  }
  ```
- Lasting rules and lessons go here, in a commit of their own (`docs: CLAUDE.md ...`), pushed straight away so the
  other session picks them up. Keep it short: no session notes or status.
- Plans and designs go in `docs/`; who does what goes in GitHub issues.

## Commits

- One feature or fix per commit, with its tests. Message style: `feat: ...`, `fix: ...`, `test: ...`, `build: ...`, `docs: ...`,
  lower case, saying what changed for the user.
- Work on a branch and open a pull request into the current release branch (`release-0.4`).

## Debugging

- VICE monitor: `chis` after a breakpoint shows recent CPU history; `device 8:` then `m 0200 022f` shows the drive's command buffer.
