local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local ImageWidget = require("ui/widget/imagewidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local Button = require("ui/widget/button")
local Menu = require("zlibrary.menu")
local IconButton = require("ui/widget/iconbutton")
local ButtonDialog = require("ui/widget/buttondialog")
local TitleBar = require("ui/widget/titlebar")
local ToggleSwitch = require("ui/widget/toggleswitch")
local GestureRange = require("ui/gesturerange")
local InputDialog = require("ui/widget/inputdialog")
local Screen = Device.screen
local T = require("zlibrary.gettext")
local Cache = require("zlibrary.cache")
local Config = require("zlibrary.config")
local util = require("util")
local logger = require("logger")

-- Lazy-load Ui to avoid circular require (ui.lua -> menu.lua, but not -> multisearch_dialog)
local _Ui

local function Ui()
    if not _Ui then _Ui = require("zlibrary.ui") end
    return _Ui
end

local function font(n)
    return math.max(n, math.floor(n * math.sqrt(Screen:getDPI() / 167) + 0.5))
end

local COVER_COLS = 1

-- ─────────────────────────────────────────────────────────────────────────────
-- CoverGrid: single InputContainer that renders a paged grid of book covers
-- and handles tap/hold/swipe through coordinate mapping.
-- ─────────────────────────────────────────────────────────────────────────────
local CoverGrid = InputContainer:extend{
    width  = 0,
    height = 0,
    books  = nil,
    cols   = COVER_COLS,
    rows   = nil, -- optional: force number of rows
    on_select_book = nil,
    on_hold_book   = nil,
    _cell_w  = 0,
    _cell_h  = 0,
    _visible_rows    = 0,
    _first_visible_row = 0,
}

function CoverGrid:init()
    self._nav_h = Screen:scaleBySize(55)
    local nav_h = self._nav_h
    local safety_margin = Size.padding.default * 3
    local grid_h = self.height - nav_h - safety_margin

    local spacer_w = (self.cols > 1) and Size.padding.large or 0
    local total_spacers_w = spacer_w * (self.cols - 1)

    if self.cols == 1 then
        self._cell_w = self.width
        -- Ensure exactly 5 rows fit perfectly with room to spare
        self._cell_h = math.floor(grid_h / 5)
    else
        self._cell_w = math.floor((self.width - total_spacers_w) / self.cols)
        if self.rows then
            self._cell_h = math.floor(grid_h / self.rows)
        else
            self._cell_h = math.floor(self._cell_w * 4 / 3)
        end
    end
    
    self._visible_rows = math.floor(grid_h / self._cell_h)
    
    if self._visible_rows < 1 then self._visible_rows = 1 end
    self._first_visible_row = 0
    self.books = self.books or {}
    self.dimen = Geom:new{ w = self.width, h = self.height }

    self._vg = VerticalGroup:new{ align = "left" }
    self[1] = self._vg
    self:_build()

    if Device:isTouchDevice() then
        self.ges_events = {
            Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
            Hold  = { GestureRange:new{ ges = "hold",  range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
end

function CoverGrid:_build()
    local total_rows = math.max(1, math.ceil(#self.books / self.cols))
    local max_first  = math.max(0, total_rows - self._visible_rows)
    self._first_visible_row = math.min(self._first_visible_row, max_first)

    -- Clear children
    while #self._vg > 0 do
        table.remove(self._vg)
    end

    local spacer_w = (self.cols > 1) and Size.padding.large or 0

    local grid_vg = VerticalGroup:new{ align = "left" }
    for r = 0, self._visible_rows - 1 do
        local actual_row = self._first_visible_row + r
        local row = HorizontalGroup:new{ align = "top" }
        for c = 0, self.cols - 1 do
            if c > 0 then
                table.insert(row, WidgetContainer:new{
                    dimen = Geom:new{ w = spacer_w, h = self._cell_h },
                })
            end
            local idx  = actual_row * self.cols + c + 1
            local book = self.books[idx]
            if book then
                table.insert(row, self:_visualCell(book))
            else
                table.insert(row, WidgetContainer:new{
                    dimen = Geom:new{ w = self._cell_w, h = self._cell_h },
                })
            end
        end
        table.insert(grid_vg, row)
    end
    table.insert(self._vg, grid_vg)
    
    -- Ensure some spacing before the nav bar
    table.insert(self._vg, WidgetContainer:new{
        dimen = Geom:new{ w = self.width, h = Size.padding.default }
    })

    -- Pagination buttons
    local nav_h    = self._nav_h
    local btn_w    = math.floor(self.width * 0.25)
    local label_w  = self.width - 2 * btn_w
    
    local cur_page = math.floor(self._first_visible_row / self._visible_rows) + 1
    local total_pages = math.ceil(total_rows / self._visible_rows)
    if total_pages < 1 then total_pages = 1 end

    local prev_btn = Button:new{
        text      = "\u{25C4}",
        width     = btn_w,
        bordersize = Size.border.thin,
        enabled   = self._first_visible_row > 0,
        callback  = function()
            self._first_visible_row = math.max(0, self._first_visible_row - self._visible_rows)
            self:_build()
            UIManager:setDirty("all", "ui")
        end,
    }

    local next_btn = Button:new{
        text      = "\u{25BA}",
        width     = btn_w,
        bordersize = Size.border.thin,
        enabled   = (self._first_visible_row + self._visible_rows < total_rows) or self.has_more_callback,
        callback  = function()
            if self._first_visible_row + self._visible_rows < total_rows then
                self._first_visible_row = self._first_visible_row + self._visible_rows
                self:_build()
                UIManager:setDirty("all", "ui")
            elseif self.has_more_callback then
                self.has_more_callback()
            end
        end,
    }

    local nav_row = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = nav_h },
        HorizontalGroup:new{
            align = "center",
            prev_btn,
            CenterContainer:new{
                dimen = Geom:new{ w = label_w, h = nav_h },
                TextWidget:new{
                    text = string.format("%d / %d", cur_page, total_pages),
                    face = Font:getFace("cfont", font(14)),
                },
            },
            next_btn,
        },
    }
    table.insert(self._vg, nav_row)
end

function CoverGrid:_visualCell(book)
    local padding   = (self.cols == 1) and Size.padding.default or Size.padding.small
    local border    = Size.border.thin
    -- Account for the outer FrameContainer borders and padding
    local inner_w   = self._cell_w - 2 * padding - 2 * border
    local inner_h   = self._cell_h - 2 * padding - 2 * border

    local cover_path = book.hash and Cache.getCoverPath(book.hash)
    local has_cover = cover_path and util.fileExists(cover_path)

    if self.cols == 1 then
        -- List layout
        -- The cover_frame also has borders, so we subtract them from cover_h
        local cover_h = inner_h - 2 * border
        local cover_w = math.floor(cover_h * 0.75) -- 3:4 ratio
        local spacer_w = Screen:scaleBySize(20)
        local text_w  = inner_w - cover_w - 2 * border - spacer_w - padding

        local cover_frame = FrameContainer:new{
            width       = cover_w,
            height      = cover_h,
            padding     = 0,
            bordersize  = border,
            bordercolor = Blitbuffer.COLOR_LIGHT_GRAY,
            background  = Blitbuffer.COLOR_WHITE,
            has_cover and ImageWidget:new{
                file = cover_path,
                width = cover_w,
                height = cover_h,
            } or CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                TextWidget:new{
                    text = (book.title and book.title ~= "") and book.title:sub(1,1):upper() or "?",
                    face = Font:getFace("cfont", math.max(font(14), math.floor(cover_h * 0.25))),
                }
            }
        }

        local title_text = TextWidget:new{
            text = book.title or T("Unknown Title"),
            face = Font:getFace("cfont", font(20)),
            bold = true,
            max_width = text_w,
            align = "left",
        }
        local author_text = TextWidget:new{
            text = book.author or T("Unknown Author"),
            face = Font:getFace("cfont", font(16)),
            max_width = text_w,
            align = "left",
        }
        -- Add year to metadata
        local details_str = string.format("%s - %s - %s - %s - \u{2605} %s",
            book.year or "N/A",
            book.lang or "N/A",
            book.format or "N/A",
            book.size or "N/A",
            book.rating or "N/A"
        )
        if self.mandatory_func then
            local man_text = self.mandatory_func(book)
            if man_text then
                details_str = details_str .. " | " .. tostring(man_text)
            end
        end
        local details_text = TextWidget:new{
            text = details_str,
            face = Font:getFace("cfont", font(14)),
            max_width = text_w,
            align = "left",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }

        local text_group = VerticalGroup:new{
            align = "left",
            title_text,
            author_text,
            details_text,
        }

        local content_row = HorizontalGroup:new{
            align = "center",
            cover_frame,
            WidgetContainer:new{ dimen = Geom:new{ w = spacer_w, h = inner_h } }, -- spacing
            text_group,
        }

        return FrameContainer:new{
            width       = self._cell_w,
            height      = self._cell_h,
            padding     = padding,
            bordersize  = border,
            bordercolor = Blitbuffer.COLOR_LIGHT_GRAY,
            background  = Blitbuffer.COLOR_WHITE,
            content_row,
        }
    else
        -- Grid layout
        local inner
        if has_cover then
            inner = ImageWidget:new{
                file = cover_path, width = inner_w, height = inner_h,
            }
        end

        if not inner then
            local initial = (book.title and book.title ~= "") and book.title:sub(1,1):upper() or "?"
            inner = CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                TextWidget:new{
                    text = initial,
                    face = Font:getFace("cfont", math.max(14, math.floor(inner_h * 0.25))),
                }
            }
        end

        return FrameContainer:new{
            width       = self._cell_w,
            height      = self._cell_h,
            padding     = padding,
            bordersize  = Size.border.thin,
            bordercolor = Blitbuffer.COLOR_LIGHT_GRAY,
            background  = Blitbuffer.COLOR_WHITE,
            inner,
        }
    end
end

function CoverGrid:_bookAtGesture(ges)
    local rx = ges.pos.x - self.dimen.x
    local ry = ges.pos.y - self.dimen.y
    if rx < 0 or ry < 0 or rx >= self.width or ry >= self._cell_h * self._visible_rows then
        return nil
    end
    local spacer_w = (self.cols > 1) and Size.padding.large or 0
    local col_unit = self._cell_w + spacer_w
    local col = math.floor(rx / col_unit)
    if rx - col * col_unit >= self._cell_w then
        return nil  -- tap fell on a spacer between columns
    end
    col = math.min(col, self.cols - 1)
    local row = math.floor(ry / self._cell_h)
    local idx = (self._first_visible_row + row) * self.cols + col + 1
    return self.books[idx]
end

function CoverGrid:onTap(_, ges)
    local book = self:_bookAtGesture(ges)
    if book and self.on_select_book then self.on_select_book(book) end
    return true
end

function CoverGrid:onHold(_, ges)
    local book = self:_bookAtGesture(ges)
    if book and self.on_hold_book then self.on_hold_book(book) end
    return true
end

function CoverGrid:onSwipe(_, ges)
    local total_rows = math.max(1, math.ceil(#self.books / self.cols))
    if ges.direction == "north" then
        local new_first = self._first_visible_row + self._visible_rows
        self._first_visible_row = math.min(new_first, math.max(0, total_rows - self._visible_rows))
        self:_build()
        UIManager:setDirty("all", "ui")
        return true
    elseif ges.direction == "south" then
        self._first_visible_row = math.max(0, self._first_visible_row - self._visible_rows)
        self:_build()
        UIManager:setDirty("all", "ui")
        return true
    end
    return false
end

function CoverGrid:updateBooks(books, has_more)
    self.books = books or {}
    self.has_more_api_results = has_more
    self._first_visible_row = 0
    self:_build()
    UIManager:setDirty("all", "full")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SearchDialog: main dialog widget
-- ─────────────────────────────────────────────────────────────────────────────
local SearchDialog = InputContainer:extend{
    title             = T("Z-library"),
    width             = nil,
    height            = nil,
    toggle_items      = nil,
    def_position      = nil,
    def_search_input  = nil,
    on_search_callback         = nil,
    on_perform_search_callback = nil,
    on_select_book_callback    = nil,
    on_similar_books_callback  = nil,
    on_fetch_and_show          = nil,
    current_page_loaded  = nil,
    has_more_api_results = nil,
    books  = nil,
    _position = nil,
    _cache    = nil,
    cover_grid_mode   = false,
    no_search_bar     = false,
    _cover_grid       = nil,
    menu_container    = nil,
    _content_height   = nil,
    _frame_inner_width = nil,
}

function SearchDialog:init()
    self.width    = Screen:getWidth()
    self.height   = Screen:getHeight()
    self._position = self.def_position or 1
    self.books    = self.books or {}

    if type(self.on_select_book_callback) ~= "function" then
        self.on_select_book_callback = function() end
    end
    if type(self.on_search_callback) ~= "function" then
        self.on_search_callback = function() end
    end

    -- Validate toggle items
    local toggle_text_list, toggle_values = {}, {}
    if not (type(self.toggle_items) == "table" and #self.toggle_items > 0) then
        error("SearchDialog: toggle_items not configured")
    end
    for i, v in ipairs(self.toggle_items) do
        if type(v) == "table" and v["text"] then
            table.insert(toggle_text_list, v["text"])
            table.insert(toggle_values, i)
        end
    end
    local toggle_items_count = #self.toggle_items
    if self._position > toggle_items_count then self._position = toggle_items_count end

    -- Frame geometry
    local fp = Size.padding.default   -- frame padding
    local fb = Size.border.thin       -- frame border
    local fiw = self.width  - 2*fp - 2*fb
    local fih = self.height - 2*fp - 2*fb
    self._frame_inner_width = fiw

    -- ── TitleBar ──────────────────────────────────────────────────────────
    local titlebar = TitleBar:new{
        title            = self.title,
        with_bottom_line = true,
        close_callback   = function() UIManager:close(self) end,
    }
    local tb_h = titlebar:getSize().h

    -- ── Search bar ────────────────────────────────────────────────────────
    local search_row
    local sr_h = 0
    if not self.no_search_bar then
        local go_btn_w     = Screen:scaleBySize(52)
        local filter_btn_w = Screen:scaleBySize(52)
        local input_w      = fiw - go_btn_w - filter_btn_w

        self._last_query = self.def_search_input or ""

        self._search_display_btn = Button:new{
            text      = self._last_query ~= "" and self._last_query or T("Search books\u{2026}"),
            width     = input_w,
            align     = "left",
            bordersize = Size.border.thin,
            callback  = function() self:_openSearchInput() end,
        }

        local go_btn = Button:new{
            text      = T("\u{f002}"),
            width     = go_btn_w,
            bordersize = Size.border.thin,
            callback  = function()
                if self._last_query ~= "" then
                    self:_doSearch(self._last_query)
                else
                    self:_openSearchInput()
                end
            end,
        }

        local filter_btn = Button:new{
            text      = T("\u{2261}"),
            width     = filter_btn_w,
            bordersize = Size.border.thin,
            callback  = function() self:_showFiltersMenu() end,
        }

        search_row = HorizontalGroup:new{
            dimen = Geom:new{ w = fiw }, align = "center",
            self._search_display_btn, go_btn, filter_btn,
        }
        sr_h = search_row:getSize().h
    end

    -- ── Toggle + Refresh ──────────────────────────────────────────────────
    local toggle_grp
    local tg_h = 0
    if toggle_items_count > 1 then
        local icon_sz = Size.item.height_default + 2*Size.padding.default + 2*Size.border.thin
        local refresh_btn = IconButton:new{
            icon = "cre.render.reload", height = icon_sz, width = icon_sz,
            padding_right = Size.padding.button,
            callback = function() self:forceFetchAndReloadMenu() end,
        }
        local tw = fiw - refresh_btn.width - (refresh_btn.padding_right or 0)
        self.toggle_switch = ToggleSwitch:new{
            width = tw, font_size = font(20), alternate = false,
            enabled = (toggle_items_count ~= 1),
            toggle = toggle_text_list, values = toggle_values,
            config = {
                onConfigChoose = function(_, _values, name, event, args, _position)
                    local pos = type(_position) == "number" and _position or tonumber(name)
                    UIManager:nextTick(function() self:ToggleSwitchCallBack(pos) end)
                end
            }
        }
        toggle_grp = HorizontalGroup:new{
            dimen = Geom:new{ w = fiw }, align = "center",
            self.toggle_switch, refresh_btn,
        }
        self.toggle_switch:setPosition(self._position)
        tg_h = toggle_grp:getSize().h
    end

    -- ── Content area ──────────────────────────────────────────────────────
    local content_h = fih - tb_h - sr_h - tg_h
    content_h = math.max(content_h, Screen:scaleBySize(80))
    self._content_height = content_h

    local content_widget
    if self.cover_grid_mode then
        local active_item = self:getActiveItem()
        self._cover_grid = CoverGrid:new{
            width  = fiw,
            height = content_h,
            books  = self.books,
            cols   = self.cover_grid_cols or COVER_COLS,
            rows   = self.cover_grid_rows,
            mandatory_func = active_item and active_item.mandatory_func,
            on_select_book = function(book) self.on_select_book_callback(book) end,
            on_hold_book   = function(book) self:_showContextMenu(book) end,
            has_more_callback = function()
                if self.has_more_api_results and self:_isEnablePagination() then
                    self:_fetchAndProcessData((self.current_page_loaded or 1) + 1)
                end
            end,
        }
        content_widget = self._cover_grid
        self.menu_container = nil
    else
        self.menu_container = self:_makeMenuWidget(self.books, content_h, fiw)
        content_widget = self.menu_container
        self.menu_container.onMenuSelect = function(_, item) self:onMenuSelect(item) end
        self.menu_container.onMenuHold   = function(_, item) self:onMenuHold(item) end
        self.menu_container.onGotoPage   = function(m, page) self:onMenuGotoPage(m, page) end
        if Device:hasKeys() then
            self.menu_container.key_events.Close    = nil
            self.menu_container.key_events.FocusRight = nil
            self.menu_container.key_events.Right    = nil
            if self.toggle_switch then
                self.toggle_switch:disableFocusManagement(self[1])
            end
        end
    end

    -- container_parent wraps the content widget with a fixed dimen
    self.container_parent = VerticalGroup:new{
        dimen = Geom:new{ w = fiw, h = content_h },
        content_widget,
    }

    -- Build inner layout
    local inner_vgroup = VerticalGroup:new{
        align = "left",
        titlebar,
    }
    if search_row then table.insert(inner_vgroup, search_row) end
    if toggle_grp then table.insert(inner_vgroup, toggle_grp) end
    table.insert(inner_vgroup, self.container_parent)

    self[1] = FrameContainer:new{
        width = self.width, height = self.height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = fb, bordercolor = Blitbuffer.COLOR_BLACK,
        padding = fp,
        inner_vgroup,
    }

    self._cache = Cache:new{ name = "multi_search" }
end

-- ── Menu widget factory (non-grid mode) ──────────────────────────────────────

function SearchDialog:_makeMenuWidget(books, height, width)
    return Menu:new{
        width = (width or self._frame_inner_width) - Screen:scaleBySize(6),
        height = height,
        item_table = self:_getMenuItems(books),
        items_per_page = math.max(4, math.min(10, math.floor(height / Screen:scaleBySize(150)))),
        is_popout = false,
        no_title = true,
        show_captions = true,
        is_borderless = true,
        multilines_show_more_text = true,
        show_parent = self,
    }
end

function SearchDialog:_getMenuItems(books)
    local items = {}
    if type(books) ~= "table" then return items end
    local current_toggle = self:getActiveItem()
    local mandatory_func = current_toggle and current_toggle.mandatory_func
    for i, book in ipairs(books) do
        table.insert(items, {
            book_index = i,
            text = string.format("%s - %s", book.title or T("Untitled"), book.author or T("Unknown Author")),
            mandatory = mandatory_func and mandatory_func(book),
            shortcut  = book.hash and ("cover:" .. book.hash) or nil,
        })
    end
    return items
end

-- ── Context menu (long-press on cover) ────────────────────────────────────────

function SearchDialog:_showContextMenu(book)
    if type(book) ~= "table" then return end
    local dialog
    local buttons = {}
    if book.title then
        table.insert(buttons, {{ text = T("Title") .. ": " .. book.title, callback = function()
            UIManager:close(dialog); self.on_search_callback(tostring(book.title))
        end }})
    end
    if book.author then
        table.insert(buttons, {{ text = T("Author") .. ": " .. book.author, callback = function()
            UIManager:close(dialog); self.on_search_callback(tostring(book.author))
        end }})
    end
    if book.id and book.hash and type(self.on_similar_books_callback) == "function" then
        table.insert(buttons, {{ text = T("More Similar Books"), callback = function()
            UIManager:close(dialog); self.on_similar_books_callback(book)
        end }})
    end
    dialog = ButtonDialog:new{
        buttons = buttons,
        title = string.format("\u{f002} %s", T("Search")),
        title_align = "center",
    }
    Ui().showAndTrackDialog(dialog)
end

-- ── Key navigation ────────────────────────────────────────────────────────────

function SearchDialog:onKeyPress(key)
    if type(key) ~= "table" then return false end
    if key["Right"] or key["Tab"] then
        local pos = (self._position % #self.toggle_items) + 1
        self.toggle_switch:togglePosition(pos, true)
        UIManager:nextTick(function() self:ToggleSwitchCallBack(pos) end)
        return true
    elseif key["Menu"] then
        self.on_search_callback(self.def_search_input); return true
    elseif key["Home"] then
        self:forceFetchAndReloadMenu(); return true
    elseif key["Back"] then
        UIManager:close(self); return true
    end
    return InputContainer.onKeyPress(self, key)
end

function SearchDialog:onClose()
    UIManager:close(self)
    return true
end

-- ── Tab switching ─────────────────────────────────────────────────────────────

function SearchDialog:ToggleSwitchCallBack(_position)
    if not (type(_position) == "number" and _position > 0) then return end
    self._position = _position
    self:clearMenuItems()

    local cache_key, cache_expiry = self:getActiveItemCacheKey()
    if cache_key then
        local cached = self._cache:get(cache_key, cache_expiry)
        if cached then self:reloadFromBookData(cached, true); return true end
    end
    self:_fetchAndProcessData()
end

function SearchDialog:_fetchAndProcessData(page, is_refresh)
    local item = self:getActiveItem()
    if type(item) == "table" and type(item.callback) == "function" then
        UIManager:nextTick(function() item.callback(self, page, is_refresh) end)
    end
end

-- ── Content update ─────────────────────────────────────────────────────────────

function SearchDialog:reloadFromBookData(books, skip_cache, select_number, no_recalculate_dimen)
    self.books = books or {}

    if self.cover_grid_mode and self._cover_grid then
        self._cover_grid:updateBooks(self.books, self.has_more_api_results)
    elseif self.menu_container then
        self.menu_container.item_table = self:_getMenuItems(self.books)
        self.menu_container:updateItems(select_number, no_recalculate_dimen)
    end

    if not skip_cache then
        local ck = self:getActiveItemCacheKey()
        if ck then self._cache:insert(ck, self.books) end
    end
end

function SearchDialog:clearMenuItems()
    self.books = {}
    if self.cover_grid_mode and self._cover_grid then
        self._cover_grid:updateBooks({})
    elseif self.menu_container then
        self.menu_container.item_table = {}
        Menu.updateItems(self.menu_container)
    end
end

function SearchDialog:forceFetchAndReloadMenu()
    local ck = self:getActiveItemCacheKey()
    if ck then self._cache:remove(ck) end
    self:clearMenuItems()
    self:_fetchAndProcessData(nil, true)
end

-- ── Show ───────────────────────────────────────────────────────────────────────

function SearchDialog:fetchAndShow()
    UIManager:show(self)
    if not (self.books and #self.books > 0) then
        self:ToggleSwitchCallBack(self._position)
    else
        self:reloadFromBookData(self.books)
    end
    if type(self.on_fetch_and_show) == "function" then
        self.on_fetch_and_show(self)
    end
    if not self.def_position and self._cache:hasValidCache() then
        self.on_search_callback(self.def_search_input)
    end
end

-- ── Menu callbacks (non-grid mode) ────────────────────────────────────────────

function SearchDialog:onMenuSelect(item)
    if not (item and item.book_index) then return true end
    self.on_select_book_callback(self.books[item.book_index])
    return true
end

function SearchDialog:onMenuHold(item)
    self:_showContextMenu(self.books[item.book_index])
end

-- ── Pagination (non-grid mode) ─────────────────────────────────────────────────

function SearchDialog:onMenuGotoPage(menu_instance, new_page)
    Menu.onGotoPage(menu_instance, new_page)
    if new_page == menu_instance.page_num and self.has_more_api_results and self:_isEnablePagination() then
        self:_fetchAndProcessData((self.current_page_loaded or 1) + 1)
    end
    return true
end

function SearchDialog:extendBatchData(books)
    if not self.current_page_loaded or self.current_page_loaded == 1 then self.books = {} end
    if type(books) == "table" then
        for _, b in ipairs(books) do table.insert(self.books, b) end
    end
    return self.books
end

function SearchDialog:appendBatchDataAndReload(books)
    local all_books = self:extendBatchData(books)
    self:reloadFromBookData(all_books, nil, 1)
end

function SearchDialog:replaceBatchDataAndReload(books)
    self.books = type(books) == "table" and books or {}
    self:reloadFromBookData(self.books, nil, 1)
end

function SearchDialog:setPaginationState(has_more, current_page)
    self.has_more_api_results = has_more
    self.current_page_loaded  = current_page
end

-- ── Search helpers ────────────────────────────────────────────────────────────

function SearchDialog:_openSearchInput()
    local dialog
    dialog = InputDialog:new{
        title  = T("Search Z-Library"),
        input  = self._last_query or "",
        buttons = {{
            {
                text = T("Cancel"),
                id   = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text             = T("Search"),
                is_enter_default = true,
                callback         = function()
                    local q = util.trim(dialog:getInputText() or "")
                    UIManager:close(dialog)
                    if q ~= "" then
                        self._last_query = q
                        self._search_display_btn:setText(q)
                        self:_doSearch(q)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SearchDialog:_doSearch(query)
    if type(self.on_perform_search_callback) == "function" then
        self.on_perform_search_callback(query)
    else
        self.on_search_callback(query)
    end
end

function SearchDialog:_showFiltersMenu()
    local filter_dialog
    filter_dialog = ButtonDialog:new{
        title = T("Filters"),
        buttons = {
            {{ text = T("Language"), callback = function()
                UIManager:close(filter_dialog)
                Ui().showLanguageSelectionDialog(nil)
            end }},
            {{ text = T("Format"), callback = function()
                UIManager:close(filter_dialog)
                Ui().showExtensionSelectionDialog(nil)
            end }},
            {{ text = T("Sort by"), callback = function()
                UIManager:close(filter_dialog)
                Ui().showOrdersSelectionDialog(nil)
            end }},
            {{ text = T("Cancel"), callback = function()
                UIManager:close(filter_dialog)
            end }},
        },
    }
    Ui().showAndTrackDialog(filter_dialog)
end

-- ── Helpers ────────────────────────────────────────────────────────────────────

function SearchDialog:getActiveItem()
    return self.toggle_items[self._position]
end

function SearchDialog:_isEnablePagination()
    local item = self:getActiveItem()
    return item and item["enable_pagination"] == true
end

function SearchDialog:getActiveItemCacheKey()
    local item = self:getActiveItem()
    if item then return item["cache_key"], item["cache_expiry"] end
end

function SearchDialog:setToggleTitle(position, title)
    if position < 1 or position > #self.toggle_items then return end
    self.toggle_items[position].text = title or ""
    if self.toggle_switch and self.toggle_switch.toggle then
        self.toggle_switch.toggle[position] = title or ""
        self.toggle_switch:update()
    end
    UIManager:setDirty("all", "ui")
end

return SearchDialog
