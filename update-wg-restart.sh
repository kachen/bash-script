#!/bin/bash

SERVICE_FILE="/usr/lib/systemd/system/wg-quick@.service"

# 確認檔案存在
if [ ! -f "$SERVICE_FILE" ]; then
    echo "Error: $SERVICE_FILE 不存在"
    exit 1
fi

# 先備份原始檔
cp "$SERVICE_FILE" "${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"

# 在 [Service] 區塊中插入設定，若已存在則更新
if grep -q "Restart=" "$SERVICE_FILE"; then
    sed -i 's/^Restart=.*/Restart=always/' "$SERVICE_FILE"
else
    sed -i '/^\[Service\]/a Restart=always' "$SERVICE_FILE"
fi

if grep -q "RestartSec=" "$SERVICE_FILE"; then
    sed -i 's/^RestartSec=.*/RestartSec=5/' "$SERVICE_FILE"
else
    sed -i '/^\[Service\]/a RestartSec=5' "$SERVICE_FILE"
fi

# 重新載入 systemd 並顯示結果
systemctl daemon-reload
systemctl cat wg-quick@.service | grep -E "Restart|RestartSec"
echo "✅ 已更新並重新載入 systemd。"