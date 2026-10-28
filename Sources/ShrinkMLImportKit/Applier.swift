import Darwin
import Foundation

public struct ApplyHooks: @unchecked Sendable {
  /// Called after every step of the commit with the step's name. A test throws from it to simulate an
  /// import that was interrupted at exactly that point.
  public var afterStep: ((String) throws -> Void)?

  public init(afterStep: ((String) throws -> Void)? = nil) { self.afterStep = afterStep }
}

public struct ApplyResult: Equatable, Sendable {
  public let imported: [PlannedModel]
  /// Generated files written (created or replaced).
  public let wrote: [String]
  /// `.new` files written beside files you changed.
  public let newFiles: [String]
  public static let nothing = ApplyResult(imported: [], wrote: [], newFiles: [])
}

/// An exclusive lock on `.shrinkml/import.lock`, so two imports never run in one folder at once.
final class ImportLock {
  private var descriptor: Int32 = -1

  init(root: URL) throws {
    try SafeFS.ensureDirectory(root, ".shrinkml")
    let path = root.appendingPathComponent(".shrinkml/import.lock").path
    descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if descriptor >= 0 { close(descriptor) }
      descriptor = -1
      throw ImportRefusal("import_running", Say(
        "另一個匯入正在這個資料夾裡執行（或鎖檔打不開）。等它結束再試，沒有改任何東西。",
        "Another import is running in this folder (or the lock file cannot be opened). Wait for it and try again; nothing was changed."))
    }
  }

  deinit {
    if descriptor >= 0 {
      flock(descriptor, LOCK_UN)
      close(descriptor)
    }
  }
}

public enum ImportApplier {
  /// Applies a plan. Everything is built and checked in `.shrinkml/staging/` first; only then are
  /// folders moved into place, generated files written (a file you changed is never overwritten), and,
  /// last of all, `shrinkml.lock.json` is replaced in one rename. If anything fails before that last
  /// step the lock is exactly what it was, nothing of yours was touched, and running the import again
  /// is safe and finishes the job.
  public static func apply(_ plan: ImportPlan, options: ImportOptions, hooks: ApplyHooks = ApplyHooks()) throws -> ApplyResult {
    guard plan.hasChanges else { return .nothing }
    let root = options.packageDirectory.resolvingSymlinksInPath()
    try SafeFS.refuseLinkedShrinkmlFolder(root)
    let guardLock = try ImportLock(root: root)
    _ = guardLock

    // The folder must still be what the plan was made from.
    let nowLock = try SafeFS.readRegular(root, ImportPlanner.lockFileName)
    guard nowLock == plan.lockExistedWithBytes else {
      throw ImportRefusal("lock_changed", Say(
        "shrinkml.lock.json 在預覽之後被改過了。請重新預覽再匯入，沒有改任何東西。",
        "shrinkml.lock.json changed after the preview. Preview again and then import; nothing was changed."))
    }
    // The Inbox is where a person drops the zips; it is made so that it is there to be found.
    if options.inboxIsDefault { try SafeFS.ensureDirectory(root, "Inbox") }
    // A staging folder left by an import that was killed is ours to clear: we hold the lock.
    if SafeFS.kind(of: root.appendingPathComponent(".shrinkml/staging")) == .directory {
      for name in (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".shrinkml/staging").path)) ?? [] {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".shrinkml/staging/\(name)"))
      }
    }

    let stage = try StagingArea(packageDirectory: root)
    defer { stage.remove() }

    // Stage: read each archive again, writing as we go, and require it to be what the preview saw.
    for inspection in plan.inspections {
      let url = options.inboxDirectory.appendingPathComponent(inspection.archive.filename)
      let reread = try ArchiveReader.read(url, identity: nil, limits: options.limits, stage: stage)
      guard reread.archive == inspection.archive, reread.members == inspection.members else {
        throw ImportRefusal("archive_changed", Say(
          "「\(inspection.archive.filename)」在預覽之後變了；沒有匯入，也沒有改任何東西。",
          "\"\(inspection.archive.filename)\" changed after the preview; it was not imported and nothing was changed."))
      }
      try stage.verify(reread.members, model: inspection.name)
    }

    var step = 0
    func done(_ name: String) throws {
      step += 1
      try hooks.afterStep?(name)
    }

    // 1. Remember which generated texts we are about to write, so an interrupted run is recognised as ours.
    let newHashes = plan.generated.map(\.sha256)
    let pending = CanonicalJSON.bytes(.object(["sha256": .array(Set(newHashes).sorted().map(JSONValue.string))]))
    try SafeFS.writeAtomically(root, ImportPlanner.pendingFileName, pending)
    try done("pending")

    // 2. Folders from the staging area.
    let orphanId = UUID().uuidString.prefix(8).lowercased()
    func placeAside(_ relative: String, as label: String) throws {
      guard SafeFS.kind(of: root.appendingPathComponent(relative)) != nil else { return }
      // Something is already where a new revision goes, and no lock entry owns it (an interrupted import,
      // or yours): it is moved to .shrinkml/orphans, never deleted.
      try SafeFS.ensureDirectory(root, ".shrinkml/orphans")
      let aside = root.appendingPathComponent(".shrinkml/orphans/\(orphanId)-\(label)")
      guard rename(root.appendingPathComponent(relative).path, aside.path) == 0 else {
        throw SafeFS.refusal("write_failed", "「\(relative)」已經在那裡，也移不開。", "\"\(relative)\" is already there and could not be moved aside.")
      }
    }
    for inspection in plan.inspections {
      let model = plan.newLock.model(named: inspection.name)!
      let resources = stage.directory(.resources, model: inspection.name)
      if SafeFS.kind(of: resources) == .directory {
        try placeAside(model.resourceDirectory, as: "\(model.name)-r\(model.revision)-resources")
        try SafeFS.moveIntoPlace(resources, root, model.resourceDirectory)
        try done("resources:\(model.name)")
      }
      let records = stage.directory(.records, model: inspection.name)
      if SafeFS.kind(of: records) == .directory {
        try placeAside(model.recordDirectory, as: "\(model.name)-r\(model.revision)-records")
        try SafeFS.moveIntoPlace(records, root, model.recordDirectory)
        try done("records:\(model.name)")
      }
      // Overrides/ is yours: created once, with a note, only if it is not there; never touched again.
      if SafeFS.kind(of: root.appendingPathComponent(model.overridesDirectory)) == nil {
        try SafeFS.writeAtomically(
          root, "\(model.overridesDirectory)/Overrides.swift", Data(Generators.overridesPlaceholder(name: model.name).utf8))
        try done("overrides:\(model.name)")
      }
      let runtime = stage.directory(.runtime, model: inspection.name)
      if plan.installsRuntime, SafeFS.kind(of: runtime) == .directory {
        if SafeFS.kind(of: root.appendingPathComponent(".shrinkml/runtime")) != nil {
          try SafeFS.ensureDirectory(root, ".shrinkml/previous-runtime")
          let aside = root.appendingPathComponent(".shrinkml/previous-runtime/\(orphanId)")
          guard rename(root.appendingPathComponent(".shrinkml/runtime").path, aside.path) == 0 else {
            throw SafeFS.refusal("write_failed", "舊的 runtime 移不開。", "The old runtime could not be moved aside.")
          }
        }
        try SafeFS.moveIntoPlace(runtime, root, ".shrinkml/runtime")
        try done("runtime:\(model.name)")
      }
    }

    // 3. Generated files, by the rule: yours is never overwritten.
    var wrote: [String] = []
    var newFiles: [String] = []
    for change in plan.generated {
      guard let data = plan.contents[change.path] else { continue }
      switch change.decision {
      case .create, .replace:
        try SafeFS.writeAtomically(root, change.path, data)
        wrote.append(change.path)
        try done("generated:\(change.path)")
      case .unchanged:
        break
      case .keepYoursWriteNew(let newPath):
        if try SafeFS.readRegular(root, newPath).map({ SHA256Hex.of($0) }) != change.sha256 {
          try SafeFS.writeAtomically(root, newPath, plan.contents[newPath] ?? data)
        }
        newFiles.append(newPath)
        try done("new:\(newPath)")
      }
    }

    // 4. The lock, last, in one rename.
    try SafeFS.writeAtomically(root, ImportPlanner.lockFileName, LockCodec.canonicalBytes(of: plan.newLock), sync: true)
    try done("lock")

    // 5. Tidy up.
    try? FileManager.default.removeItem(at: root.appendingPathComponent(ImportPlanner.pendingFileName))
    return ApplyResult(imported: plan.models, wrote: wrote, newFiles: newFiles)
  }
}
