// Radar ping interval: with an interval the radar and compass only update on each ping, Thermal
// Vision tracks live between pings, and an EMP blanks the radar at once. Throwaway server only.
import { io } from 'socket.io-client';
import { execFileSync } from 'node:child_process';

const API = process.env.API ?? 'http://127.0.0.1:4555';
const C = { lat: 50.9375, lng: 6.9603 };
const m = (dn, de) => ({ lat: C.lat + dn / 111320, lng: C.lng + de / (111320 * Math.cos((C.lat * Math.PI) / 180)) });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, label, extra = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${extra ? '  — ' + extra : ''}`); if (!ok) failures++; };
const sql = (q) => execFileSync('docker', ['exec', 'hgtest-db', 'psql', '-U', 't', '-d', 't', '-tAc', q]).toString().trim();
async function req(method, path, body, token) {
  const r = await fetch(API + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, body: await r.json().catch(() => ({})) };
}
const sfx = Date.now().toString(36).slice(-4); let n = 0;
async function account(name) { const r = await req('POST', '/auth/register', { username: `${name}${sfx}${n++}`, password: 'Testpass123!' }); return { name, token: r.body.token }; }
const move = (p, pos) => { p.pos = pos; p.socket.emit('send_location_update', { lat: pos.lat, lng: pos.lng, accuracy: 5, speed: 1, battery: 90, isMovingOnFoot: true }); };
const dist = (p, r) => p.radar?.runnerBearings?.find((b) => b.runnerId === r.gp.id)?.distanceMeters;

const H = await account('ph'), R = await account('pr'), R2 = await account('pq');
const bounds = [m(-800, -800), m(-800, 800), m(800, 800), m(800, -800)];
const c = await req('POST', '/games', { durationMinutes: 30, boundsPolygon: bounds, role: 'HUNTER', mode: 'STANDARD' }, H.token);
const code = c.body.session.code, sessionId = c.body.session.id; H.gp = c.body.player;
R.gp = (await req('POST', `/games/${code}/join`, { role: 'RUNNER' }, R.token)).body.player;
R2.gp = (await req('POST', `/games/${code}/join`, { role: 'RUNNER' }, R2.token)).body.player;
sql(`UPDATE "GamePlayer" SET role='HUNTER', hearts=5 WHERE id='${H.gp.id}'`);
const patch = await req('PATCH', `/games/${code}/settings`, { radarIntervalSeconds: 10 }, H.token);
check(patch.status === 200 && patch.body.session.settings.radarIntervalSeconds === 10, 'setting: the host sets a 10 s ping');
const bad = await req('PATCH', `/games/${code}/settings`, { radarIntervalSeconds: 601 }, H.token);
check(bad.status === 400, 'setting: more than 10 minutes is refused');
sql(`DELETE FROM "PowerUpSpawn" WHERE "sessionId"='${sessionId}'`);
await req('POST', `/games/${code}/start`, {}, H.token);
for (const p of [H, R, R2]) {
  p.socket = io(API, { auth: { token: p.token }, transports: ['websocket'], forceNew: true });
  p.socket.on('radar_broadcast', (d) => { p.radar = d; p.radarCount = (p.radarCount ?? 0) + 1; });
  p.socket.on('compass_update', (d) => { p.compass = d; p.compassCount = (p.compassCount ?? 0) + 1; });
  p.socket.on('radar_ping', (d) => { p.ping = d; });
  p.socket.on('error_event', (d) => console.log('   error:', d.reason));
  await new Promise((res) => p.socket.on('connect', res));
  p.socket.emit('join_room', { roomCode: code, gamePlayerId: p.gp.id });
}
await sleep(800);
move(H, m(0, 0)); move(R, m(0, 100)); move(R2, m(0, 400));
// Wait for a ping so everyone has a baseline.
const waitPing = async () => { const before = H.ping?.at; for (let i = 0; i < 24 && H.ping?.at === before; i++) await sleep(500); };
await waitPing(); await sleep(400);
const d0 = dist(H, R);
check(d0 != null && Math.abs(d0 - 100) < 5, 'ping: the hunter gets a baseline at the ping', `${d0} m`);
check(typeof H.radar?.nextPingAt === 'number' && H.radar.nextPingAt > Date.now(), 'ping: the radar carries the next ping time');
move(R, m(0, 200)); await sleep(1500);
check(dist(H, R) === d0, 'ping: between pings the radar does NOT update when the runner moves', `${dist(H, R)} m`);
const c0 = R.compassCount; move(H, m(0, 20)); await sleep(1200);
check(R.compassCount === c0, "ping: the runner's compass doesn't update between pings either");
await waitPing(); await sleep(400);
check(Math.abs(dist(H, R) - 180) < 6, 'ping: at the next ping the radar jumps to the new position', `${dist(H, R)} m`);

// Thermal Vision: live between pings, with heat signatures
const sp = sql(`INSERT INTO "PowerUpSpawn"(id,"sessionId",type,latitude,longitude,"isCollected","spawnedAt","expiresAt") VALUES (gen_random_uuid(),'${sessionId}','THERMAL_VISION',${H.pos.lat},${H.pos.lng},false,now(),now()+interval '1 hour') RETURNING id`).split('\n')[0];
H.socket.emit('collect_powerup', { spawnId: sp }); await sleep(500);
H.socket.emit('use_powerup', { powerUpType: 'THERMAL_VISION' }); await sleep(1500);
check(H.radar?.live === true, 'thermal: the radar is marked live');
move(R, m(0, 120)); await sleep(1500);
check(Math.abs(dist(H, R) - 100) < 6, 'thermal: the radar tracks the runner live between pings', `${dist(H, R)} m`);
check((H.radar?.heat ?? []).some((h) => h.id === R.gp.id) && !(H.radar?.heat ?? []).some((h) => h.id === R2.gp.id), 'thermal: heat signature for the runner at 100 m, none for the one at 400 m');

for (const p of [H, R, R2]) p.socket.disconnect();
console.log(`\n${failures === 0 ? 'ALL PASSED' : failures + ' FAILED'}`);
process.exit(failures ? 1 : 0);
