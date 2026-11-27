// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// Comments stored inside the media file itself (what VLC's Media Information
// and Music show), as opposed to the Finder Get Info comment.
//
//   mp3            ID3v2 COMM frames, and the ID3v1 comment field
//   wav            LIST/INFO ICMT, and an embedded "id3 " chunk
//   aif / aiff     an embedded "ID3 " chunk
//   mp4 m4a m4v mov  ©cmt in the iTunes item list, the QuickTime
//                  com.apple.quicktime.comment key, and classic udta ©cmt
//
// Removal never changes the file's size or moves any audio or video data:
// ID3 frames are rewritten into the same tag space and padded with zeros,
// MP4 atoms are renamed to "free", and WAV/ID3v1 text is zeroed. Finder tags,
// the Finder comment and every other xattr stay as they are.

import Foundation

enum EmbeddedComment {
    /// The comment text, or nil if the file has none this code can remove.
    static func read(_ path: String) -> String? {
        guard let edits = try? scan(path) else { return nil }
        let texts = edits.compactMap(\.text).map(trim).filter { !$0.isEmpty }
        // ID3v1 holds a copy cut to 30 characters: keep only the longest of each.
        var unique: [String] = []
        for t in texts.sorted(by: { $0.count > $1.count }) where !unique.contains(where: { $0.hasPrefix(t) }) {
            unique.append(t)
        }
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }

    /// Strips every comment `read` would show. True when something was removed.
    @discardableResult
    static func remove(_ path: String) throws -> Bool {
        let edits = try scan(path)
        guard !edits.isEmpty else { return false }
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        for edit in edits {
            try handle.seek(toOffset: edit.offset)
            try handle.write(contentsOf: edit.replacement)
        }
        try handle.synchronize()
        return true
    }

    // MARK: - Scanning

    /// One in-place write: `replacement` goes at `offset`, same length as what it replaces.
    struct Edit {
        let offset: UInt64
        let replacement: Data
        let text: String?
    }

    enum Failure: Error { case unreadable }

    private static func scan(_ path: String) throws -> [Edit] {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Failure.unreadable }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let file = Reader(handle: handle, size: size)
        guard let magic = file.bytes(0, 12) else { return [] }

        if magic.starts(with: Array("ID3".utf8)) || isMP3(path) {
            var edits = id3v2(file, at: 0)
            edits += id3v1(file)
            return edits
        }
        if magic.starts(with: Array("RIFF".utf8)), magic[8..<12].elementsEqual("WAVE".utf8) {
            return riff(file)
        }
        if magic.starts(with: Array("FORM".utf8)),
           magic[8..<12].elementsEqual("AIFF".utf8) || magic[8..<12].elementsEqual("AIFC".utf8) {
            return aiff(file)
        }
        if magic[4..<8].elementsEqual("ftyp".utf8) || magic[4..<8].elementsEqual("moov".utf8)
            || magic[4..<8].elementsEqual("wide".utf8) || magic[4..<8].elementsEqual("mdat".utf8) {
            return mp4(file)
        }
        return []
    }

    private static func isMP3(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "mp3"
    }

    // MARK: - ID3v2

    private static func id3v2(_ file: Reader, at start: UInt64) -> [Edit] {
        guard let h = file.bytes(start, 10), h.starts(with: Array("ID3".utf8)) else { return [] }
        let major = h[3], flags = h[5]
        guard (2...4).contains(major), flags & 0x80 == 0 else { return [] }   // unsynchronised tags: leave alone
        let tagSize = Int(syncsafe(h[6..<10]))
        guard tagSize > 0, let body = file.bytes(start + 10, tagSize) else { return [] }

        var pos = 0
        if major >= 3, flags & 0x40 != 0, body.count >= 4 {             // extended header
            pos = major == 3 ? 4 + Int(bigEndian(body[0..<4])) : Int(syncsafe(body[0..<4]))
        }
        let headerLen = major == 2 ? 6 : 10
        let framesStart = pos
        var kept = Data(), texts: [String] = [], dropped = false
        while pos + headerLen <= body.count {
            let idBytes = body[pos..<(pos + (major == 2 ? 3 : 4))]
            guard idBytes.first != 0, let id = String(bytes: idBytes, encoding: .isoLatin1) else { break }
            let size: Int
            switch major {
            case 2: size = Int(bigEndian(body[(pos + 3)..<(pos + 6)]))
            case 3: size = Int(bigEndian(body[(pos + 4)..<(pos + 8)]))
            default: size = Int(syncsafe(body[(pos + 4)..<(pos + 8)]))
            }
            let end = pos + headerLen + size
            guard size >= 0, end <= body.count else { break }
            let payload = Data(body[(pos + headerLen)..<end])
            // COMM is the standard frame; ffmpeg and some taggers write TXXX "comment" instead.
            let isComm = id == "COMM" || id == "COM"
            let isTXXX = id == "TXXX" || id == "TXX"
            if isComm || isTXXX, let comment = comm(payload, skip: isComm ? 4 : 1),
               isComm ? !comment.description.hasPrefix("iTun") : comment.description.lowercased() == "comment" {
                texts.append(comment.text)
                dropped = true
            } else {
                kept.append(contentsOf: body[pos..<end])
            }
            pos = end
        }
        guard dropped else { return [] }
        let region = body.count - framesStart
        kept.append(Data(count: max(0, region - kept.count)))                     // padding keeps the tag the same size
        return [Edit(offset: start + 10 + UInt64(framesStart), replacement: kept, text: texts.joined(separator: "\n"))]
    }

    /// COMM: encoding, 3-byte language, short description, text (skip 4).
    /// TXXX: encoding, description, value (skip 1).
    private static func comm(_ d: Data, skip: Int) -> (description: String, text: String)? {
        guard d.count >= skip else { return nil }
        let enc = d[d.startIndex]
        let rest = Data(d.dropFirst(skip))
        let wide = enc == 1 || enc == 2
        var split = rest.count
        var i = 0
        while i < rest.count {
            if wide {
                if i + 1 < rest.count, rest[i] == 0, rest[i + 1] == 0 { split = i; break }
                i += 2
            } else {
                if rest[i] == 0 { split = i; break }
                i += 1
            }
        }
        let term = wide ? 2 : 1
        let desc = decode(rest.prefix(split), enc)
        let text = split + term <= rest.count ? decode(rest.suffix(from: split + term), enc) : ""
        return (desc, text)
    }

    private static func decode(_ d: Data, _ enc: UInt8) -> String {
        let s: String?
        switch enc {
        case 1: s = String(data: d, encoding: .utf16)
        case 2: s = String(data: d, encoding: .utf16BigEndian)
        case 3: s = String(data: d, encoding: .utf8)
        default: s = String(data: d, encoding: .isoLatin1)
        }
        return trim(s ?? "")
    }

    // MARK: - ID3v1

    private static func id3v1(_ file: Reader) -> [Edit] {
        guard file.size >= 128, let t = file.bytes(file.size - 128, 128), t.starts(with: Array("TAG".utf8)) else { return [] }
        let track = t[125] == 0 && t[126] != 0          // ID3v1.1 keeps the track number in the last two bytes
        let range = 97..<(track ? 125 : 127)
        let raw = Data(t[range])
        let text = trim(String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? "")
        guard !text.isEmpty else { return [] }
        return [Edit(offset: file.size - 128 + 97, replacement: Data(count: raw.count), text: text)]
    }

    // MARK: - WAV and AIFF

    private static func riff(_ file: Reader) -> [Edit] {
        var edits: [Edit] = []
        var pos: UInt64 = 12
        while pos + 8 <= file.size, let h = file.bytes(pos, 8) {
            let id = String(bytes: h[0..<4], encoding: .isoLatin1) ?? ""
            let size = UInt64(littleEndian(h[4..<8]))
            let data = pos + 8
            if id == "LIST", let kind = file.bytes(data, 4), kind.elementsEqual("INFO".utf8) {
                var sub = data + 4
                while sub + 8 <= data + size, let sh = file.bytes(sub, 8) {
                    let sid = String(bytes: sh[0..<4], encoding: .isoLatin1) ?? ""
                    let ssize = UInt64(littleEndian(sh[4..<8]))
                    if sid == "ICMT", ssize > 0, let raw = file.bytes(sub + 8, Int(ssize)) {
                        let text = trim(String(data: Data(raw), encoding: .utf8) ?? String(data: Data(raw), encoding: .isoLatin1) ?? "")
                        if !text.isEmpty { edits.append(Edit(offset: sub + 8, replacement: Data(count: Int(ssize)), text: text)) }
                    }
                    sub += 8 + ssize + (ssize & 1)
                }
            } else if id.lowercased() == "id3 " {
                edits += id3v2(file, at: data)
            }
            pos = data + size + (size & 1)
        }
        return edits
    }

    private static func aiff(_ file: Reader) -> [Edit] {
        var edits: [Edit] = []
        var pos: UInt64 = 12
        while pos + 8 <= file.size, let h = file.bytes(pos, 8) {
            let id = String(bytes: h[0..<4], encoding: .isoLatin1) ?? ""
            let size = UInt64(bigEndian(h[4..<8]))
            if id == "ID3 " { edits += id3v2(file, at: pos + 8) }
            pos += 8 + size + (size & 1)
        }
        return edits
    }

    // MARK: - MP4 / QuickTime

    private struct Atom {
        let type: String
        let start: UInt64       // file offset of the atom header
        let header: UInt64      // 8 or 16
        let size: UInt64
        var body: UInt64 { start + header }
        var end: UInt64 { start + size }
    }

    private static func atoms(_ file: Reader, from: UInt64, to: UInt64) -> [Atom] {
        var out: [Atom] = []
        var pos = from
        while pos + 8 <= to, let h = file.bytes(pos, 8) {
            var size = UInt64(bigEndian(h[0..<4]))
            var header: UInt64 = 8
            if size == 1, let big = file.bytes(pos + 8, 8) { size = bigEndian64(big); header = 16 }
            else if size == 0 { size = to - pos }
            guard size >= header, pos + size <= to else { break }
            out.append(Atom(type: String(bytes: h[4..<8], encoding: .isoLatin1) ?? "", start: pos, header: header, size: size))
            pos += size
        }
        return out
    }

    private static func mp4(_ file: Reader) -> [Edit] {
        guard let moov = atoms(file, from: 0, to: file.size).first(where: { $0.type == "moov" }) else { return [] }
        var edits: [Edit] = []
        let free = Data("free".utf8)
        func rename(_ a: Atom, _ text: String?) { edits.append(Edit(offset: a.start + 4, replacement: free, text: text)) }

        let children = atoms(file, from: moov.body, to: moov.end)
        var metas = children.filter { $0.type == "meta" }
        if let udta = children.first(where: { $0.type == "udta" }) {
            for a in atoms(file, from: udta.body, to: udta.end) {
                if a.type == "\u{A9}cmt" { rename(a, classicText(file, a)) }      // QuickTime user data
                if a.type == "meta" { metas.append(a) }
            }
        }
        for meta in metas {
            // ISO meta is a full box (4 bytes of version and flags); QuickTime's is not.
            var inner = meta.body
            if let peek = file.bytes(inner, 8), bigEndian(peek[0..<4]) == 0,
               !atoms(file, from: inner + 4, to: meta.end).isEmpty { inner += 4 }
            let list = atoms(file, from: inner, to: meta.end)
            var commentKeys = Set<UInt32>()
            if let keys = list.first(where: { $0.type == "keys" }), let kh = file.bytes(keys.body, 8) {
                let count = bigEndian(kh[4..<8])
                var pos = keys.body + 8
                var index: UInt32 = 1
                while index <= count, pos + 8 <= keys.end, let e = file.bytes(pos, 8) {
                    let len = UInt64(bigEndian(e[0..<4]))
                    guard len >= 8 else { break }
                    if let name = file.bytes(pos + 8, Int(len - 8)), String(bytes: name, encoding: .utf8) == "com.apple.quicktime.comment" {
                        commentKeys.insert(index)
                    }
                    pos += len; index += 1
                }
            }
            guard let ilst = list.first(where: { $0.type == "ilst" }) else { continue }
            for item in atoms(file, from: ilst.body, to: ilst.end) {
                let raw = file.bytes(item.start + 4, 4).map { bigEndian($0[0..<4]) } ?? 0
                if item.type == "\u{A9}cmt" || commentKeys.contains(raw) { rename(item, dataText(file, item)) }
            }
        }
        return edits
    }

    /// The UTF-8 payload of an item's "data" atom.
    private static func dataText(_ file: Reader, _ item: Atom) -> String? {
        guard let data = atoms(file, from: item.body, to: item.end).first(where: { $0.type == "data" }),
              data.size > data.header + 8,
              let raw = file.bytes(data.body + 8, Int(data.size - data.header - 8)) else { return nil }
        return String(bytes: raw, encoding: .utf8)
    }

    /// Classic QuickTime user data text: 2-byte length, 2-byte language, text.
    private static func classicText(_ file: Reader, _ a: Atom) -> String? {
        guard let h = file.bytes(a.body, 4) else { return nil }
        let len = Int(bigEndian(h[0..<2]))
        guard len > 0, a.body + 4 + UInt64(len) <= a.end, let raw = file.bytes(a.body + 4, len) else { return nil }
        return String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .macOSRoman)
    }

    // MARK: - Helpers

    private struct Reader {
        let handle: FileHandle
        let size: UInt64
        func bytes(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard count >= 0, offset + UInt64(count) <= size else { return nil }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let d = try? handle.read(upToCount: count), d.count == count else { return nil }
            return [UInt8](d)
        }
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}")))
    }

    private static func syncsafe<C: Collection>(_ b: C) -> UInt32 where C.Element == UInt8 {
        b.reduce(0) { ($0 << 7) | UInt32($1 & 0x7F) }
    }

    private static func bigEndian<C: Collection>(_ b: C) -> UInt32 where C.Element == UInt8 {
        b.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func bigEndian64<C: Collection>(_ b: C) -> UInt64 where C.Element == UInt8 {
        b.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func littleEndian<C: Collection>(_ b: C) -> UInt32 where C.Element == UInt8 {
        b.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
