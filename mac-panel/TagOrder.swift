// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// Reordering custom tags by holding one in the panel's grid and dragging it.
// Only list and geometry logic lives here, so tests/test_tag_order.sh can
// check it without the app. Green, Yellow and Red are never part of it.

import CoreGraphics

enum TagOrder {
    /// Where a dragged tag would land.
    struct Drop: Equatable {
        /// Index among the other custom tags (the list without the dragged one).
        var index: Int
        /// The drop line to draw, in the same space as the frames.
        var line: CGRect
    }

    /// The list with `name` taken out and put back at `index`, where `index`
    /// counts the other tags only. Unknown names leave the list as it is.
    static func moving(_ tags: [String], _ name: String, to index: Int) -> [String] {
        guard let from = tags.firstIndex(of: name) else { return tags }
        var out = tags
        out.remove(at: from)
        out.insert(name, at: min(max(index, 0), out.count))
        return out
    }

    /// The drop slot nearest `point`. `others` are the frames of every custom
    /// tag except the dragged one, in palette order, laid out in rows that
    /// read left to right. A pointer above or below the grid lands on the
    /// nearest row, so dropping on Green, Yellow and Red puts the tag first.
    static func drop(at point: CGPoint, among others: [CGRect],
                     gap: CGFloat = 8, lineWidth: CGFloat = 3) -> Drop? {
        guard !others.isEmpty else { return nil }

        var rows: [[Int]] = []
        for i in others.indices {
            if let row = rows.last, abs(others[row[0]].minY - others[i].minY) < 2 {
                rows[rows.count - 1].append(i)
            } else {
                rows.append([i])
            }
        }
        let row = rows.min { distance(point.y, others[$0[0]]) < distance(point.y, others[$1[0]]) }!

        let index: Int
        let x: CGFloat
        if let hit = row.first(where: { others[$0].midX > point.x }) {
            index = hit
            x = others[hit].minX - gap / 2
        } else {
            index = row.last! + 1
            x = others[row.last!].maxX + gap / 2
        }
        let ref = others[row[0]]
        return Drop(index: index,
                    line: CGRect(x: x - lineWidth / 2, y: ref.minY - 2, width: lineWidth, height: ref.height + 4))
    }

    private static func distance(_ y: CGFloat, _ frame: CGRect) -> CGFloat {
        if y < frame.minY { return frame.minY - y }
        if y > frame.maxY { return y - frame.maxY }
        return 0
    }
}
