# vps-watchdog

Watchdog de CPU e memória para VPS Linux com systemd: detecta processos (ou o
conjunto de processos) consumindo CPU ou memória demais por tempo demais e
age — throttle (via `cpulimit`) nos casos comuns, `kill` nos casos de fork
bomb e de falta de memória.

Nasceu numa VPS de desenvolvimento compartilhada por várias sessões de
agentes de IA (Claude Code), node e php: primeiro o provedor limitou a máquina
por uso excessivo e sustentado de CPU; depois um OOM derrubou a máquina — o
OOM killer do kernel matou `systemd`, `dbus` e o serviço principal enquanto
as 20 sessões de ~300 MB que inflavam a memória seguiam vivas. As Camadas 1–3
vieram do primeiro incidente, a Camada 4 do segundo.

Roda como um timer systemd de 1 em 1 minuto.

> Antes chamado **cpu-watchdog**. Por compatibilidade com instalações
> existentes, arquivos, units e caminhos instalados continuam com esse nome
> (`/etc/cpu-watchdog.conf`, `cpu-watchdog.timer`, ...).

## Como funciona

Quatro camadas, todas configuráveis em `/etc/cpu-watchdog.conf`:

- **Camada 1 — processo único**: se um processo sozinho sustenta
  `CPU_THRESHOLD`% de CPU (base 1 core) por `SUSTAIN_CHECKS` minutos
  seguidos, ele é limitado a `LIMIT_PERCENT`%.
- **Camada 2 — uso agregado**: cobre o caso de vários processos moderados
  que juntos pressionam a máquina sem nenhum sozinho cruzar a Camada 1. Se a
  soma de CPU de todos os processos passar de `AGG_CPU_THRESHOLD_PCT`% da
  capacidade total (nproc × 100) por `AGG_SUSTAIN_CHECKS` minutos seguidos,
  limita até `AGG_MAX_THROTTLES` processos (os que mais consomem no momento)
  a `AGG_LIMIT_PERCENT`% cada.
- **Camada 3 — fork bomb**: cobre o caso de N processos com a **mesma linha
  de comando completa**, cada um sozinho já acima de `CPU_THRESHOLD` (ex.:
  um `while :; do :; done` disparado várias vezes com `&`). Throttle não
  escala nesse caso — com processos o bastante, sempre sobra gente rodando a
  todo vapor. Sustentado por `FORKBOMB_SUSTAIN_CHECKS` execuções com
  `FORKBOMB_MIN_COUNT` ou mais cópias idênticas, mata todas com `SIGTERM`.
  Risco conhecido: pools legítimos de workers (php-fpm, gunicorn) sob carga
  pesada sustentada poderiam, em teoria, casar com esse padrão — se acontecer
  um falso positivo, adicione o comando à `WHITELIST_COMM`.
- **Camada 4 — memória**: o kernel só age quando a memória já acabou, e
  escolhe mal. Duas partes:
  - **earlyoom** (daemon, reage em ~1s, config em `config/earlyoom.default`):
    SIGTERM quando RAM disponível <= 6% **e** swap livre <= 10%, SIGKILL em
    3%/5%. `--prefer` mira node/php/chrome (onde rodam vite, jest, phpunit,
    browsers headless); `--avoid` protege sshd, systemd, docker, bancos,
    tailscaled. Sessões `claude` não têm bônus: só morrem depois, pelo
    tamanho. Rede de segurança contra picos súbitos.
  - **no watchdog** (a cada minuto), para o que é lento:
    - 4a: processo com RSS >= `MEM_PROC_KILL_MB` por
      `MEM_PROC_SUSTAIN_CHECKS` minutos -> SIGTERM; SIGKILL na execução
      seguinte se ignorar.
    - 4b: máquina com RAM disponível <= `MEM_AVAIL_KILL_PCT`% e swap livre
      <= `MEM_SWAP_FREE_KILL_PCT`% por `MEM_SYS_SUSTAIN_CHECKS` minutos ->
      SIGTERM no maior processo, um por vez, nesta ordem: primeiro quem
      casa `MEM_PREFER_FIRST_REGEX` (cmdline — ferramentas de teste/build
      como vite e phpunit), depois `MEM_PREFER_REGEX` (comm — sessões
      claude, node, php), depois o resto. Antes disso, alerta (com cooldown) ao cruzar
      `MEM_AVAIL_WARN_PCT` / `MEM_SWAP_USED_WARN_PCT`, listando os maiores
      grupos por nome (ex.: `20×claude=5361MB`). Em host sem swap, o
      critério depende só da RAM.
    - 4c: relata os kills feitos pelo earlyoom.

  A camada de memória usa a própria whitelist, `MEM_WHITELIST_COMM`:
  `claude` é isento de throttle de CPU mas **pode** ser morto por memória.

Processos na `WHITELIST_COMM` (sshd, systemd, cron, etc.) nunca são tocados
pelas camadas de CPU (1–3). Nomes em ambas as whitelists são o `comm` do
kernel, truncado em 15 caracteres (`systemd-journald` -> `systemd-journal`).
`WHITELIST_CMDLINE` (regex ERE contra a linha de comando completa) vale para
todas as camadas.

O `cpulimit` é iniciado com `systemd-run --scope`: o serviço é oneshot com
`KillMode=control-group`, e um `cpulimit` em background no cgroup do serviço
era morto pelo systemd assim que o script terminava (o throttle durava
segundos e era reaplicado a cada execução).

Identifica cada processo por `pid:horário-de-início` (lido de
`/proc/<pid>/stat`) pra não confundir com outro processo que reaproveitou o
mesmo PID depois.

## Requisitos e suporte

Alvo: **Linux com systemd**, rodando como root. Testado em Ubuntu 24.04
(systemd 255, kernel 6.8); o CI roda em Ubuntu 22.04 e 24.04.

| Dependência | Uso | Obrigatória? |
|---|---|---|
| bash >= 4.4 | `mapfile -d`, arrays associativos | sim |
| systemd (`systemctl`, `systemd-run`) | timer, scope próprio do `cpulimit` | sim |
| procps (`ps`), util-linux (`flock`, `logger`), coreutils, GNU sed, awk | coleta e log | sim |
| `/proc/meminfo`, `/proc/<pid>/{stat,cmdline}` | medição | sim |
| `cpulimit` | throttle (Camadas 1–2) | não — sem ele o watchdog só alerta |
| `earlyoom` | picos súbitos de memória | não — recomendado |
| `curl` | alertas no Telegram | não |
| `/proc/pressure/memory` (PSI, kernel >= 4.20) | contexto nos alertas | não — mostra `?` |
| `tailscaled` | drop-in de proteção OOM | não — só aplicado se existir |

- O `install.sh` usa `apt-get` para instalar `cpulimit` e `earlyoom`: pronto
  para Debian/Ubuntu. Em outras distros, instale as dependências pelo gerenciador
  de pacotes local antes de rodar o script (ele pula o que já existe).
- GNU sed é necessário (`sed -z` e a flag `I` na sanitização). BusyBox/Alpine
  não é suportado.
- Containers sem systemd (Docker comum, WSL sem systemd) não são suportados.

## Instalação / atualização

```bash
sudo ./install.sh
```

Idempotente — rode de novo sempre que mudar algo neste repo:

- Copia `bin/cpu-watchdog.sh` e as units em `systemd/` só se o conteúdo mudou.
- Dá `systemctl daemon-reload` + `restart` no timer automaticamente quando
  algo muda.
- Instala `/etc/cpu-watchdog.conf` a partir de `config/cpu-watchdog.conf.example`
  **só na primeira vez**. Se já existe e foi customizado (ex.: tokens de
  Telegram preenchidos, thresholds ajustados), o install nunca sobrescreve —
  só mostra o diff em relação ao template do repo, com valores sensíveis
  mascarados.
- Instala `cpulimit` e `earlyoom` via apt se não estiverem presentes.
- **Sobrescreve** `/etc/default/earlyoom` com `config/earlyoom.default` (e
  reinicia o earlyoom) sempre que o conteúdo difere — faça backup antes da
  primeira instalação se você já tinha um earlyoom customizado.

Configs antigas continuam válidas: nenhuma variável nova é obrigatória.

## Recursos opcionais

- **Alertas via Telegram**: preencha `TELEGRAM_BOT_TOKEN` e `TELEGRAM_CHAT_ID`
  em `/etc/cpu-watchdog.conf`. Em branco = só loga localmente. Token e chat_id
  são passados ao `curl` pelo stdin, nunca no argv. As mensagens trazem nome do
  processo, PID e ação — nunca a linha de comando.
- **earlyoom**: instalado e configurado pelo `install.sh`. Para não usar,
  `sudo systemctl disable --now earlyoom` depois da instalação (as Camadas
  4a/4b do watchdog continuam valendo; a 4c fica inativa).
- **Proteção OOM do tailscaled**: se `tailscaled.service` existir, o install
  aplica `OOMScoreAdjust=-900` via drop-in (e ao vivo com `choom`, sem
  reiniciar o tailscaled). Nada é feito se não houver tailscale.
- **Sem `cpulimit`**: as Camadas 1–2 só registram/alertam
  (`ALERTA (cpulimit ausente)`); Camadas 3–4 funcionam normalmente.

## Logs e segredos

A linha de comando dos processos afetados vai para o log local e para o
journal, **sanitizada** — nunca para o Telegram. Viram `<redacted>`:

- valores de flags e variáveis com nomes sensíveis (`--password x`,
  `--token=x`, `DB_PASSWORD=x`, `"password":"x"` em JSON), inclusive valores
  com espaços;
- senha ou token em URL (`postgres://u:x@host`, `https://TOKEN@github.com`),
  query params e fragmentos (`?access_token=x`, `#access_token=x`), DSN Go
  (`u:x@tcp(host)`);
- headers de autenticação (`Authorization: Bearer x`, `X-Api-Key: x`,
  `Cookie: x`), inclusive embutidos (`--header=X-Api-Key: x`);
- `user:senha` do curl (`--user`, `-u`, `--proxy-user`, `-U`, com ou sem `=`);
- flags curtas de senha de programas conhecidos: `mysql`/`mariadb -pSENHA`,
  `sshpass -p`, `redis-cli -a`, `docker`/`podman`/`helm ... login -p`;
- formatos conhecidos de token (GitHub, GitLab, Slack, AWS, OpenAI/Anthropic,
  Google, JWT, bot do Telegram).

Argumentos com espaços (`sh -c '...'`, processos que reescrevem o próprio
argv) são quebrados em palavras e passam pelas mesmas regras. A comparação é
feita byte a byte (`LC_ALL=C`), então UTF-8 inválido não escapa das regras.
Caracteres de controle viram `?` (sem forjar linhas no log), a linha é
truncada em 1024 bytes e argv gigantes param de ser processados logo após o
limite.

É uma heurística que prefere redigir demais (`--author x` também some). Ainda
escapam: segredo posicional ou em formato desconhecido sem nome sugestivo,
flag curta de programa fora da lista acima, valor que começa com `-` depois
de flag sensível (`--password -x`) e cookies com vários pares (só o primeiro é
redigido). Arquivos novos são criados com `umask 077` (log `600`, estado
`700`); um log que já existia mantém o modo antigo. Veja
[SECURITY.md](SECURITY.md).

## Arquivos em produção

| O quê | Onde |
|---|---|
| Script | `/usr/local/bin/cpu-watchdog.sh` |
| Config | `/etc/cpu-watchdog.conf` |
| Estado (não editar) | `/var/lib/cpu-watchdog/*.tsv` |
| Log de ações | `/var/log/cpu-watchdog.log` (e `journalctl -u cpu-watchdog`) |
| Units | `/etc/systemd/system/cpu-watchdog.{service,timer}` |
| Throttles ativos | `systemctl list-units 'cpu-watchdog-limit-*'` |
| earlyoom | `/etc/default/earlyoom` (e `journalctl -u earlyoom`) |
| Proteção OOM do tailscaled | `/etc/systemd/system/tailscaled.service.d/oom.conf` |

## Operação

```bash
systemctl status cpu-watchdog.timer      # está rodando?
tail -f /var/log/cpu-watchdog.log        # ações em tempo real
systemctl stop cpu-watchdog.timer        # pausar
```

Liberar um processo já throttled manualmente (mata o `cpulimit` associado,
não o processo alvo):

```bash
systemctl stop cpu-watchdog-limit-<PID>-<starttime>.scope
# ou: pkill -f "cpulimit -p <PID>"
```

## Rollback

**Voltar para uma versão anterior** (o config instalado não é tocado):

```bash
git checkout <commit-ou-tag-anterior>
sudo ./install.sh
```

**Desligar sem desinstalar** (reversível com `enable --now`):

```bash
sudo systemctl disable --now cpu-watchdog.timer
sudo systemctl stop 'cpu-watchdog-limit-*.scope'   # solta throttles ativos
```

**Desinstalar**:

```bash
sudo systemctl disable --now cpu-watchdog.timer
sudo systemctl stop 'cpu-watchdog-limit-*.scope'
sudo rm /etc/systemd/system/cpu-watchdog.service /etc/systemd/system/cpu-watchdog.timer
sudo rm /usr/local/bin/cpu-watchdog.sh
sudo rm -r /var/lib/cpu-watchdog /run/cpu-watchdog.lock
sudo cp /etc/cpu-watchdog.conf ~/cpu-watchdog.conf.bak && sudo rm /etc/cpu-watchdog.conf  # contém o token
sudo rm /etc/systemd/system/tailscaled.service.d/oom.conf   # se existir
sudo systemctl daemon-reload
# earlyoom: desligar, ou remover o pacote, ou restaurar seu /etc/default/earlyoom
sudo systemctl disable --now earlyoom
```

O log `/var/log/cpu-watchdog.log` fica para auditoria; apague quando não
precisar mais. O ajuste ao vivo de OOM do tailscaled some no próximo restart
dele.

## Desenvolvimento

```bash
tests/lint.sh   # bash -n, shellcheck, systemd-analyze verify
tests/run.sh    # testes das camadas, sanitização, notificação e config
```

Os testes rodam sem root e sem tocar o sistema: executam o script de verdade
contra processos-vítima filhos do próprio teste, com `ps`, `cpulimit`,
`systemd-run`, `curl`, `logger`, `journalctl` e `systemctl` substituídos por
stubs (`tests/stubs/`). Para isso o script aceita três overrides de ambiente,
que o systemd nunca define e que são **ignorados quando o script roda como
root**:

| Variável | Default |
|---|---|
| `CPU_WATCHDOG_CONF` | `/etc/cpu-watchdog.conf` |
| `CPU_WATCHDOG_LOCK` | `/run/cpu-watchdog.lock` |
| `CPU_WATCHDOG_PROC_DIR` | `/proc` |

Veja [CONTRIBUTING.md](CONTRIBUTING.md).

## Licença

[MIT](LICENSE).
