import { Router } from 'express';
import { z } from 'zod';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { gameService } from '../services/GameService';
import { overpassSpawner } from '../services/OverpassSpawner';
import { prisma } from '../lib/prisma';
import { zodErrorMessage } from '../utils/validation';
// Circular import (server.ts imports this router) — safe because `io` and
// `sessionStartedAtCache` are only read inside route handlers, which run
// long after both modules have finished loading, never at module top level.
import { io, sessionStartedAtCache } from '../server';

export const gamesRouter = Router();
gamesRouter.use(requireAuth);

const pointSchema = z.object({ lat: z.number(), lng: z.number() });

const createSessionSchema = z
  .object({
    durationMinutes: z.number().min(5).max(240),
    radarIntervalSec: z.number().min(15).max(600),
    boundsPolygon: z.array(pointSchema).min(3),
    powerUpCount: z.number().min(1).max(30).optional(),
    mode: z.enum(['STANDARD', 'INFECTION', 'SQUAD']).optional(),
    // The host plays too — same role choice as anyone joining, no separate
    // supervisor/observer role forced on them. Host-only admin actions (end
    // game, override a catch) are authorized via GameSession.hostId instead.
    role: z.enum(['HUNTER', 'RUNNER', 'SPECTATOR']),
    squad: z.string().max(40).optional(),
    jailEnabled: z.boolean().optional(),
    jailPolygon: z.array(pointSchema).optional(),
    gamblingEnabled: z.boolean().optional(),
  })
  .superRefine((data, ctx) => {
    if (data.jailEnabled && (data.jailPolygon?.length ?? 0) < 3) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'Draw a jail area with at least 3 points when jail mode is enabled.',
        path: ['jailPolygon'],
      });
    }
  });

gamesRouter.post('/', async (req: AuthedRequest, res) => {
  const parsed = createSessionSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  if (parsed.data.mode === 'SQUAD' && !parsed.data.squad) {
    return res.status(400).json({ error: 'Squad name is required to host a SQUAD mode game.' });
  }

  const session = await gameService.createSession({
    hostId: req.user!.userId,
    durationMinutes: parsed.data.durationMinutes,
    radarIntervalSec: parsed.data.radarIntervalSec,
    boundsPolygon: parsed.data.boundsPolygon,
    powerUpCount: parsed.data.powerUpCount,
    mode: parsed.data.mode,
    jailEnabled: parsed.data.jailEnabled,
    jailPolygon: parsed.data.jailPolygon,
    gamblingEnabled: parsed.data.gamblingEnabled,
  });
  const player = await gameService.joinSession(session.id, req.user!.userId, parsed.data.role, parsed.data.squad);
  return res.status(201).json({ session, player });
});

const joinSchema = z.object({
  role: z.enum(['HUNTER', 'RUNNER', 'SPECTATOR']),
  squad: z.string().max(40).optional(),
});

gamesRouter.post('/:code/join', async (req: AuthedRequest, res) => {
  const session = await gameService.getSessionByCode(req.params.code);
  if (!session) return res.status(404).json({ error: 'Game not found.' });
  if (session.status !== 'LOBBY') {
    return res.status(409).json({ error: 'Game has already started or ended.' });
  }
  const parsed = joinSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  if (session.mode === 'SQUAD' && !parsed.data.squad) {
    return res.status(400).json({ error: 'Squad name is required to join a SQUAD mode game.' });
  }

  const player = await gameService.joinSession(
    session.id,
    req.user!.userId,
    parsed.data.role,
    parsed.data.squad
  );
  return res.status(201).json({ player, session });
});

gamesRouter.post('/:code/start', async (req: AuthedRequest, res) => {
  const session = await gameService.getSessionByCode(req.params.code);
  if (!session) return res.status(404).json({ error: 'Game not found.' });
  if (session.hostId !== req.user!.userId) {
    return res.status(403).json({ error: 'Only the host can start the game.' });
  }
  const started = await gameService.startSession(session.id);
  // Live-patch the socket layer's cache so already-connected sockets (and any that
  // join after this point) immediately see the real match clock and shrinking zone,
  // rather than waiting on the next join_room DB read.
  if (started.startedAt) {
    sessionStartedAtCache.set(started.code, started.startedAt.getTime());
  }
  io.to(started.code).emit('game_started', { startedAt: started.startedAt });
  return res.json({ session: started });
});

gamesRouter.post('/:code/end', async (req: AuthedRequest, res) => {
  const session = await gameService.getSessionByCode(req.params.code);
  if (!session) return res.status(404).json({ error: 'Game not found.' });
  if (session.hostId !== req.user!.userId) {
    return res.status(403).json({ error: 'Only the host can end the game.' });
  }
  const ended = await gameService.endSession(session.id);
  sessionStartedAtCache.delete(session.code);
  io.to(session.code).emit('game_over', { reason: 'HOST_ENDED' });
  return res.json({ session: ended });
});

gamesRouter.get('/:code', async (req: AuthedRequest, res) => {
  const session = await gameService.getSessionByCode(req.params.code);
  if (!session) return res.status(404).json({ error: 'Game not found.' });
  return res.json({ session });
});

/**
 * Post-game (or in-progress) playback: every buffered GPS fix for the match, grouped
 * by player, ordered by time. Restricted to session members so spectators/hosts
 * of *this* match can scrub through it, but no one else can pull another match's tracks.
 */
gamesRouter.get('/:code/replay', async (req: AuthedRequest, res) => {
  const session = await gameService.getSessionByCode(req.params.code);
  if (!session) return res.status(404).json({ error: 'Game not found.' });
  const isMember = session.players.some((p) => p.userId === req.user!.userId);
  if (!isMember) return res.status(403).json({ error: 'You are not a member of this game.' });

  const logs = await prisma.locationLog.findMany({
    where: { sessionId: session.id },
    orderBy: { timestamp: 'asc' },
    take: 20_000,
  });

  const byPlayer = new Map<string, { lat: number; lng: number; accuracy: number; speed: number | null; timestamp: string }[]>();
  for (const log of logs) {
    const list = byPlayer.get(log.playerId) ?? [];
    list.push({ lat: log.latitude, lng: log.longitude, accuracy: log.accuracy, speed: log.speed, timestamp: log.timestamp.toISOString() });
    byPlayer.set(log.playerId, list);
  }

  const players = session.players.map((p) => ({
    gamePlayerId: p.id,
    username: p.user.username,
    role: p.role,
    track: byPlayer.get(p.id) ?? [],
  }));

  return res.json({
    startedAt: session.startedAt,
    endedAt: session.endedAt,
    players,
  });
});

/** Verifies a proposed play-area boundary actually contains real, public outdoor terrain. */
gamesRouter.post('/verify-boundary', async (req: AuthedRequest, res) => {
  const parsed = z.object({ boundsPolygon: z.array(pointSchema).min(3) }).safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });

  const points = await overpassSpawner.generatePublicPowerUpSpawns(parsed.data.boundsPolygon, 3);
  return res.json({ hasPublicAccess: points.length > 0, sampledPoints: points });
});

gamesRouter.get('/history/mine', async (req: AuthedRequest, res) => {
  const players = await prisma.gamePlayer.findMany({
    where: { userId: req.user!.userId },
    include: { session: true },
    orderBy: { joinedAt: 'desc' },
    take: 25,
  });
  return res.json({ history: players });
});
