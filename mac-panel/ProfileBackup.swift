// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// Dated backups of the tag profiles file, and the summaries shown before an
// Import or a Restore replaces your profiles. Foundation only, so
// tests/test_profile_backup.sh can check it without the app.
//
// A backup is a byte-for-byte copy of video-tags-profiles.json: every
// profile's tags in their order, and each tag's move folder. So a backup or
// an export is itself a valid profiles file.

import Foundation

enum ProfileBackup {
    static let folderName = "Video Tags Backups"
    static let keepRecent = 30
    static let keepDaily = 30
    /// While you edit, at most one automatic backup in this long.
    static let autoInterval: TimeInterval = 10 * 60

    struct Entry: Equatable {
        let url: URL
        let date: Date
        /// "before import", "before restore"… nil for automatic backups.
        let reason: String?
    }

    // MARK: Names

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// "Profiles 2026-11-27 14.05.33.json", or with a reason
    /// "Profiles 2026-11-27 14.05.33 before import.json". Sorts by date.
    static func fileName(_ date: Date, reason: String? = nil) -> String {
        let base = "Profiles \(stamp.string(from: date))"
        return (reason.map { "\(base) \($0)" } ?? base) + ".json"
    }

    /// The date and reason back out of a backup's name, or nil for any other file.
    static func parse(_ name: String) -> (date: Date, reason: String?)? {
        let prefix = "Profiles "
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let rest = name.dropFirst(prefix.count).dropLast(".json".count)
        let stampLength = 19   // yyyy-MM-dd HH.mm.ss
        guard rest.count >= stampLength, let date = stamp.date(from: String(rest.prefix(stampLength))) else { return nil }
        let tail = rest.dropFirst(stampLength).trimmingCharacters(in: .whitespaces)
        return (date, tail.isEmpty ? nil : tail)
    }

    /// "Video Tags Profiles 2026-11-27.json", the name an Export suggests.
    static func exportName(_ date: Date = Date()) -> String {
        "Video Tags Profiles \(String(stamp.string(from: date).prefix(10))).json"
    }

    // MARK: Backups

    /// Every backup in `folder`, newest first.
    static func list(in folder: URL) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> Entry? in
            guard let p = parse(name) else { return nil }
            return Entry(url: folder.appendingPathComponent(name), date: p.date, reason: p.reason)
        }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    /// Saves `data` as a new dated backup and prunes old ones. Returns the
    /// backup that now holds this content, or nil if it was skipped.
    ///
    /// Nothing is written when the newest backup already has the same bytes
    /// (that one is returned), or when `minInterval` is set and the newest
    /// backup is younger than that. A backup never replaces another file.
    @discardableResult
    static func save(_ data: Data, in folder: URL, reason: String? = nil,
                     now: Date = Date(), minInterval: TimeInterval = 0) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let newest = list(in: folder).first {
            if (try? Data(contentsOf: newest.url)) == data { return newest.url }
            if minInterval > 0, now.timeIntervalSince(newest.date) < minInterval { return nil }
        }
        var date = now
        var url = folder.appendingPathComponent(fileName(date, reason: reason))
        // Two backups in the same second: step the stamp on rather than overwrite.
        while fm.fileExists(atPath: url.path) {
            date += 1
            url = folder.appendingPathComponent(fileName(date, reason: reason))
        }
        try data.write(to: url, options: .withoutOverwriting)
        prune(in: folder)
        return url
    }

    /// Keeps the `recent` newest backups, plus the newest backup of each of
    /// the `daily` most recent days before those. Deletes the rest.
    @discardableResult
    static func prune(in folder: URL, recent: Int = keepRecent, daily: Int = keepDaily,
                      calendar: Calendar = .current) -> [URL] {
        let all = list(in: folder)
        guard all.count > recent else { return [] }
        var keep = Set(all.prefix(recent).map(\.url))
        var days = Set(all.prefix(recent).map { calendar.startOfDay(for: $0.date) })
        var dailyKept = 0
        for entry in all.dropFirst(recent) where dailyKept < daily {
            let day = calendar.startOfDay(for: entry.date)
            if days.insert(day).inserted { keep.insert(entry.url); dailyKept += 1 }
        }
        let gone = all.map(\.url).filter { !keep.contains($0) }
        for url in gone { try? FileManager.default.removeItem(at: url) }
        return gone
    }

    // MARK: What a file holds

    private struct File: Decodable {
        var active: String
        var profiles: [Profile]
    }
    private struct Profile: Decodable {
        var name: String
        var tags: [String]
        var moves: [String: String]?
    }

    struct Summary: Equatable {
        struct Item: Equatable {
            let name: String
            let tags: [String]
            let moves: [String: String]
        }
        let active: String
        let profiles: [Item]

        var tagCount: Int { profiles.reduce(0) { $0 + $1.tags.count } }

        /// "3 profiles, 42 tags: Personal (30), Work (9), Archive (3)"
        var line: String {
            let list = profiles.map { "\($0.name) (\($0.tags.count))" }.joined(separator: ", ")
            return "\(count(profiles.count, "profile")), \(count(tagCount, "tag")): \(list)"
        }
    }

    /// What a profiles file holds, or nil if it is not one (or has no profiles).
    static func summary(of data: Data) -> Summary? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), !file.profiles.isEmpty else { return nil }
        return Summary(active: file.active,
                       profiles: file.profiles.map { .init(name: $0.name, tags: $0.tags, moves: $0.moves ?? [:]) })
    }

    struct Diff: Equatable {
        var added: [String] = []      // in the new file only
        var removed: [String] = []    // in the current profiles only
        var changed: [String] = []    // in both, with different tags, order or move folders
        var same: [String] = []

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

        /// One line per kind of change, for the confirmation dialog.
        var lines: [String] {
            var out: [String] = []
            if !removed.isEmpty { out.append("Removed: \(removed.joined(separator: ", "))") }
            if !changed.isEmpty { out.append("Changed: \(changed.joined(separator: ", "))") }
            if !added.isEmpty { out.append("Added: \(added.joined(separator: ", "))") }
            if out.isEmpty { out.append("Same as your profiles now.") }
            return out
        }
    }

    /// How `new` differs from `current`. Profile names match ignoring case.
    static func diff(from current: Summary, to new: Summary) -> Diff {
        var d = Diff()
        func find(_ name: String, in s: Summary) -> Summary.Item? {
            s.profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        for item in new.profiles {
            guard let old = find(item.name, in: current) else { d.added.append(item.name); continue }
            if old.tags == item.tags && old.moves == item.moves { d.same.append(item.name) } else { d.changed.append(item.name) }
        }
        for item in current.profiles where find(item.name, in: new) == nil { d.removed.append(item.name) }
        return d
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
