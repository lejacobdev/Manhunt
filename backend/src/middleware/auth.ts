import { NextFunction, Request, Response } from 'express';
import jwt from 'jsonwebtoken';
import { AuthTokenPayload } from '../types';

export interface AuthedRequest extends Request {
  user?: AuthTokenPayload;
}

const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-secret-do-not-use-in-production';

export function requireAuth(req: AuthedRequest, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing bearer token.' });
  }
  const token = header.slice('Bearer '.length);
  try {
    const decoded = jwt.verify(token, JWT_SECRET) as AuthTokenPayload;
    req.user = decoded;
    next();
  } catch {
    return res.status(401).json({ error: 'Invalid or expired token.' });
  }
}

export function signToken(payload: AuthTokenPayload): string {
  const expiresIn = process.env.JWT_EXPIRES_IN ?? '30d';
  return jwt.sign(payload, JWT_SECRET, { expiresIn } as jwt.SignOptions);
}
