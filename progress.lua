------------------------------------------------------------
-- ASS progress bar for mpvsubsync job stages

local mp = require('mp')

local Progress = {}
Progress.__index = Progress

local BAR_W = 480
local BAR_H = 8
local FONT_SIZE = 30
local FONT_SM = 22
local PADDING = 16
local PCT_GAP = 14
local PCT_WIDTH = 64
local INDETERMINATE_WIDTH = 144

local function hex_to_bbggrr(hex)
    return hex:sub(5, 6), hex:sub(3, 4), hex:sub(1, 2)
end

local function format_clock(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

function Progress:new()
    local p = {
        visible = false,
        paused = false,
        stage = "",
        fraction = nil,
        elapsed_start = nil,
        detail_current = nil,
        detail_total = nil,
        timer = nil,
        anim_pos = 0,
        poll_path = nil,
        poll_target = nil,
    }
    setmetatable(p, self)
    return p
end

function Progress:show()
    self.visible = true
    self.anim_pos = 0
    self:draw()
    if self.timer == nil then
        self.timer = mp.add_periodic_timer(0.15, function()
            self:poll_and_draw()
            self.anim_pos = (self.anim_pos + 8) % (BAR_W + INDETERMINATE_WIDTH)
            self:draw()
        end)
    end
end

function Progress:hide()
    self.visible = false
    self.stage = ""
    self.fraction = nil
    self.elapsed_start = nil
    self.detail_current = nil
    self.detail_total = nil
    self.poll_path = nil
    self.poll_target = nil
    if self.timer ~= nil then
        self.timer:kill()
        self.timer = nil
    end

    local osd_w = mp.get_property_number("osd-width") or 1280
    local osd_h = mp.get_property_number("osd-height") or 720
    mp.set_osd_ass(osd_w, osd_h, '')
end

function Progress:update(params)
    self.stage = params.stage or self.stage
    self.fraction = params.fraction
    if params.elapsed_start ~= nil then self.elapsed_start = params.elapsed_start end
    self.detail_current = params.detail_current
    self.detail_total = params.detail_total
    self.poll_path = params.poll_path
    self.poll_target = params.poll_target
    self:draw()
end

function Progress:poll_and_draw()
    if not self.visible or self.poll_path == nil or self.poll_target == nil or self.poll_target <= 0 then
        return
    end
    local info = require('mp.utils').file_info(self.poll_path)
    if info ~= nil and info.size ~= nil and info.size > 44 then
        local seconds = math.max(0, (info.size - 44) / 32000)
        self.fraction = math.min(1, seconds / self.poll_target)
        self.detail_current = seconds
    end
end

function Progress:draw()
    if not self.visible or self.paused then return end

    local elapsed = 0
    if self.elapsed_start ~= nil then
        elapsed = mp.get_time() - self.elapsed_start
    end

    local osd_w = mp.get_property_number("osd-width") or 1280
    local osd_h = mp.get_property_number("osd-height") or 720
    local container_w = math.min(BAR_W + PCT_GAP + PCT_WIDTH + PADDING * 2, osd_w - 40)

    local has_detail = self.detail_current ~= nil and self.detail_total ~= nil
    local content_h = FONT_SIZE + 8 + BAR_H + 8 + FONT_SM
    local container_h = content_h + PADDING * 2
    local cx = math.floor((osd_w - container_w) / 2)
    local cy = math.floor((osd_h - container_h) / 2)

    local events = {}

    local function rgb(hex, cmd)
        local r, g, b = hex_to_bbggrr(hex)
        return string.format("\\%s&H%s%s%s&", cmd, r, g, b)
    end
    local function al(val, cmd)
        return string.format("\\%s&H%s&", cmd, val)
    end
    local function emit(s) table.insert(events, s) end

    -- backdrop
    emit(string.format(
        "{\\pos(0,0)\\an7%s%s%s\\bord0\\p1}m %d %d l %d %d l %d %d l %d %d{\\p0}",
        rgb("2f1728", "1c"), al("70", "1a"), rgb("000000", "3c"),
        cx - 3, cy - 3, cx + container_w + 3, cy - 3,
        cx + container_w + 3, cy + container_h + 3, cx - 3, cy + container_h + 3
    ))

    -- label
    emit(string.format(
        "{\\pos(%d,%d)\\an7%s%s%s\\bord1\\fs%d}{\\b1}mpvsubsync{\\b0}  %s",
        cx + PADDING, cy + PADDING,
        rgb("fff5da", "1c"), al("00", "1a"), rgb("2f1728", "3c"),
        FONT_SIZE, self.stage or ""
    ))

    -- bar background
    local bar_x = cx + PADDING
    local bar_y = cy + PADDING + FONT_SIZE + 8
    emit(string.format(
        "{\\pos(%d,%d)\\an7%s%s%s\\bord0\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
        bar_x, bar_y,
        rgb("fff5da", "1c"), al("30", "1a"), rgb("000000", "3c"),
        BAR_W, BAR_W, BAR_H, BAR_H
    ))

    -- bar fill
    if self.fraction ~= nil then
        local fill_w = math.floor(math.max(0, math.min(1, self.fraction)) * BAR_W)
        if fill_w > 0 then
            emit(string.format(
                "{\\pos(%d,%d)\\an7%s%s%s\\bord0\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
                bar_x, bar_y,
                rgb("ff6b71", "1c"), al("00", "1a"), rgb("000000", "3c"),
                fill_w, fill_w, BAR_H, BAR_H
            ))
        end
        local pct = math.floor(math.max(0, math.min(1, self.fraction)) * 100)
        emit(string.format(
            "{\\pos(%d,%d)\\an4%s%s%s\\bord1\\fs%d}%d%%",
            bar_x + BAR_W + 10, bar_y + math.floor(BAR_H / 2),
            rgb("fff5da", "1c"), al("00", "1a"), rgb("000000", "3c"),
            FONT_SM, pct
        ))
    else
        local band_x = self.anim_pos - INDETERMINATE_WIDTH
        local clip_x0 = math.max(0, band_x)
        local clip_x1 = math.min(BAR_W, band_x + INDETERMINATE_WIDTH)
        if clip_x0 < clip_x1 then
            emit(string.format(
                "{\\pos(%d,%d)\\an7%s%s%s\\bord0\\p1}m %d 0 l %d 0 l %d %d l %d %d{\\p0}",
                bar_x, bar_y,
                rgb("ff6b71", "1c"), al("00", "1a"), rgb("000000", "3c"),
                clip_x0, clip_x1, clip_x1, BAR_H, clip_x0, BAR_H
            ))
        end
    end

    -- elapsed / detail
    local extra_y = bar_y + BAR_H + 8
    local extra_text
    if has_detail then
        extra_text = string.format("%s / %s", format_clock(self.detail_current), format_clock(self.detail_total))
    else
        extra_text = format_clock(elapsed)
    end
    emit(string.format(
        "{\\pos(%d,%d)\\an7%s%s%s\\bord1\\fs%d}%s",
        cx + PADDING, extra_y,
        rgb("fff5da", "1c"), al("00", "1a"), rgb("000000", "3c"),
        FONT_SM, extra_text
    ))

    mp.set_osd_ass(osd_w, osd_h, table.concat(events, "\n"))
end

return Progress
