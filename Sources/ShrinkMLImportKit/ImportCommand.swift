import Darwin
import Foundation

/// The command line of `shrinkml-import`, as a function: arguments in, text out, an exit status back.
/// The executable (`Sources/ShrinkMLImportTool/main.swift`) and the two command plugins call exactly
/// this, and the tests call it too, so what a person sees in a terminal or in Xcode is what is tested.
///
/// Exit status, the same three the ShrinkML CLI uses: 0 = it did what was asked and nothing was
/// refused; 1 = something was refused or failed (the text says what, and what was changed, if
/// anything); 2 = the command line itself was wrong.
public enum ImportCommand {
  public static let version = "shrinkml-import \(PublicRepository.current.from) (shrinkml.lock.v1)"

  public struct Arguments: Equatable, Sendable {
    /// false (the default) previews: reads, writes nothing.
    public var apply = false
    public var packageDirectory = "."
    public var inboxDirectory: String?
    public var importPackage: String?
    /// With `--apply`: make the ShrinkMLModels folder if it does not exist yet (the first import).
    public var create = false
    public var showHelp = false
    public var showVersion = false
    /// A hand-over zip to put in the Inbox and import (the app's "Put in Xcode"); see `InboxAdder`.
    public var add: String?
    /// Print one JSON document (`ImportReportJSON`) on standard output instead of the two-language text.
    public var json = false

    public init() {}
  }

  public static var help: Say {
    Say(
      """
      shrinkml-import：把 ShrinkML 的交付 zip 匯入 ShrinkMLModels 套件（離線；不連網、不需要任何金鑰）。
      用法：shrinkml-import [--apply [--create]] [--package <ShrinkMLModels 資料夾>] [--inbox <資料夾>] [--add <交付 zip>] [--json] [--import-package <路徑>]
        （不加 --apply）  預覽：顯示會發生什麼，不寫任何東西
        --apply           匯入：先驗證 sha256、路徑與大小，再寫入；中途失敗不會留下半套
        --create          （搭配 --apply）ShrinkMLModels 資料夾還不存在時，建立它（第一次匯入用；打錯路徑時不會憑空多出資料夾）
        --package         ShrinkMLModels 資料夾（預設：目前資料夾）
        --inbox           放交付 zip 的資料夾（預設：<package>/Inbox）
        --add             把這個交付 zip（旁邊若有 <名>.zip.swift-package.json 一起）放進 <package>/Inbox 再匯入，只匯入這一個；不加 --apply 時只預覽，什麼都不放。不蓋掉 Inbox 裡別人放的同名檔案；不能和 --inbox 一起用
        --json            輸出一份 JSON（shrinkml.import-report.v1）而不是文字，給程式讀
        --import-package  （開發用）本機的 ShrinkMLImport 套件在哪裡；第一次建立 Package.swift 時寫成 .package(path:)（相對於目前資料夾，或絕對路徑）。
                          不加的話，Package.swift 依賴公開的 ShrinkMLImport（.package(url:from:)）；這個版本還不知道公開網址時，就不寫相依
        --version, --help
      退出碼：0 完成；1 有東西被拒絕或失敗（文字會說明）；2 命令列不對。
      """,
      """
      shrinkml-import: imports ShrinkML hand-over zips into a ShrinkMLModels package (offline; no network, no key).
      Usage: shrinkml-import [--apply [--create]] [--package <ShrinkMLModels folder>] [--inbox <folder>] [--add <hand-over zip>] [--json] [--import-package <path>]
        (no --apply)      preview: shows what would happen, writes nothing
        --apply           import: checks sha256, paths and sizes first, then writes; a failure leaves no half import
        --create          (with --apply) make the ShrinkMLModels folder if it does not exist yet (for the first import; a mistyped path never makes a stray folder)
        --package         the ShrinkMLModels folder (default: the current folder)
        --inbox           where the hand-over zips are (default: <package>/Inbox)
        --add             put this hand-over zip (and <name>.zip.swift-package.json beside it, if there is one) in <package>/Inbox and import it, only it; without --apply it only previews and puts nothing anywhere. A file of the same name that someone else put in the Inbox is never overwritten; cannot be combined with --inbox
        --json            print one JSON document (shrinkml.import-report.v1) instead of text, for programs to read
        --import-package  (for development) where a local ShrinkMLImport checkout lives; written into Package.swift as .package(path:) when it is first created (relative to the current folder, or absolute).
                          Without it Package.swift depends on the public ShrinkMLImport by address (.package(url:from:))
        --version, --help
      Exit status: 0 done; 1 something was refused or failed (the text says what); 2 the command line is wrong.
      """)
  }

  public static func parse(_ arguments: [String]) -> Result<Arguments, ImportRefusal> {
    var parsed = Arguments()
    var index = 0
    func usage(_ zh: String, _ en: String) -> ImportRefusal { ImportRefusal("usage", Say(zh, en)) }
    func value(for flag: String) -> String? {
      index += 1
      return index < arguments.count && !arguments[index].hasPrefix("--") ? arguments[index] : nil
    }
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--apply": parsed.apply = true
      case "--create": parsed.create = true
      case "--help", "-h": parsed.showHelp = true
      case "--version": parsed.showVersion = true
      case "--json": parsed.json = true
      case "--package", "--inbox", "--import-package", "--add":
        guard let given = value(for: argument) else {
          return .failure(usage("\(argument) 後面要接一個路徑。", "\(argument) needs a path after it."))
        }
        switch argument {
        case "--package": parsed.packageDirectory = given
        case "--inbox": parsed.inboxDirectory = given
        case "--add": parsed.add = given
        default: parsed.importPackage = given
        }
      default:
        return .failure(
          usage("不認得的引數「\(argument)」。用 --help 看用法。", "Unknown argument \"\(argument)\". Use --help for usage."))
      }
      index += 1
    }
    if parsed.add != nil, parsed.inboxDirectory != nil {
      return .failure(usage("--add 和 --inbox 不能一起用（--add 放進的就是 <package>/Inbox）。", "--add and --inbox cannot be used together (--add puts the file in <package>/Inbox)."))
    }
    return .success(parsed)
  }

  /// What a run came to, before it is written out as text or as JSON.
  struct Execution {
    var status: Int32 = 0
    var package: URL
    var plan: ImportPlan?
    var applied: ApplyResult?
    var added: AddOutcome?
    /// The first import of a folder that does not exist yet, asked for without `--apply` (and without a file to plan).
    var createPreview: Say?
    var refusal: ImportRefusal?
    /// The run failed on something the importer did not foresee.
    var unexpected: String?
    /// `--add --apply` found a refusal in the plan and so put nothing in the Inbox.
    var stoppedBeforeWriting = false
  }

  /// Runs the command. `out` receives normal text, `err` receives refusals and failures; both get
  /// Chinese first and English under it. With `--json` everything is ONE JSON document on `out` (a refusal and a wrong
  /// command line too), and `err` stays empty.
  @discardableResult
  public static func run(
    arguments: [String], currentDirectory: URL, now: @escaping @Sendable () -> Date = { Date() },
    temporaryDirectory: URL? = nil, out: (String) -> Void, err: (String) -> Void
  ) -> Int32 {
    let parsed: Arguments
    switch parse(arguments) {
    case .failure(let refusal):
      if arguments.contains("--json") {
        out(ImportReportJSON.text(for: Execution(status: 2, package: currentDirectory, refusal: refusal), mode: .usage, apply: false))
        return 2
      }
      err(refusal.say.text)
      err(help.text)
      return 2
    case .success(let value):
      parsed = value
    }
    if parsed.showHelp {
      out(help.text)
      return 0
    }
    if parsed.showVersion {
      out(version)
      return 0
    }

    let execution = execute(
      parsed, currentDirectory: currentDirectory, now: now, temporaryDirectory: temporaryDirectory ?? Self.scratchRoot())
    if parsed.json {
      out(ImportReportJSON.text(for: execution, mode: .run, apply: parsed.apply))
      return execution.status
    }
    if let say = execution.createPreview {
      out(say.text)
      return 0
    }
    if let refusal = execution.refusal {
      err(refusal.say.text)
      return 1
    }
    if let message = execution.unexpected {
      err(
        Say(
          "匯入因為預期之外的錯誤停下來：\(message)。如果它發生在寫入途中，lock 檔沒有被改；再執行一次是安全的。",
          "The import stopped on an unexpected error: \(message). If it happened while writing, the lock file was not changed; running it again is safe."
        ).text)
      return 1
    }
    guard let plan = execution.plan else { return execution.status }
    if let added = execution.added { out(ImportReport.addedLines(added).map(\.text).joined(separator: "\n")) }
    out(ImportReport.text(plan: plan, applied: execution.applied))
    if execution.stoppedBeforeWriting {
      out(
        Say(
          "這個交付被拒絕了，所以沒有放進 Inbox，也沒有寫任何東西。",
          "This hand-over was refused, so nothing was put in the Inbox and nothing was written."
        ).text)
    } else if !parsed.apply, plan.hasChanges {
      out(
        Say(
          "這只是預覽，沒有寫任何東西。要匯入，請執行「匯入／更新 ShrinkML 模型」（或加 --apply）。",
          "This was a preview; nothing was written. To import, run \"Import / update ShrinkML models\" (or add --apply)."
        ).text)
    }
    return execution.status
  }

  /// Where a preview of a first import keeps its scratch folder. Foundation's `temporaryDirectory` ignores `$TMPDIR` on macOS (it asks the
  /// system for the user's own folder), so a program that runs this tool with a private working folder and a sandbox that writes
  /// nowhere else (ShrinkML Desktop's "Put in Xcode" does) could not have one made. `$TMPDIR` is used when it names a folder; otherwise
  /// the system's.
  static func scratchRoot(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let named = environment["TMPDIR"], !named.isEmpty {
      var isFolder: ObjCBool = false
      if FileManager.default.fileExists(atPath: named, isDirectory: &isFolder), isFolder.boolValue {
        return URL(fileURLWithPath: named, isDirectory: true)
      }
    }
    return FileManager.default.temporaryDirectory
  }

  static func execute(
    _ parsed: Arguments, currentDirectory: URL, now: @escaping @Sendable () -> Date, temporaryDirectory: URL
  ) -> Execution {
    func resolve(_ path: String) -> URL {
      URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
    }
    let package = resolve(parsed.packageDirectory)
    var execution = Execution(package: package)
    func options(package: URL, inbox: URL?, only: String? = nil) -> ImportOptions {
      ImportOptions(
        packageDirectory: package,
        inboxDirectory: inbox,
        importPackagePath: parsed.importPackage.map { resolve($0).path },
        onlyArchive: only,
        now: now)
    }
    var madeFolder = false
    do {
      if let addPath = parsed.add {
        try executeAdd(
          addPath: resolve(addPath), parsed: parsed, options: options, temporaryDirectory: temporaryDirectory,
          madeFolder: &madeFolder, into: &execution)
        return execution
      }
      let plainOptions = options(package: package, inbox: parsed.inboxDirectory.map(resolve))
      if parsed.create, SafeFS.kind(of: package) == nil {
        guard parsed.apply else {
          execution.createPreview = Say(
            "「\(package.path)」還不存在；加上 --apply 會建立它，並放進 ShrinkMLModels 套件的骨架。這只是預覽，沒有寫任何東西。",
            "\"\(package.path)\" does not exist yet; with --apply it is created with the ShrinkMLModels package skeleton. This was a preview; nothing was written.")
          return execution
        }
        try makeFolder(package)
      }
      let plan = try ImportPlanner.plan(plainOptions)
      execution.plan = plan
      if parsed.apply {
        execution.applied = try ImportApplier.apply(plan, options: plainOptions)
      }
      execution.status = plan.refusals.isEmpty ? 0 : 1
    } catch let refusal as ImportRefusal {
      execution.refusal = refusal
      execution.status = 1
    } catch {
      execution.unexpected = "\(error)"
      execution.status = 1
    }
    return execution
  }

  static func makeFolder(_ package: URL) throws {
    guard SafeFS.kind(of: package.deletingLastPathComponent()) == .directory, mkdir(package.path, 0o755) == 0 else {
      throw ImportRefusal(
        "write_failed",
        Say(
          "建不了資料夾「\(package.path)」（它上面那層要先存在）。",
          "Could not create the folder \"\(package.path)\" (the folder above it must exist first)."))
    }
  }

  /// `--add`: plan the one file where it is (nothing is written), and only if the plan refuses nothing put it in the Inbox and
  /// import it. A folder this run made and then had to give up on is taken away again when it is still empty.
  static func executeAdd(
    addPath: URL, parsed: Arguments, options: (URL, URL?, String?) -> ImportOptions, temporaryDirectory: URL,
    madeFolder: inout Bool, into execution: inout Execution
  ) throws {
    let package = execution.package
    let source = try InboxAdder.inspect(addPath)
    let sourceInbox = addPath.deletingLastPathComponent()
    var scratch: URL?
    defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }

    if SafeFS.kind(of: package) == nil, parsed.create {
      if parsed.apply {
        try makeFolder(package)
        madeFolder = true
      } else {
        // A preview of a first import: plan it in a scratch folder that is exactly an empty ShrinkMLModels, and remove that.
        let folder = temporaryDirectory.appendingPathComponent("shrinkml-import-preview-\(UUID().uuidString.lowercased())", isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else {
          throw ImportRefusal(
            "write_failed",
            Say("建不了預覽用的暫存資料夾。", "Could not create the scratch folder for the preview."))
        }
        scratch = folder
      }
    }
    func giveUp() {
      if madeFolder, (try? FileManager.default.contentsOfDirectory(atPath: package.path))?.isEmpty == true {
        rmdir(package.path)
      }
    }
    do {
      let first = try ImportPlanner.plan(options(scratch ?? package, sourceInbox, source.name))
      execution.plan = first
      execution.status = first.refusals.isEmpty ? 0 : 1
      guard parsed.apply else { return }
      guard first.refusals.isEmpty else {
        execution.stoppedBeforeWriting = true
        giveUp()
        return
      }
      let root = package.resolvingSymlinksInPath()
      let lock = first.currentLock
      execution.added = try InboxAdder.put(source, into: root, lock: lock)
      let real = options(package, nil, source.name)
      let plan = try ImportPlanner.plan(real)
      execution.plan = plan
      execution.applied = try ImportApplier.apply(plan, options: real)
      execution.status = plan.refusals.isEmpty ? 0 : 1
    } catch {
      giveUp()
      throw error
    }
  }
}
