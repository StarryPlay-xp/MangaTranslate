#!/bin/zsh
# 卸载 Mac 小助手：删掉 Chrome 里的登记和小助手程序。
# 加上 --all 时连设置、术语表、用量记录、译文缓存和钥匙串里的 Key 一起删掉
set -euo pipefail

HOST_NAME="io.github.starryplay_xp.mangatranslate"
SUPPORT="$HOME/Library/Application Support/MangaTranslate Chrome"
CHROME_DIR="${MANGA_CHROME_DIR:-$HOME/Library/Application Support/Google/Chrome}"

rm -f "$CHROME_DIR/NativeMessagingHosts/$HOST_NAME.json"
rm -rf "$SUPPORT/bin"
echo "已删除小助手和 Chrome 里的登记。"

if [[ "${1:-}" == "--all" ]]; then
  rm -rf "$SUPPORT" "$HOME/Library/Caches/MangaTranslate Chrome"
  # 每个模型服务一把 Key，逐个删到删不到为止
  while security delete-generic-password -s "io.github.starryplay-xp.MangaTranslate.chrome" >/dev/null 2>&1; do :; done
  echo "已删除设置、术语表、用量记录、译文缓存和钥匙串里的 Key。"
fi
echo "插件本身请在 chrome://extensions 里移除。"
