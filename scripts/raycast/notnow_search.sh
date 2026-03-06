#!/usr/bin/env bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title NotNow Search
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.icon 🔎
# @raycast.packageName NotNow
# @raycast.argument1 { "type": "text", "placeholder": "keyword", "optional": false }
# @raycast.argument2 { "type": "text", "placeholder": "limit (default 8, max 20)", "optional": true }
#
# Documentation:
# @raycast.description Search NotNow bookmarks/snippets/tasks/apis from local SwiftData store
# @raycast.author shadow
# @raycast.authorURL https://github.com/o98k-ok
#
# NeoShell metadata (compatible):
# @ai-shell
# @name NotNow Search
# @tags notnow,search,list
# @arg keyword:string:关键词:输入搜索关键词
# @arg limit:string:返回数量(默认8):输入 1-20
# @output list

set -euo pipefail

STORE_PATH="${NOTNOW_STORE_PATH:-$HOME/Library/Application Support/default.store}"
QUERY_RAW="${ARG_KEYWORD:-${1:-}}"
LIMIT_RAW="${ARG_LIMIT:-${2:-8}}"
MAX_LIMIT=20

trim() {
  local input="$1"
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  printf "%s" "$input"
}

escape_like_literal() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//%/\\%}"
  value="${value//_/\\_}"
  value="$(printf "%s" "$value" | sed "s/'/''/g")"
  printf "%s" "$value"
}

escape_sql_literal() {
  local value="$1"
  value="$(printf "%s" "$value" | sed "s/'/''/g")"
  printf "%s" "$value"
}

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Error: sqlite3 is not installed." >&2
  exit 127
fi

if [[ ! -f "$STORE_PATH" ]]; then
  echo "Error: NotNow store not found: $STORE_PATH" >&2
  echo "Hint: set NOTNOW_STORE_PATH if your store is in a custom location." >&2
  exit 1
fi

QUERY="$(trim "$QUERY_RAW")"
if [[ -z "$QUERY" ]]; then
  echo "Usage: NotNow Search <keyword> [limit]" >&2
  exit 2
fi

if [[ ! "$LIMIT_RAW" =~ ^[0-9]+$ ]]; then
  LIMIT_RAW=8
fi
if (( LIMIT_RAW < 1 )); then LIMIT_RAW=1; fi
if (( LIMIT_RAW > MAX_LIMIT )); then LIMIT_RAW=$MAX_LIMIT; fi
LIMIT="$LIMIT_RAW"

QUERY_ESCAPED="$(escape_like_literal "$QUERY")"
QUERY_LITERAL="$(escape_sql_literal "$QUERY")"

where_clause="(
  lower(COALESCE(b.ZTITLE, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\'
  OR lower(COALESCE(b.ZURL, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\'
  OR lower(COALESCE(b.ZDESC, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\'
  OR lower(COALESCE(b.ZNOTES, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\'
  OR lower(COALESCE(b.ZSNIPPETCONTENT, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\'
)"

read_sql="
WITH ranked AS (
  SELECT
    lower(hex(b.ZID)) AS id,
    REPLACE(REPLACE(COALESCE(NULLIF(trim(b.ZTITLE), ''), '(untitled)'), char(10), ' '), char(9), ' ') AS title,
    COALESCE(NULLIF(trim(b.ZURL), ''), '') AS url,
    COALESCE(NULLIF(trim(b.ZKIND), ''), 'link') AS kind,
    COALESCE(NULLIF(trim(c.ZNAME), ''), 'Uncategorized') AS category,
    COALESCE(b.ZDESC, '') AS desc,
    COALESCE(NULLIF(trim(b.ZOPENWITHAPP), ''), '') AS open_with_app,
    COALESCE(NULLIF(trim(b.ZOPENWITHSCRIPT), ''), '') AS open_with_script,
    COALESCE(b.ZSNIPPETCONTENT, '') AS snippet_content,
    COALESCE(b.ZISCOMPLETED, 0) AS is_completed,
    COALESCE(b.ZDUEDATE, 0) AS due_date_raw,
    COALESCE(NULLIF(trim(b.ZAPIMETHOD), ''), '') AS api_method,
    COALESCE(NULLIF(trim(b.ZAPIQUERYPARAMS), ''), '') AS api_query_params,
    COALESCE(hex(b.ZTAGS), '') AS tags_blob_hex,
    COALESCE(b.ZUPDATEDAT, 0) AS updated_at_raw,
    (
      CASE WHEN lower(COALESCE(b.ZTITLE, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 60 ELSE 0 END +
      CASE WHEN lower(COALESCE(b.ZURL, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 30 ELSE 0 END +
      CASE WHEN lower(COALESCE(b.ZDESC, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 24 ELSE 0 END +
      CASE WHEN lower(COALESCE(b.ZNOTES, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 18 ELSE 0 END +
      CASE WHEN lower(COALESCE(b.ZSNIPPETCONTENT, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 18 ELSE 0 END +
      (COALESCE(b.ZUPDATEDAT, 0) / 31557600.0)
    ) AS score
  FROM ZBOOKMARK b
  LEFT JOIN ZCATEGORY c ON c.Z_PK = b.ZCATEGORY
  WHERE $where_clause
),
limited AS (
  SELECT
    id,
    title,
    url,
    kind,
    category,
    desc,
    open_with_app,
    open_with_script,
    snippet_content,
    is_completed,
    due_date_raw,
    api_method,
    api_query_params,
    tags_blob_hex
  FROM ranked
  ORDER BY score DESC, updated_at_raw DESC
  LIMIT $LIMIT
)
SELECT
  json_object(
    'ok', 1,
    'query', '$QUERY_LITERAL',
    'total', (SELECT COUNT(*) FROM ranked),
    'limit', $LIMIT,
    'results', COALESCE(
      (
        SELECT json_group_array(
          json_object(
            'id', x.id,
            'title', x.title,
            'url', x.url,
            'kind', x.kind,
            'category', x.category,
            'desc', x.desc,
            'open_with_app', x.open_with_app,
            'open_with_script', x.open_with_script,
            'snippet_content', x.snippet_content,
            'is_completed', x.is_completed,
            'due_date_raw', x.due_date_raw,
            'api_method', x.api_method,
            'api_query_params', x.api_query_params,
            'tags_blob_hex', x.tags_blob_hex
          )
        )
        FROM (
          SELECT
            id,
            title,
            url,
            kind,
            category,
            desc,
            open_with_app,
            open_with_script,
            snippet_content,
            is_completed,
            due_date_raw,
            api_method,
            api_query_params,
            tags_blob_hex
          FROM limited
        ) AS x
      ),
      json('[]')
    )
  );
"

RESULT_JSON="$(sqlite3 -noheader "$STORE_PATH" "$read_sql" 2>/dev/null || true)"

if [[ -z "$RESULT_JSON" ]]; then
  echo "{\"ok\":0,\"error\":\"query_failed\"}"
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Error: swift is not installed." >&2
  exit 127
fi

JSON_TMP="$(mktemp)"
SWIFT_CACHE_DIR="$(mktemp -d)"
cleanup() {
  rm -f "$JSON_TMP"
  rm -rf "$SWIFT_CACHE_DIR"
}
trap cleanup EXIT
printf "%s" "$RESULT_JSON" > "$JSON_TMP"

RESULT_JSON="$(SWIFT_MODULECACHE_PATH="$SWIFT_CACHE_DIR" CLANG_MODULE_CACHE_PATH="$SWIFT_CACHE_DIR" swift - "$JSON_TMP" <<'SWIFT'
import Foundation

func stringValue(_ value: Any?) -> String {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return ""
}

func doubleValue(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

func boolValue(_ value: Any?) -> Bool {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.intValue != 0 }
    if let s = value as? String, let n = Int(s) { return n != 0 }
    return false
}

func normalizedKind(_ raw: String) -> String {
    switch raw.lowercased() {
    case "link", "snippet", "task", "api":
        return raw.lowercased()
    default:
        return "link"
    }
}

func dataFromHex(_ hex: String) -> Data? {
    let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
    var data = Data(capacity: cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

func decodeTags(from hex: String) -> [String] {
    guard let blob = dataFromHex(hex) else { return [] }
    do {
        if let tags = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, NSString.self],
            from: blob
        ) as? [String] {
            return tags
        }
    } catch {
        return []
    }
    return []
}

func iso8601FromAppleReference(_ raw: Double?) -> String? {
    guard let raw, raw > 0 else { return nil }
    let unixTime = raw + 978307200
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: unixTime))
}

guard CommandLine.arguments.count >= 2 else {
    print("{\"ok\":0,\"error\":\"query_failed\"}")
    exit(1)
}

let path = CommandLine.arguments[1]
let inputData = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
let parsed = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any]

guard var root = parsed else {
    print("{\"ok\":0,\"error\":\"query_failed\"}")
    exit(1)
}

let rawResults = root["results"] as? [[String: Any]] ?? []
var transformed: [[String: Any]] = []
transformed.reserveCapacity(rawResults.count)

for row in rawResults {
    let kind = normalizedKind(stringValue(row["kind"]))
    let desc = stringValue(row["desc"])
    let tags = decodeTags(from: stringValue(row["tags_blob_hex"]))

    var item: [String: Any] = [
        "id": stringValue(row["id"]),
        "title": stringValue(row["title"]),
        "url": stringValue(row["url"]),
        "kind": kind,
        "category": stringValue(row["category"])
    ]

    switch kind {
    case "snippet":
        item["desc"] = desc
        item["tags"] = tags
        item["snippetContent"] = stringValue(row["snippet_content"])
    case "task":
        item["desc"] = desc
        item["tags"] = tags
        item["isCompleted"] = boolValue(row["is_completed"])
        if let dueDate = iso8601FromAppleReference(doubleValue(row["due_date_raw"])) {
            item["dueDate"] = dueDate
        } else {
            item["dueDate"] = NSNull()
        }
    case "api":
        item["desc"] = desc
        item["tags"] = tags
        let method = stringValue(row["api_method"])
        item["apiMethod"] = method.isEmpty ? "GET" : method
        item["apiQueryParams"] = stringValue(row["api_query_params"])
    default:
        item["desc"] = desc
        item["tags"] = tags
        item["openWithApp"] = stringValue(row["open_with_app"])
        item["openWithScript"] = stringValue(row["open_with_script"])
    }

    transformed.append(item)
}

root["results"] = transformed

guard let outputData = try? JSONSerialization.data(withJSONObject: root),
      let output = String(data: outputData, encoding: .utf8) else {
    print("{\"ok\":0,\"error\":\"query_failed\"}")
    exit(1)
}

print(output)
SWIFT
)"

if [[ -z "$RESULT_JSON" ]]; then
  echo "{\"ok\":0,\"error\":\"query_failed\"}"
  exit 1
fi

printf "%s\n" "$RESULT_JSON"
