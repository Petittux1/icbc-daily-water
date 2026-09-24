#!/usr/bin/env bash
# build_zip.sh - 从仓库内容重新生成可刷入的 KSU/Magisk 模块 zip
# 用法: bash build_zip.sh   (在仓库根目录执行)
# 产物: ../icbc-daily-water-v<版本>.zip
set -e
cd "$(dirname "$0")/.."
VER=$(grep -m1 '^version=' module.prop | cut -d= -f2)
OUT="../icbc-daily-water-${VER}.zip"
STAGE="${TMPDIR:-/tmp}/icbc_zip_stage"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/tools"
cp module.prop service.sh water.sh customize.sh README.md LICENSE .gitignore "$STAGE/"
cp tools/px.py tools/run_once.sh "$STAGE/tools/"
# /sdcard 是 FUSE, chmod 无效, 故在 /tmp 暂存后打包, 确保权限写入 zip
chmod 755 "$STAGE"/service.sh "$STAGE"/water.sh "$STAGE"/customize.sh "$STAGE"/tools/run_once.sh
chmod 644 "$STAGE"/module.prop "$STAGE"/README.md "$STAGE"/LICENSE "$STAGE"/.gitignore "$STAGE"/tools/px.py
(cd "$STAGE" && zip -qr "$OLDPWD/$OUT" .)
rm -rf "$STAGE"
echo "已生成: $OUT"