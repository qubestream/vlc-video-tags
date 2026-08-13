-- Video Tags: tag the current local file from a floating VLC dialog.
-- Green / Red / custom names become macOS Finder tags (last click wins).
-- Delete moves the file to Trash after skip or when the video ends.

-- VLC copies extension callbacks into another environment; top-level locals
-- are often nil inside activate/input_changed. Keep shared state global.
--
-- Do not call os/io/string/vlc at file scope. VLC scans extensions in a bare
-- luaL_newstate() with no standard libraries; any such call hides the menu item.
SUPPORT = nil
FINDER_SCRIPT = nil
PALETTE_FILE = nil
BUILTIN_TAGS = { "Green", "Red" }
NEAR_END = 0.98

dlg = nil
filename_label = nil
status_label = nil
name_input = nil
custom_tags = {}
current_path = nil
current_choice = nil
pending_path = nil
rebuilding = false

function descriptor()
    return {
        title = "Video Tags",
        version = "0.1",
        author = "Glen Pridgen",
        shortdesc = "Tag videos with Finder tags or send them to Trash",
        description = "Floating palette: Green, Red, Delete, plus tags you add. "
            .. "One tag per video. Delete trashes the file when you skip or the video ends.",
        capabilities = { "input-listener", "playing-listener" }
    }
end

function activate()
    ensure_paths()
    custom_tags = load_palette()
    current_path = peek_path()
    current_choice = nil
    create_dialog()
end

function deactivate()
    destroy_dialog()
end

function close()
    vlc.deactivate()
end

function meta_changed()
end

function input_changed()
    if rebuilding then return end
    local new_path = peek_path()
    local flushed = false
    -- Only trash when a different file actually starts. A nil path can mean
    -- mid-video Stop; that must not flush (playing_changed handles true EOF).
    if pending_path and new_path and pending_path ~= new_path then
        flush_pending_delete()
        flushed = true
    end
    local path_changed = (new_path ~= current_path)
    current_path = new_path
    if path_changed then
        current_choice = nil
        if filename_label then
            filename_label:set_text(filename_text())
        end
        if not flushed then
            refresh_status()
        end
    end
end

function playing_changed()
    if rebuilding then return end
    maybe_flush_on_natural_end()
end

function status_changed()
    playing_changed()
end

function click_green()
    on_tag("Green")
end

function click_red()
    on_tag("Red")
end

function click_delete()
    on_delete()
end

function click_add()
    local name = sanitize_tag_name(widget_text(name_input))
    if not name then
        set_status("Enter a tag name to add")
        return
    end
    if is_builtin_name(name) then
        set_status(name .. " is already a built-in button")
        return
    end
    if find_custom(name) then
        set_status(name .. " is already in the palette")
        return
    end
    custom_tags[#custom_tags + 1] = name
    save_palette()
    on_tag(name)
    rebuild_dialog()
end

function click_remove()
    local name = sanitize_tag_name(widget_text(name_input))
    local removed = nil
    if name then
        if is_builtin_name(name) then
            set_status("Cannot remove built-in " .. name)
            return
        end
        removed = remove_custom(name)
        if not removed then
            set_status(name .. " is not in the palette")
            return
        end
    else
        if #custom_tags == 0 then
            set_status("No custom tags to remove")
            return
        end
        removed = table.remove(custom_tags)
    end
    save_palette()
    rebuild_dialog()
    set_status("Removed " .. removed .. " from palette")
end

-- Dialog -----------------------------------------------------------------

function create_dialog()
    dlg = vlc.dialog("Video Tags")
    filename_label = dlg:add_label(filename_text(), 1, 1, 3, 1)
    status_label = dlg:add_label(status_text(), 1, 2, 3, 1)
    dlg:add_button("Green", click_green, 1, 3, 1, 1)
    dlg:add_button("Red", click_red, 2, 3, 1, 1)
    dlg:add_button("Delete", click_delete, 3, 3, 1, 1)

    local row = 4
    local col = 1
    for i = 1, #custom_tags do
        local name = custom_tags[i]
        dlg:add_button(name, make_tag_click(name), col, row, 1, 1)
        col = col + 1
        if col > 3 then
            col = 1
            row = row + 1
        end
    end
    if col ~= 1 then
        row = row + 1
    end

    name_input = dlg:add_text_input("", 1, row, 2, 1)
    dlg:add_button("Add", click_add, 3, row, 1, 1)
    dlg:add_button("Remove", click_remove, 1, row + 1, 3, 1)
    dlg:show()
end

function destroy_dialog()
    if dlg then
        dlg:delete()
        dlg = nil
    end
    filename_label = nil
    status_label = nil
    name_input = nil
end

function rebuild_dialog()
    rebuilding = true
    destroy_dialog()
    create_dialog()
    rebuilding = false
end

function make_tag_click(name)
    return function()
        on_tag(name)
    end
end

function refresh_labels()
    if filename_label then
        filename_label:set_text(filename_text())
    end
    refresh_status()
end

function refresh_status()
    if status_label then
        status_label:set_text(status_text())
    end
end

function filename_text()
    if not current_path then
        return "No local file playing"
    end
    return basename(current_path)
end

function status_text()
    if current_choice == "Delete" then
        return "Will delete when this video ends or you skip"
    end
    if current_choice then
        return "Tagged " .. current_choice
    end
    return "No tag selected"
end

function set_status(text)
    if status_label then
        status_label:set_text(text)
    end
    log(text)
end

-- Tag / delete -----------------------------------------------------------

function on_tag(name)
    local path, err = require_local_path()
    if not path then
        set_status(err)
        return
    end
    if pending_path == path then
        pending_path = nil
    end
    local ok, out = finder_run("set-tag", path, name, palette_csv())
    if not ok then
        set_status("Could not set Finder tag: " .. out)
        return
    end
    current_choice = name
    refresh_labels()
    osd("Tagged " .. name)
    log("Tagged " .. name .. " -> " .. path)
end

function on_delete()
    local path, err = require_local_path()
    if not path then
        set_status(err)
        return
    end
    local ok, out = finder_run("clear-palette-tags", path, palette_csv())
    if not ok then
        log("clear-palette-tags failed: " .. out)
    end
    pending_path = path
    current_choice = "Delete"
    refresh_labels()
    osd("Will delete when this video ends or you skip")
end

function flush_pending_delete()
    local path = pending_path
    if not path then return end
    pending_path = nil
    if current_choice == "Delete" then
        current_choice = nil
    end
    local ok, out = finder_run("trash", path)
    if not ok then
        set_status("Could not move to Trash: " .. out)
        return
    end
    set_status("Moved " .. basename(path) .. " to Trash")
    osd("Moved to Trash")
end

function maybe_flush_on_natural_end()
    if not pending_path then return end
    local status = playlist_status()
    if status ~= "stopped" then return end
    if not is_near_end() then return end
    if pending_path ~= current_path then return end
    flush_pending_delete()
    current_path = peek_path()
    current_choice = nil
    if filename_label then
        filename_label:set_text(filename_text())
    end
end

function require_local_path()
    if not current_path then
        local playing = current_item()
        if playing then
            return nil, "Tags apply to local files only"
        end
        return nil, "No video playing"
    end
    return current_path
end

function peek_path()
    local item = current_item()
    if not item or not item.uri then return nil end
    return uri_to_path(item:uri())
end

-- Finder helper ----------------------------------------------------------

function finder_run(cmd, ...)
    if not ensure_paths() then
        return false, "Could not resolve VLC data directory"
    end
    if not file_exists(FINDER_SCRIPT) then
        return false, "Finder helper missing — run install.sh"
    end
    local args = { cmd, ... }
    local quoted = { "osascript", shell_quote(FINDER_SCRIPT) }
    for i = 1, #args do
        quoted[#quoted + 1] = shell_quote(args[i])
    end
    local out_file = SUPPORT .. "/video-tags-cmd.out"
    local err_file = SUPPORT .. "/video-tags-cmd.err"
    local cmdline = table.concat(quoted, " ") .. " > " .. shell_quote(out_file) .. " 2> " .. shell_quote(err_file)
    if not os.execute then
        return false, "os.execute is not available"
    end
    local ran, exec_result, _, exec_code = pcall(os.execute, cmdline)
    if not ran then
        return false, tostring(exec_result)
    end
    local out = read_all(out_file) or ""
    local err = read_all(err_file) or ""
    local ok = execute_ok(exec_result, exec_code)
    if not ok then
        local msg = trim(err)
        if msg == "" then msg = trim(out) end
        if msg == "" then msg = "osascript failed" end
        return false, msg
    end
    return true, trim(out)
end

function palette_csv()
    local names = { "Green", "Red" }
    for i = 1, #custom_tags do
        names[#names + 1] = custom_tags[i]
    end
    return table.concat(names, ",")
end

function load_palette()
    ensure_paths()
    local list = {}
    local raw = read_all(PALETTE_FILE)
    if not raw then return list end
    for line in string.gmatch(raw .. "\n", "(.-)\n") do
        local name = sanitize_tag_name(line)
        if name and not is_builtin_name(name) and not name_in_list(list, name) then
            list[#list + 1] = name
        end
    end
    return list
end

function save_palette()
    if not ensure_paths() then
        log("Could not resolve VLC data directory")
        return
    end
    local f = open_file(PALETTE_FILE, "w")
    if not f then
        log("Could not write " .. PALETTE_FILE)
        return
    end
    for i = 1, #custom_tags do
        f:write(custom_tags[i] .. "\n")
    end
    f:close()
end

function find_custom(name)
    local want = string.lower(name)
    for i = 1, #custom_tags do
        if string.lower(custom_tags[i]) == want then
            return i
        end
    end
    return nil
end

function remove_custom(name)
    local idx = find_custom(name)
    if not idx then return nil end
    local removed = custom_tags[idx]
    table.remove(custom_tags, idx)
    return removed
end

function is_builtin_name(name)
    local want = string.lower(name)
    if want == "delete" then return true end
    for i = 1, #BUILTIN_TAGS do
        if string.lower(BUILTIN_TAGS[i]) == want then return true end
    end
    return false
end

function name_in_list(list, name)
    local want = string.lower(name)
    for i = 1, #list do
        if string.lower(list[i]) == want then return true end
    end
    return false
end

function sanitize_tag_name(raw)
    if not raw then return nil end
    local name = trim(raw)
    if name == "" then return nil end
    if string.find(name, ",") then return nil end
    if string.find(name, "[\r\n]") then return nil end
    if #name > 40 then return nil end
    return name
end

-- VLC / path helpers -----------------------------------------------------

function ensure_paths()
    if SUPPORT and FINDER_SCRIPT and PALETTE_FILE then
        return true
    end
    local base = nil
    if vlc.config and vlc.config.userdatadir then
        base = vlc.config.userdatadir()
    end
    if (not base or base == "") and vlc.config and vlc.config.homedir then
        base = vlc.config.homedir() .. "/Library/Application Support/org.videolan.vlc"
    end
    if not base or base == "" then
        return false
    end
    SUPPORT = base
    FINDER_SCRIPT = SUPPORT .. "/video-tags-finder_ops.applescript"
    PALETTE_FILE = SUPPORT .. "/video-tags-palette.txt"
    return true
end

function current_item()
    if vlc.input and vlc.input.item then
        local item = vlc.input.item()
        if item then return item end
    end
    if vlc.player and vlc.player.item then
        return vlc.player.item()
    end
    return nil
end

function playlist_status()
    if vlc.playlist and vlc.playlist.status then
        return vlc.playlist.status()
    end
    return "unknown"
end

function is_near_end()
    local input = nil
    if vlc.object and vlc.object.input then
        input = vlc.object.input()
    end
    if not input or not vlc.var or not vlc.var.get then
        return false
    end
    local pos = vlc.var.get(input, "position")
    if type(pos) == "number" and pos >= NEAR_END then
        return true
    end
    local t = vlc.var.get(input, "time")
    local len = vlc.var.get(input, "length")
    if type(t) == "number" and type(len) == "number" and len > 0 then
        return (len - t) <= 1000000
    end
    return false
end

function uri_to_path(uri)
    if not uri or uri == "" then return nil end
    local decoded = decode_uri(uri)
    decoded = string.gsub(decoded, "^file://localhost", "")
    decoded = string.gsub(decoded, "^file://", "")
    if string.sub(decoded, 1, 1) ~= "/" then
        return nil
    end
    return decoded
end

function decode_uri(uri)
    if vlc.strings and vlc.strings.decode_uri then
        return vlc.strings.decode_uri(uri)
    end
    return string.gsub(uri, "%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
end

function basename(path)
    return string.match(path, "([^/]+)$") or path
end

function osd(text)
    if not vlc.osd or not vlc.osd.message then return end
    pcall(function()
        vlc.osd.message(text, nil, "top", 2000000)
    end)
end

function log(text)
    if vlc.msg and vlc.msg.info then
        vlc.msg.info("[Video Tags] " .. text)
    end
end

function widget_text(widget)
    if not widget or not widget.get_text then return "" end
    return widget:get_text() or ""
end

function shell_quote(s)
    return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'"
end

function execute_ok(result, code)
    if result == true or result == 0 then return true end
    if type(code) == "number" and code == 0 then return true end
    return false
end

function open_file(path, mode)
    if vlc.io and vlc.io.open then
        local ok, f = pcall(vlc.io.open, path, mode)
        if ok and f then return f end
    end
    return io.open(path, mode)
end

function file_exists(path)
    local f = open_file(path, "r")
    if not f then return false end
    f:close()
    return true
end

function read_all(path)
    local f = open_file(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

function trim(s)
    return string.gsub(tostring(s), "^%s*(.-)%s*$", "%1")
end
