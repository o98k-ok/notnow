#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <tweet_url>" >&2
  exit 2
fi

TWEET_URL="$1"
ACTIONBOOK_BIN="${ACTIONBOOK_BIN:-actionbook}"
AB_MODE="${ACTIONBOOK_BROWSER_MODE:-extension}"
SETTLE_SECONDS="${TWITTER_TWEET_SETTLE_SECONDS:-8}"

if ! command -v "$ACTIONBOOK_BIN" >/dev/null 2>&1; then
  echo "actionbook not found: $ACTIONBOOK_BIN" >&2
  exit 127
fi

cleanup() {
  "$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser close >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser close >/dev/null 2>&1 || true
"$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser open "$TWEET_URL" >/dev/null 2>&1 || true
"$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser wait "body" --timeout 10000 >/dev/null 2>&1 || true
"$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser wait "article" --timeout 10000 >/dev/null 2>&1 || true
sleep "$SETTLE_SECONDS"

JS='(() => {
  const m = location.pathname.match(/\/status\/(\d+)/);
  const wantedId = m ? m[1] : "";
  const allArticles = Array.from(document.querySelectorAll("article"));
  let target = null;
  if (wantedId) {
    for (const a of allArticles) {
      const link = a.querySelector(`a[href*="/status/${wantedId}"]`);
      if (link) { target = a; break; }
    }
  }
  if (!target) target = allArticles[0] || null;

  const textNodes = target ? Array.from(target.querySelectorAll("[data-testid=\"tweetText\"]")) : [];
  let text = textNodes.map(n => n.innerText || "").join("\n").trim();
  if (!text) {
    text = document.querySelector("meta[property=\"og:description\"]")?.content
      || document.querySelector("meta[name=\"description\"]")?.content
      || "";
    text = text.trim();
  }

  const imgs = target ? Array.from(target.querySelectorAll("img[src*=\"pbs.twimg.com\"]")) : [];
  let media = imgs
    .map(i => i.getAttribute("src") || "")
    .filter(src => src.includes("pbs.twimg.com/media/") && !src.includes("profile_images"));
  if (media.length === 0) {
    const ogImage = document.querySelector("meta[property=\"og:image\"]")?.content || "";
    if (ogImage.includes("pbs.twimg.com/media/")) media = [ogImage];
  }

  const title = (document.title || "").trim();
  return JSON.stringify({
    text,
    image_url: media.length > 0 ? media[0] : "",
    title
  });
})()'

OUT="$("$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser eval "$JS" 2>/dev/null || true)"
if [[ -z "${OUT:-}" ]]; then
  exit 1
fi

if [[ "${OUT}" == \"*\" && "${OUT}" == *\" ]]; then
  OUT="${OUT:1:${#OUT}-2}"
  OUT="$(printf '%s' "$OUT" | sed 's#\\/#/#g; s/\\"/"/g')"
fi

printf '%s\n' "$OUT"
