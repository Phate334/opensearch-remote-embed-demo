#!/bin/bash
set -euo pipefail

# 確保 test_index (或自訂 INDEX_NAME) 存在，不存在則以 1024 維 knn_vector 建立

# ===== 可覆寫環境變數 =====
OS_URL="${OS_URL:-https://localhost:9200}"
OS_USER="${OS_USER:-admin}"
OS_PASS="${OS_PASS:-ChangeMeNow!_A1}"
INDEX_NAME="${INDEX_NAME:-test_index}"
DIM="${DIM:-1024}"

echo "🔎 檢查索引是否存在: $INDEX_NAME (@ $OS_URL)"
HTTP_CODE=$(curl -s -k -u "$OS_USER:$OS_PASS" -o /dev/null -w "%{http_code}" -I "$OS_URL/$INDEX_NAME")

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "✅ 索引已存在，拉取設定以檢查 knn / 維度 ..."
  CURR_DIM=$(curl -s -k -u "$OS_USER:$OS_PASS" "$OS_URL/$INDEX_NAME" | jq -r ".[]?.mappings.properties.embedding.dimension // .${INDEX_NAME}.mappings.properties.embedding.dimension // empty")
  if [[ -n "$CURR_DIM" && "$CURR_DIM" != "$DIM" ]]; then
    echo "⚠️  索引已存在但維度為 $CURR_DIM 與期望 $DIM 不同；若需重新建立請先刪除索引。" >&2
  else
    echo "ℹ️  維度: ${CURR_DIM:-未知 (可能尚未設定)}"
  fi
  exit 0
fi

echo "📦 建立索引 $INDEX_NAME (dimension=$DIM) ..."
CREATE_BODY=$(jq -n --argjson dim "$DIM" '{
  settings: { index: { knn: true } },
  mappings: { properties: {
    content: { type: "text" },
    embedding: { type: "knn_vector", dimension: $dim }
  }}
}')

curl -s -k -u "$OS_USER:$OS_PASS" -X PUT "$OS_URL/$INDEX_NAME" \
  -H 'Content-Type: application/json' -d "$CREATE_BODY" | jq .

echo "✅ 索引建立完成。"
