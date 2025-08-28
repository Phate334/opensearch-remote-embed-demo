#!/bin/bash
set -euo pipefail

# 以文字查詢：呼叫本地 embedding 服務取得查詢向量，對 OpenSearch 執行 knn 查詢，僅輸出依相似度排序的 content。
# 用法： ./query.sh "your query text"  或  QUERY_TEXT="your query" ./query.sh
# 可覆寫環境變數：
#   OS_URL, OS_USER, OS_PASS, INDEX_NAME, EMBED_API_URL, EMBED_MODEL, TOP_K

OS_URL="${OS_URL:-https://localhost:9200}"
OS_USER="${OS_USER:-admin}"
OS_PASS="${OS_PASS:-ChangeMeNow!_A1}"
INDEX_NAME="${INDEX_NAME:-test_index}"
LLM_API_URL="${LLM_API_URL:-http://localhost:8080/v1/chat/completions}"
EMBED_API_URL="${EMBED_API_URL:-http://localhost:8081/v1/embeddings}"
EMBED_MODEL="${EMBED_MODEL:-e5-large}"
TOP_K="${TOP_K:-5}"
# 是否翻譯第一筆結果內容：1=翻譯 0=不翻譯
TRANSLATE_FIRST="${TRANSLATE_FIRST:-1}"

QUERY_TEXT="${1:-${QUERY_TEXT:-}}"
if [[ -z "$QUERY_TEXT" ]]; then
  echo "用法: $0 \"query text\"" >&2
  exit 1
fi

echo "🔎 索引: $INDEX_NAME (@ $OS_URL)"
HTTP_CODE=$(curl -s -k -u "$OS_USER:$OS_PASS" -o /dev/null -w "%{http_code}" -I "$OS_URL/$INDEX_NAME")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "❌ 索引不存在: $INDEX_NAME" >&2
  exit 1
fi

echo "🧠 取得查詢向量 (model=$EMBED_MODEL) ..."
EMB_RESP=$(curl -s -k -H 'Content-Type: application/json' \
  -d "$(jq -n --arg input "$QUERY_TEXT" --arg model "$EMBED_MODEL" '{input:$input, model:$model}')" \
  "$EMBED_API_URL" || true)
EMB=$(jq -ec '.data[0].embedding' <<<"$EMB_RESP" 2>/dev/null || true)
if [[ -z "$EMB" || "$EMB" == "null" ]]; then
  echo "❌ 無法取得查詢 embedding，回應: $EMB_RESP" >&2
  exit 1
fi

echo "🔍 knn 搜尋 (top $TOP_K) ..."
SEARCH_BODY=$(jq -n --argjson v "$EMB" --argjson k "$TOP_K" '{size:$k, _source:["content"], query:{knn:{embedding:{vector:$v, k:$k}}}}')
RESP=$(curl -s -k -u "$OS_USER:$OS_PASS" -X POST "$OS_URL/$INDEX_NAME/_search" -H 'Content-Type: application/json' -d "$SEARCH_BODY" || true)

if ! jq -e '.hits.hits' >/dev/null 2>&1 <<<"$RESP"; then
  echo "❌ OpenSearch 回應非預期: $RESP" >&2
  exit 1
fi

COUNT=$(jq '.hits.hits | length' <<<"$RESP")
if [[ "$COUNT" -eq 0 ]]; then
  echo "(無相似結果)"
  exit 0
fi

echo "\n📄 結果 (僅列出 content)："
# 只列出 content，依原排序 (score 由 OpenSearch 決定)；編號 1..N
jq -r '.hits.hits[]._source.content' <<<"$RESP" | nl -w1 -s'. '

if [[ "$TRANSLATE_FIRST" == "1" ]]; then
  echo -e "\n🌐 翻譯第 1 筆內容 -> 繁體中文 (台灣用語) ..."
  FIRST_DOC_CONTENT=$(jq -r '.hits.hits[0]._source.content' <<<"$RESP")
  # 構造 Chat Completions 請求
  LLM_REQ=$(jq -n --arg sys "Directly translate the user's input into Traditional Chinese using expressions customary in Taiwan; do not include any additional explanations" \
                    --arg user "$FIRST_DOC_CONTENT" '{messages:[{role:"system",content:$sys},{role:"user",content:$user}]}' )
  LLM_RESP=$(curl -s -H 'Content-Type: application/json' -d "$LLM_REQ" "$LLM_API_URL" || true)
  # 嘗試解析常見結構 (OpenAI 相容格式)
  LLM_TEXT=$(jq -r '.choices[0].message.content // empty' <<<"$LLM_RESP" 2>/dev/null || true)
  if [[ -n "$LLM_TEXT" ]]; then
    echo -e "\n🈶 翻譯：\n$LLM_TEXT"
  else
    echo "⚠️ 翻譯失敗，原始回應：$LLM_RESP" >&2
  fi
fi

exit 0
