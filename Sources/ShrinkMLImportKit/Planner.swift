import Foundation

public struct ImportOptions: Sendable {
  public var packageDirectory: URL
  public var inboxDirectory: URL
  /// true when no inbox was named: the folder is `<package>/Inbox`, which an import then makes if it is missing.
  public var inboxIsDefault: Bool
  /// Where a LOCAL checkout of the import package lives, as it should be written into Package.swift (for
  /// development). nil keeps what an existing Package.swift already remembers; with nothing remembered the
  /// manifest depends on `publicRepository` instead.
  public var importPackagePath: String?
  /// The address a `Package.swift` depends on when no `importPackagePath` is given or remembered.
  public var publicRepository: PublicRepository
  public var limits: ZipLimits
  /// With `--add`: the one file name the import looks at in the Inbox (and the record that sits beside it).
  /// Every other file in the folder is left alone and not read. nil, the default, looks at the whole folder.
  public var onlyArchive: String?
  public var now: @Sendable () -> Date

  public init(
    packageDirectory: URL, inboxDirectory: URL? = nil, importPackagePath: String? = nil,
    publicRepository: PublicRepository = .current,
    limits: ZipLimits = .modelBundle, onlyArchive: String? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.packageDirectory = packageDirectory
    self.inboxDirectory = inboxDirectory ?? packageDirectory.appendingPathComponent("Inbox", isDirectory: true)
    self.inboxIsDefault = inboxDirectory == nil
    self.importPackagePath = importPackagePath
    self.publicRepository = publicRepository
    self.limits = limits
    self.onlyArchive = onlyArchive
    self.now = now
  }
}

/// What happened to one file in the Inbox.
public struct ArchiveReport: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case imports(name: String, revision: Int, isNewModel: Bool)
    case alreadyCurrent(name: String, revision: Int)
    case alreadyImportedEarlier(name: String, revision: Int, current: Int)
    case sameBytesAs(String)
    case refused(ImportRefusal)
    case ignored(Say)
  }

  public let filename: String
  public let sha256: String?
  public let outcome: Outcome
}

/// One file the importer writes that is not copied from an archive, and what it will do about it.
public struct GeneratedChange: Equatable, Sendable {
  public enum Decision: Equatable, Sendable {
    case create
    /// The file is exactly what the last import wrote, so it is replaced.
    case replace
    case unchanged
    /// You changed it (or it was never ours): it stays, the new text goes to this path.
    case keepYoursWriteNew(String)
  }

  public let path: String
  public let decision: Decision
  public let sha256: String
}

/// What changes between the current revision of a model and the one being imported, by file.
public struct RevisionDiff: Equatable, Sendable {
  public let added: [String]
  public let changed: [String]
  public let removed: [String]
  public let unchanged: [String]
}

public struct PlannedModel: Equatable, Sendable {
  public let name: String
  public let revision: Int
  public let previousRevision: Int?
  public let road: String
  public let diff: RevisionDiff?
}

public struct ImportPlan: Sendable {
  public let archives: [ArchiveReport]
  public let models: [PlannedModel]
  public let generated: [GeneratedChange]
  public let warnings: [Say]
  public let currentLock: Lock
  public let newLock: Lock
  /// The package has no lock yet: this import creates it.
  public let createsPackage: Bool

  let inspections: [Inspection]
  let contents: [String: Data]
  let installsRuntime: Bool
  let runtimeTreeSHA256: String?
  let lockExistedWithBytes: Data?

  public var refusals: [ArchiveReport] {
    archives.filter { if case .refused = $0.outcome { return true } else { return false } }
  }

  /// Would applying this plan write anything?
  public var hasChanges: Bool {
    !inspections.isEmpty || createsPackage
  }
}

public enum ImportPlanner {
  public static let lockFileName = "shrinkml.lock.json"
  static let pendingFileName = ".shrinkml/pending.json"

  // MARK: Lock

  public static func readLock(in packageDirectory: URL) throws -> (lock: Lock, bytes: Data?) {
    guard let bytes = try SafeFS.readRegular(packageDirectory, lockFileName) else { return (.empty, nil) }
    let result = LockValidator.validate(bytes)
    guard let lock = result.lock else {
      let first = result.violations.prefix(3).map { "\($0.location)：\($0.say.zh)" }.joined(separator: "\n  ")
      let firstEn = result.violations.prefix(3).map { "\($0.location): \($0.say.en)" }.joined(separator: "\n  ")
      throw ImportRefusal(
        "lock_invalid",
        Say(
          "shrinkml.lock.json 不合規則（\(result.violations.count) 處），匯入停止，沒有改任何東西：\n  \(first)",
          "shrinkml.lock.json breaks the rules (\(result.violations.count) place(s)); the import stopped and changed nothing:\n  \(firstEn)"))
    }
    return (lock, bytes)
  }

  static func pendingHashes(in packageDirectory: URL) -> Set<String> {
    guard let data = try? SafeFS.readRegular(packageDirectory, pendingFileName),
      let json = try? StrictJSON.parse(data), let list = json["sha256"]?.arrayValue
    else { return [] }
    return Set(list.compactMap(\.stringValue).filter(SHA256Hex.isValid))
  }

  // MARK: Plan

  public static func plan(_ options: ImportOptions) throws -> ImportPlan {
    let root = options.packageDirectory.resolvingSymlinksInPath()
    guard SafeFS.kind(of: root) == .directory else {
      throw ImportRefusal(
        "package_missing",
        Say(
          "找不到資料夾「\(root.path)」。第一次匯入請加 --apply --create，它會建立這個資料夾。",
          "The folder \"\(root.path)\" does not exist. For a first import add --apply --create, which creates it."))
    }
    try SafeFS.refuseLinkedShrinkmlFolder(root)
    let (lock, lockBytes) = try readLock(in: root)
    let pending = pendingHashes(in: root)

    // The Inbox.
    var reports: [ArchiveReport] = []
    var candidates: [(url: URL, identity: ArchiveIdentity)] = []
    let inboxKind = SafeFS.kind(of: options.inboxDirectory)
    if inboxKind == .directory {
      let names = try FileManager.default.contentsOfDirectory(atPath: options.inboxDirectory.path).sorted()
      var identified: [(name: String, url: URL, identity: ArchiveIdentity)] = []
      for name in names {
        let url = options.inboxDirectory.appendingPathComponent(name)
        if name.hasPrefix(".") || name.lowercased().hasSuffix(".sha256") { continue }
        if let only = options.onlyArchive, name != only, name != PackageFlavourFile.companionName(for: only) { continue }
        // The saved answer of the swift-package route belongs to the zip beside it, never an archive itself.
        if PackageFlavourFile.isCompanion(name) {
          let zipName = String(name.dropLast(PackageFlavourFile.companionSuffix.count))
          if !names.contains(zipName) {
            reports.append(ArchiveReport(filename: name, sha256: nil, outcome: .ignored(Say(
              "旁邊沒有 \(zipName)，這個 swift-package 回應沒有用上。",
              "There is no \(zipName) beside it, so this swift-package reply was not used."))))
          }
          continue
        }
        guard name.lowercased().hasSuffix(".zip") else {
          reports.append(ArchiveReport(filename: name, sha256: nil, outcome: .ignored(Say("不是 .zip 檔，略過。", "Not a .zip file; skipped."))))
          continue
        }
        guard SafeFS.kind(of: url) == .file else {
          reports.append(ArchiveReport(filename: name, sha256: nil, outcome: .ignored(Say("是連結或資料夾，不是普通檔案，略過。", "A link or a folder, not a plain file; skipped."))))
          continue
        }
        if looksLikeASecret(name) {
          reports.append(ArchiveReport(filename: name, sha256: nil, outcome: .refused(ImportRefusal("filename_secret", Say(
            "這個檔名看起來像金鑰或帶簽章的網址；檔名會被記進 lock 檔，而 lock 檔絕不存這種東西。請改檔名。",
            "This file name looks like a key or a signed link; the name is recorded in the lock file, which never stores such things. Rename the file.")))))
          continue
        }
        do {
          identified.append((name, url, try ArchiveReader.identity(of: url)))
        } catch {
          reports.append(ArchiveReport(filename: name, sha256: nil, outcome: .refused(ImportRefusal("archive_unreadable", Say("讀不了這個檔案。", "Could not read this file.")))))
        }
      }
      // The same bytes under two names (a browser's "Beans (1).zip") are one hand-over. The plainest
      // name wins, because the file name becomes the model name: the shortest name the model would get,
      // then the first in sorted order. The others are reported, not imported.
      for group in Dictionary(grouping: identified, by: { $0.identity.sha256 }).values.sorted(by: { $0[0].name < $1[0].name }) {
        let ranked = group.sorted { lhs, rhs in
          let (left, right) = (ArchiveReader.suggestedName(forFilename: lhs.name), ArchiveReader.suggestedName(forFilename: rhs.name))
          return left.count != right.count ? left.count < right.count : lhs.name < rhs.name
        }
        candidates.append((ranked[0].url, ranked[0].identity))
        for other in ranked.dropFirst() {
          reports.append(ArchiveReport(filename: other.name, sha256: other.identity.sha256, outcome: .sameBytesAs(ranked[0].name)))
        }
      }
      candidates.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    // Which archives are new, which are known.
    var inspections: [Inspection] = []
    for (url, identity) in candidates {
      var bringsANewRecord = false
      if let model = lock.models.first(where: { $0.archive.sha256 == identity.sha256 }) {
        // The same zip is current, unless a record of the swift-package route sits beside it that the
        // lock does not hold yet: then it is the next revision (the Swift file arrives with it). Taking a
        // record away again undoes nothing.
        if model.kind == .coremlBundle, let record = PackageFlavourFile.companionSHA256(for: url),
          !model.files.contains(where: {
            $0.role == .record && $0.path == "\(model.recordDirectory)/\(PackageFlavourFile.memberName)" && $0.sha256 == record
          })
        {
          bringsANewRecord = true
        } else {
          reports.append(ArchiveReport(filename: url.lastPathComponent, sha256: identity.sha256, outcome: .alreadyCurrent(name: model.name, revision: model.revision)))
          continue
        }
      }
      if !bringsANewRecord, let earlier = lock.models.flatMap({ model in model.previousRevisions.map { (model, $0) } }).first(where: { $0.1.archive.sha256 == identity.sha256 }) {
        reports.append(ArchiveReport(filename: url.lastPathComponent, sha256: identity.sha256, outcome: .alreadyImportedEarlier(name: earlier.0.name, revision: earlier.1.revision, current: earlier.0.revision)))
        continue
      }
      let expected: String?
      do {
        expected = try expectedDigest(next: url)
      } catch let refusal as ImportRefusal {
        reports.append(ArchiveReport(filename: url.lastPathComponent, sha256: identity.sha256, outcome: .refused(refusal)))
        continue
      }
      do {
        let inspection = try ArchiveReader.read(url, identity: identity, expectedSHA256: expected, limits: options.limits)
        inspections.append(inspection)
      } catch let refusal as ImportRefusal {
        // The bare Pipeline Bundle of an invoice hand-over is not a failure: the developer kit holds it.
        let outcome: ArchiveReport.Outcome = refusal.code == "bare_pipeline_bundle" ? .ignored(refusal.say) : .refused(refusal)
        reports.append(ArchiveReport(filename: url.lastPathComponent, sha256: identity.sha256, outcome: outcome))
      }
    }

    // Names: acceptable, not taken by a different road, not claimed twice in this run.
    var accepted: [Inspection] = []
    var claimed: [String: Inspection] = [:]
    let byName = Dictionary(grouping: inspections, by: { PathKey.key($0.name) })
    for inspection in inspections.sorted(by: { $0.name < $1.name }) {
      func refuse(_ refusal: ImportRefusal) {
        reports.append(ArchiveReport(filename: inspection.archive.filename, sha256: inspection.archive.sha256, outcome: .refused(refusal)))
      }
      if let problem = ModelName.problem(in: inspection.name) {
        refuse(ImportRefusal("name_invalid", Say(
          "這個檔案的名稱會變成模型名稱「\(inspection.name)」，但它不行（\(problem.rawValue)）。請把檔案改個英文名字再放進 Inbox，例如 Beans.zip。",
          "This file's name would become the model name \"\(inspection.name)\", which is not allowed (\(problem.rawValue)). Rename the file to a plain name such as Beans.zip and drop it in the Inbox again.")))
        continue
      }
      if byName[PathKey.key(inspection.name)]!.count > 1 {
        refuse(ImportRefusal("name_claimed_twice", Say(
          "Inbox 裡有不只一個不同的交付會變成模型「\(inspection.name)」。不猜哪個比較新：請只留一個，或改檔名。",
          "More than one different hand-over in the Inbox would become the model \"\(inspection.name)\". Which is newer is not guessed: keep one, or rename a file.")))
        continue
      }
      if let existing = lock.models.first(where: { PathKey.key($0.name) == PathKey.key(inspection.name) }) {
        if existing.name != inspection.name {
          refuse(ImportRefusal("name_case", Say(
            "已經有模型「\(existing.name)」，這個檔案的名稱只差大小寫（\(inspection.name)）。請改檔名。",
            "A model \"\(existing.name)\" already exists and this file's name differs only by case (\(inspection.name)). Rename the file.")))
          continue
        }
        if existing.kind != inspection.kind || existing.road != inspection.road {
          refuse(ImportRefusal("model_name_taken", Say(
            "模型「\(existing.name)」已經是另一條路（\(existing.road)）的模型，這個交付是 \(inspection.road)。請改檔名，免得兩個模型互相覆蓋。",
            "The model \"\(existing.name)\" is already on another road (\(existing.road)) and this hand-over is \(inspection.road). Rename the file so that two models do not replace one another.")))
          continue
        }
      }
      claimed[inspection.name] = inspection
      accepted.append(inspection)
    }

    // Types: one valid Swift type per Core ML model, which is neither another model's type nor the
    // name of another model's module (`import ShrinkMLModels` brings every model in at once).
    func typeOf(_ model: LockedModel) -> String? { model.kind == .coremlBundle ? TypeName.derive(from: model.name) : nil }
    var typed: [Inspection] = []
    for inspection in accepted {
      func refuse(_ code: String, _ zh: String, _ en: String) {
        reports.append(ArchiveReport(filename: inspection.archive.filename, sha256: inspection.archive.sha256, outcome: .refused(ImportRefusal(code, Say(zh, en)))))
      }
      let name = inspection.name
      if let type = inspection.typeName {
        if let problem = TypeName.problem(in: type) {
          refuse(
            "type_name_invalid",
            "這個檔案的名稱會讓模型的 Swift 型別變成「\(type)」，但 Swift 檔的路徑不收這種型別名稱（\(problem.rawValue)）。請把檔案改個名字再放進 Inbox，例如 Beans.zip。",
            "This file's name would give the model the Swift type \"\(type)\", which the swift-package route does not accept (\(problem.rawValue)). Rename the file to a plain name such as Beans.zip and drop it in the Inbox again.")
          continue
        }
        if let other = accepted.first(where: { $0.name != name && $0.typeName == type }) {
          refuse(
            "type_name_clash",
            "「\(inspection.archive.filename)」和「\(other.archive.filename)」都會用 Swift 型別 \(type)；一個套件裡兩個模型不能用同一個型別名稱。不猜哪個要改：請改其中一個的檔名。",
            "\"\(inspection.archive.filename)\" and \"\(other.archive.filename)\" would both use the Swift type \(type); two models in one package cannot share a type name. Which one to rename is not guessed: rename one of the files.")
          continue
        }
        if let existing = lock.models.first(where: { $0.name != name && typeOf($0) == type }) {
          refuse(
            "type_name_clash",
            "已經匯入的模型「\(existing.name)」用了 Swift 型別 \(type)，這個檔案（模型「\(name)」）也會用它。已匯入的沒有動；請改這個檔案的檔名。",
            "The imported model \"\(existing.name)\" already uses the Swift type \(type), and this file (the model \"\(name)\") would use it too. The imported one was left alone; rename this file.")
          continue
        }
        if accepted.contains(where: { $0.name == type && $0.name != name }) || lock.models.contains(where: { $0.name == type && $0.name != name }) {
          refuse(
            "type_name_clash",
            "這個模型的 Swift 型別會是「\(type)」，而「\(type)」已經是另一個模型的 module 名稱；型別和 module 同名會讓 module 自己的名字被蓋住。請改這個檔案的檔名。",
            "This model's Swift type would be \"\(type)\", which is already the module name of another model; a type named like a module hides the module's own name. Rename this file.")
          continue
        }
      }
      if let existing = lock.models.first(where: { $0.name != name && typeOf($0) == name }) {
        refuse(
          "type_name_clash",
          "這個檔案的 module 名稱「\(name)」就是已匯入模型「\(existing.name)」的 Swift 型別名稱；型別和 module 同名會讓 module 自己的名字被蓋住。已匯入的沒有動；請改這個檔案的檔名。",
          "This file's module name \"\(name)\" is the Swift type of the imported model \"\(existing.name)\"; a type named like a module hides the module's own name. The imported one was left alone; rename this file.")
        continue
      }
      typed.append(inspection)
    }
    accepted = typed

    // One Swift runtime at a time (v0.2).
    var runtimeTree: String? = lock.models.first(where: { $0.kind == .pipelineKit })?.runtime?.treeSHA256
    var runtimeOwner: String? = lock.models.first(where: { $0.kind == .pipelineKit })?.name
    var final: [Inspection] = []
    for inspection in accepted {
      guard inspection.kind == .pipelineKit, let kit = inspection.kit else {
        final.append(inspection)
        continue
      }
      if let tree = runtimeTree, let owner = runtimeOwner, tree != kit.runtimeTreeSHA256, owner != inspection.name {
        reports.append(ArchiveReport(filename: inspection.archive.filename, sha256: inspection.archive.sha256, outcome: .refused(ImportRefusal(
          "runtime_conflict", Say(
            "這個發票交付附的 runtime 和「\(owner)」用的不是同一份；目前一個專案只能放一份 runtime。沒有匯入。",
            "This invoice hand-over carries a different runtime from the one \"\(owner)\" uses; one project can hold one runtime for now. Not imported.")))))
        continue
      }
      runtimeTree = kit.runtimeTreeSHA256
      runtimeOwner = inspection.name
      final.append(inspection)
    }
    // A saved swift-package reply beside an invoice kit is not used: say so, once.
    var kitWarnings: [Say] = []
    for inspection in final where inspection.kind == .pipelineKit {
      let companion = PackageFlavourFile.companionName(for: inspection.archive.filename)
      if SafeFS.kind(of: options.inboxDirectory.appendingPathComponent(companion)) != nil {
        kitWarnings.append(Say(
          "\(companion) 放在發票交付旁邊，沒有用上：套件版 Swift 檔（swift-package.json）只屬於 Core ML 模型的交付；發票讀取用的是 runtime，不是它。",
          "\(companion) sits beside an invoice hand-over and was not used: the package flavour of the Swift file (swift-package.json) belongs to Core ML model hand-overs only; the invoice reader works through the runtime."))
      }
    }
    for inspection in final {
      let existing = lock.model(named: inspection.name)
      reports.append(ArchiveReport(
        filename: inspection.archive.filename, sha256: inspection.archive.sha256,
        outcome: .imports(name: inspection.name, revision: (existing?.revision ?? 0) + 1, isNewModel: existing == nil)))
    }
    reports.sort { $0.filename < $1.filename }

    // The new lock.
    let timestamp = timestampString(options.now())
    var models = lock.models
    var planned: [PlannedModel] = []
    var contents: [String: Data] = [:]
    var perModelGenerated: [String: [GeneratedChange]] = [:]
    var perModelGeneratedEntries: [String: [TrackedFile]] = [:]
    var warnings: [Say] = kitWarnings

    for inspection in final.sorted(by: { $0.name < $1.name }) {
      let existing = lock.model(named: inspection.name)
      let revision = (existing?.revision ?? 0) + 1
      let prefix = [Destination.resources: "Sources/\(inspection.name)/Resources/r\(revision)", .records: "Records/\(inspection.name)/r\(revision)"]
      var files: [RecordedFile] = []
      for member in inspection.members where member.destination != .runtime {
        files.append(RecordedFile(path: prefix[member.destination]! + "/" + member.relativePath, sha256: member.sha256, sizeBytes: member.size, role: member.role!))
      }
      var previous = existing?.previousRevisions ?? []
      var diff: RevisionDiff?
      if let existing {
        previous.append(PreviousRevision(revision: existing.revision, archive: existing.archive, files: existing.files, importedAt: existing.importedAt))
        diff = revisionDiff(old: existing, newFiles: files, newRevision: revision, name: inspection.name)
      }
      var model = LockedModel(
        name: inspection.name, road: inspection.road, kind: inspection.kind, revision: revision,
        deliverableID: inspection.deliverableID, whatShipped: inspection.whatShipped, format: inspection.format,
        archive: inspection.archive, files: files, generated: [], scorecard: inspection.scorecard,
        swiftRunsEndToEnd: inspection.swiftRunsEndToEnd,
        runtime: inspection.kit.map { RuntimePin(licence: $0.licenceName, treeSHA256: $0.runtimeTreeSHA256) },
        importedAt: timestamp, previousRevisions: previous)

      var generatedTexts: [(path: String, text: String)] = [
        ("\(model.generatedDirectory)/\(model.name)Files.swift", Generators.filesSwift(model: model, kit: inspection.kit))
      ]
      if let kit = inspection.kit {
        generatedTexts.append(("\(model.generatedDirectory)/\(model.name)Runtime.swift", Generators.runtimeSwift(model: model, kit: kit)))
      }
      // The Swift file of the package flavour: `<Type>.swift`, the record's text byte for byte.
      var keptSwiftFile: TrackedFile?
      if let flavour = inspection.flavour {
        generatedTexts.append(("\(model.generatedDirectory)/\(flavour.swiftFile)", flavour.swiftSource))
        let floors = PackageFlavourFile.floorsAbovePackage(flavour.minimumOS)
        if !floors.isEmpty {
          warnings.append(Say(
            "\(inspection.name) 的 Swift 檔說它需要 \(floors.joined(separator: "、"))，比這個套件的 Package.swift 宣告的 platforms（macOS 14、iOS 17）高：你的 App 的最低系統要夠新，或自己處理（Package.swift 由匯入產生，匯入不替你改）。",
            "The Swift file of \(inspection.name) says it needs \(floors.joined(separator: ", ")), which is above the platforms this package's Package.swift declares (macOS 14, iOS 17): make your app's minimum system new enough, or handle it yourself (Package.swift is generated by the import, which does not change it for you)."))
        }
      } else if let type = inspection.typeName, let known = existing?.generated.first(where: { $0.path == "\(model.generatedDirectory)/\(TypeName.swiftFile(for: type))" }) {
        // This revision came without a record: the Swift file of the last one stays, and is said to be old.
        keptSwiftFile = known
        warnings.append(Say(
          "\(inspection.name) r\(revision) 沒有附 swift-package 回應：上一版的 \(TypeName.swiftFile(for: type)) 留著，但它可能和這一版的標籤、輸入大小不一致。請再向 swift-package 路徑要一份（type_name=\(type)）放進 Inbox。",
          "\(inspection.name) r\(revision) came without a swift-package reply: the \(TypeName.swiftFile(for: type)) of the last revision stays, but it may not match this revision's labels or input size. Ask the swift-package route again (type_name=\(type)) and drop the reply in the Inbox."))
      }
      var changes: [GeneratedChange] = []
      var entries: [TrackedFile] = []
      for (path, text) in generatedTexts {
        let data = Data(text.utf8)
        let known = existing?.generated.first { $0.path == path }
        let change = try decide(path: path, data: data, lockedSHA: known?.sha256, pending: pending, root: root)
        changes.append(change)
        contents[path] = data
        if case .keepYoursWriteNew(let newPath) = change.decision {
          contents[newPath] = data
          if let known { entries.append(known) }
        } else {
          entries.append(TrackedFile(path: path, sha256: change.sha256, sizeBytes: data.count))
        }
      }
      if let keptSwiftFile { entries.append(keptSwiftFile) }
      model.generated = entries
      perModelGenerated[inspection.name] = changes
      perModelGeneratedEntries[inspection.name] = entries
      if let index = models.firstIndex(where: { $0.name == model.name }) { models[index] = model } else { models.append(model) }
      planned.append(PlannedModel(name: model.name, revision: revision, previousRevision: existing?.revision, road: model.road, diff: diff))
    }
    models.sort { $0.name < $1.name }

    // The top-level files.
    let createsPackage = lockBytes == nil
    var topChanges: [GeneratedChange] = []
    var topEntries: [TrackedFile] = []
    let changed = !final.isEmpty || createsPackage
    if changed {
      let rememberedPath = (try? SafeFS.readRegular(root, "Package.swift")).flatMap { $0 }.flatMap { Generators.importPackagePath(inManifest: String(decoding: $0, as: UTF8.self)) }
      var importPackage = rememberedPath
      if let given = options.importPackagePath {
        let relative = relativePath(from: root, to: URL(fileURLWithPath: given, relativeTo: root))
        guard Generators.isSafeImportPackagePath(relative) else {
          throw ImportRefusal("import_package_invalid", Say(
            "ShrinkML 匯入套件的路徑「\(given)」含有不能寫進 Package.swift 的字元。",
            "The path to the ShrinkML import package (\"\(given)\") has characters that cannot go into Package.swift."))
        }
        importPackage = relative
      }
      let tops: [(String, String)] = [
        ("Package.swift", Generators.packageSwift(models: models, importPackage: importPackage, repository: options.publicRepository)),
        (".gitignore", Generators.gitignore()),
        ("Sources/ShrinkMLModels/Exports.swift", Generators.exportsSwift(models: models)),
      ]
      for (path, text) in tops {
        let data = Data(text.utf8)
        let known = lock.generated.first { $0.path == path }
        let change = try decide(path: path, data: data, lockedSHA: known?.sha256, pending: pending, root: root)
        topChanges.append(change)
        contents[path] = data
        if case .keepYoursWriteNew(let newPath) = change.decision {
          contents[newPath] = data
          if let known { topEntries.append(known) }
        } else {
          topEntries.append(TrackedFile(path: path, sha256: change.sha256, sizeBytes: data.count))
        }
      }
    } else {
      topEntries = lock.generated
    }

    let newLock = Lock(generated: topEntries, models: models)

    // The runtime.
    var installsRuntime = false
    var treeToInstall: String?
    if let inspection = final.first(where: { $0.kind == .pipelineKit }), let kit = inspection.kit {
      treeToInstall = kit.runtimeTreeSHA256
      installsRuntime = try RuntimeTree.digest(of: root.appendingPathComponent(".shrinkml/runtime")) != kit.runtimeTreeSHA256
    } else if let pin = lock.models.first(where: { $0.kind == .pipelineKit })?.runtime {
      if try RuntimeTree.digest(of: root.appendingPathComponent(".shrinkml/runtime")) != pin.treeSHA256 {
        warnings.append(Say(
          "\(lock.models.first(where: { $0.kind == .pipelineKit })!.name) 需要的 Swift runtime 不在 .shrinkml/runtime（或內容不對）。它不進 git，所以剛 clone 的專案會缺：把發票交付的 zip 放進 Inbox 再匯入一次。",
          "The Swift runtime \(lock.models.first(where: { $0.kind == .pipelineKit })!.name) needs is not in .shrinkml/runtime (or its content is wrong). It is not in git, so a fresh clone lacks it: drop the invoice hand-over zip in the Inbox and import again."))
      }
    }
    let generatedChanges = perModelGenerated.keys.sorted().flatMap { perModelGenerated[$0]! } + topChanges
    return ImportPlan(
      archives: reports, models: planned, generated: generatedChanges, warnings: warnings,
      currentLock: lock, newLock: newLock, createsPackage: createsPackage, inspections: final,
      contents: contents, installsRuntime: installsRuntime, runtimeTreeSHA256: treeToInstall,
      lockExistedWithBytes: lockBytes)
  }

  // MARK: Pieces

  static func timestampString(_ date: Date) -> String {
    var time = time_t(date.timeIntervalSince1970)
    var parts = tm()
    gmtime_r(&time, &parts)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02dZ", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1,
      Int(parts.tm_mday), Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec))
  }

  /// `Beans.zip.sha256` beside the archive: the digest the hand-over page showed, if the person saved it.
  static func expectedDigest(next url: URL) throws -> String? {
    let sidecar = URL(fileURLWithPath: url.path + ".sha256")
    guard SafeFS.kind(of: sidecar) == .file, let data = try? Data(contentsOf: sidecar) else { return nil }
    let text = String(decoding: data.prefix(4096), as: UTF8.self)
    let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).first.map { $0.lowercased() } ?? ""
    guard SHA256Hex.isValid(token) else {
      throw ImportRefusal("sha256_file_invalid", Say(
        "「\(sidecar.lastPathComponent)」裡沒有看得懂的 sha256（要 64 個十六進位字元）。為了不匯入沒驗證的檔案，這個交付先不匯入。",
        "\"\(sidecar.lastPathComponent)\" holds no sha256 that can be read (64 hex characters). So as not to import a file that was not verified, this hand-over was not imported."))
    }
    return token
  }

  static func decide(path: String, data: Data, lockedSHA: String?, pending: Set<String>, root: URL) throws -> GeneratedChange {
    let newDigest = SHA256Hex.of(data)
    guard let current = try SafeFS.readRegular(root, path) else {
      return GeneratedChange(path: path, decision: .create, sha256: newDigest)
    }
    let currentDigest = SHA256Hex.of(current)
    if currentDigest == newDigest { return GeneratedChange(path: path, decision: .unchanged, sha256: newDigest) }
    if currentDigest == lockedSHA || pending.contains(currentDigest) {
      return GeneratedChange(path: path, decision: .replace, sha256: newDigest)
    }
    var candidate = path + ".new"
    var number = 1
    while let existing = try SafeFS.readRegular(root, candidate), SHA256Hex.of(existing) != newDigest {
      number += 1
      guard number <= 99 else {
        throw ImportRefusal("too_many_new_files", Say(
          "「\(path)」旁邊已經有 99 個 .new 檔，請先整理。", "There are already 99 .new files beside \"\(path)\"; tidy them first."))
      }
      candidate = path + ".new.\(number)"
    }
    return GeneratedChange(path: path, decision: .keepYoursWriteNew(candidate), sha256: newDigest)
  }

  static func revisionDiff(old: LockedModel, newFiles: [RecordedFile], newRevision: Int, name: String) -> RevisionDiff {
    func key(_ file: RecordedFile, revision: Int) -> String {
      file.path
        .replacingOccurrences(of: "Sources/\(name)/Resources/r\(revision)/", with: "")
        .replacingOccurrences(of: "Records/\(name)/r\(revision)/", with: "records/")
    }
    let before = Dictionary(old.files.map { (key($0, revision: old.revision), $0.sha256) }, uniquingKeysWith: { first, _ in first })
    let after = Dictionary(newFiles.map { (key($0, revision: newRevision), $0.sha256) }, uniquingKeysWith: { first, _ in first })
    let sortedKeys: ([String]) -> [String] = { $0.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } } }
    return RevisionDiff(
      added: sortedKeys(after.keys.filter { before[$0] == nil }),
      changed: sortedKeys(after.keys.filter { before[$0] != nil && before[$0] != after[$0] }),
      removed: sortedKeys(before.keys.filter { after[$0] == nil }),
      unchanged: sortedKeys(after.keys.filter { before[$0] == after[$0] }))
  }

  /// `target` as seen from `base`, written with `..` where it has to be; absolute when no common prefix helps.
  static func relativePath(from base: URL, to target: URL) -> String {
    let baseParts = SafeFS.realURL(base).pathComponents
    let targetParts = SafeFS.realURL(target).pathComponents
    var common = 0
    while common < baseParts.count, common < targetParts.count, baseParts[common] == targetParts[common] { common += 1 }
    if common <= 1 { return SafeFS.realURL(target).path }
    let up = Array(repeating: "..", count: baseParts.count - common)
    let rest = Array(targetParts[common...])
    let parts = up + rest
    return parts.isEmpty ? "." : parts.joined(separator: "/")
  }
}

/// The Swift runtime of an invoice reader, kept in `.shrinkml/runtime`, pinned by one digest.
enum RuntimeTree {
  /// sha256 of "<relative path>\n<file sha256>\n" for every file, in path order; nil when there is no folder.
  static func digest(of directory: URL) throws -> String? {
    guard SafeFS.kind(of: directory) == .directory else { return nil }
    let files = try SafeFS.regularFiles(under: directory)
      .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
    var text = ""
    for relative in files {
      let (digest, _) = try SHA256Hex.ofFile(at: directory.appendingPathComponent(relative))
      text += "\(relative)\n\(digest)\n"
    }
    return SHA256Hex.of(Data(text.utf8))
  }
}
