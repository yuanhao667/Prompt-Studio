import AppKit
import PromptIterationCore
import SwiftUI

@main
struct PromptIterationAssistantApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .frame(minWidth: 1_080, minHeight: 700)
    }
    .windowStyle(.titleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("新建手动候选") { model.createManualComparison() }
          .keyboardShortcut("n")
      }
      CommandMenu("Prompt") {
        Button("保存为新版本") { model.saveVersion() }
          .keyboardShortcut("s", modifiers: [.command, .shift])
        Button("复制完整 Prompt") { model.copyFullPrompt() }
          .keyboardShortcut("c", modifiers: [.command, .shift])
      }
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published var workspace: PromptWorkspace?
  @Published var comparison: ComparisonSnapshot?
  @Published var versions: [VersionSummary] = []
  @Published var currentOnLeading = true
  @Published var hasUnversionedChanges = false
  @Published var status = "就绪"
  @Published var errorMessage: String?

  let databaseURL: URL
  private var repository: WorkspaceRepository?

  init() {
    databaseURL = Self.databaseURLFromArguments()
    do {
      let repository = try WorkspaceRepository(databaseURL: databaseURL)
      self.repository = repository
      let workspace = try repository.loadOrCreateWorkspace()
      self.workspace = workspace
      comparison = try repository.loadComparison(projectID: workspace.id)
      versions = try repository.listVersions(projectID: workspace.id)
      hasUnversionedChanges = try Self.hasChanges(
        workspace: workspace,
        repository: repository
      )
      status = "工作稿已从本地恢复"
    } catch {
      repository = nil
      errorMessage = error.localizedDescription
      status = "数据库打开失败"
    }
  }

  var versionLabel: String {
    guard let workspace else { return "不可用" }
    return workspace.currentVersion == 0 ? "尚无正式版本" : "当前版本 V\(workspace.currentVersion)"
  }

  var saveStateLabel: String {
    hasUnversionedChanges ? "有未保存到正式版本的修改" : "工作稿已自动保存"
  }

  var comparisonTitle: String {
    guard let comparison else { return "对比内容为空" }
    switch comparison.kind {
    case .manual: return "手动候选"
    case .history: return "历史版本 V\(comparison.sourceVersion ?? 0)"
    }
  }

  func updateName(_ name: String) {
    guard var workspace else { return }
    workspace.name = name
    self.workspace = workspace
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      status = "Prompt 名称不能为空；输入有效名称后会自动保存"
    } else {
      persistDraft(markChanged: false)
    }
  }

  func updateTitle(sectionID: String, title: String) {
    guard var workspace,
      let index = workspace.sections.firstIndex(where: { $0.id == sectionID })
    else { return }
    workspace.sections[index].title = title
    self.workspace = workspace
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      status = "栏目名称不能为空；输入有效名称后会自动保存"
    } else {
      persistDraft()
      syncManualComparisonStructure()
    }
  }

  func updateContent(sectionID: String, content: String) {
    mutateWorkspace { workspace in
      guard let index = workspace.sections.firstIndex(where: { $0.id == sectionID }) else { return }
      workspace.sections[index].content = content
    }
  }

  func addSection() {
    mutateWorkspace { workspace in
      workspace.sections.append(
        PromptSection(
          id: UUID().uuidString.lowercased(),
          title: "新维度",
          position: workspace.sections.count
        )
      )
    }
    syncManualComparisonStructure()
  }

  func deleteSection(_ sectionID: String) {
    mutateWorkspace { workspace in
      workspace.sections.removeAll { $0.id == sectionID }
      normalize(&workspace.sections)
    }
    syncManualComparisonStructure()
  }

  func moveSection(_ sectionID: String, to targetID: String) {
    mutateWorkspace { workspace in
      guard sectionID != targetID,
        let source = workspace.sections.firstIndex(where: { $0.id == sectionID }),
        let destination = workspace.sections.firstIndex(where: { $0.id == targetID })
      else { return }
      workspace.sections.swapAt(source, destination)
      normalize(&workspace.sections)
    }
    syncManualComparisonStructure()
  }

  func toggleSectionInclusion(_ sectionID: String) {
    mutateWorkspace { workspace in
      guard let index = workspace.sections.firstIndex(where: { $0.id == sectionID }) else {
        return
      }
      workspace.sections[index].isIncluded.toggle()
    }
  }

  func createManualComparison() {
    guard let workspace, let repository else { return }
    let snapshot = ComparisonSnapshot(
      kind: .manual,
      sourceVersion: nil,
      sections: workspace.sections.map {
        ComparisonSection(
          sectionID: $0.id,
          title: $0.title,
          content: "",
          position: $0.position
        )
      }
    )
    do {
      try repository.saveComparison(projectID: workspace.id, snapshot: snapshot)
      comparison = snapshot
      status = "已创建空白手动候选"
    } catch { report(error) }
  }

  func loadHistory(_ version: VersionSummary) {
    guard let workspace, let repository else { return }
    do {
      let sections = try repository.versionSections(projectID: workspace.id, number: version.number)
      let snapshot = ComparisonSnapshot(
        kind: .history,
        sourceVersion: version.number,
        sections: sections.map {
          ComparisonSection(
            sectionID: $0.id,
            title: $0.title,
            content: $0.content,
            position: $0.position
          )
        }
      )
      try repository.saveComparison(projectID: workspace.id, snapshot: snapshot)
      comparison = snapshot
      status = "已将 V\(version.number) 调入对比区"
    } catch { report(error) }
  }

  func clearComparison() {
    guard let workspace, let repository else { return }
    do {
      try repository.clearComparison(projectID: workspace.id)
      comparison = nil
      status = "对比区已清空"
    } catch { report(error) }
  }

  func updateComparisonContent(sectionID: String, content: String) {
    guard var comparison, comparison.kind == .manual,
      let index = comparison.sections.firstIndex(where: { $0.sectionID == sectionID })
    else { return }
    comparison.sections[index].content = content
    comparison.sections[index].status = .userModified
    self.comparison = comparison
    persistComparison()
  }

  func applyComparison(sectionID: String) {
    guard var workspace, var comparison else { return }
    do {
      try WorkspaceActions.apply(
        sectionID: sectionID,
        current: &workspace.sections,
        comparison: &comparison.sections
      )
      self.workspace = workspace
      self.comparison = comparison
      persistDraft()
      persistComparison()
      status = "已应用目标栏目"
    } catch { report(error) }
  }

  func rejectComparison(sectionID: String) {
    guard var comparison else { return }
    do {
      try WorkspaceActions.reject(sectionID: sectionID, comparison: &comparison.sections)
      self.comparison = comparison
      persistComparison()
      status = "已拒绝目标栏目"
    } catch { report(error) }
  }

  func saveVersion() {
    guard var workspace, let repository else { return }
    do {
      try repository.saveDraft(workspace)
      let version = try repository.saveVersion(workspace: workspace, note: "手动保存")
      workspace.currentVersion = version.number
      self.workspace = workspace
      versions = try repository.listVersions(projectID: workspace.id)
      hasUnversionedChanges = false
      status = "已保存正式版本 V\(version.number)"
    } catch { report(error) }
  }

  func copyFullPrompt() {
    guard let workspace else { return }
    copy(PromptMarkdown.render(workspace.sections))
    let count = workspace.sections.filter(\.isIncluded).count
    status = "已复制 Markdown Prompt，共 \(count) 个维度"
  }

  func copyComparisonPrompt() {
    guard let workspace, let comparison else { return }
    let included = Dictionary(uniqueKeysWithValues: workspace.sections.map { ($0.id, $0.isIncluded) })
    let sections = comparison.sections.map {
      PromptSection(
        id: $0.sectionID,
        title: $0.title,
        content: $0.content,
        position: $0.position,
        isIncluded: included[$0.sectionID] ?? true
      )
    }
    copy(PromptMarkdown.render(sections))
    status = "已复制 Markdown 候选 Prompt"
  }

  private func mutateWorkspace(_ change: (inout PromptWorkspace) -> Void) {
    guard var workspace else { return }
    change(&workspace)
    self.workspace = workspace
    persistDraft()
  }

  private func persistDraft(markChanged: Bool = true) {
    guard let workspace, let repository else { return }
    do {
      // ponytail: per-edit writes are enough for the single-user prototype; debounce if profiling shows UI stalls.
      try repository.saveDraft(workspace)
      if markChanged { hasUnversionedChanges = true }
      status = "工作稿已自动保存"
    } catch { report(error) }
  }

  private func persistComparison() {
    guard let workspace, let comparison, let repository else { return }
    do { try repository.saveComparison(projectID: workspace.id, snapshot: comparison) } catch {
      report(error)
    }
  }

  private func syncManualComparisonStructure() {
    guard let workspace, var comparison, comparison.kind == .manual else { return }
    let old = Dictionary(uniqueKeysWithValues: comparison.sections.map { ($0.sectionID, $0) })
    comparison.sections = workspace.sections.map { section in
      var item =
        old[section.id]
        ?? ComparisonSection(
          sectionID: section.id,
          title: section.title,
          content: "",
          position: section.position
        )
      item.title = section.title
      item.position = section.position
      return item
    }
    self.comparison = comparison
    persistComparison()
  }

  private func normalize(_ sections: inout [PromptSection]) {
    for index in sections.indices { sections[index].position = index }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func report(_ error: Error) {
    errorMessage = error.localizedDescription
    status = error.localizedDescription
  }

  private static func hasChanges(
    workspace: PromptWorkspace,
    repository: WorkspaceRepository
  ) throws -> Bool {
    guard workspace.currentVersion > 0 else {
      return workspace.sections.contains {
        !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
    return try repository.versionSections(
      projectID: workspace.id,
      number: workspace.currentVersion
    ) != workspace.sections
  }

  private static func databaseURLFromArguments() -> URL {
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "--db"), arguments.indices.contains(index + 1) {
      return URL(
        fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath
      )
    }
    return WorkspaceRepository.defaultDatabaseURL()
  }
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @State private var pendingDeletion: PromptSection?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let workspace = model.workspace {
        HStack(alignment: .top, spacing: 12) {
          if model.currentOnLeading {
            currentPane(workspace)
            comparisonPane
          } else {
            comparisonPane
            currentPane(workspace)
          }
        }
        .padding(14)
      } else {
        emptyState
      }
      Divider()
      footer
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("好") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .confirmationDialog(
      "删除栏目“\(pendingDeletion?.title ?? "")”？",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("删除栏目", role: .destructive) {
        if let pendingDeletion { model.deleteSection(pendingDeletion.id) }
        pendingDeletion = nil
      }
      Button("取消", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("该栏目会从当前工作稿和手动候选中删除；已保存的正式版本不受影响。")
    }
  }

  private var header: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) {
        TextField(
          "Prompt 名称",
          text: Binding(
            get: { model.workspace?.name ?? "" },
            set: model.updateName
          )
        )
        .font(.title2.bold())
        .textFieldStyle(.plain)
        .frame(minWidth: 220, maxWidth: 420)

        Text(model.versionLabel)
          .foregroundStyle(.secondary)
        Text(model.saveStateLabel)
          .font(.caption.bold())
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            model.hasUnversionedChanges ? Color.orange.opacity(0.15) : Color.green.opacity(0.15),
            in: Capsule()
          )
        Spacer()
        Button("保存为新版本") { model.saveVersion() }
          .buttonStyle(.borderedProminent)
      }

      HStack {
        Button("新增维度") { model.addSection() }
        Menu("选择对比来源") {
          Button("新建空白手动候选") { model.createManualComparison() }
          if !model.versions.isEmpty {
            Divider()
            ForEach(model.versions) { version in
              Button("历史版本 V\(version.number)") { model.loadHistory(version) }
            }
          }
          Divider()
          Button("清空对比区") { model.clearComparison() }
        }
        Text("当前：\(model.comparisonTitle)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
    }
    .padding(14)
  }

  private func currentPane(_ workspace: PromptWorkspace) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Spacer()
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
          .draggable("prompt-pane-current")
          .help("左右拖动用户 Prompt")
        Spacer()
      }
      HStack {
        Label("用户 Prompt", systemImage: "pencil.line")
          .font(.headline)
          .foregroundStyle(.blue)
        Spacer()
        Button { model.copyFullPrompt() } label: {
          Image(systemName: "doc.on.doc")
        }
        .help("复制完整 Prompt")
      }
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(workspace.sections) { section in
            currentSectionEditor(section)
            if section.id != workspace.sections.last?.id {
              Divider().padding(.vertical, 6)
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
      }
    }
    .padding(12)
    .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue, lineWidth: 2))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .dropDestination(for: String.self) { items, _ in
      guard items.contains("prompt-pane-comparison") else { return false }
      model.currentOnLeading.toggle()
      return true
    }
  }

  private var comparisonPane: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Spacer()
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
          .draggable("prompt-pane-comparison")
          .help("左右拖动 AI 生成 Prompt")
        Spacer()
      }
      HStack {
        Label("AI 生成 Prompt（\(model.comparisonTitle)）", systemImage: "rectangle.split.2x1")
          .font(.headline)
        Spacer()
        if model.comparison != nil {
          Button { model.copyComparisonPrompt() } label: {
            Image(systemName: "doc.on.doc")
          }
          .help("复制完整候选")
        }
      }
      if let comparison = model.comparison {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(comparison.sections) { section in
              comparisonSectionEditor(section, kind: comparison.kind)
              if section.id != comparison.sections.last?.id {
                Divider().padding(.vertical, 6)
              }
            }
          }
          .padding(.horizontal, 10)
          .padding(.bottom, 10)
        }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "rectangle.dashed")
            .font(.system(size: 38))
            .foregroundStyle(.secondary)
          Text("选择历史版本，或新建空白手动候选。")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(12)
    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .dropDestination(for: String.self) { items, _ in
      guard items.contains("prompt-pane-current") else { return false }
      model.currentOnLeading.toggle()
      return true
    }
  }

  private func currentSectionEditor(_ section: PromptSection) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
          .draggable(section.id)
          .help("上下拖动维度")
        Text("#")
          .font(.headline.monospaced())
          .foregroundStyle(.blue)
        TextField(
          "维度名称",
          text: Binding(
            get: {
              model.workspace?.sections.first(where: { $0.id == section.id })?.title ?? ""
            },
            set: { model.updateTitle(sectionID: section.id, title: $0) }
          )
        )
        .font(.headline)
        .textFieldStyle(.plain)
        Button {
          model.toggleSectionInclusion(section.id)
        } label: {
          Image(systemName: section.isIncluded ? "eye" : "eye.slash")
        }
        .buttonStyle(.plain)
        .help(section.isIncluded ? "从复制中隐藏" : "加入复制")
        Button(role: .destructive) {
          pendingDeletion = section
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.plain)
        .help("删除维度")
      }
      TextEditor(
        text: Binding(
          get: {
            model.workspace?.sections.first(where: { $0.id == section.id })?.content ?? ""
          },
          set: { model.updateContent(sectionID: section.id, content: $0) }
        )
      )
      .font(.system(.body, design: .monospaced))
      .scrollContentBackground(.hidden)
      .frame(minHeight: 100)
      .padding(.leading, 42)
    }
    .padding(.vertical, 10)
    .opacity(section.isIncluded ? 1 : 0.48)
    .dropDestination(for: String.self) { items, _ in
      guard let sourceID = items.first,
        model.workspace?.sections.contains(where: { $0.id == sourceID }) == true
      else { return false }
      model.moveSection(sourceID, to: section.id)
      return true
    }
  }

  private func comparisonSectionEditor(
    _ section: ComparisonSection,
    kind: ComparisonKind
  ) -> some View {
    let isIncluded = model.workspace?.sections.first(where: { $0.id == section.sectionID })?
      .isIncluded ?? true
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Color.clear.frame(width: 16, height: 16)
        Text("#")
          .font(.headline.monospaced())
          .foregroundStyle(.blue)
        Text(section.title).font(.headline)
        Spacer()
      }
      if kind == .manual {
        TextEditor(
          text: Binding(
            get: {
              model.comparison?.sections.first(where: { $0.sectionID == section.sectionID })?
                .content ?? ""
            },
            set: { model.updateComparisonContent(sectionID: section.sectionID, content: $0) }
          )
        )
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .frame(minHeight: 100)
        .padding(.leading, 42)
      } else {
        Text(section.content.isEmpty ? "该版本无内容" : section.content)
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(section.content.isEmpty ? .secondary : .primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
          .padding(.leading, 42)
      }
    }
    .padding(.vertical, 10)
    .opacity(isIncluded ? 1 : 0.48)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 40))
      Text("工作台无法加载")
      Text(model.errorMessage ?? "请检查本地数据库。")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      Text(model.status)
      Spacer()
      Text("本地数据库：\(model.databaseURL.path)")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(.bar)
  }
}
