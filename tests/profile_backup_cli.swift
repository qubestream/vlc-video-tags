// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// Test driver for mac-panel/ProfileBackup.swift, run by
// tests/test_profile_backup.sh. Argument 1: a scratch folder.
import Foundation

var fails = 0
func check<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS: \(label)") } else { print("FAIL: \(label) (got \(got), want \(want))"); fails += 1 }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var caseNo = 0
func fresh() -> URL {
    caseNo += 1
    let dir = root.appendingPathComponent("case\(caseNo)/\(ProfileBackup.folderName)")
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
func json(_ active: String, _ profiles: [(String, [String], [String: String]?)]) -> Data {
    var list: [[String: Any]] = []
    for (name, tags, moves) in profiles {
        var p: [String: Any] = ["name": name, "tags": tags]
        if let moves { p["moves"] = moves }
        list.append(p)
    }
    return try! JSONSerialization.data(withJSONObject: ["active": active, "profiles": list], options: [.sortedKeys])
}
func names(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

let cal = Calendar(identifier: .gregorian)
let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 14, minute: 5, second: 33))!
let sample = json("Personal", [("Personal", ["Funny", "Keep", "Later"], ["Keep": "/Users/x/Movies/Keep"]),
                               ("Work", ["Client", "Draft"], nil)])

// Names
check(ProfileBackup.fileName(base), "Profiles 2026-11-27 14.05.33.json", "file name has a sortable stamp")
check(ProfileBackup.fileName(base, reason: "before import"), "Profiles 2026-11-27 14.05.33 before import.json", "reason goes after the stamp")
check(ProfileBackup.parse("Profiles 2026-11-27 14.05.33.json")?.date, base, "stamp parses back")
check(ProfileBackup.parse("Profiles 2026-11-27 14.05.33 before restore.json")?.reason, "before restore", "reason parses back")
check(ProfileBackup.parse("notes.txt") == nil, true, "other files are ignored")
check(ProfileBackup.parse("Profiles garbage.json") == nil, true, "a bad stamp is ignored")
check(ProfileBackup.exportName(base), "Video Tags Profiles 2026-11-27.json", "export name")

// A backup is the exact bytes
do {
    let dir = fresh()
    let url = try! ProfileBackup.save(sample, in: dir, now: base)
    check(url?.lastPathComponent, "Profiles 2026-11-27 14.05.33.json", "first backup written")
    check(try? Data(contentsOf: url!), sample, "backup is a byte-for-byte copy")
}

// Identical content is not saved twice
do {
    let dir = fresh()
    let first = try! ProfileBackup.save(sample, in: dir, now: base)
    let again = try! ProfileBackup.save(sample, in: dir, now: base + 3600)
    check(again, first, "same content returns the existing backup")
    check(names(dir).count, 1, "same content: still one file")
}

// Throttle for automatic backups, but a reasoned one always lands
do {
    let dir = fresh()
    _ = try! ProfileBackup.save(sample, in: dir, now: base)
    let other = json("Personal", [("Personal", ["Funny"], nil)])
    let skipped = try! ProfileBackup.save(other, in: dir, now: base + 60, minInterval: ProfileBackup.autoInterval)
    check(skipped == nil, true, "automatic backup inside 10 minutes is skipped")
    let later = try! ProfileBackup.save(other, in: dir, now: base + 11 * 60, minInterval: ProfileBackup.autoInterval)
    check(later != nil, true, "automatic backup after 10 minutes lands")
    let safety = try! ProfileBackup.save(sample, in: dir, reason: "before import", now: base + 11 * 60 + 5)
    check(safety?.lastPathComponent.hasSuffix("before import.json"), true, "safety backup ignores the throttle")
    check(names(dir).count, 3, "three backups")
}

// Same second: never overwrites
do {
    let dir = fresh()
    let a = try! ProfileBackup.save(json("A", [("A", [], nil)]), in: dir, now: base)
    let b = try! ProfileBackup.save(json("B", [("B", [], nil)]), in: dir, now: base)
    check(a != b, true, "two backups in one second get two names")
    check(names(dir).count, 2, "same second: both kept")
    check(ProfileBackup.list(in: dir).first?.url, b, "newest first")
}

// Pruning: 30 newest plus one per day for 30 more days
do {
    let dir = fresh()
    // 50 backups an hour apart today-ish, then one every 6 hours for 60 days before.
    var made = 0
    for i in 0..<50 {
        _ = try! ProfileBackup.save(json("P", [("P", ["t\(made)"], nil)]), in: dir, now: base - Double(i) * 3600)
        made += 1
    }
    let start = base - 50 * 3600
    for i in 0..<(60 * 4) {
        _ = try! ProfileBackup.save(json("P", [("P", ["t\(made)"], nil)]), in: dir, now: start - Double(i) * 6 * 3600)
        made += 1
    }
    // save() prunes as it goes; prune once more with a fixed calendar.
    ProfileBackup.prune(in: dir, calendar: cal)
    let left = ProfileBackup.list(in: dir)
    let recent = left.prefix(30)
    check(recent.first?.date, base, "the newest backup is kept")
    let olderDays = Set(left.dropFirst(30).map { cal.startOfDay(for: $0.date) })
    check(left.count - 30, olderDays.count, "older backups: one per day")
    check(olderDays.count, 30, "older backups: 30 days kept")
    check(left.count, 60, "60 backups in all")
    check(names(dir).count, 60, "pruned files are gone from disk")
}

// Pruning ignores files that are not backups
do {
    let dir = fresh()
    try! "keep me".write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    for i in 0..<35 { _ = try! ProfileBackup.save(json("P", [("P", ["t\(i)"], nil)]), in: dir, now: base + Double(i)) }
    check(fm.fileExists(atPath: dir.appendingPathComponent("README.txt").path), true, "other files survive pruning")
}

// Summary
do {
    let s = ProfileBackup.summary(of: sample)
    check(s?.profiles.count, 2, "summary: two profiles")
    check(s?.tagCount, 5, "summary: five tags")
    check(s?.line, "2 profiles, 5 tags: Personal (3), Work (2)", "summary line")
    check(s?.profiles.first?.moves["Keep"], "/Users/x/Movies/Keep", "summary keeps move folders")
    check(s?.profiles.first?.tags, ["Funny", "Keep", "Later"], "summary keeps tag order")
    check(ProfileBackup.summary(of: Data("not json".utf8)) == nil, true, "junk is not a profiles file")
    check(ProfileBackup.summary(of: json("X", [])) == nil, true, "no profiles is not a backup")
    check(ProfileBackup.summary(of: Data(#"{"active":"A","profiles":[{"name":"A"}]}"#.utf8)) == nil, true, "a profile without tags is rejected")
}

// Diff
do {
    let now = ProfileBackup.summary(of: sample)!
    let backup = ProfileBackup.summary(of: json("Personal", [
        ("personal", ["Keep", "Funny", "Later"], ["Keep": "/Users/x/Movies/Keep"]),   // order changed
        ("Archive", ["Old"], nil),
    ]))!
    let d = ProfileBackup.diff(from: now, to: backup)
    check(d.changed, ["personal"], "diff: reordered tags count as changed")
    check(d.added, ["Archive"], "diff: new profile")
    check(d.removed, ["Work"], "diff: missing profile")
    check(d.lines, ["Removed: Work", "Changed: personal", "Added: Archive"], "diff lines")
    let movesOnly = ProfileBackup.summary(of: json("Personal", [("Personal", ["Funny", "Keep", "Later"], nil), ("Work", ["Client", "Draft"], nil)]))!
    check(ProfileBackup.diff(from: now, to: movesOnly).changed, ["Personal"], "diff: a move folder change counts")
    let same = ProfileBackup.diff(from: now, to: now)
    check(same.isEmpty, true, "diff: identical is empty")
    check(same.lines, ["Same as your profiles now."], "diff: identical line")
}

if fails > 0 { print("\(fails) failed"); exit(1) }
print("All passed")
