// swift-tools-version:6.0
// ShrinkML Import: the local, offline half of "ShrinkML in Xcode".
//
// What this package is: a library (ShrinkMLImportKit) that reads the archive a ShrinkML hand-over
// gives you, checks it, and writes it into a local Swift package, ShrinkMLModels/, next to your
// Xcode project; a small command-line tool (shrinkml-import) around that library; and two command
// plugins around the tool, one that APPLIES an import and one that only SHOWS what it would change.
//
// What it is not: it has no network code, it holds and needs no key, and nothing in it is linked
// into your app. Your ShrinkMLModels/Package.swift depends on this package only so that its
// command plugins show up for that package; none of its products is a dependency of a model target.
//
// Tools version 6.0 is what makes the bundled swift-testing macros resolve under the Command Line
// Tools (the same reason ShrinkML's Pipeline Runtime package uses it). The language mode stays Swift 5.
import Foundation
import PackageDescription

/// Command Line Tools workaround, test target only. Measured in the Package.swift of ShrinkML's Pipeline
/// Runtime package (2026-09-28: 7 failures in 16 clean runs without it, 26 passes in 26 with it):
/// with the Command Line Tools' toolchain the default build engine sometimes loads only
/// `SwiftMacros` and not `TestingMacros`, so `@Test` fails with "plugin for module 'TestingMacros'
/// not found". Naming the CLT's own testing plugin directory makes the scan find it. It applies
/// ONLY when the Command Line Tools are the active developer directory and no other toolchain is
/// selected, so an Xcode toolchain never gets a plugin path from a different toolchain.
let commandLineToolsTestingPluginFlags: [String] = {
  let commandLineTools = "/Library/Developer/CommandLineTools"
  let environment = ProcessInfo.processInfo.environment
  guard environment["TOOLCHAINS"] == nil else { return [] }
  let active =
    environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
  guard active == commandLineTools else { return [] }
  let plugins = commandLineTools + "/usr/lib/swift/host/plugins/testing"
  return FileManager.default.fileExists(atPath: plugins) ? ["-plugin-path", plugins] : []
}()

/// The tests read the contract files of the ShrinkML repository, so they live and run there only. The public copy
/// of this package has no Tests folder and gets this same file unchanged: no Tests folder, no test target (SwiftPM
/// stops at a test target without sources).
let testTargets: [Target] =
  FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/ShrinkMLImportKitTests")
  ? [
    .testTarget(
      name: "ShrinkMLImportKitTests",
      dependencies: ["ShrinkMLImportKit"],
      swiftSettings: [.unsafeFlags(commandLineToolsTestingPluginFlags)]
    )
  ] : []

let package = Package(
  name: "ShrinkMLImport",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "ShrinkMLImportKit", targets: ["ShrinkMLImportKit"]),
    .executable(name: "shrinkml-import", targets: ["ShrinkMLImportTool"]),
    .plugin(name: "ShrinkMLImportPlugin", targets: ["ShrinkMLImportPlugin"]),
    .plugin(name: "ShrinkMLImportPlanPlugin", targets: ["ShrinkMLImportPlanPlugin"]),
  ],
  targets: [
    .target(name: "ShrinkMLImportKit"),
    .executableTarget(name: "ShrinkMLImportTool", dependencies: ["ShrinkMLImportKit"]),
    .plugin(
      name: "ShrinkMLImportPlugin",
      capability: .command(
        intent: .custom(
          verb: "shrinkml-import",
          description:
            "匯入／更新 ShrinkML 模型 (import or update the ShrinkML hand-overs in ShrinkMLModels/Inbox)"
        ),
        permissions: [
          .writeToPackageDirectory(
            reason:
              "ShrinkML 只會寫入 ShrinkMLModels 資料夾（Inbox 裡的交付檔、shrinkml.lock.json、Sources/、Records/、.shrinkml/）；不連網、不放任何金鑰。 / ShrinkML writes only inside the ShrinkMLModels folder; no network, no key."
          )
        ]
      ),
      dependencies: ["ShrinkMLImportTool"]
    ),
    .plugin(
      name: "ShrinkMLImportPlanPlugin",
      capability: .command(
        intent: .custom(
          verb: "shrinkml-import-plan",
          description:
            "檢視匯入變更（不寫入任何東西） (show what an import would change; writes nothing)"
        ),
        permissions: []
      ),
      dependencies: ["ShrinkMLImportTool"]
    ),
  ] + testTargets,
  swiftLanguageModes: [.v5]
)
