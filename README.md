# Hunting Game

A native iOS clone of a real-world GPS manhunt game: hunters chase runners
across a real, publicly-accessible play area, with live radar, a compass
bearing to the nearest threat, six power-ups, three game modes, a
friends/social layer, a Dynamic Island / Live Activity threat readout, and a
full Apple Watch companion app with its own complication.

This repo has three deployable pieces:

| Path              | What it is                                                        |
|--------------------|--------------------------------------------------------------------|
| `backend/`         | Node/TypeScript API + Socket.IO real-time server + Postgres schema |
| `ios/HuntingGame/` | Native SwiftUI app (iOS 16.2+), a Live Activity widget extension, and a watchOS companion app + complication |
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

### Deploying with Apache behind Cloudflare (what runs api.lejacob.eu)

`docker-compose.yml` at the repo root runs Postgres and the backend in
Docker, with the backend bound to **127.0.0.1 only** on `BACKEND_PORT`
(default `8420`) — never exposed to the public internet directly. Apache,
running on the host (not in Docker), owns ports 80/443 and reverse-proxies
`api.lejacob.eu` to that loopback port. This is what every build of the app
talks to — `APIClient.baseURL` / `SocketService.serverURL` are hardcoded to
`https://api.lejacob.eu`; there's no per-developer backend to stand up
unless you're working on the server itself.

Traffic path: **client → Cloudflare (public TLS) → this server on 80/443 →
Apache → `127.0.0.1:8420`**. Two things enforce that Cloudflare is the only
way in:

- **Cloudflare Origin CA certificate** on Apache's `:443` vhost instead of a
  Let's Encrypt one — issued free from the Cloudflare dashboard, trusted
  only by Cloudflare's edge, valid up to 15 years, no renewal automation to
  babysit.
- **An IP allowlist** (`deploy/apache/cloudflare-ips.conf`, `Include`d into
  both vhosts) restricting Apache to Cloudflare's published ranges (plus
  `127.0.0.1` for local health checks) — this is what actually closes the
  direct-origin-IP bypass; the Origin CA cert alone doesn't stop someone
  from hitting your IP directly over plain HTTP or an untrusted cert.

Prerequisites: a DNS record for `api.lejacob.eu` proxied through Cloudflare
(orange cloud, not grey/DNS-only), and Cloudflare's SSL/TLS mode set to
**Full (strict)** — required for Cloudflare to actually validate the Origin
CA cert rather than accept anything.

On the server (Ubuntu/Debian; adjust package manager commands if yours differs):

```bash
# 1. Install Docker and Apache
curl -fsSL https://get.docker.com | sh
apt update && apt install -y apache2
a2enmod proxy proxy_http proxy_wstunnel rewrite ssl headers authz_host

# 2. Get the code
git clone https://github.com/lejacobdev/manhunt.git
cd manhunt

# 3. Configure secrets
cp .env.example .env
nano .env   # set POSTGRES_PASSWORD, JWT_SECRET (openssl rand -base64 48);
            # BACKEND_PORT defaults to 8420 — only change it if that's
            # already in use, and keep it in sync with step 6 below

# 4. Start Postgres + the backend (loopback-only, nothing public yet)
docker compose up -d --build
curl http://127.0.0.1:8420/health   # sanity check from the server itself
# {"ok":true,"service":"hunting-game-backend"}
```

Get the Origin CA cert from the Cloudflare dashboard (**SSL/TLS → Origin
Server → Create Certificate**; accept the defaults, it'll cover
`api.lejacob.eu`), then install it and the vhost:

```bash
# 5. Install the cert + key, and Cloudflare's origin CA root for the chain
# (download the root from https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/#download-the-cloudflare-origin-ca-root-certificate)
mkdir -p /etc/cloudflare
nano /etc/cloudflare/origin.pem                # paste the certificate
nano /etc/cloudflare/origin.key                # paste the private key
nano /etc/cloudflare/origin_ca_rsa_root.pem     # paste the origin CA root
chmod 600 /etc/cloudflare/origin.key

# 6. Install Apache, the IP allowlist, and the vhost, then enable + reload —
# deploy/bootstrap-apache.sh does exactly the manual steps from here down
# (a2enmod, copy the two conf templates in with BACKEND_PORT substituted,
# a2ensite, configtest, reload) so there's one idempotent script instead of
# a sequence to retype by hand on every redeploy.
sudo ./deploy/bootstrap-apache.sh

# 7. Firewall — 80/443 need to accept Cloudflare's traffic; Apache's own
# IP allowlist (from the script above) is what actually rejects anyone else
# that reaches them
ufw allow 80/tcp && ufw allow 443/tcp
```

`bootstrap-apache.sh` reads `BACKEND_PORT` straight out of your `.env` (falling
back to `8420` if unset), so it stays in sync automatically — no separate
`sed` step to remember. Safe to re-run any time you change either
`deploy/apache/*.conf` template or `.env`'s `BACKEND_PORT`; it always
overwrites the installed copies rather than leaving stale ones in place. If
the Cloudflare cert/key aren't in place yet it warns and exits cleanly
without touching Apache's running config — drop the certs in and re-run it.

Verify from your own machine (not the server):

```bash
curl https://api.lejacob.eu/health
# {"ok":true,"service":"hunting-game-backend"}
```

If that hangs or 403s, check in order: Cloudflare's proxy status is orange
(not grey/DNS-only) for the `api` record, SSL/TLS mode is Full (strict),
and `tail -f /var/log/apache2/api_lejacob_ssl_error.log` on the server for
the actual rejection reason (a wrong cert path or a stale IP range are the
two usual suspects).

`deploy/apache/api.lejacob.eu.conf` and `cloudflare-ips.conf` in the repo
are the source of truth — if you tweak either, re-run
`sudo ./deploy/bootstrap-apache.sh` rather than hand-editing
`/etc/apache2/...` only, or the next redeploy will silently overwrite your
change back. Cloudflare does
occasionally rotate its IP ranges (rare, but it happens) — re-sync
`cloudflare-ips.conf` from
[cloudflare.com/ips-v4](https://www.cloudflare.com/ips-v4/) /
[ips-v6](https://www.cloudflare.com/ips-v6/) if requests start getting
403'd for no obvious reason.

Useful follow-up commands:

```bash
docker compose logs -f backend             # tail the backend's own logs
docker compose ps                          # container health
docker compose pull && docker compose up -d --build   # redeploy after a git pull
tail -f /var/log/apache2/api_lejacob_ssl_error.log     # proxy-level errors
```

Data persists in the named Docker volume `postgres_data` across restarts
and redeploys — `docker compose down` leaves it intact; only
`docker compose down -v` destroys it.

If you'd rather not run Cloudflare in front, the same Apache/Docker split
still works with a plain Let's Encrypt cert instead — swap the `SSLEngine`
block in `api.lejacob.eu.conf` for `certbot --apache -d api.lejacob.eu` and
drop the IP allowlist (or replace it with your own).

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

### Getting the project open in Xcode

You can import the repo straight from Xcode's UI — no terminal needed for
this part: **Xcode → File → Clone Repository...** (or the "Clone an existing
project" option on the Welcome screen), paste
`https://github.com/lejacobdev/manhunt.git`, and click through like any
other git clone.

Xcode won't have anything to open immediately after, though — the
`.xcodeproj` is generated from `project.yml` via XcodeGen rather than
committed to git (a committed generated project file is a well-known source
of noisy merge conflicts every time a Swift file is added or removed). To
turn that into an open project, either:

- **One click:** in Finder, double-click **`setup.command`** at the repo
  root. It installs XcodeGen via Homebrew if you don't have it, generates
  the project, and opens it in Xcode automatically.
- **Or from a terminal:**
  ```bash
  cd ios/HuntingGame
  xcodegen generate
  open HuntingGame.xcodeproj
  ```

Either way, re-run `xcodegen generate` (or double-click `setup.command`
again) any time you pull changes that touch `project.yml` or add/remove
Swift files — that's what keeps the generated project in sync.

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

## 5. Apple Watch companion app

The Watch app is a separate target (`HuntingGameWatch`, plus a
`HuntingGameWatchWidgets` complication extension) embedded automatically
into the iPhone `.app`/`.ipa` — `xcodegen generate` and `build_ipa.sh` both
already produce it, nothing extra to run.

**Architecture:** the phone stays the single source of truth. It owns the
JWT session and the live Socket.IO connection; the Watch never talks to the
backend directly. Instead:

- The phone (`GameViewModel` → `PhoneConnectivityManager`) pushes a
  lightweight `WatchGameSnapshot` — role, arrest code, nearest-hunter
  distance/bearing, inventory, visible runners (if hunting) — to the Watch
  over `WCSession.updateApplicationContext`, throttled to roughly once every
  1.5s plus immediately on state transitions (caught, infected).
- The Watch (`WatchConnectivityManager`) renders that snapshot
  (`WatchGameView`) and sends action intents back — use a power-up, attempt
  a catch with a target + arrest code — via `sendMessage`
  (`transferUserInfo` as a queued fallback if the phone isn't immediately
  reachable). The phone receives these and forwards them into the same
  `usePowerUp`/`socket.attemptCatch` calls the in-app UI uses.
- A watch face complication (`HuntingGameComplication`, all three accessory
  families — circular, rectangular, inline) reads the same snapshot from a
  shared App Group container (`group.com.huntinggame.app.watch`) that the
  Watch app writes to on every update, then calls
  `WidgetCenter.shared.reloadAllTimelines()`. The complication extension has
  no network or WatchConnectivity access of its own by design — it's a pure,
  cheap reader of already-synced state.
- Haptics on the Watch go through `WKInterfaceDevice.play(_:)`
  (`WatchHaptics.swift`) rather than CoreHaptics, which doesn't exist on
  watchOS — a discrete proximity pulse fires once nearest-hunter distance
  drops under 25m, cooldown-limited the same way as the phone's version.

**Running it:** pair a physical Apple Watch with your test iPhone (or use
the paired Watch Simulator in Xcode — Simulator supports WatchConnectivity
between an iPhone simulator and a paired Watch simulator, though not real
GPS/haptics). Build and run the `HuntingGame` scheme as usual; Xcode installs
the embedded Watch app alongside it. First launch: give the Watch app a
few seconds after joining a game on the phone for the first
`updateApplicationContext` to land.

**Signing note:** the complication needs an **App Group** capability
(`group.com.huntinggame.app.watch`) on both `HuntingGameWatch` and
`HuntingGameWatchWidgets`, already declared in each target's
`.entitlements` file. With **Automatically manage signing** and a personal
(free) Apple ID team, Xcode registers App Groups for local device/simulator
builds automatically — if it complains, open each Watch-related target's
Signing & Capabilities tab and confirm the App Group is checked/created
under your team.

**Known gap:** there's no watch app icon bundled (`ASSETCATALOG_COMPILER_APPICON_NAME`
is intentionally left unset for the Watch targets) — fine for local
dev/testing, but add a proper `AppIcon.appiconset` with the watchOS-required
sizes under `Watch/HuntingGameWatch/Resources/` before any App Store
submission.

---

## 6. Building the sideloadable IPA

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

## 7. End-to-end smoke test

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

## 8. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen` |
| App can't reach the backend | Check `APIClient.baseURL` / `SocketService.serverURL`, and that the host is HTTPS (ATS blocks plain HTTP) |
| Socket connects then immediately disconnects | JWT expired/invalid, or the `Authorization`/`connectParams` token doesn't match what `io.use(...)` in `server.ts` expects |
| No power-ups spawn on game creation | Overpass API is rate-limited/unreachable — the backend falls back to random points inside your polygon automatically, so this degrades gracefully rather than failing |
| Live Activity never appears | Confirm iOS 16.2+, a physical device, Live Activities enabled in Settings, and that you joined as a **runner** (hunters don't get one by design) |
| `xcodebuild archive` fails immediately | Make sure you're on macOS with Xcode command line tools installed (`xcode-select --install`); `build_ipa.sh` checks for both and exits early with a clear message if either is missing |
| Background location stops after a while | `NSLocationAlwaysAndWhenInUseUsageDescription` + `UIBackgroundModes: [location]` are already set in `project.yml` — if you're testing via Xcode's debugger, background execution can still be throttled by the debugger itself; test with a real, detached install for accurate behavior |
