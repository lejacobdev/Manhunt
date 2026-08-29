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

const createSessionSchema = z.object({
  durationMinutes: z.number().min(5).max(240),
  radarIntervalSec: z.number().min(15).max(600),
  boundsPolygon: z.array(pointSchema).min(3),
  powerUpCount: z.number().min(1).max(30).optional(),
  mode: z.enum(['STANDARD', 'INFECTION', 'SQUAD']).optional(),
});

gamesRouter.post('/', async (req: AuthedRequest, res) => {
  const parsed = createSessionSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });

  const session = await gameService.createSession({
    hostId: req.user!.userId,
    ...parsed.data,
  });
  await gameService.joinSession(session.id, req.user!.userId, 'SUPERVISOR');
  return res.status(201).json({ session });
});

const joinSchema = z.object({
  role: z.enum(['HUNTER', 'RUNNER', 'SUPERVISOR', 'SPECTATOR']),
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
