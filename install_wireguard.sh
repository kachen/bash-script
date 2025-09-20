#!/bin/bash

# =================================================================
#         WireGuard Installer for Major Linux Distributions
# =================================================================
#
# 這個腳本會偵測作業系統並安裝 WireGuard 工具。
# 它必須以 root 權限執行。
#
# 支援的發行版:
# - Debian / Ubuntu
# - CentOS / RHEL / Rocky Linux / AlmaLinux
# - Fedora
# - Arch Linux
#
# =================================================================

# 如果任何指令失敗，立即退出
set -e
# 將未設定的變數視為錯誤
set -u
# Pipeline 的回傳值以最後一個非零狀態的指令為準
set -o pipefail

# --- 函數定義 ---

# 輸出日誌訊息
log() {
    echo "[INFO] $1"
}

# 輸出錯誤訊息並退出
error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# --- 主腳本 ---

# 1. 檢查 root 權限
if [ "$(id -u)" -ne 0 ]; then
    error "此腳本必須以 root 權限執行。請使用 'sudo'。"
fi

log "開始安裝 WireGuard..."

# 2. 偵測 Linux 發行版
# 嘗試讀取 /etc/os-release (新式系統)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
# 備用方法
elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    VER=$(lsb_release -sr)
else
    error "無法偵測到您的 Linux 發行版。請手動安裝 WireGuard。"
fi

log "偵測到作業系統: $OS, 版本: $VER"

# 3. 根據不同的發行版執行安裝指令
case "$OS" in
    ubuntu|debian)
        log "正在更新套件列表..."
        apt-get update
        log "正在安裝 WireGuard..."
        # 'resolvconf' 是 wg-quick 的建議相依套件，用於 DNS 管理
        apt-get install -y wireguard resolvconf
        ;;

    centos|rhel|rocky|almalinux)
        log "正在安裝 EPEL repository..."
        # 如果有 dnf 就用 dnf，否則用 yum
        if command -v dnf &> /dev/null; then
            dnf install -y epel-release
            log "正在安裝 WireGuard..."
            dnf install -y wireguard-tools
        else
            yum install -y epel-release
            log "正在安裝 WireGuard..."
            # CentOS/RHEL 7 可能需要從 elrepo 安裝核心模組
            if [[ "$VER" == 7* ]]; then
                 yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm
                 yum install -y kmod-wireguard wireguard-tools
            else
                 yum install -y wireguard-tools
            fi
        fi
        ;;

    fedora)
        log "正在安裝 WireGuard..."
        dnf install -y wireguard-tools
        ;;

    arch)
        log "正在更新系統並安裝 WireGuard..."
        pacman -Syu --noconfirm wireguard-tools
        ;;

    *)
        error "不支援的作業系統: $OS。請參考官方文件手動安裝。"
        ;;
esac

# 4. 驗證安裝結果
if command -v wg &> /dev/null; then
    log "WireGuard 安裝成功！"
    log "您現在可以開始設定您的 WireGuard 介面了。"
    log "例如：在 /etc/wireguard/wg0.conf 建立設定檔。"
else
    error "WireGuard 安裝失敗。找不到 'wg' 指令。"
fi

exit 0
