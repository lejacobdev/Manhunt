// Prints every App Review submission of the app: when it was submitted, its state now, and the version
// it carried. App Store Connect records no "review finished" time in the API; the approval moment has
// to come from elsewhere (the server's logs, or when the version went live).
//   node scripts/asc-review-history.mjs   (KEY_ID, ISSUER_ID, KEY_PATH)
import crypto from 'node:crypto';
import fs from 'node:fs';

const APP_ID = '6809603844';

function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const input = b64({ alg: 'ES256', kid: process.env.KEY_ID, typ: 'JWT' }) + '.' + b64({ iss: process.env.ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' });
  return input + '.' + crypto.sign('sha256', Buffer.from(input), { key: fs.readFileSync(process.env.KEY_PATH), dsaEncoding: 'ieee-p1363' }).toString('base64url');
}
async function api(p) {
  const r = await fetch('https://api.appstoreconnect.apple.com' + p, { headers: { Authorization: 'Bearer ' + jwt() } });
  const t = await r.text();
  if (!r.ok) throw new Error(`GET ${p} -> ${r.status} ${t.slice(0, 400)}`);
  return JSON.parse(t);
}

const versions = (await api(`/v1/apps/${APP_ID}/appStoreVersions?filter[platform]=IOS&limit=50`)).data;
for (const v of versions) {
  console.log(`VERSION ${v.attributes.versionString}  state=${v.attributes.appStoreState}  created=${v.attributes.createdDate}`);
}
const subs = await api(`/v1/reviewSubmissions?filter[app]=${APP_ID}&limit=50&include=items,appStoreVersionForReview`);
const byId = Object.fromEntries((subs.included ?? []).map((i) => [`${i.type}/${i.id}`, i]));
for (const s of subs.data.sort((a, b) => String(a.attributes.submittedDate).localeCompare(String(b.attributes.submittedDate)))) {
  const vRef = s.relationships?.appStoreVersionForReview?.data;
  const v = vRef && (byId[`${vRef.type}/${vRef.id}`] ?? versions.find((x) => x.id === vRef.id));
  const items = [];
  for (const ref of s.relationships?.items?.data ?? []) {
    const item = byId[`${ref.type}/${ref.id}`];
    if (item) items.push(item.attributes?.state);
  }
  console.log(`SUBMISSION ${s.id}  submitted=${s.attributes.submittedDate}  state=${s.attributes.state}  version=${v?.attributes?.versionString ?? '-'}  items=${items.join(',')}`);
}
