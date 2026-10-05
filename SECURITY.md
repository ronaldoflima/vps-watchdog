# Segurança

## Reportando uma vulnerabilidade

Não abra issue pública. Use o **reporte privado de vulnerabilidade do GitHub**
(aba *Security* → *Report a vulnerability*) neste repositório. Inclua versão
(commit), distro/systemd e passos para reproduzir. A resposta inicial é feita
em melhor esforço — este é um projeto mantido por voluntários.

Versões suportadas: apenas a `main` mais recente.

## Modelo de ameaça

O watchdog roda como **root** a cada minuto e pode aplicar throttle e enviar
`SIGTERM`/`SIGKILL` a qualquer processo fora das whitelists. Por isso:

- **`/etc/cpu-watchdog.conf` é código executado como root** (é carregado com
  `source`). Deve ser `root:root`, modo `600`; o `install.sh` cria com modo `600` e
  reaplica o modo em reinstalações quando ele está customizado. Quem escreve
  nesse arquivo tem root.
- **Processos alheios são entrada não confiável.** `comm` e cmdline são
  controlados por qualquer usuário local. O script nunca os interpreta como
  código; a cmdline só é casada contra `WHITELIST_CMDLINE`, agrupada por hash
  (Camada 3) e, sanitizada, gravada em log.
- **Um usuário local pode provocar ações contra os próprios processos** (ex.:
  subir CPU para ser limitado) ou, com processos que imitem o `comm` de um
  serviço, tentar se esconder numa whitelist. Whitelists por `comm` são
  conveniência, não fronteira de segurança.
- **Camadas 3 e 4 matam processos.** Um falso positivo derruba serviço
  legítimo. Revise `WHITELIST_COMM`, `MEM_WHITELIST_COMM`, `MEM_PREFER_REGEX`
  e o `--avoid` do earlyoom para a sua máquina antes de instalar.

## Segredos

- **Telegram**: token e chat_id vivem só em `/etc/cpu-watchdog.conf`. São
  passados ao `curl` pelo stdin (`-K -`), não pelo argv, então não aparecem em
  `ps`. As mensagens nunca incluem a linha de comando dos processos.
- **Logs**: `/var/log/cpu-watchdog.log` e o journal recebem a cmdline dos
  processos afetados **sanitizada** (ver README, "Logs e segredos"). A
  sanitização é heurística: segredo posicional ou em formato desconhecido sem
  nome sugestivo ainda pode aparecer. Trate os logs como sensíveis:
  - o script roda com `umask 077`, então um log criado por ele nasce `600`;
    **um log que já existia mantém o modo antigo** — rode
    `sudo chmod 600 /var/log/cpu-watchdog.log` (e `chmod 700` no
    `STATE_DIR`, que guarda hashes de cmdlines);
  - logs e journal gravados por versões anteriores à sanitização contêm
    cmdlines cruas — revise e rotacione (`journalctl --rotate` +
    `--vacuum-time`) se processos da máquina recebiam segredos por argv;
  - o journal é legível pelos grupos `adm`/`systemd-journal`;
  - as linhas do earlyoom repassadas pela Camada 4c não passam pela
    sanitização (hoje o earlyoom só informa pid, uid e nome do processo).
- **Ambiente**: os overrides `CPU_WATCHDOG_CONF`, `CPU_WATCHDOG_LOCK` e
  `CPU_WATCHDOG_PROC_DIR` existem só para os testes e são ignorados quando o
  script roda como root. Lock e `/proc` também não podem ser alterados pelo
  config.
- **Telegram (credenciais inválidas)**: token ou chat_id com caractere de
  controle desativa o envio (evita injetar diretivas no config do curl) e é
  registrado no log.
- **Instalação**: o `install.sh` nunca imprime o config em texto puro — o diff
  mostrado mascara variáveis `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*CHAT_ID*`,
  `*API_KEY*`.
