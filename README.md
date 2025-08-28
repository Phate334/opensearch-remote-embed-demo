## OpenSearch Remote Embedding Demo

### 新增的腳本

1. `ensure_index.sh`：檢查並建立 `test_index`（可用 `INDEX_NAME` 覆寫）。若存在則僅顯示維度資訊。預設使用 1024 維 `knn_vector`。
2. `upsert_test_docs.sh`：插入/補齊 5 筆測試文件。以「文件原始內容 SHA256」做為 `_id`，避免重複；已存在則跳過。缺少索引會提示先執行 `ensure_index.sh`。
3. `delete_index.sh`：互動式刪除整個索引（確認後執行 DELETE），用於重建或清空全部資料。
4. `query.sh`：輸入查詢文字，呼叫本地 embedding 服務取得查詢向量並對 OpenSearch 執行 kNN 搜尋；預設顯示前 `TOP_K` (預設 5) 筆 `content`，並自動呼叫 LLM 翻譯第一筆結果為繁體中文（可用 `TRANSLATE_FIRST=0` 關閉）。

### 使用步驟（啟動後）

```bash
# 1. 建立 / 確認索引存在
./ensure_index.sh

# 2. 寫入（或補齊）測試文件
./upsert_test_docs.sh

# 3. 相似度查詢並翻譯第一筆結果
./query.sh "這是一段要查的文字"   # 或 QUERY_TEXT=... ./query.sh

# 若只想看原文不翻譯：
TRANSLATE_FIRST=0 ./query.sh "your query text"
```

### `query.sh` 查詢腳本說明

功能流程：

1. 確認索引存在。
2. 呼叫 embedding 服務 (`/v1/embeddings`) 取得查詢文字向量。
3. 對指定索引執行 kNN (`knn`) 搜尋，取前 `TOP_K` 筆。
4. 以編號列出每筆文件的 `content`。
5. （預設）將第 1 筆內容送至 LLM Chat Completions 端點翻譯成繁體中文（台灣用語）。

使用範例：

```bash
./query.sh "what is vector database"
TOP_K=10 TRANSLATE_FIRST=0 ./query.sh "hybrid search techniques"
```
