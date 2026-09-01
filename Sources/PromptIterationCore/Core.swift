import Foundation
import SQLite3

public enum PromptIterationError: LocalizedError, Equatable {
  case validation(String)
  case notFound(String)
  case database(String)

  public var errorDescription: String? {
    switch self {
    case .validation(let message), .notFound(let message), .database(let message):
      return message
    }
  }
}

public struct PromptSection: Identifiable, Equatable, Sendable {
  public let id: String
  public var title: String
  public var content: String
  public var position: Int
  public var isIncluded: Bool

  public init(
    id: String,
    title: String,
    content: String = "",
    position: Int,
    isIncluded: Bool = true
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.position = position
    self.isIncluded = isIncluded
  }

  public static func defaults() -> [PromptSection] {
    [
      "角色与定位", "任务目标", "背景与上下文", "输入与变量",
      "意图识别与澄清", "工作流程", "工具使用", "输出要求",
      "质量标准", "约束与禁止事项", "异常与兜底", "示例",
    ].enumerated().map { index, title in
      PromptSection(
        id: UUID().uuidString.lowercased(),
        title: title,
        position: index
      )
    }
  }
}

public enum PromptMarkdown {
  public static func render(_ sections: [PromptSection]) -> String {
    renderSections(sections.filter(\.isIncluded))
  }

  public static func renderAll(_ sections: [PromptSection]) -> String {
    renderSections(sections)
  }

  private static func renderSections(_ sections: [PromptSection]) -> String {
    sections
      .compactMap { section in
        let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = section.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !content.isEmpty else { return nil }
        return [title.isEmpty ? "" : "# \(title)", content]
          .filter { !$0.isEmpty }
          .joined(separator: "\n")
      }
      .joined(separator: "\n\n")
  }

  public static func parse(_ markdown: String) -> [PromptSection] {
    var parsed: [(title: String, content: [String])] = []
    var currentTitle: String?
    var currentContent: [String] = []

    func appendCurrent() {
      guard let currentTitle else { return }
      parsed.append((currentTitle, currentContent))
    }

    for line in markdown.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#"), !trimmed.hasPrefix("##") {
        let title = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        if !title.isEmpty {
          appendCurrent()
          currentTitle = title
          currentContent = []
          continue
        }
      }
      if currentTitle != nil { currentContent.append(line) }
    }
    appendCurrent()

    if parsed.isEmpty {
      var sections = PromptSection.defaults()
      let content = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
      if !content.isEmpty { sections[0].content = content }
      return sections
    }

    return parsed.enumerated().map { index, item in
      PromptSection(
        id: UUID().uuidString.lowercased(),
        title: item.title,
        content: item.content.joined(separator: "\n")
          .trimmingCharacters(in: .whitespacesAndNewlines),
        position: index
      )
    }
  }

  public static func isStructuredPrompt(_ markdown: String) -> Bool {
    let defaultTitles = Set(PromptSection.defaults().map(\.title))
    let headings: Set<String> = Set(markdown.components(separatedBy: .newlines).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#"), !trimmed.hasPrefix("##") else { return nil }
      let title = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
      return title.isEmpty ? nil : title
    })
    return headings.intersection(defaultTitles).count >= 3
  }
}

public enum ComparisonStatus: String, Sendable {
  case pending
  case accepted
  case rejected
  case userModified = "user_modified"
}

public struct ComparisonSection: Identifiable, Equatable, Sendable {
  public var id: String { sectionID }
  public let sectionID: String
  public var title: String
  public var content: String
  public var position: Int
  public var status: ComparisonStatus

  public init(
    sectionID: String,
    title: String,
    content: String,
    position: Int,
    status: ComparisonStatus = .pending
  ) {
    self.sectionID = sectionID
    self.title = title
    self.content = content
    self.position = position
    self.status = status
  }
}

public enum ComparisonKind: String, Sendable {
  case manual
  case history
}

public struct ComparisonSnapshot: Equatable, Sendable {
  public var kind: ComparisonKind
  public var sourceVersion: Int?
  public var sections: [ComparisonSection]

  public init(kind: ComparisonKind, sourceVersion: Int?, sections: [ComparisonSection]) {
    self.kind = kind
    self.sourceVersion = sourceVersion
    self.sections = sections
  }
}

public struct PromptWorkspace: Identifiable, Equatable, Sendable {
  public let id: String
  public var name: String
  public var currentVersion: Int
  public var sections: [PromptSection]

  public init(id: String, name: String, currentVersion: Int, sections: [PromptSection]) {
    self.id = id
    self.name = name
    self.currentVersion = currentVersion
    self.sections = sections
  }
}

public struct VersionSummary: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let number: Int
  public let note: String
  public let createdAt: String

  public init(id: Int64, number: Int, note: String, createdAt: String) {
    self.id = id
    self.number = number
    self.note = note
    self.createdAt = createdAt
  }
}

public enum WorkspaceActions {
  public static func apply(
    sectionID: String,
    current: inout [PromptSection],
    comparison: inout [ComparisonSection]
  ) throws {
    guard let proposalIndex = comparison.firstIndex(where: { $0.sectionID == sectionID }) else {
      throw PromptIterationError.notFound("未找到对比栏目。")
    }
    let proposal = comparison[proposalIndex]
    if let currentIndex = current.firstIndex(where: { $0.id == sectionID }) {
      current[currentIndex].content = proposal.content
    } else {
      current.append(
        PromptSection(
          id: proposal.sectionID,
          title: proposal.title,
          content: proposal.content,
          position: current.count
        )
      )
    }
    comparison[proposalIndex].status = .accepted
  }

  public static func reject(
    sectionID: String,
    comparison: inout [ComparisonSection]
  ) throws {
    guard let index = comparison.firstIndex(where: { $0.sectionID == sectionID }) else {
      throw PromptIterationError.notFound("未找到对比栏目。")
    }
    comparison[index].status = .rejected
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum SQLiteValue {
  case integer(Int64)
  case text(String)
  case null
}

private final class SQLiteStatement {
  private let database: OpaquePointer
  private var statement: OpaquePointer?

  init(database: OpaquePointer, sql: String) throws {
    self.database = database
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw PromptIterationError.database(String(cString: sqlite3_errmsg(database)))
    }
  }

  deinit { sqlite3_finalize(statement) }

  func bind(_ values: [SQLiteValue]) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .integer(let number):
        result = sqlite3_bind_int64(statement, index, number)
      case .text(let text):
        result = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
      case .null:
        result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else {
        throw PromptIterationError.database(String(cString: sqlite3_errmsg(database)))
      }
    }
  }

  func step() throws -> Int32 {
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW || result == SQLITE_DONE else {
      throw PromptIterationError.database(String(cString: sqlite3_errmsg(database)))
    }
    return result
  }

  func text(_ column: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: pointer)
  }

  func optionalText(_ column: Int32) -> String? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
  }

  func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
  func optionalInt(_ column: Int32) -> Int? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(column)
  }
  func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
}

private func execute(
  _ database: OpaquePointer,
  _ sql: String,
  _ values: [SQLiteValue] = []
) throws {
  let statement = try SQLiteStatement(database: database, sql: sql)
  try statement.bind(values)
  guard try statement.step() == SQLITE_DONE else {
    throw PromptIterationError.database("SQLite 写入未完成。")
  }
}

public final class WorkspaceRepository {
  public let databaseURL: URL

  private static let schema = """
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL CHECK(length(trim(name)) > 0),
        current_version INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS draft_sections (
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        section_id TEXT NOT NULL,
        title TEXT NOT NULL CHECK(length(trim(title)) > 0),
        content TEXT NOT NULL DEFAULT '',
        position INTEGER NOT NULL,
        is_included INTEGER NOT NULL DEFAULT 1 CHECK(is_included IN (0, 1)),
        PRIMARY KEY(project_id, section_id),
        UNIQUE(project_id, position)
    );
    CREATE TABLE IF NOT EXISTS versions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        version_number INTEGER NOT NULL CHECK(version_number > 0),
        note TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        UNIQUE(project_id, version_number)
    );
    CREATE TABLE IF NOT EXISTS version_sections (
        version_id INTEGER NOT NULL REFERENCES versions(id) ON DELETE CASCADE,
        section_id TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        position INTEGER NOT NULL,
        is_included INTEGER NOT NULL DEFAULT 1 CHECK(is_included IN (0, 1)),
        PRIMARY KEY(version_id, section_id),
        UNIQUE(version_id, position)
    );
    CREATE TABLE IF NOT EXISTS comparisons (
        project_id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
        source_type TEXT NOT NULL CHECK(source_type IN ('manual', 'history')),
        source_version INTEGER,
        updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS comparison_sections (
        project_id TEXT NOT NULL REFERENCES comparisons(project_id) ON DELETE CASCADE,
        section_id TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        position INTEGER NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('pending', 'accepted', 'rejected', 'user_modified')),
        PRIMARY KEY(project_id, section_id),
        UNIQUE(project_id, position)
    );
    PRAGMA user_version = 2;
    """

  public init(databaseURL: URL) throws {
    self.databaseURL = databaseURL.standardizedFileURL
    try FileManager.default.createDirectory(
      at: self.databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try withConnection { database in
      try executeScript(database, Self.schema)
      try Self.migrate(database)
      try executeScript(database, "PRAGMA journal_mode = WAL;")
    }
  }

  public static func defaultDatabaseURL() -> URL {
    if let custom = ProcessInfo.processInfo.environment["PROMPT_ITERATION_DB"], !custom.isEmpty {
      return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath)
    }
    let support =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.homeDirectoryForCurrentUser
    return
      support
      .appendingPathComponent("Prompt Iteration Assistant", isDirectory: true)
      .appendingPathComponent("prompt-iteration.db")
  }

  public func loadOrCreateWorkspace() throws -> PromptWorkspace {
    if let workspace = try firstWorkspace() { return workspace }
    let id = UUID().uuidString.lowercased()
    let timestamp = utcNow()
    let sections = PromptSection.defaults()
    try withConnection(write: true) { database in
      try execute(
        database,
        "INSERT INTO projects(id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
        [.text(id), .text("System Prompt"), .text(timestamp), .text(timestamp)]
      )
      try insertDraftSections(database, projectID: id, sections: sections)
    }
    return PromptWorkspace(id: id, name: "System Prompt", currentVersion: 0, sections: sections)
  }

  public func saveDraft(_ workspace: PromptWorkspace) throws {
    let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw PromptIterationError.validation("Prompt 名称不能为空。")
    }
    try validateSections(workspace.sections)
    try withConnection(write: true) { database in
      try ensureProject(database, projectID: workspace.id)
      try execute(
        database,
        "UPDATE projects SET name = ?, updated_at = ? WHERE id = ?",
        [.text(name), .text(utcNow()), .text(workspace.id)]
      )
      try execute(
        database, "DELETE FROM draft_sections WHERE project_id = ?", [.text(workspace.id)])
      try insertDraftSections(
        database, projectID: workspace.id, sections: normalized(workspace.sections))
    }
  }

  @discardableResult
  public func saveVersion(workspace: PromptWorkspace, note: String = "") throws -> VersionSummary {
    try validateSections(workspace.sections)
    return try withConnection(write: true) { database in
      try ensureProject(database, projectID: workspace.id)
      let number = try scalarInt(
        database,
        "SELECT COALESCE(MAX(version_number), 0) + 1 FROM versions WHERE project_id = ?",
        [.text(workspace.id)]
      )
      let timestamp = utcNow()
      try execute(
        database,
        "INSERT INTO versions(project_id, version_number, note, created_at) VALUES (?, ?, ?, ?)",
        [.text(workspace.id), .integer(Int64(number)), .text(note), .text(timestamp)]
      )
      let versionID = sqlite3_last_insert_rowid(database)
      for section in normalized(workspace.sections) {
        try execute(
          database,
          """
          INSERT INTO version_sections(version_id, section_id, title, content, position, is_included)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
          [
            .integer(versionID), .text(section.id), .text(section.title),
            .text(section.content), .integer(Int64(section.position)),
            .integer(section.isIncluded ? 1 : 0),
          ]
        )
      }
      try execute(
        database,
        "UPDATE projects SET current_version = ?, updated_at = ? WHERE id = ?",
        [.integer(Int64(number)), .text(timestamp), .text(workspace.id)]
      )
      return VersionSummary(id: versionID, number: number, note: note, createdAt: timestamp)
    }
  }

  public func listVersions(projectID: String) throws -> [VersionSummary] {
    try withConnection { database in
      try ensureProject(database, projectID: projectID)
      let statement = try SQLiteStatement(
        database: database,
        sql: """
          SELECT id, version_number, note, created_at
          FROM versions WHERE project_id = ? ORDER BY version_number DESC
          """
      )
      try statement.bind([.text(projectID)])
      var versions: [VersionSummary] = []
      while try statement.step() == SQLITE_ROW {
        versions.append(
          VersionSummary(
            id: statement.int64(0),
            number: statement.int(1),
            note: statement.text(2),
            createdAt: statement.text(3)
          )
        )
      }
      return versions
    }
  }

  public func deleteVersion(projectID: String, number: Int) throws {
    try withConnection(write: true) { database in
      try ensureProject(database, projectID: projectID)
      let count = try scalarInt(
        database,
        "SELECT COUNT(*) FROM versions WHERE project_id = ? AND version_number = ?",
        [.text(projectID), .integer(Int64(number))]
      )
      guard count == 1 else {
        throw PromptIterationError.notFound("未找到版本 V\(number)。")
      }
      try execute(
        database,
        "DELETE FROM versions WHERE project_id = ? AND version_number = ?",
        [.text(projectID), .integer(Int64(number))]
      )
      let latest = try scalarInt(
        database,
        "SELECT COALESCE(MAX(version_number), 0) FROM versions WHERE project_id = ?",
        [.text(projectID)]
      )
      try execute(
        database,
        "UPDATE projects SET current_version = ?, updated_at = ? WHERE id = ?",
        [.integer(Int64(latest)), .text(utcNow()), .text(projectID)]
      )
    }
  }

  public func versionSections(projectID: String, number: Int) throws -> [PromptSection] {
    try withConnection { database in
      let count = try scalarInt(
        database,
        "SELECT COUNT(*) FROM versions WHERE project_id = ? AND version_number = ?",
        [.text(projectID), .integer(Int64(number))]
      )
      guard count == 1 else {
        throw PromptIterationError.notFound("未找到版本 V\(number)。")
      }
      let statement = try SQLiteStatement(
        database: database,
        sql: """
          SELECT s.section_id, s.title, s.content, s.position, s.is_included
          FROM version_sections s
          JOIN versions v ON v.id = s.version_id
          WHERE v.project_id = ? AND v.version_number = ?
          ORDER BY s.position
          """
      )
      try statement.bind([.text(projectID), .integer(Int64(number))])
      return try readPromptSections(statement)
    }
  }

  public func restoreVersionAsDraft(
    workspace: PromptWorkspace,
    number: Int
  ) throws -> PromptWorkspace {
    var restored = workspace
    restored.sections = try versionSections(projectID: workspace.id, number: number)
    try saveDraft(restored)
    return restored
  }

  public func saveComparison(projectID: String, snapshot: ComparisonSnapshot) throws {
    try withConnection(write: true) { database in
      try ensureProject(database, projectID: projectID)
      try execute(database, "DELETE FROM comparisons WHERE project_id = ?", [.text(projectID)])
      try execute(
        database,
        """
        INSERT INTO comparisons(project_id, source_type, source_version, updated_at)
        VALUES (?, ?, ?, ?)
        """,
        [
          .text(projectID), .text(snapshot.kind.rawValue),
          snapshot.sourceVersion.map { .integer(Int64($0)) } ?? .null,
          .text(utcNow()),
        ]
      )
      for section in snapshot.sections.sorted(by: { $0.position < $1.position }) {
        try execute(
          database,
          """
          INSERT INTO comparison_sections(
              project_id, section_id, title, content, position, status
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
          [
            .text(projectID), .text(section.sectionID), .text(section.title),
            .text(section.content), .integer(Int64(section.position)),
            .text(section.status.rawValue),
          ]
        )
      }
    }
  }

  public func loadComparison(projectID: String) throws -> ComparisonSnapshot? {
    try withConnection { database in
      let header = try SQLiteStatement(
        database: database,
        sql: "SELECT source_type, source_version FROM comparisons WHERE project_id = ?"
      )
      try header.bind([.text(projectID)])
      guard try header.step() == SQLITE_ROW else { return nil }
      guard let kind = ComparisonKind(rawValue: header.text(0)) else {
        throw PromptIterationError.database("对比来源类型无效。")
      }
      let sourceVersion = header.optionalInt(1)
      let rows = try SQLiteStatement(
        database: database,
        sql: """
          SELECT section_id, title, content, position, status
          FROM comparison_sections WHERE project_id = ? ORDER BY position
          """
      )
      try rows.bind([.text(projectID)])
      var sections: [ComparisonSection] = []
      while try rows.step() == SQLITE_ROW {
        guard let status = ComparisonStatus(rawValue: rows.text(4)) else {
          throw PromptIterationError.database("对比栏目状态无效。")
        }
        sections.append(
          ComparisonSection(
            sectionID: rows.text(0),
            title: rows.text(1),
            content: rows.text(2),
            position: rows.int(3),
            status: status
          )
        )
      }
      return ComparisonSnapshot(kind: kind, sourceVersion: sourceVersion, sections: sections)
    }
  }

  public func clearComparison(projectID: String) throws {
    try withConnection(write: true) { database in
      try execute(database, "DELETE FROM comparisons WHERE project_id = ?", [.text(projectID)])
    }
  }

  private func firstWorkspace() throws -> PromptWorkspace? {
    try withConnection { database in
      let statement = try SQLiteStatement(
        database: database,
        sql: "SELECT id, name, current_version FROM projects ORDER BY updated_at DESC LIMIT 1"
      )
      guard try statement.step() == SQLITE_ROW else { return nil }
      let projectID = statement.text(0)
      let sectionsStatement = try SQLiteStatement(
        database: database,
        sql: """
          SELECT section_id, title, content, position, is_included
          FROM draft_sections WHERE project_id = ? ORDER BY position
          """
      )
      try sectionsStatement.bind([.text(projectID)])
      return PromptWorkspace(
        id: projectID,
        name: statement.text(1),
        currentVersion: statement.int(2),
        sections: try readPromptSections(sectionsStatement)
      )
    }
  }

  private func readPromptSections(_ statement: SQLiteStatement) throws -> [PromptSection] {
    var sections: [PromptSection] = []
    while try statement.step() == SQLITE_ROW {
      sections.append(
        PromptSection(
          id: statement.text(0),
          title: statement.text(1),
          content: statement.text(2),
          position: statement.int(3),
          isIncluded: statement.int(4) == 1
        )
      )
    }
    return sections
  }

  private func insertDraftSections(
    _ database: OpaquePointer,
    projectID: String,
    sections: [PromptSection]
  ) throws {
    for section in normalized(sections) {
      try execute(
        database,
        """
        INSERT INTO draft_sections(project_id, section_id, title, content, position, is_included)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
          .text(projectID), .text(section.id), .text(section.title),
          .text(section.content), .integer(Int64(section.position)),
          .integer(section.isIncluded ? 1 : 0),
        ]
      )
    }
  }

  private func validateSections(_ sections: [PromptSection]) throws {
    guard Set(sections.map(\.id)).count == sections.count else {
      throw PromptIterationError.validation("栏目 ID 不能重复。")
    }
    guard sections.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else {
      throw PromptIterationError.validation("栏目名称不能为空。")
    }
  }

  private func normalized(_ sections: [PromptSection]) -> [PromptSection] {
    sections.enumerated().map { index, section in
      PromptSection(
        id: section.id,
        title: section.title.trimmingCharacters(in: .whitespacesAndNewlines),
        content: section.content,
        position: index,
        isIncluded: section.isIncluded
      )
    }
  }

  private static func migrate(_ database: OpaquePointer) throws {
    for table in ["draft_sections", "version_sections"] {
      let statement = try SQLiteStatement(database: database, sql: "PRAGMA table_info(\(table))")
      var hasColumn = false
      while try statement.step() == SQLITE_ROW {
        if statement.text(1) == "is_included" { hasColumn = true }
      }
      if !hasColumn {
        try execute(
          database,
          "ALTER TABLE \(table) ADD COLUMN is_included INTEGER NOT NULL DEFAULT 1 CHECK(is_included IN (0, 1))"
        )
      }
    }
    try execute(database, "PRAGMA user_version = 2")
  }

  private func ensureProject(_ database: OpaquePointer, projectID: String) throws {
    let count = try scalarInt(
      database,
      "SELECT COUNT(*) FROM projects WHERE id = ?",
      [.text(projectID)]
    )
    guard count == 1 else {
      throw PromptIterationError.notFound("未找到 Prompt 项目。")
    }
  }

  private func scalarInt(
    _ database: OpaquePointer,
    _ sql: String,
    _ values: [SQLiteValue] = []
  ) throws -> Int {
    let statement = try SQLiteStatement(database: database, sql: sql)
    try statement.bind(values)
    guard try statement.step() == SQLITE_ROW else {
      throw PromptIterationError.database("查询没有返回结果。")
    }
    return statement.int(0)
  }

  private func withConnection<T>(
    write: Bool = false,
    _ operation: (OpaquePointer) throws -> T
  ) throws -> T {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
      let database
    else {
      let message =
        database.map { String(cString: sqlite3_errmsg($0)) }
        ?? "无法打开数据库。"
      if let database { sqlite3_close(database) }
      throw PromptIterationError.database("数据库操作失败：\(message)")
    }
    defer { sqlite3_close(database) }
    do {
      try executeScript(database, "PRAGMA foreign_keys = ON;")
      sqlite3_busy_timeout(database, 10_000)
      if write { try execute(database, "BEGIN IMMEDIATE") }
      let result = try operation(database)
      if write { try execute(database, "COMMIT") }
      return result
    } catch {
      if write { try? execute(database, "ROLLBACK") }
      if let known = error as? PromptIterationError { throw known }
      throw PromptIterationError.database("数据库操作失败：\(error.localizedDescription)")
    }
  }

  private func executeScript(_ database: OpaquePointer, _ sql: String) throws {
    var errorPointer: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
      let message =
        errorPointer.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(errorPointer)
      throw PromptIterationError.database(message)
    }
  }

  private func utcNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }
}
