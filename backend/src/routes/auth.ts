import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { generateUserTag } from '../utils/arrestCode';
import { signToken } from '../middleware/auth';

export const authRouter = Router();

const registerSchema = z.object({
  username: z.string().min(3).max(20).regex(/^[a-zA-Z0-9_]+$/),
  password: z.string().min(8).max(128),
});

authRouter.post('/register', async (req, res) => {
  const parsed = registerSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.flatten() });
  }
  const { username, password } = parsed.data;

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
  username: z.string(),
  userTag: z.string(),
  password: z.string(),
});

authRouter.post('/login', async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.flatten() });
  }
  const { username, userTag, password } = parsed.data;

  const user = await prisma.user.findUnique({ where: { username_userTag: { username, userTag } } });
  if (!user) return res.status(401).json({ error: 'Invalid credentials.' });

  const valid = await bcrypt.compare(password, user.passwordHash);
  if (!valid) return res.status(401).json({ error: 'Invalid credentials.' });

  const token = signToken({ userId: user.id, username: user.username });
  return res.json({
    token,
    user: { id: user.id, username: user.username, userTag: user.userTag, avatarUrl: user.avatarUrl },
  });
});
