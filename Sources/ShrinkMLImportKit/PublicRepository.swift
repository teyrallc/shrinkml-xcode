import Foundation

/// Where the public copy of this package (ShrinkMLImport) lives, so that a `ShrinkMLModels/Package.swift` can
/// depend on it by address. Without that dependency Xcode never shows the two import plug-ins for the
/// ShrinkMLModels package.
///
/// A `Package.swift` that is written without `--import-package <path>` depends on this repository:
///
///     .package(url: "<url>", from: "<from>"),
///
/// `--import-package <path>` stays for development against a checkout; the path wins over the address, and a
/// path an existing `Package.swift` already remembers wins too (see `Generators.importPackageMarker`).
///
/// The address is ONE constant, below. The repository is `teyrallc/shrinkml-xcode` on GitHub; the tag `v0.9.0`
/// (the version in `from:`) is pushed with the 0.9.0 release, after the freeze.
public struct PublicRepository: Sendable, Equatable {
  /// The repository's `https://` address. Anything else is not an address a manifest can depend on, so a
  /// `Package.swift` written for it carries no dependency (only the tests build such a value).
  public var url: String
  /// The first release a `Package.swift` accepts (SwiftPM's `from:`: this release and later ones of the same
  /// major version). It is the version `shrinkml-import --version` reports and the tag `v<from>` of the repository.
  public var from: String

  public init(url: String, from: String) {
    self.url = url
    self.from = from
  }

  /// The public repository and the first release a generated `Package.swift` accepts. The generator, the tests and
  /// the export script read this one line (the export script also tags the copy `v<from>`).
  public static let current = PublicRepository(url: "https://github.com/teyrallc/shrinkml-xcode.git", from: "0.9.0")

  /// true once `url` is a real address (starts with `https://`).
  public var isPublished: Bool { url.hasPrefix("https://") }

  /// The `Package.swift` line for this repository, or nil when `url` is not an `https://` address.
  var dependencyLine: String? {
    isPublished ? "    .package(url: \(Generators.literal(url)), from: \(Generators.literal(from)))," : nil
  }
}
