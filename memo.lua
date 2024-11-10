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
	--enabel/disables the script from automatically saving the prev session
    auto_save = true,

    --runs the script automatically when started in idle mode and no files are in the playlist
    auto_load = false,

    --file path where playlists get saved.
    --playlist_path = "~~state/watch_later/playlist/",   
    playlist_path = "",
    --maintain position in the playlist
    load_position = false,
	
    ext = ".pls",	

    -- icon for the uosc button. Name of a material icon (look at uosc.conf for more info)
    icon="article",
    -- tooltip for the uosc button
    tooltip="Playlist",
    -- keep_n=0 keep all memo entrys during memo-cleanup, keep_n=100 keep the last 100. 
    -- Playlists (files ending with ext) will always be kept
    -- All duplicates will be removed.
    keep_n = 0,
    -- delete playlists from memo and filesystem
    delte_pl_file = true,

    -- show button in uosc menu
    show_append = true,
    show_delete = true,
    show_save = true,
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
--------- slapdash ------------
-------------------------------
-------------------------------
local pl_menu_data = nil
local function create_directory_if_missing(path)
    local dir = mp.command_native({ "expand-path", path })
    local res = mp.utils.file_info(dir)

    if not res then
        mp.msg.error("Creating directory: " .. dir)
        if res.config:sub(1,1) == "/" then
            -- create the directory for linux
            os.execute(string.format('mkdir -p "%s"', dir))
        else
            -- create the directory for windows
            os.execute(string.format('mkdir "%s"', dir))
        end
    end
end

-- Helper function for safe file operations
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
local function write_lines(file_path, lines)
    return with_file(file_path, "w", function(file)
        for _, line in ipairs(lines) do
            file:write(line, "\n")
        end
        return true
    end)
end

-- Function to process lines and keep the last N items
local function process_lines(lines, keep_n, ext)
    local seen_paths = {}
    local processed_lines = {}
    local processed_playlists = {}
    -- Iterate over lines in reverse order

    for i = #lines, 1, -1 do
        local line = lines[i]

        if line == nil then
            mp.msg.debug("Aborting found empty line. Check memo.log")
            break
        end

        -- Extract the path from the line
        -- TDOD: check if memo already has a function for this
        local path = line:match("[^,]*,[^,]*,[^,]*,([^,]*),")
        -- fix issue with case-sensitive checks TODO: why are some paths uppercased?
        local lower_path = path:lower()
        if path and not seen_paths[lower_path] then
            seen_paths[lower_path] = true


            if path:match("%.[^%.]+$") == options.ext then
                --mp.msg.debug(seen_paths[path])
                mp.msg.debug('[process_lines] found: ' .. path)
                table.insert(processed_lines, 1, line)
                 -- Track playlists separately
                table.insert(processed_playlists, 1, path)
            
            -- Keep lines that match any of these conditions: is below limit, is unique
            elseif (keep_n == 0) or (#processed_lines < keep_n) then
                table.insert(processed_lines, 1, line)
            end
        end
    end
    return processed_lines, processed_playlists
end

local function get_playlists()
    local dir = mp.command_native({"expand-path", options.playlist_path})
    local files = mp.utils.readdir(dir,'files')
  
    mp.msg.debug("Processing playlists from dir: " .. dir)
    -- Read current history to check what files are already logged
    local all_lines = read_lines(history_path)
    local seen_paths = {}
    
    -- Build lookup table of paths already in history
    if all_lines then
       _, seen_paths = process_lines(all_lines, 0, options.ext)
    end
    return files, seen_paths
end

local function delete_entry(path)
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
        history:close()
        history = io.open(history_path, "a+b")
        history:setvbuf("full")

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

local default_flag = false

--# Adapted parts from [https://github.com/CogentRedTester/mpv-scripts/blob/master/keep-session.lua]
--# Copyright (c) [2020] [Oscar Manglaras]
--# MIT License

--init----------------------------------------------------------------------------
--sets the default session file to the watch_later directory or ~~state/watch_later/playlist
if options.playlist_path == "" or options.playlist_path == "default" then
    mp.msg.verbose("playlist_path not put, using default")
    options.playlist_path = "~~state/watch_later/playlist/"
    default_flag = true
end

create_directory_if_missing(options.playlist_path)   

options.playlist_path = mp.command_native({"expand-path", options.playlist_path})
options.playlist_path = normalize(options.playlist_path)


-- button for uosc ribbon TODO: replace names with variables
mp.commandv('script-message-to', 'uosc', 'set-button', 'memo-playlist', mp.utils.format_json({
    icon = options.icon,
    active = false,
    tooltip = options.tooltip,
    command = 'script-binding memo-playlist',
  }))

--init-end----------------------------------------------------------------------------

function custom_write_history(display, full_path)
    --mp.msg[display and "info" or "debug"]("[memo] logging file " .. full_path)
    print("custom_write_history", full_path)
    local _, file = mp.utils.split_path(full_path)
    print("filename", file)
    -- TODO: catch options.ext in filename?
    local title, extension = file:match("^(.*)%.(.*)$")

    if not title then
        mp.msg.error("no title found, aborting")
        return
    end

    mp.msg.debug("logging playlist " .. full_path)
    if display then
        mp.osd_message("[memo] logging playlist " .. full_path)
    end

    local entry = string.format("%d,%s,%s,%s",
        os.time(),
        #title > 0 and #title or "",
        title,
        full_path
    )

    history:seek("end")
    history:write(string.format("%s,%d\n", entry, #entry))
    history:flush()

    if dyn_menu then dyn_menu_update() end
end

--saves the current playlist as a json string
local function save_playlist(playlist_name, playlist_full_path)
    --if not playlist_name and not default_flag then
    if not playlist_name then
        playlist_name = "default"
    end
    
    if not playlist_full_path then
        mp.msg.debug("Only name found, creating full path with: ", playlist_name)
        if playlist_name:find("." .. options.ext, -#options.ext) then
            mp.msg.debug("Name with ext found, only adding path")
            playlist_full_path = mp.utils.join_path(options.playlist_path, playlist_name)
            -- TODO: Check if this is enough for the uosc playlist menu or are there  new playlists that get saved with path
            pl_menu_data = nil
        else
            playlist_name = playlist_name .. options.ext
            playlist_full_path = mp.utils.join_path(options.playlist_path, playlist_name)
        end
        
    else
        mp.msg.debug("playlist_full_path found: ", playlist_full_path)
        _, playlist_name = mp.utils.split_path(playlist_full_path)
    end

    playlist_full_path = mp.command_native({"expand-path", playlist_full_path})
    playlist_full_path = normalize(playlist_full_path)


    mp.msg.verbose('Saving Playlist to', playlist_full_path)
    mp.osd_message("Saved Playlist as: " .. playlist_name, 3)

    local playlist = mp.get_property_native('playlist')

    if #playlist == 0 then
        mp.msg.debug('Playlist empty, aborting save')
        return
    end

    -- position loading is bugged if its done directly after a playlist is loaded, maybe a subprocess would work
    --local time_pos = mp.get_property('time-pos')
    local playlist_pos = mp.get_property('playlist-pos')
    local both_pos = time_pos and (playlist_pos .. ":" .. time_pos) or playlist_pos

    local success, err = with_file(playlist_full_path, "w", function(pls_file)
        local working_directory = mp.get_property('working-directory')
        local count = 0
        pls_file:write("[playlist]\n" .. both_pos ..   "\n")

        for i, v in ipairs(playlist) do
            count = i
            mp.msg.trace('adding ' .. v.filename .. ' to playlist')

            --if the file is available then it attempts to expand the path in-case of relative playlists
            --presumably if the file contains a protocol then it shouldn't be expanded
            if not v.filename:find("^%a*://") then
                v.filename = mp.utils.join_path(working_directory, v.filename, options.ext)
                mp.msg.trace('expanded path: ' .. v.filename)
            end

            pls_file:write("File".. count .."=" .. v.filename .. "\n")
        end
        pls_file:write("NumberOfEntries=".. count .. "\n" .. "Version=2\n")
        return true
    end)

    if not success then
        mp.msg.error("Failed to write to file " .. playlist_full_path)
        mp.msg.error(err)
        return
    end

    custom_write_history(false, playlist_full_path)
end

-- save playlist on mpv close
local function autosave()
    if options.auto_save then
        save_playlist("last_session")
    end
end


--native input method modified from memo-search
function input_action(action)
    --local action = "delete"
    if not action then
        mp.msg.error("No action specified")
        return
    end
    mp.msg.verbose ("memo input function")

    if uosc_available then
        mp.msg.debug(uosc_available)
        mp.commandv('script-message-to', 'uosc', 'disable-elements', mp.get_script_name(), 'controls')
    end

    local pl_title, _ = get_playlists()
    local input_string = "default"
    local input = require 'mp.input'
    --local playlist_name = "default"
    local aborted = false

   input.select({
    prompt = "Enter playlist name: ",
    items = pl_title,
    default_item = 1,
    opened = function ()
    end,
    edited = function (input_string)
        mp.msg.trace(input_string)
        if #input_string >= 4 and string.sub(input_string, -4) == "exit" then
            aborted = true
            input.terminate()
        end
    end,
    submit = function (input_string)
        mp.msg.debug("pl_title[id]: ",pl_title[input_string])
        playlist_name = pl_title[input_string]
        if action == "delete" then
            delete_entry(playlist_name)
            if options.delte_pl_file then
                local pl_path = mp.utils.join_path(options.playlist_path, playlist_name)
                pl_path = mp.command_native({"expand-path", pl_path})
                pl_path = normalize(pl_path)
                os.remove(pl_path)
            end
        end
    end,
    closed = function (playlist_name)
        print("closed: ", playlist_name)
        -- input.select does ignores submit if input_string is not in items.
        -- so we just do it here
        -- TODO: catch esc key press
        if action == "save_as" and #playlist_name > 0 and not aborted then
            save_playlist(playlist_name)
            pl_menu_data = nil
        else
            mp.msg.debug("aborted")
        end

        mp.msg.debug("closed input")
        if uosc_available then
            mp.commandv('script-message-to', 'uosc', 'disable-elements', mp.get_script_name(), '')
        end
    end,
    })
end

-- either 
local function load_playlist(name, path)
    local file = nil
    if name then
        file = mp.command_native({"expand-path", options.playlist_path..name.. options.ext})
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

-- todo: memo_search_uosc
function custom_search(indirect)
    if not indirect then
        memo_close()
    end

    -- TODO: set entries to playlist count if available
    if event_loop_exhausted then return end
    last_state = nil
    -- show no duplicate for this menu
    search_words = {options.ext}
    local tmp_options = {
        hide_duplicates = options.hide_duplicates,
        pagination = options.pagination,
        use_titles = options.use_titles,
        hide_same_dir = options.hide_same_dir,
        entires = options.entries
    }
    options.hide_duplicates = true
    options.pagination = false 
    options.use_titles = false 
    options.hide_same_dir = false
    options.entries = 99
    -- save should never show up in normal history menu. 
    -- if options.show_save == nil then options.show_save = true end

    if pl_menu_data == nil then
        show_history(options.entries,false,false,true,false)
    end
    -- if playlist menu add a save button
    if menu_data and pl_menu_data == nil then 
        --print("custom_search", mp.utils.to_string(menu_data.items['actions']))
        if not menu_data.items then 
            return 
        end  -- Ensure menu_data.items exists  
        for i, item in ipairs(menu_data.items) do
            if item.actions then
                -- Check if the action already exists to avoid duplicates
                local action_exists = false
                for _, action in ipairs(item.actions) do
                    if action.name == 'memo_action_saveto' then
                        action_exists = true
                        break
                    end
                end
                if not action_exists then
                    table.insert(item.actions, {name = 'memo_action_saveto', icon = 'save', label = 'Save playlist' .. ' (alt+enter/click)'})
                end
            end
        end
        pl_menu_data = menu_data
        uosc_update()
    else
        local tmp_menu_data = menu_data
        menu_data = pl_menu_data
        uosc_update()
        menu_data = tmp_menu_data
    end

    --memo_search_uosc(options.ext)

    --if options.show_save then options.show_save = nil end
    search_words = nil
    options.use_titles = tmp_options.use_titles
    options.pagination = tmp_options.pagination
    options.hide_duplicates = tmp_options.hide_duplicates
    options.hide_same_dir = tmp_options.hide_same_dir
    options.entries = tmp_options.entires

end

-- shows normal history but filtered for the extention (.pls)
mp.add_key_binding('g', 'memo-playlist', custom_search)
mp.register_script_message('memo-load', load_playlist)
mp.register_script_message('memo-save', save_playlist)
mp.register_script_message('memo-action', input_action)
mp.register_event('shutdown', autosave)
mp.register_script_message("menu-event", function(json)
    -- hijacks the menu event, check if our action is triggerd , if not proceed to continue with normal memo flow.
    local event = mp.utils.parse_json(json)
    if event.type == "activate" or event.type == "key" then
        if event.action == "memo_action_hide" or event.key == "del" then
            pl_menu_data = nil
        end

        if options.pagination and event.key == 'right' then
            memo_next()
        elseif options.pagination and event.key == 'left' then
            memo_prev()
        elseif event.action == "memo_action_saveto" or event.key == "alt" then
            local item = event.selected_item and event.selected_item or event
            mp.commandv("script-message-to", script_name, "memo-save", "", item.value[2])
            memo_close()

        else
            process_menu_event(event)
        end
    end
end)

-- Key binding function for memo cleanup
mp.register_script_message("memo-cleanup", function(keep_n)
    local temp_path = history_path .. ".tmp"
    -- Read all lines from the history file
    local all_lines = read_lines(history_path)
    if not all_lines then return end

    keep_n = tonumber(keep_n) or options.keep_n
    -- Process the lines to keep the necessary ones
    local lines = process_lines(all_lines, keep_n, options.ext)
    -- Write the processed lines to a temporary file
    write_lines(temp_path, lines)
    -- Remove the original history file and rename the temp file to history file
    os.remove(history_path)
    os.rename(temp_path, history_path)

    -- msg
    mp.osd_message("History cleaned up: kept " .. #lines .. " entries", 3)
    mp.msg.debug("History cleanup completed. Removed " .. (#all_lines - #lines) .. " entries")

    -- reload history file to load modified data
    history:close()
    history = io.open(history_path, "a+b")
    history:setvbuf("full")
    memo_clear()
end)

mp.register_script_message("memo-pull-pldir", function()
    -- Get all files in playlist directory
    local dir = mp.command_native({"expand-path", options.playlist_path})
    local files, seen_paths = get_playlists()

    -- Check each playlist file and log if not already in history
    if files then
        for _, file in ipairs(files) do
            local full_path = mp.utils.join_path(dir, file)
            full_path = normalize(full_path)
            local match = false
            for _, path in ipairs(seen_paths) do
                if path == full_path then 
                    match = true
                    break
                end
            end
            if not match then
                custom_write_history(false, full_path)
            end
        end
        pl_menu_data = nil
    end
end)
-- slapdash-end
--Todo: pull menu stuff down
--mp.utils.append_file(fname, str)
-- TODO: https://mpv.io/manual/stable/#command-interface-stream-pos or https://mpv.io/manual/stable/#command-interface-time-pos
-- TODO: playlist uppercase after protocol youtube?
-- TODO: function for the expand and normalize stuff

        --slapdash Playlist
    --menu.item_actions = {}
    --local delete = {name = 'delete_memo_entry', icon = 'delete', label = 'Remove (del)'}
    --local append = {name = 'append_memo_entry', icon = 'playlist_add', label = 'Add to playlist' .. ' (shift+enter/click)'}
    --local saveto = {name = 'saveto_memo_entry', icon = 'save', label = 'Save playlist' .. ' (alt+enter/click)'}
--
    --if options.show_append then menu.item_actions[#menu.item_actions+1] = append end
    --if options.show_save then menu.item_actions[#menu.item_actions+1] = saveto end
    --if options.show_delete then menu.item_actions[#menu.item_actions+1] =delete end
   --
    --menu.callback = {mp.get_script_name(), 'menu-event'}
    -- slapdash-end Playlist