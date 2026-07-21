# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

`~/git/delta-stack` is the **unified build stack** — the ONE environment for all macOS and iOS
development on this project (pre-June-2026 scattered repos are archived as `~/git/*.archived`).
It is a fork of the Delta iOS emulator (`Cfretz244/Delta`) whose headline addition is **GameCube
support without JIT**: an ahead-of-time (AOT) recompilation pipeline that statically transpiles
PowerPC game code to C, compiles it to native ARM64, and links it into Dolphin — because iOS
prohibits `MAP_JIT`.

Three nested repos carry the AOT work (more-specific CLAUDE.md files live in each):

```
delta-stack/                          ← Cfretz244/Delta (iOS app, workspace root)
  Cores/GCDeltaCore/                  ← Cfretz244/GCDeltaCore (private) — bridge + build driver
    CLAUDE.md                         ← stack layout, bootstrap, bridge architecture
    scripts/stack.sh                  ← THE driver: all build knowledge lives here
    games.conf                        ← committed game registry (ISO sha256 pins, ENABLED list)
    dolphin/                          ← Cfretz244/dolphin @ master — emulator + AOT toolchain
      CLAUDE.md                       ← AOT pipeline internals, diagnostic env vars
      docs/restoration-2026-06.md     ← post-mortem; motivates most of the hard rules below
```

**Submodule discipline:** `Cores/GCDeltaCore` stays on `main`, `dolphin` on `master` — never work
detached. Dolphin changes are pushed to `Cfretz244/dolphin` and the gitlink bumped in GCDeltaCore
in the same change; same pattern one level up for GCDeltaCore → Delta.

## Build Commands

```bash
# AOT/Dolphin work — ALWAYS via the driver, never raw cmake (it encodes all pins):
cd Cores/GCDeltaCore
./scripts/stack.sh macos-dolphin       # macOS DolphinQt + dolphin-tool → dolphin/build/
./scripts/stack.sh translate GALE01    # ISO-hash-checked AOT C generation → aot-src/GALE01/
./scripts/stack.sh aot-macos GALE01    # macOS AOT lib (rerun macos-dolphin to link it)
./scripts/stack.sh aot-ios GALE01      # iOS AOT lib → aot-libs/lib<ID>_aot_ios.a
./scripts/stack.sh dolphin-ios         # iOS Dolphin static libs → build-ios/  (--clean for full)
./scripts/stack.sh xcodegen            # regen aot-games.xcconfig + GCDeltaCore Xcode project
./scripts/stack.sh all                 # translate + aot-ios for every ENABLED game, then the rest

# iOS app build (from the stack root):
xcodebuild -workspace Delta.xcworkspace -scheme Delta -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' build
# (or open Delta.xcworkspace in Xcode for device deploy/signing)

# Dolphin unit tests (Google Test, in dolphin/Source/UnitTests/):
cd Cores/GCDeltaCore/dolphin/build && cmake --build . --target unittests
```

Prerequisites and fresh-machine bootstrap (including the un-versioned `isos/` and `traces/`
assets that exist only locally) are documented in `Cores/GCDeltaCore/CLAUDE.md`.

## Hard Rules (each backed by a real incident)

- **Never run `pod install`.** Pods are fully committed; rerunning rewrites 800+ files.
- **Never hand-edit `project.pbxproj` or `aot-games.xcconfig` in GCDeltaCore.** Both are
  generated — edit `project.yml` / `games.conf` and run `stack.sh xcodegen` (XcodeGen pinned
  baseline: 2.45.2). The main Delta.xcodeproj is NOT generated and is edited normally.
- **The AOT library must come from the exact disc image the traces were recorded from.**
  A different revision of the same game silently marks ~36% of blocks untranslatable (April 2026
  Melee Rev0-vs-Rev2 incident). `games.conf` pins each ISO's sha256; `stack.sh translate`
  refuses a mismatch and warns on high skip counts. Never ship a high-skip library.
- **AOT libs require `-force_load`** — their `__attribute__((constructor))` registration would
  otherwise be stripped by the linker. The flags are generated into `aot-games.xcconfig` from
  `ENABLED` in `games.conf`.
- **Vulkan stays off** (`-DENABLE_VULKAN=OFF`, encoded in stack.sh): bundled MoltenVK fails to
  build on recent Xcode. Metal is the primary backend.
- **Homebrew contamination:** pkg-config can leak host libraries into the iOS cross-compile
  despite toolchain isolation (FFmpeg is hard-disabled in `build-dolphin-ios.sh` for this).
  New undefined-symbol classes in the workspace link after a `brew install/upgrade` → suspect
  this first. On the macOS side, stack.sh pins 19 `USE_SYSTEM_<LIB>=OFF` against brew drift.
- **Vertex-loader AOT is deferred** (known emitter bugs). iOS uses the software vertex loader
  fallback — the validated configuration. Don't link `vtxaot` output into iOS.

## How the AOT Reassembly Stack Works

Four phases, each producing the next phase's input (toolchain lives in
`dolphin/Source/Core/DolphinTool/`, runtime in `dolphin/Source/Core/Core/PowerPC/`):

1. **Trace collection (macOS, manual gameplay):** Play the game in the stack's DolphinQt with
   `-C Dolphin.Debug.TraceCollection=True -C Dolphin.Debug.TraceOutputPath=<game>.dpht`.
   An instrumented JIT records executed blocks/edges. Coverage = what you played.
2. **CFG extraction:** `dolphin-tool cfg --iso game.iso --trace trace.dpht --output cfg.db` —
   recursive-descent disassembly seeded by the traces + DOL entry point → SQLite DB.
   `--trace` is repeatable: multiple traces union (broad base trace + targeted scene traces).
   Frame drops in a specific scene = missing coverage; fix via the incremental trace loop in
   `Cores/GCDeltaCore/CLAUDE.md` ("Incremental Trace Updates") — play the scene, union the new
   trace, translate + aot-ios, rebuild. No gates needed for coverage-only updates.
3. **PPC→C translation:** `stack.sh translate <ID>` (wraps `dolphin-tool translate`) emits one C
   function per block plus an O(1) flat dispatch table (`<ID>_fast_table[(pc - BASE) >> 2]`)
   into `aot-src/<ID>/`.
4. **Compile + link:** `stack.sh aot-ios <ID>` cross-compiles the C with ThinLTO into
   `aot-libs/lib<ID>_aot_ios.a`; `stack.sh dolphin-ios` builds Dolphin's iOS static libs and
   links every AOT lib present in `aot-libs/`.

At runtime, each game's dispatch table self-registers with `AotRegistry` via constructor;
`AOTCore::Init()` (CPU core 6) selects the table matching the loaded game ID. NULL table entries
fall back to single-stepping the interpreter, so partial coverage degrades gracefully — and a
game with no AOT lib at all falls back entirely. FP/paired-single ops delegate to interpreter
wrappers in `AotRuntime.cpp` (FP "fast paths" were removed in the June 2026 restoration as
unsound). Config flags use the `Dolphin.` prefix (e.g. `-C Dolphin.Core.CPUCore=6`), not `Main.`.

Correctness golden rule: runtime helpers must exactly replicate
`Source/Core/Core/PowerPC/Interpreter/` behavior including side effects — implement from the
interpreter source, never from PPC ISA docs. Diagnostic harnesses (`AOT_COMPARE=1`,
`AOT_INTERP_ONLY=1`, `dolphin-tool diff`, etc.) are tabled in `dolphin/CLAUDE.md`.

## End-to-End: iOS Build for a New AOT Game Backend

All steps from `Cores/GCDeltaCore/` unless noted. GameID below is the 6-char code (e.g. GALE01).

1. **Build the toolchain** if not present: `./scripts/stack.sh macos-dolphin`.
2. **Collect traces (macOS):** play the game in `dolphin/build/Binaries/DolphinQt.app` with
   trace collection on (phase 1 above). Play broadly — untraced code paths run via interpreter
   fallback on device. Produce the CFG DB with `dolphin-tool cfg` (phase 2).
3. **Register the game:** put the disc image in `isos/`, add `ISO_<ID>`, `SHA256_<ID>`,
   `TRACE_<ID>`, `CFG_<ID>` entries to `games.conf`, add the ID to `ALL_GAMES` and `ENABLED`.
   Move trace + cfg into `traces/` under the names you registered.
4. **(Recommended) validate on macOS first:** `stack.sh translate <ID> && stack.sh aot-macos <ID>
   && stack.sh macos-dolphin`, then run the game in DolphinQt with `-C Dolphin.Core.CPUCore=6`.
5. **Build for iOS:**
   `./scripts/stack.sh translate <ID> && ./scripts/stack.sh aot-ios <ID> && ./scripts/stack.sh dolphin-ios && ./scripts/stack.sh xcodegen`
   (xcodegen regenerates `aot-games.xcconfig` so the new lib gets its `-force_load`).
6. **Build the app:** from the stack root, build the `Delta` scheme in `Delta.xcworkspace`
   (command above). No app-side code changes are needed for a new *game* — the GameCube system
   is already registered; AOT backends are selected per-game at runtime by `AotRegistry`.
7. **Commit:** `games.conf` + `aot-games.xcconfig` (and pbxproj if it changed) in GCDeltaCore;
   then bump the GCDeltaCore gitlink in this repo. `isos/`, `traces/`, `aot-src/`, `aot-libs/`
   are gitignored local-only assets — keep an off-machine backup of isos and traces (losing
   traces means re-playing the game to recollect).

## Delta App Architecture (app side of the bridge)

- **Workspace:** `Delta.xcworkspace` references Delta.xcodeproj, all 9 core projects under
  `Cores/`, `External/{Harmony,Roxas}`, and the committed Pods project. Each core builds a
  `.framework` embedded in the app.
- **System registration:** `Delta/Systems/System.swift` defines the `System` enum (`.gc` for
  GameCube) and maps each case to its core; `AppDelegate.registerCores()` registers them at
  launch (GC is in all non-LITE builds; Genesis is BETA-gated). Core metadata and fast-forward
  speeds live in `Delta/Systems/DeltaCoreProtocol+Delta.swift`. Adding a *new system* (not a new
  GC game) touches: System.swift, DeltaCoreProtocol+Delta.swift, AppDelegate.registerCores(),
  Info.plist document/UTType entries, and the workspace/app linking of the new core framework.
- **GCDeltaCore bridge:** `GCEmulatorBridge.mm` implements Delta's `DLTAEmulatorBridging` —
  boots Dolphin on a dedicated thread, semaphore-synced frame loop against Dolphin's VI
  end-of-field, blit-based Metal frame readback, pull-based 48kHz audio (`DeltaSoundStream`),
  and direct `GCPadStatus` input injection. Details in `Cores/GCDeltaCore/CLAUDE.md`.
- **Entitlements** (`Delta/Delta.entitlements`): increased-memory-limit and
  extended-virtual-addressing matter for Dolphin (24MB+ emulated RAM); note `MAIN_FASTMEM` is
  still disabled on iOS. Min deployment target iOS 14.0; signing is automatic ("iPhone
  Developer").
- **ObjC/C++ gotcha:** include Dolphin C++ headers before ObjC headers (the `State` enum in
  DeltaCore-Swift collides with Dolphin's `Core/State.h`; `DolphinStateHelper` exists solely to
  isolate that include).
