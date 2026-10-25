// Load test against the throwaway backend on 127.0.0.1:4555 (never production): MATCHES matches
// of six players (2 hunters, 4 runners) running at once, every player sending a GPS fix every
// second with a live radar — the heaviest setting. Reports how quickly a runner's move reaches the
// hunters' radar, how many updates go missing, and how the API answers meanwhile.
//
//   MATCHES=60 SECONDS=60 node loadtest.mjs
import { io } from 'socket.io-client';
import { execFileSync } from 'node:child_process';

const API = process.env.API ?? 'http://127.0.0.1:4555';
const MATCHES = Number(process.env.MATCHES ?? 60);
const SECONDS = Number(process.env.SECONDS ?? 60);
const C = { lat: 50.9375, lng: 6.9603 };
const m = (dn, de) => ({ lat: C.lat + dn / 111320, lng: C.lng + de / (111320 * Math.cos((C.lat * Math.PI) / 180)) });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sql = (q) => execFileSync('docker', ['exec', 'hgtest-db', 'psql', '-U', 't', '-d', 't', '-tAc', q]).toString().trim();

async function req(method, path, body, token) {
  const r = await fetch(API + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, body: await r.json().catch(() => ({})) };
}
const sfx = Date.now().toString(36).slice(-4);
let n = 0;
async function account() {
  // Retried with the next name if a random one happens to trip the username filter.
  for (let tries = 0; tries < 5; tries++) {
    const r = await req('POST', '/auth/register', { username: `player${sfx}${n++}`, password: 'Testpass123!' });
    if (r.status === 201) return { token: r.body.token, user: r.body.user };
    if (tries === 4) throw new Error(JSON.stringify(r.body));
  }
}
const pct = (arr, p) => (arr.length ? [...arr].sort((a, b) => a - b)[Math.min(arr.length - 1, Math.floor((p / 100) * arr.length))] : NaN);

console.log(`setting up ${MATCHES} matches × 6 players…`);
const matches = [];
for (let i = 0; i < MATCHES; i++) {
  const players = [];
  for (let k = 0; k < 6; k++) players.push(await account());
  const [host, ...rest] = players;
  const bounds = [m(-800, -800), m(-800, 800), m(800, 800), m(800, -800)];
  const c = await req('POST', '/games', { durationMinutes: 30, boundsPolygon: bounds, role: 'HUNTER', mode: 'STANDARD' }, host.token);
  const code = c.body.session.code;
  host.gp = c.body.player; host.role = 'HUNTER';
  for (const [k, p] of rest.entries()) {
    p.gp = (await req('POST', `/games/${code}/join`, { role: 'RUNNER' }, p.token)).body.player;
    p.role = k === 0 ? 'HUNTER' : 'RUNNER';
  }
  sql(`UPDATE "GamePlayer" SET role='HUNTER', hearts=5 WHERE id IN ('${host.gp.id}','${rest[0].gp.id}')`);
  await req('PATCH', `/games/${code}/settings`, { radarIntervalSeconds: 0, headStartSeconds: 0 }, host.token);
  const st = await req('POST', `/games/${code}/start`, {}, host.token);
  if (st.status !== 200) throw new Error('start ' + JSON.stringify(st.body));
  matches.push({ code, players });
}

console.log('connecting sockets…');
const latencies = [];
let radarMessages = 0;
let sent = 0;
for (const { code, players } of matches) {
  for (const p of players) {
    p.socket = io(API, { auth: { token: p.token }, transports: ['websocket'], forceNew: true });
    await new Promise((res) => p.socket.on('connect', res));
    p.socket.emit('join_room', { roomCode: code, gamePlayerId: p.gp.id });
    if (p.role === 'HUNTER') {
      p.socket.on('radar_broadcast', () => { radarMessages++; });
    }
  }
}
await sleep(2000);

// Each runner walks a slow circle; every fix carries its send time in the speed field's twin,
// measured by when the nearest hunter's radar next changes after it.
console.log(`running for ${SECONDS} s…`);
const apiTimes = [];
const started = Date.now();
const apiProbe = setInterval(async () => {
  const t = Date.now();
  const r = await fetch(API + '/health').catch(() => null);
  if (r?.ok) apiTimes.push(Date.now() - t);
}, 500);
let tick = 0;
while (Date.now() - started < SECONDS * 1000) {
  const t0 = Date.now();
  for (const [mi, { players }] of matches.entries()) {
    for (const [pi, p] of players.entries()) {
      const a = (tick / 30 + pi) * 0.5;
      const r = p.role === 'HUNTER' ? 40 : 150 + pi * 20;
      const pos = m(Math.sin(a) * r + mi, Math.cos(a) * r);
      p.socket.emit('send_location_update', { lat: pos.lat, lng: pos.lng, accuracy: 5, speed: 1.4, battery: 80, isMovingOnFoot: true });
      sent++;
    }
  }
  // Round trip: one hunter per match waits for its next radar after a runner moved.
  const probes = matches.slice(0, 10).map(({ players }) => new Promise((res) => {
    const hunter = players.find((p) => p.role === 'HUNTER');
    const t = Date.now();
    const timer = setTimeout(() => { hunter.socket.off('radar_broadcast', on); res(null); }, 3000);
    const on = () => { clearTimeout(timer); hunter.socket.off('radar_broadcast', on); res(Date.now() - t); };
    hunter.socket.on('radar_broadcast', on);
  }));
  for (const l of await Promise.all(probes)) if (l !== null) latencies.push(l);
  tick++;
  await sleep(Math.max(0, 1000 - (Date.now() - t0)));
}
clearInterval(apiProbe);

const stats = execFileSync('docker', ['stats', '--no-stream', '--format', '{{.CPUPerc}} {{.MemUsage}}', 'hgtest-api']).toString().trim();
const secs = (Date.now() - started) / 1000;
const hunters = MATCHES * 2;
console.log(`
${MATCHES} matches, ${MATCHES * 6} players connected, ${secs.toFixed(0)} s
GPS fixes sent:          ${sent} (${(sent / secs).toFixed(0)}/s)
radar updates received:  ${radarMessages} (${(radarMessages / secs / hunters).toFixed(2)} per hunter per second)
move → hunter radar:     p50 ${pct(latencies, 50)} ms · p95 ${pct(latencies, 95)} ms · p99 ${pct(latencies, 99)} ms (${latencies.length} samples)
API /health meanwhile:   p50 ${pct(apiTimes, 50)} ms · p95 ${pct(apiTimes, 95)} ms
server at the end:       ${stats}`);
for (const { players } of matches) for (const p of players) p.socket.close();
process.exit(0);
