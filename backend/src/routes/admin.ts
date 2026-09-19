import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { requireAdmin } from '../middleware/admin';
import { usernameField, zodErrorMessage } from '../utils/validation';
// Circular import (server.ts imports this router) — safe because these are only read
// inside handlers, which run long after both modules finish loading.
import { io, isUserOnline } from '../server';
import { pushService } from '../services/PushService';
import {
  invalidateUsernameFilterCache,
  scanExistingUsernames,
  screenUsername,
} from '../services/UsernameFilter';

export const adminRouter = Router();
adminRouter.use(requireAuth, requireAdmin);

const safeUser = {
  id: true,
  username: true,
  userTag: true,
  avatarUrl: true,
  isAdmin: true,
  isBanned: true,
  bannedAt: true,
  banReason: true,
  createdAt: true,
} as const;

/** Writes the audit trail. Every mutating handler below calls this — see AdminAction. */
async function audit(
  req: AuthedRequest,
  action: string,
  targetType: string,
  targetId: string,
  detail?: string
) {
  await prisma.adminAction.create({
    data: {
      adminId: req.user!.userId,
      adminName: req.user!.username,
      action,
      targetType,
      targetId,
      detail: detail ?? null,
    },
  });
}

// ---------------------------------------------------------------- session / identity

/** Lets the panel confirm the stored token still belongs to an admin before rendering. */
adminRouter.get('/me', async (req: AuthedRequest, res) => {
  const user = await prisma.user.findUnique({ where: { id: req.user!.userId }, select: safeUser });
  return res.json({ user });
});

// ---------------------------------------------------------------- dashboard

adminRouter.get('/stats', async (_req, res) => {
  const dayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);
  const weekAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);

  const [
    users,
    newUsersDay,
    newUsersWeek,
    banned,
    openReports,
    reportsWeek,
    liveSessions,
    lobbySessions,
    sessionsWeek,
    blocks,
  ] = await Promise.all([
    prisma.user.count(),
    prisma.user.count({ where: { createdAt: { gte: dayAgo } } }),
    prisma.user.count({ where: { createdAt: { gte: weekAgo } } }),
    prisma.user.count({ where: { isBanned: true } }),
    prisma.report.count({ where: { status: 'OPEN' } }),
    prisma.report.count({ where: { createdAt: { gte: weekAgo } } }),
    prisma.gameSession.count({ where: { status: 'ACTIVE' } }),
    prisma.gameSession.count({ where: { status: 'LOBBY' } }),
    prisma.gameSession.count({ where: { createdAt: { gte: weekAgo } } }),
    prisma.friendship.count({ where: { status: 'BLOCKED' } }),
  ]);

  // Online count comes from the live socket registry rather than the database — there is
  // no "last seen" column, and presence is exactly the kind of thing that should be read
  // from the thing that actually knows.
  const allUsers = await prisma.user.findMany({ select: { id: true } });
  const online = allUsers.filter((u) => isUserOnline(u.id)).length;

  return res.json({
    users,
    newUsersDay,
    newUsersWeek,
    banned,
    online,
    openReports,
    reportsWeek,
    liveSessions,
    lobbySessions,
    sessionsWeek,
    blocks,
  });
});

/** Daily signups, matches and reports for the last 30 days, for the dashboard charts. */
adminRouter.get('/analytics', async (_req, res) => {
  const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  const [users, sessions, reports] = await Promise.all([
    prisma.user.findMany({ where: { createdAt: { gte: since } }, select: { createdAt: true } }),
    prisma.gameSession.findMany({ where: { createdAt: { gte: since } }, select: { createdAt: true, mode: true } }),
    prisma.report.findMany({ where: { createdAt: { gte: since } }, select: { createdAt: true, category: true } }),
  ]);

  const bucket = (rows: { createdAt: Date }[]) => {
    const out: Record<string, number> = {};
    for (let i = 29; i >= 0; i--) {
      const d = new Date(Date.now() - i * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
      out[d] = 0;
    }
    for (const row of rows) {
      const key = row.createdAt.toISOString().slice(0, 10);
      if (key in out) out[key] += 1;
    }
    return out;
  };

  const tally = <T extends string>(rows: { [k: string]: unknown }[], field: string) => {
    const out: Record<string, number> = {};
    for (const row of rows) {
      const key = String(row[field]);
      out[key] = (out[key] ?? 0) + 1;
    }
    return out;
  };

  return res.json({
    signups: bucket(users),
    matches: bucket(sessions),
    reports: bucket(reports),
    modeSplit: tally(sessions, 'mode'),
    categorySplit: tally(reports, 'category'),
  });
});

// ---------------------------------------------------------------- reports

adminRouter.get('/reports', async (req, res) => {
  const status = typeof req.query.status === 'string' ? req.query.status : undefined;
  const category = typeof req.query.category === 'string' ? req.query.category : undefined;

  const reports = await prisma.report.findMany({
    where: {
      ...(status && status !== 'ALL' ? { status: status as 'OPEN' | 'RESOLVED' | 'DISMISSED' } : {}),
      ...(category && category !== 'ALL' ? { category: category as never } : {}),
    },
    orderBy: { createdAt: 'desc' },
    take: 200,
  });

  // Report has no relation to User on purpose (so a report outlives the account it was
  // filed against), which means names are resolved here instead of joined.
  const ids = [...new Set(reports.flatMap((r) => [r.reporterId, r.reportedUserId]))];
  const users = await prisma.user.findMany({ where: { id: { in: ids } }, select: safeUser });
  const byId = new Map(users.map((u) => [u.id, u]));

  // How many reports each reported account has attracted overall — one complaint is noise,
  // five is a pattern, and that distinction is the whole job here.
  const counts = await prisma.report.groupBy({
    by: ['reportedUserId'],
    where: { reportedUserId: { in: reports.map((r) => r.reportedUserId) } },
    _count: true,
  });
  const countById = new Map(counts.map((c) => [c.reportedUserId, c._count]));

  return res.json({
    reports: reports.map((r) => ({
      ...r,
      reporter: byId.get(r.reporterId) ?? null,
      reported: byId.get(r.reportedUserId) ?? null,
      totalAgainstReported: countById.get(r.reportedUserId) ?? 0,
    })),
  });
});

const respondSchema = z.object({ message: z.string().min(1).max(1000) });

/** Replies to whoever filed the report. Delivered as a push and kept on the row. */
adminRouter.post('/reports/:id/respond', async (req: AuthedRequest, res) => {
  const parsed = respondSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });

  const report = await prisma.report.findUnique({ where: { id: req.params.id } });
  if (!report) return res.status(404).json({ error: 'Report not found.' });

  const updated = await prisma.report.update({
    where: { id: report.id },
    data: {
      adminResponse: parsed.data.message,
      respondedAt: new Date(),
      handledBy: req.user!.userId,
      status: report.status === 'OPEN' ? 'RESOLVED' : report.status,
    },
  });

  void pushService.notify(report.reporterId, {
    title: 'About your report',
    body: parsed.data.message,
    data: { type: 'report_response', reportId: report.id },
  });
  io.to(`user:${report.reporterId}`).emit('report_response', {
    reportId: report.id,
    message: parsed.data.message,
  });

  await audit(req, 'RESPOND_REPORT', 'REPORT', report.id, parsed.data.message.slice(0, 200));
  return res.json({ report: updated });
});

const statusSchema = z.object({ status: z.enum(['OPEN', 'RESOLVED', 'DISMISSED']) });

adminRouter.post('/reports/:id/status', async (req: AuthedRequest, res) => {
  const parsed = statusSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  const report = await prisma.report.update({
    where: { id: req.params.id },
    data: { status: parsed.data.status, handledBy: req.user!.userId },
  });
  await audit(req, `REPORT_${parsed.data.status}`, 'REPORT', report.id);
  return res.json({ report });
});

// ---------------------------------------------------------------- users

adminRouter.get('/users', async (req, res) => {
  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  const banned = req.query.banned === 'true';

  const users = await prisma.user.findMany({
    where: {
      ...(banned ? { isBanned: true } : {}),
      ...(q
        ? q.includes('#')
          ? { username: q.split('#')[0], userTag: q.split('#')[1] }
          : { username: { contains: q, mode: 'insensitive' as const } }
        : {}),
    },
    select: safeUser,
    orderBy: { createdAt: 'desc' },
    take: 100,
  });

  const ids = users.map((u) => u.id);
  const [reportCounts, matchCounts] = await Promise.all([
    prisma.report.groupBy({ by: ['reportedUserId'], where: { reportedUserId: { in: ids } }, _count: true }),
    prisma.gamePlayer.groupBy({ by: ['userId'], where: { userId: { in: ids } }, _count: true }),
  ]);
  const reportsById = new Map(reportCounts.map((r) => [r.reportedUserId, r._count]));
  const matchesById = new Map(matchCounts.map((m) => [m.userId, m._count]));

  return res.json({
    users: users.map((u) => ({
      ...u,
      isOnline: isUserOnline(u.id),
      reportsAgainst: reportsById.get(u.id) ?? 0,
      matchesPlayed: matchesById.get(u.id) ?? 0,
    })),
  });
});

adminRouter.get('/users/:id', async (req, res) => {
  const user = await prisma.user.findUnique({ where: { id: req.params.id }, select: safeUser });
  if (!user) return res.status(404).json({ error: 'User not found.' });

  const [friendships, reportsAgainst, reportsFiled, players, devices, actions] = await Promise.all([
    prisma.friendship.findMany({
      where: { OR: [{ senderId: user.id }, { receiverId: user.id }] },
      include: { sender: { select: safeUser }, receiver: { select: safeUser } },
    }),
    prisma.report.findMany({ where: { reportedUserId: user.id }, orderBy: { createdAt: 'desc' } }),
    prisma.report.findMany({ where: { reporterId: user.id }, orderBy: { createdAt: 'desc' } }),
    prisma.gamePlayer.findMany({
      where: { userId: user.id },
      include: { session: true },
      orderBy: { joinedAt: 'desc' },
      take: 25,
    }),
    prisma.deviceToken.count({ where: { userId: user.id } }),
    prisma.adminAction.findMany({ where: { targetId: user.id }, orderBy: { createdAt: 'desc' }, take: 25 }),
  ]);

  return res.json({
    user: { ...user, isOnline: isUserOnline(user.id) },
    friends: friendships
      .filter((f) => f.status === 'ACCEPTED')
      .map((f) => (f.senderId === user.id ? f.receiver : f.sender)),
    blocked: friendships
      .filter((f) => f.status === 'BLOCKED')
      .map((f) => ({ user: f.senderId === user.id ? f.receiver : f.sender, blockedByThisUser: f.senderId === user.id })),
    reportsAgainst,
    reportsFiled,
    matches: players.map((p) => ({
      sessionId: p.sessionId,
      code: p.session.code,
      mode: p.session.mode,
      status: p.session.status,
      role: p.role,
      isCaught: p.isCaught,
      isOut: p.isOut,
      hearts: p.hearts,
      joinedAt: p.joinedAt,
    })),
    deviceTokens: devices,
    adminHistory: actions,
  });
});

const banSchema = z.object({ reason: z.string().max(500).optional() });

adminRouter.post('/users/:id/ban', async (req: AuthedRequest, res) => {
  const parsed = banSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  if (req.params.id === req.user!.userId) {
    return res.status(400).json({ error: 'You cannot ban yourself.' });
  }
  const user = await prisma.user.update({
    where: { id: req.params.id },
    data: { isBanned: true, bannedAt: new Date(), banReason: parsed.data.reason ?? null },
    select: safeUser,
  });
  // Cut them off mid-session rather than waiting for their next sign-in.
  io.to(`user:${user.id}`).emit('account_banned', { reason: user.banReason });
  await audit(req, 'BAN', 'USER', user.id, parsed.data.reason);
  return res.json({ user });
});

adminRouter.post('/users/:id/unban', async (req: AuthedRequest, res) => {
  const user = await prisma.user.update({
    where: { id: req.params.id },
    data: { isBanned: false, bannedAt: null, banReason: null },
    select: safeUser,
  });
  await audit(req, 'UNBAN', 'USER', user.id);
  return res.json({ user });
});

const renameSchema = z.object({ username: usernameField() });

/**
 * Renames an account. This exists because "inappropriate username" is one of the report
 * categories, and banning someone over a name they can't change themselves is a blunt
 * answer to a fixable problem.
 */
adminRouter.post('/users/:id/rename', async (req: AuthedRequest, res) => {
  const parsed = renameSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  const existing = await prisma.user.findUnique({ where: { id: req.params.id } });
  if (!existing) return res.status(404).json({ error: 'User not found.' });

  const clash = await prisma.user.findFirst({
    where: { username: parsed.data.username, userTag: existing.userTag, id: { not: existing.id } },
  });
  if (clash) return res.status(409).json({ error: 'That username and tag combination is taken.' });

  // Renaming someone *onto* a blocked name would be an odd own goal for a tool whose main
  // use is renaming people off one.
  const verdict = await screenUsername(parsed.data.username);
  if (!verdict.allowed) {
    return res.status(400).json({ error: `That name matches the blocklist (${verdict.term}).` });
  }

  const user = await prisma.user.update({
    where: { id: existing.id },
    data: { username: parsed.data.username },
    select: safeUser,
  });
  void pushService.notify(user.id, {
    title: 'Your username was changed',
    body: `A moderator changed your username to ${user.username}#${user.userTag}.`,
    data: { type: 'username_changed' },
  });
  await audit(req, 'RENAME', 'USER', user.id, `${existing.username} -> ${user.username}`);
  return res.json({ user });
});

const adminFlagSchema = z.object({ isAdmin: z.boolean() });

adminRouter.post('/users/:id/admin', async (req: AuthedRequest, res) => {
  const parsed = adminFlagSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  if (req.params.id === req.user!.userId && !parsed.data.isAdmin) {
    return res.status(400).json({ error: 'You cannot remove your own admin access.' });
  }
  const user = await prisma.user.update({
    where: { id: req.params.id },
    data: { isAdmin: parsed.data.isAdmin },
    select: safeUser,
  });
  await audit(req, parsed.data.isAdmin ? 'GRANT_ADMIN' : 'REVOKE_ADMIN', 'USER', user.id);
  return res.json({ user });
});

const messageSchema = z.object({ title: z.string().min(1).max(60), body: z.string().min(1).max(300) });

adminRouter.post('/users/:id/message', async (req: AuthedRequest, res) => {
  const parsed = messageSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  void pushService.notify(req.params.id, {
    title: parsed.data.title,
    body: parsed.data.body,
    data: { type: 'admin_message' },
  });
  await audit(req, 'MESSAGE', 'USER', req.params.id, parsed.data.body.slice(0, 200));
  return res.status(204).send();
});

adminRouter.delete('/users/:id', async (req: AuthedRequest, res) => {
  if (req.params.id === req.user!.userId) {
    return res.status(400).json({ error: 'Use the app to delete your own account.' });
  }
  const user = await prisma.user.findUnique({ where: { id: req.params.id } });
  if (!user) return res.status(404).json({ error: 'User not found.' });

  // Same teardown order as the user's own deletion route — rows that reference the account
  // go first, then the account. Reports are deliberately left standing (see the Report
  // model): the moderation history of a deleted account is still worth having.
  await prisma.$transaction([
    prisma.deviceToken.deleteMany({ where: { userId: user.id } }),
    prisma.friendship.deleteMany({ where: { OR: [{ senderId: user.id }, { receiverId: user.id }] } }),
    prisma.gameInvite.deleteMany({ where: { OR: [{ fromUserId: user.id }, { toUserId: user.id }] } }),
    prisma.gamePlayer.deleteMany({ where: { userId: user.id } }),
    prisma.user.delete({ where: { id: user.id } }),
  ]);
  await audit(req, 'DELETE_USER', 'USER', user.id, `${user.username}#${user.userTag}`);
  return res.status(204).send();
});

// ---------------------------------------------------------------- sessions

adminRouter.get('/sessions', async (req, res) => {
  const status = typeof req.query.status === 'string' ? req.query.status : undefined;
  const sessions = await prisma.gameSession.findMany({
    where: status && status !== 'ALL' ? { status: status as never } : {},
    include: { players: { include: { user: { select: safeUser } } } },
    orderBy: { createdAt: 'desc' },
    take: 100,
  });
  return res.json({
    sessions: sessions.map((s) => ({
      id: s.id,
      code: s.code,
      mode: s.mode,
      status: s.status,
      hostId: s.hostId,
      startedAt: s.startedAt,
      endedAt: s.endedAt,
      createdAt: s.createdAt,
      playerCount: s.players.length,
      players: s.players.map((p) => ({
        id: p.id,
        role: p.role,
        hearts: p.hearts,
        isCaught: p.isCaught,
        isJailed: p.isJailed,
        isOut: p.isOut,
        user: p.user,
      })),
    })),
  });
});

adminRouter.get('/sessions/:id/events', async (req, res) => {
  const events = await prisma.gameEvent.findMany({
    where: { sessionId: req.params.id },
    orderBy: { timestamp: 'desc' },
    take: 200,
  });
  return res.json({ events });
});

adminRouter.post('/sessions/:id/end', async (req: AuthedRequest, res) => {
  const session = await prisma.gameSession.findUnique({ where: { id: req.params.id } });
  if (!session) return res.status(404).json({ error: 'Session not found.' });
  await prisma.gameSession.update({
    where: { id: session.id },
    data: { status: 'ENDED', endedAt: new Date() },
  });
  io.to(session.code).emit('game_over', { reason: 'ENDED_BY_ADMIN' });
  await audit(req, 'END_SESSION', 'SESSION', session.id, session.code);
  return res.status(204).send();
});

// ---------------------------------------------------------------- broadcast

const broadcastSchema = z.object({
  title: z.string().min(1).max(60),
  body: z.string().min(1).max(300),
  onlineOnly: z.boolean().optional(),
});

adminRouter.post('/broadcast', async (req: AuthedRequest, res) => {
  const parsed = broadcastSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });

  const users = await prisma.user.findMany({ where: { isBanned: false }, select: { id: true } });
  const targets = parsed.data.onlineOnly ? users.filter((u) => isUserOnline(u.id)) : users;
  for (const user of targets) {
    void pushService.notify(user.id, {
      title: parsed.data.title,
      body: parsed.data.body,
      data: { type: 'announcement' },
    });
  }
  await audit(req, 'BROADCAST', 'ALL', 'all', `${targets.length} recipients: ${parsed.data.body.slice(0, 150)}`);
  return res.json({ sent: targets.length });
});

// ---------------------------------------------------------------- username filter

/** Every account whose username matches the filter as it stands right now. */
adminRouter.get('/usernames/flagged', async (_req, res) => {
  return res.json({ flagged: await scanExistingUsernames() });
});

adminRouter.get('/usernames/terms', async (_req, res) => {
  const terms = await prisma.blockedTerm.findMany({ orderBy: { createdAt: 'desc' } });
  return res.json({ terms });
});

const termSchema = z.object({
  term: z.string().min(2).max(60),
  category: z.string().max(30).optional(),
  isAllowlist: z.boolean().optional(),
});

adminRouter.post('/usernames/terms', async (req: AuthedRequest, res) => {
  const parsed = termSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  const term = await prisma.blockedTerm.upsert({
    where: { term: parsed.data.term.toLowerCase() },
    create: {
      term: parsed.data.term.toLowerCase(),
      category: parsed.data.category ?? (parsed.data.isAllowlist ? 'ALLOWED' : 'CUSTOM'),
      isAllowlist: parsed.data.isAllowlist ?? false,
      createdBy: req.user!.userId,
    },
    update: { isAllowlist: parsed.data.isAllowlist ?? false },
  });
  invalidateUsernameFilterCache();
  await audit(req, parsed.data.isAllowlist ? 'ALLOW_TERM' : 'BLOCK_TERM', 'TERM', term.id, term.term);
  return res.status(201).json({ term });
});

adminRouter.delete('/usernames/terms/:id', async (req: AuthedRequest, res) => {
  const term = await prisma.blockedTerm.delete({ where: { id: req.params.id } });
  invalidateUsernameFilterCache();
  await audit(req, 'REMOVE_TERM', 'TERM', term.id, term.term);
  return res.status(204).send();
});

/** Quick way to see what the filter makes of a name without creating an account. */
adminRouter.get('/usernames/test', async (req, res) => {
  const name = typeof req.query.name === 'string' ? req.query.name : '';
  return res.json({ name, verdict: await screenUsername(name) });
});

// ---------------------------------------------------------------- audit trail

adminRouter.get('/audit', async (_req, res) => {
  const actions = await prisma.adminAction.findMany({ orderBy: { createdAt: 'desc' }, take: 200 });
  return res.json({ actions });
});
