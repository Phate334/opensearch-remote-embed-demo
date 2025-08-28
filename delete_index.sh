#!/bin/bash
set -euo pipefail

OS_URL="${OS_URL:-https://localhost:9200}"
OS_USER="${OS_USER:-admin}"
OS_PASS="${OS_PASS:-ChangeMeNow!_A1}"
INDEX_NAME="${INDEX_NAME:-test_index}"

echo "🔍 檢查索引是否存在: $INDEX_NAME"
HTTP_CODE=$(curl -s -k -u "$OS_USER:$OS_PASS" -o /dev/null -w "%{http_code}" -I "$OS_URL/$INDEX_NAME")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ℹ️ 索引 $INDEX_NAME 不存在 (HTTP $HTTP_CODE)，不需刪除。"
  exit 0
fi

read -p "⚠️ 確定要刪除索引 $INDEX_NAME ? (y/N) " ans
if [[ "${ans:-N}" != "y" && "${ans:-N}" != "Y" ]]; then
  echo "已取消。"
  exit 0
fi

echo "🗑️ 正在刪除索引 $INDEX_NAME ..."
RESP=$(curl -s -k -u "$OS_USER:$OS_PASS" -X DELETE "$OS_URL/$INDEX_NAME")
echo "$RESP" | (command -v jq >/dev/null 2>&1 && jq '.' || cat)

echo "✅ 完成"
