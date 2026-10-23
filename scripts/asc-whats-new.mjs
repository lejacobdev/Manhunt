// Sets "What's New" on the iOS version being prepared for submission, from
// ios/HuntingGame/WhatsNew.txt (en-US). Credentials: KEY_ID, ISSUER_ID, KEY_PATH.
import crypto from 'node:crypto';
import fs from 'node:fs';

const APP_ID = '6809603844';
const text = fs.readFileSync('ios/HuntingGame/WhatsNew.txt', 'utf8').trim();
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
const versions = (await api('GET', `/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10`)).data;
const editable = versions.filter((v) => ['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED'].includes(v.attributes.appStoreState));
if (!editable.length) { console.log('No version is open for editing:', versions.map((v) => `${v.attributes.versionString}=${v.attributes.appStoreState}`).join(', ')); process.exit(1); }
for (const v of editable) {
  const locs = (await api('GET', `/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations`)).data;
  for (const l of locs) {
    if (l.attributes.locale !== 'en-US') { console.log(`${v.attributes.versionString} ${l.attributes.locale}: left alone (not English)`); continue; }
    await api('PATCH', `/v1/appStoreVersionLocalizations/${l.id}`, { data: { type: 'appStoreVersionLocalizations', id: l.id, attributes: { whatsNew: text } } });
    const check = (await api('GET', `/v1/appStoreVersionLocalizations/${l.id}`)).data.attributes.whatsNew;
    console.log(`${v.attributes.versionString} ${l.attributes.locale}: What's New set (${check.length} characters, matches: ${check === text})`);
  }
}
