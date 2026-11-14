#!/usr/bin/env bash
# dsh-guard 安装器：把 dsh-guard 放进 PATH，可选建一个桌面入口。
#
#   ./install.sh              安装到 ~/.local/bin（可用 PREFIX 覆盖）
#   ./install.sh --desktop    同时建「DSH（守护启动）」桌面入口
#   ./install.sh --uninstall  卸载（含桌面入口）
#
# 幂等：重复运行不会装出两份。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local/bin}"
DESKTOP_DIR="${DESKTOP_DIR:-$HOME/.local/share/applications}"
ENTRY="$DESKTOP_DIR/dsh-guard.desktop"
TARGET="$PREFIX/dsh-guard"
MODE="install"
WANT_DESKTOP=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE="uninstall" ;;
    --desktop) WANT_DESKTOP=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$arg" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "uninstall" ]; then
  rm -f "$TARGET" "$ENTRY"
  echo "已卸载：$TARGET"
  [ -f "$ENTRY" ] || echo "（桌面入口本来就没有）"
  exit 0
fi

mkdir -p "$PREFIX"
install -m 755 "$HERE/dsh-guard" "$TARGET"
echo "已安装：$TARGET"

# 立刻跑一次体检，成功与否都不中止安装
echo
if ! "$TARGET" --check; then
  echo "（体检没跑通，但工具已就位；上面就是原因）"
fi

if [ "$WANT_DESKTOP" = "1" ]; then
  mkdir -p "$DESKTOP_DIR"
  cat >"$ENTRY" <<EOF
[Desktop Entry]
Type=Application
Name=DSH（守护启动）
Comment=启动 DeepSeek Harness；插件把启动拖垮时自动停用它并告知
Exec=$TARGET
Terminal=false
Categories=Utility;
Keywords=dsh;deepseek;harness;
EOF
  echo "已建桌面入口：$ENTRY"
fi

cat <<EOF

下一步（三选一）：
  1. 手动跑：$TARGET
  2. 桌面入口：$ENTRY（如果加过 --desktop）
  3. 挂到现有的启动脚本：把「dsh-toggle.sh 启动成功后」改成先跑
     $TARGET --heal-log ~/.cache/dsh-desktop/dsh-web.log
     命中就说明是某个插件拖的，它已经帮你停用了。
EOF
