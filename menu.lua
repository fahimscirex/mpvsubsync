------------------------------------------------------------
-- Menu visuals

local mp = require('mp')
local assdraw = require('mp.assdraw')

local Menu = assdraw.ass_new()

local function hex_to_bbggrr(hex)
    return hex:sub(5, 6), hex:sub(3, 4), hex:sub(1, 2)
end

function Menu:new(o)
    self.__index = self
    o = o or {}
    o.selected = o.selected or 1
    o.font_size = o.font_size or 25
    o.padding = o.padding or 8
    o.item_height = o.item_height or 40
    o.backdrop_alpha = o.backdrop_alpha or "80"
    o.active_color = o.active_color or 'ff6b71'
    o.inactive_color = o.inactive_color or 'ffffff'
    o.border_color = o.border_color or '2f1728'
    o.text_color = o.text_color or 'ffffff'
    return setmetatable(o, self)
end

function Menu:measure_item_text(item)
    return #item * (self.font_size * 0.55)
end

function Menu:measure_width()
    local max_w = 0
    for _, item in ipairs(self.items) do
        local w = self:measure_item_text(item)
        if w > max_w then max_w = w end
    end
    return max_w + self.padding * 2
end

function Menu:get_dimensions()
    local w = self:measure_width()
    local h = #self.items * self.item_height
    local osd_w = mp.get_property_number("osd-width") or 1280
    local osd_h = mp.get_property_number("osd-height") or 720
    local x = math.floor((osd_w - w) / 2)
    local y = math.floor((osd_h - h) / 2)
    return x, y, w, h
end

function Menu:ass_font_size(size)
    self:append(string.format("{\\fs%d}", size))
end

function Menu:ass_text_color(hex)
    local r, g, b = hex_to_bbggrr(hex)
    self:append(string.format("{\\1c&H%s%s%s&}", r, g, b))
end

function Menu:ass_fill_color(hex, alpha)
    local r, g, b = hex_to_bbggrr(hex)
    self:append(string.format("{\\1c&H%s%s%s&\\1a&H%s&}", r, g, b, alpha or "FF"))
end

function Menu:ass_border_color(hex)
    local r, g, b = hex_to_bbggrr(hex)
    self:append(string.format("{\\3c&H%s%s%s&}", r, g, b))
end

function Menu:draw_backdrop(x, y, w, h)
    local color = self.border_color or "000000"
    local a = self.backdrop_alpha or "80"
    self:new_event()
    self:pos(0, 0)
    self:ass_fill_color(color, a)
    self:ass_border_color(color)
    self:draw_start()
    self:rect_cw(x - 4, y - 4, x + w + 4, y + h + 4)
    self:draw_stop()
end

function Menu:draw_text(i)
    self:new_event()
    local y = self.py + self.item_height * (i - 1) + math.floor(self.item_height / 2)
    self:pos(self.px + self.padding, y)
    self:append("{\\an4}")
    self:ass_font_size(self.font_size)
    self:ass_border_color(self.border_color)
    if i == self.selected then
        self:ass_text_color(self.active_color)
    else
        self:ass_text_color(self.inactive_color)
    end
    self:append(self.items[i])
end

function Menu:draw_item(i)
    if i == self.selected then
        self:new_event()
        self:pos(self.px, self.py)
        local r, g, b = hex_to_bbggrr(self.active_color)
        self:append(string.format("{\\3c&H%s%s%s&\\3a&H60&\\1c&H%s%s%s&\\1a&H20&}",
                r, g, b, r, g, b))
        self:draw_start()
        self:rect_cw(0, (i - 1) * self.item_height, self.w, i * self.item_height)
        self:draw_stop()
    end
    self:draw_text(i)
end

function Menu:draw()
    self.px, self.py, self.w, self.h = self:get_dimensions()
    self.text = ''
    self:draw_backdrop(self.px, self.py, self.w, self.h)
    for i, _ in ipairs(self.items) do
        self:draw_item(i)
    end
    local osd_w = mp.get_property_number("osd-width") or 1280
    local osd_h = mp.get_property_number("osd-height") or 720
    mp.set_osd_ass(osd_w, osd_h, self.text)
end

function Menu:erase()
    local osd_w = mp.get_property_number("osd-width") or 1280
    local osd_h = mp.get_property_number("osd-height") or 720
    mp.set_osd_ass(osd_w, osd_h, '')
end

function Menu:up()
    self.selected = self.selected - 1
    if self.selected == 0 then self.selected = #self.items end
    self:draw()
end

function Menu:down()
    self.selected = self.selected + 1
    if self.selected > #self.items then self.selected = 1 end
    self:draw()
end

return Menu
