// SPDX-License-Identifier: GPL-2.0-or-later
//
// Video Tags Panel: a native macOS floating panel for VLC-Video-Tags.
// Copyright (C) 2026 Glen Pridgen
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// What it does
//   Watches the file VLC is playing (over VLC's AppleScript dictionary) and
//   shows a small always-on-top panel to toggle Finder tags on it, or mark it
//   for Trash when you skip or the file ends. Same palette file and same
//   semantics as the Lua extension (1.1), plus what Lua cannot do:
//     - global hotkeys: ⌃⌥1…⌃⌥9 toggle palette tag N, ⌃⌥⌫ marks/unmarks Delete
//     - playback remote: previous / next video, play-pause, ±5 s, speed
//       (⌃⌥Space, ⌃⌥← ⌃⌥→, ⌃⌥↑ ⌃⌥↓ faster/slower, ⌃⌥0 normal speed)
//     - floats over full-screen VLC and follows you across Spaces
//     - Undo for the last Trash
//     - a Comments box that edits the file's Finder Get Info comment and saves
//       itself when you skip, pause, or quit (⌃⌥C jumps to it)
//     - a normal app: Dock icon, app menu, ⌘Q; optional Open at Login
//
// Build: open VideoTagsPanel.xcodeproj in Xcode, or run ./build.sh. macOS 14+.

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Paths and constants

enum Paths {
    static let vlcBundleID = "org.videolan.vlc"

    /// The user's real home folder. Inside the App Sandbox, NSHomeDirectory()
    /// and homeDirectoryForCurrentUser point at the app's container instead,
    /// where VLC's files are not.
    static let realHome: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    static var support: URL {
        realHome
            .appendingPathComponent("Library/Application Support/org.videolan.vlc", isDirectory: true)
    }

    /// Shared with the Lua extension, so both show the same buttons.
    static var palette: URL { support.appendingPathComponent("video-tags-palette.txt") }

    /// Every profile's tags and which one is active. The palette file always
    /// holds the active profile's tags, so the Lua extension follows along.
    static var profiles: URL { support.appendingPathComponent("video-tags-profiles.json") }
}

enum Rules {
    static let builtins = ["Green", "Yellow", "Red"]
    static let nearEnd = 0.98
    static let maxTagLength = 40
    static let pollInterval: TimeInterval = 1.0
    static let undoWindow: TimeInterval = 12
    static let jumpSeconds = 5

    /// Same rules as `sanitize_tag_name` in video_tags.lua.
    static func sanitize(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxTagLength,
              !name.contains(","), !name.contains(where: \.isNewline) else { return nil }
        return name
    }

    static func isBuiltin(_ name: String) -> Bool {
        name.caseInsensitiveCompare("Delete") == .orderedSame || builtins.containsIgnoringCase(name)
    }
}

extension Array where Element == String {
    func containsIgnoringCase(_ name: String) -> Bool {
        contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func removingIgnoringCase(_ name: String) -> [String] {
        filter { $0.caseInsensitiveCompare(name) != .orderedSame }
    }
}

// MARK: - Palette file (shared with the Lua extension)

struct PaletteStore {
    private(set) var lastModified: Date?

    mutating func load() -> [String] {
        let url = Paths.palette
        lastModified = Self.modificationDate(url)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            guard let name = Rules.sanitize(line), !Rules.isBuiltin(name), !out.containsIgnoringCase(name) else { continue }
            out.append(name)
        }
        return out
    }

    mutating func save(_ custom: [String]) throws {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let body = custom.map { $0 + "\n" }.joined()
        try body.write(to: Paths.palette, atomically: true, encoding: .utf8)
        lastModified = Self.modificationDate(Paths.palette)
    }

    /// True when the Lua extension (or a person) changed the file since we last read it.
    func changedOnDisk() -> Bool {
        Self.modificationDate(Paths.palette) != lastModified
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

// MARK: - Tag profiles

/// A named set of custom tags, such as Personal or Work. Green and Red are in every profile.
struct TagProfile: Codable, Equatable, Identifiable {
    var name: String
    var tags: [String]
    /// Tag name → folder path. Tagging a video with one of these tags moves it
    /// to that folder when you move on, the same way Delete waits.
    var moves: [String: String]?
    var id: String { name }

    func moveFolder(for tag: String) -> String? {
        moves?.first { $0.key.caseInsensitiveCompare(tag) == .orderedSame }?.value
    }

    mutating func setMoveFolder(_ folder: String?, for tag: String) {
        var all = (moves ?? [:]).filter { $0.key.caseInsensitiveCompare(tag) != .orderedSame }
        if let folder { all[tag] = folder }
        moves = all.isEmpty ? nil : all
    }
}

struct ProfileFile: Codable {
    var active: String
    var profiles: [TagProfile]
}

enum ProfileStore {
    static let defaultName = "Personal"

    static func load() -> ProfileFile? {
        guard let data = try? Data(contentsOf: Paths.profiles),
              var file = try? JSONDecoder().decode(ProfileFile.self, from: data) else { return nil }
        var seen: [String] = []
        file.profiles = file.profiles.compactMap { profile in
            guard let name = Rules.sanitize(profile.name), !seen.containsIgnoringCase(name) else { return nil }
            seen.append(name)
            var tags: [String] = []
            for tag in profile.tags {
                if let t = Rules.sanitize(tag), !Rules.isBuiltin(t), !tags.containsIgnoringCase(t) { tags.append(t) }
            }
            return TagProfile(name: name, tags: tags, moves: profile.moves)
        }
        guard let first = file.profiles.first else { return nil }
        if !seen.contains(file.active) { file.active = first.name }
        return file
    }

    static func save(_ file: ProfileFile) throws {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(file).write(to: Paths.profiles, options: .atomic)
    }
}

/// Asks for a short name in a small sheet-like alert. Returns nil on Cancel.
@MainActor
enum NamePrompt {
    static func ask(title: String, message: String, initial: String = "", confirm: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Asks for a new file name. Only the name is editable; the extension is
    /// shown beside the field and always kept.
    enum RenameChoice { case rename(String), keepName, cancel }

    static func rename(stem: String, ext: String, pending: Bool) -> RenameChoice {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.informativeText = "The file is renamed when this file ends or you skip, before any Move. Tags and comments stay with it."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if pending { alert.addButton(withTitle: "Keep Original Name") }
        let field = NSTextField(string: stem)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: ext.isEmpty ? 280 : 236).isActive = true
        let row = NSStackView(views: [field])
        row.orientation = .horizontal
        row.spacing = 4
        if !ext.isEmpty {
            let suffix = NSTextField(labelWithString: ".\(ext)")
            suffix.textColor = .secondaryLabelColor
            row.addArrangedSubview(suffix)
        }
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = row
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .rename(field.stringValue)
        case .alertThirdButtonReturn: return .keepName
        default: return .cancel
        }
    }

    static func confirm(title: String, message: String, button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Finder tags and Trash (Foundation only; no Finder automation needed)

enum FinderTags {
    static func read(_ path: String) -> [String] {
        let url = NSURL(fileURLWithPath: path)
        url.removeAllCachedResourceValues()
        var value: AnyObject?
        try? url.getResourceValue(&value, forKey: .tagNamesKey)
        return (value as? [String]) ?? []
    }

    static func write(_ path: String, _ tags: [String]) throws {
        try NSURL(fileURLWithPath: path).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
    }

    /// Adds the tag if missing, removes it if present, keeps every other tag.
    /// Returns true when the tag is now on.
    @discardableResult
    static func toggle(_ path: String, _ tag: String) throws -> Bool {
        let current = read(path)
        if current.containsIgnoringCase(tag) {
            try write(path, current.removingIgnoringCase(tag))
            return false
        }
        try write(path, current + [tag])
        return true
    }

    /// Removes palette tags only; unrelated tags such as "Work" stay.
    static func clear(_ path: String, palette: [String]) throws {
        let kept = read(path).filter { !palette.containsIgnoringCase($0) }
        try write(path, kept)
    }

    /// Moves the file into `folder`, adding " 2", " 3"… if the name is taken.
    /// Finder tags and the comment xattr travel with the file.
    /// Moves a file into `folder`, optionally under a new name, in one step.
    /// A name already taken there gets " 2", " 3"… (a case-only rename in
    /// the same folder is not a clash).
    static func move(_ path: String, into folder: String, named newName: String? = nil) throws -> URL {
        let source = URL(fileURLWithPath: path)
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder,
                NSLocalizedDescriptionKey: "The folder \(dir.lastPathComponent) isn't there (is the drive connected?)"])
        }
        let name = newName ?? source.lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path),
              target.path.lowercased() != source.path.lowercased() {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            target = dir.appendingPathComponent(name)
            n += 1
        }
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    static func trash(_ path: String) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting as URL?
    }
}

// MARK: - Finder comments (the "Comments" box in Get Info)
//
// Get Info shows the comment Finder keeps in the folder's .DS_Store; Spotlight
// indexes the copy in the com.apple.metadata:kMDItemFinderComment xattr.
// Writing through Finder updates both, so that is the main path. If Finder
// automation is refused, reads and writes fall back to the xattr alone, which
// Spotlight sees but Get Info may not.

final class FinderComments: @unchecked Sendable {
    enum Failure: Error { case notAuthorized, failed(String) }

    static let xattrName = "com.apple.metadata:kMDItemFinderComment"

    /// Serial: a save for the old video always lands before the load for the next.
    private let queue = DispatchQueue(label: "dev.qubestream.videotags.comments", qos: .userInitiated)

    /// The Finder comment, plus the comment stored inside the file (ID3, MP4, WAV), if any.
    struct Loaded { var finder: String; var embedded: String? }

    /// Queues the read now; `done` runs on the main thread.
    func read(_ path: String, done: @escaping @MainActor (Result<Loaded, Failure>) -> Void) {
        queue.async {
            let result = Self.readNow(path).map { Loaded(finder: $0, embedded: EmbeddedComment.read(path)) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    /// Queues the write now; `done` runs on the main thread. `stripEmbedded`
    /// also removes the comment stored inside the file.
    func write(_ path: String, _ text: String, stripEmbedded: Bool = false,
               done: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        queue.async {
            let result = Self.writeAll(path, text, stripEmbedded)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    private static func writeAll(_ path: String, _ text: String, _ stripEmbedded: Bool) -> Result<Void, Failure> {
        if stripEmbedded {
            do { try EmbeddedComment.remove(path) } catch { return .failure(.failed("could not edit the file")) }
        }
        return writeNow(path, text)
    }

    /// Blocks until queued reads and writes finish (before Trash, and on quit).
    func drain() { queue.sync {} }

    /// Synchronous write for app quit.
    @discardableResult
    func writeBlocking(_ path: String, _ text: String, stripEmbedded: Bool = false) -> Result<Void, Failure> {
        queue.sync { Self.writeAll(path, text, stripEmbedded) }
    }

    // MARK: Implementation (runs on `queue`)

    private static func readNow(_ path: String) -> Result<String, Failure> {
        let source = """
        set f to (POSIX file \(literal(path))) as alias
        tell application id "com.apple.finder" to return comment of f
        """
        switch run(source) {
        case .success(let value): return .success(value ?? "")
        case .failure(.notAuthorized): return .success(readXattr(path) ?? "")
        case .failure(let failure): return readXattr(path).map { .success($0) } ?? .failure(failure)
        }
    }

    private static func writeNow(_ path: String, _ text: String) -> Result<Void, Failure> {
        guard FileManager.default.fileExists(atPath: path) else { return .failure(.failed("File is gone")) }
        let source = """
        set f to (POSIX file \(literal(path))) as alias
        tell application id "com.apple.finder" to set comment of f to \(literal(text))
        """
        switch run(source) {
        case .success: return .success(())
        case .failure(let failure):
            // Keep the words even when Finder says no: Spotlight still gets them.
            writeXattr(path, text)
            return .failure(failure)
        }
    }

    /// AppleScript string literal; comments may hold quotes, backslashes and newlines.
    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ source: String) -> Result<String?, Failure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("Could not build the Finder script")) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == -1743 { return .failure(.notAuthorized) }
            return .failure(.failed((error[NSAppleScript.errorMessage] as? String) ?? "Finder error \(number)"))
        }
        return .success(result.stringValue)
    }

    static func readXattr(_ path: String) -> String? {
        let size = getxattr(path, xattrName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, xattrName, $0.baseAddress, size, 0, 0) }
        guard read > 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? String
    }

    static func writeXattr(_ path: String, _ text: String) {
        if text.isEmpty { removexattr(path, xattrName, 0); return }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { setxattr(path, xattrName, $0.baseAddress, data.count, 0, 0) }
    }
}

// MARK: - VLC over AppleScript

struct NowPlaying: Equatable {
    var path: String?        // nil: nothing playing, or not a local file
    var isStream: Bool       // something is playing but it is not a local file
    var time: Double         // seconds
    var duration: Double     // seconds, 0 when unknown
    var playing: Bool

    var progress: Double { duration > 0 ? min(max(time / duration, 0), 1) : 0 }
}

enum VLCError: Error, Equatable {
    case notRunning
    case notAuthorized          // -1743: Automation permission denied
    case script(Int, String)
}

final class VLCBridge {
    // VLC 3's dictionary: `path of current item`, `duration of current item`,
    // `current time`, `playing`. Each read is guarded so an empty playlist
    // returns blanks instead of an error.
    private static let source = """
    tell application id "org.videolan.vlc"
        set p to ""
        set t to -1
        set d to -1
        set pl to false
        try
            set p to path of current item
        end try
        try
            set t to current time
        end try
        try
            set d to duration of current item
        end try
        try
            set pl to playing
        end try
    end tell
    -- With nothing loaded (the playlist ended), VLC returns no result and the
    -- variable is left undefined rather than raising inside the try.
    try
        p
    on error
        set p to ""
    end try
    try
        t
    on error
        set t to -1
    end try
    try
        d
    on error
        set d to -1
    end try
    if p is missing value then set p to ""
    return {p as text, t as integer, d as integer, pl as boolean}
    """

    private var script: NSAppleScript?

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Paths.vlcBundleID).isEmpty
    }

    /// Never launches VLC: callers check `isRunning` first, and the script is
    /// compiled only once VLC is up.
    func snapshot() -> Result<NowPlaying, VLCError> {
        guard Self.isRunning else { return .failure(.notRunning) }
        if script == nil {
            script = NSAppleScript(source: Self.source)
            var compileError: NSDictionary?
            if script?.compileAndReturnError(&compileError) == false {
                script = nil
                return .failure(Self.error(from: compileError))
            }
        }
        var runError: NSDictionary?
        guard let result = script?.executeAndReturnError(&runError), runError == nil else {
            return .failure(Self.error(from: runError))
        }
        guard result.numberOfItems >= 4 else { return .failure(.script(0, "Unexpected reply from VLC")) }

        let raw = result.atIndex(1)?.stringValue ?? ""
        let time = Double(result.atIndex(2)?.int32Value ?? -1)
        let duration = Double(result.atIndex(3)?.int32Value ?? -1)
        let playing = result.atIndex(4)?.booleanValue ?? false

        let path = Self.localPath(raw)
        return .success(NowPlaying(
            path: path,
            isStream: path == nil && !raw.isEmpty,
            time: max(time, 0),
            duration: max(duration, 0),
            playing: playing
        ))
    }

    enum Command {
        case playPause, next, previous
        case jump(seconds: Int)
        case seek(seconds: Int)

        var source: String {
            let target = "tell application id \"org.videolan.vlc\""
            switch self {
            case .playPause: return "\(target) to play"          // VLC's `play` toggles play/pause
            case .next: return "\(target) to next"
            case .previous: return "\(target) to previous"
            case .jump(let seconds):
                return """
                \(target)
                    set t to (current time) + (\(seconds))
                    if t < 0 then set t to 0
                    set current time to t
                end tell
                """
            case .seek(let seconds):
                return "\(target) to set current time to \(max(seconds, 0))"
            }
        }
    }

    private var commandScripts: [String: NSAppleScript] = [:]

    /// Sends a transport command. Never launches VLC.
    @discardableResult
    func send(_ command: Command) -> VLCError? {
        guard Self.isRunning else { return .notRunning }
        let source = command.source
        guard let script = commandScripts[source] ?? NSAppleScript(source: source) else {
            return .script(0, "Could not build the VLC command")
        }
        if case .seek = command {} else { commandScripts[source] = script }   // one script per position: don't keep them
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error.map { Self.error(from: $0) }
    }

    /// VLC reports a POSIX path for local files; some builds report a file URL.
    static func localPath(_ raw: String) -> String? {
        if raw.hasPrefix("/") { return raw }
        if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL { return url.path }
        return nil
    }

    private static func error(from info: NSDictionary?) -> VLCError {
        let number = (info?[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info?[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
        switch number {
        case -1743: return .notAuthorized
        case -600, -609: return .notRunning
        default: return .script(number, message)
        }
    }
}

// MARK: - Speed over VLC's local web interface
//
// VLC 3's AppleScript dictionary has no playback rate, so speed goes through
// VLC's built-in HTTP interface (/requests/status.json) on 127.0.0.1.
// One-time setup writes a few settings to vlcrc while VLC is quit.

struct VLCWebSettings: Equatable {
    var port: Int
    var password: String
}

enum VLCPrefs {
    static let defaultPort = 9842

    static var vlcrc: URL {
        Paths.realHome
            .appendingPathComponent("Library/Preferences/org.videolan.vlc/vlcrc")
    }

    static var vlcAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.vlcBundleID)
    }

    /// The web settings VLC will use, or nil while its web interface is off.
    static func current() -> VLCWebSettings? {
        guard let text = try? String(contentsOf: vlcrc, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        let interfaces = (value(lines, section: "core", key: "extraintf") ?? "").split(separator: ":").map(String.init)
        guard interfaces.contains("http"),
              let password = value(lines, section: "lua", key: "http-password"), !password.isEmpty else { return nil }
        let port = value(lines, section: "core", key: "http-port").flatMap { Int($0) } ?? 8080
        return VLCWebSettings(port: port, password: password)
    }

    /// Turns on VLC's web interface on localhost. Keeps a password, port or
    /// host the user already set. Call only while VLC is not running, because
    /// VLC can rewrite vlcrc when it quits. Backs up the original once.
    static func enableWebInterface() throws -> VLCWebSettings {
        let existing = (try? String(contentsOf: vlcrc, encoding: .utf8)) ?? ""
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")

        var interfaces = (value(lines, section: "core", key: "extraintf") ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if !interfaces.contains("http") { interfaces.append("http") }
        set(&lines, section: "core", key: "extraintf", to: interfaces.joined(separator: ":"))

        var password = value(lines, section: "lua", key: "http-password") ?? ""
        if password.isEmpty {
            password = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            set(&lines, section: "lua", key: "http-password", to: password)
        }

        let port: Int
        if let configured = value(lines, section: "core", key: "http-port").flatMap({ Int($0) }) {
            port = configured
        } else {
            port = defaultPort
            set(&lines, section: "core", key: "http-port", to: String(port))
        }

        if value(lines, section: "core", key: "http-host") == nil {
            set(&lines, section: "core", key: "http-host", to: "127.0.0.1")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: vlcrc.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !existing.isEmpty {
            let backup = vlcrc.appendingPathExtension("video-tags-backup")
            if !fm.fileExists(atPath: backup.path) {
                try? existing.write(to: backup, atomically: true, encoding: .utf8)
            }
        }
        try lines.joined(separator: "\n").write(to: vlcrc, atomically: true, encoding: .utf8)
        return VLCWebSettings(port: port, password: password)
    }

    // vlcrc is INI-style: "[core] # core program" headers, "key=value" lines,
    // and "#key=default" for settings left at their default.

    private static func sectionName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), let close = t.firstIndex(of: "]") else { return nil }
        return String(t[t.index(after: t.startIndex)..<close])
    }

    private static func sectionRange(_ lines: [String], _ section: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { sectionName($0) == section }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: { sectionName($0) != nil }) ?? lines.count
        return (start + 1)..<end
    }

    static func value(_ lines: [String], section: String, key: String) -> String? {
        guard let range = sectionRange(lines, section) else { return nil }
        for line in lines[range] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + "=") { return String(t.dropFirst(key.count + 1)) }
        }
        return nil
    }

    private static func set(_ lines: inout [String], section: String, key: String, to newValue: String) {
        let entry = "\(key)=\(newValue)"
        guard let range = sectionRange(lines, section) else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines.append(entry)
            return
        }
        let snapshot = lines
        let trimmed: (Int) -> String = { snapshot[$0].trimmingCharacters(in: .whitespaces) }
        if let i = range.first(where: { trimmed($0).hasPrefix(key + "=") }) {
            lines[i] = entry
        } else if let i = range.first(where: { trimmed($0).hasPrefix("#" + key + "=") }) {
            lines[i] = entry
        } else {
            lines.insert(entry, at: range.lowerBound)
        }
    }
}

enum VLCWeb {
    enum Failure: Error { case unreachable, unauthorized, badReply }

    /// Reads the playback rate, setting it first when `newRate` is given.
    static func rate(_ settings: VLCWebSettings, set newRate: Double? = nil) async -> Result<Double, Failure> {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = settings.port
        components.path = "/requests/status.json"
        if let newRate {
            components.queryItems = [
                URLQueryItem(name: "command", value: "rate"),
                URLQueryItem(name: "val", value: String(format: "%.2f", newRate)),
            ]
        }
        guard let url = components.url else { return .failure(.badReply) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        let token = Data(":\(settings.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return .failure(.unauthorized) }
            guard code == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rate = (json["rate"] as? NSNumber)?.doubleValue else { return .failure(.badReply) }
            return .success(rate)
        } catch {
            return .failure(.unreachable)
        }
    }
}

enum Speed {
    static let steps: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]

    static func faster(than rate: Double) -> Double { steps.first { $0 > rate + 0.01 } ?? steps[steps.count - 1] }
    static func slower(than rate: Double) -> Double { steps.last { $0 < rate - 0.01 } ?? steps[0] }

    static func label(_ rate: Double) -> String {
        let rounded = (rate * 100).rounded() / 100
        return String(format: "%g×", rounded)
    }
}

// MARK: - Model

@MainActor
final class PanelModel: ObservableObject {
    enum Connection: Equatable {
        case vlcNotRunning
        case nothingPlaying
        case stream
        case playing
        case needsPermission
        case failed(String)
    }

    enum SpeedStatus: Equatable {
        case off          // VLC's web interface is not set up
        case settingUp    // quitting VLC, writing vlcrc, reopening
        case connecting   // set up, waiting for VLC to answer (it may need one restart)
        case ready
    }

    /// The last Trash or folder move, kept for a short Undo.
    struct LastMove {
        let originalPath: String
        let movedURL: URL
        let at: Date
    }

    /// A tag with a folder was put on a video: it moves there when you move on.
    struct PendingMove: Equatable {
        let path: String
        let folder: String
        let tag: String
        var folderName: String { (folder as NSString).lastPathComponent }
    }

    /// A new name for a video: applied when you move on, before any Move.
    struct PendingRename: Equatable {
        let path: String
        let name: String      // full file name, extension included
    }

    @Published private(set) var connection: Connection = .vlcNotRunning
    @Published private(set) var currentPath: String?
    @Published private(set) var tags: [String] = []           // palette tags on the current file
    @Published private(set) var custom: [String] = []
    @Published private(set) var profiles: [TagProfile] = []
    @Published private(set) var activeProfile = ProfileStore.defaultName
    @Published private(set) var pendingDelete: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsed: Double = 0                // seconds
    @Published private(set) var duration: Double = 0               // seconds, 0 when unknown
    @Published private(set) var playing = false
    @Published private(set) var message: String?
    @Published private(set) var lastMove: LastMove?
    @Published private(set) var pendingMove: PendingMove?
    @Published private(set) var pendingRename: PendingRename?
    @Published private(set) var speedStatus: SpeedStatus = .off
    @Published private(set) var rate: Double = 1
    @Published var showSpeedSetup = false
    @Published var comment = ""                                   // bound to the comment box
    @Published private(set) var commentLoading = false
    @Published private(set) var commentFocusRequest = 0
    @Published private(set) var savedComment = ""
    /// The box is showing the comment stored inside the file (no Finder comment).
    @Published private(set) var commentFromFile = false

    var palette: [String] { Rules.builtins + custom }
    var fileName: String? { currentPath.map { ($0 as NSString).lastPathComponent } }
    var pendingIsCurrent: Bool { pendingDelete != nil && pendingDelete == currentPath }
    var pendingMoveIsCurrent: Bool { pendingMove != nil && pendingMove?.path == currentPath }
    var pendingRenameIsCurrent: Bool { pendingRename != nil && pendingRename?.path == currentPath }

    /// The folder a tag moves videos to, in the active profile.
    func moveFolder(for tag: String) -> String? {
        profiles.first { $0.name == activeProfile }?.moveFolder(for: tag)
    }
    var commentDirty: Bool { commentPath != nil && comment != savedComment }

    private let vlc = VLCBridge()
    private var store = PaletteStore()
    private var timer: Timer?
    private var lastProgress: Double = 0
    private var messageTask: Task<Void, Never>?
    private var web: VLCWebSettings?
    private var rateInFlight = false
    private var rateGeneration = 0
    private let comments = FinderComments()
    private var commentPath: String?      // the file `comment` belongs to

    init() {
        custom = store.load()
        if let file = ProfileStore.load() {
            profiles = file.profiles
            activeProfile = file.active
            // The palette file is the truth for the active profile: the Lua
            // extension may have added tags while the panel was closed.
            syncActiveProfile()
        } else {
            // First run with profiles: today's palette becomes the default profile.
            profiles = [TagProfile(name: ProfileStore.defaultName, tags: custom)]
            activeProfile = ProfileStore.defaultName
            saveProfiles()
        }
        web = VLCPrefs.current()
        speedStatus = web == nil ? .off : .connecting
    }

    func start() {
        tick()
        let timer = Timer(timeInterval: Rules.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Poll

    func tick() {
        if store.changedOnDisk() { custom = store.load(); syncActiveProfile(); refreshTags() }

        switch vlc.snapshot() {
        case .failure(.notRunning):
            // Quitting VLC applies a pending Rename and Move. A pending Delete
            // leaves the file exactly as it is, same as the Lua extension.
            if connection != .vlcNotRunning {
                saveComment()
                if pendingDelete != nil {
                    pendingDelete = nil; pendingRename = nil; pendingMove = nil
                } else {
                    flushFileActions()
                }
            }
            connection = .vlcNotRunning
            setCurrent(nil)
            playing = false
            progress = 0
            elapsed = 0
            duration = 0
            rate = 1
        case .failure(.notAuthorized):
            connection = .needsPermission
        case .failure(.script(let code, let text)):
            connection = .failed("\(text) (\(code))")
        case .success(let now):
            apply(now)
            refreshRate()
        }
    }

    private func apply(_ now: NowPlaying) {
        // Save the comment before anything moves: on skip, and when playback pauses.
        if now.path != currentPath || (playing && !now.playing) { saveComment() }

        // Delete, Rename and Move wait for the video to be done with: a
        // different file started (skip), or the playlist ran out right after
        // the marked file reached its end.
        let pendingPath = pendingDelete ?? pendingRename?.path ?? pendingMove?.path
        if let pending = pendingPath {
            let skipped = now.path != nil && now.path != pending
            let ended = now.path == nil && pending == currentPath && lastProgress >= Rules.nearEnd
            if skipped || ended { flushFileActions() }
        }

        connection = now.path != nil ? .playing : (now.isStream ? .stream : .nothingPlaying)
        setCurrent(now.path)
        playing = now.playing
        progress = now.progress
        elapsed = now.time
        duration = now.duration
        if now.path != nil { lastProgress = now.progress }
        refreshTags()
    }

    private func setCurrent(_ path: String?) {
        guard path != currentPath else { return }
        saveComment()
        currentPath = path
        lastProgress = 0
        refreshTags()
        loadComment(for: path)
    }

    private func refreshTags() {
        guard let path = currentPath else { tags = []; return }
        let onFile = FinderTags.read(path)
        let next = palette.filter { onFile.containsIgnoringCase($0) }
        if next != tags { tags = next }
    }

    // MARK: Finder comment

    /// Writes the comment box to the file's Get Info Comments if it changed.
    /// Called on skip, pause, VLC quitting, Return, leaving the box, and app quit.
    func saveComment() {
        guard let path = commentPath, comment != savedComment else { return }
        let text = comment
        // Clearing a comment that came from inside the file removes it there too.
        let strip = commentFromFile && text.isEmpty
        savedComment = text
        commentFromFile = false
        let name = (path as NSString).lastPathComponent
        comments.write(path, text, stripEmbedded: strip) { [weak self] result in
            switch result {
            case .success:
                self?.flash(text.isEmpty ? "Cleared comment on \(name)" : "Saved comment to \(name)")
            case .failure(.notAuthorized):
                self?.flash("Finder access is off, so Get Info won't show it. Allow Finder under Privacy & Security → Automation.")
            case .failure(.failed(let why)):
                self?.flash("Could not save comment: \(why)")
            }
        }
    }

    /// Empties the box and saves right away (the × button).
    func clearComment() {
        comment = ""
        saveComment()
    }

    /// Throws away unsaved typing and goes back to what Get Info has.
    func revertComment() {
        comment = savedComment
    }

    /// Saves synchronously; used when the app quits.
    func saveCommentBeforeQuit() {
        guard let path = commentPath, comment != savedComment else { return }
        let strip = commentFromFile && comment.isEmpty
        savedComment = comment
        commentFromFile = false
        comments.writeBlocking(path, comment, stripEmbedded: strip)
    }

    func focusComment() {
        guard currentPath != nil else { flash("Nothing playing"); return }
        commentFocusRequest += 1
    }

    /// Gives the keyboard back to VLC after typing a comment.
    func returnFocusToVLC() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Paths.vlcBundleID).first?.activate()
    }

    private func loadComment(for path: String?) {
        commentPath = path
        comment = ""
        savedComment = ""
        commentFromFile = false
        commentLoading = path != nil
        guard let path else { return }
        comments.read(path) { [weak self] result in
            guard let self, self.commentPath == path else { return }   // already moved on
            self.commentLoading = false
            if case .success(let loaded) = result {
                // Show the Finder comment; if there is none, the one inside the file.
                let fromFile = loaded.finder.isEmpty && loaded.embedded != nil
                let text = fromFile ? loaded.embedded ?? "" : loaded.finder
                self.commentFromFile = fromFile
                self.savedComment = text
                self.comment = text
            }
        }
    }

    // MARK: Playback remote

    func playPause() { send(.playPause) }
    func nextVideo() { send(.next) }
    func previousVideo() { send(.previous) }
    func jumpBack() { send(.jump(seconds: -Rules.jumpSeconds)) }
    func jumpForward() { send(.jump(seconds: Rules.jumpSeconds)) }

    /// Moves playback to a point on the progress bar (0…1).
    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        let f = min(max(fraction, 0), 1)
        // Stop just short of the very end so VLC does not skip to the next file.
        let seconds = min(Int((f * duration).rounded()), max(Int(duration) - 1, 0))
        progress = f
        elapsed = Double(seconds)
        send(.seek(seconds: seconds))
    }

    func faster() { setRate(Speed.faster(than: rate)) }
    func slower() { setRate(Speed.slower(than: rate)) }
    func normalSpeed() { setRate(1) }

    private func send(_ command: VLCBridge.Command) {
        switch vlc.send(command) {
        case nil: tick()   // show the new state right away
        case .notRunning?: flash("VLC is not running")
        case .notAuthorized?: connection = .needsPermission
        case .script(let code, let text)?: flash("VLC: \(text) (\(code))")
        }
    }

    private func setRate(_ newRate: Double) {
        guard let web, speedStatus == .ready else {
            if speedStatus == .connecting {
                flash("Waiting for VLC's web control. If this stays, quit and reopen VLC.")
            } else {
                showSpeedSetup = true
            }
            return
        }
        rate = newRate   // optimistic; the reply confirms it
        rateGeneration += 1   // any status read already on its way is now stale
        Task { @MainActor [weak self] in
            let result = await VLCWeb.rate(web, set: newRate)
            self?.handleRate(result)
        }
    }

    private func refreshRate() {
        guard let web, !rateInFlight, speedStatus != .settingUp else { return }
        rateInFlight = true
        let generation = rateGeneration
        Task { @MainActor [weak self] in
            let result = await VLCWeb.rate(web)
            guard let self else { return }
            self.rateInFlight = false
            // A speed change landed while this read was out: its answer is the old speed.
            if case .success = result, generation != self.rateGeneration { return }
            self.handleRate(result)
        }
    }

    private func handleRate(_ result: Result<Double, VLCWeb.Failure>) {
        switch result {
        case .success(let value):
            rate = value
            speedStatus = .ready
        case .failure(.unauthorized):
            // Someone changed VLC's web password; set up again picks it up.
            web = nil
            speedStatus = .off
        case .failure:
            if speedStatus == .ready { speedStatus = .connecting }
        }
    }

    /// One-time setup: quit VLC, turn on its web interface on localhost, reopen it.
    func setUpSpeed() {
        guard speedStatus != .settingUp else { return }
        guard let appURL = VLCPrefs.vlcAppURL else { flash("VLC is not installed"); return }
        speedStatus = .settingUp
        showSpeedSetup = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.vlcBundleID)
            running.forEach { $0.terminate() }
            for _ in 0..<60 where VLCBridge.isRunning {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !VLCBridge.isRunning else {
                self.speedStatus = self.web == nil ? .off : .connecting
                self.flash("VLC didn't quit. Quit it, then try Set up again.")
                return
            }
            do {
                self.web = try VLCPrefs.enableWebInterface()
            } catch {
                self.speedStatus = .off
                self.flash("Could not update VLC settings: \(error.localizedDescription)")
                return
            }
            self.speedStatus = .connecting
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            self.flash("Speed control is on. VLC reopened.")
        }
    }

    // MARK: Actions

    func toggle(_ name: String) {
        guard let path = requireFile() else { return }
        if pendingDelete == path { pendingDelete = nil }
        do {
            let on = try FinderTags.toggle(path, name)
            refreshTags()
            if on, let folder = moveFolder(for: name) {
                let move = PendingMove(path: path, folder: folder, tag: name)
                pendingMove = move
                flash("Tagged \(name) · moves to \(move.folderName) when you move on")
                return
            }
            if !on, let move = pendingMove, move.path == path, move.tag.caseInsensitiveCompare(name) == .orderedSame {
                pendingMove = nil
                flash("Removed \(name) · it stays where it is")
                return
            }
            flash(on ? "Tagged \(name)" : "Removed \(name)")
        } catch {
            flash("Could not change tag: \(error.localizedDescription)")
        }
    }

    func toggle(index: Int) {
        guard palette.indices.contains(index) else { return }
        toggle(palette[index])
    }

    /// Mark the current file for Trash, or unmark it if already marked.
    /// Tags are kept until the file is actually trashed, so unmarking loses nothing.
    func toggleDelete() {
        guard let path = requireFile() else { return }
        if pendingDelete == path {
            pendingDelete = nil
            flash("Delete cancelled")
        } else {
            // A pending Rename or Move is kept: Delete wins when you move on,
            // and cancelling Delete brings them back.
            pendingDelete = path
            flash("Will move to Trash when this file ends or you skip")
        }
    }

    func add(_ raw: String) -> Bool {
        guard let name = Rules.sanitize(raw) else {
            flash("Tag names are 1–40 characters, no commas")
            return false
        }
        if Rules.isBuiltin(name) { flash("\(name) is already a built-in button"); return false }
        if custom.containsIgnoringCase(name) { flash("\(name) is already in the palette"); return false }
        custom.append(name)
        persistPalette()
        if let path = currentPath {
            if pendingDelete == path { pendingDelete = nil }
            var onFile = FinderTags.read(path)
            if !onFile.containsIgnoringCase(name) { onFile.append(name) }
            try? FinderTags.write(path, onFile)
            refreshTags()
            flash("Added and tagged \(name)")
        } else {
            flash("Added \(name) to the palette")
        }
        return true
    }

    /// Drops a custom name from the palette. Files already tagged are not changed.
    func remove(_ name: String) {
        guard !Rules.isBuiltin(name) else { return }
        custom = custom.removingIgnoringCase(name)
        persistPalette()
        if moveFolder(for: name) != nil { setMoveFolder(nil, for: name, quiet: true) }
        refreshTags()
        flash("Removed \(name) from the palette")
    }

    /// Gives a tag a folder to move videos to, or clears it (nil).
    func setMoveFolder(_ folder: String?, for tag: String, quiet: Bool = false) {
        guard let i = profiles.firstIndex(where: { $0.name == activeProfile }) else { return }
        profiles[i].setMoveFolder(folder, for: tag)
        saveProfiles()
        if let move = pendingMove, move.tag.caseInsensitiveCompare(tag) == .orderedSame {
            pendingMove = folder.map { PendingMove(path: move.path, folder: $0, tag: move.tag) }
        }
        guard !quiet else { return }
        if let folder {
            flash("\(tag) now moves files to \((folder as NSString).lastPathComponent)")
        } else {
            flash("\(tag) no longer moves files")
        }
    }

    func undoLastMove() {
        guard let last = lastMove else { return }
        do {
            try FileManager.default.moveItem(at: last.movedURL, to: URL(fileURLWithPath: last.originalPath))
            lastMove = nil
            flash("Restored \((last.originalPath as NSString).lastPathComponent)")
        } catch {
            flash("Could not restore: \(error.localizedDescription)")
        }
    }

    // MARK: Internals

    /// Runs what is pending for the video you just left, in this order:
    /// Delete wins outright; otherwise Rename then Move, as one step, so the
    /// file lands in the Move folder under its new name.
    private func flushFileActions() {
        let delete = pendingDelete, rename = pendingRename, move = pendingMove
        pendingDelete = nil; pendingRename = nil; pendingMove = nil
        comments.drain()   // a comment save for this file is queued just before

        if let path = delete {
            try? FinderTags.clear(path, palette: palette)
            do {
                if let trashed = try FinderTags.trash(path) { offerUndo(path, trashed) }
                flash("Moved \((path as NSString).lastPathComponent) to Trash")
            } catch {
                flash("Could not move to Trash: \(error.localizedDescription)")
            }
            return
        }

        // Rename and Move belong to the same file unless a skip raced a mark.
        guard let path = rename?.path ?? move?.path else { return }
        let newName = rename?.path == path ? rename?.name : nil
        let folder = move?.path == path ? move?.folder : nil
        let oldName = (path as NSString).lastPathComponent
        let dir = folder ?? (path as NSString).deletingLastPathComponent
        do {
            let moved = try FinderTags.move(path, into: dir, named: newName)
            offerUndo(path, moved)
            let finalName = moved.lastPathComponent
            switch (newName, folder) {
            case (_?, let folder?):
                flash("Renamed to \(finalName) and moved to \((folder as NSString).lastPathComponent)")
            case (_?, nil):
                flash("Renamed \(oldName) to \(finalName)")
            default:
                flash("Moved \(oldName) to \(move?.folderName ?? "")")
            }
        } catch {
            flash("Could not \(newName != nil ? "rename" : "move") \(oldName): \(error.localizedDescription)")
        }
    }

    private func offerUndo(_ original: String, _ moved: URL) {
        let entry = LastMove(originalPath: original, movedURL: moved, at: Date())
        lastMove = entry
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Rules.undoWindow))
            if self?.lastMove?.at == entry.at { self?.lastMove = nil }
        }
    }

    /// Sets the name the current video gets when you move on (extension
    /// kept). Giving it back its own name cancels the rename.
    func setPendingRename(_ raw: String) {
        guard let path = requireFile() else { return }
        let stem = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, !stem.hasPrefix("."), !stem.contains("/"), !stem.contains(":") else {
            flash("A name can't be empty, start with a dot, or contain / or :")
            return
        }
        let source = URL(fileURLWithPath: path)
        let ext = source.pathExtension
        let newName = ext.isEmpty ? stem : "\(stem).\(ext)"
        if newName == source.lastPathComponent {
            cancelPendingRename()
            return
        }
        // Check the folder it will land in now; at move-on time a late
        // clash gets " 2" instead of overwriting anything.
        let folders = [source.deletingLastPathComponent().path] + (pendingMoveIsCurrent ? [pendingMove!.folder] : [])
        for folder in folders {
            let target = URL(fileURLWithPath: folder).appendingPathComponent(newName)
            let caseOnly = target.path.lowercased() == path.lowercased()
            if !caseOnly, FileManager.default.fileExists(atPath: target.path) {
                flash("There's already a file named \(newName) in \((folder as NSString).lastPathComponent)")
                return
            }
        }
        pendingRename = PendingRename(path: path, name: newName)
        flash("Renames to \(newName) when this file ends or you skip")
    }

    func cancelPendingRename() {
        guard pendingRenameIsCurrent else { return }
        pendingRename = nil
        flash("Rename cancelled")
    }

    private func requireFile() -> String? {
        if let path = currentPath { return path }
        switch connection {
        case .stream: flash("Tags apply to local files only")
        case .vlcNotRunning: flash("VLC is not running")
        default: flash("Nothing playing")
        }
        return nil
    }

    private func persistPalette() {
        do { try store.save(custom) } catch { flash("Could not save palette: \(error.localizedDescription)") }
        syncActiveProfile()
    }

    // MARK: Profiles

    private var activeIndex: Int? { profiles.firstIndex { $0.name == activeProfile } }

    /// Copies the palette into the active profile and saves if it changed.
    private func syncActiveProfile() {
        guard let i = activeIndex, profiles[i].tags != custom else { return }
        profiles[i].tags = custom
        saveProfiles()
    }

    private func saveProfiles() {
        do { try ProfileStore.save(ProfileFile(active: activeProfile, profiles: profiles)) }
        catch { flash("Could not save profiles: \(error.localizedDescription)") }
    }

    /// Swaps the whole tag grid, and so the ⌃⌥1–9 hotkeys, to another profile.
    func switchProfile(to name: String) {
        guard name != activeProfile, let profile = profiles.first(where: { $0.name == name }) else { return }
        syncActiveProfile()
        activeProfile = profile.name
        custom = profile.tags
        do { try store.save(custom) } catch { flash("Could not save palette: \(error.localizedDescription)") }
        saveProfiles()
        refreshTags()
        flash("\(profile.name) profile")
    }

    func nextProfile() {
        guard profiles.count > 1, let i = activeIndex else {
            flash("Only one profile. Add one with the profile menu.")
            return
        }
        switchProfile(to: profiles[(i + 1) % profiles.count].name)
    }

    /// Makes an empty profile and switches to it.
    @discardableResult
    func createProfile(_ raw: String) -> Bool {
        guard let name = Rules.sanitize(raw) else { flash("Profile names are 1–40 characters, no commas"); return false }
        guard !profiles.map(\.name).containsIgnoringCase(name) else { flash("There is already a \(name) profile"); return false }
        profiles.append(TagProfile(name: name, tags: []))
        saveProfiles()
        switchProfile(to: name)
        return true
    }

    @discardableResult
    func renameProfile(_ old: String, to raw: String) -> Bool {
        guard let i = profiles.firstIndex(where: { $0.name == old }) else { return false }
        guard let name = Rules.sanitize(raw) else { flash("Profile names are 1–40 characters, no commas"); return false }
        if name == old { return true }
        let others = profiles.map(\.name).filter { $0 != old }
        guard !others.containsIgnoringCase(name) else { flash("There is already a \(name) profile"); return false }
        profiles[i].name = name
        if activeProfile == old { activeProfile = name }
        saveProfiles()
        flash("Renamed to \(name)")
        return true
    }

    /// Deletes a profile's list of tags. Files already tagged are not changed.
    func deleteProfile(_ name: String) {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.name == name }) else { return }
        if name == activeProfile { switchProfile(to: profiles[i == 0 ? 1 : 0].name) }
        profiles.removeAll { $0.name == name }
        saveProfiles()
        flash("Deleted the \(name) profile")
    }

    private func flash(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

// MARK: - Global hotkeys (Carbon RegisterEventHotKey: no Accessibility permission needed)

@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var handlerInstalled = false
    private let signature: OSType = 0x5654_4147 // 'VTAG'

    /// ANSI digit key codes are not sequential, so list them.
    static let digitKeys: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
    static let modifiers = UInt32(controlKey | optionKey)
    static let modifierGlyphs = "⌃⌥"

    func register(keyCode: Int, id: UInt32, action: @escaping @MainActor () -> Void) {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), Self.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            actions[id] = action
        } else {
            NSLog("Video Tags Panel: hotkey \(id) is taken by another app (status \(status))")
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            // Carbon delivers hotkey events on the main thread.
            let id = hotKeyID.id
            if status == noErr { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Views

enum TagColor {
    /// Finder's built-in color tag names. Other names are plain tags.
    static func color(for name: String) -> Color? {
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "gray", "grey": return .gray
        default: return nil
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var draft = ""
    @FocusState private var commentFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            transportBar
            if model.showSpeedSetup {
                speedSetupCard
            }
            Divider().opacity(0.5)
            header
            if model.connection == .needsPermission {
                permissionCard
            } else {
                profileBar
                tagGrid
                HStack(spacing: 8) {
                    deleteButton
                    renameButton
                }
                addRow
            }
            footer
            if model.connection != .needsPermission {
                commentBox
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial)
        .animation(.snappy(duration: 0.18), value: model.showSpeedSetup)
        .animation(.snappy(duration: 0.18), value: model.tags)
        .animation(.snappy(duration: 0.18), value: model.pendingDelete)
        .animation(.snappy(duration: 0.18), value: model.pendingMove)
        .animation(.snappy(duration: 0.18), value: model.pendingRename)
        .onChange(of: model.commentFocusRequest) { commentFocused = true }
        .onChange(of: commentFocused) { _, focused in
            if !focused { model.saveComment() }
        }
    }

    // Finder comment: the same text as the Comments box in Get Info

    private var commentBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text("Comments")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(commentStatus)
                    .font(.caption2)
                    .foregroundStyle(model.commentDirty ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                if !model.comment.isEmpty, !model.commentLoading {
                    Button {
                        model.clearComment()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.commentFromFile
                          ? "Delete this comment from the file"
                          : "Delete this comment")
                }
            }
            TextField(
                model.commentLoading ? "Loading…" : "What's in this file?",
                text: $model.comment,
                axis: .vertical
            )
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .focused($commentFocused)
            .disabled(model.currentPath == nil || model.commentLoading)
            .onSubmit {
                model.saveComment()
                model.returnFocusToVLC()
            }
            .onExitCommand {
                model.revertComment()
                model.returnFocusToVLC()
            }
            .help("Saved to Finder's Get Info Comments when you skip, pause or press Return. If the comment came from inside the file, clearing it removes it from the file too. ⌥Return adds a line, Esc undoes your edit. \(HotKeys.modifierGlyphs)C jumps here.")
        }
    }

    private var commentStatus: String {
        if model.currentPath == nil { return "" }
        if model.commentLoading { return "Loading…" }
        if model.commentDirty { return "Saves on skip or pause" }
        if model.commentFromFile { return "Stored in the file" }
        if !model.savedComment.isEmpty { return "Saved in Get Info" }
        return "\(HotKeys.modifierGlyphs)C to type"
    }

    // Playback remote

    private var transportBar: some View {
        HStack(spacing: 2) {
            TransportButton(symbol: "backward.end.fill", help: "Previous  ⌃⌥←") { model.previousVideo() }
            TransportButton(symbol: "gobackward.5", help: "Back \(Rules.jumpSeconds) seconds") { model.jumpBack() }
            TransportButton(
                symbol: model.playing ? "pause.fill" : "play.fill",
                help: "Play / Pause  ⌃⌥Space",
                prominent: true
            ) { model.playPause() }
            TransportButton(symbol: "goforward.5", help: "Forward \(Rules.jumpSeconds) seconds") { model.jumpForward() }
            TransportButton(symbol: "forward.end.fill", help: "Next  ⌃⌥→") { model.nextVideo() }
            Spacer(minLength: 8)
            speedControl
        }
        .disabled(model.connection == .vlcNotRunning || model.connection == .needsPermission)
        .opacity(model.connection == .vlcNotRunning ? 0.5 : 1)
    }

    private var speedControl: some View {
        let ready = model.speedStatus == .ready
        let changed = ready && abs(model.rate - 1) > 0.01
        return HStack(spacing: 0) {
            Button { model.slower() } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .help("Slower  ⌃⌥↓")

            SpeedResetButton(label: speedLabel, ready: ready, changed: changed) {
                ready ? model.normalSpeed() : model.faster()
            }

            Button { model.faster() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .help("Faster  ⌃⌥↑")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .background(
            Capsule(style: .continuous)
                .fill(changed ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(changed ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback speed")
    }

    /// The number in the middle of the speed control. Clicking it goes back to 1×.
    private struct SpeedResetButton: View {
        let label: String
        let ready: Bool
        let changed: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(ready ? Color.primary : Color.secondary)
                    .frame(minWidth: 44, minHeight: 22)
                    .padding(.horizontal, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(hovering && (changed || !ready) ? 0.12 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
            .help(ready ? (changed ? "Reset to 1×  ⌃⌥0" : "Normal speed  ⌃⌥0") : "Set up speed control")
            .accessibilityLabel(ready ? "Speed \(label). Reset to 1×" : "Set up speed control")
        }
    }

    private var speedLabel: String {
        switch model.speedStatus {
        case .ready: return Speed.label(model.rate)
        case .settingUp, .connecting: return "…"
        case .off: return "Speed"
        }
    }

    private var speedSetupCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Turn on speed control?")
                .font(.callout.weight(.semibold))
            Text("VLC only lets other apps change speed through its built-in web control. Set up turns it on for this Mac only and restarts VLC once. Your other VLC settings stay as they are.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not now") { model.showSpeedSetup = false }
                Button("Set up") { model.setUpSpeed() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // Header: what is playing, and how far along

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: headerSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(headerTitle)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.currentPath ?? "")
            }
            if model.currentPath != nil {
                ScrubBar(
                    progress: model.progress,
                    elapsed: model.elapsed,
                    duration: model.duration,
                    tint: model.pendingIsCurrent ? .red : .accentColor,
                    seek: { model.seek(toFraction: $0) }
                )
            }
        }
    }

    private var headerSymbol: String {
        switch model.connection {
        case .playing: return model.playing ? "play.fill" : "pause.fill"
        case .stream: return "antenna.radiowaves.left.and.right"
        case .needsPermission: return "lock.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "film"
        }
    }

    private var headerTitle: String {
        switch model.connection {
        case .vlcNotRunning: return "VLC is not running"
        case .nothingPlaying: return "Nothing playing"
        case .stream: return "Streams can't be tagged"
        case .needsPermission: return "Allow access to VLC"
        case .failed: return "Can't read VLC"
        case .playing: return model.fileName ?? "Playing"
        }
    }

    // Profiles

    /// One click switches profile; the menu creates, renames and deletes.
    private var profileBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.profiles) { profile in
                        let active = profile.name == model.activeProfile
                        Button { model.switchProfile(to: profile.name) } label: {
                            Text(profile.name)
                                .font(.caption.weight(active ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(active ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                                .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.7) : Color.clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(active ? "Active profile" : "Switch to \(profile.name)")
                    }
                }
            }
            Menu {
                Button("New Profile…") { newProfile() }
                Button("Rename “\(model.activeProfile)”…") { renameProfile() }
                Divider()
                Button("Delete “\(model.activeProfile)”…", role: .destructive) { deleteProfile() }
                    .disabled(model.profiles.count < 2)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Profiles · \(HotKeys.modifierGlyphs)P switches to the next one")
        }
    }

    private func newProfile() {
        guard let name = NamePrompt.ask(title: "New Profile",
                                        message: "A profile is its own set of tags. Green and Red are in every profile.",
                                        confirm: "Create") else { return }
        model.createProfile(name)
    }

    private func renameProfile() {
        let old = model.activeProfile
        guard let name = NamePrompt.ask(title: "Rename Profile", message: "", initial: old, confirm: "Rename") else { return }
        model.renameProfile(old, to: name)
    }

    private func deleteProfile() {
        let name = model.activeProfile
        guard NamePrompt.confirm(title: "Delete the \(name) profile?",
                                 message: "Its tag buttons go away. Files you already tagged keep their tags.",
                                 button: "Delete") else { return }
        model.deleteProfile(name)
    }

    // Tags

    /// Green, Yellow and Red always share the top row; custom tags follow.
    private var tagGrid: some View {
        let builtins = Array(model.palette.prefix(Rules.builtins.count))
        let custom = Array(model.palette.dropFirst(Rules.builtins.count).enumerated())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(builtins.enumerated()), id: \.element) { index, name in
                    tagChip(name, index: index)
                }
            }
            if !custom.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(custom, id: \.element) { offset, name in
                        tagChip(name, index: Rules.builtins.count + offset)
                    }
                }
            }
        }
    }

    private func tagChip(_ name: String, index: Int) -> some View {
        TagChip(
            name: name,
            hotkey: index < HotKeys.digitKeys.count ? "\(HotKeys.modifierGlyphs)\(index + 1)" : nil,
            isOn: model.tags.containsIgnoringCase(name),
            enabled: model.currentPath != nil,
            moveFolder: model.moveFolder(for: name),
            movePending: model.pendingMoveIsCurrent && model.pendingMove?.tag.caseInsensitiveCompare(name) == .orderedSame
        ) {
            model.toggle(name)
        }
        .contextMenu {
            if let folder = model.moveFolder(for: name) {
                Button("Change Folder for “\(name)”…") { chooseFolder(for: name) }
                Button("Stop Moving “\(name)” Files to \((folder as NSString).lastPathComponent)") {
                    model.setMoveFolder(nil, for: name)
                }
            } else {
                Button("Move “\(name)” Files to a Folder…") { chooseFolder(for: name) }
            }
            if !Rules.isBuiltin(name) {
                Divider()
                Button("Remove “\(name)” from palette", role: .destructive) { model.remove(name) }
            }
        }
    }

    private func chooseFolder(for tag: String) {
        NSApp.activate()
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "Choose"
        open.message = "Files you tag “\(tag)” move to this folder when you skip or the file ends."
        if let current = model.moveFolder(for: tag) { open.directoryURL = URL(fileURLWithPath: current) }
        guard open.runModal() == .OK, let url = open.url else { return }
        model.setMoveFolder(url.path, for: tag)
    }

    private enum ActionButton { static let height: CGFloat = 32 }

    private var renameButton: some View {
        let pending = model.pendingRenameIsCurrent
        return Button(action: promptRename) {
            HStack {
                Image(systemName: pending ? "pencil.circle.fill" : "pencil")
                Text(pending ? "Renaming" : "Rename")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // Same size for Delete and Rename: the HStack must not size either one by its text.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: ActionButton.height, maxHeight: ActionButton.height)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(pending ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(pending ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.18), lineWidth: 1.5)
            )
            .foregroundStyle(pending ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.currentPath == nil)
        .opacity(model.currentPath == nil ? 0.55 : 1)
        .help(pending ? "Change or cancel the new name" : "Rename the file when this file ends or you skip")
    }

    private func promptRename() {
        guard let path = model.currentPath else { return }
        let url = URL(fileURLWithPath: path)
        let current = model.pendingRenameIsCurrent ? model.pendingRename!.name : url.lastPathComponent
        let ext = url.pathExtension
        let stem = ext.isEmpty ? current : (current as NSString).deletingPathExtension
        switch NamePrompt.rename(stem: stem, ext: ext, pending: model.pendingRenameIsCurrent) {
        case .rename(let name): model.setPendingRename(name)
        case .keepName: model.cancelPendingRename()
        case .cancel: break
        }
    }

    private var deleteButton: some View {
        Button {
            model.toggleDelete()
        } label: {
            HStack {
                Image(systemName: model.pendingIsCurrent ? "trash.fill" : "trash")
                Text(model.pendingIsCurrent ? "Trashing" : "Delete")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(HotKeys.modifierGlyphs)⌫").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            // Same size for Delete and Rename: the HStack must not size either one by its text.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: ActionButton.height, maxHeight: ActionButton.height)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(model.pendingIsCurrent ? Color.red.opacity(0.22) : DeleteStyle.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(model.pendingIsCurrent ? Color.red.opacity(0.7) : DeleteStyle.outline, lineWidth: 1.5)
            )
            .foregroundStyle(model.pendingIsCurrent ? Color.red : DeleteStyle.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.currentPath == nil)
        .opacity(model.currentPath == nil ? 0.55 : 1)
        .help(model.pendingIsCurrent ? "Click to cancel the delete" : "Move to Trash when this file ends or you skip")
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            TextField("New tag", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitDraft)
            Button(action: commitDraft) {
                Image(systemName: "plus")
            }
            .disabled(Rules.sanitize(draft) == nil)
            .help("Add to the palette and tag the current file")
        }
    }

    private func commitDraft() {
        if model.add(draft) { draft = "" }
    }

    // Permission and status

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Video Tags Panel needs permission to read what VLC is playing.")
                .font(.callout)
            Text("System Settings → Privacy & Security → Automation → Video Tags Panel → VLC")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Automation settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .transition(.opacity)
            Spacer(minLength: 0)
            if model.lastMove != nil {
                Button("Undo") { model.undoLastMove() }
                    .controlSize(.small)
            }
        }
    }

    private var footerText: String {
        if let message = model.message { return message }
        if case .failed(let detail) = model.connection { return detail }
        if model.pendingIsCurrent { return "Will move to Trash when this file ends or you skip" }
        let rename = model.pendingRenameIsCurrent ? model.pendingRename : nil
        let move = model.pendingMoveIsCurrent ? model.pendingMove : nil
        switch (rename, move) {
        case let (rename?, move?):
            return "Renames to \(rename.name), then moves to \(move.folderName), when this file ends or you skip"
        case let (rename?, nil):
            return "Renames to \(rename.name) when this file ends or you skip"
        case let (nil, move?):
            return "Moves to \(move.folderName) when this file ends or you skip"
        default: break
        }
        if model.currentPath == nil { return "Right-click a tag to give it a folder or remove it" }
        return model.tags.isEmpty ? "No tags" : "Tags: " + model.tags.joined(separator: ", ")
    }
}

struct TransportButton: View {
    let symbol: String
    let help: String
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 15 : 12, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: prominent ? 34 : 28, height: prominent ? 34 : 28)
                .background(
                    Circle().fill(
                        prominent
                            ? Color.accentColor.opacity(hovering ? 0.35 : 0.22)
                            : Color.primary.opacity(hovering ? 0.10 : 0)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Light orange Delete button: fill and outline in the same orange, so it stands
/// out from the tags. Separate light and dark values keep the text readable.
enum DeleteStyle {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        })
    }
    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    static let fill = dynamic(light: rgb(255, 214, 168), dark: rgb(255, 158, 64, 0.30))
    static let outline = dynamic(light: rgb(246, 163, 88), dark: rgb(255, 178, 102))
    static let text = dynamic(light: rgb(122, 56, 0), dark: rgb(255, 208, 156))
}

/// The progress bar under the title. Drag or click anywhere on it to move
/// through the file; VLC follows while you drag.
struct ScrubBar: View {
    let progress: Double
    let elapsed: Double
    let duration: Double
    let tint: Color
    let seek: (Double) -> Void

    @State private var dragFraction: Double?
    @State private var lastSent = Date.distantPast
    @State private var hovering = false

    private var shown: Double { dragFraction ?? progress }
    private var active: Bool { hovering || dragFraction != nil }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                        .frame(height: active ? 6 : 4)
                    Capsule().fill(tint)
                        .frame(width: width * shown, height: active ? 6 : 4)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .frame(width: 12, height: 12)
                        .offset(x: width * shown - 6)
                        .opacity(active ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let f = min(max(value.location.x / width, 0), 1)
                            dragFraction = f
                            // Follow along while dragging, a few times a second.
                            if Date().timeIntervalSince(lastSent) > 0.15 {
                                lastSent = Date()
                                seek(f)
                            }
                        }
                        .onEnded { value in
                            let f = min(max(value.location.x / width, 0), 1)
                            seek(f)
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering = $0 }
            .disabled(duration <= 0)
            HStack {
                Text(Self.clock(dragFraction.map { $0 * duration } ?? elapsed))
                Spacer()
                Text(duration > 0 ? Self.clock(duration) : "")
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .animation(.easeOut(duration: 0.12), value: active)
        .help("Drag to move through the file")
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.clock(elapsed)) of \(Self.clock(duration))")
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            let step = 10 / duration
            seek(direction == .increment ? progress + step : progress - step)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded()), 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

struct TagChip: View {
    let name: String
    let hotkey: String?
    let isOn: Bool
    let enabled: Bool
    var moveFolder: String? = nil
    var movePending = false
    let action: () -> Void

    @State private var hovering = false

    private var tint: Color { TagColor.color(for: name) ?? .accentColor }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(TagColor.color(for: name) ?? Color.secondary.opacity(0.35))
                        .frame(width: 10, height: 10)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.white)
                    }
                }
                Text(name)
                    .font(.system(.callout, design: .rounded).weight(isOn ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if moveFolder != nil {
                    Image(systemName: movePending ? "folder.fill" : "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(movePending ? Color.accentColor : Color.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? tint.opacity(0.25) : Color.primary.opacity(hovering ? 0.09 : 0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isOn ? tint.opacity(0.8) : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .help(hotkey.map { "\(isOn ? "Remove" : "Add") \(name)  \($0)" } ?? name)
        .accessibilityLabel("\(name) tag")
        .accessibilityValue(isOn ? "on" : "off")
    }
}

// MARK: - Panel window

final class FloatingPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Video Tags"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        // Follow the user across Spaces and over full-screen VLC.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear

        isOpaque = false
        // The hosting view's intrinsic size drives the panel size as tags are added.
        contentView = NSHostingView(rootView: rootView)

        if !setFrameUsingName("VideoTagsPanel") {
            positionTopRight()
        }
        setFrameAutosaveName("VideoTagsPanel")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeKey: Bool { true }   // so the "New tag" field takes typing
    override var canBecomeMain: Bool { false }

    /// Brings the panel back whether it was closed (red button) or minimized (yellow button).
    func show() {
        if isMiniaturized { deminiaturize(nil) }
        orderFrontRegardless()
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 24, y: screen.maxY - frame.height - 24))
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var model: PanelModel!
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = PanelModel()
        panel = FloatingPanel(rootView: PanelView(model: model))
        installStatusItem()
        installHotKeys()
        model.start()
        installMainMenu()
        installEditShortcuts()
        panel.orderFrontRegardless()
        undoAutomaticLoginItem()
    }

    // MARK: Open at Login (SMAppService, macOS 13+). Off unless the user turns it on.

    /// Builds before 1.5 turned Open at Login on by themselves on first launch.
    /// Turn that off once, so it is only ever on when the user chose it.
    private func undoAutomaticLoginItem() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "didSetUpLoginItem"), !defaults.bool(forKey: "loginItemIsOptIn") else { return }
        defaults.set(true, forKey: "loginItemIsOptIn")
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        UserDefaults.standard.set(true, forKey: "loginItemIsOptIn")
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Video Tags Panel: login item change failed: \(error.localizedDescription)")
        }
    }

    // Keeps every "Open at Login" item (app menu and menu-bar menu) in step.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleLoginItem(_:)) {
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else if item.action == #selector(togglePanel) {
            item.title = panel.isVisible && !panel.isMiniaturized ? "Hide Tags Panel" : "Show Tags Panel"
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // closing the panel keeps the app running; the Dock icon brings it back
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveCommentBeforeQuit()
        HotKeys.shared.unregisterAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    private func installHotKeys() {
        for (index, key) in HotKeys.digitKeys.enumerated() {
            HotKeys.shared.register(keyCode: key, id: UInt32(index + 1)) { [weak self] in
                self?.model.toggle(index: index)
            }
        }
        HotKeys.shared.register(keyCode: kVK_Delete, id: 100) { [weak self] in
            self?.model.toggleDelete()
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_P, id: 108) { [weak self] in
            self?.model.nextProfile()
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_C, id: 107) { [weak self] in
            guard let self else { return }
            self.panel.show()
            self.panel.makeKey()   // non-activating: VLC stays the active app
            self.model.focusComment()
        }
        let remote: [(key: Int, id: UInt32, action: @MainActor (PanelModel) -> Void)] = [
            (kVK_Space, 101, { $0.playPause() }),
            (kVK_LeftArrow, 102, { $0.previousVideo() }),
            (kVK_RightArrow, 103, { $0.nextVideo() }),
            (kVK_UpArrow, 104, { $0.faster() }),
            (kVK_DownArrow, 105, { $0.slower() }),
            (kVK_ANSI_0, 106, { $0.normalSpeed() }),
        ]
        for entry in remote {
            HotKeys.shared.register(keyCode: entry.key, id: entry.id) { [weak self] in
                guard let model = self?.model else { return }
                entry.action(model)
            }
        }
    }

    /// Menu-bar template glyph: the app icon's tag with the play button and
    /// string hole punched out, tilted the same way. Drawn in code so it stays
    /// crisp at every scale and follows the menu bar's light/dark tint.
    static func menuBarGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            let xf = NSAffineTransform()
            xf.translateX(by: 8.4, yBy: 9.6)   // optical centre after the tilt
            xf.rotate(byDegrees: -18)
            xf.scale(by: 0.86)
            xf.translateX(by: -9, yBy: -9)
            xf.concat()

            let tag = NSBezierPath()
            tag.move(to: NSPoint(x: 1.5, y: 9))
            tag.line(to: NSPoint(x: 6, y: 4))
            tag.line(to: NSPoint(x: 16.5, y: 4))
            tag.line(to: NSPoint(x: 16.5, y: 14))
            tag.line(to: NSPoint(x: 6, y: 14))
            tag.close()
            tag.lineJoinStyle = .round
            tag.lineWidth = 1.6
            NSColor.black.set()
            tag.fill()
            tag.stroke()

            ctx.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 4.2, y: 7.6, width: 2.8, height: 2.8)).fill()
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 9.6, y: 6.1))
            play.line(to: NSPoint(x: 14.2, y: 9))
            play.line(to: NSPoint(x: 9.6, y: 11.9))
            play.close()
            play.lineJoinStyle = .round
            play.lineWidth = 1.0
            play.fill()
            play.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Video Tags"
        return image
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarGlyph()
        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide Panel", action: #selector(togglePanel), keyEquivalent: "").target = self
        let profiles = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profiles.submenu = makeProfilesMenu()
        menu.addItem(profiles)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "\(HotKeys.modifierGlyphs)1–9 tags · P profile · ⌫ Delete · C comment · Space play · ←→ next/previous · ↑↓ speed", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        menu.addItem(withTitle: "Quit Video Tags Panel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// The panel takes typing without making the app active (so VLC keeps
    /// the menu bar), which means the Edit menu's ⌘C, ⌘V and friends never
    /// fire. Send them straight to whatever text field has the cursor, in the
    /// panel or in the Rename box.
    private var editMonitor: Any?
    private func installEditShortcuts() {
        editMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command || mods == [.command, .shift],
                  let window = NSApp.keyWindow,
                  window.firstResponder is NSText,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            let action: Selector?
            switch (key, mods.contains(.shift)) {
            case ("x", false): action = #selector(NSText.cut(_:))
            case ("c", false): action = #selector(NSText.copy(_:))
            case ("v", false): action = #selector(NSText.paste(_:))
            case ("a", false): action = #selector(NSText.selectAll(_:))
            case ("z", false): action = Selector(("undo:"))
            case ("z", true): action = Selector(("redo:"))
            default: action = nil
            }
            guard let action, NSApp.sendAction(action, to: nil, from: nil) else { return event }
            return nil
        }
    }

    /// Standard app menus, so the app has About, ⌘Q, ⌘H and a working Edit
    /// menu (⌘C/⌘V/⌘A in the Comments box need it).
    private func installMainMenu() {
        let name = "Video Tags Panel"
        let main = NSMenu()

        let appMenu = NSMenu(title: name)
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        appMenu.addItem(login)
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: name, action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        main.addItem(withTitle: "Profile", action: nil, keyEquivalent: "").submenu = makeProfilesMenu()

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Show Tags Panel", action: #selector(togglePanel), keyEquivalent: "1").target = self
        window.addItem(.separator())
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    /// Rebuilt each time it opens, so it lists the current profiles.
    private func makeProfilesMenu() -> NSMenu {
        let menu = NSMenu(title: "Profile")
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Profile" else { return }
        menu.removeAllItems()
        for (i, profile) in model.profiles.enumerated() {
            let item = NSMenuItem(title: profile.name, action: #selector(chooseProfile(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = profile.name == model.activeProfile ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let next = NSMenuItem(title: "Next Profile  \(HotKeys.modifierGlyphs)P", action: #selector(nextProfile), keyEquivalent: "")
        next.target = self
        next.isEnabled = model.profiles.count > 1
        menu.addItem(next)
        menu.addItem(withTitle: "New Profile…", action: #selector(newProfile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Rename “\(model.activeProfile)”…", action: #selector(renameProfile), keyEquivalent: "").target = self
    }

    @objc private func chooseProfile(_ sender: NSMenuItem) {
        guard model.profiles.indices.contains(sender.tag) else { return }
        model.switchProfile(to: model.profiles[sender.tag].name)
    }

    @objc private func nextProfile() { model.nextProfile() }

    @objc private func newProfile() {
        guard let name = NamePrompt.ask(title: "New Profile",
                                        message: "A profile is its own set of tags. Green and Red are in every profile.",
                                        confirm: "Create") else { return }
        model.createProfile(name)
    }

    @objc private func renameProfile() {
        let old = model.activeProfile
        guard let name = NamePrompt.ask(title: "Rename Profile", message: "", initial: old, confirm: "Rename") else { return }
        model.renameProfile(old, to: name)
    }

    @objc private func togglePanel() {
        if panel.isVisible && !panel.isMiniaturized { panel.orderOut(nil) } else { panel.show() }
    }
}

@main
enum VideoTagsPanelApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()   // NSApplication.delegate is weak; run() keeps this frame alive
        app.delegate = delegate
        app.setActivationPolicy(.regular)   // a normal app: Dock icon and app menu, plus the menu-bar item
        app.run()
    }
}
