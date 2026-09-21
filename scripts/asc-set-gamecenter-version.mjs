// Switches Game Center on or off for the App Store version being prepared, then reads it back.
// Only a version in PREPARE_FOR_SUBMISSION can change; anything else is refused.
//
//   node scripts/asc-set-gamecenter-version.mjs <versionString> <on|off>
//
// Credentials come from KEY_ID, ISSUER_ID and KEY_PATH. Public repo, public logs: identifiers and
// states only.

import crypto from 'node:crypto';
import fs from 'node:fs';

const [versionString, position] = process.argv.slice(2);
if (!versionString || !['on', 'off'].includes(position)) {
  console.error('usage: asc-set-gamecenter-version.mjs <versionString> <on|off>');
  process.exit(2);
}
const want = position === 'on';
const BUNDLE_ID = 'com.huntinggame.app';
const API = 'https://api.appstoreconnect.apple.com';

function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const input =
    b64({ alg: 'ES256', kid: process.env.KEY_ID, typ: 'JWT' }) + '.' +
    b64({ iss: process.env.ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' });
  const sig = crypto.sign('sha256', Buffer.from(input), {
    key: fs.readFileSync(process.env.KEY_PATH),
    dsaEncoding: 'ieee-p1363',
  });
  return input + '.' + sig.toString('base64url');
}

async function api(method, url, body) {
  const res = await fetch(url.startsWith('http') ? url : API + url, {
    method,
    headers: { Authorization: 'Bearer ' + jwt(), ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { status: res.status, ok: res.ok, json, text };
}

function problem(res) {
  const errors = (res.json && res.json.errors) || [];
  return errors.map((e) => `${e.code || e.status}: ${e.title || ''} ${e.detail || ''}`.trim()).join(' | ') || res.text.slice(0, 300);
}

const apps = await api('GET', `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.json && apps.json.data && apps.json.data[0];
if (!app) { console.error('app not found: ' + problem(apps)); process.exit(1); }

const versions = await api('GET', `/v1/apps/${app.id}/appStoreVersions?limit=10`);
const version = ((versions.json && versions.json.data) || []).find((v) => v.attributes.versionString === versionString);
if (!version) { console.error(`version ${versionString} not found`); process.exit(1); }
const state = version.attributes.appStoreState || version.attributes.appVersionState;
console.log(`VERSION ${versionString} (${version.id})  state=${state}`);
if (state !== 'PREPARE_FOR_SUBMISSION') { console.error('not editable; refusing'); process.exit(1); }

const gcv = await api('GET', `/v1/appStoreVersions/${version.id}/gameCenterAppVersion`);
if (!gcv.ok || !gcv.json || !gcv.json.data) { console.error(`no gameCenterAppVersion (HTTP ${gcv.status}): ${problem(gcv)}`); process.exit(1); }
const id = gcv.json.data.id;
console.log(`gameCenterAppVersion ${id}  enabled=${gcv.json.data.attributes.enabled}  ->  wanted ${want}`);

if (gcv.json.data.attributes.enabled !== want) {
  const patched = await api('PATCH', `/v1/gameCenterAppVersions/${id}`, {
    data: { type: 'gameCenterAppVersions', id, attributes: { enabled: want } },
  });
  console.log(`PATCH enabled=${want}: HTTP ${patched.status}${patched.ok ? '' : '  (' + problem(patched) + ')'}`);
}

const back = await api('GET', `/v1/gameCenterAppVersions/${id}`);
const now = back.json && back.json.data && back.json.data.attributes.enabled;
console.log(`read back: enabled=${now}`);
if (now !== want) { console.log('FAILED: the flag is not ' + want); process.exit(1); }
console.log(`DONE: Game Center is ${position} for ${versionString}`);
