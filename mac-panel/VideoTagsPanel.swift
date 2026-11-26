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
//     - floats over full-screen VLC and follows you across Spaces
//     - Undo for the last Trash
//     - starts on its own; no "VLC → Extensions" step every launch
//
// Build: ./build.sh (swiftc from Xcode or the Command Line Tools). macOS 14+.

import AppKit
import Carbon.HIToolbox
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

    var palette: [String] { Rules.builtins + custom }
    var fileName: String? { currentPath.map { ($0 as NSString).lastPathComponent } }
    var pendingIsCurrent: Bool { pendingDelete != nil && pendingDelete == currentPath }

    private let vlc = VLCBridge()
    private var store = PaletteStore()
    private var timer: Timer?
    private var lastProgress: Double = 0
    private var messageTask: Task<Void, Never>?

    init() {
        custom = store.load()
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
        case .failure(.notAuthorized):
            connection = .needsPermission
        case .failure(.script(let code, let text)):
            connection = .failed("\(text) (\(code))")
        case .success(let now):
            apply(now)
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
        .frame(width: 330)
        .background(.regularMaterial)
        .animation(.snappy(duration: 0.18), value: model.tags)
        .animation(.snappy(duration: 0.18), value: model.pendingDelete)
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
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 260),
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
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tag", accessibilityDescription: "Video Tags")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide Panel", action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "\(HotKeys.modifierGlyphs)1–9 toggle tags · \(HotKeys.modifierGlyphs)⌫ Delete", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
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
