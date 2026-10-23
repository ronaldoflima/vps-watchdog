"use strict";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* storage unavailable */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* storage unavailable */ } },
};

let token = store.get("cwp-token") || "";
let status = null;
let samples = [];
let creditSamples = [];
let range = Number(new URLSearchParams(location.search).get("range")) || Number(store.get("cwp-range")) || 3600;
let config = null;
let cfgEdits = {};
let tab = store.get("cwp-tab") || "overview";

async function api(path, body) {
  const opts = { headers: { Authorization: "Bearer " + token } };
  if (body !== undefined) {
    opts.method = "POST";
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(path, opts);
  if (r.status === 401) { showLogin("Invalid or expired token."); throw new Error("unauthorized"); }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || r.statusText);
  return data;
}

function toast(msg, err = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast" + (err ? " err" : "");
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { t.hidden = true; }, err ? 9000 : 5000);
}

async function act(path, body, confirmMsg) {
  if (confirmMsg && !confirm(confirmMsg)) return null;
  try {
    const r = await api(path, body);
    toast(r.message || "Done.");
    refresh();
    return r;
  } catch (e) {
    if (e.message !== "unauthorized") toast(e.message, true);
    return null;
  }
}

/* ---------- formatting ---------- */

const fmtPct = (v, d = 0) => (v == null || isNaN(v) ? "–" : Number(v).toFixed(d) + "%");
const fmtMB = (mb) => (mb == null ? "–" : mb >= 1024 ? (mb / 1024).toFixed(1) + " GB" : Math.round(mb) + " MB");
function fmtAge(sec) {
  if (sec == null || sec < 0) return "–";
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  if (d) return d + "d " + h + "h";
  if (h) return h + "h " + m + "m";
  return m + "m " + (sec % 60) + "s";
}
function fmtLeft(sec) {
  sec = Math.max(0, Math.round(sec));
  const m = Math.floor(sec / 60), s = sec % 60;
  return m + ":" + String(s).padStart(2, "0");
}
function level(v, warn, crit) {
  if (v == null) return "good";
  if (v >= crit) return "critical";
  if (v >= warn) return "warning";
  return "good";
}
const levelText = { good: "OK", warning: "Elevated", serious: "High", critical: "Critical" };

/* ---------- duration selects ---------- */

const DURATIONS = [["", "permanently"], ["5", "for 5 min"], ["10", "for 10 min"], ["15", "for 15 min"],
  ["30", "for 30 min"], ["60", "for 1 h"], ["120", "for 2 h"], ["240", "for 4 h"]];
function fillDurations() {
  for (const sel of $$("select.duration")) {
    sel.innerHTML = DURATIONS.map(([v, l]) => `<option value="${v}">${l}</option>`).join("");
  }
  $("#q-quota-dur").value = "10";
  $("#q-pause-dur").value = "10";
  $("#free-dur").value = "30";
  $("#q-gov-dur").value = "";
}
const dur = (sel) => ($(sel).value ? Number($(sel).value) : 0);

/* ---------- login / tabs ---------- */

function showLogin(msg = "") {
  $("#app").hidden = true;
  $("#login").hidden = false;
  $("#login-error").textContent = msg;
  $("#token").focus();
}

$("#login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  token = $("#token").value.trim();
  try {
    await api("/api/status");
    store.set("cwp-token", token);
    start();
  } catch (err) {
    if (err.message !== "unauthorized") $("#login-error").textContent = err.message;
  }
});
$("#logout").addEventListener("click", () => { store.del("cwp-token"); token = ""; showLogin(); });

function setTab(name) {
  tab = name;
  store.set("cwp-tab", name);
  for (const b of $$("#tabs button")) b.classList.toggle("active", b.dataset.tab === name);
  for (const s of $$("main > section")) s.hidden = s.dataset.panel !== name;
  if (name === "config" && !config) loadConfig();
  if (name === "watchdog") loadLog();
  if (name === "overview") setTimeout(renderCharts, 0);
  render();
}
$("#tabs").addEventListener("click", (e) => { if (e.target.dataset.tab) setTab(e.target.dataset.tab); });

/* ---------- polling ---------- */

let polling = null;
async function refresh() {
  try {
    status = await api("/api/status");
    $("#updated").textContent = "updated " + new Date().toLocaleTimeString();
    render();
  } catch (e) {
    if (e.message !== "unauthorized") $("#updated").textContent = "offline: " + e.message;
  }
}
async function refreshHistory() {
  try {
    samples = await api(`/api/history?range=${range}`);
    creditSamples = status?.credits_enabled ? await api(`/api/credits?range=${range}`) : [];
    renderCharts();
  } catch { /* next poll retries */ }
}

let historyTimer = null;
function scheduleHistory() {
  clearInterval(historyTimer);
  historyTimer = setInterval(refreshHistory, range <= 10800 ? 15000 : 60000);
}

function setRange(r) {
  range = r;
  store.set("cwp-range", String(r));
  for (const b of $$("#range button")) b.classList.toggle("active", Number(b.dataset.range) === r);
  $("#range-note").textContent = r > 3600 ? "minute averages" : "3 s samples";
  refreshHistory();
  scheduleHistory();
}
$("#range").addEventListener("click", (e) => { if (e.target.dataset.range) setRange(Number(e.target.dataset.range)); });
function start() {
  $("#login").hidden = true;
  $("#app").hidden = false;
  setTab(tab);
  refresh().then(() => setRange(range));
  clearInterval(polling);
  polling = setInterval(() => { refresh(); }, 3000);
  setInterval(renderOverrides, 1000);
}

/* ---------- rendering ---------- */

function render() {
  if (!status) return;
  $("#hostname").textContent = status.hostname;
  const mode = status.watchdog.thresholds.MODE || "active";
  const badge = $("#mode-badge");
  badge.textContent = mode;
  badge.className = "badge " + mode;
  renderOverrides();
  if (tab === "overview") renderOverview();
  if (tab === "processes") renderProcs();
  if (tab === "watchdog") renderWatchdog();
  if (tab === "services") renderServices();
}

function renderOverrides() {
  const box = $("#overrides");
  const list = status?.overrides || [];
  if (!list.length) { box.hidden = true; box.innerHTML = ""; return; }
  box.hidden = false;
  const now = Date.now() / 1000;
  const html = list.map((o) => `
    <div class="override">
      <span class="dot warning"></span>
      <span>Temporary: <b>${esc(o.label)}</b></span>
      <span class="muted">reverts in</span>
      <span class="when">${fmtLeft(o.expires - now)}</span>
      <span class="spacer"></span>
      <button class="small" data-ov="extend" data-id="${esc(o.id)}">+10 min</button>
      <button class="small" data-ov="revert" data-id="${esc(o.id)}">Revert now</button>
      <button class="small" data-ov="keep" data-id="${esc(o.id)}">Keep permanently</button>
    </div>`).join("");
  if (box.dataset.html !== html) { box.innerHTML = html; box.dataset.html = html; }
}
$("#overrides").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-ov]");
  if (!b) return;
  const o = (status?.overrides || []).find((x) => x.id === b.dataset.id);
  const body = { id: b.dataset.id, op: b.dataset.ov };
  if (b.dataset.ov === "extend") body.duration_min = Math.ceil(((o ? o.expires : 0) - Date.now() / 1000) / 60) + 10;
  act("/api/override", body);
});

function tile({ label, value, sub, lvl, meter }) {
  const st = lvl ? `<div class="status"><span class="dot ${lvl}"></span>${levelText[lvl]}</div>` : "";
  const m = meter != null ? `<div class="meter"><span style="width:${Math.min(100, Math.max(0, meter))}%"></span></div>` : "";
  return `<div class="tile"><div class="label">${esc(label)}</div><div class="value">${value}</div>${sub ? `<div class="sub">${sub}</div>` : ""}${st}${m}</div>`;
}

const fmtMin = (m) => (m == null ? "–" : m >= 60 ? `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")} min` : `${m} min`);

const creditLabel = (c) => `CPU credits (${c?.provider_label ? c.provider_label + ", " : ""}est.)`;

function creditTile(c) {
  if (!c) return "";
  let sub;
  if (c.throttled_est) sub = `provider cap ~${c.throttle_cores} cores until ${c.recover_pct}%`;
  else if (c.empty_in_min != null) sub = `draining · empty in ${fmtMin(c.empty_in_min)}`;
  else if (c.full_in_min != null) sub = `refilling · full in ${fmtMin(c.full_in_min)}`;
  else sub = "full";
  const lvl = c.throttled_est || c.balance_pct < 20 ? "critical" : c.balance_pct < 40 ? "warning" : "good";
  return tile({ label: creditLabel(c), value: fmtPct(c.balance_pct), sub: `${sub}<br>baseline ${c.baseline_cores} cores · using ${c.use_cores ?? "–"}`, lvl, meter: c.balance_pct });
}

function governorText(g) {
  if (!g || !g.enabled) return "Credit governor off: the agent quota follows the fixed Layer 2b policy.";
  if (g.allowed_cores == null) return "Credit governor on: collecting samples…";
  const q = g.quota_pct == null ? "uncapped" : `${g.quota_pct}%`;
  const reserve = g.reserve_pct ? ` above the ${g.reserve_pct}% reserve` : "";
  return `Credit governor ${g.observe ? "(observe mode, not applied)" : "on"}: the balance${reserve} sustains ${g.allowed_cores} cores over ${g.horizon_min} min; other processes use ${g.others_cores}, so the agent quota is ${q}.`;
}

function renderCreditNote() {
  const c = status?.credits;
  const el = $("#credits-note");
  if (!el) return;
  if (!c) { el.textContent = ""; return; }
  const parts = [
    `Spending more than ${c.baseline_cores} cores drains the balance; less refills it.`,
    c.burst_full_min != null ? `With the current balance all ${c.vcpus} vCPUs can run flat out for ${fmtMin(c.burst_full_min)}.` : "",
    governorText(status.governor),
    `Source: ${c.backfilling ? "replaying atop history…" : c.source}. ${c.provider_label && c.provider_label !== "Custom" ? c.provider_label : "The provider"} does not expose the real balance to the guest; this follows the configured model.`,
  ];
  el.textContent = parts.filter(Boolean).join(" ");
}

function renderOverview() {
  const h = status.host, sl = status.slice, w = status.watchdog, th = w.thresholds;
  const aggThr = Number(th.AGG_CPU_THRESHOLD_PCT || 55);
  const quota = sl?.quota_pct;
  const slUse = sl?.usage_pct;
  const psi = h.psi?.cpu?.some?.avg10;
  const slPsiFull = sl?.pressure?.full?.avg10;
  const tiles = [
    tile({ label: "Host CPU busy", value: fmtPct(h.busy_pct), sub: `Layer 2 trigger at ${aggThr}% · counter ${w.agg_count}/${th.AGG_SUSTAIN_CHECKS || 5}`, lvl: level(h.busy_pct, aggThr - 10, aggThr), meter: h.busy_pct }),
    tile({ label: "Steal", value: fmtPct(h.steal_pct), sub: "CPU taken by the hypervisor", lvl: level(h.steal_pct, 10, 25) }),
    status.credit_provider?.error ? tile({ label: "CPU credits", value: "–", sub: `not estimated: ${esc(status.credit_provider.error)}`, lvl: "warning" }) : creditTile(status.credits),
    tile({ label: "Load average", value: esc((h.load || [])[0] || "–"), sub: `${esc((h.load || []).slice(1).join(" · "))} · ${h.nproc} CPUs`, lvl: level(Number((h.load || [])[0]) / h.nproc * 100, 100, 200) }),
    tile({ label: "Agent slice", value: slUse == null ? "–" : fmtPct(slUse), sub: quota != null ? `quota ${quota}% · ${w.agent_quota_state}` : `uncapped · config ${th.AGENT_CPU_QUOTA_PCT}%`, lvl: quota != null ? level(slUse / quota * 100, 85, 97) : null, meter: quota != null ? slUse / quota * 100 : null }),
    tile({ label: "Agent stall (PSI full)", value: fmtPct(slPsiFull), sub: "time all agents waited for CPU", lvl: level(slPsiFull, 15, 35) }),
    tile({ label: "Agent sessions", value: status.agent_count, sub: `${status.process_count} processes total` }),
    tile({ label: "Memory available", value: fmtMB(h.mem_avail_mb), sub: `${fmtPct(h.mem_avail_pct)} of ${fmtMB(h.mem_total_mb)}`, lvl: h.mem_avail_pct <= 10 ? "critical" : h.mem_avail_pct <= 20 ? "warning" : "good", meter: 100 - h.mem_avail_pct }),
    tile({ label: "Swap used", value: fmtPct(h.swap_used_pct), sub: `${fmtMB(h.swap_used_mb)} of ${fmtMB(h.swap_total_mb)}` }),
    tile({ label: "CPU pressure", value: fmtPct(psi), sub: "some avg10, host", lvl: level(psi, 40, 80) }),
    tile({ label: "cpulimit throttles", value: w.limited.length, sub: w.timer?.ActiveState === "active" ? "watchdog timer running" : "watchdog timer STOPPED", lvl: w.timer?.ActiveState === "active" ? "good" : "serious" }),
  ];
  $("#tiles").innerHTML = tiles.join("");
  $("#groups").innerHTML = `<tr><th>Command</th><th class="num">Processes</th></tr>` +
    status.top_comm.map(([c, n]) => `<tr><td>${esc(c)}</td><td class="num">${n}</td></tr>`).join("");
  const creditsOn = !!status.credits_enabled;
  $("#card-credits").hidden = !creditsOn;
  $("#q-gov-row").hidden = !creditsOn;
  if (creditsOn) $("#credits-title").textContent = creditLabel(status.credits);
  const g = status.governor;
  $("#gov-state").textContent = g?.enabled ? `on · agent quota ${g.quota_pct == null ? "uncapped" : g.quota_pct + "%"}` : "off";
  $("#q-quota").disabled = !!(g?.enabled && !g.observe);
  if (document.activeElement !== $("#q-quota") && !$("#q-quota").value) $("#q-quota").placeholder = (quota ?? th.AGENT_CPU_QUOTA_PCT) + "%";
}

/* ---------- charts ---------- */

const CHARTS = {
  cpu: { el: "#chart-cpu", legend: "#legend-cpu", max: 100, series: [
    { key: "busy", label: "Busy", color: "--series-1" },
    { key: "steal", label: "Steal", color: "--series-2" },
  ], ref: () => ({ value: Number(status?.watchdog.thresholds.AGG_CPU_THRESHOLD_PCT || 55), label: "Layer 2 trigger" }) },
  agents: { el: "#chart-agents", legend: "#legend-agents", series: [
    { key: "agents", label: "Agent usage", color: "--series-1" },
  ], refKey: { key: "quota", label: "Quota" } },
  credits: { el: "#chart-credits", legend: "#legend-credits", max: 100, data: () => creditSamples, series: [
    { key: "credits", label: "Balance", color: "--series-3" },
  ], ref: () => ({ value: Number(status?.credits?.recover_pct || 20), label: "Limit lifts" }) },
  mem: { el: "#chart-mem", legend: "#legend-mem", max: 100, series: [
    { key: "mem_avail", label: "RAM available", color: "--series-1" },
    { key: "swap_used", label: "Swap used", color: "--series-2" },
  ] },
};

function cssVar(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

function renderCharts() {
  if (tab !== "overview") return;
  for (const [name, c] of Object.entries(CHARTS)) if (name !== "credits" || status?.credits_enabled) drawChart(c);
  renderCreditNote();
}

function drawChart(c) {
  const el = $(c.el);
  const W = el.clientWidth || 400, H = el.clientHeight || 170;
  const pad = { l: 36, r: 10, t: 8, b: 20 };
  const data = c.data ? c.data() : samples;
  const legend = c.series.map((s) => `<span><span class="sw" style="background:var(${s.color})"></span>${esc(s.label)}</span>`);
  if (c.ref) legend.push(`<span><span class="sw dash"></span>${esc(c.ref().label)}</span>`);
  if (c.refKey) legend.push(`<span><span class="sw dash"></span>${esc(c.refKey.label)}</span>`);
  $(c.legend).innerHTML = c.series.length + (c.ref || c.refKey ? 1 : 0) > 1 ? legend.join("") : "";
  if (data.length < 2) { el.innerHTML = `<p class="muted small">Collecting samples…</p>`; return; }

  let max = c.max;
  if (!max) {
    max = 100;
    for (const d of data) {
      for (const s of c.series) if (d[s.key] != null) max = Math.max(max, d[s.key]);
      if (c.refKey && d[c.refKey.key] != null) max = Math.max(max, d[c.refKey.key]);
    }
    max = Math.ceil(max / 100) * 100;
  }
  const t0 = data[0].t, t1 = data[data.length - 1].t || t0 + 1;
  const x = (t) => pad.l + (t - t0) / Math.max(1, t1 - t0) * (W - pad.l - pad.r);
  const y = (v) => pad.t + (1 - v / max) * (H - pad.t - pad.b);

  let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(c.series.map((s) => s.label).join(", "))}">`;
  for (let i = 0; i <= 4; i++) {
    const v = max * i / 4, yy = y(v);
    svg += `<line class="gridline" x1="${pad.l}" x2="${W - pad.r}" y1="${yy}" y2="${yy}"/>`;
    svg += `<text class="axis-label" x="${pad.l - 6}" y="${yy + 3}" text-anchor="end">${Math.round(v)}%</text>`;
  }
  const mins = Math.round((t1 - t0) / 60);
  const span = mins >= 2880 ? `-${Math.round(mins / 1440)} d` : mins >= 120 ? `-${Math.round(mins / 60)} h` : `-${mins} min`;
  svg += `<text class="axis-label" x="${pad.l}" y="${H - 4}">${span}</text><text class="axis-label" x="${W - pad.r}" y="${H - 4}" text-anchor="end">now</text>`;
  if (c.ref) {
    const r = c.ref();
    svg += `<line class="ref" x1="${pad.l}" x2="${W - pad.r}" y1="${y(r.value)}" y2="${y(r.value)}"/>`;
  }
  if (c.refKey) svg += path(data, c.refKey.key, x, y, "ref", null);
  for (const s of c.series) svg += path(data, s.key, x, y, "series", cssVar(s.color));
  svg += `<line class="cross" id="${c.el.slice(1)}-cross" x1="0" x2="0" y1="${pad.t}" y2="${H - pad.b}" visibility="hidden"/>`;
  svg += `<rect x="${pad.l}" y="0" width="${W - pad.l - pad.r}" height="${H}" fill="transparent" data-hit="1"/></svg>`;
  el.innerHTML = svg;

  const rect = $("rect[data-hit]", el), cross = $(".cross", el), tip = $("#tooltip");
  rect.addEventListener("mousemove", (ev) => {
    const box = el.getBoundingClientRect();
    const px = (ev.clientX - box.left) * (W / box.width);
    const t = t0 + (px - pad.l) / (W - pad.l - pad.r) * (t1 - t0);
    let best = data[0];
    for (const d of data) if (Math.abs(d.t - t) < Math.abs(best.t - t)) best = d;
    cross.setAttribute("x1", x(best.t)); cross.setAttribute("x2", x(best.t)); cross.setAttribute("visibility", "visible");
    const rows = c.series.map((s) => `<div class="t-row"><span class="sw" style="display:inline-block;width:10px;height:3px;border-radius:2px;background:var(${s.color})"></span>${esc(s.label)}<b>${fmtPct(best[s.key], 1)}</b></div>`);
    if (c.refKey) rows.push(`<div class="t-row">${esc(c.refKey.label)}<b>${best[c.refKey.key] == null ? "none" : best[c.refKey.key] + "%"}</b></div>`);
    const when = new Date(best.t * 1000);
    tip.innerHTML = `<div class="muted">${range > 86400 ? when.toLocaleString() : when.toLocaleTimeString()}</div>` + rows.join("");
    tip.hidden = false;
    tip.style.left = Math.min(window.innerWidth - tip.offsetWidth - 8, ev.clientX + 14) + "px";
    tip.style.top = (ev.clientY + 14) + "px";
  });
  rect.addEventListener("mouseleave", () => { tip.hidden = true; cross.setAttribute("visibility", "hidden"); });
}

function path(data, key, x, y, cls, color) {
  let d = "", pen = false;
  for (const p of data) {
    if (p[key] == null) { pen = false; continue; }
    d += (pen ? "L" : "M") + x(p.t).toFixed(1) + "," + y(p[key]).toFixed(1);
    pen = true;
  }
  return d ? `<path class="${cls}" d="${d}"${color ? ` style="stroke:${color}"` : ""}/>` : "";
}

window.addEventListener("resize", () => renderCharts());

/* ---------- processes ---------- */

function renderProcs() {
  const view = $("#proc-view").value;
  const q = $("#proc-filter").value.toLowerCase();
  let list = status.processes.slice();
  if (view === "agents") list = list.filter((p) => p.agent);
  if (view === "throttled") list = list.filter((p) => p.throttled);
  list.sort(view === "rss" ? (a, b) => b.rss_mb - a.rss_mb : view === "agents" ? (a, b) => (b.cpu || 0) - (a.cpu || 0) : (a, b) => (b.cpu ?? -1) - (a.cpu ?? -1));
  if (q) list = list.filter((p) => [p.comm, p.cwd, p.user, p.cmd, p.pid, p.tty].join(" ").toLowerCase().includes(q));
  $("#proc-count").textContent = `${list.length} shown`;
  const head = `<tr><th class="num">PID</th><th>Command</th><th>User</th><th class="num">CPU</th><th class="num">RSS</th><th class="num">Age</th><th>TTY</th><th>cwd / command line</th><th></th></tr>`;
  $("#procs").innerHTML = head + list.map((p) => `
    <tr>
      <td class="num">${p.pid}</td>
      <td><b>${esc(p.comm)}</b><br>${p.agent ? `<span class="tag agent">agent${p.in_slice ? " · slice" : ""}</span>` : ""}${p.throttled ? `<span class="tag throttled">cpulimit ${esc(p.throttled)}%</span>` : ""}${p.state === "T" ? `<span class="tag throttled">stopped</span>` : ""}</td>
      <td>${esc(p.user)}</td>
      <td class="num">${fmtPct(p.cpu, 1)}</td>
      <td class="num">${fmtMB(p.rss_mb)}</td>
      <td class="num">${fmtAge(p.age_sec)}</td>
      <td>${esc(p.tty)}</td>
      <td class="cmd">${esc(p.cwd)}<br>${esc(p.cmd)}</td>
      <td class="actions">
        ${p.throttled ? `<button class="small" data-unthrottle="${p.pid}">Release</button>` : ""}
        ${p.state === "T" ? `<button class="small" data-kill="CONT" data-pid="${p.pid}" data-start="${p.start}" data-comm="${esc(p.comm)}">Resume</button>` : ""}
        <button class="small" data-kill="TERM" data-pid="${p.pid}" data-start="${p.start}" data-comm="${esc(p.comm)}">Terminate</button>
        <button class="small" data-kill="KILL" data-pid="${p.pid}" data-start="${p.start}" data-comm="${esc(p.comm)}">Kill</button>
      </td>
    </tr>`).join("");
}
$("#proc-view").addEventListener("change", renderProcs);
$("#proc-filter").addEventListener("input", renderProcs);
document.addEventListener("click", (e) => {
  const k = e.target.closest("button[data-kill]");
  if (k) {
    const sig = k.dataset.kill;
    act("/api/action", { action: "kill", pid: Number(k.dataset.pid), start: Number(k.dataset.start), signal: sig },
      sig === "CONT" ? null : `Send SIG${sig} to ${k.dataset.comm} (pid ${k.dataset.pid})?`);
  }
  const u = e.target.closest("button[data-unthrottle]");
  if (u) act("/api/action", { action: "unthrottle", pid: u.dataset.unthrottle });
});

/* ---------- watchdog ---------- */

function renderWatchdog() {
  const w = status.watchdog, sl = status.slice, th = w.thresholds;
  const kv = [
    ["Mode", th.MODE],
    ["Timer", `${w.timer?.ActiveState || "?"} · last ${w.timer?.LastTriggerUSec || "–"}`],
    ["Last run", `${w.service?.Result || "?"} (exit ${w.service?.ExecMainStatus ?? "?"})`],
    ["Layer 2 counter", `${w.agg_count} / ${th.AGG_SUSTAIN_CHECKS} (trigger ${th.AGG_CPU_THRESHOLD_PCT}% of host)`],
    ["Agent quota", `${w.agent_quota_state} · slice ${sl?.quota_pct != null ? sl.quota_pct + "%" : "uncapped"} · config ${th.AGENT_CPU_QUOTA_PCT}%`],
    ["Agent slice", sl ? `${esc(status.slice_name)} · ${sl.scopes} scopes · throttled ${fmtPct(sl.throttled_pct, 0)} of a core` : "not found"],
    ["Memory kill counter", String(w.mem_sys_count)],
    ["earlyoom", w.earlyoom?.ActiveState || "?"],
    ["Freed processes", String(w.freed.length)],
  ];
  $("#wd-state").innerHTML = kv.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("");
  $("#throttles").innerHTML = w.limited.length
    ? `<tr><th class="num">PID</th><th>Command</th><th class="num">Limit</th><th>Since</th><th>Reason</th><th></th></tr>` +
      w.limited.map((l) => `<tr><td class="num">${l.pid}</td><td>${esc(l.comm)}</td><td class="num">${esc(l.limit)}%</td><td>${esc(l.applied_at)}</td><td>${esc(l.reason)}</td><td><button class="small" data-unthrottle="${l.pid}">Release</button></td></tr>`).join("")
    : `<tr><td class="muted">No active throttles.</td></tr>`;
}

async function loadLog() {
  try {
    const r = await api("/api/log?n=400");
    const q = $("#log-filter").value.toLowerCase();
    const lines = r.lines.filter((l) => !q || l.toLowerCase().includes(q)).reverse();
    $("#log").textContent = lines.join("\n") || "(empty)";
  } catch { /* toast already shown */ }
}
$("#log-refresh").addEventListener("click", loadLog);
$("#log-filter").addEventListener("input", loadLog);
let tmuxLoaded = 0;
async function loadTmux(force = false) {
  if (!force && Date.now() - tmuxLoaded < 15000) return;
  const sel = $("#free-target");
  const keep = sel.value;
  tmuxLoaded = Date.now();
  try {
    const { sessions } = await api("/api/tmux");
    const groups = {};
    for (const s of sessions) (groups[s.user] ||= []).push(s);
    let html = `<option value="">${sessions.length ? "Choose a session, window or pane…" : "No tmux sessions found"}</option>`;
    for (const [user, list] of Object.entries(groups)) {
      html += `<optgroup label="${esc(user)}">`;
      for (const s of list) {
        html += `<option value="${esc(user + "|" + s.target)}">${esc(s.session)} — whole session (${s.windows.length} windows)</option>`;
        for (const w of s.windows) {
          html += `<option value="${esc(user + "|" + w.target)}">\u00a0\u00a0${esc(w.target)} ${esc(w.name)}</option>`;
          if (w.panes.length > 1) {
            for (const p of w.panes) {
              html += `<option value="${esc(user + "|" + p.target)}">\u00a0\u00a0\u00a0\u00a0${esc(p.target)} ${esc(p.command)} · ${esc(p.path)}</option>`;
            }
          }
        }
      }
      html += `</optgroup>`;
    }
    sel.innerHTML = html;
    if ([...sel.options].some((o) => o.value === keep)) sel.value = keep;
  } catch (e) {
    tmuxLoaded = 0;
    if (e.message !== "unauthorized") toast(e.message, true);
  }
}
function freeTarget() {
  const [user, target] = $("#free-target").value.split("|");
  if (!target) { toast("Choose a tmux session first.", true); return null; }
  return { user, target };
}
$("#free-target").addEventListener("mousedown", () => loadTmux());
$("#free-target").addEventListener("focus", () => loadTmux());
$("#free-reload").addEventListener("click", () => loadTmux(true));
$("#free-go").addEventListener("click", () => {
  const t = freeTarget();
  if (t) act("/api/action", { action: "free", ...t, duration_min: dur("#free-dur") });
});
$("#free-undo").addEventListener("click", () => {
  const t = freeTarget();
  if (t) act("/api/action", { action: "free", ...t, undo: true });
});

/* ---------- quick actions ---------- */

$(".quick").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-quick]");
  if (!b) return;
  const q = b.dataset.quick;
  if (q === "quota") {
    const v = $("#q-quota").value.trim();
    if (!v) return toast("Type a quota in % (100 = one core).", true);
    act("/api/action", { action: "quota", value: v, duration_min: dur("#q-quota-dur") });
  }
  if (q === "gov-on" || q === "gov-off") {
    act("/api/config", { changes: { CREDIT_GOVERNOR: q === "gov-on" ? "1" : "0" }, duration_min: dur("#q-gov-dur") });
    config = null;
  }
  if (q === "quota-off") act("/api/action", { action: "quota", value: "", duration_min: dur("#q-quota-dur") });
  if (q === "pause") act("/api/action", { action: "timer", op: "stop", duration_min: dur("#q-pause-dur") },
    dur("#q-pause-dur") ? null : "Pause the watchdog with no automatic resume?");
  if (q === "resume") act("/api/action", { action: "timer", op: "start" });
  if (q === "run") act("/api/action", { action: "watchdog_run" });
  if (q === "unthrottle-all") act("/api/action", { action: "unthrottle", pid: "all" }, "Release every cpulimit throttle?");
});

/* ---------- config ---------- */

async function loadConfig() {
  try {
    [config, creditCfg] = await Promise.all([api("/api/config"), api("/api/credits/config")]);
    cfgEdits = {};
    renderConfig();
    renderCreditConfig();
  } catch { /* toast already shown */ }
}

let creditCfg = null;
const CREDIT_FIELDS = [
  ["PANEL_CREDIT_VCPUS", "vCPUs", "vcpus", "Billed vCPUs (empty = this host's CPU count)."],
  ["PANEL_CREDIT_BASELINE_PCT", "Baseline %", "baseline_pct", "Sustained usage that earns as much as it spends, % of all vCPUs."],
  ["PANEL_CREDIT_CAP_MODE", "Capacity mode", "cap_mode", "burst: a full balance lasts N hours at 100%; accrual: it holds N hours of baseline earnings."],
  ["PANEL_CREDIT_CAP_HOURS", "Capacity hours", "cap_hours", "The N in the capacity mode."],
  ["PANEL_CREDIT_THROTTLE_PCT", "Throttle %", "throttle_pct", "CPU cap applied by the provider when the balance hits zero, % of all vCPUs."],
  ["PANEL_CREDIT_RECOVER_PCT", "Recover %", "recover_pct", "Balance (%) at which the provider lifts the cap."],
  ["PANEL_CREDIT_EARN_WHILE_THROTTLED", "Earn while capped", "earn_while_throttled", "0: no credits are earned while usage sits at the cap."],
];

function renderCreditConfig() {
  const c = creditCfg;
  const vals = { ...c.values };
  if (!vals.PANEL_CREDIT_PROVIDER && c.legacy.PANEL_CREDIT_MODEL === "1") vals.PANEL_CREDIT_PROVIDER = "hostinger";
  if (!vals.PANEL_CREDIT_CAP_HOURS && c.legacy.PANEL_CREDIT_BURST_HOURS) vals.PANEL_CREDIT_CAP_HOURS = c.legacy.PANEL_CREDIT_BURST_HOURS;
  const provider = vals.PANEL_CREDIT_PROVIDER || "none";
  $("#cc-path").textContent = c.path;
  $("#cc-provider").innerHTML = c.providers.map((p) => `<option value="${esc(p)}"${p === provider ? " selected" : ""}>${esc(p === "none" ? "None (disabled)" : c.labels[p])}</option>`).join("");
  const r = c.resolved;
  $("#cc-state").textContent = r.enabled ? `active · ${r.label}` : r.error ? "" : "disabled";
  $("#cc-error").textContent = r.error || "";
  renderCreditFields(vals);
}

function renderCreditFields(vals) {
  const provider = $("#cc-provider").value;
  const preset = creditCfg.presets[provider];
  $("#cc-fields").hidden = !preset;
  if (!preset) return;
  $("#cc-fields").innerHTML = CREDIT_FIELDS.map(([key, label, pk, doc]) => {
    const v = vals[key] || "";
    const ph = key === "PANEL_CREDIT_VCPUS" ? String(creditCfg.nproc) : preset[pk] ?? "";
    const input = key === "PANEL_CREDIT_CAP_MODE" || key === "PANEL_CREDIT_EARN_WHILE_THROTTLED"
      ? `<select data-cc="${key}"><option value="">preset (${esc(ph)})</option>${(key === "PANEL_CREDIT_CAP_MODE" ? ["burst", "accrual"] : ["0", "1"]).map((o) => `<option${o === v ? " selected" : ""}>${o}</option>`).join("")}</select>`
      : `<input data-cc="${key}" class="narrow" value="${esc(v)}" placeholder="${esc(ph)}" inputmode="decimal">`;
    return `<div class="row"><label title="${esc(key)}">${esc(label)}</label>${input}<span class="muted small grow">${esc(doc)}</span></div>`;
  }).join("");
}

function creditFormValues() {
  const values = { PANEL_CREDIT_PROVIDER: $("#cc-provider").value === "none" ? "" : $("#cc-provider").value };
  for (const el of $$("[data-cc]")) values[el.dataset.cc] = el.value.trim();
  return values;
}

$("#cc-provider").addEventListener("change", () => {
  const keep = creditFormValues();
  renderCreditFields($("#cc-provider").value === creditCfg.values.PANEL_CREDIT_PROVIDER ? keep : {});
});
$("#cc-save").addEventListener("click", async () => {
  const r = await act("/api/credits/config", { values: creditFormValues() }, "Save the CPU-credit settings and replay the history?");
  if (r) { await loadConfig(); refresh(); setTimeout(refreshHistory, 3000); }
});

function cfgInput(e) {
  const id = `cfg-${e.key}`;
  const val = e.key in cfgEdits ? cfgEdits[e.key] : e.value;
  if (e.type.startsWith("enum:")) {
    return `<select id="${id}" data-key="${e.key}">${e.type.slice(5).split(",").map((o) => `<option${o === val ? " selected" : ""}>${esc(o)}</option>`).join("")}</select>`;
  }
  if (e.type === "int") return `<input id="${id}" data-key="${e.key}" type="number" min="0" value="${esc(val)}" placeholder="${esc(e.default)}">`;
  if (e.type === "secret") return `<input id="${id}" data-key="${e.key}" type="password" autocomplete="off" placeholder="${e.value ? "set · type to replace" : "empty"}" value="${esc(cfgEdits[e.key] || "")}">`;
  if (e.type === "words" || e.type === "regex" || String(val).length > 60) return `<textarea id="${id}" data-key="${e.key}" rows="2" spellcheck="false">${esc(val)}</textarea>`;
  return `<input id="${id}" data-key="${e.key}" value="${esc(val)}" placeholder="${esc(e.default)}">`;
}

function renderConfig() {
  const groups = {};
  for (const e of config.entries) (groups[e.group] ||= []).push(e);
  $("#cfg-path").textContent = `${config.path} · ${config.nproc} CPUs (100% quota = one core)`;
  $("#cfg-groups").innerHTML = Object.entries(groups).map(([g, items]) => `
    <div class="card cfg-group"><h3>${esc(g)}</h3>
      ${items.map((e) => `
        <div class="cfg-item${e.key in cfgEdits ? " dirty" : ""}" data-item="${e.key}">
          <div><div class="key">${esc(e.key)}</div><div class="doc">${esc(e.doc)}</div>
            <div class="default">${e.set ? "" : `unset · default ${esc(e.default || "empty")}`}</div></div>
          <div class="field">${cfgInput(e)}
            ${e.set && e.type !== "secret" ? `<button class="small ghost" data-unset="${e.key}" title="Remove the assignment (use the default)">Unset</button>` : ""}</div>
        </div>`).join("")}
    </div>`).join("");
  $("#eo-args").value = config.earlyoom_args;
  $("#eo-path").textContent = config.earlyoom_path;
  $("#cfg-restore").disabled = !config.has_backup;
  updateDirty();
}

function updateDirty() {
  const n = Object.keys(cfgEdits).length;
  $("#cfg-dirty").textContent = n ? `${n} unsaved change(s): ${Object.keys(cfgEdits).join(", ")}` : "No changes.";
  $("#cfg-save").disabled = !n;
  for (const el of $$(".cfg-item")) el.classList.toggle("dirty", el.dataset.item in cfgEdits);
}

$("#cfg-groups").addEventListener("input", (e) => {
  const key = e.target.dataset.key;
  if (!key) return;
  const entry = config.entries.find((x) => x.key === key);
  const v = e.target.value;
  if (entry.type === "secret" ? v === "" : v === entry.value) delete cfgEdits[key];
  else cfgEdits[key] = v;
  updateDirty();
});
$("#cfg-groups").addEventListener("click", (e) => {
  const key = e.target.dataset?.unset;
  if (!key) return;
  cfgEdits[key] = null;
  const el = $(`#cfg-${key}`);
  if (el) el.value = "";
  updateDirty();
});
$("#cfg-reset").addEventListener("click", () => { cfgEdits = {}; renderConfig(); });
$("#cfg-save").addEventListener("click", async () => {
  const d = dur("#cfg-dur");
  const r = await act("/api/config", { changes: cfgEdits, apply_quota: $("#cfg-apply-quota").checked, duration_min: d });
  if (r) loadConfig();
});
$("#cfg-restore").addEventListener("click", async () => {
  const r = await act("/api/config/restore", {}, "Swap the current configuration with the previous version?");
  if (r) loadConfig();
});
$("#eo-save").addEventListener("click", () => act("/api/earlyoom", { args: $("#eo-args").value.trim() }, "Restart earlyoom with these arguments?"));

/* ---------- services ---------- */

function renderServices() {
  const units = status.watchdog.units || {};
  $("#units").innerHTML = `<tr><th>Unit</th><th>State</th><th class="num">Memory</th><th>Since</th><th></th></tr>` +
    status.units.map((u) => {
      const s = units[u] || {};
      const lvl = s.ActiveState === "active" ? "good" : s.ActiveState === "failed" ? "critical" : "warning";
      const mem = Number(s.MemoryCurrent);
      return `<tr><td><b>${esc(u)}</b><br><span class="muted small">${esc(s.Description || "")}</span></td>
        <td><span class="dot ${lvl}"></span> ${esc(s.ActiveState || "?")} (${esc(s.SubState || "")})</td>
        <td class="num">${mem && mem < 1e18 ? fmtMB(mem / 1048576) : "–"}</td>
        <td>${esc(s.ActiveEnterTimestamp || "")}</td>
        <td class="actions"><button class="small" data-unit="${esc(u)}" data-op="start">Start</button>
          <button class="small" data-unit="${esc(u)}" data-op="restart">Restart</button>
          <button class="small" data-unit="${esc(u)}" data-op="stop">Stop</button></td></tr>`;
    }).join("");
  if (document.activeElement !== $("#units-edit")) $("#units-edit").value = status.units.join(" ");
  const h = status.host, sw = status.swap;
  $("#swap-info").textContent = `Used ${fmtMB(h.swap_used_mb)} of ${fmtMB(h.swap_total_mb)} · RAM available ${fmtMB(h.mem_avail_mb)} · disk ${sw.disk_free_gb} GB free of ${sw.disk_total_gb} GB (${sw.fstype})`;
  $("#swap-devices").innerHTML = `<tr><th>File</th><th class="num">Size</th><th class="num">Used</th><th class="num">Priority</th><th></th></tr>` +
    (sw.devices.length ? sw.devices.map((d) => `<tr><td class="mono">${esc(d.path)}</td><td class="num">${fmtMB(d.size_mb)}</td><td class="num">${fmtMB(d.used_mb)}</td><td class="num">${d.priority}</td>
      <td class="actions"><button class="small" data-swap-remove="${esc(d.path)}">Remove</button></td></tr>`).join("") : `<tr><td class="muted" colspan="5">No swap configured.</td></tr>`);
  if (document.activeElement !== $("#swappiness")) $("#swappiness").value = sw.swappiness;
  $("#reboot-confirm").placeholder = status.hostname;
  $("#reboot-go").disabled = !status.allow_reboot;
}
$("#units").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-unit]");
  if (b) act("/api/action", { action: "unit", unit: b.dataset.unit, op: b.dataset.op }, b.dataset.op === "start" ? null : `${b.dataset.op} ${b.dataset.unit}?`);
});
$("#units-save").addEventListener("click", () => act("/api/units", { units: $("#units-edit").value }));
$("#swap-add").addEventListener("click", () => {
  const gb = Number($("#swap-size").value);
  act("/api/action", { action: "swap_add", size_gb: gb }, `Create a ${gb} GB swap file and enable it now?`);
});
$("#swap-devices").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-swap-remove]");
  if (b) act("/api/action", { action: "swap_remove", path: b.dataset.swapRemove }, `Turn off and delete ${b.dataset.swapRemove}? Its pages move back to RAM first, which can take a few minutes.`);
});
$("#swappiness-set").addEventListener("click", () => act("/api/action", { action: "swappiness", value: Number($("#swappiness").value) }));
$("#swap-flush").addEventListener("click", () => act("/api/action", { action: "swap_flush" }, "Flush swap now? This can take a few minutes."));
$("#reboot-go").addEventListener("click", () => act("/api/action", { action: "reboot", confirm: $("#reboot-confirm").value.trim() }, "Reboot the host now?"));

/* ---------- boot ---------- */

fillDurations();
const hashToken = new URLSearchParams(location.hash.slice(1)).get("token");
const queryTab = new URLSearchParams(location.search).get("tab");
if (queryTab && $(`#tabs button[data-tab="${CSS.escape(queryTab)}"]`)) tab = queryTab;
if (hashToken) {
  token = hashToken;
  store.set("cwp-token", token);
  history.replaceState(null, "", location.pathname + location.search);
}
if (token) start(); else showLogin();
