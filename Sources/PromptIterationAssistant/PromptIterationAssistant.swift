import AppKit
import CryptoKit
import PromptIterationCore
import Security
import SwiftUI
import UniformTypeIdentifiers

@main
struct PromptIterationAssistantApp: App {
  var body: some Scene {
    WindowGroup {
      AppRootView()
        .frame(minWidth: 1_080, minHeight: 700)
        .ignoresSafeArea(.container, edges: .top)
    }
    .windowStyle(.hiddenTitleBar)
  }
}

private struct WorkspaceItem: Identifiable {
  let url: URL
  let children: [WorkspaceItem]?

  var id: String { url.standardizedFileURL.path }
  var isDirectory: Bool { children != nil }
}

struct AppRootView: View {
  private static let workspaceMarkerName = ".prompt-iteration-folder"
  @State private var model: AppModel?
  @State private var launchSettingsModel: AppModel?
  @State private var folderURL: URL?
  @State private var markdownFiles: [URL] = []
  @State private var workspaceItems: [WorkspaceItem] = []
  @State private var launcherError: String?
  @State private var workspacePage: WorkspacePage = .editor
  @State private var showsSidebar = true
  @State private var pendingRenameURL: URL?
  @State private var renameText = ""
  @State private var pendingDocumentDeletion: URL?

  var body: some View {
    Group {
      if let launchSettingsModel {
        VStack(spacing: 0) {
          HStack {
            Button {
              self.launchSettingsModel = nil
            } label: {
              Label("返回启动页", systemImage: "chevron.left")
            }
            Spacer()
          }
          .padding(.leading, 82)
          .padding(.trailing, 14)
          .padding(.vertical, 14)
          Divider()
          DeepSeekSettingsView(model: launchSettingsModel)
        }
      } else if let folderURL {
        HSplitView {
          if showsSidebar {
            folderSidebar(folderURL)
              .frame(minWidth: 210, idealWidth: 230, maxWidth: 320)
          }
          VStack(spacing: 0) {
            workspaceNavigation
            if let model {
              ContentView(model: model, page: $workspacePage)
            } else {
              VStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                  .font(.system(size: 40))
                  .foregroundStyle(.secondary)
                Text("这个文件夹里还没有 Markdown Prompt")
                  .font(.headline)
                Button("新建 Prompt") { createPrompt(in: folderURL) }
                  .buttonStyle(.borderedProminent)
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
      } else {
        launchPage
      }
    }
    .alert(
      "文件操作失败",
      isPresented: Binding(
        get: { launcherError != nil },
        set: { if !$0 { launcherError = nil } }
      )
    ) {
      Button("好") { launcherError = nil }
    } message: {
      Text(launcherError ?? "")
    }
    .alert(
      "重命名文档",
      isPresented: Binding(
        get: { pendingRenameURL != nil },
        set: { if !$0 { pendingRenameURL = nil } }
      )
    ) {
      TextField("文档名称", text: $renameText)
      Button("重命名") {
        if let pendingRenameURL { renameDocument(pendingRenameURL, to: renameText) }
        pendingRenameURL = nil
      }
      Button("取消", role: .cancel) { pendingRenameURL = nil }
    } message: {
      Text("文件会继续保存为 Markdown 格式。")
    }
    .confirmationDialog(
      "将“\(pendingDocumentDeletion?.deletingPathExtension().lastPathComponent ?? "")”移到废纸篓？",
      isPresented: Binding(
        get: { pendingDocumentDeletion != nil },
        set: { if !$0 { pendingDocumentDeletion = nil } }
      )
    ) {
      Button("移到废纸篓", role: .destructive) {
        if let pendingDocumentDeletion { trashDocument(pendingDocumentDeletion) }
        pendingDocumentDeletion = nil
      }
      Button("取消", role: .cancel) { pendingDocumentDeletion = nil }
    }
  }

  private var workspaceNavigation: some View {
    HStack(spacing: 12) {
      Button { showsSidebar.toggle() } label: {
        Image(systemName: "sidebar.leading")
          .font(.system(size: 18, weight: .semibold))
          .frame(width: 40, height: 40)
          .background(Color(nsColor: .controlBackgroundColor), in: Circle())
          .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(showsSidebar ? "收起文件列表" : "展开文件列表")

      Spacer()
      HStack(spacing: 4) {
        ForEach(WorkspacePage.allCases) { item in
          Button { workspacePage = item } label: {
            Label(item.rawValue, systemImage: item.systemImage)
              .frame(minWidth: 96)
              .padding(.horizontal, 10)
              .padding(.vertical, 9)
              .foregroundStyle(workspacePage == item ? Color.white : Color.primary)
              .background(
                workspacePage == item ? Color.accentColor : Color.clear,
                in: Capsule()
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(3)
      .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
      Spacer()

      Color.clear.frame(width: 40, height: 40)
    }
    .padding(.leading, showsSidebar ? 14 : 82)
    .padding(.trailing, 14)
    .padding(.vertical, 8)
  }

  private var launchPage: some View {
    ZStack(alignment: .topTrailing) {
      VStack(spacing: 30) {
        VStack(spacing: 8) {
          Image(systemName: "text.document")
            .font(.system(size: 46))
            .foregroundStyle(.blue)
          Text("Prompt 迭代助手")
            .font(.largeTitle.bold())
          Text("选择一个本地 Markdown 工作区开始编写 System Prompt")
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 14) {
          launchAction(
            "新建 Prompt",
            detail: "创建带固定标题模板的 .md 文件",
            systemImage: "doc.badge.plus",
            action: createStandalonePrompt
          )
          launchAction(
            "新建文件夹",
            detail: "创建本地文件夹和第一个 Prompt",
            systemImage: "folder.badge.plus",
            action: createFolder
          )
          launchAction(
            "打开文件夹",
            detail: "读取文件夹内已有的 .md 文件",
            systemImage: "folder",
            action: openFolder
          )
        }
        .frame(maxWidth: 800)
      }

      Button {
        launchSettingsModel = AppModel()
      } label: {
        Label("设置", systemImage: "gearshape")
      }
      .padding(24)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func launchAction(
    _ title: String,
    detail: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 12) {
        Image(systemName: systemImage)
          .font(.system(size: 28))
          .foregroundStyle(.blue)
        Text(title).font(.headline)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
      }
      .padding(18)
      .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }
    .buttonStyle(.plain)
  }

  private func folderSidebar(_ folderURL: URL) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button {
          model = nil
          self.folderURL = nil
          markdownFiles = []
          workspaceItems = []
          workspacePage = .editor
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.plain)
        .help("返回启动页")
        Image(systemName: "folder.fill").foregroundStyle(.blue)
        Text(folderURL.lastPathComponent)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Menu {
          Button("新建 Prompt", systemImage: "doc.badge.plus") {
            createPrompt(in: folderURL)
          }
          Button("新建文件夹", systemImage: "folder.badge.plus") {
            createPromptFolder(in: folderURL)
          }
        } label: {
          Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("新建 Prompt 或文件夹")
      }
      .padding(.leading, 72)
      .padding(.trailing, 12)
      .padding(.vertical, 12)
      Divider()

      ScrollView {
        OutlineGroup(workspaceItems, children: \.children) { item in
          workspaceItemRow(item)
        }
        .padding(8)
      }
      Spacer()
      Text(folderURL.path)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(2)
        .padding(12)
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  @ViewBuilder
  private func workspaceItemRow(_ item: WorkspaceItem) -> some View {
    if item.isDirectory {
      Label(item.url.lastPathComponent, systemImage: "folder")
        .lineLimit(1)
        .padding(.vertical, 6)
    } else {
      HStack(spacing: 4) {
        Button { openDocument(item.url) } label: {
          HStack(spacing: 8) {
            Image(systemName: "doc.text")
            Text(item.url.deletingPathExtension().lastPathComponent)
              .lineLimit(1)
            Spacer()
          }
          .padding(.leading, 8)
          .padding(.vertical, 7)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Menu {
          Button("重命名", systemImage: "pencil") { beginRenaming(item.url) }
          Button("在 Finder 中显示", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
          }
          Divider()
          Button("移到废纸篓", systemImage: "trash", role: .destructive) {
            pendingDocumentDeletion = item.url
          }
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      .padding(.horizontal, 2)
      .frame(maxWidth: .infinity)
      .background(
        model?.documentURL?.standardizedFileURL == item.url.standardizedFileURL
          ? Color.blue.opacity(0.14) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7)
      )
      .contextMenu {
        Button("重命名") { beginRenaming(item.url) }
        Button("在 Finder 中显示") {
          NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        Button("移到废纸篓", role: .destructive) {
          pendingDocumentDeletion = item.url
        }
      }
    }
  }

  private func createStandalonePrompt() {
    let panel = NSSavePanel()
    panel.title = "新建 Prompt"
    panel.nameFieldStringValue = "System Prompt.md"
    panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    createDocument(at: url.pathExtension.lowercased() == "md" ? url : url.appendingPathExtension("md"))
  }

  private func createFolder() {
    let panel = NSSavePanel()
    panel.title = "新建 Prompt 文件夹"
    panel.nameFieldStringValue = "Prompt 项目"
    panel.allowedContentTypes = [.folder]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try markPromptFolder(url)
      let promptURL = uniquePromptURL(in: url)
      try writeDefaultPrompt(to: promptURL)
      openWorkspace(url, selecting: promptURL)
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func openFolder() {
    let panel = NSOpenPanel()
    panel.title = "打开 Prompt 文件夹"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    openWorkspace(url)
  }

  private func createPrompt(in folderURL: URL) {
    let panel = NSSavePanel()
    panel.title = "在文件夹中新建 Prompt"
    panel.directoryURL = folderURL
    panel.nameFieldStringValue = "System Prompt.md"
    panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
    panel.canCreateDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    createDocument(at: url.pathExtension.lowercased() == "md" ? url : url.appendingPathExtension("md"))
  }

  private func createPromptFolder(in folderURL: URL) {
    let panel = NSSavePanel()
    panel.title = "新建 Prompt 文件夹"
    panel.directoryURL = folderURL
    panel.nameFieldStringValue = "Prompt 文件夹"
    panel.allowedContentTypes = [.folder]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try markPromptFolder(url)
      refreshFiles(in: folderURL)
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func createDocument(at url: URL) {
    do {
      try writeDefaultPrompt(to: url)
      openWorkspace(url.deletingLastPathComponent(), selecting: url)
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func openWorkspace(_ url: URL, selecting selected: URL? = nil) {
    folderURL = url
    refreshFiles(in: url)
    if let selected {
      openDocument(selected)
    } else if let first = markdownFiles.first {
      openDocument(first)
    } else {
      model = nil
    }
  }

  private func openDocument(_ url: URL) {
    model = AppModel(documentURL: url)
  }

  private func beginRenaming(_ url: URL) {
    renameText = url.deletingPathExtension().lastPathComponent
    pendingRenameURL = url
  }

  private func renameDocument(_ url: URL, to enteredName: String) {
    let trimmed = enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = trimmed.lowercased().hasSuffix(".md")
      ? String(trimmed.dropLast(3)) : trimmed
    guard !name.isEmpty,
      name != ".",
      name != "..",
      !name.contains("/")
    else {
      launcherError = "请输入有效的文档名称"
      return
    }

    let destination = url.deletingLastPathComponent().appendingPathComponent("\(name).md")
    guard destination.standardizedFileURL != url.standardizedFileURL else { return }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      launcherError = "同名文档已经存在"
      return
    }

    let wasSelected = model?.documentURL?.standardizedFileURL == url.standardizedFileURL
    if wasSelected { model = nil }
    do {
      try FileManager.default.moveItem(at: url, to: destination)
      do {
        try moveHistoryDatabase(from: url, to: destination)
      } catch {
        try? FileManager.default.moveItem(at: destination, to: url)
        throw error
      }
      if let folderURL { refreshFiles(in: folderURL) }
      if wasSelected { openDocument(destination) }
    } catch {
      launcherError = error.localizedDescription
      if let folderURL { refreshFiles(in: folderURL) }
      if wasSelected, FileManager.default.fileExists(atPath: url.path) { openDocument(url) }
    }
  }

  private func trashDocument(_ url: URL) {
    let wasSelected = model?.documentURL?.standardizedFileURL == url.standardizedFileURL
    if wasSelected { model = nil }
    do {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      if let folderURL {
        refreshFiles(in: folderURL)
        if wasSelected, let next = markdownFiles.first { openDocument(next) }
      }
    } catch {
      launcherError = error.localizedDescription
      if wasSelected { openDocument(url) }
    }
  }

  private func moveHistoryDatabase(from sourceDocument: URL, to destinationDocument: URL) throws {
    let source = AppModel.databaseURL(for: sourceDocument)
    let destination = AppModel.databaseURL(for: destinationDocument)
    guard source != destination, FileManager.default.fileExists(atPath: source.path) else { return }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.moveItem(at: source, to: destination)
  }

  private func refreshFiles(in folderURL: URL) {
    do {
      workspaceItems = try loadWorkspaceItems(in: folderURL)
      markdownFiles = flattenedMarkdownFiles(in: workspaceItems)
    } catch {
      launcherError = error.localizedDescription
      workspaceItems = []
      markdownFiles = []
    }
  }

  private func loadWorkspaceItems(in folderURL: URL) throws -> [WorkspaceItem] {
    try FileManager.default.contentsOfDirectory(
      at: folderURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )
    .compactMap { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isDirectory == true, values.isSymbolicLink != true {
        guard try isPromptFolder(url) else { return nil }
        return WorkspaceItem(url: url, children: try loadWorkspaceItems(in: url))
      }
      return isPromptDocument(url)
        ? WorkspaceItem(url: url, children: nil) : nil
    }
    .sorted {
      if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
      return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent)
        == .orderedAscending
    }
  }

  private func flattenedMarkdownFiles(in items: [WorkspaceItem]) -> [URL] {
    items.flatMap { item in
      item.children.map(flattenedMarkdownFiles(in:)) ?? [item.url]
    }
  }

  private func isPromptFolder(_ url: URL) throws -> Bool {
    if FileManager.default.fileExists(
      atPath: url.appendingPathComponent(Self.workspaceMarkerName).path
    ) {
      return true
    }
    return try FileManager.default.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    ).contains(where: isPromptDocument)
  }

  private func isPromptDocument(_ url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "md" else { return false }
    if FileManager.default.fileExists(atPath: AppModel.databaseURL(for: url).path) { return true }
    guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return PromptMarkdown.isStructuredPrompt(markdown)
  }

  private func markPromptFolder(_ url: URL) throws {
    let marker = url.appendingPathComponent(Self.workspaceMarkerName)
    guard !FileManager.default.fileExists(atPath: marker.path) else { return }
    try Data().write(to: marker, options: .atomic)
  }

  private func writeDefaultPrompt(to url: URL) throws {
    try PromptMarkdown.renderAll(PromptSection.defaults())
      .write(to: url, atomically: true, encoding: .utf8)
  }

  private func uniquePromptURL(in folderURL: URL) -> URL {
    var number = 1
    var url = folderURL.appendingPathComponent("System Prompt.md")
    while FileManager.default.fileExists(atPath: url.path) {
      number += 1
      url = folderURL.appendingPathComponent("System Prompt \(number).md")
    }
    return url
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published var workspace: PromptWorkspace?
  @Published var comparison: ComparisonSnapshot?
  @Published var versions: [VersionSummary] = []
  @Published var selectedHistoryVersion: VersionSummary?
  @Published var selectedHistorySections: [PromptSection] = []
  @Published var currentOnLeading = false
  @Published var showsComparison = false
  @Published var hasUnversionedChanges = false
  @Published var autosaveStatus = "已自动保存"
  @Published var versionSaveFeedback: String?
  @Published var status = "就绪"
  @Published var errorMessage: String?
  @Published var deepSeekAPIKey = ""
  @Published var deepSeekBaseURL = "https://api.deepseek.com"
  @Published var deepSeekModel = "deepseek-v4-flash"
  @Published var isTestingDeepSeek = false
  @Published var deepSeekConnectionSucceeded: Bool?
  @Published var deepSeekConnectionMessage = "尚未配置"
  @Published var isGeneratingPrompt = false

  let databaseURL: URL
  let documentURL: URL?
  private var repository: WorkspaceRepository?

  init(documentURL: URL? = nil) {
    self.documentURL = documentURL?.standardizedFileURL
    databaseURL = Self.databaseURL(for: documentURL)
    do {
      let repository = try WorkspaceRepository(databaseURL: databaseURL)
      self.repository = repository
      var workspace = try repository.loadOrCreateWorkspace()
      if let documentURL = self.documentURL {
        let markdown = try String(contentsOf: documentURL, encoding: .utf8)
        workspace.name = documentURL.deletingPathExtension().lastPathComponent
        workspace.sections = Self.preserveSectionIDs(
          parsed: PromptMarkdown.parse(markdown),
          existing: workspace.sections
        )
        try repository.saveDraft(workspace)
      }
      self.workspace = workspace
      comparison = try repository.loadComparison(projectID: workspace.id)
      versions = try repository.listVersions(projectID: workspace.id)
      if let latest = versions.first {
        selectedHistoryVersion = latest
        selectedHistorySections = try repository.versionSections(
          projectID: workspace.id,
          number: latest.number
        )
      }
      hasUnversionedChanges = try Self.hasChanges(
        workspace: workspace,
        repository: repository
      )
    } catch {
      repository = nil
      errorMessage = error.localizedDescription
      status = "数据库打开失败"
    }

    deepSeekBaseURL = UserDefaults.standard.string(forKey: "deepseek.baseURL")
      ?? "https://api.deepseek.com"
    let storedModel = UserDefaults.standard.string(forKey: "deepseek.model")
    deepSeekModel = storedModel.flatMap {
      Self.supportedDeepSeekModels.contains($0) ? $0 : nil
    } ?? "deepseek-v4-flash"
    do {
      deepSeekAPIKey = try DeepSeekKeychain.load() ?? ""
      if !deepSeekAPIKey.isEmpty {
        deepSeekConnectionMessage = "已读取本机配置，尚未测试"
      }
    } catch {
      deepSeekConnectionSucceeded = false
      deepSeekConnectionMessage = "无法读取 Keychain：\(error.localizedDescription)"
    }
  }

  var comparisonTitle: String {
    guard let comparison else { return "对比内容为空" }
    switch comparison.kind {
    case .manual: return "AI 生成结果"
    case .history: return "历史版本 V\(comparison.sourceVersion ?? 0)"
    }
  }

  func selectDeepSeekModel(_ model: String) {
    guard Self.supportedDeepSeekModels.contains(model) else { return }
    deepSeekModel = model
    deepSeekConnectionSucceeded = nil
    deepSeekConnectionMessage = "已切换模型，请保存或测试连接"
  }

  func updateTitle(sectionID: String, title: String) {
    guard var workspace,
      let index = workspace.sections.firstIndex(where: { $0.id == sectionID })
    else { return }
    workspace.sections[index].title = title
    self.workspace = workspace
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      autosaveStatus = "尚未自动保存"
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
      let section = workspace.sections.remove(at: source)
      workspace.sections.insert(section, at: min(destination, workspace.sections.count))
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
      currentOnLeading = false
      showsComparison = true
      status = "已将 V\(version.number) 调入对比区"
    } catch { report(error) }
  }

  func selectHistory(_ version: VersionSummary) {
    guard let workspace, let repository else { return }
    do {
      selectedHistoryVersion = version
      selectedHistorySections = try repository.versionSections(
        projectID: workspace.id,
        number: version.number
      )
      status = "正在查看历史版本 V\(version.number)"
    } catch { report(error) }
  }

  func copySelectedHistory() {
    guard let version = selectedHistoryVersion else { return }
    copy(PromptMarkdown.render(selectedHistorySections))
    status = "已复制历史版本 V\(version.number)"
  }

  @discardableResult
  func startEditingHistory(_ version: VersionSummary) -> Bool {
    guard let workspace, let repository else { return false }
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
      self.workspace = try repository.restoreVersionAsDraft(
        workspace: workspace,
        number: version.number
      )
      if let restored = self.workspace {
        try saveMarkdownDraft(restored)
        autosaveStatus = "已自动保存"
      }
      try repository.saveComparison(projectID: workspace.id, snapshot: snapshot)
      comparison = snapshot
      currentOnLeading = false
      showsComparison = true
      hasUnversionedChanges = true
      status = "正在基于 V\(version.number) 编辑下一版"
      return true
    } catch {
      report(error)
      return false
    }
  }

  func clearComparison() {
    guard let workspace, let repository else { return }
    do {
      try repository.clearComparison(projectID: workspace.id)
      comparison = nil
      showsComparison = false
      status = "对比区已清空"
    } catch { report(error) }
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
      selectedHistoryVersion = version
      selectedHistorySections = workspace.sections
      hasUnversionedChanges = false
      let feedback = "已保存 V\(version.number)"
      versionSaveFeedback = feedback
      status = feedback
      Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if versionSaveFeedback == feedback { versionSaveFeedback = nil }
      }
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

  @discardableResult
  func saveDeepSeekSettings() -> Bool {
    let apiKey = deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseURL = deepSeekBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let model = deepSeekModel.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !apiKey.isEmpty else {
      deepSeekConnectionSucceeded = false
      deepSeekConnectionMessage = "请先填写 DeepSeek API Key"
      status = deepSeekConnectionMessage
      return false
    }
    guard let url = URL(string: baseURL), url.scheme == "https", url.host != nil else {
      deepSeekConnectionSucceeded = false
      deepSeekConnectionMessage = "接口地址必须是有效的 HTTPS 地址"
      status = deepSeekConnectionMessage
      return false
    }
    guard Self.supportedDeepSeekModels.contains(model) else {
      deepSeekConnectionSucceeded = false
      deepSeekConnectionMessage = "请选择受支持的 DeepSeek 模型"
      status = deepSeekConnectionMessage
      return false
    }

    do {
      try DeepSeekKeychain.save(apiKey)
      UserDefaults.standard.set(baseURL, forKey: "deepseek.baseURL")
      UserDefaults.standard.set(model, forKey: "deepseek.model")
      deepSeekAPIKey = apiKey
      deepSeekBaseURL = baseURL
      deepSeekModel = model
      deepSeekConnectionSucceeded = nil
      deepSeekConnectionMessage = "配置已保存，尚未测试"
      status = "DeepSeek 配置已保存到本机"
      return true
    } catch {
      deepSeekConnectionSucceeded = false
      deepSeekConnectionMessage = "保存失败：\(error.localizedDescription)"
      status = deepSeekConnectionMessage
      return false
    }
  }

  func testDeepSeekConnection() {
    guard saveDeepSeekSettings() else { return }
    guard let endpoint = URL(string: "\(deepSeekBaseURL)/models") else { return }

    isTestingDeepSeek = true
    deepSeekConnectionSucceeded = nil
    deepSeekConnectionMessage = "正在连接 DeepSeek…"

    Task {
      do {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(deepSeekAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
          throw DeepSeekConfigurationError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
          let message = Self.deepSeekErrorMessage(from: data)
          throw DeepSeekConfigurationError.requestFailed(
            statusCode: response.statusCode,
            message: message
          )
        }
        let models = try JSONDecoder().decode(DeepSeekModelsResponse.self, from: data)
        guard models.data.contains(where: { $0.id == deepSeekModel }) else {
          throw DeepSeekConfigurationError.modelUnavailable(deepSeekModel)
        }

        isTestingDeepSeek = false
        deepSeekConnectionSucceeded = true
        deepSeekConnectionMessage = "连接成功，所选模型可以使用"
        status = "DeepSeek 连接测试成功"
      } catch {
        isTestingDeepSeek = false
        deepSeekConnectionSucceeded = false
        deepSeekConnectionMessage = "连接失败：\(error.localizedDescription)"
        status = deepSeekConnectionMessage
      }
    }
  }

  func generatePrompt() {
    guard let workspace, let repository else { return }
    let includedSections = workspace.sections.filter(\.isIncluded)
    guard includedSections.contains(where: {
      !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) else {
      errorMessage = "请先在 System Prompt 中写入内容。"
      status = errorMessage ?? ""
      return
    }
    guard saveDeepSeekSettings() else { return }
    guard let endpoint = URL(string: "\(deepSeekBaseURL)/chat/completions") else { return }

    isGeneratingPrompt = true
    status = "DeepSeek 正在优化 Prompt…"

    Task {
      do {
        let input = try JSONEncoder().encode(
          includedSections.map {
            DeepSeekPromptSection(id: $0.id, title: $0.title, content: $0.content)
          }
        )
        guard let inputJSON = String(data: input, encoding: .utf8) else {
          throw DeepSeekConfigurationError.invalidResponse
        }
        let body: [String: Any] = [
          "model": deepSeekModel,
          "messages": [
            [
              "role": "system",
              "content": """
                你是 Prompt 优化助手。优化每个栏目中的内容，但不得增加、删除、改名或调整栏目顺序。
                只返回合法 JSON，格式必须是 {"sections":[{"id":"原 id","content":"优化后的内容"}]}。
                每个输入 id 必须原样返回一次，不要输出 Markdown 代码围栏或其他说明。
                """,
            ],
            ["role": "user", "content": inputJSON],
          ],
          "response_format": ["type": "json_object"],
          "stream": false,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(deepSeekAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
          throw DeepSeekConfigurationError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
          throw DeepSeekConfigurationError.requestFailed(
            statusCode: response.statusCode,
            message: Self.deepSeekErrorMessage(from: data)
          )
        }

        let chat = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
        guard let content = chat.choices.first?.message.content,
          let generatedData = content.data(using: .utf8)
        else { throw DeepSeekConfigurationError.invalidResponse }
        let generated = try JSONDecoder().decode(DeepSeekGeneratedPrompt.self, from: generatedData)
        let generatedByID = Dictionary(
          generated.sections.map { ($0.id, $0.content) },
          uniquingKeysWith: { _, latest in latest }
        )
        guard includedSections.allSatisfy({ generatedByID[$0.id] != nil }) else {
          throw DeepSeekConfigurationError.incompletePrompt
        }

        let snapshot = ComparisonSnapshot(
          kind: .manual,
          sourceVersion: nil,
          sections: workspace.sections.map { section in
            ComparisonSection(
              sectionID: section.id,
              title: section.title,
              content: generatedByID[section.id] ?? "",
              position: section.position
            )
          }
        )
        try repository.saveComparison(projectID: workspace.id, snapshot: snapshot)
        comparison = snapshot
        currentOnLeading = false
        showsComparison = true
        isGeneratingPrompt = false
        status = "AI 参考稿已生成，右侧 System Prompt 正式稿可继续编排和修改"
      } catch {
        isGeneratingPrompt = false
        errorMessage = "AI 生成失败：\(error.localizedDescription)"
        status = errorMessage ?? ""
      }
    }
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
      try saveMarkdownDraft(workspace)
      if markChanged { hasUnversionedChanges = true }
      autosaveStatus = "已自动保存"
      status = "工作稿已自动保存"
    } catch {
      autosaveStatus = "自动保存失败"
      report(error)
    }
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

  private static func deepSeekErrorMessage(from data: Data) -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = object["error"] as? [String: Any],
      let message = error["message"] as? String
    else { return nil }
    return message
  }

  private static let supportedDeepSeekModels = [
    "deepseek-v4-flash",
    "deepseek-v4-pro",
  ]

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

  private func saveMarkdownDraft(_ workspace: PromptWorkspace) throws {
    guard let documentURL else { return }
    try PromptMarkdown.renderAll(workspace.sections)
      .write(to: documentURL, atomically: true, encoding: .utf8)
  }

  private static func preserveSectionIDs(
    parsed: [PromptSection],
    existing: [PromptSection]
  ) -> [PromptSection] {
    parsed.enumerated().map { index, section in
      let existingSection = existing.indices.contains(index) && existing[index].title == section.title
        ? existing[index] : nil
      return PromptSection(
        id: existingSection?.id ?? section.id,
        title: section.title,
        content: section.content,
        position: index,
        isIncluded: existingSection?.isIncluded ?? true
      )
    }
  }

  static func databaseURL(for documentURL: URL?) -> URL {
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "--db"), arguments.indices.contains(index + 1) {
      return URL(
        fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath
      )
    }
    if let custom = ProcessInfo.processInfo.environment["PROMPT_ITERATION_DB"], !custom.isEmpty {
      return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath)
    }
    if let documentURL {
      let digest = SHA256.hash(data: Data(documentURL.standardizedFileURL.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
      let support =
        FileManager.default.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
      return support
        .appendingPathComponent("Prompt Iteration Assistant", isDirectory: true)
        .appendingPathComponent("Workspaces", isDirectory: true)
        .appendingPathComponent("\(digest).db")
    }
    return WorkspaceRepository.defaultDatabaseURL()
  }
}

private enum DeepSeekConfigurationError: LocalizedError {
  case invalidResponse
  case incompletePrompt
  case modelUnavailable(String)
  case requestFailed(statusCode: Int, message: String?)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "服务器返回了无法识别的响应"
    case .incompletePrompt:
      return "AI 返回的栏目不完整，请重新生成"
    case .modelUnavailable(let model):
      return "当前 API Key 无法使用模型 \(model)"
    case let .requestFailed(statusCode, message):
      if let message, !message.isEmpty {
        return "HTTP \(statusCode)：\(message)"
      }
      return "HTTP \(statusCode)"
    }
  }
}

private struct DeepSeekModelsResponse: Decodable {
  struct Model: Decodable { let id: String }
  let data: [Model]
}

private struct DeepSeekPromptSection: Encodable {
  let id: String
  let title: String
  let content: String
}

private struct DeepSeekChatResponse: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message
  }

  let choices: [Choice]
}

private struct DeepSeekGeneratedPrompt: Decodable {
  struct Section: Decodable {
    let id: String
    let content: String
  }

  let sections: [Section]
}

private enum DeepSeekKeychain {
  private static let service = "com.promptiterationassistant.app"
  private static let account = "deepseek-api-key"

  static func load() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
      throw KeychainError(status: errSecDecode)
    }
    return value
  }

  static func save(_ value: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let data = Data(value.utf8)
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
  }

  private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误 \(status)"
    }
  }
}

enum WorkspacePage: String, CaseIterable, Identifiable {
  case editor = "编辑"
  case history = "历史版本"
  case settings = "设置"

  var id: Self { self }

  var systemImage: String {
    switch self {
    case .editor: return "square.and.pencil"
    case .history: return "clock.arrow.circlepath"
    case .settings: return "gearshape"
    }
  }
}

private struct DeepSeekSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var revealsAPIKey = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 6) {
          Text("设置")
            .font(.largeTitle.bold())
          Text("配置应用直连 DeepSeek 所需的本地凭证。")
            .foregroundStyle(.secondary)
        }

        GroupBox {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
              Text("API Key")
                .frame(width: 90, alignment: .trailing)
              HStack(spacing: 8) {
                if revealsAPIKey {
                  TextField("sk-…", text: $model.deepSeekAPIKey)
                    .textFieldStyle(.roundedBorder)
                } else {
                  SecureField("sk-…", text: $model.deepSeekAPIKey)
                    .textFieldStyle(.roundedBorder)
                }
                Button {
                  revealsAPIKey.toggle()
                } label: {
                  Image(systemName: revealsAPIKey ? "eye.slash" : "eye")
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(revealsAPIKey ? "隐藏 API Key" : "显示 API Key")
              }
            }

            GridRow {
              Text("接口地址")
                .frame(width: 90, alignment: .trailing)
              TextField("https://api.deepseek.com", text: $model.deepSeekBaseURL)
                .textFieldStyle(.roundedBorder)
            }

            GridRow {
              Text("模型")
                .frame(width: 90, alignment: .trailing)
              Picker(
                "模型",
                selection: Binding(
                  get: { model.deepSeekModel },
                  set: model.selectDeepSeekModel
                )
              ) {
                Text("DeepSeek V4 Flash").tag("deepseek-v4-flash")
                Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
              }
              .pickerStyle(.segmented)
              .labelsHidden()
            }
          }
          .padding(10)
        } label: {
          Label("DeepSeek API", systemImage: "network")
            .font(.headline)
        }

        HStack(spacing: 10) {
          Button("保存配置") { model.saveDeepSeekSettings() }
            .buttonStyle(.borderedProminent)
          Button("测试连接") { model.testDeepSeekConnection() }
            .disabled(model.isTestingDeepSeek)
          if model.isTestingDeepSeek {
            ProgressView()
              .controlSize(.small)
          }
        }

        HStack(alignment: .top, spacing: 10) {
          Image(
            systemName: model.deepSeekConnectionSucceeded == true
              ? "checkmark.circle.fill"
              : model.deepSeekConnectionSucceeded == false
                ? "exclamationmark.triangle.fill" : "info.circle"
          )
          .foregroundStyle(
            model.deepSeekConnectionSucceeded == true
              ? Color.green
              : model.deepSeekConnectionSucceeded == false ? Color.orange : Color.secondary
          )
          Text(model.deepSeekConnectionMessage)
        }
        .font(.callout)

        VStack(alignment: .leading, spacing: 8) {
          Label("API Key 只保存在这台 Mac 的系统 Keychain 中。", systemImage: "lock.fill")
          Label("连接测试不会上传 Prompt，只验证当前密钥能否访问模型列表。", systemImage: "checkmark.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: 720, alignment: .leading)
      .padding(32)
      .frame(maxWidth: .infinity, alignment: .top)
    }
  }
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @Binding var page: WorkspacePage
  @State private var pendingDeletion: PromptSection?
  @State private var pendingHistoryEdit: VersionSummary?
  @State private var versionSearch = ""
  @State private var hoveredSectionID: String?
  @State private var sectionDropTargetID: String?

  var body: some View {
    VStack(spacing: 0) {
      if page == .editor {
        editorPage
      } else if page == .history {
        historyPage
      } else {
        settingsPage
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
    .confirmationDialog(
      "从 V\(pendingHistoryEdit?.number ?? 0) 开始编辑？",
      isPresented: Binding(
        get: { pendingHistoryEdit != nil },
        set: { if !$0 { pendingHistoryEdit = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("创建待迭代版本") {
        if let version = pendingHistoryEdit { openHistoryEditor(version) }
        pendingHistoryEdit = nil
      }
      Button("取消", role: .cancel) { pendingHistoryEdit = nil }
    } message: {
      Text("当前工作稿会替换为这个历史版本，已保存的正式版本不会改变。")
    }
  }

  private var settingsPage: some View {
    DeepSeekSettingsView(model: model)
  }

  @ViewBuilder
  private var editorPage: some View {
    if let workspace = model.workspace {
      if !model.showsComparison {
        currentPane(workspace)
          .padding(14)
      } else {
        HStack(alignment: .top, spacing: 12) {
          if model.comparison?.kind == .history {
            comparisonPane
            currentPane(workspace)
          } else if model.currentOnLeading {
            currentPane(workspace)
            comparisonPane
          } else {
            comparisonPane
            currentPane(workspace)
          }
        }
        .padding(14)
      }
    } else {
      emptyState
    }
  }

  private var filteredVersions: [VersionSummary] {
    let query = versionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.versions }
    return model.versions.filter {
      "V\($0.number) \($0.note) \($0.createdAt)".localizedCaseInsensitiveContains(query)
    }
  }

  @ViewBuilder
  private var historyPage: some View {
    if model.versions.isEmpty {
      VStack(spacing: 12) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 42))
          .foregroundStyle(.secondary)
        Text("还没有历史版本").font(.title3.bold())
        Text("回到编辑页，点击“保存为新版本”后会出现在这里。")
          .foregroundStyle(.secondary)
        Button("返回编辑") { page = .editor }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      HSplitView {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 10) {
            TextField("搜索版本或备注", text: $versionSearch)
              .textFieldStyle(.roundedBorder)
            ScrollView {
              LazyVStack(spacing: 6) {
                ForEach(filteredVersions) { version in
                  versionRow(version)
                }
              }
            }
            if filteredVersions.isEmpty {
              Text("没有匹配的版本")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
          .padding(14)
        }
        .frame(minWidth: 250, idealWidth: 290, maxWidth: 330)

        historyDetail
          .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func versionRow(_ version: VersionSummary) -> some View {
    let selected = model.selectedHistoryVersion?.id == version.id
    return Button {
      model.selectHistory(version)
    } label: {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text("V\(version.number)").font(.headline.monospacedDigit())
          Spacer()
          if model.workspace?.currentVersion == version.number {
            Text("当前正式版本")
              .font(.caption)
              .foregroundStyle(.blue)
          }
        }
        Text(version.note.isEmpty ? "无备注" : version.note)
          .lineLimit(1)
        Text(compactDate(version.createdAt))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selected ? Color.blue.opacity(0.12) : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var historyDetail: some View {
    if let version = model.selectedHistoryVersion {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Text("V\(version.number)")
            .font(.caption.bold().monospacedDigit())
          Text(version.note.isEmpty ? "无备注" : version.note)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(compactDate(version.createdAt))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
          Spacer()
          Button {
            if model.hasUnversionedChanges {
              pendingHistoryEdit = version
            } else {
              openHistoryEditor(version)
            }
          } label: {
            Image(systemName: "square.and.pencil")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("基于这个版本编辑")
          Button {
            model.copySelectedHistory()
          } label: {
            Image(systemName: "doc.on.doc")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("复制这个版本")
        }
        .frame(height: 42)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .controlBackgroundColor))

        Divider()

        ScrollView {
          Text(PromptMarkdown.render(model.selectedHistorySections))
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
      .padding(14)
    } else {
      Text("从左侧选择一个版本")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func compactDate(_ value: String) -> String {
    String(value.replacingOccurrences(of: "T", with: " ").prefix(16))
  }

  private func openHistoryEditor(_ version: VersionSummary) {
    if model.startEditingHistory(version) { page = .editor }
  }

  private func currentPane(_ workspace: PromptWorkspace) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if model.showsComparison,
        let comparison = model.comparison,
        comparison.kind != .history
      {
        HStack {
          Spacer()
          Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .draggable("prompt-pane-current")
            .help("左右拖动 System Prompt 正式稿")
          Spacer()
        }
      }
      HStack {
        Label(
          model.showsComparison && model.comparison?.kind == .history
            ? "待迭代版本"
            : model.showsComparison ? "System Prompt 正式稿" : "System Prompt",
          systemImage: "pencil.line"
        )
          .font(.headline)
          .foregroundStyle(.blue)
        Spacer()
        Button("新增维度") { model.addSection() }
        if model.showsComparison {
          Button {
            model.clearComparison()
          } label: {
            Image(systemName: "rectangle.compress.vertical")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("收起对照，返回单栏编辑")
        }
        Button {
          if model.deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.status = "请先配置 DeepSeek API Key"
            page = .settings
          } else {
            model.generatePrompt()
          }
        } label: {
          HStack(spacing: 7) {
            if model.isGeneratingPrompt {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "sparkles")
            }
            Text(model.isGeneratingPrompt ? "生成中…" : "AI 生成")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isGeneratingPrompt)
        Button {
          model.saveVersion()
        } label: {
          if let feedback = model.versionSaveFeedback {
            Label(feedback, systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else {
            Text("保存新版本")
          }
        }
        .disabled(model.versionSaveFeedback != nil)
      }

      VStack(spacing: 0) {
        HStack {
          Text("Markdown")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          Spacer()
          Button { model.copyFullPrompt() } label: {
            Image(systemName: "doc.on.doc")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("复制完整 Prompt")
        }
        .frame(height: 40)
        .padding(.horizontal, 8)
        .padding(.leading, 5)
        .background(Color(nsColor: .controlBackgroundColor))

        Divider()

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
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
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
      if model.comparison?.kind != .history {
        HStack {
          Spacer()
          Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .draggable("prompt-pane-comparison")
            .help("左右拖动 AI 生成 Prompt")
          Spacer()
        }
      }
      HStack {
        Label(
          model.comparison?.kind == .history ? model.comparisonTitle : "AI 参考稿",
          systemImage: model.comparison?.kind == .history
            ? "clock.arrow.circlepath" : "rectangle.split.2x1"
        )
          .font(.headline)
        Spacer()
      }
      if let comparison = model.comparison {
        VStack(spacing: 0) {
          HStack {
            Text("Markdown")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            Spacer()
            Button { model.copyComparisonPrompt() } label: {
              Image(systemName: "doc.on.doc")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制完整 AI 参考稿")
          }
          .frame(height: 40)
          .padding(.horizontal, 8)
          .padding(.leading, 5)
          .background(Color(nsColor: .controlBackgroundColor))

          Divider()

          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(comparison.sections) { section in
                comparisonSectionEditor(section)
                if section.id != comparison.sections.last?.id {
                  Divider().padding(.vertical, 6)
                }
              }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
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
    let isHovered = hoveredSectionID == section.id
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 0) {
        ZStack {
          Color.clear
          Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
        }
          .frame(width: isHovered ? 32 : 0, height: 32)
          .contentShape(Rectangle())
          .opacity(isHovered ? 1 : 0)
          .clipped()
          .draggable(section.id)
          .allowsHitTesting(isHovered)
          .help("上下拖动维度")
        Text("#")
          .font(.headline.monospaced())
          .foregroundStyle(.blue)
          .padding(.trailing, 10)
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
        HStack(spacing: 6) {
          Button {
            model.toggleSectionInclusion(section.id)
          } label: {
            Image(systemName: section.isIncluded ? "eye" : "eye.slash")
              .frame(width: 30, height: 30)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(section.isIncluded ? "从复制中隐藏" : "加入复制")
          Button(role: .destructive) {
            pendingDeletion = section
          } label: {
            Image(systemName: "trash")
              .frame(width: 30, height: 30)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("删除维度")
        }
        .padding(.leading, 8)
      }
      .frame(minHeight: 36)
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
      .padding(.leading, isHovered ? 32 : 0)
    }
    .padding(.vertical, 10)
    .opacity(section.isIncluded ? 1 : 0.48)
    .animation(.easeOut(duration: 0.14), value: isHovered)
    .onHover { hovering in
      if hovering {
        hoveredSectionID = section.id
      } else if hoveredSectionID == section.id {
        hoveredSectionID = nil
      }
    }
    .overlay(alignment: .top) {
      if sectionDropTargetID == section.id {
        Rectangle()
          .fill(Color.accentColor)
          .frame(height: 2)
      }
    }
    .dropDestination(for: String.self) { items, _ in
      guard let sourceID = items.first,
        model.workspace?.sections.contains(where: { $0.id == sourceID }) == true
      else { return false }
      model.moveSection(sourceID, to: section.id)
      sectionDropTargetID = nil
      return true
    } isTargeted: { isTargeted in
      if isTargeted {
        sectionDropTargetID = section.id
      } else if sectionDropTargetID == section.id {
        sectionDropTargetID = nil
      }
    }
  }

  private func comparisonSectionEditor(_ section: ComparisonSection) -> some View {
    let isIncluded = model.workspace?.sections.first(where: { $0.id == section.sectionID })?
      .isIncluded ?? true
    let mirrorsHover = hoveredSectionID == section.sectionID
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 0) {
        Color.clear.frame(width: mirrorsHover ? 32 : 0, height: 32)
        Text("#")
          .font(.headline.monospaced())
          .foregroundStyle(.blue)
          .padding(.trailing, 10)
        Text(section.title).font(.headline)
        Spacer()
      }
      .frame(minHeight: 36)
      Text(section.content.isEmpty ? "该栏目无内容" : section.content)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(section.content.isEmpty ? .secondary : .primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .padding(.leading, mirrorsHover ? 32 : 0)
    }
    .padding(.vertical, 10)
    .opacity(isIncluded ? 1 : 0.48)
    .animation(.easeOut(duration: 0.14), value: mirrorsHover)
    .overlay(alignment: .top) {
      if sectionDropTargetID == section.sectionID {
        Rectangle()
          .fill(Color.accentColor)
          .frame(height: 2)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 40))
      Text("工作台无法加载")
      Text(model.errorMessage ?? "请检查 Markdown 文件或本地版本数据。")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      Label(
        model.autosaveStatus,
        systemImage: model.autosaveStatus == "已自动保存"
          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
      )
      .foregroundStyle(model.autosaveStatus == "已自动保存" ? Color.green : Color.orange)
      Spacer()
      Text("Markdown 文件：\(model.documentURL?.path ?? "尚未选择")")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(.bar)
  }
}
