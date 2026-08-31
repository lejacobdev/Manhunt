import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { zodErrorMessage } from '../utils/validation';
// Circular import (server.ts imports this router) — safe because `io`/`isUserOnline`
// are only read inside route handlers, which run long after both modules finish loading.
import { io, isUserOnline } from '../server';

export const invitesRouter = Router();
invitesRouter.use(requireAuth);

const createInviteSchema = z.object({
  sessionCode: z.string().min(1),
  toUserId: z.string().uuid(),
});

/** Invite an accepted friend into a lobby you're already a member of. */
invitesRouter.post('/', async (req: AuthedRequest, res) => {
  const parsed = createInviteSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  const fromUserId = req.user!.userId;
  const { sessionCode, toUserId } = parsed.data;

  if (fromUserId === toUserId) {
    return res.status(400).json({ error: 'Cannot invite yourself.' });
  }

  const session = await prisma.gameSession.findUnique({ where: { code: sessionCode } });
  if (!session) return res.status(404).json({ error: 'Game not found.' });
  if (session.status !== 'LOBBY') {
    return res.status(409).json({ error: 'This game has already started or ended.' });
  }

  const membership = await prisma.gamePlayer.findUnique({
    where: { sessionId_userId: { sessionId: session.id, userId: fromUserId } },
  });
  if (!membership) {
    return res.status(403).json({ error: 'You must be in this lobby to invite others to it.' });
  }

  const friendship = await prisma.friendship.findFirst({
    where: {
      status: 'ACCEPTED',
      OR: [
        { senderId: fromUserId, receiverId: toUserId },
        { senderId: toUserId, receiverId: fromUserId },
      ],
    },
  });
  if (!friendship) {
    return res.status(403).json({ error: 'You can only invite accepted friends.' });
  }

  const invite = await prisma.gameInvite.upsert({
    where: { sessionId_toUserId: { sessionId: session.id, toUserId } },
    create: { sessionId: session.id, fromUserId, toUserId, status: 'PENDING' },
    update: { status: 'PENDING', fromUserId, respondedAt: null },
    include: { fromUser: true },
  });

  // Best-effort live push — if the friend isn't connected right now, the durable
  // row is still there for GET /invites/incoming the next time they open the app.
  if (isUserOnline(toUserId)) {
    io.to(`user:${toUserId}`).emit('game_invite', {
      id: invite.id,
      sessionCode: session.code,
      mode: session.mode,
      fromUserId,
      fromUsername: invite.fromUser.username,
      createdAt: invite.createdAt,
    });
  }

  return res.status(201).json({ invite });
});

invitesRouter.get('/incoming', async (req: AuthedRequest, res) => {
  const invites = await prisma.gameInvite.findMany({
    where: { toUserId: req.user!.userId, status: 'PENDING' },
    include: { fromUser: true, session: true },
    orderBy: { createdAt: 'desc' },
  });
  const active = invites.filter((i) => i.session.status === 'LOBBY');
  return res.json({
    invites: active.map((i) => ({
      id: i.id,
      sessionCode: i.session.code,
      mode: i.session.mode,
      fromUserId: i.fromUserId,
      fromUsername: i.fromUser.username,
      createdAt: i.createdAt,
    })),
  });
});

invitesRouter.post('/:id/accept', async (req: AuthedRequest, res) => {
  const invite = await prisma.gameInvite.findUnique({ where: { id: req.params.id }, include: { session: true } });
  if (!invite || invite.toUserId !== req.user!.userId) {
    return res.status(404).json({ error: 'Invite not found.' });
  }
  if (invite.session.status !== 'LOBBY') {
    return res.status(409).json({ error: 'This game has already started or ended.' });
  }
  await prisma.gameInvite.update({ where: { id: invite.id }, data: { status: 'ACCEPTED', respondedAt: new Date() } });
  return res.json({ session: invite.session });
});

invitesRouter.post('/:id/decline', async (req: AuthedRequest, res) => {
  const invite = await prisma.gameInvite.findUnique({ where: { id: req.params.id } });
  if (!invite || invite.toUserId !== req.user!.userId) {
    return res.status(404).json({ error: 'Invite not found.' });
  }
  await prisma.gameInvite.update({ where: { id: invite.id }, data: { status: 'DECLINED', respondedAt: new Date() } });
  return res.status(204).send();
});
