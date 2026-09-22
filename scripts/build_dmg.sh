#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: build_dmg.sh
# 核心功能: 在 .app 基础上产出可分发的压缩安装镜像 (.dmg)
#
# 说明：使用系统自带 hdiutil，无需 create-dmg 等外部工具（本机无 brew）。
#      镜像内含应用本体与 /Applications 快捷方式，符合 macOS 常规安装习惯。
# ==============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Key注入器"
VOLUME_NAME="Key 注入器"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"

# 版本号单一来源：仓库根目录 VERSION 文件
if [ ! -f "$PROJECT_DIR/VERSION" ]; then
  echo "❌ 未找到版本文件 $PROJECT_DIR/VERSION"
  exit 1
fi
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
DMG_PATH="$DIST_DIR/KeyInjector-${VERSION}.dmg"
STAGING="$DIST_DIR/dmg-staging"

echo "=========================================================="
echo "  KeyInjector DMG 打包 (v${VERSION})"
echo "=========================================================="

# 1. 确保应用包存在（不存在则先构建）
if [ ! -d "$APP_DIR" ]; then
  echo "▶️  未找到应用包，先执行 build_app.sh…"
  "$PROJECT_DIR/scripts/build_app.sh"
fi

# 2. 准备暂存目录
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
echo "✅ 暂存目录就绪（含 /Applications 快捷方式）"

# 3. 产出压缩镜像
rm -f "$DMG_PATH"
echo "▶️  正在生成 DMG…"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH" > /dev/null

rm -rf "$STAGING"

# 4. 校验镜像
if hdiutil verify "$DMG_PATH" > /dev/null 2>&1; then
  echo "✅ DMG 完整性与校验和验证通过"
else
  echo "❌ DMG 校验失败"
  exit 1
fi

SIZE="$(du -sh "$DMG_PATH" | cut -f1)"
echo ""
echo "📦 安装镜像: $DMG_PATH"
echo "   体积: $SIZE"
echo "   挂载: open \"$DMG_PATH\""
echo ""
echo "🎉 DMG 打包完成"
