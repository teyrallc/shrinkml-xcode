import Foundation

/// The Swift type the package flavour of a hand-over declares for one model (contract `build-run.v1-11`).
///
/// Every Core ML hand-over names its model file `model_fp32` (or `model_fp16`), and the Swift file the
/// server writes for a package takes the name of its type from the caller (`type_name`): two models
/// that were asked for the same type, or a type that is also a module of the package, would clash as
/// soon as one `import ShrinkMLModels` brings them in together. So the import chooses the name, one
/// per model, from the model's own name and nothing else, and asks the route for exactly that:
///
///   * the model name's words (split at `_`) are capitalised and joined, then `Model` is added, so the
///     type is never the module's own name (`Beans` the module holds `BeansModel` the type);
///   * the result must pass the route's own rules (`TypeName.problem`), which the corpus
///     `golden/xcode-import/type-names.json` of the ShrinkML repository pins on both sides;
///   * it is a pure function of the model name, so every revision, and every machine, asks for the
///     same type and an updated hand-over keeps the name its callers already use.
public enum TypeName {
  public static let maximumLength = 64
  static let suffix = "Model"

  public enum Problem: String, Equatable, Sendable, CaseIterable {
    case shape
    case denied
    case endsInError = "ends_in_error"
  }

  /// Names the generated Swift file uses unqualified: a type of the same name would shadow them
  /// (the same list as `_TYPE_NAME_DENYLIST` of `swift_package.py`; the corpus holds both to it).
  static let denied: Set<String> = [
    "Any", "AnyObject", "Array", "Bool", "Bundle", "Character", "Data", "Date", "Dictionary", "Double", "Error",
    "Float", "Foundation", "Int", "Int32", "Int64", "MLModel", "Never", "Optional", "Result", "Self", "Sendable",
    "Set", "String", "Substring", "Type", "URL", "UInt8", "UInt32", "UInt64", "Void",
  ]

  /// The type name asked for a model: its words capitalised and joined, then `Model`; cut so that it
  /// stays within `maximumLength`. Total: a name the import refuses anyway still gets an answer.
  public static func derive(from modelName: String) -> String {
    let words = modelName.split(separator: "_", omittingEmptySubsequences: true).map { word -> String in
      guard let first = word.first else { return "" }
      return first.uppercased() + word.dropFirst()
    }
    var stem = words.joined()
    if stem.isEmpty { stem = "Model" }
    if let first = stem.unicodeScalars.first, first.value >= 0x30 && first.value <= 0x39 { stem = "M" + stem }
    return String(stem.prefix(maximumLength - suffix.count)) + suffix
  }

  /// Why the route would refuse this type name, or nil when it accepts it.
  public static func problem(in typeName: String) -> Problem? {
    let scalars = Array(typeName.unicodeScalars)
    guard let first = scalars.first, scalars.count <= maximumLength, first.value >= 0x41 && first.value <= 0x5A,
      scalars.dropFirst().allSatisfy({
        ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
      })
    else { return .shape }
    if denied.contains(typeName) { return .denied }
    if typeName.hasSuffix("Error") { return .endsInError }
    return nil
  }

  /// The one Swift file of a package flavour: `<Type>.swift`.
  static func swiftFile(for typeName: String) -> String { typeName + ".swift" }

  /// The folder, inside the copied `Models` folder of a revision, that holds this model's files: the
  /// route's own default for the type, so asking for the type alone is enough.
  static func resourceDirectory(for typeName: String) -> String { "Models/" + typeName }
}
