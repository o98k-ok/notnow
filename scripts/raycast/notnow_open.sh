#!/usr/bin/env bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title NotNow Open
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.packageName NotNow
# @raycast.argument1 { "type": "text", "placeholder": "target (id/title/url/keyword)", "optional": false }
# @raycast.argument2 { "type": "text", "placeholder": "mode: auto|id|url|title|keyword", "optional": true }
#
# Documentation:
# @raycast.description Open exactly one NotNow result; ambiguous matches are never opened
# @raycast.author shadow
# @raycast.authorURL https://github.com/o98k-ok

set -euo pipefail

STORE_PATH="${NOTNOW_STORE_PATH:-$HOME/Library/Application Support/default.store}"
TARGET_RAW="${1:-}"
MODE_RAW="${2:-auto}"
MAX_AMBIGUOUS=10

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

TARGET="$(trim "$TARGET_RAW")"
if [[ -z "$TARGET" ]]; then
  echo "Usage: NotNow Open <target> [mode]" >&2
  exit 2
fi

MODE="$(printf "%s" "$MODE_RAW" | tr '[:upper:]' '[:lower:]')"
case "$MODE" in
  auto|id|url|title|keyword) ;;
  *) MODE="auto" ;;
esac

TARGET_LITERAL="$(escape_sql_literal "$TARGET")"
TARGET_LIKE_ESCAPED="$(escape_like_literal "$TARGET")"
TARGET_ID_LOWER="$(printf "%s" "$TARGET" | tr '[:upper:]' '[:lower:]')"
TARGET_ID_LITERAL="$(escape_sql_literal "$TARGET_ID_LOWER")"

base_from="FROM ZBOOKMARK b LEFT JOIN ZCATEGORY c ON c.Z_PK = b.ZCATEGORY"
score_expr="(
  CASE WHEN lower(COALESCE(b.ZTITLE, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\' THEN 60 ELSE 0 END +
  CASE WHEN lower(COALESCE(b.ZURL, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\' THEN 30 ELSE 0 END +
  CASE WHEN lower(COALESCE(b.ZDESC, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\' THEN 24 ELSE 0 END +
  CASE WHEN lower(COALESCE(b.ZNOTES, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\' THEN 18 ELSE 0 END +
  CASE WHEN lower(COALESCE(b.ZSNIPPETCONTENT, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\' THEN 18 ELSE 0 END +
  CASE WHEN COALESCE(b.ZISFAVORITE, 0) = 1 THEN 6 ELSE 0 END +
  (COALESCE(b.ZUPDATEDAT, 0) / 31557600.0)
)"

id_where="lower(hex(b.ZID)) = '$TARGET_ID_LITERAL'"
url_where="lower(trim(COALESCE(b.ZURL, ''))) = lower(trim('$TARGET_LITERAL'))"
title_where="lower(trim(COALESCE(b.ZTITLE, ''))) = lower(trim('$TARGET_LITERAL'))"
keyword_where="(
  lower(COALESCE(b.ZTITLE, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\'
  OR lower(COALESCE(b.ZURL, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\'
  OR lower(COALESCE(b.ZDESC, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\'
  OR lower(COALESCE(b.ZNOTES, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\'
  OR lower(COALESCE(b.ZSNIPPETCONTENT, '')) LIKE lower('%$TARGET_LIKE_ESCAPED%') ESCAPE '\\'
)"

count_matches() {
  local where_clause="$1"
  local sql="SELECT COUNT(*) $base_from WHERE $where_clause;"
  sqlite3 "$STORE_PATH" "$sql" 2>/dev/null || echo 0
}

print_ambiguous() {
  local where_clause="$1"
  local order_clause="$2"
  local show_mode="$3"
  local sql="
WITH matched AS (
  SELECT
    lower(hex(b.ZID)) AS id,
    REPLACE(REPLACE(COALESCE(NULLIF(trim(b.ZTITLE), ''), '(untitled)'), char(10), ' '), char(9), ' ') AS title,
    COALESCE(NULLIF(trim(b.ZURL), ''), '') AS url,
    COALESCE(NULLIF(trim(b.ZKIND), ''), 'link') AS kind,
    COALESCE(NULLIF(trim(c.ZNAME), ''), 'Uncategorized') AS category,
    datetime(COALESCE(b.ZUPDATEDAT, 0) + 978307200, 'unixepoch', 'localtime') AS updated_at,
    $score_expr AS score,
    COALESCE(b.ZUPDATEDAT, 0) AS updated_at_raw
    $base_from
  WHERE $where_clause
),
ordered AS (
  SELECT
    ROW_NUMBER() OVER (ORDER BY $order_clause) AS rank,
    id, title, url, kind, category, updated_at, score
  FROM matched
)
SELECT rank, id, title, url, kind, category, updated_at, printf('%.2f', score)
FROM ordered
LIMIT $MAX_AMBIGUOUS;
"
  echo "Ambiguous target. mode=$show_mode target=$TARGET"
  echo "Multiple matches found. Please copy id from below and rerun:"
  echo "NotNow Open <id> id"
  echo
  while IFS=$'\t' read -r rank id title url kind category updated_at score; do
    printf "[%s] id=%s | kind=%s | category=%s | updated=%s | score=%s\n" "$rank" "$id" "$kind" "$category" "$updated_at" "$score"
    printf "    title=%s\n" "$title"
    if [[ -n "$url" ]]; then
      printf "    url=%s\n" "$url"
    fi
    echo
  done < <(sqlite3 -tabs -noheader "$STORE_PATH" "$sql")
}

select_and_open_unique() {
  local where_clause="$1"
  local order_clause="$2"
  local show_mode="$3"
  local sql="
WITH matched AS (
  SELECT
    lower(hex(b.ZID)) AS id,
    REPLACE(REPLACE(COALESCE(NULLIF(trim(b.ZTITLE), ''), '(untitled)'), char(10), ' '), char(9), ' ') AS title,
    COALESCE(NULLIF(trim(b.ZURL), ''), '') AS url,
    COALESCE(NULLIF(trim(b.ZKIND), ''), 'link') AS kind,
    COALESCE(NULLIF(trim(c.ZNAME), ''), 'Uncategorized') AS category,
    datetime(COALESCE(b.ZUPDATEDAT, 0) + 978307200, 'unixepoch', 'localtime') AS updated_at,
    $score_expr AS score,
    COALESCE(b.ZUPDATEDAT, 0) AS updated_at_raw
    $base_from
  WHERE $where_clause
)
SELECT
  id, title, url, kind, category, updated_at, printf('%.2f', score)
FROM matched
ORDER BY $order_clause
LIMIT 1;
"
  local row
  row="$(sqlite3 -tabs -noheader "$STORE_PATH" "$sql" || true)"
  if [[ -z "$row" ]]; then
    return 1
  fi
  local id title url kind category updated_at score
  IFS=$'\t' read -r id title url kind category updated_at score <<<"$row"

  echo "Selected (mode=$show_mode)"
  echo "id=$id"
  echo "title=$title"
  echo "kind=$kind | category=$category | updated=$updated_at | score=$score"
  echo "url=$url"

  if [[ "$url" =~ ^https?:// ]]; then
    open "$url"
    echo "Opened in browser."
    return 0
  fi

  echo "Skipped: this result is not an http(s) URL."
  echo "Use NotNow app for snippet/task/api local actions."
  return 0
}

try_mode() {
  local mode_name="$1"
  local where_clause="$2"
  local order_clause="$3"
  local count
  count="$(count_matches "$where_clause")"
  if [[ "$count" == "1" ]]; then
    select_and_open_unique "$where_clause" "$order_clause" "$mode_name"
    return 0
  fi
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 1 )); then
    print_ambiguous "$where_clause" "$order_clause" "$mode_name"
    return 0
  fi
  return 1
}

if [[ "$MODE" == "auto" ]]; then
  try_mode "id" "$id_where" "updated_at_raw DESC" && exit 0
  try_mode "url" "$url_where" "updated_at_raw DESC" && exit 0
  try_mode "title" "$title_where" "updated_at_raw DESC" && exit 0
  try_mode "keyword" "$keyword_where" "score DESC, updated_at_raw DESC" && exit 0
  echo "No match for target: $TARGET"
  exit 1
fi

case "$MODE" in
  id)
    try_mode "id" "$id_where" "updated_at_raw DESC" && exit 0
    ;;
  url)
    try_mode "url" "$url_where" "updated_at_raw DESC" && exit 0
    ;;
  title)
    try_mode "title" "$title_where" "updated_at_raw DESC" && exit 0
    ;;
  keyword)
    try_mode "keyword" "$keyword_where" "score DESC, updated_at_raw DESC" && exit 0
    ;;
esac

echo "No match for mode=$MODE target: $TARGET"
exit 1
