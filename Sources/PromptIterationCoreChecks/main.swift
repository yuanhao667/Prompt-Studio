import Foundation
import PromptIterationCore

@main
struct PromptIterationCoreChecks {
  static func main() throws {
    let checks: [(String, () throws -> Void)] = [
      ("default workspace and autosave", defaultWorkspaceAndAutosave),
      ("partial apply and reject", partialApplyAndReject),
      ("comparison state persistence", comparisonStatePersistence),
      ("immutable version history", immutableVersionHistory),
    ]

    for (name, check) in checks {
      do {
        try check()
        print("PASS  \(name)")
      } catch {
        fputs("FAIL  \(name): \(error.localizedDescription)\n", stderr)
        Foundation.exit(1)
      }
    }
    print("All \(checks.count) phase-one core checks passed.")
  }

  private static func defaultWorkspaceAndAutosave() throws {
    let context = try TestContext()
    defer { context.cleanup() }
    var workspace = try context.repository.loadOrCreateWorkspace()
    try require(workspace.sections.count == 12, "默认栏目数量不正确")
    try require(workspace.sections.first?.title == "角色与定位", "默认栏目顺序不正确")

    workspace.sections[0].content = "你是一名编辑"
    try context.repository.saveDraft(workspace)
    let reopened = try WorkspaceRepository(databaseURL: context.databaseURL)
    let restored = try reopened.loadOrCreateWorkspace()
    try require(restored.sections[0].content == "你是一名编辑", "工作稿未在重启后恢复")
  }

  private static func partialApplyAndReject() throws {
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

    try require(current[0].content == "新角色", "接受栏目没有更新当前工作稿")
    try require(current[1].content == "原目标", "接受一个栏目影响了其他栏目")
    try require(comparison[0].status == .accepted, "接受状态错误")
    try require(comparison[1].status == .rejected, "拒绝状态错误")
  }

  private static func comparisonStatePersistence() throws {
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
    let restored = try context.repository.loadComparison(projectID: workspace.id)
    try require(restored == snapshot, "候选内容或处理状态未恢复")
  }

  private static func immutableVersionHistory() throws {
    let context = try TestContext()
    defer { context.cleanup() }
    var workspace = try context.repository.loadOrCreateWorkspace()
    workspace.sections[0].content = "第一版"
    try context.repository.saveDraft(workspace)
    let first = try context.repository.saveVersion(workspace: workspace, note: "v1")

    workspace.sections[0].content = "第二版"
    try context.repository.saveDraft(workspace)
    let second = try context.repository.saveVersion(workspace: workspace, note: "v2")

    workspace.sections = []
    try context.repository.saveDraft(workspace)
    let third = try context.repository.saveVersion(workspace: workspace, note: "empty")

    try require(first.number == 1 && second.number == 2 && third.number == 3, "正式版本号不连续")
    try require(
      try context.repository.versionSections(projectID: workspace.id, number: 1)[0].content
        == "第一版",
      "修改工作稿覆盖了历史版本"
    )
    try require(
      try context.repository.versionSections(projectID: workspace.id, number: 2)[0].content
        == "第二版",
      "第二版快照不正确"
    )
    try require(
      try context.repository.versionSections(projectID: workspace.id, number: 3).isEmpty,
      "空栏目正式版本无法恢复"
    )
  }

  private static func require(
    _ condition: @autoclosure () throws -> Bool,
    _ message: String
  ) throws {
    if try !condition() { throw CheckError(message) }
  }
}

private struct CheckError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

private final class TestContext {
  let directory: URL
  let databaseURL: URL
  let repository: WorkspaceRepository

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("prompt-iteration-checks-\(UUID().uuidString)")
    databaseURL = directory.appendingPathComponent("test.db")
    repository = try WorkspaceRepository(databaseURL: databaseURL)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}
