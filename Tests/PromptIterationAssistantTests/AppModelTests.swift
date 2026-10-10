import XCTest
import AppKit
import PromptIterationCore
@testable import PromptIterationAssistant

final class AppModelTests: XCTestCase {
  private let settingKeys = ["deepseek.apiKey", "deepseek.baseURL", "deepseek.model", "deepseek.generationSystemPrompt"]
  private var savedSettings: [Any?] = []
  private var roots: [URL] = []

  override func setUp() {
    super.setUp()
    savedSettings = settingKeys.map { UserDefaults.standard.object(forKey: $0) }
    UserDefaults.standard.set("test-key", forKey: "deepseek.apiKey")
    UserDefaults.standard.set("https://bugfix-test.invalid", forKey: "deepseek.baseURL")
    MockDeepSeek.reset()
    URLProtocol.registerClass(MockDeepSeek.self)
  }

  override func tearDown() {
    URLProtocol.unregisterClass(MockDeepSeek.self)
    for (key, value) in zip(settingKeys, savedSettings) {
      if let value { UserDefaults.standard.set(value, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    for root in roots { try? FileManager.default.removeItem(at: root) }
    super.tearDown()
  }

  @MainActor private func makeModel(_ content: String = "原有提示词") throws -> AppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    roots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let document = root.appendingPathComponent("Prompt.md")
    try content.write(to: document, atomically: true, encoding: .utf8)
    return AppModel(documentURL: document)
  }

  @MainActor private func waitForAI(_ model: AppModel) async throws {
    for _ in 0..<500 {
      if !model.hasActiveAIRequest && !model.isTestingDeepSeek { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("模拟请求未在 5 秒内结束")
  }

  @MainActor func testTwoWindowsSavingVersionsDoNotOverwriteEarlierSnapshot() throws {
    let first = try makeModel("初稿")
    let document = try XCTUnwrap(first.documentURL)
    let second = AppModel(documentURL: document)
    XCTAssertTrue(first.saveVersion())
    second.updateFreeformContent("第二个窗口的修改")
    XCTAssertTrue(second.saveVersion())
    let reopened = AppModel(documentURL: document)
    XCTAssertEqual(reopened.versions.map(\.number), [2, 1])
    XCTAssertEqual(try String(contentsOf: PromptDocumentStorage.versionURL(1, for: document), encoding: .utf8), "初稿")
    XCTAssertEqual(try String(contentsOf: PromptDocumentStorage.versionURL(2, for: document), encoding: .utf8), "第二个窗口的修改")
  }

  @MainActor func testSnapshotCollisionDoesNotOverwriteFileOrCommitVersion() throws {
    let model = try makeModel("当前工作稿")
    let document = try XCTUnwrap(model.documentURL)
    let snapshot = PromptDocumentStorage.versionURL(1, for: document)
    try "需要保留的历史文件".write(to: snapshot, atomically: true, encoding: .utf8)
    XCTAssertFalse(model.saveVersion())
    XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "需要保留的历史文件")
    let repository = try WorkspaceRepository(databaseURL: model.databaseURL)
    XCTAssertTrue(try repository.listVersions(projectID: XCTUnwrap(model.workspace).id).isEmpty)
    XCTAssertEqual(try repository.loadOrCreateWorkspace().currentVersion, 0)
  }

  @MainActor func testComparisonEditsSurviveReopeningWithoutChangingDraftOrHistory() throws {
    let model = try makeModel("原文")
    XCTAssertTrue(model.saveVersion())
    model.openPromptComparison()
    model.updateComparisonEdit("draft", content: "待确认修改")
    model.comparisonRightID = "version-1"
    model.updateComparisonEdit("version-1", content: "另一个待确认修改")
    let document = try XCTUnwrap(model.documentURL)
    let reopened = AppModel(documentURL: document)
    XCTAssertTrue(reopened.showsComparison)
    XCTAssertEqual(reopened.comparisonRightID, "version-1")
    XCTAssertEqual(reopened.comparisonEdits["draft"]?.content, "待确认修改")
    XCTAssertEqual(reopened.comparisonEdits["version-1"]?.content, "另一个待确认修改")
    XCTAssertEqual(reopened.freeformContent, "原文")
    XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "原文")
    XCTAssertEqual(try String(contentsOf: PromptDocumentStorage.versionURL(1, for: document), encoding: .utf8), "原文")
    XCTAssertTrue(reopened.applyComparisonSource("draft", editedContent: reopened.comparisonEdits["draft"]?.content))
    XCTAssertNil(AppModel(documentURL: document).comparisonEdits["draft"])
    XCTAssertEqual(AppModel(documentURL: document).comparisonEdits["version-1"]?.content, "另一个待确认修改")
  }

  @MainActor func testSavingOriginalDraftRetainsPendingEditAndSavingEditClearsIt() throws {
    let model = try makeModel("原文")
    model.openPromptComparison()
    model.updateComparisonEdit("draft", content: "待确认修改")
    XCTAssertTrue(model.saveVersion())
    XCTAssertEqual(model.comparisonEdits["draft"]?.content, "待确认修改")
    XCTAssertTrue(model.saveVersion(sourceID: "draft", editedContent: model.comparisonEdits["draft"]?.content))
    let reopened = AppModel(documentURL: model.documentURL)
    XCTAssertTrue(reopened.comparisonEdits.isEmpty)
    XCTAssertEqual(reopened.freeformContent, "原文")
    XCTAssertEqual(try reopened.comparisonSources().first(where: { $0.id == "version-2" })?.content, "待确认修改")
  }

  @MainActor func testFailedComparisonEditWriteIsReportedAndKeepsPreviousEdit() throws {
    let model = try makeModel("原文")
    model.openPromptComparison()
    model.updateComparisonEdit("draft", content: "已经恢复的修改")
    let editsURL = model.databaseURL.deletingLastPathComponent().appendingPathComponent("comparison-edits.json")
    try FileManager.default.removeItem(at: editsURL)
    try FileManager.default.createDirectory(at: editsURL, withIntermediateDirectories: false)
    model.updateComparisonEdit("draft", content: "不能保存的修改")
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(model.comparisonEdits["draft"]?.content, "已经恢复的修改")
    XCTAssertEqual(model.freeformContent, "原文")
  }

  @MainActor func testVersionLabelOnlyShowsSnapshotWhenDraftMatchesIt() throws {
    let model = try makeModel("")
    let document = try XCTUnwrap(model.documentURL)
    XCTAssertEqual(model.draftVersionLabel, "工作稿")
    XCTAssertNil(model.savedDraftEditedAt)
    XCTAssertNil(AppModel.savedDraftEditedAt(for: document))
    model.updateFreeformContent("初稿")
    XCTAssertEqual(model.draftVersionLabel, "工作稿")
    XCTAssertNil(model.savedDraftEditedAt)
    XCTAssertTrue(model.saveVersion())
    XCTAssertEqual(model.versions.map(\.number), [1])
    XCTAssertEqual(model.draftVersionLabel, "V1")
    XCTAssertEqual(try XCTUnwrap(model.savedDraftEditedAt), model.editedAt(forVersion: 1))
    let snapshotTime = try XCTUnwrap(AppModel.savedDraftEditedAt(for: document))
    XCTAssertEqual(snapshotTime, try PromptDocumentStorage.versionURL(1, for: document)
      .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    model.updateFreeformContent("修改后的工作稿")
    XCTAssertEqual(model.draftVersionLabel, "工作稿")
    XCTAssertNil(model.savedDraftEditedAt)
    XCTAssertNil(AppModel.savedDraftEditedAt(for: document))
    model.updateFreeformContent("初稿")
    XCTAssertEqual(model.draftVersionLabel, "V1")
    XCTAssertEqual(AppModel.savedDraftEditedAt(for: document), snapshotTime)
    XCTAssertEqual(AppModel(documentURL: model.documentURL).draftVersionLabel, "V1")
  }

  @MainActor func testSavingComparisonSelectsNewVersionAndPreservesStandardAndDraft() throws {
    let model = try makeModel("初稿")
    XCTAssertTrue(model.saveVersion())
    model.updateFreeformContent("新的工作稿")
    model.openPromptComparison()
    XCTAssertEqual(model.comparisonLeftID, "version-1")
    XCTAssertEqual(model.comparisonRightID, "draft")
    XCTAssertNil(model.savedDraftEditedAt)
    XCTAssertTrue(model.saveVersion(sourceID: "draft"))
    XCTAssertEqual(model.comparisonLeftID, "version-1")
    XCTAssertEqual(model.comparisonRightID, "version-2")
    XCTAssertEqual(try XCTUnwrap(model.savedDraftEditedAt), model.editedAt(forVersion: 2))
    XCTAssertTrue(model.saveVersion(sourceID: "version-2", editedContent: "右侧修改"))
    XCTAssertEqual(model.comparisonLeftID, "version-1")
    XCTAssertEqual(model.comparisonRightID, "version-3")
    XCTAssertEqual(model.freeformContent, "新的工作稿")
    XCTAssertNil(model.savedDraftEditedAt)
    let savedSource = try XCTUnwrap(model.comparisonSources().first(where: { $0.id == "version-3" }))
    XCTAssertEqual(savedSource.content, "右侧修改")
    XCTAssertEqual(try XCTUnwrap(savedSource.updatedAt), model.editedAt(forVersion: 3))
  }

  @MainActor func testComparisonDefaultsHandleEmptyHistoryLatestVersionAndAICandidate() async throws {
    let model = try makeModel("初稿")
    model.openPromptComparison()
    XCTAssertTrue(model.showsComparison)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(try model.comparisonSources().map(\.id), ["draft"])
    XCTAssertTrue(model.saveVersion())
    model.updateFreeformContent("第二版")
    XCTAssertTrue(model.saveVersion())
    model.updateFreeformContent("初稿")
    model.openPromptComparison()
    XCTAssertEqual(model.comparisonLeftID, "version-2")
    XCTAssertEqual(model.comparisonRightID, "draft")
    model.generatePrompt()
    try await waitForAI(model)
    model.openPromptComparison()
    XCTAssertEqual(model.comparisonLeftID, "draft")
    XCTAssertEqual(model.comparisonRightID, "candidate")
    let candidate = model.comparison
    model.loadHistory(try XCTUnwrap(model.versions.last))
    XCTAssertEqual(model.comparisonLeftID, "version-1")
    XCTAssertEqual(model.comparisonRightID, "draft")
    XCTAssertEqual(model.comparison, candidate)
    XCTAssertEqual(try model.comparisonSources().map(\.id), ["draft", "candidate", "version-2", "version-1"])
    let timedSources = try model.comparisonSources()
    XCTAssertTrue(timedSources.allSatisfy { $0.updatedAt != nil })
    XCTAssertEqual(timedSources.first(where: { $0.id == "version-1" })?.updatedAt, model.editedAt(forVersion: 1))
    let reopened = AppModel(documentURL: model.documentURL)
    XCTAssertEqual(try reopened.comparisonSources().first(where: { $0.id == "candidate" })?.updatedAt,
      timedSources.first(where: { $0.id == "candidate" })?.updatedAt)
  }

  @MainActor func testSavingCandidatePreservesDraftHiddenSectionsAndImmutableVersions() async throws {
    let model = try makeModel("# 角色\n老师原稿\n\n# 约束\n隐藏内容")
    let hidden = try XCTUnwrap(model.workspace?.sections.last)
    model.toggleSectionInclusion(hidden.id)
    XCTAssertTrue(model.saveVersion())
    let original = try XCTUnwrap(model.workspace?.sections)
    let document = try XCTUnwrap(model.documentURL)
    let markdown = try String(contentsOf: document, encoding: .utf8)
    model.generatePrompt()
    try await waitForAI(model)
    XCTAssertTrue(model.saveVersion(sourceID: "candidate"))
    XCTAssertEqual(model.versions.map(\.number), [2, 1])
    XCTAssertEqual(model.workspace?.sections, original)
    XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), markdown)
    XCTAssertEqual(model.selectedHistorySections.last?.content, hidden.content)
    XCTAssertEqual(model.selectedHistorySections.last?.isIncluded, false)
    XCTAssertTrue(model.selectedHistorySections.first?.content.hasPrefix("优化：") == true)
    XCTAssertEqual(model.draftVersionLabel, "工作稿")
    let reopened = AppModel(documentURL: document)
    XCTAssertEqual(reopened.workspace?.sections, original)
    XCTAssertEqual(reopened.draftVersionLabel, "工作稿")
    XCTAssertTrue(model.applyComparisonSource("candidate"))
    XCTAssertEqual(model.workspace?.sections, model.selectedHistorySections)
    XCTAssertEqual(model.draftVersionLabel, "V2")
    model.selectHistory(try XCTUnwrap(model.versions.last))
    XCTAssertEqual(model.selectedHistorySections, original)
    XCTAssertFalse(try String(contentsOf: PromptDocumentStorage.versionURL(1, for: document), encoding: .utf8).contains("优化："))
  }

  @MainActor func testMissingComparisonSourceCannotReplaceDraftOrCreateVersion() throws {
    let model = try makeModel("保留原稿")
    let original = model.workspace
    XCTAssertFalse(model.applyComparisonSource("version-99"))
    XCTAssertFalse(model.saveVersion(sourceID: "candidate"))
    XCTAssertEqual(model.workspace, original)
    XCTAssertTrue(model.versions.isEmpty)
    XCTAssertEqual(try String(contentsOf: XCTUnwrap(model.documentURL), encoding: .utf8), "保留原稿")
  }

  @MainActor func testApplyingEditedComparisonPreservesHiddenSectionsAndSavedStandard() throws {
    let model = try makeModel("# 角色\n原文\n\n# 约束\n隐藏内容")
    model.toggleSectionInclusion(try XCTUnwrap(model.workspace?.sections.last?.id))
    XCTAssertTrue(model.saveVersion())
    let standard = try XCTUnwrap(model.versions.first)
    let original = try XCTUnwrap(model.workspace?.sections)
    XCTAssertTrue(model.applyComparisonSource("version-1", editedContent: "# 角色\n修改后的正文"))
    XCTAssertEqual(model.workspace?.sections.first?.id, original.first?.id)
    XCTAssertEqual(model.workspace?.sections.first?.content, "修改后的正文")
    XCTAssertEqual(model.workspace?.sections.last, original.last)
    model.selectHistory(standard)
    XCTAssertEqual(model.selectedHistorySections, original)
    XCTAssertEqual(try model.comparisonSources().first(where: { $0.id == "version-1" })?.content, "# 角色\n原文")
    let reopened = AppModel(documentURL: model.documentURL)
    XCTAssertEqual(reopened.workspace?.sections, model.workspace?.sections)
    XCTAssertEqual(reopened.draftVersionLabel, "工作稿")
    XCTAssertTrue(model.applyComparisonSource("draft", editedContent: ""))
    XCTAssertEqual(try model.comparisonSources().first?.content, "")
    XCTAssertEqual(model.workspace?.sections.last?.content, "隐藏内容")
    XCTAssertEqual(try model.comparisonSources().first(where: { $0.id == "version-1" })?.content, "# 角色\n原文")
  }

  @MainActor func testSavingEditedComparisonDoesNotApplyItOrOverwriteStandard() throws {
    let model = try makeModel("保留原文")
    XCTAssertTrue(model.saveVersion())
    XCTAssertTrue(model.saveVersion(sourceID: "version-1", editedContent: "右侧编辑后的文本 👩‍🏫"))
    XCTAssertEqual(model.freeformContent, "保留原文")
    XCTAssertEqual(model.selectedHistorySections.first?.content, "右侧编辑后的文本 👩‍🏫")
    XCTAssertEqual(try model.comparisonSources().first(where: { $0.id == "version-1" })?.content, "保留原文")
    XCTAssertFalse(model.applyComparisonSource("version-99", editedContent: "不能应用"))
    XCTAssertEqual(model.freeformContent, "保留原文")
  }

  @MainActor func testTrackedEditorSeparatesDeletedDisplayTextFromAppliedTextAndUnicodeEdits() throws {
    let edited = "保留\n新增 👩‍🏫\n"
    let presentation = PromptTrackedText(baseline: "保留\n删除文字\n", text: edited)
    XCTAssertTrue(presentation.attributed.string.contains("删除文字"))
    XCTAssertEqual(PromptTrackedText.cleanText(in: presentation.attributed), edited)
    let deletedRange = (presentation.attributed.string as NSString).range(of: "删除文字")
    XCTAssertNotNil(presentation.attributed.attribute(.strikethroughStyle, at: deletedRange.location, effectiveRange: nil))
    let addedRange = (presentation.attributed.string as NSString).range(of: "新增")
    XCTAssertNotNil(presentation.attributed.attribute(.backgroundColor, at: addedRange.location, effectiveRange: nil))
    let replacement = presentation.replacing(addedRange, with: "老师")
    XCTAssertEqual(replacement.text, "保留\n老师 👩‍🏫\n")
    XCTAssertEqual(replacement.caret, "保留\n老师".utf16.count)
    let replaceAll = presentation.replacing(NSRange(location: 0, length: presentation.attributed.length), with: "全新内容 👩‍🏫")
    XCTAssertEqual(replaceAll.text, "全新内容 👩‍🏫")
    let accepted = PromptTrackedText(baseline: "保留\n删除文字\n", text: edited, showsChanges: false)
    XCTAssertEqual(accepted.attributed.string, edited)
    XCTAssertNil(accepted.attributed.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    XCTAssertNil(accepted.attributed.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
    for offset in 0...edited.utf16.count {
      XCTAssertEqual(PromptTrackedText.plainOffset(presentation.displayOffset(offset), in: presentation.attributed), offset)
    }
    let appended = PromptTrackedText(baseline: "保留这行。", text: "保留这行。\n新增一行。")
    XCTAssertEqual(appended.attributed.string, "保留这行。\n新增一行。")
    XCTAssertNil(appended.attributed.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
    let wordEdit = PromptTrackedText(baseline: "你是一名语文老师。", text: "你是一名数学老师。")
    XCTAssertEqual(wordEdit.attributed.string, "你是一名语文数学老师。")
    XCTAssertEqual(PromptTrackedText.cleanText(in: wordEdit.attributed), "你是一名数学老师。")
    let deletedAll = PromptTrackedText(baseline: "删除全部", text: "")
    XCTAssertEqual(deletedAll.attributed.string, "删除全部")
    XCTAssertEqual(PromptTrackedText.cleanText(in: deletedAll.attributed), "")
  }

  @MainActor func testOutputComparisonSendsSameInputAndDistinctSystemPrompts() async throws {
    let model = try makeModel()
    let left = PromptComparisonSource(id: "version-1", label: "V1", content: "左侧提示词")
    let right = PromptComparisonSource(id: "draft", label: "工作稿", content: "右侧提示词")
    XCTAssertTrue(model.comparePromptOutputs(left: left, right: right, input: "同一条测试输入"))
    try await waitForAI(model)
    let requests = MockDeepSeek.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(Set(requests.compactMap { $0.messages.first?["content"] }), Set([left.content, right.content]))
    XCTAssertTrue(requests.allSatisfy { $0.messages.last?["content"] == "同一条测试输入" && $0.stream == false })
    XCTAssertNil(model.outputComparison?.leftResult.error)
    XCTAssertNil(model.outputComparison?.rightResult.error)
    XCTAssertFalse(model.outputComparison?.leftResult.content.isEmpty ?? true)
    XCTAssertFalse(model.outputComparison?.rightResult.content.isEmpty ?? true)
    let draft = PromptComparisonSource(id: "draft", label: "工作稿", content: "原文")
    let editedDraft = PromptComparisonSource(id: "draft", label: "工作稿", content: "右侧修改的原文")
    XCTAssertTrue(model.comparePromptOutputs(left: draft, right: editedDraft, input: "测试修改稿"))
    try await waitForAI(model)
    XCTAssertEqual(model.outputComparison?.left.content, "原文")
    XCTAssertEqual(model.outputComparison?.right.content, "右侧修改的原文")
  }

  @MainActor func testDeletingLatestVersionRechecksUnsavedChangesAgainstRemainingVersion() throws {
    let model = try makeModel("初稿")
    XCTAssertTrue(model.saveVersion())
    model.updateFreeformContent("新版工作稿")
    XCTAssertTrue(model.saveVersion())
    XCTAssertFalse(model.hasUnversionedChanges)
    let document = try XCTUnwrap(model.documentURL)
    // Exercise deletion when the snapshot file was already removed outside the app.
    try FileManager.default.removeItem(at: PromptDocumentStorage.versionURL(2, for: document))
    XCTAssertTrue(model.deleteVersion(2))
    XCTAssertEqual(model.workspace?.currentVersion, 1)
    XCTAssertTrue(model.hasUnversionedChanges)
    XCTAssertEqual(model.freeformContent, "新版工作稿")
    XCTAssertTrue(AppModel(documentURL: document).hasUnversionedChanges)
  }

  @MainActor func testFailedAndIncompleteOptimizationPreservePreviousReferenceAndDraft() async throws {
    let model = try makeModel()
    model.generatePrompt()
    try await waitForAI(model)
    XCTAssertNil(model.errorMessage)
    let reference = model.comparison
    let draft = model.workspace
    let document = try XCTUnwrap(model.documentURL)
    let markdown = try String(contentsOf: document, encoding: .utf8)
    for mode in ["failure", "incomplete", "malformed", "truncated", "empty"] {
      MockDeepSeek.reset(mode: mode)
      model.generatePrompt()
      try await waitForAI(model)
      XCTAssertNotNil(model.errorMessage, mode)
      XCTAssertEqual(model.comparison, reference, mode)
      XCTAssertTrue(model.showsComparison)
      XCTAssertEqual(model.workspace, draft, mode)
      XCTAssertEqual(AppModel(documentURL: document).comparison, reference, mode)
      XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), markdown, mode)
    }
  }

  @MainActor func testRightSideOptimizationUsesItsEditsAndKeepsLeftVersionAndDraft() async throws {
    let model = try makeModel("# 角色\n标准版本原文")
    XCTAssertTrue(model.saveVersion())
    model.updateFreeformContent("# 角色\n当前工作稿原文")
    model.openPromptComparison(version: 1)
    model.comparisonRightID = "version-1"
    let draft = model.workspace
    let original = try model.sectionsForComparisonSource("version-1")
    let edited = try model.sectionsForComparisonSource("version-1", editedContent: "# 角色\n右侧尚未应用的修改")
    var acceptedNewReference = false
    model.generatePrompt(from: edited) { acceptedNewReference = true }
    XCTAssertEqual(model.comparisonLeftID, "version-1")
    try await waitForAI(model)
    XCTAssertNil(model.errorMessage)
    XCTAssertTrue(acceptedNewReference)
    XCTAssertEqual(MockDeepSeek.requests.first?.sections.first?["content"], "右侧尚未应用的修改")
    XCTAssertEqual(model.comparisonRightID, "candidate")
    XCTAssertEqual(model.comparison?.sections.first?.content, "优化：右侧尚未应用的修改")
    XCTAssertEqual(model.workspace, draft)
    XCTAssertEqual(try model.sectionsForComparisonSource("version-1"), original)

    model.comparisonRightID = "version-1"
    let reference = model.comparison
    MockDeepSeek.reset(mode: "failure")
    acceptedNewReference = false
    model.generatePrompt(from: edited) { acceptedNewReference = true }
    try await waitForAI(model)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertFalse(acceptedNewReference)
    XCTAssertEqual(model.comparisonLeftID, "version-1")
    XCTAssertEqual(model.comparisonRightID, "version-1")
    XCTAssertEqual(model.comparison, reference)
    XCTAssertEqual(model.workspace, draft)
  }

  @MainActor func testCancelOptimizationRestoresReferenceAndBlocksInFlightEdits() async throws {
    let model = try makeModel()
    XCTAssertTrue(model.saveVersion())
    model.generatePrompt()
    try await waitForAI(model)
    let reference = model.comparison
    let original = model.workspace
    let section = try XCTUnwrap(original?.sections.first)
    let version = try XCTUnwrap(model.versions.first)
    model.openPromptComparison(version: version.number)
    let selection = [model.comparisonLeftID, model.comparisonRightID]
    MockDeepSeek.reset(mode: "delayed")
    model.generatePrompt()
    XCTAssertTrue(model.hasActiveAIRequest)
    model.updateFreeformContent("不能保存进正在优化的原稿")
    model.updateContent(sectionID: section.id, content: "不能覆盖")
    model.updateTitle(sectionID: section.id, title: "不能改名")
    model.deleteSection(section.id)
    model.addSection()
    model.toggleSectionInclusion(section.id)
    model.toggleFramework()
    model.loadHistory(version)
    XCTAssertFalse(model.startEditingHistory(version))
    XCTAssertFalse(model.saveVersion())
    XCTAssertFalse(model.deleteVersion(version.number))
    XCTAssertEqual(model.workspace, original)
    model.cancelPromptGeneration()
    try await waitForAI(model)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.comparison, reference)
    XCTAssertEqual(model.workspace, original)
    XCTAssertEqual([model.comparisonLeftID, model.comparisonRightID], selection)
    XCTAssertEqual(model.versions.count, 1)
    XCTAssertEqual(AppModel(documentURL: model.documentURL).comparison, reference)
  }

  @MainActor func testOptimizationPreservesExcludedSectionsAndFreezesRequestSettings() async throws {
    let model = try makeModel("# 角色\n需要优化的正文\n\n# 约束\n隐藏的原文")
    let hidden = try XCTUnwrap(model.workspace?.sections.last)
    model.toggleSectionInclusion(hidden.id)
    model.generatePrompt()
    model.deepSeekModel = "不应进入请求的模型"
    model.deepSeekAPIKey = "不应进入请求的 Key"
    try await waitForAI(model)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.comparison?.sections.first(where: { $0.sectionID == hidden.id })?.content, hidden.content)
    let request = try XCTUnwrap(MockDeepSeek.requests.first)
    XCTAssertEqual(request.model, "deepseek-flash")
    XCTAssertEqual(request.authorization, "Bearer test-key")
    XCTAssertEqual(request.sections.count, 1)
  }

  @MainActor func testConnectionResultDoesNotValidateSettingsChangedDuringRequest() async throws {
    let model = try makeModel()
    MockDeepSeek.reset(mode: "delayed")
    model.testDeepSeekConnection()
    model.testDeepSeekConnection()
    model.deepSeekAPIKey = "修改后的 Key"
    try await waitForAI(model)
    XCTAssertNil(model.deepSeekConnectionSucceeded)
    XCTAssertEqual(model.deepSeekConnectionMessage, "配置已修改，请重新测试")
    XCTAssertEqual(MockDeepSeek.requests.count, 1)
    XCTAssertEqual(MockDeepSeek.requests.first?.authorization, "Bearer test-key")
  }

  @MainActor func testCreationFailureAndCancelPreservePreviousResult() async throws {
    let model = try makeModel()
    let draft = model.workspace
    model.creationRequest = "给老师写个提示词"
    model.createPromptWithAI()
    try await waitForAI(model)
    let result = model.generatedPrompt
    XCTAssertFalse(result.isEmpty)
    for mode in ["failure", "delayed"] {
      MockDeepSeek.reset(mode: mode)
      model.createPromptWithAI()
      if mode == "delayed" { model.cancelPromptGeneration() }
      try await waitForAI(model)
      XCTAssertEqual(model.generatedPrompt, result)
      XCTAssertEqual(model.workspace, draft)
      XCTAssertNil(model.comparison)
    }
  }
}

private final class MockDeepSeek: URLProtocol {
  struct Captured {
    let model: String?
    let authorization: String?
    let sections: [[String: String]]
    let messages: [[String: String]]
    let stream: Bool
  }
  private static let lock = NSLock()
  private static var mode = "success"
  private static var captured: [Captured] = []
  private var stopped = false

  static var requests: [Captured] {
    lock.lock(); defer { lock.unlock() }
    return captured
  }
  static func reset(mode: String = "success") {
    lock.lock(); defer { lock.unlock() }
    self.mode = mode
    captured = []
  }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bugfix-test.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
      }
    }
    let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let messages = object["messages"] as? [[String: String]] ?? []
    let input = messages.last?["content"]?.data(using: .utf8) ?? Data()
    let sections = (try? JSONSerialization.jsonObject(with: input)) as? [[String: String]] ?? []
    Self.lock.lock()
    let mode = Self.mode
    Self.captured.append(.init(model: object["model"] as? String, authorization: request.value(forHTTPHeaderField: "Authorization"), sections: sections, messages: messages, stream: object["stream"] as? Bool ?? false))
    Self.lock.unlock()
    let deliver = {
      Self.lock.lock()
      let stopped = self.stopped
      Self.lock.unlock()
      guard !stopped else { return }
      let response = HTTPURLResponse(url: self.request.url!, statusCode: mode == "failure" ? 500 : 200,
        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      let data: Data
      if self.request.httpMethod == "GET" {
        data = Data(#"{"data":[{"id":"deepseek-flash"}]}"#.utf8)
      } else if mode == "failure" {
        data = Data(#"{"error":{"message":"模拟失败"}}"#.utf8)
      } else if object["stream"] as? Bool == false {
        data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "测试输出"], "finish_reason": "stop"]]])
      } else {
        let lines = sections.map { section -> String in
          let content = mode == "empty" ? "" : "优化：" + (section["content"] ?? "")
          return String(data: try! JSONSerialization.data(withJSONObject: ["id": section["id"]!, "content": content]), encoding: .utf8)!
        }.joined(separator: "\n")
        let chunk = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": mode == "incomplete" ? "" : mode == "malformed" ? "无效 JSON" : lines], "finish_reason": mode == "truncated" ? "length" : "stop"]]])
        data = Data("data: \(String(data: chunk, encoding: .utf8)!)\n\ndata: [DONE]\n\n".utf8)
      }
      self.client?.urlProtocol(self, didLoad: data)
      self.client?.urlProtocolDidFinishLoading(self)
    }
    if mode == "delayed" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: deliver) }
    else { deliver() }
  }
  override func stopLoading() {
    Self.lock.lock(); defer { Self.lock.unlock() }
    stopped = true
  }
}
