#!/bin/bash

# =================================================================
#    All-in-One WireGuard + Phantun Server Setup Script for Linux
# =================================================================
#
# 這個腳本會自動化安裝與設定一個整合了 Phantun 的 WireGuard VPN 伺服器。
# Phantun 用於將 WireGuard 的 UDP 流量偽裝成 TCP 流量，以繞過網路限制。
#
# 腳本功能:
# 1. 自動偵測發行版並安裝 WireGuard, Phantun, qrencode。
# 2. 設定 IP 轉發與防火牆 (iptables)。
# 3. 產生 WireGuard 和 Phantun 的伺服器設定。
# 4. 建立並啟用 systemd 服務。
# 5. 為客戶端產生包含 WireGuard 設定、Phantun 設定和 QR Code 的設定包。
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

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# 顯示用法/幫助訊息
usage() {
    echo "用法: $0 [選項]"
    echo
    echo "這個腳本會設定一個 WireGuard + Phantun 伺服器。"
    echo "如果未提供選項，將會以互動模式詢問所有設定值。"
    echo
    echo "選項:"
    echo "  --public-ip <ip>        伺服器公網 IP 位址"
    echo "  --nic <interface>       伺服器公網網路介面"
    echo "  --phantun-port <port>   Phantun 監聽的 TCP 埠"
    echo "  --wg-interface <name>   WireGuard 介面名稱 (例如 wg0)"
    echo "  --wg-port <port>        WireGuard 監聽的 UDP 埠"
    echo "  --wg-subnet <cidr>      WireGuard 的虛擬網段"
    echo "  --dns <ip>              提供給客戶端的 DNS 伺服器"
    echo "  --clients <count>       要產生的客戶端數量"
    echo "  --client-phantun-port <port> 客戶端 Phantun 監聽的本地 UDP 埠"
    echo "  -h, --help              顯示此幫助訊息"
}

# 檢查 root 權限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此腳本必須以 root 權限執行。請使用 'sudo'。"
    fi
}

# 偵測 Linux 發行版
detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        error "無法偵測到您的 Linux 發行版。"
    fi
    log "偵測到作業系統: $OS, 版本: $VER"
}

# 安裝相依套件
install_dependencies() {
    log "正在安裝必要的相依套件 (curl, unzip, qrencode)..."
    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y curl unzip qrencode wireguard resolvconf
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &> /dev/null; then
                dnf install -y epel-release
                dnf install -y curl unzip qrencode wireguard-tools
            else # CentOS 7
                yum install -y epel-release
                yum install -y curl unzip qrencode
                yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm
                yum install -y kmod-wireguard wireguard-tools
            fi
            ;;
        fedora)
            dnf install -y curl unzip qrencode wireguard-tools
            ;;
        arch)
            pacman -Syu --noconfirm curl unzip qrencode wireguard-tools
            ;;
        *)
            error "不支援的作業系統: $OS。請手動安裝 curl, unzip, qrencode, wireguard-tools。"
            ;;
    esac
    log "相依套件安裝完成。"
}

# 安裝 Phantun
install_phantun() {
    if command -v phantun_server &> /dev/null && command -v phantun_client &> /dev/null; then
        log "Phantun 伺服器與客戶端二進位檔案已存在，跳過安裝步驟。"
        return
    fi
    log "正在安裝 Phantun..."
    local ARCH
    ARCH=$(uname -m)
    local PHANTUN_ARCH
    case "$ARCH" in
        x86_64) PHANTUN_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64) PHANTUN_ARCH="aarch64-unknown-linux-musl" ;;
        armv7l) PHANTUN_ARCH="armv7-unknown-linux-musleabihf" ;;
        *) error "不支援的系統架構: $ARCH" ;;
    esac

    local DOWNLOAD_URL
    DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/dndx/phantun/releases/latest" | grep "browser_download_url" | grep "$PHANTUN_ARCH" | cut -d '"' -f 4)
    if [ -z "$DOWNLOAD_URL" ]; then
        error "無法找到適用於 '$PHANTUN_ARCH' 架構的 Phantun 下載連結。"
    fi

    local FILENAME
    FILENAME=$(basename "$DOWNLOAD_URL")
    local DOWNLOAD_PATH="/tmp/$FILENAME"

    log "正在下載 $FILENAME..."
    curl -L -o "$DOWNLOAD_PATH" "$DOWNLOAD_URL"
    log "正在解壓縮檔案..."
    unzip -o "$DOWNLOAD_PATH" -d /tmp
    log "正在安裝 phantun_server 和 phantun_client..."
    install -m 755 "/tmp/phantun_server" /usr/local/bin/phantun_server
    install -m 755 "/tmp/phantun_client" /usr/local/bin/phantun_client
    rm -f "$DOWNLOAD_PATH" "/tmp/phantun_server" "/tmp/phantun_client"
    log "Phantun 安裝成功。"
}

# 獲取使用者輸入
get_user_input() {
    log "--- 正在收集設定資訊 ---"
    
    # --- 伺服器公網 IP ---
    if [ -z "$SERVER_PUBLIC_IP" ]; then
        local default_ip
        default_ip=$(curl -s https://ipinfo.io/ip)
        read -rp "請輸入伺服器公網 IP 位址 [預設: $default_ip]: " -e -i "$default_ip" SERVER_PUBLIC_IP < /dev/tty
    else
        log "使用參數提供的公網 IP: $SERVER_PUBLIC_IP"
    fi

    # --- 伺服器公網網路介面 ---
    if [ -z "$SERVER_NIC" ]; then
        local default_nic
        default_nic=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
        read -rp "請輸入伺服器公網網路介面 [預設: $default_nic]: " -e -i "$default_nic" SERVER_NIC < /dev/tty
    else
        log "使用參數提供的網路介面: $SERVER_NIC"
    fi

    # --- Phantun TCP 埠 ---
    if [ -z "$PHANTUN_PORT" ]; then
        while true; do
            read -rp "請輸入 Phantun 監聽的 TCP 埠 (建議 443) [預設: 443]: " -e -i "443" PHANTUN_PORT < /dev/tty
            if ss -lnt | grep -q ":$PHANTUN_PORT\b"; then
                warn "TCP 埠 $PHANTUN_PORT 已被佔用，請選擇其他埠。"
                PHANTUN_PORT="" # 重置以便循環
            else
                break
            fi
        done
    else
        log "使用參數提供的 Phantun TCP 埠: $PHANTUN_PORT"
        if ss -lnt | grep -q ":$PHANTUN_PORT\b"; then error "TCP 埠 $PHANTUN_PORT 已被佔用。"; fi
    fi

    # --- WireGuard 介面名稱 ---
    if [ -z "$WG_INTERFACE" ]; then
        while true; do
            read -rp "請輸入 WireGuard 介面名稱 [預設: wg0]: " -e -i "wg0" WG_INTERFACE < /dev/tty
            if ip link show "$WG_INTERFACE" &>/dev/null; then
                warn "介面 '$WG_INTERFACE' 已存在，請選擇其他名稱。"
                WG_INTERFACE="" # 重置以便循環
            else
                break
            fi
        done
    else
        log "使用參數提供的 WireGuard 介面名稱: $WG_INTERFACE"
        if ip link show "$WG_INTERFACE" &>/dev/null; then error "介面 '$WG_INTERFACE' 已存在。"; fi
    fi

    # --- WireGuard 內部 UDP 埠 ---
    if [ -z "$WG_PORT" ]; then
        while true; do
            read -rp "請輸入 WireGuard 內部監聽的 UDP 埠 [預設: 51820]: " -e -i "51820" WG_PORT < /dev/tty
            if ss -lnu | grep -q ":$WG_PORT\b"; then
                warn "UDP 埠 $WG_PORT 已被佔用，請選擇其他埠。"
                WG_PORT="" # 重置以便循環
            else
                break
            fi
        done
    else
        log "使用參數提供的 WireGuard 內部 UDP 埠: $WG_PORT"
        if ss -lnu | grep -q ":$WG_PORT\b"; then error "UDP 埠 $WG_PORT 已被佔用。"; fi
    fi

    # --- 其他設定 ---
    if [ -z "$WG_SUBNET" ]; then read -rp "請輸入 WireGuard 的虛擬網段 (CIDR) [預設: 10.9.0.1/24]: " -e -i "10.9.0.1/24" WG_SUBNET < /dev/tty; else log "使用參數提供的虛擬網段: $WG_SUBNET"; fi
    if [ -z "$CLIENT_DNS" ]; then read -rp "請輸入要提供給客戶端的 DNS 伺服器 [預設: 1.1.1.1]: " -e -i "1.1.1.1" CLIENT_DNS < /dev/tty; else log "使用參數提供的 DNS: $CLIENT_DNS"; fi
    if [ -z "$CLIENT_COUNT" ]; then read -rp "請輸入要產生的客戶端數量 [預設: 1]: " -e -i "1" CLIENT_COUNT < /dev/tty; else log "使用參數產生的客戶端數量: $CLIENT_COUNT"; fi

    # --- 客戶端 Phantun UDP 埠 ---
    if [ -z "$CLIENT_PHANTUN_PORT" ]; then
        read -rp "請輸入客戶端 Phantun 監聽的本地 UDP 埠 [預設: 51821]: " -e -i "51821" CLIENT_PHANTUN_PORT < /dev/tty
    else
        log "使用參數提供的客戶端 Phantun UDP 埠: $CLIENT_PHANTUN_PORT"
    fi


    # --- 驗證 ---
    if ! [[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] || [ "$CLIENT_COUNT" -lt 1 ]; then
        error "客戶端數量必須是一個大於 0 的整數。"
    fi
}

# 設定 IP 轉發
setup_ip_forwarding() {
    log "正在啟用 IPv4 轉發..."
    if grep -q "^#\?net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        sed -i 's/^#\?net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p
}

# 設定防火牆
setup_firewall() {
    log "正在設定防火牆規則 (iptables)..."

    # 允許 Phantun 的 TCP 流量
    iptables -A INPUT -p tcp --dport "$PHANTUN_PORT" -j ACCEPT
    # 允許來自 WireGuard 客戶端的流量
    iptables -A FORWARD -i "$WG_INTERFACE" -j ACCEPT
    # 進行 NAT 轉換
    iptables -t nat -A POSTROUTING -o "$SERVER_NIC" -j MASQUERADE

    log "防火牆規則已新增。"
    warn "這些 iptables 規則在重啟後可能會遺失。建議安裝 'iptables-persistent' (Debian/Ubuntu) 或 'iptables-services' (CentOS/RHEL) 來保存規則。"
}

# 產生伺服器設定
generate_server_configs() {
    log "正在產生伺服器設定檔..."
    # WireGuard 設定
    local WG_DIR="/etc/wireguard"
    mkdir -p "$WG_DIR"
    cd "$WG_DIR"
    wg genkey | tee "$WG_INTERFACE"_private.key | wg pubkey > "$WG_INTERFACE"_public.key
    chmod 600 "$WG_INTERFACE"_private.key
    SERVER_PRIVATE_KEY=$(cat "$WG_INTERFACE"_private.key)
    SERVER_PUBLIC_KEY=$(cat "$WG_INTERFACE"_public.key)

    echo "[Interface]
Address = $WG_SUBNET
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY
SaveConfig = true
" > "$WG_DIR/$WG_INTERFACE.conf"

    # Phantun 設定
    local PHANTUN_DIR="/etc/phantun"
    mkdir -p "$PHANTUN_DIR"
    echo "[server]
listen = \"0.0.0.0:$PHANTUN_PORT\"
remote = \"127.0.0.1:$WG_PORT\"
" > "$PHANTUN_DIR/server.toml"
}

# 產生客戶端設定包
generate_client_packages() {
    echo
    local choice
    read -rp "是否要為每個客戶端產生設定包? [y/N]: " -e choice < /dev/tty
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        return
    fi

    log "正在為客戶端產生設定包..."
    local IP_BASE
    IP_BASE=$(echo "$WG_SUBNET" | cut -d '.' -f 1-3)
    local CLIENT_PACKAGE_DIR="/root/wireguard-clients"
    mkdir -p "$CLIENT_PACKAGE_DIR"

    for i in $(seq 1 "$CLIENT_COUNT"); do
        local CLIENT_NAME="client$i"
        local CLIENT_DIR="$CLIENT_PACKAGE_DIR/$CLIENT_NAME"
        mkdir -p "$CLIENT_DIR"

        log "正在處理 $CLIENT_NAME..."
        local CLIENT_IP="${IP_BASE}.$((i + 1))"
        
        # 產生客戶端金鑰
        wg genkey | tee "$CLIENT_DIR/private.key" | wg pubkey > "$CLIENT_DIR/public.key"
        local CLIENT_PRIVATE_KEY
        CLIENT_PRIVATE_KEY=$(cat "$CLIENT_DIR/private.key")
        local CLIENT_PUBLIC_KEY
        CLIENT_PUBLIC_KEY=$(cat "$CLIENT_DIR/public.key")

        # 更新 WireGuard 伺服器設定
        wg set "$WG_INTERFACE" peer "$CLIENT_PUBLIC_KEY" allowed-ips "$CLIENT_IP/32"

        # 建立客戶端 WireGuard 設定檔
        local WG_CLIENT_CONF="$CLIENT_DIR/wg0.conf"
        echo "[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = $CLIENT_DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = 127.0.0.1:$CLIENT_PHANTUN_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
" > "$WG_CLIENT_CONF"

        # 建立客戶端 Phantun 設定檔
        echo "[client]
local = \"127.0.0.1:$CLIENT_PHANTUN_PORT\"
remote = \"$SERVER_PUBLIC_IP:$PHANTUN_PORT\"
" > "$CLIENT_DIR/phantun.toml"

        # 產生 QR Code
        qrencode -t ANSIUTF8 -o "$CLIENT_DIR/wg0.png" < "$WG_CLIENT_CONF"
    done
    
    log "所有客戶端設定包已產生於 $CLIENT_PACKAGE_DIR"
    warn "請將每個 client 資料夾安全地傳輸到對應的客戶端設備。"
}

# 建立並啟用服務
setup_services() {
    log "正在建立並啟用 systemd 服務..."
    # Phantun 服務
    echo "[Unit]
Description=Phantun Server
After=network.target
Wants=wg-quick@$WG_INTERFACE.service

[Service]
User=root
ExecStart=/usr/local/bin/phantun_server -c /etc/phantun/server.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
" > /etc/systemd/system/phantun-server.service

    # 重新載入並啟動
    systemctl daemon-reload
    systemctl enable --now "wg-quick@$WG_INTERFACE.service"
    systemctl enable --now phantun-server.service
    log "WireGuard 和 Phantun 服務已啟動並設定為開機自啟。"
}

# 建立可選的 phantun_client 服務
setup_optional_client_service() {
    echo
    local choice
    read -rp "是否要在此伺服器上額外建立一個 phantun_client 服務 (用於測試或串接)? [y/N]: " -e choice < /dev/tty
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        return
    fi

    log "--- 正在設定可選的 Phantun Client 服務 ---"

    local PHANTUN_REMOTE_SERVER=""
    while [ -z "$PHANTUN_REMOTE_SERVER" ]; do
        read -rp "請輸入 phantun_client 要連線的遠端伺服器位址 (例如: other_server_ip:443): " -e PHANTUN_REMOTE_SERVER < /dev/tty
    done

    local PHANTUN_CLIENT_LOCAL_PORT
    while true; do
        read -rp "請輸入 phantun_client 本地監聽的 UDP 埠 [預設: 51831]: " -e -i "51831" PHANTUN_CLIENT_LOCAL_PORT < /dev/tty
        if ! ss -lnu | grep -q ":$PHANTUN_CLIENT_LOCAL_PORT\b"; then
            break
        fi
        warn "UDP 埠 $PHANTUN_CLIENT_LOCAL_PORT 已被佔用，請選擇其他埠。"
    done

    log "正在於 /etc/phantun/client.toml 建立客戶端設定檔"
    cat > "/etc/phantun/client.toml" << EOF
# Phantun Client Configuration (Optional service on server)
# 由設定腳本產生

[client]
local = "127.0.0.1:$PHANTUN_CLIENT_LOCAL_PORT"
remote = "$PHANTUN_REMOTE_SERVER"
EOF

    log "正在於 /etc/systemd/system/phantun-client.service 建立服務檔案"
    cat > "/etc/systemd/system/phantun-client.service" << EOF
[Unit]
Description=Phantun Client (Optional)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/phantun_client -c /etc/phantun/client.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log "正在重新載入 systemd 並啟動 phantun-client 服務..."
    systemctl daemon-reload
    systemctl enable --now phantun-client.service

    log "可選的 Phantun Client 服務設定完成並已啟動。"
    warn "此服務會將本地 127.0.0.1:$PHANTUN_CLIENT_LOCAL_PORT 的 UDP 流量轉發到 $PHANTUN_REMOTE_SERVER。"
}

# --- 主腳本 ---
main() {
    check_root

    # 初始化變數
    SERVER_PUBLIC_IP=""
    SERVER_NIC=""
    PHANTUN_PORT=""
    WG_INTERFACE=""
    WG_SUBNET=""
    CLIENT_DNS=""
    CLIENT_COUNT=""
    WG_PORT=""
    CLIENT_PHANTUN_PORT=""

    # 解析命令列參數
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --public-ip) SERVER_PUBLIC_IP="$2"; shift 2 ;;
            --nic) SERVER_NIC="$2"; shift 2 ;;
            --phantun-port) PHANTUN_PORT="$2"; shift 2 ;;
            --wg-interface) WG_INTERFACE="$2"; shift 2 ;;
            --wg-port) WG_PORT="$2"; shift 2 ;;
            --wg-subnet) WG_SUBNET="$2"; shift 2 ;;
            --dns) CLIENT_DNS="$2"; shift 2 ;;
            --clients) CLIENT_COUNT="$2"; shift 2 ;;
            --client-phantun-port) CLIENT_PHANTUN_PORT="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) error "未知選項: $1" ;;
        esac
    done

    detect_distro
    install_dependencies
    install_phantun
    get_user_input
    setup_ip_forwarding
    setup_firewall
    generate_server_configs
    setup_services # 必須在產生客戶端之前啟動 wg0，以便使用 `wg set`
    generate_client_packages
    setup_optional_client_service

    echo
    log "🎉 WireGuard + Phantun 伺服器設定完成！"
    echo
    log "客戶端設定包位於 /root/wireguard-clients/ 目錄下。"
    log "每個客戶端資料夾 (例如 client1) 包含："
    log "  - wg0.conf: WireGuard 設定檔，匯入到客戶端 App。"
    log "  - phantun.toml: Phantun 客戶端設定檔。"
    log "  - wg0.png: WireGuard 設定的 QR Code，可用手機 App 掃描。"
    echo
    warn "客戶端操作步驟："
    warn "1. 在客戶端安裝 WireGuard 和 Phantun (解壓縮後使用 phantun_client)。"
    warn "2. 使用 phantun.toml 啟動 Phantun 客戶端 (例如: ./phantun_client -c phantun.toml)。"
    warn "3. 匯入 wg0.conf 或掃描 QR Code 來設定 WireGuard 並連線。"
    echo
    log "您可以使用 'wg show' 和 'systemctl status phantun-server' 來檢查伺服器狀態。"
}

# 執行主函數
main "$@"
