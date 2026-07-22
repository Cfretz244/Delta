# Getting Started with the Delta Stack

This is the from-scratch bootstrap guide for `delta-stack` — the unified build environment
for a fork of the [Delta](https://github.com/rileytestut/Delta) iOS emulator whose headline
feature is **GameCube emulation on iPhone without JIT**: PowerPC game code is statically
recompiled ahead-of-time (AOT) to C, compiled to native ARM64, and linked into Dolphin,
because iOS prohibits `MAP_JIT`. If you can read this file locally, you have the workspace
root; everything below happens inside it.

Deep-dive docs live next to the code (this guide links to them at the end). This file gets
you from a blank Mac to the app running a game on a phone.

## 1. What you need

**Hardware/OS**
- Apple Silicon Mac (the AOT toolchain and Dolphin build are ARM64-only here).
- An iPhone for deployment (device testing is the point; the Simulator is not a target).
  Older/128GB phones work but watch free space — disc images are GB-scale.

**Software**
- Xcode 16+ (with an Apple Developer identity for device signing — free personal team OK).
- Homebrew packages: `brew install cmake qt xcodegen`
  - XcodeGen pinned baseline: **2.45.2**. A different version regenerates the project with
    spurious diffs — if you must upgrade, commit the regenerated pbxproj once, deliberately.

**Access**
- An SSH key added to GitHub with access to `Cfretz244/Delta`, `Cfretz244/GCDeltaCore`
  (private), and `Cfretz244/dolphin`.

**Un-versioned assets (get these from an existing developer / the off-machine backup)**
- Disc images → `Cores/GCDeltaCore/isos/` — filenames and sha256 pins are recorded in
  `Cores/GCDeltaCore/games.conf`. The pins are enforced; a different rip will not build.
- Gameplay traces + CFG databases → `Cores/GCDeltaCore/traces/` — per-game filenames also
  in `games.conf`. Losing traces means re-playing the games on macOS to recollect them,
  so treat the backup as precious.

## 2. Clone

```bash
git clone --recurse-submodules -j8 git@github.com:Cfretz244/Delta.git delta-stack
cd delta-stack
```

Two known warts, both harmless:

1. `git submodule update --init --recursive` errors on
   `External/Harmony/Backends/Dropbox/SwiftyDropbox` — that pinned commit no longer exists
   upstream. Ignore it; the app builds SwiftyDropbox from the committed `Pods/`, and that
   nested submodule is Harmony-standalone dev scaffolding only.
2. Clones leave submodules detached. This stack's discipline is **never work detached**:

```bash
git -C Cores/GCDeltaCore checkout main
git -C Cores/GCDeltaCore/dolphin checkout master
git -C Cores/DeltaCore checkout delta-stack   # forked DeltaCore lives on this branch
```

Optionally add upstream remotes (e.g. `https://github.com/dolphin-emu/dolphin.git` on the
dolphin submodule) for reference; development pushes go to the `Cfretz244` forks.

**Never run `pod install`.** Pods are fully committed; rerunning rewrites 800+ files.

## 3. Build everything (in order)

All AOT/Dolphin build knowledge is encoded in ONE driver:
`Cores/GCDeltaCore/scripts/stack.sh`. Never invoke cmake by hand for dolphin — the driver
carries all the pins (Vulkan off, Qt prefix, 19 `USE_SYSTEM_<LIB>=OFF` guards against
homebrew drift, FFmpeg disabled).

```bash
cd Cores/GCDeltaCore

# 1. macOS Dolphin (DolphinQt + dolphin-tool). This is the AOT toolchain AND the
#    macOS validation environment. First build takes a while.
./scripts/stack.sh macos-dolphin

# 2. Per-game AOT generation, for every game in games.conf ENABLED:
#    translate = ISO-hash-checked PPC→C generation into aot-src/<ID>/
#    aot-ios   = cross-compile that C into aot-libs/lib<ID>_aot_ios.a
./scripts/stack.sh translate GALE01
./scripts/stack.sh aot-ios GALE01
#    ...repeat per game, or do everything in one shot:
./scripts/stack.sh all      # translate + aot-ios for all ENABLED, then dolphin-ios + xcodegen

# 3. If you did NOT use `all`: iOS Dolphin static libs, then project regeneration.
./scripts/stack.sh dolphin-ios     # → build-ios/   (--clean for a full rebuild)
./scripts/stack.sh xcodegen        # regenerates aot-games.xcconfig + the Xcode project
```

For macOS-side testing of a game (recommended before any device work):

```bash
./scripts/stack.sh aot-macos GALE01   # macOS AOT lib
./scripts/stack.sh macos-dolphin      # rerun to LINK the lib into DolphinQt
./dolphin/build/Binaries/DolphinQt.app/Contents/MacOS/DolphinQt -e isos/GALE01-netplay.iso \
  -C Dolphin.Core.CPUCore=6           # CPU core 6 = the AOT core
```

Note: **`ENABLED` in games.conf gates BOTH links.** `stack.sh macos-dolphin` links the
macOS AOT libs of ENABLED games, and the iOS build force-loads the iOS libs of ENABLED
games. A game whose ID isn't in ENABLED silently runs interpreter-only (~4 fps) even if
its lib exists — if a game is inexplicably slow, check ENABLED first.

## 4. Build and deploy the app

From the workspace root:

```bash
xcodebuild -workspace Delta.xcworkspace -scheme Delta -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' build
```

For device deployment, open `Delta.xcworkspace` in Xcode, select the `Delta` scheme and
your phone, and run. Signing is automatic ("iPhone Developer") — set your team in the
Delta target once. First install on a new phone needs Settings → General → VPN & Device
Management → trust the developer certificate.

Import games on-device via the Files app / share sheet (`.iso`/`.rvz` etc.). Artwork
resolves automatically from the bundled OpenVGDB by file hash/name.

## 5. How the AOT pipeline works (30-second version)

Four phases per game; each produces the next phase's input:

1. **Trace collection (macOS, manual gameplay):** play the game in the stack's DolphinQt
   with `-C Dolphin.Debug.TraceCollection=True -C Dolphin.Debug.TraceOutputPath=<f>.dpht`.
   An instrumented JIT records executed blocks. Coverage = what you played; untraced code
   falls back to the interpreter on device (graceful, but ~100x slower — frame dips in a
   specific scene almost always mean missing coverage, not bugs).
2. **CFG extraction:** `dolphin-tool cfg --iso ... --trace ... --output cfg.db`.
   `--trace` is repeatable — sessions union additively, so keep every trace file forever
   and add new ones for rough spots (the "incremental trace loop" in
   `Cores/GCDeltaCore/CLAUDE.md` is the standard perf-fix workflow).
3. **Translation:** `stack.sh translate <ID>` emits one C function per block + an O(1)
   dispatch table.
4. **Compile + link:** `stack.sh aot-ios <ID>`, then the app links every ENABLED lib with
   `-force_load` (constructor-based registration would otherwise be stripped — this is why
   `aot-games.xcconfig` is generated and must never be hand-edited).

At runtime each game's table self-registers; Dolphin's CPU core 6 selects it by game ID.
Games without a lib fall back entirely to the interpreter.

**The one iron rule:** an AOT library must be generated from the *exact* disc image the
traces came from — `games.conf` pins sha256 per ISO and `translate` refuses mismatches.
A different revision of the same game silently marks ~36% of blocks untranslatable.

## 6. Building the custom Melee netplay ISO

The `GALE01` entry in games.conf is not retail Melee — it's a custom image built from the
[doldecomp/melee](https://github.com/doldecomp/melee) decompilation with a lockstep-netplay
module ("nw") baked in, surgically repacked over a verified retail image. The tooling lives
in a separate repo: `git clone --recursive git@github.com:Cfretz244/aot-dolphin-helper.git`
(the `melee/` submodule tracks branch `netplay` of `Cfretz244/melee`). Its `HANDOFF.md` is
the authoritative deep-dive; this is the happy path.

**Prerequisites** (beyond §1): `python3`, `ninja`, and Wine (the gcenx "Wine Devel" app
bundle — the decomp compiles with the original Metrowerks compiler under Wine; no
devkitPPC). Everything else (MWCC 1.2.5, binutils, decomp-toolkit, wibo, ...) is
auto-downloaded by `configure.py` at pinned versions. One wart: `configure.py --wrapper`
breaks on paths containing spaces, so the repo carries a space-free symlink at
`tools/wine` — use that.

**Source image:** a verified retail NTSC v1.02 GALE01 ISO. The anchor is the retail
`main.dol` SHA-1 `08e0bf20134dfcb260699671004527b2d6bb1a45` — the decomp pins it
(`melee/ssbm.us.1.2.sha1`), and the extracted retail DOL must sit at
`melee/orig/GALE01/sys/main.dol` or the build refuses to start. The full retail ISO is the
repack input (kept as `isos/GALE01-netplay-src.iso` in GCDeltaCore).

**Build (deterministic — unchanged source reproduces the pinned image byte-identically):**

```bash
cd aot-dolphin-helper/melee
python3 configure.py --netplay --map --wrapper /abs/path/to/aot-dolphin-helper/tools/wine
ninja                                    # → build/GALE01/main.dol (+ main.elf.MAP)

# Regenerate the rollback region table (REQUIRED after every relink — symbols move):
python3 ../scripts/gen-rollback-regions.py --out ../rollback-regions-GALE01.txt

# Surgical repack: grown main.dol overwritten in place, FST relocated into the disc's
# junk tail; every file offset stays byte-identical to retail. NEVER use pyisotools /
# a full relayout — it breaks DVD file access.
python3 ../scripts/repack-melee-iso.py \
    ../Delta/Cores/GCDeltaCore/isos/GALE01-netplay-src.iso \
    build/GALE01/main.dol \
    ../isos/GALE01-netplay.iso

shasum -a 256 ../isos/GALE01-netplay.iso   # must equal SHA256_GALE01 in games.conf
```

`--netplay` implies non-matching, adds `-DNETPLAY`, and links `src/melee/nw/nw_netplay.c`
(the module lives in the tree on the `netplay` branch; `patches/` in aot-dolphin-helper is
the historical provenance record, not something you apply).

**If you actually changed the DOL** (not just reproducing it), you've obligated the full
re-pin procedure — new sha256 into games.conf **before** `stack.sh translate GALE01`
(translate reads the image from games.conf; pin-then-translate or you build a hybrid lib),
retrace, verify `Skipped (SMC): 0` — exactly zero — rebuild the AOT libs, run the netplay
verification script, snapshot the region table as `rollback-regions-GALE01-vNN.txt` and
bundle it into GCDeltaCore. Follow `aot-dolphin-helper/HANDOFF.md` invariants #1/#2 to the
letter; several of its gotchas (silent offline free-running on proto mismatch, hooks
allowed in `gm/` only, ASCII-only comments for sjiswrap) each cost real debugging time.

## 7. Pitfalls checklist (each backed by a real incident)

- **Never `pod install`.** (Rewrites 800+ committed files.)
- **Never hand-edit** `GCDeltaCore.xcodeproj/project.pbxproj` or `aot-games.xcconfig` —
  both are generated. Edit `project.yml` / `games.conf` and rerun `stack.sh xcodegen`.
  (The main `Delta.xcodeproj` is NOT generated and is edited normally.)
- **ISO revision rule** (see §5). Never ship a library that translated with a high
  skip count.
- **ENABLED gates both the macOS and iOS links** (see §3).
- **Homebrew contamination:** pkg-config can leak host libraries into the iOS
  cross-compile. If a new undefined-symbol class appears in the workspace link right
  after a `brew install/upgrade`, suspect this first.
- **Vulkan stays off** on macOS builds (bundled MoltenVK breaks on recent Xcode; Metal is
  the backend). Encoded in stack.sh — another reason not to run cmake by hand.
- **Submodule discipline:** GCDeltaCore on `main`, dolphin on `master`, DeltaCore on
  `delta-stack`. Push submodule changes and bump the parent's gitlink in the same change.
- **Trace sessions must run the JIT core** (default), never `-C Dolphin.Core.CPUCore=6` —
  trace collection instruments the JIT. Quit DolphinQt with ⌘Q so the trace flushes.
- **Device save sync:** GC saves are GCI files; use the targeted `devicectl` copy recipes
  in `Cores/GCDeltaCore/CLAUDE.md` ("Device save sync") — Xcode's whole-container download
  silently omits `Library/`.
- **Dolphin config flags use the `Dolphin.` prefix** with `-C` (e.g.
  `-C Dolphin.Core.CPUCore=6`), not `Main.`.

## 8. Where the knowledge lives

| Doc | Covers |
|---|---|
| `CLAUDE.md` (workspace root) | Stack layout, build commands, hard rules, app architecture |
| `Cores/GCDeltaCore/CLAUDE.md` | Bootstrap detail, bridge architecture, incremental trace loop, save sync |
| `Cores/GCDeltaCore/dolphin/CLAUDE.md` | AOT pipeline internals, diagnostic env vars (`AOT_COMPARE`, `dolphin-tool diff`, ...) |
| `Cores/GCDeltaCore/dolphin/docs/restoration-2026-06.md` | Post-mortem that motivates most hard rules |
| `~/git/aot-dolphin-helper/` | Melee netplay research repo: netplay module, ISO repack tooling, rollback region tables |

In-flight feature branches (e.g. `wii-bringup`, which adds Wii/Brawl support across all
three repos) may add games and steps not covered here; this guide describes `main`.
