/**
 * Ties a verified Apple or Game Center identity to one of our accounts.
 *
 * Everything here takes a subject that has ALREADY been verified by AppleIdentity or
 * GameCenterIdentity. Nothing in this file decides whether an identity is genuine; it only decides
 * which account it belongs to, so the verification can never be accidentally skipped by adding a
 * new caller.
 *
 * Signing in with a provider that no account claims does not silently invent an account with a
 * machine-made name: it hands back a short-lived ticket, the app asks the person what they want to
 * be called, and the account is created in a second step. That keeps the username rules (and the
 * blocklist) applying to provider sign-ups exactly as they do to registration.
 */

import crypto from 'node:crypto';
import jwt from 'jsonwebtoken';
import { prisma } from '../lib/prisma';

export type Provider = 'apple' | 'gamecenter';

export const PROVIDERS: Provider[] = ['apple', 'gamecenter'];

export function isProvider(value: string): value is Provider {
  return (PROVIDERS as string[]).includes(value);
}

/** What a person calls it, for messages they read. */
export const PROVIDER_LABEL: Record<Provider, string> = {
  apple: 'Apple',
  gamecenter: 'Game Center',
};

/** Which User column stores each provider's subject. */
const PROVIDER_COLUMN: Record<Provider, 'appleUserId' | 'gameCenterPlayerId'> = {
  apple: 'appleUserId',
  gamecenter: 'gameCenterPlayerId',
};

export function providerColumn(provider: Provider): 'appleUserId' | 'gameCenterPlayerId' {
  return PROVIDER_COLUMN[provider];
}

export async function findUserByProvider(provider: Provider, subject: string) {
  return prisma.user.findFirst({ where: { [PROVIDER_COLUMN[provider]]: subject } });
}

// ---------------------------------------------------------------------------------------
// The "now choose a username" ticket
// ---------------------------------------------------------------------------------------

const TICKET_TTL_SECONDS = 15 * 60;

/**
 * Deliberately NOT JWT_SECRET itself. A ticket names no user, so if it verified as an ordinary
 * auth token, presenting one as a Bearer token would put a request through requireAuth with an
 * undefined userId. Signing it with a separate derived key means it simply is not a valid session
 * token, whatever it is sent as.
 */
function ticketSecret(): string {
  const base = process.env.JWT_SECRET ?? 'dev-secret-do-not-use-in-production';
  return crypto.createHmac('sha256', base).update('provider-signup-ticket/v1').digest('hex');
}

interface TicketClaims {
  provider: Provider;
  subject: string;
}

export function issueSignupTicket(provider: Provider, subject: string): string {
  return jwt.sign({ provider, subject } satisfies TicketClaims, ticketSecret(), {
    expiresIn: TICKET_TTL_SECONDS,
  });
}

export function readSignupTicket(ticket: string): TicketClaims | null {
  try {
    const decoded = jwt.verify(ticket, ticketSecret()) as TicketClaims;
    if (!decoded || !decoded.subject || !isProvider(decoded.provider)) return null;
    return { provider: decoded.provider, subject: decoded.subject };
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------------------
// Linking
// ---------------------------------------------------------------------------------------

export interface LinkOutcome {
  ok: boolean;
  /** HTTP status to answer with when `ok` is false. */
  status?: number;
  error?: string;
}

/**
 * Attaches a verified identity to an existing account.
 *
 * Refuses when another account already holds it rather than moving it across: silently
 * re-pointing someone else's Apple sign-in at this account would be an account takeover with
 * extra steps. Re-linking the identity the account already has is a no-op success, so a double
 * tap is harmless.
 */
export async function linkProviderToUser(
  userId: string,
  provider: Provider,
  subject: string,
): Promise<LinkOutcome> {
  const column = PROVIDER_COLUMN[provider];
  const label = PROVIDER_LABEL[provider];

  const holder = await prisma.user.findFirst({ where: { [column]: subject } });
  if (holder) {
    if (holder.id === userId) return { ok: true };
    return {
      ok: false,
      status: 409,
      error: `That ${label} account is already linked to ${holder.username}#${holder.userTag}. Sign in as that account, or unlink it there first.`,
    };
  }

  const existing = await prisma.user.findUnique({ where: { id: userId } });
  if (!existing) return { ok: false, status: 404, error: 'Account not found.' };
  const current = existing[column];
  if (current && current !== subject) {
    return {
      ok: false,
      status: 409,
      error: `This account is already linked to a different ${label} account. Unlink that one first.`,
    };
  }

  await prisma.user.update({ where: { id: userId }, data: { [column]: subject } });
  return { ok: true };
}

/**
 * Detaches an identity, unless doing so would lock the person out. An account created with Apple
 * has no password, so unlinking its only sign-in method would leave nothing at all to sign in
 * with — and since we do not collect email addresses, there is no recovery path to fall back on.
 */
export async function unlinkProviderFromUser(userId: string, provider: Provider): Promise<LinkOutcome> {
  const user = await prisma.user.findUnique({ where: { id: userId } });
  if (!user) return { ok: false, status: 404, error: 'Account not found.' };

  const column = PROVIDER_COLUMN[provider];
  if (!user[column]) return { ok: false, status: 400, error: `This account is not linked to ${PROVIDER_LABEL[provider]}.` };

  const remaining = PROVIDERS.filter((p) => p !== provider).filter((p) => Boolean(user[PROVIDER_COLUMN[p]]));
  if (!user.passwordHash && remaining.length === 0) {
    return {
      ok: false,
      status: 400,
      error:
        `${PROVIDER_LABEL[provider]} is the only way to sign in to this account. ` +
        'Set a password first, then you can unlink it.',
    };
  }

  await prisma.user.update({ where: { id: userId }, data: { [column]: null } });
  return { ok: true };
}

export interface Connections {
  apple: boolean;
  gamecenter: boolean;
  hasPassword: boolean;
}

export function describeConnections(user: {
  appleUserId: string | null;
  gameCenterPlayerId: string | null;
  passwordHash: string | null;
}): Connections {
  return {
    apple: Boolean(user.appleUserId),
    gamecenter: Boolean(user.gameCenterPlayerId),
    hasPassword: Boolean(user.passwordHash),
  };
}
