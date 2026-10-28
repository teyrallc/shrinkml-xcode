import Foundation
import PackagePlugin

/// 匯入／更新 ShrinkML 模型 (Import / update ShrinkML models): runs `shrinkml-import --apply` on the
/// ShrinkMLModels package this plugin was run on. It reads the zips in `ShrinkMLModels/Inbox` and writes
/// only inside the ShrinkMLModels folder; it has no network code and needs no key. It is a command
/// plugin, so it runs when a person chooses it and never by itself: nothing is imported, updated or
/// fetched in the background. To see what an import would change first, run the sibling plugin
/// ShrinkMLImportPlanPlugin ("shrinkml-import-plan"), which has no write permission at all.
@main
struct ShrinkMLImportPlugin: CommandPlugin {
  func performCommand(context: PluginContext, arguments: [String]) async throws {
    let tool = try context.tool(named: "ShrinkMLImportTool")
    let directory = context.package.directoryURL
    // Where this import package lives, so that a Package.swift written for the first time can point at
    // it, but ONLY when it is a local checkout (a development setup): a package fetched from its public
    // address sits in a cache folder, and writing that folder into Package.swift would turn the address
    // into a path that stops existing when the cache is cleaned. Then the tool is given nothing and writes
    // the address itself (or keeps what an existing Package.swift remembers).
    let importPackage = context.package.dependencies.first { $0.package.displayName == "ShrinkMLImport" }
    var localCheckout: URL?
    if let importPackage, case .local = importPackage.package.origin {
      localCheckout = importPackage.package.directoryURL
    }
    try ImportToolRun.run(
      tool: tool.url, mode: .apply, packageDirectory: directory, importPackage: localCheckout,
      extraArguments: arguments)
  }
}

#if canImport(XcodeProjectPlugin)
  import XcodeProjectPlugin

  extension ShrinkMLImportPlugin: XcodeCommandPlugin {
    /// The half Xcode runs on an .xcodeproj project. The ShrinkMLModels package is the folder of that
    /// name beside the project file unless `--package <folder>` says otherwise (the folder must be
    /// inside the project's folder: that is the only place the permission reaches).
    func performCommand(context: XcodePluginContext, arguments: [String]) throws {
      let tool = try context.tool(named: "ShrinkMLImportTool")
      let directory = try ImportToolRun.packageDirectory(
        inProject: context.xcodeProject.directoryURL, arguments: arguments)
      try ImportToolRun.run(
        tool: tool.url, mode: .apply, packageDirectory: directory, importPackage: nil, extraArguments: arguments)
    }
  }
#endif

/// Shared by the two halves above (and copied, because a plugin target cannot link a library).
enum ImportToolRun {
  enum Mode: String { case apply, preview }

  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  /// The arguments the tool is given: always this package, always this mode; of what a person typed
  /// only `--inbox` and `--import-package` (and their values) are passed on.
  static func toolArguments(
    mode: Mode, packageDirectory: URL, importPackage: URL?, extraArguments: [String]
  ) -> [String] {
    var out: [String] = mode == .apply ? ["--apply"] : []
    out += ["--package", packageDirectory.path]
    var passed = Set<String>()
    var index = 0
    while index < extraArguments.count {
      let flag = extraArguments[index]
      if (flag == "--inbox" || flag == "--import-package"), index + 1 < extraArguments.count {
        out += [flag, extraArguments[index + 1]]
        passed.insert(flag)
        index += 2
      } else {
        index += (flag == "--package" && index + 1 < extraArguments.count) ? 2 : 1
      }
    }
    if let importPackage, !passed.contains("--import-package") {
      out += ["--import-package", importPackage.path]
    }
    return out
  }

  static func run(
    tool: URL, mode: Mode, packageDirectory: URL, importPackage: URL?, extraArguments: [String]
  ) throws {
    let process = Process()
    process.executableURL = tool
    process.arguments = toolArguments(
      mode: mode, packageDirectory: packageDirectory, importPackage: importPackage, extraArguments: extraArguments)
    // The tool prints Chinese first and English under it; its output is the plugin's output.
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure(
        description:
          "shrinkml-import 結束時狀態為 \(process.terminationStatus)；原因在上面的文字。 / shrinkml-import ended with status \(process.terminationStatus); the reason is in the text above."
      )
    }
  }

  /// `--package <folder>` or `<project folder>/ShrinkMLModels`, which must exist and lie inside the project folder.
  static func packageDirectory(inProject project: URL, arguments: [String]) throws -> URL {
    var chosen = project.appendingPathComponent("ShrinkMLModels", isDirectory: true)
    if let position = arguments.firstIndex(of: "--package"), position + 1 < arguments.count {
      chosen = URL(fileURLWithPath: arguments[position + 1], relativeTo: project)
    }
    chosen = chosen.standardizedFileURL
    let root = project.standardizedFileURL.path
    guard chosen.path == root || chosen.path.hasPrefix(root + "/") else {
      throw Failure(
        description:
          "資料夾「\(chosen.path)」不在專案資料夾裡；外掛只有寫入專案資料夾的權限。 / The folder \"\(chosen.path)\" is not inside the project folder; the plugin may write only there."
      )
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: chosen.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw Failure(
        description:
          "找不到 ShrinkMLModels 資料夾（\(chosen.path)）。先建立它：在終端機執行 shrinkml-import --apply --create --package ShrinkMLModels（只有在本機開發時才加 --import-package <ShrinkMLImport 的路徑>），再把它加進專案。 / The ShrinkMLModels folder was not found (\(chosen.path)). Create it first: run shrinkml-import --apply --create --package ShrinkMLModels in a terminal (add --import-package <path to ShrinkMLImport> only when developing against a local checkout), then add it to the project."
      )
    }
    return chosen
  }
}
