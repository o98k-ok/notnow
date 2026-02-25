# NotNow

macOS 书签管理应用，支持分类、搜索与多来源导入。

## 功能

- **书签管理**：添加、编辑、分类、批量移动/删除
- **导入**
  - **Chrome**：从本机 Chrome 书签文件导入
  - **GitHub Stars**：输入 GitHub 用户名或 profile 链接，拉取公开 star 列表导入（无需 Token，受 API 60 次/小时限制）
- **可选 AI**：设置中配置自建 API 后，可为书签生成/优化标题、描述与标签
- **外观**：多强调色、瀑布流布局、悬停预览

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
