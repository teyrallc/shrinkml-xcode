import Foundation

/// The one way the importer writes JSON that goes into git: the same bytes Python's
/// `json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True)` plus a final newline writes.
/// Keys sorted by code point, two-space indent, `": "` between a key and its value, `[]` and `{}`
/// for empty containers, everything outside printable ASCII written as `\uXXXX`. The same input
/// always gives the same bytes, which is what makes "import twice, no diff" a checkable promise,
/// and the corpus files of the ShrinkML repository that the tests read (`golden/xcode-import/`) are in this form.
public enum CanonicalJSON {
  public static func bytes(_ value: JSONValue) -> Data {
    var out = ""
    write(value, indent: 0, into: &out)
    out += "\n"
    return Data(out.utf8)
  }

  private static func write(_ value: JSONValue, indent: Int, into out: inout String) {
    switch value {
    case .null: out += "null"
    case .bool(let flag): out += flag ? "true" : "false"
    case .int(let whole): out += String(whole)
    case .double(let real): out += "\(real)"
    case .string(let text): writeString(text, into: &out)
    case .array(let items):
      if items.isEmpty {
        out += "[]"
        return
      }
      out += "[\n"
      for (position, item) in items.enumerated() {
        out += String(repeating: " ", count: indent + 2)
        write(item, indent: indent + 2, into: &out)
        out += position == items.count - 1 ? "\n" : ",\n"
      }
      out += String(repeating: " ", count: indent) + "]"
    case .object(let members):
      if members.isEmpty {
        out += "{}"
        return
      }
      out += "{\n"
      let keys = members.keys.sorted { lhs, rhs in
        lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) { $0.value < $1.value }
      }
      for (position, key) in keys.enumerated() {
        out += String(repeating: " ", count: indent + 2)
        writeString(key, into: &out)
        out += ": "
        write(members[key]!, indent: indent + 2, into: &out)
        out += position == keys.count - 1 ? "\n" : ",\n"
      }
      out += String(repeating: " ", count: indent) + "}"
    }
  }

  private static func writeString(_ text: String, into out: inout String) {
    out += "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{8}": out += "\\b"
      case "\u{c}": out += "\\f"
      default:
        if scalar.value >= 0x20 && scalar.value <= 0x7E {
          out.unicodeScalars.append(scalar)
        } else if scalar.value > 0xFFFF {
          let shifted = scalar.value - 0x10000
          out += hex4(0xD800 + (shifted >> 10)) + hex4(0xDC00 + (shifted & 0x3FF))
        } else {
          out += hex4(scalar.value)
        }
      }
    }
    out += "\""
  }

  private static func hex4(_ value: UInt32) -> String {
    let digits = String(value, radix: 16)
    return "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
  }
}
