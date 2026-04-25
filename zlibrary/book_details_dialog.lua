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
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ButtonTable = require("ui/widget/buttontable")
local TitleBar = require("ui/widget/titlebar")
local InputContainer = require("ui/widget/container/inputcontainer")
local T = require("zlibrary.gettext")
local Cache = require("zlibrary.cache")
local util = require("util")

local BookDetailsDialog = InputContainer:extend{
    book = nil,
    parent_zlibrary = nil,
    clear_cache_callback = nil,
}

function BookDetailsDialog:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    local title_text  = util.htmlEntitiesToUtf8(self.book.title  or T("Book Details"))
    local author_text = util.htmlEntitiesToUtf8(self.book.author or T("Unknown Author"))

    -- Layout constants
    local fb       = Size.border.window
    local fp       = Screen:scaleBySize(16)
    local dialog_w = math.min(screen_w - 2 * fp, Screen:scaleBySize(520))
    local content_w = dialog_w - 2 * fb   -- inside the frame border (no frame padding)
    local inner_w   = content_w - 2 * fp  -- content with manual horizontal padding

    -- 1. Title Bar
    local title_bar = TitleBar:new{
        title          = title_text,
        width          = content_w,
        close_callback = function() UIManager:close(self) end,
    }
    local tb_h = title_bar:getSize().h

    -- 2. Cover
    local border  = Size.border.thin
    local cover_w = math.floor(inner_w * 0.40)
    local cover_h = math.floor(cover_w * 1.5)
    local info_w  = inner_w - cover_w - fp

    local cover_path = self.book.hash and Cache.getCoverPath(self.book.hash)
    local cover_widget
    if cover_path and util.fileExists(cover_path) then
        local ok, img = pcall(ImageWidget.new, ImageWidget, {
            file   = cover_path,
            width  = cover_w - 2 * border,
            height = cover_h - 2 * border,
        })
        if ok then cover_widget = img end
    end

    local cover_frame = FrameContainer:new{
        width       = cover_w,
        height      = cover_h,
        padding     = 0,
        bordersize  = border,
        bordercolor = Blitbuffer.COLOR_LIGHT_GRAY,
        cover_widget or CenterContainer:new{
            dimen = Geom:new{ w = cover_w - 2*border, h = cover_h - 2*border },
            TextWidget:new{ text = "?", face = Font:getFace("cfont", 48) }
        }
    }

    -- 3. Info column
    local info_vg = VerticalGroup:new{ align = "left" }
    local function addMeta(label, val)
        if val and val ~= "" and val ~= "N/A" and tostring(val) ~= "0" then
            table.insert(info_vg, TextWidget:new{
                text      = label .. ": " .. tostring(val),
                face      = Font:getFace("cfont", 16),
                max_width = info_w,
            })
        end
    end
    table.insert(info_vg, TextWidget:new{
        text      = author_text,
        face      = Font:getFace("cfont", 20),
        bold      = true,
        max_width = info_w,
    })
    addMeta(T("Year"),     self.book.year)
    addMeta(T("Language"), self.book.lang)
    addMeta(T("Format"),   self.book.format)
    addMeta(T("Size"),     self.book.size)
    addMeta(T("Pages"),    self.book.pages)
    if self.book.publisher and self.book.publisher ~= "" then
        addMeta(T("Publisher"), util.htmlEntitiesToUtf8(self.book.publisher))
    end
    if self.book.rating then addMeta(T("Rating"), "\u{2605} " .. self.book.rating) end

    local top_section = HorizontalGroup:new{
        align = "top",
        cover_frame,
        WidgetContainer:new{ dimen = Geom:new{ w = fp, h = cover_h } },
        info_vg,
    }

    -- 4. Buttons
    local action_row_1 = {
        {
            text     = self.book.download and T("Download") or T("Unavailable"),
            enabled  = self.book.download ~= nil,
            callback = function() self.parent_zlibrary:downloadBook(self.book) end,
        },
        {
            text     = T("Comments"),
            callback = function() self.parent_zlibrary:fetchAndDisplayComments(self.book) end,
        },
    }
    local in_favorites = self.parent_zlibrary:isBookInFavorites(self.book) == true
    local fav_text     = in_favorites and ("\u{2665} " .. T("Remove Fav")) or ("\u{2661} " .. T("Add Fav"))
    local action_row_2 = {
        {
            text     = T("Similar"),
            callback = function() self.parent_zlibrary:searchSimilarBooks(self.book) end,
        },
        {
            text     = fav_text,
            callback = function()
                local reload = function()
                    UIManager:close(self)
                    local Ui = require("zlibrary.ui")
                    Ui.showBookDetails(self.parent_zlibrary, self.book, self.clear_cache_callback)
                end
                if in_favorites then
                    self.parent_zlibrary:unfavoriteBook(self.book, reload)
                else
                    self.parent_zlibrary:favoriteBook(self.book, reload)
                end
            end,
        },
    }
    local buttons_table = ButtonTable:new{
        width   = inner_w,
        buttons = { action_row_1, action_row_2 },
    }
    local buttons_h = buttons_table:getSize().h

    -- 5. Description (only when text exists)
    local desc_text = ""
    if type(self.book.description) == "string" and self.book.description ~= "" then
        local raw = util.htmlEntitiesToUtf8(self.book.description)
        -- Paragraph ends become blank lines
        raw = raw:gsub("</%s*[Pp]%s*>", "\n\n")
        -- <br> variants become single newlines
        raw = raw:gsub("<[Bb][Rr]%s*/?>", "\n")
        -- Strip all remaining HTML tags (including empty ones like <>)
        raw = raw:gsub("<[^>]*>", "")
        -- Normalize non-breaking space (UTF-8: \194\160) to regular space
        raw = raw:gsub("\194\160", " ")
        -- Normalize line endings and collapse runs of 3+ blank lines into 2
        raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
        raw = raw:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
        desc_text = util.trim(raw)
    end
    local description_widget
    local desc_h = 0
    if desc_text ~= "" then
        local max_desc_h = math.min(Screen:scaleBySize(200), math.floor(screen_h * 0.25))
        local text_box = TextBoxWidget:new{
            text  = desc_text,
            face  = Font:getFace("cfont", 17),
            width = inner_w,
        }
        desc_h = math.min(text_box:getSize().h, max_desc_h)
        description_widget = ScrollableContainer:new{
            dimen  = Geom:new{ w = inner_w, h = desc_h },
            widget = text_box,
        }
    end

    -- 6. Total dialog height (content + spacers + frame border)
    local total_h = tb_h + cover_h + buttons_h + 3 * fp + 2 * fb
    if description_widget then
        total_h = total_h + desc_h + fp
    end
    total_h = math.min(total_h, math.floor(screen_h * 0.92))

    -- 7. Assemble inner content
    local main_layout = VerticalGroup:new{
        align = "center",
        top_section,
        WidgetContainer:new{ dimen = Geom:new{ w = inner_w, h = fp } },
    }
    if description_widget then
        table.insert(main_layout, description_widget)
        table.insert(main_layout, WidgetContainer:new{ dimen = Geom:new{ w = inner_w, h = fp } })
    end
    table.insert(main_layout, buttons_table)

    -- 8. Center dialog on screen
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        FrameContainer:new{
            width      = dialog_w,
            height     = total_h,
            background = Blitbuffer.COLOR_WHITE,
            bordersize = fb,
            padding    = 0,
            VerticalGroup:new{
                align = "center",
                title_bar,
                CenterContainer:new{
                    dimen = Geom:new{ w = content_w, h = total_h - tb_h - 2*fb },
                    main_layout,
                },
            },
        },
    }
end

function BookDetailsDialog:onShow()
    UIManager:setDirty(self, "ui")
end

function BookDetailsDialog:onClose()
    UIManager:close(self)
    return true
end

return BookDetailsDialog
