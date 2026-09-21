/**
 * Verifies a Game Center identity signature.
 *
 * GameKit's `fetchItems(forIdentityVerificationSignature:)` hands the app a publicKeyURL,
 * signature, salt and timestamp; the app sends those plus its `teamPlayerID`. Apple's documented
 * server-side check (see that method's docs) is implemented here verbatim:
 *
 *   1. the timestamp is recent, to blunt replay;
 *   2. download the public key from `publicKeyURL`;
 *   3. satisfy yourself Apple signed that key;
 *   4. concatenate teamPlayerID (UTF-8) + bundle id (UTF-8) + timestamp (big-endian UInt64) + salt;
 *   5. verify the signature over that buffer, RFC 8017 section 8.2 (RSASSA-PKCS1-v1_5).
 *
 * This is what makes the player id trustworthy. Without it the app could claim to be any player
 * simply by sending their id. Apple's own note on the method: "Trust only the fields in the signed
 * payload" — so nicknames and display names the app sends are never used for identity here.
 *
 * On step 3: the key is fetched over HTTPS from a host that must sit under apple.com, so TLS
 * establishes that Apple served it, and the certificate's own validity window is checked. Building
 * the full chain back to a pinned Apple root is deliberately not attempted — Node would need the
 * intermediates, which the endpoint does not serve — so the trust here rests on TLS to an
 * Apple-owned host plus a signature that only the holder of that certificate's private key could
 * have produced.
 */

import crypto from 'node:crypto';

import { IdentityError } from './IdentityError';

const DEFAULT_BUNDLE_ID = 'com.huntinggame.app';
/** Apple's own advice is "make sure the timestamp is recent"; ten minutes is generous for a slow network. */
const MAX_AGE_MS = 10 * 60 * 1000;
/** A timestamp meaningfully in the future means a tampered or badly skewed client. */
const MAX_SKEW_AHEAD_MS = 5 * 60 * 1000;
const MAX_CERT_BYTES = 64 * 1024;

const certCache = new Map<string, { publicKey: crypto.KeyObject; fetchedAt: number }>();
const CERT_CACHE_MS = 12 * 60 * 60 * 1000;

/**
 * Only Apple's own hosts. Checked on the parsed URL's hostname (not a substring of the string)
 * so `https://apple.com.attacker.example/key.cer` and `https://evil/?x=apple.com` both fail.
 */
function assertAppleKeyUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new IdentityError('Game Center returned a key location we could not read.');
  }
  if (url.protocol !== 'https:') throw new IdentityError('Game Center key location was not HTTPS.');
  const host = url.hostname.toLowerCase();
  if (host !== 'apple.com' && !host.endsWith('.apple.com')) {
    throw new IdentityError('Game Center key location was not an Apple host.');
  }
  return url;
}

async function applePublicKey(rawUrl: string): Promise<crypto.KeyObject> {
  const url = assertAppleKeyUrl(rawUrl);
  const cacheKey = url.toString();
  const cached = certCache.get(cacheKey);
  if (cached && Date.now() - cached.fetchedAt < CERT_CACHE_MS) return cached.publicKey;

  const res = await fetch(cacheKey, { signal: AbortSignal.timeout(10_000) });
  if (!res.ok) {
    if (cached) return cached.publicKey;
    throw new IdentityError(`Could not reach Apple to verify Game Center (HTTP ${res.status}). Please try again.`);
  }
  const body = Buffer.from(await res.arrayBuffer());
  if (body.length === 0 || body.length > MAX_CERT_BYTES) {
    throw new IdentityError('Apple returned a Game Center key we could not read.');
  }

  let cert: crypto.X509Certificate;
  try {
    cert = new crypto.X509Certificate(body);
  } catch {
    throw new IdentityError('Apple returned a Game Center key we could not read.');
  }

  const now = Date.now();
  const validFrom = Date.parse(cert.validFrom);
  const validTo = Date.parse(cert.validTo);
  if (Number.isFinite(validFrom) && now < validFrom - MAX_SKEW_AHEAD_MS) {
    throw new IdentityError('The Game Center key Apple returned is not valid yet.');
  }
  if (Number.isFinite(validTo) && now > validTo) {
    throw new IdentityError('The Game Center key Apple returned has expired.');
  }

  const publicKey = cert.publicKey;
  certCache.set(cacheKey, { publicKey, fetchedAt: now });
  return publicKey;
}

export interface GameCenterSignature {
  /** GameKit's teamPlayerID, as sent by the app — trusted only once the signature verifies over it. */
  playerId: string;
  publicKeyUrl: string;
  /** Base64, as GameKit produced it. */
  signature: string;
  /** Base64, as GameKit produced it. */
  salt: string;
  /** Milliseconds since the Unix epoch, as GameKit produced it. */
  timestamp: number;
}

export interface GameCenterIdentity {
  playerId: string;
}

export async function verifyGameCenterSignature(input: GameCenterSignature): Promise<GameCenterIdentity> {
  const playerId = (input.playerId ?? '').trim();
  if (!playerId) throw new IdentityError('Game Center did not return a player identifier.');
  if (!Number.isFinite(input.timestamp) || input.timestamp <= 0) {
    throw new IdentityError('Game Center returned an unusable timestamp.');
  }

  const now = Date.now();
  if (input.timestamp > now + MAX_SKEW_AHEAD_MS) {
    throw new IdentityError('Your device clock is ahead of ours, so Game Center sign-in could not be verified.');
  }
  if (now - input.timestamp > MAX_AGE_MS) {
    throw new IdentityError('That Game Center sign-in took too long to reach us. Please try again.');
  }

  const signature = Buffer.from(input.signature ?? '', 'base64');
  const salt = Buffer.from(input.salt ?? '', 'base64');
  if (signature.length === 0) throw new IdentityError('Game Center returned no signature.');
  if (salt.length === 0) throw new IdentityError('Game Center returned no salt.');

  const bundleId = process.env.APPLE_BUNDLE_ID ?? DEFAULT_BUNDLE_ID;

  // Exactly the order Apple documents. The timestamp is 8 bytes big-endian, NOT its decimal text:
  // writing it as a string would verify against nothing.
  const timestampBytes = Buffer.alloc(8);
  timestampBytes.writeBigUInt64BE(BigInt(Math.trunc(input.timestamp)));
  const payload = Buffer.concat([
    Buffer.from(playerId, 'utf8'),
    Buffer.from(bundleId, 'utf8'),
    timestampBytes,
    salt,
  ]);

  const publicKey = await applePublicKey(input.publicKeyUrl);
  // Default RSA padding in Node's verify is PKCS1-v1_5, which is what RFC 8017 section 8.2 is.
  const ok = crypto.verify('sha256', payload, publicKey, signature);
  if (!ok) throw new IdentityError('That Game Center sign-in could not be verified.');

  return { playerId };
}

export { IdentityError };
