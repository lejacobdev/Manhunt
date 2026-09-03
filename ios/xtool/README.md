# Building HuntingGame with xtool (Linux/Windows, no Xcode)

This is a second, parallel build definition for HuntingGame, targeting
[xtool](https://xtool.sh) instead of Xcode. It exists for people who want to
build a sideloadable `.ipa` on Linux or Windows (via WSL) without a Mac.

**The primary, full-featured build is still `../HuntingGame/` + `../../build_ipa.sh`,
built with Xcode on a Mac.** Nothing here replaces that — every `.swift` file
under `Sources/` in this directory is a symlink back into `../HuntingGame/`, so
both build paths compile the exact same code with nothing duplicated.

## What's missing here

xtool's own documentation (`Appex.md`) confirms it supports iOS app extensions
(the WidgetKit/Live Activity extension is included below), but nowhere
documents building a **watchOS** app or companion-app bundling. So:

- **Included:** the iPhone app, and the Lock Screen / Dynamic Island Live
  Activity widget extension.
- **Not included:** the Apple Watch companion app and its own widget
  extension (`ios/HuntingGame/Watch/`, `ios/HuntingGame/WatchWidgets/`). If
  you want those, build via Xcode instead.
- Has its own app icon (`icon.png`, wired up via `xtool.yml`'s `iconPath`) —
  the main Xcode project's asset catalog is still empty (fine there, since a
  Simulator/device run via Xcode doesn't require one), so this doesn't fix
  that build path, only this one.

This restructuring was originally written without a working Swift toolchain
available to verify it compiles, then debugged live against a real Debian 11
server. It now builds successfully there. Treat it as solid, but any *new*
host may still surface something distro-specific (see the "known-good build
environment" note below) — that's normal, not a sign something's fundamentally
wrong; paste the error and it's usually one missing package.

## Building

Two options, both unsigned (same trust model as `build_ipa.sh`'s Mac output —
AltStore/SideStore sign it on install) and **neither needs an Apple ID
login**. That surprised us too: `xtool setup` always logs in first, but login
is only actually required for a *signed* build (`--sign`) or installing
straight to a device. Both scripts below skip `xtool setup` entirely and go
straight to the standalone `xtool sdk install` command instead, which needs
no auth.

### Option A — `docker-build.sh` (recommended)

```bash
./docker-build.sh [/path/to/Xcode.xip]
```

Builds a `swift:6.2-jammy`-based image (has every runtime lib xtool/Swift
need already correctly set up — this is the known-good build environment,
confirmed working on Debian 11 where the host's own glibc was too old for a
directly-installed toolchain) and runs the whole build inside it. The Darwin
SDK is cached at `~/.xtool-cache/swiftpm/` — **shared with any other xtool
project on the same server** — so if you've built one before, this skips SDK
extraction entirely and needs no `Xcode.xip` at all. First time on a given
server, pass the path to a downloaded `Xcode.xip` (from
https://developer.apple.com/download/all/?q=Xcode, logged in with your Apple
ID in the browser — that login is separate from and unrelated to `xtool`'s
own auth).

### Option B — `xtool-build.sh` (no Docker)

```bash
./xtool-build.sh [/path/to/Xcode.xip]
```

Same logic, but installs Swift and `xtool` directly on the host instead of in
a container. Only works if the host's glibc is new enough for the prebuilt
Swift 6.3 toolchain and the xtool AppImage (both need glibc ≥ 2.35 as of this
writing) — Debian 11/Ubuntu 20.04 are too old for this path; use
`docker-build.sh` there instead.

Both scripts publish the finished `HuntingGame.ipa` to `/var/www/html/` if
that directory exists, so it's directly downloadable from the server.

See each script's own comments for the full step-by-step, and xtool's docs
(`Documentation/xtool.docc/` in https://github.com/xtool-org/xtool — cloned
directly since `xtool.sh` itself was unreachable from the session that wrote
this) for the underlying reference.

## Files

- `Package.swift` — SwiftPM manifest: two library products, `HuntingGame`
  (app) and `HuntingGameWidget` (extension), plus the socket.io-client-swift
  dependency (matching `project.yml`'s `packages.SocketIO`).
- `xtool.yml` — tells xtool which product is the app vs. the extension, and
  where each one's `Info.plist`/entitlements live.
- `Info.plist` / `HuntingGameWidget-Info.plist` — only the keys that differ
  from xtool's auto-generated defaults (location/motion usage strings,
  background modes, Live Activity support, the widget's
  `NSExtensionPointIdentifier`) — mirrors `project.yml`'s `info.properties`.
- `HuntingGame.entitlements` — identical to `../HuntingGame/HuntingGame.entitlements`.
- `icon.png` — 1024×1024 app icon (a radar/crosshair motif in the app's own
  tactical palette), pointed to by `xtool.yml`'s `iconPath`. Also published
  by the build scripts to `backend/dist-static/icon.png` and referenced by
  `source.json`'s `iconURL`, so it shows up in SideStore's Sources browser too.
- `Sources/HuntingGame/`, `Sources/HuntingGameWidget/` — each a real directory
  (not itself a symlink) containing subfolder-level symlinks into
  `../HuntingGame/{Sources,Shared,LiveActivityShared,Widgets/HuntingGameWidgets}`.
  Both targets pull in `Shared/`/`LiveActivityShared/` directly rather than
  depending on separate library targets for them — that code was written for
  Xcode's "same file compiled into multiple targets" model (no imports, no
  `public`), not SwiftPM's real module boundaries, so this mirrors Xcode's
  approach instead of fighting it.
- `Dockerfile.xtool` — the known-good build image (`swift:6.2-jammy` + xtool +
  runtime libs) that `docker-build.sh` builds and runs against.
- `docker-build.sh` / `xtool-build.sh` — see "Building" above.
