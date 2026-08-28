import { Router } from 'express';
import { z } from 'zod';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { prisma } from '../lib/prisma';
import { overpassSpawner } from '../services/OverpassSpawner';

export const powerUpsRouter = Router();
powerUpsRouter.use(requireAuth);

powerUpsRouter.get('/session/:sessionId', async (req: AuthedRequest, res) => {
  const spawns = await prisma.powerUpSpawn.findMany({
    where: { sessionId: req.params.sessionId, isCollected: false, expiresAt: { gt: new Date() } },
  });
  return res.json({ spawns });
});

const verifySchema = z.object({ lat: z.number(), lng: z.number() });

/** Real-world accessibility check for a single coordinate before it's used as a spawn/safe-zone. */
powerUpsRouter.post('/verify-point', async (req: AuthedRequest, res) => {
  const parsed = verifySchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });
  const isPublic = await overpassSpawner.isPointOnPublicLand(parsed.data);
  return res.json({ isPublic });
});
