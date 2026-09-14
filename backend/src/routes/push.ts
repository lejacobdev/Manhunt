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
  if (!parsed.success) {
    console.log(`[PUSH] register REJECTED for ${req.user!.username}: ${zodErrorMessage(parsed.error)}`);
    return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  }
  console.log(`[PUSH] register ok for ${req.user!.username} (${parsed.data.token.length} chars)`);
  await pushService.registerToken(req.user!.userId, parsed.data.token);
  return res.json({ ok: true });
});

const diagnosticSchema = z.object({
  stage: z.string().max(40),
  detail: z.string().max(500).optional(),
});

/**
 * The device reporting how far it got registering for push. APNs registration failing
 * on-device is otherwise completely invisible from the server — the app simply never calls
 * /register, which looks identical to it never having tried. Apple's own error text names
 * the problem outright ("no valid aps-environment entitlement string found"), so it's worth
 * a round trip to see it rather than inferring from absence.
 */
pushRouter.post('/diagnostic', async (req: AuthedRequest, res) => {
  const parsed = diagnosticSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  console.log(
    `[PUSH-DIAG] ${req.user!.username}: ${parsed.data.stage}` +
      (parsed.data.detail ? ` — ${parsed.data.detail}` : '')
  );
  return res.status(204).send();
});

/** Called on sign-out so a shared/reset device stops receiving this account's pushes. */
pushRouter.post('/unregister', async (req: AuthedRequest, res) => {
  const parsed = tokenSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  await pushService.unregisterToken(parsed.data.token);
  return res.json({ ok: true });
});
