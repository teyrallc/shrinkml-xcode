import Foundation

/// Where a file from an archive ends up, relative to the `ShrinkMLModels` folder.
public enum Destination: String, Equatable, Sendable {
  /// `Sources/<Name>/Resources/r<n>/`
  case resources
  /// `Records/<Name>/r<n>/`
  case records
  /// `.shrinkml/runtime/` (a Pipeline Bundle's Swift runtime; never in git)
  case runtime
}

/// One file an import will place: which archive member, where it goes, what it is, and (after the
/// archive was read) its sha256 and size.
public struct Member: Equatable, Sendable {
  /// The member's name in the archive.
  public let entryName: String
  public let destination: Destination
  /// Relative to the destination folder.
  public let relativePath: String
  /// nil for runtime files, which the lock pins as one tree instead of file by file.
  public let role: FileRole?
  public internal(set) var sha256: String
  public internal(set) var size: Int
  /// true for the saved answer of the swift-package route that sits beside the zip in the Inbox: its
  /// bytes are not a member of the zip, so they are read (and staged) from that file.
  var viaCompanion = false

  /// Destination first, then the path by code point: the one order every list of members is kept in.
  static func lessThan(_ lhs: Member, _ rhs: Member) -> Bool {
    if lhs.destination != rhs.destination { return lhs.destination.rawValue < rhs.destination.rawValue }
    return lhs.relativePath.unicodeScalars.lexicographicallyPrecedes(rhs.relativePath.unicodeScalars) { $0.value < $1.value }
  }
}

/// What a Pipeline Bundle kit says about itself, read from the bundle inside it.
public struct KitFacts: Equatable, Sendable {
  public let runtimeVersion: String
  /// sha256 of the nested `pipeline-bundle.zip` bytes.
  public let bundleArchiveSHA256: String
  public let bundleChecksum: String
  public let manifestSHA256: String
  public let licenceName: String
  public let runtimeTreeSHA256: String
}

/// An archive that was read, checked and understood, with nothing written yet.
public struct Inspection: Equatable, Sendable {
  public let archive: ArchiveIdentity
  public let name: String
  public let kind: ModelKind
  public let road: String
  public let format: String
  public let whatShipped: WhatShipped
  public let scorecard: Scorecard
  public let swiftRunsEndToEnd: Bool?
  public let deliverableID: String?
  public internal(set) var members: [Member]
  /// The `.mlpackage` folder names of a Core ML bundle (one, or two for a model in two parts), sorted.
  public let modelPackages: [String]
  /// The Swift type the package flavour of a Core ML bundle declares for this model (nil for a kit).
  public let typeName: String?
  /// The package flavour of the Swift file, when a record of the swift-package route was found.
  public let flavour: PackageFlavour?
  public let kit: KitFacts?

  public func members(in destination: Destination) -> [Member] {
    members.filter { $0.destination == destination }
  }
}

/// Reads one archive: structure, kind, road, every declared digest. With a `stage` it also writes
/// each file into the staging area in the same pass; without one it writes nothing.
public enum ArchiveReader {
  /// A road of a Core ML hand-over the server writes a package flavour for (`swift_flavor.py`, one row
  /// per road in `swift_flavor_cases.py`).
  public struct PackageRoad: Equatable, Sendable {
    public let key: String
    public let zh: String
    public let en: String
  }

  /// The six task keys of Core ML hand-overs with a package flavour (contract `build-run.v1-11`).
  public static let packageRoads: [PackageRoad] = [
    PackageRoad(key: "visual.image_classification", zh: "影像分類", en: "image classification"),
    PackageRoad(key: "visual.object_detection", zh: "物件偵測", en: "object detection"),
    PackageRoad(key: "audio.keyword_spotting", zh: "關鍵字偵測", en: "keyword spotting"),
    PackageRoad(key: "audio.asr", zh: "語音轉文字", en: "speech to text"),
    PackageRoad(key: "text.sequence_classification", zh: "文字分類", en: "text classification"),
    PackageRoad(key: "text.token_classification", zh: "文字逐詞標記", en: "token tagging"),
  ]
  public static let supportedRoad = packageRoads[0].key
  public static let kitRoad = "document_extraction.field_pipeline"

  public static func packageRoad(for key: String) -> PackageRoad? { packageRoads.first { $0.key == key } }

  /// "影像分類（visual.image_classification）、…" and its English twin.
  static var roadList: Say {
    Say(
      packageRoads.map { "\($0.zh)（\($0.key)）" }.joined(separator: "、"),
      packageRoads.map { "\($0.en) (\($0.key))" }.joined(separator: ", "))
  }

  /// How many `.mlpackage` folders a pipeline shape holds.
  static let shapes: [String: Int] = ["single_graph": 1, "encoder_decoder_split": 2]

  static let maximumManifestBytes = 4 << 20
  static let maximumNestedArchiveBytes = 20 << 20
  static let handOverName = "shrinkml-handover"

  // MARK: Identity

  public static func identity(of url: URL) throws -> ArchiveIdentity {
    let (digest, size) = try SHA256Hex.ofFile(at: url)
    return ArchiveIdentity(filename: url.lastPathComponent, sha256: digest, sizeBytes: size)
  }

  /// A file name made by `shrinkml xcode pull` (the CLI, v0.2 X3): `shrinkml-handover-<id>.zip` for a
  /// model file and `shrinkml-handover-<id>-developer-kit.zip` for an invoice kit, `<id>` a UUID.
  /// Such a name is the CLI's, not the person's, and says nothing about the model, so the model name
  /// comes from the contents (see `read`), and the id is the lock's `deliverable_id`.
  public struct PulledName: Equatable, Sendable {
    public let id: String
    public let isKit: Bool
  }

  public static func pulledName(forFilename filename: String) -> PulledName? {
    let lower = filename.lowercased()
    guard lower.hasSuffix(".zip") else { return nil }
    var rest = String(lower.dropLast(4))
    let prefix = handOverName + "-"
    guard rest.hasPrefix(prefix) else { return nil }
    rest = String(rest.dropFirst(prefix.count))
    var isKit = false
    if rest.hasSuffix("-developer-kit") {
      isKit = true
      rest = String(rest.dropLast("-developer-kit".count))
    }
    let groups = rest.split(separator: "-", omittingEmptySubsequences: false)
    guard groups.map(\.count) == [8, 4, 4, 4, 12],
      rest.unicodeScalars.allSatisfy({ $0 == "-" || ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x66) })
    else { return nil }
    return PulledName(id: rest, isKit: isKit)
  }

  /// The model name a file name gives: its stem made into a Swift module name, or the road's own name
  /// for the generic file name a Pipeline Bundle kit comes in.
  public static func suggestedName(forFilename filename: String) -> String {
    let stem = (filename as NSString).deletingPathExtension
    if stem.lowercased() == handOverName { return "InvoiceReader" }
    return moduleName(fromWords: stem)
  }

  /// Letters and digits kept, any other run becomes `_`, a leading digit gets an `M`, first letter
  /// upper case, at most 64; "Model" when nothing is left.
  static func moduleName(fromWords words: String) -> String {
    var out = ""
    var lastWasSeparator = true
    for scalar in words.unicodeScalars {
      let isWordScalar =
        (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
        || (scalar.value >= 0x61 && scalar.value <= 0x7A)
      if isWordScalar {
        out.unicodeScalars.append(scalar)
        lastWasSeparator = false
      } else if !lastWasSeparator {
        out.append("_")
        lastWasSeparator = true
      }
    }
    while out.hasSuffix("_") { out.removeLast() }
    var stem = out
    if stem.isEmpty { return "Model" }
    if let first = stem.unicodeScalars.first, first.value >= 0x30 && first.value <= 0x39 { stem = "M" + stem }
    stem = stem.prefix(1).uppercased() + stem.dropFirst()
    return String(stem.prefix(ModelName.maximumLength))
  }

  // MARK: Read

  /// - Parameters:
  ///   - expectedSHA256: when the person (or the hand-over page) gave the archive's digest, it is
  ///     checked before one byte of the archive is parsed.
  ///   - stage: where to write the files, or nil to only check.
  public static func read(
    _ url: URL, identity: ArchiveIdentity? = nil, expectedSHA256: String? = nil,
    limits: ZipLimits = .modelBundle, stage: StagingArea? = nil
  ) throws -> Inspection {
    let identity = try identity ?? ArchiveReader.identity(of: url)
    if let expected = expectedSHA256, expected != identity.sha256 {
      throw ImportRefusal(
        "archive_sha256_mismatch",
        Say(
          "「\(url.lastPathComponent)」的 sha256 是 \(identity.sha256)，和你給的 \(expected) 不一樣；沒有打開它，也沒有寫任何東西。",
          "The sha256 of \"\(url.lastPathComponent)\" is \(identity.sha256), not the \(expected) you gave; it was not opened and nothing was written."))
    }
    let zip = try ZipArchive(contentsOf: url, limits: limits)
    let files = zip.entries.filter { $0.kind == .file }
    let names = Set(files.map(\.name))
    let pulled = pulledName(forFilename: url.lastPathComponent)
    let name = pulled == nil ? suggestedName(forFilename: url.lastPathComponent) : nil

    if names.contains("manifest.json") && names.contains("pipeline-bundle.zip") {
      throw ImportRefusal(
        "unknown_archive",
        Say(
          "「\(url.lastPathComponent)」同時有 manifest.json 和 pipeline-bundle.zip，不像任何一種 ShrinkML 交付。",
          "\"\(url.lastPathComponent)\" has both manifest.json and pipeline-bundle.zip, which is no ShrinkML hand-over shape."))
    }
    if names.contains("manifest.json") {
      return try readCoreML(zip, url: url, identity: identity, name: name, pulled: pulled, stage: stage)
    }
    if names.contains("pipeline-bundle.zip") {
      return try readKit(zip, identity: identity, name: name ?? "InvoiceReader", deliverableID: pulled?.id, limits: limits, stage: stage)
    }
    let top = Set(files.map { $0.name.split(separator: "/").first.map(String.init) ?? $0.name }).sorted().prefix(8)
    throw ImportRefusal(
      "unknown_archive",
      Say(
        "「\(url.lastPathComponent)」不像 ShrinkML 的交付：裡面沒有 manifest.json（模型交付）也沒有 pipeline-bundle.zip（發票交付）。最上層有：\(top.joined(separator: "、"))。",
        "\"\(url.lastPathComponent)\" does not look like a ShrinkML hand-over: it has neither manifest.json (a model hand-over) nor pipeline-bundle.zip (an invoice hand-over). Top level: \(top.joined(separator: ", "))."))
  }

  // MARK: Core ML bundle

  private static func parseJSON(_ data: Data, what: String) throws -> JSONValue {
    do {
      return try StrictJSON.parse(data)
    } catch let error as JSONParseError {
      throw ImportRefusal(
        "manifest_invalid",
        Say("\(what) 不是合法的 JSON（\(error.reason)）。", "\(what) is not valid JSON (\(error.reason))."))
    }
  }

  static let flatName = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

  static func isFlatName(_ text: String) -> Bool {
    flatName.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  /// The README and the sample code a Core ML or ONNX hand-over carries beside the model since
  /// v1-flow-fixes F2: `README.txt`, and one file per sample language the hand-over page shows
  /// (`shrinkml_predict.py`, `<Type>.swift`, `<Type>.cs`) at the top of the zip. They are read-only
  /// records like `OWNERSHIP.txt`: kept under `Records/<Name>/r<n>/` (the samples in `samples/`,
  /// outside `Sources/`, so a sample is never compiled into the package), never taken for a model
  /// file or a sidecar. Only a flat file name with one of these three endings qualifies, and the
  /// manifest's own `files` take precedence, so nothing else gets in this way.
  static let readmeMember = "README.txt"
  static let sampleSuffixes = [".py", ".swift", ".cs"]

  static func isSampleFile(_ name: String) -> Bool {
    isFlatName(name) && sampleSuffixes.contains { name.hasSuffix($0) }
  }

  /// The folder a Package carries the Swift runtime in: `ShrinkMLRuntime`, a SwiftPM package that the
  /// Package's own `Package.swift` and Swift sample build against. An Xcode project keeps its own generated Swift file and
  /// does not use it, so the importer does not take the folder in; it does not refuse it either, when the manifest explains it.
  static let shippedRuntimeFolder = "runtime/swift/"

  /// Does `manifest.json` say, in its `package.runtimes`, that this Package ships the runtime in `runtime/swift`?
  static func manifestShipsTheSwiftRuntime(_ manifest: JSONValue) -> Bool {
    (manifest["package"]?["runtimes"]?.arrayValue ?? []).contains {
      $0["role"]?.stringValue == "ships" && $0["path"]?.stringValue == String(shippedRuntimeFolder.dropLast())
    }
  }

  private static func readCoreML(
    _ zip: ZipArchive, url: URL, identity: ArchiveIdentity, name suggested: String?, pulled: PulledName?, stage: StagingArea?
  ) throws -> Inspection {
    func bad(_ code: String, _ zh: String, _ en: String) -> ImportRefusal { ImportRefusal(code, Say(zh, en)) }
    let manifestEntry = zip.entry(named: "manifest.json")!
    let manifest = try parseJSON(
      try zip.contents(of: manifestEntry, maximumBytes: maximumManifestBytes), what: "manifest.json")
    guard manifest.objectValue != nil else {
      throw bad("manifest_invalid", "manifest.json 不是一個物件。", "manifest.json is not an object.")
    }
    if manifest["schema_version"]?.stringValue == "shrinkml.pipeline-bundle-manifest.v1" {
      throw bad(
        "bare_pipeline_bundle",
        "這是發票交付裡的 Pipeline Bundle 本身（開發者套件 zip 裡的 pipeline-bundle.zip 就是它）。匯入收的是開發者套件（附 runtime 與授權），所以這個檔先略過；開發者套件有的話，它的內容會一起匯入。",
        "This is the Pipeline Bundle of an invoice hand-over by itself (the pipeline-bundle.zip inside the developer kit is the same file). The import takes the developer kit (it brings the runtime and its licence), so this file is skipped; if the developer kit is here, its contents are imported.")
    }
    let type = manifest["type"]?.stringValue
    guard type == "shrinkml_coreml_bundle" else {
      let shown = type ?? "（沒寫 / missing）"
      throw bad(
        "unsupported_format",
        "這個交付的格式是「\(shown)」，不是 Core ML（shrinkml_coreml_bundle）；Xcode 匯入只收 Core ML 的交付（ONNX 是給 Windows、Linux 用的）。",
        "This hand-over's format is \"\(shown)\", not Core ML (shrinkml_coreml_bundle); the Xcode import takes Core ML hand-overs only (ONNX is for Windows and Linux).")
    }
    guard let road = manifest["task_key"]?.stringValue, !road.isEmpty else {
      throw bad(
        "manifest_invalid", "manifest.json 沒有寫這個模型屬於哪一條路（task_key），無法匯入。",
        "manifest.json does not say which road the model belongs to (task_key), so it cannot be imported.")
    }
    guard packageRoad(for: road) != nil else {
      let list = roadList
      throw bad(
        "unsupported_road",
        "這個交付屬於「\(road)」這條路。Xcode 匯入收這六條有套件版 Swift 檔的路：\(list.zh)，加上發票（\(kitRoad)，開發者套件）。其他路目前沒有放得進套件的 Swift 檔，所以先不收。沒有寫任何東西。",
        "This hand-over is on the road \"\(road)\". The Xcode import takes the six roads that have a package flavour of the Swift file: \(list.en), plus invoices (\(kitRoad), the developer kit). The other roads have no Swift file that fits in a package yet, so they are not taken. Nothing was written.")
    }
    // One model (single_graph) or two parts (encoder_decoder_split); a manifest that says nothing is one.
    let shape = manifest["pipeline_shape"]?.stringValue ?? "single_graph"
    guard let wanted = shapes[shape] else {
      throw bad(
        "unsupported_shape",
        "這個交付的 pipeline_shape 是「\(shape)」；匯入認得 single_graph（一個模型）和 encoder_decoder_split（兩個模型）。",
        "The pipeline_shape of this hand-over is \"\(shape)\"; the import knows single_graph (one model) and encoder_decoder_split (two models).")
    }
    let listed = (manifest["artifacts"]?.arrayValue ?? []).compactMap(\.stringValue)
    guard manifest["artifacts"]?.arrayValue?.count == wanted, listed.count == wanted,
      listed.allSatisfy({ $0.hasSuffix(".mlpackage") && isFlatName($0) }), PathKey.collisions(in: listed).isEmpty
    else {
      throw bad(
        "manifest_invalid",
        "manifest.json 的 artifacts 在 \(shape) 時應該剛好是 \(wanted) 個互不相同的 .mlpackage 資料夾名稱。",
        "The artifacts of manifest.json should be exactly \(wanted) different .mlpackage folder name(s) for \(shape).")
    }
    let packages = listed.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
    // The compiled copies of a hand-over made by a recent ShrinkML: per .mlpackage a `<name>.mlmodelc` folder, named by the
    // manifest's `precompiled` record. A manifest without the key (a hand-over made before) has none.
    var compiledPackages: [String] = []
    if let record = manifest["precompiled"], !record.isNull {
      let source = Set(packages)
      guard record["schema"]?.stringValue == "shrinkml.precompiled-models.v1", let models = record["models"]?.arrayValue else {
        throw bad(
          "manifest_invalid",
          "manifest.json 的 precompiled 要有 schema（shrinkml.precompiled-models.v1）和 models 清單。",
          "precompiled in manifest.json needs the schema shrinkml.precompiled-models.v1 and a models list.")
      }
      for (position, item) in models.enumerated() {
        guard let origin = item["source"]?.stringValue, source.contains(origin),
          let member = item["member"]?.stringValue, isFlatName(member), member.hasSuffix(".mlmodelc"), !compiledPackages.contains(member)
        else {
          throw bad(
            "manifest_invalid",
            "manifest.json 的 precompiled.models[\(position)] 要寫一個 artifacts 裡的 .mlpackage（source）和一個不重複的單層 .mlmodelc 資料夾名稱（member）。",
            "precompiled.models[\(position)] of manifest.json needs a source that is one of the artifacts and a distinct flat .mlmodelc folder name (member).")
        }
        compiledPackages.append(member)
      }
      if PathKey.collisions(in: compiledPackages + packages).isEmpty == false {
        throw bad(
          "manifest_invalid", "manifest.json 的 precompiled 資料夾名稱和 artifacts 的名稱撞名。",
          "A folder name of precompiled in manifest.json clashes with a name of the artifacts.")
      }
      compiledPackages.sort { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
    }
    var declared: [String: (sha256: String, size: Int)] = [:]
    var declaredOrder: [String] = []
    let reserved = ["manifest.json", "OWNERSHIP.txt", readmeMember, PackageFlavourFile.memberName]
    for (position, item) in (manifest["files"]?.arrayValue ?? []).enumerated() {
      guard let file = item["file"]?.stringValue, isFlatName(file),
        let digest = item["sha256"]?.stringValue, SHA256Hex.isValid(digest),
        let size = item["size_bytes"]?.intValue, size >= 0
      else {
        throw bad(
          "manifest_invalid",
          "manifest.json 的 files[\(position)] 要有 file（單層檔名）、sha256（64 個小寫十六進位字元）和 size_bytes。",
          "files[\(position)] of manifest.json needs a flat file name, a 64-character lower-case hex sha256 and a size_bytes.")
      }
      if reserved.contains(file) || file.hasSuffix(".mlpackage") || file.hasSuffix(".mlmodelc") || declared[file] != nil
        || declared.keys.contains(where: { PathKey.key($0) == PathKey.key(file) })
      {
        throw bad(
          "manifest_invalid", "manifest.json 的 files 裡「\(file)」重複，或跟保留的名稱衝突。",
          "\"\(file)\" in the files of manifest.json repeats or clashes with a reserved name.")
      }
      declared[file] = (digest, Int(size))
      declaredOrder.append(file)
    }

    // A pulled file's name is the CLI's, so the model is named by what the manifest calls it.
    let name = suggested ?? moduleName(fromWords: manifest["model"]?.stringValue ?? "")
    let typeName = TypeName.derive(from: name)
    // Every file of the hand-over goes into one folder, `Models/<Type>`, inside the revision's folder:
    // the folder a package flavour of the Swift file looks in (and the one `.copy` declares).
    let modelFolder = TypeName.resourceDirectory(for: typeName) + "/"

    var members: [Member] = []
    var unexpected: [String] = []
    let explainsTheRuntime = manifestShipsTheSwiftRuntime(manifest)
    var packageManifests = Set<String>()
    var compiledMarkers = Set<String>()
    var topLevel = Set<String>()
    var inZipRecord: ZipEntry?
    for entry in zip.entries where entry.kind == .file {
      let entryName = entry.name
      if !entryName.contains("/") { topLevel.insert(entryName) }
      if entryName == "manifest.json" {
        members.append(Member(entryName: entryName, destination: .resources, relativePath: modelFolder + entryName, role: .manifest, sha256: "", size: 0))
      } else if entryName == "OWNERSHIP.txt" {
        members.append(Member(entryName: entryName, destination: .records, relativePath: entryName, role: .record, sha256: "", size: 0))
      } else if entryName == PackageFlavourFile.memberName {
        inZipRecord = entry
        members.append(Member(entryName: entryName, destination: .records, relativePath: entryName, role: .record, sha256: "", size: 0))
      } else if let package = packages.first(where: { entryName.hasPrefix($0 + "/") }) {
        if entryName == package + "/Manifest.json" { packageManifests.insert(package) }
        members.append(Member(entryName: entryName, destination: .resources, relativePath: modelFolder + entryName, role: .model, sha256: "", size: 0))
      } else if let compiled = compiledPackages.first(where: { entryName.hasPrefix($0 + "/") }) {
        if entryName == compiled + "/coremldata.bin" { compiledMarkers.insert(compiled) }
        members.append(Member(entryName: entryName, destination: .resources, relativePath: modelFolder + entryName, role: .model, sha256: "", size: 0))
      } else if declared[entryName] != nil {
        members.append(Member(entryName: entryName, destination: .resources, relativePath: modelFolder + entryName, role: .sidecar, sha256: "", size: 0))
      } else if entryName == readmeMember {
        members.append(Member(entryName: entryName, destination: .records, relativePath: entryName, role: .record, sha256: "", size: 0))
      } else if isSampleFile(entryName) {
        members.append(Member(entryName: entryName, destination: .records, relativePath: "samples/" + entryName, role: .record, sha256: "", size: 0))
      } else if explainsTheRuntime && entryName.hasPrefix(shippedRuntimeFolder) {
        // The runtime the Swift sample builds against: named in the manifest, not part of the Xcode project.
        continue
      } else {
        unexpected.append(entryName)
      }
    }
    if !unexpected.isEmpty {
      throw bad(
        "unexpected_members",
        "交付裡有 manifest.json 沒提到的檔案：\(unexpected.prefix(5).joined(separator: "、"))\(unexpected.count > 5 ? " 等 \(unexpected.count) 個" : "")。一個檔案都不收沒說明的東西，整包沒有匯入。",
        "The hand-over holds files its manifest does not mention: \(unexpected.prefix(5).joined(separator: ", "))\(unexpected.count > 5 ? " and \(unexpected.count - 5) more" : ""). Nothing unexplained is taken in; the whole archive was refused.")
    }
    for package in packages where !packageManifests.contains(package) {
      throw bad(
        "manifest_invalid", "\(package) 裡沒有 Manifest.json，不是一個完整的 .mlpackage。",
        "\(package) has no Manifest.json, so it is not a complete .mlpackage.")
    }
    for compiled in compiledPackages where !compiledMarkers.contains(compiled) {
      throw bad(
        "manifest_invalid", "\(compiled) 裡沒有 coremldata.bin，不是一個完整的 .mlmodelc。",
        "\(compiled) has no coremldata.bin, so it is not a complete .mlmodelc.")
    }
    for file in declaredOrder where !members.contains(where: { $0.entryName == file }) {
      throw bad(
        "manifest_invalid", "manifest.json 說有「\(file)」，壓縮檔裡卻沒有。", "manifest.json lists \"\(file)\" but the archive does not hold it.")
    }

    // The package flavour of the Swift file, when this hand-over comes with the answer of the route:
    // as a member of the zip, or beside it. Only for a name and a type the import will accept (anything
    // else is refused by the planner, and a record for it would be read for nothing).
    var flavour: PackageFlavour?
    if ModelName.problem(in: name) == nil, TypeName.problem(in: typeName) == nil {
      let expectation = FlavourExpectation(
        typeName: typeName, pulledID: pulled?.id, archiveName: url.lastPathComponent,
        archiveMembers: topLevel.subtracting([PackageFlavourFile.memberName]).union(packages).union(compiledPackages),
        packages: packages, compiledPackages: compiledPackages)
      var inside: Data?
      if let entry = inZipRecord {
        guard entry.uncompressedSize <= UInt64(PackageFlavourFile.maximumRecordBytes) else {
          throw PackageFlavourFile.tooBig(PackageFlavourFile.memberName)
        }
        inside = try zip.contents(of: entry, maximumBytes: PackageFlavourFile.maximumRecordBytes)
      }
      let beside = try PackageFlavourFile.readCompanion(for: url)
      if let inside, let beside, inside != beside {
        let companion = PackageFlavourFile.companionName(for: url.lastPathComponent)
        throw bad(
          "flavour_two_records",
          "「\(url.lastPathComponent)」裡有 swift-package.json，旁邊又有 \(companion)，而且內容不一樣。不猜哪一個才對：請只留一個。",
          "\"\(url.lastPathComponent)\" holds a swift-package.json and there is a \(companion) beside it, and they differ. Which is right is not guessed: keep one.")
      }
      if let inside {
        flavour = try PackageFlavourFile.parse(inside, place: .insideTheArchive, expecting: expectation)
      } else if let beside {
        let companion = PackageFlavourFile.companionName(for: url.lastPathComponent)
        flavour = try PackageFlavourFile.parse(beside, place: .besideTheArchive(companion), expecting: expectation)
        members.append(
          Member(
            entryName: PackageFlavourFile.memberName, destination: .records, relativePath: PackageFlavourFile.memberName,
            role: .record, sha256: SHA256Hex.of(beside), size: beside.count, viaCompanion: true))
      }
    }
    members.sort { Member.lessThan($0, $1) }
    try digest(&members, in: zip, declared: declared, stage: stage, model: name)
    if let flavour, let stage, let companion = members.first(where: { $0.viaCompanion }) {
      try StagingArea.stageBytes(flavour.recordBytes, to: stage.destination(for: companion, model: name))
    }

    let roles = manifest["roles"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let shipped: WhatShipped =
      roles.first.map { $0.hasPrefix("baseline_") ? .frozenBaseline : .trainedCandidate } ?? .notStated
    return Inspection(
      archive: identity, name: name, kind: .coremlBundle, road: road, format: "shrinkml_coreml_bundle",
      whatShipped: shipped, scorecard: .notRecorded, swiftRunsEndToEnd: flavour?.runsEndToEnd,
      deliverableID: pulled?.id ?? flavour?.deliverableID, members: members, modelPackages: packages,
      typeName: typeName, flavour: flavour, kit: nil)
  }

  // MARK: Pipeline Bundle kit

  static let kitFixedMembers: [String: (destination: Destination, relative: String, role: FileRole)] = [
    "pipeline-bundle.zip": (.resources, "pipeline-bundle.zip", .pipelineBundle),
    "OWNERSHIP.txt": (.records, "OWNERSHIP.txt", .record),
    "README.txt": (.records, "README.txt", .record),
    "Package.swift": (.records, "sample/Package.swift", .record),
    "Sources/ReadPipelineBundle/main.swift": (.records, "sample/Sources/ReadPipelineBundle/main.swift", .record),
  ]
  static let runtimePrefix = "ShrinkMLPipelineRuntime/"

  private static func readKit(
    _ zip: ZipArchive, identity: ArchiveIdentity, name: String, deliverableID: String?, limits: ZipLimits, stage: StagingArea?
  ) throws -> Inspection {
    func bad(_ code: String, _ zh: String, _ en: String) -> ImportRefusal { ImportRefusal(code, Say(zh, en)) }
    var members: [Member] = []
    var unexpected: [String] = []
    for entry in zip.entries where entry.kind == .file {
      if let fixed = kitFixedMembers[entry.name] {
        members.append(Member(entryName: entry.name, destination: fixed.destination, relativePath: fixed.relative, role: fixed.role, sha256: "", size: 0))
      } else if entry.name.hasPrefix(runtimePrefix) {
        members.append(Member(entryName: entry.name, destination: .runtime, relativePath: String(entry.name.dropFirst(runtimePrefix.count)), role: nil, sha256: "", size: 0))
      } else {
        unexpected.append(entry.name)
      }
    }
    if !unexpected.isEmpty {
      throw bad(
        "unexpected_members",
        "發票交付裡有不認得的檔案：\(unexpected.prefix(5).joined(separator: "、"))\(unexpected.count > 5 ? " 等 \(unexpected.count) 個" : "")。整包沒有匯入。",
        "The invoice hand-over holds files it should not: \(unexpected.prefix(5).joined(separator: ", "))\(unexpected.count > 5 ? " and \(unexpected.count - 5) more" : ""). The whole archive was refused.")
    }
    for required in ["pipeline-bundle.zip", runtimePrefix + "LICENSE", runtimePrefix + "Package.swift"]
    where !members.contains(where: { $0.entryName == required }) {
      throw bad(
        "kit_incomplete", "發票交付缺少「\(required)」。授權檔與 runtime 必須一起來。",
        "The invoice hand-over lacks \"\(required)\". The licence and the runtime must travel together.")
    }
    guard members.contains(where: { $0.destination == .runtime && $0.relativePath.hasPrefix("Sources/") }) else {
      throw bad("kit_incomplete", "發票交付裡的 runtime 沒有 Sources/。", "The runtime in the invoice hand-over has no Sources/.")
    }
    members.sort { Member.lessThan($0, $1) }

    // The licence names itself on its first line; it must be a ShrinkML Runtime Licence.
    let licenceEntry = zip.entry(named: runtimePrefix + "LICENSE")!
    let licenceText = String(decoding: try zip.contents(of: licenceEntry, maximumBytes: 1 << 20), as: UTF8.self)
    let licenceName = licenceText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    guard licenceName.hasPrefix("ShrinkML Runtime Licence"), licenceName.unicodeScalars.count <= 120,
      !looksLikeASecret(licenceName)
    else {
      throw bad(
        "kit_licence", "runtime 的 LICENSE 第一行不是「ShrinkML Runtime Licence …」，不能確定這是哪個授權，所以不匯入。",
        "The first line of the runtime's LICENSE is not \"ShrinkML Runtime Licence ...\", so it is not certain which licence this is; not imported.")
    }

    // The bundle inside: its manifest, every file digest, the runtime version it needs.
    let bundleEntry = zip.entry(named: "pipeline-bundle.zip")!
    guard bundleEntry.uncompressedSize <= UInt64(maximumNestedArchiveBytes) else {
      throw bad("kit_bundle_invalid", "pipeline-bundle.zip 太大了。", "pipeline-bundle.zip is too large.")
    }
    let bundleBytes = try zip.contents(of: bundleEntry, maximumBytes: maximumNestedArchiveBytes)
    var nestedLimits = ZipLimits()
    nestedLimits.maximumArchiveBytes = maximumNestedArchiveBytes
    nestedLimits.maximumEntries = 16
    nestedLimits.maximumEntryBytes = 8 << 20
    nestedLimits.maximumTotalBytes = 32 << 20
    let nested: ZipArchive
    do {
      nested = try ZipArchive(data: bundleBytes, limits: nestedLimits)
    } catch let refusal as ImportRefusal {
      throw bad(
        "kit_bundle_invalid", "pipeline-bundle.zip 打不開：\(refusal.say.zh)", "pipeline-bundle.zip cannot be opened: \(refusal.say.en)")
    }
    let manifestBytes: Data
    let manifest: JSONValue
    guard let nestedManifest = nested.entry(named: "manifest.json") else {
      throw bad("kit_bundle_invalid", "pipeline-bundle.zip 裡沒有 manifest.json。", "pipeline-bundle.zip has no manifest.json.")
    }
    manifestBytes = try nested.contents(of: nestedManifest, maximumBytes: maximumManifestBytes)
    manifest = try parseJSON(manifestBytes, what: "pipeline-bundle.zip 裡的 manifest.json")
    guard manifest["schema_version"]?.stringValue == "shrinkml.pipeline-bundle-manifest.v1",
      let bundleChecksum = manifest["bundle_checksum"]?.stringValue, SHA256Hex.isValid(bundleChecksum),
      let listed = manifest["files"]?.arrayValue
    else {
      throw bad("kit_bundle_invalid", "pipeline-bundle.zip 的 manifest.json 不是預期的格式。", "The manifest.json inside pipeline-bundle.zip is not in the expected format.")
    }
    var listedPaths = Set<String>()
    for item in listed {
      guard let path = item["path"]?.stringValue, let digest = item["sha256"]?.stringValue,
        let size = item["size_bytes"]?.intValue, let entry = nested.entry(named: path), entry.kind == .file
      else {
        throw bad("kit_bundle_invalid", "pipeline-bundle.zip 的 manifest.json 列了一個裡面沒有的檔案。", "The manifest inside pipeline-bundle.zip lists a file the bundle does not hold.")
      }
      let actual = SHA256Hex.of(try nested.contents(of: entry, maximumBytes: 8 << 20))
      guard actual == digest, Int(size) == Int(entry.uncompressedSize) else {
        throw bad(
          "kit_bundle_invalid", "pipeline-bundle.zip 裡的「\(path)」和 manifest.json 記的 sha256 或大小不一樣。",
          "\"\(path)\" inside pipeline-bundle.zip does not match the sha256 or size its manifest records.")
      }
      listedPaths.insert(path)
    }
    let unlisted = nested.entries.filter { $0.kind == .file && $0.name != "manifest.json" && !listedPaths.contains($0.name) }
    if !unlisted.isEmpty {
      throw bad("kit_bundle_invalid", "pipeline-bundle.zip 裡有 manifest.json 沒列的檔案。", "pipeline-bundle.zip holds files its manifest does not list.")
    }
    guard let contractEntry = nested.entry(named: "contract/pipeline.json"),
      let contract = try? StrictJSON.parse(try nested.contents(of: contractEntry, maximumBytes: maximumManifestBytes)),
      let runtimeVersion = contract["runtime_version"]?.stringValue,
      ["shrinkml.swift-invoice-runtime.v1", "shrinkml.swift-invoice-runtime.v2"].contains(runtimeVersion)
    else {
      throw bad(
        "kit_bundle_invalid", "pipeline-bundle.zip 裡的 contract/pipeline.json 讀不了，或 runtime 版本不是 v1／v2。",
        "contract/pipeline.json inside pipeline-bundle.zip is unreadable, or its runtime version is not v1 or v2.")
    }

    try digest(&members, in: zip, declared: [:], stage: stage, model: name)

    let treeLines = members.filter { $0.destination == .runtime }.map { "\($0.relativePath)\n\($0.sha256)\n" }
    let tree = SHA256Hex.of(Data(treeLines.joined().utf8))
    let bundleMember = members.first { $0.entryName == "pipeline-bundle.zip" }!
    let facts = KitFacts(
      runtimeVersion: runtimeVersion, bundleArchiveSHA256: bundleMember.sha256, bundleChecksum: bundleChecksum,
      manifestSHA256: SHA256Hex.of(manifestBytes), licenceName: licenceName, runtimeTreeSHA256: tree)
    return Inspection(
      archive: identity, name: name, kind: .pipelineKit, road: kitRoad, format: runtimeVersion,
      whatShipped: runtimeVersion.hasSuffix(".v2") ? .trainedCandidate : .frozenBaseline,
      scorecard: .notRecorded, swiftRunsEndToEnd: nil, deliverableID: deliverableID, members: members,
      modelPackages: [], typeName: nil, flavour: nil, kit: facts)
  }

  // MARK: One pass over the files

  /// Streams every file once: sha256 and size are computed, a declared digest must match, and when
  /// a staging area is given the same bytes are written there.
  private static func digest(
    _ members: inout [Member], in zip: ZipArchive, declared: [String: (sha256: String, size: Int)],
    stage: StagingArea?, model: String
  ) throws {
    for index in members.indices {
      let member = members[index]
      guard let entry = zip.entry(named: member.entryName) else { continue }
      let result = try StagingArea.copy(entry, from: zip, to: stage?.destination(for: member, model: model))
      members[index].sha256 = result.sha256
      members[index].size = result.size
      if let promise = declared[member.entryName] {
        guard promise.sha256 == result.sha256, promise.size == result.size else {
          throw ImportRefusal(
            "sidecar_digest_mismatch",
            Say(
              "「\(member.entryName)」的 sha256 或大小和 manifest.json 記的不一樣（記的是 \(promise.sha256)，實際是 \(result.sha256)）；沒有寫進你的專案。",
              "\"\(member.entryName)\" does not match the sha256 or size its manifest records (recorded \(promise.sha256), actual \(result.sha256)); nothing was written into your project."))
        }
      }
    }
  }
}
