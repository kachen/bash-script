#!/bin/bash

# =================================================================
#         WireGuard Server Setup Script for Linux
# =================================================================
#
# 這個腳本會自動化設定一個 WireGuard VPN 伺服器，包括：
# 1. 產生伺服器金鑰
# 2. 建立伺服器設定檔
# 3. 設定 IP 轉發 (IP Forwarding)
# 4. 設定防火牆規則 (iptables)
# 5. 產生客戶端設定檔
#
# 執行前，請確保已使用 'install_wireguard.sh' 或手動安裝了 WireGuard。
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

# 檢查必要指令
check_prerequisites() {
    if ! command -v wg &> /dev/null || ! command -v wg-quick &> /dev/null; then
        error "找不到 'wg' 或 'wg-quick' 指令。請先執行安裝腳本或手動安裝 WireGuard。"
    fi
    log "必要指令已找到。"
}

# 獲取使用者輸入
get_user_input() {
    # 自動偵測公網 IP 和網路介面
    SERVER_PUBLIC_IP=$(curl -s https://ipinfo.io/ip)
    SERVER_NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

    read -rp "請輸入伺服器公網 IP 位址 [預設: $SERVER_PUBLIC_IP]: " -e -i "$SERVER_PUBLIC_IP" SERVER_PUBLIC_IP
    read -rp "請輸入伺服器公網網路介面 [預設: $SERVER_NIC]: " -e -i "$SERVER_NIC" SERVER_NIC
    read -rp "請輸入 WireGuard 的監聽埠 (Port) [預設: 51820]: " -e -i "51820" WG_PORT
    read -rp "請輸入 WireGuard 的虛擬網段 (CIDR) [預設: 10.8.0.1/24]: " -e -i "10.8.0.1/24" WG_SUBNET
    read -rp "請輸入要提供給客戶端的 DNS 伺服器 [預設: 1.1.1.1]: " -e -i "1.1.1.1" CLIENT_DNS
    read -rp "請輸入要產生的客戶端數量 [預設: 1]: " -e -i "1" CLIENT_COUNT

    # 驗證客戶端數量是否為數字
    if ! [[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] || [ "$CLIENT_COUNT" -lt 1 ]; then
        error "客戶端數量必須是一個大於 0 的整數。"
    fi
}

# 設定 IP 轉發
setup_ip_forwarding() {
    log "正在啟用 IPv4 轉發..."
    # 使用 sed 取消註解或新增 net.ipv4.ip_forward=1
    if grep -q "^#\?net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        sed -i 's/^#\?net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    # 立即生效
    sysctl -p
    log "IPv4 轉發已啟用。"
}

# 設定防火牆
setup_firewall() {
    log "正在設定防火牆規則 (iptables)..."
    local WG_INTERFACE="wg0" # WireGuard 介面名稱固定為 wg0

    # 新增規則
    iptables -A INPUT -p udp --dport "$WG_PORT" -j ACCEPT
    iptables -A FORWARD -i "$WG_INTERFACE" -j ACCEPT
    iptables -t nat -A POSTROUTING -o "$SERVER_NIC" -j MASQUERADE

    log "防火牆規則已新增。"
    warn "這些 iptables 規則在重啟後會遺失。"
    warn "請安裝 'iptables-persistent' (Debian/Ubuntu) 或 'iptables-services' (CentOS/RHEL) 來保存規則。"
    warn "例如，在 Debian/Ubuntu 上執行: sudo apt-get install -y iptables-persistent"
}

# 產生設定檔
generate_configs() {
    local WG_DIR="/etc/wireguard"
    local WG_INTERFACE="wg0"
    local SERVER_CONFIG_FILE="$WG_DIR/$WG_INTERFACE.conf"

    log "正在於 $WG_DIR 中產生金鑰與設定檔..."
    mkdir -p "$WG_DIR"
    cd "$WG_DIR"

    # 1. 產生伺服器金鑰
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    chmod 600 server_private.key
    local SERVER_PRIVATE_KEY
    SERVER_PRIVATE_KEY=$(cat server_private.key)
    local SERVER_PUBLIC_KEY
    SERVER_PUBLIC_KEY=$(cat server_public.key)

    # 2. 建立伺服器設定檔
    echo "[Interface]
Address = $WG_SUBNET
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY
SaveConfig = false # 避免 wg-quick 自動修改
" > "$SERVER_CONFIG_FILE"

    # 3. 產生客戶端設定檔並更新伺服器設定
    # 從子網路中提取網路位址部分，例如 10.8.0.
    local IP_BASE
    IP_BASE=$(echo "$WG_SUBNET" | cut -d '.' -f 1-3)

    for i in $(seq 1 "$CLIENT_COUNT"); do
        local CLIENT_NAME="client$i"
        local CLIENT_IP="${IP_BASE}.$((i + 1))"

        log "正在產生 ${CLIENT_NAME} 的設定..."

        # 產生客戶端金鑰
        wg genkey | tee "${CLIENT_NAME}_private.key" | wg pubkey > "${CLIENT_NAME}_public.key"
        chmod 600 "${CLIENT_NAME}_private.key"
        local CLIENT_PRIVATE_KEY
        CLIENT_PRIVATE_KEY=$(cat "${CLIENT_NAME}_private.key")
        local CLIENT_PUBLIC_KEY
        CLIENT_PUBLIC_KEY=$(cat "${CLIENT_NAME}_public.key")

        # 新增 Peer 到伺服器設定檔
        echo "
# Client: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = ${CLIENT_IP}/32
" >> "$SERVER_CONFIG_FILE"

        # 建立客戶端設定檔
        echo "[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = ${CLIENT_IP}/24
DNS = $CLIENT_DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
" > "${WG_DIR}/${CLIENT_NAME}.conf"
    done

    log "所有設定檔產生完畢。"
}

# 啟動並啟用服務
start_service() {
    local WG_INTERFACE="wg0"
    log "正在啟動 WireGuard 服務 (wg-quick@$WG_INTERFACE)..."
    wg-quick up "$WG_INTERFACE"

    log "正在設定開機自動啟動..."
    systemctl enable "wg-quick@$WG_INTERFACE"

    log "服務已啟動並設定為開機自啟。"
}

# --- 主腳本 ---
main() {
    check_root
    check_prerequisites

    echo "--- WireGuard 伺服器設定精靈 ---"
    echo "此腳本將引導您完成設定。請按 Enter 使用預設值。"
    echo

    get_user_input
    setup_ip_forwarding
    setup_firewall
    generate_configs
    start_service

    echo
    log "🎉 WireGuard 伺服器設定完成！"
    log "客戶端設定檔位於 /etc/wireguard/client*.conf"
    log "請將這些 .conf 檔案安全地傳輸到您的客戶端設備上。"
    log "您可以使用 'wg show' 指令來查看目前的連線狀態。"
}

# 執行主函數
main
