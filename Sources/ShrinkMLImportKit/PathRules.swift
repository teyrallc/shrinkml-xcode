import Foundation

/// The rules for a relative path that came out of an archive or that the lock records.
/// One rule set serves both: an archive member name is checked with it before anything is
/// written, and every path in the lock is checked with it before anything is trusted.
/// The contract `xcode-import.v1` lists the rules; `golden/xcode-import/paths.json` of the ShrinkML repository
/// holds a row for each, and the lock JSON Schema's pattern is held to the same rows.
public enum ArchivePath {
  public enum Problem: String, Equatable, Sendable, CaseIterable {
    case empty
    case absolute
    case backslash
    case driveLetter = "drive_letter"
    case nul
    case control
    case dotdot
    case dot
    case emptyComponent = "empty_component"
    case namedfork
    case trailingSlash = "trailing_slash"
    case tooLong = "too_long"
  }

  public static let maximumBytes = 1024
  public static let maximumComponentBytes = 255

  /// The first rule the path breaks, or nil when the path is acceptable.
  public static func problem(in path: String) -> Problem? {
    if path.isEmpty { return .empty }
    let bytes = Array(path.utf8)
    if bytes.contains(0) { return .nul }
    if bytes.contains(UInt8(ascii: "\\")) { return .backslash }
    if bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }) { return .control }
    if bytes.count > maximumBytes { return .tooLong }
    if bytes.first == UInt8(ascii: "/") { return .absolute }
    if bytes.count >= 2, bytes[1] == UInt8(ascii: ":"),
      (bytes[0] >= UInt8(ascii: "A") && bytes[0] <= UInt8(ascii: "Z"))
        || (bytes[0] >= UInt8(ascii: "a") && bytes[0] <= UInt8(ascii: "z"))
    {
      return .driveLetter
    }
    if bytes.last == UInt8(ascii: "/") { return .trailingSlash }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    for component in components {
      if component.isEmpty { return .emptyComponent }
      if component == "." { return .dot }
      if component == ".." { return .dotdot }
      if component.lowercased() == "..namedfork" { return .namedfork }
      if component.utf8.count > maximumComponentBytes { return .tooLong }
    }
    return nil
  }

  public static func isAcceptable(_ path: String) -> Bool { problem(in: path) == nil }

  /// The path's components. Only call this on a path that passed `problem(in:)`.
  public static func components(_ path: String) -> [String] {
    path.split(separator: "/").map(String.init)
  }

  /// A zip directory entry spells itself with one trailing slash; the rules apply without it.
  public static func withoutDirectorySlash(_ name: String) -> String {
    name.hasSuffix("/") && !name.hasSuffix("//") ? String(name.dropLast()) : name
  }
}

/// Names the importer gives to a model: the folder `Sources/<Name>`, the Swift module `<Name>`.
public enum ModelName {
  public enum Problem: String, Equatable, Sendable, CaseIterable {
    case empty
    case tooLong = "too_long"
    case startsWithDigit = "starts_with_digit"
    case startsWithUnderscore = "starts_with_underscore"
    case dash
    case space
    case nonASCII = "non_ascii"
    case punctuation
    case reserved
  }

  public static let maximumLength = 64

  /// Names a model may not take (compared ignoring case): this package's own modules and the
  /// system modules an app imports, so `import <Name>` can never mean something else.
  public static let reserved: Set<String> = Set(
    [
      "ShrinkMLModels", "ShrinkMLPipelineRuntime", "ShrinkMLImportKit", "ShrinkMLImport",
      "Swift", "SwiftOnoneSupport", "Foundation", "Dispatch", "Darwin", "Observation", "Combine",
      "SwiftUI", "SwiftData", "UIKit", "AppKit", "CoreML", "CreateML", "Vision", "NaturalLanguage",
      "Speech", "Accelerate", "Compression", "CryptoKit", "Security", "CoreGraphics", "CoreImage",
      "CoreVideo", "CoreMedia", "AVFoundation", "Metal", "MetalKit", "MLCompute", "os", "Testing",
      "XCTest", "PackageDescription", "PackagePlugin", "Inbox", "Records", "Sources",
    ].map { $0.lowercased() })

  public static func problem(in name: String) -> Problem? {
    if name.isEmpty { return .empty }
    let scalars = Array(name.unicodeScalars)
    if scalars.count > maximumLength { return .tooLong }
    func isLetter(_ scalar: Unicode.Scalar) -> Bool {
      (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }
    func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }
    func classify(_ scalar: Unicode.Scalar) -> Problem {
      if scalar.value > 0x7F { return .nonASCII }
      if scalar == "-" { return .dash }
      if scalar == " " { return .space }
      return .punctuation
    }
    let first = scalars[0]
    if isDigit(first) { return .startsWithDigit }
    if first == "_" { return .startsWithUnderscore }
    if !isLetter(first) { return classify(first) }
    for scalar in scalars.dropFirst() where !(isLetter(scalar) || isDigit(scalar) || scalar == "_") {
      return classify(scalar)
    }
    if reserved.contains(name.lowercased()) { return .reserved }
    return nil
  }

  public static func isAcceptable(_ name: String) -> Bool { problem(in: name) == nil }
}

/// Which paths would be the same file on a case-insensitive file system. APFS and HFS+ both fold
/// case, and treat a precomposed letter and its decomposed spelling as one name, so the key
/// decomposes first and lower-cases second.
public enum PathKey {
  public static func key(_ path: String) -> String {
    path.decomposedStringWithCanonicalMapping.lowercased()
  }

  /// Every path (after the first of its kind) whose key was already taken, in input order.
  public static func collisions(in paths: [String]) -> [String] {
    var seen = Set<String>()
    var repeated: [String] = []
    for path in paths {
      if !seen.insert(key(path)).inserted { repeated.append(path) }
    }
    return repeated
  }
}
