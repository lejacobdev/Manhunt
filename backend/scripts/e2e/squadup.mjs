// End-to-end test of 1.2's group features against the throwaway backend on 127.0.0.1:4555 (see
// README.md): invite links and their landing page, Universal Links, lobby previews, rematches
// (roles carried over, one lobby however many tap), report screenshots, and the Recruiter badge.
import { io } from 'socket.io-client';
import { execFileSync } from 'node:child_process';

const API = process.env.API ?? 'http://127.0.0.1:4555';
const C = { lat: 50.9375, lng: 6.9603 };
const m = (dn, de) => ({ lat: C.lat + dn / 111320, lng: C.lng + de / (111320 * Math.cos((C.lat * Math.PI) / 180)) });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, label, extra = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${extra ? '  — ' + extra : ''}`); if (!ok) failures++; };
const sql = (q) => execFileSync('docker', ['exec', 'hgtest-db', 'psql', '-U', 't', '-d', 't', '-tAc', q]).toString().trim();
async function waitFor(fn, ms = 10_000, step = 200) { const end = Date.now() + ms; while (Date.now() < end) { if (fn()) return true; await sleep(step); } return !!fn(); }

async function req(method, path, body, token) {
  const r = await fetch(API + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let json = {};
  try { json = JSON.parse(text); } catch {}
  return { status: r.status, body: json, text, headers: r.headers };
}
const sfx = Date.now().toString(36).slice(-4);
let n = 0;
async function account(name) {
  const r = await req('POST', '/auth/register', { username: `${name}${sfx}${n++}`, password: 'Testpass123!' });
  if (r.status !== 201) throw new Error(JSON.stringify(r.body));
  return { name, token: r.body.token, user: r.body.user };
}
function listen(p) {
  const s = io(API, { auth: { token: p.token }, transports: ['websocket'], forceNew: true });
  p.socket = s; p.ev = [];
  for (const e of ['game_invite', 'rematch_ready', 'game_over']) s.on(e, (d) => p.ev.push({ e, d }));
  return new Promise((res) => s.on('connect', res));
}
const got = (p, e, pred = () => true) => p.ev.some((x) => x.e === e && pred(x.d));

/** A started-and-ended match: host plus players, roles as given. Returns its code. */
async function playedMatch(host, players, { mode = 'STANDARD', end = true } = {}) {
  const bounds = [m(-300, -300), m(-300, 300), m(300, 300), m(300, -300)];
  const c = await req('POST', '/games', { durationMinutes: 20, boundsPolygon: bounds, role: host.role, mode, headStartSeconds: 30 }, host.token);
  if (c.status !== 201) throw new Error('create ' + JSON.stringify(c.body));
  host.gp = c.body.player;
  const code = c.body.session.code;
  for (const p of players) {
    const j = await req('POST', `/games/${code}/join`, { role: 'RUNNER' }, p.token);
    p.gp = j.body.player;
  }
  for (const p of [host, ...players]) sql(`UPDATE "GamePlayer" SET role='${p.role}' WHERE id='${p.gp.id}'`);
  await req('PATCH', `/games/${code}/settings`, { radarIntervalSeconds: 45 }, host.token);
  const st = await req('POST', `/games/${code}/start`, {}, host.token);
  if (st.status !== 200) throw new Error('start ' + JSON.stringify(st.body));
  if (end) await req('POST', `/games/${code}/end`, {}, host.token);
  return code;
}

// ------------------------------------------------------------------ Universal Links
{
  const r = await req('GET', '/.well-known/apple-app-site-association');
  const details = r.body?.applinks?.details?.[0];
  check(r.status === 200 && /json/.test(r.headers.get('content-type') ?? ''), 'apple-app-site-association is served as JSON', `${r.status}`);
  check(details?.appIDs?.[0] === 'TESTTEAM01.com.huntinggame.app', 'it names this app by team and bundle id', details?.appIDs?.[0]);
  const paths = (details?.components ?? []).map((c) => c['/']);
  check(paths.includes('/j/*') && paths.includes('/u/*/*'), 'invite and friend links are claimed', paths.join(' '));
}

// ------------------------------------------------------------------ lobby, preview, landing page
const host = await account('host'); host.role = 'HUNTER';
const r1 = await account('run'); r1.role = 'RUNNER';
const r2 = await account('run'); r2.role = 'RUNNER';
const outsider = await account('out');
{
  const c = await req('POST', '/games', { durationMinutes: 20, boundsPolygon: [], role: 'RUNNER', mode: 'STANDARD' }, host.token);
  const code = c.body.session.code;
  await req('POST', `/games/${code}/join`, { role: 'RUNNER' }, r1.token);

  const pv = await req('GET', `/games/${code.toLowerCase()}/preview`, null, outsider.token);
  check(pv.status === 200 && pv.body.hostUsername === host.user.username && pv.body.playerCount === 2 && pv.body.isMember === false && pv.body.status === 'LOBBY',
    'preview: host, player count, not a member (and the code is case-insensitive)', JSON.stringify(pv.body));
  check(!('settings' in pv.body) && !JSON.stringify(pv.body).includes('lat'), 'preview reveals nothing about where the game is');
  const pvMember = await req('GET', `/games/${code}/preview`, null, r1.token);
  check(pvMember.body.isMember === true, 'preview knows when you are already in');
  check((await req('GET', '/games/ZZZZ9/preview', null, outsider.token)).status === 404, 'preview of an unknown code is a 404');
  check((await req('GET', `/games/${code}/preview`)).status === 401, 'preview needs a signed-in player');

  const page = await req('GET', `/j/${code.toLowerCase()}`);
  check(page.status === 200 && page.text.includes(code) && page.text.includes(host.user.username) && page.text.includes('2 players'),
    'landing page shows the code, the host and how many are in');
  check(page.text.includes(`huntinggame://join?code=${code}`) && page.text.includes('apps.apple.com'), 'landing page links into the app and to the App Store');
  check(!page.text.includes('location.replace'), 'landing page never jumps to the app on its own (no Safari error without it)');
  check(page.text.includes(`app-argument=huntinggame://join?code=${code}`), 'Smart App Banner carries the join link');
  const missing = await req('GET', '/j/NOPE99');
  check(missing.status === 200 && missing.text.includes("doesn&#39;t exist") && !missing.text.includes('huntinggame://join'), 'unknown code: says so, no join button');
  const xss = await req('GET', '/j/%3Cscript%3E');
  check(!xss.text.includes('<script>alert') && !/<script>[^<]*SCRIPT/.test(xss.text), 'landing page is not an injection vector');
}

// ------------------------------------------------------------------ rematch
{
  for (const p of [host, r1, r2]) await listen(p);
  const code = await playedMatch(host, [r1, r2]);
  for (const p of [host, r1, r2]) p.socket.emit('join_room', { roomCode: code, gamePlayerId: p.gp.id });
  await sleep(600);

  const early = await req('POST', `/games/${code}/rematch`, {}, outsider.token);
  check(early.status === 403, 'a stranger cannot start a rematch', `${early.status}`);

  // The runner asks first, so the runner hosts the rematch.
  const a = await req('POST', `/games/${code}/rematch`, {}, r1.token);
  check(a.status === 201 && a.body.session.code !== code && a.body.session.hostId === r1.user.id, 'first tap creates the rematch, hosted by whoever tapped', `${a.status}`);
  const next = a.body.session.code;
  check(a.body.player.role === 'RUNNER', 'they start in their old role (runner)');
  const s = a.body.session.settings;
  check(s.durationMinutes === 20 && s.boundsPolygon.length === 4 && s.radarIntervalSeconds === 45 && s.headStartSeconds === 30 && a.body.session.mode === 'STANDARD',
    'same mode, length, play area, radar ping and head start', JSON.stringify({ d: s.durationMinutes, b: s.boundsPolygon.length, r: s.radarIntervalSeconds, h: s.headStartSeconds }));
  check(Number(sql(`SELECT COUNT(*) FROM "PowerUpSpawn" s JOIN "GameSession" g ON g.id=s."sessionId" WHERE g.code='${next}'`)) > 0, 'power-ups are laid out in the rematch play area');

  check(await waitFor(() => got(host, 'rematch_ready', (d) => d.code === next) && got(r2, 'rematch_ready', (d) => d.code === next)), 'everyone on the results screen hears rematch_ready');
  check(got(host, 'game_invite', (d) => d.sessionCode === next) && got(r2, 'game_invite', (d) => d.sessionCode === next), 'everyone else gets an ordinary invite (works on older apps)');
  check(!got(r1, 'game_invite', (d) => d.sessionCode === next), 'the rematch host is not invited to their own lobby');
  const inc = await req('GET', '/invites/incoming', null, r2.token);
  check((inc.body.invites ?? []).some((i) => i.sessionCode === next || i.session?.code === next), 'the invite is in the invites list for later');

  // Simultaneous taps land in the same lobby.
  const [b, c] = await Promise.all([req('POST', `/games/${code}/rematch`, {}, host.token), req('POST', `/games/${code}/rematch`, {}, r2.token)]);
  check(b.status === 200 && c.status === 200 && b.body.session.code === next && c.body.session.code === next, 'two more taps at once: both join the same rematch', `${b.body.session?.code} ${c.body.session?.code}`);
  check(b.body.player.role === 'HUNTER', 'the hunter comes back as a hunter', b.body.player.role);
  check(Number(sql(`SELECT COUNT(*) FROM "GamePlayer" p JOIN "GameSession" g ON g.id=p."sessionId" WHERE g.code='${next}'`)) === 3, 'exactly three players in the rematch, no duplicates');
  const again = await req('POST', `/games/${code}/rematch`, {}, host.token);
  check(again.status === 200 && again.body.session.code === next && again.body.player.id === b.body.player.id, 'asking again just returns your place in it');

  // Joining the rematch by its code (an older app via the invite) also restores the role.
  const late = await account('late');
  sql(`INSERT INTO "GamePlayer"(id,"sessionId","userId",role,"arrestCode") SELECT gen_random_uuid(), id, '${late.user.id}', 'HUNTER', '1234' FROM "GameSession" WHERE code='${code}'`);
  const j = await req('POST', `/games/${next}/join`, { role: 'RUNNER' }, late.token);
  check(j.status === 201 && j.body.player.role === 'HUNTER', 'joining a rematch by code restores your old role too', j.body.player?.role);
  const fresh = await req('POST', `/games/${next}/join`, { role: 'RUNNER' }, outsider.token);
  check(fresh.status === 201 && fresh.body.player.role === 'RUNNER', 'someone new to the group joins as asked');

  // Once the rematch starts, latecomers are told so.
  sql(`UPDATE "GameSession" SET status='ACTIVE' WHERE code='${next}'`);
  const tooLate = await req('POST', `/games/${code}/rematch`, {}, (await (async () => { const x = await account('x'); sql(`INSERT INTO "GamePlayer"(id,"sessionId","userId",role,"arrestCode") SELECT gen_random_uuid(), id, '${x.user.id}', 'RUNNER', '1' FROM "GameSession" WHERE code='${code}'`); return x; })()).token);
  check(tooLate.status === 409, 'a rematch that already started says so', `${tooLate.status} ${tooLate.body.error}`);

  const running = await playedMatch(host, [r1], { end: false });
  check((await req('POST', `/games/${running}/rematch`, {}, host.token)).status === 409, 'no rematch while the match is still going');
  await req('POST', `/games/${running}/end`, {}, host.token);
  for (const p of [host, r1, r2]) p.socket.close();
}

// Infection: a runner who was turned comes back as a runner.
{
  const h = await account('ih'); h.role = 'HUNTER';
  const r = await account('ir'); r.role = 'RUNNER';
  const code = await playedMatch(h, [r], { mode: 'INFECTION' });
  const sid = sql(`SELECT id FROM "GameSession" WHERE code='${code}'`);
  sql(`UPDATE "GamePlayer" SET role='HUNTER' WHERE id='${r.gp.id}'`);
  sql(`INSERT INTO "GameEvent"(id,"sessionId",type,payload) VALUES (gen_random_uuid(),'${sid}','INFECTED','{"playerId":"${r.gp.id}","byPlayerId":"${h.gp.id}"}')`);
  const x = await req('POST', `/games/${code}/rematch`, {}, r.token);
  check(x.status === 201 && x.body.player.role === 'RUNNER' && x.body.session.mode === 'INFECTION', 'Infection rematch: a turned runner starts as a runner again', x.body.player?.role);
}

// A blocked player is not invited.
{
  const h = await account('bh'); h.role = 'HUNTER';
  const r = await account('br'); r.role = 'RUNNER';
  await listen(r);
  sql(`INSERT INTO "Friendship"(id,"senderId","receiverId",status,"createdAt","updatedAt") VALUES (gen_random_uuid(),'${r.user.id}','${h.user.id}','BLOCKED',now(),now())`);
  const code = await playedMatch(h, [r]);
  const x = await req('POST', `/games/${code}/rematch`, {}, h.token);
  await sleep(500);
  check(x.status === 201 && !got(r, 'game_invite') && Number(sql(`SELECT COUNT(*) FROM "GameInvite" WHERE "toUserId"='${r.user.id}'`)) === 0, 'no rematch invite to someone who blocked you');
  r.socket.close();
}

// ------------------------------------------------------------------ report screenshots
{
  const reporter = await account('rep');
  const target = await account('tgt');
  const admin = await account('adm');
  sql(`UPDATE "User" SET "isAdmin"=true WHERE id='${admin.user.id}'`);
  const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(200_000, 7), Buffer.from([0xff, 0xd9])]);
  const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(100, 1)]);
  const att = (buf, mime = 'image/jpeg') => ({ mime, data: buf.toString('base64') });

  const ok = await req('POST', `/friends/${target.user.id}/report`, { category: 'HARASSMENT', attachments: [att(jpeg), att(png, 'image/png')] }, reporter.token);
  check(ok.status === 201, 'a report with two screenshots (~270 kB body) is accepted', `${ok.status} ${ok.body.error ?? ''}`);
  check(!JSON.stringify(ok.body).includes(jpeg.toString('base64').slice(0, 40)), 'the response does not echo the images back');
  const plain = await req('POST', `/friends/${target.user.id}/report`, { category: 'CHEATING' }, reporter.token);
  check(plain.status === 201, 'a report without screenshots still works (older apps)');
  const fake = await req('POST', `/friends/${target.user.id}/report`, { category: 'CHEATING', attachments: [att(Buffer.from('<html>not an image</html>'))] }, reporter.token);
  check(fake.status === 400, 'something that is not an image is refused', fake.body.error);
  const mismatch = await req('POST', `/friends/${target.user.id}/report`, { category: 'CHEATING', attachments: [att(png, 'image/jpeg')] }, reporter.token);
  check(mismatch.status === 400, 'a PNG labelled as JPEG is refused');
  const four = await req('POST', `/friends/${target.user.id}/report`, { category: 'CHEATING', attachments: [att(png, 'image/png'), att(png, 'image/png'), att(png, 'image/png'), att(png, 'image/png')] }, reporter.token);
  check(four.status === 400, 'more than three screenshots is refused');
  const huge = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(2_200_000, 1)]);
  const big = await req('POST', `/friends/${target.user.id}/report`, { category: 'CHEATING', attachments: [att(huge)] }, reporter.token);
  check(big.status === 400, 'a screenshot over 2 MB is refused', `${big.status}`);
  const otherRoute = await req('POST', '/friends/requests', { username: 'x'.repeat(200_000), tag: '1' }, reporter.token);
  check(otherRoute.status === 413, 'other routes keep the small body limit', `${otherRoute.status}`);

  const list = await req('GET', '/admin/reports?status=ALL', null, admin.token);
  const filed = (list.body.reports ?? []).find((r) => r.id === ok.body.report.id);
  check(filed?.attachments?.length === 2 && filed.attachments[0].mime === 'image/jpeg' && !('data' in filed.attachments[0]), 'admin list shows two screenshots by id, without the bytes');
  const img = await fetch(`${API}/admin/reports/${filed.id}/attachments/${filed.attachments[0].id}`, { headers: { Authorization: 'Bearer ' + admin.token } });
  const bytes = Buffer.from(await img.arrayBuffer());
  check(img.status === 200 && img.headers.get('content-type') === 'image/jpeg' && bytes.equals(jpeg), 'admin can open the screenshot, byte for byte');
  check(/no-store/.test(img.headers.get('cache-control') ?? ''), 'screenshots are never cached');
  const notAdmin = await fetch(`${API}/admin/reports/${filed.id}/attachments/${filed.attachments[0].id}`, { headers: { Authorization: 'Bearer ' + reporter.token } });
  check(notAdmin.status === 403 || notAdmin.status === 404, 'nobody but an admin can open them', `${notAdmin.status}`);
  const wrongReport = await fetch(`${API}/admin/reports/${plain.body.report.id}/attachments/${filed.attachments[0].id}`, { headers: { Authorization: 'Bearer ' + admin.token } });
  check(wrongReport.status === 404, 'a screenshot is only reachable through its own report');
}

// ------------------------------------------------------------------ Recruiter badge
{
  const recruiter = await account('rec'); recruiter.role = 'HUNTER';
  const newbies = [await account('nb'), await account('nb'), await account('nb')];
  newbies.forEach((p) => (p.role = 'RUNNER'));
  const veteran = await account('vet'); veteran.role = 'RUNNER';
  // The veteran's first match was elsewhere, so they don't count.
  const other = await account('oth'); other.role = 'HUNTER';
  await playedMatch(other, [veteran]);
  await playedMatch(recruiter, [newbies[0], newbies[1], veteran]);
  let snap = await req('GET', '/cosmetics', null, recruiter.token);
  let badge = snap.body.items.find((i) => i.id === 'badge.recruiter');
  check(badge && badge.owned === false && badge.progress === 2 && badge.goal === 3, 'Recruiter counts only players whose first match you hosted (2 of 3)', JSON.stringify(badge));
  await playedMatch(recruiter, [newbies[2], newbies[0]]);
  snap = await req('GET', '/cosmetics', null, recruiter.token);
  badge = snap.body.items.find((i) => i.id === 'badge.recruiter');
  check(badge?.owned === true, 'third new player unlocks the Recruiter badge', JSON.stringify(badge));
  const eq = await req('POST', '/cosmetics/equip', { category: 'badge', itemId: 'badge.recruiter' }, recruiter.token);
  check(eq.status === 200 && eq.body.equipped.badge === 'badge.recruiter', 'and it can be worn');
}

console.log(failures ? `\n${failures} FAILED` : '\nALL PASSED');
process.exit(failures ? 1 : 0);
