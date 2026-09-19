import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { generateUserTag } from '../utils/arrestCode';
import { signToken } from '../middleware/auth';
import { passwordField, usernameField, zodErrorMessage } from '../utils/validation';
import { rejectionMessage, screenUsername } from '../services/UsernameFilter';
import { cleanText, parseLoginIdentity, printable } from '../utils/loginIdentity';

export const authRouter = Router();

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
    // exists: it's the 4 digits shown after the # on their profile.
    return res.status(401).json({
      error: 'Wrong username, tag or password. Your tag is the 4 digits after the # in your name (e.g. name#1234).',
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
