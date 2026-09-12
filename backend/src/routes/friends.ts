import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { zodErrorMessage } from '../utils/validation';
// Circular import (server.ts imports this router) — safe because `isUserOnline` is
// only read inside route handlers, which run long after both modules finish loading.
import { isUserOnline } from '../server';
import { pushService } from '../services/PushService';

export const friendsRouter = Router();
friendsRouter.use(requireAuth);

/** Search users by "username#tag" or bare username prefix. */
friendsRouter.get('/search', async (req: AuthedRequest, res) => {
  const q = String(req.query.q ?? '').trim();
  if (q.length < 2) return res.json({ results: [] });

  const userId = req.user!.userId;
  let where;
  if (q.includes('#')) {
    const [username, userTag] = q.split('#');
    where = { username, userTag };
  } else {
    where = { username: { startsWith: q, mode: 'insensitive' as const } };
  }

  // A block should remove the other person from view in both directions — someone you
  // blocked shouldn't turn up when you search, and (just as importantly) you shouldn't
  // turn up when *they* search either.
  const blocks = await prisma.friendship.findMany({
    where: { status: 'BLOCKED', OR: [{ senderId: userId }, { receiverId: userId }] },
    select: { senderId: true, receiverId: true },
  });
  const blockedIds = blocks.map((b) => (b.senderId === userId ? b.receiverId : b.senderId));

  const users = await prisma.user.findMany({
    where: { ...where, id: { not: userId, notIn: blockedIds } },
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

  const [friendship, sender] = await Promise.all([
    prisma.friendship.create({ data: { senderId, receiverId, status: 'PENDING' } }),
    prisma.user.findUnique({ where: { id: senderId }, select: { username: true, userTag: true } }),
  ]);
  if (sender) {
    void pushService.notify(receiverId, {
      title: 'New Friend Request',
      body: `${sender.username}#${sender.userTag} wants to be friends.`,
      data: { type: 'friend_request', friendshipId: friendship.id },
    });
  }
  return res.status(201).json({ friendship });
});

friendsRouter.post('/requests/:id/accept', async (req: AuthedRequest, res) => {
  const friendship = await prisma.friendship.findUnique({
    where: { id: req.params.id },
    include: { receiver: { select: { username: true, userTag: true } } },
  });
  if (!friendship || friendship.receiverId !== req.user!.userId) {
    return res.status(404).json({ error: 'Friend request not found.' });
  }
  const updated = await prisma.friendship.update({
    where: { id: friendship.id },
    data: { status: 'ACCEPTED' },
  });
  void pushService.notify(friendship.senderId, {
    title: 'Friend Request Accepted',
    body: `${friendship.receiver.username}#${friendship.receiver.userTag} accepted your friend request.`,
    data: { type: 'friend_accepted', friendshipId: friendship.id },
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

/**
 * Blocking removes any existing friendship (whichever direction it ran) and replaces it
 * with a BLOCKED row, which GET /friends' ACCEPTED-only query and /search's exclusion
 * above both already respect — the blocked account disappears from the blocker's own
 * view immediately, without needing a separate "hide" step anywhere. App Store guideline
 * 1.2 requires blocking to also notify the developer, which for a project this size means
 * a clearly-tagged server log rather than a dedicated moderation dashboard — grep/alert on
 * "[BLOCK]" in production logs; see also POST /:userId/report just below for the same
 * pattern applied to actual content reports.
 */
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
  const result = existing
    ? await prisma.friendship.update({
        where: { id: existing.id },
        data: { status: 'BLOCKED', senderId, receiverId },
      })
    : await prisma.friendship.create({ data: { senderId, receiverId, status: 'BLOCKED' } });

  console.log(`[BLOCK] user ${senderId} blocked user ${receiverId} at ${new Date().toISOString()}`);
  return res.status(existing ? 200 : 201).json({ friendship: result });
});

friendsRouter.post('/:userId/unblock', async (req: AuthedRequest, res) => {
  const userId = req.user!.userId;
  const otherId = req.params.userId;
  const existing = await prisma.friendship.findFirst({
    where: {
      status: 'BLOCKED',
      OR: [
        { senderId: userId, receiverId: otherId },
        { senderId: otherId, receiverId: userId },
      ],
    },
  });
  if (!existing) return res.status(404).json({ error: 'Not blocked.' });
  await prisma.friendship.delete({ where: { id: existing.id } });
  return res.status(204).send();
});

friendsRouter.get('/blocked', async (req: AuthedRequest, res) => {
  const userId = req.user!.userId;
  const blocks = await prisma.friendship.findMany({
    where: { status: 'BLOCKED', OR: [{ senderId: userId }, { receiverId: userId }] },
    include: { sender: { select: safeUserSelect }, receiver: { select: safeUserSelect } },
  });
  const blocked = blocks.map((b) => (b.senderId === userId ? b.receiver : b.sender));
  return res.json({ blocked });
});

const reportSchema = z.object({ reason: z.string().min(1).max(500) });

/**
 * App Store guideline 1.2 requires apps with user-generated content to let people flag
 * objectionable content/behavior, and — like blocking above — to notify the developer.
 * Persisted (so reports survive past a single log line, and outlive the reported account
 * if it's later deleted — see Report's schema comment) as well as logged, both under the
 * same "[REPORT]"/"[BLOCK]" tags for easy grepping in production.
 */
friendsRouter.post('/:userId/report', async (req: AuthedRequest, res) => {
  const parsed = reportSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });

  const reporterId = req.user!.userId;
  const reportedUserId = req.params.userId;
  if (reporterId === reportedUserId) {
    return res.status(400).json({ error: 'Cannot report yourself.' });
  }

  const report = await prisma.report.create({
    data: { reporterId, reportedUserId, reason: parsed.data.reason },
  });
  console.log(
    `[REPORT] user ${reporterId} reported user ${reportedUserId} — "${parsed.data.reason}" (report ${report.id})`
  );
  return res.status(201).json({ report });
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
    return {
      id: other.id,
      username: other.username,
      userTag: other.userTag,
      avatarUrl: other.avatarUrl,
      isOnline: isUserOnline(other.id),
    };
  });
  return res.json({ friends });
});

const safeUserSelect = { id: true, username: true, userTag: true, avatarUrl: true } as const;

friendsRouter.get('/requests/incoming', async (req: AuthedRequest, res) => {
  const requests = await prisma.friendship.findMany({
    where: { receiverId: req.user!.userId, status: 'PENDING' },
    include: { sender: { select: safeUserSelect } },
  });
  return res.json({
    requests: requests.map((r) => ({ id: r.id, createdAt: r.createdAt, from: r.sender })),
  });
});

friendsRouter.get('/requests/outgoing', async (req: AuthedRequest, res) => {
  const requests = await prisma.friendship.findMany({
    where: { senderId: req.user!.userId, status: 'PENDING' },
    include: { receiver: { select: safeUserSelect } },
  });
  return res.json({
    requests: requests.map((r) => ({ id: r.id, createdAt: r.createdAt, to: r.receiver })),
  });
});
