#!/bin/bash

# =================================================================
#         Phantun Installer for Linux
# =================================================================
#
# 這個腳本會自動從 GitHub 下載並安裝最新版本的 phantun。
# 它會偵測系統架構並安裝對應的預編譯二進位檔案。
#
# 它必須以 root 權限執行。
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
GITHUB_REPO="dndx/phantun"

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
    if ! command -v curl &> /dev/null; then
        error "找不到 'curl' 指令。請先安裝 curl。"
    fi
    if ! command -v tar &> /dev/null; then
        error "找不到 'tar' 指令。請先安裝 tar。"
    fi
    log "必要指令 (curl, tar) 已找到。"
}

# 安裝 Phantun
install_phantun() {
    log "正在偵測系統架構..."
    local ARCH
    ARCH=$(uname -m)
    local PHANTUN_ARCH
    case "$ARCH" in
        x86_64)
            PHANTUN_ARCH="x86_64-unknown-linux-musl"
            ;;
        aarch64)
            PHANTUN_ARCH="aarch64-unknown-linux-musl"
            ;;
        armv7l)
            PHANTUN_ARCH="armv7-unknown-linux-musleabihf"
            ;;
        armv6l)
            PHANTUN_ARCH="arm-unknown-linux-musleabihf"
            ;;
        *)
            error "不支援的系統架構: $ARCH"
            ;;
    esac
    log "系統架構為: $ARCH (對應 Phantun 架構: $PHANTUN_ARCH)"

    log "正在從 GitHub 獲取最新版本資訊..."
    local LATEST_JSON
    LATEST_JSON=$(curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest")
    
    local DOWNLOAD_URL
    DOWNLOAD_URL=$(echo "$LATEST_JSON" | grep "browser_download_url" | grep "$PHANTUN_ARCH" | cut -d '"' -f 4)

    if [ -z "$DOWNLOAD_URL" ]; then
        error "無法找到適用於 '$PHANTUN_ARCH' 架構的下載連結。請檢查 GitHub 發布頁面。"
    fi

    local FILENAME
    FILENAME=$(basename "$DOWNLOAD_URL")
    local DOWNLOAD_PATH="/tmp/$FILENAME"

    log "正在下載 $FILENAME..."
    curl -L -o "$DOWNLOAD_PATH" "$DOWNLOAD_URL"

    log "正在解壓縮檔案..."
    tar -xzf "$DOWNLOAD_PATH" -C /tmp

    log "正在安裝 phantun 到 /usr/local/bin..."
    # 使用 install 指令來複製檔案並設定權限
    install -m 755 "/tmp/phantun" /usr/local/bin/phantun

    log "正在清理暫存檔案..."
    rm "$DOWNLOAD_PATH"
    rm "/tmp/phantun"
}

# --- 主腳本 ---
main() {
    check_root
    check_prerequisites
    install_phantun

    # 驗證安裝
    if command -v phantun &> /dev/null; then
        log "🎉 Phantun 安裝成功！版本資訊如下："
        phantun --version
        echo
        log "下一步："
        log "1. 建立設定檔 (例如 /etc/phantun/config.toml)。"
        log "2. 建立 systemd 服務來管理 phantun 進程。"
        echo
        warn "以下是一個 systemd 服務檔案範本 ('/etc/systemd/system/phantun-client.service'):"
        echo -e "${YELLOW}
[Unit]
Description=Phantun Client
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/phantun -c /etc/phantun/config.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
        ${NC}"
        log "建立後，執行 'sudo systemctl enable --now phantun-client' 來啟動並設定開機自啟。"
    else
        error "Phantun 安裝失敗。找不到 'phantun' 指令。"
    fi
}

# 執行主函數
main
