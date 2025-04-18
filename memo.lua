-- memo.lua
--
-- A recent files menu for mpv

local options = {
    -- File path gets expanded, leave empty for in-memory history
    history_path = "~~/memo-history.log",

    -- How many entries to display in menu
    entries = 10,

    -- Display navigation to older/newer entries
    pagination = true,

    -- Display files only once
    hide_duplicates = true,

    -- Check if files still exist
    hide_deleted = true,

    -- Display only the latest file from each directory
    hide_same_dir = false,

    -- Date format https://www.lua.org/pil/22.1.html
    timestamp_format = "%Y-%m-%d %H:%M:%S",

    -- Display titles instead of filenames when available
    use_titles = true,

    -- Truncate titles to n characters, 0 to disable
    truncate_titles = 60,

    -- Meant for use in auto profiles
    enabled = true,

    -- Keybinds for vanilla menu
    up_binding = "UP WHEEL_UP",
    down_binding = "DOWN WHEEL_DOWN",
    select_binding = "RIGHT ENTER",
    append_binding = "Shift+RIGHT Shift+ENTER",
    hide_binding = "DEL",
    close_binding = "LEFT ESC",

    -- Path prefixes for the recent directory menu
    -- This can be used to restrict the parent directory relative to which the
    -- directories are shown.
    -- Syntax
    --   Prefixes are separated by | and can use Lua patterns by prefixing
    --   them with "pattern:", otherwise they will be treated as plain text.
    --   Pattern syntax can be found here https://www.lua.org/manual/5.1/manual.html#5.4.1
    -- Example
    --   "path_prefixes=My-Movies|pattern:TV Shows/.-/|Anime" will show directories
    --   that are direct subdirectories of directories named "My-Movies" as well as
    --   "Anime", while for TV Shows the shown directories are one level below that.
    --   Opening the file "/data/TV Shows/Comedy/Curb Your Enthusiasm/S4/E06.mkv" will
    --   lead to "Curb Your Enthusiasm" to be shown in the directory menu. Opening
    --   of that entry will then open that file again.
    path_prefixes = "pattern:.*",
    --
	-- playlist part
	--
	--enabel/disables the script from automatically saving the playlist when closing mpv
    auto_save = true,

    --loads last_session when mpv is started in idle mode and no files are in the playlist
    auto_load = false,

    --path where playlists get saved. Defaults to the watch_later folder in mpv config
    --if you have duplicated entries in the playlist menu under windows and are using symlinks then better put a path here
    -- use double backslashes or slashes for windows
    playlist_path = "",
    -- use the playlist_path and the basename in the .log file to filter for unique playlists. For example if you have mpv portable on a usb stick
    -- the drive letter changes from e: to d: then memo would treat them as seperate playlists and show both even if they point to the same file.
    -- you don't need this if there is a static path in playlist_path above.
    use_relative_path = true,
    --maintain position in the playlist that is saved in the playlist file
    load_position = false,
	
    ext = ".pls",	

    -- icon for the uosc button. Name of a material icon (look at uosc.conf for more info)
    icon="article",
    -- tooltip for the uosc button
    tooltip="Playlist",
    -- retention_limit=0 keep all memo entrys during memo-cleanup, retention_limit=100 keep the last 100. 
    -- Playlists (files ending with ext) will always be kept
    -- All duplicates will be removed.
    retention_limit = 0,
    -- delete playlists from filesystem
    delte_pl_file = true,
    -- delete playlist entries from the playlist .log file, Setting this to false will only mark them as hidden
    delete_playlist_entries = false,
    -- remove entries marked as hidden
    remove_hidden = true,
}
function parse_path_prefixes(path_prefixes)
    local patterns = {}
    for prefix in path_prefixes:gmatch("([^|]+)") do
        if prefix:find("pattern:", 1, true) == 1 then
            patterns[#patterns + 1] = {pattern = prefix:sub(9)}
        else
            patterns[#patterns + 1] = {pattern = prefix, plain = true}
        end
    end
    return patterns
end

local script_name = mp.get_script_name()

mp.utils = require "mp.utils"
mp.options = require "mp.options"
mp.options.read_options(options, "memo", function(list)
    if list.path_prefixes then
        options.path_prefixes = parse_path_prefixes(options.path_prefixes)
    end
end)
options.path_prefixes = parse_path_prefixes(options.path_prefixes)

local assdraw = require "mp.assdraw"

local osd = mp.create_osd_overlay("ass-events")
osd.z = 2000
local osd_update = nil
local width, height = 0, 0
local margin_top, margin_bottom = 0, 0
local font_size = mp.get_property_number("osd-font-size") or 55

local fakeio = {data = "", cursor = 0, offset = 0, file = nil}
function fakeio:setvbuf(mode) end
function fakeio:flush()
    self.cursor = self.offset + #self.data
end
function fakeio:read(format)
    local out = ""
    if self.cursor < self.offset then
        self.file:seek("set", self.cursor)
        out = self.file:read(format)
        format = format - #out
        self.cursor = self.cursor + #out
    end
    if format > 0 then
        out = out .. self.data:sub(self.cursor - self.offset, self.cursor - self.offset + format)
        self.cursor = self.cursor + format
    end
    return out
end
function fakeio:seek(whence, offset)
    local base = 0
    offset = offset or 0
    if whence == "end" then
        base = self.offset + #self.data
    end
    self.cursor = base + offset
    return self.cursor
end
function fakeio:write(...)
    local args = {...}
    for i, v in ipairs(args) do
        self.data = self.data .. v
    end
end

local history, history_path

if options.history_path ~= "" then
    history_path = mp.command_native({"expand-path", options.history_path})
    history = io.open(history_path, "a+b")
end
if history == nil then
    if history_path then
        mp.msg.warn("cannot write to history file " .. options.history_path .. ", new entries will not be saved to disk")
        history = io.open(history_path, "rb")
        if history then
            fakeio.offset = history:seek("end")
            fakeio.file = history
        end
    end
    history = fakeio
end
history:setvbuf("full")

local event_loop_exhausted = false
local uosc_available = false
local dyn_menu = nil
local menu_shown = false
local last_state = nil
local menu_data = nil
local palette = false
local search_words = nil
local search_query = nil
local dir_menu = false
local dir_menu_prefixes = nil
local new_loadfile = nil
local normalize_path = nil

local data_protocols = {
    edl = true,
    data = true,
    null = true,
    memory = true,
    hex = true,
    fd = true,
    fdclose = true,
    mf = true
}

local stacked_protocols = {
    ffmpeg = true,
    lavf = true,
    appending = true,
    file = true,
    archive = true,
    slice = true
}

local device_protocols = {
    bd = true,
    br = true,
    bluray = true,
    cdda = true,
    dvb = true,
    dvd = true,
    dvdnav = true
}

function utf8_char_bytes(str, i)
    local char_byte = str:byte(i)
    local max_bytes = #str - i + 1
    if char_byte < 0xC0 then
        return math.min(max_bytes, 1)
    elseif char_byte < 0xE0 then
        return math.min(max_bytes, 2)
    elseif char_byte < 0xF0 then
        return math.min(max_bytes, 3)
    elseif char_byte < 0xF8 then
        return math.min(max_bytes, 4)
    else
        return math.min(max_bytes, 1)
    end
end

function utf8_iter(str)
    local byte_start = 1
    return function()
        local start = byte_start
        if #str < start then return nil end
        local byte_count = utf8_char_bytes(str, start)
        byte_start = start + byte_count
        return start, str:sub(start, byte_start - 1)
    end
end

function utf8_table(str)
    local t = {}
    local width = 0
    for _, char in utf8_iter(str) do
        width = width + (#char > 2 and 2 or 1)
        table.insert(t, char)
    end
    return t, width
end

function utf8_subwidth(t, start_index, end_index)
    local index = 1
    local substr = ""
    for _, char in ipairs(t) do
        if start_index <= index and index <= end_index then
            local width = #char > 2 and 2 or 1
            index = index + width
            substr = substr .. char
        end
    end
    return substr, index
end

function utf8_subwidth_back(t, num_chars)
    local index = 0
    local substr = ""
    for i = #t, 1, -1 do
        if num_chars > index then
            local width = #t[i] > 2 and 2 or 1
            index = index + width
            substr = t[i] .. substr
        end
    end
    return substr
end

function utf8_to_unicode(str, i)
    local byte_count = utf8_char_bytes(str, i)
    local char_byte = str:byte(i)
    local unicode = char_byte
    if byte_count ~= 1 then
        local shift = 2 ^ (8 - byte_count)
        char_byte = char_byte - math.floor(0xFF / shift) * shift
        unicode = char_byte * (2 ^ 6) ^ (byte_count - 1)
    end
    for j = 2, byte_count do
        char_byte = str:byte(i + j - 1) - 0x80
        unicode = unicode + char_byte * (2 ^ 6) ^ (byte_count - j)
    end
    return math.floor(unicode + 0.5)
end

function ass_clean(str)
    str = str:gsub("\\", "\\\239\187\191")
    str = str:gsub("{", "\\{")
    str = str:gsub("}", "\\}")
    return str
end

-- Extended from https://stackoverflow.com/a/73283799 with zero-width handling from uosc
function unaccent(str)
    local unimask = "[%z\1-\127\194-\244][\128-\191]*"

    -- "Basic Latin".."Latin-1 Supplement".."Latin Extended-A".."Latin Extended-B"
    local charmap =
    "AÀÁÂÃÄÅĀĂĄǍǞǠǺȀȂȦȺAEÆǢǼ"..
    "BßƁƂƄɃ"..
    "CÇĆĈĊČƆƇȻ"..
    "DÐĎĐƉƊDZƻǄǱDzǅǲ"..
    "EÈÉÊËĒĔĖĘĚƎƏƐȄȆȨɆ"..
    "FƑ"..
    "GĜĞĠĢƓǤǦǴ"..
    "HĤĦȞHuǶ"..
    "IÌÍÎÏĨĪĬĮİƖƗǏȈȊIJĲ"..
    "JĴɈ"..
    "KĶƘǨ"..
    "LĹĻĽĿŁȽLJǇLjǈ"..
    "NÑŃŅŇŊƝǸȠNJǊNjǋ"..
    "OÒÓÔÕÖØŌŎŐƟƠǑǪǬǾȌȎȪȬȮȰOEŒOIƢOUȢ"..
    "PÞƤǷ"..
    "QɊ"..
    "RŔŖŘȐȒɌ"..
    "SŚŜŞŠƧƩƪƼȘ"..
    "TŢŤŦƬƮȚȾ"..
    "UÙÚÛÜŨŪŬŮŰŲƯƱƲȔȖɄǓǕǗǙǛ"..
    "VɅ"..
    "WŴƜ"..
    "YÝŶŸƳȜȲɎ"..
    "ZŹŻŽƵƷƸǮȤ"..
    "aàáâãäåāăąǎǟǡǻȁȃȧaeæǣǽ"..
    "bƀƃƅ"..
    "cçćĉċčƈȼ"..
    "dðƌƋƍȡďđdbȸdzǆǳ"..
    "eèéêëēĕėęěǝȅȇȩɇ"..
    "fƒ"..
    "gĝğġģƔǥǧǵ"..
    "hĥħȟhvƕ"..
    "iìíîïĩīĭįıǐȉȋijĳ"..
    "jĵǰȷɉ"..
    "kķĸƙǩ"..
    "lĺļľŀłƚƛȴljǉ"..
    "nñńņňŉŋƞǹȵnjǌ"..
    "oòóôõöøōŏőơǒǫǭǿȍȏȫȭȯȱoeœoiƣouȣ"..
    "pþƥƿ"..
    "qɋqpȹ"..
    "rŕŗřƦȑȓɍ"..
    "sśŝşšſƨƽșȿ"..
    "tţťŧƫƭțȶtsƾ"..
    "uùúûüũūŭůűųưǔǖǘǚǜȕȗ"..
    "wŵ"..
    "yýÿŷƴȝȳɏ"..
    "zźżžƶƹƺǯȥɀ"

    local zero_width_blocks = {
        {0x0000,  0x001F}, -- C0
        {0x007F,  0x009F}, -- Delete + C1
        {0x034F,  0x034F}, -- combining grapheme joiner
        {0x061C,  0x061C}, -- Arabic Letter Strong
        {0x200B,  0x200F}, -- {zero-width space, zero-width non-joiner, zero-width joiner, left-to-right mark, right-to-left mark}
        {0x2028,  0x202E}, -- {line separator, paragraph separator, Left-to-Right Embedding, Right-to-Left Embedding, Pop Directional Format, Left-to-Right Override, Right-to-Left Override}
        {0x2060,  0x2060}, -- word joiner
        {0x2066,  0x2069}, -- {Left-to-Right Isolate, Right-to-Left Isolate, First Strong Isolate, Pop Directional Isolate}
        {0xFEFF,  0xFEFF}, -- zero-width non-breaking space
        -- Some other characters can also be combined https://en.wikipedia.org/wiki/Combining_character
        {0x0300,  0x036F}, -- Combining Diacritical Marks    0 BMP  Inherited
        {0x1AB0,  0x1AFF}, -- Combining Diacritical Marks Extended   0 BMP  Inherited
        {0x1DC0,  0x1DFF}, -- Combining Diacritical Marks Supplement     0 BMP  Inherited
        {0x20D0,  0x20FF}, -- Combining Diacritical Marks for Symbols    0 BMP  Inherited
        {0xFE20,  0xFE2F}, -- Combining Half Marks   0 BMP  Cyrillic (2 characters), Inherited (14 characters)
        -- Egyptian Hieroglyph Format Controls and Shorthand format Controls
        {0x13430, 0x1345F}, -- Egyptian Hieroglyph Format Controls   1 SMP  Egyptian Hieroglyphs
        {0x1BCA0, 0x1BCAF}, -- Shorthand Format Controls     1 SMP  Common
        -- not sure how to deal with those https://en.wikipedia.org/wiki/Spacing_Modifier_Letters
        {0x02B0,  0x02FF}, -- Spacing Modifier Letters   0 BMP  Bopomofo (2 characters), Latin (14 characters), Common (64 characters)
    }

    return str:gsub(unimask, function(unichar)
        local unicode = utf8_to_unicode(unichar, 1)
        for _, block in ipairs(zero_width_blocks) do
            if unicode >= block[1] and unicode <= block[2] then
                return ""
            end
        end

        return unichar:match("%a") or charmap:match("(%a+)[^%a]-"..(unichar:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1")))
    end)
end

function shallow_copy(t)
    local t2 = {}
    for k,v in pairs(t) do
        t2[k] = v
    end
    return t2
end

function has_protocol(path)
    return path:find("^%a[%w.+-]-://") or path:find("^%a[%w.+-]-:%?")
end

function normalize(path)
    if normalize_path ~= nil then
        if normalize_path then
            -- don't normalize magnet-style paths
            local protocol_start, protocol_end, protocol = path:find("^(%a[%w.+-]-):%?")
            if not protocol_end then
                path = mp.command_native({"normalize-path", path})
            end
        else
            -- TODO: implement the basics of path normalization ourselves for mpv 0.38.0 and under
            local directory = mp.get_property("working-directory", "")
            if not has_protocol(path) then
                path = mp.utils.join_path(directory, path)
            end
        end
        return path
    end

    normalize_path = false

    local commands = mp.get_property_native("command-list", {})
    for _, command in ipairs(commands) do
        if command.name == "loadfile" then
            for _, arg in ipairs(command.args) do
                if arg.name == "index" then
                    new_loadfile = true
                    break
                end
            end
        end
        if command.name == "normalize-path" then
            normalize_path = true
            break
        end
    end
    return normalize(path)
end

function loadfile_compat(path)
    if new_loadfile ~= nil then
        if new_loadfile then
            return {"-1", path}
        end
        return {path}
    end

    new_loadfile = false

    local commands = mp.get_property_native("command-list", {})
    for _, command in ipairs(commands) do
        if command.name == "loadfile" then
            for _, arg in ipairs(command.args) do
                if arg.name == "index" then
                    new_loadfile = true
                    return {"-1", path}
                end
            end
            return {path}
        end
    end
    return {path}
end

function menu_json(menu_items, page, hidden_files)
    local title = (search_query or (dir_menu and "Directories" or "History")) .. " (memo)"
    if options.pagination or page ~= 1 then
        title = title .. " - Page " .. page
    end

    for i = #menu_items, 1, -1 do
        local item = menu_items[i]
        if hidden_files[item.value[2]] and (page * 10000 + i >= hidden_files[item.value[2]]) then
            table.remove(menu_items, i)
        end
    end

    local menu = {
        type = "memo-history",
        title = title,
        items = menu_items,
        on_search = {"script-message-to", script_name, "memo-search-uosc:"},
        on_close = {"script-message-to", script_name, "memo-clear"},
        palette = palette, -- TODO: remove on next uosc release
        search_style = palette and "palette" or nil,
        callback = {script_name, "menu-event"}
    }

    return menu
end

function uosc_update()
    local json = mp.utils.format_json(menu_data) or "{}"
    mp.commandv("script-message-to", "uosc", menu_shown and "update-menu" or "open-menu", json)
end

function update_dimensions()
    width, height = mp.get_osd_size()
    osd.res_x = width
    osd.res_y = height
    draw_menu()
end

if mp.utils.shared_script_property_set then
    function update_margins()
        local shared_props = mp.get_property_native("shared-script-properties")
        local val = shared_props["osc-margins"]
        if val then
            -- formatted as "%f,%f,%f,%f" with left, right, top, bottom, each
            -- value being the border size as ratio of the window size (0.0-1.0)
            local vals = {}
            for v in string.gmatch(val, "[^,]+") do
                vals[#vals + 1] = tonumber(v)
            end
            margin_top = vals[3] -- top
            margin_bottom = vals[4] -- bottom
        else
            margin_top = 0
            margin_bottom = 0
        end
        draw_menu()
    end
else
    function update_margins()
        local val = mp.get_property_native("user-data/osc/margins")
        if val then
            margin_top = val.t
            margin_bottom = val.b
        else
            margin_top = 0
            margin_bottom = 0
        end
        draw_menu()
    end
end

function bind_keys(keys, name, func, opts)
    if not keys then
        mp.add_forced_key_binding(keys, name, func, opts)
        return
    end
    local i = 1
    for key in keys:gmatch("[^%s]+") do
        local prefix = i == 1 and "" or i
        mp.add_forced_key_binding(key, name .. prefix, func, opts)
        i = i + 1
    end
end

function unbind_keys(keys, name)
    if not keys then
        mp.remove_key_binding(name)
        return
    end
    local i = 1
    for key in keys:gmatch("[^%s]+") do
        local prefix = i == 1 and "" or i
        mp.remove_key_binding(name .. prefix)
        i = i + 1
    end
end

function close_menu()
    mp.unobserve_property(update_dimensions)
    mp.unobserve_property(update_margins)
    unbind_keys(options.up_binding, "move_up")
    unbind_keys(options.down_binding, "move_down")
    unbind_keys(options.select_binding, "select")
    unbind_keys(options.append_binding, "append")
    unbind_keys(options.hide_binding, "hide")
    unbind_keys(options.close_binding, "close")
    last_state = nil
    menu_data = nil
    search_words = nil
    search_query = nil
    dir_menu = false
    menu_shown = false
    palette = false
    osd:update()
    osd.hidden = true
    osd:update()
end

function open_menu()
    menu_shown = true

    update_dimensions()
    mp.observe_property("osd-dimensions", "native", update_dimensions)
    mp.observe_property("video-out-params", "native", update_dimensions)
    local margin_prop = mp.utils.shared_script_property_set and "shared-script-properties" or "user-data/osc/margins"
    mp.observe_property(margin_prop, "native", update_margins)

    local function select_item(action)
        local item = menu_data.items[last_state.selected_index]
        if not item then return end
        if action then
            process_menu_event({type = "activate", value = item.value, keep_open = item.keep_open, action = "memo_action_" .. action, index = last_state.selected_index})
        else
            process_menu_event({type = "activate", value = item.value, keep_open = item.keep_open})
        end
    end

    bind_keys(options.up_binding, "move_up", function()
        last_state.selected_index = math.max(last_state.selected_index - 1, 1)
        draw_menu()
    end, { repeatable = true })
    bind_keys(options.down_binding, "move_down", function()
        last_state.selected_index = math.min(last_state.selected_index + 1, #menu_data.items)
        draw_menu()
    end, { repeatable = true })
    bind_keys(options.select_binding, "select", select_item)
    bind_keys(options.append_binding, "append", function()
        select_item("append")
    end)
    bind_keys(options.hide_binding, "hide", function()
        select_item("hide")
    end)
    bind_keys(options.close_binding, "close", close_menu)
    osd.hidden = false
    draw_menu()
end

function draw_menu()
    if not menu_data then return end
    if not menu_shown then
        open_menu()
    end

    local num_options = #menu_data.items > 0 and #menu_data.items + 1 or 1
    last_state.selected_index = math.min(last_state.selected_index, #menu_data.items)

    local function get_scrolled_lines()
        local output_height = height - margin_top * height - margin_bottom * height - 0.2 * font_size + 0.5
        local screen_lines = math.max(math.floor(output_height / font_size), 1)
        local max_scroll = math.max(num_options - screen_lines, 0)
        return math.min(math.max(last_state.selected_index - math.ceil(screen_lines / 2), 0), max_scroll) - 1
    end

    local ass = assdraw.ass_new()
    local curtain_opacity = 0.7

    local alpha = 255 - math.ceil(255 * curtain_opacity)
    ass.text = string.format("{\\pos(0,0)\\rDefault\\an7\\1c&H000000&\\alpha&H%X&}", alpha)
    ass:draw_start()
    ass:rect_cw(0, 0, width, height)
    ass:draw_stop()
    ass:new_event()

    ass:append("{\\rDefault\\pos("..(0.3 * font_size).."," .. (margin_top * height + 0.1 * font_size) .. ")\\an7\\fs" .. font_size .. "\\bord2\\q2\\b1}" .. ass_clean(menu_data.title) .. "{\\b0}")
    ass:new_event()

    local scrolled_lines = get_scrolled_lines() - 1
    local pos_y = margin_top * height - scrolled_lines * font_size + 0.2 * font_size + 0.5
    local clip_top = math.floor(margin_top * height + font_size + 0.2 * font_size + 0.5)
    local clip_bottom = math.floor((1 - margin_bottom) * height + 0.5)
    local clipping_coordinates = "0," .. clip_top .. "," .. width .. "," .. clip_bottom

    if #menu_data.items > 0 then
        local menu_index = 0
        for i = 1, #menu_data.items do
            local item = menu_data.items[i]
            if item.title then
                local icon
                local separator = last_state.selected_index == i and "{\\alpha&HFF&}●{\\alpha&H00&}  - " or "{\\alpha&HFF&}●{\\alpha&H00&} - "
                if item.icon == "spinner" then
                    separator = "⟳ "
                elseif item.icon == "navigate_next" then
                    icon = last_state.selected_index == i and "▶" or "▷"
                elseif item.icon == "navigate_before" then
                    icon = last_state.selected_index == i and "◀" or "◁"
                else
                    icon = last_state.selected_index == i and "●" or "○"
                end
                ass:new_event()
                ass:pos(0.3 * font_size, pos_y + menu_index * font_size)
                ass:append("{\\rDefault\\fnmonospace\\an1\\fs" .. font_size .. "\\bord2\\q2\\clip(" .. clipping_coordinates .. ")}"..separator.."{\\rDefault\\an7\\fs" .. font_size .. "\\bord2\\q2}" .. ass_clean(item.title))
                if icon then
                    ass:new_event()
                    ass:pos(0.6 * font_size, pos_y + menu_index * font_size)
                    ass:append("{\\rDefault\\fnmonospace\\an2\\fs" .. font_size .. "\\bord2\\q2\\clip(" .. clipping_coordinates .. ")}" .. icon)
                end
                menu_index = menu_index + 1
            end
        end
    else
        ass:pos(0.3 * font_size, pos_y)
        ass:append("{\\rDefault\\an1\\fs" .. font_size .. "\\bord2\\q2\\clip(" .. clipping_coordinates .. ")}")
        ass:append("No entries")
    end

    osd_update = nil
    osd.data = ass.text
    osd:update()
end

function get_full_path(forced_path)
    local path = forced_path or mp.get_property("path")
    if path == nil or path == "-" or path == "/dev/stdin" then return end

    local display_path, save_path, effective_path, effective_protocol, is_remote, file_options = path_info(path)

    if not is_remote then
        path = normalize(save_path)
    end

    return path, display_path, save_path, effective_path, effective_protocol, is_remote, file_options
end

function path_info(full_path)
    local function resolve(effective_path, save_path, display_path, last_protocol, is_remote)
        local protocol_start, protocol_end, protocol = display_path:find("^(%a[%w.+-]-)://")

        if protocol == "ytdl" then
            -- for direct video access ytdl://videoID and ytsearch:
            is_remote = true
        elseif protocol and not stacked_protocols[protocol] then
            local input_path, file_options
            if device_protocols[protocol] then
                input_path, file_options = display_path:match("(.-) %-%-opt=(.+)")
                effective_path = file_options and file_options:match(".+=(.*)")
                if protocol == "dvb" then
                    is_remote = true
                    if not effective_path then
                        effective_path = display_path
                        input_path = display_path:sub(protocol_end + 1)
                    end
                end
                display_path = input_path or display_path
            else
                is_remote = true
                display_path = display_path:sub(protocol_end + 1)
            end
            return display_path, save_path, effective_path, protocol, is_remote, file_options
        end

        if not protocol_end then
            if last_protocol == "ytdl" then
                display_path = "ytdl://" .. display_path
            end
            return display_path, save_path, effective_path, last_protocol, is_remote, nil
        end

        display_path = display_path:sub(protocol_end + 1)

        if protocol == "archive" then
            local main_path, archive_path, filename = display_path:gsub("%%7C", "|"):match("(.-)(|.-[\\/])(.+)")
            if not main_path then
                local main_path = display_path:match("(.-)|")
                effective_path = normalize(main_path or display_path)
                _, save_path, effective_path, protocol, is_remote, file_options = resolve(effective_path, save_path, display_path, protocol, is_remote)
                effective_path = normalize(effective_path)
                save_path = "archive://" .. (save_path or effective_path)
                if main_path then
                    save_path = save_path .. display_path:match("|(.-)")
                end
            else
                display_path, save_path, _, protocol, is_remote, file_options = resolve(main_path, save_path, main_path, protocol, is_remote)
                effective_path = normalize(display_path)
                save_path = save_path or effective_path
                save_path = "archive://" .. save_path .. (save_path:find("archive://") and archive_path:gsub("|", "%%7C") or archive_path) .. filename
                _, main_path = mp.utils.split_path(main_path)
                _, filename = mp.utils.split_path(filename)
                display_path = main_path .. ": " .. filename
            end
        elseif protocol == "slice" then
            if effective_path then
                effective_path = effective_path:match(".-@(.*)") or effective_path
            end
            display_path = display_path:match(".-@(.*)") or display_path
        end

        return resolve(effective_path, save_path, display_path, protocol, is_remote)
    end

    -- don't resolve magnet-style paths
    local protocol_start, protocol_end, protocol = full_path:find("^(%a[%w.+-]-):%?")
    if protocol_end then
        return full_path, full_path, protocol, true, nil
    end

    local display_path, save_path, effective_path, effective_protocol, is_remote, file_options = resolve(nil, nil, full_path, nil, false)
    effective_path = effective_path or display_path
    save_path = save_path or effective_path
    if is_remote and not file_options then
        display_path = display_path:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
    end

    return display_path, save_path, effective_path, effective_protocol, is_remote, file_options
end

function write_history(display, forced_path, mark_hidden, item_index)
    local full_path, display_path, save_path, effective_path, effective_protocol, is_remote, file_options = get_full_path(forced_path)
    if full_path == nil then
        mp.msg.debug("cannot get full path to file")
        if display then
            mp.osd_message("[memo] cannot get full path to file")
        end
        return
    end

    if data_protocols[effective_protocol] then
        mp.msg.debug("not logging file with " .. effective_protocol .. " protocol")
        if display then
            mp.osd_message("[memo] not logging file with " .. effective_protocol .. " protocol")
        end
        return
    end

    if forced_path then
        full_path = effective_path
    elseif effective_protocol == "bd" or effective_protocol == "br" or effective_protocol == "bluray" then
        full_path = full_path .. " --opt=bluray-device=" .. mp.get_property("bluray-device", "")
    elseif effective_protocol == "cdda" then
        full_path = full_path .. " --opt=cdrom-device=" .. mp.get_property("cdrom-device", "")
    elseif effective_protocol == "dvb" then
        local dvb_program = mp.get_property("dvbin-prog", "")
        if dvb_program ~= "" then
            full_path = full_path .. " --opt=dvbin-prog=" .. dvb_program
        end
    elseif effective_protocol == "dvd" or effective_protocol == "dvdnav" then
        full_path = full_path .. " --opt=dvd-angle=" .. mp.get_property("dvd-angle", "1") .. ",dvd-device=" .. mp.get_property("dvd-device", "")
    end

    mp.msg.debug("logging file " .. full_path)
    if display then
        mp.osd_message("[memo] logging file " .. full_path)
    end

    -- format: <timestamp>,<title length>,<title>,<path>,<entry length>
    local entry = "hide,,," .. full_path

    if not mark_hidden then
        local playlist_pos = mp.get_property_number("playlist-pos") or -1
        local title = playlist_pos > -1 and mp.get_property("playlist/"..playlist_pos.."/title") or ""
        local title_length = #title
        local timestamp = os.time()

        entry = timestamp .. "," .. (title_length > 0 and title_length or "") .. "," .. title .. "," .. full_path
    elseif last_state then
        last_state.hidden_files[full_path] = last_state.current_page * 10000 + item_index
    end
    local entry_length = #entry

    history:seek("end")
    history:write(entry .. "," .. entry_length, "\n")
    history:flush()

    if dyn_menu then
        dyn_menu_update()
    end
end

function show_history(entries, next_page, prev_page, update, return_items, keep_state)
    if event_loop_exhausted then return end
    event_loop_exhausted = true

    local should_close = menu_shown and not prev_page and not next_page and not update
    if should_close then
        memo_close()
        if not return_items then
            return
        end
    end

    local max_digits_length = 4 + 2
    local retry_offset = 512
    local menu_items = {}
    local state = (prev_page or next_page or keep_state) and last_state or {
        known_dirs = {},
        known_files = {},
        hidden_files = {},
        existing_files = {},
        cursor = history:seek("end"),
        retry = 0,
        pages = {},
        current_page = 1,
        selected_index = 1
    }

    if update and not keep_state then
        state.pages = {}
    end

    if last_state then
        if prev_page then
            if state.current_page == 1 then return end
            state.current_page = state.current_page - 1
        elseif next_page then
            if state.cursor == 0 and not state.pages[state.current_page + 1] then return end
            if options.entries < 1 then return end
            state.current_page = state.current_page + 1
        end
    end

    last_state = state

    if state.pages[state.current_page] then
        menu_data = menu_json(state.pages[state.current_page], state.current_page, state.hidden_files)

        if uosc_available then
            uosc_update()
        else
            draw_menu()
        end
        return
    end

    local function find_path_prefix(path, path_prefixes)
        for _, prefix in ipairs(path_prefixes) do
            local start, stop = path:find(prefix.pattern, 1, prefix.plain)
            if start then
                return start, stop
            end
        end
    end

    -- all of these error cases can only happen if the user messes with the history file externally
    local function read_line()
        history:seek("set", state.cursor - max_digits_length)
        local tail = history:read(max_digits_length)
        if not tail then
            mp.msg.debug("error could not read entry length @ " .. state.cursor - max_digits_length)
            return
        end

        local entry_length_str, whitespace = tail:match("(%d+)(%s*)$")
        if not entry_length_str then
            mp.msg.debug("invalid entry length @ " .. state.cursor)
            state.cursor = math.max(state.cursor - retry_offset, 0)
            history:seek("set", state.cursor)
            local retry = history:read(retry_offset)
            if not retry then
                mp.msg.debug("retry failed @ " .. state.cursor)
                state.cursor = 0
                return
            end
            local last_valid = string.match(retry, ".*(%d+\n.*)")
            local offset = last_valid and #last_valid or retry_offset
            state.cursor = state.cursor + retry_offset - offset + 1
            if state.cursor == state.retry then
                mp.msg.debug("bailing")
                state.cursor = 0
                return
            end
            state.retry = state.cursor
            mp.msg.debug("retrying @ " .. state.cursor)
            return
        end

        local entry_length = tonumber(entry_length_str)
        state.cursor = state.cursor - entry_length - #entry_length_str - #whitespace - 1
        history:seek("set", state.cursor)

        local entry = history:read(entry_length)
        if not entry then
            mp.msg.debug("unreadable entry data @ " .. state.cursor)
            return
        end
        local timestamp_str, title_length_str, file_info = entry:match("([^,]*),(%d*),(.*)")
        if not timestamp_str then
            mp.msg.debug("invalid entry data @ " .. state.cursor)
            return
        end

        local timestamp = tonumber(timestamp_str)
        timestamp = timestamp and os.date(options.timestamp_format, timestamp) or timestamp_str

        local title_length = title_length_str ~= "" and tonumber(title_length_str) or 0
        local full_path = file_info:sub(title_length + 2)

        local display_path, save_path, effective_path, effective_protocol, is_remote, file_options = path_info(full_path)

        if state.hidden_files[effective_path] then
            return
        elseif timestamp_str == "hide" then
            state.hidden_files[effective_path] = state.current_page * 10000 + #menu_items + 1
            return
        end

        local cache_key = effective_path .. display_path .. (file_options or "")

        if options.hide_duplicates and state.known_files[cache_key] then
            return
        end

        if dir_menu and is_remote then
            return
        end

        if search_words and not options.use_titles then
            for _, word in ipairs(search_words) do
                if unaccent(display_path):lower():find(word, 1, true) == nil then
                    return
                end
            end
        end

        local dirname, basename

        if is_remote then
            state.existing_files[cache_key] = true
            state.known_files[cache_key] = true
        elseif options.hide_same_dir or dir_menu then
            dirname, basename = mp.utils.split_path(display_path)
            if dir_menu then
                if dirname == "." then return end
                local unix_dirname = dirname:gsub("\\", "/")
                local parent, _ = mp.utils.split_path(unix_dirname:sub(1, -2))
                local start, stop = find_path_prefix(parent, dir_menu_prefixes)
                if not start then
                    return
                end
                basename = unix_dirname:match("/(.-)/", stop)
                if basename == nil then return end
                start, stop = dirname:find(basename, stop, true)
                dirname = dirname:sub(1, stop + 1)
            end
            if state.known_dirs[dirname] then
                return
            end
            if dirname ~= "." then
                state.known_dirs[dirname] = true
            end
        end

        if options.hide_deleted and not (search_words and options.use_titles) then
            if state.known_files[cache_key] and not state.existing_files[cache_key] then
                return
            end
            if not state.known_files[cache_key] then
                local stat = mp.utils.file_info(effective_path)
                if stat then
                    state.existing_files[cache_key] = true
                elseif dir_menu then
                    state.known_files[cache_key] = true
                    local dir = mp.utils.split_path(effective_path)
                    if dir == "." then
                        return
                    end
                    stat = mp.utils.readdir(dir, "files")
                    if stat and next(stat) ~= nil then
                        full_path = dir
                    else
                        return
                    end
                else
                    state.known_files[cache_key] = true
                    return
                end
            end
        end

        local title = file_info:sub(1, title_length)
        if not options.use_titles then
            title = ""
        end

        if dir_menu then
            title = basename
        elseif title == "" then
            if is_remote then
                title = display_path
            else
                local effective_display_path = display_path
                if file_options then
                    effective_display_path = file_options
                end
                if not dirname then
                    dirname, basename = mp.utils.split_path(effective_display_path)
                end
                title = basename ~= "" and basename or display_path
                if file_options then
                    title = display_path .. " " .. title
                end
            end
        end

        title = title:gsub("\n", " ")

        if search_words and options.use_titles then
            for _, word in ipairs(search_words) do
                if unaccent(title):lower():find(word, 1, true) == nil then
                    return
                end
            end
        end

        if options.hide_deleted and (search_words and options.use_titles) then
            if state.known_files[cache_key] and not state.existing_files[cache_key] then
                return
            end
            if not state.known_files[cache_key] then
                local stat = mp.utils.file_info(effective_path)
                if stat then
                    state.existing_files[cache_key] = true
                elseif dir_menu then
                    state.known_files[cache_key] = true
                    local dir = mp.utils.split_path(effective_path)
                    if dir == "." then
                        return
                    end
                    stat = mp.utils.readdir(dir, "files")
                    if stat and next(stat) ~= nil then
                        full_path = dir
                    else
                        return
                    end
                else
                    state.known_files[cache_key] = true
                    return
                end
            end
        end

        if options.truncate_titles > 0 then
            local title_chars, title_width = utf8_table(title)
            if title_width > options.truncate_titles then
                local extension = string.match(title, "%.([^.][^.][^.]?[^.]?)$") or ""
                local extra = #extension + 4
                local title_sub, end_index = utf8_subwidth(title_chars, 1, options.truncate_titles - 3 - extra)
                local title_trim = title_sub:gsub("[] ._'()?![]+$", "")
                local around_extension = ""
                if title_trim == "" then
                    title_trim = utf8_subwidth(title_chars, 1, options.truncate_titles - 3)
                else
                    extra = extra + #title_sub - #title_trim
                    around_extension = utf8_subwidth_back(title_chars, extra)
                end
                if title_trim == "" then
                    title = utf8_subwidth(title_chars, 1, options.truncate_titles)
                else
                    title = title_trim .. "..." .. around_extension
                end
            end
        end

        state.known_files[cache_key] = true

        local command = {"loadfile", full_path, "replace"}

        if file_options then
            command[2] = display_path
            for _, arg in ipairs(loadfile_compat(file_options)) do
                table.insert(command, arg)
            end
        end

        table.insert(menu_items, {title = title, hint = timestamp, value = command, actions_place = "inside",
            actions = {
                {name = "memo_action_hide", icon = "visibility_off", label = "Hide from past logs (del)"},
                {name = "memo_action_append", icon = "playlist_add", label = "Add to playlist (shift+enter/click)"},
            }
        })

    end

    local item_count = -1
    local attempts = 0

    while #menu_items < entries do
        if state.cursor - max_digits_length <= 0 then
            break
        end

        if osd_update then
            local time = mp.get_time()
            if time > osd_update then
                draw_menu()
            end
        end

        if not return_items and (attempts > 0 or not (prev_page or next_page)) and attempts % options.entries == 0 and #menu_items ~= item_count then
            item_count = #menu_items
            local temp_items = {unpack(menu_items)}
            for i = 1, options.entries - item_count do
                table.insert(temp_items, {value = {"ignore"}, keep_open = true})
            end

            table.insert(temp_items, {title = "Loading...", value = {"ignore"}, italic = "true", muted = "true", icon = "spinner", keep_open = true})

            if next_page and state.current_page ~= 1 then
                table.insert(temp_items, {value = {"ignore"}, keep_open = true})
            end

            menu_data = menu_json(temp_items, state.current_page, state.hidden_files)

            if uosc_available then
                uosc_update()
                menu_shown = true
            else
                osd_update = mp.get_time() + 0.1
            end
        end

        read_line()

        attempts = attempts + 1
    end

    if return_items then
        return menu_items
    end

    if options.pagination then
        if #menu_items > 0 and state.cursor - max_digits_length > 0 then
            table.insert(menu_items, {title = "Older entries", value = {"script-binding", "memo-next"}, italic = "true", muted = "true", icon = "navigate_next", keep_open = true})
        end
        if state.current_page ~= 1 then
            table.insert(menu_items, {title = "Newer entries", value = {"script-binding", "memo-prev"}, italic = "true", muted = "true", icon = "navigate_before", keep_open = true})
        end
    end

    menu_data = menu_json(menu_items, state.current_page, state.hidden_files)
    state.pages[state.current_page] = menu_items
    last_state = state

    if uosc_available then
        uosc_update()
    else
        draw_menu()
    end

    menu_shown = true
end

function file_load()
    if options.enabled then
        write_history()
    elseif dyn_menu then
        dyn_menu_update()
    end

    if menu_shown and last_state and last_state.current_page == 1 then
        show_history(options.entries, false, false, true)
    end
end

function idle()
    event_loop_exhausted = false
    if osd_update then
        osd_update = nil
        osd:update()
    end
end

mp.register_script_message("uosc-version", function(version)
    local function semver_comp(v1, v2)
        local v1_iterator = v1:gmatch("%d+")
        local v2_iterator = v2:gmatch("%d+")
        for v2_num_str in v2_iterator do
            local v1_num_str = v1_iterator()
            if not v1_num_str then return true end
            local v1_num = tonumber(v1_num_str)
            local v2_num = tonumber(v2_num_str)
            if v1_num < v2_num then return true end
            if v1_num > v2_num then return false end
        end
        return false
    end

    local min_version = "5.0.0"
    uosc_available = not semver_comp(version, min_version)
end)

mp.register_script_message("menu-ready", function(client_name)
    dyn_menu = client_name
    dyn_menu_update()
end)

function memo_close()
    menu_shown = false
    palette = false
    if uosc_available then
        mp.commandv("script-message-to", "uosc", "close-menu", "memo-history")
    else
        close_menu()
    end
end

function memo_clear()
    last_state = nil
    search_words = nil
    search_query = nil
    menu_shown = false
    palette = false
    dir_menu = false
end

function memo_prev()
    show_history(options.entries, false, true)
end

function memo_next()
    show_history(options.entries, true)
end

function memo_search(...)
    -- close REPL
    mp.commandv("keypress", "ESC")

    local words = {...}
    if #words > 0 then
        query = table.concat(words, " ")

        if query ~= "" then
            for i, word in ipairs(words) do
                words[i] = unaccent(word):lower()
            end
            search_query = query
            search_words = words
        else
            search_query = nil
            search_words = nil
        end
    end

    show_history(options.entries, false)
end

function parse_query_parts(query)
    local pos, len, parts = query:find("%S"), query:len(), {}
    while pos and pos <= len do
        local first_char, part, pos_end = query:sub(pos, pos)
        if first_char == '"' or first_char == "'" then
            pos_end = query:find(first_char, pos + 1, true)
            if not pos_end or pos_end ~= len and not query:find("^%s", pos_end + 1) then
                parts[#parts + 1] = query:sub(pos + 1)
                return parts
            end
            part = query:sub(pos + 1, pos_end - 1)
        else
            pos_end = query:find("%S%s", pos) or len
            part = query:sub(pos, pos_end)
        end
        parts[#parts + 1] = part
        pos = query:find("%S", pos_end + 2)
    end
    return parts
end

function memo_search_uosc(query)
    if query ~= "" then
        search_query = query
        search_words = parse_query_parts(unaccent(query):lower())
    else
        search_query = nil
        search_words = nil
    end
    event_loop_exhausted = false
    show_history(options.entries, false, false, menu_shown and last_state)
end

-- update menu in mpv-menu-plugin
function dyn_menu_update()
    search_words = nil
    event_loop_exhausted = false
    local items = show_history(options.entries, false, false, false, true)
    event_loop_exhausted = false

    local menu = {
        type = "submenu",
        submenu = {}
    }

    if not options.enabled then
        menu.submenu = {{title = "Add current file to memo", cmd = "script-binding memo-log"}, {type = "separator"}}
    end

    if items and #items > 0 then
        local full_path, display_path, save_path, effective_path, effective_protocol, is_remote, file_options = get_full_path()
        for _, item in ipairs(items) do
            local cmd = string.format("%s \"%s\" %s %s %s",
                item.value[1],
                item.value[2]:gsub("\\", "\\\\"):gsub("\"", "\\\""),
                item.value[3],
                (item.value[4] or ""):gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("^(.+)$", "\"%1\""),
                (item.value[5] or ""):gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("^(.+)$", "\"%1\"")
            )
            menu.submenu[#menu.submenu + 1] = {
                title = item.title,
                cmd = cmd,
                shortcut = item.hint,
                state = full_path == item.value[2] and {"checked"} or {}
            }
        end
        if last_state.cursor > 0 then
            menu.submenu[#menu.submenu + 1] = {title = "...", cmd = "script-binding memo-next"}
        end
    else
        menu.submenu[#menu.submenu + 1] = {
            title = "No entries",
            state = {"disabled"}
        }
    end

    mp.commandv("script-message-to", dyn_menu, "update", "memo", mp.utils.format_json(menu))
end

function process_menu_event(event)
    if not event then return end

    if event.type == "activate" or event.type == "key" then

        if event.action == "memo_action_hide" or event.key == "del" then
            local item = event.selected_item and event.selected_item or event
            if item.value[1] ~= "loadfile" then return end
            write_history(false, item.value[2], true, item.index)
            -- TODO: shift over page data to fill out options.entries and continue reading if required to fill a page? have to move alread-fetched entry hiding out of menu_json()
            show_history(options.entries, false, false, true, false, true)
        elseif event.action == "memo_action_append" or (event.type == "activate" and event.modifiers == "shift") then
            local item = event.selected_item and event.selected_item or event
            if item.value[1] ~= "loadfile" then return end
            -- bail if file is already in playlist
            local playlist = mp.get_property_native("playlist", {})
            for i = 1, #playlist do
                local playlist_file = playlist[i].filename
                local display_path, save_path, effective_path, effective_protocol, is_remote, file_options = path_info(playlist_file)
                if not is_remote then
                    playlist_file = normalize(save_path)
                end
                if item.value[2] == playlist_file then
                    return
                end
            end
            item.value[3] = "append-play"
            mp.commandv(unpack(event.value))
            local title
            if last_state then
                title = last_state.pages[last_state.current_page][item.index].title
            else
                dirname, basename = mp.utils.split_path(item.value[2])
                title = basename ~= "" and basename or item.value[2]
            end
            mp.commandv("show-text", "Added to playlist: " .. title, 3000)
        elseif event.value then
            mp.commandv(unpack(event.value))
            if not event.keep_open then
                memo_close()
            end
        end
    end
end

mp.register_script_message("memo-clear", memo_clear)
mp.register_script_message("memo-search:", memo_search)
mp.register_script_message("memo-search-uosc:", memo_search_uosc)

mp.add_key_binding(nil, "memo-next", memo_next)
mp.add_key_binding(nil, "memo-prev", memo_prev)
mp.add_key_binding(nil, "memo-log", function()
    write_history(true)

    if menu_shown and last_state and last_state.current_page == 1 then
        show_history(options.entries, false, false, true)
    end
end)
mp.add_key_binding(nil, "memo-last", function()
    if event_loop_exhausted then return end

    local items
    if last_state and last_state.current_page == 1 and options.hide_duplicates and options.hide_deleted and options.entries >= 2 and not search_words and not dir_menu then
        -- menu is open and we for sure have everything we need
        items = last_state.pages[1]
        last_state = nil
        show_history(0, false, false, false, true)
    else
        -- menu is closed or we may not have everything
        local options_bak = shallow_copy(options)
        options.pagination = false
        options.hide_duplicates = true
        options.hide_deleted = true
        last_state = nil
        search_words = nil
        dir_menu = false
        items = show_history(2, false, false, false, true)
        options = options_bak
    end
    if items then
        local item
        local full_path, display_path, save_path, effective_path, effective_protocol, is_remote, file_options = get_full_path()
        if #items >= 1 and not items[1].keep_open then
            if items[1].value[2] ~= full_path then
                item = items[1]
            elseif #items >= 2 and not items[2].keep_open and items[2].value[2] ~= full_path then
                item = items[2]
            end
        end

        if item then
            mp.commandv(unpack(item.value))
            return
        end
    end
    mp.osd_message("[memo] no recent files to open")
end)
mp.add_key_binding(nil, "memo-search", function()
    if uosc_available then
        palette = true
        show_history(options.entries, false, false, true)
        return
    end
    if menu_shown then
        memo_close()
    end
    mp.commandv("script-message-to", "console", "type", "script-message memo-search: ")
end)
mp.add_key_binding("h", "memo-history", function()
    if event_loop_exhausted then return end
    last_state = nil
    search_words = nil
    dir_menu = false
    show_history(options.entries, false)
end)
mp.register_script_message("memo-dirs", function(path_prefixes)
    if event_loop_exhausted then return end
    last_state = nil
    search_words = nil
    dir_menu = true
    if path_prefixes then
        dir_menu_prefixes = parse_path_prefixes(path_prefixes)
    else
        dir_menu_prefixes = options.path_prefixes
    end
    show_history(options.entries, false)
end)

mp.register_script_message("menu-event", function(json)
    local event = mp.utils.parse_json(json)
    process_menu_event(event)
end)

mp.register_event("file-loaded", file_load)
mp.register_idle(idle)


-------------------------------
-------------------------------
--------- slapdash ------------ -- MARK: slapdash start
-------------------------------
-------------------------------


--local pl_menu_data = nil
local pl_history
local pl_history_path
local last_entrie_index = 0

local function custom_uosc_update(menu_data)
    local json = mp.utils.format_json(menu_data) or "{}"
    mp.commandv("script-message-to", "uosc", menu_shown and "update-menu" or "open-menu", json)
end

-- MARK: is_playlist
local function is_playlist(path)
    if not path or path == "" then return false end
    local result = path:match("%.%w+$") == options.ext
    mp.msg.trace("is a playlist=", result, " ", options.ext, " not found")
    return result
end



-- MARK: refresh
local function refresh_history_files(file_path, history_handle)
    history_handle:close()
    history_handle = io.open(file_path, "a+b")
    history_handle:setvbuf("full")
    return history_handle
end


-- MARK: create_dir
local function create_directory_if_missing(path)
    local dir = mp.command_native({ "expand-path", path })
    -- Split path into components
    local components = {}
    for component in dir:gmatch("[^/\\]+") do
        table.insert(components, component)
    end
   
    -- Build path incrementally and create directories as needed
    local current_path = ""
    if dir:match("^%a:") then  -- Check if path starts with drive letter
        current_path = components[1] .. "\\"  -- Use backslash for Windows drive
        table.remove(components, 1)  -- Remove drive letter from components
    elseif dir:sub(1,1) == "/" then
        current_path = "/"
    end
   
    for _, component in ipairs(components) do
        -- Always use backslash for Windows paths
        current_path = current_path .. "\\" .. component
        local res = mp.utils.file_info(current_path)
       
        if not res then
            mp.msg.debug("Creating directory: " .. current_path)
            if current_path:match("^%a:") then
                -- create the directory for windows
                os.execute(string.format('mkdir "%s"', current_path))
            else
                -- create the directory for linux
                os.execute(string.format('mkdir -p "%s"', current_path))
            end
        else
            print("current_path ", current_path)
        end
    end
end



-- MARK: split path
local function trisect_path(str_path)
    if  not str_path then return end
    -- Returns the Parent Path, Filename without Extension, and Extension
    local parent, filename_with_ext = mp.utils.split_path(str_path)
    local filename, extension = filename_with_ext:match("(.+)%.(.+)$")    
    return parent, filename, extension
end

-- Move path manipulation into a dedicated function
    -- MARK: normalize_pl
local function normalize_playlist_path(path, name, ext)
    local tmp_path, tmp_name, tmp_ext = trisect_path(path)

    -- if there is nothing in path than something is wrong
    if not tmp_path then path = options.playlist_path end
    if not name and tmp_name then name = tmp_name end
    if not ext and tmp_ext then ext = tmp_ext end

    if not ext then ext = options.ext end
    if not name then name = "default" end

    local basename = name
    if not is_playlist(basename) then
        basename = name .. ext   
    end

    local full_path = mp.utils.join_path(path, basename)
    local expanded_full_path = mp.command_native({ "expand-path", full_path })
    return normalize(expanded_full_path), basename, name
end
        

-- Helper function for safe file operations
    -- MARK: with_file
local function with_file(path, mode, func)
    local file, err = io.open(path, mode)

    if not file then 
        mp.msg.error("Could not open file: " .. (err or "unknown error"))
        return nil, err 
    end

    local success, result = pcall(func, file)

    file:close()
    if not success then
        mp.msg.error("File operation failed: " .. result)
        return nil, result
    end

    return result
end

-- Function to read all lines from a file
-- MARK: read_lines
local function read_lines(file_path)
    local lines = {}
    local result = with_file(file_path, "r", function(file)
        for line in file:lines() do
            table.insert(lines, line)
        end
        return lines
    end)
    return result
end

-- Function to write lines to a file 
-- MARK: write_lines
local function write_lines(file_path, lines)
    return with_file(file_path, "w", function(file)
        for _, line in ipairs(lines) do
            file:write(line, "\n")
        end
        return true
    end)
end

-- MARK: process_lines
---Process history file lines and handle duplicates/hidden entries
---@param lines table Array of history file lines
---@param retention_limit number Number of entries to keep (0 = keep all)
---@param is_pl boolean Whether processing playlist entries
---@return table processed_lines Filtered history lines
---@return table? playlist_paths List of playlist paths (if is_pl=true)
---@return table? files_to_delete List of files marked for deletion
---@return table? processed_pairs Title/path pairs for playlists
local function process_lines(history_lines, retention_limit)
    -- Input validation
    if not history_lines or type(history_lines) ~= "table" then
        mp.msg.error("process_lines: No valid lines provided")
        return {}, nil, nil, nil
    end

    local state = {
        unique_paths  = {},
        filtered_entries  = {},
        playlist_paths = {},
        deletion_queue = {},
        entry_pairs = {},
        entry_count = 0
    }

    local function parse_line(index)
        local line = history_lines[index]
        if not line or line:match("^%s*$") or #line < 5 then
            mp.msg.warn("process_lines: Malformed or empty line at index %d", index)
            return false
        end

        -- Parse line components
        local time_hide, title_length, title, path, length = line:match("([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)")
        if not path then
            mp.msg.warn(string.format("process_lines: Malformed path at index %d", index))
            return false
        end

        local lower_path = path:lower()
        if state.unique_paths[lower_path] then
            return true
        end
        state.unique_paths[lower_path] = true

        -- Handle playlist-specific processing
        if is_playlist(path) then
            if time_hide == "hide" and options.delte_pl_file then
                table.insert(state.deletion_queue, path)
            else
                table.insert(state.filtered_entries , 1, line)
            end
            table.insert(state.playlist_paths, path)
            table.insert(state.entry_pairs, {title = title, path = path})
        -- Handle regular history entries
        elseif retention_limit == 0 or state.entry_count < retention_limit then
            if time_hide ~= "hide" and options.remove_hidden then
                table.insert(state.filtered_entries , 1, line)
                state.entry_count = state.entry_count + 1
            end
        end

        return true
    end

    local continue = true
    -- Process lines in reverse for newest-first ordering
    for index = #history_lines, 1, -1 do
        continue = parse_line(index)
        if not continue then
            mp.msg.error("Some error Occured while processing history file")
            break
        end
    end

    return state.filtered_entries , state.playlist_paths, state.deletion_queue, state.entry_pairs
end




-- MARK: get_playlists
local function get_playlists() --TODO: dont repull. return saved

    -- Read current history to check what files are already logged
    local all_lines = read_lines(pl_history_path)
    if not all_lines then return end


    -- Build lookup table of paths already in history
    local _, unique_paths , _, pairs = process_lines(all_lines, 0)



    return unique_paths , pairs
end

local function get_missing_playlists()
    local dir = mp.command_native({"expand-path", options.playlist_path})
    local files = mp.utils.readdir(dir,'files')

    mp.msg.debug("Processing playlists from dir: " .. options.playlist_path)

    local unique_paths , _ = get_playlists()
    local not_seen = {}
    if files == nil then files = {} end
    --local matched = false
    for i, file in ipairs(files) do
        local full_path = ""
        
        if is_playlist(file) then
            for _, path in ipairs(unique_paths ) do
                full_path = path

                if path:match(file) then
                    full_path = nil
                    break
                end
            end
        
            if is_playlist(full_path) or #unique_paths  <= 0   then
                local new_path = mp.utils.join_path(dir, file)
                new_path = normalize(new_path)
                table.insert(not_seen, new_path)
            end
        end
    end
  
    return not_seen
end
-- MARK: delete_entry
local function delete_entry(path, history_path)
    mp.msg.info('delete memo entry: ' .. path)
    local temp_path = history_path .. ".tmp"

    -- Safe file operation using with_file helper
    local success = with_file(history_path, "r", function(memo_history)
        return with_file(temp_path, "w", function(temp_file)
            for line in memo_history:lines() do
                if not line:find(path, 1, true) then
                    temp_file:write(line .. "\n")
                end
            end
            return true
        end)
    end)

    if success then
        os.remove(history_path)
        os.rename(temp_path, history_path)
        
        -- close and open history to load changed data
        history = refresh_history_files(history_path, history)
        pl_history = refresh_history_files(pl_history_path, pl_history)

        -- Provide user feedback TODO: printing wrong path part
        local a, b = mp.utils.split_path(path)
        mp.osd_message(string.format("Deleted Memo entry: %s", b), 3)
        
        return true
        
    else
        mp.msg.error("Failed to delete entry")
        mp.osd_message("Failed to delete entry", 3)
        return false
    end
end

if options.show_save then
    options.show_save = nil
end

--# Adapted parts from [https://github.com/CogentRedTester/mpv-scripts/blob/master/keep-session.lua]
--# Copyright (c) [2020] [Oscar Manglaras]
--# MIT License

-- MARK: Init
--init----------------------------------------------------------------------------
--sets the default session file to the watch_later directory or ~~state/watch_later/playlist
if #options.playlist_path <= 3 or options.playlist_path == "default" then
    if options.playlist_path == "default" then
        mp.msg.verbose("Using default path to save playlists (whereMPVsavesyourstuff/watch_later/playlist/)")
    else
        mp.msg.verbose("playlist_path not missing or not valid, using default (whereMPVsavesyourstuff/watch_later/playlist/)")
    end
    
    options.playlist_path = "~~state/watch_later/playlist/"
end


-- Expands the playlist path specified in the options and normalizes it.
-- This ensures the path is valid and can be used to create the necessary directories.
local expanded_playlist_path = mp.command_native({"expand-path", options.playlist_path})
local normalized_playlist_path = normalize(expanded_playlist_path)

-- ensure the save location exist and create if not
create_directory_if_missing(normalized_playlist_path)  

pl_history_path = mp.utils.join_path(normalized_playlist_path, "pl-history.log")

-- open plhistory file
pl_history = io.open(pl_history_path, "a+b")
pl_history:setvbuf("full")

-- make sure ext is vaild
options.ext = " "
--options.ext = (options.ext and #options.ext > 0) and (options.ext:match("^%.") and options.ext or "." .. options.ext) or ".pls"
local function sanitize_extension(ext)
    if not ext or #ext == 0 then return ".pls" end
    -- Remove spaces, control chars, and common invalid filename chars
    ext = ext:gsub('[%s%c%\\/%|%:%*%?%"%<%>]+', "")
    -- Keep only alphanumeric and few valid special chars
    ext = ext:match("[%w%.%-_]+") or "pls"
    -- Ensure single dot at start
    return (ext:match("^%.") and ext or "." .. ext)
end

options.ext = sanitize_extension(options.ext)
print("ext:->", options.ext)  
-- button for uosc ribbon
mp.commandv('script-message-to', 'uosc', 'set-button', 'memo-playlist', mp.utils.format_json({
    icon = options.icon,
    active = false,
    tooltip = options.tooltip,
    command = 'script-binding memo-playlist',
  }))

--init-end----------------------------------------------------------------------------
-- MARK: custom_write
local function custom_write_history(display, full_path, mark_hidden, item_index)

    -- title = filename without ext
    local _, title, _ = trisect_path(full_path)

    -- TODO: catch options.ext in filename? why? fuck them
    if not title then mp.msg.error("no title found, aborting") return end

    mp.msg.debug("logging playlist " .. full_path)
    if display then
        mp.osd_message("[memo] logging playlist " .. full_path)
    end

    local entry = "hide,,," .. full_path

    if not mark_hidden then
        entry = string.format("%d,%s,%s,%s",
        os.time(),
        #title > 0 and #title or "",
        title,
        full_path
        )
    elseif last_state then
        last_state.hidden_files[full_path] = last_state.current_page * 10000 + item_index
    end

    pl_history:seek("end")
    pl_history:write(string.format("%s,%d\n", entry, #entry))
    pl_history:flush()

    if dyn_menu then dyn_menu_update() end
end

-- MARK: Save playlist
---Saves the current playlist in PLS format with position information
---@param playlist_name string? Optional name for the playlist
---@param playlist_path string? Optional full path for the playlist
---@return boolean success Whether the save operation succeeded
local function save_playlist(playlist_name, playlist_path)
    -- Normalize paths and get sanitized name
    local full_path, basename, _ = normalize_playlist_path(playlist_path, playlist_name)
    
    -- Get current playlist state
    local playlist_data = mp.get_property_native('playlist')
    if not playlist_data or #playlist_data == 0 then
        mp.msg.debug('No playlist entries to save')
        return false
    end

    -- Capture position info for resume
    local curr_pos = {
        index = mp.get_property_number('playlist-pos'),
        time  = mp.get_property_number('time-pos')
    }
    local position_str = curr_pos.time and 
                        string.format("%d:%s", curr_pos.index, curr_pos.time) or 
                        tostring(curr_pos.index)

    -- Write playlist with error handling
    local success, err = with_file(full_path, "w", function(file)
        local working_dir = mp.get_property('working-directory')
        
        -- Write PLS header and position
        file:write("[playlist]\n", position_str, "\n")
        
        -- Process and write entries
        for i, entry in ipairs(playlist_data) do
            local path = entry.filename
            -- Expand local paths but preserve URLs
            if not path:match("^%a+://") then
                path = mp.utils.join_path(working_dir, path)
                mp.msg.trace('Expanded path: ' .. path)
            end
            file:write(string.format("File%d=%s\n", i, path))
        end

        -- Write PLS footer
        file:write(string.format("NumberOfEntries=%d\nVersion=2\n", #playlist_data))
        return true
    end)

    -- Handle results
    if success then
        mp.msg.verbose('Saved playlist to: ' .. full_path)
        mp.osd_message(string.format("Saved playlist as: %s", basename), 3)

        -- Log entrie in pl_history.log
        custom_write_history(false, full_path)
    else
        mp.msg.error(string.format("Failed to save playlist: %s", err or "unknown error"))
        return false
    end

    return true
end

-- MARK: autosave
-- save playlist on mpv close
local function autosave()
    if options.auto_save then
        if save_playlist("last_session") then
            mp.msg.debug("Autosaved Session")
        else
            mp.msg.error("Autosave failed")
        end
    end
end

-- either 
-- MARK: Load
local function load_playlist(name, path)
    local file = nil
    if name then
        file = mp.command_native({"expand-path", options.playlist_path .. name .. options.ext})
        if not file then
            mp.msg.error("Could not expand path: " .. (file or "nil"))
            return
        end
    elseif path then
        file = path
    else
        mp.msg.debug("No valid name or path, Aborting loading Playlist")
    end
    -- Check if file exists and load playlist
    local success, time_pos = with_file(file, "r", function(f)
        mp.commandv("loadlist", file, "replace")
        mp.msg.verbose('Playlist loaded from: ' .. file)
        if options.load_position then
            -- Check playlist format and get position
            local first_line = f:read()
            if first_line ~= "[playlist]" then
                mp.msg.verbose('File is not in correct format, cancelling load')
                return false
            end

            local second_line = f:read()
            local pos, time_pos = second_line:match("(%d+):([%d%.]+)")
            if pos then
                mp.msg.verbose("restoring playlist position", pos)
                mp.set_property_number('playlist-current-pos', pos)
            end
        end
        return true, time_pos
    end)

    if not success then
        mp.msg.error("Failed to load playlist or position: " .. file)
        mp.osd_message("Failed to load playlist or position: " .. file, 3)
    end

end

-- autload last session
if options.auto_load then
    local playlist = mp.get_property_native('playlist')
    -- only autoload if mpv was started in idle
    if #playlist == 0 then
        load_playlist("last_session")
    end
end

-- MARK: pl_operation
---Handles playlist-related user input actions (save/delete)
---@param action string The action to perform ('save_as' or 'delete')
local function handle_playlist_operation(action)
    -- Validate input
    if not action then
        mp.msg.error("pl_ops: No action specified")
        return false
    end

    local valid_actions = { save_as = true, delete = true }
    if not valid_actions[action] then
        mp.msg.error(string.format("pl_ops: Invalid action '%s'", action))
        return false
    end

    -- Debug state
    mp.msg.debug(string.format("pl_ops: Starting '%s' operation", action))

    -- Temporarily disable uosc controls if available
    if uosc_available then
        mp.commandv('script-message-to', 'uosc', 'disable-elements', mp.get_script_name(), 'controls')
    end

    -- Get playlist data
    local playlists, pl_pairs = get_playlists()
    if not pl_pairs then
        mp.msg.error("pl_ops: Failed to fetch playlist data")
        return false
    end

    -- Prepare playlist titles for selection
    local pl_titles = {}
    for _, entry in ipairs(pl_pairs) do
        if #entry.title > 0 then
            table.insert(pl_titles, entry.title)
        end
    end

    if #pl_titles == 0 then
        mp.msg.info("pl_ops: No playlists available")
        mp.osd_message("No playlists available", 3)
        return false
    end

    -- Input handling state
    local state = {
        aborted = false,
        selected_path = nil,
        selected_name = nil,
    }

    -- Configure input selection
    local input = require 'mp.input'

    input.select({

        prompt = "Select playlist:",
        items = pl_titles,
        default_item = 1,
        
        edited = function(input_str)
            -- Handle abort commands
            local abort_commands = {
                exit = 4,
                qqq = 3
            }
            for cmd, len in pairs(abort_commands) do
                if #input_str >= len and input_str:sub(-len) == cmd then
                    mp.msg.info("pl_ops: User aborted via command: " .. cmd)
                    state.aborted = true
                    input.terminate()
                    return
                end
            end
        end,

        submit = function(selected_index)
            if selected_index and pl_pairs[selected_index] then
                local entry = pl_pairs[selected_index]
                state.selected_path = entry.path
                state.selected_name = entry.title
                state.selected_index = selected_index
            else 
                state.aborted = true
            end

            if action == "save_as" and state.selected_index and not state.aborted then
                print("Saving playlist as: " .. state.selected_name, selected_index, state.selected_path)
                mp.msg.debug(string.format("pl_ops: Saving playlist as: %s", state.selected_name))
                save_playlist(state.selected_name)
                state.aborted = true
            end

            if action == "delete" and not state.aborted then
                mp.msg.debug(string.format("pl_ops: Selected for deletion - Name: %s, Path: %s", 
                    state.selected_name, state.selected_path))

                -- Handle playlist deletion
                if options.delete_playlist_entries then
                    mp.msg.debug("pl_ops: Deleting playlist entry")
                    delete_entry(state.selected_name, pl_history_path)
                else
                    mp.msg.debug("pl_ops: Hiding playlist entry")
                    custom_write_history(false, state.selected_path, true)
                end

                -- Hide in main history
                write_history(false, state.selected_path, true)

                -- Delete physical file if enabled
                if options.delte_pl_file and is_playlist(state.selected_path) then
                    local success, err = os.remove(state.selected_path)
                    if success then
                        mp.msg.info(string.format("pl_ops: Removed playlist file: %s", state.selected_path))
                    else
                        mp.msg.error(string.format("pl_ops: Failed to remove playlist file: %s (Error: %s)", 
                            state.selected_path, err or "unknown"))
                    end
                end

                state.aborted = true
            end
        end,

        -- input.select ignores submit if input_string is not in items.
        -- TODO: maybe do a seperate input for doing a new save. Like the default item is open an input Dialog
            -- where a new name can be input. Would be less jank but more work to save new playlists. Maybe even a seperate
            -- function. ctrl+shift+s = input.select and ctrl+s = input.get(table).
            -- trl+shift+s -> selecting "new playlist" -> input in input.get  
        -- TODO: catch esc key press?
        closed = function(input_name, test)
            -- Handle save_as action when not aborted
            if not state.aborted and action == "save_as" and input_name and #input_name > 0 then
                mp.msg.debug(string.format("pl_ops: Saving playlist as: %s", input_name))
                input_name = input_name:match("^%s*(.-)%s*$")
                save_playlist(input_name)
            else
                mp.msg.debug("pl_ops: Closing input selection")
            end

            -- Restore uosc controls
            if uosc_available then
                mp.commandv('script-message-to', 'uosc', 'disable-elements', mp.get_script_name(), '')
            end
        end,
    })

    return true
end



-- MARK: modify menu_data
local function modify_menu_data(search)
    --mp.msg.debug("menu", mp.utils.format_json(menu_data))
    local title = menu_data['title']
    local page_number = title:match(" - Page (%d+)")
    menu_data['title'] = page_number and 'History (playlist) - Page ' .. page_number or 'History (playlist)'
    menu_data['on_search'][3] = "memo-custom-search-uosc:" 

    -- breaks search
    --menu_data['id'] = 'playlist_history'



    local newer_exists = false
    local older_exists = false
    for i, item in ipairs(menu_data.items) do
        if item.title == 'Newer entries' then
            newer_exists = true
            --item.value[2] = "custom_memo_prev"
        end
        if item.title == 'Older entries' then
            older_exists = true
            --item.value[2] = "custom_memo_next"
        end
        --print(mp.utils.format_json(item))   
        if item.actions then
            -- Check if the action already exists to avoid duplicates
            local action_exists = false


            for _, action in ipairs(item.actions) do
                if action.name == 'memo_action_saveto' then
                    action_exists = true
                    --break
                end
            end
            if not action_exists then
                table.insert(item.actions, {name = 'memo_action_saveto', icon = 'save', label = 'Save playlist' .. ' (alt+enter/click)'})
            end
        end
    end

    if last_entrie_index < 0 then
        -- newer or older = false means there is only one entry for pagination and that will be the last
        if not newer_exists or not older_exists then
            last_entrie_index = #menu_data.items
        -- -1 means older was pressed previously -2 means newer was pressed previously
        else
            last_entrie_index = #menu_data.items + last_entrie_index + 1 -- +1 to get second to last and last
        end
    end

    menu_data['selected_index'] = last_entrie_index
    menu_data['callback'][2] = 'playlist-event'


    -- combats duplicate entries on symlink or changing working directory. As far memo is concerned c:\path\to\mpc\portable_config\playlistfile and 
    -- c:\path\to\mpc\portable_config\playlistfile are different files and get different entries. here we remove these "duplicate" entries
    if options.use_relative_path then
        --print("menu_data", mp.utils.format_json(menu_data))
        local unique_paths  = {}
        local i = 1
        while i <= #menu_data.items do
            local item = menu_data.items[i]
            if item.value[1] == 'loadfile' then
                local _, basename = mp.utils.split_path(item.value[2])
                local full_path = mp.utils.join_path(normalized_playlist_path, basename)
                
                if unique_paths [full_path] then
                    table.remove(menu_data.items, i)
                else
                    unique_paths [full_path] = true
                    i = i + 1
                end
            else
                i = i + 1
            end
        end
        --print("menu_data", mp.utils.format_json(menu_data))    end
    end
end

-- todo: memo_search_uosc
-- MARK: show playlist
function show_playlist(indirect, next, prev, search, hide)
    if not indirect then
        memo_close()
    end

    -- dunno
    if event_loop_exhausted then return end

    local should_update = true
    local tmp_options = shallow_copy(options)
    local tmp_history = history
    
    -- TODO: Do we need this? probably not since this is for uosc only. needed for paginnation and entries.
    -- since we don't have access to vanilla menu, we can't manipulate menu_data on page turn. Page turn on uosc
    -- can be manipulated because we inject our own event handler for uosc playlist menus.
    if not uosc_available then
        search_words = {options.ext}
        options.use_titles = false
        options.pagination = false
        options.entries = 99
    end

    options.hide_duplicates = true
    options.hide_same_dir = false
    --options.pagination = true 
    --options.entries = 3
    history = pl_history


    if next or prev then
        local items = menu_data.items
        local last_item = items[#items]
        local second_last_item = items[#items - 1]
        should_update = false
        
        -- there is no need to update the menu on the last page and key right or first page and key left
        should_update = (prev and last_item.value[2] == "memo-prev") or
                             (next and last_item.value[2] == "memo-next") or
                             (second_last_item and (second_last_item.value[2] == "memo-next" or second_last_item.value[2] == "memo-prev"))
        if should_update then
            show_history(options.entries, next, prev, false, false, true)
        end
    elseif hide then
        -- original show_history(options.entries, false, false, true, false, true)
        show_history(options.entries, false, false, true, false, true)
    elseif search then
        show_history(options.entries, false, false, true, false, false)
    else
        show_history(options.entries)
    end


    if should_update and uosc_available then
        modify_menu_data()
        uosc_update()
    end


    search_words = nil
    options = tmp_options
    history = tmp_history
end

-- MARK: custom_search
local function memo_custom_search_uosc(query)
    if query ~= "" then
        search_query = query
        search_words = parse_query_parts(unaccent(query):lower())
    else
        search_query = nil
        search_words = nil
    end
    event_loop_exhausted = false
    show_playlist(true, false, false, "search")
end

-- MARK: Script msg
-- shows normal history but filtered for the extention (.pls)
mp.add_key_binding('g', 'memo-playlist', show_playlist)
mp.register_script_message('memo-load', load_playlist)
mp.register_script_message('memo-save', save_playlist)
mp.register_script_message('memo-plops', handle_playlist_operation)
mp.register_script_message("memo-custom-search-uosc:", memo_custom_search_uosc)
mp.register_event('shutdown', autosave)



-- MARK: menu_event
mp.register_script_message("playlist-event", function(json)
    -- hijacks the menu event, check if our action is triggerd , if not proceed to continue with normal memo flow.
    local event = mp.utils.parse_json(json)

    last_entrie_index = event.index or 1 --or event.selected_item.index
    if event.type == "activate" or event.type == "key" then
        -- if pagination entries are pressed, pretend it was the left or right key
        if event.value then 
            if event.value[2] == 'memo-next' then 
                event.key = 'right' 
                last_entrie_index = -2
            elseif event.value[2] == 'memo-prev' then 
                event.key = 'left' 
                last_entrie_index = -1
            end 
        end

        -- go through pages with left or right keys
        if options.pagination and (event.key == 'right' or event.key == 'left') then
            local right = (event.key == 'right')
            show_playlist(true, right, not right)
            --return
        --end
        

        elseif event.action == "memo_action_saveto" or event.key == "alt" then
            local item = event.selected_item and event.selected_item or event
            --mp.commandv("script-message-to", script_name, "memo-save", "", item.value[2])
            save_playlist(item.value[2])
            memo_close()

        elseif event.action == "memo_action_hide" or event.key == "del" then
                local item = event.selected_item and event.selected_item or event
                if item.value[1] ~= "loadfile" then return end

                custom_write_history(false, item.value[2], true, item.index)
                memo_close()
                show_playlist(false, false, false, false, true)
                
                

        elseif event.value then
            mp.commandv(unpack(event.value))
            if not event.keep_open then
                memo_close()
            end  
        else
            mp.msg.warn("Somthing went wrong, unknown action:", event.action)
        end
    end
end)

-- Key binding function for memo cleanup
-- MARK:cleanup
-- Handle cleanup operations for history files
local function process_cleanup(file_path, retention_limit, as_playlist)
    local lines = read_lines(file_path)
    if not lines then return end

    local processed_lines, _, files_to_delete = process_lines(lines, retention_limit)
    
    -- Delete marked playlist files if enabled
    if as_playlist and files_to_delete and options.delte_pl_file then
        for _, path in ipairs(files_to_delete) do
            if is_playlist(path) then -- doublechecking it is a playlist
                os.remove(path)
            end
        end
    end

    -- Write processed lines to temp file and replace original
    local temp_path = file_path .. ".tmp"
    write_lines(temp_path, processed_lines)
    os.remove(file_path)
    os.rename(temp_path, file_path)

    return processed_lines, lines
end

-- Register cleanup command handler
mp.register_script_message("memo-cleanup", function(retention_limit)
    retention_limit = tonumber(retention_limit) or options.retention_limit

    -- Process main history file
    local lines, all_lines = process_cleanup(history_path, retention_limit, false)
    if lines then
        local removed = #all_lines - #lines
        mp.osd_message(string.format("History cleaned up: kept %d entries", #lines), 3)
        mp.msg.debug(string.format("History cleanup completed. Removed %d entries", removed))
    end

    -- Process playlist history
    local pl_lines, pl_all_lines = process_cleanup(pl_history_path, 0, true)
    if pl_lines then
        local removed = #pl_all_lines - #pl_lines
        mp.msg.debug(string.format("Playlist cleanup completed. Removed %d entries", removed))
    end

    -- Refresh file handles
    history = refresh_history_files(history_path, history)
    pl_history = refresh_history_files(pl_history_path, pl_history)
    memo_clear()
end)

-- MARK: pull-pldir
mp.register_script_message("memo-pull-pldir", function()
    -- Get all files in playlist directory
    --local dir = mp.command_native({"expand-path", options.playlist_path})
    local not_seen = get_missing_playlists()

    -- Check each playlist file and log if not already in playlist history
    if not not_seen then return end

    for _, path in ipairs(not_seen) do
        custom_write_history(false, path)
    end
end)
-- MARK: slapdash-end

-- MARK: TODO:
--Todo: pull menu stuff down. what?
--mp.utils.append_file(fname, str) ???
-- TODO: search dont work for single letter? a gives otherpls... maybe pagination fucks this up again?
-- TODO: custom memo next prev for pagination on vanilla?
-- TODO: hide messes with pagination. Update state? or memos fault? artefact on page turn 
-- TODO: Why is menu_data ID faulty? Search does not work correctly with it
-- TODO: empty log files throw error? or single empty line throw error?
-- TODO: check if menu-event is hijacking other uosc menus. Like appending files via files menu. Nope uosc is broken, post issue?
-- TODO: https://mpv.io/manual/stable/#command-interface-stream-pos or https://mpv.io/manual/stable/#command-interface-time-pos
-- TODO: playlist uppercase after protocol youtube? No, different working-directory depending if mpv is started directly or via other programm.... damn
-- TODO: function for the expand and normalize stuff
