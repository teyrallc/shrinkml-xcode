import CryptoKit
import Foundation

/// SHA-256 as 64 lower-case hex characters, the only digest form the lock uses.
public enum SHA256Hex {
  public static func of(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  public static func of(_ bytes: [UInt8]) -> String {
    hex(SHA256.hash(data: bytes))
  }

  /// A hash that can be fed in pieces, for files that are never held in memory whole.
  public struct Stream {
    private var hasher = SHA256()
    public private(set) var count: Int = 0

    public init() {}

    public mutating func update(_ data: Data) {
      hasher.update(data: data)
      count += data.count
    }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
      hasher.update(bufferPointer: bytes)
      count += bytes.count
    }

    public func finish() -> String { hex(hasher.finalize()) }
  }

  /// The digest of a file, read in 1 MiB pieces.
  public static func ofFile(at url: URL) throws -> (sha256: String, size: Int) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var stream = Stream()
    while true {
      let piece = try handle.read(upToCount: 1 << 20) ?? Data()
      if piece.isEmpty { break }
      stream.update(piece)
    }
    return (stream.finish(), stream.count)
  }

  private static let digits = Array("0123456789abcdef".utf8)

  static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    var out: [UInt8] = []
    out.reserveCapacity(64)
    for byte in digest {
      out.append(digits[Int(byte >> 4)])
      out.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Is this exactly 64 lower-case hex characters?
  public static func isValid(_ text: String) -> Bool {
    text.utf8.count == 64
      && text.utf8.allSatisfy {
        ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
          || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
      }
  }
}

/// CRC-32 (the zip polynomial). A zip entry's bytes must match the checksum its headers claim.
public struct CRC32 {
  private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
    var crc = UInt32(index)
    for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    return crc
  }

  private var state: UInt32 = 0xFFFF_FFFF

  public init() {}

  public mutating func update(_ bytes: UnsafeRawBufferPointer) {
    for byte in bytes {
      state = CRC32.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
    }
  }

  public mutating func update(_ data: Data) {
    data.withUnsafeBytes { update($0) }
  }

  public var value: UInt32 { ~state }

  public static func of(_ data: Data) -> UInt32 {
    var crc = CRC32()
    crc.update(data)
    return crc.value
  }
}
