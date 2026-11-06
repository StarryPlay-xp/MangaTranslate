#!/bin/zsh
# 安装漫译 Chrome 插件的 Mac 小助手：编译 → 复制到 ~/Library/Application Support/MangaTranslate Chrome/bin →
# 在 Chrome 的 NativeMessagingHosts 目录登记，只允许本插件（固定 ID）连接。重新运行就是更新。
# 其他基于 Chromium 的浏览器：用 MANGA_CHROME_DIR 指定它的资料目录，例如
#   MANGA_CHROME_DIR="$HOME/Library/Application Support/Microsoft Edge" Chrome/install.sh
set -euo pipefail

ROOT="${0:A:h}"
EXTENSION_ID="gkghibbflnabefngldccgikgnaeolobi"
HOST_NAME="io.github.starryplay_xp.mangatranslate"
INSTALL_DIR="${MANGA_HELPER_INSTALL_DIR:-$HOME/Library/Application Support/MangaTranslate Chrome/bin}"
CHROME_DIR="${MANGA_CHROME_DIR:-$HOME/Library/Application Support/Google/Chrome}"
MANIFEST_DIR="$CHROME_DIR/NativeMessagingHosts"

echo "① 编译小助手（第一次要一两分钟）…"
swift build -c release --package-path "$ROOT/Helper"
BUILT="$(swift build -c release --package-path "$ROOT/Helper" --show-bin-path)/manga-translate-helper"

echo "② 复制到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -f "$BUILT" "$INSTALL_DIR/manga-translate-helper"
chmod 755 "$INSTALL_DIR/manga-translate-helper"

echo "③ 登记给 Chrome：$MANIFEST_DIR/$HOST_NAME.json"
mkdir -p "$MANIFEST_DIR"
/usr/bin/python3 - "$MANIFEST_DIR/$HOST_NAME.json" "$INSTALL_DIR/manga-translate-helper" "$HOST_NAME" "$EXTENSION_ID" <<'PY'
import json, sys
path, binary, name, extension = sys.argv[1:5]
manifest = {
    "name": name,
    "description": "漫译 Chrome 插件的 Mac 小助手：识别图片文字、调用模型翻译",
    "path": binary,
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{extension}/"],
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
PY

echo
echo "安装完成。接下来："
echo "  1. 完全退出 Chrome（⌘Q）再重新打开"
echo "  2. 打开 chrome://extensions ，打开右上角的「开发者模式」"
echo "  3. 点「加载已解压的扩展程序」，选择 $ROOT/Extension"
echo "  4. 点插件的「详细信息 → 扩展程序选项」，在设置页粘贴 DeepSeek 的 API Key"
