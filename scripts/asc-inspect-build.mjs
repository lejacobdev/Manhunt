// Read-only: what App Store Connect itself recorded for the builds of this app and for the version
// being prepared. Used to answer "does App Store Connect see the Game Center entitlement in build N?"
// without guessing from our own signing report.
//
//   node scripts/asc-inspect-build.mjs [buildNumber]
//
// Credentials come from KEY_ID, ISSUER_ID and KEY_PATH. This runs in a PUBLIC repo's Actions, whose
// logs are public: it prints identifiers, states and entitlement keys, and redacts the team id.

import crypto from 'node:crypto';
import fs from 'node:fs';

const wanted = process.argv[2] || '';
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

async function get(url) {
  const res = await fetch(url.startsWith('http') ? url : API + url, { headers: { Authorization: 'Bearer ' + jwt() } });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { status: res.status, ok: res.ok, json, text };
}

function problem(res) {
  const errors = (res.json && res.json.errors) || [];
  return errors.map((e) => `${e.code || e.status}: ${e.title || ''} ${e.detail || ''}`.trim()).join(' | ') || res.text.slice(0, 300);
}

const SECRET_KEYS = new Set(['application-identifier', 'com.apple.developer.team-identifier']);
function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = SECRET_KEYS.has(k) ? '(redacted)' : redact(v);
    return out;
  }
  return value;
}

const apps = await get(`/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.json && apps.json.data && apps.json.data[0];
if (!app) { console.error('app not found: ' + problem(apps)); process.exit(1); }
console.log(`APP ${app.id}`);

// ---- the capabilities on the App ID itself (the identifier filter is a PREFIX match and `included`
// pools every matching App ID's capabilities, so narrow to this exact bundle's own relationship ids)
console.log('\n== Capabilities on the App ID ==');
{
  const ids = await get(`/v1/bundleIds?filter[identifier]=${BUNDLE_ID}&include=bundleIdCapabilities&limit=10`);
  if (!ids.ok) console.log('  FAILED ' + problem(ids));
  else {
    const bundle = (ids.json.data || []).find((b) => b.attributes.identifier === BUNDLE_ID);
    const own = new Set((((bundle && bundle.relationships && bundle.relationships.bundleIdCapabilities) || {}).data || []).map((c) => c.id));
    const caps = (ids.json.included || []).filter((i) => i.type === 'bundleIdCapabilities' && own.has(i.id));
    console.log(`  ${BUNDLE_ID}: ${caps.map((c) => c.attributes.capabilityType).join(', ') || '(none)'}`);
  }
}

// ---- the versions and which build each one has attached
console.log('\n== App Store versions ==');
const versions = await get(`/v1/apps/${app.id}/appStoreVersions?limit=10`);
for (const v of (versions.json && versions.json.data) || []) {
  const state = v.attributes.appStoreState || v.attributes.appVersionState;
  const build = await get(`/v1/appStoreVersions/${v.id}/build`);
  const b = build.json && build.json.data;
  console.log(`  ${v.attributes.versionString}  ${state}  attached build: ${b ? b.attributes.version + ' (' + b.id + ')' : '(none)'}`);
  const gcv = await get(`/v1/appStoreVersions/${v.id}/gameCenterAppVersion`);
  if (gcv.ok && gcv.json && gcv.json.data) console.log(`    gameCenterAppVersion ${gcv.json.data.id}  enabled=${gcv.json.data.attributes.enabled}`);
  else console.log(`    no gameCenterAppVersion (HTTP ${gcv.status})`);
}

// ---- recent builds and what App Store Connect recorded inside them
console.log('\n== Builds ==');
const builds = await get(`/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=6&include=preReleaseVersion`);
if (!builds.ok) { console.log('  FAILED ' + problem(builds)); process.exit(1); }
const preRelease = new Map(((builds.json && builds.json.included) || []).map((i) => [i.id, i.attributes.version]));
for (const b of builds.json.data || []) {
  const pre = preRelease.get(b.relationships && b.relationships.preReleaseVersion && b.relationships.preReleaseVersion.data && b.relationships.preReleaseVersion.data.id);
  const a = b.attributes;
  console.log(`\n  build ${a.version}  version ${pre || '?'}  processing=${a.processingState}  expired=${a.expired}  uploaded=${a.uploadedDate}`);
  if (wanted && a.version !== wanted) continue;
  if (!wanted && b !== builds.json.data[0]) continue;
  // The sub-endpoint is not allowed for API keys, so try the other ways to reach the same records:
  // sideloading them through `include`, then through the relationship's ids.
  let records = [];
  const viaInclude = await get(`/v1/builds/${b.id}?include=buildBundles`);
  if (viaInclude.ok) records = (viaInclude.json.included || []).filter((i) => i.type === 'buildBundles');
  else console.log('    include=buildBundles FAILED ' + problem(viaInclude));
  if (records.length === 0) {
    const rel = await get(`/v1/builds/${b.id}/relationships/buildBundles`);
    if (!rel.ok) console.log('    relationships/buildBundles FAILED ' + problem(rel));
    for (const ref of (rel.ok && rel.json.data) || []) {
      const one = await get(`/v1/buildBundles/${ref.id}`);
      if (one.ok) records.push(one.json.data);
      else console.log(`    buildBundles/${ref.id} FAILED ` + problem(one));
    }
  }
  if (records.length === 0) console.log('    (no bundle records reachable)');
  for (const bb of records) {
    const attrs = bb.attributes || {};
    console.log(`    bundle ${attrs.bundleId}  type=${attrs.bundleType}`);
    if (attrs.entitlements === undefined) console.log(`      attributes present: ${Object.keys(attrs).join(', ')}`);
    else console.log('      entitlements: ' + JSON.stringify(redact(attrs.entitlements)));
  }
}
