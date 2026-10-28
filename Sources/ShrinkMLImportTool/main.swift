import Foundation
import ShrinkMLImportKit

/// `shrinkml-import`: a thin shell around `ImportCommand`, which holds everything that is tested.
let standardError = FileHandle.standardError
exit(
  ImportCommand.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    out: { print($0) },
    err: { standardError.write(Data(($0 + "\n").utf8)) }))
