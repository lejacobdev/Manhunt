import { Response, Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { generateUserTag } from '../utils/arrestCode';
import { signToken } from '../middleware/auth';
import { passwordField, usernameField, zodErrorMessage } from '../utils/validation';
import { rejectionMessage, screenUsername } from '../services/UsernameFilter';
import { cleanText, parseLoginIdentity, printable } from '../utils/loginIdentity';
import { IdentityError, verifyAppleIdentityToken } from '../services/AppleIdentity';
import { verifyGameCenterSignature } from '../services/GameCenterIdentity';
import {
  Provider,
  findUserByProvider,
  issueSignupTicket,
  readSignupTicket,
} from '../services/ProviderAccounts';

export const authRouter = Router();

/** The one shape every successful sign-in answers with, so the app has one thing to decode. */
function sessionResponse(user: { id: string; username: string; userTag: string; avatarUrl: string | null }) {
  return {
    token: signToken({ userId: user.id, username: user.username }),
    user: { id: user.id, username: user.username, userTag: user.userTag, avatarUrl: user.avatarUrl },
  };
}

function bannedMessage(user: { banReason: string | null }) {
  return user.banReason ? `This account has been suspended: ${user.banReason}` : 'This account has been suspended.';
}

// The rules and their wording live in utils/validation.ts — the message a player sees when a
// username is rejected is the whole point, so it says which characters were the problem.
const registerSchema = z.object({
  username: usernameField(),
  password: passwordField(),
});

authRouter.post('/register', async (req, res) => {
  const parsed = registerSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  }
  const { username, password } = parsed.data;

  // Screened before the account exists, so a blocked name never gets a tag, a token, or a
  // row someone later has to clean up.
  const verdict = await screenUsername(username);
  if (!verdict.allowed) {
    return res.status(400).json({ error: rejectionMessage(verdict) });
  }

  let userTag = generateUserTag();
  let attempts = 0;
  while (attempts < 10) {
    const clash = await prisma.user.findUnique({ where: { username_userTag: { username, userTag } } });
    if (!clash) break;
    userTag = generateUserTag();
    attempts++;
  }

  const passwordHash = await bcrypt.hash(password, 12);
  const user = await prisma.user.create({
    data: { username, userTag, passwordHash },
  });

  const token = signToken({ userId: user.id, username: user.username });
  return res.status(201).json({
    token,
    user: { id: user.id, username: user.username, userTag: user.userTag, avatarUrl: user.avatarUrl },
  });
});

const loginSchema = z.object({
  username: z.string({ required_error: 'Please enter your username.' }),
  // Optional: the tag can be written into the username ("name#1234") or left out when the
  // name is unambiguous — see loginIdentity.ts. Requiring it here would answer those with a
  // bare "userTag: Required" before the smarter lookup ever ran.
  userTag: z.string().optional().default(''),
  password: z.string({ required_error: 'Please enter your password.' }),
});

authRouter.post('/login', async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  }
  const { username: rawUsername, userTag: rawTag, password } = parsed.data;

  // Forgiving about formatting, strict about credentials — see loginIdentity.ts for why.
  const identity = parseLoginIdentity(rawUsername, rawTag);
  const { username, userTag } = identity;
  const ua = req.get('user-agent') ?? '-';

  // A blank field is a "you forgot something", not a "your credentials are wrong".
  if (!username) return res.status(400).json({ error: 'Please enter your username.' });
  if (password.length === 0) return res.status(400).json({ error: 'Please enter your password.' });

  // Exact (name, tag) first so a correct login behaves exactly as it always has. Then the same
  // pair ignoring case. Only when no tag was given anywhere do we look up by name alone, and
  // then only up to a handful of accounts — a tag that WAS given but matches nothing is never
  // quietly widened into a name-only search.
  let candidates: Awaited<ReturnType<typeof prisma.user.findMany>> = [];
  if (username) {
    if (userTag) {
      const exact = await prisma.user.findUnique({ where: { username_userTag: { username, userTag } } });
      candidates = exact
        ? [exact]
        : await prisma.user.findMany({
            where: { username: { equals: username, mode: 'insensitive' }, userTag },
            take: 5,
          });
    } else {
      candidates = await prisma.user.findMany({
        where: { username: { equals: username, mode: 'insensitive' } },
        orderBy: { createdAt: 'asc' },
        take: 5,
      });
    }
  }

  // The password as typed, then with pasted-in whitespace/zero-width characters stripped —
  // tried second so a password that legitimately ends in a space still works as before.
  const cleanedPassword = cleanText(password);
  const passwordVariants = [password, ...(cleanedPassword && cleanedPassword !== password ? [cleanedPassword] : [])];

  let user: (typeof candidates)[number] | null = null;
  let usedCleanedPassword = false;
  for (const candidate of candidates) {
    // An account created with Apple or Game Center has no password at all. Skipped rather than
    // compared: bcrypt.compare against null throws, and anything that treated "no hash" as a
    // match would be a hole you could sign in through with any password at all.
    if (!candidate.passwordHash) continue;
    for (const attempt of passwordVariants) {
      if (await bcrypt.compare(attempt, candidate.passwordHash)) {
        user = candidate;
        usedCleanedPassword = attempt !== password;
        break;
      }
    }
    if (user) break;
  }

  if (!user) {
    // Deliberately loud, and deliberately never the password itself (only its length): this is
    // how "the demo login doesn't work for App Review" becomes something diagnosable instead
    // of a bare 401 nobody can see into.
    console.log(
      `[AUTH] login FAILED reason=${candidates.length ? 'BAD_PASSWORD' : 'NO_SUCH_USER'} ` +
        `username=${printable(rawUsername)} tag=${printable(rawTag)} pwLen=${password.length} ua=${ua}`,
    );
    // Says what to check without saying *which* part was wrong — that would let anyone probe
    // for valid usernames. The tag hint is there because it's the part people don't know
    // exists: it's the 4 digits shown after the # on their profile. The provider hint is
    // deliberately unconditional for the same reason: saying "this account uses Apple" only
    // when it does would answer the question "does this account exist" for anyone asking.
    return res.status(401).json({
      error:
        'Wrong username, tag or password. Your tag is the 4 digits after the # in your name (e.g. name#1234). ' +
        'If you created your account with Apple or Game Center, use those buttons instead.',
    });
  }

  if (rawUsername !== user.username || rawTag !== user.userTag || usedCleanedPassword) {
    console.log(
      `[AUTH] login ok after normalising username=${printable(rawUsername)} tag=${printable(rawTag)} ` +
        `-> ${user.username}#${user.userTag}${usedCleanedPassword ? ' (password trimmed)' : ''} ua=${ua}`,
    );
  }

  // Checked after the password, not before: answering differently for a banned account
  // before credentials are proven would let anyone probe which accounts are banned.
  if (user.isBanned) {
    return res.status(403).json({
      error: user.banReason
        ? `This account has been suspended: ${user.banReason}`
        : 'This account has been suspended.',
    });
  }

  const token = signToken({ userId: user.id, username: user.username });
  return res.json({
    token,
    user: { id: user.id, username: user.username, userTag: user.userTag, avatarUrl: user.avatarUrl },
  });
});

// ---------------------------------------------------------------------------------------
// Sign in with Apple / Game Center
//
// Both providers land in the same place: verify the identity, then either hand back a session for
// the account that already claims it, or a short-lived ticket so the person can choose a username
// and finish signing up. Neither route ever trusts an identifier the app merely asserts — see
// AppleIdentity.ts and GameCenterIdentity.ts.
// ---------------------------------------------------------------------------------------

/** Shared tail of both provider sign-in routes. */
async function signInWithProvider(res: Response, provider: Provider, subject: string) {
  const existing = await findUserByProvider(provider, subject);
  if (!existing) {
    // No account yet. Rather than inventing a username, ask for one: the ticket proves the
    // identity was verified just now, so the second step needs no re-verification.
    return res.status(200).json({
      needsUsername: true,
      ticket: issueSignupTicket(provider, subject),
      provider,
    });
  }
  if (existing.isBanned) return res.status(403).json({ error: bannedMessage(existing) });
  console.log(`[AUTH] ${provider} sign-in ok user=${existing.username}#${existing.userTag}`);
  return res.json(sessionResponse(existing));
}

const appleSchema = z.object({
  identityToken: z.string({ required_error: 'Apple did not return a sign-in token.' }).min(1),
  /** SHA-256 hex of the raw nonce the app generated, when it used one. */
  nonce: z.string().optional(),
});

authRouter.post('/apple', async (req, res) => {
  const parsed = appleSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  try {
    const identity = await verifyAppleIdentityToken(parsed.data.identityToken, parsed.data.nonce);
    return await signInWithProvider(res, 'apple', identity.subject);
  } catch (error) {
    if (error instanceof IdentityError) {
      console.log(`[AUTH] apple sign-in REJECTED reason=${error.message}`);
      return res.status(401).json({ error: error.message });
    }
    throw error;
  }
});

const gameCenterSchema = z.object({
  playerId: z.string({ required_error: 'Game Center did not return a player identifier.' }).min(1),
  publicKeyUrl: z.string({ required_error: 'Game Center did not return a key location.' }).min(1),
  signature: z.string({ required_error: 'Game Center did not return a signature.' }).min(1),
  salt: z.string({ required_error: 'Game Center did not return a salt.' }).min(1),
  timestamp: z.number({ required_error: 'Game Center did not return a timestamp.' }),
});

authRouter.post('/gamecenter', async (req, res) => {
  const parsed = gameCenterSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });
  try {
    const identity = await verifyGameCenterSignature(parsed.data);
    return await signInWithProvider(res, 'gamecenter', identity.playerId);
  } catch (error) {
    if (error instanceof IdentityError) {
      console.log(`[AUTH] gamecenter sign-in REJECTED reason=${error.message}`);
      return res.status(401).json({ error: error.message });
    }
    throw error;
  }
});

const completeSchema = z.object({
  ticket: z.string({ required_error: 'That sign-up could not be continued. Please start again.' }).min(1),
  username: usernameField(),
});

/**
 * Second half of a provider sign-up: the person has chosen a username, and the ticket carries the
 * identity we verified minutes ago. The username goes through exactly the same rules and blocklist
 * as /register — a provider sign-up is not a way around either.
 */
authRouter.post('/provider/complete', async (req, res) => {
  const parsed = completeSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: zodErrorMessage(parsed.error) });

  const claims = readSignupTicket(parsed.data.ticket);
  if (!claims) {
    return res.status(401).json({ error: 'That sign-up took too long. Please tap the sign-in button again.' });
  }
  const { provider, subject } = claims;
  const { username } = parsed.data;

  const verdict = await screenUsername(username);
  if (!verdict.allowed) return res.status(400).json({ error: rejectionMessage(verdict) });

  // Between issuing the ticket and now, the identity may have been claimed (two devices, one
  // person, both tapping the button). Signing them in is the friendly answer.
  const claimed = await findUserByProvider(provider, subject);
  if (claimed) {
    if (claimed.isBanned) return res.status(403).json({ error: bannedMessage(claimed) });
    return res.json(sessionResponse(claimed));
  }

  let userTag = generateUserTag();
  for (let attempts = 0; attempts < 10; attempts++) {
    const clash = await prisma.user.findUnique({ where: { username_userTag: { username, userTag } } });
    if (!clash) break;
    userTag = generateUserTag();
  }

  try {
    const user = await prisma.user.create({
      data: {
        username,
        userTag,
        // No password: this account signs in with its provider until the owner sets one.
        [provider === 'apple' ? 'appleUserId' : 'gameCenterPlayerId']: subject,
      },
    });
    console.log(`[AUTH] ${provider} sign-up created user=${user.username}#${user.userTag}`);
    return res.status(201).json(sessionResponse(user));
  } catch (error) {
    // Unique violation on the provider column: the race above, lost between check and insert.
    const claimedNow = await findUserByProvider(provider, subject);
    if (claimedNow) {
      if (claimedNow.isBanned) return res.status(403).json({ error: bannedMessage(claimedNow) });
      return res.json(sessionResponse(claimedNow));
    }
    if ((error as { code?: string }).code === 'P2002') {
      return res.status(409).json({
        error: `${username}#${userTag} was taken a moment ago. Please try that name again.`,
      });
    }
    throw error;
  }
});
