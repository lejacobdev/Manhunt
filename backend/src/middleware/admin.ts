import { NextFunction, Response } from 'express';
import { prisma } from '../lib/prisma';
import { AuthedRequest } from './auth';

/**
 * Gate for every /admin route. Runs *after* requireAuth and re-reads the account from the
 * database rather than trusting an `isAdmin` claim baked into the token: tokens here last a
 * month, so a claim inside one would keep working for weeks after the privilege was
 * revoked. One extra query on a handful of low-traffic admin calls is a fair price for
 * revocation that actually takes effect.
 */
export async function requireAdmin(req: AuthedRequest, res: Response, next: NextFunction) {
  const userId = req.user?.userId;
  if (!userId) return res.status(401).json({ error: 'Not signed in.' });

  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { isAdmin: true, isBanned: true },
  });
  // Deliberately the same 404-shaped answer for "not an admin" as for "no such route" —
  // a signed-in non-admin probing for the panel learns nothing about whether it exists.
  if (!user?.isAdmin || user.isBanned) {
    return res.status(404).json({ error: 'Not found.' });
  }
  next();
}
