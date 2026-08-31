import express from 'express';
import cors from 'cors';
import { createServer } from 'http';
import { Server, Socket } from 'socket.io';
import * as turf from '@turf/turf';
import jwt from 'jsonwebtoken';

import { authRouter } from './routes/auth';
import { friendsRouter } from './routes/friends';
import { gamesRouter } from './routes/games';
import { powerUpsRouter } from './routes/powerups';
import { invitesRouter } from './routes/invites';
import { prisma } from './lib/prisma';
import { gameService, GameSettings } from './services/GameService';
import { checkAccuracy, checkMotion, checkSpeed, checkTeleport } from './services/AntiCheatService';
import { computeZoneState, distanceOutsideZone } from './services/ZoneService';
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
  CATCH_VERIFICATION_RADIUS_METERS,
  EXTRACTION_RADIUS_METERS,
  GameMode,
  PlayerState,
  PowerUpType,
  THERMAL_VISION_INTERVAL_MS,
  THERMAL_VISION_RADIUS_METERS,
  ZONE_GRACE_MS,
  ZONE_GRACE_METERS,
} from './types';

const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-secret-do-not-use-in-production';

export const app = express();
app.use(cors({ origin: process.env.CORS_ORIGIN ?? '*' }));
app.use(express.json());

app.get('/health', (_req, res) => res.json({ ok: true, service: 'hunting-game-backend' }));
app.use('/auth', authRouter);
app.use('/friends', friendsRouter);
app.use('/games', gamesRouter);
app.use('/powerups', powerUpsRouter);
app.use('/invites', invitesRouter);

export const httpServer = createServer(app);
export const io = new Server(httpServer, { cors: { origin: process.env.CORS_ORIGIN ?? '*' } });

// roomCode -> (gamePlayerId -> PlayerState)
const activeSessions: Map<string, Map<string, PlayerState>> = new Map();
// roomCode -> game mode, cached at join to avoid a DB hit per tick
const sessionModes: Map<string, GameMode> = new Map();
// roomCode -> immutable session settings (duration, radar interval, boundary, extraction point)
export const sessionSettingsCache: Map<string, GameSettings> = new Map();
// roomCode -> match start time (epoch ms) — set at join if already started, or live-patched by the
// REST /games/:code/start route (see routes/games.ts) the moment the host starts the match.
export const sessionStartedAtCache: Map<string, number> = new Map();
// roomCode -> ghost decoys currently live
const decoys: DecoyMap = new Map();
// roomCode -> gamePlayerId -> epoch ms of when they were first detected outside the shrinking zone
const zoneViolationSince: Map<string, Map<string, number>> = new Map();
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
      socket.data.roomCode = roomCode;
      socket.data.gamePlayerId = gamePlayerId;
      sessionModes.set(roomCode, gamePlayer.session.mode as GameMode);
      sessionSettingsCache.set(roomCode, gamePlayer.session.settings as unknown as GameSettings);
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
        isExtracted: gamePlayer.isExtracted,
        inventory: (gamePlayer.inventory as PowerUpType[]) ?? [],
        activeBuffs: {},
        lastUpdate: Date.now(),
      };
      session.set(gamePlayer.id, state);

      if (gamePlayer.role === 'SUPERVISOR' || gamePlayer.role === 'SPECTATOR') {
        // Both roles are pure observers — neither carries an inventory or takes
        // gameplay actions — so both get the continuous full-roster feed that
        // hunters/runners don't (those only see each other via radar pings).
        socket.join(`${roomCode}_observers`);
      }

      io.to(roomCode).emit('player_joined', Array.from(session.values()));

      const settings = sessionSettingsCache.get(roomCode);
      if (settings?.extractionPoint) {
        socket.emit('extraction_point', settings.extractionPoint);
      }
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
      if (p.isCaught || p.isExtracted) return;

      pruneExpiredBuffs(p);

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
      const now = Date.now();
      if (!checkTeleport(prev, { lat, lng, timestamp: now }, speedCheck.ceilingMps)) {
        socket.emit('anti_cheat_warning', { reason: 'Position jump exceeds plausible foot travel for the elapsed time.' });
        return;
      }
      lastFix.set(gamePlayerId, { lat, lng, timestamp: now });

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
        await checkExtraction(roomCode, gameSessionId, p, session, mode);
        if (mode === 'STANDARD' && !p.isCaught && !p.isExtracted) {
          await checkZoneContainment(roomCode, gameSessionId, p, session);
        }
      }

      const allPlayers = Array.from(session.values());
      const hunters = allPlayers.filter((x) => x.role === 'HUNTER');
      const runners = allPlayers.filter((x) => x.role === 'RUNNER' && !x.isCaught && !x.isExtracted);

      if (p.role === 'RUNNER' && !p.isCaught && hunters.length > 0) {
        let minDist = Infinity;
        let nearestHunterBearing = 0;
        const rPt = turf.point([p.lng, p.lat]);
        for (const h of hunters) {
          const hPt = turf.point([h.lng, h.lat]);
          const dist = turf.distance(rPt, hPt, { units: 'meters' });
          if (dist < minDist) {
            minDist = dist;
            nearestHunterBearing = turf.bearing(rPt, hPt);
          }
        }
        socket.emit('compass_update', {
          distanceMeters: Math.round(minDist),
          bearingDegrees: (nearestHunterBearing + 360) % 360,
        });
      }

      if (p.role === 'HUNTER') {
        const settings = sessionSettingsCache.get(roomCode);
        const baseIntervalMs = (settings?.radarIntervalSec ?? 5) * 1000;
        const thermalActive = isBuffActive(p, 'THERMAL_VISION');
        const effectiveIntervalMs = thermalActive ? THERMAL_VISION_INTERVAL_MS : baseIntervalMs;
        const sinceLastPush = now - (p.lastRadarPushAt ?? 0);

        // Tactical radar per spec 1.1: hunters get periodic pings, not a continuous
        // feed — except Thermal Vision, which forces a 1-second refresh.
        if (sinceLastPush >= effectiveIntervalMs) {
          p.lastRadarPushAt = now;

          if (isBuffActive(p, 'EMP_JAMMER')) {
            socket.emit('radar_broadcast', { runners: [], decoys: [], jammed: true });
          } else {
            const hunterPt = turf.point([p.lng, p.lat]);
            const visibleRunners = runners.filter((r) => {
              if (!isBuffActive(r, 'INVISIBILITY_10MIN')) return true;
              if (!thermalActive) return false;
              const dist = turf.distance(hunterPt, turf.point([r.lng, r.lat]), { units: 'meters' });
              return dist <= THERMAL_VISION_RADIUS_METERS;
            });
            pruneExpiredDecoys(decoys, roomCode);
            const liveDecoys = (decoys.get(roomCode) ?? []).map((d) => {
              const pos = currentDecoyPosition(d);
              return { lat: pos.lat, lng: pos.lng, isDecoy: true };
            });
            socket.emit('radar_broadcast', { runners: visibleRunners, decoys: liveDecoys, jammed: false });
          }
        }
      }

      io.to(`${roomCode}_observers`).emit('roster_update', allPlayers);
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

      if (!runner || runner.isCaught || runner.isExtracted) {
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

  /** Supervisor admin override: force-resolve a disputed catch/status. */
  socket.on('supervisor_override', async ({ targetId, isCaught }: { targetId: string; isCaught: boolean }) => {
    const roomCode = socket.data.roomCode as string | undefined;
    const supervisorId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !supervisorId) return;
    const session = activeSessions.get(roomCode);
    if (!session) return;
    const supervisor = session.get(supervisorId);
    if (!supervisor || supervisor.role !== 'SUPERVISOR') {
      socket.emit('error_event', { reason: 'Only supervisors can override player status.' });
      return;
    }
    const target = session.get(targetId);
    if (!target) {
      socket.emit('error_event', { reason: 'Player not found.' });
      return;
    }

    target.isCaught = isCaught;
    const gameSessionId = await resolveSessionId(roomCode);
    if (gameSessionId) await gameService.supervisorOverridePlayerStatus(gameSessionId, target.id, isCaught);

    io.to(roomCode).emit('supervisor_override_applied', {
      playerId: target.id,
      isCaught,
      timestamp: new Date().toISOString(),
    });
  });

  /** Supervisor admin action: force-end the match immediately. */
  socket.on('supervisor_end_game', async () => {
    const roomCode = socket.data.roomCode as string | undefined;
    const supervisorId = socket.data.gamePlayerId as string | undefined;
    if (!roomCode || !supervisorId) return;
    const session = activeSessions.get(roomCode);
    const supervisor = session?.get(supervisorId);
    if (!supervisor || supervisor.role !== 'SUPERVISOR') {
      socket.emit('error_event', { reason: 'Only supervisors can end the match.' });
      return;
    }
    await endMatch(roomCode, 'SUPERVISOR_ENDED');
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
    if (distance > CATCH_VERIFICATION_RADIUS_METERS) {
      socket.emit('error_event', { reason: 'Too far from the power-up to collect it.' });
      return;
    }

    const gameSessionId = await resolveSessionId(roomCode);
    if (!gameSessionId) return;

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
      await prisma.gamePlayer.update({ where: { id: gamePlayerId }, data: { inventory: player.inventory } });
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
      decoys.delete(roomCode);
      zoneViolationSince.delete(roomCode);
    }
  }
  lastFix.delete(gamePlayerId);
}

async function resolveSessionId(roomCode: string): Promise<string | undefined> {
  const gameSession = await prisma.gameSession.findUnique({ where: { code: roomCode } });
  return gameSession?.id;
}

/** Checks whether a runner has reached the designated extraction point and, if so, marks them safe. */
async function checkExtraction(
  roomCode: string,
  gameSessionId: string,
  runner: PlayerState,
  session: Map<string, PlayerState>,
  mode: GameMode
) {
  const settings = sessionSettingsCache.get(roomCode);
  const extractionPoint = settings?.extractionPoint;
  if (!extractionPoint) return;

  const distance = turf.distance(
    turf.point([runner.lng, runner.lat]),
    turf.point([extractionPoint.lng, extractionPoint.lat]),
    { units: 'meters' }
  );
  if (distance > EXTRACTION_RADIUS_METERS) return;

  runner.isExtracted = true;
  await gameService.recordExtraction(gameSessionId, runner.id);
  io.to(roomCode).emit('player_extracted', { playerId: runner.id, timestamp: new Date().toISOString() });

  if (mode === 'STANDARD') {
    await checkStandardWinCondition(roomCode, gameSessionId, session, mode);
  }
}

/** Standard mode: auto-catches a runner who has strayed outside the shrinking safe zone for too long. */
async function checkZoneContainment(
  roomCode: string,
  gameSessionId: string,
  runner: PlayerState,
  session: Map<string, PlayerState>
) {
  const settings = sessionSettingsCache.get(roomCode);
  const startedAtMs = sessionStartedAtCache.get(roomCode);
  if (!settings || !startedAtMs) return;

  const zone = computeZoneState(settings.boundsPolygon, new Date(startedAtMs), settings.durationMinutes);
  const outsideBy = distanceOutsideZone({ lat: runner.lat, lng: runner.lng }, zone);

  const violations = zoneViolationSince.get(roomCode) ?? new Map<string, number>();
  zoneViolationSince.set(roomCode, violations);

  if (outsideBy <= ZONE_GRACE_METERS) {
    violations.delete(runner.id);
    return;
  }

  const now = Date.now();
  const since = violations.get(runner.id);
  if (!since) {
    violations.set(runner.id, now);
    return;
  }

  if (now - since >= ZONE_GRACE_MS) {
    violations.delete(runner.id);
    runner.isCaught = true;
    await gameService.recordZoneCatch(gameSessionId, runner.id);
    io.to(roomCode).emit('player_caught', {
      runnerId: runner.id,
      hunterId: null,
      reason: 'ZONE',
      timestamp: new Date().toISOString(),
    });
    await checkStandardWinCondition(roomCode, gameSessionId, session, 'STANDARD');
  }
}

async function checkStandardWinCondition(
  roomCode: string,
  gameSessionId: string,
  session: Map<string, PlayerState>,
  mode: GameMode
) {
  if (mode !== 'STANDARD') return;
  const activeRunners = Array.from(session.values()).filter(
    (x) => x.role === 'RUNNER' && !x.isCaught && !x.isExtracted
  );
  if (activeRunners.length === 0) {
    await gameService.endSession(gameSessionId);
    sessionStartedAtCache.delete(roomCode);
    io.to(roomCode).emit('game_over', { reason: 'ALL_RUNNERS_RESOLVED' });
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
// broadcast the current shrinking-zone state for Standard-mode matches, and act as a
// backstop for match-timer expiry in case no player sent a location update right at the deadline.
setInterval(async () => {
  for (const roomCode of activeSessions.keys()) {
    if (await endMatchIfExpired(roomCode)) continue;

    const mode = sessionModes.get(roomCode);
    const settings = sessionSettingsCache.get(roomCode);
    const startedAtMs = sessionStartedAtCache.get(roomCode);
    if (mode === 'STANDARD' && settings && startedAtMs) {
      const zone = computeZoneState(settings.boundsPolygon, new Date(startedAtMs), settings.durationMinutes);
      io.to(roomCode).emit('zone_update', zone);
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
