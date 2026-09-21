/**
 * The rules for changing an account's name or tag, in one place because two callers need exactly
 * the same checks with one difference: an admin is not subject to the cooldown.
 *
 * A name here is always the pair `username#userTag` — the tag is what keeps names non-unique-able,
 * so every check is against the pair, never the name alone.
 */

import { prisma } from '../lib/prisma';
import { generateUserTag } from '../utils/arrestCode';
import { rejectionMessage, screenUsername } from './UsernameFilter';
import { usernameProblem } from '../utils/validation';
import { cleanText } from '../utils/loginIdentity';

/**
 * How long an owner waits between their own changes. Friends recognise each other by name here,
 * and "inappropriate username" is a report category, so a name that can churn hourly is a
 * moderation problem: a report filed against a name nobody can find any more is hard to action.
 * Admin renames bypass this entirely (see `byAdmin`) and never consume the person's own window.
 */
export const NAME_CHANGE_COOLDOWN_DAYS = 7;
const COOLDOWN_MS = NAME_CHANGE_COOLDOWN_DAYS * 24 * 60 * 60 * 1000;

export const USER_TAG_LENGTH = 4;

export interface NameChangeRequest {
  userId: string;
  /** Leave undefined to keep the current one. */
  username?: string;
  /** Leave undefined to keep the current one; 'random' picks a free tag. */
  userTag?: string | 'random';
  /** True for the admin panel: skips the cooldown and does not spend the owner's next change. */
  byAdmin?: boolean;
}

export type NameChangeResult =
  | { ok: true; user: { id: string; username: string; userTag: string }; previous: { username: string; userTag: string }; changed: boolean }
  | { ok: false; status: number; error: string };

/** Null when the tag is fine, otherwise the sentence to show. */
export function userTagProblem(value: string): string | null {
  if (value.length === 0) return 'Please enter a tag.';
  if (!/^[0-9]+$/.test(value)) return 'A tag is 4 digits, like 4921.';
  if (value.length !== USER_TAG_LENGTH) {
    return `A tag is exactly ${USER_TAG_LENGTH} digits (yours has ${value.length}).`;
  }
  return null;
}

/** "in 3 days" / "in 4 hours" / "in a few minutes" — a wait worth wording properly. */
export function describeWait(msRemaining: number): string {
  const minutes = Math.ceil(msRemaining / 60_000);
  if (minutes <= 5) return 'in a few minutes';
  if (minutes < 60) return `in ${minutes} minutes`;
  const hours = Math.ceil(minutes / 60);
  if (hours < 24) return `in ${hours} ${hours === 1 ? 'hour' : 'hours'}`;
  const days = Math.ceil(hours / 24);
  return `in ${days} ${days === 1 ? 'day' : 'days'}`;
}

export async function changeAccountName(request: NameChangeRequest): Promise<NameChangeResult> {
  const existing = await prisma.user.findUnique({ where: { id: request.userId } });
  if (!existing) return { ok: false, status: 404, error: 'Account not found.' };

  const previous = { username: existing.username, userTag: existing.userTag };

  const wantsUsername = request.username !== undefined;
  const wantsTag = request.userTag !== undefined;
  if (!wantsUsername && !wantsTag) {
    return { ok: false, status: 400, error: 'Nothing to change — send a new username, a new tag, or both.' };
  }

  let username = existing.username;
  if (wantsUsername) {
    username = cleanText(request.username ?? '');
    const problem = usernameProblem(username);
    if (problem) return { ok: false, status: 400, error: problem };
  }

  let userTag = existing.userTag;
  let randomTag = false;
  if (wantsTag) {
    if (request.userTag === 'random') {
      randomTag = true;
    } else {
      userTag = cleanText(request.userTag ?? '');
      const problem = userTagProblem(userTag);
      if (problem) return { ok: false, status: 400, error: problem };
    }
  }

  // Asking for exactly what you already have is not worth a cooldown or an error.
  if (!randomTag && username === existing.username && userTag === existing.userTag) {
    return { ok: true, user: { id: existing.id, username, userTag }, previous, changed: false };
  }

  // Cooldown checked before the blocklist call so a rate-limited request does no extra work.
  if (!request.byAdmin && existing.nameChangedAt) {
    const elapsed = Date.now() - existing.nameChangedAt.getTime();
    if (elapsed < COOLDOWN_MS) {
      return {
        ok: false,
        status: 429,
        error:
          `You can change your name once every ${NAME_CHANGE_COOLDOWN_DAYS} days. ` +
          `You can change it again ${describeWait(COOLDOWN_MS - elapsed)}.`,
      };
    }
  }

  if (wantsUsername && username !== existing.username) {
    const verdict = await screenUsername(username);
    if (!verdict.allowed) {
      return {
        ok: false,
        status: 400,
        error: request.byAdmin ? `That name matches the blocklist (${verdict.term}).` : rejectionMessage(verdict),
      };
    }
  }

  if (randomTag) {
    let found: string | null = null;
    for (let attempt = 0; attempt < 20; attempt++) {
      const candidate = generateUserTag();
      if (candidate === existing.userTag) continue;
      const clash = await prisma.user.findUnique({ where: { username_userTag: { username, userTag: candidate } } });
      if (!clash) {
        found = candidate;
        break;
      }
    }
    if (!found) {
      return { ok: false, status: 409, error: `Every tag we tried for "${username}" is taken. Try a different name.` };
    }
    userTag = found;
  } else {
    const clash = await prisma.user.findFirst({
      where: { username, userTag, id: { not: existing.id } },
    });
    if (clash) {
      return {
        ok: false,
        status: 409,
        error: `${username}#${userTag} is taken. Try a different tag — or let us pick a free one for you.`,
      };
    }
  }

  const user = await prisma.user.update({
    where: { id: existing.id },
    data: {
      username,
      userTag,
      // An admin rename shouldn't spend the person's own next change.
      ...(request.byAdmin ? {} : { nameChangedAt: new Date() }),
    },
  });

  return {
    ok: true,
    user: { id: user.id, username: user.username, userTag: user.userTag },
    previous,
    changed: true,
  };
}

/** When the owner may next change their name, or null if they may now. */
export function nextNameChangeAt(nameChangedAt: Date | null): Date | null {
  if (!nameChangedAt) return null;
  const next = new Date(nameChangedAt.getTime() + COOLDOWN_MS);
  return next.getTime() > Date.now() ? next : null;
}
