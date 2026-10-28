import Foundation

/// One sentence, said twice: 繁體中文 first, then English. Everything this package prints for a
/// person is a `Say`, so there is no message that exists in only one of the two languages.
public struct Say: Equatable, Sendable {
  public let zh: String
  public let en: String

  public init(_ zh: String, _ en: String) {
    self.zh = zh
    self.en = en
  }

  /// The two lines as they are printed: the Chinese line, then the English line.
  public var text: String { zh + "\n" + en }
}

/// A refusal: the import stopped, nothing was changed (or, for a failure after the first write,
/// the staging area was removed and the lock was not touched), and this says why.
public struct ImportRefusal: Error, Equatable, Sendable {
  /// A stable machine-readable code (`zip_slip`, `unsupported_road`, ...); tests and scripts use it.
  public let code: String
  public let say: Say

  public init(_ code: String, _ say: Say) {
    self.code = code
    self.say = say
  }
}
