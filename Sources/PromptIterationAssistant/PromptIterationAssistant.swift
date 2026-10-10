import AppKit
import CryptoKit
import PromptIterationCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct PromptIterationAssistantApp: App {
  var body: some Scene {
    WindowGroup {
      AppRootView()
        .frame(minWidth: 1_080, minHeight: 700)
    }
    .windowStyle(.hiddenTitleBar)
    .windowToolbarStyle(.unified)
  }
}

private enum WorkspaceItemKind {
  case folder
  case document
  case version(Int)
}

private struct WorkspaceItem: Identifiable {
  let url: URL
  let kind: WorkspaceItemKind
  let children: [WorkspaceItem]?
  var ownerDocument: URL? = nil
  var customName: String? = nil
  var updatedAt: Date? = nil

  var displayName: String { customName ?? (ownerDocument ?? url).deletingPathExtension().lastPathComponent }

  var orderKey: String {
    if case let .version(number) = kind, let ownerDocument {
      return ownerDocument.lastPathComponent + "/V\(number).md"
    }
    return url.lastPathComponent
  }

  var id: String { url.standardizedFileURL.path }
  var isDirectory: Bool {
    if case .folder = kind { return true }
    return false
  }
}

private func formattedPromptTime(_ date: Date) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "zh_CN")
  formatter.dateFormat = "yyyy-MM-dd HH:mm"
  return formatter.string(from: date)
}

private struct WorkspaceDocumentLabel: View {
  let item: WorkspaceItem
  @ObservedObject var model: AppModel

  private var versionLabel: String {
    if case let .version(number) = item.kind { return "V\(number)" }
    return "工作稿"
  }

  private var date: Date? {
    guard model.documentURL?.standardizedFileURL == (item.ownerDocument ?? item.url).standardizedFileURL else {
      return item.updatedAt
    }
    if case let .version(number) = item.kind { return model.editedAt(forVersion: number) ?? item.updatedAt }
    return model.savedDraftEditedAt
  }

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Text(versionLabel)
        .font(.caption.bold().monospacedDigit())
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(versionLabel == "工作稿" ? Color.blue : Color.primary)
        .background(versionLabel == "工作稿" ? Color.blue.opacity(0.14) : Color.primary.opacity(0.06), in: Capsule())
        .fixedSize()
      VStack(alignment: .leading, spacing: 3) {
        Text(item.displayName).lineLimit(1)
        if let date {
          Text(formattedPromptTime(date))
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        } else if case .document = item.kind {
          Text("未保存")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct WorkspaceDropTarget: Equatable {
  let parent: URL
  let before: String?
  let rowID: String
  let edge: Edge?
}

private struct WorkspaceDropFrames: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

struct AppRootView: View {
  private static let workspaceMarkerName = ".prompt-iteration-folder"
  @Environment(\.colorScheme) private var colorScheme
  @State private var model: AppModel?
  @State private var folderURL: URL?
  @State private var markdownFiles: [URL] = []
  @State private var workspaceItems: [WorkspaceItem] = []
  @State private var expandedFolderIDs: Set<String> = []
  @State private var launcherError: String?
  @State private var workspacePage: WorkspacePage = .generation
  @State private var pageBeforeSettings: WorkspacePage = .generation
  @State private var showsSidebar = true
  @State private var pendingNewFolderParent: URL?
  @State private var newFolderName = ""
  @State private var draggedItemID: String?
  @State private var workspaceDropTarget: WorkspaceDropTarget?
  @State private var workspaceDropFrames: [String: CGRect] = [:]
  @State private var workspaceDragLocation: CGPoint?
  @GestureState private var workspaceGestureActive = false
  @State private var pendingRenameVersion: (number: Int, documentURL: URL)?
  @State private var pendingRenameURL: URL?
  @State private var renameText = ""
  @State private var pendingDocumentDeletion: URL?
  @State private var pendingVersionDeletion: (number: Int, documentURL: URL)?
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
            workspaceHeader
            if let model {
              ContentView(
                model: model,
                page: $workspacePage,
                onRenamePrompt: renameCurrentPrompt,
                onSaveGeneratedPrompt: saveGeneratedPrompt,
                onVersionsChanged: { refreshFiles(in: folderURL) },
                onOpenSettings: {
                  pageBeforeSettings = workspacePage
                  workspacePage = .settings
                }
              )
              .id(ObjectIdentifier(model))
              .clipped()
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
      "新建子文件夹",
      isPresented: Binding(
        get: { pendingNewFolderParent != nil },
        set: { if !$0 { pendingNewFolderParent = nil } }
      )
    ) {
      TextField("文件夹名称", text: $newFolderName)
      Button("创建") {
        if let parent = pendingNewFolderParent { createSubfolder(in: parent) }
        pendingNewFolderParent = nil
      }
      Button("取消", role: .cancel) { pendingNewFolderParent = nil }
    } message: {
      Text("在“\(pendingNewFolderParent?.lastPathComponent ?? "")”中新建文件夹。")
    }
    .alert(
      pendingRenameURL?.hasDirectoryPath == true ? "重命名文件夹" : "重命名文档",
      isPresented: Binding(
        get: { pendingRenameURL != nil },
        set: { if !$0 { pendingRenameURL = nil; pendingRenameVersion = nil } }
      )
    ) {
      TextField(pendingRenameURL?.hasDirectoryPath == true ? "文件夹名称" : "文档名称", text: $renameText)
      Button("重命名") {
        if let pendingRenameURL {
          if let version = pendingRenameVersion {
            do {
              try PromptDocumentStorage.renameVersion(version.number, for: version.documentURL, to: renameText)
              if let folderURL { refreshFiles(in: folderURL) }
            } catch { launcherError = error.localizedDescription }
          } else if pendingRenameURL.hasDirectoryPath {
            renameFolder(pendingRenameURL, to: renameText)
          } else {
            renameDocument(pendingRenameURL, to: renameText)
          }
        }
        pendingRenameURL = nil
        pendingRenameVersion = nil
      }
      Button("取消", role: .cancel) { pendingRenameURL = nil; pendingRenameVersion = nil }
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
      if let deletionURL = pendingDocumentDeletion {
        Button("移到废纸篓", role: .destructive) {
          pendingDocumentDeletion = nil
          trashItem(deletionURL)
        }
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
    .confirmationDialog(
      "删除 V\(pendingVersionDeletion?.number ?? 0)？",
      isPresented: Binding(
        get: { pendingVersionDeletion != nil },
        set: { if !$0 { pendingVersionDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("删除版本", role: .destructive) {
        if let pendingVersionDeletion {
          deleteHistoryVersion(
            pendingVersionDeletion.number,
            in: pendingVersionDeletion.documentURL
          )
        }
        pendingVersionDeletion = nil
      }
      Button("取消", role: .cancel) { pendingVersionDeletion = nil }
    } message: {
      Text("该历史版本会移到废纸篓，当前工作稿不受影响。")
    }
    .onDisappear {
      model?.cancelPromptGeneration()
      model?.cancelOutputComparison()
    }
  }

  private var workspaceHeader: some View {
    ZStack {
      HStack(spacing: 6) {
        workspaceTab("生成 Prompt", selected: workspacePage == .generation) { workspacePage = .generation }
        workspaceTab("迭代管理", selected: workspacePage == .editor || workspacePage == .history) {
          workspacePage = .editor
        }
      }

      HStack {
        HStack(spacing: 10) {
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

        }
        // Leave room for macOS window controls when the sidebar is hidden.
        .padding(.leading, showsSidebar ? 0 : 80)
        Spacer()
        Button {
          if workspacePage == .settings {
            workspacePage = pageBeforeSettings
          } else {
            pageBeforeSettings = workspacePage
            workspacePage = .settings
          }
        } label: {
          Image(systemName: workspacePage == .settings ? "xmark" : "gearshape")
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 36, height: 36)
            .background(Color(nsColor: .controlBackgroundColor), in: Circle())
            .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(workspacePage == .settings ? "关闭设置" : "设置")
        .accessibilityLabel(workspacePage == .settings ? "关闭设置" : "设置")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Color(nsColor: .textBackgroundColor))
  }

  private func workspaceTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.callout.weight(selected ? .semibold : .regular))
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(selected ? "已选中" : "未选中")
  }

  private var launchPage: some View {
    VStack(alignment: .leading, spacing: 52) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Prompt Studio")
          .font(.system(size: 42, weight: .bold))
        Text("选择一个本地 Markdown 工作区开始编写 System Prompt")
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
      }

      HStack(alignment: .top, spacing: 16) {
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
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: 720)
    .padding(.horizontal, 48)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func launchAction(
    _ title: String,
    detail: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
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
      .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
  }

  private struct VisibleWorkspaceRow: Identifiable {
    let item: WorkspaceItem
    let depth: Int
    var endOfFolder: URL? = nil
    var id: String { endOfFolder.map { "end:" + $0.path } ?? item.id }
  }

  private func visibleRows(in items: [WorkspaceItem], depth: Int = 0) -> [VisibleWorkspaceRow] {
    items.flatMap { item in
      [VisibleWorkspaceRow(item: item, depth: depth)]
        + (expandedFolderIDs.contains(item.id)
          ? visibleRows(in: item.children ?? [], depth: depth + 1)
            + [VisibleWorkspaceRow(item: item, depth: depth + 1, endOfFolder: item.url)] : [])
    }
  }

  private func folderSidebar(_ folderURL: URL) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "folder.fill").foregroundStyle(.blue)
        Text(folderURL.lastPathComponent)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Menu {
          Button("新建 Prompt", systemImage: "doc.badge.plus") { createPromptFolder(in: folderURL) }
          Button("新建文件夹", systemImage: "folder.badge.plus") { beginCreatingSubfolder(in: folderURL) }
        } label: {
          Image(systemName: "plus")
            .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      .padding(.leading, 12)
      .padding(.trailing, 8)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
      .background(workspaceDropTarget?.rowID == "root" ? Color.accentColor.opacity(0.15) : .clear)
      .background(dropFrame("root"))
      Divider()

      GeometryReader { geometry in
        ScrollViewReader { scrollProxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(visibleRows(in: workspaceItems)) { row in
                if row.endOfFolder != nil {
                  workspaceEndDropRow(id: row.id)
                    .background(dropFrame(row.id))
                    .padding(.leading, CGFloat(row.depth) * 18)
                } else {
                  Group {
                    if row.item.isDirectory { workspaceFolderRow(row.item) }
                    else { workspaceItemRow(row.item) }
                  }
                  .frame(height: row.item.isDirectory ? 38 : 54)
                  .contentShape(Rectangle())
                  .background(workspaceDropTarget?.rowID == row.id && workspaceDropTarget?.edge == nil
                    ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                  .overlay(alignment: .top) { insertionLine(row.id, edge: .top) }
                  .overlay(alignment: .bottom) { insertionLine(row.id, edge: .bottom) }
                  .opacity(draggedItemID == row.id ? 0.5 : 1)
                  .background(dropFrame(row.id))
                  .highPriorityGesture(workspaceDragGesture(for: row.item))
                  .padding(.leading, CGFloat(row.depth) * 18)
                }
              }
              workspaceEndDropRow(id: "root-end")
                .frame(maxHeight: .infinity, alignment: .top)
                .background(dropFrame("root-end"))
            }
            .padding(8)
            .frame(minHeight: max(0, geometry.size.height - 16), alignment: .top)
          }
          .background(dropFrame("viewport"))
          .task(id: workspaceGestureActive) {
            guard workspaceGestureActive else { return }
            while !Task.isCancelled {
              try? await Task.sleep(nanoseconds: 180_000_000)
              guard !Task.isCancelled else { return }
              scrollWorkspaceDuringDrag(scrollProxy)
            }
          }
        }
      }
    }
    .background(
      (colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(white: 0.96))
        .ignoresSafeArea(.container, edges: .vertical)
    )
    .coordinateSpace(name: "workspaceSidebar")
    .onPreferenceChange(WorkspaceDropFrames.self) { frames in
      workspaceDropFrames = frames
      if let location = workspaceDragLocation { workspaceDropTarget = target(at: location) }
    }
    .onChange(of: workspaceGestureActive) { active in
      if !active { draggedItemID = nil; workspaceDragLocation = nil; workspaceDropTarget = nil }
    }
  }

  private func workspaceFolderRow(_ folder: WorkspaceItem) -> some View {
    HStack(spacing: 2) {
      Button {
        if expandedFolderIDs.contains(folder.id) {
          expandedFolderIDs.remove(folder.id)
        } else {
          expandedFolderIDs.insert(folder.id)
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: expandedFolderIDs.contains(folder.id) ? "chevron.down" : "chevron.right")
            .font(.caption.bold())
            .frame(width: 12)
          Image(systemName: "folder")
          Text(folder.url.lastPathComponent).lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity)
      Menu {
        folderMenuActions(folder)
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .contentShape(Rectangle())
    .contextMenu { folderMenuActions(folder) }
  }

  @ViewBuilder
  private func folderMenuActions(_ folder: WorkspaceItem) -> some View {
    Button("新建子文件夹", systemImage: "folder.badge.plus") { beginCreatingSubfolder(in: folder.url) }
    Button("新建 Prompt", systemImage: "doc.badge.plus") { createPromptFolder(in: folder.url) }
    Divider()
    Button("重命名", systemImage: "pencil") { beginRenaming(folder.url) }
    if folder.children?.contains(where: { if case .document = $0.kind { return true }; return false }) == true {
      Button("创建新版本", systemImage: "doc.badge.plus") { saveNewVersion(in: folder.url) }
    }
    Button("在访达中显示", systemImage: "folder") {
      NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }
    Divider()
    Button("删除文件夹", systemImage: "trash", role: .destructive) { pendingDocumentDeletion = folder.url }
  }

  @ViewBuilder
  private func insertionLine(_ id: String, edge: Edge) -> some View {
    if workspaceDropTarget?.rowID == id, workspaceDropTarget?.edge == edge {
      Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
    }
  }

  private func workspaceEndDropRow(id: String) -> some View {
    Color.clear
      .frame(maxWidth: .infinity, minHeight: id == "root-end" ? 44 : 10)
      .overlay(alignment: .top) {
        if workspaceDropTarget?.rowID == id {
          Rectangle().fill(Color.accentColor).frame(height: 2)
        }
      }
      .contentShape(Rectangle())
      .accessibilityHidden(true)
  }

  private func dropFrame(_ id: String) -> some View {
    GeometryReader { geometry in
      Color.clear.preference(key: WorkspaceDropFrames.self,
        value: [id: geometry.frame(in: .named("workspaceSidebar"))])
    }
  }

  private func workspaceDragGesture(for item: WorkspaceItem) -> some Gesture {
    DragGesture(minimumDistance: 6, coordinateSpace: .named("workspaceSidebar"))
      .updating($workspaceGestureActive) { _, active, _ in active = true }
      .onChanged { value in
        draggedItemID = item.id
        workspaceDragLocation = value.location
        workspaceDropTarget = target(at: value.location)
      }
      .onEnded { value in
        if let target = target(at: value.location) { _ = performWorkspaceDrop(target, sourceID: item.id) }
        draggedItemID = nil
        workspaceDragLocation = nil
        workspaceDropTarget = nil
      }
  }

  private func target(at point: CGPoint) -> WorkspaceDropTarget? {
    guard let root = folderURL else { return nil }
    if workspaceDropFrames["root"]?.contains(point) == true {
      return WorkspaceDropTarget(parent: root, before: nil, rowID: "root", edge: nil)
    }
    guard workspaceDropFrames["viewport"]?.contains(point) == true else { return nil }
    for row in visibleRows(in: workspaceItems) {
      guard let frame = workspaceDropFrames[row.id], frame.insetBy(dx: 0, dy: -1).contains(point) else { continue }
      if let parent = row.endOfFolder {
        return WorkspaceDropTarget(parent: parent, before: nil, rowID: row.id, edge: .bottom)
      }
      return dropTarget(for: row.item, at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
    }
    if let end = workspaceDropFrames["root-end"], point.y >= end.minY {
      return WorkspaceDropTarget(parent: root, before: nil, rowID: "root-end", edge: .bottom)
    }
    return nil
  }

  private func scrollWorkspaceDuringDrag(_ proxy: ScrollViewProxy) {
    guard let location = workspaceDragLocation, let viewport = workspaceDropFrames["viewport"],
      viewport.contains(location) else { return }
    let rows = visibleRows(in: workspaceItems)
    let visible = rows.indices.filter { index in
      guard let frame = workspaceDropFrames[rows[index].id] else { return false }
      return frame.intersects(viewport)
    }
    if location.y > viewport.maxY - 35, let last = visible.last, rows.indices.contains(last + 1) {
      proxy.scrollTo(rows[last + 1].id, anchor: .bottom)
    } else if location.y < viewport.minY + 35, let first = visible.first, first > 0 {
      proxy.scrollTo(rows[first - 1].id, anchor: .top)
    }
  }

  private func items(in parent: URL) -> [WorkspaceItem] {
    if parent.standardizedFileURL == folderURL?.standardizedFileURL { return workspaceItems }
    func find(_ items: [WorkspaceItem]) -> [WorkspaceItem]? {
      for item in items where item.isDirectory {
        if item.url.standardizedFileURL == parent.standardizedFileURL { return item.children ?? [] }
        if let found = find(item.children ?? []) { return found }
      }
      return nil
    }
    return find(workspaceItems) ?? []
  }

  private func parent(of item: WorkspaceItem) -> URL {
    (item.ownerDocument ?? item.url).deletingLastPathComponent()
  }

  private func dropTarget(for item: WorkspaceItem, at point: CGPoint) -> WorkspaceDropTarget {
    if item.isDirectory, point.y >= 10, point.y <= 28 {
      return WorkspaceDropTarget(parent: item.url, before: nil, rowID: item.id, edge: nil)
    }
    let parent = parent(of: item)
    let siblings = items(in: parent)
    let before = point.y < (item.isDirectory ? 10 : 27)
    let index = siblings.firstIndex(where: { $0.id == item.id }) ?? 0
    let anchor = before ? item.orderKey : (siblings.indices.contains(index + 1) ? siblings[index + 1].orderKey : nil)
    return WorkspaceDropTarget(parent: parent, before: anchor, rowID: item.id, edge: before ? .top : .bottom)
  }

  private func performWorkspaceDrop(_ target: WorkspaceDropTarget, sourceID: String) -> Bool {
    defer { draggedItemID = nil; workspaceDropTarget = nil }
    let id = sourceID
    guard let root = folderURL else { return false }
    func find(_ items: [WorkspaceItem]) -> WorkspaceItem? {
      for item in items {
        if item.id == id { return item }
        if let found = find(item.children ?? []) { return found }
      }
      return nil
    }
    guard let item = find(workspaceItems) else { return false }
    let sourceParent = parent(of: item)
    let sourceKeys = items(in: sourceParent).map(\.orderKey)
    let targetKeys = items(in: target.parent).map(\.orderKey)
    do {
      if sourceParent.standardizedFileURL == target.parent.standardizedFileURL {
        try WorkspaceItemOrder.save(WorkspaceItemOrder.placing(item.orderKey, before: target.before, in: sourceKeys), in: sourceParent)
      } else if case .version = item.kind {
        try moveVersionFile(item, to: target)
      } else {
        let destination = try WorkspaceFolderOperations.moveDestination(for: item.url, into: target.parent, root: root)
        let selected = model?.documentURL.flatMap {
          WorkspaceFolderOperations.rebasedURL($0, from: item.url, to: destination)
        }
        if selected != nil, model?.hasActiveAIRequest == true {
          throw PromptIterationError.validation("请等待当前 AI 请求完成或取消后再移动。")
        }
        var attachments: [(source: URL, destination: URL)] = []
        if !item.isDirectory {
          let history = PromptDocumentStorage.directory(for: item.url)
          if FileManager.default.fileExists(atPath: history.path) {
            attachments.append((history, PromptDocumentStorage.directory(for: destination)))
          }
        }
        // Keep an emptied source folder visible in the workspace.
        try markPromptFolder(sourceParent)
        try markPromptFolder(target.parent)
        try WorkspaceItemOrder.move(source: item.url, destination: destination, before: target.before,
          sourceKeys: sourceKeys, destinationKeys: targetKeys, attachments: attachments)
        expandedFolderIDs = Set(expandedFolderIDs.map { path in
          WorkspaceFolderOperations.rebasedURL(URL(fileURLWithPath: path), from: item.url, to: destination)?.path ?? path
        })
        if let selected { model?.relocateDocument(to: selected) }
      }
      expandAncestors(of: target.parent)
      refreshFiles(in: root)
      return true
    } catch {
      launcherError = error.localizedDescription
      return false
    }
  }

  private func moveVersionFile(_ item: WorkspaceItem, to target: WorkspaceDropTarget) throws {
    guard case let .version(number) = item.kind, let owner = item.ownerDocument else { return }
    let name = item.customName.map { $0 + ".md" }
      ?? "\(owner.deletingPathExtension().lastPathComponent) V\(number).md"
    let destination = target.parent.appendingPathComponent(name)
    let previous = try PromptDocumentStorage.detachedVersions(for: owner)
    try PromptDocumentStorage.detachVersion(number, for: owner, to: destination)
    do {
      try WorkspaceItemOrder.save(WorkspaceItemOrder.placing(name, before: target.before,
        in: items(in: target.parent).map(\.orderKey)), in: target.parent)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      try? PromptDocumentStorage.setDetachedVersions(previous, for: owner)
      throw error
    }
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
          openHistoryVersion(number, in: item.ownerDocument ?? item.url)
        } label: {
          Group {
            if let model { WorkspaceDocumentLabel(item: item, model: model) }
            else { Text(item.displayName) }
          }
          .padding(.leading, 8)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Menu {
          Button("重命名", systemImage: "pencil") { beginRenamingFile(item) }
          Divider()
          versionMenuActions(number: number, documentURL: item.ownerDocument ?? item.url)
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      .padding(.leading, 2)
      .background(
        workspacePage == .history
          && model?.documentURL?.standardizedFileURL
            == item.ownerDocument?.standardizedFileURL
          && model?.selectedHistoryVersion?.number == number
          ? Color.blue.opacity(0.12) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7)
      )
      .contextMenu {
        Button("重命名", systemImage: "pencil") { beginRenamingFile(item) }
        Divider()
        versionMenuActions(number: number, documentURL: item.ownerDocument ?? item.url)
      }
    } else if case .document = item.kind {
      HStack(spacing: 4) {
        Button {
          openDocument(item.url)
        } label: {
          Group {
            if let model { WorkspaceDocumentLabel(item: item, model: model) }
            else { Text(item.displayName) }
          }
          .padding(.leading, 8)
          .padding(.vertical, 7)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Menu {
          Button("重命名", systemImage: "pencil") { beginRenamingFile(item) }
          Divider()
          Button("保存新版本", systemImage: "doc.badge.plus") { saveNewVersion(for: item.url) }
          Button("对比", systemImage: "rectangle.split.2x1") {
            guard canChangeDocument() else { return }
            if model?.documentURL?.standardizedFileURL != item.url.standardizedFileURL,
              !openDocument(item.url) { return }
            model?.openPromptComparison()
            workspacePage = .editor
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
      .padding(.leading, 2)
      .frame(maxWidth: .infinity)
      .background(
        workspacePage == .editor
          && model?.documentURL?.standardizedFileURL == item.url.standardizedFileURL
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

  @ViewBuilder
  private func versionMenuActions(number: Int, documentURL: URL) -> some View {
    Button("保存新版本", systemImage: "doc.badge.plus") {
      saveNewVersion(for: documentURL)
    }
    Button("加入对比", systemImage: "rectangle.split.2x1") {
      compareHistoryVersion(number, in: documentURL)
    }
    Button("基于此版本编辑", systemImage: "square.and.pencil") {
      editHistoryVersion(number, in: documentURL)
    }
    Button("复制版本", systemImage: "doc.on.doc") {
      copyHistoryVersion(number, in: documentURL)
    }
    Divider()
    Button("在 Finder 中显示", systemImage: "folder") {
      let versionURL = PromptDocumentStorage.versionURL(number, for: documentURL)
      NSWorkspace.shared.activateFileViewerSelecting([versionURL])
    }
    Divider()
    Button("删除版本", systemImage: "trash", role: .destructive) {
      pendingVersionDeletion = (number, documentURL)
    }
  }

  private func createFolder() {
    guard canChangeDocument() else { return }
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
      if openWorkspace(url.deletingLastPathComponent(), selecting: promptURL) {
        workspacePage = .generation
      }
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func openFolder() {
    guard canChangeDocument() else { return }
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
      let owner = try? workingDocument(in: promptFolder)
      openWorkspace(workspaceRoot)
      if let owner { openHistoryVersion(number, in: owner) }
    } else {
      openWorkspace(workspaceRoot, selecting: url)
    }
  }

  private func beginCreatingSubfolder(in parent: URL) {
    newFolderName = "新建文件夹"
    pendingNewFolderParent = parent
  }

  private func createSubfolder(in parent: URL) {
    do {
      let destination = try WorkspaceFolderOperations.createFolder(named: newFolderName, in: parent)
      try markPromptFolder(destination)
      expandAncestors(of: destination)
      if let folderURL { refreshFiles(in: folderURL) }
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func createPromptFolder(in folderURL: URL) {
    guard canChangeDocument() else { return }
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
      if let root = self.folderURL { refreshFiles(in: root) }
      if openDocument(promptURL) { workspacePage = .generation }
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func renameCurrentPrompt(to enteredName: String) {
    guard let documentURL = model?.documentURL else { return }
    renameDocument(documentURL, to: enteredName)
  }

  private func saveGeneratedPrompt(_ content: String) {
    guard canChangeDocument(), let folderURL, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    do {
      let url = uniquePromptURL(in: folderURL)
      try content.write(to: url, atomically: true, encoding: .utf8)
      guard openDocument(url) else { return }
      _ = model?.saveVersion()
      refreshFiles(in: folderURL)
    } catch { launcherError = error.localizedDescription }
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

    _ = relocateFolder(source, to: destination)
  }

  @discardableResult
  private func relocateFolder(_ source: URL, to destination: URL) -> Bool {
    let selectedDocument = model?.documentURL
    let relocatedDocument = selectedDocument.flatMap {
      WorkspaceFolderOperations.rebasedURL($0, from: source, to: destination)
    }
    if relocatedDocument != nil, model?.hasActiveAIRequest == true {
      launcherError = "请等待当前 AI 请求完成或取消后再移动或重命名文件夹。"
      return false
    }
    do {
      // Moving the directory also carries its hidden .prompt-history databases and snapshots.
      let parent = source.deletingLastPathComponent()
      let keys = items(in: parent).map(\.orderKey)
      let next = keys.firstIndex(of: source.lastPathComponent).flatMap { keys.indices.contains($0 + 1) ? keys[$0 + 1] : nil }
      try WorkspaceItemOrder.move(source: source, destination: destination, before: next,
        sourceKeys: keys, destinationKeys: keys)
      expandedFolderIDs = Set(expandedFolderIDs.map { path in
        WorkspaceFolderOperations.rebasedURL(URL(fileURLWithPath: path), from: source, to: destination)?.path ?? path
      })
      if let root = folderURL,
        let relocatedRoot = WorkspaceFolderOperations.rebasedURL(root, from: source, to: destination) {
        folderURL = relocatedRoot
      }
      expandAncestors(of: destination)
      if let relocatedDocument {
        model?.relocateDocument(to: relocatedDocument)
      }
      if let folderURL { refreshFiles(in: folderURL) }
      return true
    } catch {
      launcherError = error.localizedDescription
      return false
    }
  }

  private func expandAncestors(of url: URL) {
    guard let root = folderURL?.standardizedFileURL else { return }
    var current = url.standardizedFileURL
    while current.path != root.path, current.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") {
      expandedFolderIDs.insert(current.path)
      current.deleteLastPathComponent()
    }
  }

  @discardableResult
  private func openWorkspace(_ url: URL, selecting selected: URL? = nil) -> Bool {
    guard canChangeDocument() else { return false }
    folderURL = url
    refreshFiles(in: url)
    if let selected {
      return openDocument(selected)
    } else if let first = markdownFiles.first {
      return openDocument(first)
    } else {
      model = nil
    }
    return true
  }

  private func canChangeDocument() -> Bool {
    guard model?.hasActiveAIRequest != true else {
      launcherError = "请等待当前 AI 请求完成或取消后，再切换或删除文档。"
      return false
    }
    return true
  }

  @discardableResult
  private func openDocument(_ url: URL) -> Bool {
    guard canChangeDocument() else { return false }
    let creationRequest = model?.creationRequest ?? ""
    let generatedPrompt = model?.generatedPrompt ?? ""
    expandAncestors(of: url.deletingLastPathComponent())
    model = AppModel(documentURL: url)
    model?.creationRequest = creationRequest
    model?.generatedPrompt = generatedPrompt
    if let folderURL { refreshFiles(in: folderURL) }
    guard model?.workspace != nil else { return false }
    workspacePage = .editor
    return true
  }

  @discardableResult
  private func openHistoryVersion(_ number: Int, in promptURL: URL) -> Bool {
    guard canChangeDocument() else { return false }
    if model?.documentURL?.standardizedFileURL != promptURL.standardizedFileURL,
      !openDocument(promptURL) { return false }
    guard let version = model?.versions.first(where: { $0.number == number }) else {
      launcherError = "找不到历史版本 V\(number)"
      return false
    }
    model?.showsComparison = false
    model?.selectHistory(version)
    workspacePage = .history
    return true
  }

  private func copyHistoryVersion(_ number: Int, in promptDocument: URL) {
    guard openHistoryVersion(number, in: promptDocument) else { return }
    model?.copySelectedHistory()
  }

  private func editHistoryVersion(_ number: Int, in promptDocument: URL) {
    guard openHistoryVersion(number, in: promptDocument) else { return }
    guard let version = model?.selectedHistoryVersion else { return }
    if model?.hasUnversionedChanges == true {
      pendingVersionEdit = version
    } else if model?.startEditingHistory(version) == true {
      workspacePage = .editor
    }
  }

  private func compareHistoryVersion(_ number: Int, in promptDocument: URL) {
    guard openHistoryVersion(number, in: promptDocument) else { return }
    guard let version = model?.selectedHistoryVersion else { return }
    model?.loadHistory(version)
  }

  private func saveNewVersion(for documentURL: URL) {
    guard canChangeDocument() else { return }
    if model?.documentURL?.standardizedFileURL != documentURL.standardizedFileURL,
      !openDocument(documentURL) { return }
    if model?.saveVersion() == true, let folderURL { refreshFiles(in: folderURL) }
  }

  private func saveNewVersion(in promptFolder: URL) {
    do {
      guard let documentURL = try workingDocument(in: promptFolder) else {
        launcherError = "这个项目中没有可编辑的 Prompt 文件"
        return
      }
      saveNewVersion(for: documentURL)
    } catch {
      launcherError = error.localizedDescription
    }
  }

  private func deleteHistoryVersion(_ number: Int, in documentURL: URL) {
    guard canChangeDocument() else { return }
    if model?.documentURL?.standardizedFileURL != documentURL.standardizedFileURL,
      !openDocument(documentURL) { return }
    if model?.deleteVersion(number) == true {
      if workspacePage == .history { workspacePage = .editor }
      if let folderURL { refreshFiles(in: folderURL) }
    }
  }

  private func workingDocument(in promptFolder: URL) throws -> URL? {
    try FileManager.default.contentsOfDirectory(
      at: promptFolder,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).first { versionNumber(from: $0) == nil && isPromptDocument($0) }
  }

  private func beginRenaming(_ url: URL) {
    pendingRenameVersion = nil
    renameText = url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    pendingRenameURL = url
  }

  private func beginRenamingFile(_ item: WorkspaceItem) {
    beginRenaming(item.url)
    if case let .version(number) = item.kind, let document = item.ownerDocument {
      pendingRenameVersion = (number, document)
      renameText = item.displayName
    }
  }

  private func renameDocument(_ url: URL, to enteredName: String) {
    let destination: URL
    do {
      let filename = try PromptDocumentStorage.markdownFilename(from: enteredName)
      destination = url.deletingLastPathComponent().appendingPathComponent(filename)
      guard PromptDocumentStorage.versionNumber(destination) == nil else {
        throw PromptIterationError.validation("V 加数字是历史版本的保留名称，请使用其他文档名称。")
      }
    } catch {
      launcherError = error.localizedDescription
      return
    }
    guard destination.standardizedFileURL != url.standardizedFileURL else { return }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      launcherError = "同名文档已经存在"
      return
    }

    let wasSelected = model?.documentURL?.standardizedFileURL == url.standardizedFileURL
    if wasSelected, model?.hasActiveAIRequest == true {
      launcherError = "请等待当前 AI 请求完成或取消后再重命名。"
      return
    }
    do {
      let parent = url.deletingLastPathComponent()
      let keys = items(in: parent).map(\.orderKey)
      let next = keys.firstIndex(of: url.lastPathComponent).flatMap { keys.indices.contains($0 + 1) ? keys[$0 + 1] : nil }
      let history = PromptDocumentStorage.directory(for: url)
      let attachments: [(source: URL, destination: URL)] = FileManager.default.fileExists(atPath: history.path)
        ? [(history, PromptDocumentStorage.directory(for: destination))] : []
      try WorkspaceItemOrder.move(source: url, destination: destination, before: next,
        sourceKeys: keys, destinationKeys: keys, attachments: attachments)
      if wasSelected { model?.relocateDocument(to: destination) }
      if let folderURL { refreshFiles(in: folderURL) }
    } catch { launcherError = error.localizedDescription }
  }

  private func trashItem(_ url: URL) {
    let selectedDocument = model?.documentURL
    let selectedPath = selectedDocument?.standardizedFileURL.path
    let targetPath = url.standardizedFileURL.path
    let wasSelected = selectedPath == targetPath || selectedPath?.hasPrefix(targetPath + "/") == true
    if wasSelected, !canChangeDocument() { return }
    do {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      if wasSelected { model = nil }
      if let folderURL {
        refreshFiles(in: folderURL)
        if wasSelected, let next = markdownFiles.first { openDocument(next) }
      }
    } catch {
      launcherError = error.localizedDescription
    }
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

  private func loadWorkspaceItems(in folder: URL, isRoot: Bool) throws -> [WorkspaceItem] {
    try PromptDocumentStorage.migrateLegacyFolder(folder)
    let urls = try FileManager.default.contentsOfDirectory(at: folder,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var result: [WorkspaceItem] = []
    for url in urls {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
      guard values.isSymbolicLink != true else { continue }
      if values.isDirectory == true {
        guard try isPromptFolder(url) else { continue }
        result.append(WorkspaceItem(url: url, kind: .folder, children: try loadWorkspaceItems(in: url, isRoot: false)))
      } else if isPromptDocument(url) {
        let snapshots = try PromptDocumentStorage.snapshots(for: url)
        result.append(WorkspaceItem(url: url, kind: .document, children: nil, updatedAt: AppModel.savedDraftEditedAt(for: url)))
        let detached = try PromptDocumentStorage.detachedVersions(for: url)
        let names = try PromptDocumentStorage.snapshotNames(for: url)
        for snapshot in snapshots where !detached.contains(snapshot.number) {
          let customName = names[String(snapshot.number)].map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
          result.append(WorkspaceItem(url: snapshot.url, kind: .version(snapshot.number), children: nil,
            ownerDocument: url, customName: customName,
            updatedAt: try snapshot.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
        }
      }
    }
    result.sort {
      if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
      switch ($0.kind, $1.kind) {
      case (.document, .version): return true
      case (.version, .document): return false
      case let (.version(lhs), .version(rhs)): return lhs > rhs
      default: break
      }
      return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
    }
    let keys = try WorkspaceItemOrder.sortedKeys(result.map(\.orderKey), in: folder)
    let positions = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
    return result.sorted { positions[$0.orderKey, default: 0] < positions[$1.orderKey, default: 0] }
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
    return (try? String(contentsOf: url, encoding: .utf8)) != nil
  }

  private func markPromptFolder(_ url: URL) throws {
    let marker = url.appendingPathComponent(Self.workspaceMarkerName)
    guard !FileManager.default.fileExists(atPath: marker.path) else { return }
    try Data().write(to: marker, options: .atomic)
  }

  private func writeDefaultPrompt(to url: URL) throws {
    try "".write(to: url, atomically: true, encoding: .utf8)
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

struct PromptComparisonSource: Identifiable, Equatable, Sendable {
  let id: String
  let label: String
  let content: String
  var updatedAt: Date? = nil
}

struct PromptOutputResult: Sendable {
  var content = ""
  var error: String?
}

struct PromptOutputRun {
  let id = UUID()
  let left: PromptComparisonSource
  let right: PromptComparisonSource
  let input: String
  let modelName: String
  var leftResult = PromptOutputResult()
  var rightResult = PromptOutputResult()
  var leftIsRunning = true
  var rightIsRunning = true
}

struct PromptComparisonEdit: Codable {
  var content: String
  var updatedAt: Date
}

private struct PendingComparisonEdits: Codable {
  var leftID: String
  var rightID: String
  var edits: [String: PromptComparisonEdit]
}

@MainActor
final class AppModel: ObservableObject {
  @Published var workspace: PromptWorkspace?
  @Published var comparison: ComparisonSnapshot?
  @Published var versions: [VersionSummary] = []
  @Published var selectedHistoryVersion: VersionSummary?
  @Published var selectedHistorySections: [PromptSection] = []
  @Published var showsComparison = false
  @Published var comparisonLeftID = "draft"
  @Published var comparisonRightID = "draft"
  @Published var hasUnversionedChanges = false
  @Published var copyFeedback: String?
  @Published var errorMessage: String?
  @Published var deepSeekAPIKey = ""
  @Published var deepSeekBaseURL = "https://api.deepseek.com"
  @Published var deepSeekModel = "deepseek-flash"
  @Published var isTestingDeepSeek = false
  @Published var deepSeekConnectionSucceeded: Bool?
  @Published var deepSeekConnectionMessage = "尚未配置"
  @Published var isGeneratingPrompt = false
  @Published var creationRequest = ""
  @Published var generatedPrompt = ""
  @Published var isCreatingPrompt = false
  @Published var optimizationRequest = ""
  @Published var outputComparison: PromptOutputRun?
  @Published var isComparingOutputs = false
  @Published var usesFramework = false
  @Published private(set) var freeformContent = ""
  @Published private(set) var comparisonEdits: [String: PromptComparisonEdit] = [:]
  @Published var generationSystemPrompt = "" {
    didSet { UserDefaults.standard.set(generationSystemPrompt, forKey: "deepseek.generationSystemPrompt") }
  }

  private(set) var databaseURL: URL
  private(set) var documentURL: URL?
  private var repository: WorkspaceRepository?
  private var testedDeepSeekSettings: [String]?
  private var outputComparisonTask: Task<Void, Never>?
  private var promptGenerationTask: Task<Void, Never>?

  var hasActiveAIRequest: Bool { isGeneratingPrompt || isCreatingPrompt || isComparingOutputs }

  var draftVersionLabel: String {
    guard let workspace, !hasUnversionedChanges,
      versions.contains(where: { $0.number == workspace.currentVersion }) else { return "工作稿" }
    return "V\(workspace.currentVersion)"
  }

  init(documentURL: URL? = nil) {
    self.documentURL = documentURL?.standardizedFileURL
    databaseURL = Self.databaseURL(for: self.documentURL)
    do {
      if let documentURL { try PromptDocumentStorage.migrateLegacyFolder(documentURL.deletingLastPathComponent()) }
      try Self.migrateLegacyDatabaseIfNeeded(
        documentURL: self.documentURL,
        destination: databaseURL
      )
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
        freeformContent = markdown
        try repository.saveDraft(workspace)
      }
      if workspace.sections.allSatisfy({ $0.content.isEmpty }),
        workspace.sections.map(\.title) == PromptSection.defaults().map(\.title) {
        freeformContent = ""
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
            requireNew: false
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
    }

    do {
      if FileManager.default.fileExists(atPath: comparisonEditsURL.path) {
        let saved = try JSONDecoder().decode(PendingComparisonEdits.self, from: Data(contentsOf: comparisonEditsURL))
        comparisonEdits = saved.edits
        let ids = Set(try comparisonSources().map(\.id))
        if !saved.edits.isEmpty, ids.contains(saved.leftID), ids.contains(saved.rightID) {
          comparisonLeftID = saved.leftID
          comparisonRightID = saved.rightID
          showsComparison = true
        }
      }
    } catch { report(error) }

    deepSeekBaseURL = UserDefaults.standard.string(forKey: "deepseek.baseURL")
      ?? "https://api.deepseek.com"
    deepSeekModel = "deepseek-flash"
    UserDefaults.standard.set(deepSeekModel, forKey: "deepseek.model")
    deepSeekAPIKey = UserDefaults.standard.string(forKey: "deepseek.apiKey") ?? ""
    let storedGenerationPrompt = UserDefaults.standard.string(forKey: "deepseek.generationSystemPrompt") ?? ""
    generationSystemPrompt = storedGenerationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? PromptGenerationInstructions.defaultCreationPrompt : storedGenerationPrompt
    if !deepSeekAPIKey.isEmpty {
      deepSeekConnectionMessage = "已读取本地配置，尚未测试"
    }
  }

  func relocateDocument(to url: URL) {
    documentURL = url.standardizedFileURL
    databaseURL = Self.databaseURL(for: documentURL)
    do {
      repository = try WorkspaceRepository(databaseURL: databaseURL)
      workspace?.name = url.deletingPathExtension().lastPathComponent
    } catch {
      repository = nil
      errorMessage = error.localizedDescription
    }
  }

  var lastEditedAt: Date? {
    guard let documentURL else { return nil }
    return try? documentURL.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
  }

  var savedDraftEditedAt: Date? {
    guard draftVersionLabel != "工作稿", let workspace else { return nil }
    return editedAt(forVersion: workspace.currentVersion)
  }

  static func savedDraftEditedAt(for document: URL) -> Date? {
    guard let latest = try? PromptDocumentStorage.snapshots(for: document).max(by: { $0.number < $1.number }),
      let draft = try? String(contentsOf: document, encoding: .utf8),
      let saved = try? String(contentsOf: latest.url, encoding: .utf8),
      PromptMarkdown.renderAll(PromptMarkdown.parse(draft)) == PromptMarkdown.renderAll(PromptMarkdown.parse(saved))
    else { return nil }
    return try? latest.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  var comparisonLastEditedAt: Date? {
    guard let comparison else { return nil }
    if let sourceVersion = comparison.sourceVersion,
      let date = editedAt(forVersion: sourceVersion) { return date }
    guard let workspace, let repository,
      let updatedAt = try? repository.comparisonUpdatedAt(projectID: workspace.id) else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: updatedAt)
  }

  func editedAt(forVersion number: Int) -> Date? {
    guard let createdAt = versions.first(where: { $0.number == number })?.createdAt else {
      return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: createdAt)
  }

  func updateTitle(sectionID: String, title: String) {
    guard !isGeneratingPrompt, var workspace,
      let index = workspace.sections.firstIndex(where: { $0.id == sectionID })
    else { return }
    workspace.sections[index].title = title
    self.workspace = workspace
    if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

  func toggleFramework() {
    guard let workspace, !isGeneratingPrompt else { return }
    usesFramework.toggle()
    if usesFramework {
      let sections = PromptMarkdown.frameworkSections(from: workspace.sections)
      if sections != workspace.sections {
        mutateWorkspace { $0.sections = sections }
        if var comparison, comparison.kind == .manual, comparison.sections.count == 1,
          let previous = comparison.sections.first, previous.sectionID == PromptSection.freeform().id {
          comparison.sections = sections.enumerated().map { index, section in
            ComparisonSection(
              sectionID: section.id, title: section.title,
              content: index == 0 ? previous.content : "", position: index,
              status: index == 0 ? previous.status : .pending
            )
          }
          self.comparison = comparison
        }
        syncManualComparisonStructure()
      }
    } else {
      freeformContent = PromptMarkdown.renderAll(workspace.sections)
    }
  }

  func updateFreeformContent(_ content: String) {
    guard !isGeneratingPrompt, var workspace else { return }
    let previousSections = workspace.sections
    workspace.sections = Self.preserveSectionIDs(
      parsed: PromptMarkdown.parse(content), existing: previousSections
    )
    self.workspace = workspace
    freeformContent = content
    persistDraft(markdown: content)
    if workspace.sections.map(\.id) != previousSections.map(\.id)
      || workspace.sections.map(\.title) != previousSections.map(\.title) {
      syncManualComparisonStructure()
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
    openPromptComparison(version: version.number)
  }

  func selectHistory(_ version: VersionSummary) {
    guard let workspace, let repository else { return }
    do {
      selectedHistoryVersion = version
      selectedHistorySections = try repository.versionSections(
        projectID: workspace.id,
        number: version.number
      )
    } catch { report(error) }
  }

  func copySelectedHistory() {
    guard let version = selectedHistoryVersion else { return }
    copy(PromptMarkdown.render(selectedHistorySections))
    showCopyFeedback("已复制 V\(version.number)")
  }

  @discardableResult
  func startEditingHistory(_ version: VersionSummary) -> Bool {
    guard !hasActiveAIRequest, let workspace, let repository else { return false }
    do {
      self.workspace = try repository.restoreVersionAsDraft(
        workspace: workspace,
        number: version.number
      )
      if let restored = self.workspace {
        try saveMarkdownDraft(restored)
      }
      showsComparison = false
      hasUnversionedChanges = try Self.hasChanges(workspace: self.workspace ?? workspace, repository: repository)
      return true
    } catch {
      report(error)
      return false
    }
  }

  @discardableResult
  func saveVersion(sourceID: String = "draft", editedContent: String? = nil) -> Bool {
    guard !hasActiveAIRequest, var workspace, let repository else { return false }
    do {
      var snapshot = workspace
      snapshot.sections = try sectionsForComparisonSource(sourceID, editedContent: editedContent)
      try repository.saveDraft(workspace)
      var writtenURL: URL?
      let version: VersionSummary
      do {
        version = try repository.saveVersion(workspace: snapshot, note: "手动保存") { number in
          if let documentURL = self.documentURL {
            try Self.writeVersionSnapshot(snapshot.sections, number: number, beside: documentURL, requireNew: true)
            writtenURL = Self.versionFileURL(number: number, beside: documentURL)
          }
        }
      } catch {
        if let writtenURL { try? FileManager.default.removeItem(at: writtenURL) }
        throw error
      }
      workspace.currentVersion = version.number
      self.workspace = workspace
      versions = try repository.listVersions(projectID: workspace.id)
      selectedHistoryVersion = version
      selectedHistorySections = snapshot.sections
      hasUnversionedChanges = try Self.hasChanges(workspace: workspace, repository: repository)
      if showsComparison && sourceID == comparisonRightID {
        comparisonRightID = "version-\(version.number)"
      }
      if editedContent == comparisonEdits[sourceID]?.content { discardComparisonEdit(sourceID) }
      return true
    } catch {
      report(error)
      return false
    }
  }

  @discardableResult
  func deleteVersion(_ number: Int) -> Bool {
    guard !hasActiveAIRequest, var workspace, let repository else { return false }
    let versionURL = documentURL.map { Self.versionFileURL(number: number, beside: $0) }
    var trashedURL: NSURL?
    do {
      if let versionURL, FileManager.default.fileExists(atPath: versionURL.path) {
        try FileManager.default.trashItem(at: versionURL, resultingItemURL: &trashedURL)
      }
      do {
        try repository.deleteVersion(projectID: workspace.id, number: number)
      } catch {
        if let trashedURL, let versionURL {
          try? FileManager.default.moveItem(at: trashedURL as URL, to: versionURL)
        }
        throw error
      }

      versions = try repository.listVersions(projectID: workspace.id)
      workspace.currentVersion = versions.first?.number ?? 0
      self.workspace = workspace
      hasUnversionedChanges = try Self.hasChanges(workspace: workspace, repository: repository)
      if selectedHistoryVersion?.number == number {
        selectedHistoryVersion = versions.first
        selectedHistorySections = try versions.first.map {
          try repository.versionSections(projectID: workspace.id, number: $0.number)
        } ?? []
      }
      if comparison?.kind == .history, comparison?.sourceVersion == number {
        try repository.clearComparison(projectID: workspace.id)
        comparison = nil
        showsComparison = false
      }
      discardComparisonEdit("version-\(number)")
      return true
    } catch {
      report(error)
      return false
    }
  }

  func copyFullPrompt() {
    guard let workspace else { return }
    copy(PromptMarkdown.render(workspace.sections))
    showCopyFeedback("复制成功")
  }

  private var comparisonPromptSections: [PromptSection] {
    guard let workspace, let comparison else { return [] }
    let included = Dictionary(uniqueKeysWithValues: workspace.sections.map { ($0.id, $0.isIncluded) })
    return comparison.sections.map {
      PromptSection(
        id: $0.sectionID,
        title: $0.title,
        content: $0.content,
        position: $0.position,
        isIncluded: included[$0.sectionID] ?? true
      )
    }
  }

  func comparisonSources() throws -> [PromptComparisonSource] {
    guard let workspace, let repository else { return [] }
    var sources = [PromptComparisonSource(id: "draft", label: "工作稿", content: PromptMarkdown.render(workspace.sections), updatedAt: lastEditedAt)]
    if comparison?.kind == .manual {
      sources.append(.init(id: "candidate", label: "AI 参考稿", content: PromptMarkdown.render(comparisonPromptSections), updatedAt: comparisonLastEditedAt))
    }
    for version in versions {
      let sections = try repository.versionSections(projectID: workspace.id, number: version.number)
      sources.append(.init(id: "version-\(version.number)", label: "V\(version.number)", content: PromptMarkdown.render(sections), updatedAt: editedAt(forVersion: version.number)))
    }
    return sources
  }

  func openPromptComparison(version: Int? = nil) {
    guard !hasActiveAIRequest else { return }
    do {
      let sources = try comparisonSources()
      if let version, sources.contains(where: { $0.id == "version-\(version)" }) {
        comparisonLeftID = "version-\(version)"
        comparisonRightID = "draft"
      } else if sources.contains(where: { $0.id == "candidate" }) {
        comparisonLeftID = "draft"
        comparisonRightID = "candidate"
      } else {
        comparisonLeftID = sources.first(where: { $0.id.hasPrefix("version-") })?.id ?? "draft"
        comparisonRightID = "draft"
      }
      showsComparison = true
    } catch { report(error) }
  }

  func sectionsForComparisonSource(_ id: String, editedContent: String? = nil) throws -> [PromptSection] {
    guard let workspace, let repository else { throw PromptIterationError.notFound("工作稿未加载") }
    let original: [PromptSection]
    if id == "draft" { original = workspace.sections }
    else if id == "candidate", comparison?.kind == .manual { original = comparisonPromptSections }
    else if id.hasPrefix("version-"), let number = Int(id.dropFirst("version-".count)),
      versions.contains(where: { $0.number == number }) {
      original = try repository.versionSections(projectID: workspace.id, number: number)
    } else {
      throw PromptIterationError.notFound("所选版本已不存在，请重新选择。")
    }
    guard let editedContent, editedContent != PromptMarkdown.render(original) else { return original }
    var sections = Self.preserveSectionIDs(
      parsed: PromptMarkdown.parse(editedContent), existing: original.filter(\.isIncluded)
    )
    for hidden in original.filter({ !$0.isIncluded }) {
      sections.insert(hidden, at: min(hidden.position, sections.count))
    }
    for index in sections.indices { sections[index].position = index }
    return sections
  }

  @discardableResult
  func applyComparisonSource(_ id: String, editedContent: String? = nil) -> Bool {
    guard !hasActiveAIRequest, var workspace, let repository else { return false }
    do {
      workspace.sections = try sectionsForComparisonSource(id, editedContent: editedContent)
      try repository.saveDraft(workspace)
      try saveMarkdownDraft(workspace)
      self.workspace = workspace
      hasUnversionedChanges = try Self.hasChanges(workspace: workspace, repository: repository)
      discardComparisonEdit(id)
      if id != "draft" { discardComparisonEdit("draft") }
      return true
    } catch {
      report(error)
      return false
    }
  }

  @discardableResult
  func saveDeepSeekSettings() -> Bool {
    let apiKey = deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseURL = deepSeekBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let model = deepSeekModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let settings = [apiKey, baseURL, model]

    guard !apiKey.isEmpty else {
      deepSeekConnectionSucceeded = false
      deepSeekConnectionMessage = "请先填写 DeepSeek API Key"
      return false
    }
    guard let url = URL(string: baseURL), url.scheme == "https", url.host != nil else {
      deepSeekConnectionSucceeded = false
      deepSeekConnectionMessage = "接口地址必须是有效的 HTTPS 地址"
      return false
    }
    guard Self.supportedDeepSeekModels.contains(model) else {
      deepSeekConnectionSucceeded = false
      deepSeekConnectionMessage = "请选择受支持的 DeepSeek 模型"
      return false
    }

    UserDefaults.standard.set(apiKey, forKey: "deepseek.apiKey")
    UserDefaults.standard.set(baseURL, forKey: "deepseek.baseURL")
    UserDefaults.standard.set(model, forKey: "deepseek.model")
    deepSeekAPIKey = apiKey
    deepSeekBaseURL = baseURL
    deepSeekModel = model
    if deepSeekConnectionSucceeded != true || testedDeepSeekSettings != settings {
      deepSeekConnectionSucceeded = nil
      deepSeekConnectionMessage = "配置已保存，尚未测试"
    }
    return true
  }

  func testDeepSeekConnection() {
    guard !isTestingDeepSeek, saveDeepSeekSettings() else { return }
    guard let endpoint = URL(string: "\(deepSeekBaseURL)/models") else { return }

    let settings = [deepSeekAPIKey, deepSeekBaseURL, deepSeekModel]
    isTestingDeepSeek = true
    deepSeekConnectionSucceeded = nil
    deepSeekConnectionMessage = "正在连接 DeepSeek…"

    Task {
      defer { isTestingDeepSeek = false }
      do {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(settings[0])", forHTTPHeaderField: "Authorization")
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
        guard models.data.contains(where: { $0.id == settings[2] }) else {
          throw DeepSeekConfigurationError.modelUnavailable(settings[2])
        }

        guard settings == [deepSeekAPIKey, deepSeekBaseURL, deepSeekModel] else {
          deepSeekConnectionSucceeded = nil
          deepSeekConnectionMessage = "配置已修改，请重新测试"
          return
        }
        testedDeepSeekSettings = settings
        deepSeekConnectionSucceeded = true
        deepSeekConnectionMessage = "连接成功，所选模型可以使用"
      } catch {
        guard settings == [deepSeekAPIKey, deepSeekBaseURL, deepSeekModel] else {
          deepSeekConnectionSucceeded = nil
          deepSeekConnectionMessage = "配置已修改，请重新测试"
          return
        }
        deepSeekConnectionSucceeded = false
        deepSeekConnectionMessage = "连接失败：\(error.localizedDescription)"
      }
    }
  }

  func generatePrompt(from sourceSections: [PromptSection]? = nil, isCreating: Bool = false, onSuccess: (() -> Void)? = nil) {
    guard !isGeneratingPrompt, !isCreatingPrompt, !isComparingOutputs else { return }
    guard let workspace, let repository else { return }
    let sourceSections = sourceSections ?? workspace.sections
    let includedSections = sourceSections.filter(\.isIncluded)
    guard includedSections.contains(where: {
      !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) else {
      errorMessage = isCreating ? "请先描述你想要的提示词。" : "请先在 System Prompt 中写入内容。"
      return
    }
    guard saveDeepSeekSettings() else {
      errorMessage = deepSeekConnectionMessage
      return
    }
    guard let endpoint = URL(string: "\(deepSeekBaseURL)/chat/completions") else { return }

    let previousComparison = comparison
    let previouslyShowingComparison = showsComparison
    let previousSelection = (comparisonLeftID, comparisonRightID)
    let apiKey = deepSeekAPIKey
    let model = deepSeekModel
    errorMessage = nil
    var snapshot = ComparisonSnapshot(
      kind: .manual,
      sourceVersion: nil,
      sections: sourceSections.map { section in
        ComparisonSection(
          sectionID: section.id,
          title: section.title,
          content: section.isIncluded ? "" : section.content,
          position: section.position
        )
      }
    )
    if isCreating {
      isCreatingPrompt = true
    } else {
      comparison = snapshot
      if !previouslyShowingComparison { comparisonLeftID = "draft" }
      comparisonRightID = "candidate"
      showsComparison = true
      isGeneratingPrompt = true
    }
    let systemMessage = PromptGenerationInstructions.systemMessage(
      customPrompt: isCreating ? generationSystemPrompt : "", isCreating: isCreating,
      optimizationRequest: optimizationRequest
    )

    promptGenerationTask = Task {
      defer {
        if isCreating { isCreatingPrompt = false } else { isGeneratingPrompt = false }
        promptGenerationTask = nil
      }
      do {
        try Task.checkCancellation()
        let input = try JSONEncoder().encode(
          includedSections.map {
            DeepSeekPromptSection(id: $0.id, title: $0.title, content: $0.content)
          }
        )
        guard let inputJSON = String(data: input, encoding: .utf8) else {
          throw DeepSeekConfigurationError.invalidResponse
        }
        let body: [String: Any] = [
          "model": model,
          "messages": [
            [
              "role": "system",
              "content": systemMessage,
            ],
            ["role": "user", "content": inputJSON],
          ],
          "stream": true,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
          throw DeepSeekConfigurationError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
          var data = Data()
          for try await byte in bytes { data.append(byte) }
          throw DeepSeekConfigurationError.requestFailed(
            statusCode: response.statusCode,
            message: Self.deepSeekErrorMessage(from: data)
          )
        }

        var generatedBuffer = ""
        var generatedCount = 0

        @MainActor
        func consumeGeneratedLine(_ rawLine: String) throws {
          let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !line.isEmpty, !line.hasPrefix("```") else { return }
          guard generatedCount < includedSections.count,
            let data = line.data(using: .utf8),
            let generated = try? JSONDecoder().decode(DeepSeekGeneratedSection.self, from: data),
            generated.id == includedSections[generatedCount].id,
            let snapshotIndex = snapshot.sections.firstIndex(where: {
              $0.sectionID == generated.id
            })
          else { throw DeepSeekConfigurationError.incompletePrompt }

          if !includedSections[generatedCount].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            generated.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DeepSeekConfigurationError.incompletePrompt
          }
          snapshot.sections[snapshotIndex].content = generated.content
          generatedCount += 1
          if !isCreating {
            comparison = snapshot
          }
        }

        for try await streamLine in bytes.lines {
          try Task.checkCancellation()
          let line = streamLine.trimmingCharacters(in: .whitespacesAndNewlines)
          guard line.hasPrefix("data:") else { continue }
          let payload = String(line.dropFirst(5))
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if payload == "[DONE]" { break }
          guard let payloadData = payload.data(using: .utf8) else {
            throw DeepSeekConfigurationError.invalidResponse
          }
          let chunk = try JSONDecoder().decode(DeepSeekStreamChunk.self, from: payloadData)
          if chunk.choices.contains(where: { $0.finish_reason == "length" || $0.finish_reason == "content_filter" }) {
            throw DeepSeekConfigurationError.incompletePrompt
          }
          guard let delta = chunk.choices.first?.delta.content else { continue }

          generatedBuffer += delta
          while let newline = generatedBuffer.firstIndex(of: "\n") {
            let generatedLine = String(generatedBuffer[..<newline])
            generatedBuffer = String(generatedBuffer[generatedBuffer.index(after: newline)...])
            try consumeGeneratedLine(generatedLine)
          }
        }

        try Task.checkCancellation()
        try consumeGeneratedLine(generatedBuffer)
        guard generatedCount == includedSections.count else {
          throw DeepSeekConfigurationError.incompletePrompt
        }
        if isCreating {
          let content = snapshot.sections.first?.content ?? ""
          guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekConfigurationError.incompletePrompt
          }
          generatedPrompt = content
        } else {
          try repository.saveComparison(projectID: workspace.id, snapshot: snapshot)
          comparison = snapshot
          discardComparisonEdit("candidate")
        }
        onSuccess?()
      } catch {
        if !isCreating {
          comparison = previousComparison
          showsComparison = previouslyShowingComparison
          comparisonLeftID = previousSelection.0
          comparisonRightID = previousSelection.1
        }
        if !Task.isCancelled {
          errorMessage = "AI \(isCreating ? "生成" : "优化")失败：\(error.localizedDescription)"
        }
      }
    }
  }

  func cancelPromptGeneration() { promptGenerationTask?.cancel() }

  func createPromptWithAI() {
    generatePrompt(from: [PromptSection.freeform(creationRequest)], isCreating: true)
  }

  func copyGeneratedPrompt() {
    copy(generatedPrompt)
    showCopyFeedback("复制成功")
  }

  @discardableResult
  func comparePromptOutputs(left: PromptComparisonSource, right: PromptComparisonSource, input: String) -> Bool {
    guard !isComparingOutputs, !isGeneratingPrompt, !isCreatingPrompt else { return false }
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !left.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !right.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorMessage = "请填写测试输入，并选择两个有内容的 Prompt。"
      return false
    }
    guard left.id != right.id || left.content != right.content else {
      errorMessage = "请选择两个不同的 Prompt。"
      return false
    }
    guard saveDeepSeekSettings() else {
      errorMessage = deepSeekConnectionMessage
      return false
    }
    guard let endpoint = URL(string: "\(deepSeekBaseURL)/chat/completions") else { return false }
    let run = PromptOutputRun(left: left, right: right, input: input, modelName: deepSeekModel)
    let apiKey = deepSeekAPIKey
    outputComparison = run
    isComparingOutputs = true
    outputComparisonTask = Task {
      await withTaskGroup(of: (Bool, PromptOutputResult).self) { group in
        for (isLeft, source) in [(true, left), (false, right)] {
          group.addTask {
            let result = await Self.requestPromptOutput(
              source: source, input: input, model: run.modelName, endpoint: endpoint, apiKey: apiKey
            )
            return (isLeft, result)
          }
        }
        for await (isLeft, result) in group {
          guard outputComparison?.id == run.id else { continue }
          if isLeft {
            outputComparison?.leftResult = result
            outputComparison?.leftIsRunning = false
          } else {
            outputComparison?.rightResult = result
            outputComparison?.rightIsRunning = false
          }
        }
      }
      isComparingOutputs = false
      outputComparisonTask = nil
    }
    return true
  }

  func cancelOutputComparison() { outputComparisonTask?.cancel() }

  func copyTestOutput(_ content: String) {
    copy(content)
    showCopyFeedback("复制成功")
  }

  private static func requestPromptOutput(
    source: PromptComparisonSource, input: String, model: String, endpoint: URL, apiKey: String
  ) async -> PromptOutputResult {
    do {
      try Task.checkCancellation()
      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = 180
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model,
        "messages": [["role": "system", "content": source.content], ["role": "user", "content": input]],
        "stream": false,
      ])
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let response = response as? HTTPURLResponse else { throw DeepSeekConfigurationError.invalidResponse }
      guard (200...299).contains(response.statusCode) else {
        throw DeepSeekConfigurationError.requestFailed(statusCode: response.statusCode, message: deepSeekErrorMessage(from: data))
      }
      let responseBody = try JSONDecoder().decode(DeepSeekOutputResponse.self, from: data)
      guard let choice = responseBody.choices.first, let content = choice.message.content,
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .init(error: "模型没有返回正文，请重试。")
      }
      return .init(content: content, error: choice.finish_reason == "length" ? "输出达到长度上限，下面保留已返回的部分。" : nil)
    } catch {
      if Task.isCancelled { return .init(error: "已取消本侧请求。") }
      return .init(error: error.localizedDescription)
    }
  }

  private func mutateWorkspace(_ change: (inout PromptWorkspace) -> Void) {
    guard !isGeneratingPrompt, var workspace else { return }
    change(&workspace)
    self.workspace = workspace
    persistDraft()
  }

  private func persistDraft(markChanged: Bool = true, markdown: String? = nil) {
    guard let workspace, let repository else { return }
    do {
      // shortcut: per-edit writes suit local documents; debounce if profiling shows UI stalls.
      try repository.saveDraft(workspace)
      try saveMarkdownDraft(workspace, markdown: markdown)
      if markChanged { hasUnversionedChanges = try Self.hasChanges(workspace: workspace, repository: repository) }
    } catch {
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
    guard !isGeneratingPrompt, let workspace, var comparison, comparison.kind == .manual else { return }
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

  private func showCopyFeedback(_ feedback: String) {
    copyFeedback = feedback
    Task {
      try? await Task.sleep(nanoseconds: 1_600_000_000)
      if copyFeedback == feedback { copyFeedback = nil }
    }
  }

  private func report(_ error: Error) {
    errorMessage = error.localizedDescription
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
    "deepseek-flash",
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

  private func saveMarkdownDraft(_ workspace: PromptWorkspace, markdown: String? = nil) throws {
    let content = markdown ?? PromptMarkdown.renderAll(workspace.sections)
    freeformContent = content
    guard let documentURL else { return }
    try content.write(to: documentURL, atomically: true, encoding: .utf8)
  }

  private static func preserveSectionIDs(
    parsed: [PromptSection],
    existing: [PromptSection]
  ) -> [PromptSection] {
    var remaining = existing
    return parsed.enumerated().map { index, section in
      let match = remaining.firstIndex {
        $0.title == section.title && $0.isFreeform == section.isFreeform
      }
      let existingSection = match.map { remaining.remove(at: $0) }
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
    PromptDocumentStorage.versionURL(number, for: documentURL)
  }

  private static func writeVersionSnapshot(
    _ sections: [PromptSection],
    number: Int,
    beside documentURL: URL,
    requireNew: Bool
  ) throws {
    let url = versionFileURL(number: number, beside: documentURL)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !requireNew, FileManager.default.fileExists(atPath: url.path) { return }
    try Data(PromptMarkdown.renderAll(sections).utf8).write(to: url, options: .withoutOverwriting)
    guard requireNew else { return }
    do {
      let detached = try PromptDocumentStorage.detachedVersions(for: documentURL)
      if detached.contains(number) {
        try PromptDocumentStorage.setDetachedVersions(detached.subtracting([number]), for: documentURL)
      }
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  private var comparisonEditsURL: URL {
    databaseURL.deletingLastPathComponent().appendingPathComponent("comparison-edits.json")
  }

  func updateComparisonEdit(_ id: String, content: String) {
    guard !hasActiveAIRequest else { return }
    do {
      guard let source = try comparisonSources().first(where: { $0.id == id }) else {
        throw PromptIterationError.notFound("所选版本已不存在，请重新选择。")
      }
      var edits = comparisonEdits
      edits[id] = content == source.content ? nil : PromptComparisonEdit(content: content, updatedAt: Date())
      try saveComparisonEdits(edits)
    } catch { report(error) }
  }

  func discardComparisonEdit(_ id: String) {
    guard comparisonEdits[id] != nil else { return }
    do {
      var edits = comparisonEdits
      edits.removeValue(forKey: id)
      try saveComparisonEdits(edits)
    } catch { report(error) }
  }

  private func saveComparisonEdits(_ edits: [String: PromptComparisonEdit]) throws {
    let saved = PendingComparisonEdits(leftID: comparisonLeftID, rightID: comparisonRightID, edits: edits)
    try JSONEncoder().encode(saved).write(to: comparisonEditsURL, options: .atomic)
    comparisonEdits = edits
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
      return PromptDocumentStorage.databaseURL(for: documentURL)
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

private struct DeepSeekStreamChunk: Decodable {
  struct Choice: Decodable {
    struct Delta: Decodable { let content: String? }
    let delta: Delta
    let finish_reason: String?
  }

  let choices: [Choice]
}

private struct DeepSeekGeneratedSection: Decodable {
  let id: String
  let content: String
}

private struct DeepSeekOutputResponse: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable { let content: String? }
    let message: Message
    let finish_reason: String?
  }
  let choices: [Choice]
}

enum WorkspacePage {
  case generation
  case editor
  case history
  case settings
}

private struct DeepSeekSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var revealsAPIKey = false
  @State private var showsSaveToast = false
  @State private var saveToastMessage = ""
  @State private var saveToastTask: Task<Void, Never>?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Text("DeepSeek")
          .font(.title2.bold())
          .padding(.bottom, 20)

        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 18) {
          GridRow {
            Text("API Key")
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

          GridRow {
            Text("模型")
              .frame(width: 150, alignment: .leading)
            Text("V4.1 Flash")
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          GridRow {
            Text("接口地址")
              .frame(width: 150, alignment: .leading)
            TextField("https://api.deepseek.com", text: $model.deepSeekBaseURL)
              .textFieldStyle(.roundedBorder)
          }
        }

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
          Button("保存") {
            guard model.saveDeepSeekSettings() else { return }
            showSaveToast("参数配置已保存")
          }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 20)

        VStack(alignment: .leading, spacing: 8) {
          Text("AI 生成系统提示词")
            .font(.headline)
          TextEditor(text: $model.generationSystemPrompt)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
            .accessibilityLabel("AI 生成系统提示词")
            .onChange(of: model.generationSystemPrompt) { _ in showSaveToast("系统提示词已自动保存") }
        }
        .padding(.top, 40)
      }
      .frame(maxWidth: 700, alignment: .leading)
      .padding(.horizontal, 28)
      .padding(.vertical, 20)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .overlay(alignment: .top) {
      if showsSaveToast {
        Label(saveToastMessage, systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.medium))
          .foregroundStyle(.green)
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
          .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 6)
          .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
          .padding(.top, 14)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .onDisappear { saveToastTask?.cancel() }
  }

  private func showSaveToast(_ message: String) {
    saveToastTask?.cancel()
    saveToastMessage = message
    withAnimation { showsSaveToast = true }
    saveToastTask = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 2_000_000_000) }
      catch { return }
      withAnimation { showsSaveToast = false }
    }
  }
}

private enum ContentSheet: Identifiable {
  case optimization([PromptSection])

  var id: String {
    switch self {
    case .optimization: return "optimization"
    }
  }
}

struct PromptTrackedText {
  static let deletionKey = NSAttributedString.Key("promptDeletedText")
  let text: String
  let attributed: NSAttributedString

  init(baseline: String, text: String, showsChanges: Bool = true) {
    self.text = text
    let result = NSMutableAttributedString(string: "")
    func append(_ text: String, kind: PromptTextChange.Kind) {
      guard !text.isEmpty else { return }
      var attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
      ]
      if kind == .removed {
        attributes[Self.deletionKey] = true
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      } else if kind == .added {
        attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.18)
      }
      result.append(NSAttributedString(string: text, attributes: attributes))
    }
    let changes = PromptTextDifference.changes(from: showsChanges ? baseline : text, to: text)
    var index = 0
    while index < changes.count {
      let change = changes[index]
      if change.kind == .removed, index + 1 < changes.count, changes[index + 1].kind == .added {
        let before = Array(change.text)
        let after = Array(changes[index + 1].text)
        var prefix = 0
        var suffix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        while suffix < min(before.count, after.count) - prefix,
          before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        append(String(before.prefix(prefix)), kind: .unchanged)
        append(String(before[prefix..<(before.count - suffix)]), kind: .removed)
        append(String(after[prefix..<(after.count - suffix)]), kind: .added)
        append(String(before.suffix(suffix)), kind: .unchanged)
        index += 2
      } else {
        append(change.text, kind: change.kind)
        index += 1
      }
    }
    attributed = result
  }

  static func plainOffset(_ displayOffset: Int, in attributed: NSAttributedString) -> Int {
    var offset = 0
    attributed.enumerateAttribute(deletionKey, in: NSRange(location: 0, length: min(displayOffset, attributed.length))) { value, range, _ in
      if value == nil { offset += range.length }
    }
    return offset
  }

  static func cleanText(in attributed: NSAttributedString) -> String {
    var result = ""
    attributed.enumerateAttribute(deletionKey, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
      if value == nil { result += (attributed.string as NSString).substring(with: range) }
    }
    return result
  }

  func displayOffset(_ plainOffset: Int) -> Int {
    var remaining = plainOffset
    var offset = attributed.length
    attributed.enumerateAttribute(Self.deletionKey, in: NSRange(location: 0, length: attributed.length)) { value, range, stop in
      guard value == nil else { return }
      if remaining < range.length {
        offset = range.location + remaining
        stop.pointee = true
      } else { remaining -= range.length }
    }
    return offset
  }

  func replacing(_ range: NSRange, with replacement: String) -> (text: String, caret: Int) {
    let start = Self.plainOffset(range.location, in: attributed)
    let end = Self.plainOffset(NSMaxRange(range), in: attributed)
    return ((text as NSString).replacingCharacters(in: NSRange(location: start, length: end - start), with: replacement),
      start + replacement.utf16.count)
  }
}

private final class PromptTrackedTextView: NSTextView {
  let editingUndoManager = UndoManager()
  override var undoManager: UndoManager? { editingUndoManager }
  var isSettingMarkedText = false
  var onCommit: (() -> Void)?

  @objc func undo(_ sender: Any?) { editingUndoManager.undo() }
  @objc func redo(_ sender: Any?) { editingUndoManager.redo() }

  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(undo(_:)) { return editingUndoManager.canUndo }
    if menuItem.action == #selector(redo(_:)) { return editingUndoManager.canRedo }
    return super.validateMenuItem(menuItem)
  }

  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    isSettingMarkedText = true
    editingUndoManager.disableUndoRegistration()
    typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), .foregroundColor: NSColor.labelColor]
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    editingUndoManager.enableUndoRegistration()
    isSettingMarkedText = false
  }

  override func insertText(_ string: Any, replacementRange: NSRange) {
    let committingMarkedText = hasMarkedText()
    if committingMarkedText {
      isSettingMarkedText = true
      editingUndoManager.disableUndoRegistration()
    }
    super.insertText(string, replacementRange: replacementRange)
    if committingMarkedText {
      editingUndoManager.enableUndoRegistration()
      isSettingMarkedText = false
    }
    if !hasMarkedText() { onCommit?() }
  }
}

private struct PromptTrackedEditor: NSViewRepresentable {
  let baseline: String
  @Binding var text: String
  let showsChanges: Bool
  let isEditable: Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    let textView = PromptTrackedTextView()
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.drawsBackground = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainerInset = NSSize(width: 14, height: 14)
    textView.setAccessibilityLabel("右侧 Prompt 修改稿")
    textView.delegate = context.coordinator
    context.coordinator.textView = textView
    textView.onCommit = { [weak coordinator = context.coordinator] in coordinator?.commitMarkedText() }
    scrollView.documentView = textView
    context.coordinator.render()
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.textView?.isEditable = isEditable
    let presentation = PromptTrackedText(baseline: baseline, text: text, showsChanges: showsChanges)
    if context.coordinator.rendered?.attributed.isEqual(to: presentation.attributed) != true {
      context.coordinator.render()
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PromptTrackedEditor
    weak var textView: PromptTrackedTextView?
    var rendered: PromptTrackedText?

    init(_ parent: PromptTrackedEditor) { self.parent = parent }

    func render(caret: Int? = nil) {
      guard let textView, !textView.hasMarkedText() else { return }
      let selection = caret ?? rendered.map { PromptTrackedText.plainOffset(textView.selectedRange().location, in: $0.attributed) } ?? 0
      let presentation = PromptTrackedText(baseline: parent.baseline, text: parent.text, showsChanges: parent.showsChanges)
      rendered = presentation
      textView.textStorage?.setAttributedString(presentation.attributed)
      textView.setSelectedRange(NSRange(location: presentation.displayOffset(min(selection, parent.text.utf16.count)), length: 0))
      textView.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), .foregroundColor: NSColor.labelColor]
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
      guard let view = textView as? PromptTrackedTextView,
        !view.isSettingMarkedText, !view.hasMarkedText() else { return true }
      guard parent.isEditable, let rendered, let replacementString else { return false }
      let edit = rendered.replacing(range, with: replacementString)
      setText(edit.text, caret: edit.caret)
      return false
    }

    func textDidChange(_ notification: Notification) { commitMarkedText() }

    func commitMarkedText() {
      guard let textView, !textView.isSettingMarkedText, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
      let text = PromptTrackedText.cleanText(in: storage)
      let caret = PromptTrackedText.plainOffset(textView.selectedRange().location, in: storage)
      setText(text, caret: caret)
    }

    private func setText(_ text: String, caret: Int) {
      guard let textView else { return }
      let previous = parent.text
      if previous != text {
        let previousCaret = rendered.map { PromptTrackedText.plainOffset(textView.selectedRange().location, in: $0.attributed) } ?? 0
        textView.editingUndoManager.registerUndo(withTarget: self) { target in
          target.setText(previous, caret: previousCaret)
        }
        parent.text = text
      }
      render(caret: caret)
    }
  }
}

private struct ComparisonVersionAnchors: PreferenceKey {
  static var defaultValue: [Bool: Anchor<CGRect>] = [:]
  static func reduce(value: inout [Bool: Anchor<CGRect>], nextValue: () -> [Bool: Anchor<CGRect>]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @Binding var page: WorkspacePage
  let onRenamePrompt: (String) -> Void
  let onSaveGeneratedPrompt: (String) -> Void
  let onVersionsChanged: () -> Void
  let onOpenSettings: () -> Void
  @State private var pendingDeletion: PromptSection?
  @State private var promptName = ""
  @State private var hoveredSectionID: String?
  @State private var hoveredModuleAction: String?
  @State private var sectionDropTargetID: String?
  @State private var presentedSheet: ContentSheet?

  @State private var sources: [PromptComparisonSource] = []
  @State private var mode = "文字差异"
  @State private var input = ""
  @State private var expandedComparisonVersion: Bool?
  @State private var comparisonStandard: PromptComparisonSource?
  @State private var comparisonAcceptedText: [String: String] = [:]

  private var left: PromptComparisonSource {
    comparisonStandard ?? sources.first(where: { $0.id == model.comparisonLeftID })
      ?? .init(id: "draft", label: "工作稿", content: "")
  }
  private var right: PromptComparisonSource {
    let source = sources.first(where: { $0.id == model.comparisonRightID })
      ?? .init(id: "draft", label: "工作稿", content: "")
    let content = model.isGeneratingPrompt && source.id == "candidate" ? source.content : model.comparisonEdits[source.id]?.content ?? source.content
    return .init(id: source.id, label: source.label, content: content,
      updatedAt: model.comparisonEdits[source.id]?.updatedAt ?? source.updatedAt)
  }

  var body: some View {
    VStack(spacing: 0) {
      if page == .generation {
        generationPage
      } else if page == .editor || page == .history {
        promptWorkspace
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
    .overlay(alignment: .top) {
      if let feedback = model.copyFeedback {
        Label(feedback, systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.medium))
          .foregroundStyle(.green)
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
          .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 6)
          .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
          .padding(.top, 14)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.18), value: model.copyFeedback)
    .onAppear {
      input = model.outputComparison?.input ?? ""
      refreshSources()
      if model.showsComparison {
        comparisonStandard = sources.first(where: { $0.id == model.comparisonLeftID })
      }
    }
    .onChange(of: model.showsComparison) { shows in
      expandedComparisonVersion = nil
      refreshSources()
      if shows {
        comparisonStandard = sources.first(where: { $0.id == model.comparisonLeftID })
        comparisonAcceptedText.removeAll()
      }
    }
    .onChange(of: model.comparisonLeftID) { id in
      comparisonStandard = sources.first(where: { $0.id == id })
      comparisonAcceptedText.removeAll()
    }
    .onChange(of: model.workspace?.sections) { _ in refreshSources() }
    .onChange(of: model.comparison) { _ in refreshSources() }
    .onChange(of: model.versions) { _ in refreshSources(); onVersionsChanged() }
    .onChange(of: page) { page in
      expandedComparisonVersion = nil
      if page == .generation || page == .settings { model.cancelOutputComparison() }
    }
    .sheet(item: $presentedSheet) { sheet in
      switch sheet {
      case .optimization(let source):
        VStack(alignment: .leading, spacing: 14) {
          Text("本次优化要求").font(.title3.weight(.semibold))
          Text("例如：只调整输出格式，保留角色和教学目标。留空则整体优化。")
            .foregroundStyle(.secondary)
          TextEditor(text: $model.optimizationRequest)
            .font(.system(.body, design: .monospaced))
            .frame(height: 120)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .accessibilityLabel("本次优化要求")
          HStack {
            Text("结果进入 AI 参考稿，由你选择应用。").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("取消") { presentedSheet = nil }
              .keyboardShortcut(.cancelAction)
            Button("开始优化") {
              presentedSheet = nil
              model.generatePrompt(from: source) {
                comparisonAcceptedText.removeAll()
              }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
          }
        }
        .padding(24)
        .frame(width: 580)
      }
    }
  }

  private func openPromptComparison() {
    if model.showsComparison {
      model.cancelOutputComparison()
      model.showsComparison = false
    } else {
      model.openPromptComparison(version: page == .history ? model.selectedHistoryVersion?.number : nil)
    }
  }

  private func requestOptimization(_ sections: [PromptSection]) {
    if model.deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      onOpenSettings()
    } else {
      presentedSheet = .optimization(sections)
    }
  }

  private var generationPage: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        Text("生成结果").font(.title3.weight(.semibold))
        VStack(alignment: .leading, spacing: 12) {
          if model.generatedPrompt.isEmpty {
            VStack(spacing: 10) {
              Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.blue)
              Text(model.isCreatingPrompt ? "正在根据需求生成提示词…" : "输入需求后，在这里查看生成的提示词")
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            TextEditor(text: $model.generatedPrompt)
              .font(.system(.body, design: .monospaced))
              .scrollContentBackground(.hidden)
              .accessibilityLabel("生成的提示词")
              .disabled(model.isCreatingPrompt)
          }
          HStack {
            Spacer()
            Button("复制") { model.copyGeneratedPrompt() }
              .disabled(model.generatedPrompt.isEmpty)
            Button("保存为新 Prompt") { onSaveGeneratedPrompt(model.generatedPrompt) }
              .buttonStyle(.borderedProminent)
              .disabled(model.generatedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || model.isCreatingPrompt)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
      }
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      VStack(alignment: .leading, spacing: 12) {
        Text("描述你想做什么").font(.title3.weight(.semibold))
        VStack(spacing: 8) {
          TextEditor(text: $model.creationRequest)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(height: 100)
            .overlay(alignment: .topLeading) {
              if model.creationRequest.isEmpty {
                Text("说个大概即可，例如：帮我写一个适合小学语文老师的备课提示词。")
                  .font(.system(.body, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 5)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .accessibilityLabel("提示词需求描述")
            .help("描述你想创建的提示词的目标或角色")
            .disabled(model.isCreatingPrompt)
          HStack(spacing: 8) {
            if model.isCreatingPrompt {
              ProgressView().controlSize(.small)
              Button("取消", action: model.cancelPromptGeneration)
            }
            Spacer()
            Button(model.isCreatingPrompt ? "生成中…" : "生成 Prompt") {
              if model.deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onOpenSettings()
              } else {
                model.createPromptWithAI()
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isCreatingPrompt || model.isGeneratingPrompt
              || model.creationRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
      }
      .padding(20)
      .frame(maxWidth: .infinity)
    }
    .padding(14)
  }

  private var settingsPage: some View {
    DeepSeekSettingsView(model: model)
  }

  @ViewBuilder
  private var promptWorkspace: some View {
    if let workspace = model.workspace {
      VStack(alignment: .leading, spacing: 12) {
        if model.showsComparison && sources.count >= 2 {
          comparisonModePicker
        }
        HStack(alignment: .top, spacing: 16) {
          if page == .history, let version = model.selectedHistoryVersion {
            historyPane(version)
          } else {
            currentPane(workspace)
          }
          if model.showsComparison { comparisonPane }
        }
        if !model.showsComparison || mode == "文字差异" {
          let leftDate = model.showsComparison && sources.count >= 2
            ? (left.id.hasPrefix("version-") ? left.updatedAt : nil)
            : (page == .history
              ? model.selectedHistoryVersion.flatMap { model.editedAt(forVersion: $0.number) }
              : model.savedDraftEditedAt)
          let rightDate = model.showsComparison && sources.count >= 2 && right.id.hasPrefix("version-")
            ? sources.first(where: { $0.id == right.id && $0.content == right.content })?.updatedAt : nil
          let leftIsUnsaved = !model.showsComparison && page == .editor && model.draftVersionLabel == "工作稿"
          let rightIsUnsaved = model.showsComparison && sources.count >= 2 && rightDate == nil
          if leftDate != nil || rightDate != nil || leftIsUnsaved || rightIsUnsaved {
            HStack(spacing: 16) {
              lastEditedFooter(leftDate, showsUnsaved: leftIsUnsaved)
              if model.showsComparison { lastEditedFooter(rightDate, showsUnsaved: rightIsUnsaved) }
            }
          }
        }
        if model.showsComparison && sources.count >= 2 && mode == "效果对比" {
          comparisonControls
        }
      }
      .padding(14)
      .overlayPreferenceValue(ComparisonVersionAnchors.self) { anchors in
        GeometryReader { proxy in
          if let side = expandedComparisonVersion, let anchor = anchors[side] {
            let bounds = proxy[anchor]
            ZStack(alignment: .topLeading) {
              Color.clear.contentShape(Rectangle()).onTapGesture { expandedComparisonVersion = nil }
              comparisonVersionList(isLeft: side)
                .frame(width: max(bounds.width, 190))
                .offset(x: bounds.minX, y: bounds.maxY + 4)
            }
          }
        }
      }
      .onExitCommand { expandedComparisonVersion = nil }
    } else {
      emptyState
    }
  }

  private func lastEditedFooter(_ date: Date?, showsUnsaved: Bool = false) -> some View {
    Group {
      if let date {
        Text("最后编辑时间：\(formattedLastEdited(date))")
      } else if showsUnsaved {
        Text("未保存")
      } else {
        Color.clear.frame(height: 0)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.leading, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var comparisonPane: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        comparisonVersionPicker(isLeft: false)
        Spacer()
        Button { model.copyTestOutput(comparisonTextToCopy(isLeft: false)) } label: {
          Image(systemName: "doc.on.doc").frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(comparisonTextToCopy(isLeft: false).isEmpty)
        .help(mode == "效果对比" ? "复制右侧模型输出" : "复制右侧 Prompt")
        Button(action: openPromptComparison) {
          Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.hasActiveAIRequest)
        .help("关闭对比")
        .accessibilityLabel("关闭对比")
      }
      .frame(height: 40)
      .padding(.horizontal, 13)
      .background(Color(nsColor: .controlBackgroundColor))
      Divider()
      if sources.count < 2 {
        VStack(spacing: 14) {
          Image(systemName: "rectangle.split.2x1").font(.system(size: 32)).foregroundStyle(.secondary)
          Text("还没有可对比的版本").font(.headline)
          Text("保存当前工作稿为 V1，或用 AI 优化生成参考稿后，再查看差异。")
            .foregroundStyle(.secondary)
          HStack(spacing: 12) {
            Button("保存为 V1") { model.saveVersion() }
              .buttonStyle(.borderedProminent)
              .disabled(model.hasActiveAIRequest)
            Button("AI 优化") { requestOptimization(model.workspace?.sections ?? []) }
              .disabled(model.hasActiveAIRequest || model.freeformContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        comparisonPromptBody(isLeft: false)
        if mode == "文字差异" {
          HStack {
            if model.isGeneratingPrompt {
              ProgressView().controlSize(.small)
              Button("取消优化", action: model.cancelPromptGeneration)
            } else {
              Button("AI 优化") {
                do {
                  requestOptimization(try model.sectionsForComparisonSource(right.id, editedContent: model.comparisonEdits[right.id]?.content))
                } catch { model.errorMessage = error.localizedDescription }
              }
              .disabled(model.hasActiveAIRequest || right.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .help("仅优化右侧 \(right.label)，结果显示在右侧 AI 参考稿")
            }
            Spacer()
            Button("应用") {
              if model.applyComparisonSource(right.id, editedContent: model.comparisonEdits[right.id]?.content) {
                model.comparisonRightID = "draft"
                refreshSources()
                comparisonAcceptedText["draft"] = right.content
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.hasActiveAIRequest)
            Button(model.versions.isEmpty ? "保存为 V1" : "保存为新版本") {
              model.saveVersion(sourceID: right.id, editedContent: model.comparisonEdits[right.id]?.content)
            }
            .disabled(model.hasActiveAIRequest || right.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          .padding(12)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(right.id == "draft" ? Color.blue : Color(nsColor: .separatorColor), lineWidth: right.id == "draft" ? 2 : 1)
    }
  }

  private func comparisonVersionPicker(isLeft: Bool) -> some View {
    let source = isLeft ? left : right
    return Button {
      expandedComparisonVersion = expandedComparisonVersion == isLeft ? nil : isLeft
    } label: {
      HStack(spacing: 6) {
        Text(model.workspace?.name ?? "Prompt 项目")
          .font(.headline).foregroundStyle(source.id == "draft" ? Color.blue : Color.primary).lineLimit(1)
        versionBadge(source.label)
        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
      }
      .frame(height: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.hasActiveAIRequest || sources.count < 2)
    .anchorPreference(key: ComparisonVersionAnchors.self, value: .bounds) { [isLeft: $0] }
    .accessibilityLabel(isLeft ? "左侧 Prompt 版本" : "右侧 Prompt 版本")
    .accessibilityValue(source.label)
  }

  private func comparisonVersionList(isLeft: Bool) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(sources) { option in
          Button {
            if isLeft { model.comparisonLeftID = option.id }
            else { model.comparisonRightID = option.id }
            comparisonAcceptedText.removeAll()
            expandedComparisonVersion = nil
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                if let date = (isLeft ? nil : model.comparisonEdits[option.id]?.updatedAt) ?? option.updatedAt {
                  Text(formattedPromptTime(date))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
              }
              Spacer()
              if option.id == (isLeft ? model.comparisonLeftID : model.comparisonRightID) {
                Image(systemName: "checkmark").foregroundStyle(.blue)
              }
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.vertical, 4)
    }
    .frame(height: min(CGFloat(sources.count) * 48 + 8, 288))
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
  }

  @ViewBuilder
  private func comparisonPromptBody(isLeft: Bool) -> some View {
    if mode == "文字差异" {
      if isLeft {
        ScrollView {
          Text(left.content)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        PromptTrackedEditor(
          baseline: comparisonAcceptedText[right.id] ?? left.content,
          text: Binding(get: { right.content }, set: {
            model.updateComparisonEdit(model.comparisonRightID, content: $0)
          }),
          showsChanges: comparisonAcceptedText[right.id] != right.content,
          isEditable: !model.hasActiveAIRequest
        )
        .id(right.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else if let run = model.outputComparison {
      resultPane(source: isLeft ? run.left : run.right,
        result: isLeft ? run.leftResult : run.rightResult,
        isRunning: isLeft ? run.leftIsRunning : run.rightIsRunning)
    } else {
      Text("填写测试输入后，查看模型输出。")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var comparisonControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      if mode == "效果对比" {
        Text("测试输入").font(.headline)
        VStack(spacing: 8) {
          TextEditor(text: $input)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(height: 90)
            .accessibilityLabel("效果对比测试输入")
            .disabled(model.isComparingOutputs)
          HStack {
            Spacer()
            Text("DeepSeek V4.1 Flash")
              .font(.caption).foregroundStyle(.secondary)
            if model.isComparingOutputs {
              ProgressView().controlSize(.small)
              Button("取消运行", action: model.cancelOutputComparison)
            } else {
              Button("运行效果对比") {
                if model.deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  onOpenSettings()
                } else {
                  model.comparePromptOutputs(left: left, right: right, input: input)
                }
              }
              .buttonStyle(.borderedProminent)
              .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (left.id == right.id && left.content == right.content) || left.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || right.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || model.isGeneratingPrompt || model.isCreatingPrompt)
            }
          }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
        if let run = model.outputComparison {
          if run.left != left || run.right != right || run.input != input {
            Text("上方为上次运行结果；版本或输入已更改，重新运行后更新。")
              .font(.caption).foregroundStyle(.orange)
          }
          DisclosureGroup("本次运行的测试输入") {
            ScrollView { Text(run.input).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
              .frame(maxHeight: 80)
          }
          .font(.caption)
        }
      }
    }
  }

  private var comparisonModePicker: some View {
    HStack(spacing: 12) {
      Picker("对比方式", selection: $mode) {
        Text("文字差异").tag("文字差异")
        Text("效果对比").tag("效果对比")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      if mode == "文字差异" {
        if comparisonAcceptedText[right.id] == right.content {
          Text("已应用到工作稿").foregroundStyle(.secondary)
        } else if left.content == right.content {
          Text("两个 Prompt 内容相同").foregroundStyle(.secondary)
        }
      }
      Spacer()
    }
    .font(.caption)
  }

  private func refreshSources() {
    do {
      let previousCount = sources.count
      sources = try model.comparisonSources()
      if model.showsComparison && (!sources.contains(where: { $0.id == model.comparisonLeftID })
        || !sources.contains(where: { $0.id == model.comparisonRightID })
        || (previousCount < 2 && sources.count >= 2 && model.comparisonLeftID == model.comparisonRightID)) {
        model.openPromptComparison()
      }
    } catch { model.errorMessage = error.localizedDescription }
  }

  private func resultPane(source: PromptComparisonSource, result: PromptOutputResult, isRunning: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("本次运行：\(source.label)").font(.caption).foregroundStyle(.secondary)
        Spacer()
        if isRunning { ProgressView().controlSize(.small) }
      }
      if let error = result.error {
        Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
      }
      ScrollView {
        Text(result.content.isEmpty ? (isRunning ? "正在运行…" : "未返回正文") : result.content)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func comparisonTextToCopy(isLeft: Bool) -> String {
    if mode == "效果对比" {
      return (isLeft ? model.outputComparison?.leftResult.content : model.outputComparison?.rightResult.content) ?? ""
    }
    return isLeft ? left.content : right.content
  }

  private func historyPane(_ version: VersionSummary) -> some View {
    let isDraft = model.showsComparison && sources.count >= 2 && left.id == "draft"
    return VStack(alignment: .leading, spacing: 10) {
      VStack(spacing: 0) {
        HStack(spacing: 6) {
          if model.showsComparison && sources.count >= 2 {
            comparisonVersionPicker(isLeft: true)
          } else {
            Text(model.workspace?.name ?? "Prompt 项目").font(.headline).lineLimit(1)
            versionBadge("V\(version.number)")
          }
          Spacer()
          if !model.showsComparison {
            Button("对比", action: openPromptComparison)
              .buttonStyle(.plain)
              .help("查看文字差异，或对比同一输入下的模型输出")
              .disabled(model.hasActiveAIRequest)
          }
          if !model.showsComparison || sources.count < 2 {
            if model.isGeneratingPrompt { Button("取消", action: model.cancelPromptGeneration) }
            Button {
              requestOptimization(model.selectedHistorySections)
            } label: {
              Text(model.isGeneratingPrompt ? "优化中" : "AI 优化")
                .frame(height: 28)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isGeneratingPrompt || model.isCreatingPrompt || model.isComparingOutputs)
          }

          Button {
            if model.showsComparison && sources.count >= 2 { model.copyTestOutput(comparisonTextToCopy(isLeft: true)) }
            else { model.copySelectedHistory() }
          } label: {
            Image(systemName: "doc.on.doc")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(model.showsComparison && sources.count >= 2 && comparisonTextToCopy(isLeft: true).isEmpty)
          .help(model.showsComparison && mode == "效果对比" ? "复制左侧模型输出" : "复制完整 Prompt")
        }
        .foregroundStyle(Color.primary)
        .frame(height: 40)
        .padding(.horizontal, 8)
        .padding(.leading, 5)
        .background(Color(nsColor: .controlBackgroundColor))

        Divider()

        if model.showsComparison && sources.count >= 2 {
          comparisonPromptBody(isLeft: true)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(model.selectedHistorySections) { section in
                VStack(alignment: .leading, spacing: 12) {
                  if !section.isFreeform {
                    HStack(spacing: 10) {
                      Text("#")
                        .font(.headline.monospaced())
                        .foregroundStyle(.blue)
                      Text(section.title).font(.headline)
                    }
                  }
                  Text(section.content.isEmpty ? "该栏目无内容" : section.content)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(section.content.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                }
                .padding(.top, 6)
                .padding(.bottom, 14)
                if section.id != model.selectedHistorySections.last?.id {
                  Divider().padding(.vertical, 6)
                }
              }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(isDraft ? Color.blue : Color(nsColor: .separatorColor), lineWidth: isDraft ? 2 : 1)
      }

    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func currentPane(_ workspace: PromptWorkspace) -> some View {
    let isDraft = model.showsComparison && sources.count >= 2 ? left.id == "draft" : model.draftVersionLabel == "工作稿"
    return VStack(alignment: .leading, spacing: 10) {
      VStack(spacing: 0) {
        HStack(spacing: 6) {
          if model.showsComparison && sources.count >= 2 {
            comparisonVersionPicker(isLeft: true)
          } else {
            Text(promptName.isEmpty ? "Prompt 名称" : promptName)
              .font(.headline)
              .lineLimit(1)
              .hidden()
              .overlay(alignment: .leading) {
                TextField("Prompt 名称", text: $promptName) { editing in
                  if !editing { onRenamePrompt(promptName) }
                }
                .textFieldStyle(.plain)
                .font(.headline)
                .foregroundStyle(isDraft ? Color.blue : Color.primary)
                .accessibilityLabel("Prompt 名称")
              }
              .onAppear { promptName = workspace.name }
              .onChange(of: model.documentURL) { _ in
                promptName = model.workspace?.name ?? ""
              }
              .onSubmit { onRenamePrompt(promptName) }
            versionBadge(model.draftVersionLabel)
          }
          Spacer()
          if !model.showsComparison {
            Button("对比", action: openPromptComparison)
              .buttonStyle(.plain)
              .help("查看文字差异，或对比同一输入下的模型输出")
              .disabled(model.hasActiveAIRequest)
          }
          if !model.showsComparison || sources.count < 2 {
            Button {
              model.toggleFramework()
            } label: {
              Text("框架")
                .frame(height: 28)
                .padding(.horizontal, 6)
                .background(
                  model.usesFramework
                    ? Color.blue.opacity(0.12)
                    : Color.clear,
                  in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isGeneratingPrompt)
            .accessibilityValue(model.usesFramework ? "已开启" : "已关闭")
            .help(model.usesFramework ? "关闭框架，直接编辑正文" : "开启提示词框架")
            if model.isGeneratingPrompt { Button("取消", action: model.cancelPromptGeneration) }
            Button {
              requestOptimization(workspace.sections)
            } label: {
              Text(model.isGeneratingPrompt ? "优化中" : "AI 优化")
                .frame(height: 28)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.blue)
            .disabled(model.isGeneratingPrompt || model.isCreatingPrompt || model.isComparingOutputs)
            .help(model.isGeneratingPrompt ? "优化中" : "AI 优化")
          }

          Button {
            if model.showsComparison && sources.count >= 2 { model.copyTestOutput(comparisonTextToCopy(isLeft: true)) }
            else { model.copyFullPrompt() }
          } label: {
            Image(systemName: "doc.on.doc")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(model.showsComparison && sources.count >= 2 && comparisonTextToCopy(isLeft: true).isEmpty)
          .help(model.showsComparison && mode == "效果对比" ? "复制左侧模型输出" : "复制完整 Prompt")
        }
        .foregroundStyle(Color.primary)
        .frame(height: 40)
        .padding(.horizontal, 8)
        .padding(.leading, 5)
        .background(Color(nsColor: .controlBackgroundColor))

        Divider()

        if model.showsComparison && sources.count >= 2 {
          comparisonPromptBody(isLeft: true)
        } else if !model.usesFramework {
          TextEditor(text: Binding(
            get: { model.freeformContent },
            set: model.updateFreeformContent
          ))
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(12)
          .disabled(model.isGeneratingPrompt)
          .accessibilityLabel("Prompt 正文")
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(workspace.sections) { section in
                currentSectionEditor(section)
                if section.id != workspace.sections.last?.id {
                  Divider().padding(.vertical, 6)
                }
              }
              Button("新增维度") { model.addSection() }
                .disabled(model.isGeneratingPrompt)
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
        if !model.showsComparison {
          HStack {
            Spacer()
            Button(model.versions.isEmpty ? "保存为 V1" : "保存为新版本") { model.saveVersion() }
              .disabled(model.hasActiveAIRequest || PromptMarkdown.render(workspace.sections).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          .padding(12)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(isDraft ? Color.blue : Color(nsColor: .separatorColor), lineWidth: isDraft ? 2 : 1)
      }

    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func versionBadge(_ label: String) -> some View {
    Text(label)
      .font(.caption.weight(.semibold).monospacedDigit())
      .foregroundStyle(label == "工作稿" ? Color.blue : Color.primary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(label == "工作稿" ? Color.blue.opacity(0.1) : Color.primary.opacity(0.06), in: Capsule())
      .fixedSize()
  }

  private func currentSectionEditor(_ section: PromptSection) -> some View {
    let isHovered = hoveredSectionID == section.id
    return VStack(alignment: .leading, spacing: 6) {
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
          moduleActionButton(
            id: "\(section.id)-clear",
            title: "清空",
            systemImage: "eraser"
          ) {
            model.updateContent(sectionID: section.id, content: "")
          }
          moduleActionButton(
            id: "\(section.id)-visibility",
            title: section.isIncluded ? "隐藏" : "显示",
            systemImage: section.isIncluded ? "eye" : "eye.slash"
          ) {
            model.toggleSectionInclusion(section.id)
          }
          moduleActionButton(
            id: "\(section.id)-delete",
            title: "删除模块",
            systemImage: "trash",
            role: .destructive
          ) {
            pendingDeletion = section
          }
        }
        .padding(.leading, 8)
      }
      .frame(minHeight: 36)
      .onHover { hovering in
        if hovering {
          hoveredSectionID = section.id
        } else if hoveredSectionID == section.id {
          hoveredSectionID = nil
        }
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
      .frame(minHeight: 80)
    }
    .disabled(model.isGeneratingPrompt)
    .padding(.top, 6)
    .padding(.bottom, 14)
    .opacity(section.isIncluded ? 1 : 0.48)
    .animation(.easeOut(duration: 0.14), value: isHovered)
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

  private func moduleActionButton(
    id: String,
    title: String,
    systemImage: String,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(role: role, action: action) {
      Image(systemName: systemImage)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .top) {
      if hoveredModuleAction == id {
        Text(title)
          .font(.caption2)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().stroke(.separator))
          .fixedSize()
          .offset(y: -28)
          .allowsHitTesting(false)
      }
    }
    .onHover { hovering in
      if hovering {
        hoveredModuleAction = id
      } else if hoveredModuleAction == id {
        hoveredModuleAction = nil
      }
    }
    .help(title)
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

  private func formattedLastEdited(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月d日 ah:mm"
    return formatter.string(from: date)
  }

}
