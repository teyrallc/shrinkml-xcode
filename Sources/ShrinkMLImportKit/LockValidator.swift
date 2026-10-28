import Foundation

/// One thing wrong with a lock: which rule, where in the document, and a sentence for a person.
public struct Violation: Equatable, Sendable {
  /// A stable code. The rules that the JSON Schema can express carry the same names the corpus
  /// uses; the seven it cannot (case-only duplicates, reserved names, which folder a path belongs
  /// to, `Overrides/`, previous-revision order, model order) exist only here.
  public let rule: String
  /// Where, like `models[1].files[3].path`.
  public let location: String
  public let say: Say
}

public struct LockValidation: Sendable {
  /// Present only when `violations` is empty.
  public let lock: Lock?
  public let violations: [Violation]
}

/// Reads a lock strictly. A lock that breaks any rule is not repaired and not partly used: the
/// importer stops, says which rule at which place, and writes nothing.
public enum LockValidator {
  public static func validate(_ data: Data) -> LockValidation {
    let json: JSONValue
    do {
      json = try StrictJSON.parse(data)
    } catch let error as JSONParseError {
      return LockValidation(
        lock: nil,
        violations: [
          Violation(
            rule: "json_invalid", location: "byte \(error.offset)",
            say: Say(
              "shrinkml.lock.json 不是合法的 JSON（第 \(error.offset) 個位元組附近：\(error.reason)）。",
              "shrinkml.lock.json is not valid JSON (near byte \(error.offset): \(error.reason))."))
        ])
    } catch {
      return LockValidation(
        lock: nil,
        violations: [
          Violation(
            rule: "json_invalid", location: "document",
            say: Say("shrinkml.lock.json 讀不了。", "shrinkml.lock.json could not be read."))
        ])
    }
    return validate(json)
  }

  public static func validate(_ json: JSONValue) -> LockValidation {
    var walk = Walk()
    let lock = walk.lock(json)
    if !walk.violations.isEmpty { return LockValidation(lock: nil, violations: walk.violations) }
    return LockValidation(lock: lock, violations: [])
  }
}

private let secretPatterns: [NSRegularExpression] = [
  "sml_[a-z]+_[A-Za-z0-9]{8,}",
  "(?i)bearer\\s+[A-Za-z0-9._~+/=-]{8,}",
  "-----BEGIN [A-Z ]*PRIVATE KEY-----",
  "(?i)[a-z][a-z0-9+.-]*://[^/\\s@]*@",
  "(?i)[?&;](x-amz-[a-z-]*|signature|sig|token|access_token|api[_-]?key|apikey|key|secret|password|passwd|auth)=",
  "\\bAKIA[0-9A-Z]{16}\\b",
  "\\bsk-[A-Za-z0-9_-]{16,}",
].map { try! NSRegularExpression(pattern: $0) }

/// Does this text look like a key, a token, or a link that carries one? The same seven patterns
/// the JSON Schema's `plainText` definition refuses.
func looksLikeASecret(_ text: String) -> Bool {
  let range = NSRange(text.startIndex..., in: text)
  return secretPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
}

private struct Walk {
  var violations: [Violation] = []

  mutating func add(_ rule: String, _ location: String, _ zh: String, _ en: String) {
    violations.append(Violation(rule: rule, location: location, say: Say(zh, en)))
  }

  // MARK: - Shapes

  /// An object with exactly these keys: unknown ones are refused (so a key like `expires_at` or
  /// `api_key` cannot be smuggled in), missing ones are refused.
  mutating func object(_ value: JSONValue?, _ location: String, keys: [String]) -> [String: JSONValue]? {
    guard let value, let members = value.objectValue else {
      add("wrong_type", location, "\(location) 應該是一個物件。", "\(location) must be an object.")
      return nil
    }
    var ok = true
    for key in members.keys.sorted() where !keys.contains(key) {
      add(
        "unknown_key", "\(location).\(key)", "\(location) 裡有不認得的欄位「\(key)」（這個格式不收額外欄位）。",
        "\(location) has an unknown key \"\(key)\" (the format takes no extra keys).")
      ok = false
    }
    for key in keys where members[key] == nil {
      add(
        "missing_key", "\(location).\(key)", "\(location) 缺了欄位「\(key)」。", "\(location) is missing the key \"\(key)\".")
      ok = false
    }
    return ok ? members : nil
  }

  mutating func array(_ value: JSONValue?, _ location: String) -> [JSONValue]? {
    guard let items = value?.arrayValue else {
      add("wrong_type", location, "\(location) 應該是一個陣列。", "\(location) must be an array.")
      return nil
    }
    return items
  }

  // MARK: - Leaves

  mutating func plain(_ value: JSONValue?, _ location: String, nullable: Bool = false) -> String? {
    if nullable, value?.isNull == true { return nil }
    guard let text = value?.stringValue else {
      add("wrong_type", location, "\(location) 應該是文字。", "\(location) must be text.")
      return nil
    }
    if text.unicodeScalars.count > 256 {
      add("value_too_long", location, "\(location) 太長（上限 256 個字）。", "\(location) is too long (at most 256 characters).")
      return nil
    }
    if looksLikeASecret(text) {
      add(
        "secret_in_value", location, "\(location) 的內容像金鑰、權杖，或帶帳密／簽章的網址；lock 檔絕不存這些。",
        "\(location) looks like a key, a token, or a link carrying one; the lock never stores those.")
      return nil
    }
    return text
  }

  mutating func sha(_ value: JSONValue?, _ location: String, nullable: Bool = false) -> String? {
    if nullable, value?.isNull == true { return nil }
    guard let text = value?.stringValue, SHA256Hex.isValid(text) else {
      add(
        "sha256_invalid", location, "\(location) 必須是 64 個小寫十六進位字元。", "\(location) must be 64 lower-case hex characters.")
      return nil
    }
    return text
  }

  mutating func size(_ value: JSONValue?, _ location: String) -> Int? {
    guard let whole = value?.intValue, whole >= 0, whole <= Int64(Int.max) else {
      add("size_invalid", location, "\(location) 必須是 0 以上的整數。", "\(location) must be an integer, zero or more.")
      return nil
    }
    return Int(whole)
  }

  mutating func revision(_ value: JSONValue?, _ location: String) -> Int? {
    guard let whole = value?.intValue, whole >= 1, whole <= 1_000_000 else {
      add("revision_invalid", location, "\(location) 必須是 1 以上的整數。", "\(location) must be an integer, one or more.")
      return nil
    }
    return Int(whole)
  }

  mutating func timestamp(_ value: JSONValue?, _ location: String) -> String? {
    guard let text = value?.stringValue, Walk.isTimestamp(text) else {
      add(
        "timestamp_invalid", location, "\(location) 必須是 UTC 整秒時間，像 2026-10-01T15:04:05Z。",
        "\(location) must be a UTC time in whole seconds, like 2026-10-01T15:04:05Z.")
      return nil
    }
    return text
  }

  static func isTimestamp(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard bytes.count == 20 else { return false }
    let separators: [Int: UInt8] = [
      4: UInt8(ascii: "-"), 7: UInt8(ascii: "-"), 10: UInt8(ascii: "T"), 13: UInt8(ascii: ":"),
      16: UInt8(ascii: ":"), 19: UInt8(ascii: "Z"),
    ]
    for (position, byte) in bytes.enumerated() {
      if let expected = separators[position] {
        if byte != expected { return false }
      } else if !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
        return false
      }
    }
    func number(_ range: Range<Int>) -> Int { Int(String(decoding: bytes[range], as: UTF8.self))! }
    let month = number(5..<7)
    let day = number(8..<10)
    return (1...12).contains(month) && (1...31).contains(day) && number(11..<13) < 24
      && number(14..<16) < 60 && number(17..<19) < 61
  }

  mutating func path(_ value: JSONValue?, _ location: String) -> String? {
    guard let text = value?.stringValue else {
      add("path_invalid", location, "\(location) 必須是路徑文字。", "\(location) must be a path.")
      return nil
    }
    if let problem = ArchivePath.problem(in: text) {
      add(
        "path_invalid", location, "\(location) 的路徑不合規則（\(problem.rawValue)）。",
        "\(location) is not an acceptable path (\(problem.rawValue)).")
      return nil
    }
    return text
  }

  mutating func choice<T: RawRepresentable & CaseIterable>(
    _ value: JSONValue?, _ location: String, as type: T.Type
  ) -> T? where T.RawValue == String {
    if let text = value?.stringValue, let chosen = T(rawValue: text) { return chosen }
    let allowed = T.allCases.map(\.rawValue).joined(separator: " | ")
    add(
      "unknown_value", location, "\(location) 的值不在允許的範圍內（\(allowed)）。",
      "\(location) holds a value that is not allowed (\(allowed)).")
    return nil
  }

  // MARK: - Pieces

  mutating func tracked(_ value: JSONValue?, _ location: String) -> TrackedFile? {
    guard let members = object(value, location, keys: ["path", "sha256", "size_bytes"]) else { return nil }
    let path = path(members["path"], "\(location).path")
    let digest = sha(members["sha256"], "\(location).sha256")
    let size = size(members["size_bytes"], "\(location).size_bytes")
    guard let path, let digest, let size else { return nil }
    return TrackedFile(path: path, sha256: digest, sizeBytes: size)
  }

  mutating func recorded(_ value: JSONValue?, _ location: String) -> RecordedFile? {
    guard let members = object(value, location, keys: ["path", "sha256", "size_bytes", "role"]) else {
      return nil
    }
    let path = path(members["path"], "\(location).path")
    let digest = sha(members["sha256"], "\(location).sha256")
    let size = size(members["size_bytes"], "\(location).size_bytes")
    let role = choice(members["role"], "\(location).role", as: FileRole.self)
    guard let path, let digest, let size, let role else { return nil }
    return RecordedFile(path: path, sha256: digest, sizeBytes: size, role: role)
  }

  mutating func archive(_ value: JSONValue?, _ location: String) -> ArchiveIdentity? {
    guard let members = object(value, location, keys: ["filename", "sha256", "size_bytes"]) else { return nil }
    let filename = plain(members["filename"], "\(location).filename")
    let digest = sha(members["sha256"], "\(location).sha256")
    let size = size(members["size_bytes"], "\(location).size_bytes")
    guard let filename, let digest, let size else { return nil }
    return ArchiveIdentity(filename: filename, sha256: digest, sizeBytes: size)
  }

  mutating func scorecard(_ value: JSONValue?, _ location: String) -> Scorecard? {
    guard let members = object(value, location, keys: ["status", "digest", "written_in"]) else { return nil }
    let status = choice(members["status"], "\(location).status", as: ScorecardStatus.self)
    let digest = sha(members["digest"], "\(location).digest", nullable: true)
    let writtenIn = plain(members["written_in"], "\(location).written_in", nullable: true)
    guard let status else { return nil }
    let digestShapeBroken = members["digest"]?.isNull == false && digest == nil
    let writtenBroken = members["written_in"]?.isNull == false && writtenIn == nil
    if digestShapeBroken || writtenBroken { return nil }
    switch status {
    case .notRecorded where digest != nil:
      add(
        "scorecard_digest_mismatch", "\(location).digest", "「沒有記錄成績單」的模型不能帶成績單摘要。",
        "A scorecard that is not_recorded cannot carry a digest.")
      return nil
    case .measured where digest == nil, .inheritedUnchanged where digest == nil, .staleNeedsRerun where digest == nil:
      add(
        "scorecard_digest_mismatch", "\(location).digest", "狀態是 \(status.rawValue) 的成績單必須有摘要。",
        "A scorecard that is \(status.rawValue) must carry a digest.")
      return nil
    default:
      return Scorecard(status: status, digest: digest, writtenIn: writtenIn)
    }
  }

  mutating func runtime(_ value: JSONValue?, _ location: String) -> RuntimePin? {
    guard let members = object(value, location, keys: ["needs", "licence", "kept_in", "tree_sha256"]) else {
      return nil
    }
    var ok = true
    if members["needs"]?.stringValue != RuntimePin.needs {
      add(
        "unknown_value", "\(location).needs", "\(location).needs 只能是 \(RuntimePin.needs)。",
        "\(location).needs can only be \(RuntimePin.needs).")
      ok = false
    }
    if members["kept_in"]?.stringValue != RuntimePin.keptIn {
      add(
        "unknown_value", "\(location).kept_in",
        "\(location).kept_in 只能是 \(RuntimePin.keptIn)（runtime 原始碼不進 git）。",
        "\(location).kept_in can only be \(RuntimePin.keptIn) (the runtime source stays out of git).")
      ok = false
    }
    let licence = plain(members["licence"], "\(location).licence")
    let tree = sha(members["tree_sha256"], "\(location).tree_sha256")
    guard ok, let licence, let tree else { return nil }
    return RuntimePin(licence: licence, treeSHA256: tree)
  }

  mutating func previous(_ value: JSONValue?, _ location: String) -> PreviousRevision? {
    guard let members = object(value, location, keys: ["revision", "archive", "files", "imported_at"]) else {
      return nil
    }
    let revision = revision(members["revision"], "\(location).revision")
    let archive = archive(members["archive"], "\(location).archive")
    var files: [RecordedFile] = []
    var filesOK = true
    if let items = array(members["files"], "\(location).files") {
      for (position, item) in items.enumerated() {
        if let file = recorded(item, "\(location).files[\(position)]") { files.append(file) } else { filesOK = false }
      }
    } else {
      filesOK = false
    }
    let importedAt = timestamp(members["imported_at"], "\(location).imported_at")
    guard let revision, let archive, filesOK, let importedAt else { return nil }
    return PreviousRevision(revision: revision, archive: archive, files: files, importedAt: importedAt)
  }

  // MARK: - Model

  mutating func model(_ value: JSONValue?, _ location: String, skipFolders: Bool = false) -> LockedModel? {
    let keys = [
      "name", "road", "kind", "revision", "deliverable_id", "what_shipped", "format", "archive", "files",
      "generated", "scorecard", "swift_runs_end_to_end", "runtime", "imported_at", "previous_revisions",
    ]
    guard let members = object(value, location, keys: keys) else { return nil }

    var name: String?
    if let text = members["name"]?.stringValue {
      if let problem = ModelName.problem(in: text) {
        let rule = problem == .reserved ? "name_reserved" : "name_invalid"
        add(
          rule, "\(location).name", "模型名稱「\(text)」不行（\(problem.rawValue)）：要英文字母開頭，只用英文字母、數字、底線，最長 64 字，而且不能跟系統模組或 ShrinkMLModels 同名。",
          "The model name \"\(text)\" is not allowed (\(problem.rawValue)): letters, digits and underscores, starting with a letter, 64 characters at most, and not the name of a system module or of ShrinkMLModels.")
      } else {
        name = text
      }
    } else {
      add("name_invalid", "\(location).name", "\(location).name 必須是文字。", "\(location).name must be text.")
    }

    let road = plain(members["road"], "\(location).road")
    let kind = choice(members["kind"], "\(location).kind", as: ModelKind.self)
    let revision = revision(members["revision"], "\(location).revision")
    let deliverableID = plain(members["deliverable_id"], "\(location).deliverable_id", nullable: true)
    let whatShipped = choice(members["what_shipped"], "\(location).what_shipped", as: WhatShipped.self)
    let format = plain(members["format"], "\(location).format")
    let archive = archive(members["archive"], "\(location).archive")

    var files: [RecordedFile] = []
    var filesOK = true
    if let items = array(members["files"], "\(location).files") {
      for (position, item) in items.enumerated() {
        if let file = recorded(item, "\(location).files[\(position)]") { files.append(file) } else { filesOK = false }
      }
    } else {
      filesOK = false
    }
    var generated: [TrackedFile] = []
    var generatedOK = true
    if let items = array(members["generated"], "\(location).generated") {
      for (position, item) in items.enumerated() {
        if let file = tracked(item, "\(location).generated[\(position)]") { generated.append(file) } else { generatedOK = false }
      }
    } else {
      generatedOK = false
    }

    let scorecard = scorecard(members["scorecard"], "\(location).scorecard")

    var swiftRuns: Bool?
    var swiftRunsOK = true
    switch members["swift_runs_end_to_end"] {
    case .some(.null): swiftRuns = nil
    case .some(.bool(let flag)): swiftRuns = flag
    default:
      swiftRunsOK = false
      add(
        "wrong_type", "\(location).swift_runs_end_to_end", "swift_runs_end_to_end 必須是 true、false 或 null。",
        "swift_runs_end_to_end must be true, false or null.")
    }

    var runtime: RuntimePin?
    var runtimeOK = true
    if members["runtime"]?.isNull == true {
      runtime = nil
    } else {
      runtime = self.runtime(members["runtime"], "\(location).runtime")
      runtimeOK = runtime != nil
    }
    if let kind, runtimeOK {
      if kind == .pipelineKit && runtime == nil {
        add(
          "runtime_kind_mismatch", "\(location).runtime", "發票類（pipeline_kit）的模型必須有 runtime 欄位。",
          "A pipeline_kit model must carry a runtime entry.")
        runtimeOK = false
      } else if kind == .coremlBundle && runtime != nil {
        add(
          "runtime_kind_mismatch", "\(location).runtime", "Core ML 模型不能有 runtime 欄位。",
          "A coreml_bundle model cannot carry a runtime entry.")
        runtimeOK = false
      }
    }

    let importedAt = timestamp(members["imported_at"], "\(location).imported_at")

    var previousRevisions: [PreviousRevision] = []
    var previousOK = true
    if let items = array(members["previous_revisions"], "\(location).previous_revisions") {
      for (position, item) in items.enumerated() {
        if let earlier = previous(item, "\(location).previous_revisions[\(position)]") {
          previousRevisions.append(earlier)
        } else {
          previousOK = false
        }
      }
    } else {
      previousOK = false
    }

    guard let name, let road, let kind, let revision, let whatShipped, let format, let archive, filesOK,
      generatedOK, let scorecard, swiftRunsOK, runtimeOK, let importedAt, previousOK
    else { return nil }
    if members["deliverable_id"]?.isNull == false && deliverableID == nil { return nil }

    // The model's folders (the seven rules the schema cannot say).
    let model = LockedModel(
      name: name, road: road, kind: kind, revision: revision, deliverableID: deliverableID,
      whatShipped: whatShipped, format: format, archive: archive, files: files, generated: generated,
      scorecard: scorecard, swiftRunsEndToEnd: swiftRuns,
      runtime: runtime, importedAt: importedAt, previousRevisions: previousRevisions)
    if !skipFolders { checkFolders(of: model, at: location) }
    return model
  }

  mutating func checkFolders(of model: LockedModel, at location: String) {
    for (position, earlier) in model.previousRevisions.enumerated() {
      if earlier.revision >= model.revision
        || (position > 0 && earlier.revision <= model.previousRevisions[position - 1].revision)
      {
        add(
          "previous_revision_order", "\(location).previous_revisions[\(position)].revision",
          "舊版的編號必須比目前的 r\(model.revision) 小，而且由小到大排。",
          "A previous revision must be older than the current r\(model.revision), listed oldest first.")
      }
    }
    for (position, file) in model.files.enumerated() {
      checkRecorded(file, model: model, revision: model.revision, at: "\(location).files[\(position)].path")
    }
    for (position, file) in model.generated.enumerated() {
      let where_ = "\(location).generated[\(position)].path"
      if isOverrides(file.path) {
        addOverrides(file.path, where_)
      } else if !file.path.hasPrefix(model.generatedDirectory + "/") {
        addOutside(file.path, where_, expected: model.generatedDirectory + "/")
      }
    }
    for (index, earlier) in model.previousRevisions.enumerated() {
      for (position, file) in earlier.files.enumerated() {
        checkRecorded(
          file, model: model, revision: earlier.revision,
          at: "\(location).previous_revisions[\(index)].files[\(position)].path")
      }
    }
  }

  mutating func checkRecorded(_ file: RecordedFile, model: LockedModel, revision: Int, at location: String) {
    if isOverrides(file.path) {
      addOverrides(file.path, location)
      return
    }
    let expected =
      file.role == .record
      ? "Records/\(model.name)/r\(revision)/" : "Sources/\(model.name)/Resources/r\(revision)/"
    if !file.path.hasPrefix(expected) { addOutside(file.path, location, expected: expected) }
  }

  func isOverrides(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    return parts.count >= 3 && parts[0] == "Sources" && parts[2] == "Overrides"
  }

  mutating func addOverrides(_ path: String, _ location: String) {
    add(
      "path_in_overrides", location, "「\(path)」在 Overrides/ 底下；那個資料夾是你的，匯入永遠不碰，所以 lock 不能記它。",
      "\"\(path)\" is inside Overrides/; that folder is yours and an import never touches it, so the lock cannot track it.")
  }

  mutating func addOutside(_ path: String, _ location: String, expected: String) {
    add(
      "path_outside_model", location, "「\(path)」不在這個模型該在的資料夾（\(expected)）裡。",
      "\"\(path)\" is not inside the folder this entry may use (\(expected)).")
  }

  // MARK: - Whole lock

  static let topLevelGenerated: Set<String> = ["Package.swift", ".gitignore", "Sources/ShrinkMLModels/Exports.swift"]

  mutating func lock(_ value: JSONValue) -> Lock? {
    guard let members = object(value, "lock", keys: ["schema", "generated", "models"]) else { return nil }
    if members["schema"]?.stringValue != Lock.schema {
      add(
        "schema_const", "schema", "schema 必須是 \(Lock.schema)；這個版本的匯入工具不讀別的版本。",
        "schema must be \(Lock.schema); this importer reads no other version.")
      return nil
    }
    var generated: [TrackedFile] = []
    var ok = true
    if let items = array(members["generated"], "generated") {
      for (position, item) in items.enumerated() {
        guard let file = tracked(item, "generated[\(position)]") else {
          ok = false
          continue
        }
        generated.append(file)
        if !Walk.topLevelGenerated.contains(file.path) {
          addOutside(
            file.path, "generated[\(position)].path",
            expected: "Package.swift、.gitignore 或 Sources/ShrinkMLModels/Exports.swift / one of Package.swift, .gitignore, Sources/ShrinkMLModels/Exports.swift")
        }
      }
    } else {
      ok = false
    }

    var models: [LockedModel] = []
    if let items = array(members["models"], "models") {
      // Names first: a model whose name repeats an earlier one cannot be judged by its folders.
      let rawNames = items.map { $0["name"]?.stringValue ?? "" }
      var seen = Set<String>()
      var repeated = Set<Int>()
      for (position, name) in rawNames.enumerated() where !seen.insert(PathKey.key(name)).inserted {
        repeated.insert(position)
        add(
          "name_duplicate_ignoring_case", "models[\(position)].name",
          "模型名稱「\(name)」和前面的重複（大小寫不同也算重複，因為 Mac 的檔案系統不分大小寫）。",
          "The model name \"\(name)\" repeats an earlier one (a different case counts, because Mac file systems ignore case).")
      }
      // The order is judged on the names that are acceptable; a refused name is reported on its own.
      let judged = rawNames.filter { ModelName.isAcceptable($0) }
      if zip(judged, judged.dropFirst()).contains(where: { $0 > $1 }) {
        add(
          "models_not_sorted", "models", "models 必須照名稱排序（輸出要固定，匯入兩次才不會有差異）。",
          "models must be sorted by name (the output has to be stable so that importing twice changes nothing).")
      }
      for (position, item) in items.enumerated() {
        if let model = model(item, "models[\(position)]", skipFolders: repeated.contains(position)) {
          models.append(model)
        } else {
          ok = false
        }
      }
    } else {
      ok = false
    }

    // Paths that are the same file on a case-insensitive file system, anywhere in the lock.
    if ok {
      var everyPath: [(path: String, location: String)] = generated.enumerated().map { ($1.path, "generated[\($0)].path") }
      for (index, model) in models.enumerated() {
        everyPath += model.files.enumerated().map { ($1.path, "models[\(index)].files[\($0)].path") }
        everyPath += model.generated.enumerated().map { ($1.path, "models[\(index)].generated[\($0)].path") }
        for (earlier, revision) in model.previousRevisions.enumerated() {
          everyPath += revision.files.enumerated().map {
            ($1.path, "models[\(index)].previous_revisions[\(earlier)].files[\($0)].path")
          }
        }
      }
      var taken = Set<String>()
      for entry in everyPath where !taken.insert(PathKey.key(entry.path)).inserted {
        add(
          "path_duplicate_ignoring_case", entry.location,
          "「\(entry.path)」和另一個路徑只差大小寫（或只差組合字的寫法），在 Mac 上會變成同一個檔。",
          "\"\(entry.path)\" differs from another path only by case (or by how an accent is written); on a Mac it would be the same file.")
      }
    }
    guard ok, violations.isEmpty else { return nil }
    return Lock(generated: generated, models: models)
  }
}
