#!/bin/bash
#
# build.sh — 命令行「不签名」构建 CCBar 并打包成可分发的 zip。
#
# 思路和主流免费开源 Mac App(如 Burrow)一致:不用付费证书、不做公证,
# 用 CODE_SIGNING_ALLOWED=NO 让工具链自动给 arm64 打上 ad-hoc 签名,
# 得到一个能在任意 Mac 上执行的 ad-hoc 包;用户首次手动去隔离一次即可。
#
# 相比 Xcode GUI 的 Archive 导出,这条路不会引入 "Apple Development" 开发证书,
# 所以也不需要事后重签脚本。
#
# 用法:
#   scripts/build.sh            # 产物输出到 ./dist/CCBar.app.zip
#   scripts/build.sh <输出目录>
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
OUT_DIR="${1:-$REPO_ROOT/dist}"
APP="$BUILD_DIR/Build/Products/Release/CCBar.app"

echo "==> [1/4] 清理旧构建"
rm -rf "$BUILD_DIR"

echo "==> [2/4] 编译(Release,不签名 → 自动 ad-hoc)"
xcodebuild \
  -project ccbar.xcodeproj \
  -scheme ccbar \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

[[ -d "$APP" ]] || { echo "❌ 构建产物未找到: $APP" >&2; exit 1; }

echo "==> [3/4] 清扩展属性并校验签名"
xattr -cr "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" \
  && echo "   ✅ 签名校验通过" \
  || echo "   ⚠️ 签名校验有告警(ad-hoc 包通常仍可正常运行,可忽略)"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Signature" || true

echo "==> [4/4] 打包"
mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/CCBar.app.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "✅ 完成: $ZIP"
echo "   上传到 GitHub Release 即可。用户首次需按 README「安装」一节手动放行一次。"
