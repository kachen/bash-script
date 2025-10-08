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
    echo "  --server-name <name>            服務端主機名稱"
    echo "  --client-name <name>            用戶端主機名稱"
    echo "  --server-host <host>            服務端主機 HOST"
    echo "  --client-host <host>            用戶端主機 HOST"
    echo "  --client-port <potr>            用戶端主機 PORT"
    echo "  --client-password <password>    用戶端主機密碼，用於自動拷貝設定檔"
    echo "  --del-interface                 僅執行移除 WireGuard interface 服務的步驟"
    echo "  --del-client                    僅執行移除 phantun-client 服務的步驟"
    echo "  --del-server                    僅執行移除 phantun-server 服務的步驟"
    echo "  --add-interface                 僅執行設定 WireGuard interface 和 phantun-server 服務的步驟"
    echo "  --set-peer                      僅執行設定 WireGuard peer 和 phantun-client 服務的步驟"
    echo "  -h, --help                      顯示此幫助訊息"
}

# 清理現有的 WireGuard 及其設定
cleanup_existing_interface() {
    local if_name="$1"
    log "正在清理現有的WireGuard '$if_name' 及其設定..."

    # 停止並禁用相關服務
    if systemctl is-active --quiet "wg-quick@${if_name}.service"; then
        log "正在停止 wg-quick@${if_name}.service..."
        systemctl stop "wg-quick@${if_name}.service"
    fi
    if systemctl is-enabled --quiet "wg-quick@${if_name}.service"; then
        log "正在禁用 wg-quick@${if_name}.service..."
        systemctl disable "wg-quick@${if_name}.service"
    fi
    
    # 移除設定檔
    log "正在移除設定檔..."
    rm -f "/etc/wireguard/${if_name}.conf" "/etc/wireguard/${if_name}_private.key" "/etc/wireguard/${if_name}_public.key"

    # 重新載入 systemd 以確保服務狀態更新
    systemctl daemon-reload

    log "清理完成。"
}

# 清理現有的 Phantun Server 及其設定
cleanup_existing_phantun_server() {
    local if_name="$1"
    log "正在清理現有的Phantun Server '$if_name' 及其設定..."

    # 停止並禁用相關服務
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
    rm -f "/etc/phantun/${if_name}.server" "/etc/phantun/${if_name}_server_up.rules" "/etc/phantun/${if_name}_server_down.rules"

    # 重新載入 systemd 以確保服務狀態更新
    systemctl daemon-reload

    log "清理完成。"
}

# 清理現有的 Phantun Client 及其設定
cleanup_existing_phantun_client() {
    local if_name="$1"
    log "正在清理現有的Phantun Client '$if_name' 及其設定..."

    # 停止並禁用相關服務
    if systemctl is-active --quiet "phantun-client@${if_name}.service"; then
        log "正在停止 phantun-client@${if_name}.service..."
        systemctl stop "phantun-client@${if_name}.service"
    fi
    if systemctl is-enabled --quiet "phantun-client@${if_name}.service"; then
        log "正在禁用 phantun-client@${if_name}.service..."
        systemctl disable "phantun-client@${if_name}.service"
    fi
    
    # 移除設定檔
    log "正在移除設定檔..."
    rm -f "/etc/phantun/${if_name}.client" "/etc/phantun/${if_name}_client_up.rules" "/etc/phantun/${if_name}_client_down.rules"

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
        read -rp "Phantun 伺服器與客戶端二進位檔案已存在，要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
        if ! [[ "$choice" =~ ^[Yy]$ ]]; then
            return
        fi
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

    log "正在建立 systemd 服務..."
    # Phantun 服務
    log "正在於 /etc/systemd/system/phantun-server@.service 建立服務檔案"
    cat > /etc/systemd/system/phantun-server@.service << "EOF"
[Unit]
Description=Phantun Server
After=network.target

[Service]
User=root
ExecStartPre=/usr/sbin/iptables-restore --noflush /etc/phantun/%i_server_up.rules
ExecStart=/bin/bash -c '/usr/local/bin/phantun_server $(</etc/phantun/%i.server)'
ExecStopPost=/usr/sbin/iptables-restore --noflush /etc/phantun/%i_server_down.rules
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
ExecStartPre=/usr/sbin/iptables-restore --noflush /etc/phantun/%i_client_up.rules
ExecStart=/bin/bash -c '/usr/local/bin/phantun_client $(</etc/phantun/%i.client)'
ExecStopPost=/usr/sbin/iptables-restore --noflush /etc/phantun/%i_client_down.rules
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "Phantun 安裝成功。"
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


# 建立 WireGuard interface 和 phantun_server 服務
setup_wg_interface_service() {

    if [ -z "$SERVER_NAME" ]; then
        read -rp "輸入服務端的主機名稱 [預設: server1]: " -e -i "server1" SERVER_NAME < /dev/tty
    else
        log "使用參數提供的服務端的主機名稱: $SERVER_NAME"
    fi
    local overwrite_phantun_server_config=true
    if [ -z "$CLIENT_NAME" ]; then
        while true; do
            read -rp "輸入用戶端的主機名稱 [預設: client1]: " -e -i "client1" CLIENT_NAME < /dev/tty
            if systemctl status "phantun-server@${CLIENT_NAME}.service" --no-pager &>/dev/null; then
                warn "phantun-server@ '$CLIENT_NAME' 已存在。您是否要移除它重新設定？"
                warn "警告：這將會刪除所有與phantun-server@ '$CLIENT_NAME' 相關的設定檔和服務。"
                local choice
                read -rp "確定要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    cleanup_existing_phantun_server "$CLIENT_NAME"
                    break
                else
                    overwrite_phantun_server_config=false
                    break
                fi
            else
                break
            fi
        done
    else
        log "使用參數提供的用戶端的主機名稱: $CLIENT_NAME"
        if systemctl status "phantun-server@${CLIENT_NAME}.service" --no-pager &>/dev/null; then
            warn "phantun-server@ '$CLIENT_NAME' 已存在。您是否要移除它重新設定？"
            warn "警告：這將會刪除所有與phantun-server@ '$CLIENT_NAME' 相關的設定檔和服務。"
            local choice
            read -rp "確定要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                cleanup_existing_phantun_server "$CLIENT_NAME"
            else
                overwrite_phantun_server_config=false
            fi
        fi
    fi
    if [ -z "$CLIENT_HOST" ]; then
        read -rp "輸入用戶端的主機 HOST: " -e CLIENT_HOST < /dev/tty
    else
        log "使用參數提供的用戶端的主機 HOST: $CLIENT_HOST"
    fi
    if [ -z "$CLIENT_PORT" ]; then
        read -rp "輸入用戶端主機的 PORT [預設: 22]: " -e -i "22" CLIENT_PORT < /dev/tty
    else
        log "使用參數提供的用戶端主機的 PORT: $CLIENT_PORT"
    fi
    if [ -z "$CLIENT_PASSWORD" ]; then
        read -rp "輸入用戶端主機的 PASSWORD: " -e CLIENT_PASSWORD < /dev/tty
    else
        log "使用參數提供的用戶端主機的 PASSWORD: ***********"
    fi

    # --- 主機公網 IP ---
    if [ -z "$PUBLIC_IP" ]; then
        local default_ip
        default_ip=$(curl -s https://ipinfo.io/ip)
        read -rp "請輸入主機公網 IP 位址 [預設: $default_ip]: " -e -i "$default_ip" PUBLIC_IP < /dev/tty
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

    # --- WireGuard 介面名稱 ---
    local overwrite_wireguard_config=true
    if [ -z "$WG_INTERFACE" ]; then
        while true; do
            read -rp "請輸入 WireGuard 介面名稱 [預設: wg_${CLIENT_NAME}]: " -e -i "wg_${CLIENT_NAME}" WG_INTERFACE < /dev/tty
            if [ -e "/sys/class/net/$WG_INTERFACE" ]; then
                warn "介面 '$WG_INTERFACE' 已存在。您是否要移除它重新設定？"
                warn "警告：這將會刪除所有與 '$WG_INTERFACE' 相關的設定檔和服務。"
                local choice
                read -rp "確定要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    cleanup_existing_interface "$WG_INTERFACE"
                    break
                else
                    overwrite_wireguard_config=false
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
            else
                overwrite_wireguard_config=false
            fi
        fi
    fi

    # 建立用戶端目錄
    local CLIENT_PACKAGE_DIR="/root/client-confs"
    local CLIENT_DIR="$CLIENT_PACKAGE_DIR/$CLIENT_NAME"
    if [ -d "$CLIENT_DIR" ]; then
        warn "目錄 '$CLIENT_DIR' 已存在，將會覆蓋其中的檔案。"
    else
        mkdir -p "$CLIENT_DIR"
    fi
    # --- 其他設定 ---
    local WG_DIR="/etc/wireguard"
    local default_wg_local_ip
    local default_wg_peer_ip
    default_wg_local_ip="192.168.6.2"
    default_wg_peer_ip="192.168.6.3"
    declare -A used=()
    declare -a local_addrs=()
    declare -a remote_addrs=()

    if [ "$overwrite_wireguard_config" = true ]; then
        # 本機讀取
        local conf_files=()
        shopt -s nullglob
        conf_files=("$WG_DIR"/*.conf)
        shopt -u nullglob
        if ((${#conf_files[@]} == 0)); then
            log "⚠️  本機沒有任何 Wireguard Address"
        else
            mapfile -t local_addrs < <(
            awk -F'[ =/]+' '/^Address[[:space:]]*=/{print $2}' "$WG_DIR"/*.conf 2>/dev/null || true
            )
            log "✅  本機讀到 ${#local_addrs[@]} 筆 Wireguard Address"
        fi
        if [ -n "$CLIENT_PASSWORD" ]; then
            # 如果提供了密碼，則對 ssh 和 scp 都使用 sshpass
            log "偵測到密碼，將使用 sshpass 進行認證。"
            if remote_out=$(sshpass -p "$CLIENT_PASSWORD" ssh -p "$CLIENT_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$CLIENT_HOST" \
                "awk -F'[ =/]+' '/^Address[[:space:]]*=/{print \$2}' /etc/wireguard/*.conf 2>/dev/null || true" ); then
                if [[ -n "$remote_out" ]]; then
                    mapfile -t remote_addrs <<<"$remote_out"
                    log "✅ 成功讀取遠端 $CLIENT_HOST 的 ${#remote_addrs[@]} 筆 Wireguard Address"
                else
                    log "⚠️ 遠端 $CLIENT_HOST 沒有任何 Wireguard Address"
                fi
            else
                error "❌ 無法讀取遠端 $CLIENT_HOST 的 conf。請檢查密碼、主機或網路連線。"
            fi
        else
            # 如果未提供密碼，則假定使用 SSH 金鑰認證
            if remote_out=$(ssh -p "$CLIENT_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$CLIENT_HOST" \
                "awk -F'[ =/]+' '/^Address[[:space:]]*=/{print \$2}' /etc/wireguard/*.conf 2>/dev/null || true" ); then
                if [[ -n "$remote_out" ]]; then
                    mapfile -t remote_addrs <<<"$remote_out"
                    log "✅ 成功讀取遠端 $CLIENT_HOST 的 ${#remote_addrs[@]} 筆 Wireguard Address"
                else
                    log "⚠️ 遠端 $CLIENT_HOST 沒有任何 Wireguard Address"
                fi
            else
                error "❌ 無法讀取遠端 $CLIENT_HOST 的 conf。請確認 SSH 金鑰是否已正確設定，或嘗試使用密碼參數 --client-password。"
            fi
        fi

        addresses=("${remote_addrs[@]}" "${local_addrs[@]}")
        for ip in "${addresses[@]}"; do
            IFS=. read -r o1 o2 o3 o4 <<<"$ip" || continue

            # 基本合法性（0–255）
            for o in "$o1" "$o2" "$o3" "$o4"; do
                [[ "$o" =~ ^[0-9]+$ ]] && (( o>=0 && o<=255 )) || { ip=""; break; }
            done
            [[ -n "$ip" ]] || continue
            used[$o4]=1
        done

        candidate=-1
        for ((i=2; i<=253; i+=2)); do
            if [[ -z "${used[$i]+x}" ]] && [[ -z "${used[$i+1]+x}" ]]; then
                candidate=$i
                break
            fi
        done

        if (( candidate < 0 )); then
            error "WireGuard 網段超出限制！"
        else
            default_wg_local_ip="192.168.6.$candidate"
            candidate=$((candidate+1))
            default_wg_peer_ip="192.168.6.$candidate"
        fi

        local third_octet
        third_octet=$(echo "$default_wg_local_ip" | cut -d '.' -f 3)
        local fourth_octet
        fourth_octet=$(echo "$default_wg_local_ip" | cut -d '.' -f 4)
        local default_server_wireguard_port
        default_server_wireguard_port=$(printf "%d%03d" "$third_octet" "$fourth_octet")

        # --- WireGuard 內部 UDP 埠 ---
        if [ -z "$WG_PORT" ]; then
            while true; do
                read -rp "請輸入 WireGuard 內部監聽的 UDP 埠 [預設: $default_server_wireguard_port]: " -e -i "$default_server_wireguard_port" WG_PORT < /dev/tty
                if ss -lnu | grep -q ":$WG_PORT\b"; then
                    warn "UDP 埠 $WG_PORT 已被佔用，請選擇其他埠。"
                    WG_PORT="" # 重置以便循環
                else
                    break
                fi
            done
        fi

        log "正在產生服務端主機設定檔..."
        # WireGuard 設定

        mkdir -p "$WG_DIR"
        cd "$WG_DIR"
        wg genkey | tee "$WG_INTERFACE"_private.key | wg pubkey > "$WG_INTERFACE"_public.key
        chmod 600 "$WG_INTERFACE"_private.key
        SERVER_PRIVATE_KEY=$(cat "$WG_INTERFACE"_private.key)
        SERVER_PUBLIC_KEY=$(cat "$WG_INTERFACE"_public.key)

        cd "$CLIENT_DIR"
        wg genkey | tee private.key | wg pubkey > public.key
        chmod 600 private.key
        CLIENT_PRIVATE_KEY=$(cat "$CLIENT_DIR"/private.key)
        CLIENT_PUBLIC_KEY=$(cat "$CLIENT_DIR"/public.key)

        echo "[Interface]
Address = ${default_wg_local_ip}/31
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY
Table = off
PostUp = /sbin/iptables -t nat -A POSTROUTING -s ${default_wg_local_ip}/31 -j MASQUERADE
PostDown =/sbin/iptables -t nat -D POSTROUTING -s ${default_wg_local_ip}/31 -j MASQUERADE
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0" > "$WG_DIR/$WG_INTERFACE.conf"

        # 重新載入並啟動
        systemctl daemon-reload
        systemctl enable --now "wg-quick@$WG_INTERFACE.service"
        log "WireGuard 服務已啟動並設定為開機自啟。"

        # 建立用戶端 Wireguard 設定檔
        echo "[Interface]
Address = ${default_wg_peer_ip}/31
PrivateKey = $CLIENT_PRIVATE_KEY
Table = off
PostUp = /sbin/iptables -t nat -A POSTROUTING -s ${default_wg_local_ip}/31 -j MASQUERADE
PostDown =/sbin/iptables -t nat -D POSTROUTING -s ${default_wg_local_ip}/31 -j MASQUERADE
[Peer]
PublicKey = $SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25" > "${CLIENT_DIR}/wg.conf"

    else

        if grep -q '^[[:space:]]*ListenPort[[:space:]]*=' "$WG_DIR/$WG_INTERFACE.conf"; then
            WG_PORT=$(grep -E '^\s*ListenPort\s*=' "$WG_DIR/$WG_INTERFACE.conf" 2>/dev/null | sed -E 's/^\s*ListenPort\s*=\s*//' | tr -d '[:space:]')
            log "找到 ListenPort: $WG_PORT"
        else
            read -rp "$WG_INTERFACE 尚未開始監聽，是否要建立 WireGuard 內部監聽的 UDP 埠？ [y/N]: " -e choice < /dev/tty
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                WG_SUBNET=$(grep -E '^\s*Address\s*=' "$WG_DIR/$WG_INTERFACE.conf" | sed -E 's/^\s*Address\s*=\s*//' | xargs)
                default_wg_local_ip=${WG_SUBNET%/*}

                local third_octet
                third_octet=$(echo "$default_wg_local_ip" | cut -d '.' -f 3)
                local fourth_octet
                fourth_octet=$(echo "$default_wg_local_ip" | cut -d '.' -f 4)
                local default_server_wireguard_port
                default_server_wireguard_port=$(printf "%d%03d" "$third_octet" "$fourth_octet")
                while true; do
                    read -rp "請輸入 WireGuard 內部監聽的 UDP 埠 [預設: $default_server_wireguard_port]: " -e -i "$default_server_wireguard_port" WG_PORT < /dev/tty
                    if ss -lnu | grep -q ":$WG_PORT\b"; then
                        warn "UDP 埠 $WG_PORT 已被佔用，請選擇其他埠。"
                        WG_PORT="" # 重置以便循環
                    else
                        break
                    fi
                done
            fi
            grep -q '^ListenPort' "$WG_DIR/$WG_INTERFACE.conf"  \
            && sed -i "s/^ListenPort.*/ListenPort = $WG_PORT/" "$WG_DIR/$WG_INTERFACE.conf"  \
            || sed -i "/^\[Interface\]/a ListenPort = $WG_PORT" "$WG_DIR/$WG_INTERFACE.conf" 
            systemctl restart "wg-quick@$WG_INTERFACE.service"
            log "WireGuard 服務已重新啟動，並開始監聽Port $WG_PORT 埠"
        fi
    fi

    local default_tun_subnet
    local default_tun_local_ip
    local default_tun_peer_ip
    local PHANTUN_DIR="/etc/phantun"
    default_tun_subnet="192.168.15.2/31"
    default_tun_local_ip="192.168.15.2"
    default_tun_peer_ip="192.168.15.3"
    used=()

    if [ "$overwrite_phantun_server_config" = true ]; then

        for f in "$PHANTUN_DIR"/*.server; do
            [[ -e "$f" ]] || continue
            ip=$(awk '/^--tun-local[[:space:]]+/ {print $2; exit}' "$f" 2>/dev/null || true)
            [[ -n "${ip:-}" ]] || continue

            IFS=. read -r o1 o2 o3 o4 <<<"$ip" || continue

            # 基本合法性（0–255）
            for o in "$o1" "$o2" "$o3" "$o4"; do
                [[ "$o" =~ ^[0-9]+$ ]] && (( o>=0 && o<=255 )) || { ip=""; break; }
            done
            [[ -n "$ip" ]] || continue
            used[$o4]=1
        done

        candidate=-1
        for ((i=2; i<=253; i+=2)); do
            if [[ -z "${used[$i]+x}" ]]; then
                candidate=$i
                break
            fi
        done

        if (( candidate < 0 )); then
            error "Phantun Server 網段超出限制！"
        else
            default_tun_subnet="192.168.15.$candidate/31"
            default_tun_local_ip="192.168.15.$candidate"
            candidate=$((candidate+1))
            default_tun_peer_ip="192.168.15.$candidate"
        fi

        local third_octet
        third_octet=$(echo "$default_tun_local_ip" | cut -d '.' -f 3)
        local fourth_octet
        fourth_octet=$(echo "$default_tun_local_ip" | cut -d '.' -f 4)
        local default_server_phantun_port
        default_server_phantun_port=$(printf "%d%03d" "$third_octet" "$fourth_octet")

        # --- Phantun TCP 埠 ---
        if [ -z "$PHANTUN_PORT" ]; then
            while true; do
                read -rp "請輸入 Phantun Server 監聽的 TCP 埠 [預設: $default_server_phantun_port]: " -e -i "$default_server_phantun_port" PHANTUN_PORT < /dev/tty
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
            log "使用參數提供的 Phantun Server TCP 埠: $PHANTUN_PORT"
            if ss -lnt | grep -q ":$PHANTUN_PORT\b"; then error "TCP 埠 $PHANTUN_PORT 已被佔用。"; fi
        fi

        # Phantun 設定
        mkdir -p "$PHANTUN_DIR"
        echo "--tun s_${CLIENT_NAME}
--tun-local $default_tun_local_ip
--tun-peer $default_tun_peer_ip
--local $PHANTUN_PORT
--remote 127.0.0.1:$WG_PORT" > "$PHANTUN_DIR/$CLIENT_NAME.server"

        echo "*nat
-A PREROUTING -p tcp -i $NIC_PARAM --dport $PHANTUN_PORT -j DNAT --to-destination $default_tun_peer_ip
COMMIT" > "$PHANTUN_DIR/${CLIENT_NAME}_server_up.rules"

        echo "*nat
-D PREROUTING -p tcp -i $NIC_PARAM --dport $PHANTUN_PORT -j DNAT --to-destination $default_tun_peer_ip
COMMIT" > "$PHANTUN_DIR/${CLIENT_NAME}_server_down.rules"

        systemctl daemon-reload
        systemctl enable --now phantun-server@$CLIENT_NAME.service
        log "Phantun Server 服務已啟動並設定為開機自啟。"

        # 建立用戶端 Phantun 設定檔
        echo "--tun c_${SERVER_NAME}
--remote $PUBLIC_IP:${PHANTUN_PORT}" > "${CLIENT_DIR}/pc.conf"

    fi


    local copy_choice
    read -rp "是否要立即將 '$CLIENT_NAME' 的設定檔拷貝到用戶端主機? [y/N]: " -e copy_choice < /dev/tty
    if [[ "$copy_choice" =~ ^[Yy]$ ]]; then
        if [ -n "$CLIENT_HOST" ] && [ -n "$SERVER_NAME" ]; then
            local remote_path="/root/server-confs/${SERVER_NAME}"
            log "正在嘗試將設定檔拷貝到 ${CLIENT_HOST}:${remote_path}..."

            # 嘗試建立遠端目錄並拷貝檔案
            if [ -n "$CLIENT_PASSWORD" ]; then
                # 如果提供了密碼，則對 ssh 和 scp 都使用 sshpass
                log "偵測到密碼，將使用 sshpass 進行認證。"
                if sshpass -p "${CLIENT_PASSWORD}" ssh -p "$CLIENT_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${CLIENT_HOST}" "mkdir -p '${remote_path}'" && \
                    sshpass -p "${CLIENT_PASSWORD}" scp -P "$CLIENT_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -r ${CLIENT_DIR}/* "${CLIENT_HOST}:${remote_path}/"; then
                    log "✅ 檔案成功拷貝到遠端設備。"
                else
                    warn "使用密碼自動拷貝檔案失敗。請檢查密碼、主機或網路連線。"
                fi
            else
                # 如果未提供密碼，則假定使用 SSH 金鑰認證
                if ssh -p "$CLIENT_PORT" -o ConnectTimeout=5 "${CLIENT_HOST}" "mkdir -p '${remote_path}'" && \
                    scp -P "$CLIENT_PORT" -o ConnectTimeout=5 -r ${CLIENT_DIR}/* "${CLIENT_HOST}:${remote_path}/"; then
                    log "✅ 檔案成功拷貝到遠端設備。"
                else
                    warn "自動拷貝檔案失敗。請確認 SSH 金鑰是否已正確設定，或嘗試使用密碼參數 --client-password。"
                fi
            fi
        fi
    fi

}

# 建立 WireGuard peer 和 phantun_client 服務
setup_peer_client_service() {

    log "--- 開始設定 Phantun Client 服務 ---"
    if [ -z "$SERVER_NAME" ]; then
        while true; do
            read -rp "選擇要連線的主機名稱 (對應 /root/server-confs/ 下的資料夾名稱) [預設: server1]: " -e -i "server1" SERVER_NAME < /dev/tty
            if systemctl status "phantun-client@${SERVER_NAME}.service" --no-pager &>/dev/null; then
                warn "phantun-client@ '$SERVER_NAME' 已存在。您是否要移除它重新設定？"
                warn "警告：這將會刪除所有與phantun-client@ '$SERVER_NAME' 相關的設定檔和服務。"
                local choice
                read -rp "確定要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    cleanup_existing_phantun_client "$SERVER_NAME"
                    break
                fi
            else
                break
            fi
        done
    else
        log "使用參數提供的伺服器名稱: $SERVER_NAME"
        if systemctl status "phantun-client@${SERVER_NAME}.service" --no-pager &>/dev/null; then
            warn "phantun-client@ '$SERVER_NAME' 已存在。您是否要移除它重新設定？"
            warn "警告：這將會刪除所有與phantun-client@ '$SERVER_NAME' 相關的設定檔和服務。"
            local choice
            read -rp "確定要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                cleanup_existing_phantun_client "$SERVER_NAME"
            fi
        fi
    fi

    local overwrite_wireguard_config=true
    # --- WireGuard 介面名稱 ---
    if [ -z "$WG_INTERFACE" ]; then
        while true; do
            read -rp "請輸入 WireGuard 介面名稱 [預設: wg_${SERVER_NAME}]: " -e -i "wg_${SERVER_NAME}" WG_INTERFACE < /dev/tty
            if [ -e "/sys/class/net/$WG_INTERFACE" ]; then
                warn "介面 '$WG_INTERFACE' 已存在。您是否要移除它重新設定？"
                warn "警告：這將會刪除所有與 '$WG_INTERFACE' 相關的設定檔和服務。"
                local choice
                read -rp "確定要移除並重建嗎？ [y/N]: " -e choice < /dev/tty
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    cleanup_existing_interface "$WG_INTERFACE"
                    break
                else
                    overwrite_wireguard_config=false
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
            else
                overwrite_wireguard_config=false
            fi
        fi
    fi

    local default_tun_subnet
    local default_tun_local_ip
    local default_tun_peer_ip
    local PHANTUN_DIR="/etc/phantun"
    default_tun_subnet="192.168.16.2/31"
    default_tun_local_ip="192.168.16.2"
    default_tun_peer_ip="192.168.16.3"

    declare -A used=()

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
        used[$o4]=1
    done

    candidate=-1
    for ((i=2; i<=253; i+=2)); do
        if [[ -z "${used[$i]+x}" ]]; then
            candidate=$i
            break
        fi
    done

    if (( candidate < 0 )); then
        error "Phantun Client 網段超出限制！"
    else
        default_tun_subnet="192.168.16.$candidate/31"
        default_tun_local_ip="192.168.16.$candidate"
        candidate=$((candidate+1))
        default_tun_peer_ip="192.168.16.$candidate"
    fi

    local third_octet
    third_octet=$(echo "$default_tun_peer_ip" | cut -d '.' -f 3)
    local fourth_octet
    fourth_octet=$(echo "$default_tun_peer_ip" | cut -d '.' -f 4)
    local default_client_phantun_port
    default_client_phantun_port=$(printf "%d%03d" "$third_octet" "$fourth_octet")

    # --- Phantun UDP 埠 ---
    if [ -z "$PHANTUN_PORT" ]; then
        while true; do
            read -rp "請輸入 Phantun Client 監聽的 UDP 埠 [預設: $default_client_phantun_port]: " -e -i "$default_client_phantun_port" PHANTUN_PORT < /dev/tty
            if ss -lnu | grep -q ":$PHANTUN_PORT\b"; then
                warn "UDP 埠 $PHANTUN_PORT 似乎已被佔用。"
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
        log "使用參數提供的 Phantun Client UDP 埠: $PHANTUN_PORT"
        if ss -lnu | grep -q ":$PHANTUN_PORT\b"; then error "UDP 埠 $PHANTUN_PORT 已被佔用。"; fi
    fi

    local SERVER_DIR="/root/server-confs/$SERVER_NAME"
    local WG_CONF_PATH_NEW="$SERVER_DIR/wg.conf"
    local PHANTUN_CONF_PATH_NEW="$SERVER_DIR/pc.conf"

    local overwrite_phantun_client_config=true
    local WG_DIR="/etc/wireguard"
    local WG_CONF_PATH="${WG_DIR}/${WG_INTERFACE}.conf"
    local PHANTUN_CONF_PATH="$PHANTUN_DIR/$SERVER_NAME.client"
    local PHANTUN_RULE_UP_PATH="$PHANTUN_DIR/${SERVER_NAME}_client_up.rules"
    local PHANTUN_RULE_DOWN_PATH="$PHANTUN_DIR/${SERVER_NAME}_client_down.rules"
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
            overwrite_phantun_client_config=false
        fi
    fi

    if [ -f "$PHANTUN_CONF_PATH_NEW" ] && [ "$overwrite_phantun_client_config" = true ]; then

        # 1. 設定 Phantun Client
        log "正在複製 Phantun Client 設定檔至 $PHANTUN_CONF_PATH"
        mkdir -p /etc/phantun
        cp "$PHANTUN_CONF_PATH_NEW" "$PHANTUN_CONF_PATH"

        echo "--local 127.0.0.1:${PHANTUN_PORT}
--tun-local $default_tun_local_ip
--tun-peer $default_tun_peer_ip" >> "$PHANTUN_CONF_PATH"

        echo "*nat
-A POSTROUTING -s $default_tun_subnet -j MASQUERADE
COMMIT" > "${PHANTUN_RULE_UP_PATH}"

        echo "*nat
-D POSTROUTING -s $default_tun_subnet -j MASQUERADE
COMMIT" > "${PHANTUN_RULE_DOWN_PATH}"

        # 2. 設定 WireGuard Peer
        if [ -f "$WG_CONF_PATH_NEW" ]; then
            log "正在複製 WireGuard 設定檔至 $WG_CONF_PATH"
            mkdir -p /etc/wireguard
            cp "$WG_CONF_PATH_NEW" "$WG_CONF_PATH"
        fi
        if [ -f "$WG_CONF_PATH" ]; then
            grep -q '^Endpoint' "$WG_CONF_PATH" \
            && sed -i "s/^Endpoint.*/Endpoint = 127.0.0.1:${PHANTUN_PORT}/" "$WG_CONF_PATH" \
            || sed -i "/^\[Peer\]/a Endpoint = 127.0.0.1:${PHANTUN_PORT}" "$WG_CONF_PATH"
        fi

        systemctl daemon-reload
        systemctl enable --now "phantun-client@$SERVER_NAME.service"
        if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}.service"; then
            systemctl restart "wg-quick@$WG_INTERFACE.service"
        else
            systemctl enable --now "wg-quick@$WG_INTERFACE.service"
        fi
        log "WireGuard 和 Phantun Client 服務已啟動並設定為開機自啟。"
    else
        warn "設定失敗！"
    fi

}

# --- 主腳本 ---
main() {
    check_root

    # 初始化變數
    PUBLIC_IP=""
    NIC_PARAM=""
    WG_PORT=""
    WG_INTERFACE=""
    PHANTUN_PORT=""
    SERVER_NAME=""
    SERVER_HOST=""
    CLIENT_NAME=""
    CLIENT_HOST=""
    CLIENT_PORT=""
    CLIENT_PASSWORD=""
    DEL_WG_INTERFACE_ONLY=false
    ADD_WG_INTERFACE_ONLY=false
    SET_PEER_SERVICE_ONLY=false
    DEL_PHANTUN_CLIENT_ONLY=false
    DEL_PHANTUN_SERVER_ONLY=false

    # 解析命令列參數
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nic) NIC_PARAM="$2"; shift 2 ;;
            --public-ip) PUBLIC_IP="$2"; shift 2 ;;
            --server-name) SERVER_NAME="$2"; shift 2 ;;
            --server-host) SERVER_HOST="$2"; shift 2 ;;
            --client-name) CLIENT_NAME="$2"; shift 2 ;;
            --client-host) CLIENT_HOST="$2"; shift 2 ;;
            --client-port) CLIENT_PORT="$2"; shift 2 ;;
            --client-password) CLIENT_PASSWORD="$2"; shift 2 ;;
            --del-interface) DEL_WG_INTERFACE_ONLY=true; shift 1 ;;
            --del-client) DEL_PHANTUN_CLIENT_ONLY=true; shift 1 ;;
            --del-server) DEL_PHANTUN_SERVER_ONLY=true; shift 1 ;;
            --add-interface) ADD_WG_INTERFACE_ONLY=true; shift 1 ;;
            --set-peer) SET_PEER_SERVICE_ONLY=true; shift 1 ;;
            -h|--help) usage; exit 0 ;;
            *) error "未知選項: $1" ;;
        esac
    done

    if [ "$DEL_PHANTUN_CLIENT_ONLY" = true ]; then
        log "--- 僅執行移除 phantun-client 服務 ---"
        read -rp "輸入要刪除的主機名稱 [預設: client1]: " -e -i "client1" SERVER_NAME < /dev/tty
        if systemctl status "phantun-client@${SERVER_NAME}.service" --no-pager &>/dev/null; then
            warn "phantun-client@ '$SERVER_NAME' 已存在。您是否要移除它重新設定？"
            warn "警告：這將會刪除所有與phantun-client@ '$SERVER_NAME' 相關的設定檔和服務。"
            local choice
            read -rp "確定要移除嗎？ [y/N]: " -e choice < /dev/tty
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                cleanup_existing_phantun_client "$SERVER_NAME"
            fi
        fi
        exit 0
    fi

    if [ "$DEL_PHANTUN_SERVER_ONLY" = true ]; then
        log "--- 僅執行移除 phantun-server 服務 ---"
        read -rp "輸入要刪除的主機名稱 [預設: server1]: " -e -i "server1" SERVER_NAME < /dev/tty
        if systemctl status "phantun-server@${SERVER_NAME}.service" --no-pager &>/dev/null; then
            warn "phantun-server@ '$SERVER_NAME' 已存在。您是否要移除它重新設定？"
            warn "警告：這將會刪除所有與phantun-server@ '$SERVER_NAME' 相關的設定檔和服務。"
            local choice
            read -rp "確定要移除嗎？ [y/N]: " -e choice < /dev/tty
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                cleanup_existing_phantun_server "$SERVER_NAME"
            fi
        fi
        exit 0
    fi

    if [ "$DEL_WG_INTERFACE_ONLY" = true ]; then
        log "--- 僅執行移除 wg interface ---"
        read -rp "請輸入 WireGuard 介面名稱 [預設: wg1}]: " -e -i "wg1" WG_INTERFACE < /dev/tty
        if [ -e "/sys/class/net/$WG_INTERFACE" ]; then
            warn "介面 '$WG_INTERFACE' 存在。您是否要移除它？"
            warn "警告：這將會刪除所有與 '$WG_INTERFACE' 相關的設定檔和服務。"
            local choice
            read -rp "確定要移除嗎？ [y/N]: " -e choice < /dev/tty
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                cleanup_existing_interface "$WG_INTERFACE"
            fi
        fi
        exit 0
    fi

    if [ "$ADD_WG_INTERFACE_ONLY" = true ]; then
        log "--- 僅執行新增 wg interface 和 phantun-server 服務 ---"
        setup_wg_interface_service
        exit 0
    fi

    if [ "$SET_PEER_SERVICE_ONLY" = true ]; then
        log "--- 僅執行新增 wg peer 和 phantun-client 服務 ---"
        setup_peer_client_service
        exit 0
    fi

    detect_distro
    install_dependencies
    install_phantun
    setup_ip_forwarding

    echo
    log "🎉 設定完成！"
}

# 執行主函數
main "$@"
