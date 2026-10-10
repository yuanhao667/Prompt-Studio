<p align="center">
  <img src="docs/readme-icon.svg" width="96" alt="Prompt Studio app icon">
</p>

<h1 align="center">Prompt Studio</h1>

<p align="center">
  面向结构化 Prompt 的本地原生 macOS 工作台。<br>
  写工作稿、与 AI 参考稿并排比较，并把每一次正式版本留在自己的电脑里。
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-FB923C?style=flat-square&amp;labelColor=111827"></a>
  <img alt="Stage Prototype" src="https://img.shields.io/badge/Stage-Prototype-F59E0B?style=flat-square&amp;labelColor=111827">
  <img alt="macOS 13 or later" src="https://img.shields.io/badge/macOS-13%2B-FFFFFF?style=flat-square&amp;labelColor=111827&amp;logo=apple&amp;logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Architecture-Apple_Silicon-4F8FF7?style=flat-square&amp;labelColor=111827">
  <img alt="SwiftUI native app" src="https://img.shields.io/badge/SwiftUI-Native-F05138?style=flat-square&amp;labelColor=111827&amp;logo=swift&amp;logoColor=white">
</p>

<p align="center">
  <a href="#about">产品简介</a>
  ·
  <a href="#core-workflow">核心工作流</a>
  ·
  <a href="#features">当前能力</a>
  ·
  <a href="#data">文件与数据</a>
  ·
  <a href="#run-app">下载安装</a>
  ·
  <a href="#license">开源许可</a>
</p>

<p align="center">
  <a href="#core-workflow"><img src="docs/readme-hero.svg" width="100%" alt="Prompt Studio：结构化编辑、AI 对照与版本历史工作流"></a>
</p>

<a id="about"></a>

## ✨ 这是什么

Prompt Studio 是一个原生、本地优先的 Prompt 编辑器。它把 Prompt 当作有结构的 Markdown 文档，而不是一段散落在聊天框里的文本：当前工作稿实时写回 `.md`，只有明确选择“保存新版本”时，才创建不可变的 `Vn.md` 历史快照。

当前仓库是第一阶段原型，重点验证从编辑、AI 辅助到版本回溯的完整闭环。

<a id="core-workflow"></a>

## 🧭 核心工作流

1. **组织** — 新建或打开本地 Prompt 文件夹，在左侧文件树管理结构化 Markdown 文档。
2. **比较** — 在当前编辑区并排选择工作稿、历史版本或 AI 参考稿；右侧标出文字变化，也可使用同一条测试输入比较输出效果。
3. **沉淀** — 工作稿自动保存；对比中的修改可恢复，点击“应用”后才更新工作稿，点击“保存为新版本”创建不可变历史快照。

<a id="features"></a>

## 🧩 当前能力

| 能力 | 现在可以做什么 |
| --- | --- |
| 本地工作区 | 新建多层文件夹；文件与文件夹均可拖入、拖出、混合排序，顺序自动保存 |
| 文件重命名 | 文件的“…”和右键菜单均可改名；工作稿、历史版本可分别改名，保留历史内容和排序 |
| 结构化编辑 | 默认直接编辑正文；开启“框架”后按维度编辑，支持新增、删除、改名、隐藏与拖动排序 |
| AI 对照 | 使用 DeepSeek V4.1 Flash（`deepseek-flash`）生成 Prompt、优化右侧内容或运行效果对比；AI 参考稿需手动确认应用 |
| 版本历史 | 创建不可变快照，预览 Markdown、加入对比或基于旧版迭代；不同 Prompt 的历史独立保存 |
| 自动保存 | 工作稿实时写回 Markdown；对比右侧未应用的修改独立保存在本地，设置中的 AI 生成系统提示词修改后立即生效 |
| 隐私边界 | API Key、接口地址和模型配置保存在当前 Mac 的应用偏好设置中，不写入 Prompt 或 App 包 |

<a id="data"></a>

## 🗂️ 文件与数据

一个工作区可包含多层文件夹，每层可放置多份 Prompt。正文始终保持可读的 Markdown 格式：

```text
My Workspace/
├── 写作/
│   ├── 文章 Prompt.md
│   └── 标题 Prompt.md
├── System Prompt.md
├── .prompt-order.json            # 当前目录的显示顺序
└── .prompt-history/
    └── <文件名哈希>/              # 每份 Prompt 独立保存历史
        ├── workspace.db          # 版本与对照元数据
        ├── comparison-edits.json # 对比中尚未确认的修改
        └── V1.md                 # 不可变历史快照，可单独改名
```

拖到行的上下边缘可调整顺序，拖到文件夹中间可移入，拖到列表末尾空白区域或顶部工作区名称可移回顶层。拖动时仅显示插入线或高亮，没有提示文字；重新打开后顺序仍保留。同名冲突和循环嵌套会被拦截。

移动或重命名工作稿时，关联历史一同迁移；旧版共用文件夹历史会自动迁移为独立存储。历史版本文件跨目录拖出后成为独立 Prompt，原不可变历史记录保留。

调试时可以通过 `--db <path>` 或环境变量 `PROMPT_ITERATION_DB` 指定隔离数据库。

<a id="run-app"></a>

## 🚀 下载安装

### [⬇️ 下载 Prompt Studio v0.1.1（Apple Silicon DMG）](https://github.com/yuanhao667/Prompt-Studio/releases/download/v0.1.1/Prompt.Studio.dmg)

点击上面的链接会直接下载 macOS 安装包。当前版本支持 Apple Silicon，要求 macOS 13 或更高版本。

1. 打开下载好的 `Prompt.Studio.dmg`。
2. 将 `Prompt Studio` 拖入“应用程序”文件夹。

### 首次打开

当前安装包尚未使用 Apple Developer ID 签名或提交 Apple 公证，因此第一次启动时可能会被 macOS 拦截：

1. 在“应用程序”中双击 `Prompt Studio`，让系统显示一次安全提醒。
2. 打开“系统设置 → 隐私与安全性”，向下滚动到“安全性”。
3. 找到关于 `Prompt Studio` 的提示，点击“仍要打开”。这个按钮会在首次尝试启动后出现。
4. 在再次弹出的确认窗口中点击“打开”；此后即可正常双击启动。

操作方法可参阅 [Apple 官方说明](https://support.apple.com/zh-cn/guide/mac-help/-mh40616/mac)。版本说明见 [Prompt Studio v0.1.1](https://github.com/yuanhao667/Prompt-Studio/releases/tag/v0.1.1)。

## 🛠️ 从源码运行

使用 Xcode 打开 `PromptIterationAssistant.xcodeproj`，选择 `PromptIterationAssistant` scheme，按 `⌘R` 运行当前源码，按 `⌘U` 运行核心测试。

```bash
xcodebuild -project PromptIterationAssistant.xcodeproj \
  -scheme PromptIterationAssistant -destination 'platform=macOS' test
```

Swift Package 入口也保留：`swift run PromptIterationAssistant` 或 `swift run PromptIterationCoreChecks`。运行 `swift test` 可同时验证核心逻辑与 App 的保存、对比和 AI 请求流程。

测试覆盖嵌套移动、文件与文件夹混合排序、末尾插入、历史隔离、文件及版本改名、同名冲突和失败回滚。

## 🙏 参考来源

SQLite 封装、事务写入和不可变版本思路改编自仓库内的 `prompt-version-manager` 参考实现。第三方许可与说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

<a id="license"></a>

## 📄 License

[MIT](LICENSE) — use it, fork it, ship it.

---

<p align="center">
  <strong>Built with ❤️ by <a href="https://github.com/yuanhao667">@yuanhao667</a></strong>
</p>

<p align="center">
  <a href="https://github.com/yuanhao667/Prompt-Studio/releases/download/v0.1.1/Prompt.Studio.dmg">Download for macOS</a>
  ·
  <a href="https://github.com/yuanhao667/Prompt-Studio/releases/tag/v0.1.1">Release Notes</a>
  ·
  <a href="https://github.com/yuanhao667/Prompt-Studio/issues">Report Issues</a>
</p>
