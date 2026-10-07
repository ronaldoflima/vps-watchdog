# Contributing

Issues and pull requests are welcome. English is the project's default language:
use it for documentation, code comments, user-facing messages, commit messages,
issues and pull requests.

1. Behavior changes require tests: write a test in `tests/`, watch it fail,
   then implement the change. Tests run without root and without modifying the
   system (see "Development" in the README).
2. Before opening a pull request, run:

   ```bash
   tests/lint.sh   # bash -n, shellcheck, systemd-analyze verify
   tests/run.sh
   ```

   CI runs the same two commands on Ubuntu 22.04, Ubuntu 24.04 and in an
   `archlinux:latest` container. Tests run as an unprivileged user, including
   installer tests with temporary destinations and simulated package/service
   managers; they never install packages or change services on the host.
3. **Configuration compatibility**: existing `/etc/cpu-watchdog.conf` files
   must keep working. New variables need defaults in the script (`${VAR:-...}`)
   and comments explaining them in `config/cpu-watchdog.conf.example`.
4. Command lines written to the log or journal must pass through
   `get_safe_cmdline`. Telegram notifications must never include command lines.
5. Do not include real data in examples, fixtures or tests: usernames, hosts,
   tokens (even revoked ones) or private paths.

For vulnerabilities, see [SECURITY.md](SECURITY.md).
