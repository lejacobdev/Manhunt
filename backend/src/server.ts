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
  AuthTokenPayload,
  BOUNDARY_BUFFER_METERS,
  BOUNDARY_DAMAGE_TICK_MS,
  BOUNDARY_WARNING_GRACE_MS,
  CATCH_REQUEST_TIMEOUT_MS,
  CATCH_VERIFICATION_RADIUS_METERS,
  POWER_UP_COLLECTION_RADIUS_METERS,
  GameMode,
  JAIL_BUFFER_METERS,
  JAIL_VIOLATION_COUNTDOWN_MS,
  PlayerState,
  PowerUpType,
  ZONE_BROADCAST_INTERVAL_MS,
} from './types';

const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-secret-do-not-use-in-production';

export const app = express();
app.use(cors({ origin: process.env.CORS_ORIGIN ?? '*' }));
app.use(express.json());

app.get('/health', (_req, res) => res.json({ ok: true, service: 'hunting-game-backend' }));

// Serves the sideloadable HuntingGame.ipa plus an AltStore/SideStore source
// manifest, so the app can be added as a SideStore "source" (one-time add,
// then install/update from there) instead of re-downloading a raw IPA every
// build. Populated by ios/xtool/{docker-build.sh,xtool-build.sh} — that
// directory doesn't exist until a build has run, and is gitignored (build
// output, not source), so express.static just 404s until then.
app.use('/dist', express.static(path.join(__dirname, '..', 'dist-static')));

app.use('/auth', authRouter);
app.use('/friends', friendsRouter);
app.use('/games', gamesRouter);
app.use('/powerups', powerUpsRouter);
app.use('/invites', invitesRouter);
app.use('/users', usersRouter);
app.use('/push', pushRouter);

/**
 * The landing page a friend QR points at. The QR encodes an https:// URL rather than the
 * huntinggame:// scheme directly so that any camera app will actually offer to open it —
 * iOS Camera silently ignores unknown custom schemes. This page then bounces straight to
 * the app's own scheme, with a tap-through and an install link for anyone who lands here
 * without the app (it's sideloaded via SideStore, so there's no App Store page to fall
 * back to). Scanning from *inside* the app skips all of this and parses the tag directly.
 */
app.get('/u/:username/:tag', (req, res) => {
  const escape = (value: string) =>
    value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
  const username = escape(req.params.username.slice(0, 40));
  const tag = escape(req.params.tag.slice(0, 10));
  const deepLink = `huntinggame://add-friend?username=${encodeURIComponent(req.params.username)}&tag=${encodeURIComponent(req.params.tag)}`;

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
  <a class="secondary" href="https://api.lejacob.dev/dist/source.json">Don't have the app?</a>
  <p>Opening Hunting Game&hellip; if nothing happens, tap "Add as friend".</p>
</div>
<script>location.replace(${JSON.stringify(deepLink)});</script>
</body></html>`);
});

export const httpServer = createServer(app);
export const io = new Server(httpServer, { cors: { origin: process.env.CORS_ORIGIN ?? '*' } });

// roomCode -> (gamePlayerId -> PlayerState)
const activeSessions: Map<string, Map<string, PlayerState>> = new Map();
// roomCode -> game mode, cached at join to avoid a DB hit per tick
const sessionModes: Map<string, GameMode> = new Map();
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
// roomCode -> runnerId -> the one pending catch request targeting them (a runner can only
// be asked about one catch at a time; a hunter, however, may have requests out to several
// runners at once, hence requestId to disambiguate which one a later deny-confirm is about).
const pendingCatchRequests: Map<string, Map<string, { requestId: string; hunterId: string; hunterUsername: string; requestedAt: number }>> = new Map();
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
  try {
    const decoded = jwt.verify(token, JWT_SECRET) as AuthTokenPayload;
    socket.data.user = decoded;
    next();
  } catch {
    next(new Error('Invalid or expired token.'));
  }
});

io.on('connection', (socket: Socket) => {
  const authedUser = socket.data.user as AuthTokenPayload;
  console.log(`[Socket] Connected: ${socket.id} (user=${authedUser.username})`);

  // Presence is independent of game membership — every authenticated socket (including
  // one just sitting on the lobby/friends screen) joins its own user room so friends and
  // invites can reach it, and counts toward "online" for the duration of the connection.
  socket.join(`user:${authedUser.userId}`);
  markUserOnline(authedUser.userId).catch((err) => console.error('[presence] markUserOnline failed', err));

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

      io.to(roomCode).emit('player_joined', publicRoster(session));

      // A match that's already running has to hand the clock to whoever just walked in.
      // game_started is otherwise only emitted once, by the REST start route, to sockets
      // already in the room — so anyone entering afterwards (the normal flow: join the
      // lobby, host starts, then you open the match) never learned when it began and
      // their "time left" readout stayed blank for the whole match.
      if (gamePlayer.session.startedAt) {
        socket.emit('game_started', { startedAt: gamePlayer.session.startedAt });
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
          socket.emit('anti_cheat_warning', { reason: accuracyCheck.reason });
          return;
        }
        const motionCheck = checkMotion(isMovingOnFoot);
        if (!motionCheck.allowed) {
          socket.emit('anti_cheat_warning', { reason: motionCheck.reason });
          return;
        }

        const speedCheck = checkSpeed(p, speed);
        if (!speedCheck.allowed) {
          socket.emit('anti_cheat_warning', { reason: speedCheck.reason });
          return;
        }

        const prev = lastFix.get(gamePlayerId);
        if (!checkTeleport(prev, { lat, lng, timestamp: now }, speedCheck.ceilingMps)) {
          socket.emit('anti_cheat_warning', { reason: 'Position jump exceeds plausible foot travel for the elapsed time.' });
          return;
        }
        lastFix.set(gamePlayerId, { lat, lng, timestamp: now });
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
          await checkJailContainment(roomCode, gameSessionId, p, session);
        } else if (!p.isCaught && !p.isOut && mode !== 'INFECTION') {
          await checkContainment(roomCode, gameSessionId, p, session, mode);
        }
      } else if (p.role === 'HUNTER' && gameSessionId && mode !== 'INFECTION' && !p.isOut) {
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
        for (const runner of runners) pushCompassToRunner(runner, hunters);
        pushRadarToHunter(roomCode, p, runners);
      } else if (p.role === 'RUNNER') {
        pushCompassToRunner(p, hunters);
        for (const hunter of hunters) pushRadarToHunter(roomCode, hunter, runners);
      }

      io.to(`${roomCode}_observers`).emit('roster_update', publicRoster(session));
    }
  );

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
      const mode = sessionModes.get(roomCode) ?? 'STANDARD';

      if (!hunter) return;

      if (mode === 'SQUAD') {
        if (!hunter.squad || !runner?.squad || hunter.squad === runner.squad) {
          socket.emit('catch_failed', { reason: 'Squad mode: you can only tag members of other squads.' });
          return;
        }
      } else if (hunter.role !== 'HUNTER') {
        socket.emit('catch_failed', { reason: 'Only hunters may attempt a catch.' });
        return;
      }

      if (!runner || runner.isCaught) {
        socket.emit('catch_failed', { reason: 'Target is not an active runner.' });
        return;
      }
      if (runner.arrestCode !== arrestCode) {
        socket.emit('catch_failed', { reason: 'Invalid arrest code.' });
        return;
      }

      const hPt = turf.point([hunter.lng, hunter.lat]);
      const rPt = turf.point([runner.lng, runner.lat]);
      const distance = turf.distance(hPt, rPt, { units: 'meters' });
      if (distance > CATCH_VERIFICATION_RADIUS_METERS) {
        socket.emit('catch_failed', { reason: `Physical distance (${Math.round(distance)}m) exceeds ${CATCH_VERIFICATION_RADIUS_METERS}m verification radius.` });
        return;
      }
      if (isWithinAnySafeZone(session, { lat: runner.lat, lng: runner.lng })) {
        socket.emit('catch_failed', { reason: 'Target is protected inside an active safe zone.' });
        return;
      }

      const gameSessionId = await resolveSessionId(roomCode);
      if (!gameSessionId) return;

      if (mode === 'INFECTION') {
        runner.role = 'HUNTER';
        runner.isCaught = false;
        await gameService.convertRunnerToHunter(gameSessionId, runner.id);
        io.to(roomCode).emit('player_infected', {
          runnerId: runner.id,
          hunterId: hunter.id,
          timestamp: new Date().toISOString(),
        });
      } else {
        runner.isCaught = true;
        await gameService.recordCatch(gameSessionId, hunter.id, runner.id);
        io.to(roomCode).emit('player_caught', {
          runnerId: runner.id,
          hunterId: hunter.id,
          timestamp: new Date().toISOString(),
        });
        await checkStandardWinCondition(roomCode, gameSessionId, session, mode);
      }
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
    if (mode === 'INFECTION') {
      socket.emit('catch_failed', { reason: 'This match uses the code-entry catch flow.' });
      return;
    }

    if (mode === 'SQUAD') {
      if (!hunter.squad || !runner?.squad || hunter.squad === runner.squad) {
        socket.emit('catch_failed', { reason: 'Squad mode: you can only tag members of other squads.' });
        return;
      }
    } else if (hunter.role !== 'HUNTER') {
      socket.emit('catch_failed', { reason: 'Only hunters may attempt a catch.' });
      return;
    }

    if (!runner || runner.isCaught || runner.isOut) {
      socket.emit('catch_failed', { reason: 'Target is not an active runner.' });
      return;
    }

    const distance = turf.distance(turf.point([hunter.lng, hunter.lat]), turf.point([runner.lng, runner.lat]), {
      units: 'meters',
    });
    if (distance > CATCH_VERIFICATION_RADIUS_METERS) {
      socket.emit('catch_failed', {
        reason: `Physical distance (${Math.round(distance)}m) exceeds ${CATCH_VERIFICATION_RADIUS_METERS}m verification radius.`,
      });
      return;
    }
    if (isWithinAnySafeZone(session, { lat: runner.lat, lng: runner.lng })) {
      socket.emit('catch_failed', { reason: 'Target is protected inside an active safe zone.' });
      return;
    }

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
        // Doesn't resolve anything — hands it to the hunter to confirm it was accidental.
        // The pending entry stays exactly as it is; a genuine disagreement (the hunter
        // won't confirm) just falls back to the host's existing host_override control,
        // or the stale-request sweep eventually clears it.
        io.to(hunter.id).emit('catch_deny_confirm', { requestId: pending.requestId, runnerUsername: runner.username });
        return;
      }

      requests!.delete(runnerId);
      const gameSessionId = await resolveSessionId(roomCode);
      if (!gameSessionId) return;
      const settings = sessionSettingsCache.get(roomCode);
      const mode = sessionModes.get(roomCode) ?? 'STANDARD';

      if (decision === 'accept') {
        const jail = !!settings?.jailEnabled;
        runner.isCaught = true;
        runner.isJailed = jail;
        await gameService.recordCatchAccepted(gameSessionId, hunter.id, runner.id, jail);
        if (jail) {
          io.to(roomCode).emit('player_jailed', { runnerId: runner.id, hunterId: hunter.id, timestamp: new Date().toISOString() });
        } else {
          io.to(roomCode).emit('player_caught', { runnerId: runner.id, hunterId: hunter.id, timestamp: new Date().toISOString() });
        }
        await checkStandardWinCondition(roomCode, gameSessionId, session, mode);
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
    if (!reviver || !target || !target.isCaught) {
      socket.emit('error_event', { reason: 'Nothing to revive.' });
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

    target.isCaught = false;
    const gameSessionId = await resolveSessionId(roomCode);
    if (gameSessionId) await gameService.revivePlayer(gameSessionId, target.id, reviver.id);

    io.to(roomCode).emit('player_revived', {
      playerId: target.id,
      revivedById: reviver.id,
      timestamp: new Date().toISOString(),
    });
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

    target.isCaught = isCaught;
    const gameSessionId = await resolveSessionId(roomCode);
    if (gameSessionId) await gameService.hostOverridePlayerStatus(gameSessionId, target.id, isCaught);

    io.to(roomCode).emit('host_override_applied', {
      playerId: target.id,
      isCaught,
      timestamp: new Date().toISOString(),
    });
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

    io.to(roomCode).emit('player_joined', publicRoster(session));
  });

  socket.on('collect_powerup', async ({ spawnId }: { spawnId: string }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const gamePlayerId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !gamePlayerId) return;
    const session = activeSessions.get(roomCode);
    if (!session || !session.has(gamePlayerId)) return;
    const player = session.get(gamePlayerId)!;

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
    if (spawn.type === 'ADRENALINE' && player.role !== 'RUNNER') {
      socket.emit('error_event', { reason: 'Only runners can pick up Adrenaline.' });
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

    let runnerBearingDegrees: number | undefined;
    if (powerUpType === 'GHOST_DECOY') {
      const prevFix = lastFix.get(gamePlayerId);
      const player = session.get(gamePlayerId);
      if (prevFix && player && (prevFix.lat !== player.lat || prevFix.lng !== player.lng)) {
        runnerBearingDegrees = turf.bearing(turf.point([prevFix.lng, prevFix.lat]), turf.point([player.lng, player.lat]));
      }
    }

    const result = usePowerUp(session, gamePlayerId, powerUpType, decoys, roomCode, runnerBearingDegrees);
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
      activeSessions.delete(roomCode);
      sessionModes.delete(roomCode);
      sessionSettingsCache.delete(roomCode);
      sessionStartedAtCache.delete(roomCode);
      sessionHostCache.delete(roomCode);
      decoys.delete(roomCode);
      boundaryViolationSince.delete(roomCode);
      boundaryLastDamageAt.delete(roomCode);
      jailViolationSince.delete(roomCode);
      pendingCatchRequests.delete(roomCode);
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
function pushCompassToRunner(runner: PlayerState, hunters: PlayerState[]) {
  if (runner.isCaught || hunters.length === 0) return;
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
  });
}

/** Mirrors `pushCompassToRunner` for a hunter's radar — pushed either from that hunter's
 *  own tick, or for every hunter in the room whenever a runner's tick lands, each
 *  respecting their own Thermal Vision/EMP Jammer buffs individually. */
function pushRadarToHunter(roomCode: string, hunter: PlayerState, runners: PlayerState[]) {
  if (isBuffActive(hunter, 'EMP_JAMMER')) {
    io.to(hunter.id).emit('radar_broadcast', { runners: [], runnerBearings: [], decoys: [], jammed: true });
    return;
  }
  const thermalActive = isBuffActive(hunter, 'THERMAL_VISION');
  const hunterPt = turf.point([hunter.lng, hunter.lat]);
  // Thermal Vision pierces every invisible runner's cloak everywhere on the map, not just
  // nearby ones — but only for the hunter who actually activated it; every other hunter's
  // own radar keeps filtering invisible runners out normally.
  const visibleRunners = runners.filter((r) => !isBuffActive(r, 'INVISIBILITY_10MIN') || thermalActive);
  const runnerBearings = visibleRunners
    .map((r) => {
      const rPt = turf.point([r.lng, r.lat]);
      return {
        runnerId: r.id,
        username: r.username,
        distanceMeters: Math.round(turf.distance(hunterPt, rPt, { units: 'meters' })),
        bearingDegrees: (turf.bearing(hunterPt, rPt) + 360) % 360,
      };
    })
    .sort((a, b) => a.distanceMeters - b.distanceMeters);
  pruneExpiredDecoys(decoys, roomCode);
  const liveDecoys = (decoys.get(roomCode) ?? []).map((d) => {
    const pos = currentDecoyPosition(d);
    return { lat: pos.lat, lng: pos.lng, isDecoy: true };
  });
  io.to(hunter.id).emit('radar_broadcast', { runners: visibleRunners, runnerBearings, decoys: liveDecoys, jammed: false });
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
  const outsideBy = Math.max(
    distanceOutsidePolygonMeters(point, settings.boundsPolygon),
    zone ? distanceOutsideZone(point, zone) : 0
  );
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

  const now = Date.now();
  const since = violations.get(player.id);
  if (!since) {
    violations.set(player.id, now);
    io.to(player.id).emit('boundary_status', { outside: true, warning: true });
    return;
  }
  if (now - since < BOUNDARY_WARNING_GRACE_MS) return;
  const lastDamage = ticks.get(player.id) ?? since;
  if (now - lastDamage < BOUNDARY_DAMAGE_TICK_MS) return;
  ticks.set(player.id, now);

  player.hearts = Math.max(0, player.hearts - 1);
  await prisma.gamePlayer.update({ where: { id: player.id }, data: { hearts: player.hearts } });
  io.to(roomCode).emit('hearts_update', { playerId: player.id, hearts: player.hearts, cause: 'BOUNDARY' });

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

async function checkStandardWinCondition(
  roomCode: string,
  gameSessionId: string,
  session: Map<string, PlayerState>,
  mode: GameMode
) {
  // Widened from STANDARD-only: this previously silently no-op'd for SQUAD mode entirely
  // (a pre-existing gap), which would leave SQUAD matches with the new hearts/jail system
  // unable to ever end via elimination.
  if (mode !== 'STANDARD' && mode !== 'SQUAD') return;
  const activeRunners = Array.from(session.values()).filter(
    (x) => x.role === 'RUNNER' && !x.isCaught && !x.isOut
  );
  if (activeRunners.length === 0) {
    await gameService.endSession(gameSessionId);
    sessionStartedAtCache.delete(roomCode);
    io.to(roomCode).emit('game_over', { reason: 'ALL_RUNNERS_RESOLVED' });
  }
}

/** New win condition: if every hunter has been eliminated — by containment damage, or by
 *  losing a gamble duel outright — the runners win early. Only ever called right after a
 *  hunter's isOut actually flips true. */
async function checkHunterEliminationWinCondition(
  roomCode: string,
  gameSessionId: string,
  session: Map<string, PlayerState>,
  mode: GameMode
) {
  if (mode === 'INFECTION') return;
  const activeHunters = Array.from(session.values()).filter((x) => x.role === 'HUNTER' && !x.isOut);
  if (activeHunters.length === 0) {
    await gameService.endSession(gameSessionId);
    sessionStartedAtCache.delete(roomCode);
    io.to(roomCode).emit('game_over', { reason: 'ALL_HUNTERS_ELIMINATED' });
  }
}

async function endMatch(roomCode: string, reason: string) {
  const gameSessionId = await resolveSessionId(roomCode);
  if (!gameSessionId) return;
  await gameService.endSession(gameSessionId);
  sessionStartedAtCache.delete(roomCode);
  io.to(roomCode).emit('game_over', { reason });
}

async function endMatchIfExpired(roomCode: string): Promise<boolean> {
  const startedAtMs = sessionStartedAtCache.get(roomCode);
  const settings = sessionSettingsCache.get(roomCode);
  if (!startedAtMs || !settings) return false;
  if (Date.now() - startedAtMs < settings.durationMinutes * 60_000) return false;
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
      const jail = !!sessionSettingsCache.get(roomCode)?.jailEnabled;
      runner.isCaught = true;
      runner.isJailed = jail;
      await gameService.recordCatchAccepted(gameSessionId, hunter.id, runner.id, jail);
      io.to(roomCode).emit(jail ? 'player_jailed' : 'player_caught', {
        runnerId: runner.id,
        hunterId: hunter.id,
        timestamp: new Date().toISOString(),
      });
      await checkStandardWinCondition(roomCode, gameSessionId, session, sessionModes.get(roomCode) ?? 'STANDARD');
    }
  }

  for (const [roomCode, requests] of pendingCatchRequests.entries()) {
    for (const [runnerId, req] of Array.from(requests.entries())) {
      if (now - req.requestedAt >= CATCH_REQUEST_TIMEOUT_MS) {
        requests.delete(runnerId);
        io.to(req.hunterId).emit('catch_request_expired', { runnerId, requestId: req.requestId });
        io.to(runnerId).emit('catch_request_cancelled', { hunterId: req.hunterId });
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

const PORT = Number(process.env.PORT ?? 4000);

export function startServer() {
  httpServer.listen(PORT, () => {
    console.log(`[Server] Hunting Game backend active on port ${PORT}`);
  });
}
