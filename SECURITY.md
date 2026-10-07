# Security

## Reporting a vulnerability

Do not open a public issue. Use **GitHub's private vulnerability reporting**
(*Security* → *Report a vulnerability*) in this repository. Include the version
(commit), distribution/systemd version and reproduction steps. Initial responses
are provided on a best-effort basis; this is a volunteer-maintained project.

Supported versions: only the latest `main`.

## Threat model

The watchdog runs as **root** every minute and can throttle or send
`SIGTERM`/`SIGKILL` to any process outside its whitelists. Therefore:

- **`/etc/cpu-watchdog.conf` is code executed as root** (loaded with `source`).
  It must be owned by `root:root` with mode `600`. `install.sh` creates it with
  mode `600` and reapplies that mode on reinstalls when it is customized.
  Anyone who can write to this file has root access.
- **Other processes are untrusted input.** Any local user can control `comm`
  and command lines. The script never interprets them as code. Command lines
  are only matched against `WHITELIST_CMDLINE`, grouped by hash (Layer 3),
  and sanitized before being logged.
- **Local users can trigger actions against their own processes** (for example,
  by increasing CPU usage to trigger throttling), or try to hide in a whitelist
  by mimicking a service's `comm`. Whitelists based on `comm` are a convenience,
  not a security boundary.
- **Layers 3 and 4 terminate processes.** A false positive can stop a legitimate
  service. Review `WHITELIST_COMM`, `MEM_WHITELIST_COMM`, `MEM_PREFER_REGEX` and
  earlyoom's `--avoid` for your host before installing.

## Secrets

- **Telegram**: the token and chat_id are stored only in `/etc/cpu-watchdog.conf`.
  They are passed to `curl` through stdin (`-K -`), rather than argv, so they
  do not appear in `ps`. Messages never include processes' command lines.
- **Logs**: `/var/log/cpu-watchdog.log` and the journal receive **sanitized**
  command lines for affected processes (see "Logs and secrets" in the README).
  Sanitization is heuristic: positional secrets or unknown formats without
  suggestive names may still appear. Treat logs as sensitive:
  - The script uses `umask 077`, so new logs have mode `600`.
    **Existing logs retain their previous permissions**. Run
    `sudo chmod 600 /var/log/cpu-watchdog.log` and `chmod 700` on `STATE_DIR`,
    which stores command-line hashes.
  - Logs and journal entries from versions before sanitization contain raw
    command lines. Review and rotate them (`journalctl --rotate` +
    `--vacuum-time`) if processes on the host received secrets through argv.
  - The journal is readable by the `adm`/`systemd-journal` groups.
  - earlyoom lines forwarded by Layer 4c are not sanitized (currently earlyoom
    only reports PID, UID and process name).
- **Environment**: the `CPU_WATCHDOG_CONF`, `CPU_WATCHDOG_LOCK` and
  `CPU_WATCHDOG_PROC_DIR` overrides exist only for tests and are ignored when
  the script runs as root. The configuration cannot override the lock or `/proc`.
- **Telegram (invalid credentials)**: a token or chat_id containing a control
  character disables sending and is logged, preventing curl configuration
  directive injection.
- **Installation**: `install.sh` never prints the configuration in plain text.
  Its diff redacts variables matching `*TOKEN*`, `*SECRET*`, `*PASSWORD*`,
  `*CHAT_ID*` and `*API_KEY*`.
