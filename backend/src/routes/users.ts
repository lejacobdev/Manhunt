import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { zodErrorMessage } from '../utils/validation';
// Circular import (server.ts imports this router) — safe because `isUserOnline` is only
// read inside route handlers, which run long after both modules finish loading.
import { isUserOnline } from '../server';

export const usersRouter = Router();
usersRouter.use(requireAuth);

interface ProfileStats {
  matchesPlayed: number;
  wins: number;
  matchesAsHunter: number;
  matchesAsRunner: number;
  catchesMade: number;
  timesCaught: number;
  extractions: number;
  timesEliminated: number;
  matchesHosted: number;
  powerUpsCollected: number;
  gamblesWon: number;
  gamblesLost: number;
  /** Whole minutes across every match that actually started and ended. */
  minutesPlayed: number;
}

interface Achievement {
  id: string;
  title: string;
  description: string;
  /** SF Symbol name — the client renders it directly. */
  icon: string;
  goal: number;
  progress: number;
  unlocked: boolean;
}

/**
 * Every achievement is derived from the same counters as the stat block rather than
 * stored per-user: unlocking is a pure function of match history, so there's no separate
 * state to migrate, backfill, or drift out of sync with the games actually played.
 */
function buildAchievements(stats: ProfileStats): Achievement[] {
  const defs: Array<Omit<Achievement, 'progress' | 'unlocked'> & { value: number }> = [
    { id: 'first_catch', title: 'First Blood', description: 'Catch your first runner.', icon: 'hand.raised.fill', goal: 1, value: stats.catchesMade },
    { id: 'catches_10', title: 'Bounty Hunter', description: 'Catch 10 runners.', icon: 'figure.run.circle.fill', goal: 10, value: stats.catchesMade },
    { id: 'catches_50', title: 'Manhunter', description: 'Catch 50 runners.', icon: 'target', goal: 50, value: stats.catchesMade },
    { id: 'first_escape', title: 'Slipped Away', description: 'Reach the extraction point once.', icon: 'flag.checkered', goal: 1, value: stats.extractions },
    { id: 'escapes_10', title: 'Ghost', description: 'Extract safely 10 times.', icon: 'eye.slash.fill', goal: 10, value: stats.extractions },
    { id: 'wins_1', title: 'On the Board', description: 'Win your first match.', icon: 'rosette', goal: 1, value: stats.wins },
    { id: 'wins_10', title: 'Champion', description: 'Win 10 matches.', icon: 'trophy.fill', goal: 10, value: stats.wins },
    { id: 'matches_10', title: 'Regular', description: 'Play 10 matches.', icon: 'gamecontroller.fill', goal: 10, value: stats.matchesPlayed },
    { id: 'matches_50', title: 'Veteran', description: 'Play 50 matches.', icon: 'shield.lefthalf.filled', goal: 50, value: stats.matchesPlayed },
    { id: 'host_5', title: 'Ringleader', description: 'Host 5 matches.', icon: 'star.fill', goal: 5, value: stats.matchesHosted },
    { id: 'powerups_20', title: 'Scavenger', description: 'Collect 20 power-ups.', icon: 'shippingbox.fill', goal: 20, value: stats.powerUpsCollected },
    { id: 'gambler_3', title: 'High Roller', description: 'Win 3 coin flips.', icon: 'circle.grid.2x2.fill', goal: 3, value: stats.gamblesWon },
    { id: 'marathon_120', title: 'Long Hunt', description: 'Play for 2 hours total.', icon: 'clock.fill', goal: 120, value: stats.minutesPlayed },
  ];

  return defs.map(({ value, ...def }) => ({
    ...def,
    progress: Math.min(value, def.goal),
    unlocked: value >= def.goal,
  }));
}

async function computeProfile(userId: string) {
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { id: true, username: true, userTag: true, avatarUrl: true, createdAt: true },
  });
  if (!user) return null;

  // Every match this account was ever a member of, with the full player list so hunter
  // wins can be judged the same way the live match does (all runners caught or out).
  const myPlayers = await prisma.gamePlayer.findMany({
    where: { userId },
    include: { session: { include: { players: true } } },
  });
  const myPlayerIds = myPlayers.map((p) => p.id);
  const endedPlayers = myPlayers.filter((p) => p.session.status === 'ENDED');

  let wins = 0;
  let minutesPlayed = 0;
  for (const me of endedPlayers) {
    const { session } = me;
    if (session.startedAt && session.endedAt) {
      const elapsed = Math.max(0, Math.round((session.endedAt.getTime() - session.startedAt.getTime()) / 60_000));
      // Clamped to the match's own configured length: a session that was abandoned and
      // only force-ended hours later still only *ran* for its timer, and without this a
      // couple of forgotten lobbies dominate the lifetime playtime figure entirely.
      const configured = (session.settings as { durationMinutes?: number } | null)?.durationMinutes;
      minutesPlayed += configured && configured > 0 ? Math.min(elapsed, configured) : elapsed;
    }
    if (me.role === 'RUNNER') {
      // Mirrors the match's own win conditions: surviving to the final whistle or
      // extracting both count, being caught or eliminated doesn't.
      if (me.isExtracted || (!me.isCaught && !me.isOut)) wins += 1;
    } else if (me.role === 'HUNTER') {
      const runners = session.players.filter((p) => p.role === 'RUNNER');
      if (runners.length > 0 && runners.every((r) => (r.isCaught || r.isOut) && !r.isExtracted)) wins += 1;
    }
  }

  const sessionIds = Array.from(new Set(myPlayers.map((p) => p.sessionId)));
  const [events, powerUpsCollected, matchesHosted] = await Promise.all([
    sessionIds.length
      ? prisma.gameEvent.findMany({ where: { sessionId: { in: sessionIds }, type: { in: ['CATCH', 'GAMBLE'] } } })
      : Promise.resolve([]),
    myPlayerIds.length
      ? prisma.powerUpSpawn.count({ where: { collectedBy: { in: myPlayerIds } } })
      : Promise.resolve(0),
    prisma.gameSession.count({ where: { hostId: userId } }),
  ]);

  const mine = new Set(myPlayerIds);
  let catchesMade = 0;
  let gamblesWon = 0;
  let gamblesLost = 0;
  for (const event of events) {
    const payload = (event.payload ?? {}) as Record<string, unknown>;
    if (event.type === 'CATCH') {
      if (typeof payload.hunterPlayerId === 'string' && mine.has(payload.hunterPlayerId)) catchesMade += 1;
      continue;
    }
    // GAMBLE: the loser is named by heartsLostBy, so "won" means the duel resolved
    // against the other side — a hunter losing a flip heals back, but it still counts
    // as the runner having won that toss.
    const iAmHunter = typeof payload.hunterPlayerId === 'string' && mine.has(payload.hunterPlayerId);
    const iAmRunner = typeof payload.runnerPlayerId === 'string' && mine.has(payload.runnerPlayerId);
    if (!iAmHunter && !iAmRunner) continue;
    const loser = payload.heartsLostBy;
    if (loser === 'HUNTER') iAmHunter ? (gamblesLost += 1) : (gamblesWon += 1);
    else if (loser === 'RUNNER') iAmRunner ? (gamblesLost += 1) : (gamblesWon += 1);
  }

  const stats: ProfileStats = {
    matchesPlayed: endedPlayers.length,
    wins,
    matchesAsHunter: myPlayers.filter((p) => p.role === 'HUNTER').length,
    matchesAsRunner: myPlayers.filter((p) => p.role === 'RUNNER').length,
    catchesMade,
    timesCaught: myPlayers.filter((p) => p.isCaught).length,
    extractions: myPlayers.filter((p) => p.isExtracted).length,
    timesEliminated: myPlayers.filter((p) => p.isOut).length,
    matchesHosted,
    powerUpsCollected,
    gamblesWon,
    gamblesLost,
    minutesPlayed,
  };

  return {
    user: {
      id: user.id,
      username: user.username,
      userTag: user.userTag,
      avatarUrl: user.avatarUrl,
      createdAt: user.createdAt,
      isOnline: isUserOnline(user.id),
    },
    stats,
    achievements: buildAchievements(stats),
  };
}

type LeaderboardSort = 'wins' | 'catches' | 'extractions' | 'matches' | 'playtime';
const LEADERBOARD_SORTS: LeaderboardSort[] = ['wins', 'catches', 'extractions', 'matches', 'playtime'];

interface LeaderboardRow {
  user: { id: string; username: string; userTag: string; avatarUrl: string | null };
  matchesPlayed: number;
  wins: number;
  winRatePercent: number;
  catchesMade: number;
  extractions: number;
  minutesPlayed: number;
}

/**
 * Ranks every player with at least one finished match. Unlike `computeProfile` (one query
 * per profile view, fine at that scale), this computes every user's totals in a single pass
 * over the same underlying rows — fetching once and aggregating in memory beats issuing one
 * query per user, and the win-condition logic (mirrors the match's own: a runner surviving
 * or extracting, a hunter resolving every runner) doesn't translate cleanly into a single
 * SQL aggregate anyway.
 */
async function computeLeaderboard(sort: LeaderboardSort) {
  const endedPlayers = await prisma.gamePlayer.findMany({
    where: { session: { status: 'ENDED' } },
    include: {
      session: { include: { players: true } },
      user: { select: { id: true, username: true, userTag: true, avatarUrl: true } },
    },
  });

  interface Accum {
    user: LeaderboardRow['user'];
    matchesPlayed: number;
    wins: number;
    catchesMade: number;
    extractions: number;
    minutesPlayed: number;
  }
  const byUser = new Map<string, Accum>();
  const playerIdToUserId = new Map<string, string>();

  for (const p of endedPlayers) {
    playerIdToUserId.set(p.id, p.userId);
    const acc = byUser.get(p.userId) ?? { user: p.user, matchesPlayed: 0, wins: 0, catchesMade: 0, extractions: 0, minutesPlayed: 0 };
    acc.matchesPlayed += 1;
    if (p.isExtracted) acc.extractions += 1;
    if (p.role === 'RUNNER') {
      if (p.isExtracted || (!p.isCaught && !p.isOut)) acc.wins += 1;
    } else if (p.role === 'HUNTER') {
      const runners = p.session.players.filter((x) => x.role === 'RUNNER');
      if (runners.length > 0 && runners.every((r) => (r.isCaught || r.isOut) && !r.isExtracted)) acc.wins += 1;
    }
    if (p.session.startedAt && p.session.endedAt) {
      const elapsed = Math.max(0, Math.round((p.session.endedAt.getTime() - p.session.startedAt.getTime()) / 60_000));
      // Same clamp as computeProfile — a session force-ended hours after being abandoned
      // still only *ran* for its configured length.
      const configured = (p.session.settings as { durationMinutes?: number } | null)?.durationMinutes;
      acc.minutesPlayed += configured && configured > 0 ? Math.min(elapsed, configured) : elapsed;
    }
    byUser.set(p.userId, acc);
  }

  const sessionIds = Array.from(new Set(endedPlayers.map((p) => p.sessionId)));
  if (sessionIds.length > 0) {
    const catchEvents = await prisma.gameEvent.findMany({
      where: { sessionId: { in: sessionIds }, type: 'CATCH' },
      select: { payload: true },
    });
    for (const event of catchEvents) {
      const payload = (event.payload ?? {}) as Record<string, unknown>;
      const hunterPlayerId = typeof payload.hunterPlayerId === 'string' ? payload.hunterPlayerId : undefined;
      const userId = hunterPlayerId ? playerIdToUserId.get(hunterPlayerId) : undefined;
      const acc = userId ? byUser.get(userId) : undefined;
      if (acc) acc.catchesMade += 1;
    }
  }

  const rows: LeaderboardRow[] = Array.from(byUser.values()).map((acc) => ({
    user: acc.user,
    matchesPlayed: acc.matchesPlayed,
    wins: acc.wins,
    winRatePercent: acc.matchesPlayed > 0 ? Math.round((acc.wins / acc.matchesPlayed) * 100) : 0,
    catchesMade: acc.catchesMade,
    extractions: acc.extractions,
    minutesPlayed: acc.minutesPlayed,
  }));

  const key: keyof Pick<LeaderboardRow, 'wins' | 'catchesMade' | 'extractions' | 'matchesPlayed' | 'minutesPlayed'> =
    sort === 'catches' ? 'catchesMade'
      : sort === 'extractions' ? 'extractions'
      : sort === 'matches' ? 'matchesPlayed'
      : sort === 'playtime' ? 'minutesPlayed'
      : 'wins';
  // Ties break on matches played (more games at the same total is the "weaker" showing),
  // then alphabetically — arbitrary but stable, so a re-fetch doesn't reorder ties randomly.
  rows.sort((a, b) => b[key] - a[key] || b.matchesPlayed - a.matchesPlayed || a.user.username.localeCompare(b.user.username));

  return rows;
}

usersRouter.get('/leaderboard', async (req: AuthedRequest, res) => {
  const sortParam = typeof req.query.sort === 'string' ? req.query.sort : 'wins';
  const sort = (LEADERBOARD_SORTS as string[]).includes(sortParam) ? (sortParam as LeaderboardSort) : 'wins';

  const rows = await computeLeaderboard(sort);
  const entries = rows.slice(0, 100).map((row, index) => ({ rank: index + 1, ...row }));

  // The caller's own standing even when it falls outside the top 100 — otherwise finishing
  // 145th just means never appearing anywhere on the screen at all.
  const myIndex = rows.findIndex((row) => row.user.id === req.user!.userId);
  const me = myIndex >= 0 ? { rank: myIndex + 1, ...rows[myIndex] } : null;

  return res.json({ sort, entries, me });
});

usersRouter.get('/me/profile', async (req: AuthedRequest, res) => {
  const profile = await computeProfile(req.user!.userId);
  if (!profile) return res.status(404).json({ error: 'User not found.' });
  return res.json(profile);
});

/** Anyone signed in can read anyone's profile — stats are the game's public scoreboard,
 *  and the QR add-friend flow shows a preview before you commit to sending a request. */
usersRouter.get('/:id/profile', async (req: AuthedRequest, res) => {
  const profile = await computeProfile(req.params.id);
  if (!profile) return res.status(404).json({ error: 'User not found.' });
  return res.json(profile);
});

const byTagSchema = z.object({
  username: z.string().min(1).max(40),
  userTag: z.string().min(1).max(10),
});

/**
 * Resolves a "username#tag" pair to an account — what a scanned friend QR carries, since
 * the tag is already the app's stable public handle and needs no extra column to mint.
 */
usersRouter.get('/by-tag', async (req: AuthedRequest, res) => {
  const parsed = byTagSchema.safeParse({ username: req.query.username, userTag: req.query.userTag });
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  const user = await prisma.user.findUnique({
    where: { username_userTag: { username: parsed.data.username, userTag: parsed.data.userTag } },
    select: { id: true, username: true, userTag: true, avatarUrl: true },
  });
  if (!user) return res.status(404).json({ error: 'No player with that tag.' });
  return res.json({ user: { ...user, isOnline: isUserOnline(user.id) } });
});
