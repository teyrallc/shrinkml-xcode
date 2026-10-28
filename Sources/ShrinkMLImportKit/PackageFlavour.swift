import Foundation

/// The package flavour of a hand-over's Swift file: what `GET /api/v1/projects/{project_id}/deliverables/
/// {deliverable_id}/swift-package?type_name=<Type>` answers,
/// saved as a file. The import has no network code and no key, so it never asks the route itself; it
/// reads the answer from a file the person (or `shrinkml xcode pull`, one day) put there:
///
///   1. a member `swift-package.json` of the hand-over's zip, when a hand-over carries one (no writer
///      makes it today; the name is reserved here so that the day one does, nothing has to change), or
///   2. `<zip name>.swift-package.json` beside the zip in the Inbox, like `<zip name>.sha256`.
///
/// Both at once are fine only when they are the same bytes. The file is checked against what the import
/// itself decided, before one byte of it is written into the person's package: the type name (chosen
/// by `TypeName`), the folder (`Models/<Type>`), the declaration (`copy`), the Swift file's name, every
/// file it says the folder holds (each must be a member of the zip), that the Swift source declares its
/// type publicly, and that it is the same hand-over as the file name says. The lock pins the record's
/// sha256 and the Swift file's, and the Swift file goes into git for review like every generated file.
public struct PackageFlavour: Equatable, Sendable {
  public enum Place: Equatable, Sendable {
    case insideTheArchive
    case besideTheArchive(String)
  }

  public let place: Place
  public let typeName: String
  public let swiftFile: String
  /// `snippet.source`, byte for byte what is written to `Generated/<Type>.swift`.
  public let swiftSource: String
  /// What the record says of whether the file runs from an input to an answer; nil when it says nothing.
  public let runsEndToEnd: Bool?
  public let deliverableID: String?
  public let minimumOS: [String]
  /// The files the record says the folder holds (each is a member of the zip).
  public let resourceMembers: [String]
  /// The record's own bytes, kept in `Records/<Name>/r<n>/swift-package.json`.
  public let recordBytes: Data
  public let recordSHA256: String
}

/// What the import knows before it reads a record, and checks the record against.
struct FlavourExpectation {
  let typeName: String
  /// The id the file name carries (`shrinkml xcode pull`), when it does.
  let pulledID: String?
  /// The file name of the zip, which the file name of its companion record is made from.
  let archiveName: String
  /// The top-level members of the zip: files, and the `.mlpackage` and `.mlmodelc` folders by their folder name.
  let archiveMembers: Set<String>
  /// The `.mlpackage` folders of the zip.
  let packages: [String]
  /// The `.mlmodelc` folders of the zip (a hand-over made by a recent ShrinkML holds one beside each `.mlpackage`); none for an older one.
  let compiledPackages: [String]
}

enum PackageFlavourFile {
  static let memberName = "swift-package.json"
  static let companionSuffix = ".swift-package.json"
  static let schema = "shrinkml.swift-package-flavor.v1"
  static let maximumRecordBytes = 2 << 20
  static let maximumSourceBytes = 1 << 20
  /// The folder every package flavour names for the resources of a model, `Models/<Type>`, and the
  /// first component of it, which is what `.copy` declares.
  static let folder = "Models"

  static func companionName(for archiveName: String) -> String { archiveName + companionSuffix }

  static func isCompanion(_ name: String) -> Bool { name.lowercased().hasSuffix(companionSuffix) }

  static func companionURL(for archive: URL) -> URL { URL(fileURLWithPath: archive.path + companionSuffix) }

  /// The request that gives a person the record for this hand-over, in the words the route uses.
  static func request(typeName: String, deliverableID: String?) -> String {
    "GET /api/v1/projects/{project_id}/deliverables/\(deliverableID ?? "{deliverable_id}")/swift-package?type_name=\(typeName)"
  }

  /// The one sentence that says how to get the record, used wherever there is none or it is wrong.
  static func howToGet(typeName: String, deliverableID: String?, archiveName: String) -> Say {
    let request = request(typeName: typeName, deliverableID: deliverableID)
    let file = companionName(for: archiveName)
    return Say(
      "向 ShrinkML 要套件版：用 API 金鑰呼叫 \(request)（一般金鑰，權限 read 或 write，或交付專用金鑰 handover:read 都可以取得套件版，唯讀），把回應存成 Inbox 裡的 \(file)，再匯入一次。",
      "To get the package flavour from ShrinkML: call \(request) with an API key (a normal key, scope read or write, or a hand-over key, handover:read: either can fetch the package flavour, read-only), save the reply as \(file) in the Inbox, and import again.")
  }

  // MARK: Reading the companion file

  /// The companion's bytes, nil when there is none. A link, a folder or a file over the cap is a
  /// refusal, not a missing file: it is something the person put there.
  static func readCompanion(for archive: URL) throws -> Data? {
    let url = companionURL(for: archive)
    guard let kind = SafeFS.kind(of: url) else { return nil }
    guard kind == .file else {
      throw ImportRefusal(
        "flavour_unreadable",
        Say(
          "「\(url.lastPathComponent)」是連結或資料夾，不是普通檔案；沒有匯入這個交付。",
          "\"\(url.lastPathComponent)\" is a link or a folder, not a plain file; this hand-over was not imported."))
    }
    var info = stat()
    guard lstat(url.path, &info) == 0, Int(info.st_size) <= maximumRecordBytes else {
      throw tooBig(url.lastPathComponent)
    }
    guard let data = try? Data(contentsOf: url) else {
      throw ImportRefusal(
        "flavour_unreadable",
        Say("讀不了「\(url.lastPathComponent)」；沒有匯入這個交付。", "Could not read \"\(url.lastPathComponent)\"; this hand-over was not imported."))
    }
    return data
  }

  /// sha256 of the companion, nil when there is none. One that is there but cannot be read gets a word
  /// that matches no digest, so a known archive with such a file beside it is looked at again (and the
  /// file is then refused by name) instead of being skipped in silence.
  static func companionSHA256(for archive: URL) -> String? {
    guard SafeFS.kind(of: companionURL(for: archive)) != nil else { return nil }
    guard let data = (try? readCompanion(for: archive)) ?? nil else { return "unreadable" }
    return SHA256Hex.of(data)
  }

  static func tooBig(_ name: String) -> ImportRefusal {
    ImportRefusal(
      "flavour_unreadable",
      Say(
        "「\(name)」超過 \(maximumRecordBytes >> 20) MiB，不像 swift-package 路徑的回應；沒有匯入這個交付。",
        "\"\(name)\" is over \(maximumRecordBytes >> 20) MiB, which is no reply of the swift-package route; this hand-over was not imported."))
  }

  // MARK: Parsing and checking

  static func parse(_ bytes: Data, place: PackageFlavour.Place, expecting expected: FlavourExpectation) throws -> PackageFlavour {
    func bad(_ code: String, _ zh: String, _ en: String) -> ImportRefusal { ImportRefusal(code, Say(zh, en)) }
    let name: String
    switch place {
    case .insideTheArchive: name = memberName
    case .besideTheArchive(let companion): name = companion
    }
    guard bytes.count <= maximumRecordBytes else { throw tooBig(name) }
    let json: JSONValue
    do {
      json = try StrictJSON.parse(bytes)
    } catch let error as JSONParseError {
      throw bad(
        "flavour_unreadable", "「\(name)」不是合法的 JSON（\(error.reason)）；沒有匯入這個交付。",
        "\"\(name)\" is not valid JSON (\(error.reason)); this hand-over was not imported.")
    }
    let type = expected.typeName
    let ask = howToGet(typeName: type, deliverableID: expected.pulledID, archiveName: expected.archiveName)
    guard json.objectValue != nil, let snippet = json["snippet"]?.objectValue else {
      throw bad(
        "flavour_unreadable",
        "「\(name)」不是 swift-package 路徑的回應（要有 snippet 物件）；沒有匯入這個交付。\(ask.zh)",
        "\"\(name)\" is not a reply of the swift-package route (it needs a snippet object); this hand-over was not imported. \(ask.en)")
    }
    let snippetValue = JSONValue.object(snippet)
    guard json["flavor"]?.stringValue == "package", snippetValue["flavor"]?.stringValue == "package",
      let package = snippetValue["package"]?.objectValue, package["schema"]?.stringValue == schema
    else {
      throw bad(
        "flavour_not_package",
        "「\(name)」不是套件版（flavor 要是 package、schema 要是 \(schema)）：預設版的 Swift 檔是貼進 App 用的，放不進套件。\(ask.zh)",
        "\"\(name)\" is not the package flavour (flavor must be package and schema \(schema)): the default Swift file is pasted into an app and does not fit in a package. \(ask.en)")
    }
    let packageValue = JSONValue.object(package)

    // The type: the one the import chose for this model.
    guard packageValue["type"]?.stringValue == type, packageValue["error_type"]?.stringValue == type + "Error" else {
      let given = packageValue["type"]?.stringValue ?? "（沒寫 / missing）"
      throw bad(
        "flavour_wrong_type",
        "「\(name)」是為 Swift 型別「\(given)」要來的，這個模型要的是「\(type)」（兩個模型不能用同一個型別名稱）。請重新要一份：type_name=\(type)。\(ask.zh)",
        "\"\(name)\" was asked for the Swift type \"\(given)\", and this model needs \"\(type)\" (two models cannot share a type name). Ask again with type_name=\(type). \(ask.en)")
    }
    let swiftFile = TypeName.swiftFile(for: type)
    guard packageValue["swift_file"]?.stringValue == swiftFile, snippetValue["filename"]?.stringValue == swiftFile else {
      throw bad(
        "flavour_wrong_file",
        "「\(name)」裡 Swift 檔的名稱不是 \(swiftFile)；沒有匯入這個交付。",
        "The name of the Swift file in \"\(name)\" is not \(swiftFile); this hand-over was not imported.")
    }

    // The folder and the declaration: `Models/<Type>`, copied.
    let directory = TypeName.resourceDirectory(for: type)
    let declare = packageValue["declare"]
    guard packageValue["resource_directory"]?.stringValue == directory, declare?["rule"]?.stringValue == "copy",
      declare?["folder"]?.stringValue == folder
    else {
      throw bad(
        "flavour_wrong_folder",
        "「\(name)」的資源資料夾或宣告不對：這個匯入要的是資料夾 \(directory)，宣告方式 copy（.copy）。請重新要一份，不要自己指定 resource_directory：type_name=\(type)。\(ask.zh)",
        "The resource folder or declaration in \"\(name)\" is not the one this import needs: folder \(directory), declared with copy (.copy). Ask again without a resource_directory of your own: type_name=\(type). \(ask.en)")
    }

    // Every file it says the folder holds is a member of this zip, and every model package of the zip is there.
    var members: [String] = []
    for (position, item) in (packageValue["resources"]?.arrayValue ?? []).enumerated() {
      guard let member = item["member"]?.stringValue, ArchiveReader.isFlatName(member),
        expected.archiveMembers.contains(member), item["path"]?.stringValue == directory + "/" + member
      else {
        let shown = item["member"]?.stringValue ?? "（沒寫 / missing）"
        if item["member"]?.stringValue != nil, ArchiveReader.isFlatName(shown), expected.archiveMembers.contains(shown) {
          throw bad(
            "flavour_wrong_folder", "「\(name)」的 resources[\(position)].path 不是 \(directory)/\(shown)；沒有匯入這個交付。",
            "resources[\(position)].path in \"\(name)\" is not \(directory)/\(shown); this hand-over was not imported.")
        }
        throw bad(
          "flavour_missing_file",
          "「\(name)」說資料夾裡要有「\(shown)」，但這個 zip 沒有這個檔案（是不是別的交付的回應？）；沒有匯入這個交付。",
          "\"\(name)\" says the folder holds \"\(shown)\", which this zip does not have (is it the reply for another hand-over?); this hand-over was not imported.")
      }
      members.append(member)
    }
    for package in expected.packages where !members.contains(package) {
      throw bad(
        "flavour_missing_file",
        "這個 zip 有模型「\(package)」，「\(name)」卻沒有提到它（是不是別的交付的回應？）；沒有匯入這個交付。",
        "This zip holds the model \"\(package)\", which \"\(name)\" does not mention (is it the reply for another hand-over?); this hand-over was not imported.")
    }

    for compiled in expected.compiledPackages where !members.contains(compiled) {
      throw bad(
        "flavour_missing_file",
        "這個 zip 有編譯好的模型「\(compiled)」，「\(name)」卻沒有提到它（是不是別的交付的回應？）；沒有匯入這個交付。",
        "This zip holds the compiled model \"\(compiled)\", which \"\(name)\" does not mention (is it the reply for another hand-over?); this hand-over was not imported.")
    }

    // The Swift file itself.
    guard let source = snippetValue["source"]?.stringValue, !source.isEmpty, source.utf8.count <= maximumSourceBytes,
      !source.unicodeScalars.contains(where: { $0.value == 0 }), declaresPublicly(type: type, in: source)
    else {
      throw bad(
        "flavour_source_invalid",
        "「\(name)」裡的 Swift 原始碼是空的、太大（超過 \(maximumSourceBytes >> 20) MiB）、含 NUL，或沒有 public 宣告型別 \(type)；沒有匯入這個交付。",
        "The Swift source in \"\(name)\" is empty, too large (over \(maximumSourceBytes >> 20) MiB), holds a NUL, or does not declare the type \(type) publicly; this hand-over was not imported.")
    }

    // Which hand-over: the record's id must agree with the file name's, and be an id.
    var recordID: String?
    if let id = json["deliverable_id"], !id.isNull {
      guard let text = id.stringValue, isUUID(text) else {
        throw bad(
          "flavour_unreadable", "「\(name)」的 deliverable_id 不是 UUID；沒有匯入這個交付。",
          "The deliverable_id in \"\(name)\" is not a UUID; this hand-over was not imported.")
      }
      recordID = text.lowercased()
    }
    if let pulled = expected.pulledID, let recordID, pulled.lowercased() != recordID {
      throw bad(
        "flavour_deliverable_mismatch",
        "「\(name)」是交付 \(recordID) 的套件版，但這個 zip 的檔名說它是交付 \(pulled.lowercased())；沒有匯入。",
        "\"\(name)\" is the package flavour of hand-over \(recordID), but this zip's file name says it is hand-over \(pulled.lowercased()); not imported.")
    }
    let minimumOS = (snippetValue["package"]?["minimum_os"]?.arrayValue ?? []).compactMap(\.stringValue).prefix(8).map { String($0.prefix(40)) }
    return PackageFlavour(
      place: place, typeName: type, swiftFile: swiftFile, swiftSource: source,
      runsEndToEnd: snippetValue["runs_end_to_end"]?.boolValue, deliverableID: recordID ?? expected.pulledID?.lowercased(),
      minimumOS: Array(minimumOS), resourceMembers: members, recordBytes: bytes, recordSHA256: SHA256Hex.of(bytes))
  }

  /// `public [final] class|struct|enum|actor <Type>` at the start of a line, not `<Type>Error` and not
  /// a longer name. The corpus `record-rules.json` carries the same pattern for the route's side.
  static func declarationPattern(type: String) -> String {
    "(?m)^[ \\t]*public[ \\t]+(?:final[ \\t]+)?(?:class|struct|enum|actor)[ \\t]+\(type)(?![A-Za-z0-9_])"
  }

  static func declaresPublicly(type: String, in source: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: declarationPattern(type: type)) else { return false }
    return expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
  }

  static func isUUID(_ text: String) -> Bool {
    let groups = text.lowercased().split(separator: "-", omittingEmptySubsequences: false)
    return groups.map(\.count) == [8, 4, 4, 4, 12]
      && text.lowercased().unicodeScalars.allSatisfy { $0 == "-" || ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x66) }
  }

  /// "iOS 18" > the package's floor: the entries the importer can compare. Returns the ones above.
  static func floorsAbovePackage(_ minimumOS: [String]) -> [String] {
    let floors: [String: Int] = ["iOS": 17, "iPadOS": 17, "macOS": 14]
    return minimumOS.filter { entry in
      let parts = entry.split(separator: " ")
      guard parts.count == 2, let floor = floors[String(parts[0])], let required = Int(parts[1].split(separator: ".").first ?? "") else {
        return false
      }
      return required > floor
    }
  }
}
