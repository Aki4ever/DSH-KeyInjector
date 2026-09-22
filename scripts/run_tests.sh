#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: run_tests.sh
# 核心功能: 一键运行核心层自动化测试，作为交付前的质量硬门禁
#
# 背景说明（本机实测踩坑）：
#   本机仅安装 Command Line Tools（无完整 Xcode），工具链不含 XCTest，
#   测试统一使用 swift-testing。但 SPM 的**增量编译**路径会漏传 swift-testing
#   的宏插件目录，导致第二次起报
#   "plugin for module 'TestingMacros' not found"。
#   因此本脚本动态探测插件路径并显式传给 swiftc，确保重复运行稳定绿灯。
# ==============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$PROJECT_DIR/reports"
LOG_FILE="$REPORT_DIR/test-report.log"
mkdir -p "$REPORT_DIR"

cd "$PROJECT_DIR"

# 动态探测 swift-testing 的宏插件目录（兼容不同 CLT / Xcode 安装位置）
PLUGIN_DIR=""
if FRONTEND="$(xcrun --find swift-frontend 2>/dev/null)"; then
  CANDIDATE="$(cd "$(dirname "$FRONTEND")/../lib/swift/host/plugins/testing" 2>/dev/null && pwd -P || true)"
  if [ -n "$CANDIDATE" ] && [ -d "$CANDIDATE" ]; then
    PLUGIN_DIR="$CANDIDATE"
  fi
fi

echo "=========================================================="
echo "  KeyInjector 自动化测试门禁"
echo "=========================================================="
if [ -n "$PLUGIN_DIR" ]; then
  echo "🔌 swift-testing 宏插件: $PLUGIN_DIR"
else
  echo "ℹ️  未探测到 swift-testing 宏插件目录，按默认方式编译"
fi

if [ -n "$PLUGIN_DIR" ]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" 2>&1 | tee "$LOG_FILE"
else
  swift test 2>&1 | tee "$LOG_FILE"
fi

SUMMARY="$(grep -oE 'Test run with [0-9]+ tests in [0-9]+ suites passed[^.]*' "$LOG_FILE" | tail -1 || true)"
if [ -z "$SUMMARY" ]; then
  echo ""
  echo "❌ 质量门禁未通过：未检测到测试全绿汇总行，请查看 $LOG_FILE"
  exit 1
fi

if grep -qE '✘|error: ' "$LOG_FILE"; then
  echo ""
  echo "❌ 质量门禁未通过：日志中仍存在失败项，请查看 $LOG_FILE"
  exit 1
fi

echo ""
echo "✅ 质量门禁通过：$SUMMARY"
echo "   完整日志: $LOG_FILE"
