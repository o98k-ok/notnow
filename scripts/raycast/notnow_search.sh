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
STORE_LITERAL="$(escape_sql_literal "$STORE_PATH")"

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
    COALESCE(b.ZISFAVORITE, 0) AS favorite,
    COALESCE(b.ZUPDATEDAT, 0) AS updated_at_raw,
    datetime(COALESCE(b.ZUPDATEDAT, 0) + 978307200, 'unixepoch', 'localtime') AS updated_at,
    COALESCE(NULLIF(trim(b.ZCOVERURL), ''), '') AS cover_url,
    CASE WHEN b.ZCOVERDATA IS NOT NULL THEN 1 ELSE 0 END AS has_cover_data,
    REPLACE(REPLACE(substr(COALESCE(b.ZSNIPPETCONTENT, ''), 1, 240), char(10), ' '), char(9), ' ') AS snippet_preview,
    COALESCE(NULLIF(trim(b.ZSNIPPETLANGUAGE), ''), '') AS snippet_language,
    COALESCE(NULLIF(trim(b.ZAPIMETHOD), ''), '') AS api_method,
    COALESCE(NULLIF(trim(b.ZAPIBODYTYPE), ''), '') AS api_body_type,
    (
      CASE
        WHEN COALESCE(NULLIF(trim(b.ZCOVERURL), ''), '') <> '' THEN 'cover_url'
        WHEN b.ZCOVERDATA IS NOT NULL THEN 'cover_data'
        ELSE 'none'
      END
    ) AS media_source,
    (
      CASE WHEN lower(COALESCE(b.ZTITLE, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 60 ELSE 0 END +
      CASE WHEN lower(COALESCE(b.ZURL, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 30 ELSE 0 END +
      CASE WHEN lower(COALESCE(b.ZDESC, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 24 ELSE 0 END +
      CASE WHEN lower(COALESCE(b.ZNOTES, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 18 ELSE 0 END +
      CASE WHEN lower(COALESCE(b.ZSNIPPETCONTENT, '')) LIKE lower('%$QUERY_ESCAPED%') ESCAPE '\\' THEN 18 ELSE 0 END +
      CASE WHEN COALESCE(b.ZISFAVORITE, 0) = 1 THEN 6 ELSE 0 END +
      (COALESCE(b.ZUPDATEDAT, 0) / 31557600.0)
    ) AS score
  FROM ZBOOKMARK b
  LEFT JOIN ZCATEGORY c ON c.Z_PK = b.ZCATEGORY
  WHERE $where_clause
),
ordered AS (
  SELECT
    ROW_NUMBER() OVER (ORDER BY score DESC, updated_at_raw DESC) AS rank,
    id,
    title,
    url,
    kind,
    category,
    favorite,
    updated_at,
    cover_url,
    has_cover_data,
    snippet_preview,
    snippet_language,
    api_method,
    api_body_type,
    media_source,
    score
  FROM ranked
),
limited AS (
  SELECT * FROM ordered WHERE rank <= $LIMIT
)
SELECT
  json_object(
    'ok', 1,
    'output_mode', 'list',
    'query', '$QUERY_LITERAL',
    'store', '$STORE_LITERAL',
    'total', (SELECT COUNT(*) FROM ordered),
    'limit', $LIMIT,
    'results', COALESCE(
      (
          SELECT json_group_array(
          json_object(
            'rank', x.rank,
            'id', x.id,
            'title', x.title,
            'url', x.url,
            'kind', x.kind,
            'category', x.category,
            'favorite', x.favorite,
            'updated_at', x.updated_at,
            'score', round(x.score, 2),
            'cover_url', x.cover_url,
            'has_cover_data', x.has_cover_data,
            'material', json_object(
              'media_source', x.media_source,
              'snippet_preview', x.snippet_preview,
              'snippet_language', x.snippet_language,
              'api_method', x.api_method,
              'api_body_type', x.api_body_type
            )
          )
        )
        FROM (
          SELECT
            rank,
            id,
            title,
            url,
            kind,
            category,
            favorite,
            updated_at,
            score,
            cover_url,
            has_cover_data,
            snippet_preview,
            snippet_language,
            api_method,
            api_body_type,
            media_source
          FROM limited
          ORDER BY rank
        ) AS x
      ),
      json('[]')
    ),
    'items', COALESCE(
      (
        SELECT json_group_array(
          json_object(
            'id', x.id,
            'title', x.title,
            'subtitle', x.category || ' · ' || x.kind,
            'url', CASE
              WHEN lower(x.url) LIKE 'http://%' OR lower(x.url) LIKE 'https://%' THEN x.url
              ELSE ''
            END,
            'accessories', json('[]'),
            'keywords', json_array(x.title, x.kind, x.category, x.url)
          )
        )
        FROM (
          SELECT
            id,
            title,
            url,
            kind,
            category,
            updated_at
          FROM limited
          ORDER BY rank
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

printf "%s\n" "$RESULT_JSON"
