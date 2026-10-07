# Contribuindo

Issues e PRs são bem-vindos. O projeto é em português (código, commits e docs).

1. Mudança de comportamento vem com teste: escreva o teste em `tests/`, veja
   falhar, depois implemente. Os testes rodam sem root e sem tocar o sistema
   (ver "Desenvolvimento" no README).
2. Antes de abrir o PR, rode:

   ```bash
   tests/lint.sh   # bash -n, shellcheck, systemd-analyze verify
   tests/run.sh
   ```

   O CI roda os mesmos dois comandos em Ubuntu 22.04, Ubuntu 24.04 e num
   container `archlinux:latest`. Os testes rodam sem root; os testes do instalador
   usam destinos temporários e gerenciadores de pacotes/serviços simulados,
   sem instalar pacotes nem alterar serviços no host.
3. **Compatibilidade de config**: `/etc/cpu-watchdog.conf` existente não pode
   quebrar. Variável nova precisa de default no script (`${VAR:-...}`) e entra
   comentada/explicada em `config/cpu-watchdog.conf.example`.
4. Nada que vá para log, journal ou Telegram pode incluir cmdline sem passar
   por `get_safe_cmdline`. Notificações não levam cmdline nenhuma.
5. Não inclua dados reais em exemplos, fixtures ou testes: nomes de usuário,
   hosts, tokens (mesmo revogados), caminhos privados.

Vulnerabilidades: veja [SECURITY.md](SECURITY.md).
