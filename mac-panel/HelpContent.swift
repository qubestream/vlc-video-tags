// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Glen Pridgen
//
// The Help window's topics, the keyboard shortcut list, and the search used
// by the Help window and the Help menu's search field. Foundation only, so
// tests/test_help_content.sh can check it without the app.
//
// Each topic is a list of paragraphs written in Markdown (bold, italics and
// links only). A paragraph that starts with "- " is drawn as a bullet, and
// one that starts with "1. " as a numbered step.

import Foundation

enum HelpContent {
    struct Topic: Equatable, Identifiable {
        let id: String
        let title: String
        let symbol: String          // SF Symbol for the sidebar
        let keywords: [String]      // extra words the search should match
        let paragraphs: [String]
    }

    struct Shortcut: Equatable {
        let keys: String            // "1–9", "Space"… (after ⌃⌥)
        let action: String
        let hotKeyID: UInt32        // the id the app registers it under
    }

    static let modifierGlyphs = "⌃⌥"

    /// Every global shortcut, in the order the Settings and Help windows list them.
    static let shortcuts: [Shortcut] = [
        Shortcut(keys: "1–9", action: "Turn tag 1 to 9 on or off (Green, Yellow, Red, then your tags in order)", hotKeyID: 1),
        Shortcut(keys: "⌫", action: "Mark or unmark the video for Trash", hotKeyID: 100),
        Shortcut(keys: "P", action: "Switch to the next tag profile", hotKeyID: 108),
        Shortcut(keys: "C", action: "Jump to the Comments box", hotKeyID: 107),
        Shortcut(keys: "Space", action: "Play or pause", hotKeyID: 101),
        Shortcut(keys: "←", action: "Previous video", hotKeyID: 102),
        Shortcut(keys: "→", action: "Next video", hotKeyID: 103),
        Shortcut(keys: "↑", action: "Faster", hotKeyID: 104),
        Shortcut(keys: "↓", action: "Slower", hotKeyID: 105),
        Shortcut(keys: "0", action: "Normal speed", hotKeyID: 106),
    ]

    static let repository = "https://github.com/qubestream/vlc-video-tags"
    static let issues = repository + "/issues/new"

    static let topics: [Topic] = [
        Topic(id: "start", title: "Getting Started", symbol: "sparkles",
              keywords: ["welcome", "begin", "first", "panel", "float", "open"],
              paragraphs: [
                "Video Tags Panel is a small window that floats above VLC. While a video plays, it lets you put Finder tags on the file, add a comment, rename it, move it to a folder, or send it to the Trash, without leaving VLC.",
                "1. Open VLC and play a video stored on your Mac.",
                "1. The panel shows the file's name and the tags it already has. Click a tag to turn it on or off.",
                "1. The first time, macOS asks whether Video Tags Panel may control VLC. Click **OK**. Without it the panel can't see what is playing.",
                "The panel stays on top of VLC, even in full screen, and follows you across Spaces. Close it with its red button; click the Dock icon, choose **Window → Show Tags Panel** (⌘1), or use the menu-bar icon to bring it back.",
                "Settings live in **Video Tags Panel → Settings…** (⌘,).",
              ]),
        Topic(id: "tags", title: "Tagging Videos", symbol: "tag",
              keywords: ["finder", "tag", "green", "yellow", "red", "custom", "add", "remove", "color", "check"],
              paragraphs: [
                "Each button is a Finder tag. Click it to put the tag on the playing file; click again to take it off. A ✓ means the file has that tag. A file can have as many tags as you like.",
                "**Green**, **Yellow** and **Red** are built in, sit on the top row, and are in every profile.",
                "To make a new tag, type its name in the box under the buttons and press Return or click **Add**. It also goes on the playing file. Names are up to 40 characters, with no commas.",
                "Right-click a tag you made to remove it from the panel. Files that already have it keep it.",
                "If you name a tag after a Finder color (Orange, Blue, Purple, Gray), Finder colors it. Tags that aren't on the panel, such as Work, are never touched.",
                "Tags work on audio files VLC plays, too: mp3, m4a, flac, wav and more.",
              ]),
        Topic(id: "reorder", title: "Reordering Tags", symbol: "arrow.up.arrow.down",
              keywords: ["drag", "order", "move", "arrange", "hotkey number"],
              paragraphs: [
                "Click and hold one of your tags until it lifts, then drag it. A glowing line shows where it will land. Let go to drop it there, or let go where it started to cancel.",
                "The order sets the shortcuts: \(modifierGlyphs)4 to \(modifierGlyphs)9 follow your tags from the left, so put the ones you use most first. Green, Yellow and Red always stay first.",
                "Each profile keeps its own order, and the VLC extension shows the same order.",
              ]),
        Topic(id: "profiles", title: "Tag Profiles", symbol: "person.2",
              keywords: ["profile", "set", "switch", "work", "personal", "rename", "new", "delete"],
              paragraphs: [
                "A profile is its own set of tags, such as Personal and Work. The row above the buttons lists your profiles. Click one to swap the whole set of buttons. \(modifierGlyphs)P switches to the next profile.",
                "Create, rename and delete profiles from the ⋯ menu beside the profiles, the **Profile** menu, or **Settings → Profiles**.",
                "Deleting a profile only removes its buttons. Files you tagged keep their tags.",
                "Each profile keeps its own tag order and its own move folders.",
              ]),
        Topic(id: "backup", title: "Backing Up and Restoring Profiles", symbol: "clock.arrow.circlepath",
              keywords: ["backup", "back up", "restore", "export", "import", "save", "lost", "undo", "copy", "drive"],
              paragraphs: [
                "Your profiles are backed up automatically when the panel opens, when it quits, and before a change (at most every 10 minutes while you edit). Each backup holds every profile, its tags in order, and each tag's move folder.",
                "The panel keeps the 30 newest backups, plus one a day for the 30 days before that. Identical copies are skipped.",
                "Everything is in **Settings → Profiles**:",
                "- **Back Up Now** makes a backup straight away.",
                "- **Export…** saves your profiles to a file you choose. Put a copy on another drive for a hard backup.",
                "- **Import…** reads an export or a backup. Before anything changes it shows what the file holds and which profiles would be removed, changed or added. **Replace All** swaps in the file's profiles; **Add New Profiles Only** keeps yours and adds the ones you don't have.",
                "- **Restore…** puts back the backup you selected in the list, with the same preview.",
                "Import and Restore back up your current profiles first, so you can always go back. They never change the tags on your files.",
              ]),
        Topic(id: "delete", title: "Deleting Videos and Undo", symbol: "trash",
              keywords: ["delete", "trash", "remove", "undo", "bin", "skip"],
              paragraphs: [
                "**Delete** marks the playing video for the Trash. Nothing happens straight away: the file goes to the Trash when you skip to another video or this one ends. Click **Delete** again to unmark it. \(modifierGlyphs)⌫ does the same.",
                "After a file goes to the Trash, **Undo** shows in the footer for a few seconds and puts it back.",
                "Files only ever go to the Trash, never straight to deletion, so you can also get them back from the Trash in Finder.",
              ]),
        Topic(id: "move", title: "Moving Videos to a Folder", symbol: "folder",
              keywords: ["move", "folder", "action", "organize", "file", "numbered", "duplicate", "overwrite"],
              paragraphs: [
                "Any tag can also move videos. Right-click the tag, choose **Move Videos to a Folder…**, and pick the folder. A small folder icon marks tags that have one.",
                "When you put that tag on a video, the video moves when you skip or it ends, like Delete. Taking the tag off first cancels the move, and **Undo** moves it back. Tags and comments go with the file.",
                "If a file with the same name is already in the folder, the moved file is numbered, as \"Clip (1).mp4\", then \"Clip (2).mp4\". Nothing is ever overwritten.",
              ]),
        Topic(id: "rename", title: "Renaming Videos", symbol: "pencil",
              keywords: ["rename", "name", "title", "file name"],
              paragraphs: [
                "Click **Rename**, type the new name and click **Rename**. The extension stays as it is.",
                "The new name is applied when you skip, the video ends, or you quit VLC, never while it plays. If a tag will also move the video, it is renamed first, then moved.",
                "To cancel, click **Rename** again and choose **Keep Original Name**. **Undo** in the footer puts back the old name.",
              ]),
        Topic(id: "comments", title: "Comments", symbol: "text.bubble",
              keywords: ["comment", "note", "get info", "spotlight", "description"],
              paragraphs: [
                "The box at the bottom of the panel edits the file's **Get Info → Comments** in Finder. Spotlight finds the text, too.",
                "It saves when you skip, pause, press Return, click away or quit. \(modifierGlyphs)C jumps to the box. Return saves and hands the keyboard back to VLC, ⌥Return adds a line, and Esc undoes your edit.",
                "Comments stored inside the file itself (an mp3 or m4a comment, or a WAV comment) show too, marked **Stored in the file**. Click × or empty the box to remove one.",
                "The first comment asks whether Video Tags Panel may control Finder. Allow it so Get Info shows your comments.",
              ]),
        Topic(id: "playback", title: "Playback and Speed", symbol: "play.circle",
              keywords: ["play", "pause", "seek", "skip", "next", "previous", "speed", "faster", "slower", "rate", "remote", "progress"],
              paragraphs: [
                "The buttons across the top control VLC: previous video, back 5 seconds, play or pause, forward 5 seconds, next video. Drag the progress bar, or click on it, to move through the file.",
                "**Speed** needs a one-time setup, because VLC only lets other apps change speed through its built-in web control. Click the speed control, or go to **Settings → VLC**, and click **Set Up**. The panel quits VLC, turns on the web control for this Mac only (127.0.0.1), and reopens VLC. Your other VLC settings stay as they are, and VLC's settings file is backed up first.",
                "Then click − or + to change speed, or click the number for normal speed.",
              ]),
        Topic(id: "shortcuts", title: "Keyboard Shortcuts", symbol: "keyboard",
              keywords: ["shortcut", "hotkey", "keyboard", "keys", "control", "option"],
              paragraphs: [
                "These shortcuts work in any app, including full-screen VLC. Each one is Control (⌃) and Option (⌥) plus a key.",
                "If a shortcut does nothing, another app may already use it. **Settings → Shortcuts** marks any shortcut that's taken.",
              ]),
        Topic(id: "extension", title: "The VLC Extension", symbol: "puzzlepiece.extension",
              keywords: ["extension", "lua", "vlc menu", "install"],
              paragraphs: [
                "Video Tags also comes as a VLC extension, for when you don't want a separate app. Start it from **VLC → Extensions → Video Tags** each time you open VLC.",
                "The extension and the panel share the same tags. Buttons you add in one show in the other, and the extension follows the panel's active profile.",
                "Use the panel or the extension to delete a file, not both on the same file.",
              ]),
        Topic(id: "permissions", title: "Permissions and Troubleshooting", symbol: "lock.shield",
              keywords: ["permission", "privacy", "automation", "allow", "not working", "problem", "help", "nothing playing", "vlc not running", "finder"],
              paragraphs: [
                "Video Tags Panel asks for two permissions, once each:",
                "- **VLC**, to see which file is playing and to control playback.",
                "- **Finder**, to save comments so Get Info shows them.",
                "If you clicked Don't Allow, open **System Settings → Privacy & Security → Automation → Video Tags Panel** and turn on VLC and Finder. **Settings → VLC** has a button that opens the page.",
                "**The panel says nothing is playing.** Only files on your Mac can be tagged, not streams or web addresses.",
                "**A shortcut does nothing.** Another app may already use it. Check **Settings → Shortcuts**.",
                "**Speed shows …** VLC may need one more restart after setup. Quit VLC with ⌘Q and open it again.",
                "Still stuck? Choose **Help → Report an Issue…**.",
              ]),
        Topic(id: "data", title: "Where Your Data Lives", symbol: "externaldrive",
              keywords: ["data", "files", "privacy", "folder", "location", "json", "palette", "network", "internet"],
              paragraphs: [
                "Tags and comments are stored by macOS on the files themselves, so they show in Finder and Spotlight and go with the file when you move or copy it.",
                "Your tag buttons and profiles are in **~/Library/Application Support/org.videolan.vlc**, next to VLC's own files, with backups in **Video Tags Backups** there. **Settings → General → Show Data Folder** opens it.",
                "Video Tags Panel never sends anything over the internet. The only network connection is to VLC on this Mac, for speed.",
              ]),
    ]

    static func topic(_ id: String) -> Topic? { topics.first { $0.id == id } }

    /// Topics matching every word of `query`, best first: title matches
    /// before keyword matches before matches in the text. Empty query: all.
    static func search(_ query: String) -> [Topic] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return topics }
        func score(_ t: Topic) -> Int {
            let title = t.title.lowercased()
            let keys = t.keywords.joined(separator: " ").lowercased()
            let text = t.paragraphs.joined(separator: " ").lowercased()
            var total = 0
            for w in words {
                if title.contains(w) { total += 100 }
                else if keys.contains(w) { total += 10 }
                else if text.contains(w) { total += 1 }
                else { return 0 }
            }
            return total
        }
        return topics.map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// How a paragraph is drawn.
    enum Kind: Equatable { case text, bullet, step }

    static func kind(of paragraph: String) -> (Kind, String) {
        if paragraph.hasPrefix("- ") { return (.bullet, String(paragraph.dropFirst(2))) }
        if paragraph.hasPrefix("1. ") { return (.step, String(paragraph.dropFirst(3))) }
        return (.text, paragraph)
    }
}
