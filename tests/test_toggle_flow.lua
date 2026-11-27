-- SPDX-License-Identifier: GPL-2.0-or-later
-- Copyright (C) 2026 Glen Pridgen
-- Drives video_tags.lua with a stub `vlc` object and the real Finder helper,
-- on a temp file, to check that tag buttons toggle and stack.
-- Usage: lua tests/test_toggle_flow.lua <repo-root> <support-dir> <video-file>
local root, support, video = arg[1], arg[2], arg[3]
local fails = 0
local function check(cond, msg)
  print((cond and "PASS: " or "FAIL: ") .. msg)
  if not cond then fails = fails + 1 end
end

local widgets = {}
local function widget(text)
  local w = { text = text }
  function w:set_text(t) self.text = t end
  function w:get_text() return self.text end
  widgets[#widgets + 1] = w
  return w
end
local buttons = {}
vlc = {
  config = { userdatadir = function() return support end },
  input = { item = function()
    return { uri = function() return "file://" .. video end }
  end },
  dialog = function()
    widgets, buttons = {}, {}
    return {
      add_label = function(_, t) return widget(t) end,
      add_text_input = function(_, t) return widget(t) end,
      add_button = function(_, t, fn) local w = widget(t); w.fn = fn; buttons[#buttons + 1] = w; return w end,
      show = function() end, delete = function() end,
    }
  end,
  msg = { info = function() end },
  osd = { message = function() end },
}
dofile(root .. "/lua/extensions/video_tags.lua")

local function labels()
  local out = {}
  for _, b in ipairs(buttons) do out[#out + 1] = b.text end
  return table.concat(out, "|")
end
local function file_tags()
  local h = io.popen("osascript '" .. root .. "/scripts/finder_ops.applescript' get-tags '" .. video .. "' | sort | tr '\\n' ','")
  local s = h:read("*a"); h:close()
  return (s:gsub(",$", ""))
end

activate()
check(status_label.text == "No tags", "starts with no tags")
click_green()
click_red()
check(file_tags() == "Green,Red", "Green then Red keeps both (got " .. file_tags() .. ")")
check(labels():find("✓ Green", 1, true) and labels():find("✓ Red", 1, true), "both buttons show ✓")
check(status_label.text == "Tags: Green, Red", "status lists both tags")
click_yellow()
check(file_tags() == "Green,Red,Yellow", "Yellow joins Green and Red (got " .. file_tags() .. ")")
check(labels():find("✓ Yellow", 1, true), "Yellow button shows ✓")
click_yellow()
click_green()
check(file_tags() == "Red", "second Green click removes Green only")
check(not labels():find("✓ Green", 1, true), "Green ✓ cleared")
name_input.text = "HOF"
click_add()
check(file_tags() == "HOF,Red", "Add puts new tag on alongside Red (got " .. file_tags() .. ")")
check(labels():find("✓ HOF", 1, true), "new HOF button shows ✓ after rebuild")
deactivate()
activate()
check(status_label.text == "Tags: Red, HOF", "reopening reads tags from the file (got " .. status_label.text .. ")")
click_delete()
check(file_tags() == "", "Delete clears palette tags")
if fails > 0 then print(fails .. " check(s) failed"); os.exit(1) end
print("All toggle flow checks passed")
