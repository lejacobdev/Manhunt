# Hunting Game

A native iOS clone of a real-world GPS manhunt game: hunters chase runners
across a real, publicly-accessible play area, with live radar, a compass
bearing to the nearest threat, six power-ups, three game modes, a
friends/social layer, and a Dynamic Island / Live Activity threat readout.

This repo has three deployable pieces:

| Path              | What it is                                                        |
|--------------------|--------------------------------------------------------------------|
| `backend/`         | Node/TypeScript API + Socket.IO real-time server + Postgres schema |
| `ios/HuntingGame/` | Native SwiftUI app (iOS 16.2+) plus a Live Activity widget extension |
| `build_ipa.sh`     | CLI-only pipeline that produces an unsigned, sideloadable `.ipa`   |

Nothing here is a placeholder — the backend type-checks clean end to end
(`tsc --noEmit`) and every Swift file is complete, production-shaped code.
The one thing this environment cannot do is actually invoke `xcodebuild`
(no macOS/Xcode available here), so treat the "run it" steps below as the
path to verify the iOS side on your own Mac.

---

## 1. Prerequisites

**Backend**
- Node.js 18+ and npm
- A PostgreSQL 14+ database (local via Docker, or a hosted instance — Render,
  Railway, Supabase, RDS, etc. all work)

**iOS app**
- A Mac running a recent macOS with Xcode 15+ installed (Xcode 16 recommended
  for iOS 18 SDK support)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A physical iPhone for testing. The simulator cannot exercise CoreLocation
  background updates, CoreHaptics, or the Dynamic Island — you need real
  hardware (iPhone 14 Pro or later shows the actual Dynamic Island; earlier
  hardware still gets the Lock Screen Live Activity and compact/minimal
  regions render fine, just without the pill).
- An Apple ID (free is fine) if you want to run the app on-device through
  Xcode. A paid Apple Developer Program membership is only required for
  TestFlight/App Store distribution, not for sideloading or local device runs.

---

## 2. Backend setup

```bash
cd backend
npm install
cp .env.example .env
```

Edit `.env`:

```
DATABASE_URL="postgresql://user:password@localhost:5432/hunting_game?schema=public"
JWT_SECRET="generate a long random string — do not reuse the sample"
JWT_EXPIRES_IN="30d"
PORT=4000
OVERPASS_API_URL="https://overpass-api.de/api/interpreter"
CORS_ORIGIN="*"   # lock this to your app's actual origin in production
```

### Local Postgres via Docker (optional, fastest path)

```bash
docker run --name hunting-game-db \
  -e POSTGRES_USER=hunting_game \
  -e POSTGRES_PASSWORD=hunting_game \
  -e POSTGRES_DB=hunting_game \
  -p 5432:5432 -d postgres:16
```

That matches the default `DATABASE_URL` in `.env.example` — no edits needed
if you use these exact credentials.

### Run migrations and start the server

```bash
npx prisma generate
npx prisma migrate deploy   # or `npx prisma db push` for a quick local sync without migration history
npm run dev                 # ts-node-dev, auto-reloads on save
```

You should see:

```
[Server] Hunting Game backend active on port 4000
```

Sanity check: `curl http://localhost:4000/health` → `{"ok":true,...}`.

### Production build

```bash
npm run build     # compiles to backend/dist
npm start          # node dist/index.js
```

Run it behind a process manager (`pm2`, systemd, or your platform's own
supervisor) and a TLS-terminating reverse proxy (nginx, Caddy, or your PaaS's
built-in HTTPS). This matters for two reasons specific to this app:

- **iOS won't talk to plain HTTP.** App Transport Security blocks
  non-HTTPS requests by default, and the iOS client is written to call
  `https://...` — see §4 below.
- **Socket.IO needs WebSocket upgrade support** on whatever's in front of
  Node. If you're behind nginx, add the standard `Upgrade`/`Connection`
  header passthrough for the `/socket.io/` path.

Any Node-friendly host works: a plain VPS with pm2, Render, Railway, Fly.io,
or a container platform — there's no framework-specific lock-in here, it's
just Express + Socket.IO + Prisma.

### Database schema reference

The Prisma schema (`backend/prisma/schema.prisma`) defines: `User`,
`Friendship`, `GameSession`, `GamePlayer`, `PowerUpSpawn`, `LocationLog`, and
`GameEvent`. To inspect data during development:

```bash
npx prisma studio
```

To change the schema, edit `schema.prisma`, then:

```bash
npx prisma migrate dev --name describe_your_change
```

---

## 3. What the backend actually does

- **Auth** — `POST /auth/register`, `POST /auth/login`. Passwords are
  bcrypt-hashed; sessions are JWTs (`Authorization: Bearer <token>`).
- **Friends** — search by `username#tag`, send/accept/decline requests,
  block, list friends (`/friends/*`).
- **Games** — create/join/start/end a session, fetch by code
  (`/games/*`). Creating a game calls the Overpass API to spawn power-ups
  only on real, publicly-accessible OSM terrain (parks, footways, plazas)
  inside your drawn boundary, with a Turf.js polygon-sampling fallback if
  Overpass is unreachable.
- **Real-time** (Socket.IO, JWT-authenticated on connect) — location
  updates, compass bearing to nearest hunter, radar broadcasts (with
  invisibility/thermal-vision/EMP-jammer/decoy logic applied), catch
  verification (15m radius + arrest code), and all three game modes
  (standard elimination, infection, squad).
- **Anti-cheat** — rejects location updates that imply faster-than-sprint
  speed or an impossible position jump between fixes (adjusted upward while
  a runner's ADRENALINE buff is active).

---

## 4. iOS app setup

```bash
cd ios/HuntingGame
xcodegen generate
open HuntingGame.xcodeproj
```

XcodeGen reads `project.yml` and generates the `.xcodeproj` — it is
intentionally **not** committed to the repo, so `xcodegen generate` is a
required first step any time you pull changes that touch `project.yml` or
add/remove Swift files.

### Point the app at your backend

Two places hardcode a placeholder host — update both before running:

- `Sources/Services/APIClient.swift` → `APIClient.shared.baseURL`
- `Sources/Services/SocketService.swift` → `SocketService.shared.serverURL`

Both should point at the same host, e.g. `https://api.yourdomain.com`
(or `https://<your-ngrok-subdomain>.ngrok.io` while developing against a
laptop-hosted backend — plain `http://localhost:4000` will not work from a
physical device due to ATS and the fact that your phone isn't your laptop).

### Signing for a device run

`project.yml` ships with `CODE_SIGNING_ALLOWED: NO` at the project level —
that's what makes `build_ipa.sh` able to produce an unsigned IPA from the
CLI without a Developer account attached. To run the app from Xcode on your
own device instead:

1. Select the `HuntingGame` target → **Signing & Capabilities**.
2. Check **Automatically manage signing** and pick your personal team.
   (Xcode will override the project-level `CODE_SIGNING_ALLOWED=NO` for a
   local run/debug build; it only affects the `xcodebuild archive` path
   `build_ipa.sh` uses.)
3. Build & run (⌘R) onto your connected iPhone.

### Live Activity / Dynamic Island

- Requires a physical device on iOS 16.2+.
- The user must have **Settings → [Hunting Game] → Live Activities**
  enabled (on by default, but respect it — `ActivityAuthorizationInfo`
  is checked before starting one).
- Only runners start a Live Activity (it's the "nearest hunter" threat
  readout — hunters already see the full in-app radar). It starts when a
  runner enters `GameView` and ends when they leave, get caught, or the
  game ends.
- The widget extension target (`HuntingGameWidgets`) is embedded into the
  app target automatically by `project.yml` — you don't build or install it
  separately, it's part of the same `.app`/`.ipa`.

### CoreHaptics

`HapticsEngine` drives an escalating haptic pulse once a runner's
nearest-hunter distance drops under 25m, plus simple tap/success/error
feedback elsewhere. Haptics are silently a no-op on hardware that doesn't
support them (and always a no-op in the simulator) — this is handled
automatically via `CHHapticEngine.capabilitiesForHardware()`, no crash risk.

### Fonts

No custom font files are bundled or need to be added to `Info.plist`. The
"SF Pro Rounded" and "SF Mono" looks come entirely from
`Font.system(size:weight:design: .rounded)` / `.monospaced)`, which are
built into iOS — see `ADATheme.swift`.

---

## 5. Building the sideloadable IPA

From the repo root, on a Mac with Xcode installed:

```bash
chmod +x build_ipa.sh
./build_ipa.sh
```

What it does:

1. Runs `xcodegen generate` if `HuntingGame.xcodeproj` doesn't exist yet.
2. `xcodebuild archive` with code signing disabled
   (`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`).
3. Packages the resulting `.app` into a `Payload/` directory and zips it as
   `build/IPA/HuntingGame.ipa`.

### Installing the unsigned IPA

The output is **unsigned**. Options:

- **AltStore / SideStore** — these sign the IPA with your free Apple ID
  on install and re-sign it automatically every 7 days (free account) or
  on-demand (paid account). Add the IPA via the AltStore/SideStore app on
  your device (AirDrop it over, or serve it and use the app's "install
  from URL" flow).
- **TrollStore** (jailbreak/exploit-dependent, device- and iOS-version
  gated) — installs unsigned IPAs directly with no re-signing needed.
  Check TrollStore's current compatibility list before relying on this.
- **A real Apple Developer account, signed properly** — if you'd rather
  ship via TestFlight or the App Store instead of sideloading, don't use
  this script's output. Instead, open the project in Xcode with a paid
  team selected under Signing & Capabilities, then Product → Archive →
  Distribute App, and let Xcode/Transporter handle signing and upload.

---

## 6. End-to-end smoke test

1. Backend running locally or deployed, `APIClient`/`SocketService` pointed
   at it.
2. Launch the app on two devices (or one device + a second build signed for
   a friend's phone).
3. Device A: **Register** → **Host New Game**, pick a mode, draw a boundary
   with 3+ taps on the map, **Create Game**. Note the game code.
4. Device B: **Register** → enter the code, pick **Hunter** or **Runner**,
   **Join Game**.
5. Device A (as the game's supervisor): **Start Game**.
6. Runner should see the live radar/compass once a hunter is nearby;
   hunter should see the runner in their "visible runners" list and be
   able to attempt a catch with the runner's on-screen arrest code.
7. On the runner's device, background the app or lock the phone — the Live
   Activity should appear on the Lock Screen (and in the Dynamic Island on
   supported hardware) showing live distance/bearing.

---

## 7. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen` |
| App can't reach the backend | Check `APIClient.baseURL` / `SocketService.serverURL`, and that the host is HTTPS (ATS blocks plain HTTP) |
| Socket connects then immediately disconnects | JWT expired/invalid, or the `Authorization`/`connectParams` token doesn't match what `io.use(...)` in `server.ts` expects |
| No power-ups spawn on game creation | Overpass API is rate-limited/unreachable — the backend falls back to random points inside your polygon automatically, so this degrades gracefully rather than failing |
| Live Activity never appears | Confirm iOS 16.2+, a physical device, Live Activities enabled in Settings, and that you joined as a **runner** (hunters don't get one by design) |
| `xcodebuild archive` fails immediately | Make sure you're on macOS with Xcode command line tools installed (`xcode-select --install`); `build_ipa.sh` checks for both and exits early with a clear message if either is missing |
| Background location stops after a while | `NSLocationAlwaysAndWhenInUseUsageDescription` + `UIBackgroundModes: [location]` are already set in `project.yml` — if you're testing via Xcode's debugger, background execution can still be throttled by the debugger itself; test with a real, detached install for accurate behavior |
