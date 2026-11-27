// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// Test driver for mac-panel/HelpContent.swift, run by tests/test_help_content.sh.
import Foundation

var fails = 0
func check<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS: \(label)") } else { print("FAIL: \(label) (got \(got), want \(want))"); fails += 1 }
}

let topics = HelpContent.topics
check(Set(topics.map(\.id)).count, topics.count, "topic ids are unique")
check(Set(topics.map(\.title)).count, topics.count, "topic titles are unique")
check(topics.allSatisfy { !$0.paragraphs.isEmpty && !$0.symbol.isEmpty }, true, "every topic has text and a symbol")
check(topics.flatMap(\.paragraphs).allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, true, "no empty paragraphs")

// Every paragraph is valid Markdown
var bad: [String] = []
for t in topics {
    for p in t.paragraphs {
        let (_, text) = HelpContent.kind(of: p)
        if (try? AttributedString(markdown: text)) == nil { bad.append("\(t.id): \(p.prefix(40))") }
    }
}
check(bad, [], "every paragraph parses as Markdown")

// Bullets and steps
check(HelpContent.kind(of: "- **Export…** saves").0, .bullet, "a dash makes a bullet")
check(HelpContent.kind(of: "- **Export…** saves").1, "**Export…** saves", "bullet text loses the dash")
check(HelpContent.kind(of: "1. Open VLC").0, .step, "1. makes a step")
check(HelpContent.kind(of: "Plain").0, .text, "plain text")

// Search
check(HelpContent.search("").count, topics.count, "empty search lists everything")
check(HelpContent.search("backup").first?.id, "backup", "backup finds the backups topic first")
check(HelpContent.search("restore").first?.id, "backup", "restore finds backups")
check(HelpContent.search("Trash").first?.id, "delete", "trash finds delete")
check(HelpContent.search("speed").first?.id, "playback", "speed finds playback")
check(HelpContent.search("shortcuts").first?.id, "shortcuts", "shortcuts finds shortcuts")
check(HelpContent.search("rename profile").map(\.id).contains("profiles"), true, "two words both have to match")
check(HelpContent.search("zzzqqq").isEmpty, true, "nonsense finds nothing")
check(HelpContent.search("PERMISSION").first?.id, "permissions", "search ignores case")

// Shortcuts
let ids = HelpContent.shortcuts.map(\.hotKeyID)
check(Set(ids).count, ids.count, "shortcut ids are unique")
check(Set(ids), Set([1, 100, 101, 102, 103, 104, 105, 106, 107, 108] as [UInt32]), "every registered hotkey is listed")
check(HelpContent.topic("shortcuts") != nil, true, "topic lookup")
check(HelpContent.topic("nope") == nil, true, "unknown topic is nil")

if fails > 0 { print("\(fails) failed"); exit(1) }
print("All passed")
