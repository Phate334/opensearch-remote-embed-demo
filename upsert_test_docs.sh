#!/bin/bash
set -euo pipefail

# 讓錯誤更好追蹤
trap 'echo "❗ 發生錯誤 (line $LINENO): 指令=[$BASH_COMMAND]" >&2' ERR

# 將固定 5 筆測試文件 (以內容 SHA256 當作 _id) upsert 到索引；若已存在則跳過。

# ===== 可覆寫環境變數 =====
OS_URL="${OS_URL:-https://localhost:9200}"
OS_USER="${OS_USER:-admin}"
OS_PASS="${OS_PASS:-ChangeMeNow!_A1}"
INDEX_NAME="${INDEX_NAME:-test_index}"
EMBED_API_URL="${EMBED_API_URL:-http://localhost:8081/v1/embeddings}"
EMBED_MODEL="${EMBED_MODEL:-e5-large}"
DIM="${DIM:-1024}"

DOCS=(
  "OpenSearch is an open-source, distributed search and analytics engine that supports full-text queries, vector similarity, aggregations, and near real-time observability use cases."
  "OpenAI provides an embeddings API that turns natural language or code into high-dimensional vectors, enabling semantic search, clustering, recommendation, and retrieval-augmented generation workflows."
  "Vector databases store embedding vectors together with metadata and support approximate nearest neighbor search so applications can perform semantic search that captures intent beyond exact keyword matches."
  "Docker Compose simplifies environment setup by letting you declaratively define multi-container services—such as OpenSearch, dashboards, and an embedding proxy—and bring them up reproducibly with a single command."
  "Machine learning models for natural language processing transform raw text into structured representations like tokens, embeddings, and entity labels, unlocking tasks such as question answering, summarization, and intent detection."
)

echo "🔎 確認索引是否存在 (若不存在請先執行 ensure_index.sh) ..."
HTTP_CODE=$(curl -s -k -u "$OS_USER:$OS_PASS" -o /dev/null -w "%{http_code}" -I "$OS_URL/$INDEX_NAME")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "❌ 索引 $INDEX_NAME 不存在；請先執行 ./ensure_index.sh 或設定正確 INDEX_NAME" >&2
  exit 1
fi

inserted=0
skipped=0

for text in "${DOCS[@]}"; do
  ID=$(printf "%s" "$text" | sha256sum | cut -d' ' -f1)
  echo ""
  echo "➡️  處理文件: $text"

  # 檢查是否已存在
  DOC_CODE=$(curl -s -k -u "$OS_USER:$OS_PASS" -o /dev/null -w "%{http_code}" -I "$OS_URL/$INDEX_NAME/_doc/$ID")
  if [[ "$DOC_CODE" == "200" ]]; then
    echo "   ✅ 已存在 (id=$ID) -> 跳過"
  # 注意：((var++)) 在 Bash 中會以「自增前的值」作為表達式結果；當結果為 0 時 exit status 為 1，配合 set -e 會提前終止腳本。
  # 改成 +=1（或 ++var）以確保第一筆時返回值非 1。
  ((skipped+=1))
    continue
  fi

  echo "   🔧 取得 embedding (model=$EMBED_MODEL) ..."
  EMB_RESP=$(curl -s -k -H 'Content-Type: application/json' \
    -d "$(jq -n --arg input "$text" --arg model "$EMBED_MODEL" '{input:$input, model:$model}')" \
    "$EMBED_API_URL" || true)
  if [[ -z "$EMB_RESP" ]]; then
    echo "   ❌ embedding API 無回應，略過" >&2; continue
  fi
  EMB=$(jq -ec '.data[0].embedding' <<<"$EMB_RESP" 2>/dev/null || true)
  if [[ -z "$EMB" || "$EMB" == "null" ]]; then
    echo "   ❌ 解析 embedding 失敗，原始回應: $EMB_RESP" >&2; continue
  fi

  LEN=$(jq -r 'length' <<<"$EMB") || LEN=0
  if [[ "$LEN" -ne "$DIM" ]]; then
    echo "   ⚠️  向量維度 ($LEN) 與期望 ($DIM) 不符，仍嘗試寫入。" >&2
  fi

  DOC_JSON=$(jq -n --arg c "$text" --argjson e "$EMB" '{content:$c, embedding:$e}')
  echo "   📥 寫入 (id=$ID) ..."
  PUT_RESP=$(curl -s -k -u "$OS_USER:$OS_PASS" -X PUT "$OS_URL/$INDEX_NAME/_doc/$ID" -H 'Content-Type: application/json' -d "$DOC_JSON" || true)
  # 顯示結果 (若非 JSON 也列出以利除錯)
  if jq -e . >/dev/null 2>&1 <<<"$PUT_RESP"; then
    echo "$PUT_RESP" | jq '.result,.error?'
  else
    echo "   ⚠️ 非 JSON 回應: $PUT_RESP" >&2
  fi
  # 同上，避免 ((inserted++)) 在 inserted 原值為 0 時返回 1 觸發 set -e
  ((inserted+=1))
done

echo ""
echo "✅ 完成：新增 $inserted 筆，跳過 $skipped 筆。"
