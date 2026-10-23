// Uploads one image as the App Review screenshot of every cosmetic in-app purchase that doesn't
// have one yet.   node scripts/asc-iap-screenshot.mjs <png>   (KEY_ID, ISSUER_ID, KEY_PATH)
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const APP_ID = '6809603844';
const file = process.argv[2];
const bytes = fs.readFileSync(file);
const md5 = crypto.createHash('md5').update(bytes).digest('hex');

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

const iaps = (await api('GET', `/v1/apps/${APP_ID}/inAppPurchasesV2?limit=50`)).data.filter((i) => i.attributes.productId.startsWith('com.huntinggame.app.'));
for (const iap of iaps) {
  try {
    const existing = await api('GET', `/v2/inAppPurchases/${iap.id}/appStoreReviewScreenshot`).catch(() => null);
    if (existing?.data) { console.log(`${iap.attributes.productId}: already has a review screenshot`); continue; }
    const res = (await api('POST', '/v1/inAppPurchaseAppStoreReviewScreenshots', { data: { type: 'inAppPurchaseAppStoreReviewScreenshots',
      attributes: { fileName: path.basename(file), fileSize: bytes.length },
      relationships: { inAppPurchaseV2: { data: { type: 'inAppPurchases', id: iap.id } } } } })).data;
    for (const op of res.attributes.uploadOperations) {
      const headers = Object.fromEntries((op.requestHeaders ?? []).map((h) => [h.name, h.value]));
      const r = await fetch(op.url, { method: op.method, headers, body: bytes.subarray(op.offset, op.offset + op.length) });
      if (!r.ok) throw new Error(`upload part -> ${r.status}`);
    }
    await api('PATCH', `/v1/inAppPurchaseAppStoreReviewScreenshots/${res.id}`, { data: { type: 'inAppPurchaseAppStoreReviewScreenshots', id: res.id, attributes: { uploaded: true, sourceFileChecksum: md5 } } });
    await new Promise((r) => setTimeout(r, 4000));
    const state = (await api('GET', `/v2/inAppPurchases/${iap.id}`)).data.attributes.state;
    console.log(`${iap.attributes.productId}: screenshot uploaded, state ${state}`);
  } catch (e) { console.log(`${iap.attributes.productId}: FAILED ${e.message}`); }
}
