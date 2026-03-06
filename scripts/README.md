# App Icon 脚本

更新 1024×1024 主图后，按 Apple 规范加透明边距并重新导出各尺寸：

```bash
# 1. 给 Icon-1024.png 加 100px 透明边距（内容 824×824 居中）
swift scripts/icon_add_margin.swift NotNow/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png

# 2. 用 sips 从 Icon-1024.png 生成各尺寸（或由 Xcode 构建时处理）
ICON=NotNow/Resources/Assets.xcassets/AppIcon.appiconset
for s in 16 32 128 256 512; do sips -z $s $s "$ICON/Icon-1024.png" --out "$ICON/icon_${s}x${s}.png"; done
sips -z 32 32 "$ICON/Icon-1024.png" --out "$ICON/icon_16x16@2x.png"
sips -z 64 64 "$ICON/Icon-1024.png" --out "$ICON/icon_32x32@2x.png"
sips -z 256 256 "$ICON/Icon-1024.png" --out "$ICON/icon_128x128@2x.png"
sips -z 512 512 "$ICON/Icon-1024.png" --out "$ICON/icon_256x256@2x.png"
cp "$ICON/Icon-1024.png" "$ICON/icon_512x512@2x.png"
```

## Twitter Likes 导入脚本

`twitter_likes_actionbook.sh` 用 `actionbook` 读取 X(Twitter) 点赞流并输出 URL（每行一个）：

```bash
# 先安装 actionbook CLI（一次性）
npm install -g @actionbookdev/cli

# 运行抓取（需你本机 Chrome 已登录 X）
scripts/twitter_likes_actionbook.sh "https://x.com/<your_username>/likes"
```

说明：
- 脚本会自动滚动并抓取推文链接（`/status/<id>`），输出按时间流顺序去重。
- 可用环境变量调节抓取轮数：`TWITTER_LIKES_MAX_ROUNDS`、`TWITTER_LIKES_IDLE_LIMIT`。

## Twitter 单条推文提取调试

用于调试「正文/封面抓取」选择器是否命中：

```bash
ACTIONBOOK_BIN='/Users/shadow/.nvm/versions/node/v20.20.0/bin/actionbook' \
  scripts/twitter_tweet_extract_debug.sh 'https://x.com/<user>/status/<id>'
```

可选参数：
- `ACTIONBOOK_BROWSER_MODE=extension`（默认）
- `TWITTER_TWEET_SETTLE_SECONDS=4`（页面稳定等待时长）

输出为 JSON，包含：
- article/tweetText/status/media 命中数量
- 首条 article 文本预览
- og:description / og:image
- 状态链接与媒体链接样本

## Raycast Script Commands（NotNow 读取）

新增脚本目录：

- `scripts/raycast/notnow_search.sh`
- `scripts/raycast/notnow_open.sh`

详细接入与使用说明见：

- `docs/raycast-script-commands.md`
