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
    echo "  --nic <interface>               本機公網網路介面"
    echo "  --public-ip <ip>                本機公網 IP 位址"
    echo "  --phantun-port <port>           Phantun 監聽的 TCP 埠"
    echo "  --wg-interface <name>           WireGuard 介面名稱 (例如 wg0)"
    echo "  --wg-port <port>                WireGuard 監聽的 UDP 埠"
    echo "  --wg-subnet <cidr>              本機 WireGuard 的虛擬網段"
    echo "  --server-name <name>            遠端伺服器名稱"
    echo "  --server-wg-subnet <cidr>       遠端 WireGuard 的虛擬網段"
    echo "  --server-host <host>            遠端伺服器主機"
    echo "  --server-password <password>    遠端伺服器密碼，用於自動拷貝設定檔"
    echo "  --set-peer                      僅執行設定 WireGuard peer 和 phantun-client 服務的步驟"
    echo "  -h, --help                      顯示此幫助訊息"
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
    log "正在檢查並安裝必要的相依套件..."

    if command -v wg &> /dev/null; then
        log "WireGuard 已安裝，將跳過其安裝步驟。"
        local install_wg=false
    else
        log "正在準備安裝 WireGuard..."
        local install_wg=true
    fi

    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y curl unzip qrencode sshpass resolvconf
            if [ "$install_wg" = true ]; then apt-get install -y wireguard; fi
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &> /dev/null; then
                dnf install -y epel-release
                dnf install -y curl unzip qrencode sshpass
                if [ "$install_wg" = true ]; then dnf install -y wireguard-tools; fi
            else # CentOS 7
                yum install -y epel-release
                yum install -y curl unzip qrencode sshpass
                if [ "$install_wg" = true ]; then
                    yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm
                    yum install -y kmod-wireguard wireguard-tools
                fi
            fi
            ;;
        fedora)
            dnf install -y curl unzip qrencode sshpass
            if [ "$install_wg" = true ]; then dnf install -y wireguard-tools; fi
            ;;
        arch)
            pacman -Syu --noconfirm curl unzip qrencode sshpass
            if [ "$install_wg" = true ]; then pacman -S --noconfirm wireguard-tools; fi
            ;;
        *)
            error "不支援的作業系統: $OS。請手動安裝 curl, unzip, qrencode, sshpass, wireguard-tools。"
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
    if [ -z "$PUBLIC_IP" ]; then
        local default_ip
        default_ip=$(curl -s https://ipinfo.io/ip)
        read -rp "請輸入伺服器公網 IP 位址 [預設: $default_ip]: " -e -i "$default_ip" PUBLIC_IP < /dev/tty
    else
        log "使用參數提供的公網 IP: $PUBLIC_IP"
    fi

    # --- 伺服器公網網路介面 ---
    if [ -z "$NIC_PARAM" ]; then
        local default_nic
        default_nic=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
        read -rp "請輸入伺服器公網網路介面 [預設: $default_nic]: " -e -i "$default_nic" NIC_PARAM < /dev/tty
    else
        log "使用參數提供的網路介面: $NIC_PARAM"
    fi

    # --- Phantun TCP 埠 ---
    if [ -z "$PHANTUN_PORT" ]; then
        while true; do
            read -rp "請輸入 Phantun 監聽的 TCP 埠 (建議 15004) [預設: 15004]: " -e -i "15004" PHANTUN_PORT < /dev/tty
            if ss -lnt | grep -q ":$PHANTUN_PORT\b"; then
                warn "TCP 埠 $PHANTUN_PORT 似乎已被佔用。"
                local use_anyway
                read -rp "您確定要繼續使用此埠嗎？ (這可能會導致衝突) [y/N]: " -e use_anyway < /dev/tty
                if [[ "$use_anyway" =~ ^[Yy]$ ]]; then
                    warn "使用者選擇繼續使用可能被佔用的埠 $PHANTUN_PORT。"
                    break
                else
                    PHANTUN_PORT="" # 重置以便循環，要求新埠
                fi
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
                warn "介面 '$WG_INTERFACE' 已存在。您是否要移除它重新設定？"
                warn "警告：這將會刪除所有與 '$WG_INTERFACE' 相關的設定檔和服務。"
                local choice
                read -rp "確定要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    cleanup_existing_interface "$WG_INTERFACE"
                    break
                fi
            else
                break
            fi
        done
    else
        log "使用參數提供的 WireGuard 介面名稱: $WG_INTERFACE"
        if [ -e "/sys/class/net/$WG_INTERFACE" ]; then
            warn "參數指定的介面 '$WG_INTERFACE' 已存在。您是否要移除它重新設定？"
            warn "警告：這將會刪除所有與 '$WG_INTERFACE' 相關的設定檔和服務。"
            local choice
            read -rp "確定要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                cleanup_existing_interface "$WG_INTERFACE"
            fi
        fi
    fi

    SKIP_WIREGUARD_SETTING=false
    # --- WireGuard 內部 UDP 埠 ---
    if [ -z "$WG_PORT" ]; then
        while true; do
            read -rp "請輸入 WireGuard 內部監聽的 UDP 埠 [預設: 5004]: " -e -i "5004" WG_PORT < /dev/tty
            if ss -lnu | grep -q ":$WG_PORT\b"; then
                warn "UDP 埠 $WG_PORT 已被佔用，請選擇其他埠。"
                local choice
                read -rp "或是略過 WireGuard 的設定？ [N/y]: " -e choice < /dev/tty
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    SKIP_WIREGUARD_SETTING=true
                    break
                else
                    WG_PORT="" # 重置以便循環
                fi
            else
                break
            fi
        done
    fi

    # --- 其他設定 ---
    if [ -z "$WG_SUBNET" ]; then read -rp "請輸入 WireGuard 的虛擬網段 (CIDR) [預設: 10.21.12.1/24]: " -e -i "10.21.12.1/24" WG_SUBNET < /dev/tty; else log "使用參數提供的虛擬網段: $WG_SUBNET"; fi
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
    iptables -t nat -A POSTROUTING -o "$NIC_PARAM" -j MASQUERADE

    log "防火牆規則已新增。"
    warn "這些 iptables 規則在重啟後可能會遺失。建議安裝 'iptables-persistent' (Debian/Ubuntu) 或 'iptables-services' (CentOS/RHEL) 來保存規則。"
}

# 產生伺服器設定
generate_server_configs() {
    log "正在產生伺服器設定檔..."
    # WireGuard 設定

    local choice
    if [ "$SKIP_WIREGUARD_SETTING" = false ]; then
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
    fi

    # Phantun 設定
    local PHANTUN_DIR="/etc/phantun"
    mkdir -p "$PHANTUN_DIR"
    echo "--local $PHANTUN_PORT
--remote 127.0.0.1:$WG_PORT" > "$PHANTUN_DIR/$WG_INTERFACE.server"
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

[Service]
User=root
ExecStartPre=/usr/sbin/iptables -t nat -A PREROUTING -p tcp -i eth0 --dport 15004 -j DNAT --to-destination 192.168.201.2
ExecStart=/bin/bash -c '/usr/local/bin/phantun_server $(</etc/phantun/%i.server)'
ExecStopPost=/usr/sbin/iptables -t nat -D PREROUTING -p tcp -i eth0 --dport 15004 -j DNAT --to-destination 192.168.201.2
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log "正在於 /etc/systemd/system/phantun-client@.service 建立服務檔案"
    cat > "/etc/systemd/system/phantun-client@.service" << "EOF"
[Unit]
Description=Phantun Client
After=network.target

[Service]
Type=simple
User=root
ExecStartPre=/usr/sbin/iptables-restore --noflush /etc/phantun/%i_up.rules
ExecStart=/bin/bash -c '/usr/local/bin/phantun_client $(</etc/phantun/%i.client)'
ExecStopPost=/usr/sbin/iptables-restore --noflush /etc/phantun/%i_down.rules
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
        read -rp "選擇要連線的伺服器名稱 [預設: server1]: " -e -i "server1" SERVER_NAME < /dev/tty
    else
        log "使用參數提供的伺服器名稱: $SERVER_NAME"
    fi
    if [ -z "$SERVER_HOST" ]; then
        read -rp "輸入要連線的伺服器HOST: " -e SERVER_HOST < /dev/tty
    else
        log "使用參數提供的伺服器HOST: $SERVER_HOST"
    fi
    if [ -z "$SERVER_WG_SUBNET" ]; then
        read -rp "輸入遠端伺服器 WireGaurd 內網 [預設: 10.21.12.1/24]: " -e -i "10.21.12.1/24" SERVER_WG_SUBNET < /dev/tty
    else
        log "使用參數提供的遠端伺服器 WireGaurd 內網: $SERVER_WG_SUBNET"
    fi
    if [ -z "$WG_SUBNET" ]; then
        read -rp "輸入本機伺服器 WireGaurd 內網 [預設: 10.21.12.1/24]: " -e -i "10.21.12.1/24" WG_SUBNET < /dev/tty
    else
        log "使用參數提供的本機伺服器 WireGaurd 內網: $WG_SUBNET"
    fi

    # 從 WG_SUBNET (例如 10.21.12.1/24) 中提取伺服器的 IP 位址 (10.21.12.1)
    local SERVER_WG_IP
    SERVER_WG_IP=${SERVER_WG_SUBNET%/*}

    local overwrite_existing_config=true
    local PHANTUN_DIR="/etc/phantun"
    local PHANTUN_CONF_PATH="$PHANTUN_DIR/$SERVER_NAME.client"
    local PHANTUN_RULE_UP_PATH="$PHANTUN_DIR/${SERVER_NAME}_up.rules"
    local PHANTUN_RULE_DOWN_PATH="$PHANTUN_DIR/${SERVER_NAME}_down.rules"
    local PHANTUN_CLIENT_LOCAL_PORT

    if [ -f "$PHANTUN_CONF_PATH" ]; then
        local use_existing_choice
        read -rp "在 $PHANTUN_CONF_PATH 中找到現有的設定檔，是否覆蓋? [y/N]: " -e -i "" use_existing_choice < /dev/tty
        if [[ "$use_existing_choice" =~ ^[Yy]$ ]]; then
            if systemctl is-active --quiet "phantun-client@${SERVER_NAME}.service"; then
                log "正在停止 phantun-client@${SERVER_NAME}.service..."
                systemctl stop "phantun-client@${SERVER_NAME}.service"
            fi
            if systemctl is-enabled --quiet "phantun-client@${SERVER_NAME}.service"; then
                log "正在禁用 phantun-client@${SERVER_NAME}.service..."
                systemctl disable "phantun-client@${SERVER_NAME}.service"
            fi
        else
            overwrite_existing_config=false
            PHANTUN_CLIENT_LOCAL_PORT=$(grep -oP '127\.0\.0\.1:\K[0-9]+' "$PHANTUN_CONF_PATH")
        fi
    fi

    if [ "$overwrite_existing_config" = true ]; then
        # --- 客戶端 Phantun UDP 埠 ---
        # 根據伺服端 WG IP 產生一個可預測的預設埠號
        # 例如: IP 10.21.12.2 -> Port 12002
        local third_octet
        third_octet=$(echo "$SERVER_WG_IP" | cut -d '.' -f 3)
        local fourth_octet
        fourth_octet=$(echo "$SERVER_WG_IP" | cut -d '.' -f 4)
        local default_client_phantun_port
        default_client_phantun_port=$(printf "%d%03d" "$third_octet" "$fourth_octet")
        local default_tun_subnet
        local default_tun_local_ip
        local default_tun_peer_ip
        default_tun_subnet="192.168.200.0/30"
        default_tun_local_ip="192.168.200.1"
        default_tun_peer_ip="192.168.200.2"

        while true; do
            read -rp "請輸入連接 '$SERVER_NAME' 的 phantun_client 在本地監聽的 UDP 埠 [預設: $default_client_phantun_port]: " -e -i "$default_client_phantun_port" PHANTUN_CLIENT_LOCAL_PORT < /dev/tty
            if ! ss -lnu | grep -q ":$PHANTUN_CLIENT_LOCAL_PORT\b"; then break; fi
            warn "UDP 埠 $PHANTUN_CLIENT_LOCAL_PORT 已被佔用，請選擇其他埠。"
        done

        max_last=-1

        for f in "$PHANTUN_DIR"/*.client; do
            [[ -e "$f" ]] || continue
            ip=$(awk '/^--tun-local[[:space:]]+/ {print $2; exit}' "$f" 2>/dev/null || true)
            [[ -n "${ip:-}" ]] || continue

            IFS=. read -r o1 o2 o3 o4 <<<"$ip" || continue

            # 基本合法性（0–255）
            for o in "$o1" "$o2" "$o3" "$o4"; do
                [[ "$o" =~ ^[0-9]+$ ]] && (( o>=0 && o<=255 )) || { ip=""; break; }
            done
            [[ -n "$ip" ]] || continue
            if (( o4 > max_last )); then
                max_last=$o4
            fi
        done

        if (( max_last > 0 )); then
            new_last=$((max_last + 3))
            if (( new_last > 252 )); then
                error "Phantun Client 網段超出限制！"
            fi
            default_tun_subnet="192.168.200.$new_last/30"
            new_last=$((max_last + 1))
            default_tun_local_ip="192.168.200.$new_last"
            new_last=$((max_last + 1))
            default_tun_peer_ip="192.168.200.$new_last"
        fi

        # 建立客戶端 Phantun 設定檔
        log "正在於 $PHANTUN_CONF_PATH 建立客戶端設定檔"
        echo "--tun tun_$SERVER_NAME
--tun-local $default_tun_local_ip
--tun-peer $default_tun_peer_ip
--local 127.0.0.1:$PHANTUN_CLIENT_LOCAL_PORT
--remote $SERVER_HOST:15004" > "$PHANTUN_CONF_PATH"
        log "正在於 $PHANTUN_RULE_UP_PATH 建立客戶端防火牆啟動規則"
        echo "-t nat -A POSTROUTING -s $default_tun_subnet -j MASQUERADE" > "$PHANTUN_RULE_UP_PATH"
        log "正在於 $PHANTUN_RULE_DOWN_PATH 建立客戶端防火牆關閉規則"
        echo "-t nat -D POSTROUTING -s $default_tun_subnet -j MASQUERADE" > "$PHANTUN_RULE_DOWN_PATH"
        log "正在重新載入 systemd 並啟動 phantun-client@$SERVER_NAME.service..."
        systemctl daemon-reload
        systemctl enable --now "phantun-client@$SERVER_NAME.service"
        log "連接 '$SERVER_NAME' 的 Phantun Client 服務已啟動。"
        warn "此服務會將本地 127.0.0.1:$PHANTUN_CLIENT_LOCAL_PORT 的 UDP 流量轉發到 $SERVER_HOST。"
    fi

    if [ -z "$WG_INTERFACE" ]; then
        while true; do
            read -rp "請輸入要建立 Peer 的 WireGuard 介面名稱 [預設: wg0]: " -e -i "wg0" WG_INTERFACE < /dev/tty
            if [ -e "/sys/class/net/$WG_INTERFACE" ]; then
                break
            else
                warn "介面 '$WG_INTERFACE' 不存在。請重新輸入！"
                WG_INTERFACE="" # 重置以便循環
            fi
        done
    else
        log "使用參數提供的 WireGuard 介面名稱: $WG_INTERFACE"
        if ! [ -e "/sys/class/net/$WG_INTERFACE" ]; then error "介面 '$WG_INTERFACE' 不存在。請指定一個不同的介面名稱。"; fi
    fi

    local WG_DIR="/etc/wireguard"
    local ALLOWED_IPS
    CLIENT_PUBLIC_KEY=$(cat "$WG_DIR/$WG_INTERFACE"_public.key)
    CLIENT_ENDPOINT="127.0.0.1:$PHANTUN_CLIENT_LOCAL_PORT"
    local LOCAL_WG_IP
    LOCAL_WG_IP=${WG_SUBNET%/*}

    if [ -n "$CLIENT_PUBLIC_KEY" ] && [ -n "$LOCAL_WG_IP" ]; then
        local copy_choice
        read -rp "是否要立即將公鑰拷貝到遠端 $SERVER_NAME 的設定檔中? [y/N]: " -e copy_choice < /dev/tty
        if [[ "$copy_choice" =~ ^[Yy]$ ]]; then
            if [ -z "$SERVER_PORT" ]; then
                read -rp "輸入要連線的伺服器PORT [預設: 22]: " -e -i "22" SERVER_PORT < /dev/tty
            else
                log "使用參數提供的伺服器PORT: $SERVER_PORT"
            fi
            if [ -z "$SERVER_PASSWORD" ]; then
                read -rp "輸入要連線的伺服器PASSWORD: " -e SERVER_PASSWORD < /dev/tty
            else
                log "使用參數提供的伺服器PASSWORD: ***********"
            fi
            # 使用 local 變數以避免意外修改全域變數
            local remote_public_key=""
            if [ -n "$SERVER_HOST" ] && [ -n "$SERVER_PORT" ]; then
                log "正在嘗試將公鑰 $CLIENT_PUBLIC_KEY 拷貝到 ${SERVER_HOST}:${SERVER_PORT}..."
                ALLOWED_IPS="$LOCAL_WG_IP/32"

                if [ -n "$SERVER_PASSWORD" ]; then
                    # 如果提供了密碼，則對 ssh 和 scp 都使用 sshpass
                    log "偵測到密碼，將使用 sshpass 進行認證。"
                    remote_public_key=$(sshpass -p "${SERVER_PASSWORD}" ssh -p "$SERVER_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SERVER_HOST}" \
                        "wg set $WG_INTERFACE peer $CLIENT_PUBLIC_KEY allowed-ips $ALLOWED_IPS && wg-quick save $WG_INTERFACE && wg show $WG_INTERFACE public-key")
                    
                    if [ -n "$remote_public_key" ]; then
                        log "✅ 公鑰成功拷貝到遠端伺服器。"
                        log "✅ 已成功從遠端伺服器取得公鑰。"
                    else
                        warn "使用密碼自動拷貝檔案失敗。請檢查密碼、主機或網路連線。"
                    fi
                else
                    # 如果未提供密碼，則假定使用 SSH 金鑰認證
                    remote_public_key=$(ssh -p "$SERVER_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SERVER_HOST}" \
                        "wg set $WG_INTERFACE peer $CLIENT_PUBLIC_KEY allowed-ips $ALLOWED_IPS && wg show $WG_INTERFACE public-key")
                    
                    if [ -n "$remote_public_key" ]; then
                        log "✅ 公鑰成功拷貝到遠端伺服器。"
                        log "✅ 已成功從遠端伺服器取得公鑰。"
                    else
                        warn "使用密碼自動拷貝檔案失敗。請檢查密碼、主機或網路連線。"
                    fi
                fi
            fi
        else
            # 優先從現有的 wg 設定中查找遠端公鑰
            local remote_public_key=""
            local search_ip="$SERVER_WG_IP/32"
            log "正在檢查 '$WG_INTERFACE' 中是否已存在 IP 為 '$search_ip' 的 peer..."
            
            # 使用 wg show dump 查找，該格式穩定可靠
            # awk: 逐行檢查，如果第4欄位等於目標IP，就印出第1欄位(公鑰)並退出
            remote_public_key=$(wg show "$WG_INTERFACE" dump | awk -v ip="$search_ip" '$4 == ip {print $1; exit}')            
        fi
    fi
    if [ -n "$remote_public_key" ] && [ -n "$SERVER_WG_IP" ] && [ -n "$CLIENT_ENDPOINT" ]; then
        ALLOWED_IPS="$SERVER_WG_IP/32"
        log "遠端公鑰: $remote_public_key"
        log "遠端 AllowedIPs: $ALLOWED_IPS"
        log "遠端 Endpoint: $CLIENT_ENDPOINT"
        # 設定 peer，包含 Endpoint，透過本地 phantun client 將流量轉發出去
        wg set "$WG_INTERFACE" peer "$remote_public_key" \
            allowed-ips "$ALLOWED_IPS" \
            endpoint "$CLIENT_ENDPOINT" \
            persistent-keepalive 25
        log "已將 '$SERVER_NAME' 作為 peer 新增至 '$WG_INTERFACE' 介面。"
        wg-quick save "$WG_INTERFACE"

        log "正在測試與遠端伺服器 ($SERVER_WG_IP) 的連線..."
        # -c 3: 發送 3 個封包
        # -W 5: 等待 5 秒回應
        if ping -c 3 -W 5 "$SERVER_WG_IP" &> /dev/null; then
            log "✅ 與 $SERVER_WG_IP 的連線測試成功！"
        else
            warn "⚠️ 與 $SERVER_WG_IP 的連線測試失敗。請檢查以下項目："
            warn "  1. 遠端伺服器 ($SERVER_HOST) 的 phantun-server 服務是否正常運作。"
            warn "  2. 本機的 phantun-client@$SERVER_NAME 服務是否正常運作。"
            warn "  3. 雙方的防火牆設定是否正確 (特別是遠端伺服器的 TCP 埠 15004)。"
            warn "  4. 雙方的金鑰與 IP 設定是否匹配。"
        fi
    else
        warn "無法從解析出完整的遠端資訊 (公鑰、AllowedIPs、Endpoint)，跳過新增 Peer。"
    fi
}

# --- 主腳本 ---
main() {
    check_root

    # 初始化變數
    PUBLIC_IP=""
    NIC_PARAM=""
    PHANTUN_PORT=""
    WG_INTERFACE=""
    WG_SUBNET=""
    WG_PORT=""
    SERVER_NAME=""
    SERVER_HOST=""
    SERVER_PORT=""
    SERVER_PASSWORD=""
    SERVER_WG_SUBNET=""
    SET_PEER_SERVICE_ONLY=false

    # 解析命令列參數
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nic) NIC_PARAM="$2"; shift 2 ;;
            --public-ip) PUBLIC_IP="$2"; shift 2 ;;
            --phantun-port) PHANTUN_PORT="$2"; shift 2 ;;
            --wg-interface) WG_INTERFACE="$2"; shift 2 ;;
            --wg-port) WG_PORT="$2"; shift 2 ;;
            --wg-subnet) WG_SUBNET="$2"; shift 2 ;;
            --server-name) SERVER_NAME="$2"; shift 2 ;;
            --server-wg-subnet) SERVER_WG_SUBNET="$2"; shift 2 ;;
            --server-host) SERVER_HOST="$2"; shift 2 ;;
            --server-port) SERVER_PORT="$2"; shift 2 ;;
            --server-password) SERVER_PASSWORD="$2"; shift 2 ;;
            --set-peer) SET_PEER_SERVICE_ONLY=true; shift 1 ;;
            -h|--help) usage; exit 0 ;;
            *) error "未知選項: $1" ;;
        esac
    done

    if [ "$SET_PEER_SERVICE_ONLY" = true ]; then
        log "--- 僅執行新增 phantun-client 服務 ---"
        setup_peer_client_service
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
    setup_peer_client_service

    echo
    log "🎉 設定完成！"
}

# 執行主函數
main "$@"
