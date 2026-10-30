#!/usr/bin/env python3
"""Breadbin's browser demo, an itch.io HTML5 upload: EmulatorJS running the VICE x64sc core on
the free MEGA65 Open ROMs, from the webdemo tool (WEBDEMO_DIR, whose build_core.sh makes kit/).

That core has no drive ROM, so Breadbin boots without a drive: the kernel is the autostarted
.prg, and the boot disk comes preloaded in the REU. breadbin.reu is the .d64 padded to 256 KB
(c64fs block b sits at offset b*256 in both), and the VICE core loads it because it is next to
the .prg once EmulatorJS unpacks breadbin-web.zip.

    python3 tools/webdemo.py WEBDEMO_DIR build/breadbin.prg build/breadbin.d64 OUT_DIR

Writes OUT_DIR (push that folder with butler) and OUT_DIR.zip.
"""
import json
import shutil
import sys
import zipfile
from pathlib import Path

REU_SIZE = 256 * 1024


def page():
    pad = {str(i): {"value": "", "value2": ""} for i in range(30)}   # every key goes to the C64
    opts = {
        "keyboardInput": "enabled",             # EmulatorJS: keys go to the C64, not the pad
        "vice_drive_true_emulation": "disabled",
        "vice_virtual_device_traps": "disabled",
        "vice_ram_expansion_unit": "256kB",
        "vice_retropad_options": "disabled",
        "vice_keyboard_keymap": "symbolic",
    }
    for m in ("a", "b", "x", "y", "select", "start", "l", "r", "l2", "r2", "l3", "r3"):
        opts[f"vice_mapper_{m}"] = "---"
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Breadbin demo</title>
<style>
  :root {{ --bg: #3e31a2; --fg: #a5a5ff; --accent: #ffffff; }}
  html, body {{ margin: 0; height: 100%; background: var(--bg); color: var(--fg);
    font: 13px/1.45 ui-monospace, Menlo, Consolas, monospace; }}
  body {{ display: flex; flex-direction: column; }}
  #game {{ flex: 1; min-height: 0; }}
  footer {{ padding: 6px 16px 8px; text-align: center; }}
  .login {{ color: var(--accent); font-weight: 700; font-size: 14px; }}
  .try {{ margin: 2px 0 4px; }}
  code {{ color: var(--accent); }}
  .credits {{ opacity: .75; font: 11px/1.4 system-ui, sans-serif; }}
  a {{ color: var(--accent); }}
</style></head><body>
<div id="game"></div>
<footer>
  <div class="login">Click the screen, then at <code>login:</code> type <code>root</code> and press Return.</div>
  <div class="try">Try <code>ls /bin</code> · <code>help</code> · <code>cat /home/readme | grep unix | wc</code> ·
  <code>ps</code> · <code>edit /home/notes</code> · <code>basic /home/hello.bas</code>.
  The disk lives in RAM: changes last until you close the page.</div>
  <div class="credits">C64 emulation: <a href="https://vice-emu.sourceforge.io/" target="_blank">VICE</a> in
  <a href="https://emulatorjs.org/" target="_blank">EmulatorJS</a>, on the free
  <a href="https://github.com/MEGA65/open-roms" target="_blank">MEGA65 Open ROMs</a>
  (no Commodore ROM). <a href="LICENSES/SOURCES.txt" target="_blank">Licences and sources</a>.
  Breadbin is MIT: <a href="https://github.com/kpatr1981/breadbin" target="_blank">source</a>.
  Commodore 64 is a trademark of its owner; Breadbin is not endorsed by it.</div>
</footer>
<script>
  EJS_player = "#game";
  EJS_core = "vice_x64sc";
  EJS_gameUrl = "breadbin-web.zip";
  EJS_pathtodata = "data/";
  EJS_paths = {{"emulator.min.js": "data/src/emulator.js", "emulator.min.css": "data/emulator.css"}};
  EJS_color = "#7c70da";
  EJS_startOnLoaded = true;
  EJS_defaultControls = {json.dumps({"0": pad})};
  EJS_defaultOptions = {json.dumps(opts)};
</script>
<script src="data/loader.js"></script>
</body></html>
"""


def main(argv):
    if len(argv) != 4:
        raise SystemExit(__doc__)
    tool, prg, d64, out = (Path(a).resolve() for a in argv)
    kit = tool / "kit"
    if not (kit / "data" / "cores" / "vice_x64sc-wasm.data").exists():
        raise SystemExit(f"webdemo: no {kit}: run build_core.sh in the webdemo tool")
    sys.path.insert(0, str(tool))
    import make_webdemo                         # its licence list and build scripts

    image = d64.read_bytes()
    if len(image) > REU_SIZE:
        raise SystemExit("webdemo: disk image larger than the REU")
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(kit / "data", out / "data")
    with zipfile.ZipFile(out / "breadbin-web.zip", "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("breadbin.prg", prg.read_bytes())
        zf.writestr("breadbin.reu", image + bytes(REU_SIZE - len(image)))
    lic = out / "LICENSES"
    lic.mkdir()
    for name, f in make_webdemo.LICENCES.items():
        shutil.copy(f, lic / name)
    shutil.copy(kit / "SOURCES.txt", lic / "SOURCES.txt")
    (lic / "build").mkdir()                     # the corresponding source of the core
    for f in ("build_core.sh", "strip_roms.py", "romscan.py", "make_webdemo.py"):
        shutil.copy(tool / f, lic / "build" / f)
    shutil.copy(Path(__file__), lic / "build" / "breadbin_webdemo.py")
    (out / "index.html").write_text(page())
    z = out.with_suffix(".zip")
    z.unlink(missing_ok=True)
    with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(out.rglob("*")):
            if f.is_file():
                zf.write(f, f.relative_to(out))
    print(out / "index.html")
    print(z, f"{z.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main(sys.argv[1:])
