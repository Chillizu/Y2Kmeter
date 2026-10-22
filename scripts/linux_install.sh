#!/usr/bin/env bash
# ==========================================================
# Y2Kmeter Linux 安装脚本（Arch + Hyprland / PipeWire 为默认目标）
#
# 做的事情：
#   1) 把构建好的 Standalone 二进制安装到 ~/.local/opt/Y2Kmeter/
#   2) 把 Milkdrop 预设/纹理 seed 到 ~/.local/share/Y2Kmeter/（应用优先读这里）
#   3) 补 ~/.local/bin/y2kmeter 软链与 .desktop 启动项
#
# 用法：
#   scripts/linux_install.sh [二进制路径]
# 不传二进制路径时默认使用 build/linux/.../Standalone/Y2Kmeter。
# ==========================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-$REPO_DIR/build/linux/Y2Kmeter_artefacts/Release/Standalone/Y2Kmeter}"

PREFIX="$HOME/.local/opt/Y2Kmeter"
DATA_DIR="$HOME/.local/share/Y2Kmeter"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"

if [[ ! -x "$BIN" ]]; then
  echo "[FAIL] 找不到可执行文件：$BIN" >&2
  echo "       先构建：cmake --preset linux-release && cmake --build --preset linux-release --target Y2Kmeter_Standalone" >&2
  exit 1
fi

echo "[1/4] 安装二进制 -> $PREFIX/Y2Kmeter"
mkdir -p "$PREFIX"
install -Dm755 "$BIN" "$PREFIX/Y2Kmeter"

echo "[2/4] seed Milkdrop 资源 -> $DATA_DIR"
mkdir -p "$DATA_DIR"
for sub in milkdrop_presets milkdrop_textures; do
  src="$REPO_DIR/assets/$sub"
  dst="$DATA_DIR/$sub"
  if [[ -d "$dst" ]] && [[ -n "$(ls -A "$dst" 2>/dev/null || true)" ]]; then
    echo "      已存在，跳过：$dst"
  elif [[ -d "$src" ]]; then
    cp -r "$src" "$dst"
    echo "      已复制：$sub"
  else
    echo "      [WARN] 仓库里缺少 assets/$sub，跳过"
  fi
done

echo "[3/4] 启动入口"
mkdir -p "$BIN_DIR" "$DESKTOP_DIR"
ln -sf "$PREFIX/Y2Kmeter" "$BIN_DIR/y2kmeter"
cat > "$DESKTOP_DIR/y2kmeter.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Y2Kmeter
Comment=Y2K audio analysis meter
Exec=$PREFIX/Y2Kmeter
Terminal=false
Categories=AudioVideo;Audio;
EOF

echo "[4/4] 完成"
cat <<'EOF'

提示：
  · Milkdrop 需要 libprojectM 4.x（Arch: sudo pacman -S libprojectm），
    缺失时模块会显示 fallback UI，其它功能不受影响。
  · Hyprland 建议加一条只针对 Y2Kmeter 的窗口规则（float + 关圆角）：
      hl.window_rule({ match = { class = "^(Y2Kmeter)$" }, float = true, rounding = 0 })
    详见 docs/Linux_Arch_Hyprland.md。
  · 启动：~/.local/bin/y2kmeter
EOF
