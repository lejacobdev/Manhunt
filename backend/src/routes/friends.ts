import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { zodErrorMessage } from '../utils/validation';

export const friendsRouter = Router();
friendsRouter.use(requireAuth);

/** Search users by "username#tag" or bare username prefix. */
friendsRouter.get('/search', async (req: AuthedRequest, res) => {
  const q = String(req.query.q ?? '').trim();
  if (q.length < 2) return res.json({ results: [] });

  let where;
  if (q.includes('#')) {
    const [username, userTag] = q.split('#');
    where = { username, userTag };
  } else {
    where = { username: { startsWith: q, mode: 'insensitive' as const } };
  }

  const users = await prisma.user.findMany({
    where: { ...where, id: { not: req.user!.userId } },
    select: { id: true, username: true, userTag: true, avatarUrl: true },
    take: 20,
  });
  return res.json({ results: users });
});

const sendRequestSchema = z.object({ receiverId: z.string().uuid() });

friendsRouter.post('/requests', async (req: AuthedRequest, res) => {
  const parsed = sendRequestSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  const senderId = req.user!.userId;
  const { receiverId } = parsed.data;

  if (senderId === receiverId) {
    return res.status(400).json({ error: 'Cannot friend yourself.' });
  }

  const existing = await prisma.friendship.findFirst({
    where: {
      OR: [
        { senderId, receiverId },
        { senderId: receiverId, receiverId: senderId },
      ],
    },
  });
  if (existing) {
    if (existing.status === 'BLOCKED') {
      return res.status(403).json({ error: 'Cannot send a request to this user.' });
    }
    return res.status(409).json({ error: 'Friendship already exists.', friendship: existing });
  }

  const friendship = await prisma.friendship.create({
    data: { senderId, receiverId, status: 'PENDING' },
  });
  return res.status(201).json({ friendship });
});

friendsRouter.post('/requests/:id/accept', async (req: AuthedRequest, res) => {
  const friendship = await prisma.friendship.findUnique({ where: { id: req.params.id } });
  if (!friendship || friendship.receiverId !== req.user!.userId) {
    return res.status(404).json({ error: 'Friend request not found.' });
  }
  const updated = await prisma.friendship.update({
    where: { id: friendship.id },
    data: { status: 'ACCEPTED' },
  });
  return res.json({ friendship: updated });
});

friendsRouter.post('/requests/:id/decline', async (req: AuthedRequest, res) => {
  const friendship = await prisma.friendship.findUnique({ where: { id: req.params.id } });
  if (!friendship || friendship.receiverId !== req.user!.userId) {
    return res.status(404).json({ error: 'Friend request not found.' });
  }
  await prisma.friendship.delete({ where: { id: friendship.id } });
  return res.status(204).send();
});

friendsRouter.post('/:userId/block', async (req: AuthedRequest, res) => {
  const senderId = req.user!.userId;
  const receiverId = req.params.userId;
  const existing = await prisma.friendship.findFirst({
    where: {
      OR: [
        { senderId, receiverId },
        { senderId: receiverId, receiverId: senderId },
      ],
    },
  });
  if (existing) {
    const updated = await prisma.friendship.update({
      where: { id: existing.id },
      data: { status: 'BLOCKED', senderId, receiverId },
    });
    return res.json({ friendship: updated });
  }
  const created = await prisma.friendship.create({
    data: { senderId, receiverId, status: 'BLOCKED' },
  });
  return res.status(201).json({ friendship: created });
});

friendsRouter.get('/', async (req: AuthedRequest, res) => {
  const userId = req.user!.userId;
  const friendships = await prisma.friendship.findMany({
    where: {
      status: 'ACCEPTED',
      OR: [{ senderId: userId }, { receiverId: userId }],
    },
    include: { sender: true, receiver: true },
  });

  const friends = friendships.map((f) => {
    const other = f.senderId === userId ? f.receiver : f.sender;
    return { id: other.id, username: other.username, userTag: other.userTag, avatarUrl: other.avatarUrl };
  });
  return res.json({ friends });
});

friendsRouter.get('/requests/incoming', async (req: AuthedRequest, res) => {
  const requests = await prisma.friendship.findMany({
    where: { receiverId: req.user!.userId, status: 'PENDING' },
    include: { sender: true },
  });
  return res.json({ requests });
});

friendsRouter.get('/requests/outgoing', async (req: AuthedRequest, res) => {
  const requests = await prisma.friendship.findMany({
    where: { senderId: req.user!.userId, status: 'PENDING' },
    include: { receiver: true },
  });
  return res.json({ requests });
});
