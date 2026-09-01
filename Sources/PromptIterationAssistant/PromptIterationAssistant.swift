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

private enum WorkspaceItemKind {
  case folder
  case document(Int)
  case version(Int)
}

private struct WorkspaceItem: Identifiable {
  let url: URL
  let kind: WorkspaceItemKind
  let children: [WorkspaceItem]?

  var id: String { url.standardizedFileURL.path }
  var isDirectory: Bool {
    if case .folder = kind { return true }
    return false
  }
}

struct AppRootView: View {
  private static let workspaceMarkerName = ".prompt-iteration-folder"
  @State private var model: AppModel?
  @State private var folderURL: URL?
  @State private var markdownFiles: [URL] = []
  @State private var workspaceItems: [WorkspaceItem] = []
  @State private var expandedFolderIDs: Set<String> = []
  @State private var launcherError: String?
  @State private var workspacePage: WorkspacePage = .editor
  @State private var showsSidebar = true
  @State private var pendingRenameURL: URL?
  @State private var renameText = ""
  @State private var pendingDocumentDeletion: URL?
  @State private var pendingVersionEdit: VersionSummary?

  var body: some View {
    Group {
      if let folderURL {
        HSplitView {
          if showsSidebar {
            folderSidebar(folderURL)
              .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
          }
          VStack(spacing: 0) {
            workspaceNavigation
            if let model {
              ContentView(
                model: model,
                page: $workspacePage,
                onRenamePrompt: renamePromptFolder
              )
            } else {
              VStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                  .font(.system(size: 40))
                  .foregroundStyle(.secondary)
                Text("这个文件夹里还没有 Markdown Prompt")
                  .font(.headline)
                Button("新建 Prompt") { createPromptFolder(in: folderURL) }
                  .buttonStyle(.borderedProminent)
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
          .ignoresSafeArea(.container, edges: .top)
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
      pendingRenameURL?.hasDirectoryPath == true ? "重命名文件夹" : "重命名文档",
      isPresented: Binding(
        get: { pendingRenameURL != nil },
        set: { if !$0 { pendingRenameURL = nil } }
      )
    ) {
      TextField(pendingRenameURL?.hasDirectoryPath == true ? "文件夹名称" : "文档名称", text: $renameText)
      Button("重命名") {
        if let pendingRenameURL {
          if pendingRenameURL.hasDirectoryPath {
            renameFolder(pendingRenameURL, to: renameText)
          } else {
            renameDocument(pendingRenameURL, to: renameText)
          }
        }
        pendingRenameURL = nil
      }
      Button("取消", role: .cancel) { pendingRenameURL = nil }
    } message: {
      Text(
        pendingRenameURL?.hasDirectoryPath == true
          ? "文件夹内的 Prompt 和历史版本会一起移动。"
          : "文件会继续保存为 Markdown 格式。"
      )
    }
    .confirmationDialog(
      pendingDocumentDeletion?.hasDirectoryPath == true
        ? "将项目“\(pendingDocumentDeletion?.lastPathComponent ?? "")”移到废纸篓？"
        : "将“\(pendingDocumentDeletion?.deletingPathExtension().lastPathComponent ?? "")”移到废纸篓？",
      isPresented: Binding(
        get: { pendingDocumentDeletion != nil },
        set: { if !$0 { pendingDocumentDeletion = nil } }
      )
    ) {
      Button("移到废纸篓", role: .destructive) {
        if let pendingDocumentDeletion { trashItem(pendingDocumentDeletion) }
        pendingDocumentDeletion = nil
      }
      Button("取消", role: .cancel) { pendingDocumentDeletion = nil }
    }
    .confirmationDialog(
      "从 V\(pendingVersionEdit?.number ?? 0) 开始编辑？",
      isPresented: Binding(
        get: { pendingVersionEdit != nil },
        set: { if !$0 { pendingVersionEdit = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("创建待迭代版本") {
        if let version = pendingVersionEdit,
          model?.startEditingHistory(version) == true
        {
          workspacePage = .editor
        }
        pendingVersionEdit = nil
      }
      Button("取消", role: .cancel) { pendingVersionEdit = nil }
    } message: {
      Text("当前工作稿会替换为这个历史版本，已保存的版本不受影响。")
    }
  }

  private var workspaceNavigation: some View {
    HStack(spacing: 12) {
      Button { showsSidebar.toggle() } label: {
        Image(systemName: "sidebar.leading")
          .font(.system(size: 18, weight: .semibold))
          .frame(width: 36, height: 36)
          .background(Color(nsColor: .controlBackgroundColor), in: Circle())
          .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(showsSidebar ? "收起文件列表" : "展开文件列表")

      if workspacePage == .settings {
        Button { workspacePage = .editor } label: {
          Image(systemName: "chevron.left")
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 36, height: 36)
            .background(Color(nsColor: .controlBackgroundColor), in: Circle())
            .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("返回编辑页")
      }

      Spacer()
      Button {
        workspacePage = workspacePage == .settings ? .editor : .settings
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 18, weight: .semibold))
          .frame(width: 36, height: 36)
          .background(Color(nsColor: .controlBackgroundColor), in: Circle())
          .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(workspacePage == .settings ? "关闭设置" : "设置")
    }
    .padding(.leading, showsSidebar ? 10 : 94)
    .padding(.trailing, 10)
    .frame(height: 28)
  }

  private var launchPage: some View {
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
          detail: "创建 Prompt 文件夹和 System Prompt.md",
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
        Image(systemName: "folder.fill").foregroundStyle(.blue)
        Text(folderURL.lastPathComponent)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Button { createPromptFolder(in: folderURL) } label: {
          Image(systemName: "plus")
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("新建 Prompt 文件夹")
      }
      .padding(.leading, 12)
      .padding(.trailing, 8)
      .padding(.vertical, 12)
      Divider()

      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(workspaceItems) { folder in
            VStack(spacing: 2) {
              HStack(spacing: 2) {
                Button {
                  if expandedFolderIDs.contains(folder.id) {
                    expandedFolderIDs.remove(folder.id)
                  } else {
                    expandedFolderIDs.insert(folder.id)
                  }
                } label: {
                  HStack(spacing: 8) {
                    Image(
                      systemName: expandedFolderIDs.contains(folder.id)
                        ? "chevron.down" : "chevron.right"
                    )
                    .font(.caption.bold())
                    .frame(width: 12)
                    Image(systemName: "folder")
                    Text(folder.url.lastPathComponent)
                      .lineLimit(1)
                    Spacer()
                  }
                  .padding(.leading, 6)
                  .padding(.vertical, 7)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Menu {
                  Button("重命名", systemImage: "pencil") { beginRenaming(folder.url) }
                  Button("添加子文件", systemImage: "doc.badge.plus") {
                    createPromptDocument(in: folder.url)
                  }
                  Button("在访达中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                  }
                  Divider()
                  Button("删除项目", systemImage: "trash", role: .destructive) {
                    pendingDocumentDeletion = folder.url
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

              if expandedFolderIDs.contains(folder.id) {
                ForEach(folder.children ?? []) { child in
                  workspaceItemRow(child)
                    .padding(.leading, 22)
                }
              }
            }
          }
        }
        .padding(8)
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  @ViewBuilder
  private func workspaceItemRow(_ item: WorkspaceItem) -> some View {
    if item.isDirectory {
      Label(item.url.lastPathComponent, systemImage: "folder")
        .lineLimit(1)
        .padding(.vertical, 6)
    } else if case let .version(number) = item.kind {
      HStack(spacing: 4) {
        Button {
          openHistoryVersion(number, in: item.url.deletingLastPathComponent())
        } label: {
          HStack(spacing: 8) {
            Text("V\(number)")
              .font(.caption.bold().monospacedDigit())
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .foregroundStyle(.blue)
              .background(Color.blue.opacity(0.14), in: Capsule())
            Text(item.url.deletingLastPathComponent().lastPathComponent)
              .lineLimit(1)
            Spacer()
          }
          .padding(.leading, 8)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Menu {
          Button("保存新版本", systemImage: "doc.badge.plus") {
            saveNewVersion(for: item.url)
          }
          Button("加入对比", systemImage: "rectangle.split.2x1") {
            compareHistoryVersion(number, in: item.url.deletingLastPathComponent())
          }
          Button("基于此版本编辑", systemImage: "square.and.pencil") {
            editHistoryVersion(number, in: item.url.deletingLastPathComponent())
          }
          Button("复制版本", systemImage: "doc.on.doc") {
            copyHistoryVersion(number, in: item.url.deletingLastPathComponent())
          }
          Divider()
          Button("在 Finder 中显示", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
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
      .background(
        workspacePage == .history
          && model?.documentURL?.deletingLastPathComponent().standardizedFileURL
            == item.url.deletingLastPathComponent().standardizedFileURL
          && model?.selectedHistoryVersion?.number == number
          ? Color.blue.opacity(0.12) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7)
      )
    } else if case let .document(number) = item.kind {
      HStack(spacing: 4) {
        Button {
          openDocument(item.url)
          workspacePage = .editor
        } label: {
          HStack(spacing: 8) {
            Text("V\(number)")
              .font(.caption.bold().monospacedDigit())
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .foregroundStyle(.blue)
              .background(Color.blue.opacity(0.14), in: Capsule())
            Text(item.url.deletingLastPathComponent().lastPathComponent)
              .lineLimit(1)
            Spacer()
          }
          .padding(.leading, 8)
          .padding(.vertical, 7)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Menu {
          Button("加入对比", systemImage: "rectangle.split.2x1") {
            compareLatestVersion(in: item.url.deletingLastPathComponent())
          }
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
      openWorkspace(url.deletingLastPathComponent(), selecting: promptURL)
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func openFolder() {
    let panel = NSOpenPanel()
    panel.title = "打开 Prompt 文件夹或 Markdown 文件"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.folder, UTType(filenameExtension: "md")!]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    if isDirectory.boolValue {
      openWorkspace(url)
      return
    }

    let promptFolder = url.deletingLastPathComponent()
    let workspaceRoot = (try? isPromptFolder(promptFolder)) == true
      ? promptFolder.deletingLastPathComponent() : promptFolder
    if let number = versionNumber(from: url) {
      openWorkspace(workspaceRoot)
      openHistoryVersion(number, in: promptFolder)
    } else {
      openWorkspace(workspaceRoot, selecting: url)
    }
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
      let promptURL = uniquePromptURL(in: url)
      try writeDefaultPrompt(to: promptURL)
      refreshFiles(in: folderURL)
      openDocument(promptURL)
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func createPromptDocument(in promptFolderURL: URL) {
    do {
      let promptURL = uniquePromptURL(in: promptFolderURL)
      try writeDefaultPrompt(to: promptURL)
      if let folderURL { refreshFiles(in: folderURL) }
      openDocument(promptURL)
      workspacePage = .editor
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func renamePromptFolder(to enteredName: String) {
    guard let documentURL = model?.documentURL else { return }
    renameFolder(documentURL.deletingLastPathComponent(), to: enteredName)
  }

  private func renameFolder(_ source: URL, to enteredName: String) {
    let name = enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      launcherError = "请输入有效的 Prompt 名称"
      return
    }

    guard source.lastPathComponent != name else { return }
    let destination = source.deletingLastPathComponent().appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      launcherError = "同名 Prompt 已经存在"
      return
    }

    let selectedDocument = model?.documentURL
    let isSelectedFolder = selectedDocument?.deletingLastPathComponent().standardizedFileURL
      == source.standardizedFileURL
    if isSelectedFolder { model = nil }
    do {
      try FileManager.default.moveItem(at: source, to: destination)
      expandedFolderIDs.remove(source.standardizedFileURL.path)
      expandedFolderIDs.insert(destination.standardizedFileURL.path)
      if let folderURL { refreshFiles(in: folderURL) }
      if isSelectedFolder, let selectedDocument {
        openDocument(destination.appendingPathComponent(selectedDocument.lastPathComponent))
      }
    } catch {
      launcherError = error.localizedDescription
      if isSelectedFolder, let selectedDocument,
        FileManager.default.fileExists(atPath: selectedDocument.path)
      {
        openDocument(selectedDocument)
      }
    }
  }

  private func openWorkspace(_ url: URL, selecting selected: URL? = nil) {
    if selected == nil, (try? isPromptFolder(url)) == true,
      let files = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ),
      let promptURL = files.first(where: {
        versionNumber(from: $0) == nil && isPromptDocument($0)
      })
    {
      openWorkspace(url.deletingLastPathComponent(), selecting: promptURL)
      return
    }
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
    expandedFolderIDs.insert(url.deletingLastPathComponent().standardizedFileURL.path)
    model = AppModel(documentURL: url)
    if let folderURL { refreshFiles(in: folderURL) }
  }

  private func openHistoryVersion(_ number: Int, in promptFolder: URL) {
    do {
      let promptURL = try FileManager.default.contentsOfDirectory(
        at: promptFolder,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ).first { versionNumber(from: $0) == nil && isPromptDocument($0) }
      guard let promptURL else {
        launcherError = "这个 Prompt 文件夹里没有可编辑的工作稿"
        return
      }
      if model?.documentURL?.standardizedFileURL != promptURL.standardizedFileURL {
        openDocument(promptURL)
      }
      guard let version = model?.versions.first(where: { $0.number == number }) else {
        launcherError = "找不到历史版本 V\(number)"
        return
      }
      model?.selectHistory(version)
      workspacePage = .history
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func copyHistoryVersion(_ number: Int, in promptFolder: URL) {
    openHistoryVersion(number, in: promptFolder)
    model?.copySelectedHistory()
  }

  private func editHistoryVersion(_ number: Int, in promptFolder: URL) {
    openHistoryVersion(number, in: promptFolder)
    guard let version = model?.selectedHistoryVersion else { return }
    if model?.hasUnversionedChanges == true {
      pendingVersionEdit = version
    } else if model?.startEditingHistory(version) == true {
      workspacePage = .editor
    }
  }

  private func compareHistoryVersion(_ number: Int, in promptFolder: URL) {
    openHistoryVersion(number, in: promptFolder)
    guard let version = model?.selectedHistoryVersion else { return }
    model?.loadHistory(version)
    workspacePage = .editor
  }

  private func compareLatestVersion(in promptFolder: URL) {
    do {
      let numbers = try FileManager.default.contentsOfDirectory(
        at: promptFolder,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ).compactMap(versionNumber).sorted(by: >)
      guard numbers.count > 1 else {
        launcherError = "至少保存两个版本后才能对比"
        return
      }
      compareHistoryVersion(numbers[1], in: promptFolder)
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func saveNewVersion(for documentURL: URL) {
    if model?.documentURL?.standardizedFileURL != documentURL.standardizedFileURL {
      openDocument(documentURL)
    }
    if model?.saveVersion() == true, let folderURL { refreshFiles(in: folderURL) }
  }

  private func beginRenaming(_ url: URL) {
    renameText = url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
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

  private func trashItem(_ url: URL) {
    let selectedDocument = model?.documentURL
    let selectedPath = selectedDocument?.standardizedFileURL.path
    let targetPath = url.standardizedFileURL.path
    let wasSelected = selectedPath == targetPath || selectedPath?.hasPrefix(targetPath + "/") == true
    if wasSelected { model = nil }
    do {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      if let folderURL {
        refreshFiles(in: folderURL)
        if wasSelected, let next = markdownFiles.first { openDocument(next) }
      }
    } catch {
      launcherError = error.localizedDescription
      if wasSelected, let selectedDocument { openDocument(selectedDocument) }
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
      workspaceItems = try loadWorkspaceItems(in: folderURL, isRoot: true)
      markdownFiles = flattenedMarkdownFiles(in: workspaceItems)
    } catch {
      launcherError = error.localizedDescription
      workspaceItems = []
      markdownFiles = []
    }
  }

  private func loadWorkspaceItems(in folderURL: URL, isRoot: Bool) throws -> [WorkspaceItem] {
    try FileManager.default.contentsOfDirectory(
      at: folderURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )
    .compactMap { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isDirectory == true, values.isSymbolicLink != true {
        guard try isPromptFolder(url) else { return nil }
        let children = try loadWorkspaceItems(in: url, isRoot: false)
        let latestVersion = children.compactMap { child in
          if case let .version(number) = child.kind { return number }
          return nil
        }.max() ?? 1
        return WorkspaceItem(
          url: url,
          kind: .folder,
          children: children.compactMap { child in
            switch child.kind {
            case .document:
              return WorkspaceItem(
                url: child.url,
                kind: .document(latestVersion),
                children: nil
              )
            case let .version(number) where number == latestVersion:
              return nil
            default:
              return child
            }
          }
        )
      }
      guard !isRoot, isPromptDocument(url) else { return nil }
      return WorkspaceItem(
        url: url,
        kind: versionNumber(from: url).map(WorkspaceItemKind.version) ?? .document(0),
        children: nil
      )
    }
    .sorted {
      if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
      switch ($0.kind, $1.kind) {
      case (.document, .version): return true
      case (.version, .document): return false
      case let (.version(lhs), .version(rhs)): return lhs > rhs
      default: break
      }
      return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent)
        == .orderedAscending
    }
  }

  private func flattenedMarkdownFiles(in items: [WorkspaceItem]) -> [URL] {
    items.flatMap { item in
      if let children = item.children { return flattenedMarkdownFiles(in: children) }
      if case .document = item.kind { return [item.url] }
      return []
    }
  }

  private func versionNumber(from url: URL) -> Int? {
    let name = url.deletingPathExtension().lastPathComponent
    guard name.first == "V", let number = Int(name.dropFirst()) else { return nil }
    return number
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
    databaseURL = Self.databaseURL(for: self.documentURL)
    do {
      try Self.migrateLegacyDatabaseIfNeeded(
        documentURL: self.documentURL,
        destination: databaseURL
      )
      let repository = try WorkspaceRepository(databaseURL: databaseURL)
      self.repository = repository
      var workspace = try repository.loadOrCreateWorkspace()
      if let documentURL = self.documentURL {
        let markdown = try String(contentsOf: documentURL, encoding: .utf8)
        workspace.name = documentURL.deletingLastPathComponent().lastPathComponent
        workspace.sections = Self.preserveSectionIDs(
          parsed: PromptMarkdown.parse(markdown),
          existing: workspace.sections
        )
        try repository.saveDraft(workspace)
      }
      self.workspace = workspace
      comparison = try repository.loadComparison(projectID: workspace.id)
      versions = try repository.listVersions(projectID: workspace.id)
      if let documentURL = self.documentURL {
        for version in versions {
          try Self.writeVersionSnapshot(
            try repository.versionSections(projectID: workspace.id, number: version.number),
            number: version.number,
            beside: documentURL,
            overwrite: false
          )
        }
      }
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

  @discardableResult
  func saveVersion() -> Bool {
    guard var workspace, let repository else { return false }
    do {
      try repository.saveDraft(workspace)
      let nextNumber = (versions.map(\.number).max() ?? 0) + 1
      if let documentURL {
        try Self.writeVersionSnapshot(
          workspace.sections,
          number: nextNumber,
          beside: documentURL,
          overwrite: true
        )
      }
      let version: VersionSummary
      do {
        version = try repository.saveVersion(workspace: workspace, note: "手动保存")
      } catch {
        if let documentURL {
          try? FileManager.default.removeItem(
            at: Self.versionFileURL(number: nextNumber, beside: documentURL)
          )
        }
        throw error
      }
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
      return true
    } catch {
      report(error)
      return false
    }
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

  private static func versionFileURL(number: Int, beside documentURL: URL) -> URL {
    documentURL.deletingLastPathComponent().appendingPathComponent("V\(number).md")
  }

  private static func writeVersionSnapshot(
    _ sections: [PromptSection],
    number: Int,
    beside documentURL: URL,
    overwrite: Bool
  ) throws {
    let url = versionFileURL(number: number, beside: documentURL)
    if !overwrite, FileManager.default.fileExists(atPath: url.path) { return }
    try PromptMarkdown.renderAll(sections).write(to: url, atomically: true, encoding: .utf8)
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
      return documentURL.deletingLastPathComponent()
        .appendingPathComponent(".prompt-history", isDirectory: true)
        .appendingPathComponent("workspace.db")
    }
    return WorkspaceRepository.defaultDatabaseURL()
  }

  private static func migrateLegacyDatabaseIfNeeded(
    documentURL: URL?,
    destination: URL
  ) throws {
    guard
      let documentURL,
      ProcessInfo.processInfo.arguments.firstIndex(of: "--db") == nil,
      ProcessInfo.processInfo.environment["PROMPT_ITERATION_DB"]?.isEmpty != false,
      !FileManager.default.fileExists(atPath: destination.path)
    else { return }

    let digest = SHA256.hash(data: Data(documentURL.standardizedFileURL.path.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser
    let legacy = support
      .appendingPathComponent("Prompt Iteration Assistant", isDirectory: true)
      .appendingPathComponent("Workspaces", isDirectory: true)
      .appendingPathComponent("\(digest).db")
    guard FileManager.default.fileExists(atPath: legacy.path) else { return }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: legacy, to: destination)
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

enum WorkspacePage {
  case editor
  case history
  case settings
}

private struct DeepSeekSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var revealsAPIKey = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
          Text("DeepSeek")
            .font(.title2.bold())
          Text("配置 API 后，即可在编辑页直接生成 Prompt。")
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 20)

        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 18) {
          GridRow {
            VStack(alignment: .leading, spacing: 3) {
              Text("API Key")
              Text("仅保存在本机 Keychain")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
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

          Divider().gridCellColumns(2)

          GridRow {
            VStack(alignment: .leading, spacing: 3) {
              Text("模型")
              Text("点击切换生成模型")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            Picker(
              "模型",
              selection: Binding(
                get: { model.deepSeekModel },
                set: model.selectDeepSeekModel
              )
            ) {
              Text("V4 Flash").tag("deepseek-v4-flash")
              Text("V4 Pro").tag("deepseek-v4-pro")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
          }

          Divider().gridCellColumns(2)

          GridRow {
            VStack(alignment: .leading, spacing: 3) {
              Text("接口地址")
              Text("默认使用 DeepSeek 官方地址")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            TextField("https://api.deepseek.com", text: $model.deepSeekBaseURL)
              .textFieldStyle(.roundedBorder)
          }
        }

        Divider().padding(.vertical, 20)

        HStack(spacing: 10) {
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
            .font(.callout)
            .lineLimit(1)
          if model.isTestingDeepSeek {
            ProgressView().controlSize(.small)
          }
          Spacer()
          Button("测试连接") { model.testDeepSeekConnection() }
            .disabled(model.isTestingDeepSeek)
          Button("保存") { model.saveDeepSeekSettings() }
            .buttonStyle(.borderedProminent)
        }

        Text("连接测试只验证密钥和模型是否可用，不会上传 Prompt。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 10)
      }
      .frame(maxWidth: 700, alignment: .leading)
      .padding(.horizontal, 28)
      .padding(.vertical, 20)
      .frame(maxWidth: .infinity, alignment: .top)
    }
  }
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @Binding var page: WorkspacePage
  let onRenamePrompt: (String) -> Void
  @State private var pendingDeletion: PromptSection?
  @State private var promptName = ""
  @State private var hoveredSectionID: String?
  @State private var sectionDropTargetID: String?

  private var promptNameFieldWidth: CGFloat {
    let displayedName = promptName.isEmpty ? "Prompt 名称" : promptName
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    let width = (displayedName as NSString).size(withAttributes: [.font: font]).width
    return min(max(width + 8, 72), 240)
  }

  var body: some View {
    VStack(spacing: 0) {
      if page == .editor {
        editorPage
      } else if page == .history {
        historyDetail
      } else {
        settingsPage
      }
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

      VStack(spacing: 0) {
        HStack(spacing: 6) {
          TextField("Prompt 名称", text: $promptName) { editing in
            if !editing { onRenamePrompt(promptName) }
          }
          .textFieldStyle(.plain)
          .font(.headline)
          .foregroundStyle(.blue)
          .frame(width: promptNameFieldWidth, alignment: .leading)
          .onAppear { promptName = workspace.name }
          .onChange(of: model.documentURL) { _ in
            promptName = model.workspace?.name ?? ""
          }
          .onSubmit { onRenamePrompt(promptName) }

          if model.showsComparison, model.comparison?.kind == .history {
            Text("V\(max(workspace.currentVersion, 1))")
              .font(.headline.monospacedDigit())
            Button {
              model.clearComparison()
              page = .history
            } label: {
              Image(systemName: "xmark")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭当前版本")
          }
          Spacer()
          Button {
            if model.deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              model.status = "请先配置 DeepSeek API Key"
              page = .settings
            } else {
              model.generatePrompt()
            }
          } label: {
            Image(systemName: model.isGeneratingPrompt ? "hourglass" : "sparkles")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(model.isGeneratingPrompt)
          .help(model.isGeneratingPrompt ? "生成中" : "AI 生成")

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
            Button("新增维度") { model.addSection() }
              .buttonStyle(.plain)
              .foregroundStyle(.blue)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 10)
              .padding(.vertical, 12)
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
          .stroke(Color.blue, lineWidth: 2)
      }
    }
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
      if let comparison = model.comparison {
        VStack(spacing: 0) {
          HStack(spacing: 6) {
            Text(
              comparison.kind == .history
                ? "\(model.workspace?.name ?? "System") V\(comparison.sourceVersion ?? 1)"
                : "AI 参考稿"
            )
            .font(.headline)
            Button {
              model.clearComparison()
              page = .editor
            } label: {
              Image(systemName: "xmark")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭对比版本")
            Spacer()
            Button { model.copyComparisonPrompt() } label: {
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

}
