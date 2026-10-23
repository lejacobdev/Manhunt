/* Hunting Game admin panel. No build step, no framework, no inline handlers: every control
   carries a data-act attribute and one delegated listener dispatches it, so the page can run
   under a strict Content-Security-Policy. */
"use strict";

const API = "https://api.lejacob.dev";
const TOKEN_KEY = "hg_admin_token";
const IDLE_LIMIT_MS = 30 * 60 * 1000;
const URGENT = new Set(["THREATS", "SEXUAL_CONTENT", "HARASSMENT"]);

let TOKEN = safeGet(TOKEN_KEY) || "";
let ME = null;
let socket = null;
let ADMINS = [];
let OPEN_REPORTS = 0;
let CHIME = safeGet("hg_admin_chime") === "1";
const STATE = { reportStatus: "OPEN", reportCategory: "ALL", sessionStatus: "ACTIVE", userQuery: "", userBanned: false, selected: 0, auditQuery: "" };
let insightsCache = null;
let refreshTimer = null;

function safeGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
function safeSet(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch {} }

// ------------------------------------------------------------------ formatting
// Every value rendered passes through esc(). Usernames, report text and ban reasons are
// attacker-controlled, and this panel belongs to the one account that can ban people.
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const fmt = (d) => (d ? new Date(d).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "—");
const day = (d) => (d ? new Date(d).toLocaleDateString(undefined, { month: "short", day: "numeric" }) : "—");
const num = (n) => (n == null ? "—" : Number(n).toLocaleString());
const handle = (u) => (u ? esc(u.username + "#" + u.userTag) : '<span class="hint">deleted account</span>');
const initial = (u) => esc((u?.username || "?").slice(0, 1).toUpperCase());
const pretty = (s) => esc(String(s ?? "").toLowerCase().replace(/_/g, " "));
function ago(d) {
  if (!d) return "—";
  const s = Math.round((Date.now() - new Date(d)) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  if (s < 86400) return Math.floor(s / 3600) + "h ago";
  if (s < 86400 * 30) return Math.floor(s / 86400) + "d ago";
  return day(d);
}
function bytes(n) {
  if (n == null) return "—";
  const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(n < 10 && i ? 1 : 0) + " " + u[i];
}
function duration(sec) {
  sec = Math.round(sec);
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
}
const COUNTRY = (() => { try { return new Intl.DisplayNames(undefined, { type: "region" }); } catch { return null; } })();
const countryName = (c) => { try { return COUNTRY?.of(c) || c; } catch { return c; } };
const flag = (c) => /^[A-Z]{2}$/.test(c) ? String.fromCodePoint(...[...c].map((ch) => 127397 + ch.charCodeAt(0))) : "🏳️";

// ------------------------------------------------------------------ icons

const ICON_PATHS = {
  overview: "M3 13h8V3H3zm10 8h8V11h-8zM3 21h8v-6H3zm10-18v6h8V3z",
  live: "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM4.9 4.9a10 10 0 0 0 0 14.2M19.1 4.9a10 10 0 0 1 0 14.2M7.8 7.8a6 6 0 0 0 0 8.4M16.2 7.8a6 6 0 0 1 0 8.4",
  matches: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 4v6l4 2",
  reports: "M5 21V4m0 0h11l-2 4 2 4H5",
  anticheat: "M12 2l8 4v6c0 5-3.5 9-8 10-4.5-1-8-5-8-10V6zm-3 10l2 2 4-4",
  usernames: "M4 7V5h16v2M9 19h6M12 5v14",
  bans: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zM5 5l14 14",
  players: "M16 11a4 4 0 1 0-8 0M3 21a9 9 0 0 1 18 0M12 7a4 4 0 1 0 0 8",
  regulars: "M12 2l3 6 7 1-5 5 1 7-6-3-6 3 1-7-5-5 7-1z",
  growth: "M3 17l6-6 4 4 8-8M14 7h7v7",
  broadcast: "M3 11v2a2 2 0 0 0 2 2h2l5 4V5L7 9H5a2 2 0 0 0-2 2zM16 8a5 5 0 0 1 0 8M19 5a9 9 0 0 1 0 14",
  modes: "M4 6h16M4 12h16M4 18h10",
  powerups: "M13 2L4 14h7l-1 8 9-12h-7z",
  peak: "M3 3h18v18H3zM3 9h18M9 3v18",
  team: "M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM23 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8",
  server: "M3 4h18v6H3zM3 14h18v6H3zM7 7h.01M7 17h.01",
  audit: "M9 11l3 3 8-8M20 12v7a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h9",
  more: "M5 12h.01M12 12h.01M19 12h.01",
  close: "M6 6l12 12M18 6L6 18",
  bell: "M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 0 1-3.4 0",
};
const icon = (name) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${ICON_PATHS[name] || ""}"/></svg>`;

// ------------------------------------------------------------------ navigation

const NAV = [
  ["Game", [["overview", "Overview"], ["live", "Live"], ["matches", "Matches"]]],
  ["Safety", [["reports", "Reports"], ["anticheat", "Anti-cheat"], ["usernames", "Usernames"], ["bans", "Bans"]]],
  ["Players", [["players", "Players"], ["regulars", "Regulars"], ["growth", "Growth"], ["broadcast", "Broadcast"]]],
  ["Insights", [["modes", "Modes"], ["powerups", "Power-ups"], ["peak", "Peak times"]]],
  ["System", [["team", "Team"], ["server", "Server"], ["audit", "Audit"]]],
];
const TITLES = Object.fromEntries(NAV.flatMap(([g, items]) => items.map(([id, label]) => [id, { label, group: g }])));
// The four sections that earn a slot in the phone tab bar; the rest live behind "more".
const TABS = [["overview", "Home"], ["reports", "Reports"], ["players", "Players"], ["live", "Live"]];

function route() {
  const id = (location.hash.replace(/^#\/?/, "") || "overview").split("?")[0];
  return TITLES[id] ? id : "overview";
}

// ------------------------------------------------------------------ API

async function api(path, opts = {}) {
  touch();
  const res = await fetch(API + path, {
    ...opts,
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + TOKEN, ...(opts.headers || {}) },
  });
  if (res.status === 401) { logout("Your session expired. Sign in again."); throw new Error("Session expired."); }
  if (res.status === 204) return null;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `Request failed (${res.status}).`);
  return body;
}
const post = (path, body) => api(path, { method: "POST", body: JSON.stringify(body || {}) });

// ------------------------------------------------------------------ toasts, dialogs, drawer

function toast(message, kind = "", onClick) {
  const el = document.createElement("div");
  el.className = `toast glass ${kind}`;
  el.innerHTML = message;
  if (onClick) { el.classList.add("event"); el.addEventListener("click", () => { onClick(); el.remove(); }); }
  document.getElementById("toasts").appendChild(el);
  setTimeout(() => el.remove(), kind === "event" ? 7000 : 3600);
}
const ok = (msg) => toast(`<span class="dot"></span>${esc(msg)}`);
const fail = (e) => toast(`⚠︎ ${esc(e?.message || e)}`, "bad");

/**
 * The replacement for prompt() and confirm(): a title, a sentence saying what will happen,
 * an optional validated input, danger styling for destructive actions, Escape and Enter.
 * Resolves to the input's value (or true), or null when cancelled.
 */
function ask({ title, text = "", input = null, confirm = "Confirm", danger = false, validate = null }) {
  return new Promise((resolve) => {
    const dlg = document.createElement("dialog");
    const field = input
      ? `<div class="field"><label for="dlg-in">${esc(input.label || "")}</label>
          ${input.multiline
            ? `<textarea id="dlg-in" class="input" maxlength="${input.maxlength || 1000}" placeholder="${esc(input.placeholder || "")}">${esc(input.value || "")}</textarea>`
            : `<input id="dlg-in" class="input" maxlength="${input.maxlength || 200}" placeholder="${esc(input.placeholder || "")}" value="${esc(input.value || "")}">`}
          ${input.hint ? `<div class="hint">${esc(input.hint)}</div>` : ""}
          <div class="error-text" id="dlg-err"></div></div>`
      : "";
    dlg.innerHTML = `<form method="dialog" class="sheet glass">
        <h4>${esc(title)}</h4>${text ? `<p>${esc(text)}</p>` : ""}${field}
        <div class="buttons"><button type="button" class="btn ghost" value="cancel">Cancel</button>
        <button type="submit" class="btn ${danger ? "danger solid" : "primary"}" value="ok">${esc(confirm)}</button></div></form>`;
    document.body.appendChild(dlg);
    const inEl = dlg.querySelector("#dlg-in");
    const finish = (v) => { dlg.close(); dlg.remove(); resolve(v); };
    dlg.querySelector('[value="cancel"]').addEventListener("click", () => finish(null));
    dlg.addEventListener("cancel", (e) => { e.preventDefault(); finish(null); });
    dlg.querySelector("form").addEventListener("submit", (e) => {
      e.preventDefault();
      if (!inEl) return finish(true);
      const v = inEl.value.trim();
      const problem = (input.required !== false && !v) ? "This can't be empty." : validate ? validate(v) : "";
      if (problem) { dlg.querySelector("#dlg-err").textContent = problem; inEl.focus(); return; }
      finish(v);
    });
    if (inEl && !input.multiline) inEl.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); dlg.querySelector("form").requestSubmit(); } });
    dlg.showModal();
    (inEl || dlg.querySelector('[value="ok"]')).focus();
  });
}

function openDrawer(html) {
  const scrim = document.getElementById("scrim"), dr = document.getElementById("drawer");
  dr.innerHTML = `<button class="btn ghost small close" data-act="close-drawer" aria-label="Close">${icon("close")}</button>${html}`;
  scrim.hidden = false; dr.hidden = false;
  requestAnimationFrame(() => { scrim.classList.add("show"); dr.classList.add("show"); });
  dr.focus();
}
function closeDrawer() {
  const scrim = document.getElementById("scrim"), dr = document.getElementById("drawer");
  scrim.classList.remove("show"); dr.classList.remove("show");
  setTimeout(() => { scrim.hidden = true; dr.hidden = true; dr.innerHTML = ""; }, 380);
}
const drawerOpen = () => !document.getElementById("drawer").hidden;

// ------------------------------------------------------------------ sign-in

function renderLogin(error) {
  stopLive();
  document.getElementById("app").innerHTML = `
    <div class="login"><form class="sheet glass" id="login-form">
      <div class="mark"><img src="/assets/apple-touch-icon.png" alt=""><b>Hunting Game</b><small>MISSION CONTROL</small></div>
      <div class="field"><label for="u">Username</label><input id="u" class="input" autocomplete="username" autocapitalize="off" spellcheck="false"></div>
      <div class="field"><label for="t">Tag</label><input id="t" class="input" inputmode="numeric" placeholder="0000" autocomplete="off"></div>
      <div class="field"><label for="p">Password</label><input id="p" class="input" type="password" autocomplete="current-password"></div>
      <button class="btn primary" style="width:100%;padding:13px" type="submit">Sign in</button>
      <div class="error-text" style="margin-top:12px;text-align:center">${esc(error || "")}</div>
      <div class="hint" style="text-align:center;margin-top:10px">Admin accounts only. You're signed out after 30 minutes idle.</div>
    </form></div>`;
  document.getElementById("login-form").addEventListener("submit", doLogin);
  document.getElementById("u").focus();
}

async function doLogin(e) {
  e.preventDefault();
  const username = document.getElementById("u").value.trim();
  const userTag = document.getElementById("t").value.trim();
  const password = document.getElementById("p").value;
  try {
    const res = await fetch(API + "/auth/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username, userTag, password }) });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) return renderLogin(body.error || "Sign-in failed.");
    TOKEN = body.token;
    // A player signing in here should be told no, not handed a broken-looking panel.
    try { await api("/admin/me"); } catch { TOKEN = ""; return renderLogin("That account doesn't have admin access."); }
    safeSet(TOKEN_KEY, TOKEN);
    boot();
  } catch (err) { renderLogin(err.message); }
}

function logout(reason) {
  TOKEN = ""; ME = null; safeSet(TOKEN_KEY, null);
  closeDrawerIfOpen();
  renderLogin(reason);
}
function closeDrawerIfOpen() { if (document.getElementById("drawer") && drawerOpen()) closeDrawer(); }

// Idle timeout: a phone left unlocked must not stay signed in to the ban button.
let lastActivity = Date.now();
function touch() { lastActivity = Date.now(); }
["pointerdown", "keydown", "scroll"].forEach((ev) => addEventListener(ev, touch, { passive: true }));
setInterval(() => { if (TOKEN && Date.now() - lastActivity > IDLE_LIMIT_MS) logout("Signed out after 30 minutes without activity."); }, 30_000);

// ------------------------------------------------------------------ shell

function shell() {
  const current = route();
  const navHtml = NAV.map(([group, items]) => `<div class="nav-group">${group}</div>` + items.map(([id, label]) =>
    `<button class="nav-item" data-act="go" data-to="${id}" ${id === current ? 'aria-current="page"' : ""}>${icon(id)}${label}${id === "reports" && OPEN_REPORTS ? `<span class="count">${OPEN_REPORTS}</span>` : ""}</button>`).join("")).join("");
  return `
    <div class="shell">
      <aside class="sidebar glass" aria-label="Sections">
        <div class="brand"><img src="/assets/apple-touch-icon.png" alt=""><div><b>Hunting Game</b><small>MISSION CONTROL</small></div></div>
        ${navHtml}
        <div class="me"><div class="avatar">${initial(ME)}</div><div class="grow" style="min-width:0"><div class="title" style="font-weight:600">${handle(ME)}</div>
          <button class="btn ghost small" style="padding:4px 0;border:0" data-act="logout">Sign out</button></div></div>
      </aside>
      <main class="main" id="main" tabindex="-1">
        <div class="topbar">
          <div><div class="sub">${esc(TITLES[current].group)}</div><h1>${esc(TITLES[current].label)}</h1></div>
          <div class="spacer"></div>
          <div class="faces" id="faces" title="Admins in the panel now"></div>
          <button class="btn small ghost" data-act="toggle-chime" aria-pressed="${CHIME}" title="Chime on new reports">${icon("bell")}${CHIME ? "Chime on" : "Chime off"}</button>
          <span class="live-pill glass" id="live-pill"><span class="dot off"></span>connecting</span>
        </div>
        <div id="stale"></div>
        <div id="view"><div class="skeleton" style="height:140px"></div></div>
      </main>
    </div>
    <nav class="tabbar" aria-label="Sections">
      <div class="pill glass">${TABS.map(([id, label]) => `<button data-act="go" data-to="${id}" ${id === current ? 'aria-current="page"' : ""} aria-label="${label}">${icon(id)}${label}${id === "reports" && OPEN_REPORTS ? `<span class="badge">${OPEN_REPORTS}</span>` : ""}</button>`).join("")}</div>
      <button class="more glass" data-act="more" aria-label="All sections">${icon("more")}</button>
    </nav>`;
}

async function boot() {
  try { ME = (await api("/admin/me")).user; } catch { return logout(); }
  document.getElementById("app").innerHTML = shell();
  paintFaces();
  startLive();
  refreshBadge();
  render();
}

async function render() {
  clearInterval(refreshTimer);
  const id = route();
  // Re-mark the nav without rebuilding the shell.
  document.querySelectorAll("[data-act=go]").forEach((b) => { if (b.dataset.to === id) b.setAttribute("aria-current", "page"); else b.removeAttribute("aria-current"); });
  const top = document.querySelector(".topbar");
  if (top) { top.querySelector(".sub").textContent = TITLES[id].group; top.querySelector("h1").textContent = TITLES[id].label; }
  document.title = `${TITLES[id].label} · Hunting Game Admin`;
  document.getElementById("stale").innerHTML = "";
  const view = document.getElementById("view");
  view.innerHTML = `<div class="skeleton" style="height:140px"></div>`;
  try {
    await VIEWS[id](view);
  } catch (e) {
    view.innerHTML = `<div class="card glass empty"><b>Couldn't load this section.</b>${esc(e.message)}<div style="margin-top:14px"><button class="btn small" data-act="reload">Try again</button></div></div>`;
  }
}

// ------------------------------------------------------------------ charts

function spark(values, color) {
  const max = Math.max(1, ...values), w = 100, h = 30;
  const pts = values.map((v, i) => `${(i / Math.max(1, values.length - 1)) * w},${h - (v / max) * (h - 3) - 1.5}`).join(" ");
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" aria-hidden="true">
    <polyline points="0,${h} ${pts} ${w},${h}" fill="${color}" fill-opacity=".12" stroke="none"/>
    <polyline points="${pts}" fill="none" stroke="${color}" stroke-width="1.6" vector-effect="non-scaling-stroke" stroke-linejoin="round"/></svg>`;
}
function bars(series, color) {
  const entries = Object.entries(series), max = Math.max(1, ...entries.map(([, v]) => v));
  return `<div class="bars" role="img" aria-label="Daily counts">${entries.map(([k, v]) => `<span title="${esc(day(k))}: ${v}" style="--c:${color};height:${Math.max(2, (v / max) * 100)}%"></span>`).join("")}</div>
    <div class="axis"><span>${esc(day(entries[0]?.[0]))}</span><span>${esc(day(entries.at(-1)?.[0]))}</span></div>`;
}
function splitRows(obj, color, labeler = pretty) {
  const entries = Object.entries(obj || {}).sort((a, b) => b[1] - a[1]);
  if (!entries.length) return `<div class="empty">Nothing yet.</div>`;
  const max = Math.max(1, ...entries.map(([, v]) => v));
  return entries.map(([k, v]) => `<div class="split-row"><span class="name">${labeler(k)}</span><span class="track"><i style="--c:${color};width:${(v / max) * 100}%"></i></span><span class="n">${num(v)}</span></div>`).join("");
}
const kpi = (label, value, delta, sparkHtml = "", color = "var(--text)") =>
  `<div class="card glass kpi"><div class="label">${label}</div><div class="value" style="color:${color}">${value}</div><div class="delta">${delta}</div>${sparkHtml}</div>`;

// ------------------------------------------------------------------ views

const VIEWS = {};

VIEWS.overview = async (view) => {
  const [s, a, r] = await Promise.all([api("/admin/stats"), api("/admin/analytics"), api("/admin/reports?status=OPEN")]);
  setOpenReports(s.openReports);
  const urgent = r.reports.filter((x) => URGENT.has(x.category));
  const queue = [...urgent, ...r.reports.filter((x) => !URGENT.has(x.category))].slice(0, 6);
  const sum = (o) => Object.values(o).reduce((x, y) => x + y, 0);
  view.innerHTML = `
    <div class="grid kpis">
      ${kpi("Players", num(s.users), `+${num(s.newUsersDay)} today · +${num(s.newUsersWeek)} this week`, spark(Object.values(a.signups), "#49D4FF"))}
      ${kpi("Online now", num(s.online), `${num(s.liveSessions)} live · ${num(s.lobbySessions)} in lobby`, "", "var(--runner)")}
      ${kpi("Matches · 30 days", num(sum(a.matches)), `${num(s.sessionsWeek)} this week`, spark(Object.values(a.matches), "#22C55E"))}
      ${kpi("Open reports", num(s.openReports), `${num(s.reportsWeek)} filed this week${urgent.length ? ` · <b style="color:#ff6b79">${urgent.length} urgent</b>` : ""}`, spark(Object.values(a.reports), "#F5A524"), s.openReports ? "var(--amber)" : "var(--text)")}
      ${kpi("Banned", num(s.banned), `${num(s.blocks)} block${s.blocks === 1 ? "" : "s"} between players`, "", s.banned ? "#ff6b79" : "var(--text)")}
    </div>
    <div class="section-gap"></div>
    <div class="grid two">
      <div class="card glass"><h2>Needs attention <span class="right">${queue.length ? "urgent first" : ""}</span></h2>
        ${queue.length ? `<div class="list" style="margin:0 -18px -18px">${queue.map(reportRow).join("")}</div>`
          : `<div class="empty"><b>All clear.</b>No open reports.</div>`}
      </div>
      <div class="card glass"><h2>Signups · 30 days</h2>${bars(a.signups, "#49D4FF")}</div>
      <div class="card glass"><h2>Matches · 30 days</h2>${bars(a.matches, "#22C55E")}</div>
      <div class="card glass"><h2>Modes played · 30 days</h2>${splitRows(a.modeSplit, "var(--runner)")}</div>
      <div class="card glass"><h2>Report categories · 30 days</h2>${splitRows(a.categorySplit, "var(--amber)")}</div>
    </div>`;
};

VIEWS.live = async (view) => {
  const paint = async () => {
    const l = await api("/admin/live");
    const countries = Object.entries(l.countries).sort((a, b) => b[1] - a[1]);
    view.innerHTML = `
      <div class="grid kpis">
        ${kpi("Players online", num(l.online), `${num(l.sockets)} open connections`, "", "var(--runner)")}
        ${kpi("Live matches", num(l.sessions.filter((x) => x.status === "ACTIVE").length), `${num(l.sessions.filter((x) => x.status === "LOBBY").length)} lobbies waiting`)}
        ${kpi("Countries", num(countries.length), "from connection headers")}
        ${kpi("Admins here", num(l.admins.length), esc(l.admins.join(", ") || "—"), "", "var(--purple)")}
      </div>
      <div class="section-gap"></div>
      <div class="grid two">
        <div class="list glass"><div class="row"><div class="grow"><div class="title">Running now</div><div class="meta">refreshes every 15 seconds</div></div></div>
          ${l.sessions.length ? l.sessions.map((x) => `<div class="row clickable" data-act="open-session" data-id="${esc(x.id)}">
            <span class="chip ${x.status === "ACTIVE" ? "live" : x.status === "LOBBY" ? "cyan" : "amber"}">${pretty(x.status)}</span>
            <div class="grow"><div class="title" style="font-family:var(--mono)">${esc(x.code)} · ${pretty(x.mode)}</div>
            <div class="meta">${x.hunters} hunters · ${x.runners} runners${x.spectators ? ` · ${x.spectators} watching` : ""}${x.caught ? ` · ${x.caught} caught` : ""}</div></div>
            <span class="meta">${x.startedAt ? "started " + ago(x.startedAt) : "opened " + ago(x.createdAt)}</span></div>`).join("")
            : `<div class="empty"><b>Quiet right now.</b>No lobby or match is open.</div>`}
        </div>
        <div class="card glass"><h2>Players online by country</h2>
          ${countries.length ? countries.map(([c, n]) => `<div class="split-row"><span class="name">${flag(c)} ${esc(countryName(c))}</span><span class="track"><i style="--c:var(--runner);width:${(n / countries[0][1]) * 100}%"></i></span><span class="n">${n}</span></div>`).join("")
            : `<div class="empty">No connections with a known country.</div>`}
          <div class="hint" style="margin-top:12px">Counts only. This panel never shows where a player is — the players include 13-year-olds.</div>
        </div>
      </div>`;
  };
  await paint();
  refreshTimer = setInterval(() => { if (route() === "live" && !document.hidden) paint().catch(() => {}); }, 15_000);
};

VIEWS.matches = async (view) => {
  const { sessions } = await api("/admin/sessions?status=" + STATE.sessionStatus);
  view.innerHTML = `
    <div class="toolbar">${segmented("session-status", ["ACTIVE", "LOBBY", "ENDED", "ALL"], STATE.sessionStatus)}</div>
    <div class="list glass">${sessions.length ? sessions.map((x) => `<div class="row clickable" data-act="open-session" data-id="${esc(x.id)}">
        <span class="chip ${x.status === "ACTIVE" ? "live" : x.status === "LOBBY" ? "cyan" : ""}">${pretty(x.status)}</span>
        <div class="grow"><div class="title" style="font-family:var(--mono)">${esc(x.code)} · ${pretty(x.mode)}</div>
          <div class="meta">${x.playerCount} players · host ${handle(x.players.find((p) => p.user?.id === x.hostId)?.user)}</div></div>
        <span class="meta">${x.endedAt && x.startedAt ? duration((new Date(x.endedAt) - new Date(x.startedAt)) / 1000) : ago(x.createdAt)}</span>
      </div>`).join("") : `<div class="empty"><b>No matches here.</b>Try another filter.</div>`}</div>`;
};

async function openSession(id) {
  const [{ sessions }, { events }] = await Promise.all([api("/admin/sessions?status=ALL"), api(`/admin/sessions/${id}/events`)]);
  const x = sessions.find((s) => s.id === id);
  if (!x) return fail("That match is no longer in the recent list.");
  openDrawer(`
    <div class="sub" style="font:700 10px/1 var(--mono);letter-spacing:.2em;color:var(--faint)">MATCH</div>
    <h3 style="font-family:var(--mono)">${esc(x.code)}</h3>
    <span class="chip ${x.status === "ACTIVE" ? "live" : ""}">${pretty(x.status)}</span> <span class="chip">${pretty(x.mode)}</span>
    <div class="section"><dl class="kv">
      <dt>Opened</dt><dd>${fmt(x.createdAt)}</dd><dt>Started</dt><dd>${fmt(x.startedAt)}</dd><dt>Ended</dt><dd>${fmt(x.endedAt)}</dd>
      <dt>Length</dt><dd>${x.startedAt && x.endedAt ? duration((new Date(x.endedAt) - new Date(x.startedAt)) / 1000) : "—"}</dd></dl></div>
    <div class="section"><div class="label">Roster · ${x.players.length}</div><div class="list glass">
      ${x.players.map((p) => `<div class="row clickable" data-act="open-user" data-id="${esc(p.user?.id || "")}"><div class="avatar">${initial(p.user)}</div>
        <div class="grow"><div class="title">${handle(p.user)}${p.user?.id === x.hostId ? ' <span class="chip amber">host</span>' : ""}</div>
        <div class="meta">${pretty(p.role)} · ${p.hearts} hearts${p.isCaught ? " · caught" : ""}${p.isJailed ? " · jailed" : ""}${p.isOut ? " · out" : ""}</div></div></div>`).join("")}</div></div>
    <div class="section"><div class="label">Event log · latest ${events.length}</div><div class="list glass">
      ${events.length ? events.slice(0, 80).map((e) => `<div class="row"><span class="chip ${e.type === "ANTI_CHEAT_FLAG" ? "red" : e.type === "CATCH" ? "amber" : ""}">${pretty(e.type)}</span>
        <div class="grow meta">${esc(eventSummary(e))}</div><span class="meta">${new Date(e.timestamp).toLocaleTimeString()}</span></div>`).join("") : `<div class="empty">No events recorded.</div>`}</div></div>
    ${x.status !== "ENDED" ? `<div class="section actions"><button class="btn danger" data-act="end-session" data-id="${esc(x.id)}" data-code="${esc(x.code)}">End this match</button></div>` : ""}`);
}
function eventSummary(e) {
  const p = e.payload || {};
  if (e.type === "ANTI_CHEAT_FLAG") return `${p.username}: ${p.reason}`;
  if (p.powerUpType) return pretty(p.powerUpType).replace(/&#39;/g, "'");
  return Object.entries(p).filter(([k]) => !/id$/i.test(k)).map(([k, v]) => `${k}: ${typeof v === "object" ? JSON.stringify(v) : v}`).join(" · ").slice(0, 140);
}

// ---------- reports

function reportRow(r, i) {
  return `<div class="row clickable ${STATE.selected === i && route() === "reports" ? "selected" : ""}" data-act="open-report" data-id="${esc(r.id)}" data-index="${i ?? ""}">
    <span class="chip ${URGENT.has(r.category) ? "urgent" : r.status === "OPEN" ? "open" : r.status === "RESOLVED" ? "green" : ""}">${pretty(r.category)}</span>
    <div class="grow"><div class="title">${handle(r.reported)}${r.totalAgainstReported > 1 ? ` <span class="chip red">${r.totalAgainstReported} reports</span>` : ""}</div>
      <div class="meta">by ${handle(r.reporter)}${r.reason ? " · " + esc(r.reason) : ""}</div></div>
    <span class="meta">${ago(r.createdAt)}</span></div>`;
}
let REPORTS = [];
VIEWS.reports = async (view) => {
  const q = `status=${STATE.reportStatus}&category=${STATE.reportCategory}`;
  const { reports } = await api("/admin/reports?" + q);
  // Urgent categories first, then oldest-waiting first within each, so nothing rots at the bottom.
  REPORTS = reports.sort((a, b) => (URGENT.has(b.category) - URGENT.has(a.category)) || (STATE.reportStatus === "OPEN" ? new Date(a.createdAt) - new Date(b.createdAt) : 0));
  if (STATE.reportStatus === "OPEN" && STATE.reportCategory === "ALL") setOpenReports(reports.length);
  STATE.selected = Math.min(STATE.selected, Math.max(0, REPORTS.length - 1));
  const cats = ["ALL", "CHEATING", "INAPPROPRIATE_USERNAME", "HARASSMENT", "THREATS", "SEXUAL_CONTENT", "IMPERSONATION", "UNSAFE_PLAY", "OTHER"];
  view.innerHTML = `
    <div class="toolbar">${segmented("report-status", ["OPEN", "RESOLVED", "DISMISSED", "ALL"], STATE.reportStatus)}
      <select class="input" style="width:auto" data-change="report-category" aria-label="Category">${cats.map((c) => `<option value="${c}" ${c === STATE.reportCategory ? "selected" : ""}>${c === "ALL" ? "Every category" : pretty(c)}</option>`).join("")}</select>
      <span class="hint">Keys: <b>J</b>/<b>K</b> move · <b>Enter</b> open · <b>R</b> resolve · <b>D</b> dismiss · <b>B</b> ban</span></div>
    <div class="list glass" id="report-list">${REPORTS.length ? REPORTS.map(reportRow).join("") : `<div class="empty"><b>Queue empty.</b>Nothing ${pretty(STATE.reportStatus)} in this category.</div>`}</div>`;
};
function selectReport(i) {
  STATE.selected = Math.max(0, Math.min(REPORTS.length - 1, i));
  document.querySelectorAll("#report-list .row").forEach((el, j) => el.classList.toggle("selected", j === STATE.selected));
  document.querySelectorAll("#report-list .row")[STATE.selected]?.scrollIntoView({ block: "nearest" });
}
async function openReport(id) {
  const r = REPORTS.find((x) => x.id === id) || (await api("/admin/reports?status=ALL")).reports.find((x) => x.id === id);
  if (!r) return fail("Report not found.");
  const history = r.reported ? await api(`/admin/users/${r.reported.id}`).catch(() => null) : null;
  const others = (history?.reportsAgainst || []).filter((x) => x.id !== r.id);
  openDrawer(`
    <div class="sub" style="font:700 10px/1 var(--mono);letter-spacing:.2em;color:var(--faint)">REPORT · ${fmt(r.createdAt)}</div>
    <h3>${pretty(r.category)}</h3>
    <span class="chip ${r.status === "OPEN" ? "open" : r.status === "RESOLVED" ? "green" : ""}">${pretty(r.status)}</span>
    ${URGENT.has(r.category) ? '<span class="chip urgent">urgent</span>' : ""}
    <div class="section"><dl class="kv">
      <dt>Reported</dt><dd>${r.reported ? `<a href="#" data-act="open-user" data-id="${esc(r.reported.id)}">${handle(r.reported)}</a>` : handle(null)}${r.reported?.isBanned ? ' <span class="chip ban">banned</span>' : ""}</dd>
      <dt>Filed by</dt><dd>${r.reporter ? `<a href="#" data-act="open-user" data-id="${esc(r.reporter.id)}">${handle(r.reporter)}</a>` : handle(null)}</dd>
      <dt>Against them</dt><dd>${r.totalAgainstReported} report${r.totalAgainstReported === 1 ? "" : "s"} in total</dd></dl></div>
    <div class="section"><div class="label">What they said</div><div class="quote">${r.reason ? esc(r.reason) : '<span class="hint">No detail — the category was the whole report.</span>'}</div></div>
    ${r.adminResponse ? `<div class="section"><div class="label">Our reply · ${fmt(r.respondedAt)}</div><div class="quote">${esc(r.adminResponse)}</div></div>` : ""}
    ${others.length ? `<div class="section"><div class="label">Other reports against this account</div><div class="list glass">${others.slice(0, 8).map((o) => `<div class="row"><span class="chip">${pretty(o.category)}</span><div class="grow meta">${esc(o.reason || "")}</div><span class="meta">${ago(o.createdAt)}</span></div>`).join("")}</div></div>` : ""}
    <div class="section actions">
      <button class="btn cyan" data-act="reply-report" data-id="${esc(r.id)}">Reply to reporter</button>
      ${r.status !== "RESOLVED" ? `<button class="btn" data-act="report-status" data-id="${esc(r.id)}" data-status="RESOLVED">Resolve <kbd>R</kbd></button>` : ""}
      ${r.status !== "DISMISSED" ? `<button class="btn" data-act="report-status" data-id="${esc(r.id)}" data-status="DISMISSED">Dismiss <kbd>D</kbd></button>` : ""}
      ${r.status !== "OPEN" ? `<button class="btn ghost" data-act="report-status" data-id="${esc(r.id)}" data-status="OPEN">Reopen</button>` : ""}
      ${r.reported && !r.reported.isBanned ? `<button class="btn danger" data-act="ban" data-id="${esc(r.reported.id)}" data-name="${esc(r.reported.username + "#" + r.reported.userTag)}" data-reason="${esc(pretty(r.category))}">Ban <kbd>B</kbd></button>` : ""}
      ${r.category === "INAPPROPRIATE_USERNAME" && r.reported ? `<button class="btn" data-act="rename" data-id="${esc(r.reported.id)}" data-current="${esc(r.reported.username)}">Rename</button>` : ""}
    </div>`);
}
async function setReportStatus(id, status) {
  await post(`/admin/reports/${id}/status`, { status });
  ok(status === "OPEN" ? "Report reopened." : `Report ${status.toLowerCase()}.`);
  if (drawerOpen()) closeDrawer();
  refreshBadge();
  if (route() === "reports") await VIEWS.reports(document.getElementById("view"));
}

// ---------- anti-cheat, usernames, bans

VIEWS.anticheat = async (view) => {
  const { players, recent } = await api("/admin/anticheat");
  view.innerHTML = `
    <div class="card glass" style="margin-bottom:14px"><div class="hint">Anti-cheat is a beta a host turns on per match. Each check is stored at most once a minute per player, so a count here is "minutes with a dropped fix", not raw GPS updates. One flag is usually bad signal; a pattern across matches is worth a look.</div></div>
    <div class="grid two">
      <div class="list glass">${players.length ? players.map((p) => `<div class="row clickable" data-act="open-user" data-id="${esc(p.userId)}">
          <div class="avatar" style="background:rgba(217,58,74,.15);color:#ff6b79">${esc(p.username.slice(0, 1).toUpperCase())}</div>
          <div class="grow"><div class="title">${esc(p.username)}</div><div class="meta">${Object.entries(p.checks).map(([k, v]) => `${pretty(k)} ${v}`).join(" · ")} · ${p.sessions.length} match${p.sessions.length === 1 ? "" : "es"}</div></div>
          <span class="chip red">${p.total}</span></div>`).join("") : `<div class="empty"><b>No flags.</b>Nothing has tripped a check yet.</div>`}</div>
      <div class="list glass"><div class="row"><div class="grow title">Latest flags</div></div>${recent.map((f) => `<div class="row"><span class="chip">${pretty(f.check)}</span>
          <div class="grow"><div class="title">${esc(f.username)} <span class="meta">· ${esc(f.code)}</span></div><div class="meta">${esc(f.reason)}</div></div><span class="meta">${ago(f.at)}</span></div>`).join("") || `<div class="empty">—</div>`}</div>
    </div>`;
};

VIEWS.usernames = async (view) => {
  const [{ flagged }, { terms }] = await Promise.all([api("/admin/usernames/flagged"), api("/admin/usernames/terms")]);
  view.innerHTML = `
    <div class="grid two">
      <div class="card glass"><h2>Test a name</h2>
        <div class="toolbar" style="margin:0"><input class="input" id="tn" placeholder="Try f_u_c_k, Cassandra…" style="flex:1;max-width:none" data-enter="test-name"><button class="btn primary" data-act="test-name">Check</button></div>
        <div id="tres" style="margin-top:12px" aria-live="polite"></div>
        <div class="hint" style="margin-top:12px">The filter folds leetspeak, separators and padding back to plain letters first, so f_u_c_k, fvck and fuuuck all land on one term.</div></div>
      <div class="card glass"><h2>Add a custom term</h2>
        <div class="toolbar" style="margin:0"><input class="input" id="nt" placeholder="A word or compound…" style="flex:1;max-width:none" data-enter="add-term">
          <select class="input" id="nk" style="width:auto"><option value="false">Block it</option><option value="true">Allow it</option></select>
          <button class="btn primary" data-act="add-term">Add</button></div>
        <div class="hint" style="margin-top:12px">Allow a word the built-in list wrongly catches, or block one it misses.</div></div>
    </div>
    <div class="section-gap"></div>
    <div class="grid two">
      <div class="list glass"><div class="row"><div class="grow title">Existing accounts that match · ${flagged.length}</div></div>
        ${flagged.length ? flagged.map((f) => `<div class="row clickable" data-act="open-user" data-id="${esc(f.id)}"><div class="grow"><div class="title">${esc(f.username)}#${esc(f.userTag)} ${f.isBanned ? '<span class="chip ban">banned</span>' : ""}</div>
          <div class="meta">matched “${esc(f.term)}” · ${pretty(f.category)}</div></div><span class="meta">${day(f.createdAt)}</span></div>`).join("") : `<div class="empty"><b>Clean.</b>No existing account matches the filter.</div>`}</div>
      <div class="list glass"><div class="row"><div class="grow title">Custom terms · ${terms.length}</div></div>
        ${terms.length ? terms.map((t) => `<div class="row"><span class="chip ${t.isAllowlist ? "green" : "red"}">${t.isAllowlist ? "allowed" : "blocked"}</span><div class="grow title" style="font-family:var(--mono)">${esc(t.term)}</div>
          <button class="btn small ghost" data-act="remove-term" data-id="${esc(t.id)}" data-term="${esc(t.term)}">Remove</button></div>`).join("") : `<div class="empty">Nothing custom yet — the built-in list is still active.</div>`}</div>
    </div>`;
};

VIEWS.bans = async (view) => {
  const { banned, history } = await api("/admin/bans");
  view.innerHTML = `<div class="grid two">
    <div class="list glass"><div class="row"><div class="grow title">Banned now · ${banned.length}</div></div>
      ${banned.length ? banned.map((u) => `<div class="row clickable" data-act="open-user" data-id="${esc(u.id)}"><div class="avatar" style="background:rgba(217,58,74,.15);color:#ff6b79">${initial(u)}</div>
        <div class="grow"><div class="title">${handle(u)}</div><div class="meta">${esc(u.banReason || "no reason given")} · ${ago(u.bannedAt)}</div></div>
        <button class="btn small" data-act="unban" data-id="${esc(u.id)}" data-name="${esc(u.username + "#" + u.userTag)}">Unban</button></div>`).join("") : `<div class="empty"><b>Nobody is banned.</b></div>`}</div>
    <div class="list glass"><div class="row"><div class="grow title">History</div></div>
      ${history.length ? history.map((h) => `<div class="row"><span class="chip ${h.action === "BAN" ? "ban" : "green"}">${pretty(h.action)}</span>
        <div class="grow"><div class="title">by ${esc(h.adminName)}</div><div class="meta">${esc(h.detail || "")}</div></div><span class="meta">${ago(h.createdAt)}</span></div>`).join("") : `<div class="empty">No bans recorded.</div>`}</div></div>`;
};

// ---------- players

VIEWS.players = async (view) => {
  view.innerHTML = `<div class="toolbar"><input class="input" id="uq" type="search" placeholder="Search username or name#1234" value="${esc(STATE.userQuery)}" aria-label="Search players">
    <button class="btn small" data-act="toggle-banned" aria-pressed="${STATE.userBanned}">${STATE.userBanned ? "Showing banned" : "Banned only"}</button></div>
    <div id="user-results"><div class="skeleton" style="height:200px"></div></div>`;
  let timer;
  document.getElementById("uq").addEventListener("input", (e) => { clearTimeout(timer); timer = setTimeout(() => { STATE.userQuery = e.target.value.trim(); loadUsers(); }, 250); });
  await loadUsers();
};
async function loadUsers() {
  const { users } = await api(`/admin/users?q=${encodeURIComponent(STATE.userQuery)}${STATE.userBanned ? "&banned=true" : ""}`);
  const el = document.getElementById("user-results");
  if (!el) return;
  el.innerHTML = `<div class="list glass">${users.length ? users.map((u) => `<div class="row clickable" data-act="open-user" data-id="${esc(u.id)}">
      <div class="avatar">${initial(u)}</div>
      <div class="grow"><div class="title">${handle(u)} ${u.isAdmin ? '<span class="chip admin">admin</span>' : ""} ${u.isBanned ? '<span class="chip ban">banned</span>' : ""}</div>
        <div class="meta">${u.matchesPlayed} matches · joined ${day(u.createdAt)}${u.reportsAgainst ? ` · <span style="color:var(--amber)">${u.reportsAgainst} reports</span>` : ""}</div></div>
      <span class="dot ${u.isOnline ? "" : "off"}" title="${u.isOnline ? "online" : "offline"}"></span></div>`).join("") : `<div class="empty"><b>No players match.</b></div>`}</div>`;
}

async function openUser(id) {
  if (!id) return;
  const d = await api(`/admin/users/${id}`);
  const u = d.user;
  openDrawer(`
    <div style="display:flex;gap:14px;align-items:center"><div class="avatar" style="width:54px;height:54px;font-size:22px">${initial(u)}</div>
      <div><h3>${handle(u)}</h3><span class="dot ${u.isOnline ? "" : "off"}" style="display:inline-block"></span> <span class="hint">${u.isOnline ? "online now" : "offline"}</span>
      ${u.isAdmin ? '<span class="chip admin">admin</span>' : ""} ${u.isBanned ? '<span class="chip ban">banned</span>' : ""}</div></div>
    <div class="section"><dl class="kv">
      <dt>Joined</dt><dd>${fmt(u.createdAt)}</dd>
      <dt>Devices</dt><dd>${d.deviceTokens} registered for push</dd>
      <dt>Friends</dt><dd>${d.friends.length}</dd>
      <dt>Blocks</dt><dd>${d.blocked.filter((b) => b.blockedByThisUser).length} by them · ${d.blocked.filter((b) => !b.blockedByThisUser).length} of them</dd>
      ${u.isBanned ? `<dt>Ban</dt><dd>${esc(u.banReason || "no reason")} · ${fmt(u.bannedAt)}</dd>` : ""}
      <dt>Account id</dt><dd style="font-family:var(--mono);font-size:11.5px">${esc(u.id)}</dd></dl></div>
    <div class="section actions">
      <button class="btn" data-act="rename" data-id="${esc(u.id)}" data-current="${esc(u.username)}">Rename</button>
      <button class="btn" data-act="retag" data-id="${esc(u.id)}" data-current="${esc(u.userTag)}">New tag</button>
      <button class="btn" data-act="message" data-id="${esc(u.id)}" data-name="${esc(u.username)}">Send message</button>
      ${u.isBanned ? `<button class="btn" data-act="unban" data-id="${esc(u.id)}" data-name="${esc(u.username + "#" + u.userTag)}">Unban</button>`
        : `<button class="btn danger" data-act="ban" data-id="${esc(u.id)}" data-name="${esc(u.username + "#" + u.userTag)}">Ban</button>`}
      <button class="btn ghost" data-act="toggle-admin" data-id="${esc(u.id)}" data-admin="${u.isAdmin}" data-name="${esc(u.username)}">${u.isAdmin ? "Remove admin" : "Make admin"}</button>
      <button class="btn danger" data-act="delete-user" data-id="${esc(u.id)}" data-name="${esc(u.username + "#" + u.userTag)}">Delete account</button></div>
    <div class="section"><div class="label">Reports against · ${d.reportsAgainst.length}</div>
      ${d.reportsAgainst.length ? `<div class="list glass">${d.reportsAgainst.slice(0, 10).map((r) => `<div class="row"><span class="chip ${r.status === "OPEN" ? "open" : ""}">${pretty(r.category)}</span><div class="grow meta">${esc(r.reason || "")}</div><span class="meta">${ago(r.createdAt)}</span></div>`).join("")}</div>` : `<div class="hint">None.</div>`}</div>
    <div class="section"><div class="label">Reports filed · ${d.reportsFiled.length}</div>
      ${d.reportsFiled.length ? `<div class="list glass">${d.reportsFiled.slice(0, 6).map((r) => `<div class="row"><span class="chip">${pretty(r.category)}</span><div class="grow meta">${esc(r.reason || "")}</div><span class="meta">${ago(r.createdAt)}</span></div>`).join("")}</div>` : `<div class="hint">None.</div>`}</div>
    <div class="section"><div class="label">Recent matches · ${d.matches.length}</div>
      ${d.matches.length ? `<div class="list glass">${d.matches.slice(0, 10).map((m) => `<div class="row clickable" data-act="open-session" data-id="${esc(m.sessionId)}"><span class="chip">${pretty(m.role)}</span><div class="grow"><div class="title" style="font-family:var(--mono)">${esc(m.code)} · ${pretty(m.mode)}</div><div class="meta">${m.isOut ? "out" : m.isCaught ? "caught" : `${m.hearts} hearts left`}</div></div><span class="meta">${ago(m.joinedAt)}</span></div>`).join("")}</div>` : `<div class="hint">Hasn't played yet.</div>`}</div>
    <div class="section"><div class="label">Moderation history</div>
      ${d.adminHistory.length ? `<div class="list glass">${d.adminHistory.map((h) => `<div class="row"><span class="chip">${pretty(h.action)}</span><div class="grow"><div class="meta">${esc(h.adminName)}${h.detail ? " · " + esc(h.detail) : ""}</div></div><span class="meta">${ago(h.createdAt)}</span></div>`).join("")}</div>` : `<div class="hint">No admin has acted on this account.</div>`}</div>`);
}

VIEWS.regulars = async (view) => {
  const i = await insights();
  const list = (rows, unit) => rows.length ? `<div class="list glass">${rows.map((r, n) => `<div class="row clickable" data-act="open-user" data-id="${esc(r.id)}">
      <span style="width:26px;font:800 15px/1 var(--rounded);color:${n === 0 ? "var(--amber)" : n < 3 ? "var(--text)" : "var(--faint)"}">${n + 1}</span>
      <div class="grow title">${esc(r.name)}</div><span class="chip cyan">${num(r.count)} ${unit}</span></div>`).join("")}</div>` : `<div class="empty">Nobody yet.</div>`;
  view.innerHTML = `<div class="grid two"><div><div class="nav-group" style="padding-left:4px">Most matches played · all time</div>${list(i.regulars.players, "matches")}</div>
    <div><div class="nav-group" style="padding-left:4px">Most matches hosted · 90 days</div>${list(i.regulars.hosts, "hosted")}</div></div>`;
};

VIEWS.growth = async (view) => {
  const [i, a] = await Promise.all([insights(), api("/admin/analytics")]);
  const g = i.growth, pct = (n) => (g.users ? Math.round((n / g.users) * 100) : 0);
  view.innerHTML = `
    <div class="grid kpis">
      ${kpi("Accounts", num(g.users), "all time")}
      ${kpi("Day-1 retention", g.day1 == null ? "—" : g.day1 + "%", "played again the day after signing up", "", "var(--cyan)")}
      ${kpi("Day-7 retention", g.day7 == null ? "—" : g.day7 + "%", "played on day 7", "", "var(--runner)")}
      ${kpi("Signups · 30 days", num(Object.values(a.signups).reduce((x, y) => x + y, 0)), "", spark(Object.values(a.signups), "#49D4FF"))}
    </div><div class="section-gap"></div>
    <div class="grid two">
      <div class="card glass funnel"><h2>Funnel</h2>
        ${[["Signed up", g.users], ["Played a match", g.played], ["Played 3 or more", g.regular]].map(([label, n]) => `<div class="step"><div class="bar" style="width:${Math.max(12, pct(n))}%">${num(n)}</div><span class="hint">${label} · ${pct(n)}%</span></div>`).join("")}
        <div class="hint" style="margin-top:8px">Retention counts a day as active when the player joined a match that day — the only per-player activity the server records.</div></div>
      <div class="card glass"><h2>Signups · 30 days</h2>${bars(a.signups, "#49D4FF")}</div>
    </div>`;
};

VIEWS.broadcast = async (view) => {
  view.innerHTML = `<div class="grid two">
    <div class="card glass"><h2>New announcement</h2>
      <div class="field"><label for="bt">Title</label><input class="input" id="bt" maxlength="60" placeholder="New mode this weekend"></div>
      <div class="field"><label for="bb">Message</label><textarea class="input" id="bb" maxlength="300" placeholder="What players will read on their lock screen."></textarea></div>
      <label class="hint" style="display:flex;gap:8px;align-items:center;margin-bottom:14px"><input type="checkbox" id="bo"> Only players online right now</label>
      <button class="btn primary" data-act="send-broadcast">Send push</button></div>
    <div class="card glass"><h2>Preview · iPhone lock screen</h2>
      <div style="padding:18px;border-radius:22px;background:linear-gradient(160deg,#1d2533,#0d1119)">
        <div class="glass" style="border-radius:20px;padding:12px 14px;display:flex;gap:10px;align-items:flex-start">
          <img src="/assets/apple-touch-icon.png" alt="" style="width:36px;height:36px;border-radius:9px">
          <div style="min-width:0;flex:1"><div style="display:flex;justify-content:space-between;font-size:12px;color:var(--muted)"><b style="color:var(--text)">HUNTING GAME</b><span>now</span></div>
            <div id="pt" style="font-weight:600;margin-top:2px">Title</div><div id="pb" style="color:var(--muted);font-size:13px;overflow-wrap:anywhere">Your message appears here.</div></div></div></div>
      <div class="hint" style="margin-top:12px">Banned accounts are skipped. Every broadcast is written to the audit trail with its recipient count.</div></div></div>`;
  const sync = () => { document.getElementById("pt").textContent = document.getElementById("bt").value || "Title"; document.getElementById("pb").textContent = document.getElementById("bb").value || "Your message appears here."; };
  ["bt", "bb"].forEach((id) => document.getElementById(id).addEventListener("input", sync));
};

// ---------- insights

async function insights() {
  if (!insightsCache || Date.now() - insightsCache.at > 5 * 60_000) insightsCache = { at: Date.now(), data: await api("/admin/insights") };
  return insightsCache.data;
}

VIEWS.modes = async (view) => {
  const i = await insights();
  const modes = Object.entries(i.modes);
  view.innerHTML = `<div class="grid kpis">${modes.map(([m, v]) => kpi(pretty(m), num(v.matches), `${v.finished} finished · ${v.avgMinutes == null ? "—" : Math.round(v.avgMinutes) + " min average"}`)).join("") || `<div class="card glass empty">No matches in 90 days.</div>`}</div>
    <div class="section-gap"></div>
    <div class="grid two"><div class="card glass"><h2>Matches by mode · 90 days</h2>${splitRows(Object.fromEntries(modes.map(([m, v]) => [m, v.matches])), "var(--runner)")}</div>
      <div class="card glass"><h2>Match length hosts pick</h2>${splitRows(i.durations, "var(--cyan)", esc)}</div></div>`;
};

VIEWS.powerups = async (view) => {
  const i = await insights();
  const COLORS = { INVISIBILITY_10MIN: "#A78BFA", GHOST_DECOY: "#49D4FF", EMP_JAMMER: "#F5A524", THERMAL_VISION: "#D93A4A", ADRENALINE: "#22C55E", SAFE_ZONE_FLARE: "#F5A524" };
  const rows = Object.entries(i.power).sort((a, b) => b[1].spawned - a[1].spawned);
  view.innerHTML = `<div class="table-wrap glass"><table><thead><tr><th>Power-up</th><th class="num">Spawned</th><th class="num">Picked up</th><th class="num">Pickup rate</th><th class="num">Used</th><th class="num">Use rate</th></tr></thead><tbody>
    ${rows.length ? rows.map(([t, v]) => `<tr><td><span class="dot" style="display:inline-block;margin-right:8px;background:${COLORS[t] || "var(--gray)"};box-shadow:0 0 8px ${COLORS[t] || "transparent"}"></span>${pretty(t)}</td>
      <td class="num">${num(v.spawned)}</td><td class="num">${num(v.collected)}</td><td class="num">${v.spawned ? Math.round((v.collected / v.spawned) * 100) + "%" : "—"}</td>
      <td class="num">${num(v.used)}</td><td class="num">${v.collected ? Math.round((v.used / v.collected) * 100) + "%" : "—"}</td></tr>`).join("") : `<tr><td colspan="6" class="empty">No power-ups in 90 days.</td></tr>`}
    </tbody></table></div><div class="hint" style="margin-top:10px">Last 90 days. A low pickup rate usually means spawns land somewhere players can't reach.</div>`;
};

VIEWS.peak = async (view) => {
  const i = await insights();
  const max = Math.max(1, ...i.heat.flat());
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  view.innerHTML = `<div class="card glass"><h2>Match starts · weekday × hour (UTC) · 90 days</h2><div style="overflow-x:auto"><div class="heat" style="min-width:560px">
      <span></span>${Array.from({ length: 24 }, (_, h) => `<span style="text-align:center">${h % 3 === 0 ? h : ""}</span>`).join("")}
      ${i.heat.map((row, d) => `<span>${days[d]}</span>${row.map((v, h) => `<i title="${days[d]} ${h}:00 — ${v} match${v === 1 ? "" : "es"}" style="--a:${v ? 0.12 + (v / max) * 0.88 : 0.04}"></i>`).join("")}`).join("")}
    </div></div><div class="hint" style="margin-top:12px">Germany is UTC+1 in winter, UTC+2 in summer.</div></div>`;
};

// ---------- system

VIEWS.team = async (view) => {
  const { team } = await api("/admin/team");
  view.innerHTML = `<div class="list glass">${team.map((u) => `<div class="row clickable" data-act="open-user" data-id="${esc(u.id)}">
      <div class="avatar" style="background:rgba(167,139,250,.18);color:var(--purple)">${initial(u)}</div>
      <div class="grow"><div class="title">${handle(u)} ${u.id === ME?.id ? '<span class="chip cyan">you</span>' : ""}</div><div class="meta">${num(u.actions)} actions · last ${ago(u.lastAction)}</div></div>
      ${u.inPanel ? '<span class="chip live">in the panel</span>' : ""}</div>`).join("")}</div>
    <div class="hint" style="margin-top:12px">Give someone access from their player page with “Make admin”. Access is checked against the database on every request, so removing it takes effect immediately.</div>`;
};

VIEWS.server = async (view) => {
  const s = await api("/admin/server");
  const usedMem = s.host.totalMemory - s.host.freeMemory;
  view.innerHTML = `<div class="grid kpis">
      ${kpi("Load · 1 min", s.host.loadAverage[0].toFixed(2), `${s.host.cpus} cores · 5m ${s.host.loadAverage[1].toFixed(2)} · 15m ${s.host.loadAverage[2].toFixed(2)}`, "", s.host.loadAverage[0] > s.host.cpus ? "var(--amber)" : "var(--runner)")}
      ${kpi("Memory", Math.round((usedMem / s.host.totalMemory) * 100) + "%", `${bytes(usedMem)} of ${bytes(s.host.totalMemory)}`)}
      ${kpi("Database", bytes(s.database.bytes), "PostgreSQL")}
      ${kpi("Sockets", num(s.sockets), "open connections", "", "var(--cyan)")}
      ${kpi("Backend up", duration(s.process.uptimeSeconds), `since ${fmt(s.process.startedAt)}`)}
      ${kpi("Server up", duration(s.host.uptimeSeconds), `${s.process.node} · ${bytes(s.process.rss)} RSS`)}
    </div><div class="section-gap"></div>
    <div class="table-wrap glass"><table><thead><tr><th>Table</th><th class="num">Rows</th></tr></thead><tbody>${s.database.tables.map((t) => `<tr><td style="font-family:var(--mono)">${esc(t.name)}</td><td class="num">${num(t.rows)}</td></tr>`).join("")}</tbody></table></div>`;
};

VIEWS.audit = async (view) => {
  const { actions } = await api("/admin/audit");
  const kinds = [...new Set(actions.map((a) => a.action))].sort();
  view.innerHTML = `<div class="toolbar"><input class="input" id="aq" type="search" placeholder="Filter by admin, target or detail" value="${esc(STATE.auditQuery)}" aria-label="Filter">
      <select class="input" id="ak" style="width:auto" aria-label="Action"><option value="">Every action</option>${kinds.map((k) => `<option value="${esc(k)}">${pretty(k)}</option>`).join("")}</select></div>
    <div class="list glass" id="audit-list"></div>`;
  const paint = () => {
    const q = document.getElementById("aq").value.toLowerCase(), k = document.getElementById("ak").value;
    STATE.auditQuery = q;
    const rows = actions.filter((a) => (!k || a.action === k) && (!q || [a.adminName, a.targetId, a.detail, a.targetType].join(" ").toLowerCase().includes(q)));
    document.getElementById("audit-list").innerHTML = rows.length ? rows.map((a) => `<div class="row ${a.targetType === "USER" ? "clickable" : ""}" ${a.targetType === "USER" ? `data-act="open-user" data-id="${esc(a.targetId)}"` : ""}>
        <span class="chip ${/BAN|DELETE|REVOKE/.test(a.action) ? "red" : /UNBAN|GRANT/.test(a.action) ? "green" : ""}">${pretty(a.action)}</span>
        <div class="grow"><div class="title">${esc(a.adminName)} <span class="meta">→ ${pretty(a.targetType)}</span></div><div class="meta">${esc(a.detail || a.targetId)}</div></div>
        <span class="meta" title="${esc(fmt(a.createdAt))}">${ago(a.createdAt)}</span></div>`).join("") : `<div class="empty"><b>Nothing matches.</b></div>`;
  };
  document.getElementById("aq").addEventListener("input", paint);
  document.getElementById("ak").addEventListener("change", paint);
  paint();
};

function segmented(name, options, current) {
  return `<div class="segmented" role="group">${options.map((o) => `<button data-act="seg" data-name="${name}" data-value="${o}" aria-pressed="${o === current}">${pretty(o)}</button>`).join("")}</div>`;
}

// ------------------------------------------------------------------ actions

async function reloadCurrent() {
  if (drawerOpen()) closeDrawer();
  await render();
}

const ACTIONS = {
  go: (d) => { if (drawerOpen()) closeDrawer(); location.hash = "#/" + d.to; },
  reload: () => render(),
  logout: () => logout(),
  more: () => openDrawer(`<h3>All sections</h3><div class="menu-sheet">${NAV.map(([g, items]) => `<div class="nav-group">${g}</div>` + items.map(([id, label]) => `<button class="nav-item" data-act="go" data-to="${id}" ${id === route() ? 'aria-current="page"' : ""}>${icon(id)}${label}</button>`).join("")).join("")}
    <div class="section"><button class="btn" data-act="logout">Sign out ${handle(ME)}</button></div></div>`),
  "close-drawer": () => closeDrawer(),
  "toggle-chime": (_d, el) => { CHIME = !CHIME; safeSet("hg_admin_chime", CHIME ? "1" : "0"); el.setAttribute("aria-pressed", CHIME); el.innerHTML = icon("bell") + (CHIME ? "Chime on" : "Chime off"); if (CHIME) chime(); },
  seg: (d) => {
    if (d.name === "report-status") { STATE.reportStatus = d.value; STATE.selected = 0; }
    if (d.name === "session-status") STATE.sessionStatus = d.value;
    render();
  },
  "toggle-banned": () => { STATE.userBanned = !STATE.userBanned; render(); },
  "open-session": (d) => openSession(d.id),
  "open-user": (d) => openUser(d.id),
  "open-report": (d) => { if (d.index !== "") STATE.selected = Number(d.index); openReport(d.id); },
  "report-status": (d) => setReportStatus(d.id, d.status),
  "reply-report": async (d) => {
    const message = await ask({ title: "Reply to the reporter", text: "They get this as a push notification, and it's kept on the report. Replying to an open report marks it resolved.", input: { label: "Message", multiline: true, maxlength: 1000, placeholder: "Thanks for reporting this. We've…" }, confirm: "Send reply" });
    if (!message) return;
    await post(`/admin/reports/${d.id}/respond`, { message });
    ok("Reply sent."); closeDrawer(); refreshBadge(); if (route() === "reports") VIEWS.reports(document.getElementById("view"));
  },
  ban: async (d) => {
    const reason = await ask({ title: `Ban ${d.name}?`, text: "They're signed out of any match immediately and can't sign in again until unbanned. The reason is shown to them.", input: { label: "Reason", value: d.reason || "", maxlength: 500, required: false, placeholder: "e.g. repeated harassment" }, confirm: "Ban account", danger: true });
    if (reason === null) return;
    await post(`/admin/users/${d.id}/ban`, reason ? { reason } : {});
    ok(`${d.name} is banned.`); await reloadCurrent();
  },
  unban: async (d) => {
    if (!(await ask({ title: `Unban ${d.name}?`, text: "They can sign in and play again straight away.", confirm: "Unban" }))) return;
    await post(`/admin/users/${d.id}/unban`); ok(`${d.name} is unbanned.`); await reloadCurrent();
  },
  rename: async (d) => {
    const username = await ask({ title: "Rename this account", text: "They keep their tag and get a push saying a moderator changed their name. It doesn't use up their own rename cooldown.", input: { label: "New username", value: d.current, maxlength: 20 }, confirm: "Rename",
      validate: (v) => (v === d.current ? "That's the current name." : "") });
    if (!username) return;
    await post(`/admin/users/${d.id}/rename`, { username }); ok("Renamed."); await reloadCurrent();
  },
  retag: async (d) => {
    const userTag = await ask({ title: "Give this account a new tag", text: "Moves a player off a friend code someone is using to harass them. Leave “random” to pick a free one.", input: { label: "Tag", value: "random", maxlength: 6, hint: `Current tag: #${d.current}` }, confirm: "Change tag",
      validate: (v) => (v === "random" || /^\d{4}$/.test(v) ? "" : "Use four digits, or “random”.") });
    if (!userTag) return;
    await post(`/admin/users/${d.id}/rename`, { userTag }); ok("Tag changed."); await reloadCurrent();
  },
  message: async (d) => {
    const body = await ask({ title: `Message ${d.name}`, text: "Sent as a push notification from Hunting Game.", input: { label: "Message", multiline: true, maxlength: 300 }, confirm: "Send" });
    if (!body) return;
    await post(`/admin/users/${d.id}/message`, { title: "A message from the Hunting Game team", body }); ok("Message sent.");
  },
  "toggle-admin": async (d) => {
    const grant = d.admin !== "true";
    if (!(await ask({ title: grant ? `Make ${d.name} an admin?` : `Remove ${d.name}'s admin access?`, text: grant ? "They get this whole panel, including bans and account deletion." : "They lose access on their next request.", confirm: grant ? "Make admin" : "Remove access", danger: !grant }))) return;
    await post(`/admin/users/${d.id}/admin`, { isAdmin: grant }); ok(grant ? "Admin access granted." : "Admin access removed."); await reloadCurrent();
  },
  "delete-user": async (d) => {
    const typed = await ask({ title: `Delete ${d.name}?`, text: "This removes the account, friendships, invites and match history for good. Reports about them are kept. It can't be undone.", input: { label: "Type the username#tag to confirm", placeholder: d.name, maxlength: 40 }, confirm: "Delete forever", danger: true,
      validate: (v) => (v === d.name ? "" : "That doesn't match.") });
    if (!typed) return;
    await api(`/admin/users/${d.id}`, { method: "DELETE" }); ok("Account deleted."); await reloadCurrent();
  },
  "end-session": async (d) => {
    if (!(await ask({ title: `End match ${d.code}?`, text: "Every player sees the match end right away.", confirm: "End match", danger: true }))) return;
    await post(`/admin/sessions/${d.id}/end`); ok(`Match ${d.code} ended.`); await reloadCurrent();
  },
  "test-name": async () => {
    const name = document.getElementById("tn").value.trim();
    if (!name) return;
    const { verdict } = await api("/admin/usernames/test?name=" + encodeURIComponent(name));
    document.getElementById("tres").innerHTML = verdict.allowed ? `<span class="chip green">allowed</span> <span class="hint">${esc(name)} would be accepted.</span>`
      : `<span class="chip red">blocked</span> <span class="hint">matched <b style="font-family:var(--mono)">${esc(verdict.term)}</b> · ${pretty(verdict.category)}</span>`;
  },
  "add-term": async () => {
    const term = document.getElementById("nt").value.trim();
    if (term.length < 2) return fail("A term needs at least two characters.");
    await post("/admin/usernames/terms", { term, isAllowlist: document.getElementById("nk").value === "true" }); ok(`“${term}” added.`); render();
  },
  "remove-term": async (d) => {
    if (!(await ask({ title: `Remove “${d.term}”?`, text: "The built-in list stays active either way.", confirm: "Remove", danger: true }))) return;
    await api(`/admin/usernames/terms/${d.id}`, { method: "DELETE" }); ok("Term removed."); render();
  },
  "send-broadcast": async () => {
    const title = document.getElementById("bt").value.trim(), body = document.getElementById("bb").value.trim(), onlineOnly = document.getElementById("bo").checked;
    if (!title || !body) return fail("A broadcast needs a title and a message.");
    if (!(await ask({ title: "Send this to " + (onlineOnly ? "everyone online" : "every player") + "?", text: `“${title}” — ${body}`, confirm: "Send push" }))) return;
    const { sent } = await post("/admin/broadcast", { title, body, onlineOnly });
    ok(`Sent to ${sent} player${sent === 1 ? "" : "s"}.`); document.getElementById("bt").value = ""; document.getElementById("bb").value = "";
  },
  "show-latest": () => render(),
};

document.addEventListener("click", async (e) => {
  const el = e.target.closest("[data-act]");
  if (!el) {
    if (e.target.id === "scrim") closeDrawer();
    return;
  }
  e.preventDefault();
  const fn = ACTIONS[el.dataset.act];
  if (!fn) return;
  el.disabled = true;
  try { await fn(el.dataset, el); } catch (err) { fail(err); } finally { el.disabled = false; }
});
document.addEventListener("change", (e) => {
  if (e.target.dataset.change === "report-category") { STATE.reportCategory = e.target.value; STATE.selected = 0; render(); }
});
document.addEventListener("keydown", (e) => {
  if (e.target.matches?.("[data-enter]") && e.key === "Enter") { e.preventDefault(); ACTIONS[e.target.dataset.enter]().catch(fail); return; }
  if (document.querySelector("dialog[open]")) return;
  if (e.key === "Escape" && drawerOpen()) return closeDrawer();
  if (route() !== "reports" || e.target.matches?.("input, textarea, select") || e.metaKey || e.ctrlKey || e.altKey) return;
  const r = REPORTS[STATE.selected];
  const k = e.key.toLowerCase();
  if (k === "j") selectReport(STATE.selected + 1);
  else if (k === "k") selectReport(STATE.selected - 1);
  else if (k === "enter" && r) openReport(r.id).catch(fail);
  else if (k === "r" && r && r.status !== "RESOLVED") setReportStatus(r.id, "RESOLVED").catch(fail);
  else if (k === "d" && r && r.status !== "DISMISSED") setReportStatus(r.id, "DISMISSED").catch(fail);
  else if (k === "b" && r?.reported && !r.reported.isBanned) ACTIONS.ban({ id: r.reported.id, name: r.reported.username + "#" + r.reported.userTag, reason: pretty(r.category) }).catch(fail);
  else return;
  e.preventDefault();
});
addEventListener("hashchange", () => { if (TOKEN && ME) render(); });

// ------------------------------------------------------------------ live layer

function startLive() {
  if (socket || typeof io !== "function") { setLivePill(false); return; }
  socket = io(API, { auth: { token: TOKEN }, transports: ["websocket"] });
  socket.on("connect", () => { setLivePill(true); socket.emit("admin_subscribe"); });
  socket.on("disconnect", () => setLivePill(false));
  socket.on("connect_error", () => setLivePill(false));
  socket.on("admin_event", onAdminEvent);
}
function stopLive() { if (socket) { socket.disconnect(); socket = null; } }
function setLivePill(on) {
  const el = document.getElementById("live-pill");
  if (el) el.innerHTML = `<span class="dot ${on ? "" : "off"}"></span>${on ? "live" : "offline"}`;
}
function paintFaces() {
  const el = document.getElementById("faces");
  if (!el) return;
  const others = ADMINS.filter((n) => n !== ME?.username);
  el.innerHTML = others.map((n) => `<span class="face" title="${esc(n)} is in the panel">${esc(n.slice(0, 1).toUpperCase())}</span>`).join("");
}
function onAdminEvent(ev) {
  if (ev.kind === "presence") { ADMINS = ev.admins || []; paintFaces(); return; }
  insightsCache = null;
  const view = route();
  if (ev.kind === "report") {
    setOpenReports(OPEN_REPORTS + 1);
    if (CHIME) chime();
    toast(`<span class="chip ${URGENT.has(ev.category) ? "urgent" : "open"}">${pretty(ev.category)}</span> New report — tap to open`, "event", () => { location.hash = "#/reports"; });
    if (view === "reports" || view === "overview") staleBar("A new report came in.");
  } else if (ev.kind === "signup") {
    toast(`<span class="dot"></span>${esc(ev.username)} just signed up`, "event", () => { location.hash = "#/players"; });
    if (view === "overview" || view === "players") staleBar("A new player signed up.");
  } else if (ev.kind === "match") {
    toast(`<span class="dot"></span>Match ${esc(ev.code)} started · ${pretty(ev.mode)}`, "event", () => { location.hash = "#/live"; });
    if (view === "matches") staleBar("A match just started.");
  } else if (ev.kind === "anticheat") {
    if (view === "anticheat") staleBar(`${ev.username} tripped the ${String(ev.check).toLowerCase()} check.`);
  }
}
function staleBar(text) {
  const el = document.getElementById("stale");
  if (el) el.innerHTML = `<div class="stale-bar glass"><span class="dot"></span><span class="grow">${esc(text)}</span><button class="btn small" data-act="show-latest">Show the latest</button></div>`;
}
let audioCtx;
function chime() {
  try {
    audioCtx ||= new AudioContext();
    const t = audioCtx.currentTime;
    [880, 1320].forEach((f, i) => {
      const o = audioCtx.createOscillator(), g = audioCtx.createGain();
      o.frequency.value = f; o.type = "sine";
      g.gain.setValueAtTime(0, t + i * 0.12); g.gain.linearRampToValueAtTime(0.08, t + i * 0.12 + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, t + i * 0.12 + 0.5);
      o.connect(g).connect(audioCtx.destination); o.start(t + i * 0.12); o.stop(t + i * 0.12 + 0.55);
    });
  } catch {}
}

// The open-report count on the nav, the phone tab bar and the home-screen icon badge.
function setOpenReports(n) {
  OPEN_REPORTS = Math.max(0, n);
  document.querySelectorAll('[data-to="reports"]').forEach((b) => {
    b.querySelector(".count, .badge")?.remove();
    if (OPEN_REPORTS) b.insertAdjacentHTML("beforeend", b.closest(".tabbar") ? `<span class="badge">${OPEN_REPORTS}</span>` : `<span class="count">${OPEN_REPORTS}</span>`);
  });
  try { OPEN_REPORTS ? navigator.setAppBadge?.(OPEN_REPORTS) : navigator.clearAppBadge?.(); } catch {}
}
async function refreshBadge() { try { setOpenReports((await api("/admin/stats")).openReports); } catch {} }
setInterval(() => { if (TOKEN && ME && !document.hidden) refreshBadge(); }, 120_000);

// ------------------------------------------------------------------ start

if ("serviceWorker" in navigator) navigator.serviceWorker.register("/admin/sw.js", { scope: "/admin/" }).catch(() => {});
if (TOKEN) boot(); else renderLogin();
