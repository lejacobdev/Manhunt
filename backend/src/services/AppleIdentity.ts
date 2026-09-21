/**
 * Verifies a Sign in with Apple identity token.
 *
 * The app sends the `identityToken` from ASAuthorizationAppleIDCredential. That token is a JWT
 * Apple signed, and it is the ONLY part of the credential worth trusting: the user identifier,
 * name and email fields sitting next to it in the credential are just values the client handed
 * us, and a modified build could put anything there. So nothing outside this file ever reads an
 * Apple subject that did not come back from `verifyAppleIdentityToken`.
 *
 * What is checked, and why each one matters:
 *   - signature, against Apple's published keys (otherwise the token is forgeable outright);
 *   - `iss` is Apple (a token from some other issuer is not Apple's to vouch for);
 *   - `aud` is OUR bundle id (an identity token minted for a different app would otherwise let
 *     that app's developer sign in as any of our users);
 *   - `exp` is in the future, with a small clock-skew allowance;
 *   - `nonce`, when the app supplied one, matches — that is what stops a token captured from
 *     one sign-in being replayed into another.
 */

import crypto from 'node:crypto';

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_KEYS_URL = 'https://appleid.apple.com/auth/keys';
/** Both halves of the app ship under the iOS bundle id, so one audience covers phone and watch. */
const DEFAULT_AUDIENCE = 'com.huntinggame.app';
const CLOCK_SKEW_SECONDS = 120;

export class IdentityError extends Error {}

interface AppleKey {
  kid: string;
  kty: string;
  alg: string;
  n: string;
  e: string;
  use?: string;
}

let keyCache: { keys: AppleKey[]; fetchedAt: number } | null = null;
/** Apple rotates these rarely; an hour keeps us off their endpoint on every sign-in. */
const KEY_CACHE_MS = 60 * 60 * 1000;

async function appleKeys(forceRefresh = false): Promise<AppleKey[]> {
  if (!forceRefresh && keyCache && Date.now() - keyCache.fetchedAt < KEY_CACHE_MS) {
    return keyCache.keys;
  }
  const res = await fetch(APPLE_KEYS_URL, { signal: AbortSignal.timeout(10_000) });
  if (!res.ok) {
    // A stale cache beats failing every sign-in while Apple has a bad minute.
    if (keyCache) return keyCache.keys;
    throw new IdentityError(`Could not reach Apple to verify your sign-in (HTTP ${res.status}). Please try again.`);
  }
  const body = (await res.json()) as { keys?: AppleKey[] };
  const keys = body.keys ?? [];
  if (keys.length === 0) throw new IdentityError('Apple returned no signing keys. Please try again.');
  keyCache = { keys, fetchedAt: Date.now() };
  return keys;
}

function base64UrlDecode(part: string): Buffer {
  return Buffer.from(part, 'base64url');
}

interface AppleClaims {
  iss?: string;
  aud?: string | string[];
  sub?: string;
  exp?: number;
  iat?: number;
  nonce?: string;
  nonce_supported?: boolean;
  email?: string;
}

export interface AppleIdentity {
  /** Apple's stable per-team subject. The only thing we persist. */
  subject: string;
}

/**
 * @param identityToken the raw JWT from the app
 * @param expectedNonce SHA-256 hex of the app's raw nonce, when the app used one
 */
export async function verifyAppleIdentityToken(
  identityToken: string,
  expectedNonce?: string,
): Promise<AppleIdentity> {
  const token = (identityToken ?? '').trim();
  if (!token) throw new IdentityError('Apple did not return a sign-in token. Please try again.');

  const parts = token.split('.');
  if (parts.length !== 3) throw new IdentityError('That Apple sign-in token is not in a form we can read.');
  const [headerPart, payloadPart, signaturePart] = parts;

  let header: { kid?: string; alg?: string };
  let claims: AppleClaims;
  try {
    header = JSON.parse(base64UrlDecode(headerPart).toString('utf8'));
    claims = JSON.parse(base64UrlDecode(payloadPart).toString('utf8'));
  } catch {
    throw new IdentityError('That Apple sign-in token could not be read.');
  }

  // Pinned rather than taken from the header: honouring whatever `alg` a token asks for is the
  // classic JWT hole (alg=none, or an HMAC verified with the public key as its secret).
  if (header.alg !== 'RS256') throw new IdentityError('That Apple sign-in token is not signed the way Apple signs.');
  if (!header.kid) throw new IdentityError('That Apple sign-in token names no signing key.');

  // One retry with fresh keys covers the window right after Apple rotates a key.
  let keys = await appleKeys();
  let jwk = keys.find((k) => k.kid === header.kid);
  if (!jwk) {
    keys = await appleKeys(true);
    jwk = keys.find((k) => k.kid === header.kid);
  }
  if (!jwk) throw new IdentityError('Apple signed your sign-in with a key we do not recognise. Please try again.');

  const publicKey = crypto.createPublicKey({ key: jwk as unknown as crypto.JsonWebKey, format: 'jwk' });
  const signedInput = Buffer.from(`${headerPart}.${payloadPart}`, 'utf8');
  const signature = base64UrlDecode(signaturePart);
  if (!crypto.verify('sha256', signedInput, publicKey, signature)) {
    throw new IdentityError('That Apple sign-in could not be verified.');
  }

  if (claims.iss !== APPLE_ISSUER) throw new IdentityError('That sign-in token did not come from Apple.');

  const audience = process.env.APPLE_BUNDLE_ID ?? DEFAULT_AUDIENCE;
  const audiences = Array.isArray(claims.aud) ? claims.aud : claims.aud ? [claims.aud] : [];
  if (!audiences.includes(audience)) {
    throw new IdentityError('That Apple sign-in was issued for a different app.');
  }

  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== 'number' || claims.exp + CLOCK_SKEW_SECONDS < now) {
    throw new IdentityError('That Apple sign-in has expired. Please try again.');
  }

  if (expectedNonce) {
    if (!claims.nonce) throw new IdentityError('That Apple sign-in is missing its one-time value. Please try again.');
    const a = Buffer.from(claims.nonce, 'utf8');
    const b = Buffer.from(expectedNonce, 'utf8');
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
      throw new IdentityError('That Apple sign-in does not match this attempt. Please try again.');
    }
  }

  if (!claims.sub) throw new IdentityError('That Apple sign-in carries no account identifier.');
  return { subject: claims.sub };
}
