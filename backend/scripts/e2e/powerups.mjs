// End-to-end power-up test against the throwaway backend on 127.0.0.1:4555.
// Two hunters and two runners join a real match over Socket.IO; every power-up is picked up and
// used, and each player's radar/compass is checked WITHOUT anyone moving afterwards, which is
// exactly where the old code failed (effects only applied on someone's next GPS fix).
import { io } from 'socket.io-client';
import { execFileSync } from 'node:child_process';

const API = 'http://127.0.0.1:4555';
const C = { lat: 50.9375, lng: 6.9603 }; // Cologne
const m = (dn, de) => ({ lat: C.lat + dn / 111320, lng: C.lng + de / (111320 * Math.cos((C.lat * Math.PI) / 180)) });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, label, extra = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${extra ? '  — ' + extra : ''}`); if (!ok) failures++; };
const sql = (q) => execFileSync('docker', ['exec', 'hgtest-db', 'psql', '-U', 't', '-d', 't', '-tAc', q]).toString().trim();

async function post(path, body, token) {
  const r = await fetch(API + path, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: JSON.stringify(body) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${path}: ${r.status} ${JSON.stringify(j)}`);
  return j;
}

const suffix = Date.now().toString(36).slice(-5);
async function account(name) {
  const { token, user } = await post('/auth/register', { username: `${name}${suffix}`, password: 'Testpass123!' });
  return { name, token, user };
}

function connect(p) {
  const s = io(API, { auth: { token: p.token }, transports: ['websocket'], forceNew: true });
  p.socket = s; p.radar = null; p.compass = null; p.buffs = {}; p.errors = []; p.activated = []; p.catchFailed = []; p.inventory = [];
  s.on('radar_broadcast', (d) => { p.radar = d; p.radarAt = Date.now(); });
  s.on('compass_update', (d) => { p.compass = d; });
  s.on('buffs_update', (d) => { p.buffs = d.buffs; });
  s.on('error_event', (d) => p.errors.push(d.reason));
  s.on('powerup_activated', (d) => p.activated.push(d));
  s.on('catch_failed', (d) => p.catchFailed.push(d.reason));
  s.on('inventory_update', (d) => { p.inventory = d.inventory; });
  return new Promise((res) => s.on('connect', res));
}
const move = (p, pos) => { p.pos = pos; p.socket.emit('send_location_update', { lat: pos.lat, lng: pos.lng, accuracy: 5, speed: 1, battery: 90, isMovingOnFoot: true }); };
const contacts = (p) => (p.radar?.runnerBearings ?? []);
const sees = (p, runner) => contacts(p).some((b) => b.runnerId === runner.gp.id);
const compassIds = (p) => (p.compass?.hunters ?? []).map((h) => h.hunterId);

function spawn(session, type, pos) {
  return sql(`INSERT INTO "PowerUpSpawn"(id,"sessionId",type,latitude,longitude,"isCollected","spawnedAt","expiresAt") VALUES (gen_random_uuid(),'${session}','${type}',${pos.lat},${pos.lng},false,now(),now()+interval '1 hour') RETURNING id`).split('\n')[0];
}
async function collect(p, session, type) {
  const id = spawn(session, type, p.pos);
  const before = p.errors.length;
  p.socket.emit('collect_powerup', { spawnId: id });
  await sleep(500);
  return p.errors.length === before ? null : p.errors.at(-1);
}
async function use(p, type) { p.socket.emit('use_powerup', { powerUpType: type }); await sleep(1600); }

// ------------------------------------------------------------------ setup
const H1 = await account('hunta'), H2 = await account('huntb'), R1 = await account('runa'), R2 = await account('runb');
const bounds = [m(-800, -800), m(-800, 800), m(800, 800), m(800, -800)];
const created = await post('/games', { durationMinutes: 30, boundsPolygon: bounds, role: 'HUNTER', mode: 'STANDARD' }, H1.token);
const code = created.session.code, sessionId = created.session.id;
H1.gp = created.player;
H2.gp = (await post(`/games/${code}/join`, { role: 'HUNTER' }, H2.token)).player;
R1.gp = (await post(`/games/${code}/join`, { role: 'RUNNER' }, R1.token)).player;
R2.gp = (await post(`/games/${code}/join`, { role: 'RUNNER' }, R2.token)).player;
sql(`DELETE FROM "PowerUpSpawn" WHERE "sessionId"='${sessionId}'`);
await post(`/games/${code}/start`, {}, H1.token);
const all = [H1, H2, R1, R2];
for (const p of all) { await connect(p); p.socket.emit('join_room', { roomCode: code, gamePlayerId: p.gp.id }); }
await sleep(800);
move(H1, m(0, 0)); move(H2, m(500, 0)); move(R1, m(0, 100)); move(R2, m(-400, 0));
await sleep(1200);
console.log(`match ${code} running with 2 hunters, 2 runners\n`);

// ------------------------------------------------------------------ baseline
check(sees(H1, R1) && sees(H1, R2), 'baseline: hunter A sees both runners on radar');
check(compassIds(R1).includes(H1.gp.id) && compassIds(R1).includes(H2.gp.id), 'baseline: runner A compass shows both hunters');

// ------------------------------------------------------------------ role rules
check((await collect(H1, sessionId, 'EMP_JAMMER'))?.includes('Only runners'), 'role rule: a hunter cannot pick up EMP Jammer');
check((await collect(H1, sessionId, 'GHOST_DECOY'))?.includes('Only runners'), 'role rule: a hunter cannot pick up Ghost Decoy');
check((await collect(R1, sessionId, 'THERMAL_VISION'))?.includes('Only hunters'), 'role rule: a runner cannot pick up Thermal Vision');
const feed = await (await fetch(`${API}/powerups/session/${sessionId}`, { headers: { Authorization: 'Bearer ' + H1.token } })).json();
spawn(sessionId, 'EMP_JAMMER', m(10, 10)); spawn(sessionId, 'THERMAL_VISION', m(10, 10));
const hunterFeed = await (await fetch(`${API}/powerups/session/${sessionId}`, { headers: { Authorization: 'Bearer ' + H1.token } })).json();
const runnerFeed = await (await fetch(`${API}/powerups/session/${sessionId}`, { headers: { Authorization: 'Bearer ' + R1.token } })).json();
check(!hunterFeed.spawns.some((s) => s.type === 'EMP_JAMMER') && hunterFeed.spawns.some((s) => s.type === 'THERMAL_VISION'), 'map feed: hunters see Thermal Vision, not EMP');
check(runnerFeed.spawns.some((s) => s.type === 'EMP_JAMMER') && !runnerFeed.spawns.some((s) => s.type === 'THERMAL_VISION'), 'map feed: runners see EMP, not Thermal Vision');
void feed;

// ------------------------------------------------------------------ invisibility (runner)
check((await collect(R1, sessionId, 'INVISIBILITY_10MIN')) === null, 'invisibility: runner A picks it up');
await use(R1, 'INVISIBILITY_10MIN');
check(!sees(H1, R1) && !sees(H2, R1), 'invisibility: runner A vanishes from BOTH hunters within 1.6 s, nobody moving');
check(sees(H1, R2), 'invisibility: runner B is still visible');
check(R1.activated.some((a) => a.type === 'INVISIBILITY_10MIN' && a.expiresAt > Date.now()), 'invisibility: caster gets a confirmation with the expiry');
check(!!R1.buffs.INVISIBILITY_10MIN, 'invisibility: caster buffs_update lists it');

// ------------------------------------------------------------------ thermal vision (hunter, 300 m)
check((await collect(H1, sessionId, 'THERMAL_VISION')) === null, 'thermal: hunter A picks it up');
await use(H1, 'THERMAL_VISION');
check(sees(H1, R1), 'thermal: hunter A sees invisible runner A at 100 m');
check(!sees(H2, R1), 'thermal: hunter B (no thermal) still cannot see runner A');
check((H1.radar?.heat ?? []).some((h) => h.id === R1.gp.id), 'thermal: runner A (100 m, invisible) shows as a heat signature on hunter A\'s map');
check(!(H2.radar?.heat ?? []).length, 'thermal: no heat signatures for a hunter without thermal');
// Runner B goes invisible at 400 m: outside thermal range.
check((await collect(R2, sessionId, 'INVISIBILITY_10MIN')) === null, 'thermal: runner B picks up invisibility');
await use(R2, 'INVISIBILITY_10MIN');
check(!sees(H1, R2), 'thermal: invisible runner B at 400 m stays hidden even from thermal (300 m range)');
check(!(H1.radar?.heat ?? []).some((h) => h.id === R2.gp.id), 'thermal: no heat signature beyond 300 m');
const t0 = H1.radarAt; await sleep(1300);
check(H1.radarAt > t0, 'thermal: radar refreshes every second with nobody moving');

// ------------------------------------------------------------------ ghost decoy (runner)
// Runner B walks north first, so the decoy should head south (away from their travel).
move(R2, m(-390, 0)); await sleep(300); move(R2, m(-380, 0)); await sleep(400);
check((await collect(R2, sessionId, 'GHOST_DECOY')) === null, 'decoy: runner B picks it up');
await use(R2, 'GHOST_DECOY');
const decoyH2 = contacts(H2).find((b) => b.runnerId.startsWith('decoy:'));
check(!!decoyH2 && decoyH2.username === R2.user.username, 'decoy: hunter B sees a contact with runner B\'s exact name', decoyH2 ? `${decoyH2.distanceMeters} m` : 'no contact');
check(!(H2.radar?.decoys ?? []).length, 'decoy: no separate labelled decoy list is sent (it used to give the decoy away)');
check(!contacts(H1).some((b) => b.runnerId.startsWith('decoy:')), 'decoy: hidden from the thermal hunter (no heat signature)');
const d1 = contacts(H2).find((b) => b.runnerId.startsWith('decoy:'))?.distanceMeters;
await sleep(3500);
const d2 = contacts(H2).find((b) => b.runnerId.startsWith('decoy:'))?.distanceMeters;
check(d1 != null && d2 != null && d2 !== d1, 'decoy: it walks on hunter B\'s radar with nobody moving', `${d1} m → ${d2} m`);
// Heading check: decoy origin was runner B's spot; hunter B is north of it, so walking south means the distance to hunter B grows.
check(d2 > d1, 'decoy: it walks away from the runner\'s own direction of travel (south)');
H2.socket.emit('request_catch', { runnerId: decoyH2?.runnerId });
await sleep(1500);
check(H2.catchFailed.some((r) => r.includes('Ghost Decoy')), 'decoy: catching it says it was a decoy');
check(!contacts(H2).some((b) => b.runnerId.startsWith('decoy:')), 'decoy: once caught it is gone from the radar');

// ------------------------------------------------------------------ EMP jammer (runner, 200 m)
check((await collect(R1, sessionId, 'EMP_JAMMER')) === null, 'emp: runner A picks it up');
await use(R1, 'EMP_JAMMER');
check(H1.radar?.jammed === true && contacts(H1).length === 0, 'emp: hunter A (100 m away) is jammed within 1.6 s, nobody moving');
check(H2.radar?.jammed === false, 'emp: hunter B (500 m away) is not jammed');
check(R1.activated.some((a) => a.type === 'EMP_JAMMER' && a.jammedCount === 1), 'emp: caster is told it jammed 1 hunter');
check(!!H1.buffs.EMP_JAMMER, 'emp: the jammed hunter gets the jam expiry for the countdown badge');

// ------------------------------------------------------------------ invisibility (hunter) and the empty compass
check((await collect(H2, sessionId, 'INVISIBILITY_10MIN')) === null, 'hunter invisibility: hunter B picks it up');
await use(H2, 'INVISIBILITY_10MIN');
check(!compassIds(R1).includes(H2.gp.id) && compassIds(R1).includes(H1.gp.id), 'hunter invisibility: runner A\'s compass drops hunter B within 1.6 s');
const before = H2.radarAt; move(R2, m(-370, 0)); await sleep(800);
check(H2.radarAt > before, 'hunter invisibility: the invisible hunter\'s own radar keeps updating');
check((await collect(H1, sessionId, 'INVISIBILITY_10MIN')) === null, 'empty compass: hunter A picks up invisibility too');
await use(H1, 'INVISIBILITY_10MIN');
check(R1.compass && R1.compass.distanceMeters === null && R1.compass.hunters.length === 0, 'empty compass: with every hunter invisible the compass clears (it used to freeze)');

// ------------------------------------------------------------------ expiry, with nobody moving
console.log('\nwaiting for the 60 s buffs to run out (nobody moves)…');
await sleep(61_500);
check(!H1.radar?.jammed, 'expiry: hunter A\'s EMP jam ends on its own');
check(sees(H1, R1) || sees(H2, R1), 'expiry: runner A is back on radar on its own');
check(compassIds(R1).length === 2, 'expiry: both hunters are back on runner A\'s compass on their own');
check(!R1.buffs.INVISIBILITY_10MIN, 'expiry: runner A\'s buffs_update drops invisibility');

for (const p of all) p.socket.disconnect();
console.log(`\n${failures === 0 ? 'ALL PASSED' : failures + ' FAILED'}`);
process.exit(failures ? 1 : 0);
