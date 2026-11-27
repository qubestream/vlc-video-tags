// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// The Help window (Help → Video Tags Panel Help, ⌘?): searchable topics from
// HelpContent.swift, and the Help menu's search field, which lists matching
// topics under Help Topics.

import AppKit
import SwiftUI

@MainActor
final class HelpState: ObservableObject {
    @Published var selection: String? = HelpContent.topics.first?.id
    @Published var query = ""
}

@MainActor
final class HelpWindowController: NSWindowController {
    private let state = HelpState()

    init() {
        let host = NSHostingController(rootView: HelpView(state: state))
        let window = NSWindow(contentViewController: host)
        window.title = "Video Tags Panel Help"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("VideoTagsHelp")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Opens Help at a topic, or with a search filled in.
    func show(topic: String? = nil, search: String? = nil) {
        if let search {
            state.query = search
            state.selection = HelpContent.search(search).first?.id ?? state.selection
        } else if let topic, HelpContent.topic(topic) != nil {
            state.query = ""
            state.selection = topic
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @ObservedObject var state: HelpState

    private var results: [HelpContent.Topic] { HelpContent.search(state.query) }

    var body: some View {
        NavigationSplitView {
            List(results, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: state.query)
                }
            }
        } detail: {
            if let id = state.selection, let topic = HelpContent.topic(id) {
                HelpTopicView(topic: topic) { state.selection = $0; state.query = "" }
                    .id(topic.id)
            } else {
                ContentUnavailableView("Choose a topic", systemImage: "questionmark.circle")
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) { _, _ in
            // Keep a topic open that still matches; otherwise show the best match.
            if let first = results.first, !results.contains(where: { $0.id == state.selection }) {
                state.selection = first.id
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

struct HelpTopicView: View {
    let topic: HelpContent.Topic
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.title.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    paragraph(row)
                }
                if topic.id == "shortcuts" {
                    ShortcutList().padding(.top, 6)
                }
                related
            }
            .textSelection(.enabled)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(topic.title)
    }

    private struct Row { let kind: HelpContent.Kind; let text: String; let number: Int }

    /// Paragraphs with numbered steps counted 1, 2, 3 within each run.
    private var rows: [Row] {
        var out: [Row] = []
        var step = 0
        for p in topic.paragraphs {
            let (kind, text) = HelpContent.kind(of: p)
            step = kind == .step ? step + 1 : 0
            out.append(Row(kind: kind, text: text, number: step))
        }
        return out
    }

    @ViewBuilder
    private func paragraph(_ row: Row) -> some View {
        let text = Text(Self.markdown(row.text)).fixedSize(horizontal: false, vertical: true)
        switch row.kind {
        case .text:
            text
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                text
            }
            .padding(.leading, 6)
        case .step:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(row.number).").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                text
            }
            .padding(.leading, 2)
        }
    }

    /// Other topics this one mentions by name, as links at the bottom.
    @ViewBuilder
    private var related: some View {
        let others = HelpContent.topics.filter { other in
            other.id != topic.id && topic.keywords.contains { other.id == $0 || other.title.localizedCaseInsensitiveContains($0) && $0.count > 4 }
        }
        if !others.isEmpty {
            Divider().padding(.top, 8)
            HStack(spacing: 14) {
                Text("See also").foregroundStyle(.secondary)
                ForEach(others) { other in
                    Button(other.title) { open(other.id) }.buttonStyle(.link)
                }
            }
            .font(.callout)
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Every global shortcut, with a warning on any another app already holds.
struct ShortcutList: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            ForEach(HelpContent.shortcuts, id: \.hotKeyID) { s in
                GridRow {
                    Text(HelpContent.modifierGlyphs + s.keys)
                        .font(.body.monospaced())
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.action)
                        if HotKeys.shared.isTaken(s.hotKeyID) {
                            Label("Another app already uses this shortcut, so it does nothing here.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }
}

/// Feeds the search field at the top of the Help menu. macOS calls the search
/// on a background thread; the topics are constants, so that is safe.
final class HelpMenuSearch: NSObject, NSUserInterfaceItemSearching {
    private let open: @MainActor (_ topic: String?, _ search: String?) -> Void

    init(open: @escaping @MainActor (_ topic: String?, _ search: String?) -> Void) {
        self.open = open
    }

    func searchForItems(withSearch searchString: String, resultLimit: Int,
                        matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void) {
        let query = searchString.trimmingCharacters(in: .whitespaces)
        handleMatchedItems(query.isEmpty ? [] : HelpContent.search(query).prefix(resultLimit).map(\.id))
    }

    func localizedTitles(forItem item: Any) -> [String] {
        [(item as? String).flatMap(HelpContent.topic)?.title ?? ""]
    }

    func performAction(forItem item: Any) {
        let id = item as? String
        MainActor.assumeIsolated { open(id, nil) }
    }

    func showAllHelpTopics(forSearch searchString: String) {
        MainActor.assumeIsolated { open(nil, searchString) }
    }
}
