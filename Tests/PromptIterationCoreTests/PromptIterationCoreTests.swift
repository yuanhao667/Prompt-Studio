import XCTest
@testable import PromptIterationCore

final class PromptIterationCoreTests: XCTestCase {
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
