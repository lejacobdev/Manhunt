// Creates the Game Center configuration in App Store Connect from GameCenter/catalog.json:
// the Game Center capability on the App ID, Game Center for the app, every leaderboard and
// achievement with its localizations, each achievement's icon, and Game Center for the version.
//
// Idempotent: everything is looked up by its vendor identifier first, and only what is missing is
// created, so it is safe to run repeatedly (and the way to add an achievement later is: add it to
// catalog.json, render its icon, run this again).
//
//   node scripts/gamecenter-setup.mjs <audit|apply> <catalog.json> <iconsDir>
//
// audit  reads and reports; changes nothing.
// apply  creates whatever is missing.
//
// Credentials come from KEY_ID, ISSUER_ID and KEY_PATH (an App Store Connect API key, Admin or App
// Manager role). This runs in a PUBLIC repo's Actions, whose logs are public: it prints identifiers
// and names only, never a credential.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [mode = 'audit', catalogPath, iconsDir] = process.argv.slice(2);
if (!['audit', 'apply'].includes(mode) || !catalogPath) {
  console.error('usage: gamecenter-setup.mjs <audit|apply> <catalog.json> <iconsDir>');
  process.exit(2);
}
const APPLY = mode === 'apply';
const BUNDLE_ID = 'com.huntinggame.app';
const API = 'https://api.appstoreconnect.apple.com';
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));

// ---------------------------------------------------------------------------- API plumbing

let token = null;
let tokenMadeAt = 0;
function jwt() {
  const now = Math.floor(Date.now() / 1000);
  if (token && now - tokenMadeAt < 900) return token;
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const input =
    b64({ alg: 'ES256', kid: process.env.KEY_ID, typ: 'JWT' }) + '.' +
    b64({ iss: process.env.ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' });
  const sig = crypto.sign('sha256', Buffer.from(input), {
    key: fs.readFileSync(process.env.KEY_PATH),
    dsaEncoding: 'ieee-p1363',
  });
  token = input + '.' + sig.toString('base64url');
  tokenMadeAt = now;
  return token;
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

/** Follows pagination so a long list is never silently cut at the first page. */
async function listAll(url) {
  const out = [];
  let next = url + (url.includes('?') ? '&' : '?') + 'limit=200';
  while (next) {
    const res = await api('GET', next);
    if (!res.ok) return { error: problem(res), status: res.status, data: out };
    out.push(...(res.json.data || []));
    next = res.json.links && res.json.links.next ? res.json.links.next : null;
  }
  return { data: out };
}

let failures = 0;
const say = (s) => console.log(s);
const fail = (s) => { failures++; console.log('  FAILED ' + s); };

// ---------------------------------------------------------------------------- the app

const apps = await api('GET', `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.json && apps.json.data && apps.json.data[0];
if (!app) { console.error('app not found: ' + problem(apps)); process.exit(1); }
const primaryLocale = app.attributes.primaryLocale || 'en-US';
const locales = [...new Set([primaryLocale, 'en-US'])];
say(`APP ${app.id}  primaryLocale=${primaryLocale}  localizing into: ${locales.join(', ')}`);
say(`MODE ${mode}${APPLY ? '' : '  (read-only: nothing is created)'}`);

// ---------------------------------------------------------------------------- 1. capability on the App ID

say('\n== Game Center capability on the App ID ==');
{
  const ids = await api('GET', `/v1/bundleIds?filter[identifier]=${BUNDLE_ID}&include=bundleIdCapabilities&limit=10`);
  const bundle = (ids.json.data || []).find((b) => b.attributes.identifier === BUNDLE_ID);
  const capTypes = (ids.json.included || []).filter((i) => i.type === 'bundleIdCapabilities').map((i) => i.attributes.capabilityType);
  say(`  capabilities: ${capTypes.join(', ') || '(none)'}`);
  if (!bundle) fail('bundle id not found');
  else if (capTypes.includes('GAME_CENTER')) say('  GAME_CENTER already enabled');
  else if (!APPLY) say('  GAME_CENTER missing (would enable)');
  else {
    const made = await api('POST', '/v1/bundleIdCapabilities', { data: {
      type: 'bundleIdCapabilities',
      attributes: { capabilityType: 'GAME_CENTER' },
      relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } } },
    } });
    say(`  enabling GAME_CENTER: HTTP ${made.status}`);
    if (!made.ok) fail(problem(made));
  }
}

// ---------------------------------------------------------------------------- 2. Game Center for the app

say('\n== Game Center for the app ==');
let detailId = null;
{
  const found = await api('GET', `/v1/apps/${app.id}/gameCenterDetail`);
  if (found.ok && found.json.data) {
    detailId = found.json.data.id;
    say(`  gameCenterDetail ${detailId} exists`);
  } else if (!APPLY) {
    say(`  no gameCenterDetail yet (HTTP ${found.status}); would create`);
  } else {
    const made = await api('POST', '/v1/gameCenterDetails', { data: {
      type: 'gameCenterDetails',
      relationships: { app: { data: { type: 'apps', id: app.id } } },
    } });
    say(`  creating gameCenterDetail: HTTP ${made.status}`);
    if (made.ok) detailId = made.json.data.id; else fail(problem(made));
  }
}

// ---------------------------------------------------------------------------- 3. leaderboards

say('\n== Leaderboards ==');
if (detailId || !APPLY) {
  const existing = detailId ? await listAll(`/v1/gameCenterDetails/${detailId}/gameCenterLeaderboards`) : { data: [] };
  if (existing.error) say('  could not list: ' + existing.error);
  const byVendor = new Map((existing.data || []).map((l) => [l.attributes.vendorIdentifier, l]));

  for (const lb of catalog.leaderboards) {
    const vendor = catalog.prefix.leaderboard + lb.sort;
    let board = byVendor.get(vendor);
    if (board) say(`  ${vendor}  exists (${board.id})`);
    else if (!APPLY) { say(`  ${vendor}  MISSING (would create)`); continue; }
    else {
      const made = await api('POST', '/v1/gameCenterLeaderboards', { data: {
        type: 'gameCenterLeaderboards',
        attributes: {
          defaultFormatter: 'INTEGER',
          referenceName: lb.name,
          vendorIdentifier: vendor,
          submissionType: 'BEST_SCORE',
          scoreSortType: 'DESC',
        },
        relationships: { gameCenterDetail: { data: { type: 'gameCenterDetails', id: detailId } } },
      } });
      say(`  ${vendor}  create: HTTP ${made.status}`);
      if (!made.ok) { fail(problem(made)); continue; }
      board = made.json.data;
    }

    const locs = await listAll(`/v1/gameCenterLeaderboards/${board.id}/localizations`);
    const have = new Set((locs.data || []).map((l) => l.attributes.locale));
    for (const locale of locales) {
      if (have.has(locale)) continue;
      if (!APPLY) { say(`    ${locale} localization MISSING (would create)`); continue; }
      const made = await api('POST', '/v1/gameCenterLeaderboardLocalizations', { data: {
        type: 'gameCenterLeaderboardLocalizations',
        attributes: { locale, name: lb.name, formatterSuffix: lb.suffix, formatterSuffixSingular: lb.suffixSingular },
        relationships: { gameCenterLeaderboard: { data: { type: 'gameCenterLeaderboards', id: board.id } } },
      } });
      say(`    ${locale} localization: HTTP ${made.status}`);
      if (!made.ok) fail(problem(made));
    }
  }
} else say('  skipped: Game Center detail could not be created');

// ---------------------------------------------------------------------------- 4. achievements

say('\n== Achievements ==');
if (detailId || !APPLY) {
  const existing = detailId ? await listAll(`/v1/gameCenterDetails/${detailId}/gameCenterAchievements`) : { data: [] };
  if (existing.error) say('  could not list: ' + existing.error);
  const byVendor = new Map((existing.data || []).map((a) => [a.attributes.vendorIdentifier, a]));

  for (const ach of catalog.achievements) {
    const vendor = catalog.prefix.achievement + ach.key;
    let item = byVendor.get(vendor);
    if (item) say(`  ${vendor}  exists (${item.id})`);
    else if (!APPLY) { say(`  ${vendor}  MISSING (would create, ${ach.points} pts)`); continue; }
    else {
      const made = await api('POST', '/v1/gameCenterAchievements', { data: {
        type: 'gameCenterAchievements',
        attributes: {
          referenceName: ach.name,
          vendorIdentifier: vendor,
          points: ach.points,
          showBeforeEarned: true,
          repeatable: false,
        },
        relationships: { gameCenterDetail: { data: { type: 'gameCenterDetails', id: detailId } } },
      } });
      say(`  ${vendor}  create: HTTP ${made.status}`);
      if (!made.ok) { fail(problem(made)); continue; }
      item = made.json.data;
    }

    // Localizations, then the icon on each one.
    const locs = await listAll(`/v1/gameCenterAchievements/${item.id}/localizations`);
    const byLocale = new Map((locs.data || []).map((l) => [l.attributes.locale, l]));
    for (const locale of locales) {
      let loc = byLocale.get(locale);
      if (!loc) {
        if (!APPLY) { say(`    ${locale} localization MISSING (would create)`); continue; }
        const made = await api('POST', '/v1/gameCenterAchievementLocalizations', { data: {
          type: 'gameCenterAchievementLocalizations',
          attributes: { locale, name: ach.name, beforeEarnedDescription: ach.before, afterEarnedDescription: ach.after },
          relationships: { gameCenterAchievement: { data: { type: 'gameCenterAchievements', id: item.id } } },
        } });
        say(`    ${locale} localization: HTTP ${made.status}`);
        if (!made.ok) { fail(problem(made)); continue; }
        loc = made.json.data;
      }

      const image = await api('GET', `/v1/gameCenterAchievementLocalizations/${loc.id}/gameCenterAchievementImage`);
      const hasImage = image.ok && image.json && image.json.data;
      if (hasImage) { say(`    ${locale} icon: present (${image.json.data.attributes.assetDeliveryState?.state || 'state unknown'})`); continue; }
      if (!APPLY) { say(`    ${locale} icon MISSING (would upload)`); continue; }
      await uploadIcon(loc.id, path.join(iconsDir || '.', ach.key + '.png'), locale);
    }
  }
} else say('  skipped: Game Center detail could not be created');

/** Reserve, upload the bytes to the URLs Apple hands back, then commit with the file's checksum. */
async function uploadIcon(localizationId, file, locale) {
  if (!fs.existsSync(file)) { fail(`icon file missing: ${file}`); return; }
  const bytes = fs.readFileSync(file);
  const reserve = await api('POST', '/v1/gameCenterAchievementImages', { data: {
    type: 'gameCenterAchievementImages',
    attributes: { fileName: path.basename(file), fileSize: bytes.length },
    relationships: { gameCenterAchievementLocalization: { data: { type: 'gameCenterAchievementLocalizations', id: localizationId } } },
  } });
  if (!reserve.ok) { fail(`icon reserve: ${problem(reserve)}`); return; }
  const image = reserve.json.data;
  for (const op of image.attributes.uploadOperations || []) {
    const headers = Object.fromEntries((op.requestHeaders || []).map((h) => [h.name, h.value]));
    const part = await fetch(op.url, { method: op.method, headers, body: bytes.subarray(op.offset, op.offset + op.length) });
    if (!part.ok) { fail(`icon upload part: HTTP ${part.status}`); return; }
  }
  const commit = await api('PATCH', `/v1/gameCenterAchievementImages/${image.id}`, { data: {
    type: 'gameCenterAchievementImages',
    id: image.id,
    attributes: { uploaded: true, sourceFileChecksum: crypto.createHash('md5').update(bytes).digest('hex') },
  } });
  say(`    ${locale} icon uploaded: HTTP ${commit.status}`);
  if (!commit.ok) fail(`icon commit: ${problem(commit)}`);
}

// ---------------------------------------------------------------------------- 5. Game Center for the version

say('\n== Game Center for the version being prepared ==');
{
  const versions = await api('GET', `/v1/apps/${app.id}/appStoreVersions?limit=10`);
  const preparing = (versions.json.data || []).find((v) => {
    const state = v.attributes.appStoreState || v.attributes.appVersionState;
    return state === 'PREPARE_FOR_SUBMISSION';
  });
  if (!preparing) say('  no version in PREPARE_FOR_SUBMISSION; nothing to enable');
  else {
    say(`  version ${preparing.attributes.versionString} (${preparing.id})`);
    const gcv = await api('GET', `/v1/appStoreVersions/${preparing.id}/gameCenterAppVersion`);
    if (gcv.ok && gcv.json.data) {
      say(`  gameCenterAppVersion exists, enabled=${gcv.json.data.attributes.enabled}`);
      if (APPLY && gcv.json.data.attributes.enabled === false) {
        const patched = await api('PATCH', `/v1/gameCenterAppVersions/${gcv.json.data.id}`, { data: {
          type: 'gameCenterAppVersions', id: gcv.json.data.id, attributes: { enabled: true },
        } });
        say(`  enabling: HTTP ${patched.status}`);
        if (!patched.ok) fail(problem(patched));
      }
    } else if (!APPLY) say(`  no gameCenterAppVersion yet (HTTP ${gcv.status}); would create`);
    else {
      const made = await api('POST', '/v1/gameCenterAppVersions', { data: {
        type: 'gameCenterAppVersions',
        attributes: { enabled: true },
        relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: preparing.id } } },
      } });
      say(`  creating gameCenterAppVersion: HTTP ${made.status}`);
      if (!made.ok) fail(problem(made));
    }
  }
}

say(`\n${failures === 0 ? 'DONE, no failures' : failures + ' STEP(S) FAILED'}`);
process.exit(failures === 0 ? 0 : 1);
