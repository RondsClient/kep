#!/usr/bin/env bash
# 一键安装脚本（在目标 Linux 服务器上运行）
# 用法: curl -fsSL https://your-server.com/install.sh | sudo bash -s -- -url https://your-server.com/kpe-linux-amd64.tar.gz

set -euo pipefail

INSTALLER_URL="${KPE_INSTALLER_URL:-https://your-server.com/kpe-install}"
RELEASE_URL="${KPE_RELEASE_URL:-https://your-server.com/kpe-linux-amd64.tar.gz}"

while [[ $# -gt 0 ]]; do
  case $1 in
    -url) RELEASE_URL="$2"; shift 2 ;;
    -installer-url) INSTALLER_URL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

TMP=$(mktemp)
echo "Downloading KPE installer from $INSTALLER_URL ..."
curl -fsSL "$INSTALLER_URL" -o "$TMP"
chmod +x "$TMP"
exec "$TMP" -url "$RELEASE_URL"
