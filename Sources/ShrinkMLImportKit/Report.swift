import Foundation

/// What the plugin and the tool print. Every line is a `Say`: 繁體中文 first, English under it.
public enum ImportReport {
  static func label(forRoad road: String) -> String {
    if let known = ArchiveReader.packageRoad(for: road) { return "\(known.zh) / \(known.en)" }
    if road == ArchiveReader.kitRoad { return "發票讀取 / invoice reader" }
    return road
  }

  public static func lines(plan: ImportPlan, applied: ApplyResult?) -> [Say] {
    var out: [Say] = []
    out.append(
      applied == nil
        ? Say("ShrinkML 匯入：預覽（沒有寫任何東西）", "ShrinkML import: preview (nothing was written)")
        : Say("ShrinkML 匯入：完成", "ShrinkML import: done"))
    if plan.createsPackage {
      out.append(Say("＋ 這個資料夾還沒有 shrinkml.lock.json：會建立 ShrinkMLModels 套件的骨架。", "+ There is no shrinkml.lock.json here yet: the ShrinkMLModels package skeleton will be created."))
    }
    if plan.archives.isEmpty {
      out.append(Say("Inbox 裡沒有 .zip 檔。把 ShrinkML 的交付 zip 放進 Inbox 再執行一次。", "There is no .zip file in the Inbox. Drop a ShrinkML hand-over zip in the Inbox and run again."))
    }
    for archive in plan.archives {
      let name = archive.filename
      switch archive.outcome {
      case .imports(let model, let revision, let isNew):
        if isNew {
          out.append(Say("＋ \(name) → 新模型 \(model)（r\(revision)）", "+ \(name) -> new model \(model) (r\(revision))"))
        } else {
          let planned = plan.models.first { $0.name == model }
          out.append(Say("↻ \(name) → \(model) 更新為 r\(revision)（舊的 r\(revision - 1) 留著，不刪）", "~ \(name) -> \(model) updated to r\(revision) (the old r\(revision - 1) stays; nothing is deleted)"))
          if let diff = planned?.diff {
            out.append(Say(
              "    新增 \(diff.added.count)、變更 \(diff.changed.count)、移除 \(diff.removed.count)、不變 \(diff.unchanged.count) 個檔案",
              "    \(diff.added.count) added, \(diff.changed.count) changed, \(diff.removed.count) removed, \(diff.unchanged.count) unchanged"))
            for path in diff.changed.prefix(8) { out.append(Say("    變更：\(path)", "    changed: \(path)")) }
            for path in diff.added.prefix(8) { out.append(Say("    新增：\(path)", "    added: \(path)")) }
            for path in diff.removed.prefix(8) { out.append(Say("    移除：\(path)", "    removed: \(path)")) }
          }
        }
        if let inspection = plan.inspections.first(where: { $0.name == model }) {
          let swiftZh: String
          let swiftEn: String
          if inspection.kind == .pipelineKit {
            swiftZh = "Swift 檔：交付附的是 runtime 原始碼（放在 .shrinkml/runtime，不進 git）與範例（在 Records/）；\(model)Runtime.swift 只負責打開 bundle，不讀發票"
            swiftEn = "Swift file: the kit carries the runtime source (kept in .shrinkml/runtime, not in git) and a sample (under Records/); \(model)Runtime.swift only opens the bundle, it does not read an invoice"
          } else if let flavour = inspection.flavour {
            let claim = flavour.runsEndToEnd.map { $0 ? "；紀錄說它能從輸入一路跑到預測（ShrinkML 的說法，匯入沒有執行）" : "；紀錄說它不能從輸入一路跑到預測" } ?? ""
            let claimEn = flavour.runsEndToEnd.map { $0 ? "; the record says it runs from an input to an answer (ShrinkML's claim; the import ran nothing)" : "; the record says it does not run from an input to an answer" } ?? ""
            swiftZh = "Swift 檔：套件版的 \(flavour.swiftFile)（來自 swift-package 路徑的回應，放在 Sources/\(model)/Generated/）\(claim)"
            swiftEn = "Swift file: the package flavour \(flavour.swiftFile) (from the reply of the swift-package route, in Sources/\(model)/Generated/)\(claimEn)"
          } else {
            swiftZh = "Swift 檔：交付裡沒有，只產生檔案位置的存取（不含前處理與解碼）"
            swiftEn = "Swift file: none in the hand-over, only file addresses are generated (no pre-processing or decoding)"
          }
          out.append(Say(
            "    路：\(label(forRoad: inspection.road))；成績單：壓縮檔沒有帶（記為 not_recorded，不是「沒量」也不是「量過」）；\(swiftZh)",
            "    road: \(label(forRoad: inspection.road)); scorecard: the archive carried none (recorded as not_recorded, which is neither \"not measured\" nor \"measured\"); \(swiftEn)"))
          // No record: say how to get the Swift file, in the words of the route.
          if inspection.kind == .coremlBundle, inspection.flavour == nil, let type = inspection.typeName {
            let how = PackageFlavourFile.howToGet(typeName: type, deliverableID: inspection.deliverableID, archiveName: inspection.archive.filename)
            out.append(Say("    ＊ \(how.zh)", "    * \(how.en)"))
          }
        }
      case .alreadyCurrent(let model, let revision):
        out.append(Say("＝ \(name)：已經匯入過（\(model) r\(revision)），沒有變更。", "= \(name): already imported (\(model) r\(revision)); no change."))
      case .alreadyImportedEarlier(let model, let revision, let current):
        out.append(Say("＝ \(name)：這是 \(model) 較早的 r\(revision)，目前是 r\(current)；沒有變更（要回到舊版請手動處理）。", "= \(name): this is the earlier r\(revision) of \(model), the current one is r\(current); no change (to go back, do it by hand)."))
      case .sameBytesAs(let other):
        out.append(Say("＝ \(name)：和 \(other) 內容完全相同，只算一份。", "= \(name): byte for byte the same as \(other); counted once."))
      case .refused(let refusal):
        out.append(Say("✗ \(name)：\(refusal.say.zh)", "x \(name): \(refusal.say.en)"))
      case .ignored(let why):
        out.append(Say("－ \(name)：\(why.zh)", "- \(name): \(why.en)"))
      }
    }
    for change in plan.generated {
      switch change.decision {
      case .create: out.append(Say("  寫入（新）\(change.path)", "  write (new) \(change.path)"))
      case .replace: out.append(Say("  寫入（上次匯入的版本沒被改過）\(change.path)", "  write (still exactly what the last import wrote) \(change.path)"))
      case .unchanged: break
      case .keepYoursWriteNew(let path):
        out.append(Say(
          "  ⚠ \(change.path) 被你改過，所以沒有蓋掉；新的內容在 \(path)，請自己比對合併。",
          "  ! \(change.path) was changed by you, so it was not overwritten; the new text is in \(path): compare and merge it yourself."))
      }
    }
    for warning in plan.warnings { out.append(Say("⚠ \(warning.zh)", "! \(warning.en)")) }
    if applied != nil, !plan.models.isEmpty {
      out.append(Say("Overrides/ 資料夾是你的，匯入沒有碰；Inbox 裡的 zip 沒有被移動或刪除。", "The Overrides/ folders are yours and were not touched; the zips in the Inbox were neither moved nor deleted."))
    }
    return out
  }

  /// What `--add` did with the file it was given.
  public static func addedLines(_ added: AddOutcome) -> [Say] {
    var out: [Say] = []
    if added.copied {
      out.append(
        added.replacedEarlierCopy
          ? Say("＋ 已放進 Inbox：\(added.filename)（換掉了上次匯入時放進去的同名檔案）", "+ put in the Inbox: \(added.filename) (it replaced the copy an earlier import put there)")
          : Say("＋ 已放進 Inbox：\(added.filename)", "+ put in the Inbox: \(added.filename)"))
    } else {
      out.append(Say("＝ Inbox 裡已經有一模一樣的 \(added.filename)，沒有再放一次。", "= the Inbox already holds exactly this \(added.filename); it was not put there again."))
    }
    if added.recordCopied {
      out.append(Say("＋ 套件版 Swift 檔的回應也放進去了（\(PackageFlavourFile.companionName(for: added.filename))）", "+ the saved swift-package reply went in too (\(PackageFlavourFile.companionName(for: added.filename)))"))
    }
    if added.removedStaleRecord {
      out.append(Say("－ 上一份留在 Inbox 的 swift-package 回應不屬於這個新的 zip，已拿掉（是上次匯入放的，不是你的）。", "- the swift-package reply an earlier import left in the Inbox does not belong to this new zip and was taken away (the importer's own, not yours)."))
    }
    return out
  }

  public static func text(plan: ImportPlan, applied: ApplyResult?) -> String {
    lines(plan: plan, applied: applied).map(\.text).joined(separator: "\n")
  }
}
