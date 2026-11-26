-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Finder tag + Trash helpers for VLC-Video-Tags.
-- Copyright (C) 2026 Glen Pridgen
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 2 of the License, or
-- (at your option) any later version.
-- Usage:
--   osascript finder_ops.applescript get-tags <posix-path>
--   osascript finder_ops.applescript toggle-tag <posix-path> <tag>
--   osascript finder_ops.applescript add-tag <posix-path> <tag>
--   osascript finder_ops.applescript set-tag <posix-path> <tag> <palette-csv>
--   osascript finder_ops.applescript clear-palette-tags <posix-path> <palette-csv>
--   osascript finder_ops.applescript replace-tags <posix-path> <tags-csv>
--   osascript finder_ops.applescript trash <posix-path>
--
-- palette-csv / tags-csv: comma-separated names, no spaces around commas required.
-- toggle-tag adds the tag if missing, removes it if present, keeps every other tag,
-- and prints "on" or "off". add-tag adds it only if missing.
-- set-tag (1.0, kept for compatibility) is last-wins among palette names.

use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 2 then error "usage: <command> <posix-path> [args...]"
	set cmd to item 1 of argv
	set posixPath to item 2 of argv
	if cmd is "get-tags" then
		return joinLines(getTags(posixPath))
	else if cmd is "toggle-tag" then
		if (count of argv) < 3 then error "usage: toggle-tag <posix-path> <tag>"
		return toggleTag(posixPath, item 3 of argv)
	else if cmd is "add-tag" then
		if (count of argv) < 3 then error "usage: add-tag <posix-path> <tag>"
		addTag(posixPath, item 3 of argv)
		return "on"
	else if cmd is "set-tag" then
		if (count of argv) < 4 then error "usage: set-tag <posix-path> <tag> <palette-csv>"
		setTagKeepingOthers(posixPath, item 3 of argv, splitCSV(item 4 of argv))
		return "OK"
	else if cmd is "clear-palette-tags" then
		if (count of argv) < 3 then error "usage: clear-palette-tags <posix-path> <palette-csv>"
		clearPaletteTags(posixPath, splitCSV(item 3 of argv))
		return "OK"
	else if cmd is "replace-tags" then
		if (count of argv) < 3 then error "usage: replace-tags <posix-path> <tags-csv>"
		setTags(posixPath, splitCSV(item 3 of argv))
		return "OK"
	else if cmd is "trash" then
		trashFile(posixPath)
		return "OK"
	else
		error "unknown command: " & cmd
	end if
end run

on fileURL(posixPath)
	return current application's NSURL's fileURLWithPath:posixPath
end fileURL

on getTags(posixPath)
	set theURL to fileURL(posixPath)
	set {ok, theValue} to theURL's getResourceValue:(reference) forKey:(current application's NSURLTagNamesKey) |error|:(missing value)
	if ok is false or theValue is missing value then return {}
	set outList to {}
	repeat with t in (theValue as list)
		set end of outList to (t as text)
	end repeat
	return outList
end getTags

on setTags(posixPath, tagList)
	set theURL to fileURL(posixPath)
	set nsTags to current application's NSMutableArray's array()
	repeat with t in tagList
		set trimmed to trim(t as text)
		if trimmed is not "" then
			nsTags's addObject:trimmed
		end if
	end repeat
	theURL's setResourceValue:nsTags forKey:(current application's NSURLTagNamesKey) |error|:(missing value)
end setTags

on setTagKeepingOthers(posixPath, selectedTag, palette)
	set kept to {}
	repeat with t in getTags(posixPath)
		set nameText to t as text
		if not listContains(palette, nameText) then
			set end of kept to nameText
		end if
	end repeat
	set end of kept to trim(selectedTag)
	setTags(posixPath, kept)
end setTagKeepingOthers

on toggleTag(posixPath, theTag)
	set wanted to trim(theTag)
	set kept to {}
	set found to false
	repeat with t in getTags(posixPath)
		set nameText to t as text
		if nameText is wanted then
			set found to true
		else
			set end of kept to nameText
		end if
	end repeat
	if found then
		setTags(posixPath, kept)
		return "off"
	end if
	set end of kept to wanted
	setTags(posixPath, kept)
	return "on"
end toggleTag

on addTag(posixPath, theTag)
	set wanted to trim(theTag)
	set current to getTags(posixPath)
	if listContains(current, wanted) then return
	set end of current to wanted
	setTags(posixPath, current)
end addTag

on clearPaletteTags(posixPath, palette)
	set kept to {}
	repeat with t in getTags(posixPath)
		set nameText to t as text
		if not listContains(palette, nameText) then
			set end of kept to nameText
		end if
	end repeat
	setTags(posixPath, kept)
end clearPaletteTags

on trashFile(posixPath)
	set posixFile to POSIX file posixPath
	tell application "Finder"
		delete posixFile
	end tell
end trashFile

on splitCSV(csv)
	set csvText to csv as text
	if csvText is "" then return {}
	set oldTIDs to AppleScript's text item delimiters
	set AppleScript's text item delimiters to ","
	set parts to every text item of csvText
	set AppleScript's text item delimiters to oldTIDs
	set outList to {}
	repeat with p in parts
		set trimmed to trim(p as text)
		if trimmed is not "" then
			set end of outList to trimmed
		end if
	end repeat
	return outList
end splitCSV

on joinLines(theList)
	if (count of theList) is 0 then return ""
	set oldTIDs to AppleScript's text item delimiters
	set AppleScript's text item delimiters to linefeed
	set theText to theList as text
	set AppleScript's text item delimiters to oldTIDs
	return theText
end joinLines

on listContains(theList, needle)
	repeat with itemRef in theList
		if (itemRef as text) is needle then return true
	end repeat
	return false
end listContains

on trim(s)
	set textStr to s as text
	set ws to current application's NSCharacterSet's whitespaceAndNewlineCharacterSet()
	set ns to current application's NSString's stringWithString:textStr
	return (ns's stringByTrimmingCharactersInSet:ws) as text
end trim
