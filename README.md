# Prompt 迭代助手｜第一阶段原型

这是一个本地原生 macOS 纵向切片，用于验证结构化双栏编辑、工作稿自动保存和不可变版本历史。

## 当前能力

- 每次启动先进入本地工作区页面，可新建 Prompt、新建文件夹或打开文件夹。
- 工作区左侧是可收起的 Prompt 文件树，可新建和展开文件夹；普通目录和无关 Markdown 不会被扫入列表。
- Prompt 文档可重命名、在 Finder 中显示或移到废纸篓。
- 编辑、历史版本和设置是贯穿整个工作区的一级 Tab。
- 启动页右上角可直接进入 DeepSeek 设置，不需要先创建或打开 Prompt。
- 正式稿直接读取并自动写回电脑里的 `.md` 文件；不同文件的历史数据彼此隔离。
- 每个新 Prompt 都自动带出固定的 12 个默认维度标题，用户可继续增删改和排序。
- 首页初始只显示一个完整的 Markdown Prompt 编辑框。
- 点击“AI 生成”后才展开左右对照：左侧为只读 AI 参考稿，右侧为可编辑 System Prompt 正式稿。
- AI 参考稿可整段复制，System Prompt 正式稿可继续增删、排序、编排、粘贴和修改；两个完整 Prompt 仍可左右拖动。
- 历史版本页支持搜索、Markdown 代码框预览和右上角一键复制。
- 点击历史版本的“编辑”后，左侧固定显示只读历史版本，右侧从该版本创建待迭代工作稿。
- 栏目可新增、删除、改名和排序；排序手柄只在悬停当前行时出现，AI 参考稿与 System Prompt 正式稿共享栏目顺序。
- System Prompt 正式稿实时写入 `.md`；SQLite 只保存该文件对应的版本历史和对照元数据。
- 完整 Prompt 使用 Markdown 一级标题复制，并排除被隐藏的栏目。
- 设置页可点击切换 DeepSeek V4 Flash / V4 Pro，并分别验证所选模型是否可用。
- API Key 只保存在当前 Mac 的系统 Keychain，接口地址和模型保存在本机偏好设置。

当前阶段以功能跑通为目标，不包含正式视觉设计、上线部署和 DMG 分发。

## 用 Xcode 开发

- Apple Silicon Mac
- macOS 13 或更高版本（第一阶段临时基线，最终最低版本仍待产品确认）
- Xcode 26.6 或更高版本

双击 `PromptIterationAssistant.xcodeproj`，选择 `PromptIterationAssistant` scheme，按 `⌘R` 运行。按 `⌘U` 运行 8 项核心测试。

命令行验证与 Xcode 使用同一个原生工程：

```bash
cd PromptIterationAssistant
xcodebuild \
  -project PromptIterationAssistant.xcodeproj \
  -scheme PromptIterationAssistant \
  -destination 'platform=macOS' \
  build
```

原有 Swift Package 仍保留作为轻量命令行入口，无需下载额外依赖：

```bash
swift run PromptIterationCoreChecks
swift run PromptIterationAssistant
```

使用隔离测试数据库启动：

```bash
swift run PromptIterationAssistant --db /tmp/prompt-iteration-demo.db
```

正式稿保存在用户选择的 `.md` 文件中。每个文件对应的版本元数据位于：

```text
~/Library/Application Support/Prompt Iteration Assistant/Workspaces/<文件路径哈希>.db
```

也可使用 `PROMPT_ITERATION_DB` 指定位置。

## 第一阶段手工验收

1. 启动应用，确认先出现“新建 Prompt / 新建文件夹 / 打开文件夹”三个入口。
2. 新建 Prompt，确认生成一个带 12 个默认标题的 `.md` 文件；展开左侧子文件夹，测试文档重命名和移到废纸篓。
3. 首页初始确认只有一个 System Prompt 编辑框；填写内容后点击“AI 生成”。
4. 确认生成完成后左侧出现只读 AI 参考稿，右侧保留可编辑 System Prompt 正式稿；交换左右位置后业务身份不变。
5. 点击“保存为新版本”，再修改工作稿。
6. 打开“历史版本”，搜索并选择旧版本，确认右侧以 Markdown 代码框显示完整 Prompt，复制图标位于代码框右上角。
7. 点击“编辑”，确认左侧是只读历史版本，右侧是可编辑的待迭代工作稿。
8. 隐藏一个栏目并复制完整 Prompt，确认该栏目未进入剪贴板。
9. 打开“设置”，填写 DeepSeek API Key，保存后重启应用，确认配置仍在；点击“测试连接”查看结果。

## 参考来源

SQLite 封装、事务写入和不可变版本思路改编自仓库内的 `参考项目/prompt-version-manager`。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
