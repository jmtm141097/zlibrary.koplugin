local Device = require("device")
local Screen = Device.screen
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local ImageWidget = require("ui/widget/imagewidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ButtonTable = require("ui/widget/buttontable")
local T = require("zlibrary.gettext")
local Cache = require("zlibrary.cache")
local util = require("util")
local Widget = require("ui/widget/widget")
local AsyncHelper = require("zlibrary.async_helper")
local Api = require("zlibrary.api")

local BookDetailsDialog = Widget:extend{
    book = nil,
    parent_zlibrary = nil,
    clear_cache_callback = nil,
}

function BookDetailsDialog:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.width = math.floor(math.min(screen_w, screen_h) * 0.9)
    local max_height = screen_h - Screen:scaleBySize(20) * 2
    local inner_width = self.width - Size.padding.default * 2
    
    local title_text_for_html = (type(self.book.title) == "string" and self.book.title) or ""
    local full_title = util.htmlEntitiesToUtf8(title_text_for_html)
    
    local author_text_for_html = (type(self.book.author) == "string" and self.book.author) or ""
    local full_author = util.htmlEntitiesToUtf8(author_text_for_html)
    
    -- Title area
    local title_widget = CenterContainer:new{
        dimen = Geom:new{ w = inner_width, h = Screen:scaleBySize(60) },
        TextWidget:new{
            text = full_title,
            face = Font:getFace("cfont", 22),
            bold = true,
            max_width = inner_width,
        }
    }
    
    -- Cover area
    local cover_w = math.floor(inner_width * 0.35)
    local cover_h = math.floor(cover_w * 4 / 3)
    
    local cover_widget
    local cover_path = self.book.hash and Cache.getCoverPath(self.book.hash)
    if cover_path and util.fileExists(cover_path) then
        local ok, img = pcall(ImageWidget.new, ImageWidget, {
            file = cover_path, width = cover_w, height = cover_h,
        })
        if ok then 
            cover_widget = CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                img
            }
        end
    end
    
    self.cover_container = FrameContainer:new{
        width = cover_w,
        height = cover_h,
        padding = 0,
        bordersize = Size.border.thin,
        bordercolor = Blitbuffer.COLOR_LIGHT_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        cover_widget or CenterContainer:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            TextWidget:new{
                text = T("No Cover"),
                face = Font:getFace("cfont", 14),
            }
        }
    }
    
    -- Info Area
    local info_w = inner_width - cover_w - Size.padding.default
    local info_items = VerticalGroup:new{ align = "left" }
    
    local function addInfo(label, val)
        if val and val ~= "" and val ~= "N/A" and tostring(val) ~= "0" then
            table.insert(info_items, TextWidget:new{
                text = string.format("%s: %s", label, val),
                face = Font:getFace("cfont", 16),
                max_width = info_w,
                align = "left"
            })
        end
    end
    
    table.insert(info_items, TextWidget:new{
        text = string.format("%s: %s", T("Author"), full_author),
        face = Font:getFace("cfont", 18),
        bold = true,
        max_width = info_w,
        align = "left"
    })
    
    addInfo(T("Year"), self.book.year)
    addInfo(T("Language"), self.book.lang)
    addInfo(T("Format"), self.book.format)
    addInfo(T("Size"), self.book.size)
    addInfo(T("Rating"), self.book.rating and ("\u{2605} " .. self.book.rating))
    
    local header_group = HorizontalGroup:new{
        align = "top",
        self.cover_container,
        WidgetContainer:new{ dimen = Geom:new{ w = Size.padding.default, h = cover_h } },
        info_items,
    }
    
    -- Buttons
    local buttons_table = ButtonTable:new{
        width = inner_width,
        buttons = {
            {
                text = self.book.download and T("Download") or T("Unavailable"),
                enabled = self.book.download ~= nil,
                callback = function()
                    self.parent_zlibrary:downloadBook(self.book)
                end,
            },
            {
                text = T("Close"),
                callback = function()
                    UIManager:close(self)
                end,
            },
        }
    }
    
    local layout = VerticalGroup:new{
        align = "center",
        title_widget,
        header_group,
        WidgetContainer:new{ dimen = Geom:new{ w = self.width, h = Size.padding.default } },
        buttons_table,
    }
    
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            padding = Size.padding.default,
            bordersize = Size.border.thin,
            bordercolor = Blitbuffer.COLOR_BLACK,
            background = Blitbuffer.COLOR_WHITE,
            layout,
        }
    }
end

return BookDetailsDialog
