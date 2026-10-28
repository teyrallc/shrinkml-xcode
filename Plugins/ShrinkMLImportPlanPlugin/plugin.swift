import Foundation
import PackagePlugin

/// 檢視匯入變更 (Show what an import would change): runs `shrinkml-import` without `--apply` on the
/// ShrinkMLModels package this plugin was run on. It asks for NO permission: it cannot write anything,
/// and the tool, run this way, writes nothing. It shows, for every zip in `ShrinkMLModels/Inbox`, whether
/// it would be imported, updated (with the files that differ) or refused, and why.
@main
struct ShrinkMLImportPlanPlugin: CommandPlugin {
  func performCommand(context: PluginContext, arguments: [String]) async throws {
    let tool = try context.tool(named: "ShrinkMLImportTool")
    try ImportToolRun.run(
      tool: tool.url, packageDirectory: context.package.directoryURL, extraArguments: arguments)
  }
}

#if canImport(XcodeProjectPlugin)
  import XcodeProjectPlugin

  extension ShrinkMLImportPlanPlugin: XcodeCommandPlugin {
    func performCommand(context: XcodePluginContext, arguments: [String]) throws {
      let tool = try context.tool(named: "ShrinkMLImportTool")
      let directory = try ImportToolRun.packageDirectory(
        inProject: context.xcodeProject.directoryURL, arguments: arguments)
      try ImportToolRun.run(tool: tool.url, packageDirectory: directory, extraArguments: arguments)
    }
  }
#endif

/// The preview half of the helper in ShrinkMLImportPlugin (a plugin target cannot link a library, so
/// each plugin carries its own): it never passes the tool `--apply`, whatever it was given.
enum ImportToolRun {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  /// Always this package, never `--apply`; of what a person typed only `--inbox` (and its value) is passed on.
  static func toolArguments(packageDirectory: URL, extraArguments: [String]) -> [String] {
    var out: [String] = ["--package", packageDirectory.path]
    var index = 0
    while index < extraArguments.count {
      if extraArguments[index] == "--inbox", index + 1 < extraArguments.count {
        out += ["--inbox", extraArguments[index + 1]]
        index += 2
      } else {
        index += (extraArguments[index] == "--package" && index + 1 < extraArguments.count) ? 2 : 1
      }
    }
    return out
  }

  static func run(tool: URL, packageDirectory: URL, extraArguments: [String]) throws {
    let process = Process()
    process.executableURL = tool
    process.arguments = toolArguments(packageDirectory: packageDirectory, extraArguments: extraArguments)
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw Failure(
        description:
          "shrinkml-import 結束時狀態為 \(process.terminationStatus)；原因在上面的文字。 / shrinkml-import ended with status \(process.terminationStatus); the reason is in the text above."
      )
    }
  }

  static func packageDirectory(inProject project: URL, arguments: [String]) throws -> URL {
    var chosen = project.appendingPathComponent("ShrinkMLModels", isDirectory: true)
    if let position = arguments.firstIndex(of: "--package"), position + 1 < arguments.count {
      chosen = URL(fileURLWithPath: arguments[position + 1], relativeTo: project)
    }
    chosen = chosen.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: chosen.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw Failure(
        description:
          "找不到 ShrinkMLModels 資料夾（\(chosen.path)）。 / The ShrinkMLModels folder was not found (\(chosen.path))."
      )
    }
    return chosen
  }
}
