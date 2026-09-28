#!/usr/bin/env bash
# Instala/atualiza o cpu-watchdog a partir deste repo.
# Idempotente: rodar de novo depois de mudar bin/systemd/config aplica só o
# que mudou (compara por conteúdo) e recarrega o systemd quando necessário.
# O /etc/cpu-watchdog.conf já instalado NUNCA é sobrescrito automaticamente
# (pode ter tokens de Telegram e thresholds ajustados manualmente).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Rode como root (sudo ./install.sh)" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGED=0

install_if_changed() {
    local src="$1" dest="$2" mode="${3:-644}"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        echo "  sem mudança: $dest"
        return 0
    fi
    install -D -m "$mode" "$src" "$dest"
    echo "  atualizado:  $dest"
    CHANGED=1
}

echo "==> Dependências"
if command -v cpulimit >/dev/null 2>&1; then
    echo "  cpulimit ok"
else
    echo "  instalando cpulimit..."
    apt-get update -qq
    apt-get install -y cpulimit
fi
if command -v earlyoom >/dev/null 2>&1; then
    echo "  earlyoom ok"
else
    echo "  instalando earlyoom..."
    apt-get update -qq
    apt-get install -y earlyoom
fi

echo "==> Script principal"
install_if_changed "$REPO_DIR/bin/cpu-watchdog.sh" /usr/local/bin/cpu-watchdog.sh 755

echo "==> Unidades systemd"
install_if_changed "$REPO_DIR/systemd/cpu-watchdog.service" /etc/systemd/system/cpu-watchdog.service
install_if_changed "$REPO_DIR/systemd/cpu-watchdog.timer" /etc/systemd/system/cpu-watchdog.timer

echo "==> earlyoom (Camada 4: picos súbitos de memória)"
EARLYOOM_CHANGED=0
if ! cmp -s "$REPO_DIR/config/earlyoom.default" /etc/default/earlyoom; then
    install -m 644 "$REPO_DIR/config/earlyoom.default" /etc/default/earlyoom
    echo "  atualizado:  /etc/default/earlyoom"
    EARLYOOM_CHANGED=1
else
    echo "  sem mudança: /etc/default/earlyoom"
fi
systemctl enable --now earlyoom >/dev/null 2>&1
if [ "$EARLYOOM_CHANGED" -eq 1 ]; then
    systemctl restart earlyoom
fi

if systemctl cat tailscaled.service >/dev/null 2>&1; then
    install_if_changed "$REPO_DIR/systemd/tailscaled-oom.conf" /etc/systemd/system/tailscaled.service.d/oom.conf
    # Aplica ao vivo sem reiniciar o tailscaled (derrubaria o acesso remoto).
    for p in $(pgrep -x tailscaled || true); do
        choom -p "$p" -n -900 >/dev/null 2>&1 || true
    done
fi

echo "==> Config"
if [ ! -f /etc/cpu-watchdog.conf ]; then
    install -D -m 600 "$REPO_DIR/config/cpu-watchdog.conf.example" /etc/cpu-watchdog.conf
    echo "  criado: /etc/cpu-watchdog.conf a partir do template"
    CHANGED=1
elif cmp -s "$REPO_DIR/config/cpu-watchdog.conf.example" /etc/cpu-watchdog.conf; then
    echo "  /etc/cpu-watchdog.conf ok (igual ao template do repo)"
else
    chmod 600 /etc/cpu-watchdog.conf  # tem token do Telegram
    echo "  /etc/cpu-watchdog.conf já existe e está customizado — não sobrescrevendo."
    echo "  diferenças em relação ao template (valores sensíveis mascarados):"
    # Nunca imprimir valores de TOKEN/CHAT_ID/SECRET/PASSWORD/API_KEY em texto puro —
    # eles vivem só em /etc/cpu-watchdog.conf, nunca no repo nem em stdout.
    redact() { sed -E 's/^([A-Z_]*(TOKEN|SECRET|PASSWORD|CHAT_ID|API_KEY)=).*/\1"<redacted>"/' "$1"; }
    diff -u <(redact /etc/cpu-watchdog.conf) <(redact "$REPO_DIR/config/cpu-watchdog.conf.example") || true
fi

echo "==> Estado"
mkdir -p /var/lib/cpu-watchdog
touch /var/lib/cpu-watchdog/counts.tsv /var/lib/cpu-watchdog/limited.tsv

echo "==> systemd"
if [ "$CHANGED" -eq 1 ]; then
    systemctl daemon-reload
fi
systemctl enable --now cpu-watchdog.timer
if [ "$CHANGED" -eq 1 ]; then
    systemctl restart cpu-watchdog.timer
    echo "  timer recarregado (havia mudanças)"
fi

echo
echo "==> Resumo"
(
    # shellcheck disable=SC1091
    source /etc/cpu-watchdog.conf
    echo "  Config:                   /etc/cpu-watchdog.conf"
    echo "  Camada 1 (processo único): ${CPU_THRESHOLD}% CPU por ${SUSTAIN_CHECKS}min -> throttle a ${LIMIT_PERCENT}%"
    echo "  Camada 2 (uso agregado):   ${AGG_CPU_THRESHOLD_PCT}% da capacidade total por ${AGG_SUSTAIN_CHECKS}min -> throttle top ${AGG_TOP_N} a ${AGG_LIMIT_PERCENT}%"
    echo "  Camada 4 (memória):        processo >= ${MEM_PROC_KILL_MB:-?}MB por ${MEM_PROC_SUSTAIN_CHECKS:-?}min -> SIGTERM; RAM livre <= ${MEM_AVAIL_KILL_PCT:-?}% e swap livre <= ${MEM_SWAP_FREE_KILL_PCT:-?}% por ${MEM_SYS_SUSTAIN_CHECKS:-?}min -> SIGTERM no maior; earlyoom $(systemctl is-active earlyoom)"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        echo "  Telegram:                 ativado"
    else
        echo "  Telegram:                 desativado (edite TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID em /etc/cpu-watchdog.conf pra ativar)"
    fi
    echo "  Editar:                   sudo \$EDITOR /etc/cpu-watchdog.conf   (não precisa reiniciar nada, o timer lê o arquivo a cada execução)"
)

echo
echo "OK."
systemctl status cpu-watchdog.timer --no-pager -l | head -5
