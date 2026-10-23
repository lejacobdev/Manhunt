import { Router } from 'express';
import { z } from 'zod';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { prisma } from '../lib/prisma';
import { overpassSpawner } from '../services/OverpassSpawner';
import { zodErrorMessage } from '../utils/validation';
import { PowerUpType, canUsePowerUp } from '../types';

export const powerUpsRouter = Router();
powerUpsRouter.use(requireAuth);

powerUpsRouter.get('/session/:sessionId', async (req: AuthedRequest, res) => {
  const spawns = await prisma.powerUpSpawn.findMany({
    where: { sessionId: req.params.sessionId, isCollected: false, expiresAt: { gt: new Date() } },
  });

  // Power-ups that only help one side (POWER_UP_ROLES: Adrenaline, Ghost Decoy and EMP Jammer
  // for runners, Thermal Vision for hunters) are filtered out of the other side's map feed
  // rather than shown and then refused on collection — see the guard in collect_powerup.
  const me = await prisma.gamePlayer.findUnique({
    where: { sessionId_userId: { sessionId: req.params.sessionId, userId: req.user!.userId } },
    select: { role: true },
  });
  const visible = spawns.filter((s) => !me || canUsePowerUp(me.role, s.type as PowerUpType));

  return res.json({ spawns: visible });
});

const verifySchema = z.object({ lat: z.number(), lng: z.number() });

/** Real-world accessibility check for a single coordinate before it's used as a spawn/safe-zone. */
powerUpsRouter.post('/verify-point', async (req: AuthedRequest, res) => {
  const parsed = verifySchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  const isPublic = await overpassSpawner.isPointOnPublicLand(parsed.data);
  return res.json({ isPublic });
});
