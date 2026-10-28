import Foundation

/// `ShrinkMLModels/shrinkml.lock.json`, schema `shrinkml.lock.v1` (the ShrinkML contract `xcode-import.v1`).
/// It pins what an import wrote: for every model its revision, the archive it came from, every file
/// with its sha256, and where the numbers on its card came from. It holds no key, no token, no URL.
public struct Lock: Equatable, Sendable {
  public static let schema = "shrinkml.lock.v1"

  /// Files the importer wrote that belong to no one model (`Package.swift`, `.gitignore`, the umbrella).
  public var generated: [TrackedFile]
  /// Sorted by name.
  public var models: [LockedModel]

  public init(generated: [TrackedFile] = [], models: [LockedModel] = []) {
    self.generated = generated
    self.models = models
  }

  public static let empty = Lock()

  public func model(named name: String) -> LockedModel? {
    models.first { $0.name == name }
  }
}

public struct TrackedFile: Equatable, Sendable {
  public var path: String
  public var sha256: String
  public var sizeBytes: Int

  public init(path: String, sha256: String, sizeBytes: Int) {
    self.path = path
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
  }
}

public enum FileRole: String, Equatable, Sendable, CaseIterable {
  case model
  case sidecar
  case manifest
  case pipelineBundle = "pipeline_bundle"
  case record
}

public struct RecordedFile: Equatable, Sendable {
  public var path: String
  public var sha256: String
  public var sizeBytes: Int
  public var role: FileRole

  public init(path: String, sha256: String, sizeBytes: Int, role: FileRole) {
    self.path = path
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
    self.role = role
  }
}

public struct ArchiveIdentity: Equatable, Sendable {
  public var filename: String
  public var sha256: String
  public var sizeBytes: Int

  public init(filename: String, sha256: String, sizeBytes: Int) {
    self.filename = filename
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
  }
}

public enum ModelKind: String, Equatable, Sendable, CaseIterable {
  case coremlBundle = "coreml_bundle"
  case pipelineKit = "pipeline_kit"
}

public enum WhatShipped: String, Equatable, Sendable, CaseIterable {
  case trainedCandidate = "trained_candidate"
  case frozenBaseline = "frozen_baseline"
  case notStated = "not_stated"
}

public enum ScorecardStatus: String, Equatable, Sendable, CaseIterable {
  case measured
  case inheritedUnchanged = "inherited_unchanged"
  case staleNeedsRerun = "stale_needs_rerun"
  case notMeasured = "not_measured"
  /// The importer's own word: the archive it read carried no scorecard. NOT the same as `notMeasured`.
  case notRecorded = "not_recorded"
}

public struct Scorecard: Equatable, Sendable {
  public var status: ScorecardStatus
  public var digest: String?
  public var writtenIn: String?

  public init(status: ScorecardStatus, digest: String?, writtenIn: String?) {
    self.status = status
    self.digest = digest
    self.writtenIn = writtenIn
  }

  /// What an archive with no scorecard gets. Never `measured`.
  public static let notRecorded = Scorecard(status: .notRecorded, digest: nil, writtenIn: nil)
}

public struct RuntimePin: Equatable, Sendable {
  public static let needs = "ShrinkMLPipelineRuntime"
  public static let keptIn = ".shrinkml/runtime"

  public var licence: String
  public var treeSHA256: String

  public init(licence: String, treeSHA256: String) {
    self.licence = licence
    self.treeSHA256 = treeSHA256
  }
}

public struct PreviousRevision: Equatable, Sendable {
  public var revision: Int
  public var archive: ArchiveIdentity
  public var files: [RecordedFile]
  public var importedAt: String

  public init(revision: Int, archive: ArchiveIdentity, files: [RecordedFile], importedAt: String) {
    self.revision = revision
    self.archive = archive
    self.files = files
    self.importedAt = importedAt
  }
}

public struct LockedModel: Equatable, Sendable {
  public var name: String
  public var road: String
  public var kind: ModelKind
  public var revision: Int
  public var deliverableID: String?
  public var whatShipped: WhatShipped
  public var format: String
  public var archive: ArchiveIdentity
  public var files: [RecordedFile]
  public var generated: [TrackedFile]
  public var scorecard: Scorecard
  public var swiftRunsEndToEnd: Bool?
  public var runtime: RuntimePin?
  public var importedAt: String
  public var previousRevisions: [PreviousRevision]

  public init(
    name: String, road: String, kind: ModelKind, revision: Int, deliverableID: String? = nil,
    whatShipped: WhatShipped, format: String, archive: ArchiveIdentity, files: [RecordedFile],
    generated: [TrackedFile], scorecard: Scorecard, swiftRunsEndToEnd: Bool?, runtime: RuntimePin?,
    importedAt: String, previousRevisions: [PreviousRevision]
  ) {
    self.name = name
    self.road = road
    self.kind = kind
    self.revision = revision
    self.deliverableID = deliverableID
    self.whatShipped = whatShipped
    self.format = format
    self.archive = archive
    self.files = files
    self.generated = generated
    self.scorecard = scorecard
    self.swiftRunsEndToEnd = swiftRunsEndToEnd
    self.runtime = runtime
    self.importedAt = importedAt
    self.previousRevisions = previousRevisions
  }

  /// The folders this model owns, by the layout in the contract.
  public var resourceDirectory: String { "Sources/\(name)/Resources/r\(revision)" }
  public var recordDirectory: String { "Records/\(name)/r\(revision)" }
  public var generatedDirectory: String { "Sources/\(name)/Generated" }
  public var overridesDirectory: String { "Sources/\(name)/Overrides" }
}

/// Lock <-> canonical bytes. Arrays are written sorted by path so the same state is the same bytes.
public enum LockCodec {
  public static func canonicalBytes(of lock: Lock) -> Data {
    CanonicalJSON.bytes(json(of: lock))
  }

  public static func json(of lock: Lock) -> JSONValue {
    .object([
      "schema": .string(Lock.schema),
      "generated": .array(sortedByPath(lock.generated).map(json(of:))),
      "models": .array(lock.models.sorted { $0.name < $1.name }.map(json(of:))),
    ])
  }

  static func sortedByPath(_ items: [TrackedFile]) -> [TrackedFile] {
    items.sorted { $0.path.unicodeScalars.lexicographicallyPrecedes($1.path.unicodeScalars) { $0.value < $1.value } }
  }

  static func sortedByPath(_ items: [RecordedFile]) -> [RecordedFile] {
    items.sorted { $0.path.unicodeScalars.lexicographicallyPrecedes($1.path.unicodeScalars) { $0.value < $1.value } }
  }

  static func json(of file: TrackedFile) -> JSONValue {
    .object([
      "path": .string(file.path), "sha256": .string(file.sha256), "size_bytes": .int(Int64(file.sizeBytes)),
    ])
  }

  static func json(of file: RecordedFile) -> JSONValue {
    .object([
      "path": .string(file.path), "sha256": .string(file.sha256), "size_bytes": .int(Int64(file.sizeBytes)),
      "role": .string(file.role.rawValue),
    ])
  }

  static func json(of archive: ArchiveIdentity) -> JSONValue {
    .object([
      "filename": .string(archive.filename), "sha256": .string(archive.sha256),
      "size_bytes": .int(Int64(archive.sizeBytes)),
    ])
  }

  static func json(of model: LockedModel) -> JSONValue {
    var runtime: JSONValue = .null
    if let pin = model.runtime {
      runtime = .object([
        "needs": .string(RuntimePin.needs), "licence": .string(pin.licence),
        "kept_in": .string(RuntimePin.keptIn), "tree_sha256": .string(pin.treeSHA256),
      ])
    }
    return .object([
      "name": .string(model.name),
      "road": .string(model.road),
      "kind": .string(model.kind.rawValue),
      "revision": .int(Int64(model.revision)),
      "deliverable_id": model.deliverableID.map(JSONValue.string) ?? .null,
      "what_shipped": .string(model.whatShipped.rawValue),
      "format": .string(model.format),
      "archive": json(of: model.archive),
      "files": .array(sortedByPath(model.files).map { json(of: $0) }),
      "generated": .array(sortedByPath(model.generated).map { json(of: $0) }),
      "scorecard": .object([
        "status": .string(model.scorecard.status.rawValue),
        "digest": model.scorecard.digest.map(JSONValue.string) ?? .null,
        "written_in": model.scorecard.writtenIn.map(JSONValue.string) ?? .null,
      ]),
      "swift_runs_end_to_end": model.swiftRunsEndToEnd.map(JSONValue.bool) ?? .null,
      "runtime": runtime,
      "imported_at": .string(model.importedAt),
      "previous_revisions": .array(
        model.previousRevisions.sorted { $0.revision < $1.revision }.map { previous in
          .object([
            "revision": .int(Int64(previous.revision)),
            "archive": json(of: previous.archive),
            "files": .array(sortedByPath(previous.files).map { json(of: $0) }),
            "imported_at": .string(previous.importedAt),
          ])
        }),
    ])
  }
}
