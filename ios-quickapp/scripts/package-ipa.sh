#!/usr/bin/env bash
set -euo pipefail
APP_PATH="${1:-}"
OUT_IPA="${2:-MobileCodexQuick.ipa}"
if [[ -z "$APP_PATH" ]]; then
  echo "用法: $0 <MobileCodexQuick.app 路径> [输出ipa文件名]" >&2
  exit 1
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "找不到 .app: $APP_PATH" >&2
  exit 1
fi
WORK_DIR="$(mktemp -d)"
mkdir -p "$WORK_DIR/Payload"
cp -R "$APP_PATH" "$WORK_DIR/Payload/"
(
  cd "$WORK_DIR"
  zip -qry "$OUT_IPA" Payload
)
mv "$WORK_DIR/$OUT_IPA" "./$OUT_IPA"
rm -rf "$WORK_DIR"
echo "已生成: $(pwd)/$OUT_IPA"
