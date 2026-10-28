import Darwin
import Foundation

/// What `--add` did with the file it was given (a hand-over zip, and the saved answer of the swift-package
/// route that sits beside it when there is one).
public struct AddOutcome: Equatable, Sendable {
  /// The zip's name in the Inbox.
  public let filename: String
  /// The zip was written into the Inbox now. false: the very same bytes were already there.
  public let copied: Bool
  /// The zip replaced a file of the same name that an earlier import of this package recorded as its own.
  public let replacedEarlierCopy: Bool
  /// The saved swift-package answer was written beside it now.
  public let recordCopied: Bool
  /// A saved answer that an earlier import recorded as its own, and that the new zip does not come with, was taken away,
  /// so that it is never read against a zip it does not belong to.
  public let removedStaleRecord: Bool

  public static func unchanged(_ filename: String) -> AddOutcome {
    AddOutcome(filename: filename, copied: false, replacedEarlierCopy: false, recordCopied: false, removedStaleRecord: false)
  }
}

/// `--add <zip>`: the one place where the importer puts a file INTO `ShrinkMLModels/Inbox/` itself.
///
/// The rules, all of them about not harming what a person already has there:
/// * the source is a plain `.zip` file (a link is refused, never followed), and the saved answer beside it, if any, a plain file;
/// * a copy is made in pieces to a temporary name and renamed, so the name never holds half a file;
/// * the same bytes already under that name change nothing;
/// * other bytes under that name are replaced ONLY when the lock says an earlier import of this package read exactly that file
///   (it is the importer's own earlier copy); otherwise they are the person's, and nothing is written;
/// * nothing else in the Inbox is looked at, moved or removed.
enum InboxAdder {
  static let inboxFolder = "Inbox"

  struct Source {
    let url: URL
    let name: String
    /// The saved swift-package answer beside the zip, when there is one.
    let record: URL?
  }

  static func inspect(_ path: URL) throws -> Source {
    let name = path.lastPathComponent
    switch SafeFS.kind(of: path) {
    case .file: break
    case nil:
      throw SafeFS.refusal(
        "add_missing", "找不到要放進 Inbox 的檔案「\(path.path)」。", "The file to put in the Inbox, \"\(path.path)\", does not exist.")
    default:
      throw SafeFS.refusal(
        "add_not_a_file", "「\(path.path)」不是普通檔案（是連結或資料夾）；為了不跟著連結走到別的地方，沒有放進 Inbox。",
        "\"\(path.path)\" is not a plain file (it is a link or a folder); it was not put in the Inbox, so that nothing is followed to another place.")
    }
    guard name.lowercased().hasSuffix(".zip"), !name.hasPrefix(".") else {
      throw SafeFS.refusal(
        "add_not_a_zip", "「\(name)」不是 .zip 檔；Inbox 只收 ShrinkML 的交付 zip。",
        "\"\(name)\" is not a .zip file; the Inbox takes ShrinkML hand-over zips only.")
    }
    guard ArchivePath.isAcceptable(name), !name.contains("/") else {
      throw SafeFS.refusal(
        "add_name_invalid", "檔名「\(name)」不能放進 Inbox。", "The file name \"\(name)\" cannot go in the Inbox.")
    }
    if looksLikeASecret(name) {
      throw SafeFS.refusal(
        "filename_secret", "這個檔名看起來像金鑰或帶簽章的網址；檔名會被記進 lock 檔，而 lock 檔絕不存這種東西。請改檔名。",
        "This file name looks like a key or a signed link; the name is recorded in the lock file, which never stores such things. Rename the file.")
    }
    let companion = PackageFlavourFile.companionURL(for: path)
    switch SafeFS.kind(of: companion) {
    case nil: return Source(url: path, name: name, record: nil)
    case .file: return Source(url: path, name: name, record: companion)
    default:
      throw SafeFS.refusal(
        "add_not_a_file", "「\(companion.lastPathComponent)」是連結或資料夾，不是普通檔案；沒有放進 Inbox。",
        "\"\(companion.lastPathComponent)\" is a link or a folder, not a plain file; nothing was put in the Inbox.")
    }
  }

  /// Does an earlier import of this package record `sha256` as the archive named `name` (any revision) ...
  static func lockHoldsArchive(_ lock: Lock, named name: String, sha256: String) -> Bool {
    lock.models.contains { model in
      (model.archive.filename == name && model.archive.sha256 == sha256)
        || model.previousRevisions.contains { $0.archive.filename == name && $0.archive.sha256 == sha256 }
    }
  }

  /// ... or as a saved swift-package answer (the `swift-package.json` record of any revision)?
  static func lockHoldsRecord(_ lock: Lock, sha256: String) -> Bool {
    lock.models.contains { model in
      model.files.contains { $0.role == .record && $0.sha256 == sha256 }
        || model.previousRevisions.contains { $0.files.contains { $0.role == .record && $0.sha256 == sha256 } }
    }
  }

  static func nameTaken(_ relative: String) -> ImportRefusal {
    SafeFS.refusal(
      "inbox_name_taken",
      "Inbox 裡已經有一個叫「\(relative)」的檔案，內容不同，而且不是這個套件上次匯入時讀過的那一份（是你放的）。不會蓋掉它：請把它搬走或改名，再放一次。",
      "The Inbox already holds a file called \"\(relative)\" with other content, and it is not the one an earlier import of this package read (it is yours). It is not overwritten: move or rename it, then put this one in again.")
  }

  /// Puts the zip (and its saved answer) in `<root>/Inbox/`, by the rules above. Call it only after the file was planned and
  /// nothing in the plan refused it.
  static func put(_ source: Source, into root: URL, lock: Lock) throws -> AddOutcome {
    try SafeFS.ensureDirectory(root, inboxFolder)
    let relative = "\(inboxFolder)/\(source.name)"
    let (sourceDigest, _) = try SHA256Hex.ofFile(at: source.url)
    var copied = false
    var replaced = false
    switch SafeFS.kind(of: root.appendingPathComponent(relative)) {
    case nil:
      try SafeFS.copyFile(from: source.url, toRoot: root, relative: relative, replacing: false)
      copied = true
    case .file:
      let (present, _) = try SHA256Hex.ofFile(at: root.appendingPathComponent(relative))
      if present != sourceDigest {
        guard lockHoldsArchive(lock, named: source.name, sha256: present) else { throw nameTaken(relative) }
        try SafeFS.copyFile(from: source.url, toRoot: root, relative: relative, replacing: true)
        copied = true
        replaced = true
      }
    default:
      throw SafeFS.refusal(
        "path_blocked", "「\(relative)」已經存在，而且不是普通檔案；沒有覆蓋它。",
        "\"\(relative)\" exists and is not a plain file; it was not overwritten.")
    }

    let recordRelative = PackageFlavourFile.companionName(for: relative)
    var recordCopied = false
    var removedStale = false
    let recordTarget = root.appendingPathComponent(recordRelative)
    if let record = source.record {
      let (recordDigest, _) = try SHA256Hex.ofFile(at: record)
      switch SafeFS.kind(of: recordTarget) {
      case nil:
        try SafeFS.copyFile(from: record, toRoot: root, relative: recordRelative, replacing: false)
        recordCopied = true
      case .file:
        let (present, _) = try SHA256Hex.ofFile(at: recordTarget)
        if present != recordDigest {
          guard lockHoldsRecord(lock, sha256: present) else { throw nameTaken(recordRelative) }
          try SafeFS.copyFile(from: record, toRoot: root, relative: recordRelative, replacing: true)
          recordCopied = true
        }
      default:
        throw SafeFS.refusal(
          "path_blocked", "「\(recordRelative)」已經存在，而且不是普通檔案；沒有覆蓋它。",
          "\"\(recordRelative)\" exists and is not a plain file; it was not overwritten.")
      }
    } else if SafeFS.kind(of: recordTarget) == .file, copied {
      // A new zip without an answer next to it must not be read against the old zip's answer. Only the importer's own is taken away.
      let (present, _) = try SHA256Hex.ofFile(at: recordTarget)
      if lockHoldsRecord(lock, sha256: present) {
        guard unlink(recordTarget.path) == 0 else {
          throw SafeFS.refusal(
            "write_failed", "拿不掉上一份留在 Inbox 的「\(recordRelative)」（\(String(cString: strerror(errno)))）。",
            "Could not take the earlier \"\(recordRelative)\" away from the Inbox (\(String(cString: strerror(errno)))).")
        }
        removedStale = true
      }
    }
    return AddOutcome(
      filename: source.name, copied: copied, replacedEarlierCopy: replaced, recordCopied: recordCopied,
      removedStaleRecord: removedStale)
  }
}

extension SafeFS {
  /// Copies the plain file `source` to `relative` under `root` a piece at a time: a temporary file in the target's folder, then
  /// `rename`. The source is opened without following a link and must be a plain file. An existing target is replaced only when
  /// `replacing` is true and it is a plain file; a link or a folder there is never touched.
  static func copyFile(from source: URL, toRoot root: URL, relative: String, replacing: Bool) throws {
    let target = root.appendingPathComponent(relative)
    if let existing = kind(of: target) {
      guard existing == .file, replacing else {
        throw refusal(
          "path_blocked", "「\(relative)」已經存在；沒有覆蓋它。", "\"\(relative)\" already exists; it was not overwritten.")
      }
    }
    let parent = (relative as NSString).deletingLastPathComponent
    if !parent.isEmpty { try ensureDirectory(root, parent) }
    let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard input >= 0 else {
      throw refusal(
        "read_failed", "讀不了「\(source.lastPathComponent)」（\(String(cString: strerror(errno)))）。",
        "Could not read \"\(source.lastPathComponent)\" (\(String(cString: strerror(errno)))).")
    }
    defer { close(input) }
    let temp = target.deletingLastPathComponent().appendingPathComponent(
      ".\(target.lastPathComponent).shrinkml-tmp-\(getpid())")
    unlink(temp.path)
    let output = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard output >= 0 else {
      throw refusal(
        "write_failed", "寫不了「\(relative)」（\(String(cString: strerror(errno)))）。",
        "Could not write \"\(relative)\" (\(String(cString: strerror(errno)))).")
    }
    var failed = false
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    copying: while true {
      let count = read(input, &buffer, buffer.count)
      if count < 0 {
        failed = true
        break
      }
      if count == 0 { break }
      var offset = 0
      while offset < count {
        let written = buffer.withUnsafeBytes { write(output, $0.baseAddress! + offset, count - offset) }
        if written <= 0 {
          failed = true
          break copying
        }
        offset += written
      }
    }
    if !failed { fsync(output) }
    close(output)
    if failed || rename(temp.path, target.path) != 0 {
      let reason = String(cString: strerror(errno))
      unlink(temp.path)
      throw refusal(
        "write_failed", "寫不了「\(relative)」（\(reason)）。磁碟滿了嗎？",
        "Could not write \"\(relative)\" (\(reason)). Is the disk full?")
    }
  }
}
