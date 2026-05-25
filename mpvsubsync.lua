-- Usage:
--  default keybinding: n
--  add the following to your input.conf to change the default keybinding:
--  keyname script_binding mpvsubsync-menu

local mp = require('mp')
local utils = require('mp.utils')
local mpopt = require('mp.options')
local menu = require('menu')
local sub = require('subtitle')
local h = require('helpers')
local progress = require('progress')
local progress_bar = progress:new()
local ref_selector
local engine_selector
local track_selector
math.randomseed(os.time())
local get_staging_path
local remove_file
local compute_current_cache_candidates
local active_job = {
    id = 0,
    running = false,
    command_id = nil,
    cancelled = false,
    reset_requested = false,
    reset_paths = nil,
}
local last_reset_paths = nil
local last_loaded_retimed_paths = {}
local last_sync_request = nil
local menu_visible = false
local pending_job_action = nil

-- Config
-- Options can be changed here or in a separate config file.
-- Config path: ~/.config/mpv/script-opts/mpvsubsync.conf
local config = {
    -- Change the following lines if the locations of executables differ from the defaults
    -- If set to empty, the path will be guessed.
    ffmpeg_path = "",
    ffsubsync_path = "",
    alass_path = "",

    -- Choose what tool to use. Allowed options: ffsubsync, alass, ask.
    -- If set to ask, the add-on will ask to choose the tool every time.
    audio_subsync_tool = "ask",
    altsub_subsync_tool = "ask",

    -- Cache extracted reference audio and generated retimed subtitles.
    -- This makes sync attempts resumable and avoids repeating ffmpeg/ffsubsync
    -- work when the same media + subtitle pair is processed again.
    cache_enabled = true,

    -- Cache directory for extracted reference audio and retimed subtitles.
    cache_dir = (function()
        if package.config:sub(1, 1) == "\\" then
            return (os.getenv("LOCALAPPDATA") or os.getenv("APPDATA") or "~") .. "\\mpvsubsync\\cache\\"
        end
        return (os.getenv("HOME") or "~") .. "/.cache/mpvsubsync/"
    end)(),

    -- Fast mode for streamed media: extract only a percentage of the
    -- reference audio, starting from the beginning of the file.
    fast_stream_mode = false,
    fast_stream_percent = 30,

    -- Verbose debug logging in mpv console/log.
    debug_logging = false,

}

local DEFAULT_CONFIG_TEXT = [[
# mpvsubsync — generated on first run. Edit to customize.
# Removing this file will recreate it next time mpv loads the script.

# --- Backends (leave empty to auto-discover in PATH) ---
# ffmpeg_path=
# ffsubsync_path=
# alass_path=

# Preferred tool per mode: ffsubsync, alass, or ask
audio_subsync_tool=ask
altsub_subsync_tool=ask

# --- Caching ---
cache_enabled=yes
cache_dir=~/.cache/mpvsubsync/

# --- Performance ---
fast_stream_mode=no
fast_stream_percent=30

# --- Debug ---
debug_logging=no
]]

local function write_default_config_if_missing()
    local target = mp.command_native({ "expand-path", "~~/script-opts/mpvsubsync.conf" })
    if target == nil or target == "" then return end
    local probe = io.open(target, "r")
    if probe ~= nil then
        probe:close()
        return
    end
    local dir = target:match("(.+)[/\\][^/\\]+$")
    if dir ~= nil then
        local is_win = package.config:sub(1, 1) == "\\"
        local args = is_win and { "cmd", "/C", "mkdir", dir } or { "mkdir", "-p", dir }
        mp.command_native({ name = "subprocess", args = args, playback_only = false, capture_stdout = true, capture_stderr = true })
    end
    local f = io.open(target, "w")
    if f == nil then return end
    f:write(DEFAULT_CONFIG_TEXT)
    f:close()
    mp.msg.info("mpvsubsync: wrote default config to " .. target)
end

write_default_config_if_missing()
mpopt.read_options(config, 'mpvsubsync')

local is_windows = package.config:sub(1, 1) == "\\"

local function os_temp()
    if is_windows then
        return os.getenv("TEMP") or os.getenv("TMP") or "."
    end
    return "/tmp/"
end

local function notify(message, level, duration)
    level = level or 'info'
    duration = duration or 1
    mp.msg[level](message)
    mp.osd_message(message, duration)
end

local function log_debug(message)
    if config.debug_logging then
        mp.msg.info("mpvsubsync: " .. message)
    end
end

local function shell_quote(arg)
    if arg == nil then
        return "''"
    end
    local s = tostring(arg)
    if s == "" then
        return "''"
    end
    if s:match("^[%w%._%-%+/:=@,]+$") then
        return s
    end
    return "'" .. s:gsub("'", [['"'"']]) .. "'"
end

local function format_args(args)
    local formatted = {}
    for _, arg in ipairs(args) do
        table.insert(formatted, shell_quote(arg))
    end
    return table.concat(formatted, " ")
end

local function subprocess(args)
    log_debug("running subprocess: " .. format_args(args))
    local ret = mp.command_native {
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }
    if ret == nil then
        log_debug("subprocess returned nil")
        return nil
    end
    log_debug(string.format("subprocess finished with status=%s", tostring(ret.status)))
    if not h.is_empty(ret.stderr) then
        mp.msg.info("mpvsubsync stderr: " .. ret.stderr:gsub("%s+$", ""))
    end
    if not h.is_empty(ret.stdout) then
        mp.msg.verbose("mpvsubsync stdout: " .. ret.stdout:gsub("%s+$", ""))
    end
    return ret
end

local function try_remove(path)
    if h.is_empty(path) or not h.file_exists(path) then
        return false
    end
    local ok, err = os.remove(path)
    if not ok then
        log_debug(string.format("failed to remove %s: %s", path, tostring(err)))
        return false
    end
    log_debug("removed cache file: " .. path)
    return true
end

local function gather_reset_paths(extra)
    local out = {}
    local seen = {}
    local function add(path)
        if h.is_empty(path) or seen[path] then return end
        seen[path] = true
        table.insert(out, path)
    end
    if extra ~= nil then
        for _, p in ipairs(extra) do add(p) end
    end
    if last_reset_paths ~= nil then
        for _, p in ipairs(last_reset_paths) do add(p) end
    end
    for _, p in ipairs(last_loaded_retimed_paths) do add(p) end
    if compute_current_cache_candidates ~= nil then
        for _, p in ipairs(compute_current_cache_candidates()) do add(p) end
    end
    return out
end

local function remember_loaded_retimed_path(path)
    if h.is_empty(path) then return end
    for _, p in ipairs(last_loaded_retimed_paths) do
        if p == path then return end
    end
    table.insert(last_loaded_retimed_paths, path)
end

local function is_retimed_filename(fn)
    if h.is_empty(fn) then return false end
    local basename = fn:match("([^/\\]+)$") or fn
    local stem = (basename:gsub("%.%w+$", "")):lower()
    return stem:match("retimed$") ~= nil or stem:match("^retimed%-") ~= nil
end

local function unload_retimed_subtitle_tracks()
    local tracks = mp.get_property_native("track-list")
    if tracks == nil then return end
    local sids_to_remove = {}
    local fallback_sub_id = nil
    for _, t in ipairs(tracks) do
        if t.type == "sub" then
            local fn = t.external and t["external-filename"] or nil
            local decoded = fn and fn:gsub("^file://", ""):gsub("+", " "):gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
            local matches = is_retimed_filename(fn) or (decoded and is_retimed_filename(decoded))
            if matches then
                table.insert(sids_to_remove, t.id)
            elseif fallback_sub_id == nil then
                fallback_sub_id = t.id
            end
        end
    end
    if fallback_sub_id ~= nil then
        mp.set_property("sid", tostring(fallback_sub_id))
    end
    for _, sid in ipairs(sids_to_remove) do
        mp.commandv("sub_remove", sid)
    end
end

local function delete_cache_paths(paths)
    if paths == nil then
        return false
    end

    unload_retimed_subtitle_tracks()

    local removed = false
    local seen = {}
    for _, path in ipairs(paths) do
        if not h.is_empty(path) and not seen[path] then
            seen[path] = true
            if try_remove(path) then removed = true end
            if try_remove(get_staging_path(path)) then removed = true end
        end
    end
    last_loaded_retimed_paths = {}
    return removed
end

local function set_job_reset_paths(paths)
    active_job.reset_paths = paths
    if paths ~= nil then
        last_reset_paths = paths
    end
end

local function remember_reset_paths(paths)
    if paths == nil then
        return
    end
    local copy = {}
    for i, path in ipairs(paths) do
        copy[i] = path
    end
    last_reset_paths = copy
end

local function start_job(reset_paths)
    if active_job.running then
        notify("Autosubsync is already running.", "warn", 3)
        return nil
    end

    active_job.id = active_job.id + 1
    active_job.running = true
    active_job.command_id = nil
    active_job.cancelled = false
    active_job.reset_requested = false
    set_job_reset_paths(reset_paths)
    return active_job.id
end

local function is_job_active(job_id)
    return active_job.running and active_job.id == job_id
end

local function finish_job(job_id)
    if active_job.id ~= job_id then
        return
    end

    local reset_requested = active_job.reset_requested
    local reset_paths = active_job.reset_paths
    active_job.running = false
    active_job.command_id = nil
    active_job.cancelled = false
    active_job.reset_requested = false
    active_job.reset_paths = nil
    progress_bar:hide()

    if reset_requested then
        if delete_cache_paths(gather_reset_paths(reset_paths)) then
            notify("Autosubsync cache reset.", nil, 2)
        else
            notify("Autosubsync reset: nothing to clear.", "warn", 2)
        end
    end

    if pending_job_action ~= nil then
        local action = pending_job_action
        pending_job_action = nil
        action()
    end
end

local function stop_active_job()
    pending_job_action = nil

    if not active_job.running then
        return notify("Autosubsync is not running.", "warn", 2)
    end

    active_job.cancelled = true
    active_job.reset_requested = false

    if active_job.command_id ~= nil then
        mp.abort_async_command(active_job.command_id)
        notify("Stopping mpvsubsync...", nil, 2)
    else
        finish_job(active_job.id)
        notify("Autosubsync stopped.", nil, 2)
    end
end

local function reset_active_job()
    if not active_job.running then
        if delete_cache_paths(gather_reset_paths(nil)) then
            return notify("Autosubsync cache reset.", nil, 2)
        end
        return notify("No mpvsubsync cache to reset.", "warn", 2)
    end

    active_job.cancelled = true
    active_job.reset_requested = true

    if active_job.command_id ~= nil then
        mp.abort_async_command(active_job.command_id)
        notify("Resetting mpvsubsync...", nil, 2)
    else
        finish_job(active_job.id)
    end
end

local function subprocess_async(job_id, args, on_done)
    log_debug("running subprocess: " .. format_args(args))
    local command_id = mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }, function(success, result, err)
        if active_job.id == job_id then
            active_job.command_id = nil
        end

        result = result or {}
        if not h.is_empty(result.stderr) then
            mp.msg.info("mpvsubsync stderr: " .. result.stderr:gsub("%s+$", ""))
        end
        if not h.is_empty(result.stdout) then
            mp.msg.verbose("mpvsubsync stdout: " .. result.stdout:gsub("%s+$", ""))
        end

        if active_job.id == job_id and active_job.cancelled then
            notify(active_job.reset_requested and "Autosubsync reset." or "Autosubsync stopped.", nil, 2)
            return on_done(false, { status = -1, cancelled = true }, err or "cancelled")
        end

        log_debug(string.format("subprocess finished with status=%s", tostring(result.status)))
        return on_done(success, result, err)
    end)

    if command_id == nil then
        log_debug("subprocess_async returned nil")
        return false
    end

    active_job.command_id = command_id
    return true
end

local function set_last_sync_request(fn)
    last_sync_request = fn
end

local function restart_last_sync()
    if last_sync_request == nil then
        return notify("No mpvsubsync run to restart.", "warn", 2)
    end

    if active_job.running then
        pending_job_action = last_sync_request
        return reset_active_job()
    end

    delete_cache_paths(gather_reset_paths(nil))
    last_sync_request()
end

local function clone_table(tbl)
    if tbl == nil then
        return nil
    end

    local copy = {}
    for k, v in pairs(tbl) do
        copy[k] = v
    end
    return copy
end

local url_decode = function(url)
    local function hex_to_char(x)
        return string.char(tonumber(x, 16))
    end
    if url ~= nil then
        url = url:gsub("^file://", "")
        url = url:gsub("+", " ")
        url = url:gsub("%%(%x%x)", hex_to_char)
        if is_windows then
            url = url:gsub("^/([a-zA-Z]:)", "%1")
        end
        return url
    else
        return
    end
end

local function get_loaded_tracks(track_type)
    local result = {}
    local track_list = mp.get_property_native('track-list')
    for _, track in pairs(track_list) do
        if track.type == track_type then
            track['external-filename'] = track.external and url_decode(track['external-filename'])
            table.insert(result, track)
        end
    end
    return result
end

local function get_active_track(track_type)
    local track_list = mp.get_property_native('track-list')
    for num, track in ipairs(track_list) do
        if track.type == track_type and track.selected == true then
            if track.external and not h.file_exists(track['external-filename']) then
                track['external-filename'] = url_decode(track['external-filename'])
            end
            if not (track_type == 'sub' and track.id == mp.get_property_native('secondary-sid')) then
                return num, track
            end
        end
    end
    return notify(string.format("Error: no track of type '%s' selected", track_type), "error", 3)
end

local function remove_extension(filename)
    return filename:gsub('%.%w+$', '')
end

local function get_extension(filename)
    return filename:match("^.+(%.%w+)$")
end

local function startswith(str, prefix)
    return string.sub(str, 1, string.len(prefix)) == prefix
end

local function is_uri(path)
    return not h.is_empty(path) and not not path:match("^%a[%w+.-]*://")
end

local function is_local_path(path)
    return not h.is_empty(path) and (not is_uri(path) or startswith(path, "file://"))
end

local function sanitize_filename(name)
    if h.is_empty(name) then
        return "mpvsubsync"
    end
    return name:gsub("[/\\:*?\"<>|]", "_"):gsub("%s+$", "")
end

local function build_temp_path(stem, ext)
    return utils.join_path(
            os_temp(),
            string.format("%s_%d_%06d.%s", stem, os.time(), math.random(0, 999999), ext)
    )
end

local function expand_path(path)
    if h.is_empty(path) then
        return path
    end

    local home = os.getenv("HOME")
    if home ~= nil then
        if path == "~" then
            path = home
        elseif startswith(path, "~/") then
            path = utils.join_path(home, path:sub(3))
        end
    end

    return path
end

local function get_cache_dir()
    if not h.is_empty(config.cache_dir) then
        return expand_path(config.cache_dir)
    end
    return utils.join_path(os_temp(), "mpvsubsync-cache")
end

local function ensure_dir(path)
    if h.is_empty(path) then
        return false
    end
    local info = utils.file_info(path)
    if info and info.is_dir then
        return true
    end

    local args
    if is_windows then
        args = { "cmd", "/C", "mkdir", path }
    else
        args = { "mkdir", "-p", path }
    end

    local ret = subprocess(args)
    info = utils.file_info(path)
    return ret ~= nil and ret.status == 0 and info and info.is_dir or false
end

local function hash_string(value)
    local hash = 5381
    for i = 1, #value do
        hash = ((hash * 33) + value:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function stat_fingerprint(path)
    if h.is_empty(path) then
        return "missing"
    end
    local info = utils.file_info(path)
    if info == nil then
        return "missing:" .. path
    end
    return table.concat({
        path,
        tostring(info.size or ""),
        tostring(info.mtime or ""),
    }, "|")
end

local function descriptor_fingerprint(value)
    if h.is_empty(value) then
        return "missing"
    end
    if h.file_exists(value) then
        return stat_fingerprint(value)
    end
    return value
end

local function build_cache_path(kind, descriptor, ext)
    local cache_dir = get_cache_dir()
    if not ensure_dir(cache_dir) then
        return nil
    end
    local stem = string.format("%s-%s", kind, hash_string(descriptor))
    return utils.join_path(cache_dir, string.format("%s.%s", stem, ext))
end

local function current_media_stem()
    return sanitize_filename(
            mp.get_property("filename/no-ext")
            or mp.get_property("media-title")
            or "stream"
    )
end

local function get_playback_source()
    local path = mp.get_property("path")
    local stream_path = mp.get_property("stream-open-filename")
    local source = stream_path or path

    if h.is_empty(source) then
        return nil
    end

    source = url_decode(source)

    if startswith(source, "ytdl://") then
        return source:gsub("^ytdl://", "")
    end

    log_debug("source: " .. source)
    return source
end

local function get_active_audio_track()
    local _, track = get_active_track('audio')
    return track
end

local function get_track_extension(track)
    if track == nil then
        return nil
    end
    if track.external and not h.is_empty(track['external-filename']) then
        return get_extension(track['external-filename'])
    end
    local codec_ext_map = { subrip = ".srt", ass = ".ass" }
    return codec_ext_map[track['codec']]
end

local function get_media_descriptor(playback_source)
    return table.concat({
        current_media_stem(),
        descriptor_fingerprint(playback_source),
    }, "|")
end

local function get_track_descriptor(track, playback_source, role)
    if track == nil then
        return "missing-track"
    end

    local origin
    if track.external and not h.is_empty(track['external-filename']) then
        origin = descriptor_fingerprint(track['external-filename'])
    else
        origin = table.concat({
            "internal",
            get_media_descriptor(playback_source),
            tostring(track['type'] or ""),
            tostring(track['id'] or ""),
            tostring(track['ff-index'] or ""),
        }, "|")
    end

    return table.concat({
        role or "track",
        origin,
        tostring(track['codec'] or ""),
        tostring(track['lang'] or ""),
        tostring(track['title'] or ""),
    }, "|")
end

local function get_audio_reference_descriptor(reference_input_path)
    local audio_track = get_active_audio_track()
    return table.concat({
        "audio",
        get_media_descriptor(reference_input_path),
        tostring(audio_track and audio_track['ff-index'] or ""),
        tostring(audio_track and audio_track['id'] or ""),
        tostring(config.fast_stream_mode or ""),
        tostring(config.fast_stream_percent or ""),
        "start",
    }, "|")
end

local function get_reference_audio_cache_path(reference_input_path)
    if not config.cache_enabled then
        return nil
    end
    return build_cache_path("reference", get_audio_reference_descriptor(reference_input_path), "wav")
end

local function get_stream_extract_window(reference_input_path)
    if is_local_path(reference_input_path) or not config.fast_stream_mode then
        return nil, nil
    end

    local duration = mp.get_property_number("duration")
    local percent = tonumber(config.fast_stream_percent) or 30
    percent = math.max(1, math.min(100, percent))
    if duration == nil or duration <= 0 then
        return nil, nil
    end

    local length = duration * (percent / 100)
    if length >= duration then
        return 0, duration
    end

    return 0, length
end

local function get_reference_descriptor(ref_sub_path, ref_track, playback_source)
    if ref_sub_path == nil then
        return get_audio_reference_descriptor(playback_source)
    end
    if ref_track ~= nil then
        return "subtitle|" .. get_track_descriptor(ref_track, playback_source, "reference")
    end
    return table.concat({
        "subtitle",
        descriptor_fingerprint(ref_sub_path),
    }, "|")
end

local function get_retimed_cache_path(reference_descriptor, subtitle_descriptor, subtitle_ext)
    if h.is_empty(subtitle_ext) then
        return nil
    end
    local descriptor = table.concat({
        reference_descriptor,
        subtitle_descriptor,
    }, "||")
    return build_cache_path("retimed", descriptor, subtitle_ext:gsub("^%.", ""))
end

local function get_active_sub_track_quiet()
    local track_list = mp.get_property_native('track-list')
    local secondary_sid = mp.get_property_native('secondary-sid')
    if track_list == nil then return nil end
    for _, track in ipairs(track_list) do
        if track.type == 'sub' and track.selected == true and track.id ~= secondary_sid then
            if track.external and not h.file_exists(track['external-filename']) then
                track['external-filename'] = url_decode(track['external-filename'])
            end
            return track
        end
    end
    return nil
end

compute_current_cache_candidates = function()
    local paths = {}
    if not config.cache_enabled then return paths end

    local playback_source = get_playback_source()
    if h.is_empty(playback_source) then return paths end

    local ref_path = get_reference_audio_cache_path(playback_source)
    if ref_path ~= nil then table.insert(paths, ref_path) end

    local sub_track = get_active_sub_track_quiet()
    if sub_track ~= nil then
        local subtitle_ext = get_track_extension(sub_track)
        if not h.is_empty(subtitle_ext) then
            local subtitle_descriptor = get_track_descriptor(sub_track, playback_source, "subtitle")
            local audio_descriptor = get_audio_reference_descriptor(playback_source)
            local retimed_path = get_retimed_cache_path(audio_descriptor, subtitle_descriptor, subtitle_ext)
            if retimed_path ~= nil then table.insert(paths, retimed_path) end
        end
    end
    return paths
end

local function get_retimed_output_path(track)
    local ext = get_track_extension(track)
    if h.is_empty(ext) then
        return nil
    end
    return utils.join_path(os_temp(), current_media_stem() .. "_retimed" .. ext)
end

local function copy_file(source_path, destination_path)
    if h.is_empty(source_path) or h.is_empty(destination_path) then
        return false
    end

    local src = io.open(source_path, "rb")
    if src == nil then
        return false
    end
    local content = src:read("*a")
    src:close()

    local dest = io.open(destination_path, "wb")
    if dest == nil then
        return false
    end
    dest:write(content)
    dest:close()
    return true
end

remove_file = function(path)
    if not h.is_empty(path) and h.file_exists(path) then
        os.remove(path)
    end
end

get_staging_path = function(final_path)
    if h.is_empty(final_path) then
        return nil
    end
    local ext = get_extension(final_path)
    if h.is_empty(ext) then
        return final_path .. ".part"
    end
    return final_path:sub(1, #final_path - #ext) .. ".part" .. ext
end

local function finalize_staged_file(staging_path, final_path)
    if h.is_empty(staging_path) or h.is_empty(final_path) then
        return false
    end
    if staging_path == final_path then
        return h.file_exists(final_path)
    end

    remove_file(final_path)
    local ok = os.rename(staging_path, final_path)
    if ok then
        return true
    end
    if copy_file(staging_path, final_path) then
        remove_file(staging_path)
        return true
    end
    return false
end

local function materialize_cached_subtitle(cache_path, output_path)
    if h.is_empty(output_path) or cache_path == output_path then
        return cache_path
    end

    log_debug(string.format("copying cached subtitle from %s to %s", cache_path, output_path))
    if copy_file(cache_path, output_path) then
        return output_path
    end

    log_debug("failed to copy cached subtitle to output path, falling back to cached file")
    return cache_path
end

local function resolve_retimed_write_path(cache_path, output_path)
    if not h.is_empty(cache_path) then
        return get_staging_path(cache_path)
    end
    return output_path
end

local function should_materialize_retimed_output(_track, _cache_path, _output_path)
    return false
end

local function engine_is_set()
    local tool = config.audio_subsync_tool
    if ref_selector:get_ref() == 'sub' then
        tool = config.altsub_subsync_tool
    end
    return not h.is_empty(tool) and tool ~= "ask"
end

local function extract_to_file(subtitle_track, input_path)
    if h.is_path(config.ffmpeg_path) and not h.file_exists(config.ffmpeg_path) then
        return notify("Can't find ffmpeg executable.\nPlease specify the correct path in the config.", "error", 5)
    end
    local codec_ext_map = { subrip = "srt", ass = "ass" }
    local ext = codec_ext_map[subtitle_track['codec']]
    if ext == nil then
        return notify(string.format("Error: unsupported codec: %s", subtitle_track['codec']), "error", 3)
    end
    local temp_sub_fp = build_temp_path("mpvsubsync_extracted", ext)
    notify("Extracting internal subtitles...", nil, 3)
    progress_bar:update({ stage = "extracting subtitles", elapsed_start = mp.get_time() })
    progress_bar:show()
    log_debug(string.format(
            "sub extract: id=%s ff=%s codec=%s src=%s out=%s",
            tostring(subtitle_track and subtitle_track['id'] or ""),
            tostring(subtitle_track and subtitle_track['ff-index'] or ""),
            tostring(subtitle_track and subtitle_track['codec'] or ""),
            tostring(input_path or get_playback_source()),
            temp_sub_fp
    ))
    local ret = subprocess {
        config.ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "error",
        "-an",
        "-vn",
        "-i", input_path or get_playback_source(),
        "-map", "0:" .. (subtitle_track and subtitle_track['ff-index'] or 's'),
        "-f", ext,
        temp_sub_fp
    }
    if ret == nil or ret.status ~= 0 or not h.file_exists(temp_sub_fp) then
        return notify("Couldn't extract internal subtitle.\nMake sure the video has internal subtitles.", "error", 7)
    end
    return temp_sub_fp
end

local function extract_to_file_async(job_id, subtitle_track, input_path, on_done)
    if h.is_path(config.ffmpeg_path) and not h.file_exists(config.ffmpeg_path) then
        notify("Can't find ffmpeg executable.\nPlease specify the correct path in the config.", "error", 5)
        return on_done(nil)
    end
    local codec_ext_map = { subrip = "srt", ass = "ass" }
    local ext = codec_ext_map[subtitle_track['codec']]
    if ext == nil then
        notify(string.format("Error: unsupported codec: %s", subtitle_track['codec']), "error", 3)
        return on_done(nil)
    end
    local temp_sub_fp = build_temp_path("mpvsubsync_extracted", ext)
    notify("Extracting internal subtitles...", nil, 3)
    log_debug(string.format(
            "sub extract: id=%s ff=%s codec=%s src=%s out=%s",
            tostring(subtitle_track and subtitle_track['id'] or ""),
            tostring(subtitle_track and subtitle_track['ff-index'] or ""),
            tostring(subtitle_track and subtitle_track['codec'] or ""),
            tostring(input_path or get_playback_source()),
            temp_sub_fp
    ))
    local ok = subprocess_async(job_id, {
        config.ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "error",
        "-an",
        "-vn",
        "-i", input_path or get_playback_source(),
        "-map", "0:" .. (subtitle_track and subtitle_track['ff-index'] or 's'),
        "-f", ext,
        temp_sub_fp
    }, function(_, ret)
        if ret.cancelled then
            return on_done(nil, true)
        end
        if ret.status ~= 0 or not h.file_exists(temp_sub_fp) then
            notify("Couldn't extract internal subtitle.\nMake sure the video has internal subtitles.", "error", 7)
            return on_done(nil)
        end
        return on_done(temp_sub_fp)
    end)
    if not ok then
        notify("Couldn't start subtitle extraction.", "error", 5)
        return on_done(nil)
    end
end

local function materialize_subtitle_input(subtitle_path)
    local ext = get_extension(subtitle_path)
    if ext ~= '.srt' and ext ~= '.ass' then
        return nil, notify(string.format("Unsupported external subtitle format: %s", subtitle_path), "error", 5)
    end

    local temp_sub_fp = build_temp_path("mpvsubsync_remote_sub", ext:gsub("^%.", ""))
    notify("Downloading external subtitles...", nil, 3)
    progress_bar:update({ stage = "downloading subtitles", elapsed_start = mp.get_time() })
    progress_bar:show()
    log_debug(string.format("sub fetch: %s -> %s", subtitle_path, temp_sub_fp))
    local ret = subprocess {
        config.ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "error",
        "-i", subtitle_path,
        temp_sub_fp
    }

    if ret == nil or ret.status ~= 0 or not h.file_exists(temp_sub_fp) then
        return nil, notify("Couldn't fetch the external subtitle track.", "error", 7)
    end

    return temp_sub_fp
end

local function materialize_subtitle_input_async(job_id, subtitle_path, on_done)
    local ext = get_extension(subtitle_path)
    if ext ~= '.srt' and ext ~= '.ass' then
        notify(string.format("Unsupported external subtitle format: %s", subtitle_path), "error", 5)
        return on_done(nil)
    end

    local temp_sub_fp = build_temp_path("mpvsubsync_remote_sub", ext:gsub("^%.", ""))
    notify("Downloading external subtitles...", nil, 3)
    log_debug(string.format("sub fetch: %s -> %s", subtitle_path, temp_sub_fp))
    local ok = subprocess_async(job_id, {
        config.ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "error",
        "-i", subtitle_path,
        temp_sub_fp
    }, function(_, ret)
        if ret.cancelled then
            return on_done(nil, true)
        end
        if ret.status ~= 0 or not h.file_exists(temp_sub_fp) then
            notify("Couldn't fetch the external subtitle track.", "error", 7)
            return on_done(nil)
        end
        return on_done(temp_sub_fp)
    end)
    if not ok then
        notify("Couldn't start subtitle download.", "error", 5)
        return on_done(nil)
    end
end

local function extract_reference_audio(reference_input_path)
    local audio_track = get_active_audio_track()
    if audio_track == nil then
        return nil, notify("Couldn't find an active audio track.", "error", 5)
    end
    log_debug(string.format(
            "ref audio: src=%s id=%s ff=%s",
            tostring(reference_input_path),
            tostring(audio_track['id']),
            tostring(audio_track['ff-index'])
    ))
    local duration = mp.get_property_number("duration")
    local window_start, window_length = get_stream_extract_window(reference_input_path)
    log_debug(string.format(
            "ref window: %s dur=%s",
            window_length and string.format("start %.0f%%", tonumber(config.fast_stream_percent) or 30) or "full",
            duration and string.format("%.3fs", duration) or "unknown"
    ))
    local cache_path
    if config.cache_enabled then
        cache_path = build_cache_path("reference", get_audio_reference_descriptor(reference_input_path), "wav")
        if cache_path ~= nil and h.file_exists(cache_path) then
            notify("Using cached reference audio...", nil, 2)
            log_debug("ref cache hit: " .. cache_path)
            return cache_path, false
        end
        if cache_path ~= nil then
            log_debug("ref cache miss: " .. cache_path)
        end
    end

    local temp_audio_fp = cache_path or build_temp_path("mpvsubsync_reference", "wav")
    notify("Extracting stream audio...", nil, 3)
    log_debug(string.format(
            "ref extract: %s -> %s",
            tostring(reference_input_path),
            temp_audio_fp
    ))
    local args = {
        config.ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "error",
    }
    if window_start ~= nil and window_length ~= nil then
        table.insert(args, "-ss")
        table.insert(args, tostring(window_start))
    end
    table.insert(args, "-i")
    table.insert(args, reference_input_path)
    if window_length ~= nil then
        table.insert(args, "-t")
        table.insert(args, tostring(window_length))
    end
    table.insert(args, "-map")
    table.insert(args, "0:" .. audio_track['ff-index'])
    table.insert(args, "-vn")
    table.insert(args, "-ac")
    table.insert(args, "1")
    table.insert(args, "-ar")
    table.insert(args, "16000")
    table.insert(args, temp_audio_fp)
    local ret = subprocess(args)

    if ret == nil or ret.status ~= 0 or not h.file_exists(temp_audio_fp) then
        return nil, notify("Couldn't extract audio from the current stream.", "error", 7)
    end

    return temp_audio_fp, cache_path == nil
end

local function extract_reference_audio_async(job_id, reference_input_path, on_done)
    local audio_track = get_active_audio_track()
    if audio_track == nil then
        notify("Couldn't find an active audio track.", "error", 5)
        return on_done(nil)
    end
    log_debug(string.format(
            "ref audio: src=%s id=%s ff=%s",
            tostring(reference_input_path),
            tostring(audio_track['id']),
            tostring(audio_track['ff-index'])
    ))
    local duration = mp.get_property_number("duration")
    local window_start, window_length = get_stream_extract_window(reference_input_path)
    log_debug(string.format(
            "ref window: %s dur=%s",
            window_length and string.format("start %.0f%%", tonumber(config.fast_stream_percent) or 30) or "full",
            duration and string.format("%.3fs", duration) or "unknown"
    ))
    local cache_path
    local staging_path
    if config.cache_enabled then
        cache_path = build_cache_path("reference", get_audio_reference_descriptor(reference_input_path), "wav")
        if cache_path ~= nil and h.file_exists(cache_path) then
            notify("Using cached reference audio...", nil, 2)
            log_debug("ref cache hit: " .. cache_path)
            return on_done(cache_path, false)
        end
        if cache_path ~= nil then
            log_debug("ref cache miss: " .. cache_path)
        end
    end

    staging_path = cache_path and get_staging_path(cache_path) or nil
    if staging_path ~= nil then
        remove_file(staging_path)
    end
    local temp_audio_fp = staging_path or build_temp_path("mpvsubsync_reference", "wav")
    notify("Extracting stream audio...", nil, 3)
    progress_bar:show()
    progress_bar:update({
        stage = "extracting audio",
        elapsed_start = mp.get_time(),
        poll_path = temp_audio_fp,
        poll_target = window_length or duration,
    })
    log_debug(string.format(
            "ref extract: %s -> %s",
            tostring(reference_input_path),
            temp_audio_fp
    ))
    local args = {
        config.ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "error",
    }
    if window_start ~= nil and window_length ~= nil then
        table.insert(args, "-ss")
        table.insert(args, tostring(window_start))
    end
    table.insert(args, "-i")
    table.insert(args, reference_input_path)
    if window_length ~= nil then
        table.insert(args, "-t")
        table.insert(args, tostring(window_length))
    end
    table.insert(args, "-map")
    table.insert(args, "0:" .. audio_track['ff-index'])
    table.insert(args, "-vn")
    table.insert(args, "-ac")
    table.insert(args, "1")
    table.insert(args, "-ar")
    table.insert(args, "16000")
    table.insert(args, temp_audio_fp)
    local ok = subprocess_async(job_id, args, function(_, ret)
        if ret.cancelled then
            remove_file(temp_audio_fp)
            return on_done(nil, true)
        end
        if ret.status ~= 0 or not h.file_exists(temp_audio_fp) then
            remove_file(temp_audio_fp)
            notify("Couldn't extract audio from the current stream.", "error", 7)
            return on_done(nil)
        end
        if cache_path ~= nil then
            if not finalize_staged_file(temp_audio_fp, cache_path) then
                remove_file(temp_audio_fp)
                notify("Couldn't finalize cached reference audio.", "error", 7)
                return on_done(nil)
            end
            return on_done(cache_path, false)
        end
        return on_done(temp_audio_fp, true)
    end)
    if not ok then
        notify("Couldn't start audio extraction.", "error", 5)
        return on_done(nil)
    end
end

local function ensure_local_subtitle_file(track, reference_input_path)
    if track.external then
        local external_path = track['external-filename']
        if h.file_exists(external_path) then
            log_debug("sub file: " .. external_path)
            return external_path, false
        elseif is_uri(external_path) then
            log_debug("sub remote: " .. external_path)
            local materialized = materialize_subtitle_input(external_path)
            return materialized, materialized ~= nil
        else
            log_debug("sub unreadable: " .. tostring(external_path))
            return nil, false
        end
    end

    log_debug("sub internal: extracting")
    local extracted = extract_to_file(track, reference_input_path)
    return extracted, extracted ~= nil
end

local function ensure_local_subtitle_file_async(job_id, track, reference_input_path, on_done)
    if track.external then
        local external_path = track['external-filename']
        if h.file_exists(external_path) then
            log_debug("sub file: " .. external_path)
            return on_done(external_path, false)
        elseif is_uri(external_path) then
            log_debug("sub remote: " .. external_path)
            return materialize_subtitle_input_async(job_id, external_path, function(materialized)
                return on_done(materialized, materialized ~= nil)
            end)
        else
            log_debug("sub unreadable: " .. tostring(external_path))
            return on_done(nil, false)
        end
    end

    log_debug("sub internal: extracting")
    return extract_to_file_async(job_id, track, reference_input_path, function(extracted)
        return on_done(extracted, extracted ~= nil)
    end)
end

local function sync_subtitles(ref_sub_path, ref_track, initial_cleanup_reference)
    local playback_source = get_playback_source()
    local reference_file_path = ref_sub_path or playback_source
    local _, sub_track = get_active_track('sub')
    if sub_track == nil then
        return
    end
    local engine_name = engine_selector:get_engine_name()
    local engine_path = config[engine_name .. '_path']
    local subtitle_descriptor = get_track_descriptor(sub_track, playback_source, "subtitle")
    local reference_descriptor = get_reference_descriptor(ref_sub_path, ref_track, playback_source)
    local subtitle_ext = get_track_extension(sub_track)
    local retimed_subtitle_path = get_retimed_output_path(sub_track)
    local cached_retimed_path
    local write_subtitle_path
    local subtitle_path
    local cleanup_subtitle = false
    local cleanup_reference = initial_cleanup_reference or false
    local job_id
    local reset_paths = {}

    local function cleanup_files()
        if cached_retimed_path ~= nil and write_subtitle_path == get_staging_path(cached_retimed_path) then
            remove_file(write_subtitle_path)
        end
        if cleanup_subtitle and not h.is_empty(subtitle_path) then
            log_debug("cleanup sub: " .. tostring(subtitle_path))
            os.remove(subtitle_path)
        end
        if cleanup_reference and not h.is_empty(reference_file_path) then
            log_debug("cleanup ref: " .. tostring(reference_file_path))
            os.remove(reference_file_path)
        end
    end

    log_debug(string.format(
            "sync: engine=%s ref=%s sid=%s ext=%s",
            tostring(engine_name),
            tostring(reference_file_path),
            tostring(sub_track and sub_track['id'] or ""),
            tostring(sub_track and sub_track.external or false)
    ))

    if h.is_path(engine_path) and not h.file_exists(engine_path) then
        return notify(
                string.format("Can't find %s executable.\nPlease specify the correct path in the config.", engine_name),
                "error",
                5
        )
    end

    if h.is_empty(reference_file_path) then
        return notify("Couldn't resolve the current playback source.", "error", 5)
    end

    log_debug("out: " .. tostring(retimed_subtitle_path))

    notify(string.format("Starting %s...", engine_name), nil, 2)

    if config.cache_enabled then
        cached_retimed_path = get_retimed_cache_path(
                reference_descriptor,
                subtitle_descriptor,
                subtitle_ext
        )
        if cached_retimed_path ~= nil then
            table.insert(reset_paths, cached_retimed_path)
            remember_reset_paths(reset_paths)
        end
        if cached_retimed_path ~= nil and h.file_exists(cached_retimed_path) then
            local load_path = cached_retimed_path
            if should_materialize_retimed_output(sub_track, cached_retimed_path, retimed_subtitle_path) then
                load_path = materialize_cached_subtitle(cached_retimed_path, retimed_subtitle_path)
            end
            notify("Using cached retimed subtitle...", nil, 2)
            log_debug("sub cache hit: " .. cached_retimed_path)
            if mp.commandv("sub_add", load_path, "select", "retimed") then
                if not (sub_track and sub_track.external and sub_track['external-filename'] == load_path) then
                    remember_loaded_retimed_path(load_path)
                end
                notify("Cached subtitle loaded.", nil, 2)
                mp.set_property("sub-delay", 0)
            else
                notify("Error: couldn't add cached subtitle.", "error", 3)
            end
            return
        end
        if cached_retimed_path ~= nil then
            log_debug("sub cache miss: " .. cached_retimed_path)
        end
    end

    job_id = start_job(reset_paths)
    if job_id == nil then
        return
    end

    write_subtitle_path = resolve_retimed_write_path(cached_retimed_path, retimed_subtitle_path)
    if cached_retimed_path ~= nil and write_subtitle_path == get_staging_path(cached_retimed_path) then
        remove_file(write_subtitle_path)
    end

    local function finalize()
        cleanup_files()
        finish_job(job_id)
    end

    local function load_retimed_subtitle()
        local load_subtitle_path = write_subtitle_path
        if cached_retimed_path ~= nil then
            if not finalize_staged_file(write_subtitle_path, cached_retimed_path) then
                notify("Couldn't finalize cached subtitle.", "error", 7)
                return false
            end
            load_subtitle_path = cached_retimed_path
        end
        if should_materialize_retimed_output(sub_track, cached_retimed_path, retimed_subtitle_path) then
            log_debug("sub out copy: " .. retimed_subtitle_path)
            load_subtitle_path = materialize_cached_subtitle(cached_retimed_path, retimed_subtitle_path)
        end
        log_debug("load: " .. tostring(load_subtitle_path))
        if mp.commandv("sub_add", load_subtitle_path, "select", "retimed") then
            if not (sub_track and sub_track.external and sub_track['external-filename'] == load_subtitle_path) then
                remember_loaded_retimed_path(load_subtitle_path)
            end
            notify("Subtitle synchronized.", nil, 2)
            mp.set_property("sub-delay", 0)
            return true
        end
        notify("Error: couldn't add synchronized subtitle.", "error", 3)
        return false
    end

    local function run_engine()
        local stage_name = "retiming with " .. engine_name
        log_debug(string.format(
                "%s: ref=%s sub=%s out=%s",
                engine_name,
                tostring(reference_file_path),
                tostring(subtitle_path),
                tostring(write_subtitle_path)
        ))
        progress_bar:update({ stage = stage_name, elapsed_start = mp.get_time() })

        local args
        if engine_name == "ffsubsync" then
            args = { config.ffsubsync_path, reference_file_path, "-i", subtitle_path, "-o", write_subtitle_path }
            if not ref_sub_path and not cleanup_reference then
                local audio_track = get_active_audio_track()
                table.insert(args, '--reference-stream')
                table.insert(args, '0:' .. tostring(audio_track and audio_track['ff-index'] or "0"))
                log_debug("ffsubsync: using reference-stream")
            end
        else
            args = { config.alass_path, reference_file_path, subtitle_path, write_subtitle_path }
        end

        local ok = subprocess_async(job_id, args, function(_, ret)
            if ret.cancelled then
                return finalize()
            end
            if ret.status == 0 then
                load_retimed_subtitle()
            else
                notify("Subtitle synchronization failed.", "error", 3)
            end
            return finalize()
        end)
        if not ok then
            notify(string.format("Couldn't start %s.", engine_name), "error", 5)
            return finalize()
        end
    end

    local function prepare_reference()
        if ref_sub_path and not h.file_exists(reference_file_path) and is_uri(reference_file_path) then
            log_debug("ref sub: remote")
            return materialize_subtitle_input_async(job_id, reference_file_path, function(materialized)
                if materialized == nil then
                    return finalize()
                end
                reference_file_path = materialized
                cleanup_reference = true
                return run_engine()
            end)
        end

        if engine_name == "ffsubsync" then
            if not ref_sub_path and not is_local_path(reference_file_path) then
                log_debug("ref audio: extract first")
                local reference_cache_path = get_reference_audio_cache_path(reference_file_path)
                if reference_cache_path ~= nil then
                    table.insert(reset_paths, reference_cache_path)
                    set_job_reset_paths(reset_paths)
                end
                return extract_reference_audio_async(job_id, reference_file_path, function(materialized, should_cleanup)
                    if materialized == nil then
                        return finalize()
                    end
                    reference_file_path = materialized
                    cleanup_reference = should_cleanup
                    return run_engine()
                end)
            end
            return run_engine()
        end

        if not is_local_path(reference_file_path) then
            log_debug("alass: extract ref first")
            local reference_cache_path = get_reference_audio_cache_path(reference_file_path)
            if reference_cache_path ~= nil then
                table.insert(reset_paths, reference_cache_path)
                set_job_reset_paths(reset_paths)
            end
            return extract_reference_audio_async(job_id, reference_file_path, function(materialized, should_cleanup)
                if materialized == nil then
                    return finalize()
                end
                reference_file_path = materialized
                cleanup_reference = should_cleanup
                return run_engine()
            end)
        end

        return run_engine()
    end

    return ensure_local_subtitle_file_async(job_id, sub_track, playback_source, function(materialized_subtitle, should_cleanup)
        subtitle_path = materialized_subtitle
        cleanup_subtitle = should_cleanup
        if not h.file_exists(subtitle_path) then
            notify(
                    table.concat {
                        "Subtitle synchronization failed:\nCouldn't find ",
                        subtitle_path or "external subtitle file."
                    },
                    "error",
                    3
            )
            return finalize()
        end
        return prepare_reference()
    end)
end

local function sync_to_selected_subtitle(selected_track)
    if selected_track == nil then
        return
    end

    if selected_track and selected_track.external then
        sync_subtitles(selected_track['external-filename'], selected_track, false)
    else
        if h.is_path(config.ffmpeg_path) and not h.file_exists(config.ffmpeg_path) then
            return notify("Can't find ffmpeg executable.\nPlease specify the correct path in the config.", "error", 5)
        end
        local playback_source = get_playback_source()
        local job_id = start_job(nil)
        if job_id == nil then
            return
        end
        extract_to_file_async(job_id, selected_track, playback_source, function(temp_sub_fp)
            if temp_sub_fp == nil then
                return finish_job(job_id)
            end
            active_job.running = false
            active_job.command_id = nil
            active_job.cancelled = false
            active_job.reset_requested = false
            active_job.reset_paths = nil
            progress_bar:hide()
            return sync_subtitles(temp_sub_fp, selected_track, true)
        end)
    end
end

local function sync_to_subtitle()
    local selected_track = track_selector:get_selected_track()
    if selected_track == nil then
        return
    end

    local selected_track_copy = clone_table(selected_track)
    set_last_sync_request(function()
        sync_to_selected_subtitle(selected_track_copy)
    end)

    sync_to_selected_subtitle(selected_track)
end

local function backup_path_for(path)
    local ext = get_extension(path)
    local base = remove_extension(path)
    if h.is_empty(ext) then
        return path .. ".bak"
    end
    return base .. ".bak" .. ext
end

local function sync_to_manual_offset()
    local _, track = get_active_track('sub')
    if track == nil then
        return
    end
    local sub_delay = tonumber(mp.get_property("sub-delay")) or 0

    local active_path = nil
    if track.external then
        active_path = track['external-filename']
        if active_path and not h.file_exists(active_path) then
            active_path = url_decode(active_path)
        end
    end
    local active_is_retimed = is_retimed_filename(active_path)

    local destination_path
    if active_is_retimed then
        local tracks = mp.get_property_native("track-list") or {}
        for _, t in ipairs(tracks) do
            if t.type == "sub" and t.external and t.id ~= track.id then
                local fn = t["external-filename"]
                if fn and not is_retimed_filename(fn) then
                    if not h.file_exists(fn) then fn = url_decode(fn) end
                    destination_path = fn
                    break
                end
            end
        end
    elseif active_path and not active_is_retimed then
        destination_path = active_path
    end

    if sub_delay == 0 and not active_is_retimed then
        return notify("Nothing to save: no timing changes pending.", "warn", 5)
    end

    local file_path, cleanup_source = ensure_local_subtitle_file(track, get_playback_source())
    if file_path == nil then
        return
    end

    local codec_parser_map = { ass = sub.ASS, subrip = sub.SRT }
    local parser = codec_parser_map[track['codec']]
    if parser == nil then
        if cleanup_source then os.remove(file_path) end
        return notify(string.format("Error: unsupported codec: %s", track['codec']), "error", 3)
    end
    local s, err = parser:populate(file_path)
    if s == nil then
        if cleanup_source then os.remove(file_path) end
        return notify("Couldn't parse subtitle: " .. tostring(err), "error", 7)
    end
    if sub_delay ~= 0 then
        s:shift_timing(sub_delay)
    end

    if destination_path == nil then
        local ext = get_extension(file_path)
        if track.external == false then
            destination_path = current_media_stem() .. "_manual_timing" .. ext
        else
            destination_path = utils.join_path(os_temp(), current_media_stem() .. "_manual_timing" .. ext)
        end
        s.filename = destination_path
        local ok, err_save = s:save()
        if cleanup_source then os.remove(file_path) end
        if not ok then
            return notify(string.format("Error saving: %s", tostring(err_save or "unknown")), "error", 7)
        end
        mp.commandv("sub_add", destination_path, "select")
        if track.id then
            mp.commandv("sub_remove", track.id)
        end
        mp.set_property("sub-delay", 0)
        return notify(string.format("Saved to '%s'", destination_path), "info", 5)
    end

    local backup = backup_path_for(destination_path)
    if h.file_exists(destination_path) and not h.file_exists(backup) then
        if not copy_file(destination_path, backup) then
            if cleanup_source then os.remove(file_path) end
            return notify("Couldn't back up the original sub.", "error", 7)
        end
    end

    s.filename = destination_path
    local ok, err_save = s:save()
    if cleanup_source then os.remove(file_path) end
    if not ok then
        return notify(string.format("Error saving: %s", tostring(err_save or "unknown")), "error", 7)
    end

    local destination_sid = nil
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "sub" and t.external then
            local tfn = t["external-filename"]
            if not h.file_exists(tfn) then tfn = url_decode(tfn) end
            if tfn == destination_path then
                destination_sid = t.id
                break
            end
        end
    end

    if destination_sid ~= nil then
        mp.commandv("sub-reload", tostring(destination_sid))
        mp.set_property("sid", tostring(destination_sid))
    else
        mp.commandv("sub_add", destination_path, "select")
    end

    if track.id and track.id ~= destination_sid then
        mp.commandv("sub_remove", track.id)
    end
    mp.set_property("sub-delay", 0)

    if active_is_retimed and not h.is_empty(active_path) then
        os.remove(active_path)
    end
    last_loaded_retimed_paths = {}

    return notify(string.format("Saved over '%s' (backup at %s)", destination_path, backup), "info", 5)
end

------------------------------------------------------------
-- Menu actions & bindings

ref_selector = menu:new {
    items = {},
    actions = {},
    last_choice = 'audio',
    text_color = 'fff5da',
    border_color = '2f1728',
    active_color = 'ff6b71',
    inactive_color = 'fff5da',
}

function ref_selector:get_keybindings()
    return {
        { key = 'h', fn = function() self:close() end },
        { key = 'j', fn = function() self:down() end },
        { key = 'k', fn = function() self:up() end },
        { key = 'l', fn = function() self:act() end },
        { key = 'down', fn = function() self:down() end },
        { key = 'up', fn = function() self:up() end },
        { key = 'Enter', fn = function() self:act() end },
        { key = 'ESC', fn = function() self:close() end },
        { key = 'n', fn = function() self:close() end },
        { key = 'WHEEL_DOWN', fn = function() self:down() end },
        { key = 'WHEEL_UP', fn = function() self:up() end },
        { key = 'MBTN_LEFT', fn = function() self:act() end },
        { key = 'MBTN_RIGHT', fn = function() self:close() end },
    }
end

function ref_selector:new(o)
    self.__index = self
    o = o or {}
    return setmetatable(o, self)
end

function ref_selector:get_ref()
    if self:get_action() == 'audio' then
        return 'audio'
    elseif self:get_action() == 'sub' then
        return 'sub'
    else
        return nil
    end
end

function ref_selector:get_action()
    if self.actions == nil then
        return nil
    end
    return self.actions[self.selected]
end

function ref_selector:refresh_root_items()
    self.items = {}
    self.actions = {}

    local function add_item(label, action)
        table.insert(self.items, label)
        table.insert(self.actions, action)
    end

    add_item('Sync to audio', 'audio')
    add_item('Sync to another subtitle', 'sub')
    add_item(active_job.running and 'Stop current sync' or 'Stop current sync (idle)', 'stop')
    add_item(last_sync_request ~= nil and 'Restart last sync' or 'Restart last sync (unavailable)', 'restart')
    add_item((active_job.running or last_reset_paths ~= nil) and 'Reset current sync/cache' or 'Reset current sync/cache (empty)', 'reset')
    add_item('Save current timings', 'manual')
    add_item('Cancel', 'cancel')
end

function ref_selector:act()
    self:close()

    local action = self:get_action()

    if action == 'stop' then
        return stop_active_job()
    end
    if action == 'restart' then
        return restart_last_sync()
    end
    if action == 'reset' then
        return reset_active_job()
    end
    if action == 'manual' then
        return sync_to_manual_offset()
    end
    if action == 'cancel' or action == nil then
        return
    end

    engine_selector:init()
end

function ref_selector:call_subsync()
    local action = self:get_action()

    if action == 'audio' then
        set_last_sync_request(function()
            sync_subtitles()
        end)
        sync_subtitles()
    elseif action == 'sub' then
        sync_to_subtitle()
    elseif action == 'manual' then
        sync_to_manual_offset()
    end
end

function ref_selector:open()
    if self == ref_selector then
        self:refresh_root_items()
    end
    self.selected = 1
    menu_visible = true
    progress_bar.paused = true
    for _, val in pairs(self:get_keybindings()) do
        mp.add_forced_key_binding(val.key, val.key, val.fn)
    end
    self:draw()
end

function ref_selector:close()
    menu_visible = false
    for _, val in pairs(self:get_keybindings()) do
        mp.remove_key_binding(val.key)
    end
    self:erase()
    progress_bar.paused = false
    if progress_bar.visible then
        progress_bar:draw()
    end
end


------------------------------------------------------------
-- Engine selector

engine_selector = ref_selector:new {
    items = { 'ffsubsync', 'alass', 'Cancel' },
    last_choice = 'ffsubsync',
}

function engine_selector:init()
    if not engine_is_set() then
        engine_selector:open()
    else
        track_selector:init()
    end
end

function engine_selector:get_engine_name()
    if engine_is_set() then
        local tool = config.audio_subsync_tool
        if ref_selector:get_ref() == 'sub' then
            tool = config.altsub_subsync_tool
        end
        return tool
    end
    return self.last_choice
end

function engine_selector:act()
    self:close()

    if self.selected == 1 then
        self.last_choice = 'ffsubsync'
    elseif self.selected == 2 then
        self.last_choice = 'alass'
    elseif self.selected == 3 then
        return
    end

    track_selector:init()
end

------------------------------------------------------------
-- Track selector

track_selector = ref_selector:new { }

local function is_supported_format(track)
    local supported_format = true
    if track.external then
        local ext = get_extension(track['external-filename'])
        if ext ~= '.srt' and ext ~= '.ass' then
            supported_format = false
        end
    end
    return supported_format
end

function track_selector:init()
    self.selected = 0

    if ref_selector:get_ref() == 'audio' then
        return ref_selector:call_subsync()
    end

    self.all_sub_tracks = get_loaded_tracks(ref_selector:get_ref())
    self.secondary_sid = mp.get_property_native('secondary-sid')
    self.tracks = {}
    self.items = {}

    for _, track in ipairs(self.all_sub_tracks) do
        if (not track.selected or track.id == self.secondary_sid) and is_supported_format(track) then
            table.insert(self.tracks, track)
            table.insert(
                    self.items,
                    string.format(
                            "%s #%s - %s%s",
                            (track.external and 'External' or 'Internal'),
                            track['id'],
                            (track.lang or (track.title and track.title:gsub('^.*%.', '') or 'unknown')),
                            (track.selected and ' (active)' or '')
                    )
            )
        end
    end

    if #self.items == 0 then
        notify("No supported subtitle tracks found.", "warn", 5)
        return
    end

    table.insert(self.items, "Cancel")
    self:open()
end

function track_selector:get_selected_track()
    if self.selected < 1 then
        return nil
    end
    return self.tracks[self.selected]
end

function track_selector:act()
    self:close()

    if self.selected == #self.items then
        return
    end

    ref_selector:call_subsync()
end

------------------------------------------------------------
-- Initialize the addon

local function init()
    for _, executable in pairs { 'ffmpeg', 'ffsubsync', 'alass' } do
        local config_key = executable .. '_path'
        config[config_key] = h.is_empty(config[config_key]) and h.find_executable(executable) or config[config_key]
    end
end

------------------------------------------------------------
-- Entry point

local function close_all_menus()
    ref_selector:close()
    engine_selector:close()
    track_selector:close()
end

init()
mp.add_key_binding("n", "mpvsubsync-menu", function() ref_selector:open() end)
mp.add_key_binding("Ctrl+r", "mpvsubsync-reset", reset_active_job)
mp.register_script_message("mpvsubsync-reset", reset_active_job)
mp.register_event("end-file", close_all_menus)
mp.register_event("file-loaded", function()
    close_all_menus()
    last_loaded_retimed_paths = {}
end)
