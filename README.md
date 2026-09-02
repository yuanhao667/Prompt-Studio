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
  <a href="#run-app">安装运行</a>
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
2. **比较** — 点击“AI 生成”，在只读 AI 参考稿与可编辑 System Prompt 之间逐段判断和修改。
3. **沉淀** — 草稿自动保存；确认成果后手动保存为新的不可变版本，随时预览、复制或基于旧版本继续编辑。

<a id="features"></a>

## 🧩 当前能力

| 能力 | 现在可以做什么 |
| --- | --- |
| 本地工作区 | 新建或打开 Prompt 文件夹；重命名、在 Finder 中显示或移到废纸篓 |
| 结构化编辑 | 默认生成 12 个维度；支持新增、删除、改名、隐藏与拖动排序 |
| AI 对照 | 使用 DeepSeek V4 Flash / V4 Pro 生成只读参考稿，与正式稿并排编辑 |
| 版本历史 | 创建连续的 `Vn.md` 快照，预览完整 Markdown，加入对比或基于旧版迭代 |
| 自动保存 | System Prompt 实时写回本地 Markdown；SQLite 仅保存版本和对照元数据 |
| 隐私边界 | API Key、接口地址和模型配置保存在当前 Mac 的应用偏好设置中，不写入 Prompt 或 App 包 |

<a id="data"></a>

## 🗂️ 文件与数据

每个 Prompt 都是一个独立文件夹，正文保持可读、可迁移的 Markdown 格式：

```text
My Prompt/
├── System Prompt.md              # 当前工作稿，自动保存
├── V3.md                         # 不可变历史快照
├── V2.md
├── V1.md
└── .prompt-history/
    └── workspace.db              # 版本与对照元数据
```

调试时可以通过 `--db <path>` 或环境变量 `PROMPT_ITERATION_DB` 指定隔离数据库。

<a id="run-app"></a>

## 🚀 运行应用

当前仓库暂未提供可下载的 DMG 或 GitHub Release。请在 Apple Silicon Mac 上从源码运行：

- macOS 13 或更高版本
- Xcode 26.6 或更高版本

双击 `PromptIterationAssistant.xcodeproj`，选择 `PromptIterationAssistant` scheme，然后按 `⌘R`。

也可以使用保留的 Swift Package 入口，无需额外依赖：

```bash
swift run PromptIterationAssistant
```

使用隔离数据库启动：

```bash
swift run PromptIterationAssistant --db /tmp/prompt-iteration-demo.db
```

## 🙏 参考来源

SQLite 封装、事务写入和不可变版本思路改编自仓库内的 `prompt-version-manager` 参考实现。第三方许可与说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

<a id="license"></a>

## 📄 License

[MIT](LICENSE) — use it, fork it, ship it.

你可以使用、复制、修改、合并、发布、分发、再许可或销售本项目的副本，但需要保留原始版权与许可声明；软件按“原样”提供，不附带任何形式的担保。

---

<p align="center">
  <strong>Built with ❤️ by <a href="https://github.com/yuanhao667">@yuanhao667</a></strong>
</p>

<p align="center">
  <a href="https://github.com/yuanhao667/Prompt-Studio/archive/refs/heads/main.zip">Download Source</a>
  ·
  <a href="#run-app">Install</a>
  ·
  <a href="https://github.com/yuanhao667/Prompt-Studio/issues">Report Issues</a>
</p>
