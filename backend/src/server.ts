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
import { prisma } from './lib/prisma';
import { gameService } from './services/GameService';
import { checkSpeed, checkTeleport } from './services/AntiCheatService';
import {
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
  GameMode,
  PlayerState,
  PowerUpType,
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

export const httpServer = createServer(app);
export const io = new Server(httpServer, { cors: { origin: process.env.CORS_ORIGIN ?? '*' } });

// roomCode -> (gamePlayerId -> PlayerState)
const activeSessions: Map<string, Map<string, PlayerState>> = new Map();
// roomCode -> game mode, cached at ACTIVE start to avoid a DB hit per tick
const sessionModes: Map<string, GameMode> = new Map();
// roomCode -> ghost decoys currently live
const decoys: Map<string, { sessionOwnerId: string; lat: number; lng: number; expiresAt: number }[]> = new Map();
// gamePlayerId -> last accepted fix, used for teleport detection
const lastFix: Map<string, { lat: number; lng: number; timestamp: number }> = new Map();
// gamePlayerId -> pending location log entries flushed to Postgres periodically
const pendingLogs: Map<string, { playerId: string; lat: number; lng: number; accuracy: number; speed?: number }[]> = new Map();

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
        arrestCode: gamePlayer.arrestCode,
        isCaught: gamePlayer.isCaught,
        inventory: (gamePlayer.inventory as PowerUpType[]) ?? [],
        activeBuffs: {},
        lastUpdate: Date.now(),
      };
      session.set(gamePlayer.id, state);

      if (gamePlayer.role === 'SUPERVISOR') {
        socket.join(`${roomCode}_supervisors`);
      }

      io.to(roomCode).emit('player_joined', Array.from(session.values()));
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
    }: {
      lat: number;
      lng: number;
      speed?: number;
      accuracy: number;
      battery: number;
    }) => {
      const roomCode = socket.data.roomCode as string | undefined;
      const gamePlayerId = socket.data.gamePlayerId as string | undefined;
      if (!roomCode || !gamePlayerId) return;

      const session = activeSessions.get(roomCode);
      if (!session || !session.has(gamePlayerId)) return;
      const p = session.get(gamePlayerId)!;
      if (p.isCaught) return;

      pruneExpiredBuffs(p);

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
      p.lastUpdate = now;

      const logs = pendingLogs.get(roomCode) ?? [];
      logs.push({ playerId: gamePlayerId, lat, lng, accuracy, speed });
      pendingLogs.set(roomCode, logs);

      const allPlayers = Array.from(session.values());
      const hunters = allPlayers.filter((x) => x.role === 'HUNTER');
      const runners = allPlayers.filter((x) => x.role === 'RUNNER' && !x.isCaught);

      if (p.role === 'RUNNER' && hunters.length > 0) {
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
        // A hunter's own EMP_JAMMER debuff (cast on them by a runner) blanks their radar.
        if (isBuffActive(p, 'EMP_JAMMER')) {
          socket.emit('radar_broadcast', { runners: [], jammed: true });
        } else {
          const visibleRunners = runners.filter((r) => !isBuffActive(r, 'INVISIBILITY_10MIN') || isBuffActive(p, 'THERMAL_VISION'));
          pruneExpiredDecoys(decoys, roomCode);
          const liveDecoys = (decoys.get(roomCode) ?? []).map((d) => ({ lat: d.lat, lng: d.lng, isDecoy: true }));
          socket.emit('radar_broadcast', { runners: visibleRunners, decoys: liveDecoys, jammed: false });
        }
      }

      io.to(`${roomCode}_supervisors`).emit('supervisor_map_update', allPlayers);
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

      if (!hunter || hunter.role !== 'HUNTER') {
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

      const mode = sessionModes.get(roomCode) ?? 'STANDARD';
      const gameSession = await prisma.gameSession.findUnique({ where: { code: roomCode } });
      if (!gameSession) return;

      if (mode === 'INFECTION') {
        runner.role = 'HUNTER';
        runner.isCaught = false;
        await gameService.convertRunnerToHunter(gameSession.id, runner.id);
        io.to(roomCode).emit('player_infected', {
          runnerId: runner.id,
          hunterId: hunter.id,
          timestamp: new Date().toISOString(),
        });
      } else {
        runner.isCaught = true;
        await gameService.recordCatch(gameSession.id, hunter.id, runner.id);
        io.to(roomCode).emit('player_caught', {
          runnerId: runner.id,
          hunterId: hunter.id,
          timestamp: new Date().toISOString(),
        });

        const remainingRunners = Array.from(session.values()).filter((x) => x.role === 'RUNNER' && !x.isCaught);
        if (remainingRunners.length === 0 && mode === 'STANDARD') {
          await gameService.endSession(gameSession.id);
          io.to(roomCode).emit('game_over', { reason: 'ALL_RUNNERS_CAUGHT' });
        }
      }
    }
  );

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

    const gameSession = await prisma.gameSession.findUnique({ where: { code: roomCode } });
    if (!gameSession) return;

    grantPowerUp(player, spawn.type as PowerUpType);
    await gameService.recordPowerUpCollected(gameSession.id, spawn.id, gamePlayerId);
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

    const result = usePowerUp(session, gamePlayerId, powerUpType, decoys, roomCode);
    if (!result.ok) {
      socket.emit('error_event', { reason: result.error });
      return;
    }

    const player = session.get(gamePlayerId)!;
    const gameSession = await prisma.gameSession.findUnique({ where: { code: roomCode } });
    if (gameSession) {
      await gameService.recordPowerUpUsed(gameSession.id, gamePlayerId, powerUpType);
      await prisma.gamePlayer.update({ where: { id: gamePlayerId }, data: { inventory: player.inventory } });
    }

    socket.emit('inventory_update', { inventory: player.inventory });
    if (result.broadcastEvent) {
      io.to(roomCode).emit(result.broadcastEvent.type, result.broadcastEvent.payload);
    }
  });

  socket.on('leave_room', () => cleanupSocket(socket));
  socket.on('disconnect', () => cleanupSocket(socket));
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
      decoys.delete(roomCode);
    }
  }
  lastFix.delete(gamePlayerId);
}

// Periodically flush buffered location fixes to Postgres for post-game analytics/replay.
setInterval(async () => {
  for (const [roomCode, entries] of pendingLogs.entries()) {
    if (entries.length === 0) continue;
    pendingLogs.set(roomCode, []);
    const gameSession = await prisma.gameSession.findUnique({ where: { code: roomCode } });
    if (gameSession) {
      await gameService.logLocationBatch(gameSession.id, entries).catch((err) => {
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
