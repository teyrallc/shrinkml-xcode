import Compression
import Foundation

/// The caps a zip must stay under. They are the importer's, not the zip's: a hand-over from
/// ShrinkML is far below every one of them, and an archive that reaches one is refused whole.
///
/// The numbers are the table `zip-limits.v1.json` of the ShrinkML repository (one file at most
/// 256 MiB, everything together at most 2 GiB). ShrinkML's server, its engine and the
/// command-line tool read the same table, and a test here reads the JSON and fails the day a number
/// differs. Two profiles: `standard` is that table; `modelBundle` is the same table except that
/// ONE file may be a model's weights up to 1 GiB (the compile lane's own weight ceiling), which a
/// hand-over made around a model needs: the Mandarin speech model's weights are 544 to 625 MiB.
public struct ZipLimits: Equatable, Sendable {
  /// Which row of the table this is: `standard` or `model_bundle`.
  public var name: String = "standard"
  /// The archive file: the unpacked ceiling plus 64 MiB for headers.
  public var maximumArchiveBytes: Int = (2 << 30) + (64 << 20)
  public var maximumEntries: Int = 10_000
  /// One member, after decompression.
  public var maximumEntryBytes: UInt64 = 256 << 20
  /// All members together, after decompression.
  public var maximumTotalBytes: UInt64 = 2 << 30
  /// Decompressed size over compressed size, for any member larger than `ratioFloorBytes`.
  public var maximumRatio: UInt64 = 200
  /// Below this many bytes a member cannot be a bomb whatever its ratio (an empty JSON deflates 1000:1).
  public var ratioFloorBytes: UInt64 = 1 << 20
  /// The same ratio over the whole archive, once it is larger than `ratioFloorBytes`.
  public var maximumTotalRatio: UInt64 = 200

  public init() {}

  public static let standard = ZipLimits()

  /// What a zip ShrinkML's compile lane made around a model may declare: the owner's table with one
  /// file allowed to be the model's weights (up to 1 GiB). The total stays 2 GiB.
  public static let modelBundle: ZipLimits = {
    var limits = ZipLimits()
    limits.name = "model_bundle"
    limits.maximumEntryBytes = 1 << 30
    return limits
  }()

  /// `256 MiB`, `2 GiB` when exact; `1.5 GiB (1,610,612,737 bytes)` otherwise. For messages only.
  static func describe(_ count: UInt64) -> String {
    for (unit, size) in [("GiB", UInt64(1) << 30), ("MiB", UInt64(1) << 20), ("KiB", UInt64(1) << 10)]
    where count >= size {
      if count % size == 0 { return "\(count / size) \(unit)" }
      return String(format: "%.1f %@ (%llu bytes)", Double(count) / Double(size), unit, count)
    }
    return "\(count) bytes"
  }
}

/// What the archive's own headers say about one member, after every header was cross-checked.
public struct ZipEntry: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case file, directory }

  /// The member's path without a directory entry's trailing slash.
  public let name: String
  public let kind: Kind
  public let method: UInt16
  public let compressedSize: UInt64
  public let uncompressedSize: UInt64
  public let crc32: UInt32
  /// Where the member's data starts in the archive bytes (after the local header).
  let dataOffset: Int
  let localHeaderOffset: Int
}

/// A zip, read defensively. `init` reads and checks every header and writes nothing anywhere: if it
/// returns, every name is a safe relative path, every size is under the caps, no two members share a
/// byte, and nothing in it is encrypted, linked, or a device. `read` then streams a member out
/// through a callback, stops the moment it would produce a byte more than the headers announced, and
/// at the end checks the size and CRC-32.
///
/// Handled: stored and deflate members, ZIP64 (cross-checked against the 32-bit fields), data
/// descriptors, archive comments. Refused, each with its own code: encryption, symlinks and special
/// files, any other compression method, multi-disk archives, Unicode-path extra fields (a second name
/// for the same member), overlapping members, names that break `ArchivePath`, names that collide on a
/// case-insensitive file system, a file that is also a directory, more than one possible end-of-central-
/// directory record. Bytes after the end of a deflate stream are never delivered: the output is exactly the
/// announced size or the member is refused.
public final class ZipArchive {
  public let entries: [ZipEntry]
  public let limits: ZipLimits
  private let data: Data

  public convenience init(contentsOf url: URL, limits: ZipLimits = .standard) throws {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values?.isRegularFile == true, let size = values?.fileSize else {
      throw ImportRefusal(
        "archive_unreadable",
        Say("「\(url.lastPathComponent)」不是一個能讀的檔案。", "\"\(url.lastPathComponent)\" is not a readable file."))
    }
    guard size <= limits.maximumArchiveBytes else {
      throw ImportRefusal(
        "archive_too_large",
        Say(
          "「\(url.lastPathComponent)」本身有 \(ZipLimits.describe(UInt64(size)))，最多 \(ZipLimits.describe(UInt64(limits.maximumArchiveBytes)))；沒有打開它。",
          "\"\(url.lastPathComponent)\" is \(ZipLimits.describe(UInt64(size))) as a file; at most \(ZipLimits.describe(UInt64(limits.maximumArchiveBytes))) is allowed, so it was not opened."))
    }
    let bytes: Data
    do {
      bytes = try Data(contentsOf: url, options: .alwaysMapped)
    } catch {
      throw ImportRefusal(
        "archive_unreadable",
        Say("讀不了「\(url.lastPathComponent)」。", "Could not read \"\(url.lastPathComponent)\"."))
    }
    try self.init(data: bytes, limits: limits)
  }

  public init(data: Data, limits: ZipLimits = .standard) throws {
    self.limits = limits
    // A zero-based copy: slices of a Data keep their parent's indices.
    self.data = data.startIndex == 0 ? data : Data(data)
    guard data.count <= limits.maximumArchiveBytes else {
      throw ImportRefusal(
        "archive_too_large",
        Say(
          "壓縮檔本身有 \(ZipLimits.describe(UInt64(data.count)))，最多 \(ZipLimits.describe(UInt64(limits.maximumArchiveBytes)))。",
          "The archive is \(ZipLimits.describe(UInt64(data.count))) as a file; at most \(ZipLimits.describe(UInt64(limits.maximumArchiveBytes))) is allowed."))
    }
    self.entries = try ZipArchive.readDirectory(self.data, limits: limits)
  }

  public func entry(named name: String) -> ZipEntry? { entries.first { $0.name == name } }

  /// The whole member in memory. Only for members the caller has reason to believe are small.
  public func contents(of entry: ZipEntry, maximumBytes: Int = 64 << 20) throws -> Data {
    guard entry.uncompressedSize <= UInt64(maximumBytes) else {
      throw ImportRefusal(
        "entry_too_large_to_hold",
        Say("「\(entry.name)」太大，不能整個讀進記憶體。", "\"\(entry.name)\" is too large to hold in memory."))
    }
    var out = Data()
    out.reserveCapacity(Int(entry.uncompressedSize))
    try read(entry) { out.append(contentsOf: $0) }
    return out
  }

  /// Streams a file member out. The callback sees bytes before the CRC-32 is checked; whoever
  /// writes them somewhere must treat that place as unfinished until this returns normally.
  public func read(_ entry: ZipEntry, into sink: (UnsafeRawBufferPointer) throws -> Void) throws {
    guard entry.kind == .file else { return }
    let start = entry.dataOffset
    let end = start + Int(entry.compressedSize)
    var crc = CRC32()
    var produced: UInt64 = 0
    let announced = entry.uncompressedSize

    func deliver(_ bytes: UnsafeRawBufferPointer) throws {
      produced += UInt64(bytes.count)
      if produced > announced {
        throw ImportRefusal(
          "zip_bomb",
          Say(
            "「\(entry.name)」解開後比檔頭宣告的 \(announced) 位元組還多，已停止。",
            "\"\(entry.name)\" expands to more than the \(announced) bytes its header announces; stopped."))
      }
      crc.update(bytes)
      try sink(bytes)
    }

    try data.withUnsafeBytes { (whole: UnsafeRawBufferPointer) in
      let compressed = UnsafeRawBufferPointer(rebasing: whole[start..<end])
      switch entry.method {
      case 0:
        var offset = 0
        while offset < compressed.count {
          let piece = min(1 << 20, compressed.count - offset)
          try deliver(UnsafeRawBufferPointer(rebasing: compressed[offset..<offset + piece]))
          offset += piece
        }
      case 8:
        try ZipArchive.inflate(compressed, entryName: entry.name, deliver: deliver)
      default:
        throw ImportRefusal(
          "zip_method", Say("不支援的壓縮方式。", "Unsupported compression method."))
      }
    }
    if produced != announced {
      throw ImportRefusal(
        "zip_size_mismatch",
        Say(
          "「\(entry.name)」解開是 \(produced) 位元組，檔頭說 \(announced)。",
          "\"\(entry.name)\" expands to \(produced) bytes but its header says \(announced)."))
    }
    if crc.value != entry.crc32 {
      throw ImportRefusal(
        "zip_crc",
        Say("「\(entry.name)」的 CRC-32 對不上，檔案可能壞了。", "The CRC-32 of \"\(entry.name)\" does not match; the file may be damaged."))
    }
  }

  // MARK: - Raw deflate

  private static func inflate(
    _ compressed: UnsafeRawBufferPointer, entryName: String, deliver: (UnsafeRawBufferPointer) throws -> Void
  ) throws {
    let chunk = 256 << 10
    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
    defer { output.deallocate() }
    let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { streamPointer.deallocate() }
    // The struct needs valid pointers before init; the real ones are set below.
    streamPointer.initialize(
      to: compression_stream(
        dst_ptr: output, dst_size: 0, src_ptr: UnsafePointer(output), src_size: 0, state: nil))
    guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
    else {
      throw ImportRefusal("inflate_failed", Say("解壓縮器啟動不了。", "The decompressor could not start."))
    }
    defer { compression_stream_destroy(streamPointer) }

    if let base = compressed.baseAddress {
      streamPointer.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
    }
    streamPointer.pointee.src_size = compressed.count
    var finished = false
    while !finished {
      streamPointer.pointee.dst_ptr = output
      streamPointer.pointee.dst_size = chunk
      let before = streamPointer.pointee.src_size
      let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
      let written = chunk - streamPointer.pointee.dst_size
      if written > 0 { try deliver(UnsafeRawBufferPointer(start: output, count: written)) }
      switch status {
      case COMPRESSION_STATUS_END:
        finished = true
      case COMPRESSION_STATUS_OK:
        // No input used and no output made: the stream is cut short. Stop instead of spinning.
        if written == 0 && streamPointer.pointee.src_size == before {
          throw ImportRefusal(
            "inflate_failed",
            Say("「\(entryName)」的壓縮資料不完整。", "The compressed data of \"\(entryName)\" is incomplete."))
        }
      default:
        throw ImportRefusal(
          "inflate_failed",
          Say("「\(entryName)」的壓縮資料壞了。", "The compressed data of \"\(entryName)\" is corrupt."))
      }
    }
    if streamPointer.pointee.src_size != 0 {
      throw ImportRefusal(
        "inflate_failed",
        Say(
          "「\(entryName)」的壓縮資料後面還有多餘的位元組。",
          "There are extra bytes after the compressed data of \"\(entryName)\"."))
    }
  }

  // MARK: - Directory

  private struct Cursor {
    let data: Data
    func u16(_ offset: Int) -> UInt16 {
      UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    func u32(_ offset: Int) -> UInt32 {
      UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }
    func u64(_ offset: Int) -> UInt64 {
      UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }
  }

  private static func broken(_ code: String, _ zh: String, _ en: String) -> ImportRefusal {
    ImportRefusal(code, Say(zh, en))
  }

  private static func readDirectory(_ data: Data, limits: ZipLimits) throws -> [ZipEntry] {
    let cursor = Cursor(data: data)
    let size = data.count
    guard size >= 22 else {
      throw broken("not_a_zip", "這不是 zip 檔（太短）。", "This is not a zip file (too short).")
    }

    // Exactly one end-of-central-directory record may be consistent with the end of the file.
    var candidates: [Int] = []
    let lowest = max(0, size - 22 - 0xFFFF)
    var position = size - 22
    while position >= lowest {
      if cursor.u32(position) == 0x0605_4B50 {
        let commentLength = Int(cursor.u16(position + 20))
        if position + 22 + commentLength == size { candidates.append(position) }
      }
      position -= 1
    }
    guard candidates.count == 1, let eocd = candidates.first else {
      throw broken(
        candidates.isEmpty ? "not_a_zip" : "zip_ambiguous",
        candidates.isEmpty ? "找不到 zip 的目錄結尾，這不是一個完整的 zip。" : "這個 zip 有不只一個看起來合理的目錄結尾，可能是惡意構造的，已拒絕。",
        candidates.isEmpty
          ? "No end-of-central-directory record: this is not a complete zip."
          : "This zip has more than one plausible end-of-central-directory record; refused as possibly crafted.")
    }

    var diskNumber = UInt64(cursor.u16(eocd + 4))
    var directoryDisk = UInt64(cursor.u16(eocd + 6))
    var entriesOnDisk = UInt64(cursor.u16(eocd + 8))
    var entryCount = UInt64(cursor.u16(eocd + 10))
    var directorySize = UInt64(cursor.u32(eocd + 12))
    var directoryOffset = UInt64(cursor.u32(eocd + 16))

    let needsZip64 =
      cursor.u16(eocd + 4) == 0xFFFF || cursor.u16(eocd + 6) == 0xFFFF || cursor.u16(eocd + 8) == 0xFFFF
      || cursor.u16(eocd + 10) == 0xFFFF || cursor.u32(eocd + 12) == 0xFFFF_FFFF
      || cursor.u32(eocd + 16) == 0xFFFF_FFFF
    var zip64RecordOffset: Int?
    if eocd >= 20, cursor.u32(eocd - 20) == 0x0706_4B50 {
      // A ZIP64 locator: it must point at a ZIP64 record that sits right before it.
      let locatorDisk = cursor.u32(eocd - 20 + 4)
      let recordOffset = cursor.u64(eocd - 20 + 8)
      let totalDisks = cursor.u32(eocd - 20 + 16)
      guard locatorDisk == 0, totalDisks == 1 else {
        throw broken("zip_multidisk", "不支援分割成多個檔的 zip。", "Multi-disk zips are not supported.")
      }
      guard recordOffset < UInt64(eocd), Int(recordOffset) + 56 <= eocd - 20,
        cursor.u32(Int(recordOffset)) == 0x0606_4B50
      else {
        throw broken("zip64_inconsistent", "ZIP64 的目錄記錄對不上。", "The ZIP64 directory record does not line up.")
      }
      let record = Int(recordOffset)
      let recordSize = cursor.u64(record + 4)
      // The record's size field counts the bytes after itself; it must end where the locator starts.
      guard recordSize >= 44, UInt64(record) + 12 + recordSize == UInt64(eocd - 20) else {
        throw broken("zip64_inconsistent", "ZIP64 的目錄記錄對不上。", "The ZIP64 directory record does not line up.")
      }
      zip64RecordOffset = record
    }
    if needsZip64 && zip64RecordOffset == nil {
      throw broken("zip64_inconsistent", "目錄結尾說要用 ZIP64，卻沒有 ZIP64 記錄。", "The end record asks for ZIP64 but there is no ZIP64 record.")
    }
    if let record = zip64RecordOffset {
      let diskNumber64 = UInt64(cursor.u32(record + 16))
      let directoryDisk64 = UInt64(cursor.u32(record + 20))
      let entriesOnDisk64 = cursor.u64(record + 24)
      let entryCount64 = cursor.u64(record + 32)
      let directorySize64 = cursor.u64(record + 40)
      let directoryOffset64 = cursor.u64(record + 48)
      // Where the 32-bit fields are not the "see ZIP64" marker, both must agree.
      func agree(_ small: UInt64, _ marker: UInt64, _ large: UInt64) -> Bool { small == marker || small == large }
      guard agree(diskNumber, 0xFFFF, diskNumber64), agree(directoryDisk, 0xFFFF, directoryDisk64),
        agree(entriesOnDisk, 0xFFFF, entriesOnDisk64), agree(entryCount, 0xFFFF, entryCount64),
        agree(directorySize, 0xFFFF_FFFF, directorySize64),
        agree(directoryOffset, 0xFFFF_FFFF, directoryOffset64)
      else {
        throw broken("zip64_inconsistent", "ZIP64 的數字和一般的目錄結尾對不上。", "The ZIP64 numbers disagree with the ordinary end record.")
      }
      diskNumber = diskNumber64
      directoryDisk = directoryDisk64
      entriesOnDisk = entriesOnDisk64
      entryCount = entryCount64
      directorySize = directorySize64
      directoryOffset = directoryOffset64
    }

    guard diskNumber == 0, directoryDisk == 0, entriesOnDisk == entryCount else {
      throw broken("zip_multidisk", "不支援分割成多個檔的 zip。", "Multi-disk zips are not supported.")
    }
    guard entryCount <= UInt64(limits.maximumEntries) else {
      throw broken(
        "zip_too_many_entries", "這個 zip 有 \(entryCount) 個成員，最多 \(limits.maximumEntries) 個。",
        "This zip has \(entryCount) members; at most \(limits.maximumEntries) are allowed.")
    }
    let directoryEnd = zip64RecordOffset ?? eocd
    guard directoryOffset <= UInt64(directoryEnd), directorySize <= UInt64(directoryEnd) - directoryOffset,
      directoryOffset + directorySize == UInt64(directoryEnd)
    else {
      throw broken("zip_directory", "目錄的位置對不上檔案的大小。", "The directory's position does not fit the file's size.")
    }

    // Walk the central directory.
    struct Raw {
      var name: String
      var kind: ZipEntry.Kind
      var flags: UInt16
      var method: UInt16
      var crc: UInt32
      var compressed: UInt64
      var uncompressed: UInt64
      var localOffset: UInt64
    }
    var raws: [Raw] = []
    var cursorPosition = Int(directoryOffset)
    let directoryStop = Int(directoryOffset + directorySize)
    for _ in 0..<entryCount {
      guard cursorPosition + 46 <= directoryStop, cursor.u32(cursorPosition) == 0x0201_4B50 else {
        throw broken("zip_directory", "目錄裡有壞掉的成員記錄。", "The directory holds a damaged member record.")
      }
      let madeBy = cursor.u16(cursorPosition + 4)
      let flags = cursor.u16(cursorPosition + 8)
      let method = cursor.u16(cursorPosition + 10)
      let crc = cursor.u32(cursorPosition + 16)
      var compressed = UInt64(cursor.u32(cursorPosition + 20))
      var uncompressed = UInt64(cursor.u32(cursorPosition + 24))
      let nameLength = Int(cursor.u16(cursorPosition + 28))
      let extraLength = Int(cursor.u16(cursorPosition + 30))
      let commentLength = Int(cursor.u16(cursorPosition + 32))
      let diskStart = cursor.u16(cursorPosition + 34)
      let externalAttributes = cursor.u32(cursorPosition + 38)
      var localOffset = UInt64(cursor.u32(cursorPosition + 42))
      let next = cursorPosition + 46 + nameLength + extraLength + commentLength
      guard next <= directoryStop else {
        throw broken("zip_directory", "目錄裡有壞掉的成員記錄。", "The directory holds a damaged member record.")
      }
      guard diskStart == 0 else {
        throw broken("zip_multidisk", "不支援分割成多個檔的 zip。", "Multi-disk zips are not supported.")
      }
      let nameBytes = data[(cursorPosition + 46)..<(cursorPosition + 46 + nameLength)]
      let rawName = String(decoding: nameBytes, as: UTF8.self)
      guard rawName.utf8.elementsEqual(nameBytes) else {
        throw broken("zip_name_encoding", "有成員的名稱不是合法的 UTF-8。", "A member name is not valid UTF-8.")
      }

      // Flags: only the three that change nothing about reading are allowed.
      if flags & 0x0001 != 0 || flags & 0x0040 != 0 || flags & 0x2000 != 0 {
        throw broken("zip_encrypted", "「\(rawName)」是加密的，匯入不收加密的成員。", "\"\(rawName)\" is encrypted; the importer takes no encrypted members.")
      }
      if flags & ~UInt16(0x0006 | 0x0008 | 0x0800) != 0 {
        throw broken("zip_flags", "「\(rawName)」用了不支援的 zip 旗標。", "\"\(rawName)\" uses a zip flag that is not supported.")
      }
      if method == 99 {
        throw broken("zip_encrypted", "「\(rawName)」是加密的，匯入不收加密的成員。", "\"\(rawName)\" is encrypted; the importer takes no encrypted members.")
      }
      guard method == 0 || method == 8 else {
        throw broken("zip_method", "「\(rawName)」用了不支援的壓縮方式（只收 stored 與 deflate）。", "\"\(rawName)\" uses an unsupported compression method (only stored and deflate).")
      }

      // Extra fields: ZIP64 is read, a second spelling of the name is refused, the rest is ignored.
      var extra = cursorPosition + 46 + nameLength
      let extraEnd = extra + extraLength
      var zip64Seen = false
      while extra < extraEnd {
        guard extra + 4 <= extraEnd else {
          throw broken("zip_extra", "「\(rawName)」的額外欄位壞了。", "The extra field of \"\(rawName)\" is damaged.")
        }
        let tag = cursor.u16(extra)
        let length = Int(cursor.u16(extra + 2))
        guard extra + 4 + length <= extraEnd else {
          throw broken("zip_extra", "「\(rawName)」的額外欄位壞了。", "The extra field of \"\(rawName)\" is damaged.")
        }
        if tag == 0x7075 {
          throw broken("zip_unicode_path", "「\(rawName)」帶了第二個名稱（Unicode path 額外欄位），為避免不同工具看到不同路徑，已拒絕。", "\"\(rawName)\" carries a second name (a Unicode-path extra field); refused so that no two tools see different paths.")
        }
        if tag == 0x0001 {
          guard !zip64Seen else {
            throw broken("zip64_inconsistent", "「\(rawName)」有兩個 ZIP64 欄位。", "\"\(rawName)\" has two ZIP64 fields.")
          }
          zip64Seen = true
          var at = extra + 4
          let stop = extra + 4 + length
          func take() throws -> UInt64 {
            guard at + 8 <= stop else {
              throw broken("zip64_inconsistent", "「\(rawName)」的 ZIP64 欄位太短。", "The ZIP64 field of \"\(rawName)\" is too short.")
            }
            defer { at += 8 }
            return cursor.u64(at)
          }
          if uncompressed == 0xFFFF_FFFF { uncompressed = try take() }
          if compressed == 0xFFFF_FFFF { compressed = try take() }
          if localOffset == 0xFFFF_FFFF { localOffset = try take() }
          guard at == stop || stop - at == 4 else {
            // Whatever is left must be the 4-byte disk number, or the field says more than the header asked for.
            throw broken("zip64_inconsistent", "「\(rawName)」的 ZIP64 欄位長度不對。", "The ZIP64 field of \"\(rawName)\" has the wrong length.")
          }
        }
        extra += 4 + length
      }
      if (uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF) && !zip64Seen {
        throw broken("zip64_inconsistent", "「\(rawName)」要用 ZIP64 卻沒有 ZIP64 欄位。", "\"\(rawName)\" asks for ZIP64 but has no ZIP64 field.")
      }

      // File type, from the Unix mode bits when the archive came from a Unix host.
      let host = UInt8(madeBy >> 8)
      var kind: ZipEntry.Kind = rawName.hasSuffix("/") ? .directory : .file
      if host == 3 {
        let mode = UInt16(externalAttributes >> 16)
        switch mode & 0xF000 {
        case 0x0000, 0x8000: break
        case 0x4000: kind = .directory
        case 0xA000:
          throw broken("zip_symlink", "「\(rawName)」是符號連結；匯入不收符號連結。", "\"\(rawName)\" is a symbolic link; the importer takes none.")
        default:
          throw broken("zip_special_file", "「\(rawName)」是特殊檔案（裝置、管線或 socket），匯入不收。", "\"\(rawName)\" is a special file (device, pipe or socket); the importer takes none.")
        }
      } else if externalAttributes & 0x10 != 0 {
        kind = .directory
      }
      if kind == .directory && !rawName.hasSuffix("/") {
        throw broken("zip_directory_name", "「\(rawName)」標成資料夾，名稱卻沒有結尾斜線。", "\"\(rawName)\" is marked a directory but its name has no trailing slash.")
      }
      if kind == .file && rawName.hasSuffix("/") {
        throw broken("zip_directory_name", "「\(rawName)」是檔案，名稱卻以斜線結尾。", "\"\(rawName)\" is a file but its name ends with a slash.")
      }
      if kind == .directory && (compressed != 0 || uncompressed != 0) {
        throw broken("zip_directory_name", "資料夾「\(rawName)」帶有資料。", "The directory \"\(rawName)\" carries data.")
      }
      let name = kind == .directory ? String(rawName.dropLast()) : rawName
      if let problem = ArchivePath.problem(in: name) {
        throw ImportRefusal(
          "zip_slip",
          Say(
            "成員名稱「\(rawName.debugDescription.dropFirst().dropLast())」不合規則（\(problem.rawValue)）：可能想寫到資料夾外面。整包拒絕，沒有寫任何東西。",
            "The member name \(rawName.debugDescription) breaks the path rules (\(problem.rawValue)); it may try to write outside the folder. The whole archive is refused; nothing was written."))
      }
      raws.append(
        Raw(
          name: name, kind: kind, flags: flags, method: method, crc: crc, compressed: compressed,
          uncompressed: uncompressed, localOffset: localOffset))
      cursorPosition = next
    }
    guard cursorPosition == directoryStop else {
      throw broken("zip_directory", "目錄後面有多餘的資料。", "There is extra data after the member records.")
    }

    // Names: no duplicate, none that collides on a case-insensitive file system, no file that is also a folder.
    var seen = Set<String>()
    var folders = Set<String>()
    var files = Set<String>()
    for raw in raws {
      if !seen.insert(PathKey.key(raw.name)).inserted {
        throw broken(
          "zip_duplicate_name", "成員「\(raw.name)」重複（大小寫不同也算，因為 Mac 的檔案系統不分大小寫）。",
          "The member \"\(raw.name)\" appears twice (a different case counts: Mac file systems ignore case).")
      }
      var parent = ""
      let parts = raw.name.split(separator: "/")
      for part in parts.dropLast() {
        parent += (parent.isEmpty ? "" : "/") + part
        folders.insert(PathKey.key(parent))
      }
      if raw.kind == .directory { folders.insert(PathKey.key(raw.name)) } else { files.insert(PathKey.key(raw.name)) }
    }
    if let clash = folders.intersection(files).first {
      throw broken("zip_file_is_folder", "「\(clash)」同時是檔案和資料夾。", "\"\(clash)\" is both a file and a folder.")
    }

    // Local headers, data ranges, totals.
    var result: [ZipEntry] = []
    var ranges: [(start: Int, end: Int, name: String)] = []
    var total: UInt64 = 0
    var totalCompressed: UInt64 = 0
    for raw in raws {
      guard raw.uncompressed <= limits.maximumEntryBytes else {
        throw broken(
          "zip_entry_too_large",
          "「\(raw.name)」解開後有 \(ZipLimits.describe(raw.uncompressed))，單一檔案最多 \(ZipLimits.describe(limits.maximumEntryBytes))；在解開任何東西之前就拒絕了。",
          "\"\(raw.name)\" is \(ZipLimits.describe(raw.uncompressed)) once unpacked; one file may be at most \(ZipLimits.describe(limits.maximumEntryBytes)). It was refused before anything was unpacked.")
      }
      if raw.method == 0 && raw.compressed != raw.uncompressed {
        throw broken("zip_size_mismatch", "「\(raw.name)」標成未壓縮，兩個大小卻不一樣。", "\"\(raw.name)\" is stored, yet its two sizes differ.")
      }
      if raw.uncompressed > limits.ratioFloorBytes {
        let ratioBase = max(raw.compressed, 1)
        if raw.uncompressed / ratioBase > limits.maximumRatio {
          throw broken(
            "zip_bomb", "「\(raw.name)」壓縮比超過 \(limits.maximumRatio) 倍，像壓縮炸彈，已拒絕。",
            "\"\(raw.name)\" compresses more than \(limits.maximumRatio) times, like a zip bomb; refused.")
        }
      }
      total += raw.uncompressed
      totalCompressed += raw.compressed
      guard total <= limits.maximumTotalBytes else {
        throw broken(
          "zip_too_large_total",
          "全部解開會超過 \(ZipLimits.describe(limits.maximumTotalBytes))，全部加起來最多這麼多；在解開任何東西之前就拒絕了。",
          "Everything together would pass \(ZipLimits.describe(limits.maximumTotalBytes)), the most that is allowed. It was refused before anything was unpacked.")
      }
      guard raw.localOffset <= UInt64(directoryOffset), Int(raw.localOffset) + 30 <= Int(directoryOffset) else {
        throw broken("zip_local_header", "「\(raw.name)」的本機標頭位置不對。", "The local header of \"\(raw.name)\" is misplaced.")
      }
      let local = Int(raw.localOffset)
      guard cursor.u32(local) == 0x0403_4B50 else {
        throw broken("zip_local_header", "「\(raw.name)」的本機標頭壞了。", "The local header of \"\(raw.name)\" is damaged.")
      }
      let localFlags = cursor.u16(local + 6)
      let localMethod = cursor.u16(local + 8)
      let localNameLength = Int(cursor.u16(local + 26))
      let localExtraLength = Int(cursor.u16(local + 28))
      let headerEnd = local + 30 + localNameLength + localExtraLength
      guard headerEnd <= Int(directoryOffset) else {
        throw broken("zip_local_header", "「\(raw.name)」的本機標頭壞了。", "The local header of \"\(raw.name)\" is damaged.")
      }
      let localNameBytes = data[(local + 30)..<(local + 30 + localNameLength)]
      let expectedName = raw.kind == .directory ? raw.name + "/" : raw.name
      guard localNameBytes.elementsEqual(expectedName.utf8) else {
        throw broken("zip_local_mismatch", "「\(raw.name)」在本機標頭與目錄裡的名稱不一樣。", "The name of \"\(raw.name)\" differs between its local header and the directory.")
      }
      guard localMethod == raw.method, localFlags == raw.flags else {
        throw broken("zip_local_mismatch", "「\(raw.name)」的本機標頭與目錄不一致。", "The local header and the directory disagree about \"\(raw.name)\".")
      }
      if raw.flags & 0x0008 == 0 {
        // Sizes and CRC are in the local header; they must say what the directory says.
        var localCompressed = UInt64(cursor.u32(local + 18))
        var localUncompressed = UInt64(cursor.u32(local + 22))
        let localCRC = cursor.u32(local + 14)
        if localCompressed == 0xFFFF_FFFF || localUncompressed == 0xFFFF_FFFF {
          // ZIP64 in the local extra field: it holds the uncompressed size first, then the compressed
          // size, for whichever of the two fields is the marker, exactly like the directory's.
          var at = local + 30 + localNameLength
          let stop = at + localExtraLength
          var found = false
          while at + 4 <= stop {
            let tag = cursor.u16(at)
            let length = Int(cursor.u16(at + 2))
            guard at + 4 + length <= stop else { break }
            if tag == 0x0001 {
              var take = at + 4
              if localUncompressed == 0xFFFF_FFFF, take + 8 <= at + 4 + length {
                localUncompressed = cursor.u64(take)
                take += 8
              }
              if localCompressed == 0xFFFF_FFFF, take + 8 <= at + 4 + length {
                localCompressed = cursor.u64(take)
              }
              found = true
            }
            at += 4 + length
          }
          guard found else {
            throw broken("zip64_inconsistent", "「\(raw.name)」的本機 ZIP64 欄位不見了。", "The local ZIP64 field of \"\(raw.name)\" is missing.")
          }
        }
        guard localCRC == raw.crc, localCompressed == raw.compressed, localUncompressed == raw.uncompressed else {
          throw broken("zip_local_mismatch", "「\(raw.name)」的本機標頭與目錄的大小或 CRC 不一致。", "The sizes or CRC of \"\(raw.name)\" differ between the local header and the directory.")
        }
      }
      guard raw.compressed <= UInt64(Int(directoryOffset) - headerEnd) else {
        throw broken("zip_local_header", "「\(raw.name)」的資料超出檔案範圍。", "The data of \"\(raw.name)\" runs past the end of the file.")
      }
      let dataEnd = headerEnd + Int(raw.compressed)
      ranges.append((local, dataEnd, raw.name))
      result.append(
        ZipEntry(
          name: raw.name, kind: raw.kind, method: raw.method, compressedSize: raw.compressed,
          uncompressedSize: raw.uncompressed, crc32: raw.crc, dataOffset: headerEnd, localHeaderOffset: local))
    }
    if total > limits.ratioFloorBytes, total / max(totalCompressed, 1) > limits.maximumTotalRatio {
      throw broken("zip_bomb", "整個壓縮檔的壓縮比超過 \(limits.maximumTotalRatio) 倍，像壓縮炸彈，已拒絕。", "The whole archive compresses more than \(limits.maximumTotalRatio) times, like a zip bomb; refused.")
    }
    ranges.sort { $0.start < $1.start }
    for (first, second) in zip(ranges, ranges.dropFirst()) where second.start < first.end {
      throw broken(
        "zip_overlap", "「\(first.name)」和「\(second.name)」的資料重疊，這是壓縮炸彈的手法，已拒絕。",
        "The data of \"\(first.name)\" and \"\(second.name)\" overlap, which is how overlapping-member bombs work; refused.")
    }
    return result
  }
}
