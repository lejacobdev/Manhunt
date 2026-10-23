// Creates Hunting Game's cosmetic in-app purchases in App Store Connect (idempotent: existing
// products are left alone) and points App Store Server Notifications V2 at the backend.
// Credentials: KEY_ID, ISSUER_ID, KEY_PATH. Public repo: prints ids and states only.
import crypto from 'node:crypto';
import fs from 'node:fs';

const APP_ID = '6809603844';
const NOTIFY_URL = 'https://api.lejacob.dev/cosmetics/app-store-notifications';
const PRODUCTS = [
  { productId: 'com.huntinggame.app.pack.maps', name: 'Map Pack', description: 'Satellite and Hybrid map styles.', usd: '0.99' },
  { productId: 'com.huntinggame.app.pack.radar', name: 'Radar Skins', description: 'Arctic, Gold and Mono radar sweeps.', usd: '0.99' },
  { productId: 'com.huntinggame.app.pack.markers', name: 'Marker Pack', description: 'Bolt, Flame, Star and Paw map markers.', usd: '0.99' },
  { productId: 'com.huntinggame.app.pack.banners', name: 'Banner Pack', description: 'Ember, Ice and Aurora profile banners.', usd: '0.99' },
  { productId: 'com.huntinggame.app.supporter', name: 'Supporter', description: 'Every pack, plus a Supporter badge, banner and radar.', usd: '4.99' },
];
const REVIEW_NOTE = 'Cosmetic only (looks, never gameplay). Find it under Profile > Customize; signing in with the demo account shows the store. Purchases are verified server-side.';

function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const input = b64({ alg: 'ES256', kid: process.env.KEY_ID, typ: 'JWT' }) + '.' + b64({ iss: process.env.ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' });
  return input + '.' + crypto.sign('sha256', Buffer.from(input), { key: fs.readFileSync(process.env.KEY_PATH), dsaEncoding: 'ieee-p1363' }).toString('base64url');
}
async function api(method, path, body) {
  const r = await fetch('https://api.appstoreconnect.apple.com' + path, {
    method, headers: { Authorization: 'Bearer ' + jwt(), ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let json = null; try { json = text ? JSON.parse(text) : null; } catch {}
  if (!r.ok) throw new Error(`${method} ${path} -> ${r.status} ${text.slice(0, 500)}`);
  return json;
}
async function all(path) {
  const out = []; let next = path + (path.includes('?') ? '&' : '?') + 'limit=200';
  while (next) { const j = await api('GET', next.replace('https://api.appstoreconnect.apple.com', '')); out.push(...j.data); next = j.links?.next; }
  return out;
}

// 1. Server notifications (refunds) — production and sandbox.
try {
  await api('PATCH', `/v1/apps/${APP_ID}`, { data: { type: 'apps', id: APP_ID, attributes: {
    subscriptionStatusUrl: NOTIFY_URL, subscriptionStatusUrlVersion: 'V2',
    subscriptionStatusUrlForSandbox: NOTIFY_URL, subscriptionStatusUrlVersionForSandbox: 'V2' } } });
  console.log('notifications: URL set (production + sandbox, V2)');
} catch (e) { console.log('notifications: FAILED', e.message); }

const territories = (await all('/v1/territories')).map((t) => ({ type: 'territories', id: t.id }));
const existing = await all(`/v1/apps/${APP_ID}/inAppPurchasesV2`);

for (const p of PRODUCTS) {
  try {
    let iap = existing.find((x) => x.attributes.productId === p.productId);
    if (!iap) {
      iap = (await api('POST', '/v2/inAppPurchases', { data: { type: 'inAppPurchases',
        attributes: { name: p.name, productId: p.productId, inAppPurchaseType: 'NON_CONSUMABLE', reviewNote: REVIEW_NOTE, familySharable: false },
        relationships: { app: { data: { type: 'apps', id: APP_ID } } } } })).data;
      console.log(`${p.productId}: created ${iap.id}`);
    } else console.log(`${p.productId}: exists ${iap.id} (${iap.attributes.state})`);
    const id = iap.id;

    const locs = await all(`/v2/inAppPurchases/${id}/inAppPurchaseLocalizations`);
    if (!locs.some((l) => l.attributes.locale === 'en-US')) {
      await api('POST', '/v1/inAppPurchaseLocalizations', { data: { type: 'inAppPurchaseLocalizations',
        attributes: { locale: 'en-US', name: p.name, description: p.description },
        relationships: { inAppPurchaseV2: { data: { type: 'inAppPurchases', id } } } } });
      console.log(`  localization added`);
    }

    try {
      const points = await all(`/v2/inAppPurchases/${id}/pricePoints?filter[territory]=USA`);
      const point = points.find((pt) => pt.attributes.customerPrice === p.usd);
      if (!point) throw new Error(`no USA price point ${p.usd}`);
      await api('POST', '/v1/inAppPurchasePriceSchedules', { data: { type: 'inAppPurchasePriceSchedules', relationships: {
          inAppPurchase: { data: { type: 'inAppPurchases', id } },
          baseTerritory: { data: { type: 'territories', id: 'USA' } },
          manualPrices: { data: [{ type: 'inAppPurchasePrices', id: '${price0}' }] } } },
        included: [{ type: 'inAppPurchasePrices', id: '${price0}', attributes: { startDate: null },
          relationships: { inAppPurchasePricePoint: { data: { type: 'inAppPurchasePricePoints', id: point.id } } } }] });
      console.log(`  price set: $${p.usd} (other countries follow Apple's equalization)`);
    } catch (e) { console.log('  price: FAILED', e.message); }

    try {
      await api('POST', '/v1/inAppPurchaseAvailabilities', { data: { type: 'inAppPurchaseAvailabilities',
        attributes: { availableInNewTerritories: true },
        relationships: { inAppPurchase: { data: { type: 'inAppPurchases', id } }, availableTerritories: { data: territories } } } });
      console.log(`  available in ${territories.length} territories`);
    } catch (e) { console.log('  availability:', e.message.includes('409') ? 'already set' : 'FAILED ' + e.message); }

    const fresh = (await api('GET', `/v2/inAppPurchases/${id}`)).data;
    console.log(`  state: ${fresh.attributes.state}`);
  } catch (e) { console.log(`${p.productId}: FAILED`, e.message); }
}
