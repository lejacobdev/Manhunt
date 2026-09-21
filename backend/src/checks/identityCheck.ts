/**
 * Self-contained checks for the two identity verifiers, run with `npm run check:identity`.
 *
 * These exist because neither path can be tried from a development machine: a real Apple identity
 * token needs Sign in with Apple on a device, and a real Game Center signature needs a signed-in
 * player. The parts that would silently fail — the byte layout of the Game Center payload, the JWT
 * checks that are the difference between verifying and merely decoding — are exercised here against
 * locally generated keys instead, with a stubbed `fetch` standing in for Apple's endpoints.
 *
 * A wrong byte order would not throw anywhere; it would just never verify. So the positive cases
 * matter as much as the negative ones, and there is a deliberate case proving a decimal-text
 * timestamp does NOT verify, since that is the mistake the big-endian requirement invites.
 */

import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { verifyGameCenterSignature } from '../services/GameCenterIdentity';
import { verifyAppleIdentityToken } from '../services/AppleIdentity';
import { describeWait, userTagProblem } from '../services/AccountName';

const BUNDLE_ID = 'com.huntinggame.app';
process.env.APPLE_BUNDLE_ID = BUNDLE_ID;

let failures = 0;
let checks = 0;

function ok(label: string, condition: boolean, detail = '') {
  checks++;
  if (condition) {
    console.log(`  ok   ${label}`);
  } else {
    failures++;
    console.log(`  FAIL ${label}${detail ? ` — ${detail}` : ''}`);
  }
}

/** Asserts the promise rejects, and that it rejects for the expected reason. */
async function rejects(label: string, run: () => Promise<unknown>, expectFragment?: string) {
  checks++;
  try {
    await run();
    failures++;
    console.log(`  FAIL ${label} — it was accepted, but should not have been`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (expectFragment && !message.toLowerCase().includes(expectFragment.toLowerCase())) {
      failures++;
      console.log(`  FAIL ${label} — rejected for the wrong reason: ${message}`);
    } else {
      console.log(`  ok   ${label}`);
    }
  }
}

// ---------------------------------------------------------------------------------------
// A throwaway certificate, because the verifier parses a real X.509 certificate.
// ---------------------------------------------------------------------------------------

const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'identity-check-'));
const keyPath = path.join(workDir, 'key.pem');
const certPath = path.join(workDir, 'cert.der');
execFileSync('openssl', [
  'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
  '-keyout', keyPath,
  '-out', certPath, '-outform', 'DER',
  '-days', '2', '-subj', '/CN=Test Game Center Key',
], { stdio: 'pipe' });
const gcPrivateKey = crypto.createPrivateKey(fs.readFileSync(keyPath));
const gcCertDer = fs.readFileSync(certPath);

// ---------------------------------------------------------------------------------------
// Stubbed fetch: Apple's key endpoints, and nothing else.
// ---------------------------------------------------------------------------------------

const appleKeyPair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const APPLE_KID = 'test-key-1';
const appleJwk = { ...(appleKeyPair.publicKey.export({ format: 'jwk' }) as crypto.JsonWebKey), kid: APPLE_KID, alg: 'RS256', use: 'sig' };

const realFetch = globalThis.fetch;
let servedCertRequests = 0;
globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
  if (url === 'https://appleid.apple.com/auth/keys') {
    return new Response(JSON.stringify({ keys: [appleJwk] }), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  if (url.startsWith('https://static.gc.apple.com/')) {
    servedCertRequests++;
    return new Response(new Uint8Array(gcCertDer), { status: 200 });
  }
  throw new Error(`the check made an unexpected network call to ${url}`);
}) as typeof fetch;

// ---------------------------------------------------------------------------------------
// Game Center
// ---------------------------------------------------------------------------------------

const PLAYER_ID = 'T:0123456789abcdef';
const KEY_URL = 'https://static.gc.apple.com/public-key/gc-prod-test.cer';

/** Builds the buffer exactly as Apple documents, then signs it as Apple's key would. */
function gcPayload(playerId: string, bundleId: string, timestamp: number, salt: Buffer): Buffer {
  const timestampBytes = Buffer.alloc(8);
  timestampBytes.writeBigUInt64BE(BigInt(timestamp));
  return Buffer.concat([Buffer.from(playerId, 'utf8'), Buffer.from(bundleId, 'utf8'), timestampBytes, salt]);
}

function gcSignature(payload: Buffer): string {
  return crypto.sign('sha256', payload, gcPrivateKey).toString('base64');
}

function gcInput(overrides: Partial<{ playerId: string; bundleId: string; timestamp: number; salt: Buffer; publicKeyUrl: string; signature: string }> = {}) {
  const playerId = overrides.playerId ?? PLAYER_ID;
  const bundleId = overrides.bundleId ?? BUNDLE_ID;
  const timestamp = overrides.timestamp ?? Date.now();
  const salt = overrides.salt ?? crypto.randomBytes(16);
  return {
    playerId,
    publicKeyUrl: overrides.publicKeyUrl ?? KEY_URL,
    signature: overrides.signature ?? gcSignature(gcPayload(playerId, bundleId, timestamp, salt)),
    salt: salt.toString('base64'),
    timestamp,
  };
}

async function gameCenterChecks() {
  console.log('\nGame Center identity signature');

  const good = await verifyGameCenterSignature(gcInput());
  ok('a correctly signed payload verifies', good.playerId === PLAYER_ID, `got ${good.playerId}`);

  // The whole point of the exercise: the id is only trustworthy because it is inside the signature.
  const tampered = gcInput();
  await rejects('a player id swapped after signing is rejected', () =>
    verifyGameCenterSignature({ ...tampered, playerId: 'T:ffffffffffffffff' }), 'could not be verified');

  await rejects('a signature made for another app is rejected', () =>
    verifyGameCenterSignature(gcInput({ bundleId: 'com.someone.else' })), 'could not be verified');

  // If this ever passes, the implementation stopped using big-endian bytes.
  const now = Date.now();
  const salt = crypto.randomBytes(16);
  const decimalTimestampPayload = Buffer.concat([
    Buffer.from(PLAYER_ID, 'utf8'),
    Buffer.from(BUNDLE_ID, 'utf8'),
    Buffer.from(String(now), 'utf8'),
    salt,
  ]);
  await rejects('a timestamp signed as decimal text is rejected (big-endian is required)', () =>
    verifyGameCenterSignature({
      playerId: PLAYER_ID,
      publicKeyUrl: KEY_URL,
      signature: gcSignature(decimalTimestampPayload),
      salt: salt.toString('base64'),
      timestamp: now,
    }), 'could not be verified');

  await rejects('a stale timestamp is rejected', () =>
    verifyGameCenterSignature(gcInput({ timestamp: Date.now() - 20 * 60 * 1000 })), 'took too long');

  await rejects('a timestamp from the future is rejected', () =>
    verifyGameCenterSignature(gcInput({ timestamp: Date.now() + 60 * 60 * 1000 })), 'clock');

  // Host checks are on the parsed hostname, so these lookalikes must not slip through.
  for (const url of [
    'https://static.gc.apple.com.attacker.example/key.cer',
    'http://static.gc.apple.com/key.cer',
    'https://attacker.example/key.cer?trust=static.gc.apple.com',
  ]) {
    await rejects(`a key URL at ${url} is rejected`, () =>
      verifyGameCenterSignature(gcInput({ publicKeyUrl: url })));
  }

  await rejects('an empty signature is rejected', () => verifyGameCenterSignature(gcInput({ signature: '' })), 'no signature');

  const before = servedCertRequests;
  await verifyGameCenterSignature(gcInput());
  ok('the certificate is cached rather than refetched per sign-in', servedCertRequests === before);
}

// ---------------------------------------------------------------------------------------
// Sign in with Apple
// ---------------------------------------------------------------------------------------

function b64url(value: Buffer | string): string {
  return Buffer.from(value).toString('base64url');
}

function appleToken(claims: Record<string, unknown>, options: { alg?: string; kid?: string; signWith?: crypto.KeyObject | null } = {}) {
  const header = { alg: options.alg ?? 'RS256', kid: options.kid ?? APPLE_KID, typ: 'JWT' };
  const body = { iss: 'https://appleid.apple.com', aud: BUNDLE_ID, sub: '000123.abcdef.4242', exp: Math.floor(Date.now() / 1000) + 600, iat: Math.floor(Date.now() / 1000), ...claims };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(body))}`;
  if (options.signWith === null) return `${signingInput}.`;
  const key = options.signWith ?? appleKeyPair.privateKey;
  return `${signingInput}.${crypto.sign('sha256', Buffer.from(signingInput), key).toString('base64url')}`;
}

async function appleChecks() {
  console.log('\nSign in with Apple identity token');

  const good = await verifyAppleIdentityToken(appleToken({}));
  ok('a correctly signed token verifies', good.subject === '000123.abcdef.4242', `got ${good.subject}`);

  // alg=none is the textbook JWT hole; the verifier pins RS256 rather than trusting the header.
  await rejects('an unsigned token (alg=none) is rejected', () =>
    verifyAppleIdentityToken(appleToken({}, { alg: 'none', signWith: null })), 'not signed the way Apple signs');

  const otherKey = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  await rejects('a token signed by somebody else is rejected', () =>
    verifyAppleIdentityToken(appleToken({}, { signWith: otherKey.privateKey })), 'could not be verified');

  await rejects('a token for another app is rejected', () =>
    verifyAppleIdentityToken(appleToken({ aud: 'com.someone.else' })), 'different app');

  await rejects('a token from another issuer is rejected', () =>
    verifyAppleIdentityToken(appleToken({ iss: 'https://accounts.example.com' })), 'did not come from Apple');

  await rejects('an expired token is rejected', () =>
    verifyAppleIdentityToken(appleToken({ exp: Math.floor(Date.now() / 1000) - 3600 })), 'expired');

  await rejects('an unknown signing key is rejected', () =>
    verifyAppleIdentityToken(appleToken({}, { kid: 'not-a-real-kid' })), 'do not recognise');

  const nonce = crypto.createHash('sha256').update('raw-nonce').digest('hex');
  const withNonce = await verifyAppleIdentityToken(appleToken({ nonce }), nonce);
  ok('a matching nonce verifies', withNonce.subject === '000123.abcdef.4242');

  await rejects('a mismatched nonce is rejected', () =>
    verifyAppleIdentityToken(appleToken({ nonce }), crypto.createHash('sha256').update('other').digest('hex')), 'does not match');

  await rejects('a missing nonce is rejected when one was expected', () =>
    verifyAppleIdentityToken(appleToken({}), nonce), 'missing its one-time value');

  await rejects('a token with no subject is rejected', () =>
    verifyAppleIdentityToken(appleToken({ sub: undefined })), 'no account identifier');

  await rejects('a malformed token is rejected', () => verifyAppleIdentityToken('not.a.jwt'), 'could not be read');
  await rejects('an empty token is rejected', () => verifyAppleIdentityToken(''), 'did not return a sign-in token');
}

// ---------------------------------------------------------------------------------------
// Name rules that need no database
// ---------------------------------------------------------------------------------------

function nameChecks() {
  console.log('\nTag and cooldown wording');
  ok('a 4-digit tag is accepted', userTagProblem('4921') === null);
  ok('a short tag is rejected', (userTagProblem('49') ?? '').includes('exactly 4 digits'));
  ok('a long tag is rejected', (userTagProblem('49211') ?? '').includes('exactly 4 digits'));
  ok('a non-numeric tag is rejected', (userTagProblem('49a1') ?? '').includes('4 digits'));
  ok('an empty tag is rejected', userTagProblem('') !== null);
  ok('a leading-zero tag is accepted', userTagProblem('0000') === null);

  ok('minutes are worded', describeWait(30 * 60_000) === 'in 30 minutes', describeWait(30 * 60_000));
  ok('hours are worded', describeWait(3 * 60 * 60_000) === 'in 3 hours', describeWait(3 * 60 * 60_000));
  ok('days are worded', describeWait(3 * 24 * 60 * 60_000) === 'in 3 days', describeWait(3 * 24 * 60 * 60_000));
  ok('one day is singular', describeWait(24 * 60 * 60_000) === 'in 1 day', describeWait(24 * 60 * 60_000));
  ok('a nearly-elapsed wait is vague rather than "in 0 minutes"', describeWait(1000) === 'in a few minutes');
}

async function main() {
  await gameCenterChecks();
  await appleChecks();
  nameChecks();

  globalThis.fetch = realFetch;
  fs.rmSync(workDir, { recursive: true, force: true });

  console.log(`\n${failures === 0 ? 'PASS' : 'FAIL'}: ${checks - failures}/${checks} checks passed`);
  process.exit(failures === 0 ? 0 : 1);
}

void main();
