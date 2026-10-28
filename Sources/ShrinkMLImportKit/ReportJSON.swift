import Foundation

/// `shrinkml-import --json`: the same report as the text, as ONE JSON document (`shrinkml.import-report.v1`) that a program
/// can read without taking words apart. The app's "Put in Xcode" reads it; the text a person sees in a terminal is unchanged.
///
/// Every key is always present (an empty list, `null`) so a reader never has to ask whether a key exists.
///
///     schema        "shrinkml.import-report.v1"
///     mode          "preview" (nothing was written) | "applied" | "stopped" (`--add --apply` found a refusal and put nothing
///                   anywhere) | "refused" (the whole run was refused) | "usage" (the command line was wrong)
///     status        0, 1 or 2: the exit status
///     package       the ShrinkMLModels folder, as an absolute path
///     creates_package  the folder has no lock yet: this import creates the package skeleton
///     added         null, or what `--add` did with the file: {filename, copied, replaced_earlier_copy, record_copied,
///                   removed_stale_record}
///     archives      one row per file looked at: {filename, sha256, outcome, model, revision, is_new_model, current, other,
///                   code, zh, en}; outcome is imports | already_current | already_imported_earlier | same_bytes_as | refused
///                   | ignored
///     models        what an import changes: {name, revision, previous_revision, road, type_name, swift_file, diff}
///     generated     the files the importer writes itself: {path, decision, new_path}; decision is create | replace | unchanged
///                   | keep_yours (the file is yours: it stays, the new text goes to new_path)
///     wrote         paths written (only when applied)
///     new_files     the `.new` files written beside files that are yours (only when applied)
///     warnings      [{zh, en}]
///     lines         the text report, line by line: [{zh, en}]
///     refusal       null, or {code, zh, en} when the whole run was refused
///     unexpected    null, or the text of a failure nobody foresaw
public enum ImportReportJSON {
  public static let schema = "shrinkml.import-report.v1"

  enum Mode {
    case run
    case usage
  }

  static func say(_ value: Say) -> [String: Any] { ["zh": value.zh, "en": value.en] }

  static func object(for execution: ImportCommand.Execution, mode: Mode, apply: Bool) -> [String: Any] {
    var document: [String: Any] = [
      "schema": schema,
      "status": Int(execution.status),
      "package": execution.package.path,
      "creates_package": execution.plan?.createsPackage ?? false,
      "added": NSNull(),
      "archives": [Any](),
      "models": [Any](),
      "generated": [Any](),
      "wrote": [Any](),
      "new_files": [Any](),
      "warnings": [Any](),
      "lines": [Any](),
      "refusal": NSNull(),
      "unexpected": NSNull(),
    ]
    switch mode {
    case .usage:
      document["mode"] = "usage"
    case .run:
      if execution.refusal != nil {
        document["mode"] = "refused"
      } else if execution.stoppedBeforeWriting {
        document["mode"] = "stopped"
      } else if execution.applied != nil {
        document["mode"] = "applied"
      } else {
        document["mode"] = "preview"
      }
    }
    if let refusal = execution.refusal {
      var row = say(refusal.say)
      row["code"] = refusal.code
      document["refusal"] = row
    }
    if let message = execution.unexpected { document["unexpected"] = message }
    if let say = execution.createPreview {
      document["lines"] = [self.say(say)]
      document["creates_package"] = true
    }
    if let added = execution.added {
      document["added"] = [
        "filename": added.filename,
        "copied": added.copied,
        "replaced_earlier_copy": added.replacedEarlierCopy,
        "record_copied": added.recordCopied,
        "removed_stale_record": added.removedStaleRecord,
      ]
    }
    guard let plan = execution.plan else { return document }

    document["archives"] = plan.archives.map(archiveRow)
    document["models"] = plan.models.map { model -> [String: Any] in
      let inspection = plan.inspections.first { $0.name == model.name }
      var row: [String: Any] = [
        "name": model.name,
        "revision": model.revision,
        "previous_revision": model.previousRevision.map { $0 as Any } ?? NSNull(),
        "road": model.road,
        "type_name": (inspection?.typeName).map { $0 as Any } ?? NSNull(),
        "swift_file": (inspection?.flavour?.swiftFile).map { $0 as Any } ?? NSNull(),
        "diff": NSNull(),
      ]
      if let diff = model.diff {
        row["diff"] = [
          "added": diff.added.count, "changed": diff.changed.count, "removed": diff.removed.count,
          "unchanged": diff.unchanged.count,
        ]
      }
      return row
    }
    document["generated"] = plan.generated.map { change -> [String: Any] in
      switch change.decision {
      case .create: return ["path": change.path, "decision": "create", "new_path": NSNull()]
      case .replace: return ["path": change.path, "decision": "replace", "new_path": NSNull()]
      case .unchanged: return ["path": change.path, "decision": "unchanged", "new_path": NSNull()]
      case .keepYoursWriteNew(let path): return ["path": change.path, "decision": "keep_yours", "new_path": path]
      }
    }
    if let applied = execution.applied {
      document["wrote"] = applied.wrote
      document["new_files"] = applied.newFiles
    }
    document["warnings"] = plan.warnings.map(say)
    document["lines"] =
      (execution.added.map { ImportReport.addedLines($0).map(say) } ?? [])
      + ImportReport.lines(plan: plan, applied: execution.applied).map(say)
    return document
  }

  static func archiveRow(_ report: ArchiveReport) -> [String: Any] {
    var row: [String: Any] = [
      "filename": report.filename,
      "sha256": report.sha256.map { $0 as Any } ?? NSNull(),
      "outcome": "",
      "model": NSNull(), "revision": NSNull(), "is_new_model": NSNull(), "current": NSNull(), "other": NSNull(),
      "code": NSNull(), "zh": NSNull(), "en": NSNull(),
    ]
    switch report.outcome {
    case .imports(let name, let revision, let isNew):
      row["outcome"] = "imports"
      row["model"] = name
      row["revision"] = revision
      row["is_new_model"] = isNew
    case .alreadyCurrent(let name, let revision):
      row["outcome"] = "already_current"
      row["model"] = name
      row["revision"] = revision
    case .alreadyImportedEarlier(let name, let revision, let current):
      row["outcome"] = "already_imported_earlier"
      row["model"] = name
      row["revision"] = revision
      row["current"] = current
    case .sameBytesAs(let other):
      row["outcome"] = "same_bytes_as"
      row["other"] = other
    case .refused(let refusal):
      row["outcome"] = "refused"
      row["code"] = refusal.code
      row["zh"] = refusal.say.zh
      row["en"] = refusal.say.en
    case .ignored(let why):
      row["outcome"] = "ignored"
      row["zh"] = why.zh
      row["en"] = why.en
    }
    return row
  }

  /// The document as one line of JSON text, keys sorted so the same run always prints the same bytes.
  static func text(for execution: ImportCommand.Execution, mode: Mode, apply: Bool) -> String {
    let document = object(for: execution, mode: mode, apply: apply)
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: data, encoding: .utf8)
    else { return "{\"schema\":\"\(schema)\",\"status\":1,\"mode\":\"refused\"}" }
    return text
  }
}
