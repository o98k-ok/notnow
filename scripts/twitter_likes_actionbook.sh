#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <likes_url>" >&2
  exit 2
fi

LIKES_URL="$1"
MAX_ITEMS="${2:-${TWITTER_LIKES_MAX_ITEMS:-80}}"
if ! [[ "$MAX_ITEMS" =~ ^[0-9]+$ ]] || [[ "$MAX_ITEMS" -le 0 ]]; then
  MAX_ITEMS=80
fi
ACTIONBOOK_BIN="${ACTIONBOOK_BIN:-actionbook}"

if ! command -v "$ACTIONBOOK_BIN" >/dev/null 2>&1; then
  echo "actionbook 不可用: $ACTIONBOOK_BIN" >&2
  echo "请确认路径正确，或安装: npm install -g @actionbookdev/cli" >&2
  exit 127
fi

AB_MODE="${ACTIONBOOK_BROWSER_MODE:-extension}"
DEBUG_MODE="${TWITTER_LIKES_DEBUG:-0}"
PAGE_SETTLE_SECONDS="${TWITTER_LIKES_PAGE_SETTLE_SECONDS:-5}"
ITEM_SETTLE_SECONDS="${TWITTER_LIKES_ITEM_SETTLE_SECONDS:-2}"

TMP_FILE="$(mktemp)"
MAX_ROUNDS="${TWITTER_LIKES_MAX_ROUNDS:-0}"
if ! [[ "$MAX_ROUNDS" =~ ^[0-9]+$ ]] || [[ "$MAX_ROUNDS" -le 0 ]]; then
  # Dynamic default: more target items => more scroll rounds.
  MAX_ROUNDS=$(( MAX_ITEMS * 4 ))
  if [[ "$MAX_ROUNDS" -lt 120 ]]; then MAX_ROUNDS=120; fi
fi
IDLE_LIMIT="${TWITTER_LIKES_IDLE_LIMIT:-8}"
idle_rounds=0

cleanup() {
  "$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser close >/dev/null 2>&1 || true
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

if ! open_err="$("$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser open "$LIKES_URL" 2>&1 >/dev/null)"; then
  echo "open 失败: $open_err" >&2
  exit 1
fi
"$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser wait "body" --timeout 10000 >/dev/null 2>&1 || true
"$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser eval "document.readyState" >/dev/null 2>&1 || true
sleep "$PAGE_SETTLE_SECONDS"
"$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser wait "article" --timeout 10000 >/dev/null 2>&1 || true

collect_urls() {
  local output=""
  local attempt
  for attempt in 1 2 3; do
    output="$(
      "$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser eval "(() => {
        const set = new Set();
        const anchors = document.querySelectorAll('a[href*=\"/status/\"]');
        for (const a of anchors) {
          const rawHref = (a.getAttribute('href') || '').trim();
          if (!rawHref) continue;
          let href = rawHref.split('?')[0];
          if (href.startsWith('/')) href = 'https://x.com' + href;
          try {
            const u = new URL(href, location.origin);
            const m = u.pathname.match(/\\/status\\/(\\d+)/);
            if (!m) continue;
            const pathParts = u.pathname.split('/').filter(Boolean);
            let user = pathParts[0] || 'i';
            if (user === 'i' && pathParts[1] === 'web') user = 'i';
            set.add('https://x.com/' + user + '/status/' + m[1]);
          } catch (_) {}
        }
        return Array.from(set).join('\\n');
      })()" 2>/dev/null || true
    )"
    if [[ -n "${output:-}" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep "$ITEM_SETTLE_SECONDS"
  done
  return 0
}

if [[ "$DEBUG_MODE" == "1" ]]; then
  diag="$(
    "$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser eval "(() => {
      const href = location.href;
      const title = document.title || '';
      const anchors = document.querySelectorAll('a[href*=\"/status/\"]').length;
      const articles = document.querySelectorAll('article').length;
      return JSON.stringify({ href, title, anchors, articles });
    })()" 2>/dev/null || true
  )"
  if [[ -n "${diag:-}" ]]; then
    echo "[debug] page=$diag" >&2
  else
    echo "[debug] page=unavailable" >&2
  fi

  body_preview="$(
    "$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser eval "(() => {
      const t = (document.body && document.body.innerText) ? document.body.innerText : '';
      return t.slice(0, 300);
    })()" 2>/dev/null || true
  )"
  if [[ -n "${body_preview:-}" ]]; then
    one_line="$(printf '%s' "$body_preview" | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g')"
    echo "[debug] body=${one_line}" >&2
  else
    echo "[debug] body=unavailable" >&2
  fi
fi

for ((i = 0; i < MAX_ROUNDS; i++)); do
  before_count="$(wc -l < "$TMP_FILE" | tr -d ' ')"

  urls="$(collect_urls)"
  # actionbook eval may return quoted/escaped strings; normalize to raw lines
  if [[ "${urls:-}" == \"*\" && "${urls:-}" == *\" ]]; then
    urls="${urls:1:${#urls}-2}"
  fi
  urls="$(printf '%b' "${urls//\\n/$'\n'}" | sed 's#\\/#/#g; s/\\"/"/g')"

  if [[ -n "${urls:-}" ]]; then
    while IFS= read -r line; do
      line="${line//$'\r'/}"
      line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^https?:// ]] || continue
      echo "$line" >> "$TMP_FILE"
    done <<< "$urls"
  fi

  awk '!seen[$0]++' "$TMP_FILE" > "$TMP_FILE.new" && mv "$TMP_FILE.new" "$TMP_FILE"
  after_count="$(wc -l < "$TMP_FILE" | tr -d ' ')"
  if [[ "$after_count" -ge "$MAX_ITEMS" ]]; then
    break
  fi

  if [[ "$after_count" -le "$before_count" ]]; then
    idle_rounds=$((idle_rounds + 1))
    # Give feed extra time when no immediate new cards appeared.
    sleep $((ITEM_SETTLE_SECONDS + 2))
  else
    idle_rounds=0
  fi

  if [[ "$idle_rounds" -ge "$IDLE_LIMIT" ]]; then
    break
  fi

  "$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser eval "window.scrollBy(0, Math.floor(window.innerHeight * 1.6)); 'ok'" >/dev/null 2>&1 || true
  sleep "$ITEM_SETTLE_SECONDS"
done

head -n "$MAX_ITEMS" "$TMP_FILE"
