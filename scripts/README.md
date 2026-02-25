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
