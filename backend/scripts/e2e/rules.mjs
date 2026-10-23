// End-to-end test of the game rules (catches, disputes, jail, jailbreaks, modes, win conditions)
// against a throwaway backend on 127.0.0.1:4555 — see README.md. Every scenario is a real match
// played over Socket.IO by simulated players.
import { io } from 'socket.io-client';
import { execFileSync } from 'node:child_process';

const API = process.env.API ?? 'http://127.0.0.1:4555';
const C = { lat: 50.9375, lng: 6.9603 };
const m = (dn, de) => ({ lat: C.lat + dn / 111320, lng: C.lng + de / (111320 * Math.cos((C.lat * Math.PI) / 180)) });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, label, extra = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${extra ? '  — ' + extra : ''}`); if (!ok) failures++; };
const sql = (q) => execFileSync('docker', ['exec', 'hgtest-db', 'psql', '-U', 't', '-d', 't', '-tAc', q]).toString().trim();
async function waitFor(fn, ms = 35_000, step = 250) { const end = Date.now() + ms; while (Date.now() < end) { if (fn()) return true; await sleep(step); } return !!fn(); }

async function req(method, path, body, token) {
  const r = await fetch(API + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, body: await r.json().catch(() => ({})) };
}
const sfx = Date.now().toString(36).slice(-4);
let n = 0;
async function account(name) {
  const r = await req('POST', '/auth/register', { username: `${name}${sfx}${n++}`, password: 'Testpass123!' });
  if (r.status !== 201) throw new Error(JSON.stringify(r.body));
  return { name, token: r.body.token, user: r.body.user };
}
function connect(p) {
  const s = io(API, { auth: { token: p.token }, transports: ['websocket'], forceNew: true });
  p.socket = s; p.ev = [];
  for (const e of ['radar_broadcast', 'compass_update', 'player_jailed', 'player_caught', 'player_revived', 'player_infected', 'jail_arrived', 'jail_bailout',
    'hearts_update', 'catch_failed', 'catch_requested', 'catch_deny_confirm', 'catch_dispute', 'catch_dispute_pending', 'catch_ruling', 'game_over',
    'boundary_status', 'error_event', 'player_joined', 'player_eliminated', 'catch_request_expired']) {
    s.on(e, (d) => { p.ev.push({ e, d, at: Date.now() }); if (e === 'radar_broadcast') p.radar = d; if (e === 'compass_update') p.compass = d; });
  }
  return new Promise((res) => s.on('connect', res));
}
const last = (p, e) => [...p.ev].reverse().find((x) => x.e === e)?.d;
const got = (p, e, pred = () => true) => p.ev.some((x) => x.e === e && pred(x.d));
const move = (p, pos) => { p.pos = pos; p.socket.emit('send_location_update', { lat: pos.lat, lng: pos.lng, accuracy: 5, speed: 1, battery: 90, isMovingOnFoot: true }); };

async function match({ mode = 'STANDARD', host, players, jail = false, startExpect = 200 }) {
  const bounds = [m(-800, -800), m(-800, 800), m(800, 800), m(800, -800)];
  const body = { durationMinutes: 30, boundsPolygon: bounds, role: host.role, mode, ...(host.squad ? { squad: host.squad } : {}) };
  if (jail) Object.assign(body, { jailEnabled: true, jailPolygon: [m(-30, 780), m(-30, 860), m(30, 860), m(30, 780)], jailArrivalSeconds: 30, bailOutSeconds: 5 });
  const c = await req('POST', '/games', body, host.token);
  if (c.status !== 201) throw new Error('create ' + JSON.stringify(c.body));
  host.gp = c.body.player;
  const code = c.body.session.code, sessionId = c.body.session.id;
  for (const p of players) {
    const j = await req('POST', `/games/${code}/join`, { role: p.role, ...(p.squad ? { squad: p.squad } : {}) }, p.token);
    p.gp = j.body.player;
    // join assigns RUNNER; the host assigns roles in the lobby, so mirror that here.
    if (p.gp.role !== p.role) sql(`UPDATE "GamePlayer" SET role='${p.role}', hearts=${p.role === 'HUNTER' ? 5 : 3} WHERE id='${p.gp.id}'`);
  }
  if (host.gp.role !== host.role) sql(`UPDATE "GamePlayer" SET role='${host.role}', hearts=${host.role === 'HUNTER' ? 5 : host.role === 'RUNNER' ? 3 : 0} WHERE id='${host.gp.id}'`);
  sql(`DELETE FROM "PowerUpSpawn" WHERE "sessionId"='${sessionId}'`);
  const st = await req('POST', `/games/${code}/start`, {}, host.token);
  return { code, sessionId, start: st };
}
async function enter(m_, all) { for (const p of all) { await connect(p); p.socket.emit('join_room', { roomCode: m_.code, gamePlayerId: p.gp.id }); } await sleep(800); }
const done = (all) => all.forEach((p) => p.socket?.disconnect());

// ====================================================================== start checks
{
  const h = await account('host'); h.role = 'HUNTER';
  const h2 = await account('hb'); h2.role = 'HUNTER';
  const mm = await match({ host: h, players: [h2] });
  check(mm.start.status === 409 && /hunter and one runner/.test(mm.start.body.error), 'start: refused without a runner', mm.start.body.error);
  const a = await account('sa'); a.role = 'HUNTER'; a.squad = 'red';
  const b = await account('sb'); b.role = 'RUNNER'; b.squad = 'red';
  const ms = await match({ mode: 'SQUAD', host: a, players: [b] });
  check(ms.start.status === 409 && /two squads/.test(ms.start.body.error), 'start: Squad mode refused with one squad', ms.start.body.error);
}

// ====================================================================== standard + jail
{
  const S = await account('ref'); S.role = 'SPECTATOR';
  const H1 = await account('h1'); H1.role = 'HUNTER';
  const H2 = await account('h2'); H2.role = 'HUNTER';
  const R1 = await account('r1'); R1.role = 'RUNNER';
  const R2 = await account('r2'); R2.role = 'RUNNER';
  const R3 = await account('r3'); R3.role = 'RUNNER';
  const all = [S, H1, H2, R1, R2, R3];
  const mm = await match({ host: S, players: [H1, H2, R1, R2, R3], jail: true });
  check(mm.start.status === 200, 'jail match starts', mm.start.body.error ?? '');
  await enter(mm, all);
  move(S, m(0, -500)); move(H1, m(0, 0)); move(H2, m(300, 0)); move(R1, m(0, 5)); move(R2, m(300, 6)); move(R3, m(-300, 0));
  await sleep(1200);

  // Privacy
  check((H1.radar?.runners ?? []).every((r) => r.lat === 0 && r.lng === 0 && r.arrestCode === ''), 'privacy: radar contacts carry no coordinates or arrest codes');
  const roster = last(H1, 'player_joined') ?? [];
  check(roster.filter((p) => p.role === 'RUNNER').every((p) => p.lat === 0 && p.arrestCode === ''), "privacy: a hunter's roster hides runners' positions and codes");

  // 1. Silence is not an escape
  H1.socket.emit('request_catch', { runnerId: R1.gp.id });
  await waitFor(() => got(R1, 'catch_requested'), 3000);
  check(got(R1, 'catch_requested'), 'catch: runner A is asked');
  const jailed = await waitFor(() => got(R1, 'player_jailed', (d) => d.runnerId === R1.gp.id), 35_000);
  check(jailed, 'catch: runner A never answers — after 20 s the catch stands and they are sentenced to jail');
  check(got(R1, 'hearts_update', (d) => d.playerId === R1.gp.id && d.hearts === 2), 'catch: it cost runner A a heart (3 → 2)');
  check(got(R1, 'catch_ruling', (d) => /No answer/.test(d.message)), 'catch: runner A is told why');

  // 2. Dispute: host rules "not a catch", then "catch"
  H2.socket.emit('request_catch', { runnerId: R2.gp.id });
  await waitFor(() => got(R2, 'catch_requested'), 3000);
  R2.socket.emit('respond_catch', { hunterId: H2.gp.id, decision: 'deny' });
  await waitFor(() => got(H2, 'catch_deny_confirm'), 3000);
  check(got(H2, 'catch_deny_confirm'), 'dispute: hunter B is told runner B denies it');
  H2.socket.emit('catch_dispute', { requestId: last(H2, 'catch_deny_confirm').requestId });
  await waitFor(() => got(S, 'catch_dispute'), 3000);
  check(got(S, 'catch_dispute', (d) => d.runnerUsername === R2.user.username), 'dispute: the host is asked to rule');
  S.socket.emit('resolve_dispute', { disputeId: last(S, 'catch_dispute').disputeId, catchStands: false });
  await waitFor(() => got(H2, 'catch_failed', (d) => /host ruled/.test(d.reason)), 3000);
  check(got(H2, 'catch_failed', (d) => /host ruled/.test(d.reason)) && !got(R2, 'player_jailed', (d) => d.runnerId === R2.gp.id), 'dispute: host says no catch — runner B stays free', JSON.stringify(H2.ev.filter((x) => x.e === 'catch_failed').map((x) => x.d)));
  H2.socket.emit('request_catch', { runnerId: R2.gp.id });
  await waitFor(() => R2.ev.filter((x) => x.e === 'catch_requested').length >= 2, 3000);
  R2.socket.emit('respond_catch', { hunterId: H2.gp.id, decision: 'deny' });
  await waitFor(() => H2.ev.filter((x) => x.e === 'catch_deny_confirm').length >= 2, 3000);
  H2.socket.emit('catch_dispute', { requestId: last(H2, 'catch_deny_confirm').requestId });
  await waitFor(() => S.ev.filter((x) => x.e === 'catch_dispute').length >= 2, 3000);
  S.socket.emit('resolve_dispute', { disputeId: last(S, 'catch_dispute').disputeId, catchStands: true });
  check(await waitFor(() => got(R2, 'player_jailed', (d) => d.runnerId === R2.gp.id), 3000), 'dispute: host says catch — runner B is sentenced');

  // 3. Power-ups while sentenced
  const sp = sql(`INSERT INTO "PowerUpSpawn"(id,"sessionId",type,latitude,longitude,"isCollected","spawnedAt","expiresAt") VALUES (gen_random_uuid(),'${mm.sessionId}','INVISIBILITY_10MIN',${R1.pos.lat},${R1.pos.lng},false,now(),now()+interval '1 hour') RETURNING id`).split('\n')[0];
  R1.socket.emit('collect_powerup', { spawnId: sp });
  await sleep(600);
  check(got(R1, 'error_event', (d) => /while caught/.test(d.reason)), "pickup: a sentenced runner can't collect power-ups");

  // 4. Reconnecting doesn't skip the walk to jail
  R2.socket.disconnect(); await sleep(500);
  R2.ev = []; await connect(R2); R2.socket.emit('join_room', { roomCode: mm.code, gamePlayerId: R2.gp.id });
  check(await waitFor(() => got(R2, 'player_jailed', (d) => d.runnerId === R2.gp.id && d.arrivalDeadlineMs > 0), 3000), 'reconnect: a sentenced runner who rejoins gets a fresh walk to jail, not a free arrival');

  // 5. Both prisoners walk into the jail
  move(R1, m(0, 820)); move(R2, m(5, 825));
  check(await waitFor(() => got(R1, 'jail_arrived') && got(R2, 'jail_arrived'), 4000), 'jail: both prisoners arrive');

  // 6. The jail is neutral ground for the zone and boundary
  move(R3, m(0, 845)); // inside the jail, outside the play area
  await sleep(1500);
  check(!got(R3, 'boundary_status', (d) => d.outside), 'zone: standing in the jail (outside the play area) drains no hearts');
  // Flare refused at the jail
  const fl = sql(`INSERT INTO "PowerUpSpawn"(id,"sessionId",type,latitude,longitude,"isCollected","spawnedAt","expiresAt") VALUES (gen_random_uuid(),'${mm.sessionId}','SAFE_ZONE_FLARE',${R3.pos.lat},${R3.pos.lng},false,now(),now()+interval '1 hour') RETURNING id`).split('\n')[0];
  R3.socket.emit('collect_powerup', { spawnId: fl }); await sleep(500);
  R3.socket.emit('use_powerup', { powerUpType: 'SAFE_ZONE_FLARE' }); await sleep(600);
  check(got(R3, 'error_event', (d) => /don't work at the jail/.test(d.reason)), 'flare: refused at the jail (it made jailbreaks risk-free)');

  // 7. Jailbreak: runner C holds the jail for 5 s
  H1.ev = []; R1.ev = [];
  for (let i = 0; i < 9 && !got(R1, 'jail_bailout'); i++) { move(R3, m(0, 840 + (i % 2))); await sleep(1000); }
  const bail = last(R1, 'jail_bailout');
  check(!!bail && bail.freedPlayerIds.includes(R1.gp.id) && bail.freedPlayerIds.includes(R2.gp.id), 'jailbreak: both prisoners are freed');
  check(got(H1, 'hearts_update', (d) => d.playerId === H1.gp.id && d.hearts === 4) && got(H1, 'hearts_update', (d) => d.playerId === R3.gp.id && d.hearts === 2), 'jailbreak: every hunter and the rescuer pay a heart');
  move(H1, m(0, 818)); await sleep(500);
  H1.socket.emit('request_catch', { runnerId: R1.gp.id }); await sleep(600);
  check(got(H1, 'catch_failed', (d) => /just freed/.test(d.reason)), 'jailbreak: freed runners have 30 s before they can be caught again');

  // 8. Host override goes through the rules
  R3.ev = [];
  S.socket.emit('host_override', { targetId: R3.gp.id, isCaught: true });
  check(await waitFor(() => got(R3, 'player_jailed', (d) => d.runnerId === R3.gp.id), 3000), 'host override: "caught" sentences the runner like a real catch', JSON.stringify(R3.ev.filter((x) => ['error_event','hearts_update','player_eliminated'].includes(x.e)).map((x) => [x.e, x.d])));
  S.socket.emit('host_override', { targetId: R3.gp.id, isCaught: false });
  check(await waitFor(() => got(R3, 'player_revived', (d) => d.playerId === R3.gp.id), 3000), 'host override: "free" fully releases them', JSON.stringify(S.ev.filter((x) => x.e === 'error_event').map((x) => x.d)));

  done(all);
}

// ====================================================================== infection ends
{
  const H = await account('ih'); H.role = 'HUNTER';
  const A = await account('ia'); A.role = 'RUNNER';
  const B = await account('ib'); B.role = 'RUNNER';
  const all = [H, A, B];
  const mm = await match({ mode: 'INFECTION', host: H, players: [A, B] });
  await enter(mm, all);
  move(H, m(0, 0)); move(A, m(0, 5)); move(B, m(4, 0)); await sleep(1000);
  for (const r of [A, B]) {
    H.socket.emit('request_catch', { runnerId: r.gp.id });
    await waitFor(() => got(r, 'catch_requested'), 3000);
    r.socket.emit('respond_catch', { hunterId: H.gp.id, decision: 'accept' });
    await waitFor(() => got(H, 'player_infected', (d) => d.runnerId === r.gp.id), 3000);
  }
  check(got(H, 'player_infected', (d) => d.runnerId === A.gp.id), 'infection: a caught runner turns');
  check(await waitFor(() => got(H, 'game_over', (d) => d.reason === 'ALL_RUNNERS_RESOLVED'), 3000), 'infection: the match ends once everyone is turned (it used to run to the clock)');
  done(all);
}

// ====================================================================== squads
{
  const HA = await account('sha'); HA.role = 'HUNTER'; HA.squad = 'red';
  const RA = await account('sra'); RA.role = 'RUNNER'; RA.squad = 'red';
  const HB = await account('shb'); HB.role = 'HUNTER'; HB.squad = 'blue';
  const RB = await account('srb'); RB.role = 'RUNNER'; RB.squad = 'blue';
  const all = [HA, RA, HB, RB];
  const mm = await match({ mode: 'SQUAD', host: HA, players: [RA, HB, RB] });
  check(mm.start.status === 200, 'squad: two squads start', mm.start.body.error ?? '');
  await enter(mm, all);
  move(HA, m(0, 0)); move(RA, m(5, 0)); move(RB, m(0, 6)); move(HB, m(200, 0)); await sleep(1200);
  const contacts = (HA.radar?.runnerBearings ?? []).map((b) => b.runnerId);
  check(contacts.includes(RB.gp.id) && !contacts.includes(RA.gp.id), "squad: a hunter's radar shows only the other squad's runners");
  const threats = (RA.compass?.hunters ?? []).map((h) => h.hunterId);
  check(threats.includes(HB.gp.id) && !threats.includes(HA.gp.id), "squad: a runner's compass shows only the other squad's hunters");
  HA.socket.emit('request_catch', { runnerId: RA.gp.id }); await sleep(600);
  check(got(HA, 'catch_failed', (d) => /own squad/.test(d.reason)), "squad: can't catch your own squad");
  RB.socket.emit('request_catch', { runnerId: HA.gp.id }); await sleep(600);
  check(got(RB, 'catch_failed', (d) => /Only hunters/.test(d.reason)), "squad: a runner can't catch a hunter (they used to be able to)");
  HA.socket.emit('request_catch', { runnerId: RB.gp.id });
  await waitFor(() => got(RB, 'catch_requested'), 3000);
  RB.socket.emit('respond_catch', { hunterId: HA.gp.id, decision: 'accept' });
  check(await waitFor(() => got(HA, 'game_over', (d) => d.reason === 'SQUAD_WON' && d.winningSquad === 'red'), 3000), 'squad: the last squad with a free runner wins, by name');
  done(all);
}

console.log(`\n${failures === 0 ? 'ALL PASSED' : failures + ' FAILED'}`);
process.exit(failures ? 1 : 0);
