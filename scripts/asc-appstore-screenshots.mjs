// Replaces the iPhone App Store screenshots of the version being prepared (the app's own
// MARKETING_VERSION, created if it doesn't exist yet) with the mock-ups in a folder, in file-name
// order, en-US. Each existing iPhone screenshot set is refilled at a size it accepts; if there is
// none, a 6.5" set is made. iPad sets are left alone.
//
//   node scripts/asc-appstore-screenshots.mjs site/assets/appstore-screenshots-1.2
//   (KEY_ID, ISSUER_ID, KEY_PATH; DRY_RUN=1 only lists what's there)
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const APP_ID = '6809603844';
const dir = process.argv[2];
// Folder layout: <dir>/1284x2778/*.png (6.5") and <dir>/1290x2796/*.png (6.7" and 6.9").
const SIZE_FOR = { APP_IPHONE_65: '1284x2778', APP_IPHONE_67: '1290x2796', APP_IPHONE_69: '1290x2796' };

function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const input = b64({ alg: 'ES256', kid: process.env.KEY_ID, typ: 'JWT' }) + '.' + b64({ iss: process.env.ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' });
  return input + '.' + crypto.sign('sha256', Buffer.from(input), { key: fs.readFileSync(process.env.KEY_PATH), dsaEncoding: 'ieee-p1363' }).toString('base64url');
}
async function api(method, p, body) {
  const r = await fetch('https://api.appstoreconnect.apple.com' + p, { method, headers: { Authorization: 'Bearer ' + jwt(), ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  if (!r.ok) throw new Error(`${method} ${p} -> ${r.status} ${t.slice(0, 400)}`);
  return t ? JSON.parse(t) : null;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const marketing = fs.readFileSync('ios/HuntingGame/project.yml', 'utf8').match(/MARKETING_VERSION:\s*"([^"]+)"/)[1];
const versions = (await api('GET', `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10`)).data;
let version = versions.find((v) => v.attributes.versionString === marketing);
if (!version) {
  version = (await api('POST', '/v1/appStoreVersions', { data: { type: 'appStoreVersions', attributes: { platform: 'IOS', versionString: marketing }, relationships: { app: { data: { type: 'apps', id: APP_ID } } } } })).data;
  console.log(`Created App Store version ${marketing}`);
}
console.log(`Version ${marketing}: ${version.attributes.appStoreState}`);
const loc = (await api('GET', `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)).data.find((l) => l.attributes.locale === 'en-US');
if (!loc) throw new Error('No en-US localization');

let sets = (await api('GET', `/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets?limit=50`)).data;
for (const s of sets) {
  const shots = (await api('GET', `/v1/appScreenshotSets/${s.id}/appScreenshots?limit=50`)).data;
  console.log(`  set ${s.attributes.screenshotDisplayType}: ${shots.length} screenshots`);
}
if (process.env.DRY_RUN) process.exit(0);

let targets = sets.filter((s) => SIZE_FOR[s.attributes.screenshotDisplayType]);
if (!targets.length) {
  const created = (await api('POST', '/v1/appScreenshotSets', { data: { type: 'appScreenshotSets', attributes: { screenshotDisplayType: 'APP_IPHONE_65' }, relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: loc.id } } } } })).data;
  targets = [created];
}

for (const set of targets) {
  const type = set.attributes.screenshotDisplayType;
  const folder = path.join(dir, SIZE_FOR[type]);
  const files = fs.readdirSync(folder).filter((f) => f.endsWith('.png')).sort();
  for (const old of (await api('GET', `/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`)).data) {
    await api('DELETE', `/v1/appScreenshots/${old.id}`);
  }
  const ids = [];
  for (const name of files) {
    const bytes = fs.readFileSync(path.join(folder, name));
    const shot = (await api('POST', '/v1/appScreenshots', { data: { type: 'appScreenshots', attributes: { fileName: name, fileSize: bytes.length }, relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.id } } } } })).data;
    for (const op of shot.attributes.uploadOperations) {
      const headers = Object.fromEntries((op.requestHeaders ?? []).map((h) => [h.name, h.value]));
      const r = await fetch(op.url, { method: op.method, headers, body: bytes.subarray(op.offset, op.offset + op.length) });
      if (!r.ok) throw new Error(`upload ${name} -> ${r.status}`);
    }
    const md5 = crypto.createHash('md5').update(bytes).digest('hex');
    await api('PATCH', `/v1/appScreenshots/${shot.id}`, { data: { type: 'appScreenshots', id: shot.id, attributes: { uploaded: true, sourceFileChecksum: md5 } } });
    ids.push(shot.id);
  }
  await api('PATCH', `/v1/appScreenshotSets/${set.id}/relationships/appScreenshots`, { data: ids.map((id) => ({ type: 'appScreenshots', id })) });
  // Apple processes uploads asynchronously; report how each one landed.
  await sleep(15000);
  const states = (await api('GET', `/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`)).data.map((s) => `${s.attributes.fileName}=${s.attributes.assetDeliveryState?.state}`);
  console.log(`${type}: ${ids.length} uploaded — ${states.join(', ')}`);
}
