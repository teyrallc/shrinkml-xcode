import Darwin
import Foundation

/// File-system operations that never follow a symbolic link and never overwrite what they were not
/// told to. Everything the importer does to the user's folder goes through here.
enum SafeFS {
  enum Kind: Equatable { case file, directory, symlink, other }

  static func kind(of url: URL) -> Kind? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    switch info.st_mode & S_IFMT {
    case S_IFREG: return .file
    case S_IFDIR: return .directory
    case S_IFLNK: return .symlink
    default: return .other
    }
  }

  /// The real location of a path that may not exist yet: the nearest existing ancestor is resolved with
  /// `realpath` (so /tmp and /private/tmp, /var and /private/var are one place) and the rest is appended.
  static func realURL(_ url: URL) -> URL {
    var existing = url.standardizedFileURL
    var rest: [String] = []
    while kind(of: existing) == nil, existing.pathComponents.count > 1 {
      rest.insert(existing.lastPathComponent, at: 0)
      existing = existing.deletingLastPathComponent()
    }
    var resolved = existing
    if let pointer = realpath(existing.path, nil) {
      resolved = URL(fileURLWithPath: String(cString: pointer))
      free(pointer)
    }
    for component in rest { resolved.appendPathComponent(component) }
    return resolved
  }

  static func refusal(_ code: String, _ zh: String, _ en: String) -> ImportRefusal {
    ImportRefusal(code, Say(zh, en))
  }

  /// Creates `relative` under `root` one component at a time. A component that exists as anything but
  /// a real directory (a symbolic link above all) stops the import: nothing is written through it.
  static func ensureDirectory(_ root: URL, _ relative: String) throws {
    var current = root
    for component in relative.split(separator: "/") {
      current.appendPathComponent(String(component), isDirectory: true)
      switch kind(of: current) {
      case .directory: continue
      case nil:
        guard mkdir(current.path, 0o755) == 0 || errno == EEXIST else {
          throw refusal(
            "write_failed", "建不了資料夾「\(relative)」（\(String(cString: strerror(errno)))）。",
            "Could not create the folder \"\(relative)\" (\(String(cString: strerror(errno)))).")
        }
        guard kind(of: current) == .directory else { fallthrough }
      default:
        throw refusal(
          "path_blocked", "「\(relative)」的路上有一個不是資料夾的東西（或是連結）；為了不寫到別的地方，停下來了。",
          "Something on the way to \"\(relative)\" is not a folder (or is a link); stopped so that nothing is written elsewhere.")
      }
    }
  }

  /// `.shrinkml` and `Inbox` must be real folders if they exist: they are where the importer writes.
  static func refuseLinkedShrinkmlFolder(_ root: URL) throws {
    for name in [".shrinkml"] {
      if let found = kind(of: root.appendingPathComponent(name)), found != .directory {
        throw refusal(
          "path_blocked", "「\(name)」不是一個普通資料夾（是連結或檔案）；匯入不會寫進連結。",
          "\"\(name)\" is not a plain folder (it is a link or a file); the import does not write through links.")
      }
    }
  }

  /// The bytes of a regular file under `root`, nil when it is absent; a link or a special file is refused.
  static func readRegular(_ root: URL, _ relative: String) throws -> Data? {
    let url = root.appendingPathComponent(relative)
    switch kind(of: url) {
    case nil: return nil
    case .file: break
    default:
      throw refusal(
        "path_blocked", "「\(relative)」應該是一個普通檔案，但它是連結或別的東西。",
        "\"\(relative)\" should be a plain file, but it is a link or something else.")
    }
    do {
      return try Data(contentsOf: url)
    } catch {
      throw refusal("read_failed", "讀不了「\(relative)」。", "Could not read \"\(relative)\".")
    }
  }

  /// Writes `data` as `relative` under `root`: a temporary file in the same folder, then `rename`, so
  /// the name never holds half a file. An existing link at the name is refused, never followed.
  static func writeAtomically(_ root: URL, _ relative: String, _ data: Data, sync: Bool = false) throws {
    let target = root.appendingPathComponent(relative)
    if let existing = kind(of: target), existing != .file {
      throw refusal(
        "path_blocked", "「\(relative)」已經存在，而且不是普通檔案；沒有覆蓋它。",
        "\"\(relative)\" exists and is not a plain file; it was not overwritten.")
    }
    let parent = (relative as NSString).deletingLastPathComponent
    if !parent.isEmpty { try ensureDirectory(root, parent) }
    let temp = target.deletingLastPathComponent().appendingPathComponent(
      ".\(target.lastPathComponent).shrinkml-tmp-\(getpid())")
    let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else {
      throw refusal(
        "write_failed", "寫不了「\(relative)」（\(String(cString: strerror(errno)))）。",
        "Could not write \"\(relative)\" (\(String(cString: strerror(errno)))).")
    }
    var failed = false
    data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if written <= 0 {
          failed = true
          return
        }
        offset += written
      }
    }
    if sync { fsync(descriptor) }
    close(descriptor)
    if failed || rename(temp.path, target.path) != 0 {
      unlink(temp.path)
      throw refusal(
        "write_failed", "寫不了「\(relative)」（\(String(cString: strerror(errno)))）。",
        "Could not write \"\(relative)\" (\(String(cString: strerror(errno)))).")
    }
  }

  /// `rename` of a staged folder into a path that does not exist yet.
  static func moveIntoPlace(_ source: URL, _ root: URL, _ relative: String) throws {
    let parent = (relative as NSString).deletingLastPathComponent
    if !parent.isEmpty { try ensureDirectory(root, parent) }
    let target = root.appendingPathComponent(relative)
    guard kind(of: target) == nil else {
      throw refusal(
        "path_blocked", "「\(relative)」已經存在；沒有覆蓋它。", "\"\(relative)\" already exists; it was not overwritten.")
    }
    guard rename(source.path, target.path) == 0 else {
      throw refusal(
        "write_failed", "搬不進「\(relative)」（\(String(cString: strerror(errno)))）。",
        "Could not move into \"\(relative)\" (\(String(cString: strerror(errno)))).")
    }
  }

  /// Every regular file under `directory` (relative paths, sorted), refusing links and special files.
  static func regularFiles(under directory: URL) throws -> [String] {
    var found: [String] = []
    func walk(_ url: URL, _ prefix: String) throws {
      let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
      for name in names {
        let child = url.appendingPathComponent(name)
        let relative = prefix.isEmpty ? name : prefix + "/" + name
        switch kind(of: child) {
        case .file: found.append(relative)
        case .directory: try walk(child, relative)
        default:
          throw refusal(
            "staging_unexpected", "暫存區裡出現了不該有的東西「\(relative)」（連結或特殊檔案）。",
            "Something that should not be there appeared in the staging area: \"\(relative)\" (a link or a special file).")
        }
      }
    }
    try walk(directory, "")
    return found
  }
}

/// A folder inside the package, `.shrinkml/staging/<id>/`, where an import is assembled and checked
/// before anything is moved to its final place. Same volume as the package, so the move is a rename.
public final class StagingArea {
  public let root: URL
  let packageRoot: URL

  public init(packageDirectory: URL) throws {
    packageRoot = packageDirectory
    try SafeFS.ensureDirectory(packageDirectory, ".shrinkml/staging")
    let id = UUID().uuidString.lowercased()
    root = packageDirectory.appendingPathComponent(".shrinkml/staging/\(id)", isDirectory: true)
    guard mkdir(root.path, 0o755) == 0 else {
      throw SafeFS.refusal(
        "write_failed", "建不了暫存資料夾（\(String(cString: strerror(errno)))）。",
        "Could not create the staging folder (\(String(cString: strerror(errno)))).")
    }
  }

  /// `<staging>/<model>/<resources|records|runtime>/`
  func directory(_ destination: Destination, model: String) -> URL {
    root.appendingPathComponent(model, isDirectory: true).appendingPathComponent(destination.rawValue, isDirectory: true)
  }

  func destination(for member: Member, model: String) -> URL {
    directory(member.destination, model: model).appendingPathComponent(member.relativePath)
  }

  /// Streams one archive member to `target` (or only measures it when `target` is nil).
  static func copy(_ entry: ZipEntry, from zip: ZipArchive, to target: URL?) throws -> (sha256: String, size: Int) {
    var hash = SHA256Hex.Stream()
    var descriptor: Int32 = -1
    if let target {
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
      guard descriptor >= 0 else {
        throw SafeFS.refusal(
          "write_failed", "寫不了暫存檔「\(entry.name)」（\(String(cString: strerror(errno)))）。",
          "Could not write the staging file \"\(entry.name)\" (\(String(cString: strerror(errno)))).")
      }
    }
    defer { if descriptor >= 0 { close(descriptor) } }
    try zip.read(entry) { bytes in
      hash.update(bytes)
      if descriptor >= 0 {
        var offset = 0
        while offset < bytes.count {
          let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
          if written <= 0 {
            throw SafeFS.refusal(
              "write_failed", "寫不了暫存檔「\(entry.name)」（\(String(cString: strerror(errno)))）。磁碟滿了嗎？",
              "Could not write the staging file \"\(entry.name)\" (\(String(cString: strerror(errno)))). Is the disk full?")
          }
          offset += written
        }
      }
    }
    return (hash.finish(), hash.count)
  }

  /// Writes bytes that are not a member of the archive (the saved answer of the swift-package route)
  /// to `target` in the staging area; the file must not exist yet.
  static func stageBytes(_ data: Data, to target: URL) throws {
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else {
      throw SafeFS.refusal(
        "write_failed", "寫不了暫存檔「\(target.lastPathComponent)」（\(String(cString: strerror(errno)))）。",
        "Could not write the staging file \"\(target.lastPathComponent)\" (\(String(cString: strerror(errno)))).")
    }
    defer { close(descriptor) }
    var failed = false
    data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if written <= 0 {
          failed = true
          return
        }
        offset += written
      }
    }
    if failed {
      throw SafeFS.refusal(
        "write_failed", "寫不了暫存檔「\(target.lastPathComponent)」。磁碟滿了嗎？",
        "Could not write the staging file \"\(target.lastPathComponent)\". Is the disk full?")
    }
  }

  /// The staged tree must be exactly the members that were announced, as plain files of the right size.
  func verify(_ members: [Member], model: String) throws {
    for place in [Destination.resources, .records, .runtime] {
      let expected = members.filter { $0.destination == place }
      let dir = directory(place, model: model)
      guard SafeFS.kind(of: dir) != nil || expected.isEmpty else {
        throw SafeFS.refusal("staging_unexpected", "暫存區少了東西。", "The staging area is missing something.")
      }
      let present = SafeFS.kind(of: dir) == nil ? [] : try SafeFS.regularFiles(under: dir)
      guard present == expected.map(\.relativePath).sorted(by: { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }) else {
        throw SafeFS.refusal(
          "staging_unexpected", "暫存區的檔案和預期的不一樣；沒有寫進你的專案。",
          "The files in the staging area are not the ones expected; nothing was written into your project.")
      }
      for member in expected {
        var info = stat()
        guard lstat(destination(for: member, model: model).path, &info) == 0, Int(info.st_size) == member.size else {
          throw SafeFS.refusal(
            "staging_unexpected", "暫存檔「\(member.relativePath)」的大小不對；沒有寫進你的專案。",
            "The staged file \"\(member.relativePath)\" has the wrong size; nothing was written into your project.")
        }
      }
    }
  }

  public func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
