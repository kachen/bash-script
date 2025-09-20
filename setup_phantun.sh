#!/bin/bash

# =================================================================
#         Phantun Configuration Script for Linux
# =================================================================
#
# 這個腳本會幫助您將 phantun 設定為伺服器或客戶端。
# 它會建立必要的設定檔和 systemd 服務檔案。
#
# 前提條件: phantun 必須已安裝在 /usr/local/bin/phantun。
#
# =================================================================

# --- 安全設定 ---
set -e
set -u
set -o pipefail

# --- 變數與常數 ---
# 顏色代碼
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

CONFIG_DIR="/etc/phantun"
SYSTEMD_DIR="/etc/systemd/system"

# --- 函數定義 ---

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# 檢查 root 權限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此腳本必須以 root 權限執行。請使用 'sudo'。"
    fi
}

# 檢查 phantun 二進位檔案是否存在
check_prerequisites() {
    if ! command -v phantun &> /dev/null; then
        error "找不到 'phantun' 指令。請先執行安裝腳本。"
    fi
    log "已找到 phantun 二進位檔案。"
}

# 將 phantun 設定為伺服器
setup_server() {
    log "--- 正在設定 Phantun 伺服器 ---"
    
    read -rp "請輸入 phantun 監聽的 TCP 位址 [預設: 0.0.0.0:443]: " -e -i "0.0.0.0:443" PHANTUN_LISTEN
    read -rp "請輸入要轉發到的本地 WireGuard UDP 位址 [預設: 127.0.0.1:51820]: " -e -i "127.0.0.1:51820" WG_REMOTE

    local CONFIG_FILE="$CONFIG_DIR/server.toml"
    local SERVICE_FILE="$SYSTEMD_DIR/phantun-server.service"

    log "正在建立設定目錄: $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"

    log "正在於 $CONFIG_FILE 建立 phantun 伺服器設定檔"
    cat > "$CONFIG_FILE" << EOF
# Phantun Server Configuration
# 由設定腳本產生

[server]
# 監聽來自客戶端的 TCP 連線位址
listen = "$PHANTUN_LISTEN"

# 本地 WireGuard 伺服器的 UDP 位址
remote = "$WG_REMOTE"
EOF

    log "正在於 $SERVICE_FILE 建立 systemd 服務檔案"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Phantun Server
After=network.target
Wants=wg-quick@wg0.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/phantun -c $CONFIG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log "正在重新載入 systemd 並啟動 phantun-server 服務..."
    systemctl daemon-reload
    systemctl enable --now phantun-server.service

    log "Phantun 伺服器設定完成並已啟動。"
    local PHANTUN_PORT
    PHANTUN_PORT=$(echo "$PHANTUN_LISTEN" | awk -F: '{print $NF}')
    warn "重要：請記得在您的防火牆上開啟 TCP 埠 $PHANTUN_PORT！"
    warn "例如: sudo iptables -A INPUT -p tcp --dport $PHANTUN_PORT -j ACCEPT"
}

# 將 phantun 設定為客戶端
setup_client() {
    log "--- 正在設定 Phantun 客戶端 ---"

    read -rp "請輸入 phantun 本地監聽的 UDP 位址 [預設: 127.0.0.1:51821]: " -e -i "127.0.0.1:51821" PHANTUN_LOCAL
    read -rp "請輸入遠端 phantun 伺服器的 TCP 位址 (例如: your_server_ip:443): " -e PHANTUN_REMOTE

    if [ -z "$PHANTUN_REMOTE" ]; then
        error "遠端伺服器位址不能為空。"
    fi

    local CONFIG_FILE="$CONFIG_DIR/client.toml"
    local SERVICE_FILE="$SYSTEMD_DIR/phantun-client.service"

    log "正在建立設定目錄: $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"

    log "正在於 $CONFIG_FILE 建立 phantun 客戶端設定檔"
    cat > "$CONFIG_FILE" << EOF
# Phantun Client Configuration
# 由設定腳本產生

[client]
# 本地監聽的 UDP 位址，供 WireGuard 連線
local = "$PHANTUN_LOCAL"

# 遠端 phantun 伺服器的 TCP 位址
remote = "$PHANTUN_REMOTE"
EOF

    log "正在於 $SERVICE_FILE 建立 systemd 服務檔案"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Phantun Client
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/phantun -c $CONFIG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log "正在重新載入 systemd 並啟動 phantun-client 服務..."
    systemctl daemon-reload
    systemctl enable --now phantun-client.service

    log "Phantun 客戶端設定完成並已啟動。"
    warn "重要：請將您的 WireGuard 設定檔中的 'Endpoint' 修改為 '$PHANTUN_LOCAL'。"
}

# --- 主腳本 ---
main() {
    check_root
    check_prerequisites

    echo "--- Phantun 設定精靈 ---"
    echo "此腳本將引導您完成 phantun 的設定。"
    echo
    echo "請選擇設定類型:"
    echo "  1) 伺服器 (接收 TCP 流量並轉發為 UDP 給 WireGuard)"
    echo "  2) 客戶端 (接收來自 WireGuard 的 UDP 流量並以 TCP 傳送到伺服器)"
    
    local choice
    read -rp "請輸入選項 [1-2]: " choice

    case "$choice" in
        1)
            setup_server
            ;;
        2)
            setup_client
            ;;
        *)
            error "無效的選項。請輸入 1 或 2。"
            ;;
    esac

    echo
    log "🎉 Phantun 設定成功！"
    log "您可以使用 'systemctl status phantun-server' 或 'systemctl status phantun-client' 來檢查服務狀態。"
}

# 執行主函數
main
