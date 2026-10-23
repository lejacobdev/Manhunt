import express from 'express';
import cors from 'cors';
import path from 'path';
import { randomUUID } from 'crypto';
import { createServer } from 'http';
import { Server, Socket } from 'socket.io';
import * as turf from '@turf/turf';
import jwt from 'jsonwebtoken';

import { authRouter } from './routes/auth';
import { friendsRouter } from './routes/friends';
import { gamesRouter } from './routes/games';
import { powerUpsRouter } from './routes/powerups';
import { invitesRouter } from './routes/invites';
import { adminRouter } from './routes/admin';
import { installAsyncRouteErrorForwarding } from './utils/asyncRouteErrors';
import { usersRouter } from './routes/users';
import { pushRouter } from './routes/push';
import { prisma } from './lib/prisma';
import { gameService, GameSettings } from './services/GameService';
import { checkAccuracy, checkMotion, checkSpeed, checkTeleport } from './services/AntiCheatService';
import { distanceOutsidePolygonMeters } from './services/BoundaryService';
import { ZoneState, computeZoneState, distanceOutsideZone } from './services/ZoneService';
import {
  DecoyMap,
  currentDecoyPosition,
  grantPowerUp,
  isBuffActive,
  isWithinAnySafeZone,
  pruneExpiredBuffs,
  pruneExpiredDecoys,
  usePowerUp,
} from './services/PowerUpService';
import {
  ABANDONED_SESSION_TIMEOUT_MS,
  AuthTokenPayload,
  BOUNDARY_BUFFER_METERS,
  BOUNDARY_DAMAGE_TICK_MS,
  BOUNDARY_WARNING_GRACE_MS,
  CATCH_REQUEST_TIMEOUT_MS,
  CATCH_VERIFICATION_RADIUS_METERS,
  POWER_UP_COLLECTION_RADIUS_METERS,
  THERMAL_VISION_RADIUS_METERS,
  RELEASE_PROTECTION_MS,
  CATCH_DISPUTE_TIMEOUT_MS,
  canUsePowerUp,
  powerUpRoleMessage,
  DEFAULT_BAIL_OUT_SECONDS,
  DEFAULT_JAIL_ARRIVAL_SECONDS,
  GameMode,
  JAIL_BUFFER_METERS,
  SAFE_ZONE_RADIUS_METERS,
  JAIL_VIOLATION_COUNTDOWN_MS,
  PlayerState,
  PowerUpType,
  ZONE_BROADCAST_INTERVAL_MS,
} from './types';

const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-secret-do-not-use-in-production';

export const app = express();
// Must run before any request is served: without it, an async handler that rejects leaves the
// request hanging instead of reaching the error middleware at the bottom of this file.
installAsyncRouteErrorForwarding();

app.use(cors({ origin: process.env.CORS_ORIGIN ?? '*' }));
app.use(express.json());

app.get('/health', (_req, res) => res.json({ ok: true, service: 'hunting-game-backend' }));

// Distribution has moved to TestFlight/App Store (see .github/workflows/testflight.yml) —
// this whole '/dist' tree is legacy SideStore/xtool sideloading, kept only for whatever
// raw IPA a personal dev build might still want (ios/xtool/docker-build.sh still writes
// here). It must NOT drive the in-app "update available" banner any more: that banner's
// version-compare and UI text are compiled into whatever's already shipped (including the
// TestFlight build, whose CFBundleShortVersionString is pinned at "1.0.0" — see
// project.yml's MARKETING_VERSION), while dist-static/source.json's SideStore-style
// "1.0.N" numbering keeps climbing independently of that. Left unhandled, every
// TestFlight/App Store install would permanently see "1.0.N" as newer than its own "1.0.0"
// and be told, wrongly, to "Install it from the SideStore/AltStore app." The route below
// intercepts this one path ahead of the static middleware and freezes its reported version
// at "0.0.0" — the minimum possible, so it can never register as newer than any real
// client on either channel — which suppresses that false nag without touching the already-
// compiled app. A real "check the App Store/TestFlight for updates" flow needs its own
// client-side support in a future build; this is the backend-only mitigation for now.
app.get('/dist/source.json', (_req, res) => {
  res.json({
    name: 'Hunting Game',
    identifier: 'dev.lejacob.huntinggame.source',
    iconURL: 'https://api.lejacob.dev/dist/icon.png',
    apps: [
      {
        name: 'Hunting Game',
        bundleIdentifier: 'com.huntinggame.app',
        developerName: 'lejacob.dev',
        localizedDescription: 'GPS manhunt: hunters vs. runners with live radar, power-ups, and squad play.',
        iconURL: 'https://api.lejacob.dev/dist/icon.png',
        versions: [
          {
            version: '0.0.0',
            date: new Date(0).toISOString(),
            downloadURL: 'https://api.lejacob.dev/dist/HuntingGame.ipa',
            size: 0,
            minOSVersion: '16.2',
            localizedDescription: 'Hunting Game now ships via TestFlight/App Store.',
          },
        ],
      },
    ],
  });
});

app.use('/dist', express.static(path.join(__dirname, '..', 'dist-static')));

app.use('/auth', authRouter);
app.use('/friends', friendsRouter);
app.use('/games', gamesRouter);
app.use('/powerups', powerUpsRouter);
app.use('/invites', invitesRouter);
app.use('/admin', adminRouter);
app.use('/users', usersRouter);
app.use('/push', (req, _res, next) => {
  console.log(`[PUSH] ${req.method} ${req.path} auth=${req.headers.authorization ? 'yes' : 'no'}`);
  next();
});
app.use('/push', pushRouter);

/**
 * The landing page a friend QR points at. The QR encodes an https:// URL rather than the
 * huntinggame:// scheme directly so that any camera app will actually offer to open it —
 * iOS Camera silently ignores unknown custom schemes. This page then bounces straight to
 * the app's own scheme, with a tap-through and an install link for anyone who lands here
 * without the app — the App Store (APP_STORE_URL). Scanning from *inside* the app skips
 * all of this and parses the tag directly.
 */
app.get('/u/:username/:tag', (req, res) => {
  const escape = (value: string) =>
    value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
  const username = escape(req.params.username.slice(0, 40));
  const tag = escape(req.params.tag.slice(0, 10));
  const deepLink = `huntinggame://add-friend?username=${encodeURIComponent(req.params.username)}&tag=${encodeURIComponent(req.params.tag)}`;
  const downloadUrl = process.env.APP_STORE_URL ?? 'https://lejacob.dev';

  res.type('html').send(`<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Add ${username}#${tag} on Hunting Game</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         background:#0b1114; color:#fff; font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
  .card { max-width:22rem; margin:1.5rem; padding:2rem 1.75rem; text-align:center;
          background:rgba(255,255,255,.05); border:1px solid rgba(255,255,255,.12); border-radius:1.25rem; }
  h1 { margin:0 0 .25rem; font-size:1.05rem; letter-spacing:.14em; text-transform:uppercase; color:#4dd0c7; }
  .tag { margin:.75rem 0 1.5rem; font-size:1.5rem; font-weight:700; }
  a { display:block; padding:.85rem 1rem; border-radius:.75rem; text-decoration:none; font-weight:600; }
  .primary { background:#3ddc84; color:#08130c; }
  .secondary { margin-top:.75rem; color:#9fb0b5; border:1px solid rgba(255,255,255,.15); }
  p { color:#9fb0b5; font-size:.85rem; margin:1.25rem 0 0; }
</style></head><body>
<div class="card">
  <h1>Hunting Game</h1>
  <div class="tag">${username}#${tag}</div>
  <a class="primary" href="${deepLink}">Add as friend</a>
  <a class="secondary" href="${downloadUrl}">Don't have the app?</a>
  <p>Opening Hunting Game&hellip; if nothing happens, tap "Add as friend".</p>
</div>
<script>location.replace(${JSON.stringify(deepLink)});</script>
</body></html>`);
});

/**
 * Last stop for anything a route or body parser throws. Without it Express answers with a
 * bare HTML "Bad Request" page, which the app can't decode — the player just sees
 * "Request failed with status 400." Every failure should reach them as a sentence instead.
 * (Must stay registered after every route above.)
 */
app.use((err: any, _req: express.Request, res: express.Response, next: express.NextFunction) => {
  if (res.headersSent) return next(err);
  if (err?.type === 'entity.parse.failed') {
    return res.status(400).json({ error: "That request couldn't be read. Please try again, and update the app if it keeps happening." });
  }
  if (err?.type === 'entity.too.large') {
    return res.status(413).json({ error: 'That request was too large to send.' });
  }
  console.error('[ERROR] unhandled route error:', err);
  return res.status(500).json({ error: 'Something went wrong on our side. Please try again in a moment.' });
});

export const httpServer = createServer(app);
export const io = new Server(httpServer, { cors: { origin: process.env.CORS_ORIGIN ?? '*' } });

// roomCode -> (gamePlayerId -> PlayerState)
const activeSessions: Map<string, Map<string, PlayerState>> = new Map();
// roomCode -> game mode, cached at join to avoid a DB hit per tick. Exported because the
// host can now change the mode from the lobby (PATCH /games/:code/settings), which has to
// live-patch this cache the same way sessionSettingsCache below is patched.
export const sessionModes: Map<string, GameMode> = new Map();
// roomCode -> immutable session settings (duration, radar interval, boundary)
export const sessionSettingsCache: Map<string, GameSettings> = new Map();
// roomCode -> match start time (epoch ms) — set at join if already started, or live-patched by the
// REST /games/:code/start route (see routes/games.ts) the moment the host starts the match.
export const sessionStartedAtCache: Map<string, number> = new Map();
// roomCode -> ghost decoys currently live
const decoys: DecoyMap = new Map();
// roomCode -> gamePlayerId -> epoch ms of when they were first detected outside the outer
// boundary polygon (either role) — drives the boundary "storm" warning + heart drain.
const boundaryViolationSince: Map<string, Map<string, number>> = new Map();
// roomCode -> gamePlayerId -> epoch ms of the last boundary damage tick applied to them
const boundaryLastDamageAt: Map<string, Map<string, number>> = new Map();
// roomCode -> gamePlayerId -> epoch ms of when a jailed runner was first detected outside
// the jail polygon — a 10s countdown from this moment, not a slow drain like the boundary.
const jailViolationSince: Map<string, Map<string, number>> = new Map();
// roomCode -> gamePlayerId -> epoch ms by which a sentenced runner must have set foot in
// the jail polygon. Cleared the moment they arrive; blowing past it is a disqualification
// for never turning up, which is a different failure from breaking out once inside.
const jailArrivalDeadline: Map<string, Map<string, number>> = new Map();
// roomCode -> gamePlayerId -> epoch ms since a *free* runner has been standing inside the
// jail polygon without leaving it. Reaching the host's configured dwell time springs every
// prisoner at once. Continuous, not cumulative: stepping out resets the clock, so a
// jailbreak means actually holding the spot rather than drifting past it repeatedly.
const bailDwellSince: Map<string, Map<string, number>> = new Map();
// roomCode -> runnerId -> the one pending catch request targeting them (a runner can only
// be asked about one catch at a time; a hunter, however, may have requests out to several
// runners at once, hence requestId to disambiguate which one a later deny-confirm is about).
const pendingCatchRequests: Map<
  string,
  Map<string, { requestId: string; hunterId: string; hunterUsername: string; requestedAt: number; deniedAt?: number }>
> = new Map();
// roomCode -> disputeId -> a catch the runner denied and the hunter insisted on; the host rules
// on it, or the server does once CATCH_DISPUTE_TIMEOUT_MS passes.
const pendingDisputes: Map<string, Map<string, { runnerId: string; hunterId: string; createdAt: number }>> = new Map();
// roomCode -> index of the last radar ping sent (pings are every radarIntervalSeconds from the
// match start, so the app can compute the same schedule for its countdown).
const lastPingIndex: Map<string, number> = new Map();
// hunter gamePlayerId -> whether their last radar push said "jammed", so the end of a jam can be
// announced even between pings.
const wasJammed: Map<string, boolean> = new Map();
// roomCode -> playerId -> epoch ms until which a just-freed runner can't be caught again.
const releaseProtection: Map<string, Map<string, number>> = new Map();
// roomCode -> epoch ms of when the room's last connected player left. Only rooms with
// nobody in them are in here; a rejoin removes the key. Drives the abandoned-session
// sweep below, which closes a game everyone walked away from rather than leaving it
// open forever for every one of its members.
const sessionEmptySince: Map<string, number> = new Map();
// roomCode -> runnerId -> an in-progress gamble duel. A gamble is no longer a single
// coin flip: once started it runs round after round until one side is out of hearts, so
// the pair has to be remembered between rounds while the runner calls each toss.
const activeGambles: Map<string, Map<string, { hunterId: string; round: number; lastCallAt: number }>> = new Map();
// roomCode -> the session's host userId, so host-only admin actions (end game, override a
// catch) can be authorized without a separate SUPERVISOR role — the host plays a normal
// role (hunter/runner/spectator) and keeps these powers regardless of which one.
const sessionHostCache: Map<string, string> = new Map();
// gamePlayerId -> last accepted fix, used for teleport detection and ghost-decoy bearing
const lastFix: Map<string, { lat: number; lng: number; timestamp: number }> = new Map();
// gamePlayerId -> the previous position at least 5 m back, for the Ghost Decoy's heading
const headingFrom: Map<string, { lat: number; lng: number }> = new Map();
// roomCode -> fingerprint of every visibility-changing buff, so the 1 s ticker can push a fresh
// radar and compass to everyone the moment one starts or runs out
const visibilityFingerprint: Map<string, string> = new Map();
// gamePlayerId -> fingerprint of that player's own active buffs, for buffs_update
const buffFingerprint: Map<string, string> = new Map();
// gamePlayerId -> pending location log entries flushed to Postgres periodically
const pendingLogs: Map<string, { playerId: string; lat: number; lng: number; accuracy: number; speed?: number }[]> = new Map();

// userId -> number of live sockets for that user (a user can be connected via both a
// presence-only connection and an active-match connection at once, hence a refcount
// rather than a plain set). Every authenticated socket counts here, regardless of
// whether it ever joins a game room — presence reflects "app is open", not "in a match".
const onlineUserRefCounts: Map<string, number> = new Map();

/** True if the given user currently has at least one live socket connection. */
export function isUserOnline(userId: string): boolean {
  return (onlineUserRefCounts.get(userId) ?? 0) > 0;
}

async function getAcceptedFriendIds(userId: string): Promise<string[]> {
  const friendships = await prisma.friendship.findMany({
    where: { status: 'ACCEPTED', OR: [{ senderId: userId }, { receiverId: userId }] },
    select: { senderId: true, receiverId: true },
  });
  return friendships.map((f) => (f.senderId === userId ? f.receiverId : f.senderId));
}

async function markUserOnline(userId: string) {
  const count = (onlineUserRefCounts.get(userId) ?? 0) + 1;
  onlineUserRefCounts.set(userId, count);
  if (count === 1) {
    const friendIds = await getAcceptedFriendIds(userId);
    for (const friendId of friendIds) {
      io.to(`user:${friendId}`).emit('friend_online', { userId });
    }
  }
}

async function markUserOffline(userId: string) {
  const count = (onlineUserRefCounts.get(userId) ?? 0) - 1;
  if (count <= 0) {
    onlineUserRefCounts.delete(userId);
    const friendIds = await getAcceptedFriendIds(userId);
    for (const friendId of friendIds) {
      io.to(`user:${friendId}`).emit('friend_offline', { userId });
    }
  } else {
    onlineUserRefCounts.set(userId, count);
  }
}

io.use((socket, next) => {
  // The iOS client sends the token three ways for robustness across
  // socket.io-client-swift versions (auth payload, query param, and the
  // Authorization header) — accept whichever one actually arrived.
  const authHeader = socket.handshake.headers.authorization;
  const token =
    (socket.handshake.auth?.token as string | undefined) ??
    (socket.handshake.query?.token as string | undefined) ??
    (authHeader?.startsWith('Bearer ') ? authHeader.slice('Bearer '.length) : undefined);
  if (!token) return next(new Error('Missing auth token.'));
  let decoded: AuthTokenPayload;
  try {
    decoded = jwt.verify(token, JWT_SECRET) as AuthTokenPayload;
  } catch {
    return next(new Error('Invalid or expired token.'));
  }

  // Tokens last a month, so a ban that only blocked sign-in would leave anyone already
  // holding one playing on for weeks. Checked here because the socket is where gameplay
  // actually happens — cutting it off is what a ban has to mean.
  prisma.user
    .findUnique({ where: { id: decoded.userId }, select: { isBanned: true } })
    .then((user) => {
      if (user?.isBanned) return next(new Error('This account has been suspended.'));
      socket.data.user = decoded;
      next();
    })
    .catch(() => next(new Error('Could not verify this account.')));
});

io.on('connection', (socket: Socket) => {
  const authedUser = socket.data.user as AuthTokenPayload;
  console.log(`[Socket] Connected: ${socket.id} (user=${authedUser.username})`);

  // Presence is independent of game membership — every authenticated socket (including
  // one just sitting on the lobby/friends screen) joins its own user room so friends and
  // invites can reach it, and counts toward "online" for the duration of the connection.
  socket.join(`user:${authedUser.userId}`);
  markUserOnline(authedUser.userId).catch((err) => console.error('[presence] markUserOnline failed', err));
  const country = socket.handshake.headers['cf-ipcountry'];
  if (typeof country === 'string' && /^[A-Z]{2}$/.test(country)) socketCountry.set(socket.id, country);
  socket.on('disconnect', () => {
    socketCountry.delete(socket.id);
    if (socket.rooms.has('admins')) setImmediate(() => emitAdminEvent('presence', { admins: adminsPresent() }));
  });

  // The admin panel's live channel. Re-checked against the database, like every admin route.
  socket.on('admin_subscribe', async () => {
    const user = await prisma.user.findUnique({ where: { id: authedUser.userId }, select: { isAdmin: true, isBanned: true } });
    if (!user?.isAdmin || user.isBanned) return;
    socket.join('admins');
    emitAdminEvent('presence', { admins: adminsPresent() });
  });

  socket.on('get_online_friends', async () => {
    const friendIds = await getAcceptedFriendIds(authedUser.userId);
    socket.emit('online_friends_snapshot', { onlineFriendIds: friendIds.filter(isUserOnline) });
  });

  socket.on('join_room', async ({ roomCode, gamePlayerId }: { roomCode: string; gamePlayerId: string }) => {
    try {
      const gamePlayer = await prisma.gamePlayer.findUnique({
        where: { id: gamePlayerId },
        include: { user: true, session: true },
      });
      if (!gamePlayer || gamePlayer.userId !== authedUser.userId || gamePlayer.session.code !== roomCode) {
        socket.emit('error_event', { reason: 'Player is not a member of this game.' });
        return;
      }

      socket.join(roomCode);
      // A personal room keyed by the player's own id — lets 1:1 events (a catch request,
      // a gamble result, a personal boundary/jail warning) target exactly one player via
      // io.to(gamePlayerId).emit(...) without needing to track socket ids directly.
      socket.join(gamePlayerId);
      socket.data.roomCode = roomCode;
      socket.data.gamePlayerId = gamePlayerId;
      sessionModes.set(roomCode, gamePlayer.session.mode as GameMode);
      sessionSettingsCache.set(roomCode, gamePlayer.session.settings as unknown as GameSettings);
      sessionHostCache.set(roomCode, gamePlayer.session.hostId);
      if (gamePlayer.session.startedAt) {
        sessionStartedAtCache.set(roomCode, gamePlayer.session.startedAt.getTime());
      }

      if (!activeSessions.has(roomCode)) activeSessions.set(roomCode, new Map());
      const session = activeSessions.get(roomCode)!;
      // Somebody's back — cancel any abandonment countdown started when the room emptied.
      sessionEmptySince.delete(roomCode);

      const state: PlayerState = {
        id: gamePlayer.id,
        userId: gamePlayer.userId,
        username: gamePlayer.user.username,
        role: gamePlayer.role,
        squad: gamePlayer.squad ?? undefined,
        lat: 0,
        lng: 0,
        speed: 0,
        accuracy: 9999,
        battery: gamePlayer.batteryLevel,
        isMovingOnFoot: true,
        arrestCode: gamePlayer.arrestCode,
        isCaught: gamePlayer.isCaught,
        isJailed: gamePlayer.isJailed,
        // A prisoner who reconnects has to be back inside the jail like everyone else. They
        // used to be marked as already there, which made reconnecting a way to skip the walk
        // (and stand anywhere); instead they get a fresh, full arrival window below, so a
        // dropped connection is never a disqualification either.
        hasReachedJail: false,
        isOut: gamePlayer.isOut,
        hearts: gamePlayer.hearts,
        inventory: (gamePlayer.inventory as PowerUpType[]) ?? [],
        activeBuffs: {},
        lastUpdate: Date.now(),
      };
      session.set(gamePlayer.id, state);

      if (gamePlayer.role === 'SPECTATOR' || gamePlayer.session.hostId === authedUser.userId) {
        // A pure observer — carries no inventory, takes no gameplay actions —
        // so gets the continuous full-roster feed that hunters/runners don't
        // (those only see each other via radar pings). The host also needs this
        // feed regardless of their own role, to run host-only actions like
        // overriding a disputed catch on any player.
        socket.join(`${roomCode}_observers`);
      }

      emitRoster(roomCode, session);

      // A match that's already running has to hand the clock to whoever just walked in.
      // game_started is otherwise only emitted once, by the REST start route, to sockets
      // already in the room — so anyone entering afterwards (the normal flow: join the
      // lobby, host starts, then you open the match) never learned when it began and
      // their "time left" readout stayed blank for the whole match.
      if (gamePlayer.session.startedAt) {
        socket.emit('game_started', { startedAt: gamePlayer.session.startedAt });
      }
      const jailSettings = sessionSettingsCache.get(roomCode);
      if (state.isJailed && !state.isOut && jailSettings?.jailEnabled && jailSettings.jailPolygon) {
        const arrivalMs = (jailSettings.jailArrivalSeconds ?? DEFAULT_JAIL_ARRIVAL_SECONDS) * 1000;
        const deadlines = jailArrivalDeadline.get(roomCode) ?? new Map<string, number>();
        jailArrivalDeadline.set(roomCode, deadlines);
        deadlines.set(state.id, Date.now() + arrivalMs);
        socket.emit('player_jailed', { runnerId: state.id, hunterId: '', arrivalDeadlineMs: arrivalMs, timestamp: new Date().toISOString() });
      }
      const zone = currentZone(roomCode);
      if (zone) socket.emit('zone_update', zone);
    } catch (err) {
      console.error('[join_room] failed', err);
      socket.emit('error_event', { reason: 'Failed to join room.' });
    }
  });

  socket.on(
    'send_location_update',
    async ({
      lat,
      lng,
      speed,
      accuracy,
      battery,
      isMovingOnFoot,
    }: {
      lat: number;
      lng: number;
      speed?: number;
      accuracy: number;
      battery: number;
      isMovingOnFoot: boolean;
    }) => {
      const roomCode = socket.data.roomCode as string | undefined;
      const gamePlayerId = socket.data.gamePlayerId as string | undefined;
      if (!roomCode || !gamePlayerId) return;

      // Match-timer expiry is checked on the hot path so the game ends the moment
      // it's due, not just on the 10s sweep — see that sweep below for the backstop.
      if (await endMatchIfExpired(roomCode)) return;

      const session = activeSessions.get(roomCode);
      if (!session || !session.has(gamePlayerId)) return;
      const p = session.get(gamePlayerId)!;
      // A jailed runner must keep reporting location so jail containment can still be
      // checked — everything else that's caught (non-jailed) or fully out stops here.
      if ((p.isCaught && !p.isJailed) || p.isOut) return;

      pruneExpiredBuffs(p);

      const now = Date.now();
      // BETA: off by default (absent means disabled) — a host opts in from the lobby.
      // The accuracy/motion/speed/teleport checks are new enough to produce false
      // positives, which looked exactly like a frozen radar/compass before
      // anti_cheat_warning was even surfaced to the rejected player.
      const antiCheatEnabled = sessionSettingsCache.get(roomCode)?.antiCheatEnabled ?? false;
      if (antiCheatEnabled) {
        const accuracyCheck = checkAccuracy(accuracy);
        if (!accuracyCheck.allowed) {
          flagAntiCheat(socket, roomCode, p, 'ACCURACY', accuracyCheck.reason!);
          return;
        }
        const motionCheck = checkMotion(isMovingOnFoot);
        if (!motionCheck.allowed) {
          flagAntiCheat(socket, roomCode, p, 'MOTION', motionCheck.reason!);
          return;
        }

        const speedCheck = checkSpeed(p, speed);
        if (!speedCheck.allowed) {
          flagAntiCheat(socket, roomCode, p, 'SPEED', speedCheck.reason!);
          return;
        }

        const prev = lastFix.get(gamePlayerId);
        if (!checkTeleport(prev, { lat, lng, timestamp: now }, speedCheck.ceilingMps)) {
          flagAntiCheat(socket, roomCode, p, 'TELEPORT', 'Position jump exceeds plausible foot travel for the elapsed time.');
          return;
        }
        lastFix.set(gamePlayerId, { lat, lng, timestamp: now });
      }

      // Where this player was walking from, for the Ghost Decoy's "away from me" heading.
      // Tracked on every fix: it used to come from the anti-cheat's lastFix, which only exists
      // when the host turns anti-cheat on, so decoys otherwise walked off in a random direction.
      if (p.accuracy < 9999 && turf.distance(turf.point([p.lng, p.lat]), turf.point([lng, lat]), { units: 'meters' }) >= 5) {
        headingFrom.set(gamePlayerId, { lat: p.lat, lng: p.lng });
      }
      p.lat = lat;
      p.lng = lng;
      p.speed = speed ?? 0;
      p.accuracy = accuracy;
      p.battery = battery;
      p.isMovingOnFoot = isMovingOnFoot;
      p.lastUpdate = now;

      const logs = pendingLogs.get(roomCode) ?? [];
      logs.push({ playerId: gamePlayerId, lat, lng, accuracy, speed });
      pendingLogs.set(roomCode, logs);

      const mode = sessionModes.get(roomCode) ?? 'STANDARD';
      const gameSessionId = await resolveSessionId(roomCode);

      if (p.role === 'RUNNER' && gameSessionId) {
        if (p.isJailed) {
          // Jail replaces play-area containment rather than stacking with it — a prisoner
          // is *required* to be in the jail, so they can't also be punished for where the
          // host happened to draw it. Clearing here matters because boundary_status is only
          // sent on a transition: without it, a runner caught while outside the zone keeps
          // a stuck "outside the zone" warning for the rest of the match, with no damage
          // behind it, which reads as the jail counting as in-zone.
          clearContainmentState(roomCode, p);
          // Two different jail clocks depending on whether they've got there yet: a
          // countdown to *reach* the jail, then a countdown to get *back* whenever they
          // wander out of it.
          if (p.hasReachedJail) {
            await checkJailContainment(roomCode, gameSessionId, p, session);
          } else {
            await checkJailArrival(roomCode, gameSessionId, p, session);
          }
        } else if (!p.isCaught && !p.isOut) {
          // The play area applies in Infection too: it used to be skipped there, so nobody
          // in an Infection match was ever held to the boundary or the shrinking zone.
          await checkContainment(roomCode, gameSessionId, p, session, mode);
          if (mode !== 'INFECTION') await checkBailProgress(roomCode, gameSessionId, p, session, mode);
        }
      } else if (p.role === 'HUNTER' && gameSessionId && !p.isOut) {
        await checkContainment(roomCode, gameSessionId, p, session, mode);
      }

      const allPlayers = Array.from(session.values());
      // A player is seeded into the session map at lat 0/lng 0, accuracy 9999 the moment
      // they join — before their phone has produced a first real GPS fix. Without this
      // guard, a hunter/runner who just joined (or hasn't granted location yet) reads as
      // sitting in the Gulf of Guinea, and every other player's compass/radar briefly
      // reports a "nearest hunter" or "visible runner" thousands of km away.
      const hasFix = (x: PlayerState) => x.accuracy < 9999;
      // A hunter can pick up and use INVISIBILITY_10MIN too — spawns aren't role-restricted
      // — so the runner's compass has to exclude an invisible hunter the same way the
      // hunter's own radar already excludes an invisible runner, or "invisibility" only
      // works for one direction of the matchup. !isOut excludes an eliminated player of
      // either role from threatening/appearing to the other side.
      const hunters = allPlayers.filter(
        (x) => x.role === 'HUNTER' && hasFix(x) && !x.isOut && !isBuffActive(x, 'INVISIBILITY_10MIN')
      );
      const runners = allPlayers.filter(
        (x) => x.role === 'RUNNER' && !x.isCaught && !x.isOut && hasFix(x)
      );

      // Radar/compass used to only ever refresh for the player whose own tick this was —
      // a stationary hunter's radar wouldn't learn a runner had reappeared (e.g. after a
      // reconnect) until the hunter themselves moved enough to trigger their own next
      // location update, and likewise for a stationary runner's compass. A mover's update
      // changes every *other* relevant player's bearing to them, so it's pushed to all of
      // them now, not just reflected back to the mover.
      if (p.role === 'HUNTER') {
        for (const runner of runners) pushCompassToRunner(roomCode, runner, hunters);
        pushRadarToHunter(roomCode, p, runners);
      } else if (p.role === 'RUNNER') {
        pushCompassToRunner(roomCode, p, hunters);
        // Every hunter — an invisible one is hidden from runners, not blind; filtering this
        // loop by `hunters` froze an invisible hunter's own radar for the whole minute.
        for (const hunter of visionSides(session).allHunters) pushRadarToHunter(roomCode, hunter, runners);
      }

      io.to(`${roomCode}_observers`).emit('roster_update', publicRoster(session).map((x) => ({ ...x, arrestCode: '' })));
    }
  );

  // The Watch's arrest-code catch. Same rules and the same outcome as a catch the runner
  // accepts on their phone — it used to skip hearts, jail and the Infection win check.
  socket.on(
    'attempt_catch',
    async ({ runnerId, arrestCode }: { runnerId: string; arrestCode: string }) => {
      const roomCode = socket.data.roomCode as string | undefined;
      const hunterId = socket.data.gamePlayerId as string | undefined;
      if (!roomCode || !hunterId) return;
      const session = activeSessions.get(roomCode);
      if (!session) return;
      const hunter = session.get(hunterId);
      const runner = session.get(runnerId);
      if (!hunter) return;
      const blocked = catchBlockedReason(roomCode, session, hunter, runner);
      if (blocked) {
        socket.emit('catch_failed', { reason: blocked });
        return;
      }
      if (runner!.arrestCode !== arrestCode) {
        socket.emit('catch_failed', { reason: 'Invalid arrest code.' });
        return;
      }
      pendingCatchRequests.get(roomCode)?.delete(runner!.id);
      await resolveCatch(roomCode, session, hunter, runner!);
    }
  );

  /**
   * STANDARD/SQUAD replacement for the code-entry attempt_catch above: no arrest code,
   * just a real-time request the runner has to answer (accept / gamble / deny). Same
   * proximity/role/squad/safe-zone validation as attempt_catch, minus the code check.
   */
  socket.on('request_catch', async ({ runnerId }: { runnerId: string }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const hunterId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !hunterId) return;

    const session = activeSessions.get(roomCode);
    if (!session) return;
    const hunter = session.get(hunterId);
    const runner = session.get(runnerId);
    const mode = sessionModes.get(roomCode) ?? 'STANDARD';

    if (!hunter) return;

    // A Ghost Decoy is a radar contact with no player behind it. Reaching one busts it.
    if (runnerId?.startsWith('decoy:')) {
      const list = decoys.get(roomCode) ?? [];
      decoys.set(roomCode, list.filter((d) => d.id !== runnerId));
      socket.emit('catch_failed', { reason: 'That was a Ghost Decoy. The runner is somewhere else.' });
      refreshRoomVision(roomCode);
      return;
    }

    const blocked = catchBlockedReason(roomCode, session, hunter, runner);
    if (blocked || !runner) {
      socket.emit('catch_failed', { reason: blocked ?? 'Target is not an active runner.' });
      return;
    }
    void mode;

    const requests = pendingCatchRequests.get(roomCode) ?? new Map();
    pendingCatchRequests.set(roomCode, requests);
    const existing = requests.get(runnerId);
    if (existing && existing.hunterId !== hunterId) {
      socket.emit('catch_failed', { reason: 'Another hunter already has a pending request with this runner.' });
      return;
    }

    const requestId = randomUUID();
    requests.set(runnerId, { requestId, hunterId, hunterUsername: hunter.username, requestedAt: Date.now() });
    socket.emit('catch_request_sent', { runnerId, requestId });
    io.to(runnerId).emit('catch_requested', { requestId, hunterId, hunterUsername: hunter.username });
  });

  /** Hunter-initiated cancel of their own pending request. */
  socket.on('cancel_catch_request', ({ runnerId }: { runnerId: string }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const hunterId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !hunterId) return;
    const requests = pendingCatchRequests.get(roomCode);
    const pending = requests?.get(runnerId);
    if (!pending || pending.hunterId !== hunterId) return;
    requests!.delete(runnerId);
    io.to(runnerId).emit('catch_request_cancelled', { hunterId });
  });

  /** The runner's answer to a pending catch request: accept it, gamble on it, or deny it. */
  socket.on(
    'respond_catch',
    async ({
      hunterId,
      decision,
      gambleChoice,
    }: {
      hunterId: string;
      decision: 'accept' | 'gamble' | 'deny';
      gambleChoice?: 'heads' | 'tails';
    }) => {
      const roomCode = socket.data.roomCode as string | undefined;
      const runnerId = socket.data.gamePlayerId as string | undefined;
      if (!roomCode || !runnerId) return;
      const session = activeSessions.get(roomCode);
      if (!session) return;
      const requests = pendingCatchRequests.get(roomCode);
      const pending = requests?.get(runnerId);
      if (!pending || pending.hunterId !== hunterId) {
        socket.emit('error_event', { reason: 'No pending catch request from that hunter.' });
        return;
      }
      const runner = session.get(runnerId);
      const hunter = session.get(hunterId);
      if (!runner || !hunter) return;

      if (decision === 'deny') {
        // Hands it to the hunter: "my mistake" drops it, "I caught them" escalates it to the
        // host as a dispute (catch_dispute). If the hunter says nothing, the runner's word
        // stands when the request times out — just as the hunter's stands if the runner says
        // nothing at all.
        pending.deniedAt = Date.now();
        io.to(hunter.id).emit('catch_deny_confirm', { requestId: pending.requestId, runnerUsername: runner.username });
        return;
      }

      requests!.delete(runnerId);
      const gameSessionId = await resolveSessionId(roomCode);
      if (!gameSessionId) return;
      const settings = sessionSettingsCache.get(roomCode);
      const mode = sessionModes.get(roomCode) ?? 'STANDARD';

      if (decision === 'accept') {
        await resolveCatch(roomCode, session, hunter, runner);
        return;
      }

      // decision === 'gamble' — opens a duel rather than resolving a single flip. Rounds
      // keep going (see gamble_call) until one side has no hearts left.
      if (!settings?.gamblingEnabled || !gambleChoice) {
        socket.emit('error_event', { reason: 'Gambling is not enabled for this match.' });
        return;
      }
      const duels = activeGambles.get(roomCode) ?? new Map();
      activeGambles.set(roomCode, duels);
      duels.set(runner.id, { hunterId: hunter.id, round: 0, lastCallAt: Date.now() });

      await resolveGambleRound(roomCode, gameSessionId, session, runner, hunter, gambleChoice, mode);
    }
  );

  /** A later round of an already-running gamble duel — the runner calls the next toss. */
  socket.on('gamble_call', async ({ choice }: { choice: 'heads' | 'tails' }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const runnerId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !runnerId) return;
    const session = activeSessions.get(roomCode);
    const duel = activeGambles.get(roomCode)?.get(runnerId);
    if (!session || !duel) {
      socket.emit('error_event', { reason: 'No gamble is currently running.' });
      return;
    }
    const runner = session.get(runnerId);
    const hunter = session.get(duel.hunterId);
    if (!runner || !hunter) return;
    if (choice !== 'heads' && choice !== 'tails') return;

    duel.lastCallAt = Date.now();
    const gameSessionId = await resolveSessionId(roomCode);
    if (!gameSessionId) return;
    const mode = sessionModes.get(roomCode) ?? 'STANDARD';
    await resolveGambleRound(roomCode, gameSessionId, session, runner, hunter, choice, mode);
  });

  /** Hunter confirms a runner's "no, that wasn't a catch" really was accidental — drops the
   *  pending request with no consequence to either side. */
  socket.on('catch_deny_ack', ({ requestId }: { requestId: string }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const hunterId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !hunterId) return;
    const requests = pendingCatchRequests.get(roomCode);
    if (!requests) return;
    for (const [runnerId, req] of requests.entries()) {
      if (req.requestId === requestId && req.hunterId === hunterId) {
        requests.delete(runnerId);
        io.to(runnerId).emit('catch_request_cancelled', { hunterId });
        break;
      }
    }
  });

  /** The hunter insists on a catch the runner denied. The host rules on it; if the host is one
   *  of the two players, or doesn't rule in time, the catch stands — the request already
   *  proved the hunter was within catching distance. */
  socket.on('catch_dispute', ({ requestId }: { requestId: string }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const hunterId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !hunterId) return;
    const session = activeSessions.get(roomCode);
    const requests = pendingCatchRequests.get(roomCode);
    if (!session || !requests) return;
    for (const [runnerId, req] of requests.entries()) {
      if (req.requestId !== requestId || req.hunterId !== hunterId) continue;
      requests.delete(runnerId);
      const runner = session.get(runnerId);
      const hunter = session.get(hunterId);
      if (!runner || !hunter) return;
      const hostUserId = sessionHostCache.get(roomCode);
      const host = Array.from(session.values()).find((x) => x.userId === hostUserId);
      if (!host || host.id === hunterId || host.id === runnerId) {
        void resolveCatch(roomCode, session, hunter, runner, 'The host is part of this catch, so it stands.');
        return;
      }
      const disputeId = randomUUID();
      const disputes = pendingDisputes.get(roomCode) ?? new Map();
      pendingDisputes.set(roomCode, disputes);
      disputes.set(disputeId, { runnerId, hunterId, createdAt: Date.now() });
      const distance = Math.round(turf.distance(turf.point([hunter.lng, hunter.lat]), turf.point([runner.lng, runner.lat]), { units: 'meters' }));
      io.to(host.id).emit('catch_dispute', {
        disputeId,
        hunterUsername: hunter.username,
        runnerUsername: runner.username,
        distanceMeters: distance,
        timeoutMs: CATCH_DISPUTE_TIMEOUT_MS,
      });
      io.to(hunterId).emit('catch_dispute_pending', { runnerUsername: runner.username });
      io.to(runnerId).emit('catch_dispute_pending', { hunterUsername: hunter.username });
      return;
    }
  });

  /** The host's ruling on a disputed catch. */
  socket.on('resolve_dispute', async ({ disputeId, catchStands }: { disputeId: string; catchStands: boolean }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const callerId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !callerId) return;
    const session = activeSessions.get(roomCode);
    const caller = session?.get(callerId);
    if (!session || !caller || !(await isSessionHost(roomCode, caller.userId))) {
      socket.emit('error_event', { reason: 'Only the host can rule on a disputed catch.' });
      return;
    }
    const dispute = pendingDisputes.get(roomCode)?.get(disputeId);
    if (!dispute) return;
    pendingDisputes.get(roomCode)!.delete(disputeId);
    const hunter = session.get(dispute.hunterId);
    const runner = session.get(dispute.runnerId);
    if (!hunter || !runner) return;
    if (catchStands) {
      await resolveCatch(roomCode, session, hunter, runner, 'The host ruled it a catch.');
    } else {
      io.to(hunter.id).emit('catch_failed', { reason: `The host ruled that ${runner.username} wasn't caught.` });
      io.to(runner.id).emit('catch_request_cancelled', { hunterId: hunter.id });
    }
  });

  /** Squad mode: revive a caught teammate within arm's reach. */
  socket.on('revive_teammate', async ({ targetId }: { targetId: string }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const reviverId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !reviverId) return;
    const session = activeSessions.get(roomCode);
    if (!session) return;
    const mode = sessionModes.get(roomCode) ?? 'STANDARD';
    if (mode !== 'SQUAD') {
      socket.emit('error_event', { reason: 'Revives are only available in Squad mode.' });
      return;
    }

    const reviver = session.get(reviverId);
    const target = session.get(targetId);
    // With jail on, the way to free a teammate is a jailbreak — a free revive would make the
    // jail (and the heart a jailbreak costs) pointless, and used to leave the revived player
    // half-jailed.
    const reviveSettings = sessionSettingsCache.get(roomCode);
    if (reviveSettings?.jailEnabled && reviveSettings.jailPolygon) {
      socket.emit('error_event', { reason: 'With jail mode on, free your squad with a jailbreak instead.' });
      return;
    }
    if (!reviver || !target || !target.isCaught || target.isOut) {
      socket.emit('error_event', { reason: 'Nothing to revive.' });
      return;
    }
    if (reviver.isCaught || reviver.isOut) {
      socket.emit('error_event', { reason: 'You have to be free yourself to revive a teammate.' });
      return;
    }
    if (!reviver.squad || reviver.squad !== target.squad) {
      socket.emit('error_event', { reason: 'You can only revive your own squad.' });
      return;
    }
    const dist = turf.distance(turf.point([reviver.lng, reviver.lat]), turf.point([target.lng, target.lat]), {
      units: 'meters',
    });
    if (dist > CATCH_VERIFICATION_RADIUS_METERS) {
      socket.emit('error_event', { reason: `Too far to revive (${Math.round(dist)}m away).` });
      return;
    }

    await releaseRunner(roomCode, target, reviver.id);
  });

  /** Host admin override: force-resolve a disputed catch/status. Authorized by GameSession.hostId, not a role. */
  socket.on('host_override', async ({ targetId, isCaught }: { targetId: string; isCaught: boolean }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const callerId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !callerId) return;
    const session = activeSessions.get(roomCode);
    if (!session) return;
    const caller = session.get(callerId);
    if (!caller || !(await isSessionHost(roomCode, caller.userId))) {
      socket.emit('error_event', { reason: 'Only the host can override player status.' });
      return;
    }
    const target = session.get(targetId);
    if (!target) {
      socket.emit('error_event', { reason: 'Player not found.' });
      return;
    }

    if (target.role !== 'RUNNER' || target.isOut) {
      socket.emit('error_event', { reason: 'Only a runner still in the match can be marked caught or free.' });
      return;
    }
    // Through the same rules as any other catch or release: a heart, jail, Infection's switch
    // of sides, and the win check. It used to flip a flag and nothing else, so an overridden
    // catch cost no heart and could never end the match, and "free" left a prisoner jailed.
    if (isCaught && !target.isCaught) {
      pendingCatchRequests.get(roomCode)?.delete(target.id);
      await resolveCatch(roomCode, session, caller, target, 'The host marked this catch.');
    } else if (!isCaught && target.isCaught) {
      await releaseRunner(roomCode, target, caller.id);
    }
    const gameSessionId = await resolveSessionId(roomCode);
    if (gameSessionId) {
      await prisma.gameEvent.create({
        data: { sessionId: gameSessionId, type: 'HOST_OVERRIDE', payload: { playerId: target.id, isCaught, timestamp: new Date().toISOString() } },
      });
    }
    io.to(roomCode).emit('host_override_applied', { playerId: target.id, isCaught: target.isCaught, timestamp: new Date().toISOString() });
  });

  /** Host admin action: force-end the match immediately. Authorized by GameSession.hostId, not a role. */
  socket.on('host_end_game', async () => {
    const roomCode = socket.data.roomCode as string | undefined;
    const callerId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !callerId) return;
    const session = activeSessions.get(roomCode);
    const caller = session?.get(callerId);
    if (!caller || !(await isSessionHost(roomCode, caller.userId))) {
      socket.emit('error_event', { reason: 'Only the host can end the match.' });
      return;
    }
    await endMatch(roomCode, 'HOST_ENDED');
  });

  /**
   * Host-only lobby action: assign or change any player's role, including the host's own.
   * Role used to only ever be picked once, before joining — now it's fixed at RUNNER on
   * join and entirely up to the host to assign from the roster once everyone's in. Only
   * valid pre-match: sessionStartedAtCache is set exactly once, by the /start route, right
   * when the match actually begins.
   */
  socket.on('set_player_role', async ({ targetId, role }: { targetId: string; role: 'HUNTER' | 'RUNNER' | 'SPECTATOR' }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const callerId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !callerId) return;
    const session = activeSessions.get(roomCode);
    if (!session) return;
    const caller = session.get(callerId);
    if (!caller || !(await isSessionHost(roomCode, caller.userId))) {
      socket.emit('error_event', { reason: 'Only the host can change player roles.' });
      return;
    }
    if (sessionStartedAtCache.has(roomCode)) {
      socket.emit('error_event', { reason: 'Roles can only be changed before the match starts.' });
      return;
    }
    const target = session.get(targetId);
    if (!target) {
      socket.emit('error_event', { reason: 'Player not found.' });
      return;
    }

    const updated = await gameService.setPlayerRole(targetId, role);
    target.role = role;
    target.hearts = updated.hearts;

    emitRoster(roomCode, session);
  });

  socket.on('collect_powerup', async ({ spawnId }: { spawnId: string }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const gamePlayerId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !gamePlayerId) return;
    const session = activeSessions.get(roomCode);
    if (!session || !session.has(gamePlayerId)) return;
    const player = session.get(gamePlayerId)!;

    if (player.isCaught || player.isOut) {
      socket.emit('error_event', { reason: "You can't pick up power-ups while caught or out." });
      return;
    }
    const spawn = await prisma.powerUpSpawn.findUnique({ where: { id: spawnId } });
    if (!spawn || spawn.isCollected || spawn.expiresAt < new Date()) {
      socket.emit('error_event', { reason: 'Power-up is no longer available.' });
      return;
    }
    const distance = turf.distance(
      turf.point([player.lng, player.lat]),
      turf.point([spawn.longitude, spawn.latitude]),
      { units: 'meters' }
    );
    // Widen by the collector's own reported GPS accuracy — same reasoning as the zone-grace
    // fix: a flat radius smaller than plausible GPS error means a player standing right on
    // top of the spawn can still get rejected as "too far" purely from signal noise.
    const effectiveRadius = Math.max(POWER_UP_COLLECTION_RADIUS_METERS, player.accuracy);
    if (distance > effectiveRadius) {
      socket.emit('error_event', { reason: 'Too far from the power-up to collect it.' });
      return;
    }

    const gameSessionId = await resolveSessionId(roomCode);
    if (!gameSessionId) return;

    // ADRENALINE's whole effect is bonus hearts, which only mean anything to someone who
    // can be caught — so it's a runner-only pickup, and the map feed hides it from anyone
    // else too (see routes/powerups.ts) rather than letting them walk to it and be refused.
    // Same for every power-up that only helps one side (POWER_UP_ROLES): hidden from the other
    // side's map feed, and refused here if they reach it anyway.
    if (!canUsePowerUp(player.role, spawn.type as PowerUpType)) {
      socket.emit('error_event', { reason: powerUpRoleMessage(spawn.type as PowerUpType).replace('use', 'pick up') });
      return;
    }

    grantPowerUp(player, spawn.type as PowerUpType);
    await gameService.recordPowerUpCollected(gameSessionId, spawn.id, gamePlayerId);
    await prisma.gamePlayer.update({ where: { id: gamePlayerId }, data: { inventory: player.inventory } });

    io.to(roomCode).emit('powerup_collected', { playerId: gamePlayerId, spawnId, type: spawn.type });
    socket.emit('inventory_update', { inventory: player.inventory });
  });

  socket.on('use_powerup', async ({ powerUpType }: { powerUpType: PowerUpType }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const gamePlayerId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !gamePlayerId) return;
    const session = activeSessions.get(roomCode);
    if (!session) return;

    // A no-catch bubble over the jail would make every jailbreak risk-free.
    if (powerUpType === 'SAFE_ZONE_FLARE') {
      const caster = session.get(gamePlayerId);
      const jailSettings = sessionSettingsCache.get(roomCode);
      if (caster && jailSettings?.jailEnabled && jailSettings.jailPolygon &&
          distanceOutsidePolygonMeters({ lat: caster.lat, lng: caster.lng }, jailSettings.jailPolygon) <= SAFE_ZONE_RADIUS_METERS + JAIL_BUFFER_METERS) {
        socket.emit('error_event', { reason: "Safe Zone Flares don't work at the jail." });
        return;
      }
    }

    let runnerBearingDegrees: number | undefined;
    if (powerUpType === 'GHOST_DECOY') {
      const from = headingFrom.get(gamePlayerId);
      const player = session.get(gamePlayerId);
      if (from && player) {
        runnerBearingDegrees = turf.bearing(turf.point([from.lng, from.lat]), turf.point([player.lng, player.lat]));
      }
    }

    const result = usePowerUp(
      session,
      gamePlayerId,
      powerUpType,
      decoys,
      roomCode,
      runnerBearingDegrees,
      sessionSettingsCache.get(roomCode)?.boundsPolygon
    );
    if (!result.ok) {
      socket.emit('error_event', { reason: result.error });
      return;
    }

    const player = session.get(gamePlayerId)!;
    const gameSessionId = await resolveSessionId(roomCode);
    if (gameSessionId) {
      await gameService.recordPowerUpUsed(gameSessionId, gamePlayerId, powerUpType);
      await prisma.gamePlayer.update({
        where: { id: gamePlayerId },
        data: result.heartsChanged
          ? { inventory: player.inventory, hearts: player.hearts }
          : { inventory: player.inventory },
      });
    }

    // ADRENALINE's bonus hearts ride the same hearts_update every other heart change uses,
    // so the HUD, host panel and spectator roster all pick them up without a special case.
    if (result.heartsChanged) {
      io.to(roomCode).emit('hearts_update', { playerId: player.id, hearts: player.hearts, cause: 'ADRENALINE' });
    }

    socket.emit('inventory_update', { inventory: player.inventory });
    if (result.broadcastEvent) {
      io.to(roomCode).emit(result.broadcastEvent.type, result.broadcastEvent.payload);
    }

    // The caster's confirmation, with the real expiry — the app starts its countdown from
    // this rather than optimistically, so a refused power-up never shows as running.
    const payload = result.broadcastEvent?.payload ?? {};
    socket.emit('powerup_activated', {
      type: powerUpType,
      expiresAt: payload.expiresAt,
      jammedCount: Array.isArray(payload.jammedHunterIds) ? payload.jammedHunterIds.length : undefined,
    });
    // Every radar and compass reflects the change now, not on whoever's next GPS fix.
    refreshRoomVision(roomCode);
  });

  socket.on('leave_room', () => cleanupSocket(socket));
  socket.on('disconnect', () => {
    cleanupSocket(socket);
    markUserOffline(authedUser.userId).catch((err) => console.error('[presence] markUserOffline failed', err));
  });
});

function cleanupSocket(socket: Socket) {
  const roomCode = socket.data.roomCode as string | undefined;
  const gamePlayerId = socket.data.gamePlayerId as string | undefined;
  if (!roomCode || !gamePlayerId) return;

  const session = activeSessions.get(roomCode);
  if (session) {
    session.delete(gamePlayerId);
    io.to(roomCode).emit('player_left', { gamePlayerId });
    if (session.size === 0) {
      // Last one out. The room's live state goes now, but the *session* stays open for
      // ABANDONED_SESSION_TIMEOUT_MS so a dropped connection or a quick app restart can
      // walk straight back into it; only if nobody does is it closed for everyone.
      sessionEmptySince.set(roomCode, Date.now());
      activeSessions.delete(roomCode);
      sessionModes.delete(roomCode);
      sessionSettingsCache.delete(roomCode);
      sessionStartedAtCache.delete(roomCode);
      sessionHostCache.delete(roomCode);
      decoys.delete(roomCode);
      boundaryViolationSince.delete(roomCode);
      boundaryLastDamageAt.delete(roomCode);
      jailViolationSince.delete(roomCode);
      jailArrivalDeadline.delete(roomCode);
      bailDwellSince.delete(roomCode);
      pendingCatchRequests.delete(roomCode);
      pendingDisputes.delete(roomCode);
      releaseProtection.delete(roomCode);
      lastPingIndex.delete(roomCode);
      visibilityFingerprint.delete(roomCode);
      activeGambles.delete(roomCode);
    }
  }

  // A duel dies with either participant leaving — the runner is out of the session map
  // entirely at this point, so there's nothing left to resolve rounds against.
  const duels = activeGambles.get(roomCode);
  if (duels) {
    duels.delete(gamePlayerId);
    for (const [runnerId, duel] of Array.from(duels.entries())) {
      if (duel.hunterId === gamePlayerId) {
        duels.delete(runnerId);
        io.to(runnerId).emit('gamble_cancelled', { hunterId: gamePlayerId });
      }
    }
  }

  // A leaving player might be the target or the requester of a pending catch request —
  // either way it no longer makes sense to leave it live.
  const requests = pendingCatchRequests.get(roomCode);
  if (requests) {
    requests.delete(gamePlayerId);
    for (const [runnerId, req] of Array.from(requests.entries())) {
      if (req.hunterId === gamePlayerId) {
        requests.delete(runnerId);
        io.to(runnerId).emit('catch_request_cancelled', { hunterId: gamePlayerId });
      }
    }
  }
  boundaryViolationSince.get(roomCode)?.delete(gamePlayerId);
  boundaryLastDamageAt.get(roomCode)?.delete(gamePlayerId);
  jailViolationSince.get(roomCode)?.delete(gamePlayerId);
  jailArrivalDeadline.get(roomCode)?.delete(gamePlayerId);
  bailDwellSince.get(roomCode)?.delete(gamePlayerId);
  lastFix.delete(gamePlayerId);
}

/**
 * Roster snapshot for broadcasts that reach more than just the player themself
 * (player_joined, roster_update — the latter continuously, to the host and any
 * spectators). Hunter radar and the runner compass already exclude an invisible
 * player from their respective feeds, but these two events send the raw roster
 * with real coordinates to everyone in the room/observers group regardless — an
 * invisible player's exact live position was still rendering as a map pin for
 * the host and spectators the whole time INVISIBILITY_10MIN was active. Masks
 * an invisible player's position to the same lat0/lng0 sentinel already used
 * elsewhere in this codebase for "no valid position", which the client already
 * needs to treat as un-plottable for that other reason.
 */
/**
 * The roster as one player is allowed to see it. Hosts and spectators get the observer view
 * (publicRoster). Everyone else gets the other side's players without coordinates, and nobody's
 * arrest code but their own: the whole point of the radar and compass is that finding the
 * other side takes tracking, and the roster used to hand every hunter every runner's position.
 */
function rosterFor(roomCode: string, viewer: PlayerState, session: Map<string, PlayerState>): PlayerState[] {
  const observer = viewer.role === 'SPECTATOR' || sessionHostCache.get(roomCode) === viewer.userId;
  return publicRoster(session).map((p) => {
    if (p.id === viewer.id) return p;
    const hidePosition = !observer && p.role !== viewer.role;
    return { ...p, arrestCode: '', ...(hidePosition ? { lat: 0, lng: 0 } : {}) };
  });
}

/** Sends each player in the room their own view of the roster. */
function emitRoster(roomCode: string, session: Map<string, PlayerState>) {
  for (const viewer of session.values()) io.to(viewer.id).emit('player_joined', rosterFor(roomCode, viewer, session));
}

function publicRoster(session: Map<string, PlayerState>): PlayerState[] {
  return Array.from(session.values()).map((p) => {
    if (!isBuffActive(p, 'INVISIBILITY_10MIN')) return p;
    return { ...p, lat: 0, lng: 0 };
  });
}

/**
 * Recomputes and pushes one runner's compass reading (bearing/distance to every visible
 * hunter). Factored out of `send_location_update` so it can fire either from that runner's
 * own tick, or — whenever a hunter's tick lands — for every runner in the room at once.
 * Without the latter, a runner learned a hunter appeared, moved, or reconnected only on
 * their own next GPS tick, which could be indefinitely if they happened to be standing
 * still — this is also what made a just-reconnected player invisible to everyone else
 * until they personally moved enough to trigger their own send_location_update.
 */
function pushCompassToRunner(roomCode: string, runner: PlayerState, allHunters: PlayerState[], ping = false) {
  if (runner.isCaught) return;
  // The compass follows the same ping interval as the hunters' radar — both sides get the
  // same amount of information.
  if (radarInterval(roomCode) > 0 && !ping) return;
  const next = nextPingAt(roomCode);
  // In Squad mode your own squad's hunters aren't a threat to you, so they aren't on it.
  const hunters = (sessionModes.get(roomCode) ?? 'STANDARD') === 'SQUAD'
    ? allHunters.filter((h) => h.squad !== runner.squad)
    : allHunters;
  if (hunters.length === 0) {
    // Every hunter is invisible, out, or has no fix yet. Returning early here used to leave
    // the runner's compass pointing at the last hunter it saw for as long as that lasted.
    io.to(runner.id).emit('compass_update', { distanceMeters: null, bearingDegrees: null, hunters: [], nextPingAt: next });
    return;
  }
  const rPt = turf.point([runner.lng, runner.lat]);
  const bearings = hunters
    .map((h) => {
      const hPt = turf.point([h.lng, h.lat]);
      return {
        hunterId: h.id,
        username: h.username,
        distanceMeters: Math.round(turf.distance(rPt, hPt, { units: 'meters' })),
        bearingDegrees: (turf.bearing(rPt, hPt) + 360) % 360,
      };
    })
    .sort((a, b) => a.distanceMeters - b.distanceMeters);
  io.to(runner.id).emit('compass_update', {
    // Kept at the top level (redundant with bearings[0]) for older clients/watch app code
    // that only ever reads a single nearest distance/bearing.
    distanceMeters: bearings[0].distanceMeters,
    bearingDegrees: bearings[0].bearingDegrees,
    hunters: bearings,
    nextPingAt: next,
  });
}

/** Mirrors `pushCompassToRunner` for a hunter's radar — pushed either from that hunter's
 *  own tick, or for every hunter in the room whenever a runner's tick lands, each
 *  respecting their own Thermal Vision/EMP Jammer buffs individually. */
function pushRadarToHunter(roomCode: string, hunter: PlayerState, runners: PlayerState[], ping = false) {
  const next = nextPingAt(roomCode);
  if (isBuffActive(hunter, 'EMP_JAMMER')) {
    // A jammed hunter's radar goes dark at once and misses every ping until the jam ends.
    wasJammed.set(hunter.id, true);
    io.to(hunter.id).emit('radar_broadcast', { runners: [], runnerBearings: [], decoys: [], heat: [], jammed: true, live: false, nextPingAt: next });
    return;
  }
  const thermalActive = isBuffActive(hunter, 'THERMAL_VISION');
  // With a ping interval the radar only updates on each ping — except under Thermal Vision,
  // which tracks live. Continuous matches (interval 0) update on every fix as before.
  const live = radarInterval(roomCode) === 0 || thermalActive;
  if (!live && !ping) {
    if (wasJammed.get(hunter.id)) {
      // The jam just ended between pings: clear the JAMMED state; contacts return at the next ping.
      wasJammed.set(hunter.id, false);
      io.to(hunter.id).emit('radar_broadcast', { runners: [], runnerBearings: [], decoys: [], heat: [], jammed: false, live: false, nextPingAt: next });
    }
    return;
  }
  wasJammed.set(hunter.id, false);
  const hunterPt = turf.point([hunter.lng, hunter.lat]);
  // In Squad mode a hunter only chases other squads' runners, so their own squad's runners
  // (whom they can't catch) aren't radar contacts.
  if ((sessionModes.get(roomCode) ?? 'STANDARD') === 'SQUAD') runners = runners.filter((r) => r.squad !== hunter.squad);
  const distanceTo = (lat: number, lng: number) => turf.distance(hunterPt, turf.point([lng, lat]), { units: 'meters' });

  // Invisible runners are off the radar — except to a hunter running Thermal Vision, who sees
  // through it within THERMAL_VISION_RADIUS_METERS (a heat camera, not a map of the town).
  const visibleRunners = runners.filter(
    (r) => !isBuffActive(r, 'INVISIBILITY_10MIN') || (thermalActive && distanceTo(r.lat, r.lng) <= THERMAL_VISION_RADIUS_METERS)
  );
  const contacts: PlayerState[] = [...visibleRunners];

  // Ghost Decoys appear as ordinary runner contacts — same name as the runner who dropped
  // them, same shape — so a hunter can't tell which one is real. They used to be sent in a
  // separate, labelled `decoys` list that the app drew with its own icon, which gave every
  // decoy away. Thermal Vision shows no decoys: they have no heat signature.
  if (!thermalActive) {
    pruneExpiredDecoys(decoys, roomCode);
    const session = activeSessions.get(roomCode);
    for (const d of decoys.get(roomCode) ?? []) {
      const owner = session?.get(d.sessionOwnerId);
      if (!owner || owner.isCaught || owner.isOut) continue;
      if ((sessionModes.get(roomCode) ?? 'STANDARD') === 'SQUAD' && owner.squad === hunter.squad) continue;
      const pos = currentDecoyPosition(d);
      contacts.push({ ...owner, id: d.id, lat: pos.lat, lng: pos.lng, inventory: [], activeBuffs: {} });
    }
  }

  const runnerBearings = contacts
    .map((r) => ({
      runnerId: r.id,
      username: r.username,
      distanceMeters: Math.round(distanceTo(r.lat, r.lng)),
      bearingDegrees: (turf.bearing(hunterPt, turf.point([r.lng, r.lat])) + 360) % 360,
    }))
    .sort((a, b) => a.distanceMeters - b.distanceMeters);
  const order = new Map(runnerBearings.map((b, i) => [b.runnerId, i]));
  contacts.sort((a, b) => order.get(a.id)! - order.get(b.id)!);
  // Bearing and distance only: the contact list carries no coordinates or arrest codes. It used
  // to ship every visible runner's exact position and code to the hunter's phone — never drawn,
  // but readable by a modified app, and the privacy policy promises hunters only a bearing.
  const sanitized = contacts.map((r) => ({ ...r, lat: 0, lng: 0, arrestCode: '', inventory: [], activeBuffs: {} }));
  // Thermal Vision's visible effect: every runner within 300 m — invisible ones included, decoys
  // not (no heat) — as a heat signature on the hunter's map. Before this, thermal only mattered
  // when a runner nearby happened to be invisible, so in most matches it did nothing at all.
  const heat = thermalActive
    ? runners
        .filter((r) => distanceTo(r.lat, r.lng) <= THERMAL_VISION_RADIUS_METERS)
        .map((r) => ({ id: r.id, lat: r.lat, lng: r.lng }))
    : [];
  io.to(hunter.id).emit('radar_broadcast', { runners: sanitized, runnerBearings, decoys: [], heat, jammed: false, live, nextPingAt: next });
}

/** Seconds between pings for this room; 0 means continuous. */
function radarInterval(roomCode: string): number {
  return Math.max(0, Math.min(600, sessionSettingsCache.get(roomCode)?.radarIntervalSeconds ?? 0));
}

/** When the next ping lands, for the app's countdown; null when the radar is continuous. */
function nextPingAt(roomCode: string): number | null {
  const interval = radarInterval(roomCode);
  const started = sessionStartedAtCache.get(roomCode);
  if (!interval || !started) return null;
  const k = Math.floor((Date.now() - started) / (interval * 1000)) + 1;
  return started + k * interval * 1000;
}

/** Who can see whom right now: the same filters the location handler uses. */
function visionSides(session: Map<string, PlayerState>) {
  const all = Array.from(session.values());
  const hasFix = (x: PlayerState) => x.accuracy < 9999;
  return {
    hunters: all.filter((x) => x.role === 'HUNTER' && hasFix(x) && !x.isOut && !isBuffActive(x, 'INVISIBILITY_10MIN')),
    allHunters: all.filter((x) => x.role === 'HUNTER' && hasFix(x) && !x.isOut),
    runners: all.filter((x) => x.role === 'RUNNER' && !x.isCaught && !x.isOut && hasFix(x)),
  };
}

/** Pushes a fresh radar to every hunter and compass to every runner in the room. */
function refreshRoomVision(roomCode: string, ping = false) {
  const session = activeSessions.get(roomCode);
  if (!session) return;
  const { hunters, allHunters, runners } = visionSides(session);
  for (const runner of runners) pushCompassToRunner(roomCode, runner, hunters, ping);
  // Every hunter, including an invisible one: invisibility hides you from runners, not from
  // your own radar.
  for (const hunter of allHunters) pushRadarToHunter(roomCode, hunter, runners, ping);
}

/** Each player's own active buffs and their expiry, so the app's badges follow the server. */
function pushBuffs(p: PlayerState) {
  const now = Date.now();
  const buffs: Record<string, number> = {};
  for (const [type, buff] of Object.entries(p.activeBuffs)) {
    if (buff && buff.expiresAt > now) buffs[type] = buff.expiresAt;
  }
  const fingerprint = JSON.stringify(buffs);
  if (buffFingerprint.get(p.id) === fingerprint) return;
  buffFingerprint.set(p.id, fingerprint);
  io.to(p.id).emit('buffs_update', { buffs });
}

/**
 * The power-up clock, once a second per room. Buffs used to start and stop mattering only
 * when someone's GPS fix happened to arrive: an EMP'd hunter kept a working radar until they
 * moved, an expired Invisibility kept a runner hidden, and a Ghost Decoy stood still on the
 * radar between fixes. Now:
 *  - any change in who is invisible, jammed or on thermal pushes everyone a fresh view;
 *  - live decoys walk on every hunter's radar every second;
 *  - Thermal Vision refreshes its hunter's radar every second, as specified;
 *  - each player's own buff badges are corrected from the server's clock.
 */
setInterval(() => {
  for (const [roomCode, session] of activeSessions) {
    if (!sessionStartedAtCache.has(roomCode)) continue;
    for (const p of session.values()) {
      pruneExpiredBuffs(p);
      pushBuffs(p);
    }
    // Radar pings, every radarIntervalSeconds from the match start.
    const interval = radarInterval(roomCode);
    const startedAt = sessionStartedAtCache.get(roomCode)!;
    if (interval > 0) {
      const k = Math.floor((Date.now() - startedAt) / (interval * 1000));
      if (k > (lastPingIndex.get(roomCode) ?? -1)) {
        lastPingIndex.set(roomCode, k);
        refreshRoomVision(roomCode, true);
        io.to(roomCode).emit('radar_ping', { at: Date.now(), nextPingAt: nextPingAt(roomCode) });
      }
    }
    const fingerprint = Array.from(session.values())
      .map((p) => `${p.id}:${['INVISIBILITY_10MIN', 'EMP_JAMMER', 'THERMAL_VISION'].filter((t) => isBuffActive(p, t as PowerUpType)).join(',')}`)
      .join('|');
    pruneExpiredDecoys(decoys, roomCode);
    const liveDecoys = (decoys.get(roomCode) ?? []).length > 0;
    if (visibilityFingerprint.get(roomCode) !== fingerprint || liveDecoys) {
      visibilityFingerprint.set(roomCode, fingerprint);
      refreshRoomVision(roomCode);
      continue;
    }
    const { runners } = visionSides(session);
    for (const hunter of session.values()) {
      if (hunter.role === 'HUNTER' && isBuffActive(hunter, 'THERMAL_VISION')) pushRadarToHunter(roomCode, hunter, runners);
    }
  }
}, 1000);

// gamePlayerId -> check -> epoch ms of the last stored flag. A spoofing client trips a check on
// every fix; one stored flag per check per minute is enough to see the pattern in the admin
// panel without writing a row a second.
const lastAntiCheatFlag: Map<string, Map<string, number>> = new Map();

/** Tells the player why a fix was dropped, and records it for the admin panel's anti-cheat view. */
function flagAntiCheat(socket: Socket, roomCode: string, p: PlayerState, check: string, reason: string) {
  socket.emit('anti_cheat_warning', { reason });
  const perPlayer = lastAntiCheatFlag.get(p.id) ?? new Map<string, number>();
  lastAntiCheatFlag.set(p.id, perPlayer);
  const now = Date.now();
  if (now - (perPlayer.get(check) ?? 0) < 60_000) return;
  perPlayer.set(check, now);
  void resolveSessionId(roomCode).then((sessionId) => {
    if (!sessionId) return;
    return prisma.gameEvent.create({
      data: {
        sessionId,
        type: 'ANTI_CHEAT_FLAG',
        payload: { playerId: p.id, userId: p.userId, username: p.username, check, reason },
      },
    });
  }).catch((err) => console.error('[anti-cheat] could not store flag', err));
  emitAdminEvent('anticheat', { username: p.username, check, roomCode });
}

/** Live layer for the admin panel: every open panel joins the `admins` room. */
export function emitAdminEvent(kind: string, data: Record<string, unknown> = {}) {
  io.to('admins').emit('admin_event', { kind, at: new Date().toISOString(), ...data });
}

/** Country of each connected socket, from Cloudflare's CF-IPCountry header — counts only, never a position. */
const socketCountry: Map<string, string> = new Map();
export function onlineCountryCounts(): Record<string, number> {
  const out: Record<string, number> = {};
  for (const c of socketCountry.values()) out[c] = (out[c] ?? 0) + 1;
  return out;
}
export function socketCount(): number {
  return io.engine.clientsCount;
}
/** Usernames of admins with the panel open right now, for the "who else is here" faces. */
export function adminsPresent(): string[] {
  const names = new Set<string>();
  for (const id of io.sockets.adapter.rooms.get('admins') ?? []) {
    const s = io.sockets.sockets.get(id);
    if (s?.data.user?.username) names.add(s.data.user.username);
  }
  return [...names];
}

async function resolveSessionId(roomCode: string): Promise<string | undefined> {
  const gameSession = await prisma.gameSession.findUnique({ where: { code: roomCode } });
  return gameSession?.id;
}

/**
 * Whether `userId` is the host of `roomCode`. Checks the in-memory cache first, but falls
 * back to a fresh DB read (repopulating the cache) rather than trusting the cache alone —
 * `sessionHostCache` is wiped on every process restart (a backend redeploy, a crash), and
 * without this fallback a real host could get "only the host can..." rejected on live
 * matches that were already running when the process restarted, until they happened to
 * trigger a fresh join_room. A restart is common enough here (frequent redeploys) that
 * this isn't just a theoretical edge case.
 */
async function isSessionHost(roomCode: string, userId: string): Promise<boolean> {
  const cached = sessionHostCache.get(roomCode);
  if (cached) return cached === userId;
  const gameSession = await prisma.gameSession.findUnique({ where: { code: roomCode }, select: { hostId: true } });
  if (!gameSession) return false;
  sessionHostCache.set(roomCode, gameSession.hostId);
  return gameSession.hostId === userId;
}

/** The shrinking zone as of right now, or undefined before the match clock starts. */
function currentZone(roomCode: string): ZoneState | undefined {
  const settings = sessionSettingsCache.get(roomCode);
  const startedAtMs = sessionStartedAtCache.get(roomCode);
  if (!settings || !startedAtMs || settings.boundsPolygon.length < 3) return undefined;
  return computeZoneState(settings.boundsPolygon, new Date(startedAtMs), settings.durationMinutes);
}

/**
 * Containment ("storm") damage, for both roles: a player outside the fixed outer
 * boundsPolygon *or* outside the shrinking zone inside it (+ GPS buffer) is warned first,
 * then loses a heart every damage tick while still outside. Returning inside stops it, and
 * reaching 0 hearts this way is a full elimination (isOut) — the shrinking zone's original
 * behaviour of instantly catching whoever fell outside it is gone.
 *
 * Both failure modes deliberately share one violation/tick budget: standing outside both
 * the polygon and the circle is still one heart per tick, not two.
 */
/** Drops any in-flight play-area violation for this player and tells their client the
 *  warning no longer applies. Used wherever containment stops being checked for someone
 *  (jail, a catch, elimination) — the status event only fires on a transition, so without
 *  this the last "you're outside" they were sent stands forever. */
function clearContainmentState(roomCode: string, player: PlayerState) {
  const violations = boundaryViolationSince.get(roomCode);
  const ticks = boundaryLastDamageAt.get(roomCode);
  const wasOutside = violations?.delete(player.id) ?? false;
  ticks?.delete(player.id);
  if (wasOutside) io.to(player.id).emit('boundary_status', { outside: false });
}

async function checkContainment(
  roomCode: string,
  gameSessionId: string,
  player: PlayerState,
  session: Map<string, PlayerState>,
  mode: GameMode
) {
  const settings = sessionSettingsCache.get(roomCode);
  if (!settings) return;

  const point = { lat: player.lat, lng: player.lng };
  const zone = currentZone(roomCode);
  // The jail never drains hearts. The zone shrinks towards the middle and almost always ends
  // up excluding the jail, which used to make a late jailbreak cost the rescuer more hearts
  // than they have, and turned guarding prisoners into a slow death for hunters.
  const outsideBy = isInsideJail(roomCode, point, player.accuracy)
    ? 0
    : Math.max(distanceOutsidePolygonMeters(point, settings.boundsPolygon), zone ? distanceOutsideZone(point, zone) : 0);
  const effectiveBuffer = Math.max(BOUNDARY_BUFFER_METERS, player.accuracy);
  const violations = boundaryViolationSince.get(roomCode) ?? new Map<string, number>();
  boundaryViolationSince.set(roomCode, violations);
  const ticks = boundaryLastDamageAt.get(roomCode) ?? new Map<string, number>();
  boundaryLastDamageAt.set(roomCode, ticks);

  if (outsideBy <= effectiveBuffer) {
    if (violations.delete(player.id)) {
      ticks.delete(player.id);
      io.to(player.id).emit('boundary_status', { outside: false });
    }
    return;
  }

  // Which of the two shapes they're actually outside, so the warning can name it — both
  // drain identically, but "outside the play area" and "outside the shrinking zone" are
  // very different things to be told while you're running.
  const outsideZoneBy = zone ? distanceOutsideZone(point, zone) : 0;
  const reason = outsideZoneBy > distanceOutsidePolygonMeters(point, settings.boundsPolygon) ? 'ZONE' : 'BOUNDARY';

  const now = Date.now();
  const since = violations.get(player.id);
  if (!since) {
    violations.set(player.id, now);
    io.to(player.id).emit('boundary_status', { outside: true, warning: true, reason });
    return;
  }
  // The warning comes first and buys a window to turn around — nothing is lost until the
  // grace expires, after which it's a heart every tick for as long as they stay out.
  if (now - since < BOUNDARY_WARNING_GRACE_MS) return;
  const lastDamage = ticks.get(player.id) ?? since;
  if (now - lastDamage < BOUNDARY_DAMAGE_TICK_MS) return;
  ticks.set(player.id, now);

  player.hearts = Math.max(0, player.hearts - 1);
  // Emitted before the write, not after: the socket event is the only thing the player
  // actually sees, and a database hiccup rejecting this handler mid-await would otherwise
  // take the damage feedback down with it while the in-memory heart is already gone.
  io.to(roomCode).emit('hearts_update', { playerId: player.id, hearts: player.hearts, cause: reason });
  await prisma.gamePlayer.update({ where: { id: player.id }, data: { hearts: player.hearts } });

  if (player.hearts <= 0) {
    violations.delete(player.id);
    ticks.delete(player.id);
    player.isOut = true;
    await gameService.recordPlayerOut(gameSessionId, player.id, 'BOUNDARY');
    io.to(roomCode).emit('player_eliminated', {
      playerId: player.id,
      role: player.role,
      reason: 'BOUNDARY',
      timestamp: new Date().toISOString(),
    });
    if (player.role === 'HUNTER') {
      await checkHunterEliminationWinCondition(roomCode, gameSessionId, session, mode);
    } else {
      await checkStandardWinCondition(roomCode, gameSessionId, session, mode);
    }
  }
}

/** A jailed runner who strays outside jail+buffer gets an urgent countdown (not a slow
 *  drain like the boundary) — failing to return in time is a full elimination, not
 *  re-jailing. Runner-only: hunters are never jailed. */
async function checkJailContainment(
  roomCode: string,
  gameSessionId: string,
  runner: PlayerState,
  session: Map<string, PlayerState>
) {
  const settings = sessionSettingsCache.get(roomCode);
  if (!settings?.jailEnabled || !settings.jailPolygon || !runner.isJailed) return;

  const outsideBy = distanceOutsidePolygonMeters({ lat: runner.lat, lng: runner.lng }, settings.jailPolygon);
  const effectiveBuffer = Math.max(JAIL_BUFFER_METERS, runner.accuracy);
  const violations = jailViolationSince.get(roomCode) ?? new Map<string, number>();
  jailViolationSince.set(roomCode, violations);

  if (outsideBy <= effectiveBuffer) {
    if (violations.delete(runner.id)) io.to(runner.id).emit('jail_status', { outside: false });
    return;
  }

  const now = Date.now();
  const since = violations.get(runner.id);
  if (!since) {
    violations.set(runner.id, now);
    io.to(runner.id).emit('jail_status', { outside: true, deadlineMs: JAIL_VIOLATION_COUNTDOWN_MS });
    return;
  }
  if (now - since < JAIL_VIOLATION_COUNTDOWN_MS) return;

  violations.delete(runner.id);
  runner.isOut = true;
  runner.isJailed = false;
  await gameService.recordPlayerOut(gameSessionId, runner.id, 'JAIL_BREACH');
  io.to(roomCode).emit('player_eliminated', {
    playerId: runner.id,
    role: 'RUNNER',
    reason: 'JAIL_BREACH',
    timestamp: new Date().toISOString(),
  });
  await checkStandardWinCondition(roomCode, gameSessionId, session, sessionModes.get(roomCode) ?? 'STANDARD');
}

/** True when a point is inside the jail (plus its GPS buffer). */
function isInsideJail(roomCode: string, point: { lat: number; lng: number }, accuracy = 0): boolean {
  const settings = sessionSettingsCache.get(roomCode);
  if (!settings?.jailEnabled || !settings.jailPolygon || settings.jailPolygon.length < 3) return false;
  return distanceOutsidePolygonMeters(point, settings.jailPolygon) <= Math.max(JAIL_BUFFER_METERS, accuracy);
}

/**
 * Every rule a catch has to pass, in one place, for the phone's request, the Watch's code entry
 * and the host's override alike. Returns the sentence to show the hunter, or null.
 */
function catchBlockedReason(
  roomCode: string,
  session: Map<string, PlayerState>,
  hunter: PlayerState,
  runner: PlayerState | undefined
): string | null {
  const mode = sessionModes.get(roomCode) ?? 'STANDARD';
  if (hunter.role !== 'HUNTER') return 'Only hunters can catch.';
  // An eliminated hunter used to be able to keep catching from wherever they stood.
  if (hunter.isOut) return "You're out of the match.";
  if (!runner || runner.role !== 'RUNNER') return 'You can only catch runners.';
  if (runner.isCaught || runner.isOut) return `${runner.username} isn't free to catch.`;
  if (mode === 'SQUAD' && (!hunter.squad || !runner.squad || hunter.squad === runner.squad)) {
    return "That's your own squad — you can only catch runners from other squads.";
  }
  const distance = turf.distance(turf.point([hunter.lng, hunter.lat]), turf.point([runner.lng, runner.lat]), { units: 'meters' });
  if (distance > CATCH_VERIFICATION_RADIUS_METERS) {
    return `Too far away — ${Math.round(distance)} m. Get within ${CATCH_VERIFICATION_RADIUS_METERS} m to catch.`;
  }
  // A Safe Zone Flare never protects the jail: a bubble there would make jailbreaks risk-free.
  if (isWithinAnySafeZone(session, { lat: runner.lat, lng: runner.lng }) && !isInsideJail(roomCode, runner)) {
    return `${runner.username} is inside a Safe Zone Flare.`;
  }
  const protectedUntil = releaseProtection.get(roomCode)?.get(runner.id) ?? 0;
  if (protectedUntil > Date.now()) {
    return `${runner.username} was just freed and can't be caught for another ${Math.ceil((protectedUntil - Date.now()) / 1000)} s.`;
  }
  return null;
}

/** Resolves an agreed catch: Infection switches the runner's side, every other mode applies a
 *  catch (a heart, jail if it's on, elimination at zero) — then the win check. */
async function resolveCatch(
  roomCode: string,
  session: Map<string, PlayerState>,
  hunter: PlayerState,
  runner: PlayerState,
  note?: string
) {
  if (runner.isCaught || runner.isOut || runner.role !== 'RUNNER') return;
  const gameSessionId = await resolveSessionId(roomCode);
  if (!gameSessionId) return;
  const mode = sessionModes.get(roomCode) ?? 'STANDARD';
  if (note) {
    io.to(runner.id).emit('catch_ruling', { message: note });
    io.to(hunter.id).emit('catch_ruling', { message: note });
  }
  if (mode === 'INFECTION') {
    runner.role = 'HUNTER';
    runner.isCaught = false;
    clearContainmentState(roomCode, runner);
    await gameService.convertRunnerToHunter(gameSessionId, runner.id);
    io.to(roomCode).emit('player_infected', { runnerId: runner.id, hunterId: hunter.id, timestamp: new Date().toISOString() });
    // Infection used to have no win check at all, so a match where everyone had been turned
    // kept running until the clock ran out.
    await checkInfectionWinCondition(roomCode, gameSessionId, session);
    refreshRoomVision(roomCode);
    return;
  }
  await applyCatch(roomCode, gameSessionId, session, hunter, runner, mode);
  refreshRoomVision(roomCode);
}

/** Frees a caught or jailed runner (a squad revive, or the host saying it wasn't a catch) —
 *  every piece of jail state, with the same short protection a jailbreak gives. */
async function releaseRunner(roomCode: string, runner: PlayerState, byId: string) {
  runner.isCaught = false;
  runner.isJailed = false;
  runner.hasReachedJail = false;
  jailArrivalDeadline.get(roomCode)?.delete(runner.id);
  jailViolationSince.get(roomCode)?.delete(runner.id);
  protect(roomCode, [runner.id]);
  const gameSessionId = await resolveSessionId(roomCode);
  if (gameSessionId) {
    await prisma.gamePlayer.update({ where: { id: runner.id }, data: { isCaught: false, isJailed: false, caughtAt: null } });
    await gameService.revivePlayer(gameSessionId, runner.id, byId);
  }
  io.to(roomCode).emit('player_revived', { playerId: runner.id, revivedById: byId, protectedMs: RELEASE_PROTECTION_MS, timestamp: new Date().toISOString() });
  refreshRoomVision(roomCode);
}

function protect(roomCode: string, playerIds: string[]) {
  const map = releaseProtection.get(roomCode) ?? new Map<string, number>();
  releaseProtection.set(roomCode, map);
  for (const id of playerIds) map.set(id, Date.now() + RELEASE_PROTECTION_MS);
}

/**
 * The single place a catch is applied, so the request/respond popup and the gamble-timeout
 * fallback can't drift apart on the rules.
 *
 * Every catch costs the runner a heart. With jail mode on that's what bounds the
 * catch/bail-out cycle — a runner can be broken out and re-caught only as many times as
 * they have hearts left, and one who runs out is finished regardless of any rescue.
 * Without jail mode the heart still goes, but being caught already ends their match, so it
 * only really shows up in the post-match stats.
 */
async function applyCatch(
  roomCode: string,
  gameSessionId: string,
  session: Map<string, PlayerState>,
  hunter: PlayerState,
  runner: PlayerState,
  mode: GameMode
) {
  const settings = sessionSettingsCache.get(roomCode);
  const jail = !!settings?.jailEnabled && !!settings.jailPolygon;
  const caughtAt = new Date().toISOString();

  // Containment stops applying the moment they're caught, and a caught non-jailed player
  // stops sending location fixes at all — so this is the last chance to retract a warning
  // they'd otherwise be left staring at.
  clearContainmentState(roomCode, runner);

  runner.hearts = Math.max(0, runner.hearts - 1);
  io.to(roomCode).emit('hearts_update', { playerId: runner.id, hearts: runner.hearts, cause: 'CAUGHT' });

  // Out of hearts is out of the match: no jail, and no rescue to wait for.
  if (runner.hearts <= 0) {
    runner.isCaught = true;
    runner.isJailed = false;
    runner.isOut = true;
    await gameService.recordCatchAccepted(gameSessionId, hunter.id, runner.id, false, runner.hearts);
    await gameService.recordPlayerOut(gameSessionId, runner.id, 'CAUGHT');
    io.to(roomCode).emit('player_caught', { runnerId: runner.id, hunterId: hunter.id, timestamp: caughtAt });
    io.to(roomCode).emit('player_eliminated', {
      playerId: runner.id,
      role: runner.role,
      reason: 'CAUGHT',
      timestamp: caughtAt,
    });
    await checkStandardWinCondition(roomCode, gameSessionId, session, mode);
    return;
  }

  runner.isCaught = true;
  runner.isJailed = jail;
  runner.hasReachedJail = false;
  await gameService.recordCatchAccepted(gameSessionId, hunter.id, runner.id, jail, runner.hearts);

  if (!jail) {
    io.to(roomCode).emit('player_caught', { runnerId: runner.id, hunterId: hunter.id, timestamp: caughtAt });
    await checkStandardWinCondition(roomCode, gameSessionId, session, mode);
    return;
  }

  // Sentenced but not yet imprisoned — they walk to the jail themselves, on a clock.
  const arrivalMs = (settings?.jailArrivalSeconds ?? DEFAULT_JAIL_ARRIVAL_SECONDS) * 1000;
  const deadlines = jailArrivalDeadline.get(roomCode) ?? new Map<string, number>();
  jailArrivalDeadline.set(roomCode, deadlines);
  deadlines.set(runner.id, Date.now() + arrivalMs);

  io.to(roomCode).emit('player_jailed', {
    runnerId: runner.id,
    hunterId: hunter.id,
    arrivalDeadlineMs: arrivalMs,
    timestamp: caughtAt,
  });
  // A jailed runner counts as resolved for the win check, which is correct even with
  // bail-outs in play: if every runner is locked up there's nobody left free to spring
  // them, so the hunters really have won.
  await checkStandardWinCondition(roomCode, gameSessionId, session, mode);
}

/** A sentenced runner has a fixed window to actually reach the jail. Missing it is a
 *  disqualification for never showing up — a different failure from JAIL_BREACH, which is
 *  walking out again after arriving. */
async function checkJailArrival(
  roomCode: string,
  gameSessionId: string,
  runner: PlayerState,
  session: Map<string, PlayerState>
) {
  const settings = sessionSettingsCache.get(roomCode);
  if (!settings?.jailEnabled || !settings.jailPolygon) return;

  const deadlines = jailArrivalDeadline.get(roomCode);
  const deadline = deadlines?.get(runner.id);
  // No deadline on record — jail was switched on mid-sentence, or this is a reconnect.
  // Nothing fair to enforce, so treat them as having served their way in already.
  if (!deadline) {
    runner.hasReachedJail = true;
    return;
  }

  const outsideBy = distanceOutsidePolygonMeters({ lat: runner.lat, lng: runner.lng }, settings.jailPolygon);
  if (outsideBy <= Math.max(JAIL_BUFFER_METERS, runner.accuracy)) {
    deadlines!.delete(runner.id);
    runner.hasReachedJail = true;
    io.to(roomCode).emit('jail_arrived', { runnerId: runner.id, timestamp: new Date().toISOString() });
    return;
  }

  if (Date.now() < deadline) return;

  deadlines!.delete(runner.id);
  runner.isJailed = false;
  runner.isOut = true;
  await gameService.recordPlayerOut(gameSessionId, runner.id, 'JAIL_NO_SHOW');
  io.to(roomCode).emit('player_eliminated', {
    playerId: runner.id,
    role: 'RUNNER',
    reason: 'JAIL_NO_SHOW',
    timestamp: new Date().toISOString(),
  });
  await checkStandardWinCondition(roomCode, gameSessionId, session, sessionModes.get(roomCode) ?? 'STANDARD');
}

/** A free runner standing inside the jail long enough springs everyone in it. Continuous,
 *  not cumulative — stepping outside resets the clock, so it costs a real, exposed stay
 *  right where the hunters know to look. */
async function checkBailProgress(
  roomCode: string,
  gameSessionId: string,
  runner: PlayerState,
  session: Map<string, PlayerState>,
  mode: GameMode
) {
  const settings = sessionSettingsCache.get(roomCode);
  if (!settings?.jailEnabled || !settings.jailPolygon) return;

  const dwell = bailDwellSince.get(roomCode) ?? new Map<string, number>();
  bailDwellSince.set(roomCode, dwell);

  const outsideBy = distanceOutsidePolygonMeters({ lat: runner.lat, lng: runner.lng }, settings.jailPolygon);
  const inside = outsideBy <= Math.max(JAIL_BUFFER_METERS, runner.accuracy);
  // Only counts when there's someone to let out. Otherwise a runner could park in an empty
  // jail and drain every hunter's hearts for nothing.
  // In Squad mode a jailbreak is for your own squad only.
  const hasPrisoner = Array.from(session.values()).some(
    (x) => x.isJailed && x.hasReachedJail && !x.isOut && (mode !== 'SQUAD' || x.squad === runner.squad)
  );
  const requiredMs = (settings.bailOutSeconds ?? DEFAULT_BAIL_OUT_SECONDS) * 1000;

  if (!inside || !hasPrisoner) {
    if (dwell.delete(runner.id)) {
      io.to(runner.id).emit('bail_progress', { active: false, elapsedMs: 0, requiredMs });
    }
    return;
  }

  const now = Date.now();
  const since = dwell.get(runner.id);
  if (!since) {
    dwell.set(runner.id, now);
    io.to(runner.id).emit('bail_progress', { active: true, elapsedMs: 0, requiredMs });
    return;
  }

  const elapsed = now - since;
  if (elapsed < requiredMs) {
    io.to(runner.id).emit('bail_progress', { active: true, elapsedMs: elapsed, requiredMs });
    return;
  }

  await performBailOut(roomCode, gameSessionId, session, runner, mode);
}

/** The jailbreak itself: every prisoner walks, the runner who held the jail pays a heart
 *  for it, and so does every hunter still in the match. */
async function performBailOut(
  roomCode: string,
  gameSessionId: string,
  session: Map<string, PlayerState>,
  bailer: PlayerState,
  mode: GameMode
) {
  // Cleared for everyone, not just the bailer: the jail is empty now, so nobody else
  // standing in it should roll straight into a second jailbreak on the next fix.
  bailDwellSince.get(roomCode)?.clear();

  const arrivals = jailArrivalDeadline.get(roomCode);
  const violations = jailViolationSince.get(roomCode);
  // Squad mode frees only the bailer's own squad, and only the other squads' hunters pay.
  const freed = Array.from(session.values()).filter(
    (x) => x.isJailed && !x.isOut && (mode !== 'SQUAD' || x.squad === bailer.squad)
  );
  for (const prisoner of freed) {
    prisoner.isJailed = false;
    prisoner.isCaught = false;
    prisoner.hasReachedJail = false;
    arrivals?.delete(prisoner.id);
    violations?.delete(prisoner.id);
  }

  const hunters = Array.from(session.values()).filter(
    (x) => x.role === 'HUNTER' && !x.isOut && (mode !== 'SQUAD' || x.squad !== bailer.squad)
  );
  const eliminated: PlayerState[] = [];
  // A head start: without it the hunters guarding the jail re-caught everyone on the spot.
  protect(roomCode, freed.map((f) => f.id));

  bailer.hearts = Math.max(0, bailer.hearts - 1);
  if (bailer.hearts <= 0) eliminated.push(bailer);
  for (const hunter of hunters) {
    hunter.hearts = Math.max(0, hunter.hearts - 1);
    if (hunter.hearts <= 0) eliminated.push(hunter);
  }

  const heartUpdates = [bailer, ...hunters].map((p) => ({ playerId: p.id, hearts: p.hearts }));
  await gameService.recordBailOut(
    gameSessionId,
    bailer.id,
    freed.map((f) => f.id),
    heartUpdates
  );

  const timestamp = new Date().toISOString();
  io.to(roomCode).emit('jail_bailout', {
    bailerId: bailer.id,
    bailerUsername: bailer.username,
    freedPlayerIds: freed.map((f) => f.id),
    protectedMs: RELEASE_PROTECTION_MS,
    timestamp,
  });
  refreshRoomVision(roomCode);
  for (const p of [bailer, ...hunters]) {
    io.to(roomCode).emit('hearts_update', { playerId: p.id, hearts: p.hearts, cause: 'BAILOUT' });
  }

  for (const p of eliminated) {
    p.isOut = true;
    await gameService.recordPlayerOut(gameSessionId, p.id, 'BAILOUT');
    io.to(roomCode).emit('player_eliminated', { playerId: p.id, role: p.role, reason: 'BAILOUT', timestamp });
  }

  if (eliminated.some((p) => p.role === 'HUNTER')) {
    await checkHunterEliminationWinCondition(roomCode, gameSessionId, session, mode);
  }
  await checkStandardWinCondition(roomCode, gameSessionId, session, mode);
}

/**
 * One round of a gamble duel. A gamble is no longer a single flip for a single heart:
 * rounds repeat until one side is out of hearts, and unlike the earlier version there is
 * no heal-back for the hunter — both sides put real, persistent hearts on the line, so a
 * hunter who keeps calling it wrong can be eliminated by a runner who refused to come
 * quietly. The loser of the duel is out; the winner walks away (a runner who wins is never
 * marked caught).
 */
async function resolveGambleRound(
  roomCode: string,
  gameSessionId: string,
  session: Map<string, PlayerState>,
  runner: PlayerState,
  hunter: PlayerState,
  gambleChoice: 'heads' | 'tails',
  mode: GameMode
) {
  const duels = activeGambles.get(roomCode);
  const duel = duels?.get(runner.id);
  if (!duel) return;
  duel.round += 1;
  duel.lastCallAt = Date.now();

  const result: 'heads' | 'tails' = Math.random() < 0.5 ? 'heads' : 'tails';
  const runnerWins = gambleChoice === result;
  const loser = runnerWins ? hunter : runner;
  const heartsLostBy: 'HUNTER' | 'RUNNER' = runnerWins ? 'HUNTER' : 'RUNNER';

  loser.hearts = Math.max(0, loser.hearts - 1);
  const finished = loser.hearts <= 0;

  // Persists both sides' hearts as well as writing the GAMBLE event row.
  await gameService.recordGambleResult(
    gameSessionId,
    hunter.id,
    runner.id,
    gambleChoice,
    result,
    heartsLostBy,
    hunter.hearts,
    runner.hearts
  );

  io.to(roomCode).emit('gamble_result', {
    hunterId: hunter.id,
    runnerId: runner.id,
    gambleChoice,
    result,
    heartsLostBy,
    hunterHeartsRemaining: hunter.hearts,
    runnerHeartsRemaining: runner.hearts,
    round: duel.round,
    continues: !finished,
    timestamp: new Date().toISOString(),
  });

  // Still alive on both sides — the runner's client re-prompts for the next call.
  if (!finished) return;

  duels!.delete(runner.id);
  loser.isOut = true;
  await gameService.recordPlayerOut(gameSessionId, loser.id, 'GAMBLE');
  io.to(roomCode).emit('player_eliminated', {
    playerId: loser.id,
    role: loser.role,
    reason: 'GAMBLE',
    timestamp: new Date().toISOString(),
  });

  if (loser.role === 'HUNTER') {
    await checkHunterEliminationWinCondition(roomCode, gameSessionId, session, mode);
  } else {
    await checkStandardWinCondition(roomCode, gameSessionId, session, mode);
  }
}

/** Squads that still have at least one runner free. */
function squadsWithFreeRunners(session: Map<string, PlayerState>): Map<string, number> {
  const out = new Map<string, number>();
  for (const p of session.values()) {
    if (p.role === 'RUNNER' && !p.isCaught && !p.isOut && p.squad) out.set(p.squad, (out.get(p.squad) ?? 0) + 1);
  }
  return out;
}

async function finishMatch(roomCode: string, gameSessionId: string, payload: Record<string, unknown>) {
  if (!sessionStartedAtCache.has(roomCode)) return; // already over
  await gameService.endSession(gameSessionId);
  sessionStartedAtCache.delete(roomCode);
  io.to(roomCode).emit('game_over', payload);
}

async function checkStandardWinCondition(
  roomCode: string,
  gameSessionId: string,
  session: Map<string, PlayerState>,
  mode: GameMode
) {
  if (mode === 'INFECTION') return checkInfectionWinCondition(roomCode, gameSessionId, session);
  if (mode === 'SQUAD') {
    // Squad mode is won by a squad, not by "the hunters": the last squad with a runner still
    // free wins. It used to end only when every runner of every squad was caught, and then
    // announce that the hunters had won.
    const alive = squadsWithFreeRunners(session);
    if (alive.size === 1) {
      await finishMatch(roomCode, gameSessionId, { reason: 'SQUAD_WON', winningSquad: [...alive.keys()][0] });
    } else if (alive.size === 0) {
      await finishMatch(roomCode, gameSessionId, { reason: 'DRAW' });
    }
    return;
  }
  const activeRunners = Array.from(session.values()).filter((x) => x.role === 'RUNNER' && !x.isCaught && !x.isOut);
  if (activeRunners.length === 0) await finishMatch(roomCode, gameSessionId, { reason: 'ALL_RUNNERS_RESOLVED' });
}

/** Infection ends when nobody is left running: everyone has been turned or eliminated. */
async function checkInfectionWinCondition(roomCode: string, gameSessionId: string, session: Map<string, PlayerState>) {
  const runnersLeft = Array.from(session.values()).filter((x) => x.role === 'RUNNER' && !x.isOut);
  if (runnersLeft.length === 0) await finishMatch(roomCode, gameSessionId, { reason: 'ALL_RUNNERS_RESOLVED' });
}

/** If every hunter has been eliminated — by containment damage, a jailbreak, or a lost gamble
 *  — the runners win early. Squad mode is decided by squads instead. */
async function checkHunterEliminationWinCondition(
  roomCode: string,
  gameSessionId: string,
  session: Map<string, PlayerState>,
  mode: GameMode
) {
  if (mode === 'SQUAD') return;
  const activeHunters = Array.from(session.values()).filter((x) => x.role === 'HUNTER' && !x.isOut);
  if (activeHunters.length === 0) await finishMatch(roomCode, gameSessionId, { reason: 'ALL_HUNTERS_ELIMINATED' });
}

async function endMatch(roomCode: string, reason: string) {
  const gameSessionId = await resolveSessionId(roomCode);
  if (!gameSessionId) return;
  await gameService.endSession(gameSessionId);
  sessionStartedAtCache.delete(roomCode);
  io.to(roomCode).emit('game_over', { reason });
}

/**
 * Closes any unfinished session that's had nobody connected to it for longer than
 * ABANDONED_SESSION_TIMEOUT_MS, so a lobby or match everyone walked away from doesn't stay
 * open forever — an open session is what GET /games/active/mine hands back as "the game
 * you're still in", so leaving it dangling keeps offering every one of its members a way
 * back into a game nobody is playing, and blocks them from being seen as free to host or
 * join another. Marking it ENDED resolves it for all of them at once and moves it into
 * their match history like any other finished game.
 *
 * Driven off the DB rather than the in-memory rooms because an abandoned room is, by
 * definition, no longer in `activeSessions` — cleanupSocket drops it the moment the last
 * player leaves. Sessions this process has never seen occupied (created just before a
 * restart, say) start their countdown at the first sweep that finds them, which also gives
 * clients a full timeout's grace to reconnect after a deploy.
 */
async function closeAbandonedSessions() {
  const open = await prisma.gameSession.findMany({
    where: { status: { in: ['LOBBY', 'ACTIVE'] } },
    select: { id: true, code: true },
  });
  const openCodes = new Set(open.map((s) => s.code));
  for (const code of sessionEmptySince.keys()) {
    if (!openCodes.has(code)) sessionEmptySince.delete(code);
  }

  const now = Date.now();
  for (const session of open) {
    if ((activeSessions.get(session.code)?.size ?? 0) > 0) {
      sessionEmptySince.delete(session.code);
      continue;
    }
    const emptySince = sessionEmptySince.get(session.code);
    if (emptySince === undefined) {
      sessionEmptySince.set(session.code, now);
      continue;
    }
    if (now - emptySince < ABANDONED_SESSION_TIMEOUT_MS) continue;

    sessionEmptySince.delete(session.code);
    pendingLogs.delete(session.code);
    await gameService.endSession(session.id);
    sessionStartedAtCache.delete(session.code);
    // Nobody is in the room to hear this by definition — it's here for the edge case of a
    // socket that joined the room without ever registering a player state, so it isn't
    // left sitting in a match the server has just closed underneath it.
    io.to(session.code).emit('game_over', { reason: 'ABANDONED' });
    console.log(`[Session] closed abandoned game ${session.code} — empty for over ${ABANDONED_SESSION_TIMEOUT_MS / 60_000} min`);
  }
}

async function endMatchIfExpired(roomCode: string): Promise<boolean> {
  const startedAtMs = sessionStartedAtCache.get(roomCode);
  const settings = sessionSettingsCache.get(roomCode);
  if (!startedAtMs || !settings) return false;
  if (Date.now() - startedAtMs < settings.durationMinutes * 60_000) return false;
  const session = activeSessions.get(roomCode);
  if ((sessionModes.get(roomCode) ?? 'STANDARD') === 'SQUAD' && session) {
    // At the whistle, the squad with the most runners still free wins; a tie is a draw.
    const alive = [...squadsWithFreeRunners(session).entries()].sort((a, b) => b[1] - a[1]);
    const gameSessionId = await resolveSessionId(roomCode);
    if (!gameSessionId) return false;
    if (alive.length > 0 && (alive.length === 1 || alive[0][1] > alive[1][1])) {
      await finishMatch(roomCode, gameSessionId, { reason: 'TIME_EXPIRED', winningSquad: alive[0][0] });
    } else {
      await finishMatch(roomCode, gameSessionId, { reason: 'TIME_EXPIRED_DRAW' });
    }
    return true;
  }
  await endMatch(roomCode, 'TIME_EXPIRED');
  return true;
}

// Periodically flush buffered location fixes to Postgres for post-game analytics/replay,
// expire stale catch requests a runner never answered, and act as a backstop for
// match-timer expiry in case no player sent a location update right at the deadline.
setInterval(async () => {
  for (const roomCode of activeSessions.keys()) {
    if (await endMatchIfExpired(roomCode)) continue;
    // Push the shrinking zone's current circle so clients can redraw it — it contracts
    // continuously, so unlike the fixed boundary polygon it can't just be sent once.
    const zone = currentZone(roomCode);
    if (zone) io.to(roomCode).emit('zone_update', zone);
  }

  const now = Date.now();

  // A duel the runner stopped answering (backgrounded app, or simply walking away from a
  // losing streak) resolves as the catch they were originally asked to accept — otherwise
  // silence would be a free escape from a gamble they chose to start.
  for (const [roomCode, duels] of activeGambles.entries()) {
    for (const [runnerId, duel] of Array.from(duels.entries())) {
      if (now - duel.lastCallAt < CATCH_REQUEST_TIMEOUT_MS) continue;
      duels.delete(runnerId);
      const session = activeSessions.get(roomCode);
      const runner = session?.get(runnerId);
      const hunter = session?.get(duel.hunterId);
      if (!session || !runner || !hunter || runner.isOut) continue;
      const gameSessionId = await resolveSessionId(roomCode);
      if (!gameSessionId) continue;
      await applyCatch(roomCode, gameSessionId, session, hunter, runner, sessionModes.get(roomCode) ?? 'STANDARD');
    }
  }

  for (const [roomCode, requests] of pendingCatchRequests.entries()) {
    for (const [runnerId, req] of Array.from(requests.entries())) {
      if (now - req.requestedAt < CATCH_REQUEST_TIMEOUT_MS) continue;
      requests.delete(runnerId);
      const session = activeSessions.get(roomCode);
      const runner = session?.get(runnerId);
      const hunter = session?.get(req.hunterId);
      if (!req.deniedAt && session && runner && hunter && !hunter.isOut) {
        // Silence isn't an escape: the request already proved the hunter was within catching
        // distance, so a runner who never answers is caught. (Ignoring the popup used to
        // cancel the catch outright.)
        await resolveCatch(roomCode, session, hunter, runner, 'No answer in time — the catch stands.');
        continue;
      }
      // The runner said no and the hunter never insisted: the runner's word stands.
      io.to(req.hunterId).emit('catch_request_expired', { runnerId, requestId: req.requestId });
      io.to(runnerId).emit('catch_request_cancelled', { hunterId: req.hunterId });
    }
  }

  for (const [roomCode, disputes] of pendingDisputes.entries()) {
    for (const [disputeId, d] of Array.from(disputes.entries())) {
      if (now - d.createdAt < CATCH_DISPUTE_TIMEOUT_MS) continue;
      disputes.delete(disputeId);
      const session = activeSessions.get(roomCode);
      const runner = session?.get(d.runnerId);
      const hunter = session?.get(d.hunterId);
      if (session && runner && hunter) {
        await resolveCatch(roomCode, session, hunter, runner, "The host didn't rule in time, so the catch stands.");
      }
    }
  }

  for (const [roomCode, entries] of pendingLogs.entries()) {
    if (entries.length === 0) continue;
    pendingLogs.set(roomCode, []);
    const gameSessionId = await resolveSessionId(roomCode);
    if (gameSessionId) {
      await gameService.logLocationBatch(gameSessionId, entries).catch((err) => {
        console.error('[locationLogFlush] failed', err);
      });
    }
  }
}, 10_000);

// Deliberately its own, slower loop: it's one DB query against an unfinished-session index
// and the thing it's watching for takes minutes, so there's no reason to run it at the
// per-tick cadence of the live game loop above.
setInterval(() => {
  closeAbandonedSessions().catch((err) => console.error('[Session] abandoned sweep failed', err));
}, 30_000);

const PORT = Number(process.env.PORT ?? 4000);

export function startServer() {
  httpServer.listen(PORT, () => {
    console.log(`[Server] Hunting Game backend active on port ${PORT}`);
  });
}
