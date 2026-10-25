import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { AuthedRequest, requireAuth } from '../middleware/auth';
import { zodErrorMessage } from '../utils/validation';
import { computeProfile } from './users';
import { CATEGORIES, COSMETICS, DEFAULTS, PRODUCTS, byId } from '../cosmetics/catalog';
import { AppStoreVerificationError, verifyAppStoreJws } from '../cosmetics/appStoreVerify';

/**
 * Cosmetics: the catalog with what this player owns and how close they are to the items they
 * unlock by playing, equipping, and App Store purchases. Nothing here touches gameplay.
 */
export const cosmeticsRouter = Router();

const BUNDLE_ID = process.env.APNS_BUNDLE_ID || 'com.huntinggame.app';

/** Grants every play-unlock this player has earned, and returns their stats for progress bars. */
async function grantPlayUnlocks(userId: string) {
  const [profile, playersRecruited] = await Promise.all([computeProfile(userId), countPlayersRecruited(userId)]);
  const stats: Record<string, number> = { ...((profile?.stats ?? {}) as unknown as Record<string, number>), playersRecruited };
  const earned = COSMETICS.filter((c) => c.unlock.kind === 'play' && (stats[c.unlock.stat] ?? 0) >= c.unlock.goal);
  if (earned.length) {
    await prisma.userCosmetic.createMany({
      data: earned.map((c) => ({ userId, itemId: c.id, source: 'PLAY' })),
      skipDuplicates: true,
    });
  }
  return stats;
}

/**
 * How many people played their very first finished match in a game this player hosted — the
 * Recruiter badge. Counted from match history rather than from invite links, which can't survive
 * an App Store install.
 */
async function countPlayersRecruited(userId: string): Promise<number> {
  const rows = await prisma.$queryRaw<{ n: bigint }[]>`
    SELECT COUNT(DISTINCT p."userId") AS n
    FROM "GamePlayer" p
    JOIN "GameSession" s ON s.id = p."sessionId"
    WHERE s."hostId" = ${userId} AND s.status = 'ENDED' AND s."startedAt" IS NOT NULL AND p."userId" <> ${userId}
      AND s."startedAt" = (
        SELECT MIN(s2."startedAt") FROM "GamePlayer" p2 JOIN "GameSession" s2 ON s2.id = p2."sessionId"
        WHERE p2."userId" = p."userId" AND s2.status = 'ENDED' AND s2."startedAt" IS NOT NULL
      )`;
  return Number(rows[0]?.n ?? 0);
}

async function ownedIds(userId: string): Promise<Set<string>> {
  const rows = await prisma.userCosmetic.findMany({ where: { userId }, select: { itemId: true } });
  const owned = new Set(rows.map((r) => r.itemId));
  for (const c of COSMETICS) if (c.unlock.kind === 'free') owned.add(c.id);
  return owned;
}

async function equippedFor(userId: string, owned: Set<string>) {
  const user = await prisma.user.findUnique({ where: { id: userId }, select: { equippedCosmetics: true } });
  const stored = (user?.equippedCosmetics ?? {}) as Record<string, string>;
  const out: Record<string, string> = {};
  // Anything no longer owned (a refunded pack) falls back to the default.
  for (const cat of CATEGORIES) out[cat] = stored[cat] && owned.has(stored[cat]) ? stored[cat] : DEFAULTS[cat];
  return out;
}

async function snapshot(userId: string) {
  const stats = await grantPlayUnlocks(userId);
  const owned = await ownedIds(userId);
  const purchased = await prisma.purchase.findMany({ where: { userId, revokedAt: null }, select: { productId: true } });
  return {
    items: COSMETICS.map((c) => ({
      id: c.id,
      category: c.category,
      name: c.name,
      description: c.description,
      unlock: c.unlock.kind,
      productId: c.unlock.kind === 'pack' ? c.unlock.productId : c.unlock.kind === 'supporter' ? PRODUCTS.find((p) => p.productId.endsWith('.supporter'))!.productId : null,
      requirement: c.unlock.kind === 'play' ? c.unlock.label : null,
      progress: c.unlock.kind === 'play' ? Math.min(stats[c.unlock.stat] ?? 0, c.unlock.goal) : null,
      goal: c.unlock.kind === 'play' ? c.unlock.goal : null,
      owned: owned.has(c.id),
    })),
    products: PRODUCTS.map((p) => ({ ...p, owned: purchased.some((x) => x.productId === p.productId) })),
    equipped: await equippedFor(userId, owned),
  };
}

cosmeticsRouter.get('/', requireAuth, async (req: AuthedRequest, res) => {
  return res.json(await snapshot(req.user!.userId));
});

const equipSchema = z.object({ category: z.enum(['mapStyle', 'radarSkin', 'marker', 'banner', 'badge']), itemId: z.string() });

cosmeticsRouter.post('/equip', requireAuth, async (req: AuthedRequest, res) => {
  const parsed = equipSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  const item = byId.get(parsed.data.itemId);
  if (!item || item.category !== parsed.data.category) return res.status(400).json({ error: "That item doesn't go there." });
  const userId = req.user!.userId;
  const owned = await ownedIds(userId);
  if (!owned.has(item.id)) return res.status(403).json({ error: `You haven't unlocked ${item.name} yet.` });
  const user = await prisma.user.findUnique({ where: { id: userId }, select: { equippedCosmetics: true } });
  const equipped = { ...((user?.equippedCosmetics ?? {}) as Record<string, string>), [item.category]: item.id };
  await prisma.user.update({ where: { id: userId }, data: { equippedCosmetics: equipped } });
  return res.json(await snapshot(userId));
});

interface SignedTransaction {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  purchaseDate: number;
  revocationDate?: number;
  environment: string;
  appAccountToken?: string;
}

/** Records one verified transaction for this user and grants (or, if revoked, removes) its items. */
async function applyTransaction(userId: string, tx: SignedTransaction) {
  const product = PRODUCTS.find((p) => p.productId === tx.productId);
  if (!product) throw new AppStoreVerificationError('That product is not sold in this app.');
  if (tx.bundleId !== BUNDLE_ID) throw new AppStoreVerificationError('That purchase belongs to a different app.');
  // The app tags every purchase with the buyer's account id (StoreKit appAccountToken).
  if (tx.appAccountToken && tx.appAccountToken.toLowerCase() !== userId.toLowerCase()) {
    throw new AppStoreVerificationError('That purchase was made from another Hunting Game account.');
  }

  // A transaction can only ever belong to the account that first presented it.
  const existing = await prisma.purchase.findFirst({ where: { originalTransactionId: tx.originalTransactionId } });
  if (existing && existing.userId !== userId) {
    throw new AppStoreVerificationError('That purchase is already linked to another Hunting Game account.');
  }

  await prisma.purchase.upsert({
    where: { transactionId: tx.transactionId },
    create: {
      userId,
      productId: tx.productId,
      transactionId: tx.transactionId,
      originalTransactionId: tx.originalTransactionId,
      environment: tx.environment,
      purchasedAt: new Date(tx.purchaseDate),
      revokedAt: tx.revocationDate ? new Date(tx.revocationDate) : null,
    },
    update: { revokedAt: tx.revocationDate ? new Date(tx.revocationDate) : null },
  });

  if (tx.revocationDate) {
    await revokeProductItems(userId, product.productId);
  } else {
    await prisma.userCosmetic.createMany({
      data: product.items.map((itemId) => ({ userId, itemId, source: product.productId.endsWith('.supporter') ? 'SUPPORTER' : 'PURCHASE' })),
      skipDuplicates: true,
    });
  }
}

/** Takes back what a refunded product granted — except items another active purchase still covers. */
async function revokeProductItems(userId: string, productId: string) {
  const active = await prisma.purchase.findMany({ where: { userId, revokedAt: null }, select: { productId: true } });
  const stillCovered = new Set(active.flatMap((p) => PRODUCTS.find((x) => x.productId === p.productId)?.items ?? []));
  const items = PRODUCTS.find((p) => p.productId === productId)?.items ?? [];
  await prisma.userCosmetic.deleteMany({
    where: { userId, itemId: { in: items.filter((i) => !stillCovered.has(i)) }, source: { in: ['PURCHASE', 'SUPPORTER'] } },
  });
}

const purchaseSchema = z.object({ transactions: z.array(z.string().min(20)).min(1).max(50) });

/**
 * The app sends the StoreKit 2 signed transactions (jwsRepresentation) for a new purchase, a
 * restore, or Transaction.updates. Each is verified against Apple's certificate chain before
 * anything is granted; a client can't fake one.
 */
cosmeticsRouter.post('/purchases', requireAuth, async (req: AuthedRequest, res) => {
  const parsed = purchaseSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  const userId = req.user!.userId;
  const problems: string[] = [];
  for (const jws of parsed.data.transactions) {
    try {
      await applyTransaction(userId, verifyAppStoreJws<SignedTransaction>(jws));
    } catch (err) {
      problems.push(err instanceof AppStoreVerificationError ? err.message : 'That purchase could not be checked.');
      if (!(err instanceof AppStoreVerificationError)) console.error('[cosmetics] purchase failed', err);
    }
  }
  if (problems.length === parsed.data.transactions.length) return res.status(400).json({ error: problems[0] });
  return res.json(await snapshot(userId));
});

/**
 * App Store Server Notifications V2. Apple calls this for refunds and revocations so items are
 * taken back even if the player never opens the app again. Configured in App Store Connect →
 * App Information → App Store Server Notifications: https://api.lejacob.dev/cosmetics/app-store-notifications
 */
cosmeticsRouter.post('/app-store-notifications', async (req, res) => {
  try {
    const signedPayload = typeof req.body?.signedPayload === 'string' ? req.body.signedPayload : '';
    const notification = verifyAppStoreJws<{ notificationType: string; data?: { signedTransactionInfo?: string; bundleId?: string } }>(signedPayload);
    const signedTx = notification.data?.signedTransactionInfo;
    if (signedTx && ['REFUND', 'REVOKE'].includes(notification.notificationType)) {
      const tx = verifyAppStoreJws<SignedTransaction>(signedTx);
      const purchase = await prisma.purchase.findFirst({ where: { originalTransactionId: tx.originalTransactionId } });
      if (purchase) {
        await applyTransaction(purchase.userId, { ...tx, revocationDate: tx.revocationDate ?? Date.now() });
        console.log(`[cosmetics] ${notification.notificationType} for ${tx.productId} (user ${purchase.userId})`);
      }
    }
    return res.status(200).json({ ok: true });
  } catch (err) {
    console.warn('[cosmetics] rejected an App Store notification:', (err as Error).message);
    return res.status(400).json({ error: 'Invalid notification.' });
  }
});
