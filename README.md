# vps-watchdog

A configurable CPU and memory watchdog for Linux VPS hosts with systemd.
It detects sustained resource pressure from individual processes or groups of
processes, applies CPU throttling, and terminates eligible processes under
configured fork bomb or memory conditions.

Use it to manage resource contention on hosts running background jobs, worker
processes, build and test workloads, or interactive tools. CPU limits are applied
with `cpulimit` and released automatically when usage drops. Memory protection
combines periodic checks with `earlyoom` for sudden pressure, with configurable
exemptions and process selection priorities.

The watchdog runs once a minute through a systemd timer. Its policy applies across
the host: review thresholds, whitelists and memory priorities for your workload
before enabling it. The supplied configuration is a starting point oriented
toward development workloads; see [Configuring for your workload](#configuring-for-your-workload).

> Previously named **cpu-watchdog**. For compatibility with existing
> installations, installed files, units and paths retain that name
> (`/etc/cpu-watchdog.conf`, `cpu-watchdog.timer`, ...).

## How it works

Four layers, all configurable in `/etc/cpu-watchdog.conf`:

- **Layer 1 — single process**: if a process sustains `CPU_THRESHOLD`% CPU
  (relative to one core) for `SUSTAIN_CHECKS` consecutive minutes, it is limited
  to `LIMIT_PERCENT`%.
- **Layer 2 — aggregate usage**: handles multiple moderately busy processes
  that together overload the host without any one crossing the Layer 1 threshold.
  It measures actual CPU usage between runs (deltas from `/proc/stat`, excluding
  idle, iowait and steal). If usage exceeds `AGG_CPU_THRESHOLD_PCT`% of total
  capacity (nproc × 100) for `AGG_SUSTAIN_CHECKS` consecutive minutes, it limits
  up to `AGG_MAX_THROTTLES` processes to `AGG_LIMIT_PERCENT`% each, starting with
  those that consumed the most CPU in the last minute. Only processes that used
  more than `AGG_LIMIT_PERCENT`% qualify; kernel threads and new processes with
  no previous sample are excluded. The first run, or a run after reboot, only
  records a sample.
- **Automatic release**: throttling is temporary. The watchdog measures the
  throttled process's actual usage (`utime+stime` from `/proc`, rather than the
  lifetime `%CPU` average from `ps`). If usage stays below `RELEASE_IDLE_PCT`%
  of the limit for `RELEASE_SUSTAIN_CHECKS` minutes, `cpulimit` is removed and
  the process is exempt from further throttling for `RELEASE_GRACE_MIN` minutes.
  `RELEASE_SUSTAIN_CHECKS=0` disables automatic release.
- **Layer 3 — fork bomb**: handles N processes with the **same full command
  line**, each already above `CPU_THRESHOLD` (for example, a
  `while :; do :; done` loop launched several times with `&`). Throttling does
  not scale in this case: with enough processes, some always run at full speed.
  After `FORKBOMB_SUSTAIN_CHECKS` consecutive runs with `FORKBOMB_MIN_COUNT` or
  more identical copies, all are sent `SIGTERM`. Known risk: legitimate worker
  pools (php-fpm, gunicorn) under sustained heavy load could match this pattern.
  If a false positive occurs, add the command name to `WHITELIST_COMM`.
- **Layer 4 — memory**: the kernel intervenes only when memory is exhausted
  and may choose the wrong victims. Protection has two parts:
  - **earlyoom** (daemon, reacts in ~1s, configured in `config/earlyoom.default`):
    sends SIGTERM when available RAM <= 6% **and** free swap <= 10%, and SIGKILL
    at 3%/5%. Its `--prefer` and `--avoid` patterns define which process names
    to favor or protect when selecting a victim. The supplied policy favors
    selected application runtimes and browser processes, while protecting
    essential services. Configure these patterns for your host. This provides
    protection against sudden spikes.
  - **The watchdog** (once a minute) handles slower problems:
    - 4a: a process with RSS >= `MEM_PROC_KILL_MB` for `MEM_PROC_SUSTAIN_CHECKS`
      minutes receives SIGTERM, then SIGKILL on the next run if it ignores it.
    - 4b: if available RAM <= `MEM_AVAIL_KILL_PCT`% and free swap <=
      `MEM_SWAP_FREE_KILL_PCT`% for `MEM_SYS_SUSTAIN_CHECKS` minutes, the largest
      eligible process receives SIGTERM, one at a time. Selection prioritizes
      full command lines matching `MEM_PREFER_FIRST_REGEX`, then process names
      matching `MEM_PREFER_REGEX`, then other eligible processes. Within each
      priority group, the largest RSS is selected first. Before that, warnings
      with a cooldown are sent when usage crosses
      `MEM_AVAIL_WARN_PCT` / `MEM_SWAP_USED_WARN_PCT`, listing the largest groups
      by name (for example, `12×worker=3600MB`). On hosts without swap, the
      criterion depends only on RAM.
    - 4c: reports processes killed by earlyoom.

  The memory layer has its own whitelist, `MEM_WHITELIST_COMM`. A process
  exempt from CPU throttling **can still** be terminated for memory usage
  unless it is also exempt from the memory layer.

Processes in `WHITELIST_COMM` (sshd, systemd, cron, etc.) are never affected by
CPU layers (1–3). Names in both whitelists use the kernel's `comm`, truncated to
15 characters (`systemd-journald` -> `systemd-journal`). `WHITELIST_CMDLINE`
(an ERE regex against the full command line) applies to all layers.

`cpulimit` is started with `systemd-run --scope`. The watchdog service is oneshot
with `KillMode=control-group`; a background `cpulimit` in the service's cgroup
would be killed by systemd as soon as the script exited, making throttling last
only seconds and requiring it to be reapplied on every run.

Processes are identified by `pid:starttime` (read from `/proc/<pid>/stat`) to
avoid confusing a process with a later process that reuses the same PID.

## Requirements and support

Target: **Linux with systemd**, running as root. Tested on Ubuntu 24.04
(systemd 255, kernel 6.8); CI runs on Ubuntu 22.04, Ubuntu 24.04 and an
`archlinux:latest` container. The Arch job checks lint and tests, without
starting systemd services inside the container.

| Dependency | Purpose | Required? |
|---|---|---|
| bash >= 4.4 | `mapfile -d`, associative arrays | yes |
| systemd (`systemctl`, `systemd-run`) | timer, separate `cpulimit` scope | yes |
| procps (`ps`), util-linux (`flock`, `logger`), coreutils, GNU sed, awk | collection and logging | yes |
| diffutils (`cmp`, `diff`) | idempotent installation and configuration comparison | yes — installer |
| `/proc/meminfo`, `/proc/<pid>/{stat,cmdline}` | measurements | yes |
| `cpulimit` | throttling (Layers 1–2) | no — without it, the watchdog only alerts |
| `earlyoom` | sudden memory spikes | no — recommended |
| `curl` | Telegram alerts | no |
| `/proc/pressure/memory` (PSI, kernel >= 4.20) | alert context | no — displays `?` |
| `tailscaled` | OOM protection drop-in | no — applied only if present |

- `install.sh` supports Debian/Ubuntu (`apt-get`) and Arch Linux (`pacman`).
  On Arch, it installs `earlyoom` from the official repositories and continues
  without `cpulimit` if missing; see the AUR instructions below. On other
  distributions, install both dependencies before running the script
  (it skips existing ones).
- GNU sed is required (`sed -z` and the `I` flag for sanitization).
  BusyBox/Alpine is unsupported.
- Containers without systemd (standard Docker, WSL without systemd) are unsupported.

## Installation / updates

```bash
sudo ./install.sh
```

On **Debian/Ubuntu**, the installer installs missing `cpulimit` and `earlyoom`
packages through apt.

On **Arch Linux**, keep the system up to date with `sudo pacman -Syu` before
running the installer. Ensure `diffutils` is installed
(`sudo pacman -S --needed diffutils`) for file and configuration comparisons.
The installer installs missing `earlyoom` with
`pacman -S --needed --noconfirm earlyoom`, using the current package database.
`cpulimit` is available from the AUR: install it as your regular user with an
AUR helper (for example, `yay -S cpulimit`) if you want CPU throttling, then
run `sudo ./install.sh`. The installer never builds AUR packages as root;
without `cpulimit`, Layers 1–2 only log and alert and Layers 3–4 remain active.

The default whitelists include `cron`/`crond` and protect both `php-fpm8.3`
and `php-fpm` from watchdog memory kills. For an existing custom configuration,
add `crond` to `WHITELIST_COMM` and `MEM_WHITELIST_COMM`, and `php-fpm` to
`MEM_WHITELIST_COMM` yourself; rerunning the installer preserves that file.

The installer is idempotent. Run it again whenever this repository changes:

- Copies `bin/cpu-watchdog.sh` and the units in `systemd/` only if content changed.
- Automatically runs `systemctl daemon-reload` and restarts the timer when needed.
- Installs `/etc/cpu-watchdog.conf` from `config/cpu-watchdog.conf.example`
  **only on the first installation**. If the file already exists and is customized
  (for example, Telegram credentials or adjusted thresholds), it is never
  overwritten. The installer only displays a diff against the repository template,
  with sensitive values redacted.
- Installs missing dependencies through apt on Debian/Ubuntu; on Arch,
  installs `earlyoom` through pacman and prints AUR instructions for `cpulimit`.
- **Overwrites** `/etc/default/earlyoom` with `config/earlyoom.default` and
  restarts earlyoom whenever content differs. Back up any customized earlyoom
  configuration before the first installation.

Older configurations remain valid: no new variable is required.

## Configuring for your workload

The detection logic uses resource measurements and configurable process matches;
it does not require a particular application or programming language. The
supplied policies include choices for development workloads, such as CPU
exemptions for interactive tools and memory priorities for test/build processes.
Review them rather than assuming they match your services.

| Setting | What to choose for your host |
|---|---|
| `CPU_THRESHOLD`, `AGG_CPU_THRESHOLD_PCT` and sustain checks | How much sustained CPU usage should trigger throttling |
| `WHITELIST_COMM` | Process names exempt from CPU layers (1–3) |
| `WHITELIST_CMDLINE` | Full command-line patterns exempt from all watchdog layers |
| `MEM_PROC_KILL_MB` and memory pressure thresholds | Acceptable process size and remaining host memory |
| `MEM_WHITELIST_COMM` | Process names the watchdog must never terminate for memory usage |
| `MEM_PREFER_FIRST_REGEX` | Command-line patterns for workloads to terminate first under host memory pressure |
| `MEM_PREFER_REGEX` | Process names to prioritize next under host memory pressure |
| earlyoom `--prefer` / `--avoid` | A separate victim selection policy for sudden memory pressure |

For example, a host running disposable batch jobs may prioritize those jobs for
termination while protecting its database and remote access. Another host may
need to protect long-running workers and allow them sustained CPU usage. Use
command-line patterns when a process name is shared by several applications.

The watchdog and earlyoom have separate policies: watchdog whitelists do not
configure earlyoom. Review both
[`config/cpu-watchdog.conf.example`](config/cpu-watchdog.conf.example) and
[`config/earlyoom.default`](config/earlyoom.default). See
[SECURITY.md](SECURITY.md) for configuration permissions and process selection risks.

## Optional features

- **Telegram alerts**: set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in
  `/etc/cpu-watchdog.conf`. Empty values mean local logging only. Token and
  chat_id are passed to `curl` through stdin, never argv. Messages include the
  process name, PID and action, never the command line.
- **earlyoom**: installed and configured by `install.sh`. To disable it, run
  `sudo systemctl disable --now earlyoom` after installation. Watchdog Layers
  4a/4b remain active; Layer 4c becomes inactive.
- **tailscaled OOM protection**: if `tailscaled.service` exists, the installer
  applies `OOMScoreAdjust=-900` through a drop-in and updates the running process
  with `choom`, without restarting tailscaled. It does nothing if Tailscale is absent.
- **Without `cpulimit`**: Layers 1–2 only log and alert
  (`ALERT (cpulimit missing)`); Layers 3–4 work normally.

## Logs and secrets

Affected processes' command lines are **sanitized** before being written to the
local log and journal, and are never sent to Telegram. The following become
`<redacted>`:

- Values of flags and variables with sensitive names (`--password x`, `--token=x`,
  `DB_PASSWORD=x`, `"password":"x"` in JSON), including values containing spaces.
- Passwords or tokens in URLs (`postgres://u:x@host`, `https://TOKEN@github.com`),
  query parameters and fragments (`?access_token=x`, `#access_token=x`), and Go
  DSNs (`u:x@tcp(host)`).
- Authentication headers (`Authorization: Bearer x`, `X-Api-Key: x`, `Cookie: x`),
  including embedded headers (`--header=X-Api-Key: x`).
- curl's `user:password` (`--user`, `-u`, `--proxy-user`, `-U`, with or without `=`).
- Short password flags for known programs: `mysql`/`mariadb -pPASSWORD`,
  `sshpass -p`, `redis-cli -a`, `docker`/`podman`/`helm ... login -p`.
- Known token formats (GitHub, GitLab, Slack, AWS, OpenAI/Anthropic, Google,
  JWT, Telegram bot).

Arguments containing spaces (`sh -c '...'`, processes rewriting their argv) are
split into words and processed with the same rules. Matching is byte-oriented
(`LC_ALL=C`), so invalid UTF-8 cannot bypass the rules. Control characters become
`?` to prevent forged log lines. Lines are truncated to 1024 bytes, and huge argv
lists stop being processed soon after the limit.

This is a heuristic that favors over-redaction (`--author x` is also removed).
It can still miss positional secrets or unknown formats without a suggestive
name, short flags for programs outside the list above, values starting with `-`
after sensitive flags (`--password -x`), and cookies with multiple pairs (only
the first is redacted). New files use `umask 077` (log `600`, state `700`);
existing logs retain their previous permissions. See [SECURITY.md](SECURITY.md).

## Installed files

| Item | Location |
|---|---|
| Script | `/usr/local/bin/cpu-watchdog.sh` |
| Management tool | `/usr/local/bin/cpu-watchdog-ctl` |
| Configuration | `/etc/cpu-watchdog.conf` |
| State (do not edit) | `/var/lib/cpu-watchdog/*.tsv` |
| Action log | `/var/log/cpu-watchdog.log` (and `journalctl -u cpu-watchdog`) |
| Units | `/etc/systemd/system/cpu-watchdog.{service,timer}` |
| Active throttles | `systemctl list-units 'cpu-watchdog-limit-*'` |
| earlyoom | `/etc/default/earlyoom` (and `journalctl -u earlyoom`) |
| tailscaled OOM protection | `/etc/systemd/system/tailscaled.service.d/oom.conf` |

## Operations

Use the management tool to inspect active throttles and take action without
memorizing file paths or systemd commands:

```bash
sudo cpu-watchdog-ctl            # interactive menu
sudo cpu-watchdog-ctl status     # active throttles + host snapshot
sudo cpu-watchdog-ctl log 100    # last 100 log lines
```

Stop an active throttle (releases the process and kills only its `cpulimit`):

```bash
sudo cpu-watchdog-ctl unthrottle <PID>   # target process PID, not the cpulimit PID
sudo cpu-watchdog-ctl unthrottle all     # release all throttles
```

This only removes the current throttle. If the process keeps consuming too much
CPU, it will be throttled again on a later run. For a permanent exemption, use
the whitelist:

```bash
sudo cpu-watchdog-ctl whitelist-cpu batch-worker    # exempt from CPU layers (1–3)
sudo cpu-watchdog-ctl whitelist-mem batch-worker    # exempt from memory layer (4)
sudo cpu-watchdog-ctl whitelist-cmdline 'my-job\.py' # for generic names such as python/node/php
```

No restart is needed after whitelist changes: the watchdog reads
`/etc/cpu-watchdog.conf` on every run (once a minute).

Equivalent manual commands (used by the management tool):

```bash
systemctl status cpu-watchdog.timer      # is it running?
tail -f /var/log/cpu-watchdog.log        # actions in real time
systemctl stop cpu-watchdog.timer        # pause
systemctl stop cpu-watchdog-limit-<PID>-<starttime>.scope   # release one throttle
# or: pkill -f "cpulimit -p <PID>"
```

## Rollback

**Restore an earlier version** (preserves the installed watchdog configuration):

```bash
git checkout <previous-commit-or-tag>
sudo ./install.sh
```

**Disable without uninstalling** (reversible with `enable --now`):

```bash
sudo systemctl disable --now cpu-watchdog.timer
sudo systemctl stop 'cpu-watchdog-limit-*.scope'   # release active throttles
```

**Uninstall**:

```bash
sudo systemctl disable --now cpu-watchdog.timer
sudo systemctl stop 'cpu-watchdog-limit-*.scope'
sudo rm /etc/systemd/system/cpu-watchdog.service /etc/systemd/system/cpu-watchdog.timer
sudo rm /usr/local/bin/cpu-watchdog.sh /usr/local/bin/cpu-watchdog-ctl
sudo rm -r /var/lib/cpu-watchdog /run/cpu-watchdog.lock
sudo cp /etc/cpu-watchdog.conf ~/cpu-watchdog.conf.bak && sudo rm /etc/cpu-watchdog.conf  # contains the token
sudo rm /etc/systemd/system/tailscaled.service.d/oom.conf   # if present
sudo systemctl daemon-reload
# earlyoom: disable it, remove the package, or restore your /etc/default/earlyoom
sudo systemctl disable --now earlyoom
```

The log `/var/log/cpu-watchdog.log` remains for auditing; delete it when no longer
needed. The live tailscaled OOM adjustment resets on its next restart.

## Development

English is the default language for documentation, code comments, user-facing
messages, commit messages, issues and pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
tests/lint.sh   # bash -n, shellcheck, systemd-analyze verify
tests/run.sh    # layer, sanitization, notification, configuration and installer tests
```

Tests require the runtime tools listed above, including `diffutils` for installer
tests. They run without root and without modifying the system. Installer tests
redirect file destinations to a temporary directory and simulate package and
service managers. Other tests execute the actual
script against harmless child processes, replacing `ps`, `cpulimit`,
`systemd-run`, `curl`, `logger`, `journalctl` and `systemctl` with stubs
(`tests/stubs/`). For this purpose, the script accepts three environment
overrides that systemd never sets and that are **ignored when running as root**:

| Variable | Default |
|---|---|
| `CPU_WATCHDOG_CONF` | `/etc/cpu-watchdog.conf` |
| `CPU_WATCHDOG_LOCK` | `/run/cpu-watchdog.lock` |
| `CPU_WATCHDOG_PROC_DIR` | `/proc` |

## Background

The project grew out of two incidents on a shared VPS: provider throttling after
sustained CPU usage, followed by an OOM event that stopped essential services
while memory-heavy workloads remained alive. CPU throttling and memory protection
were added to address those failures. Their thresholds and process selection
policies are configurable so they can be adapted to other hosts.

## License

[MIT](LICENSE).
