#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: check_version_sync.sh
# 核心功能: 三位一体版本一致性门禁
#
# 校验版本号在「① 版本源文件 ② 代码常量 ③ 文档与技能包 ④ 已打包产物」
# 四处完全一致，防止多处硬编码各自漂移。
# 任一处不一致即以非零退出码失败，可直接接入 CI 或收尾流程。
# ==============================================================================
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

FAIL=0
note_fail() { echo "  ❌ $1"; FAIL=1; }
note_ok()   { echo "  ✅ $1"; }

echo "=========================================================="
echo "  版本一致性门禁"
echo "=========================================================="

# ① 版本源文件
if [ ! -f VERSION ]; then
  note_fail "缺少版本源文件 VERSION"
  echo "结论：❌ 门禁失败"; exit 1
fi
VERSION="$(tr -d '[:space:]' < VERSION)"
if [ -z "$VERSION" ]; then
  note_fail "VERSION 文件为空"
  echo "结论：❌ 门禁失败"; exit 1
fi
note_ok "① 版本源文件 VERSION = $VERSION"

# ② 代码常量
CODE_VER="$(grep -o 'current = "[0-9][0-9.]*"' Sources/KeyInjectorCore/Version.swift | head -1 | sed 's/.*"\(.*\)"/\1/')"
if [ "$CODE_VER" = "$VERSION" ]; then
  note_ok "② 代码常量 Version.swift = $CODE_VER"
else
  note_fail "② 代码常量不一致：Version.swift = '$CODE_VER'，期望 '$VERSION'"
fi

# ③ 文档与技能包
check_doc() {
  local file="$1" label="$2"
  if [ ! -f "$file" ]; then note_fail "${label}：文件不存在（$file）"; return; fi
  if grep -q "$VERSION" "$file"; then
    note_ok "${label}：含 $VERSION"
  else
    note_fail "${label}：未找到 $VERSION（$file）"
  fi
}
check_doc "README.md" "③ README"
check_doc "skills/keyinject/SKILL.md" "③ 技能包 SKILL.md"
check_doc "docs/requirements.md" "③ 需求台账"
check_doc "docs/architecture.md" "③ 架构说明"
check_doc "CHANGELOG.md" "③ 变更日志"

# ④ 已打包产物（存在才校验）
APP="dist/账号管理器.app"
if [ -d "$APP" ]; then
  PLIST_VER="$(plutil -extract CFBundleShortVersionString raw -o - "$PROJECT_DIR/$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$PLIST_VER" = "$VERSION" ]; then
    note_ok "④ 应用包 Info.plist = $PLIST_VER"
  else
    note_fail "④ 应用包版本不一致：Info.plist = '$PLIST_VER'，期望 '$VERSION'（请重新执行 build_app.sh）"
  fi
  if [ -f "dist/账号管理器-${VERSION}.dmg" ]; then
    note_ok "④ 安装镜像 dist/账号管理器-${VERSION}.dmg 存在"
  else
    note_fail "④ 缺少与当前版本匹配的 DMG：dist/账号管理器-${VERSION}.dmg"
  fi
else
  echo "  ⏭️  ④ 尚未打包，跳过产物校验（执行 scripts/build_app.sh 后可校验）"
fi

echo "=========================================================="
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 版本一致性门禁通过（版本 ${VERSION}）"
else
  echo "❌ 版本一致性门禁失败，请修正上述不一致项"
fi
echo "=========================================================="
exit "$FAIL"
