#!/usr/bin/env bash
# 一鍵安裝 v3：WireGuard 健康檢查 service + timer（嚴格偵測 + Drop-In 提醒）
#
# 功能：
#   - 嚴格偵測已啟用的 wg-quick 介面（enabled / enabled-runtime），可選擇只取 active
#   - 安裝 /usr/local/bin/wg-health.sh 與 /etc/systemd/system/wg-health@.{service,timer}
#   - 為每個介面建立並啟用 timer；支援解除安裝
#
# 用法：
#   安裝（自動偵測）:            ./wg-health-install.sh
#   指定介面覆寫:                ./wg-health-install.sh -i wg0,wg1
#   調整檢查頻率:                ./wg-health-install.sh -f 30s
#   調整握手逾時（秒）:          ./wg-health-install.sh -t 600
#   僅針對 active 介面:          ./wg-health-install.sh --only-active
#   解除安裝:                    ./wg-health-install.sh --uninstall
#
set -euo pipefail

# 預設參數（可被 CLI 覆寫）
INTERFACES=""               # 若留空會自動偵測
FREQUENCY="10s"             # systemd OnUnitActiveSec
HANDSHAKE_TIMEOUT="0"     # MAX_NO_HANDSHAKE_SEC；0=不檢查握手
UNINSTALL="false"
ONLY_ACTIVE="false"

BIN_PATH="/usr/local/bin/wg-health.sh"
SVC_PATH="/etc/systemd/system/wg-health@.service"
TMR_PATH="/etc/systemd/system/wg-health@.timer"

err() { echo "Error: $*" >&2; }
log() { echo "==> $*"; }

trim_csv() {
  local s="${1:-}"
  # 移除多餘逗號與空白
  s="$(echo "$s" | tr -s ',' | sed 's/^,//; s/,$//' | tr ',' '\n' | awk 'length>0 {gsub(/^[ \t]+|[ \t]+$/, "", $0); print}' | sort -u | tr '\n' ',' | sed 's/,$//')"
  echo "$s"
}

# 參數解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interfaces) INTERFACES="${2:-}"; shift 2;;
    -f|--frequency)  FREQUENCY="${2:-}"; shift 2;;
    -t|--timeout)    HANDSHAKE_TIMEOUT="${2:-}"; shift 2;;
    --uninstall)     UNINSTALL="true"; shift;;
    --only-active)   ONLY_ACTIVE="true"; shift;;
    -h|--help)       sed -n '1,160p' "$0"; exit 0;;
    *) err "未知參數：$1"; exit 1;;
  esac
done

# 權限與依賴檢查
if [[ "$EUID" -ne 0 ]]; then
  err "請以 root 執行（或前置 sudo）。"
  exit 1
fi
command -v systemctl >/dev/null 2>&1 || { err "需要 systemctl"; exit 1; }

detect_enabled_ifaces() {
  local out=""
  # 來源 A：unit-files 列表，選取 enabled / enabled-runtime
  local a
  a="$(systemctl list-unit-files 'wg-quick@*.service' \
      | awk '/enabled|enabled-runtime/ {gsub(/wg-quick@|\.service/, "", $1); print $1}')"
  [[ -n "$a" ]] && out+="$a"$'\n'

  # 來源 B：/etc/wireguard/*.conf 存在時，以檔名推估 iface，並再驗證 is-enabled
  if compgen -G "/etc/wireguard/*.conf" > /dev/null; then
    while IFS= read -r f; do
      local iface; iface="$(basename "$f" .conf)"
      if systemctl is-enabled "wg-quick@${iface}.service" >/dev/null 2>&1; then
        out+="$iface"$'\n'
      fi
    done < <(ls -1 /etc/wireguard/*.conf 2>/dev/null || true)
  fi

  # 去重、整理
  echo "$out" | awk 'length>0' | sort -u
}

has_dropins_note() {
  local iface="${1:?iface}"
  local noted=""

  # 模板級 Drop-In
  if [[ -d "/etc/systemd/system/wg-quick@.service.d" ]]; then
    noted="template"
  fi
  # 實例級 Drop-In
  if [[ -d "/etc/systemd/system/wg-quick@${iface}.service.d" ]]; then
    [[ -n "$noted" ]] && noted+=","
    noted+="instance"
  fi

  if [[ -n "$noted" ]]; then
    echo "⚠️  偵測到 Drop-In 覆寫（$noted）: 可能改變 Restart/Type 等行為"
  fi
}

is_masked_or_disabled() {
  local iface="${1:?iface}"
  local state
  state="$(systemctl is-enabled "wg-quick@${iface}.service" 2>/dev/null || true)"
  # masked | disabled | static | indirect | enabled | enabled-runtime
  case "$state" in
    masked|disabled|"") return 0;;
    *) return 1;;
  esac
}

is_active_unit() {
  local iface="${1:?iface}"
  local act
  act="$(systemctl is-active "wg-quick@${iface}.service" 2>/dev/null || true)"
  [[ "$act" == "active" ]]
}

# 處理解除安裝（會依據 -i 或偵測結果停用 timers）
if [[ "$UNINSTALL" == "true" ]]; then
  if [[ -z "$INTERFACES" ]]; then
    mapfile -t arr < <(detect_enabled_ifaces)
  else
    IFS=',' read -ra arr <<< "$(trim_csv "$INTERFACES")"
  fi
  log "停止並禁用 timers..."
  for i in "${arr[@]}"; do
    [[ -z "$i" ]] && continue
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

# 取得介面名單
if [[ -z "$INTERFACES" ]]; then
  mapfile -t IFACES < <(detect_enabled_ifaces)
  if [[ "${#IFACES[@]}" -eq 0 ]]; then
    log "未偵測到已啟用介面，將預設為：wg0"
    IFACES=(wg0)
  else
    log "偵測到已啟用介面：${IFACES[*]}"
  fi
else
  IFS=',' read -ra IFACES <<< "$(trim_csv "$INTERFACES")"
  log "使用指定介面：${IFACES[*]}"
fi

# 只保留 enabled / enabled-runtime；且若指定 --only-active，會過濾掉非 active
FILTERED_IFACES=()
for i in "${IFACES[@]}"; do
  [[ -z "$i" ]] && continue
  if is_masked_or_disabled "$i"; then
    log "略過（未啟用/被 masked）：$i"
    continue
  fi
  if [[ "$ONLY_ACTIVE" == "true" ]] && ! is_active_unit "$i"; then
    log "略過（非 active）：$i"
    continue
  fi
  FILTERED_IFACES+=("$i")
done

if [[ "${#FILTERED_IFACES[@]}" -eq 0 ]]; then
  err "沒有可套用的介面（可能都未啟用或非 active）。"
  exit 1
fi

# 安裝健康檢查腳本
log "安裝健康檢查腳本到 $BIN_PATH"
install -D -m 0755 /dev/stdin "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFACE="${1:-wg0}"
MAX_NO_HANDSHAKE_SEC="${MAX_NO_HANDSHAKE_SEC:-600}"

log() { logger -t "wg-health[$IFACE]" -- "$*"; echo "$*"; }

# 介面存在？
if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
  log "interface $IFACE not found; restarting wg-quick@$IFACE"
  systemctl restart "wg-quick@$IFACE"
  exit 0
fi

STATE="$(cat /sys/class/net/$IFACE/carrier 2>/dev/null || echo unknown)"
if [[ "$STATE" != "1" ]]; then
  log "interface $IFACE carrier=$STATE; restarting wg-quick@$IFACE"
  systemctl restart "wg-quick@$IFACE"
  exit 0
fi

# peers 數
PEER_COUNT="$(wg show "$IFACE" peers 2>/dev/null | wc -w || echo 0)"
if [[ "${PEER_COUNT:-0}" -eq 0 ]]; then
  log "no peers on $IFACE; interface up; nothing to do"
  exit 0
fi

# 檢查握手（0 表示不檢查）
if [[ "${MAX_NO_HANDSHAKE_SEC}" != "0" ]]; then
  NOW="$(date +%s)"
  STALES=0
  # wg show dump：第1行 interface；之後每行 peer；第6欄 latest_handshake（epoch 秒；0=從未握手）
  while IFS=$'\t' read -r _pk _psk _ep _allowed latest _rx _tx _keepalive; do
    [[ -z "${latest:-}" ]] && continue
    if [[ "$latest" -eq 0 ]]; then
      ((STALES++)); continue
    fi
    AGE=$(( NOW - latest ))
    (( AGE > MAX_NO_HANDSHAKE_SEC )) && ((STALES++))
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

for i in "${FILTERED_IFACES[@]}"; do
  note="$(has_dropins_note "$i" || true)"
  [[ -n "$note" ]] && log "$note （iface: $i）"

  log "啟用並啟動 timer：wg-health@${i}.timer"
  systemctl enable --now "wg-health@${i}.timer"
done

log "檢視 timers 狀態（僅 wg-health）："
echo "  systemctl list-timers 'wg-health@*.timer' --all || true"
systemctl list-timers 'wg-health@*.timer' --all || true

log "完成。手動觸發與檢視日誌："
echo "  systemctl start wg-health@${FILTERED_IFACES[0]}.service"
echo "  journalctl -u wg-health@${FILTERED_IFACES[0]}.service -n 50 --no-pager"