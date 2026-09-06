import { Router } from 'express';
import { z } from 'zod';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { gameService, GameSettings } from '../services/GameService';
import { overpassSpawner } from '../services/OverpassSpawner';
import { prisma } from '../lib/prisma';
import { zodErrorMessage } from '../utils/validation';
// Circular import (server.ts imports this router) — safe because `io` and
// the caches are only read inside route handlers, which run long after both
// modules have finished loading, never at module top level.
import { io, sessionSettingsCache, sessionStartedAtCache } from '../server';
import { GameMode } from '../types';

export const gamesRouter = Router();
gamesRouter.use(requireAuth);

const pointSchema = z.object({ lat: z.number(), lng: z.number() });

const createSessionSchema = z
  .object({
    durationMinutes: z.number().min(5).max(240),
    radarIntervalSec: z.number().min(15).max(600),
    // Empty is valid now — hosting opens the lobby immediately, and the play area gets
    // drawn from inside it (via PATCH /:code/settings) before the host can start.
    boundsPolygon: z.array(pointSchema).optional().default([]),
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

const updateSettingsSchema = z.object({
  durationMinutes: z.number().min(5).max(240).optional(),
  radarIntervalSec: z.number().min(15).max(600).optional(),
  // Only meaningful the first time — see the guard below. Once spawns exist they're tied to
  // this exact shape, so a later redraw would strand them outside the new play area.
  boundsPolygon: z.array(pointSchema).optional(),
  jailEnabled: z.boolean().optional(),
  jailPolygon: z.array(pointSchema).optional(),
  gamblingEnabled: z.boolean().optional(),
});

/**
 * Host-only settings changes from the pre-match lobby, so a host doesn't have to tear the
 * game down and re-host just to change the duration, draw the play area, or turn jail on
 * once everyone's in.
 */
gamesRouter.patch('/:code/settings', async (req: AuthedRequest, res) => {
  const session = await gameService.getSessionByCode(req.params.code);
  if (!session) return res.status(404).json({ error: 'Game not found.' });
  if (session.hostId !== req.user!.userId) {
    return res.status(403).json({ error: 'Only the host can change the settings.' });
  }
  if (session.status !== 'LOBBY') {
    return res.status(409).json({ error: 'Settings can only be changed before the match starts.' });
  }
  const parsed = updateSettingsSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });

  const current = session.settings as unknown as GameSettings;
  const settingBoundaryNow = (parsed.data.boundsPolygon?.length ?? 0) >= 3;
  if (parsed.data.boundsPolygon && current.boundsPolygon.length >= 3) {
    return res.status(409).json({ error: 'The play area is already set for this game and can\'t be redrawn.' });
  }
  if (parsed.data.boundsPolygon && !settingBoundaryNow) {
    return res.status(400).json({ error: 'Draw a play-area boundary with at least 3 points.' });
  }

  const merged: GameSettings = { ...current, ...parsed.data };
  // Turning jail on needs an area to hold people in — either one drawn in this request or
  // one already stored from a previous save.
  if (merged.jailEnabled && (merged.jailPolygon?.length ?? 0) < 3) {
    return res.status(400).json({ error: 'Draw a jail area with at least 3 points before enabling jail mode.' });
  }
  if (!merged.jailEnabled) merged.jailPolygon = undefined;

  // First time the boundary is set: lay out the extraction point and power-up spawns that
  // couldn't exist until there was a real play area to place them inside (see createSession).
  if (settingBoundaryNow) {
    merged.extractionPoint = await gameService.generateExtractionPoint(merged.boundsPolygon, session.mode as GameMode);
    await gameService.layOutSpawns(session.id, merged.boundsPolygon, merged.durationMinutes);
  }

  const updated = await gameService.updateSessionSettings(session.id, merged);
  sessionSettingsCache.set(session.code, merged);
  io.to(session.code).emit('settings_updated', merged);
  return res.json({ session: updated });
});

/**
 * The one unfinished match this user is in, if any — lets the app offer a way back into a
 * lobby or a running match after it was closed, instead of stranding them outside a game
 * they're still a member of.
 */
gamesRouter.get('/active/mine', async (req: AuthedRequest, res) => {
  const player = await prisma.gamePlayer.findFirst({
    where: { userId: req.user!.userId, session: { status: { in: ['LOBBY', 'ACTIVE'] } } },
    include: { session: true },
    orderBy: { joinedAt: 'desc' },
  });
  if (!player) return res.json({ session: null, player: null });
  return res.json({ session: player.session, player });
});

gamesRouter.post('/:code/start', async (req: AuthedRequest, res) => {
  const session = await gameService.getSessionByCode(req.params.code);
  if (!session) return res.status(404).json({ error: 'Game not found.' });
  if (session.hostId !== req.user!.userId) {
    return res.status(403).json({ error: 'Only the host can start the game.' });
  }
  const settings = session.settings as unknown as GameSettings;
  if (settings.boundsPolygon.length < 3) {
    return res.status(409).json({ error: 'Draw the play area in Settings before starting.' });
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
