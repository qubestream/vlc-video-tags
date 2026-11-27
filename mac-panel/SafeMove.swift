// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// Moving or renaming a file without ever overwriting another one. Used by the
// deferred Move and Rename, and by Undo. Foundation only, so
// tests/test_safe_move.sh can check it without the app.

import Foundation

enum SafeMove {
    enum Failure: LocalizedError {
        case taken(String)
        case noFreeName(String)

        var errorDescription: String? {
            switch self {
            case .taken(let name): return "There's already a file named \(name) there"
            case .noFreeName(let name): return "No free name left for \(name)"
            }
        }
    }

    /// The name to try for attempt `n`: "Name.ext", then "Name (1).ext",
    /// "Name (2).ext"… A name without an extension gets "Name (1)".
    static func candidate(_ name: String, _ n: Int) -> String {
        guard n > 0 else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
    }

    /// Moves `source` into `folder` as `name`. If that name is taken, it uses
    /// the lowest free "Name (n).ext" (with `numbering` off it throws instead).
    /// Returns where the file ended up.
    ///
    /// Taking a name is atomic: `renamex_np` with `RENAME_EXCL` fails rather
    /// than replace a file, so a file that appears there at the same moment is
    /// never overwritten; the next number is tried instead. Across volumes the
    /// file is first copied into the folder under a hidden name, which then
    /// takes the free name the same way, and only then is the original removed.
    /// Finder tags and comment xattrs travel with the file both ways.
    ///
    /// A name that is the file itself (a case-only rename, or a move into the
    /// folder it is already in) is not a clash.
    static func move(_ source: URL, into folder: URL, named name: String,
                     numbering: Bool = true, limit: Int = 9999) throws -> URL {
        let fm = FileManager.default
        let src = source.path
        let first = folder.appendingPathComponent(name)
        if isSelf(src, first.path) {
            if src != first.path { try check(rename(src, first.path), src) }
            return first
        }

        var staged: String?          // the hidden copy when crossing volumes
        defer { if let staged { try? fm.removeItem(atPath: staged) } }

        var n = 0
        while n <= limit {
            let target = folder.appendingPathComponent(candidate(name, n))
            let from = staged ?? src
            switch claim(from, target.path) {
            case 0:
                if staged != nil {
                    staged = nil
                    do { try fm.removeItem(atPath: src) } catch {
                        // Leave things as they were rather than keep two copies.
                        try? fm.removeItem(at: target)
                        throw error
                    }
                }
                return target
            case EEXIST, ENOTEMPTY:
                guard numbering else { throw Failure.taken(target.lastPathComponent) }
                n += 1
            case EXDEV where staged == nil:
                let hidden = folder.appendingPathComponent(".videotags-move-\(UUID().uuidString)").path
                try fm.copyItem(atPath: src, toPath: hidden)
                staged = hidden   // retry the same name with the copy
            case let code:
                throw posixError(code, from)
            }
        }
        throw Failure.noFreeName(name)
    }

    /// Renames `from` to `to` only if `to` is free. Returns 0 or an errno.
    private static func claim(_ from: String, _ to: String) -> Int32 {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { return code }
        // A volume without RENAME_EXCL (some network and FAT drives): reserve
        // the name by creating it exclusively, then rename onto that empty
        // placeholder, which is the only thing replaced.
        let fd = open(to, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd < 0 { return errno }
        close(fd)
        if rename(from, to) == 0 { return 0 }
        let failed = errno
        unlink(to)
        return failed
    }

    /// The same file under a name that differs at most in case.
    private static func isSelf(_ a: String, _ b: String) -> Bool {
        guard a.lowercased() == b.lowercased() else { return false }
        var sa = stat(), sb = stat()
        guard lstat(a, &sa) == 0, lstat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    private static func check(_ result: Int32, _ path: String) throws {
        if result != 0 { throw posixError(errno, path) }
    }

    private static func posixError(_ code: Int32, _ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSFilePathErrorKey: path,
                           NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }
}
