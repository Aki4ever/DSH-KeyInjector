#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: build_app.sh
# 核心功能: 构建 release 二进制并组装为可双击运行的 macOS 应用包 (.app)
#
# 重要说明（本机实测）：
#   本机仅安装 Command Line Tools，没有完整 Xcode，因此不使用 xcodebuild，
#   而是用 SPM 产出二进制后手工组装 bundle，并用 ad-hoc 签名 (codesign -s -)。
#   这样产出的应用可本机直接运行；分发给他人时对方需在「隐私与安全性」中放行。
# ==============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Key注入器"
EXECUTABLE_NAME="KeyInjector"
BUNDLE_ID="com.aki4ever.keyinjector"
VERSION="1.0.0"
BUILD_NUMBER="1"

DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"

echo "=========================================================="
echo "  KeyInjector 应用打包 (v${VERSION})"
echo "=========================================================="

# 1. 构建 release 二进制
echo "▶️  正在编译 release 版本…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
echo "   产物目录: $BIN_PATH"

# 2. 组装 bundle 骨架
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/bin"

cp "$BIN_PATH/KeyInjectorApp" "$CONTENTS/MacOS/$EXECUTABLE_NAME"
chmod +x "$CONTENTS/MacOS/$EXECUTABLE_NAME"
echo "✅ 已复制主程序: Contents/MacOS/$EXECUTABLE_NAME"

# 3. 图标
if [ -f "$PROJECT_DIR/assets/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
  echo "✅ 已复制应用图标: Contents/Resources/AppIcon.icns"
else
  echo "⚠️  未找到 assets/AppIcon.icns，将使用系统默认图标"
fi

# 4. 前端资源（AppKit + WKWebView 界面）
cp -R "$PROJECT_DIR/web" "$CONTENTS/Resources/ui"
echo "✅ 已复制前端资源: Contents/Resources/ui"

# 5. 一并内置命令行工具，方便 DSH 会话直接调用
if [ -f "$BIN_PATH/keyinject" ]; then
  cp "$BIN_PATH/keyinject" "$CONTENTS/Resources/bin/keyinject"
  chmod +x "$CONTENTS/Resources/bin/keyinject"
  echo "✅ 已内置命令行工具: Contents/Resources/bin/keyinject"
fi

# 6. Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>KeyInjector — 本地密钥管理与配置注入工具</string>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" > /dev/null && echo "✅ Info.plist 校验通过"

# 7. ad-hoc 签名（无开发者证书时 macOS 可运行的唯一方式）
codesign --force --deep --sign - "$APP_DIR" 2>&1 | sed 's/^/   /'
if codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
  echo "✅ ad-hoc 签名校验通过"
else
  echo "⚠️  签名校验未通过（应用仍可在本机运行，但系统可能提示来源不明）"
fi

# 8. 汇总
echo ""
echo "📦 应用包: $APP_DIR"
echo "   体积: $(du -sh "$APP_DIR" | cut -f1)"
echo "   启动: open \"$APP_DIR\""
echo ""
echo "🎉 应用打包完成"
