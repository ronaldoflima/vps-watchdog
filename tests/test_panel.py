"""Unit and HTTP tests for panel/cpu-watchdog-panel.py (no root, temp files only)."""
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "panel", "cpu-watchdog-panel.py")


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def load_module(env):
    os.environ.update(env)
    spec = importlib.util.spec_from_file_location("panel", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Fixture(unittest.TestCase):
    PANEL_EXTRA = "PANEL_CREDIT_PROVIDER=hostinger\n"

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.conf = os.path.join(self.tmp, "cpu-watchdog.conf")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        with open(self.conf, "w") as f:
            f.write('MODE=active\nCPU_THRESHOLD=80\nWHITELIST_CMDLINE="a\\\\.b|c"\n'
                    'TELEGRAM_BOT_TOKEN="Zq9SecretValue"\nSTATE_DIR="%s"\nLOG_FILE="%s/log"\n'
                    'AGENT_CPU_QUOTA_PCT=350\nAGENT_CPU_QUOTA_PCT=300\n' % (self.state, self.tmp))
        os.chmod(self.conf, 0o600)
        self.panel_conf = os.path.join(self.tmp, "panel.conf")
        with open(self.panel_conf, "w") as f:
            f.write('PANEL_TOKEN_FILE=%s/token\nWATCHDOG_CONF=%s\nPANEL_UNITS="a.service bad;unit"\n'
                    'EARLYOOM_DEFAULT=%s/earlyoom\nWATCHDOG_CTL=/bin/false\nPANEL_ATOP_DIR=%s/no-atop\n' % (self.tmp, self.conf, self.tmp, self.tmp)
                    + self.PANEL_EXTRA)
        self.m = load_module({"CPU_WATCHDOG_PANEL_CONF": self.panel_conf})
        self.p = self.m.Panel()

    def sourced(self, key):
        out = subprocess.run(["bash", "-c", 'source "$1"; printf %s "${!2}"', "_", self.conf, key],
                             capture_output=True, text=True, check=True)
        return out.stdout


class ParsingTests(Fixture):
    def test_quote_roundtrip_matches_bash(self):
        for value in ['plain', 'with "quotes"', 'dollar $HOME `x`', 'back\\slash', "single 'q'", ""]:
            self.p.write_watchdog_conf({"TELEGRAM_CHAT_ID": self.m.bash_quote(value)})
            self.assertEqual(self.sourced("TELEGRAM_CHAT_ID"), value)
            self.assertEqual(self.p.watchdog_values()["TELEGRAM_CHAT_ID"], value)

    def test_last_assignment_wins_and_rewrite_collapses_duplicates(self):
        self.assertEqual(self.p.watchdog_values()["AGENT_CPU_QUOTA_PCT"], "300")
        self.assertEqual(self.p.watchdog_values()["WHITELIST_CMDLINE"], "a\\.b|c")
        self.p.save_config({"changes": {"AGENT_CPU_QUOTA_PCT": "400"}})
        text = read(self.conf)
        self.assertEqual(text.count("AGENT_CPU_QUOTA_PCT="), 1)
        self.assertEqual(self.sourced("AGENT_CPU_QUOTA_PCT"), "400")
        self.assertEqual(oct(os.stat(self.conf).st_mode & 0o777), "0o600")
        self.assertTrue(os.path.exists(self.conf + ".panel-bak"))

    def test_validation(self):
        bad = [{"CPU_THRESHOLD": "abc"}, {"AGG_CPU_THRESHOLD_PCT": "150"}, {"MODE": "off"},
               {"AGENT_CPU_QUOTA_PCT": str((os.cpu_count() or 1) * 100 + 1)},
               {"lower": "1"}, {"CPU_WATCHDOG_CONF": "/x"}, {"WHITELIST_COMM": "a\nb"},
               {"MEM_PREFER_REGEX": "("}]
        for changes in bad:
            with self.assertRaises(ValueError, msg=changes):
                self.p.save_config({"changes": changes})
        self.assertEqual(self.sourced("MODE"), "active")

    def test_secret_is_masked_and_empty_keeps_it(self):
        entry = [e for e in self.p.config()["entries"] if e["key"] == "TELEGRAM_BOT_TOKEN"][0]
        self.assertEqual(entry["value"], "set")
        with self.assertRaises(ValueError):
            self.p.save_config({"changes": {"TELEGRAM_BOT_TOKEN": ""}})
        self.assertEqual(self.sourced("TELEGRAM_BOT_TOKEN"), "Zq9SecretValue")
        self.assertNotIn("Zq9SecretValue", read(os.path.join(self.tmp, "log")))

    def test_unset_removes_key(self):
        self.p.save_config({"changes": {"CPU_THRESHOLD": None}})
        self.assertNotIn("CPU_THRESHOLD=", read(self.conf))

    def test_units_filtered(self):
        self.assertEqual(self.p.units(), ["a.service"])

    def test_user_units(self):
        user = __import__("pwd").getpwuid(os.getuid()).pw_name
        self.assertEqual(self.m.systemctl_cmd("x.service"), (["systemctl"], "x.service"))
        self.assertEqual(self.m.systemctl_cmd(user + "/x.service"),
                         (["systemctl", "--user", "-M", user + "@"], "x.service"))
        with self.assertRaises(ValueError):
            self.m.systemctl_cmd("no-such-user-zz/x.service")
        self.assertIsNone(self.m.UNIT_RE.match("a/b/c.service"))
        self.assertIsNone(self.m.UNIT_RE.match("../x.service"))


class OverrideTests(Fixture):
    def test_temporary_change_reverts(self):
        self.p.save_config({"changes": {"CPU_THRESHOLD": "95", "MODE": "observe"}, "duration_min": 5})
        self.assertEqual(self.sourced("CPU_THRESHOLD"), "95")
        items = self.p.load_overrides()
        self.assertEqual(len(items), 1)
        items[0]["expires"] = 0
        self.p.store_overrides(items)
        self.assertTrue(self.p.expire_overrides())
        self.assertEqual(self.sourced("CPU_THRESHOLD"), "80")
        self.assertEqual(self.sourced("MODE"), "active")
        self.assertEqual(self.p.load_overrides(), [])

    def test_revert_skips_keys_changed_meanwhile(self):
        self.p.save_config({"changes": {"CPU_THRESHOLD": "95", "MODE": "observe"}, "duration_min": 5})
        self.p.save_config({"changes": {"CPU_THRESHOLD": "70"}})
        oid = self.p.load_overrides()[0]["id"]
        self.p.override_action({"id": oid, "op": "revert"})
        self.assertEqual(self.sourced("CPU_THRESHOLD"), "70")
        self.assertEqual(self.sourced("MODE"), "active")

    def test_unset_key_is_removed_again(self):
        self.p.save_config({"changes": {"RELEASE_GRACE_MIN": "5"}, "duration_min": 5})
        oid = self.p.load_overrides()[0]["id"]
        self.p.override_action({"id": oid, "op": "revert"})
        self.assertNotIn("RELEASE_GRACE_MIN=", read(self.conf))

    def test_extend_and_keep(self):
        self.p.save_config({"changes": {"CPU_THRESHOLD": "95"}, "duration_min": 5})
        oid = self.p.load_overrides()[0]["id"]
        self.p.override_action({"id": oid, "op": "extend", "duration_min": 30})
        self.assertGreater(self.p.load_overrides()[0]["expires"], time.time() + 25 * 60)
        self.p.override_action({"id": oid, "op": "keep"})
        self.assertEqual(self.p.load_overrides(), [])
        self.assertEqual(self.sourced("CPU_THRESHOLD"), "95")

    def test_secret_cannot_be_temporary(self):
        with self.assertRaises(ValueError):
            self.p.save_config({"changes": {"TELEGRAM_BOT_TOKEN": "x"}, "duration_min": 5})


class CreditTests(Fixture):
    def model(self, vcpus, **keys):
        conf = dict(self.m.PANEL_DEFAULTS, PANEL_CREDIT_PROVIDER="hostinger", **keys)
        resolved = self.m.resolve_credit_conf(conf, vcpus)
        return self.m.CreditModel(resolved["params"], os.path.join(self.tmp, "credits.json"))

    def test_hostinger_documented_numbers(self):
        k1, k8 = self.model(1), self.model(8)
        self.assertAlmostEqual(k1.cap, 4320)
        self.assertAlmostEqual(k8.cap, 34560)
        k1.balance = 1000
        for pct, delta in ((10, 30), (60, 0), (100, -24)):
            before = k1.balance
            k1.step(pct / 100 * 60, 60)
            self.assertAlmostEqual(k1.balance - before, delta)

    def test_full_balance_lasts_three_hours_at_full_load(self):
        k8 = self.model(8)
        for _ in range(3 * 60 - 1):
            k8.step(8 * 60, 60)
        self.assertFalse(k8.throttled)
        k8.step(8 * 60, 60)
        self.assertTrue(k8.throttled)
        self.assertEqual(k8.balance, 0)

    def test_no_earning_while_pressing_the_cap(self):
        k8 = self.model(8)
        k8.balance, k8.throttled = 0, True
        k8.step(k8.limit * 600, 600)
        self.assertEqual(k8.balance, 0)
        self.assertTrue(k8.throttled)

    def test_earning_below_the_cap_lifts_at_recover_threshold(self):
        k8 = self.model(8)
        k8.balance, k8.throttled = 0, True
        k8.step(0, 600)
        self.assertAlmostEqual(k8.balance, 4.8 * 600)
        self.assertTrue(k8.throttled)
        while k8.throttled:
            k8.step(0, 600)
        self.assertGreaterEqual(k8.balance, 0.2 * k8.cap)

    def test_live_updates_save_and_resume_after_restart(self):
        k = self.model(8)
        k.update(1000.0, 1000.0)
        k.update(1000.0 + 8 * 600, 1600.0)
        expected = k.cap - (8 - 4.8) * 600
        self.assertAlmostEqual(k.balance, expected)
        k.save()
        k2 = self.model(8)
        self.assertTrue(k2.load())
        self.assertAlmostEqual(k2.balance, round(expected, 1), places=0)
        k2.update(1000.0 + 8 * 600, 2200.0)
        self.assertAlmostEqual(k2.balance, min(k2.cap, round(expected, 1) + 4.8 * 600), places=0)

    def test_backfill_replays_atop_then_pending_live_steps(self):
        bindir = os.path.join(self.tmp, "bin")
        atop = os.path.join(self.tmp, "atop")
        os.makedirs(bindir)
        os.makedirs(atop)
        day = time.strftime("%Y%m%d")
        open(os.path.join(atop, "atop_" + day), "w").close()
        now = time.localtime()
        base = time.mktime(time.strptime(day, "%Y%m%d"))
        lines = ["00:00:00  cpu  %usr %nice %sys %irq %softirq  %steal %guest  %wait %idle  _cpu_"]
        t = base
        while t + 600 < time.mktime(now):
            t += 600
            lines.append("%s  all   700     0  100    0        0      0      0      0     0" % time.strftime("%H:%M:%S", time.localtime(t)))
            lines.append("            0    90     0   10    0        0       0      0      0     0")
        with open(os.path.join(bindir, "atopsar"), "w") as f:
            f.write("#!/bin/sh\ncat <<'X'\n%s\nX\n" % "\n".join(lines))
        os.chmod(os.path.join(bindir, "atopsar"), 0o755)
        os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
        samples = self.m.atop_samples(atop, 48)
        if not samples:
            self.skipTest("too early in the day for a sample")
        self.assertTrue(all(abs(c - 8.0) < 1e-9 and dt == 600 and st == 0 for _t, dt, c, st in samples))
        k = self.model(8)
        k.backfilling = True
        k.pending = [(0.0, 600.0)]
        k.backfill(samples, "test")
        drained = max(0.0, k.cap - 3.2 * 600 * len(samples))
        self.assertLessEqual(k.balance, k.cap)
        if drained > 0:
            self.assertAlmostEqual(k.balance, min(k.cap, drained + 4.8 * 600))
        self.assertFalse(k.backfilling)


class HistoryTests(Fixture):
    def test_downsample_averages_into_buckets(self):
        pts = [{"t": t, "busy": float(t % 2), "agents": None} for t in range(1000, 2200)]
        out = self.m.downsample(pts, 1000, bins=100)
        self.assertLessEqual(len(out), 101)
        self.assertTrue(all(abs(p["busy"] - 0.5) < 0.1 for p in out[:-1]))
        self.assertNotIn("agents", out[0])
        self.assertEqual(self.m.downsample(pts, 2150, bins=100), pts[-50:])

    def test_minute_history_flushes_persists_and_seeds(self):
        path = os.path.join(self.tmp, "hist.json")
        h = self.m.MinuteHistory(path, 1)
        for t in range(6000, 6180, 3):
            h.add({"t": t, "busy": 10.0 if t < 6060 else 30.0})
        snap = h.snapshot()
        self.assertEqual([p["t"] for p in snap], [6000, 6060])
        self.assertEqual([p["busy"] for p in snap], [10.0, 30.0])
        h.seed([{"t": 5400, "busy": 50.0}, {"t": 6000, "busy": 99.0}])
        self.assertEqual([p["t"] for p in h.snapshot()], [5400, 6000, 6060])
        h2 = self.m.MinuteHistory(path, 1)
        self.assertTrue(h2.load())
        self.assertEqual(len(h2.snapshot()), 3)

    def test_history_range_uses_minutes_beyond_raw_window(self):
        now = time.time()
        self.p.sampler.minutes.seed([{"t": int(now - 7200 + 60 * i), "busy": 40.0} for i in range(100)])
        with self.p.sampler.lock:
            self.p.sampler.history.clear()
            for i in range(10):
                self.p.sampler.history.append({"t": int(now - 30 + 3 * i), "busy": 80.0})
        long = self.p.history(3 * 3600)
        self.assertEqual(long[0]["busy"], 40.0)
        self.assertEqual(long[-1]["busy"], 80.0)
        self.assertTrue(all(p["busy"] == 80.0 for p in self.p.history(300)))


class SwapTests(Fixture):
    def setUp(self):
        super().setUp()
        self.fake = os.path.join(self.tmp, "proc")
        os.makedirs(os.path.join(self.fake, "sys", "vm"))
        with open(os.path.join(self.fake, "swaps"), "w") as f:
            f.write("Filename\tType\tSize\tUsed\tPriority\n/swapfile file 2097148 2097148 -2\n"
                    "/swapfile2 file 2097148 1048576 -3\n/dev/sdb2 partition 1048572 0 -4\n")
        self.mounts("ext4")
        with open(os.path.join(self.fake, "sys", "vm", "swappiness"), "w") as f:
            f.write("10\n")
        self.m.PROC = self.fake

    def tearDown(self):
        self.m.PROC = "/proc"

    def mounts(self, fstype):
        with open(os.path.join(self.fake, "mounts"), "w") as f:
            f.write("/dev/sda1 / %s rw 0 0\ntmpfs /run tmpfs rw 0 0\n" % fstype)

    def test_status_parses_proc_swaps(self):
        st = self.p.swap_status()
        self.assertEqual([(d["path"], d["size_mb"], d["used_mb"]) for d in st["devices"]],
                         [("/swapfile", 2047, 2047), ("/swapfile2", 2047, 1024), ("/dev/sdb2", 1023, 0)])
        self.assertEqual((st["fstype"], st["swappiness"]), ("ext4", 10))

    def test_fstab_edits(self):
        text = "UUID=x / ext4 defaults 0 1\n/swapfile none swap sw 0 0\n# /swapfile9 none swap sw 0 0\n"
        added = self.m.fstab_add_swap(text, "/swapfile3")
        self.assertTrue(added.endswith("/swapfile3 none swap sw 0 0\n"))
        self.assertEqual(self.m.fstab_add_swap(added, "/swapfile3"), added)
        removed = self.m.fstab_remove_swap(added, "/swapfile")
        self.assertNotIn("\n/swapfile none", "\n" + removed)
        self.assertIn("UUID=x", removed)
        self.assertIn("# /swapfile9", removed)

    def test_add_validation(self):
        for size in (0, 65, "x"):
            with self.assertRaises(ValueError):
                self.p.swap_add({"size_gb": size})
        self.mounts("btrfs")
        with self.assertRaises(ValueError) as ctx:
            self.p.swap_add({"size_gb": 1})
        self.assertIn("btrfs", str(ctx.exception))
        self.p.swap_status = lambda: {"fstype": "ext4", "disk_free_gb": 15.0, "disk_total_gb": 100.0}
        with self.assertRaises(ValueError) as ctx:
            self.p.swap_add({"size_gb": 6})
        self.assertIn("free on disk", str(ctx.exception))

    def test_remove_only_managed_active_swapfiles(self):
        for path in ("/swapfile5", "/dev/sdb2", "/etc/passwd"):
            with self.assertRaises(ValueError):
                self.p.swap_remove({"path": path})

    def test_swappiness_bounds(self):
        for v in (-1, 201, "x"):
            with self.assertRaises(ValueError):
                self.p.set_swappiness({"value": v})


class ProviderTests(Fixture):
    def resolve(self, nproc=8, **keys):
        return self.m.resolve_credit_conf(dict(self.m.PANEL_DEFAULTS, **keys), nproc)

    def test_default_is_disabled(self):
        r = self.resolve()
        self.assertEqual((r["provider"], r["enabled"], r["error"]), ("none", False, None))

    def test_hostinger_preset(self):
        p = self.resolve(PANEL_CREDIT_PROVIDER="hostinger")["params"]
        self.assertEqual((p["vcpus"], p["baseline_pct"], p["throttle_pct"], p["cap_mode"], p["cap_hours"],
                          p["recover_pct"], p["earn_while_throttled"]), (8, 60, 30, "burst", 3, 20, False))
        self.assertEqual(self.resolve(1, PANEL_CREDIT_PROVIDER="hostinger")["params"]["throttle_pct"], 40)

    def test_aws_t3_requires_baseline_and_throttles_to_it(self):
        r = self.resolve(2, PANEL_CREDIT_PROVIDER="aws-t3")
        self.assertFalse(r["enabled"])
        self.assertIn("PANEL_CREDIT_BASELINE_PCT", r["error"])
        r = self.resolve(2, PANEL_CREDIT_PROVIDER="aws-t3", PANEL_CREDIT_BASELINE_PCT="20")
        p = r["params"]
        self.assertEqual((p["throttle_pct"], p["cap_mode"], p["cap_hours"], p["recover_pct"]), (20, "accrual", 24, 0))
        c = self.m.CreditModel(p, os.path.join(self.tmp, "c.json"), r["label"])
        self.assertAlmostEqual(c.cap, 576 * 60)
        c.balance, c.throttled = 0, True
        c.step(c.limit * 0.95 * 60, 60)
        self.assertGreater(c.balance, 0)
        self.assertFalse(c.throttled)

    def test_explicit_keys_override_preset(self):
        p = self.resolve(PANEL_CREDIT_PROVIDER="hostinger", PANEL_CREDIT_BASELINE_PCT="50",
                         PANEL_CREDIT_CAP_HOURS="2.5", PANEL_CREDIT_THROTTLE_PCT="45",
                         PANEL_CREDIT_EARN_WHILE_THROTTLED="1")["params"]
        self.assertEqual((p["baseline_pct"], p["cap_hours"], p["throttle_pct"], p["recover_pct"],
                          p["earn_while_throttled"]), (50, 2.5, 45, 20, True))
        p = self.resolve(PANEL_CREDIT_PROVIDER="aws-t3", PANEL_CREDIT_BASELINE_PCT="40",
                         PANEL_CREDIT_CAP_MODE="burst")["params"]
        self.assertEqual(p["cap_mode"], "burst")

    def test_legacy_model_flag_and_burst_hours(self):
        r = self.resolve(PANEL_CREDIT_MODEL="1", PANEL_CREDIT_BASELINE_PCT="50",
                         PANEL_CREDIT_BURST_HOURS="2.5", PANEL_CREDIT_THROTTLE_PCT="45")
        self.assertEqual((r["provider"], r["enabled"]), ("hostinger", True))
        self.assertEqual((r["params"]["cap_hours"], r["params"]["cap_mode"]), (2.5, "burst"))
        self.assertEqual(self.resolve(PANEL_CREDIT_MODEL="0")["provider"], "none")
        self.assertEqual(self.resolve(PANEL_CREDIT_MODEL="1", PANEL_CREDIT_PROVIDER="none")["provider"], "none")

    def test_custom_needs_explicit_values(self):
        r = self.resolve(PANEL_CREDIT_PROVIDER="custom", PANEL_CREDIT_BASELINE_PCT="25")
        self.assertFalse(r["enabled"])
        r = self.resolve(PANEL_CREDIT_PROVIDER="custom", PANEL_CREDIT_BASELINE_PCT="25",
                         PANEL_CREDIT_THROTTLE_PCT="10", PANEL_CREDIT_CAP_HOURS="12", PANEL_CREDIT_CAP_MODE="accrual")
        self.assertTrue(r["enabled"])
        self.assertEqual(r["params"]["cap_mode"], "accrual")

    def test_invalid_values_disable_with_error(self):
        for keys in ({"PANEL_CREDIT_PROVIDER": "acme"},
                     {"PANEL_CREDIT_PROVIDER": "hostinger", "PANEL_CREDIT_BASELINE_PCT": "x"},
                     {"PANEL_CREDIT_PROVIDER": "hostinger", "PANEL_CREDIT_CAP_MODE": "weird"}):
            r = self.resolve(**keys)
            self.assertFalse(r["enabled"])
            self.assertTrue(r["error"])


class NoProviderTests(Fixture):
    PANEL_EXTRA = ""

    def test_status_hides_credits(self):
        st = self.p.status()
        self.assertFalse(st["credits_enabled"])
        self.assertIsNone(st["credits"])
        self.assertEqual(st["credit_provider"]["provider"], "none")
        self.assertEqual(self.p.credit_history(3600), [])

    def test_governor_refused_and_loop_idle(self):
        with self.assertRaises(ValueError):
            self.p.save_config({"changes": {"CREDIT_GOVERNOR": "1"}})
        with open(self.conf, "a") as f:
            f.write("CREDIT_GOVERNOR=1\n")
        quotas = []
        self.p.set_quota = lambda pct, quiet=False: quotas.append(pct)
        with self.p.sampler.lock:
            for i in range(20):
                self.p.sampler.history.append({"t": i, "busy": 90.0, "agents": 300.0})
        self.p.governor_tick()
        self.assertEqual(quotas, [])
        self.assertFalse(self.p.gov["enabled"])
        self.assertFalse(os.path.exists(os.path.join(self.state, "credit-governor")))

    def test_save_credit_config_enables_and_persists(self):
        with self.assertRaises(ValueError):
            self.p.save_credit_config({"values": {"PANEL_CREDIT_PROVIDER": "custom"}})
        with self.assertRaises(ValueError):
            self.p.save_credit_config({"values": {"PANEL_CREDIT_PROVIDER": "hostinger",
                                                  "PANEL_CREDIT_BASELINE_PCT": "5$(x)"}})
        self.assertIsNone(self.p.sampler.credits)
        with open(self.panel_conf, "a") as f:
            f.write("PANEL_CREDIT_BURST_HOURS=9\n")
        self.p.save_credit_config({"values": {"PANEL_CREDIT_PROVIDER": "hostinger", "PANEL_CREDIT_BASELINE_PCT": "50",
                                              "PANEL_CREDIT_CAP_HOURS": "2.5"}})
        self.assertIsNotNone(self.p.sampler.credits)
        self.assertTrue(self.p.status()["credits_enabled"])
        text = open(self.panel_conf).read()
        self.assertIn("PANEL_CREDIT_PROVIDER=hostinger", text)
        self.assertIn("PANEL_CREDIT_CAP_HOURS=2.5", text)
        self.assertNotIn("BURST_HOURS", text)
        cfg = self.p.credit_config()
        self.assertEqual(cfg["values"]["PANEL_CREDIT_BASELINE_PCT"], "50")
        self.assertEqual(cfg["presets"]["hostinger"]["throttle_pct"], "30 (40 on 1 vCPU)")

    def test_disabling_credits_refused_while_governor_on(self):
        self.p.save_credit_config({"values": {"PANEL_CREDIT_PROVIDER": "hostinger"}})
        self.p.save_config({"changes": {"CREDIT_GOVERNOR": "1"}})
        with self.assertRaises(ValueError):
            self.p.save_credit_config({"values": {"PANEL_CREDIT_PROVIDER": ""}})
        self.p.save_config({"changes": {"CREDIT_GOVERNOR": "0"}})
        self.p.save_credit_config({"values": {"PANEL_CREDIT_PROVIDER": ""}})
        self.assertIsNone(self.p.sampler.credits)


class GovernorTests(Fixture):
    def setUp(self):
        super().setUp()
        c = self.p.sampler.credits
        c.backfilling = False
        c.n, c.base, c.limit = 8.0, 4.8, 2.4
        c.cap = 3 * 3600 * 3.2
        self.quotas = []
        self.p.set_quota = lambda pct, quiet=False: self.quotas.append(pct)

    def decide(self, balance_pct, others, throttled=False, **vals):
        summary = {"balance_s": self.p.sampler.credits.cap * balance_pct / 100, "throttled_est": throttled}
        return self.p.governor_decide(vals, summary, others + 2.0, 2.0)

    def test_full_balance_leaves_agents_uncapped(self):
        allowed, _o, quota = self.decide(100, 1.0)
        self.assertAlmostEqual(allowed, 8.0)
        self.assertIsNone(quota)

    def test_low_balance_spreads_it_over_the_horizon(self):
        allowed, others, quota = self.decide(20, 1.0)
        self.assertAlmostEqual(allowed, 4.8 + 6912 / 7200.0)
        self.assertEqual(quota, 450)
        allowed, _o, quota = self.decide(20, 1.0, CREDIT_HORIZON_MIN="10")
        self.assertAlmostEqual(allowed, 8.0)
        self.assertIsNone(quota)

    def test_throttled_uses_provider_cap_and_floor(self):
        allowed, _o, quota = self.decide(0, 2.0, throttled=True, CREDIT_GOV_MIN_QUOTA_PCT="150")
        self.assertAlmostEqual(allowed, 2.4)
        self.assertEqual(quota, 150)

    def fill_history(self, busy_pct, agents_pct):
        with self.p.sampler.lock:
            for i in range(20):
                self.p.sampler.history.append({"t": i, "busy": busy_pct, "agents": agents_pct})

    def test_tick_publishes_file_applies_quota_and_releases_when_disabled(self):
        self.p.save_config({"changes": {"CREDIT_GOVERNOR": "1"}})
        self.p.sampler.credits.balance = self.p.sampler.credits.cap * 0.2
        self.fill_history(50.0, 300.0)
        self.p.governor_tick()
        self.assertEqual(self.quotas, ["450"])
        epoch, allowed, _bal, quota = read(os.path.join(self.state, "credit-governor")).split()
        self.assertEqual((allowed, quota), ("576", "450"))
        with self.assertRaises(ValueError):
            self.p.action({"action": "quota", "value": "500"})
        self.p.governor_tick()
        self.assertEqual(self.quotas, ["450"], "unchanged quota is not reapplied")
        self.p.save_config({"changes": {"CREDIT_GOVERNOR": "0"}})
        self.p.governor_tick()
        self.assertEqual(self.quotas, ["450", ""])
        self.assertFalse(os.path.exists(os.path.join(self.state, "credit-governor")))

    def test_observe_mode_computes_without_applying(self):
        self.p.save_config({"changes": {"CREDIT_GOVERNOR": "1", "MODE": "observe"}})
        self.fill_history(50.0, 300.0)
        self.p.governor_tick()
        self.assertEqual(self.quotas, [])
        self.assertTrue(self.p.gov["observe"])
        self.assertFalse(os.path.exists(os.path.join(self.state, "credit-governor")))


class TmuxTests(Fixture):
    def setUp(self):
        super().setUp()
        self.ctl = os.path.join(self.tmp, "ctl")
        with open(self.ctl, "w") as f:
            f.write('#!/bin/sh\necho "$TMUX_USER $*" >>"%s/ctl.log"\n' % self.tmp)
        os.chmod(self.ctl, 0o755)
        self.p.conf["WATCHDOG_CTL"] = self.ctl
        self.user = __import__("pwd").getpwuid(os.getuid()).pw_name

    def test_free_passes_user_and_reverts_with_it(self):
        self.p.action({"action": "free", "user": self.user, "target": "work:2", "duration_min": 5})
        oid = self.p.load_overrides()[0]["id"]
        self.p.override_action({"id": oid, "op": "revert"})
        self.assertEqual(read(os.path.join(self.tmp, "ctl.log")).splitlines(),
                         ["%s free work:2" % self.user, "%s free work:2 --undo" % self.user])

    def test_free_rejects_bad_input(self):
        for body in ({"target": "a;b", "user": self.user}, {"target": "work", "user": "no-such-user-zz"}):
            with self.assertRaises(ValueError):
                self.p.action(dict(body, action="free"))

    @unittest.skipUnless(shutil.which("tmux"), "tmux not installed")
    def test_lists_sessions_windows_and_panes(self):
        tmpdir = os.path.join(self.tmp, "tmux")
        os.makedirs(tmpdir)
        self.m.TMUX_TMPDIR = tmpdir
        env = dict(os.environ, TMUX_TMPDIR=tmpdir)
        env.pop("TMUX", None)
        subprocess.run(["tmux", "-f", "/dev/null", "new-session", "-d", "-s", "work", "-n", "editor", "sleep 60"], env=env, check=True)
        try:
            subprocess.run(["tmux", "split-window", "-t", "work:0", "sleep 60"], env=env, check=True)
            sessions = self.p.tmux_targets()
            self.assertEqual([(s["user"], s["target"]) for s in sessions], [(self.user, "work")])
            win = sessions[0]["windows"][0]
            self.assertEqual((win["target"], win["name"]), ("work:0", "editor"))
            self.assertEqual([p["target"] for p in win["panes"]], ["work:0.0", "work:0.1"])
        finally:
            subprocess.run(["tmux", "kill-server"], env=env)


class HttpTests(Fixture):
    def setUp(self):
        super().setUp()
        self.m.Handler.panel = self.p
        self.p.conf["PANEL_PORT"] = "0"
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), self.m.Handler)
        port = self.httpd.server_address[1]
        self.p.conf["PANEL_PORT"] = str(port)
        self.base = "http://127.0.0.1:%d" % port
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def req(self, path, token=None, body=None, host=None, ctype="application/json"):
        r = urllib.request.Request(self.base + path, data=json.dumps(body).encode() if body is not None else None)
        if token:
            r.add_header("Authorization", "Bearer " + token)
        if body is not None:
            r.add_header("Content-Type", ctype)
        if host:
            r.add_header("Host", host)
        try:
            with urllib.request.urlopen(r) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def test_auth_and_host(self):
        self.assertEqual(self.req("/api/config")[0], 401)
        self.assertEqual(self.req("/api/config", token="wrong")[0], 401)
        self.assertEqual(self.req("/api/config", token=self.p.token, host="evil.example:80")[0], 421)
        code, data = self.req("/api/config", token=self.p.token)
        self.assertEqual(code, 200)
        self.assertNotIn(b"Zq9SecretValue", data)
        self.assertEqual(oct(os.stat(os.path.join(self.tmp, "token")).st_mode & 0o777), "0o600")

    def test_post_requires_json_and_reports_errors(self):
        self.assertEqual(self.req("/api/config", token=self.p.token, body={}, ctype="text/plain")[0], 415)
        code, data = self.req("/api/config", token=self.p.token, body={"changes": {"MODE": "x"}})
        self.assertEqual(code, 400)
        self.assertIn(b"MODE", data)
        self.assertEqual(self.req("/api/action", token=self.p.token, body={"action": "unit", "unit": "x", "op": "stop"})[0], 400)

    def test_kill_checks_identity(self):
        proc = subprocess.Popen(["sleep", "30"])
        try:
            code, _ = self.req("/api/action", token=self.p.token,
                               body={"action": "kill", "pid": proc.pid, "start": 1, "signal": "TERM"})
            self.assertEqual(code, 400)
            raw = read("/proc/%d/stat" % proc.pid)
            start = int(raw[raw.rfind(")") + 2:].split()[19])
            code, _ = self.req("/api/action", token=self.p.token,
                               body={"action": "kill", "pid": proc.pid, "start": start, "signal": "TERM"})
            self.assertEqual(code, 200)
            self.assertEqual(proc.wait(5), -15)
        finally:
            proc.kill()

    def test_static_files(self):
        code, data = self.req("/")
        self.assertEqual(code, 200)
        self.assertIn(b"app.js", data)
        self.assertEqual(self.req("/../cpu-watchdog-panel.py")[0], 404)


if __name__ == "__main__":
    unittest.main()
