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
- App icon isn't wired up (the source project's asset catalog is empty
  anyway — no PNGs to point xtool's `iconPath` at). Cosmetic only.

This restructuring was done without a working Swift toolchain available to
verify it compiles — the session that wrote it hit network restrictions
blocking every source of a Linux Swift toolchain (`download.swift.org`,
GitHub release assets, and Docker Hub's CDN were all blocked by that
session's egress policy). Treat this as a solid best-effort starting point,
not a verified-working build; you may need to fix small things once you see
real compiler output.

## Building

Run this on a machine with normal internet access (this restructuring itself
was done from a network-restricted session — the actual build has to happen
somewhere that can reach `swift.org`, `developer.apple.com`, and GitHub
without restriction):

```bash
./xtool-build.sh
```

It installs `xtool` itself, walks you through `xtool setup` (your own Apple
ID — this step needs a human, `xtool` will prompt you interactively for
either an App Store Connect API key or your Apple ID password + a live 2FA
code, plus the path to an `Xcode.xip` you download yourself from
https://developer.apple.com/download/all/?q=Xcode), then builds and packages
`HuntingGame.ipa`.

See the script's own comments for exactly what it does at each step, and
xtool's docs (cloned into this session at build time from
https://github.com/xtool-org/xtool — `Documentation/xtool.docc/`) for the
full reference, since `xtool.sh` itself was unreachable from this session.

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
- `Sources/*` — symlinks into `../HuntingGame/{Sources,Shared,LiveActivityShared,Widgets/HuntingGameWidgets}`.
