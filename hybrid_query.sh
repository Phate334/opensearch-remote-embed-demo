#!/bin/bash
set -euo pipefail

# 混合搜尋：同時執行 BM25 (lexical) 與 向量 (kNN) 查詢，採 Reciprocal Rank Fusion (RRF) 融合結果。
# 依 fused_score 排序後輸出 content，並可選擇翻譯第一筆。
# 需求：已建立索引，文件包含 text 欄位 (content) 與 embedding (knn_vector / dense_vector)。
# 需安裝 jq、curl。
#
# 用法： ./hybrid_query.sh "your query"  或  QUERY_TEXT="your query" ./hybrid_query.sh
# 可覆寫環境變數：
#   OS_URL, OS_USER, OS_PASS, INDEX_NAME,
#   EMBED_API_URL, EMBED_MODEL,
#   LEXICAL_TOP_K, VECTOR_TOP_K, FINAL_TOP_K,
#   RRF_K, WEIGHT_LEXICAL, WEIGHT_VECTOR,
#   TRANSLATE_FIRST, LLM_API_URL
#
# RRF 公式： score = Σ weight_i / (RRF_K + rank_i)  (rank 從 1 起算)

OS_URL="${OS_URL:-https://localhost:9200}"
OS_USER="${OS_USER:-admin}"
OS_PASS="${OS_PASS:-ChangeMeNow!_A1}"
INDEX_NAME="${INDEX_NAME:-test_index}"

EMBED_API_URL="${EMBED_API_URL:-http://localhost:8081/v1/embeddings}"
EMBED_MODEL="${EMBED_MODEL:-e5-large}"

LLM_API_URL="${LLM_API_URL:-http://localhost:8080/v1/chat/completions}"
TRANSLATE_FIRST="${TRANSLATE_FIRST:-1}"

LEXICAL_TOP_K="${LEXICAL_TOP_K:-50}"      # 單純 BM25 取回數量
VECTOR_TOP_K="${VECTOR_TOP_K:-50}"        # 單純向量取回數量
FINAL_TOP_K="${FINAL_TOP_K:-10}"          # 融合後輸出前 N 筆
RRF_K="${RRF_K:-60}"                      # RRF 常數 (常見 60)
WEIGHT_LEXICAL="${WEIGHT_LEXICAL:-1}"      # BM25 權重
WEIGHT_VECTOR="${WEIGHT_VECTOR:-1}"        # 向量權重

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

echo "📝 Lexical (BM25) 查詢 (top $LEXICAL_TOP_K) ..."
LEX_BODY=$(jq -n --arg q "$QUERY_TEXT" --argjson k "$LEXICAL_TOP_K" '{size:$k, _source:["content"], query:{match:{content:$q}}}')
LEX_RESP=$(curl -s -k -u "$OS_USER:$OS_PASS" -X POST "$OS_URL/$INDEX_NAME/_search" -H 'Content-Type: application/json' -d "$LEX_BODY" || true)
if ! jq -e '.hits.hits' >/dev/null 2>&1 <<<"$LEX_RESP"; then
  echo "❌ Lexical 查詢失敗: $LEX_RESP" >&2
  exit 1
fi

echo "🔍 向量 (kNN) 查詢 (top $VECTOR_TOP_K) ..."
VEC_BODY=$(jq -n --argjson v "$EMB" --argjson k "$VECTOR_TOP_K" '{size:$k, _source:["content"], query:{knn:{embedding:{vector:$v, k:$k}}}}')
VEC_RESP=$(curl -s -k -u "$OS_USER:$OS_PASS" -X POST "$OS_URL/$INDEX_NAME/_search" -H 'Content-Type: application/json' -d "$VEC_BODY" || true)
if ! jq -e '.hits.hits' >/dev/null 2>&1 <<<"$VEC_RESP"; then
  echo "❌ 向量查詢失敗: $VEC_RESP" >&2
  exit 1
fi

LEX_HITS=$(jq '.hits.hits' <<<"$LEX_RESP")
VEC_HITS=$(jq '.hits.hits' <<<"$VEC_RESP")

echo "⚗️ 進行 RRF 融合 (RRF_K=$RRF_K, weight_lexical=$WEIGHT_LEXICAL, weight_vector=$WEIGHT_VECTOR) ..."
FUSED=$(jq -n \
  --argjson l "$LEX_HITS" \
  --argjson v "$VEC_HITS" \
  --argjson rrfk "$RRF_K" \
  --argjson wL "$WEIGHT_LEXICAL" \
  --argjson wV "$WEIGHT_VECTOR" \
  --argjson finalK "$FINAL_TOP_K" '
  # 以 _id 為 key，建立 {id: {sourceType: {rank, score, content}}}
  def add_rank(arr; tag):
    reduce range(0; (arr|length)) as $i ({}; . + { (arr[$i]._id): { (tag): { rank: ($i+1), score: arr[$i]._score, content: (arr[$i]._source.content // "") } } });
  # 合併 lexical 與 vector 兩個 map
  (add_rank($l; "lexical") + add_rank($v; "vector"))
  | to_entries
  | map(
      . as $e
      | $e.value as $val
      | {
          id: $e.key,
          content: ($val.lexical.content // $val.vector.content // ""),
          lexical_rank: ($val.lexical.rank // null),
          vector_rank: ($val.vector.rank // null),
          lexical_score: ($val.lexical.score // null),
          vector_score: ($val.vector.score // null),
          fused_score: ((if $val.lexical then ($wL / ($rrfk + $val.lexical.rank)) else 0 end)
                      + (if $val.vector  then ($wV / ($rrfk + $val.vector.rank))  else 0 end))
        }
    )
  | sort_by(-.fused_score)
  | .[:$finalK]
')

COUNT=$(jq 'length' <<<"$FUSED")
if [[ "$COUNT" -eq 0 ]]; then
  echo "(無相似結果)"
  exit 0
fi

echo -e "\n📄 混合結果 (Top $FINAL_TOP_K, 依 fused_score)："
printf "%s\n" "$FUSED" | jq -r 'to_entries | .[] | "\(.key|tonumber+1). [fused=\(.value.fused_score|tostring)] (L#\(.value.lexical_rank//"-"), V#\(.value.vector_rank//"-"))\n\(.value.content)\n"'

if [[ "$TRANSLATE_FIRST" == "1" ]]; then
  echo -e "\n🌐 翻譯第 1 筆內容 -> 繁體中文 (台灣用語) ..."
  FIRST_DOC_CONTENT=$(jq -r '.[0].content' <<<"$FUSED")
  LLM_REQ=$(jq -n --arg sys "Directly translate the user's input into Traditional Chinese using expressions customary in Taiwan; do not include any additional explanations" \
                    --arg user "$FIRST_DOC_CONTENT" '{messages:[{role:"system",content:$sys},{role:"user",content:$user}]}' )
  LLM_RESP=$(curl -s -H 'Content-Type: application/json' -d "$LLM_REQ" "$LLM_API_URL" || true)
  LLM_TEXT=$(jq -r '.choices[0].message.content // empty' <<<"$LLM_RESP" 2>/dev/null || true)
  if [[ -n "$LLM_TEXT" ]]; then
    echo -e "\n🈶 翻譯：\n$LLM_TEXT"
  else
    echo "⚠️ 翻譯失敗，原始回應：$LLM_RESP" >&2
  fi
fi

exit 0
