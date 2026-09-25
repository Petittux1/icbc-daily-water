#!/usr/bin/env bash
# build_zip.sh - 从仓库内容重新生成可刷入的 KSU/Magisk 模块 zip
# 用法: bash tools/build_zip.sh   (在仓库根目录执行)
# 产物: ../xiaomi-17-pro-automation-v<版本>.zip
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VER=$(grep -m1 '^version=' "$ROOT/module.prop" | cut -d= -f2)
OUT="$(dirname "$ROOT")/xiaomi-17-pro-automation-${VER}.zip"
STAGE="${TMPDIR:-/tmp}/xiaomi_17_pro_automation_zip_stage.$$"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

rm -f "$OUT"
mkdir -p "$STAGE/tools" "$STAGE/webroot"
cp "$ROOT"/module.prop "$ROOT"/service.sh "$ROOT"/water.sh "$ROOT"/record.sh "$ROOT"/replay.sh \
   "$ROOT"/webctl.sh "$ROOT"/sched.conf "$ROOT"/customize.sh "$ROOT"/README.md \
   "$ROOT"/LICENSE "$ROOT"/.gitignore "$STAGE/"
cp "$ROOT"/webroot/* "$STAGE/webroot/"
cp "$ROOT"/tools/px.py "$ROOT"/tools/run_once.sh "$STAGE/tools/"

chmod 755 "$STAGE"/service.sh "$STAGE"/water.sh "$STAGE"/record.sh "$STAGE"/replay.sh \
  "$STAGE"/webctl.sh "$STAGE"/customize.sh "$STAGE"/tools/run_once.sh
chmod 644 "$STAGE"/module.prop "$STAGE"/sched.conf "$STAGE"/README.md "$STAGE"/LICENSE \
  "$STAGE"/.gitignore "$STAGE"/tools/px.py "$STAGE"/webroot/*

(cd "$STAGE" && zip -qr "$OUT" .)
echo "已生成: $OUT"
