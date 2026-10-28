import Foundation

/// A parsed JSON document. The importer reads three kinds of JSON written by other programs
/// (the lock, a bundle manifest, a bundle's pipeline contract). `JSONSerialization` accepts
/// duplicate keys (the last one wins), cannot tell `true` from `1`, and reads lone surrogates; a
/// file that goes into git and drives file writes deserves a stricter reader than that.
public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }
  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }
  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }
  public var intValue: Int64? {
    if case .int(let value) = self { return value }
    return nil
  }
  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }
  public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

public struct JSONParseError: Error, Equatable, Sendable {
  public let offset: Int
  public let reason: String
}

/// RFC 8259 and nothing else: no comments, no trailing commas, no `NaN`, no byte-order mark, no
/// duplicate object keys, no lone surrogates, no leading zeros, nesting at most 64 deep.
public enum StrictJSON {
  public static let maximumDepth = 64

  public static func parse(_ data: Data) throws -> JSONValue {
    var parser = Parser(bytes: [UInt8](data))
    parser.skipSpace()
    let value = try parser.value(depth: 0)
    parser.skipSpace()
    if parser.index != parser.bytes.count {
      throw parser.fail("text after the end of the document")
    }
    return value
  }

  private struct Parser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    func fail(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

    mutating func skipSpace() {
      while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value(depth: Int) throws -> JSONValue {
      guard depth <= StrictJSON.maximumDepth else { throw fail("nested too deeply") }
      guard index < bytes.count else { throw fail("the document ends early") }
      switch bytes[index] {
      case UInt8(ascii: "{"): return try object(depth: depth)
      case UInt8(ascii: "["): return try array(depth: depth)
      case UInt8(ascii: "\""): return .string(try string())
      case UInt8(ascii: "t"): try literal("true"); return .bool(true)
      case UInt8(ascii: "f"): try literal("false"); return .bool(false)
      case UInt8(ascii: "n"): try literal("null"); return .null
      case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
      default: throw fail("not a JSON value")
      }
    }

    mutating func literal(_ word: String) throws {
      let expected = Array(word.utf8)
      guard index + expected.count <= bytes.count,
        Array(bytes[index..<index + expected.count]) == expected
      else { throw fail("not a JSON value") }
      index += expected.count
    }

    mutating func object(depth: Int) throws -> JSONValue {
      index += 1
      var members: [String: JSONValue] = [:]
      skipSpace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .object(members)
      }
      while true {
        skipSpace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
          throw fail("an object key must be a string")
        }
        let key = try string()
        if members[key] != nil { throw fail("the key \"\(key)\" appears twice") }
        skipSpace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
          throw fail("a colon is missing")
        }
        index += 1
        skipSpace()
        members[key] = try value(depth: depth + 1)
        skipSpace()
        guard index < bytes.count else { throw fail("the object is not closed") }
        if bytes[index] == UInt8(ascii: ",") {
          index += 1
          continue
        }
        if bytes[index] == UInt8(ascii: "}") {
          index += 1
          return .object(members)
        }
        throw fail("expected a comma or a closing brace")
      }
    }

    mutating func array(depth: Int) throws -> JSONValue {
      index += 1
      var items: [JSONValue] = []
      skipSpace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
        index += 1
        return .array(items)
      }
      while true {
        skipSpace()
        items.append(try value(depth: depth + 1))
        skipSpace()
        guard index < bytes.count else { throw fail("the array is not closed") }
        if bytes[index] == UInt8(ascii: ",") {
          index += 1
          continue
        }
        if bytes[index] == UInt8(ascii: "]") {
          index += 1
          return .array(items)
        }
        throw fail("expected a comma or a closing bracket")
      }
    }

    mutating func number() throws -> JSONValue {
      let start = index
      if bytes[index] == UInt8(ascii: "-") { index += 1 }
      guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
        throw fail("a digit is missing")
      }
      if bytes[index] == UInt8(ascii: "0") {
        index += 1
        if index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
          throw fail("a number may not have a leading zero")
        }
      } else {
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
          index += 1
        }
      }
      var isInteger = true
      if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        isInteger = false
        index += 1
        let digits = index
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
          index += 1
        }
        if index == digits { throw fail("a digit is missing after the decimal point") }
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
        isInteger = false
        index += 1
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
          index += 1
        }
        let digits = index
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
          index += 1
        }
        if index == digits { throw fail("a digit is missing in the exponent") }
      }
      let text = String(decoding: bytes[start..<index], as: UTF8.self)
      if isInteger, let whole = Int64(text) { return .int(whole) }
      guard let real = Double(text), real.isFinite else { throw fail("the number is out of range") }
      return .double(real)
    }

    mutating func hex4() throws -> UInt32 {
      guard index + 4 <= bytes.count else { throw fail("a \\u escape is cut short") }
      var result: UInt32 = 0
      for _ in 0..<4 {
        let byte = bytes[index]
        let digit: UInt32
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
        default: throw fail("a \\u escape needs four hex digits")
        }
        result = result * 16 + digit
        index += 1
      }
      return result
    }

    mutating func string() throws -> String {
      index += 1
      var scalars = String.UnicodeScalarView()
      var run: [UInt8] = []
      func flush(_ run: inout [UInt8], into scalars: inout String.UnicodeScalarView) throws {
        guard !run.isEmpty else { return }
        // Invalid UTF-8 decodes to U+FFFD, which changes the bytes: a round trip that differs is refused.
        let text = String(decoding: run, as: UTF8.self)
        guard text.utf8.elementsEqual(run) else {
          throw JSONParseError(offset: 0, reason: "the text is not valid UTF-8")
        }
        scalars.append(contentsOf: text.unicodeScalars)
        run.removeAll()
      }
      while true {
        guard index < bytes.count else { throw fail("a string is not closed") }
        let byte = bytes[index]
        if byte == UInt8(ascii: "\"") {
          index += 1
          try flush(&run, into: &scalars)
          return String(scalars)
        }
        if byte < 0x20 { throw fail("a control character must be escaped inside a string") }
        if byte == UInt8(ascii: "\\") {
          try flush(&run, into: &scalars)
          index += 1
          guard index < bytes.count else { throw fail("an escape is cut short") }
          let escape = bytes[index]
          index += 1
          switch escape {
          case UInt8(ascii: "\""): scalars.append("\"")
          case UInt8(ascii: "\\"): scalars.append("\\")
          case UInt8(ascii: "/"): scalars.append("/")
          case UInt8(ascii: "b"): scalars.append("\u{8}")
          case UInt8(ascii: "f"): scalars.append("\u{c}")
          case UInt8(ascii: "n"): scalars.append("\n")
          case UInt8(ascii: "r"): scalars.append("\r")
          case UInt8(ascii: "t"): scalars.append("\t")
          case UInt8(ascii: "u"):
            let first = try hex4()
            if (0xD800...0xDBFF).contains(first) {
              guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"),
                bytes[index + 1] == UInt8(ascii: "u")
              else { throw fail("a lone surrogate") }
              index += 2
              let second = try hex4()
              guard (0xDC00...0xDFFF).contains(second) else { throw fail("a lone surrogate") }
              let code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
              scalars.append(Unicode.Scalar(code)!)
            } else if (0xDC00...0xDFFF).contains(first) {
              throw fail("a lone surrogate")
            } else {
              scalars.append(Unicode.Scalar(first)!)
            }
          default: throw fail("an unknown escape")
          }
          continue
        }
        run.append(byte)
        index += 1
      }
    }
  }
}
