import AppKit
import PromptIterationCore
import Security
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
  @Published var selectedHistoryVersion: VersionSummary?
  @Published var selectedHistorySections: [PromptSection] = []
  @Published var currentOnLeading = true
  @Published var hasUnversionedChanges = false
  @Published var status = "就绪"
  @Published var errorMessage: String?
  @Published var deepSeekAPIKey = ""
  @Published var deepSeekBaseURL = "https://api.deepseek.com"
  @Published var deepSeekModel = "deepseek-chat"
  @Published var isTestingDeepSeek = false
  @Published var deepSeekConnectionSucceeded: Bool?
  @Published var deepSeekConnectionMessage = "尚未配置"

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
      status = "工作稿已从本地恢复"
    } catch {
      repository = nil
      errorMessage = error.localizedDescription
      status = "数据库打开失败"
    }

    deepSeekBaseURL = UserDefaults.standard.string(forKey: "deepseek.baseURL")
      ?? "https://api.deepseek.com"
    deepSeekModel = UserDefaults.standard.string(forKey: "deepseek.model")
      ?? "deepseek-chat"
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
      currentOnLeading = false
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
      try repository.saveComparison(projectID: workspace.id, snapshot: snapshot)
      comparison = snapshot
      currentOnLeading = false
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
      selectedHistoryVersion = version
      selectedHistorySections = workspace.sections
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
    guard !model.isEmpty else {
      deepSeekConnectionSucceeded = false
      deepSeekConnectionMessage = "请填写模型名称"
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

        isTestingDeepSeek = false
        deepSeekConnectionSucceeded = true
        deepSeekConnectionMessage = "连接成功，API Key 可以使用"
        status = "DeepSeek 连接测试成功"
      } catch {
        isTestingDeepSeek = false
        deepSeekConnectionSucceeded = false
        deepSeekConnectionMessage = "连接失败：\(error.localizedDescription)"
        status = deepSeekConnectionMessage
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

  private static func deepSeekErrorMessage(from data: Data) -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = object["error"] as? [String: Any],
      let message = error["message"] as? String
    else { return nil }
    return message
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

private enum DeepSeekConfigurationError: LocalizedError {
  case invalidResponse
  case requestFailed(statusCode: Int, message: String?)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "服务器返回了无法识别的响应"
    case let .requestFailed(statusCode, message):
      if let message, !message.isEmpty {
        return "HTTP \(statusCode)：\(message)"
      }
      return "HTTP \(statusCode)"
    }
  }
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

private enum WorkspacePage: String, CaseIterable, Identifiable {
  case editor = "编辑"
  case history = "历史版本"
  case settings = "设置"

  var id: Self { self }
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @State private var pendingDeletion: PromptSection?
  @State private var pendingHistoryEdit: VersionSummary?
  @State private var page: WorkspacePage = .editor
  @State private var versionSearch = ""
  @State private var hoveredSectionID: String?
  @State private var revealsDeepSeekAPIKey = false

  var body: some View {
    VStack(spacing: 0) {
      appNavigation
      Divider()
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

  private var appNavigation: some View {
    HStack {
      Label("Prompt 迭代助手", systemImage: "text.document")
        .font(.headline)
      Spacer()
      Picker("页面", selection: $page) {
        ForEach(WorkspacePage.allCases) { item in
          Text(item.rawValue).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 300)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var settingsPage: some View {
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
                if revealsDeepSeekAPIKey {
                  TextField("sk-…", text: $model.deepSeekAPIKey)
                    .textFieldStyle(.roundedBorder)
                } else {
                  SecureField("sk-…", text: $model.deepSeekAPIKey)
                    .textFieldStyle(.roundedBorder)
                }
                Button {
                  revealsDeepSeekAPIKey.toggle()
                } label: {
                  Image(systemName: revealsDeepSeekAPIKey ? "eye.slash" : "eye")
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(revealsDeepSeekAPIKey ? "隐藏 API Key" : "显示 API Key")
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
              TextField("deepseek-chat", text: $model.deepSeekModel)
                .textFieldStyle(.roundedBorder)
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

  @ViewBuilder
  private var editorPage: some View {
    editorHeader
    Divider()
    if let workspace = model.workspace {
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
    } else {
      emptyState
    }
  }

  private var editorHeader: some View {
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
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
              Text("历史版本").font(.title2.bold())
              Text("共 \(model.versions.count) 个不可变快照")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
          .padding(14)
          Divider()

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
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text("版本 V\(version.number)").font(.title2.bold())
            Text("\(version.note.isEmpty ? "无备注" : version.note)  \(compactDate(version.createdAt))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("编辑") {
            if model.hasUnversionedChanges {
              pendingHistoryEdit = version
            } else {
              openHistoryEditor(version)
            }
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(14)
        Divider()

        VStack(spacing: 0) {
          HStack {
            Text("Markdown")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            Spacer()
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
          .frame(height: 40)
          .padding(.horizontal, 8)
          .padding(.leading, 5)
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
      }
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
      if model.comparison?.kind != .history {
        HStack {
          Spacer()
          Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .draggable("prompt-pane-current")
            .help("左右拖动用户 Prompt")
          Spacer()
        }
      }
      HStack {
        Label(
          model.comparison?.kind == .history ? "待迭代版本" : "用户 Prompt",
          systemImage: "pencil.line"
        )
          .font(.headline)
          .foregroundStyle(.blue)
        Spacer()
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
          model.comparison?.kind == .history
            ? model.comparisonTitle : "AI 生成 Prompt（\(model.comparisonTitle)）",
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
            .help("复制完整候选")
          }
          .frame(height: 40)
          .padding(.horizontal, 8)
          .padding(.leading, 5)
          .background(Color(nsColor: .controlBackgroundColor))

          Divider()

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
      HStack(spacing: isHovered ? 8 : 0) {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.secondary)
          .frame(width: isHovered ? 16 : 0)
          .opacity(isHovered ? 1 : 0)
          .clipped()
          .contentShape(Rectangle())
          .draggable(section.id)
          .allowsHitTesting(isHovered)
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
    .animation(.easeOut(duration: 0.14), value: isHovered)
    .onHover { hovering in
      if hovering {
        hoveredSectionID = section.id
      } else if hoveredSectionID == section.id {
        hoveredSectionID = nil
      }
    }
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
