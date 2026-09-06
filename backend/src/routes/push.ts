import { Router } from 'express';
import { z } from 'zod';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { zodErrorMessage } from '../utils/validation';
import { pushService } from '../services/PushService';

export const pushRouter = Router();
pushRouter.use(requireAuth);

const tokenSchema = z.object({ token: z.string().min(10).max(512) });

/** Called once permission is granted and APNs hands back a device token, and again on
 *  every launch — cheap to repeat (an upsert), and covers the token rotating. */
pushRouter.post('/register', async (req: AuthedRequest, res) => {
  const parsed = tokenSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  await pushService.registerToken(req.user!.userId, parsed.data.token);
  return res.json({ ok: true });
});

/** Called on sign-out so a shared/reset device stops receiving this account's pushes. */
pushRouter.post('/unregister', async (req: AuthedRequest, res) => {
  const parsed = tokenSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  await pushService.unregisterToken(parsed.data.token);
  return res.json({ ok: true });
});
