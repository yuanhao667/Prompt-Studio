# Prompt 迭代助手｜第一阶段原型

这是一个本地原生 macOS 纵向切片，用于验证结构化双栏编辑、工作稿自动保存和不可变版本历史。

## 当前能力

- 自动创建 PRD 规定的 12 个默认栏目。
- 首页左右完整 Prompt 使用 Markdown 文本器对照，交换左右后业务身份不变。
- 可创建空白手动候选，逐段编辑或复制，由用户自行决定如何使用。
- 历史版本页支持搜索、Markdown 代码框预览和右上角一键复制。
- 点击历史版本的“编辑”后，左侧固定显示只读历史版本，右侧从该版本创建待迭代工作稿。
- 栏目可新增、删除、改名和排序；排序手柄只在悬停当前行时出现，手动候选共享当前栏目结构。
- 工作稿和候选状态实时保存到本地 SQLite；正式版本只在用户点击后生成。
- 完整 Prompt 使用 Markdown 一级标题复制，并排除被隐藏的栏目。

第一阶段不包含 DeepSeek、Keychain、导入导出、Prompt 管理、设置窗口或 DMG。

## 用 Xcode 开发

- Apple Silicon Mac
- macOS 13 或更高版本（第一阶段临时基线，最终最低版本仍待产品确认）
- Xcode 26.6 或更高版本

双击 `PromptIterationAssistant.xcodeproj`，选择 `PromptIterationAssistant` scheme，按 `⌘R` 运行。按 `⌘U` 运行 6 项核心测试。

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

默认数据库位于：

```text
~/Library/Application Support/Prompt Iteration Assistant/prompt-iteration.db
```

也可使用 `PROMPT_ITERATION_DB` 指定位置。

## 预览 API

`PreviewAPI` 是一个不保存 Prompt 或 API Key 的无状态联调服务。它只用于验证部署和预留接口契约，不替代 PRD 规定的本地 App 直连 DeepSeek 方案。

线上预览：https://s55a2810lfsogrqs2979l.apigateway-cn-beijing.volceapi.com/

```bash
cd PreviewAPI
npm start
curl http://localhost:8080/health
```

## 第一阶段手工验收

1. 启动应用，确认出现 12 个默认栏目。
2. 在任一栏目输入内容，退出后重新启动，确认内容恢复。
3. 新建空白手动候选，在两个栏目中输入不同内容。
4. 交换左右位置，确认当前编辑版本仍高亮且可编辑。
5. 点击“保存为新版本”，再修改工作稿。
6. 打开“历史版本”，搜索并选择旧版本，确认右侧以 Markdown 代码框显示完整 Prompt，复制图标位于代码框右上角。
7. 点击“编辑”，确认左侧是只读历史版本，右侧是可编辑的待迭代工作稿。
8. 隐藏一个栏目并复制完整 Prompt，确认该栏目未进入剪贴板。

## 参考来源

SQLite 封装、事务写入和不可变版本思路改编自仓库内的 `参考项目/prompt-version-manager`。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
