#!/usr/bin/env python3
"""Local web panel for cpu-watchdog: live host/agent metrics, configuration
editing and control actions (throttles, quota, services, processes, reboot).

Runs as root (it edits /etc and signals processes), so it binds to loopback
by default and every /api call requires the bearer token stored in
PANEL_TOKEN_FILE. Reach it through an SSH tunnel:

    ssh -L 8790:127.0.0.1:8790 <host>   then open http://127.0.0.1:8790

Standard library only; Python 3.8+.
"""

import collections
import hmac
import json
import os
import pwd
import re
import secrets
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PANEL_CONF = os.environ.get("CPU_WATCHDOG_PANEL_CONF", "/etc/cpu-watchdog-panel.conf")
PROC = os.environ.get("CPU_WATCHDOG_PROC_DIR", "/proc")
CGROUP = os.environ.get("CPU_WATCHDOG_CGROUP_DIR", "/sys/fs/cgroup")
TMUX_TMPDIR = os.environ.get("CPU_WATCHDOG_TMUX_TMPDIR", "/tmp")
STATIC_DIR = os.environ.get(
    "CPU_WATCHDOG_PANEL_STATIC",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "static"),
)

PANEL_DEFAULTS = {
    "PANEL_BIND": "127.0.0.1",
    "PANEL_PORT": "8790",
    "PANEL_TOKEN_FILE": "/etc/cpu-watchdog-panel.token",
    "PANEL_ALLOWED_HOSTS": "",
    "PANEL_UNITS": "cpu-watchdog.timer earlyoom cpu-watchdog-panel",
    "PANEL_ALLOW_REBOOT": "1",
    "PANEL_SAMPLE_SEC": "3",
    "PANEL_HISTORY_MIN": "60",
    "PANEL_CREDIT_MODEL": "1",
    "PANEL_CREDIT_VCPUS": "",
    "PANEL_CREDIT_BASELINE_PCT": "60",
    "PANEL_CREDIT_THROTTLE_PCT": "30",
    "PANEL_CREDIT_BURST_HOURS": "3",
    "PANEL_CREDIT_RECOVER_PCT": "20",
    "PANEL_ATOP_DIR": "/var/log/atop",
    "PANEL_CREDIT_REPLAY_HOURS": "168",
    "PANEL_HISTORY_DAYS": "7",
    "WATCHDOG_CONF": "/etc/cpu-watchdog.conf",
    "WATCHDOG_CTL": "/usr/local/bin/cpu-watchdog-ctl",
    "EARLYOOM_DEFAULT": "/etc/default/earlyoom",
}

KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
ASSIGN_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
UNIT_RE = re.compile(r"^(?:[a-z_][a-z0-9_-]{0,31}/)?[A-Za-z0-9@._:-]+$")

# type: int | enum | words | regex | str | secret | path
SCHEMA = [
    ("General", "MODE", "enum:active,observe", "active",
     "active applies throttles/signals; observe only logs and alerts what it would do."),
    ("Layer 1 - single process", "CPU_THRESHOLD", "int", "80",
     "% of one core above which a process counts as hot."),
    ("Layer 1 - single process", "SUSTAIN_CHECKS", "int", "5",
     "Consecutive minutes above CPU_THRESHOLD before throttling."),
    ("Layer 1 - single process", "LIMIT_PERCENT", "int", "50",
     "cpulimit cap applied by Layer 1."),
    ("Layer 1 - single process", "WHITELIST_COMM", "words", "",
     "Commands never touched by CPU layers 1 and 3 (ps -o comm names)."),
    ("Layer 1 - single process", "WHITELIST_CMDLINE", "regex", "",
     "ERE matched against the full command line; exempt from every layer."),
    ("Layer 2 - aggregate", "AGG_CPU_THRESHOLD_PCT", "int", "55",
     "% of total host capacity (nproc x 100). Keep below the provider credit baseline."),
    ("Layer 2 - aggregate", "AGG_SUSTAIN_CHECKS", "int", "5",
     "Consecutive minutes above the aggregate threshold before acting."),
    ("Layer 2 - aggregate", "AGG_MAX_THROTTLES", "int", "5",
     "Maximum processes throttled per run."),
    ("Layer 2 - aggregate", "AGG_TOP_N", "int", "5",
     "Legacy fallback for AGG_MAX_THROTTLES."),
    ("Layer 2 - aggregate", "AGG_LIMIT_PERCENT", "int", "20",
     "cpulimit cap applied by Layer 2."),
    ("Layer 2 - aggregate", "AGG_WHITELIST_COMM", "words", "",
     "Replaces WHITELIST_COMM in Layer 2 only. Unset = use WHITELIST_COMM."),
    ("Layer 2b - agent quota", "AGENT_COMM", "words", "",
     "Commands moved into the agent slice and capped by cgroup quota instead of cpulimit."),
    ("Layer 2b - agent quota", "AGENT_CPU_QUOTA_PCT", "int", "0",
     "CPUQuota for the agent slice while Layer 2 is high (100 = one core). 0 disables."),
    ("Layer 2b - agent quota", "AGENT_SLICE", "str", "cpu-watchdog-agents.slice",
     "systemd slice holding agent processes."),
    ("Credit governor", "CREDIT_GOVERNOR", "enum:0,1", "0",
     "1 = the panel sizes the agent quota from the estimated credit balance every 30 s "
     "(Layer 2 then triggers on what the balance can sustain). Needs the panel running."),
    ("Credit governor", "CREDIT_HORIZON_MIN", "int", "120",
     "Spend the balance over at least this long: allowed CPU = baseline + balance / horizon."),
    ("Credit governor", "CREDIT_GOV_MIN_QUOTA_PCT", "int", "100",
     "Agent quota never goes below this (100 = one core)."),
    ("Release", "RELEASE_SUSTAIN_CHECKS", "int", "3",
     "Minutes of low usage before a throttle or quota is lifted. 0 disables release."),
    ("Release", "RELEASE_IDLE_PCT", "int", "50",
     "Low usage = below this % of the applied limit."),
    ("Release", "RELEASE_GRACE_MIN", "int", "30",
     "Minutes a released process stays exempt."),
    ("Layer 3 - fork bomb", "FORKBOMB_MIN_COUNT", "int", "3",
     "Identical hot copies of one command that count as a fork bomb."),
    ("Layer 3 - fork bomb", "FORKBOMB_SUSTAIN_CHECKS", "int", "3",
     "Consecutive minutes before SIGTERM to every copy."),
    ("Layer 4 - memory", "MEM_PROC_KILL_MB", "int", "4096",
     "RSS above which a single process is terminated."),
    ("Layer 4 - memory", "MEM_PROC_SUSTAIN_CHECKS", "int", "3",
     "Consecutive minutes above MEM_PROC_KILL_MB."),
    ("Layer 4 - memory", "MEM_AVAIL_WARN_PCT", "int", "20",
     "Alert when available RAM drops to this %."),
    ("Layer 4 - memory", "MEM_SWAP_USED_WARN_PCT", "int", "50",
     "Alert when swap usage reaches this % (and RAM <= MEM_SWAP_WARN_AVAIL_PCT)."),
    ("Layer 4 - memory", "MEM_SWAP_WARN_AVAIL_PCT", "int", "30",
     "Swap alert only fires when available RAM is also at or below this %."),
    ("Layer 4 - memory", "MEM_ALERT_COOLDOWN_MIN", "int", "30",
     "Minutes between memory alerts."),
    ("Layer 4 - memory", "MEM_AVAIL_KILL_PCT", "int", "10",
     "Kill when available RAM <= this % ..."),
    ("Layer 4 - memory", "MEM_SWAP_FREE_KILL_PCT", "int", "40",
     "... and free swap <= this %."),
    ("Layer 4 - memory", "MEM_SYS_SUSTAIN_CHECKS", "int", "2",
     "Consecutive minutes of host memory pressure before each kill."),
    ("Layer 4 - memory", "MEM_VICTIM_MIN_MB", "int", "200",
     "Smallest RSS considered as a victim."),
    ("Layer 4 - memory", "MEM_PREFER_REGEX", "regex", "",
     "ERE on comm: preferred victims."),
    ("Layer 4 - memory", "MEM_PREFER_FIRST_REGEX", "regex", "",
     "ERE on full command line: terminated before MEM_PREFER_REGEX matches."),
    ("Layer 4 - memory", "MEM_WHITELIST_COMM", "words", "",
     "Commands never killed by the memory layer."),
    ("Notifications", "TELEGRAM_BOT_TOKEN", "secret", "",
     "Telegram bot token. Write-only from the panel."),
    ("Notifications", "TELEGRAM_CHAT_ID", "str", "", "Telegram chat id."),
    ("Paths", "STATE_DIR", "path", "/var/lib/cpu-watchdog", "Watchdog state directory."),
    ("Paths", "LOG_FILE", "path", "/var/log/cpu-watchdog.log", "Watchdog log file."),
]
SCHEMA_BY_KEY = {s[1]: s for s in SCHEMA}


def now_str():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def read_file(path, default=""):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return default


def bash_unquote(raw):
    """Value of a simple shell assignment right-hand side: "..." | '...' | bare."""
    raw = raw.strip()
    if raw.startswith('"'):
        out, i = [], 1
        while i < len(raw):
            c = raw[i]
            if c == "\\" and i + 1 < len(raw) and raw[i + 1] in '\\"$`':
                out.append(raw[i + 1])
                i += 2
                continue
            if c == '"':
                break
            out.append(c)
            i += 1
        return "".join(out)
    if raw.startswith("'"):
        end = raw.find("'", 1)
        return raw[1:end if end > 0 else len(raw)]
    return raw.split("#", 1)[0].strip()


def bash_quote(value):
    for ch in ("\\", '"', "$", "`"):
        value = value.replace(ch, "\\" + ch)
    return '"' + value + '"'


def raw_assignments(text):
    """Right-hand side as written; last assignment wins, as when sourced."""
    values = {}
    for line in text.splitlines():
        m = ASSIGN_RE.match(line)
        if m and not line.lstrip().startswith("#"):
            values[m.group(1)] = m.group(2).strip()
    return values


def parse_assignments(text):
    return {k: bash_unquote(v) for k, v in raw_assignments(text).items()}


def load_panel_conf():
    conf = dict(PANEL_DEFAULTS)
    conf.update({k: v for k, v in parse_assignments(read_file(PANEL_CONF)).items() if k in PANEL_DEFAULTS})
    return conf


def run(cmd, timeout=30, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           env=dict(os.environ, **env) if env else None)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout after %ss" % timeout
    except OSError as e:
        return 127, str(e)


def systemctl_cmd(spec):
    """"unit" -> system manager; "user/unit" -> that user's manager (needs lingering)."""
    if "/" in spec:
        user, unit = spec.split("/", 1)
        try:
            pwd.getpwnam(user)
        except KeyError:
            raise ValueError("unknown user %r" % user)
        return ["systemctl", "--user", "-M", user + "@"], unit
    return ["systemctl"], spec


def systemctl_show_many(specs, props):
    """One systemctl call per manager instead of one per unit."""
    groups = collections.OrderedDict()
    for spec in specs:
        try:
            base, unit = systemctl_cmd(spec)
        except ValueError:
            continue
        groups.setdefault(tuple(base), []).append((spec, unit))
    result = {}
    for base, items in groups.items():
        rc, out = run(list(base) + ["show"] + [u for _s, u in items] + ["-p", ",".join(props)], timeout=15)
        if rc != 0:
            continue
        blocks = out.split("\n\n")
        for (spec, _unit), block in zip(items, blocks):
            result[spec] = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
    return result


def systemctl_show(spec, props):
    try:
        base, unit = systemctl_cmd(spec)
    except ValueError:
        return {}
    rc, out = run(base + ["show", unit, "-p", ",".join(props)], timeout=10)
    result = {}
    if rc == 0:
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                result[k] = v
    return result


def atomic_write(path, text, mode=None):
    st = None
    try:
        st = os.stat(path)
    except OSError:
        pass
    tmp = "%s.panel-tmp-%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    if st is not None:
        os.chmod(tmp, st.st_mode & 0o7777)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except OSError:
            pass
    elif mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def backup(path):
    text = read_file(path, None)
    if text is not None:
        atomic_write(path + ".panel-bak", text, 0o600)
    return text


def set_assignments(text, changes):
    """Rewrite every assignment of each changed key; append missing ones.
    A value of None removes the key."""
    lines = text.splitlines()
    seen = set()
    out = []
    for line in lines:
        m = ASSIGN_RE.match(line)
        if m and not line.lstrip().startswith("#") and m.group(1) in changes:
            key = m.group(1)
            if changes[key] is None or key in seen:
                continue
            seen.add(key)
            out.append("%s=%s" % (key, changes[key]))
            continue
        out.append(line)
    for key, rendered in changes.items():
        if rendered is not None and key not in seen:
            out.append("%s=%s" % (key, rendered))
    return "\n".join(out) + "\n"


def duration_minutes(body):
    v = body.get("duration_min")
    if v in (None, "", 0, "0"):
        return 0
    try:
        n = int(v)
    except (TypeError, ValueError):
        raise ValueError("duration_min must be an integer")
    if not 1 <= n <= 7 * 24 * 60:
        raise ValueError("duration_min must be between 1 and 10080")
    return n


def bash_syntax_ok(path):
    rc, out = run(["bash", "-n", path], timeout=10)
    return rc == 0, out


def validate_value(key, value, nproc):
    """Return the rendered right-hand side for KEY or raise ValueError."""
    if value is None:
        return None
    if not isinstance(value, (str, int)):
        raise ValueError("%s: invalid value type" % key)
    value = str(value)
    if "\n" in value or "\r" in value or "\0" in value:
        raise ValueError("%s: newlines are not allowed" % key)
    kind = SCHEMA_BY_KEY.get(key, (None, key, "str"))[2]
    if kind == "int":
        if not re.fullmatch(r"\d{1,7}", value):
            raise ValueError("%s: expected a non-negative integer" % key)
        n = int(value)
        if key.endswith("_PCT") and key not in ("AGENT_CPU_QUOTA_PCT", "CREDIT_GOV_MIN_QUOTA_PCT") and n > 100:
            raise ValueError("%s: percentage above 100" % key)
        if key in ("AGENT_CPU_QUOTA_PCT", "CREDIT_GOV_MIN_QUOTA_PCT") and n > nproc * 100:
            raise ValueError("%s: above %d (nproc x 100)" % (key, nproc * 100))
        return str(n)
    if kind.startswith("enum:"):
        allowed = kind[5:].split(",")
        if value not in allowed:
            raise ValueError("%s: must be one of %s" % (key, ", ".join(allowed)))
        return value
    if kind == "regex" and value:
        try:
            re.compile(value)
        except re.error as e:
            raise ValueError("%s: invalid regex (%s)" % (key, e))
    if kind == "words":
        value = " ".join(value.split())
    if kind == "path" and value and not value.startswith("/"):
        raise ValueError("%s: must be an absolute path" % key)
    return bash_quote(value)


def boot_id():
    return read_file(os.path.join(PROC, "sys", "kernel", "random", "boot_id")).strip()


def busy_seconds(cpu_fields, hz):
    """Non-idle CPU time (user+nice+system+irq+softirq) in core-seconds; steal excluded."""
    f = (cpu_fields + [0] * 8)[:8]
    return (f[0] + f[1] + f[2] + f[5] + f[6]) / hz


class CreditModel:
    """Estimate of a provider CPU-credit balance (token bucket, Hostinger's model by default).

    One credit is one vCPU-second at 100%. The VM earns BASELINE% x vCPUs credits per
    second and spends the busy core-seconds it actually ran. Capacity is
    BURST_HOURS x 3600 x (vCPUs - baseline cores), i.e. the time a full balance lasts at
    100% on every vCPU. At zero the provider caps the VM at THROTTLE% of its vCPUs until
    the balance is back to RECOVER% of capacity; nothing is earned while the VM is
    pressing against that cap.
    The provider does not expose the real balance, so this is an estimate."""

    def __init__(self, conf, nproc, path):
        self.n = float(conf["PANEL_CREDIT_VCPUS"] or nproc)
        self.base = self.n * float(conf["PANEL_CREDIT_BASELINE_PCT"]) / 100
        self.limit = self.n * float(conf["PANEL_CREDIT_THROTTLE_PCT"]) / 100
        self.cap = float(conf["PANEL_CREDIT_BURST_HOURS"]) * 3600 * max(0.01, self.n - self.base)
        self.recover = float(conf["PANEL_CREDIT_RECOVER_PCT"]) / 100
        self.path = path
        self.lock = threading.Lock()
        self.balance = self.cap
        self.throttled = False
        self.source = "assumed full (no history yet)"
        self.last = None
        self.history = collections.deque(maxlen=int(conf.get("PANEL_HISTORY_DAYS") or 7) * 24 * 60)
        self.recent = collections.deque(maxlen=200)
        self.pending = []
        self.backfilling = False
        self.last_saved = 0

    def step(self, consumed, dt):
        at_cap = self.throttled and consumed / dt >= 0.9 * self.limit
        earn = 0.0 if at_cap else self.base * dt
        self.balance = min(self.cap, max(0.0, self.balance + earn - consumed))
        if self.balance <= 0:
            self.throttled = True
        elif self.throttled and self.balance >= self.recover * self.cap:
            self.throttled = False

    def load(self):
        try:
            data = json.loads(read_file(self.path, "{}"))
        except ValueError:
            return False
        if not data.get("balance_s") and data.get("balance_s") != 0:
            return False
        with self.lock:
            self.balance = min(self.cap, float(data["balance_s"]))
            self.throttled = bool(data.get("throttled"))
            self.source = data.get("source", "saved state")
            self.history.extend(tuple(x) for x in data.get("history", []))
            last = data.get("last")
            if last and last.get("boot_id") == boot_id():
                self.last = (float(last["busy_s"]), float(last["t"]))
        return True

    def save(self):
        with self.lock:
            data = {"balance_s": round(self.balance, 1), "throttled": self.throttled, "source": self.source,
                    "history": list(self.history),
                    "last": {"busy_s": self.last[0], "t": self.last[1], "boot_id": boot_id()} if self.last else None}
        try:
            atomic_write(self.path, json.dumps(data), 0o600)
        except OSError:
            pass

    def update(self, busy_s, t):
        with self.lock:
            if self.last and busy_s >= self.last[0] and t > self.last[1]:
                consumed, dt = busy_s - self.last[0], t - self.last[1]
                if self.backfilling:
                    self.pending.append((consumed, dt))
                self.step(consumed, dt)
                self.recent.append((t, self.balance, consumed / dt))
            self.last = (busy_s, t)
            if not self.history or t - self.history[-1][0] >= 60:
                self.history.append((int(t), round(self.balance / self.cap * 100, 2)))
        if t - self.last_saved >= 60:
            self.last_saved = t
            self.save()

    def backfill(self, samples, source):
        """Replay (dt, busy cores) samples from a full balance, then the live steps seen meanwhile."""
        with self.lock:
            self.balance, self.throttled = self.cap, False
            hist = []
            for t, dt, cores, *_ in samples:
                self.step(cores * dt, dt)
                hist.append((int(t), round(self.balance / self.cap * 100, 2)))
            for consumed, dt in self.pending:
                self.step(consumed, dt)
            self.pending = []
            self.backfilling = False
            self.source = source
            live = list(self.history)
            self.history.clear()
            self.history.extend(hist + [h for h in live if not hist or h[0] > hist[-1][0]])
        self.save()

    def summary(self):
        with self.lock:
            bal, cap, thr = self.balance, self.cap, self.throttled
            recent = list(self.recent)
            hist = list(self.history)
            source = self.source
        use = None
        rate = None
        window = [r for r in recent if r[0] >= time.time() - 300]
        if len(window) >= 2:
            span = window[-1][0] - window[0][0]
            if span > 0:
                rate = (window[-1][1] - window[0][1]) / span
                use = sum(r[2] for r in window) / len(window)
        out = {
            "balance_pct": round(bal / cap * 100, 1), "balance_s": round(bal), "capacity_s": round(cap),
            "vcpus": self.n, "baseline_cores": round(self.base, 2), "throttle_cores": round(self.limit, 2),
            "throttled_est": thr, "recover_pct": self.recover * 100, "source": source,
            "use_cores": round(use, 2) if use is not None else None,
            "net_per_min": round(rate * 60) if rate is not None else None,
            "burst_full_min": round(bal / (self.n - self.base) / 60) if self.n > self.base else None,
            "history": hist,
        }
        if use is not None and use > self.base:
            out["empty_in_min"] = round(bal / (use - self.base) / 60)
        elif use is not None and bal < cap:
            out["full_in_min"] = round((cap - bal) / max(0.01, self.base - use) / 60)
        return out


def downsample(points, since, bins=600):
    """Average dict points (with "t") newer than SINCE into at most BINS buckets."""
    points = [p for p in points if p["t"] >= since]
    if len(points) <= bins:
        return points
    width = (points[-1]["t"] - since) / float(bins) or 1
    out, cur, idx = [], None, None
    for p in points:
        b = int((p["t"] - since) // width)
        if b != idx:
            if cur:
                out.append(cur.finish())
            cur, idx = _Bucket(), b
        cur.add(p)
    if cur:
        out.append(cur.finish())
    return out


class _Bucket:
    def __init__(self):
        self.sums, self.counts, self.last = {}, {}, None

    def add(self, p):
        self.last = p
        for k, v in p.items():
            if k != "t" and isinstance(v, (int, float)):
                self.sums[k] = self.sums.get(k, 0.0) + v
                self.counts[k] = self.counts.get(k, 0) + 1

    def finish(self):
        out = {"t": self.last["t"]}
        for k in self.sums:
            out[k] = round(self.sums[k] / self.counts[k], 2)
        return out


class MinuteHistory:
    """Per-minute averages of the live samples, kept for PANEL_HISTORY_DAYS and persisted."""

    def __init__(self, path, days):
        self.path = path
        self.lock = threading.Lock()
        self.points = collections.deque(maxlen=max(1, days) * 24 * 60)
        self.minute = None
        self.acc = _Bucket()
        self.last_saved = time.time()

    def add(self, rec):
        m = int(rec["t"]) // 60
        with self.lock:
            if self.minute is not None and m != self.minute and self.acc.last:
                point = self.acc.finish()
                point["t"] = self.minute * 60
                self.points.append(point)
                self.acc = _Bucket()
            self.minute = m
            self.acc.add(rec)
        if time.time() - self.last_saved >= 300:
            self.save()

    def load(self):
        try:
            data = json.loads(read_file(self.path, ""))
        except ValueError:
            return False
        if not isinstance(data, list):
            return False
        with self.lock:
            self.points.extend(p for p in data if isinstance(p, dict) and "t" in p)
        return True

    def save(self):
        self.last_saved = time.time()
        with self.lock:
            data = list(self.points)
        try:
            atomic_write(self.path, json.dumps(data, separators=(",", ":")), 0o600)
        except OSError:
            pass

    def seed(self, points):
        """Prepend older points (e.g. from atop) before the first live minute."""
        with self.lock:
            first = self.points[0]["t"] if self.points else float("inf")
            merged = [p for p in points if p["t"] < first] + list(self.points)
            self.points.clear()
            self.points.extend(merged[-self.points.maxlen:])
        self.save()

    def snapshot(self):
        with self.lock:
            return list(self.points)


def atop_samples(atop_dir, hours, hz_cores=100.0):
    """(epoch, interval seconds, busy cores, steal cores) from atop logs of the last HOURS hours."""
    since = time.time() - hours * 3600
    days = sorted({time.strftime("%Y%m%d", time.localtime(x))
                   for x in range(int(since), int(time.time()) + 86400, 86400)})
    samples = []
    for day in days:
        path = os.path.join(atop_dir, "atop_" + day)
        if not os.path.exists(path):
            continue
        rc, out = run(["nice", "-n", "19", "atopsar", "-c", "-r", path], timeout=900)
        if rc != 0:
            continue
        prev = None
        for line in out.splitlines():
            f = line.split()
            if len(f) >= 11 and f[1] == "all" and re.fullmatch(r"\d\d:\d\d:\d\d", f[0]):
                t = time.mktime(time.strptime(day + " " + f[0], "%Y%m%d %H:%M:%S"))
                if prev is not None and 0 < t - prev <= 3600 and t >= since:
                    try:
                        cores = sum(float(x) for x in f[2:7]) / hz_cores
                        steal = float(f[7]) / hz_cores
                    except ValueError:
                        cores = None
                    if cores is not None:
                        samples.append((t, t - prev, cores, steal))
                prev = t
            elif "restart" in line.lower():
                prev = None
    samples.sort()
    return samples


class Sampler(threading.Thread):
    """Samples /proc and the agent slice periodically; keeps a short history."""

    def __init__(self, panel):
        super().__init__(daemon=True)
        self.panel = panel
        self.lock = threading.Lock()
        self.prev_cpu = None
        self.prev_procs = {}
        self.prev_slice = None
        self.prev_t = None
        self.procs = []
        self.host = {}
        self.slow = {}
        self.slow_t = 0
        self.last_view = 0
        self.sample_lock = threading.Lock()
        self.slice_path = None
        self.slice_name = None
        maxlen = int(panel.conf["PANEL_HISTORY_MIN"]) * 60 // max(1, int(panel.conf["PANEL_SAMPLE_SEC"]))
        self.history = collections.deque(maxlen=max(10, maxlen))
        self.hz = os.sysconf("SC_CLK_TCK")
        self.nproc = os.cpu_count() or 1
        self.boot = self._boot_time()
        days = int(panel.conf["PANEL_HISTORY_DAYS"])
        self.minutes = MinuteHistory(os.path.join(panel.state_dir(), "panel-history.json"), days)
        need_history = not self.minutes.load()
        self.credits = None
        need_credits = False
        if panel.conf["PANEL_CREDIT_MODEL"] == "1":
            self.credits = CreditModel(panel.conf, self.nproc,
                                       os.path.join(panel.state_dir(), "panel-credits.json"))
            need_credits = not self.credits.load()
            self.credits.backfilling = need_credits
        if need_history or need_credits:
            threading.Thread(target=self.backfill, args=(need_history, need_credits), daemon=True).start()

    def backfill(self, need_history, need_credits):
        """One pass over the atop logs seeds the minute history and replays the credits."""
        replay = int(self.panel.conf["PANEL_CREDIT_REPLAY_HOURS"])
        hours = max(replay if need_credits else 0, int(self.panel.conf["PANEL_HISTORY_DAYS"]) * 24 if need_history else 0)
        samples = atop_samples(self.panel.conf["PANEL_ATOP_DIR"], hours)
        if need_history and samples:
            n = float(self.nproc)
            self.minutes.seed([{"t": int(t), "busy": round(c / n * 100, 1), "steal": round(st / n * 100, 1)}
                               for t, _dt, c, st in samples])
        if need_credits:
            since = time.time() - replay * 3600
            replayed = [x for x in samples if x[0] >= since]
            if replayed:
                span = (replayed[-1][0] - replayed[0][0]) / 3600
                self.credits.backfill(replayed, "replayed %.0f h of atop history, then live" % span)
            else:
                with self.credits.lock:
                    self.credits.backfilling = False
                    self.credits.pending = []

    def _boot_time(self):
        for line in read_file(os.path.join(PROC, "stat")).splitlines():
            if line.startswith("btime "):
                return int(line.split()[1])
        return 0

    def run(self):
        while True:
            try:
                self.sample()
            except Exception as e:
                sys.stderr.write("sample error: %s\n" % e)
            time.sleep(max(1, int(self.panel.conf["PANEL_SAMPLE_SEC"])))

    def read_cpu(self):
        for line in read_file(os.path.join(PROC, "stat")).splitlines():
            if line.startswith("cpu "):
                return [int(x) for x in line.split()[1:]]
        return None

    def read_procs(self):
        procs = {}
        for name in os.listdir(PROC):
            if not name.isdigit():
                continue
            raw = read_file(os.path.join(PROC, name, "stat"))
            if not raw:
                continue
            r = raw.rfind(")")
            l = raw.find("(")
            if r < 0 or l < 0:
                continue
            f = raw[r + 2:].split()
            if len(f) < 22 or int(f[6]) & 0x00200000:
                continue
            procs[int(name)] = {
                "comm": raw[l + 1:r],
                "state": f[0],
                "ppid": int(f[1]),
                "tty_nr": int(f[4]),
                "ticks": int(f[11]) + int(f[12]),
                "start": int(f[19]),
                "rss_kb": int(f[21]) * (os.sysconf("SC_PAGE_SIZE") // 1024),
            }
        return procs

    def viewed(self):
        self.last_view = time.time()

    def viewing(self):
        return time.time() - self.last_view < 30

    def slice_dir(self):
        name = self.panel.watchdog_value("AGENT_SLICE")
        if name == self.slice_name and self.slice_path and os.path.isdir(self.slice_path):
            return self.slice_path
        self.slice_name, self.slice_path = name, self.find_slice(name)
        return self.slice_path

    def find_slice(self, name):
        for root, dirs, _files in os.walk(CGROUP):
            if os.path.basename(root) == name:
                return root
            if root.count(os.sep) - CGROUP.count(os.sep) >= 3:
                dirs[:] = []
        return None

    def read_slice(self):
        d = self.slice_dir()
        if not d:
            return None
        stat = {}
        for line in read_file(os.path.join(d, "cpu.stat")).splitlines():
            parts = line.split()
            if len(parts) == 2:
                stat[parts[0]] = int(parts[1])
        quota_raw = read_file(os.path.join(d, "cpu.max")).split()
        quota = None
        if len(quota_raw) == 2 and quota_raw[0] != "max":
            quota = round(int(quota_raw[0]) * 100 / int(quota_raw[1]))
        scopes = sum(1 for n in os.listdir(d) if n.endswith(".scope"))
        return {
            "dir": d,
            "usage_usec": stat.get("usage_usec", 0),
            "throttled_usec": stat.get("throttled_usec", 0),
            "nr_throttled": stat.get("nr_throttled", 0),
            "quota_pct": quota,
            "pressure": parse_pressure(read_file(os.path.join(d, "cpu.pressure"))),
            "scopes": scopes,
        }

    def sample(self):
        with self.sample_lock:
            self._sample()

    def _sample(self):
        t = time.time()
        cpu = self.read_cpu()
        viewing = self.viewing()
        procs = self.read_procs() if viewing else {}
        sl = self.read_slice()
        host = {"t": t, "nproc": self.nproc}
        if cpu and self.prev_cpu:
            d = [a - b for a, b in zip(cpu, self.prev_cpu)]
            total = sum(d[:8]) or 1
            user, nice, system, idle, iowait, irq, softirq, steal = (d + [0] * 8)[:8]
            host.update({
                "busy_pct": round((user + nice + system + irq + softirq) * 100 / total, 1),
                "user_pct": round((user + nice) * 100 / total, 1),
                "system_pct": round((system + irq + softirq) * 100 / total, 1),
                "iowait_pct": round(iowait * 100 / total, 1),
                "steal_pct": round(steal * 100 / total, 1),
                "idle_pct": round(idle * 100 / total, 1),
            })
        dt = (t - self.prev_t) if self.prev_t else None
        if sl and self.prev_slice and dt:
            sl["usage_pct"] = round((sl["usage_usec"] - self.prev_slice["usage_usec"]) / (dt * 10000), 1)
            sl["throttled_pct"] = round(
                (sl["throttled_usec"] - self.prev_slice["throttled_usec"]) / (dt * 10000), 1)
        mem = meminfo()
        host.update(mem)
        host["load"] = read_file(os.path.join(PROC, "loadavg")).split()[:3]
        host["psi"] = {r: parse_pressure(read_file(os.path.join(PROC, "pressure", r)))
                       for r in ("cpu", "memory", "io")}
        host["uptime_sec"] = int(float(read_file(os.path.join(PROC, "uptime"), "0").split()[0]))

        rows = []
        if dt:
            for pid, p in procs.items():
                prev = self.prev_procs.get(pid)
                if prev and prev["start"] == p["start"]:
                    p["cpu"] = round((p["ticks"] - prev["ticks"]) * 100 / (self.hz * dt), 1)
                else:
                    p["cpu"] = None
                rows.append((pid, p))

        if viewing and t - self.slow_t > 10:
            slow = self.panel.collect_slow()
            with self.lock:
                self.slow = slow
            self.slow_t = t

        with self.lock:
            self.prev_cpu, self.prev_procs, self.prev_slice, self.prev_t = cpu, procs, sl, t
        if cpu and self.credits:
            self.credits.update(busy_seconds(cpu, self.hz), t)
        with self.lock:
            self.host = host
            self.slice = sl
            self.procs = rows
            if "busy_pct" in host:
                self.history.append({
                    "t": int(t),
                    "busy": host["busy_pct"],
                    "steal": host["steal_pct"],
                    "iowait": host["iowait_pct"],
                    "agents": (sl or {}).get("usage_pct"),
                    "quota": (sl or {}).get("quota_pct"),
                    "mem_avail": host.get("mem_avail_pct"),
                    "swap_used": host.get("swap_used_pct"),
                    "psi_cpu": host["psi"]["cpu"].get("some", {}).get("avg10"),
                })
                self.minutes.add(self.history[-1])

    def snapshot(self):
        with self.lock:
            return self.host, getattr(self, "slice", None), list(self.procs), dict(self.slow)


def parse_pressure(text):
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        vals = {}
        for kv in parts[1:]:
            k, _, v = kv.partition("=")
            try:
                vals[k] = float(v)
            except ValueError:
                pass
        out[parts[0]] = vals
    return out


def meminfo():
    info = {}
    for line in read_file(os.path.join(PROC, "meminfo")).splitlines():
        k, _, rest = line.partition(":")
        try:
            info[k] = int(rest.split()[0])
        except (IndexError, ValueError):
            pass
    total = info.get("MemTotal", 1)
    avail = info.get("MemAvailable", 0)
    swap_total = info.get("SwapTotal", 0)
    swap_free = info.get("SwapFree", 0)
    return {
        "mem_total_mb": total // 1024,
        "mem_avail_mb": avail // 1024,
        "mem_avail_pct": round(avail * 100 / total, 1),
        "swap_total_mb": swap_total // 1024,
        "swap_used_mb": (swap_total - swap_free) // 1024,
        "swap_used_pct": round((swap_total - swap_free) * 100 / swap_total, 1) if swap_total else 0,
    }


def proc_extra(pid):
    base = os.path.join(PROC, str(pid))
    try:
        cwd = os.readlink(os.path.join(base, "cwd"))
    except OSError:
        cwd = ""
    cmd = read_file(os.path.join(base, "cmdline")).replace("\0", " ").strip()
    user = ""
    for line in read_file(os.path.join(base, "status")).splitlines():
        if line.startswith("Uid:"):
            uid = int(line.split()[1])
            try:
                user = pwd.getpwuid(uid).pw_name
            except KeyError:
                user = str(uid)
            break
    try:
        tty = os.readlink(os.path.join(base, "fd", "0"))
        tty = tty[5:] if tty.startswith("/dev/pts/") or tty.startswith("/dev/tty") else ""
    except OSError:
        tty = ""
    cgroup = read_file(os.path.join(base, "cgroup")).strip().rsplit(":", 1)[-1]
    return {"cwd": cwd, "cmd": cmd[:400], "user": user, "tty": tty, "cgroup": cgroup}


class Panel:
    def __init__(self):
        self.conf = load_panel_conf()
        self.token = self.load_token()
        self.sampler = Sampler(self)
        self.audit_lock = threading.Lock()
        self.override_lock = threading.Lock()
        self.gov = {"enabled": False}
        self.gov_quota = "unset"

    def load_token(self):
        path = self.conf["PANEL_TOKEN_FILE"]
        token = read_file(path).strip()
        if not token:
            token = secrets.token_urlsafe(32)
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(token + "\n")
        return token

    def watchdog_values(self):
        return parse_assignments(read_file(self.conf["WATCHDOG_CONF"]))

    def watchdog_value(self, key):
        v = self.watchdog_values().get(key)
        if v is None and key in SCHEMA_BY_KEY:
            v = SCHEMA_BY_KEY[key][3]
        return v

    def audit(self, msg):
        line = "%s PANEL %s\n" % (now_str(), msg)
        log = self.watchdog_value("LOG_FILE") or "/var/log/cpu-watchdog.log"
        with self.audit_lock:
            try:
                with open(log, "a", encoding="utf-8") as f:
                    f.write(line)
            except OSError:
                sys.stderr.write(line)

    def units(self):
        return [u for u in self.conf["PANEL_UNITS"].split() if UNIT_RE.match(u)]

    def collect_slow(self):
        props = ["ActiveState", "SubState", "MainPID", "MemoryCurrent", "CPUUsageNSec",
                 "ActiveEnterTimestamp", "Description", "LoadState", "UnitFileState"]
        units = systemctl_show_many(self.units(), props)
        timer = systemctl_show("cpu-watchdog.timer", ["ActiveState", "LastTriggerUSec", "NextElapseUSecRealtime"])
        service = systemctl_show("cpu-watchdog.service", ["Result", "ExecMainStatus", "ExecMainExitTimestamp"])
        earlyoom = systemctl_show("earlyoom.service", ["ActiveState", "SubState"])
        return {"units": units, "timer": timer, "service": service, "earlyoom": earlyoom}

    def state_dir(self):
        return self.watchdog_value("STATE_DIR") or "/var/lib/cpu-watchdog"

    def watchdog_state(self):
        sd = self.state_dir()
        limited = []
        for line in read_file(os.path.join(sd, "limited.tsv")).splitlines():
            parts = line.split("\t")
            if len(parts) >= 5:
                pid = parts[0].split(":")[0]
                limited.append({"key": parts[0], "pid": int(pid), "cpulimit_pid": parts[1],
                                "limit": parts[2], "applied_at": parts[3], "reason": parts[4],
                                "comm": read_file(os.path.join(PROC, pid, "comm")).strip()})
        freed = [l.split("\t")[0] for l in read_file(os.path.join(sd, "freed.tsv")).splitlines() if l.strip()]
        quota = read_file(os.path.join(sd, "agent_quota")).strip().split("\t")
        agg_count = read_file(os.path.join(sd, "agg_count")).strip()
        mem_sys = read_file(os.path.join(sd, "mem_sys_count")).strip()
        return {
            "limited": limited,
            "freed": freed,
            "agent_quota_state": quota[0] if quota and quota[0] else "off",
            "agg_count": int(agg_count) if agg_count.isdigit() else 0,
            "mem_sys_count": int(mem_sys) if mem_sys.isdigit() else 0,
        }

    def status(self):
        if not self.sampler.viewing():
            self.sampler.viewed()
            self.sampler.sample()
        self.sampler.viewed()
        host, sl, rows, slow = self.sampler.snapshot()
        vals = self.watchdog_values()

        def val(k):
            return vals.get(k, SCHEMA_BY_KEY[k][3] if k in SCHEMA_BY_KEY else "")

        agent_comm = set(val("AGENT_COMM").split())
        limited = self.watchdog_state()
        limited_pids = {e["pid"]: e for e in limited["limited"]}
        slice_name = val("AGENT_SLICE")

        hot = sorted((r for r in rows if r[1].get("cpu") is not None), key=lambda r: -r[1]["cpu"])[:40]
        big = sorted(rows, key=lambda r: -r[1]["rss_kb"])[:15]
        agents = [r for r in rows if r[1]["comm"] in agent_comm]
        chosen = {}
        for pid, p in hot + big + agents:
            chosen[pid] = p
        procs = []
        for pid, p in chosen.items():
            extra = proc_extra(pid)
            age = int(time.time() - self.sampler.boot - p["start"] / self.sampler.hz)
            procs.append({
                "pid": pid, "start": p["start"], "comm": p["comm"], "state": p["state"],
                "ppid": p["ppid"], "cpu": p.get("cpu"), "rss_mb": p["rss_kb"] // 1024,
                "age_sec": age, "agent": p["comm"] in agent_comm,
                "in_slice": ("/" + slice_name + "/") in extra["cgroup"],
                "throttled": limited_pids.get(pid, {}).get("limit"),
                **extra,
            })
        counts = collections.Counter(p["comm"] for _pid, p in rows)
        thresholds = {k: val(k) for k in ("AGG_CPU_THRESHOLD_PCT", "AGENT_CPU_QUOTA_PCT", "MODE",
                                          "AGG_SUSTAIN_CHECKS", "CPU_THRESHOLD")}
        return {
            "now": int(time.time()),
            "hostname": socket.gethostname(),
            "host": host,
            "slice": {k: v for k, v in (sl or {}).items() if k != "dir"} if sl else None,
            "slice_name": slice_name,
            "watchdog": {**limited, **slow, "thresholds": thresholds},
            "processes": procs,
            "process_count": len(rows),
            "agent_count": len(agents),
            "top_comm": counts.most_common(8),
            "units": self.units(),
            "allow_reboot": self.conf["PANEL_ALLOW_REBOOT"] == "1",
            "overrides": [{k: v for k, v in o.items() if k != "data"} for o in self.load_overrides()],
            "credits": self.credit_summary(),
            "governor": self.gov,
        }

    def credit_summary(self):
        c = self.sampler.credits
        if not c:
            return None
        out = c.summary()
        out.pop("history", None)
        out["backfilling"] = c.backfilling
        return out

    def credit_history(self, seconds):
        c = self.sampler.credits
        if not c:
            return []
        points = [{"t": t, "credits": v} for t, v in c.summary()["history"]]
        return downsample(points, time.time() - seconds)

    def history(self, seconds):
        since = time.time() - seconds
        with self.sampler.lock:
            raw = list(self.sampler.history)
        if raw and raw[0]["t"] <= since:
            return downsample(raw, since)
        first_raw = raw[0]["t"] if raw else float("inf")
        older = [p for p in self.sampler.minutes.snapshot() if p["t"] < first_raw]
        return downsample(older + raw, since)

    def config(self):
        vals = self.watchdog_values()
        entries = []
        for group, key, kind, default, doc in SCHEMA:
            present = key in vals
            v = vals.get(key, "")
            if kind == "secret":
                v = "set" if v else ""
            entries.append({"group": group, "key": key, "type": kind, "default": default,
                            "doc": doc, "set": present, "value": v})
        for key, v in vals.items():
            if key not in SCHEMA_BY_KEY:
                entries.append({"group": "Other", "key": key, "type": "str", "default": "",
                                "doc": "Not in the panel schema.", "set": True, "value": v})
        eo = parse_assignments(read_file(self.conf["EARLYOOM_DEFAULT"])).get("EARLYOOM_ARGS", "")
        return {
            "path": self.conf["WATCHDOG_CONF"],
            "entries": entries,
            "earlyoom_args": eo,
            "earlyoom_path": self.conf["EARLYOOM_DEFAULT"],
            "panel_units": self.conf["PANEL_UNITS"],
            "nproc": self.sampler.nproc,
            "has_backup": os.path.exists(self.conf["WATCHDOG_CONF"] + ".panel-bak"),
        }

    def save_config(self, body):
        changes = body.get("changes") or {}
        if not isinstance(changes, dict) or not changes:
            raise ValueError("no changes")
        rendered = {}
        for key, value in changes.items():
            if not KEY_RE.match(key) or key.startswith("CPU_WATCHDOG_"):
                raise ValueError("invalid key %r" % key)
            if SCHEMA_BY_KEY.get(key, ("", "", ""))[2] == "secret" and value == "":
                continue
            rendered[key] = validate_value(key, value, self.sampler.nproc)
        if not rendered:
            raise ValueError("no changes")
        minutes = duration_minutes(body)
        if minutes and any(SCHEMA_BY_KEY.get(k, ("", "", ""))[2] == "secret" for k in rendered):
            raise ValueError("secrets cannot be changed temporarily")
        previous = self.write_watchdog_conf(rendered)
        shown = {k: ("<secret>" if SCHEMA_BY_KEY.get(k, ("", "", ""))[2] == "secret" else v)
                 for k, v in rendered.items()}
        self.audit("config %s%s" % (" ".join("%s=%s" % kv for kv in shown.items()),
                                    " for %d min" % minutes if minutes else ""))
        messages = ["Saved %d key(s) (backup: .panel-bak)." % len(rendered)]
        quota_prev = None
        if body.get("apply_quota") and "AGENT_CPU_QUOTA_PCT" in rendered:
            _host, sl, _rows, _slow = self.sampler.snapshot()
            if sl and sl.get("quota_pct") is not None:
                quota_prev = sl["quota_pct"]
                messages.append(self.set_quota(rendered["AGENT_CPU_QUOTA_PCT"]))
            else:
                messages.append("Agent slice is not capped right now; the new quota applies on the next cap.")
        if minutes:
            self.add_override("config", minutes, {
                "previous": previous, "applied": rendered,
                "quota_previous": quota_prev,
                "quota_applied": int(rendered["AGENT_CPU_QUOTA_PCT"]) if quota_prev is not None else None,
            }, "config " + ", ".join("%s=%s" % kv for kv in shown.items()))
            messages.append("Reverts automatically in %d min." % minutes)
        return {"ok": True, "message": " ".join(messages)}

    def write_watchdog_conf(self, rendered):
        """Write rendered values; return the previous raw values (None = unset)."""
        path = self.conf["WATCHDOG_CONF"]
        original = read_file(path, None)
        if original is None:
            raise ValueError("%s not found" % path)
        raw = raw_assignments(original)
        new_text = set_assignments(original, rendered)
        tmp = path + ".panel-check"
        atomic_write(tmp, new_text, 0o600)
        ok, err = bash_syntax_ok(tmp)
        os.unlink(tmp)
        if not ok:
            raise ValueError("bash -n rejected the result: %s" % err)
        backup(path)
        atomic_write(path, new_text, 0o600)
        return {k: raw.get(k) for k in rendered}

    # --- temporary overrides ---

    def overrides_path(self):
        return os.path.join(self.state_dir(), "panel-overrides.json")

    def load_overrides(self):
        try:
            data = json.loads(read_file(self.overrides_path(), "[]"))
            return data if isinstance(data, list) else []
        except ValueError:
            return []

    def store_overrides(self, items):
        os.makedirs(self.state_dir(), exist_ok=True)
        atomic_write(self.overrides_path(), json.dumps(items, indent=1), 0o600)

    def add_override(self, kind, minutes, data, label):
        with self.override_lock:
            items = self.load_overrides()
            items.append({"id": secrets.token_hex(6), "kind": kind, "label": label,
                          "created": int(time.time()), "expires": int(time.time()) + minutes * 60,
                          "data": data})
            self.store_overrides(items)

    def revert_override(self, item):
        kind, data = item["kind"], item["data"]
        notes = []
        if kind == "config":
            path = self.conf["WATCHDOG_CONF"]
            current = raw_assignments(read_file(path, ""))
            restore = {}
            for key, applied in data["applied"].items():
                if current.get(key) == applied:
                    restore[key] = data["previous"].get(key)
                else:
                    notes.append("%s changed since, kept" % key)
            if restore:
                self.write_watchdog_conf(restore)
            if data.get("quota_applied") is not None:
                _h, sl, _r, _s = self.sampler.snapshot()
                if sl and sl.get("quota_pct") == data["quota_applied"]:
                    self.set_quota(str(data["quota_previous"]))
        elif kind == "quota":
            _h, sl, _r, _s = self.sampler.snapshot()
            current = sl.get("quota_pct") if sl else None
            if current == data["applied"]:
                self.set_quota("" if data["previous"] is None else str(data["previous"]))
            else:
                notes.append("quota changed since, kept")
        elif kind == "timer":
            run(["systemctl", "start", "cpu-watchdog.timer"])
        elif kind == "free":
            run([self.conf["WATCHDOG_CTL"], "free", data["target"], "--undo"],
                env={"TMUX_USER": data.get("user") or "root"})
        self.audit("override expired: %s%s" % (item["label"], " (%s)" % "; ".join(notes) if notes else ""))

    def expire_overrides(self, force_id=None):
        with self.override_lock:
            items = self.load_overrides()
            now = time.time()
            keep, due = [], []
            for it in items:
                (due if it["expires"] <= now or it["id"] == force_id else keep).append(it)
            if not due:
                return False
            for it in due:
                try:
                    self.revert_override(it)
                except Exception as e:
                    self.audit("override revert failed: %s: %s" % (it["label"], e))
            self.store_overrides(keep)
            return True

    def extend_override(self, oid, minutes):
        with self.override_lock:
            items = self.load_overrides()
            for it in items:
                if it["id"] == oid:
                    it["expires"] = int(time.time()) + minutes * 60
                    self.store_overrides(items)
                    self.audit("override extended: %s to %d min" % (it["label"], minutes))
                    return {"ok": True, "message": "Now reverts in %d min." % minutes}
        raise ValueError("override not found")

    def drop_override(self, oid):
        with self.override_lock:
            items = self.load_overrides()
            keep = [it for it in items if it["id"] != oid]
            if len(keep) == len(items):
                raise ValueError("override not found")
            self.store_overrides(keep)
            self.audit("override made permanent: %s" % oid)
        return {"ok": True, "message": "Change kept permanently."}

    # --- credit governor ---

    GOV_MARGIN_CORES = 0.25

    def governor_file(self):
        return os.path.join(self.state_dir(), "credit-governor")

    def governor_decide(self, vals, summary, total_cores, agent_cores):
        """Allowed host CPU and the agent quota (None = uncapped), in cores/percent."""
        c = self.sampler.credits
        horizon = max(1, int(vals.get("CREDIT_HORIZON_MIN") or 120))
        floor = int(vals.get("CREDIT_GOV_MIN_QUOTA_PCT") or 100)
        if summary["throttled_est"]:
            allowed = c.limit
        else:
            allowed = min(c.n, c.base + summary["balance_s"] / (horizon * 60.0))
        others = max(0.0, total_cores - agent_cores)
        quota = int(round((allowed - others - self.GOV_MARGIN_CORES) * 100 / 25.0)) * 25
        quota = max(floor, quota)
        if allowed >= c.n - 1e-6 or quota >= c.n * 100:
            return allowed, others, None
        return allowed, others, quota

    def governor_tick(self):
        vals = self.watchdog_values()
        c = self.sampler.credits
        enabled = vals.get("CREDIT_GOVERNOR") == "1" and c is not None and not c.backfilling
        observe = vals.get("MODE", "active") == "observe"
        if not enabled:
            if self.gov.get("enabled"):
                try:
                    os.unlink(self.governor_file())
                except OSError:
                    pass
                if not observe:
                    self.set_quota("", quiet=True)
                self.audit("governor off -> agent quota released, fixed policy restored")
            self.gov = {"enabled": False}
            self.gov_quota = "unset"
            return
        with self.sampler.lock:
            recent = list(self.sampler.history)[-20:]
        if len(recent) < 5:
            return
        n = c.n
        total = sum(r["busy"] for r in recent) / len(recent) * n / 100
        agents = [r["agents"] for r in recent if r.get("agents") is not None]
        agent_cores = sum(agents) / len(agents) / 100 if agents else 0.0
        summary = c.summary()
        allowed, others, quota = self.governor_decide(vals, summary, total, agent_cores)
        self.gov = {"enabled": True, "observe": observe, "allowed_cores": round(allowed, 2),
                    "others_cores": round(others, 2), "agents_cores": round(agent_cores, 2),
                    "quota_pct": quota, "balance_pct": summary["balance_pct"],
                    "horizon_min": int(vals.get("CREDIT_HORIZON_MIN") or 120), "t": int(time.time())}
        if observe:
            return
        if quota != self.gov_quota:
            prev = self.gov_quota
            self.set_quota("" if quota is None else str(quota), quiet=True)
            self.gov_quota = quota
            big = prev == "unset" or prev is None or quota is None or abs(quota - prev) >= 100
            if big:
                self.audit("governor agent quota %s (balance %.0f%%, allowed %.1f cores, others %.1f)" % (
                    "uncapped" if quota is None else "%d%%" % quota, summary["balance_pct"], allowed, others))
        atomic_write(self.governor_file(), "%d\t%d\t%.1f\t%d\n" % (
            time.time(), allowed * 100, summary["balance_pct"], quota or 0), 0o600)

    def governor_loop(self):
        while True:
            time.sleep(30)
            try:
                self.governor_tick()
            except Exception as e:
                sys.stderr.write("governor error: %s\n" % e)

    def reverter(self):
        while True:
            time.sleep(10)
            try:
                self.expire_overrides()
            except Exception as e:
                sys.stderr.write("reverter error: %s\n" % e)

    def restore_config(self):
        path = self.conf["WATCHDOG_CONF"]
        bak = read_file(path + ".panel-bak", None)
        if bak is None:
            raise ValueError("no backup")
        current = read_file(path, "")
        atomic_write(path, bak, 0o600)
        atomic_write(path + ".panel-bak", current, 0o600)
        self.audit("config restored from backup")
        return {"ok": True, "message": "Restored previous configuration (the replaced one is now the backup)."}

    def save_earlyoom(self, body):
        args = body.get("args", "")
        if not isinstance(args, str) or "\n" in args:
            raise ValueError("invalid args")
        try:
            shlex.split(args)
        except ValueError as e:
            raise ValueError("args do not parse: %s" % e)
        path = self.conf["EARLYOOM_DEFAULT"]
        original = read_file(path, "")
        new_text = set_assignments(original, {"EARLYOOM_ARGS": bash_quote(args)})
        backup(path)
        atomic_write(path, new_text, 0o644)
        rc, out = run(["systemctl", "restart", "earlyoom"], timeout=30)
        time.sleep(1.5)
        active = systemctl_show("earlyoom.service", ["ActiveState"]).get("ActiveState")
        if rc != 0 or active != "active":
            atomic_write(path, original, 0o644)
            run(["systemctl", "restart", "earlyoom"], timeout=30)
            self.audit("earlyoom args rejected, rolled back")
            raise ValueError("earlyoom did not start with these args; rolled back. %s" % out)
        self.audit("earlyoom args=%s" % args)
        return {"ok": True, "message": "earlyoom restarted with the new arguments."}

    def save_units(self, body):
        units = " ".join(body.get("units", "").split())
        if any(not UNIT_RE.match(u) for u in units.split()):
            raise ValueError("invalid unit name")
        text = read_file(PANEL_CONF, "")
        atomic_write(PANEL_CONF, set_assignments(text, {"PANEL_UNITS": bash_quote(units)}), 0o600)
        self.conf["PANEL_UNITS"] = units
        self.audit("panel units=%s" % units)
        return {"ok": True, "message": "Managed units updated."}

    def set_quota(self, pct, quiet=False):
        slice_name = self.watchdog_value("AGENT_SLICE")
        value = "" if pct in ("", "0", None) else "%s%%" % int(pct)
        rc, out = run(["systemctl", "set-property", "--runtime", slice_name, "CPUQuota=" + value])
        if rc != 0:
            raise ValueError("set-property failed: %s" % out)
        if not quiet:
            self.audit("quota %s=%s" % (slice_name, value or "none"))
        return "Agent slice quota now %s." % (value or "unlimited")

    def action(self, body):
        a = body.get("action")
        if a == "watchdog_run":
            rc, out = run(["systemctl", "start", "--no-block", "cpu-watchdog.service"])
            self.audit("run watchdog now")
            return self.result(rc, out, "Watchdog run started.")
        minutes = duration_minutes(body)
        if a == "timer":
            op = body.get("op")
            if op not in ("start", "stop", "restart"):
                raise ValueError("invalid op")
            if minutes and op != "stop":
                raise ValueError("only stop can be temporary")
            rc, out = run(["systemctl", op, "cpu-watchdog.timer"])
            self.audit("timer %s%s" % (op, " for %d min" % minutes if minutes else ""))
            res = self.result(rc, out, "cpu-watchdog.timer %s." % op)
            if minutes:
                self.add_override("timer", minutes, {}, "watchdog paused")
                res["message"] += " Resumes automatically in %d min." % minutes
            return res
        if a == "quota":
            if self.gov.get("enabled") and not self.gov.get("observe"):
                raise ValueError("The credit governor manages the agent quota. Turn it off "
                                 "(permanently or for a while) before setting the quota by hand.")
            value = str(body.get("value", "")).rstrip("%")
            if value and not value.isdigit():
                raise ValueError("quota must be a number")
            _h, sl, _r, _s = self.sampler.snapshot()
            previous = sl.get("quota_pct") if sl else None
            message = self.set_quota(value)
            if minutes:
                applied = int(value) if value not in ("", "0") else None
                self.add_override("quota", minutes, {"previous": previous, "applied": applied},
                                  "agent quota %s" % ("%s%%" % value if applied else "removed"))
                message += " Reverts to %s in %d min." % (
                    "%s%%" % previous if previous is not None else "unlimited", minutes)
            return {"ok": True, "message": message}
        if a == "unthrottle":
            target = str(body.get("pid", ""))
            if target != "all" and not target.isdigit():
                raise ValueError("pid must be a number or 'all'")
            rc, out = run([self.conf["WATCHDOG_CTL"], "unthrottle", target])
            self.audit("unthrottle %s" % target)
            return self.result(rc, out, out)
        if a == "free":
            target = str(body.get("target", ""))
            if not re.fullmatch(r"[A-Za-z0-9_.:@%-]+", target):
                raise ValueError("invalid tmux target")
            user = str(body.get("user") or "root")
            try:
                pwd.getpwnam(user)
            except KeyError:
                raise ValueError("unknown user %r" % user)
            cmd = [self.conf["WATCHDOG_CTL"], "free", target] + (["--undo"] if body.get("undo") else [])
            if minutes and body.get("undo"):
                raise ValueError("undo cannot be temporary")
            rc, out = run(cmd, env={"TMUX_USER": user})
            self.audit("free %s/%s%s" % (user, target, " --undo" if body.get("undo") else ""))
            res = self.result(rc, out, out)
            if minutes:
                self.add_override("free", minutes, {"target": target, "user": user},
                                  "free tmux %s/%s" % (user, target))
                res["message"] += " Limits return in %d min." % minutes
            return res
        if a == "kill":
            return self.kill(body)
        if a == "unit":
            unit, op = body.get("unit", ""), body.get("op")
            if unit not in self.units():
                raise ValueError("unit not in PANEL_UNITS")
            if op not in ("start", "stop", "restart"):
                raise ValueError("invalid op")
            base, name = systemctl_cmd(unit)
            cmd = base + [op, name]
            if unit.startswith("cpu-watchdog-panel"):
                cmd.insert(1, "--no-block")
            self.audit("unit %s %s" % (op, unit))
            rc, out = run(cmd, timeout=90)
            return self.result(rc, out, "%s %s." % (unit, op))
        if a == "swap_flush":
            m = meminfo()
            if m["swap_used_mb"] == 0:
                return {"ok": True, "message": "Swap is already empty."}
            if m["mem_avail_mb"] - m["swap_used_mb"] < 2048:
                raise ValueError("Not enough available RAM to absorb %d MB of swap safely." % m["swap_used_mb"])
            self.audit("swap flush (%d MB)" % m["swap_used_mb"])
            rc, out = run(["sh", "-c", "swapoff -a && swapon -a"], timeout=900)
            return self.result(rc, out, "Swap flushed.")
        if a == "reboot":
            if self.conf["PANEL_ALLOW_REBOOT"] != "1":
                raise ValueError("reboot disabled (PANEL_ALLOW_REBOOT)")
            if body.get("confirm") != socket.gethostname():
                raise ValueError("type the hostname to confirm")
            self.audit("REBOOT requested")
            threading.Timer(2, lambda: run(["systemctl", "reboot"])).start()
            return {"ok": True, "message": "Rebooting in 2 seconds."}
        raise ValueError("unknown action")

    def kill(self, body):
        try:
            pid = int(body.get("pid"))
            start = int(body.get("start"))
        except (TypeError, ValueError):
            raise ValueError("pid and start are required")
        sig = {"TERM": signal.SIGTERM, "KILL": signal.SIGKILL, "INT": signal.SIGINT,
               "HUP": signal.SIGHUP, "CONT": signal.SIGCONT}.get(body.get("signal", "TERM"))
        if sig is None:
            raise ValueError("invalid signal")
        if pid <= 1 or pid == os.getpid():
            raise ValueError("refusing to signal pid %d" % pid)
        raw = read_file(os.path.join(PROC, str(pid), "stat"))
        f = raw[raw.rfind(")") + 2:].split() if raw else []
        if len(f) < 20 or int(f[19]) != start:
            raise ValueError("pid %d is no longer the same process" % pid)
        comm = read_file(os.path.join(PROC, str(pid), "comm")).strip()
        os.kill(pid, sig)
        self.audit("kill -%s pid=%d comm=%s" % (body.get("signal", "TERM"), pid, comm))
        return {"ok": True, "message": "Sent SIG%s to %s (%d)." % (body.get("signal", "TERM"), comm, pid)}

    def override_action(self, body):
        oid, op = str(body.get("id", "")), body.get("op")
        if op == "revert":
            if not self.expire_overrides(force_id=oid):
                raise ValueError("override not found")
            return {"ok": True, "message": "Reverted."}
        if op == "extend":
            return self.extend_override(oid, duration_minutes(body) or 10)
        if op == "keep":
            return self.drop_override(oid)
        raise ValueError("invalid op")

    @staticmethod
    def result(rc, out, ok_message):
        if rc != 0:
            raise ValueError(out or "command failed (%d)" % rc)
        return {"ok": True, "message": ok_message or "Done."}

    def tmux_targets(self):
        """Sessions, windows and panes of every user's default tmux server."""
        fmt = "\t".join(["#{session_name}", "#{window_index}", "#{window_name}", "#{pane_index}",
                         "#{pane_pid}", "#{pane_current_command}", "#{pane_current_path}"])
        result = []
        try:
            dirs = sorted(d for d in os.listdir(TMUX_TMPDIR) if re.fullmatch(r"tmux-\d+", d))
        except OSError:
            dirs = []
        for d in dirs:
            uid = int(d[5:])
            if not os.path.exists(os.path.join(TMUX_TMPDIR, d, "default")):
                continue
            try:
                user = pwd.getpwuid(uid).pw_name
            except KeyError:
                continue
            cmd = ["tmux", "list-panes", "-a", "-F", fmt]
            if uid != os.getuid():
                cmd = ["runuser", "-u", user, "--"] + cmd
            rc, out = run(cmd, timeout=10, env={"TMUX_TMPDIR": TMUX_TMPDIR})
            if rc != 0:
                continue
            sessions = collections.OrderedDict()
            for line in out.splitlines():
                f = line.split("\t")
                if len(f) != 7:
                    continue
                sess, widx, wname, pidx, ppid, pcmd, path = f
                win = sessions.setdefault(sess, collections.OrderedDict()).setdefault(
                    widx, {"name": wname, "panes": []})
                win["panes"].append({"target": "%s:%s.%s" % (sess, widx, pidx), "pid": int(ppid),
                                     "command": pcmd, "path": path})
            for sess, windows in sessions.items():
                result.append({
                    "user": user, "session": sess, "target": sess,
                    "windows": [{"target": "%s:%s" % (sess, w), "name": v["name"], "panes": v["panes"]}
                                for w, v in windows.items()],
                })
        return result

    def log_tail(self, n):
        path = self.watchdog_value("LOG_FILE") or "/var/log/cpu-watchdog.log"
        try:
            with open(path, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 256 * 1024))
                data = f.read().decode("utf-8", errors="replace")
        except OSError:
            return []
        return data.splitlines()[-n:]


STATIC_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml"}


class Handler(BaseHTTPRequestHandler):
    panel = None
    server_version = "cpu-watchdog-panel"

    def log_message(self, fmt, *args):
        pass

    def host_ok(self):
        host = (self.headers.get("Host") or "").lower()
        port = self.panel.conf["PANEL_PORT"]
        allowed = {"127.0.0.1:" + port, "localhost:" + port, "[::1]:" + port}
        allowed.update(h.lower() for h in self.panel.conf["PANEL_ALLOWED_HOSTS"].split())
        return host in allowed

    def authorized(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        return hmac.compare_digest(auth[7:].strip().encode(), self.panel.token.encode())

    def send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; "
                         "img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        self.wfile.write(data)

    def guard(self):
        if not self.host_ok():
            self.send(421, {"error": "unexpected Host header"})
            return False
        return True

    def do_GET(self):
        if not self.guard():
            return
        url = urlparse(self.path)
        if not url.path.startswith("/api/"):
            name = "index.html" if url.path in ("/", "/index.html") else url.path.lstrip("/")
            if name not in ("index.html", "app.js", "app.css"):
                return self.send(404, {"error": "not found"})
            data = read_file(os.path.join(STATIC_DIR, name), None)
            if data is None:
                return self.send(404, {"error": "not found"})
            return self.send(200, data.encode(), STATIC_TYPES[os.path.splitext(name)[1]])
        if not self.authorized():
            return self.send(401, {"error": "unauthorized"})
        try:
            if url.path == "/api/status":
                return self.send(200, self.panel.status())
            if url.path in ("/api/history", "/api/credits"):
                try:
                    seconds = int(parse_qs(url.query).get("range", ["3600"])[0])
                except ValueError:
                    seconds = 3600
                seconds = max(300, min(seconds, 31 * 86400))
                if url.path == "/api/credits":
                    return self.send(200, self.panel.credit_history(seconds))
                return self.send(200, self.panel.history(seconds))
            if url.path == "/api/config":
                return self.send(200, self.panel.config())
            if url.path == "/api/tmux":
                return self.send(200, {"sessions": self.panel.tmux_targets()})
            if url.path == "/api/log":
                n = int(parse_qs(url.query).get("n", ["200"])[0])
                return self.send(200, {"lines": self.panel.log_tail(max(1, min(n, 2000)))})
        except Exception as e:
            return self.send(500, {"error": str(e)})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if not self.guard():
            return
        if not self.authorized():
            return self.send(401, {"error": "unauthorized"})
        if not (self.headers.get("Content-Type") or "").startswith("application/json"):
            return self.send(415, {"error": "expected application/json"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(min(length, 1 << 20)) or b"{}")
            if not isinstance(body, dict):
                raise ValueError("expected an object")
        except (ValueError, json.JSONDecodeError) as e:
            return self.send(400, {"error": "bad request: %s" % e})
        routes = {
            "/api/config": self.panel.save_config,
            "/api/config/restore": lambda _b: self.panel.restore_config(),
            "/api/earlyoom": self.panel.save_earlyoom,
            "/api/units": self.panel.save_units,
            "/api/action": self.panel.action,
            "/api/override": self.panel.override_action,
        }
        fn = routes.get(urlparse(self.path).path)
        if fn is None:
            return self.send(404, {"error": "not found"})
        try:
            self.send(200, fn(body))
        except ValueError as e:
            self.send(400, {"error": str(e)})
        except Exception as e:
            self.send(500, {"error": str(e)})


def main():
    if os.geteuid() != 0 and not os.environ.get("CPU_WATCHDOG_PANEL_ALLOW_USER"):
        sys.stderr.write("cpu-watchdog-panel must run as root\n")
        return 1
    panel = Panel()
    panel.sampler.start()
    threading.Thread(target=panel.reverter, daemon=True).start()
    threading.Thread(target=panel.governor_loop, daemon=True).start()
    Handler.panel = panel
    bind, port = panel.conf["PANEL_BIND"], int(panel.conf["PANEL_PORT"])
    family = socket.AF_INET6 if ":" in bind else socket.AF_INET
    ThreadingHTTPServer.address_family = family
    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    sys.stderr.write("cpu-watchdog-panel listening on %s:%d\n" % (bind, port))
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
