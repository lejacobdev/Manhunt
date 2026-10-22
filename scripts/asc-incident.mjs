// Incident response for the October 2026 GhostAction credential theft (see the repo's incident notes).
//
//   node scripts/asc-incident.mjs audit
//       Read-only. What an attacker holding the stolen App Store Connect key could have changed:
//       certificates (with creation dates), users and pending invitations, apps, and every build
//       uploaded since 2026-09-01.
//
//   node scripts/asc-incident.mjs rotate-cert <csr.pem path> <comma-separated certificate ids to revoke>
//       Creates a new Apple Distribution certificate from a CSR whose private key never leaves the
//       machine that made it, prints the new certificate (public data) between markers, then
//       revokes the listed certificates. Revoking a distribution certificate does not affect apps
//       already on the App Store or builds already in TestFlight.
//
// Credentials come from KEY_ID, ISSUER_ID and KEY_PATH. This runs in a PUBLIC repo's Actions, so
// email addresses are masked and nothing secret is printed.

import crypto from 'node:crypto';
import fs from 'node:fs';

const [mode, ...rest] = process.argv.slice(2);
const API = 'https://api.appstoreconnect.apple.com';

function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const input =
    b64({ alg: 'ES256', kid: process.env.KEY_ID, typ: 'JWT' }) + '.' +
    b64({ iss: process.env.ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' });
  const sig = crypto.sign('sha256', Buffer.from(input), {
    key: fs.readFileSync(process.env.KEY_PATH), dsaEncoding: 'ieee-p1363',
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

async function listAll(url) {
  const out = [];
  let next = url + (url.includes('?') ? '&' : '?') + 'limit=200';
  while (next) {
    const r = await api('GET', next);
    if (!r.ok) { console.log(`  FAILED ${url}: HTTP ${r.status} ${r.text.slice(0, 200)}`); return out; }
    out.push(...(r.json.data || []));
    next = r.json.links && r.json.links.next;
  }
  return out;
}

const mask = (email) => {
  if (!email || !email.includes('@')) return '(none)';
  const [u, d] = email.split('@');
  return `${u[0]}***@${d}`;
};

async function audit() {
  console.log('== Certificates (created = expiry minus one year) ==');
  const certs = await listAll('/v1/certificates');
  for (const c of certs.sort((a, b) => a.attributes.expirationDate.localeCompare(b.attributes.expirationDate))) {
    const made = new Date(c.attributes.expirationDate); made.setFullYear(made.getFullYear() - 1);
    const flag = made >= new Date('2026-09-23') ? '  <-- created after the last known CI build' : '';
    console.log(`  ${made.toISOString().slice(0, 16)}  ${c.attributes.certificateType.padEnd(22)} ${c.id}  ${c.attributes.name}${flag}`);
  }

  console.log('\n== Users ==');
  for (const u of await listAll('/v1/users')) {
    console.log(`  ${mask(u.attributes.username)}  roles=${(u.attributes.roles || []).join(',')}  allApps=${u.attributes.allAppsVisible}`);
  }
  console.log('\n== Pending invitations (an attacker with an Admin key could add a user this way) ==');
  const inv = await listAll('/v1/userInvitations');
  if (inv.length === 0) console.log('  none');
  for (const i of inv) {
    console.log(`  ${mask(i.attributes.email)}  roles=${(i.attributes.roles || []).join(',')}  expires=${i.attributes.expirationDate}`);
  }

  console.log('\n== Apps, and builds uploaded since 2026-09-01 ==');
  for (const a of await listAll('/v1/apps')) {
    console.log(`  APP ${a.attributes.name}  (${a.attributes.bundleId})`);
    const builds = await listAll(`/v1/builds?filter[app]=${a.id}&sort=-uploadedDate`);
    const recent = builds.filter((b) => b.attributes.uploadedDate >= '2026-09-01');
    if (recent.length === 0) console.log('    no builds since 2026-09-01');
    for (const b of recent) {
      console.log(`    build ${b.attributes.version}  uploaded ${b.attributes.uploadedDate}  ${b.attributes.processingState}`);
    }
  }
}

async function rotateCert(csrPath, revokeCsv) {
  const csr = fs.readFileSync(csrPath, 'utf8')
    .replace(/-----BEGIN CERTIFICATE REQUEST-----|-----END CERTIFICATE REQUEST-----|\s/g, '');
  const made = await api('POST', '/v1/certificates', {
    data: { type: 'certificates', attributes: { certificateType: 'DISTRIBUTION', csrContent: csr } },
  });
  console.log(`create DISTRIBUTION certificate: HTTP ${made.status}`);
  if (!made.ok) {
    console.log(made.text.slice(0, 600));
    process.exit(1);
  }
  const cert = made.json.data;
  console.log(`new certificate ${cert.id}  ${cert.attributes.name}  expires ${cert.attributes.expirationDate}`);
  // Public data: the certificate itself, never the private key (which stays where the CSR was made).
  console.log('NEW_CERT_BEGIN');
  console.log(cert.attributes.certificateContent);
  console.log('NEW_CERT_END');

  for (const id of (revokeCsv || '').split(',').map((s) => s.trim()).filter(Boolean)) {
    if (id === cert.id) { console.log(`skip ${id}: that is the new certificate`); continue; }
    const r = await api('DELETE', `/v1/certificates/${id}`);
    console.log(`revoke ${id}: HTTP ${r.status}${r.ok ? '' : ' ' + r.text.slice(0, 300)}`);
  }
}

if (mode === 'audit') await audit();
else if (mode === 'rotate-cert') await rotateCert(rest[0], rest[1]);
else { console.error('usage: asc-incident.mjs audit | rotate-cert <csr.pem> <ids>'); process.exit(2); }
