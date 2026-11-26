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
//   for Trash when you skip or the video ends. Same palette file and same
//   semantics as the Lua extension (1.1), plus what Lua cannot do:
//     - global hotkeys: ⌃⌥1…⌃⌥9 toggle palette tag N, ⌃⌥⌫ marks/unmarks Delete
//     - playback remote: previous / next video, play-pause, ±5 s, speed
//       (⌃⌥Space, ⌃⌥← ⌃⌥→, ⌃⌥↑ ⌃⌥↓ faster/slower, ⌃⌥0 normal speed)
//     - floats over full-screen VLC and follows you across Spaces
//     - Undo for the last Trash
//     - starts on its own; no "VLC → Extensions" step every launch
//
// Build: ./build.sh (swiftc from Xcode or the Command Line Tools). macOS 14+.

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Paths and constants

enum Paths {
    static let vlcBundleID = "org.videolan.vlc"

    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/org.videolan.vlc", isDirectory: true)
    }

    /// Shared with the Lua extension, so both show the same buttons.
    static var palette: URL { support.appendingPathComponent("video-tags-palette.txt") }
}

enum Rules {
    static let builtins = ["Green", "Red"]
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

    static func trash(_ path: String) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting as URL?
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
        commandScripts[source] = script
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
        FileManager.default.homeDirectoryForCurrentUser
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

    struct LastTrash {
        let originalPath: String
        let trashedURL: URL
        let at: Date
    }

    @Published private(set) var connection: Connection = .vlcNotRunning
    @Published private(set) var currentPath: String?
    @Published private(set) var tags: [String] = []           // palette tags on the current file
    @Published private(set) var custom: [String] = []
    @Published private(set) var pendingDelete: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var message: String?
    @Published private(set) var lastTrash: LastTrash?
    @Published private(set) var speedStatus: SpeedStatus = .off
    @Published private(set) var rate: Double = 1
    @Published var showSpeedSetup = false

    var palette: [String] { Rules.builtins + custom }
    var fileName: String? { currentPath.map { ($0 as NSString).lastPathComponent } }
    var pendingIsCurrent: Bool { pendingDelete != nil && pendingDelete == currentPath }

    private let vlc = VLCBridge()
    private var store = PaletteStore()
    private var timer: Timer?
    private var lastProgress: Double = 0
    private var messageTask: Task<Void, Never>?
    private var web: VLCWebSettings?
    private var rateInFlight = false

    init() {
        custom = store.load()
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
        if store.changedOnDisk() { custom = store.load(); refreshTags() }

        switch vlc.snapshot() {
        case .failure(.notRunning):
            // Quitting VLC with a pending delete leaves the file, same as the Lua extension.
            connection = .vlcNotRunning
            setCurrent(nil)
            playing = false
            progress = 0
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
        // A different file started: flush the pending delete (skip).
        if let pending = pendingDelete, let next = now.path, next != pending {
            flushPendingDelete()
        }
        // The playlist ran out right after the marked file reached its end.
        if let pending = pendingDelete, now.path == nil, pending == currentPath, lastProgress >= Rules.nearEnd {
            flushPendingDelete()
        }

        connection = now.path != nil ? .playing : (now.isStream ? .stream : .nothingPlaying)
        setCurrent(now.path)
        playing = now.playing
        progress = now.progress
        if now.path != nil { lastProgress = now.progress }
        refreshTags()
    }

    private func setCurrent(_ path: String?) {
        guard path != currentPath else { return }
        currentPath = path
        lastProgress = 0
        refreshTags()
    }

    private func refreshTags() {
        guard let path = currentPath else { tags = []; return }
        let onFile = FinderTags.read(path)
        let next = palette.filter { onFile.containsIgnoringCase($0) }
        if next != tags { tags = next }
    }

    // MARK: Playback remote

    func playPause() { send(.playPause) }
    func nextVideo() { send(.next) }
    func previousVideo() { send(.previous) }
    func jumpBack() { send(.jump(seconds: -Rules.jumpSeconds)) }
    func jumpForward() { send(.jump(seconds: Rules.jumpSeconds)) }

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
        Task { @MainActor [weak self] in
            let result = await VLCWeb.rate(web, set: newRate)
            self?.handleRate(result)
        }
    }

    private func refreshRate() {
        guard let web, !rateInFlight, speedStatus != .settingUp else { return }
        rateInFlight = true
        Task { @MainActor [weak self] in
            let result = await VLCWeb.rate(web)
            self?.rateInFlight = false
            self?.handleRate(result)
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
            pendingDelete = path
            flash("Will move to Trash when this video ends or you skip")
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
        refreshTags()
        flash("Removed \(name) from the palette")
    }

    func undoLastTrash() {
        guard let last = lastTrash else { return }
        do {
            try FileManager.default.moveItem(at: last.trashedURL, to: URL(fileURLWithPath: last.originalPath))
            lastTrash = nil
            flash("Restored \((last.originalPath as NSString).lastPathComponent)")
        } catch {
            flash("Could not restore: \(error.localizedDescription)")
        }
    }

    // MARK: Internals

    private func flushPendingDelete() {
        guard let path = pendingDelete else { return }
        pendingDelete = nil
        try? FinderTags.clear(path, palette: palette)
        do {
            if let trashed = try FinderTags.trash(path) {
                let entry = LastTrash(originalPath: path, trashedURL: trashed, at: Date())
                lastTrash = entry
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Rules.undoWindow))
                    if self?.lastTrash?.at == entry.at { self?.lastTrash = nil }
                }
            }
            flash("Moved \((path as NSString).lastPathComponent) to Trash")
        } catch {
            flash("Could not move to Trash: \(error.localizedDescription)")
        }
    }

    private func requireFile() -> String? {
        if let path = currentPath { return path }
        switch connection {
        case .stream: flash("Tags apply to local files only")
        case .vlcNotRunning: flash("VLC is not running")
        default: flash("No video playing")
        }
        return nil
    }

    private func persistPalette() {
        do { try store.save(custom) } catch { flash("Could not save palette: \(error.localizedDescription)") }
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
                tagGrid
                deleteButton
                addRow
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial)
        .animation(.snappy(duration: 0.18), value: model.showSpeedSetup)
        .animation(.snappy(duration: 0.18), value: model.tags)
        .animation(.snappy(duration: 0.18), value: model.pendingDelete)
    }

    // Playback remote

    private var transportBar: some View {
        HStack(spacing: 2) {
            TransportButton(symbol: "backward.end.fill", help: "Previous video  ⌃⌥←") { model.previousVideo() }
            TransportButton(symbol: "gobackward.5", help: "Back \(Rules.jumpSeconds) seconds") { model.jumpBack() }
            TransportButton(
                symbol: model.playing ? "pause.fill" : "play.fill",
                help: "Play / Pause  ⌃⌥Space",
                prominent: true
            ) { model.playPause() }
            TransportButton(symbol: "goforward.5", help: "Forward \(Rules.jumpSeconds) seconds") { model.jumpForward() }
            TransportButton(symbol: "forward.end.fill", help: "Next video  ⌃⌥→") { model.nextVideo() }
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

            Button { ready ? model.normalSpeed() : model.faster() } label: {
                Text(speedLabel)
                    .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(ready ? Color.primary : Color.secondary)
                    .frame(minWidth: 44)
                    .contentShape(Rectangle())
            }
            .help(ready ? "Back to normal speed  ⌃⌥0" : "Set up speed control")

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
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(model.pendingIsCurrent ? .red : .accentColor)
                    .controlSize(.mini)
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

    // Tags

    private var tagGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Array(model.palette.enumerated()), id: \.element) { index, name in
                TagChip(
                    name: name,
                    hotkey: index < HotKeys.digitKeys.count ? "\(HotKeys.modifierGlyphs)\(index + 1)" : nil,
                    isOn: model.tags.containsIgnoringCase(name),
                    enabled: model.currentPath != nil
                ) {
                    model.toggle(name)
                }
                .contextMenu {
                    if !Rules.isBuiltin(name) {
                        Button("Remove “\(name)” from palette", role: .destructive) { model.remove(name) }
                    }
                }
            }
        }
    }

    private var deleteButton: some View {
        Button {
            model.toggleDelete()
        } label: {
            HStack {
                Image(systemName: model.pendingIsCurrent ? "trash.fill" : "trash")
                Text(model.pendingIsCurrent ? "Trash when it ends · click to cancel" : "Delete")
                Spacer()
                Text("\(HotKeys.modifierGlyphs)⌫").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(model.pendingIsCurrent ? Color.red.opacity(0.22) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(model.pendingIsCurrent ? Color.red.opacity(0.7) : Color.primary.opacity(0.1))
            )
            .foregroundStyle(model.pendingIsCurrent ? Color.red : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.currentPath == nil)
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
            .help("Add to the palette and tag the current video")
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
            if model.lastTrash != nil {
                Button("Undo") { model.undoLastTrash() }
                    .controlSize(.small)
            }
        }
    }

    private var footerText: String {
        if let message = model.message { return message }
        if case .failed(let detail) = model.connection { return detail }
        if model.pendingIsCurrent { return "Will move to Trash when this video ends or you skip" }
        if model.currentPath == nil { return "Right-click a custom tag to remove it" }
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

struct TagChip: View {
    let name: String
    let hotkey: String?
    let isOn: Bool
    let enabled: Bool
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
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
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

    private func positionTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 24, y: screen.maxY - frame.height - 24))
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: PanelModel!
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = PanelModel()
        panel = FloatingPanel(rootView: PanelView(model: model))
        installStatusItem()
        installHotKeys()
        model.start()
        panel.orderFrontRegardless()
        enableLoginItemOnFirstInstalledLaunch()
    }

    // MARK: Open at Login (SMAppService, macOS 13+)

    private var isInstalled: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// The first launch from an Applications folder turns on Open at Login once.
    /// After that the menu toggle is the only thing that changes it.
    private func enableLoginItemOnFirstInstalledLaunch() {
        let key = "didSetUpLoginItem"
        guard isInstalled, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Video Tags Panel: login item change failed: \(error.localizedDescription)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeys.shared.unregisterAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
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
            xf.translateX(by: 9, yBy: 9)
            xf.rotate(byDegrees: -18)
            xf.scale(by: 0.9)
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
            NSBezierPath(ovalIn: NSRect(x: 4.4, y: 7.8, width: 2.4, height: 2.4)).fill()
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
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "\(HotKeys.modifierGlyphs)1–9 tags · ⌫ Delete · Space play · ←→ video · ↑↓ speed", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Quit Video Tags Panel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
}

@main
enum VideoTagsPanelApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()   // NSApplication.delegate is weak; run() keeps this frame alive
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon; lives in the menu bar
        app.run()
    }
}
