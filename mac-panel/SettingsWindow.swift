// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// Settings (Video Tags Panel → Settings…, ⌘,): General, Profiles & Backups,
// Shortcuts and VLC, in the standard toolbar-tab window.

import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, profiles, shortcuts, vlc

    var label: String {
        switch self {
        case .general: return "General"
        case .profiles: return "Profiles"
        case .shortcuts: return "Shortcuts"
        case .vlc: return "VLC"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .profiles: return "person.2.crop.square.stack"
        case .shortcuts: return "keyboard"
        case .vlc: return "play.rectangle"
        }
    }

    /// Each tab has a fixed size; the window resizes to it, keeping its top edge.
    var size: NSSize {
        switch self {
        case .general: return NSSize(width: 560, height: 390)
        case .profiles: return NSSize(width: 620, height: 640)
        case .shortcuts: return NSSize(width: 560, height: 560)
        case .vlc: return NSSize(width: 560, height: 470)
        }
    }
}

/// What Settings asks the app to do.
struct SettingsActions {
    var setMenuBarIconVisible: @MainActor (Bool) -> Void
    var resetPanelPosition: @MainActor () -> Void
    var openHelp: @MainActor (String) -> Void
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabs = SettingsTabs()

    init(model: PanelModel, actions: SettingsActions) {
        for tab in SettingsTab.allCases {
            let root: AnyView
            switch tab {
            case .general: root = AnyView(GeneralSettings(actions: actions))
            case .profiles: root = AnyView(ProfileSettings(model: model, actions: actions))
            case .shortcuts: root = AnyView(ShortcutSettings(model: model, actions: actions))
            case .vlc: root = AnyView(VLCSettings(model: model, actions: actions))
            }
            let host = NSHostingController(rootView: root.frame(width: tab.size.width, height: tab.size.height))
            host.sizingOptions = []
            host.preferredContentSize = tab.size
            let item = NSTabViewItem(viewController: host)
            item.label = tab.label
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            tabs.addTabViewItem(item)
        }
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsTab.general.size)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ tab: SettingsTab? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        tabs.fitWindow(animate: false)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow(animate: true)
    }

    func fitWindow(animate: Bool) {
        guard let window = view.window, let tab = SettingsTab(rawValue: selectedTabViewItemIndex) else { return }
        let content = NSRect(origin: .zero, size: tab.size)
        var frame = window.frameRect(forContentRect: content)
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height   // keep the top edge where it is
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let actions: SettingsActions
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Video Tags Panel at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLogin))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("macOS needs you to allow it in Login Items.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).foregroundStyle(.red).font(.callout)
                }
                Toggle("Show icon in the menu bar", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, on in actions.setMenuBarIconVisible(on) }
            } footer: {
                if !showMenuBarIcon {
                    Text("Click Video Tags Panel in the Dock to bring the panel back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Panel") {
                LabeledContent("Lost the panel off screen?") {
                    Button("Move to Top Right") { actions.resetPanelPosition() }
                }
            }

            Section {
                LabeledContent("Your profiles, backups and tag list") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.profiles])
                    }
                }
            } header: {
                Text("Data")
            } footer: {
                Text("They live in VLC's own folder, so the Lua extension uses the same tags. Your tags and comments are on the video files themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private func setLogin(_ on: Bool) {
        UserDefaults.standard.set(true, forKey: "loginItemIsOptIn")
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Couldn't change it: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}

// MARK: - Profiles and backups

private struct BackupRow: Identifiable {
    let entry: ProfileBackup.Entry
    let contents: String
    var id: URL { entry.url }

    var kind: String {
        switch entry.reason {
        case nil: return "Automatic"
        case "manual": return "Back Up Now"
        case let reason?: return reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }
}

private struct ProfileSettings: View {
    @ObservedObject var model: PanelModel
    let actions: SettingsActions
    @State private var selectedProfile: String?
    @State private var backups: [BackupRow] = []
    @State private var selectedBackup: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            profilesBox
            backupsBox
            Text(model.message ?? " ")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(20)
        .onAppear {
            if selectedProfile == nil { selectedProfile = model.activeProfile }
            reload()
        }
        .onChange(of: model.profiles) { _, _ in reload() }
    }

    private var profilesBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                profileTable
                profileButtons
            }
            .padding(4)
        } label: {
            Text("Profiles").font(.headline)
        }
    }

    private var profileTable: some View {
        Table(model.profiles, selection: $selectedProfile) {
            TableColumn("Profile") { (p: TagProfile) in
                Text(p.name).fontWeight(p.name == model.activeProfile ? .semibold : .regular)
            }
            TableColumn("Tags") { (p: TagProfile) in
                Text("\(p.tags.count)").monospacedDigit()
            }
            .width(50)
            TableColumn("Active") { (p: TagProfile) in
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(p.name == model.activeProfile ? 1 : 0)
            }
            .width(50)
        }
        .frame(height: 150)
        .contextMenu(forSelectionType: String.self) { _ in EmptyView() } primaryAction: { names in
            if let name = names.first { model.switchProfile(to: name) }
        }
    }

    private var profileButtons: some View {
        HStack(spacing: 6) {
            Button { newProfile() } label: { Image(systemName: "plus") }
                .help("New profile")
            Button { deleteProfile() } label: { Image(systemName: "minus") }
                .help("Delete profile")
                .disabled(selected == nil || model.profiles.count < 2)
            Button("Rename…") { renameProfile() }.disabled(selected == nil)
            Button("Make Active") { if let s = selected { model.switchProfile(to: s.name) } }
                .disabled(selected == nil || selected?.name == model.activeProfile)
            Spacer()
            Text("Double-click a profile to use it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backupsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Back Up Now") { backUpNow() }
                    Button("Export…") { ProfileTransfer.export(model); reload() }
                    Button("Import…") { ProfileTransfer.importFile(model); reload() }
                    Spacer()
                    Button("Help") { actions.openHelp("backup") }
                }
                backupTable
                HStack {
                    Button("Restore…") { if let url = selectedBackup { restore(url) } }
                        .disabled(selectedBackup == nil)
                    Button("Show in Finder") { showBackup() }
                    Spacer()
                }
                Text(retentionNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        } label: {
            Text("Backups").font(.headline)
        }
    }

    private var backupTable: some View {
        Table(backups, selection: $selectedBackup) {
            TableColumn("Date") { (b: BackupRow) in
                Text(b.entry.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
            }
            .width(min: 130, ideal: 150)
            TableColumn("Kind") { (b: BackupRow) in Text(b.kind) }
                .width(min: 80, ideal: 100)
            TableColumn("Contents") { (b: BackupRow) in Text(b.contents).help(b.contents) }
        }
        .frame(minHeight: 170)
        .contextMenu(forSelectionType: URL.self) { _ in EmptyView() } primaryAction: { urls in
            if let url = urls.first { restore(url) }
        }
    }

    private var retentionNote: String {
        "Video Tags backs up your profiles before every change (at most every 10 minutes while you edit), and when it opens and quits. "
            + "It keeps the newest \(ProfileBackup.keepRecent) plus one a day for \(ProfileBackup.keepDaily) days. "
            + "For a copy that survives this Mac, use Export and keep the file on another drive."
    }

    private func showBackup() {
        if let url = selectedBackup ?? backups.first?.entry.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(Paths.backups)
        }
    }

    private var selected: TagProfile? { model.profiles.first { $0.name == selectedProfile } }

    private func reload() {
        backups = ProfileBackup.list(in: Paths.backups).map { entry in
            let line = (try? Data(contentsOf: entry.url)).flatMap(ProfileBackup.summary(of:))?.line ?? "Unreadable"
            return BackupRow(entry: entry, contents: line)
        }
        if let s = selectedBackup, !backups.contains(where: { $0.id == s }) { selectedBackup = nil }
    }

    private func backUpNow() {
        let previous = ProfileBackup.list(in: Paths.backups).first
        do {
            guard let url = try ProfileBackup.save(model.profilesData(), in: Paths.backups, reason: "manual") else { return }
            if let previous, url == previous.url {
                model.flash("Nothing changed since the backup from \(previous.date.formatted(date: .abbreviated, time: .shortened)), so that one is still current.")
            } else {
                model.flash("Backed up to \(url.lastPathComponent)")
            }
            reload()
            selectedBackup = url
        } catch {
            model.flash("Could not back up: \(error.localizedDescription)")
        }
    }

    private func restore(_ url: URL) {
        ProfileTransfer.apply(url, to: model, restoring: true)
        reload()
    }

    private func newProfile() {
        guard let name = NamePrompt.ask(title: "New Profile",
                                        message: "A profile is its own set of tags. Green and Red are in every profile.",
                                        confirm: "Create") else { return }
        if model.createProfile(name) { selectedProfile = model.activeProfile }
    }

    private func renameProfile() {
        guard let old = selected?.name,
              let name = NamePrompt.ask(title: "Rename Profile", message: "", initial: old, confirm: "Rename") else { return }
        if model.renameProfile(old, to: name) {
            selectedProfile = model.profiles.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }?.name
        }
    }

    private func deleteProfile() {
        guard let name = selected?.name,
              NamePrompt.confirm(title: "Delete the \(name) profile?",
                                 message: "Its tag buttons go away. Files you already tagged keep their tags. A backup is kept, so you can restore it.",
                                 button: "Delete") else { return }
        model.deleteProfile(name)
        selectedProfile = model.activeProfile
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject var model: PanelModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                ShortcutList()
                    .padding(.vertical, 4)
            } header: {
                Text("Work from any app, VLC included")
            } footer: {
                Text("These shortcuts are fixed. If another app already uses one, quit that app or change its shortcut, then reopen Video Tags Panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("\(HotKeys.modifierGlyphs)1–9 in the \(model.activeProfile) profile") {
                let keys = Array(model.palette.prefix(9).enumerated())
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    ForEach(keys, id: \.offset) { i, tag in
                        GridRow {
                            Text("\(HotKeys.modifierGlyphs)\(i + 1)").font(.body.monospaced())
                            Text(tag)
                        }
                    }
                }
                if model.palette.count > 9 {
                    Text("Tags after the ninth have no shortcut. Drag the ones you use most to the front of the panel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - VLC

/// Installs the Lua extension that ships inside the app.
enum LuaExtension {
    static var folder: URL { Paths.support.appendingPathComponent("lua/extensions", isDirectory: true) }
    static var installed: URL { folder.appendingPathComponent("video_tags.lua") }
    static var helperInstalled: URL { Paths.support.appendingPathComponent("video-tags-finder_ops.applescript") }

    static var bundled: URL? { Bundle.main.url(forResource: "video_tags", withExtension: "lua") }
    static var bundledHelper: URL? { Bundle.main.url(forResource: "finder_ops", withExtension: "applescript") }

    enum State { case notInstalled, upToDate, outOfDate, unavailable }

    static var state: State {
        guard let bundled, let ours = try? Data(contentsOf: bundled) else { return .unavailable }
        guard let theirs = try? Data(contentsOf: installed) else { return .notInstalled }
        let helperOK = bundledHelper.flatMap { try? Data(contentsOf: $0) } == (try? Data(contentsOf: helperInstalled))
        return ours == theirs && helperOK ? .upToDate : .outOfDate
    }

    /// Copies the extension and its Finder helper into VLC's folder,
    /// replacing an older copy of the same two files only.
    static func install() throws {
        guard let bundled, let bundledHelper else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contentsOf: bundled).write(to: installed, options: .atomic)
        try Data(contentsOf: bundledHelper).write(to: helperInstalled, options: .atomic)
    }
}

private struct VLCSettings: View {
    @ObservedObject var model: PanelModel
    let actions: SettingsActions
    @State private var lua = LuaExtension.state
    @State private var luaMessage: String?
    @State private var web = VLCPrefs.current()

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("VLC") { Text(connection) }
                LabeledContent("Automation permission") {
                    Button("Open Privacy Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Speed and the web remote") {
                    switch model.speedStatus {
                    case .off:
                        Button("Set Up…") { model.setUpSpeed() }
                    case .settingUp:
                        Text("Setting up…").foregroundStyle(.secondary)
                    case .connecting:
                        Text("Waiting for VLC…").foregroundStyle(.secondary)
                    case .ready:
                        Text("On, port \(web?.port ?? VLCPrefs.defaultPort)").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Set Up quits VLC, turns on its web interface for this Mac only (127.0.0.1) and reopens it. Your VLC settings are backed up first.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Video Tags extension") {
                    HStack {
                        Text(luaText).foregroundStyle(.secondary)
                        switch lua {
                        case .notInstalled: Button("Install") { installLua() }
                        case .outOfDate: Button("Update") { installLua() }
                        case .upToDate:
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LuaExtension.installed]) }
                        case .unavailable: EmptyView()
                        }
                    }
                }
                if let luaMessage {
                    Text(luaMessage).font(.callout)
                }
            } header: {
                Text("Lua extension")
            } footer: {
                Text("Optional. It adds the same tag buttons inside VLC (VLC → Extensions → Video Tags), using the same tags as this panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { lua = LuaExtension.state; web = VLCPrefs.current() }
        .onChange(of: model.speedStatus) { _, _ in web = VLCPrefs.current() }
    }

    private var connection: String {
        switch model.connection {
        case .vlcNotRunning: return "Not running"
        case .nothingPlaying: return "Running, nothing playing"
        case .stream: return "Playing a stream (only local files can be tagged)"
        case .playing: return model.currentPath.map { "Playing \(($0 as NSString).lastPathComponent)" } ?? "Playing"
        case .needsPermission: return "Needs Automation permission"
        case .failed(let why): return "Can't reach VLC: \(why)"
        }
    }

    private var luaText: String {
        switch lua {
        case .notInstalled: return "Not installed"
        case .upToDate: return "Installed"
        case .outOfDate: return "Older version installed"
        case .unavailable: return "Not included in this build"
        }
    }

    private func installLua() {
        do {
            try LuaExtension.install()
            lua = LuaExtension.state
            luaMessage = VLCBridge.isRunning
                ? "Installed. Quit VLC with ⌘Q and open it again, then choose VLC → Extensions → Video Tags."
                : "Installed. Open VLC and choose VLC → Extensions → Video Tags."
        } catch {
            luaMessage = "Couldn't install it: \(error.localizedDescription)"
        }
    }
}
