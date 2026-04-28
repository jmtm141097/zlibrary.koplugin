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
local logger = require("logger")

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
    -- Use the shorter screen dimension so the dialog stays proportional in both
    -- portrait and landscape, and on large tablets (10"+ devices).
    local dialog_w = math.min(screen_w - 2 * fp, math.floor(math.min(screen_w, screen_h) * 0.92))
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
            TextWidget:new{ text = "?", face = Font:getFace("cfont", Screen:scaleBySize(48)) }
        }
    }

    -- 3. Info column
    local info_vg = VerticalGroup:new{ align = "left" }
    local function addMeta(label, val)
        if val and val ~= "" and val ~= "N/A" and tostring(val) ~= "0" then
            table.insert(info_vg, TextWidget:new{
                text      = label .. ": " .. tostring(val),
                face      = Font:getFace("cfont", Screen:scaleBySize(16)),
                max_width = info_w,
            })
        end
    end
    table.insert(info_vg, TextWidget:new{
        text      = author_text,
        face      = Font:getFace("cfont", Screen:scaleBySize(20)),
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

    -- 5. Description (with placeholder if empty for debugging)
    local desc_text = ""
    local book_description = self.book.description
    if type(book_description) == "string" and book_description ~= "" then
        local raw = util.htmlEntitiesToUtf8(book_description)
        raw = raw:gsub("</?%s*[Pp]%s*>", "\n\n")
        raw = raw:gsub("<[Bb][Rr]%s*/?>", "\n")
        raw = raw:gsub("<[^>]*>", "")
        raw = raw:gsub("\194\160", " ")
        raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
        raw = raw:gsub("\n[ \t]*\n[ \t]*\n+", "\n\n")
        desc_text = util.trim(raw)
    end

    -- If still empty, add a placeholder to distinguish between "UI bug" and "No data"
    if desc_text == "" then
        desc_text = "(" .. T("No description available") .. ")"
    end

    local description_widget
    if desc_text ~= "" then
        local is_long = #desc_text > 300
        local preview_text = is_long and (string.sub(desc_text, 1, 297) .. "…") or desc_text
        local open_full_desc = is_long and function()
            local Ui = require("zlibrary.ui")
            Ui.showFullTextDialog(T("Description"), desc_text)
        end or nil

        -- Label is a tappable Button when description is long, plain text otherwise.
        -- It sits at the TOP of the section so it is never clipped by the dialog height.
        local Button = require("ui/widget/button")
        local label = Button:new{
            text           = T("Description") .. (is_long and (" \u{2139}") or ":"),
            callback       = open_full_desc,
            width          = inner_w,
            bordersize     = is_long and Size.border.thin or 0,
            padding_h      = 0,
            padding_v      = Screen:scaleBySize(2),
            text_font_face = "cfont",
            text_font_size = Screen:scaleBySize(16),
            text_font_bold = true,
            align          = "left",
        }

        local text_content = TextBoxWidget:new{
            text      = preview_text,
            face      = Font:getFace("cfont", Screen:scaleBySize(17)),
            width     = inner_w,
            alignment = "justify",
        }

        description_widget = VerticalGroup:new{
            align = "left",
            label,
            WidgetContainer:new{ dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(4) } },
            text_content,
        }
    end

    -- 6. Body content (cover + description)
    local body_vg = VerticalGroup:new{
        align = "center",
        top_section,
        WidgetContainer:new{ dimen = Geom:new{ w = inner_w, h = fp } },
    }
    if description_widget then
        table.insert(body_vg, description_widget)
        table.insert(body_vg, WidgetContainer:new{ dimen = Geom:new{ w = inner_w, h = fp } })
    end

    -- 7. Compute dialog and scroll-area heights
    local body_natural_h = body_vg:getSize().h
    local natural_h = tb_h + fp + body_natural_h + fp + buttons_h + 2 * fb
    local dialog_h  = math.min(natural_h, math.floor(screen_h * 0.94))
    local scroll_h  = math.max(dialog_h - tb_h - 2 * fp - buttons_h - 2 * fb, Screen:scaleBySize(60))

    -- ScrollableContainer child must be at self[1], not in a named field.
    local scroll_area = ScrollableContainer:new{
        dimen = Geom:new{ w = inner_w, h = scroll_h },
        body_vg,
    }
    -- Required by ScrollableContainer so UIManager clips repaints correctly.
    self.cropping_widget = scroll_area

    -- 8. Center dialog on screen
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        FrameContainer:new{
            width      = dialog_w,
            height     = dialog_h,
            background = Blitbuffer.COLOR_WHITE,
            bordersize = fb,
            padding    = 0,
            VerticalGroup:new{
                align = "center",
                title_bar,
                WidgetContainer:new{ dimen = Geom:new{ w = content_w, h = fp } },
                scroll_area,
                WidgetContainer:new{ dimen = Geom:new{ w = content_w, h = fp } },
                buttons_table,
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
