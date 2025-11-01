#!/usr/bin/env bash
# 一鍵安裝：WireGuard 健康檢查 service + timer
# 用法：
#   安裝（預設介面 wg0）：      ./wg-health-install.sh
#   指定介面：                  ./wg-health-install.sh -i wg0,wg1
#   調整檢查頻率：              ./wg-health-install.sh -f 30s
#   調整握手逾時（秒）：        ./wg-health-install.sh -t 600
#   同時指定多項：              ./wg-health-install.sh -i wg0,wg1 -f 45s -t 900
#   解除安裝：                  ./wg-health-install.sh --uninstall

set -euo pipefail

# 預設值
INTERFACES="wg0"
FREQUENCY="10s"              # systemd OnUnitActiveSec
HANDSHAKE_TIMEOUT="0"      # MAX_NO_HANDSHAKE_SEC；0 代表不檢查握手
UNINSTALL="false"

err() { echo "Error: $*" >&2; }
log() { echo "==> $*"; }

# 參數解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interfaces)
      INTERFACES="${2:-}"; shift 2;;
    -f|--frequency)
      FREQUENCY="${2:-}"; shift 2;;
    -t|--timeout)
      HANDSHAKE_TIMEOUT="${2:-}"; shift 2;;
    --uninstall)
      UNINSTALL="true"; shift;;
    -h|--help)
      sed -n '1,80p' "$0"; exit 0;;
    *)
      err "未知參數：$1"; exit 1;;
  esac
done

# 權限與依賴檢查
if [[ "$EUID" -ne 0 ]]; then
  err "請以 root 執行（或前置 sudo）。"
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  err "需要 systemd 的 systemctl 指令。"
  exit 1
fi

# 檔案路徑
BIN_PATH="/usr/local/bin/wg-health.sh"
SVC_PATH="/etc/systemd/system/wg-health@.service"
TMR_PATH="/etc/systemd/system/wg-health@.timer"

if [[ "$UNINSTALL" == "true" ]]; then
  log "停止並禁用 timers..."
  IFS=',' read -ra IFACES <<< "$INTERFACES"
  for i in "${IFACES[@]}"; do
    systemctl disable --now "wg-health@${i}.timer" >/dev/null 2>&1 || true
    systemctl stop "wg-health@${i}.service" >/dev/null 2>&1 || true
  done

  log "移除單元檔與腳本..."
  rm -f "$SVC_PATH" "$TMR_PATH" "$BIN_PATH"

  log "重新載入 systemd..."
  systemctl daemon-reload

  log "完成移除。"
  exit 0
fi

# 安裝健康檢查腳本
log "安裝健康檢查腳本到 $BIN_PATH"
install -D -m 0755 /dev/stdin "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFACE="${1:-wg0}"
MAX_NO_HANDSHAKE_SEC="${MAX_NO_HANDSHAKE_SEC:-600}"

log() { logger -t "wg-health[$IFACE]" -- "$*"; echo "$*"; }

# 檢查介面存在
if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
  log "interface $IFACE not found; restarting wg-quick@$IFACE"
  systemctl restart "wg-quick@$IFACE"
  exit 0
fi

STATE="$(cat /sys/class/net/$IFACE/operstate 2>/dev/null || echo unknown)"
if [[ "$STATE" != "up" ]]; then
  log "interface $IFACE state=$STATE; restarting wg-quick@$IFACE"
  systemctl restart "wg-quick@$IFACE"
  exit 0
fi

# peers 數量
PEER_COUNT="$(wg show "$IFACE" peers 2>/dev/null | wc -w || echo 0)"
if [[ "${PEER_COUNT:-0}" -eq 0 ]]; then
  log "no peers on $IFACE; interface up; nothing to do"
  exit 0
fi

# 是否檢查握手
if [[ "${MAX_NO_HANDSHAKE_SEC}" != "0" ]]; then
  NOW="$(date +%s)"
  STALES=0
  # wg show dump：第一行是 interface，之後每行是 peer；第6欄是 latest_handshake（epoch 秒，0=從未握手）
  while IFS=$'\t' read -r _pk _psk _ep _allowed latest _rx _tx _keepalive; do
    [[ -z "${latest:-}" ]] && continue
    if [[ "$latest" -eq 0 ]]; then
      ((STALES++))
      continue
    fi
    AGE=$(( NOW - latest ))
    if (( AGE > MAX_NO_HANDSHAKE_SEC )); then
      ((STALES++))
    fi
  done < <(wg show "$IFACE" dump | awk 'NR>1')

  if (( STALES == PEER_COUNT )); then
    log "all peers on $IFACE stale (> ${MAX_NO_HANDSHAKE_SEC}s); restarting wg-quick@$IFACE"
    systemctl restart "wg-quick@$IFACE"
  else
    log "OK: $IFACE peers healthy"
  fi
else
  log "OK: $IFACE up (handshake check disabled)"
fi
EOF

# 建立 service
log "建立 $SVC_PATH"
install -D -m 0644 /dev/stdin "$SVC_PATH" <<EOF
[Unit]
Description=WireGuard health check for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=MAX_NO_HANDSHAKE_SEC=${HANDSHAKE_TIMEOUT}
ExecStart=${BIN_PATH} %i
EOF

# 建立 timer
log "建立 $TMR_PATH（頻率：${FREQUENCY}）"
install -D -m 0644 /dev/stdin "$TMR_PATH" <<EOF
[Unit]
Description=Periodic WireGuard health check for %i

[Timer]
OnBootSec=1min
OnUnitActiveSec=${FREQUENCY}
Unit=wg-health@%i.service
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 套用與啟用
log "重新載入 systemd..."
systemctl daemon-reload

IFS=',' read -ra IFACES <<< "$INTERFACES"
for i in "${IFACES[@]}"; do
  i="$(echo "$i" | xargs)"  # trim
  [[ -z "$i" ]] && continue
  log "啟用並啟動 timer：wg-health@${i}.timer"
  systemctl enable --now "wg-health@${i}.timer"
done

log "檢視 timers 狀態（只顯示這組）："
systemctl list-timers 'wg-health@*.timer' --all || true

log "完成。你可以用以下指令手動觸發一次檢查，並看日誌："
echo "  systemctl start wg-health@wg0.service"
echo "  journalctl -u wg-health@wg0.service -n 50 --no-pager"