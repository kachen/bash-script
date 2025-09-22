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
    echo "  --client-name <name>    要產生的客戶端名稱 (當客戶端數量為 1 時)"
    echo "  --client-ip <ip>        要產生的客戶端 IP (當客戶端數量為 1 時)"
    echo "  --server-name <name>    選擇要連線或是當前要設定的伺服器名稱"
    echo "  --add-clients           僅執行新增客戶端的步驟"
    echo "  --set-peer              僅執行新增可選的 WireGuard peer 和 phantun-client 服務的步驟"
    echo "  -h, --help              顯示此幫助訊息"
}

# 清理現有的 WireGuard 介面及其設定
cleanup_existing_interface() {
    local if_name="$1"
    log "正在清理現有的介面 '$if_name' 及其設定..."

    # 停止並禁用相關服務
    if systemctl is-active --quiet "wg-quick@${if_name}.service"; then
        log "正在停止 wg-quick@${if_name}.service..."
        systemctl stop "wg-quick@${if_name}.service"
    fi
    if systemctl is-enabled --quiet "wg-quick@${if_name}.service"; then
        log "正在禁用 wg-quick@${if_name}.service..."
        systemctl disable "wg-quick@${if_name}.service"
    fi

    if systemctl is-active --quiet "phantun-server@${if_name}.service"; then
        log "正在停止 phantun-server@${if_name}.service..."
        systemctl stop "phantun-server@${if_name}.service"
    fi
    if systemctl is-enabled --quiet "phantun-server@${if_name}.service"; then
        log "正在禁用 phantun-server@${if_name}.service..."
        systemctl disable "phantun-server@${if_name}.service"
    fi
    
    # 移除設定檔
    log "正在移除設定檔..."
    rm -f "/etc/wireguard/${if_name}.conf" "/etc/wireguard/${if_name}_private.key" "/etc/wireguard/${if_name}_public.key"
    rm -f "/etc/phantun/${if_name}.server"

    # 重新載入 systemd 以確保服務狀態更新
    systemctl daemon-reload

    log "清理完成。"
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
            read -rp "請輸入 Phantun 監聽的 TCP 埠 (建議 15004) [預設: 15004]: " -e -i "15004" PHANTUN_PORT < /dev/tty
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
            if [ -e "/sys/class/net/$WG_INTERFACE" ]; then
                warn "介面 '$WG_INTERFACE' 已存在。您是否要移除它並繼續設定？"
                warn "警告：這將會刪除所有與 '$WG_INTERFACE' 相關的設定檔和服務。"
                local choice
                read -rp "確定要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    cleanup_existing_interface "$WG_INTERFACE"
                    break
                else
                    warn "操作已取消。請選擇一個不同的介面名稱。"
                    WG_INTERFACE="" # 重置以便循環
                fi
            else
                break
            fi
        done
    else
        log "使用參數提供的 WireGuard 介面名稱: $WG_INTERFACE"
        if [ -e "/sys/class/net/$WG_INTERFACE" ]; then error "介面 '$WG_INTERFACE' 已存在。請使用互動模式來移除它，或指定一個不同的介面名稱。"; fi
    fi

    # --- WireGuard 內部 UDP 埠 ---
    if [ -z "$WG_PORT" ]; then
        while true; do
            read -rp "請輸入 WireGuard 內部監聽的 UDP 埠 [預設: 5004]: " -e -i "5004" WG_PORT < /dev/tty
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
    if [ -z "$WG_SUBNET" ]; then read -rp "請輸入 WireGuard 的虛擬網段 (CIDR) [預設: 10.21.12.1/24]: " -e -i "10.21.12.1/24" WG_SUBNET < /dev/tty; else log "使用參數提供的虛擬網段: $WG_SUBNET"; fi
    if [ -z "$CLIENT_DNS" ]; then read -rp "請輸入要提供給客戶端的 DNS 伺服器 [預設: 1.1.1.1]: " -e -i "1.1.1.1" CLIENT_DNS < /dev/tty; else log "使用參數提供的 DNS: $CLIENT_DNS"; fi
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
SaveConfig = true" > "$WG_DIR/$WG_INTERFACE.conf"

    # Phantun 設定
    local PHANTUN_DIR="/etc/phantun"
    mkdir -p "$PHANTUN_DIR"
    echo "--local $PHANTUN_PORT
--remote 127.0.0.1:$WG_PORT" > "$PHANTUN_DIR/$WG_INTERFACE.server"
}

# 載入現有伺服器設定以新增客戶端
load_existing_server_config() {
    log "--- 正在載入現有伺服器設定以新增客戶端 ---"
    local WG_DIR="/etc/wireguard"
    local PHANTUN_DIR="/etc/phantun"
    local SERVER_WG_CONF="$WG_DIR/$WG_INTERFACE.conf"
    local SERVER_PHANTUN_CONF="$PHANTUN_DIR/$WG_INTERFACE.server"
    local SERVER_PUBKEY_FILE="$WG_DIR/${WG_INTERFACE}_public.key"

    if ! [ -f "$SERVER_WG_CONF" ] || ! [ -f "$SERVER_PHANTUN_CONF" ] || ! [ -f "$SERVER_PUBKEY_FILE" ]; then
        error "找不到介面 '$WG_INTERFACE' 的現有設定檔。請確認 /etc/wireguard 和 /etc/phantun 中的檔案是否存在。"
    fi

    log "從設定檔讀取現有設定..."
    SERVER_PUBLIC_KEY=$(cat "$SERVER_PUBKEY_FILE")
    WG_SUBNET=$(grep -E '^\s*Address\s*=' "$SERVER_WG_CONF" | sed -E 's/^\s*Address\s*=\s*//' | xargs)
    WG_PORT=$(grep -E '^\s*ListenPort\s*=' "$SERVER_WG_CONF" | sed -E 's/^\s*ListenPort\s*=\s*//' | xargs)
    PHANTUN_PORT=$(awk '/--local/ {print $2}' "$SERVER_PHANTUN_CONF")

    log "已載入 WG 子網路: $WG_SUBNET, Phantun 埠: $PHANTUN_PORT"

    # 獲取執行此操作所需的其餘資訊
    if [ -z "$SERVER_PUBLIC_IP" ]; then local default_ip; default_ip=$(curl -s https://ipinfo.io/ip); read -rp "請確認伺服器公網 IP 位址 [預設: $default_ip]: " -e -i "$default_ip" SERVER_PUBLIC_IP < /dev/tty; fi
    if [ -z "$CLIENT_DNS" ]; then read -rp "請輸入要提供給客戶端的 DNS 伺服器 [預設: 1.1.1.1]: " -e -i "1.1.1.1" CLIENT_DNS < /dev/tty; fi
}

# 產生客戶端設定包
generate_client_packages() {
    echo
    local choice
    read -rp "是否要為每個客戶端產生設定包? [y/N]: " -e choice < /dev/tty
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        return
    fi

    if [ -z "$CLIENT_COUNT" ]; then read -rp "請輸入要產生的客戶端數量 [預設: 1]: " -e -i "1" CLIENT_COUNT < /dev/tty; else log "使用參數產生的客戶端數量: $CLIENT_COUNT"; fi

    # --- 驗證 ---
    if ! [[ "$CLIENT_COUNT" =~ ^[0-9]+$ ]] || [ "$CLIENT_COUNT" -lt 1 ]; then
        error "客戶端數量必須是一個大於 0 的整數。"
    fi

    local IP_BASE
    IP_BASE=$(echo "$WG_SUBNET" | cut -d '.' -f 1-3)
    local CLIENT_PACKAGE_DIR="/root/wireguard-confs"
    mkdir -p "$CLIENT_PACKAGE_DIR"

    # 從 WG_SUBNET (例如 10.21.12.1/24) 中提取伺服器的 IP 位址 (10.21.12.1)
    local SERVER_WG_IP
    SERVER_WG_IP=${WG_SUBNET%/*}

    # 找出目前已設定的最大客戶端 IP，以避免衝突
    local last_ip_octet
    # 從 'wg show' 的輸出中，提取 AllowedIPs (e.g., 10.21.12.2/32)，
    # 然後取出 IP 的最後一個八位位元組，並找到最大值。
    last_ip_octet=$(wg show "$WG_INTERFACE" allowed-ips | awk '{print $2}' | sed 's|/.*||' | cut -d. -f4 | sort -rn | head -n 1)
    if [ -z "$last_ip_octet" ]; then
        last_ip_octet=1 # 如果沒有現有客戶端，從 .2 開始
    fi

    for i in $(seq 1 "$CLIENT_COUNT"); do
        local client_num=$((last_ip_octet - 1 + i))
        local default_client_name="client${client_num}"
        local default_client_ip="${IP_BASE}.$((client_num + 1))"

        echo # 為每個客戶端增加空行以提高可讀性
        log "--- 正在設定新客戶端 ($i/$CLIENT_COUNT) ---"

        local CLIENT_NAME
        local CLIENT_IP

        # 如果 CLIENT_COUNT 為 1 且提供了參數，則使用它們
        if [ "$CLIENT_COUNT" -eq 1 ] && [ -n "$CLIENT_NAME_PARAM" ]; then
            CLIENT_NAME="$CLIENT_NAME_PARAM"
            log "使用參數提供的客戶端名稱: $CLIENT_NAME"
        else
            read -rp "請輸入客戶端名稱 [預設: $default_client_name]: " -e -i "$default_client_name" CLIENT_NAME < /dev/tty
        fi

        if [ "$CLIENT_COUNT" -eq 1 ] && [ -n "$CLIENT_IP_PARAM" ]; then
            CLIENT_IP="$CLIENT_IP_PARAM"
            log "使用參數提供的客戶端 IP: $CLIENT_IP"
        else
            read -rp "請輸入 '$CLIENT_NAME' 的 IP 位址 [預設: $default_client_ip]: " -e -i "$default_client_ip" CLIENT_IP < /dev/tty
        fi
        # --- 客戶端 Phantun UDP 埠 ---
        # 根據客戶端 IP 產生一個可預測的預設埠號
        # 例如: IP 10.21.12.2 -> Port 12002
        local third_octet
        third_octet=$(echo "$SERVER_WG_IP" | cut -d '.' -f 3)
        local fourth_octet
        fourth_octet=$(echo "$SERVER_WG_IP" | cut -d '.' -f 4)
        local default_client_phantun_port
        default_client_phantun_port=$(printf "%d%03d" "$third_octet" "$fourth_octet")

        read -rp "請輸入 '$CLIENT_NAME' 的 Phantun 本地 UDP 埠 [預設: $default_client_phantun_port]: " -e -i "$default_client_phantun_port" CURRENT_CLIENT_PHANTUN_PORT < /dev/tty
        # 建立客戶端目錄
        local CLIENT_DIR="$CLIENT_PACKAGE_DIR/$CLIENT_NAME"
        if [ -d "$CLIENT_DIR" ]; then
            warn "目錄 '$CLIENT_DIR' 已存在，將會覆蓋其中的檔案。"
        fi
        mkdir -p "$CLIENT_DIR"

        log "正在為 '$CLIENT_NAME' 於 '$CLIENT_DIR' 產生設定..."
        # 產生客戶端金鑰
        wg genkey | tee "$CLIENT_DIR/private.key" | wg pubkey > "$CLIENT_DIR/public.key"
        local CLIENT_PRIVATE_KEY=$(cat "$CLIENT_DIR/private.key")
        local CLIENT_PUBLIC_KEY=$(cat "$CLIENT_DIR/public.key")

        # 更新 WireGuard 伺服器設定
        wg set "$WG_INTERFACE" peer "$CLIENT_PUBLIC_KEY" allowed-ips "$CLIENT_IP/32"

        # 建立客戶端 WireGuard 設定檔
        echo "[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = $CLIENT_DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = 127.0.0.1:$CURRENT_CLIENT_PHANTUN_PORT
AllowedIPs = $SERVER_WG_IP/32
PersistentKeepalive = 25" > "$CLIENT_DIR/wg0.conf"

        # 建立客戶端 Phantun 設定檔
        echo "--local $CURRENT_CLIENT_PHANTUN_PORT
--remote $SERVER_PUBLIC_IP:$PHANTUN_PORT" > "$CLIENT_DIR/phantun.client"

        # 產生 QR Code
        qrencode -t ANSIUTF8 -o "$CLIENT_DIR/wg0.png" < "$CLIENT_DIR/wg0.conf"
        
        local copy_choice
        read -rp "是否要立即將 '$CLIENT_NAME' 的設定檔拷貝到遠端設備? [y/N]: " -e copy_choice < /dev/tty
        if [[ "$copy_choice" =~ ^[Yy]$ ]]; then
            # 使用 local 變數以避免意外修改全域變數
            local current_remote_user_host="$REMOTE_USER_HOST"
            if [ -z "$current_remote_user_host" ]; then
                read -rp "請輸入遠端設備的使用者和 IP (例如: user@192.168.1.100): " -e current_remote_user_host < /dev/tty
            else
                log "使用參數提供的遠端使用者和主機: $current_remote_user_host"
            fi

            local current_server_name="$SERVER_NAME"
            if [ -z "$current_server_name" ]; then
                read -rp "選擇要設定的伺服器名稱 (對應 /root/wireguard-peers/ 下的資料夾名稱) [預設: server1]: " -e -i "server1" current_server_name < /dev/tty
            else
                log "使用參數提供的伺服器名稱: $current_server_name"
            fi

            if [ -n "$current_remote_user_host" ] && [ -n "$current_server_name" ]; then
                local remote_path="/root/wireguard-peers/${current_server_name}"
                log "正在嘗試將設定檔拷貝到 ${current_remote_user_host}:${remote_path}..."
                
                # 嘗試建立遠端目錄並拷貝檔案
                if ssh "${current_remote_user_host}" "mkdir -p '${remote_path}'" && \
                   scp -r "${CLIENT_DIR}/*" "${current_remote_user_host}:${remote_path}/"; then
                    log "✅ 檔案成功拷貝到遠端設備。"
                else
                    warn "自動拷貝檔案失敗。這可能是因為需要密碼認證或 SSH 金鑰未設定。"
                    warn "請在遠端設備上手動執行以下指令來完成設定："
                    warn "ssh ${current_remote_user_host} \"mkdir -p '${remote_path}'\""
                    warn "scp -r \"${CLIENT_DIR}/\" \"${current_remote_user_host}:${remote_path}/\""
                fi
            fi
        fi

    done
    
    wg-quick save "$WG_INTERFACE"
    echo
    log "所有客戶端設定包已產生於 $CLIENT_PACKAGE_DIR"
    log "每個客戶端資料夾 (例如 client1) 包含："
    log "  - wg0.conf: WireGuard 設定檔，匯入到客戶端 App。"
    log "  - wg0.png: WireGuard 設定的 QR Code，可用手機 App 掃描。"
    log "  - phantun.client: Phantun 設定檔，匯入到客戶端 App。"
    warn "請將每個 client 資料夾安全地傳輸到對應的客戶端設備。"
}

# 建立並啟用服務
setup_services() {
    log "正在建立並啟用 systemd 服務..."
    # Phantun 服務
    log "正在於 /etc/systemd/system/phantun-server@.service 建立服務檔案"
    cat > /etc/systemd/system/phantun-server@.service << "EOF"
[Unit]
Description=Phantun Server
After=network.target
Wants=wg-quick@$WG_INTERFACE.service

[Service]
User=root
ExecStartPre=/usr/sbin/iptables -t nat -A PREROUTING -p tcp -i eth0 --dport 15004 -j DNAT --to-destination 192.168.201.2
ExecStart=/usr/local/bin/phantun_server $(for i in $(cat /etc/phantun/%i.server); do tmp="$tmp $i"; done; echo $tmp)
ExecStopPost=/usr/sbin/iptables -t nat -D PREROUTING -p tcp -i eth0 --dport 15004 -j DNAT --to-destination 192.168.201.2
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log "正在於 /etc/systemd/system/phantun-client@.service 建立服務檔案"
    cat > "/etc/systemd/system/phantun-client@.service" << "EOF"
[Unit]
Description=Phantun Client (Optional)
After=network.target

[Service]
Type=simple
User=root
ExecStartPre=/usr/sbin/iptables -t nat -A POSTROUTING -s 192.168.200.0/30 -j MASQUERADE
ExecStart=/usr/local/bin/phantun_client $(for i in $(cat /etc/phantun/%i.client); do tmp="$tmp $i"; done; echo $tmp)
ExecStopPost=/usr/sbin/iptables -t nat -D POSTROUTING -s 192.168.200.0/30 -j MASQUERADE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    # 重新載入並啟動
    systemctl daemon-reload
    systemctl enable --now "wg-quick@$WG_INTERFACE.service"
    systemctl enable --now phantun-server@$WG_INTERFACE.service
    log "WireGuard 和 Phantun 服務已啟動並設定為開機自啟。"
}

# 建立可選的 WireGuard peer 和 phantun_client 服務
setup_peer_client_service() {
    echo
    local choice
    read -rp "是否要在此伺服器上建立一個 phantun_client 服務用於 WireGuard Peer 串接? [y/N]: " -e choice < /dev/tty
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        return
    fi

    log "--- 開始設定 Phantun Client 服務 ---"
    if [ -z "$SERVER_NAME" ]; then
        read -rp "選擇要連線的伺服器名稱 (對應 /root/wireguard-peers/ 下的資料夾名稱) [預設: server1]: " -e -i "server1" SERVER_NAME < /dev/tty
    else
        log "使用參數提供的伺服器名稱: $SERVER_NAME"
    fi

    local SERVER_DIR="/root/wireguard-peers/$SERVER_NAME"
    local WG_CONF_PATH="$SERVER_DIR/wg0.conf"
    local PHANTUN_CONF_PATH="$SERVER_DIR/phantun.client"
    local use_existing_config=false

    if [ -f "$WG_CONF_PATH" ] && [ -f "$PHANTUN_CONF_PATH" ]; then
        local use_existing_choice
        read -rp "在 $SERVER_DIR 中找到現有的設定檔，是否直接使用它們來設定此伺服器上的 client 服務? [Y/n]: " -e -i "Y" use_existing_choice < /dev/tty
        if [[ "$use_existing_choice" =~ ^[Yy]$ ]]; then
            use_existing_config=true
        fi
    fi

    if [ "$use_existing_config" = true ]; then
        log "正在使用 $SERVER_DIR 中的設定檔自動設定..."

        # 1. 設定 Phantun Client
        log "正在複製 Phantun Client 設定檔至 /etc/phantun/$SERVER_NAME.client"
        mkdir -p /etc/phantun
        cp "$PHANTUN_CONF_PATH" "/etc/phantun/$SERVER_NAME.client"
        
        # 2. 設定 WireGuard Peer
        log "正在從 $WG_CONF_PATH 讀取客戶端資訊並新增至伺服器..."
        # 從客戶端設定檔中解析出公鑰、IP 位址和 Endpoint
        local CLIENT_PUBLIC_KEY
        CLIENT_PUBLIC_KEY=$(wg pubkey < "$SERVER_DIR/private.key")
        local CLIENT_ALLOWED_IPS
        # 從客戶端設定檔的 [Peer] 區塊中直接讀取 AllowedIPs 的值
        CLIENT_ALLOWED_IPS=$(grep -E '^\s*AllowedIPs\s*=' "$WG_CONF_PATH" | sed -E 's/^\s*AllowedIPs\s*=\s*//' | xargs)
        local CLIENT_ENDPOINT
        CLIENT_ENDPOINT=$(grep -E '^\s*Endpoint\s*=' "$WG_CONF_PATH" | sed -E 's/^\s*Endpoint\s*=\s*//' | xargs)

        if [ -n "$CLIENT_PUBLIC_KEY" ] && [ -n "$CLIENT_ALLOWED_IPS" ] && [ -n "$CLIENT_ENDPOINT" ]; then
            log "找到客戶端公鑰: $CLIENT_PUBLIC_KEY"
            log "找到客戶端 AllowedIPs: $CLIENT_ALLOWED_IPS"
            log "找到客戶端 Endpoint: $CLIENT_ENDPOINT"
            # 設定 peer，包含 Endpoint，這樣伺服器就知道要透過本地 phantun client 將流量轉發出去
            wg set "$WG_INTERFACE" peer "$CLIENT_PUBLIC_KEY" \
                allowed-ips "$CLIENT_ALLOWED_IPS" \
                endpoint "$CLIENT_ENDPOINT"
            log "已將 '$SERVER_NAME' 作為 peer 新增至 '$WG_INTERFACE' 介面。"
        else
            warn "無法從 '$SERVER_DIR' 的設定檔中解析出完整的客戶端資訊 (公鑰、AllowedIPs、Endpoint)，跳過新增 Peer。"
        fi

        # 3. 啟動 phantun 客戶端服務
        log "正在重新載入 systemd 並啟動服務..."
        systemctl daemon-reload
        systemctl enable --now "phantun-client@$SERVER_NAME.service"

        log "使用現有設定檔設定 Phantun 和 WireGuard 客戶端服務完成。"
        log "服務 'phantun-client@$SERVER_NAME.service' 已啟動。"
    else
        if [ -f "$WG_CONF_PATH" ]; then
            warn "找到了設定檔，但您選擇了手動設定。"
        else
            warn "找不到設定檔，進入手動設定。"
        fi
        log "--- 正在手動設定 Phantun Client 服務 ---"
        local PHANTUN_REMOTE_SERVER=""
        while [ -z "$PHANTUN_REMOTE_SERVER" ]; do
            read -rp "請輸入 phantun_client 要連線的遠端伺服器位址 (例如: other_server_ip:443): " -e PHANTUN_REMOTE_SERVER < /dev/tty
        done

        local PHANTUN_CLIENT_LOCAL_PORT
        while true; do
            read -rp "請輸入 phantun_client 本地監聽的 UDP 埠 [預設: 51831]: " -e -i "51831" PHANTUN_CLIENT_LOCAL_PORT < /dev/tty
            if ! ss -lnu | grep -q ":$PHANTUN_CLIENT_LOCAL_PORT\b"; then break; fi
            warn "UDP 埠 $PHANTUN_CLIENT_LOCAL_PORT 已被佔用，請選擇其他埠。"
        done

        log "正在於 /etc/phantun/$SERVER_NAME.client 建立客戶端設定檔"
        echo "--local $PHANTUN_CLIENT_LOCAL_PORT
--remote $PHANTUN_REMOTE_SERVER" > "/etc/phantun/$SERVER_NAME.client"

        log "正在重新載入 systemd 並啟動 phantun-client@$SERVER_NAME.service..."
        systemctl daemon-reload
        systemctl enable --now "phantun-client@$SERVER_NAME.service"

        log "手動設定的 Phantun Client 服務已啟動。"
        warn "此服務會將本地 127.0.0.1:$PHANTUN_CLIENT_LOCAL_PORT 的 UDP 流量轉發到 $PHANTUN_REMOTE_SERVER。"
        warn "您需要手動設定對應的 WireGuard 介面才能使用此連線。"
    fi
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
    CLIENT_NAME_PARAM=""
    CLIENT_IP_PARAM=""
    CLIENT_PHANTUN_PORT=""
    SERVER_NAME=""
    REMOTE_USER_HOST=""
    SET_PEER_SERVICE_ONLY=false
    ADD_CLIENTS_ONLY=false

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
            --client-name) CLIENT_NAME_PARAM="$2"; shift 2 ;;
            --client-ip) CLIENT_IP_PARAM="$2"; shift 2 ;;
            --server-name) SERVER_NAME="$2"; shift 2 ;;
            --remote-user-host) REMOTE_USER_HOST="$2"; shift 2 ;;
            --add-clients) ADD_CLIENTS_ONLY=true; shift 1 ;;
            --set-peer) SET_PEER_SERVICE_ONLY=true; shift 1 ;;
            -h|--help) usage; exit 0 ;;
            *) error "未知選項: $1" ;;
        esac
    done

    if [ "$SET_PEER_SERVICE_ONLY" = true ]; then
        log "--- 僅執行新增 phantun-client 服務 ---"
        if [ -z "$WG_INTERFACE" ]; then
            read -rp "請輸入要操作的 WireGuard 介面名稱 (例如 wg0): " -e WG_INTERFACE < /dev/tty
        fi
        if [ -z "$WG_INTERFACE" ]; then error "必須提供 WireGuard 介面名稱。"; fi
        setup_peer_client_service
        exit 0
    fi

    if [ "$ADD_CLIENTS_ONLY" = true ]; then
        log "--- 僅執行新增客戶端 ---"
        if [ -z "$WG_INTERFACE" ]; then
            read -rp "請輸入要新增客戶端的 WireGuard 介面名稱 (例如 wg0): " -e WG_INTERFACE < /dev/tty
        fi
        if [ -z "$WG_INTERFACE" ]; then error "必須提供 WireGuard 介面名稱。"; fi
        load_existing_server_config
        generate_client_packages
        log "✅ 新客戶端新增完成。"
        exit 0
    fi

    detect_distro
    install_dependencies
    install_phantun
    get_user_input
    setup_ip_forwarding
    #setup_firewall
    generate_server_configs
    setup_services # 必須在產生客戶端之前啟動 wg0，以便使用 `wg set`
    generate_client_packages
    setup_peer_client_service

    echo
    log "🎉 設定完成！"
}

# 執行主函數
main "$@"
