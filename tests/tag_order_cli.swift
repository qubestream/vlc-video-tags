// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// Test driver for mac-panel/TagOrder.swift, run by tests/test_tag_order.sh.
import CoreGraphics
import Foundation

var fails = 0
func check<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS: \(label)") } else { print("FAIL: \(label) (got \(got), want \(want))"); fails += 1 }
}

// moving
let tags = ["A", "B", "C", "D"]
check(TagOrder.moving(tags, "A", to: 3), ["B", "C", "D", "A"], "A to the end")
check(TagOrder.moving(tags, "D", to: 0), ["D", "A", "B", "C"], "D to the front")
check(TagOrder.moving(tags, "B", to: 2), ["A", "C", "B", "D"], "B after C")
check(TagOrder.moving(tags, "B", to: 1), tags, "B back where it was")
check(TagOrder.moving(tags, "Z", to: 0), tags, "unknown name changes nothing")
check(TagOrder.moving(tags, "C", to: 99), ["A", "B", "D", "C"], "index past the end clamps")
check(TagOrder.moving(tags, "C", to: -5), ["C", "A", "B", "D"], "negative index clamps")

// drop: a 3-column grid, chips 100 x 28, 8pt gaps, rows at y = 0, 36.
// Dragging the 2nd chip of 6, so the others are slots 0, 2, 3, 4, 5.
func cell(_ i: Int) -> CGRect { CGRect(x: CGFloat(i % 3) * 108, y: CGFloat(i / 3) * 36, width: 100, height: 28) }
let others = [0, 2, 3, 4, 5].map(cell)
func idx(_ x: CGFloat, _ y: CGFloat) -> Int { TagOrder.drop(at: CGPoint(x: x, y: y), among: others)!.index }
check(idx(10, 10), 0, "left half of the first chip lands before it")
check(idx(80, 10), 1, "right half of the first chip lands after it")
check(idx(160, 14), 1, "over its own empty slot stays in place")
check(idx(300, 14), 2, "past the end of row 1 lands after its last chip")
check(idx(10, 50), 2, "start of row 2")
check(idx(200, 50), 4, "middle of row 2")
check(idx(400, 50), 5, "past the last chip lands at the end")
check(idx(10, -40), 0, "above the grid (Green, Yellow, Red) lands first")
check(idx(400, 300), 5, "far below the grid lands last")
check(idx(150, 31), 1, "in the gap between rows picks the nearer row")
let line = TagOrder.drop(at: CGPoint(x: 10, y: 50), among: others)!.line
check(line.midX, 0 - 4, "line sits in the gap before the target chip")
check(line.minY, 36 - 2, "line is on the pointer's row")
check(TagOrder.drop(at: .zero, among: []) == nil, true, "nothing to drop among")

exit(fails == 0 ? 0 : 1)
