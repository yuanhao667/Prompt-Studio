import XCTest
@testable import PromptIterationCore

final class PromptIterationCoreTests: XCTestCase {
  func testTextDifferenceReconstructsBothPromptsIncludingWhitespaceAndRepeatedLines() {
    let cases = [
      ("", ""), ("", "新增"), ("删除", ""), ("相同\n", "相同\n"),
      ("角色\n旧任务\n格式\n", "角色\n新任务\n格式\n"),
      ("重复\n重复\n尾", "重复\n新增\n重复\n尾\n"),
      ("  中文 👩‍🏫\n\n", "中文 👩‍🏫\n\n\n"), ("a\r\nb", "a\nb"),
      ("第一行\n第二行", "第二行\n第一行"),
    ]
    for (old, new) in cases {
      let changes = PromptTextDifference.changes(from: old, to: new)
      XCTAssertEqual(changes.filter { $0.kind != .added }.map(\.text).joined(), old)
      XCTAssertEqual(changes.filter { $0.kind != .removed }.map(\.text).joined(), new)
    }
    let replacement = PromptTextDifference.changes(from: "保留\n旧任务\n", to: "保留\n新任务\n")
    XCTAssertEqual(replacement.filter { $0.kind == .removed }.map(\.text), ["旧任务\n"])
    XCTAssertEqual(replacement.filter { $0.kind == .added }.map(\.text), ["新任务\n"])
  }

  func testOptimizationRequirementOnlyAffectsOptimizationAndKeepsResponseContract() {
    let requirement = "只调整输出格式，保留教学目标。"
    let optimized = PromptGenerationInstructions.systemMessage(customPrompt: "", optimizationRequest: requirement)
    XCTAssertTrue(optimized.contains("本次优化要求：\(requirement)"))
    XCTAssertTrue(optimized.contains("保留无关内容"))
    XCTAssertTrue(optimized.contains("每个输入 id 必须原样返回一次"))
    let creation = PromptGenerationInstructions.systemMessage(customPrompt: "", isCreating: true, optimizationRequest: requirement)
    XCTAssertFalse(creation.contains(requirement))
    let blank = PromptGenerationInstructions.systemMessage(customPrompt: "", optimizationRequest: " \n\t")
    XCTAssertFalse(blank.contains("本次优化要求："))
  }

  func testFreeformMarkdownPreservesTextAndVersionHistory() throws {
    let context = try TestContext()
    defer { context.cleanup() }
    for markdown in ["", "  直接写提示词\n\n", "先说明要求\n# 自定义标题\n保留这段", "```markdown\n# 示例标题\n```\n"] {
      var workspace = try context.repository.loadOrCreateWorkspace()
      workspace.sections = PromptMarkdown.parse(markdown)
      XCTAssertEqual(workspace.sections.count, 1)
      XCTAssertTrue(workspace.sections[0].isFreeform)
      XCTAssertEqual(PromptMarkdown.renderAll(workspace.sections), markdown)
      XCTAssertEqual(PromptMarkdown.render(workspace.sections), markdown)
      try context.repository.saveDraft(workspace)
      let version = try context.repository.saveVersion(workspace: workspace)
      let reopened = try WorkspaceRepository(databaseURL: context.databaseURL)
      XCTAssertEqual(try reopened.loadOrCreateWorkspace().sections, workspace.sections)
      XCTAssertEqual(try reopened.versionSections(projectID: workspace.id, number: version.number), workspace.sections)
    }
  }

  func testEnablingFrameworkPreservesFreeformContentAndExistingSections() {
    let markdown = "先说明要求\n# 自定义标题\n原正文"
    let framework = PromptMarkdown.frameworkSections(from: [PromptSection.freeform(markdown)])
    XCTAssertEqual(framework.count, 12)
    XCTAssertEqual(framework[0].content, markdown)
    XCTAssertEqual(framework[0].title, "角色与定位")
    XCTAssertEqual(PromptMarkdown.frameworkSections(from: framework), framework)
    XCTAssertEqual(PromptMarkdown.frameworkSections(from: []).count, 12)
    var custom = [PromptSection(id: "custom", title: "自定义", content: "隐藏内容", position: 0)]
    custom[0].isIncluded = false
    XCTAssertEqual(PromptMarkdown.frameworkSections(from: custom), custom)
  }

  func testMarkdownParserKeepsHeadingsInsideCodeFencesInTheirSection() {
    let markdown = "# 角色与定位\n```markdown\n# 示例标题\n```\n\n# 任务目标\n目标"
    let sections = PromptMarkdown.parse(markdown)
    XCTAssertEqual(sections.map(\.title), ["角色与定位", "任务目标"])
    XCTAssertEqual(sections[0].content, "```markdown\n# 示例标题\n```")
    XCTAssertEqual(PromptMarkdown.renderAll(sections), markdown)
  }

  func testMarkdownParserKeepsNestedAndInvalidClosingFencesAsContent() {
    for marker in ["`", "~"] {
      let fence = String(repeating: marker, count: 4)
      let shorter = String(repeating: marker, count: 3)
      let markdown = "# 角色\n\(fence)markdown\n\(shorter)\n# 示例\n\(fence)仍是正文\n# 另一个示例\n\(fence)\n\n# 任务\n目标"
      let sections = PromptMarkdown.parse(markdown)
      XCTAssertEqual(sections.map(\.title), ["角色", "任务"])
      XCTAssertEqual(PromptMarkdown.renderAll(sections), markdown)
    }
  }

  func testCustomGenerationPromptKeepsRequiredResponseFormatAndEmptyFallback() {
    let custom = "只用中文，保留业务事实。"
    let message = PromptGenerationInstructions.systemMessage(customPrompt: custom)
    XCTAssertTrue(message.hasPrefix(custom))
    XCTAssertTrue(message.contains("NDJSON"))
    XCTAssertTrue(message.contains("每个输入 id 必须原样返回一次"))
    XCTAssertFalse(message.contains(PromptGenerationInstructions.defaultPrompt))
    for empty in ["", " \n\t"] {
      XCTAssertTrue(PromptGenerationInstructions.systemMessage(customPrompt: empty)
        .hasPrefix(PromptGenerationInstructions.defaultPrompt))
    }
    let creation = PromptGenerationInstructions.systemMessage(customPrompt: "", isCreating: true)
    XCTAssertTrue(creation.hasPrefix(PromptGenerationInstructions.defaultCreationPrompt))
    XCTAssertTrue(creation.contains("根据需求描述生成完整提示词正文"))
    XCTAssertTrue(creation.contains("不要重复开场介绍"))
    XCTAssertTrue(PromptGenerationInstructions.defaultCreationPrompt.hasPrefix("## 角色定位\n"))
    XCTAssertTrue(PromptGenerationInstructions.defaultCreationPrompt.hasSuffix("等待用户回应。如果需要，提出澄清问题，然后使用上述结构生成最终提示词。"))
    XCTAssertTrue(creation.contains("NDJSON"))
    XCTAssertTrue(PromptGenerationInstructions.systemMessage(customPrompt: custom, isCreating: true)
      .hasPrefix(custom))
  }

  func testDocumentRenamePreservesVersionDataAndSiblingPositions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = root.appendingPathComponent("旧名称.md")
    let destination = root.appendingPathComponent("新名称.md")
    let repository = try WorkspaceRepository(databaseURL: PromptDocumentStorage.databaseURL(for: document))
    var workspace = try repository.loadOrCreateWorkspace()
    workspace.sections[0].content = "改名不丢失"
    _ = try repository.saveVersion(workspace: workspace, note: "版本")
    let markdown = PromptMarkdown.renderAll(workspace.sections)
    try markdown.write(to: document, atomically: true, encoding: .utf8)
    try markdown.write(to: PromptDocumentStorage.versionURL(1, for: document), atomically: true, encoding: .utf8)
    let keys = ["其他文件.md", "旧名称.md/V1.md", "旧名称.md", "末尾文件.md"]
    try WorkspaceItemOrder.move(source: document, destination: destination, before: "末尾文件.md",
      sourceKeys: keys, destinationKeys: keys,
      attachments: [(PromptDocumentStorage.directory(for: document), PromptDocumentStorage.directory(for: destination))])
    let expected = ["其他文件.md", "新名称.md/V1.md", "新名称.md", "末尾文件.md"]
    XCTAssertEqual(try WorkspaceItemOrder.sortedKeys(Array(expected.reversed()), in: root), expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: document.path))
    let restored = try WorkspaceRepository(databaseURL: PromptDocumentStorage.databaseURL(for: destination))
    XCTAssertEqual(try restored.versionSections(projectID: workspace.id, number: 1)[0].content, "改名不丢失")
    XCTAssertEqual(try String(contentsOf: PromptDocumentStorage.versionURL(1, for: destination), encoding: .utf8), markdown)
    XCTAssertEqual(try PromptDocumentStorage.markdownFilename(from: "  新名称.MD  "), "新名称.md")
    for invalid in ["", ".md", "..", ".隐藏", "父/子", "父:子", "父\n子"] {
      XCTAssertThrowsError(try PromptDocumentStorage.markdownFilename(from: invalid))
    }
  }

  func testVersionFileRenameKeepsNumberHistoryAndFutureStorageLocation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = root.appendingPathComponent("Prompt.md")
    let repository = try WorkspaceRepository(databaseURL: PromptDocumentStorage.databaseURL(for: document))
    var workspace = try repository.loadOrCreateWorkspace()
    workspace.sections[0].content = "不可变历史"
    _ = try repository.saveVersion(workspace: workspace, note: "版本")
    let markdown = PromptMarkdown.renderAll(workspace.sections)
    try markdown.write(to: document, atomically: true, encoding: .utf8)
    let oldSnapshot = PromptDocumentStorage.versionURL(1, for: document)
    try markdown.write(to: oldSnapshot, atomically: true, encoding: .utf8)
    try PromptDocumentStorage.renameVersion(1, for: document, to: "精简版")
    let renamed = PromptDocumentStorage.versionURL(1, for: document)
    XCTAssertEqual(renamed.lastPathComponent, "精简版.md")
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldSnapshot.path))
    XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), markdown)
    XCTAssertEqual(try PromptDocumentStorage.snapshots(for: document).map(\.number), [1])
    XCTAssertEqual(try repository.versionSections(projectID: workspace.id, number: 1)[0].content, "不可变历史")
    try PromptDocumentStorage.migrateLegacyFolder(root)
    XCTAssertEqual(PromptDocumentStorage.versionURL(1, for: document), renamed)
    XCTAssertThrowsError(try PromptDocumentStorage.renameVersion(1, for: document, to: "V2"))
    let collision = PromptDocumentStorage.directory(for: document).appendingPathComponent("已存在.md")
    try Data("保留".utf8).write(to: collision)
    XCTAssertThrowsError(try PromptDocumentStorage.renameVersion(1, for: document, to: "已存在"))
    XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "保留")
    XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
  }

  func testMixedFileAndFolderOrderPersistsIncludingLastPosition() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try WorkspaceFolderOperations.createFolder(named: "A 文件夹", in: root)
    let first = root.appendingPathComponent("B.md")
    let last = root.appendingPathComponent("C.md")
    try Data().write(to: first)
    try Data().write(to: last)
    let names = [folder.lastPathComponent, first.lastPathComponent, last.lastPathComponent]
    try WorkspaceItemOrder.move(source: folder, destination: folder, before: nil, sourceKeys: names, destinationKeys: names)
    var order = try WorkspaceItemOrder.sortedKeys(names, in: root)
    XCTAssertEqual(order, ["B.md", "C.md", "A 文件夹"])
    try WorkspaceItemOrder.move(source: first, destination: first, before: nil, sourceKeys: order, destinationKeys: order)
    order = try WorkspaceItemOrder.sortedKeys(names, in: root)
    XCTAssertEqual(order, ["C.md", "A 文件夹", "B.md"])
    try WorkspaceItemOrder.move(source: first, destination: first, before: "C.md", sourceKeys: order, destinationKeys: order)
    XCTAssertEqual(try WorkspaceItemOrder.sortedKeys(names, in: root), ["B.md", "C.md", "A 文件夹"])
    XCTAssertEqual(WorkspaceItemOrder.placing("C.md", before: "C.md", in: names), names)
    XCTAssertEqual(try WorkspaceItemOrder.sortedKeys(["C.md", "A 文件夹", "新文件.md"], in: root), ["C.md", "A 文件夹", "新文件.md"])
  }

  func testMovingFilesBetweenFoldersKeepsSeparateHistoriesAndOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = try WorkspaceFolderOperations.createFolder(named: "子目录", in: root)
    let source = nested.appendingPathComponent("来源.md")
    let other = root.appendingPathComponent("已有.md")
    for (document, content) in [(source, "来源历史"), (other, "已有历史")] {
      let repository = try WorkspaceRepository(databaseURL: PromptDocumentStorage.databaseURL(for: document))
      var workspace = try repository.loadOrCreateWorkspace()
      workspace.sections[0].content = content
      try repository.saveDraft(workspace)
      _ = try repository.saveVersion(workspace: workspace, note: "历史")
      try PromptMarkdown.renderAll(workspace.sections).write(to: document, atomically: true, encoding: .utf8)
      try PromptMarkdown.renderAll(workspace.sections).write(to: PromptDocumentStorage.versionURL(1, for: document), atomically: true, encoding: .utf8)
    }
    let destination = try WorkspaceFolderOperations.moveDestination(for: source, into: root, root: root)
    try WorkspaceItemOrder.move(source: source, destination: destination, before: other.lastPathComponent,
      sourceKeys: [source.lastPathComponent], destinationKeys: [nested.lastPathComponent, other.lastPathComponent],
      attachments: [(PromptDocumentStorage.directory(for: source), PromptDocumentStorage.directory(for: destination))])
    XCTAssertEqual(try WorkspaceItemOrder.sortedKeys(["子目录", "已有.md", "来源.md"], in: root), ["子目录", "来源.md", "已有.md"])
    for (document, content) in [(destination, "来源历史"), (other, "已有历史")] {
      let repository = try WorkspaceRepository(databaseURL: PromptDocumentStorage.databaseURL(for: document))
      var workspace = try repository.loadOrCreateWorkspace()
      XCTAssertEqual(try repository.versionSections(projectID: workspace.id, number: 1)[0].content, content)
      workspace.sections[0].content += "继续编辑"
      try repository.saveDraft(workspace)
      XCTAssertTrue(try String(contentsOf: PromptDocumentStorage.versionURL(1, for: document), encoding: .utf8).contains(content))
    }
    // Move back into the nested directory and append to its last position.
    try WorkspaceItemOrder.move(source: destination, destination: source, before: nil,
      sourceKeys: ["子目录", "来源.md", "已有.md"], destinationKeys: [],
      attachments: [(PromptDocumentStorage.directory(for: destination), PromptDocumentStorage.directory(for: source))])
    XCTAssertTrue(FileManager.default.fileExists(atPath: PromptDocumentStorage.databaseURL(for: source).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(try WorkspaceItemOrder.sortedKeys(["来源.md"], in: nested), ["来源.md"])
  }

  func testLegacyFolderMigrationAndVersionDetachmentPreserveImmutableHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try WorkspaceRepository(databaseURL: root.appendingPathComponent(".prompt-history/workspace.db"))
    var workspace = try legacy.loadOrCreateWorkspace()
    workspace.sections[0].content = "旧版内容"
    _ = try legacy.saveVersion(workspace: workspace, note: "旧版本")
    let document = root.appendingPathComponent("System Prompt.md")
    let markdown = PromptMarkdown.renderAll(workspace.sections)
    try markdown.write(to: document, atomically: true, encoding: .utf8)
    try markdown.write(to: root.appendingPathComponent("V1.md"), atomically: true, encoding: .utf8)
    try PromptDocumentStorage.migrateLegacyFolder(root)
    try PromptDocumentStorage.migrateLegacyFolder(root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("V1.md").path))
    let repository = try WorkspaceRepository(databaseURL: PromptDocumentStorage.databaseURL(for: document))
    XCTAssertEqual(try repository.versionSections(projectID: workspace.id, number: 1)[0].content, "旧版内容")
    let nested = try WorkspaceFolderOperations.createFolder(named: "目标", in: root)
    let detached = nested.appendingPathComponent("System Prompt V1.md")
    try PromptDocumentStorage.detachVersion(1, for: document, to: detached)
    XCTAssertEqual(try PromptDocumentStorage.detachedVersions(for: document), [1])
    XCTAssertEqual(try String(contentsOf: detached, encoding: .utf8), markdown)
    XCTAssertEqual(try repository.versionSections(projectID: workspace.id, number: 1)[0].content, "旧版内容")
    try "独立修改".write(to: detached, atomically: true, encoding: .utf8)
    XCTAssertTrue(try String(contentsOf: PromptDocumentStorage.versionURL(1, for: document), encoding: .utf8).contains("旧版内容"))
    XCTAssertThrowsError(try PromptDocumentStorage.detachVersion(1, for: document, to: detached))
    XCTAssertEqual(try String(contentsOf: detached, encoding: .utf8), "独立修改")
  }

  func testMoveRejectsHistoryCollisionWithoutMovingFileOrChangingOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = try WorkspaceFolderOperations.createFolder(named: "子目录", in: root)
    let source = nested.appendingPathComponent("Prompt.md")
    let destination = root.appendingPathComponent("Prompt.md")
    try Data("保留原文".utf8).write(to: source)
    let history = PromptDocumentStorage.directory(for: source)
    let conflict = PromptDocumentStorage.directory(for: destination)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: true)
    try WorkspaceItemOrder.save(["子目录"], in: root)
    XCTAssertThrowsError(try WorkspaceItemOrder.move(source: source, destination: destination, before: nil,
      sourceKeys: ["Prompt.md"], destinationKeys: ["子目录"], attachments: [(history, conflict)]))
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "保留原文")
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(try WorkspaceItemOrder.sortedKeys(["子目录"], in: root), ["子目录"])
    // A failure after the document and history already moved must roll both back.
    try FileManager.default.removeItem(at: conflict)
    XCTAssertThrowsError(try WorkspaceItemOrder.move(source: source, destination: destination, before: nil,
      sourceKeys: ["Prompt.md"], destinationKeys: ["子目录"], attachments: [
        (history, conflict), (nested.appendingPathComponent("不存在"), root.appendingPathComponent("不存在")),
      ]))
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "保留原文")
    XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: conflict.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testNestedFolderMovesPreservePromptAndHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = try WorkspaceFolderOperations.createFolder(named: "父目录", in: root)
    let child = try WorkspaceFolderOperations.createFolder(named: "子目录", in: parent)
    let project = try WorkspaceFolderOperations.createFolder(named: "Prompt", in: child)
    let document = project.appendingPathComponent("System Prompt.md")
    let database = project.appendingPathComponent(".prompt-history/workspace.db")
    var repository = try WorkspaceRepository(databaseURL: database)
    var workspace = try repository.loadOrCreateWorkspace()
    workspace.sections[0].content = "移动后仍可编辑"
    try repository.saveDraft(workspace)
    _ = try repository.saveVersion(workspace: workspace, note: "保留历史")
    try PromptMarkdown.renderAll(workspace.sections).write(to: document, atomically: true, encoding: .utf8)
    try Data().write(to: child.appendingPathComponent(".prompt-iteration-folder"))

    // Move the entire nested subtree out to the root, then into a different folder.
    let topLevel = try WorkspaceFolderOperations.moveDestination(for: child, into: root, root: root)
    try FileManager.default.moveItem(at: child, to: topLevel)
    let sibling = try WorkspaceFolderOperations.createFolder(named: "另一目录", in: root)
    let nested = try WorkspaceFolderOperations.moveDestination(for: topLevel, into: sibling, root: root)
    try FileManager.default.moveItem(at: topLevel, to: nested)
    let movedDocument = try XCTUnwrap(WorkspaceFolderOperations.rebasedURL(document, from: child, to: nested))
    XCTAssertTrue(try String(contentsOf: movedDocument, encoding: .utf8).contains("移动后仍可编辑"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent(".prompt-iteration-folder").path))
    let movedDatabase = try XCTUnwrap(WorkspaceFolderOperations.rebasedURL(database, from: child, to: nested))
    repository = try WorkspaceRepository(databaseURL: movedDatabase)
    XCTAssertEqual(try repository.listVersions(projectID: workspace.id).count, 1)
    XCTAssertEqual(try repository.versionSections(projectID: workspace.id, number: 1)[0].content, "移动后仍可编辑")
    workspace.sections[0].content = "继续保存"
    try repository.saveDraft(workspace)
    XCTAssertEqual(try repository.loadOrCreateWorkspace().sections[0].content, "继续保存")
    XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
    XCTAssertNil(WorkspaceFolderOperations.rebasedURL(parent.appendingPathComponent("子目录2/test.md"), from: child, to: nested))
  }

  func testFolderMoveRejectsCyclesConflictsAndWorkspaceEscape() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = try WorkspaceFolderOperations.createFolder(named: "父目录", in: root)
    let child = try WorkspaceFolderOperations.createFolder(named: "子目录", in: parent)
    XCTAssertThrowsError(try WorkspaceFolderOperations.moveDestination(for: parent, into: parent, root: root))
    XCTAssertThrowsError(try WorkspaceFolderOperations.moveDestination(for: parent, into: child, root: root))
    XCTAssertThrowsError(try WorkspaceFolderOperations.moveDestination(for: root, into: child, root: root))
    XCTAssertThrowsError(try WorkspaceFolderOperations.moveDestination(for: child, into: root.deletingLastPathComponent(), root: root))
    XCTAssertEqual(try WorkspaceFolderOperations.moveDestination(for: child, into: parent, root: root), child)
    let conflict = try WorkspaceFolderOperations.createFolder(named: "子目录", in: root)
    XCTAssertThrowsError(try WorkspaceFolderOperations.moveDestination(for: child, into: root, root: root))
    XCTAssertTrue(FileManager.default.fileExists(atPath: conflict.path))
    let alias = root.appendingPathComponent("外部链接")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.deletingLastPathComponent())
    XCTAssertThrowsError(try WorkspaceFolderOperations.moveDestination(for: child, into: alias, root: root))
    for name in ["", " ", ".", "..", ".隐藏", "父/子", "父:子", "父\n子", "父目录"] {
      XCTAssertThrowsError(try WorkspaceFolderOperations.createFolder(named: name, in: root))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
  }

  func testDefaultWorkspaceAutosaves() throws {
    let context = try TestContext()
    defer { context.cleanup() }
    var workspace = try context.repository.loadOrCreateWorkspace()

    XCTAssertEqual(workspace.name, "System Prompt")
    XCTAssertEqual(workspace.sections.count, 12)
    XCTAssertEqual(
      workspace.sections.map(\.title),
      [
        "角色与定位", "任务目标", "背景与上下文", "输入与变量",
        "意图识别与澄清", "工作流程", "工具使用", "输出要求",
        "质量标准", "约束与禁止事项", "异常与兜底", "示例",
      ]
    )
    workspace.sections[0].content = "你是一名编辑"
    try context.repository.saveDraft(workspace)

    let restored = try WorkspaceRepository(databaseURL: context.databaseURL)
      .loadOrCreateWorkspace()
    XCTAssertEqual(restored.sections[0].content, "你是一名编辑")
  }

  func testHiddenDimensionPersistsAndIsExcludedFromMarkdown() throws {
    let context = try TestContext()
    defer { context.cleanup() }
    var workspace = try context.repository.loadOrCreateWorkspace()

    workspace.sections[0].content = "隐藏内容"
    workspace.sections[0].isIncluded = false
    workspace.sections[1].content = "保留内容"
    try context.repository.saveDraft(workspace)

    let restored = try WorkspaceRepository(databaseURL: context.databaseURL)
      .loadOrCreateWorkspace()
    let markdown = PromptMarkdown.render(restored.sections)
    XCTAssertFalse(restored.sections[0].isIncluded)
    XCTAssertFalse(markdown.contains("隐藏内容"))
    XCTAssertTrue(PromptMarkdown.renderAll(restored.sections).contains("隐藏内容"))
    XCTAssertTrue(markdown.contains("# \(restored.sections[1].title)\n保留内容"))
  }

  func testMarkdownRoundTripPreservesTitlesAndContent() {
    var sections = PromptSection.defaults()
    sections[0].content = "你是一名编辑"
    sections[1].content = "优化这篇文章"

    let restored = PromptMarkdown.parse(PromptMarkdown.render(sections))

    XCTAssertEqual(restored.map(\.title), sections.map(\.title))
    XCTAssertEqual(restored[0].content, "你是一名编辑")
    XCTAssertEqual(restored[1].content, "优化这篇文章")
  }

  func testStructuredPromptDetectionRejectsUnrelatedMarkdown() {
    XCTAssertTrue(PromptMarkdown.isStructuredPrompt(PromptMarkdown.renderAll(PromptSection.defaults())))
    XCTAssertFalse(PromptMarkdown.isStructuredPrompt("# README\n\n这是普通项目文档。"))
    XCTAssertFalse(PromptMarkdown.isStructuredPrompt("没有标题的普通 Markdown"))
  }

  func testPartialApplyAndReject() throws {
    var current = [
      PromptSection(id: "role", title: "角色", content: "原角色", position: 0),
      PromptSection(id: "goal", title: "目标", content: "原目标", position: 1),
    ]
    var comparison = [
      ComparisonSection(sectionID: "role", title: "角色", content: "新角色", position: 0),
      ComparisonSection(sectionID: "goal", title: "目标", content: "新目标", position: 1),
    ]

    try WorkspaceActions.apply(sectionID: "role", current: &current, comparison: &comparison)
    try WorkspaceActions.reject(sectionID: "goal", comparison: &comparison)

    XCTAssertEqual(current[0].content, "新角色")
    XCTAssertEqual(current[1].content, "原目标")
    XCTAssertEqual(comparison[0].status, .accepted)
    XCTAssertEqual(comparison[1].status, .rejected)
  }

  func testComparisonStatePersists() throws {
    let context = try TestContext()
    defer { context.cleanup() }
    let workspace = try context.repository.loadOrCreateWorkspace()
    let first = workspace.sections[0]
    let snapshot = ComparisonSnapshot(
      kind: .manual,
      sourceVersion: nil,
      sections: [
        ComparisonSection(
          sectionID: first.id,
          title: first.title,
          content: "候选内容",
          position: 0,
          status: .userModified
        )
      ]
    )

    try context.repository.saveComparison(projectID: workspace.id, snapshot: snapshot)
    XCTAssertEqual(try context.repository.loadComparison(projectID: workspace.id), snapshot)
  }

  func testVersionHistoryIsImmutable() throws {
    let context = try TestContext()
    defer { context.cleanup() }
    var workspace = try context.repository.loadOrCreateWorkspace()

    workspace.sections[0].content = "第一版"
    try context.repository.saveDraft(workspace)
    let first = try context.repository.saveVersion(workspace: workspace, note: "v1")

    workspace.sections[0].content = "第二版"
    try context.repository.saveDraft(workspace)
    let second = try context.repository.saveVersion(workspace: workspace, note: "v2")

    XCTAssertEqual(first.number, 1)
    XCTAssertEqual(second.number, 2)
    XCTAssertEqual(
      try context.repository.versionSections(projectID: workspace.id, number: 1)[0].content,
      "第一版"
    )
  }

  func testVersionCanBeDeletedAndCurrentVersionFallsBack() throws {
    let context = try TestContext()
    defer { context.cleanup() }
    let workspace = try context.repository.loadOrCreateWorkspace()

    _ = try context.repository.saveVersion(workspace: workspace, note: "v1")
    _ = try context.repository.saveVersion(workspace: workspace, note: "v2")
    try context.repository.deleteVersion(projectID: workspace.id, number: 2)

    XCTAssertEqual(try context.repository.listVersions(projectID: workspace.id).map(\.number), [1])
    XCTAssertEqual(try context.repository.loadOrCreateWorkspace().currentVersion, 1)
    XCTAssertThrowsError(
      try context.repository.versionSections(projectID: workspace.id, number: 2)
    )
  }

  func testRestoreVersionCreatesEditableDraftWithoutChangingHistory() throws {
    let context = try TestContext()
    defer { context.cleanup() }
    var workspace = try context.repository.loadOrCreateWorkspace()

    workspace.sections[0].content = "需要恢复的内容"
    try context.repository.saveDraft(workspace)
    _ = try context.repository.saveVersion(workspace: workspace, note: "可恢复版本")

    workspace.sections[0].content = "后来修改的内容"
    try context.repository.saveDraft(workspace)
    let restored = try context.repository.restoreVersionAsDraft(workspace: workspace, number: 1)

    XCTAssertEqual(restored.sections[0].content, "需要恢复的内容")
    XCTAssertEqual(try context.repository.loadOrCreateWorkspace().sections[0].content, "需要恢复的内容")
    XCTAssertEqual(
      try context.repository.versionSections(projectID: workspace.id, number: 1)[0].content,
      "需要恢复的内容"
    )
  }
}

private final class TestContext {
  let directory: URL
  let databaseURL: URL
  let repository: WorkspaceRepository

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("prompt-iteration-tests-\(UUID().uuidString)")
    databaseURL = directory.appendingPathComponent("test.db")
    repository = try WorkspaceRepository(databaseURL: databaseURL)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}
