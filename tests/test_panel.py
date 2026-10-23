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
                    'EARLYOOM_DEFAULT=%s/earlyoom\nWATCHDOG_CTL=/bin/false\n' % (self.tmp, self.conf, self.tmp))
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
