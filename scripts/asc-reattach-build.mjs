// Re-attaches a build to the App Store version being prepared, through the API: the same thing as
// pressing the minus next to Build in App Store Connect and choosing the build again. It ends with
// the SAME build attached (verified at the end, and it exits non-zero if not), so it can only ever
// re-trigger App Store Connect's own checks on that pairing.
//
//   node scripts/asc-reattach-build.mjs <versionString> <buildNumber>
//
// Credentials come from KEY_ID, ISSUER_ID and KEY_PATH. Public repo, public logs: only identifiers
// and states are printed.

import crypto from 'node:crypto';
import fs from 'node:fs';

const [versionString, buildNumber] = process.argv.slice(2);
if (!versionString || !buildNumber) {
  console.error('usage: asc-reattach-build.mjs <versionString> <buildNumber>');
  process.exit(2);
}
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
    headers: { Authorization: 'Bearer ' + jwt(), ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
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

const builds = await api('GET',
  `/v1/builds?filter[app]=${app.id}&filter[version]=${buildNumber}&filter[preReleaseVersion.version]=${versionString}&limit=5`);
const build = builds.json && builds.json.data && builds.json.data[0];
if (!build) { console.error(`build ${buildNumber} for ${versionString} not found: ${problem(builds)}`); process.exit(1); }
console.log(`BUILD ${buildNumber} (${build.id})  processing=${build.attributes.processingState}`);

async function attached() {
  const r = await api('GET', `/v1/appStoreVersions/${version.id}/build`);
  const b = r.json && r.json.data;
  return b ? `${b.attributes.version} (${b.id})` : '(none)';
}
const link = { data: { type: 'builds', id: build.id } };

console.log(`before: attached = ${await attached()}`);

// 1. Try the true "minus": clear the build. The API may refuse a null link; that is fine.
const cleared = await api('PATCH', `/v1/appStoreVersions/${version.id}/relationships/build`, { data: null });
console.log(`clear build: HTTP ${cleared.status}${cleared.ok ? '' : '  (' + problem(cleared) + ')'}`);
console.log(`  attached now = ${await attached()}`);

// 2. Attach the build again. Always attempted, and retried once, so the version is never left without it.
let put = await api('PATCH', `/v1/appStoreVersions/${version.id}/relationships/build`, link);
console.log(`attach build ${buildNumber}: HTTP ${put.status}${put.ok ? '' : '  (' + problem(put) + ')'}`);
if (!put.ok) {
  put = await api('PATCH', `/v1/appStoreVersions/${version.id}/relationships/build`, link);
  console.log(`attach build ${buildNumber} (retry): HTTP ${put.status}${put.ok ? '' : '  (' + problem(put) + ')'}`);
}

const after = await attached();
console.log(`after: attached = ${after}`);
const gcv = await api('GET', `/v1/appStoreVersions/${version.id}/gameCenterAppVersion`);
if (gcv.ok && gcv.json && gcv.json.data) console.log(`gameCenterAppVersion enabled=${gcv.json.data.attributes.enabled}`);

if (!after.startsWith(buildNumber + ' ')) { console.log('FAILED: the build is not attached'); process.exit(1); }
console.log('DONE: build ' + buildNumber + ' is attached to ' + versionString);
