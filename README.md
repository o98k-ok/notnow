# NotNow

macOS 书签管理应用，支持链接与 Snippet 两种书签类型，提供分类、搜索与多来源导入。

## 功能

- **书签管理**：支持链接和 Snippet 两种类型，添加、编辑、分类、批量移动/删除
- **点击行为**：可分别为链接和 Snippet 配置点击 / ⌘+点击行为（浏览器打开、复制、编辑、自定义脚本），单个卡片可通过自定义脚本覆盖全局设置，脚本支持 `{TEXT}` 占位符传参
- **导入**
  - **浏览器书签**：从本机 Chromium 系浏览器书签导入（Chrome、Edge、Brave、Arc、Tabbit），支持选择浏览器与多个 Profile
  - **GitHub Stars**：输入 GitHub 用户名或 profile 链接，拉取公开 star 列表导入（无需 Token，受 API 60 次/小时限制）
  - **Twitter Likes**：增量导入 X(Twitter) 点赞，遇到已有链接即停止
  - **NotNow 备份**：从导出的 .zip 恢复书签、分类与配置
- **可选 AI**：设置中配置自建 API 后，可为书签生成/优化标题、描述与标签
- **外观**：多强调色主题、瀑布流布局、可折叠设置面板

## 环境

- macOS 14+
- Xcode 15+（含 Swift 5、SwiftData、SwiftUI）

## 构建与运行

```bash
# 用 Xcode 打开
open NotNow.xcodeproj

# 或命令行构建 Release 包（产物在 build/export/NotNow.app）
./build.sh
```

## 项目结构

```
NotNow/
├── NotNowApp.swift          # 应用入口、SwiftData 容器
├── Models/                  # Bookmark, Category
├── Views/                   # ContentView、各类 Sheet、Theme
├── Services/                # MetadataService（抓取/AI）、OpenService
├── Resources/               # Assets
build.sh                     # 归档并输出 .app 到 build/export/
project.yml                  # XcodeGen 配置（可选）
```

## 许可

未指定；按需自定。
