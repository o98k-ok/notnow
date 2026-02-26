#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <tweet_url>" >&2
  exit 2
fi

TWEET_URL="$1"
ACTIONBOOK_BIN="${ACTIONBOOK_BIN:-actionbook}"
AB_MODE="${ACTIONBOOK_BROWSER_MODE:-extension}"
SETTLE_SECONDS="${TWITTER_TWEET_SETTLE_SECONDS:-4}"

if ! command -v "$ACTIONBOOK_BIN" >/dev/null 2>&1; then
  echo "actionbook not found: $ACTIONBOOK_BIN" >&2
  exit 127
fi

cleanup() {
  "$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser close >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! "$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser open "$TWEET_URL" >/dev/null 2>&1; then
  echo "open failed" >&2
  exit 1
fi

"$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser wait "body" --timeout 15000 >/dev/null 2>&1 || true
"$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser wait "article" --timeout 15000 >/dev/null 2>&1 || true
sleep "$SETTLE_SECONDS"

JS='(() => {
  const href = location.href;
  const title = document.title || "";
  const articles = Array.from(document.querySelectorAll("article"));
  const tweetTextNodes = Array.from(document.querySelectorAll("[data-testid=\"tweetText\"]"));
  const statusAnchors = Array.from(document.querySelectorAll("a[href*=\"/status/\"]"));
  const mediaImgsAll = Array.from(document.querySelectorAll("img[src*=\"pbs.twimg.com\"]"));
  const mediaImgs = mediaImgsAll
    .map(i => i.getAttribute("src") || "")
    .filter(src => src.includes("pbs.twimg.com/media/") && !src.includes("profile_images"));

  let firstArticleText = "";
  if (articles.length > 0) {
    const nodes = Array.from(articles[0].querySelectorAll("[data-testid=\"tweetText\"]"));
    firstArticleText = nodes.map(n => n.innerText || "").join("\n").trim();
  }

  const ogDesc = document.querySelector("meta[property=\"og:description\"]")?.content || "";
  const ogImage = document.querySelector("meta[property=\"og:image\"]")?.content || "";

  const statusSamples = statusAnchors.slice(0, 8).map(a => a.getAttribute("href") || "");
  const textSamples = tweetTextNodes.slice(0, 5).map(n => (n.innerText || "").slice(0, 140));
  const mediaSamples = mediaImgs.slice(0, 8);

  return JSON.stringify({
    href,
    title,
    counts: {
      articles: articles.length,
      tweetTextNodes: tweetTextNodes.length,
      statusAnchors: statusAnchors.length,
      mediaImgsAll: mediaImgsAll.length,
      mediaImgs: mediaImgs.length
    },
    firstArticleTextLen: firstArticleText.length,
    firstArticleTextPreview: firstArticleText.slice(0, 280),
    meta: {
      ogDescription: ogDesc.slice(0, 280),
      ogImage
    },
    samples: {
      statusAnchors: statusSamples,
      tweetTexts: textSamples,
      mediaImgs: mediaSamples
    }
  }, null, 2);
})()'

OUT="$("$ACTIONBOOK_BIN" --browser-mode "$AB_MODE" browser eval "$JS" 2>/dev/null || true)"

if [[ -z "${OUT:-}" ]]; then
  echo "eval returned empty output" >&2
  exit 1
fi

if [[ "${OUT}" == \"*\" && "${OUT}" == *\" ]]; then
  OUT="${OUT:1:${#OUT}-2}"
  OUT="$(printf '%s' "$OUT" | sed 's#\\/#/#g; s/\\"/"/g')"
fi

printf '%s\n' "$OUT"
