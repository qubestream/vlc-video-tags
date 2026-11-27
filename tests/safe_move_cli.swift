// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// Test driver for mac-panel/SafeMove.swift, run by tests/test_safe_move.sh.
// Argument 1: a scratch folder. Argument 2 (optional): a folder on another
// volume, for the cross-volume case.
import Foundation

var fails = 0
func check<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS: \(label)") } else { print("FAIL: \(label) (got \(got), want \(want))"); fails += 1 }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var caseNo = 0

/// A fresh source folder and destination folder for one case.
func fresh(_ base: URL = root) -> (src: URL, dst: URL) {
    caseNo += 1
    let dir = base.appendingPathComponent("case\(caseNo)")
    let src = dir.appendingPathComponent("from"), dst = dir.appendingPathComponent("to")
    try! fm.createDirectory(at: src, withIntermediateDirectories: true)
    try! fm.createDirectory(at: dst, withIntermediateDirectories: true)
    return (src, dst)
}
func put(_ dir: URL, _ name: String, _ body: String) -> URL {
    let url = dir.appendingPathComponent(name)
    try! body.write(to: url, atomically: false, encoding: .utf8)
    return url
}
func body(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func names(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
func tags(_ url: URL) -> [String] {
    let u = NSURL(fileURLWithPath: url.path); u.removeAllCachedResourceValues()
    var v: AnyObject?; try? u.getResourceValue(&v, forKey: .tagNamesKey); return (v as? [String]) ?? []
}
func setTags(_ url: URL, _ t: [String]) { try! NSURL(fileURLWithPath: url.path).setResourceValue(t, forKey: .tagNamesKey) }

// Names
check(SafeMove.candidate("Clip.mp4", 0), "Clip.mp4", "attempt 0 is the name itself")
check(SafeMove.candidate("Clip.mp4", 1), "Clip (1).mp4", "attempt 1 is Name (1).ext")
check(SafeMove.candidate("My.Clip.mov", 3), "My.Clip (3).mov", "only the last extension is kept apart")
check(SafeMove.candidate("Clip", 2), "Clip (2)", "no extension gets Name (2)")

// 0 existing copies
do {
    let (s, d) = fresh(); let f = put(s, "Clip.mp4", "new")
    let out = try! SafeMove.move(f, into: d, named: "Clip.mp4")
    check(out.lastPathComponent, "Clip.mp4", "0 existing: keeps its name")
    check(names(d), ["Clip.mp4"], "0 existing: one file in the folder")
    check(body(out), "new", "0 existing: contents intact")
    check(fm.fileExists(atPath: f.path), false, "0 existing: source is gone")
}

// 1 existing copy
do {
    let (s, d) = fresh(); let f = put(s, "Clip.mp4", "new")
    let old = put(d, "Clip.mp4", "old")
    let out = try! SafeMove.move(f, into: d, named: "Clip.mp4")
    check(out.lastPathComponent, "Clip (1).mp4", "1 existing: lands as Clip (1).mp4")
    check(body(old), "old", "1 existing: the existing file is untouched")
    check(body(out), "new", "1 existing: the moved file is intact")
    check(names(s), [], "1 existing: nothing left behind")
}

// 3 existing copies
do {
    let (s, d) = fresh(); let f = put(s, "Clip.mp4", "new")
    for (n, name) in ["Clip.mp4", "Clip (1).mp4", "Clip (2).mp4"].enumerated() { _ = put(d, name, "old\(n)") }
    let out = try! SafeMove.move(f, into: d, named: "Clip.mp4")
    check(out.lastPathComponent, "Clip (3).mp4", "3 existing: lands as Clip (3).mp4")
    check(names(d), ["Clip (1).mp4", "Clip (2).mp4", "Clip (3).mp4", "Clip.mp4"], "3 existing: four files")
    check([body(d.appendingPathComponent("Clip.mp4")), body(d.appendingPathComponent("Clip (1).mp4")),
           body(d.appendingPathComponent("Clip (2).mp4")), body(out)],
          ["old0", "old1", "old2", "new"], "3 existing: no file overwritten")
}

// Lowest free number fills a gap
do {
    let (s, d) = fresh(); let f = put(s, "Clip.mp4", "new")
    _ = put(d, "Clip.mp4", "a"); _ = put(d, "Clip (2).mp4", "b")
    let out = try! SafeMove.move(f, into: d, named: "Clip.mp4")
    check(out.lastPathComponent, "Clip (1).mp4", "gap: takes the lowest free number")
}

// Rename + Move stacked, new name taken in the destination
do {
    let (s, d) = fresh(); let f = put(s, "raw.mp4", "new"); _ = put(d, "Final.mp4", "old")
    let out = try! SafeMove.move(f, into: d, named: "Final.mp4")
    check(out.lastPathComponent, "Final (1).mp4", "rename+move: new name numbered in the destination")
}

// Rename in place to a taken name, no extension
do {
    let (s, _) = fresh(); let f = put(s, "a", "new"); _ = put(s, "b", "old")
    let out = try! SafeMove.move(f, into: s, named: "b")
    check(out.lastPathComponent, "b (1)", "rename in place: taken name numbered, no extension")
    check(names(s), ["b", "b (1)"], "rename in place: old name gone")
}

// Case-only rename and a move into its own folder are not clashes
do {
    let (s, _) = fresh(); let f = put(s, "clip.mp4", "x")
    let out = try! SafeMove.move(f, into: s, named: "Clip.mp4")
    check(names(s), ["Clip.mp4"], "case-only rename: just the case changes")
    check(out.lastPathComponent, "Clip.mp4", "case-only rename: returns the new case")
    let again = try! SafeMove.move(out, into: s, named: "Clip.mp4")
    check(again.lastPathComponent, "Clip.mp4", "move into its own folder: no number added")
    check(names(s), ["Clip.mp4"], "move into its own folder: still one file")
}

// Undo mode: exact name or nothing
do {
    let (s, d) = fresh(); let f = put(s, "Clip.mp4", "new"); _ = put(d, "Clip.mp4", "old")
    var threw = false
    do { _ = try SafeMove.move(f, into: d, named: "Clip.mp4", numbering: false) } catch { threw = true }
    check(threw, true, "no numbering: a taken name throws")
    check(body(f), "new", "no numbering: the file stays where it was")
    check(names(d), ["Clip.mp4"], "no numbering: nothing added")
}

// Tags travel
do {
    let (s, d) = fresh(); let f = put(s, "Clip.mp4", "new"); setTags(f, ["Green", "Work"]); _ = put(d, "Clip.mp4", "old")
    let out = try! SafeMove.move(f, into: d, named: "Clip.mp4")
    check(tags(out), ["Green", "Work"], "Finder tags travel with a numbered move")
}

// Missing source: an error, nothing created
do {
    let (s, d) = fresh()
    var threw = false
    do { _ = try SafeMove.move(s.appendingPathComponent("gone.mp4"), into: d, named: "gone.mp4") } catch { threw = true }
    check(threw, true, "missing source throws")
    check(names(d), [], "missing source leaves the folder empty")
}

// Race: 40 files with the same name moved into one folder at once
do {
    let (s, d) = fresh(); _ = put(d, "Clip.mp4", "old")
    let count = 40
    var sources: [URL] = []
    for i in 0..<count {
        let sub = s.appendingPathComponent("s\(i)")
        try! fm.createDirectory(at: sub, withIntermediateDirectories: true)
        sources.append(put(sub, "Clip.mp4", "new\(i)"))
    }
    let lock = NSLock(); var errors = 0
    DispatchQueue.concurrentPerform(iterations: count) { i in
        do { _ = try SafeMove.move(sources[i], into: d, named: "Clip.mp4") } catch { lock.lock(); errors += 1; lock.unlock() }
    }
    check(errors, 0, "race: every move succeeded")
    check(names(d).count, count + 1, "race: 41 files, none overwritten")
    let bodies = Set(names(d).compactMap { body(d.appendingPathComponent($0)) })
    check(bodies.count, count + 1, "race: every file's contents survived")
    check(Set(names(d)) == Set(["Clip.mp4"] + (1...count).map { "Clip (\($0)).mp4" }), true, "race: numbers 1 to 40, no gaps")
}

// Across volumes
if CommandLine.arguments.count > 2 {
    let other = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let (s, _) = fresh(); let (_, d) = fresh(other)
    let f = put(s, "Clip.mp4", "new"); setTags(f, ["Red"])
    _ = put(d, "Clip.mp4", "old0"); _ = put(d, "Clip (1).mp4", "old1"); _ = put(d, "Clip (2).mp4", "old2")
    let out = try! SafeMove.move(f, into: d, named: "Clip.mp4")
    check(out.lastPathComponent, "Clip (3).mp4", "other volume, 3 existing: lands as Clip (3).mp4")
    check(body(out), "new", "other volume: contents intact")
    check(tags(out), ["Red"], "other volume: Finder tags travel")
    check(fm.fileExists(atPath: f.path), false, "other volume: source removed")
    check(names(d).filter { $0.hasPrefix(".videotags-move-") }, [], "other volume: no hidden copy left")
    check(body(d.appendingPathComponent("Clip.mp4")), "old0", "other volume: existing file untouched")
    let back = try! SafeMove.move(out, into: s, named: "Clip.mp4", numbering: false)
    check(back.path, f.path, "other volume: undo puts it back by name")
} else {
    print("SKIP: other volume (no second folder given)")
}

if fails > 0 { print("\(fails) failed"); exit(1) }
print("All passed")
