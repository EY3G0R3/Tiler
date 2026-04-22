-- TilerUI.lua
-- Management window for Tiler.  Open with /tiler ui.
--
-- Uses virtual row recycling: exactly NUM_VIS row frames sit at fixed
-- positions inside a plain Frame.  Scrolling swaps their data content
-- rather than moving a large content frame, avoiding WoW's scroll-frame
-- mouse-event bleed outside the clip rect.

local WIN_W   = 750
local WIN_H   = 650
local PAD     = 12
local ROW_H   = 24
local TITLE_H = 34   -- window top → column-header row
local HDR_H   = 18   -- column-header row height
local FOOT_H  = 38   -- reserved at the bottom for footer widgets

local LIST_TOP = TITLE_H + HDR_H + 8           -- y from win top to list area
local LIST_H   = WIN_H - LIST_TOP - FOOT_H     -- 402 px
local NUM_VIS  = math.floor(LIST_H / ROW_H)    -- 16 fully-visible rows

-- Column layout (x offsets relative to the list frame)
local COL_NAME  = { x = 4,   w = 270 }
local COL_SRC   = { x = 278, w = 44  }
local COL_PRIO  = { x = 326, w = 62  }
local COL_PLACE = { x = 392, w = 296 }
local INNER_W   = COL_PLACE.x + COL_PLACE.w   -- 688

local PLACE_OPTS = { "auto", "left", "center", "right", "float" }
local BTN_GAPS   = { 8, 1, 1, 8 }   -- gaps after buttons 1-4 (auto|left-center-right|float)
local BTN_W      = math.floor((COL_PLACE.w - (8+1+1+8)) / #PLACE_OPTS)  -- 55

local SRC_COL   = { default = "|cff888888", user = "|cff44aaff", scan = "|cff666666" }


local function GetPlacement(d)
    local z = Tiler.GetZone(d.name)
    if z == "float" then return "float" end
    if z then return z end
    if d.source == "default" or d.allowed then return "auto" end
    return "float"
end

local function SetPlacement(d, placement)
    if placement == "float" then
        if d.source == "default" then
            Tiler.SetZone(d.name, "float")
        else
            if d.allowed then Tiler.Disallow(d.name) end
            Tiler.ClearZone(d.name)
            d.allowed = false
        end
    elseif placement == "auto" then
        Tiler.ClearZone(d.name)
        if d.source ~= "default" and not d.allowed then
            Tiler.Allow(d.name)
            d.allowed = true
        end
    else
        Tiler.SetZone(d.name, placement)
        if d.source ~= "default" and not d.allowed then
            Tiler.Allow(d.name)
            d.allowed = true
        end
    end
end

------------------------------------------------------------------------
-- Module state
------------------------------------------------------------------------
TilerUI = {}

local _win          = nil   -- main window; nil until first Toggle
local _rows         = {}    -- exactly NUM_VIS row frames at fixed positions
local _data         = {}    -- full sorted list from GetRows()
local _scrollOffset = 0     -- 0-based index of first visible data entry

------------------------------------------------------------------------
-- GetRows — collect every window the user might care about
------------------------------------------------------------------------
local function GetRows()
    local seen = {}
    local list = {}

    for name in pairs(Tiler.ALLOWED_NAMES) do
        if not seen[name] then
            seen[name] = true
            list[#list+1] = { name=name, source="default", frame=_G[name], allowed=true }
        end
    end

    for name in pairs(TilerDB.allowed or {}) do
        if not seen[name] then
            seen[name] = true
            list[#list+1] = { name=name, source="user", frame=_G[name], allowed=true }
        end
    end

    for _, f in ipairs({ UIParent:GetChildren() }) do
        local ok, nm, w, h = pcall(function()
            return f:GetName(), f:GetWidth() or 0, f:GetHeight() or 0
        end)
        if ok and nm and not seen[nm]
           and f:IsVisible()
           and w >= Tiler.MIN_WIDTH and h >= Tiler.MIN_HEIGHT
        then
            seen[nm] = true
            list[#list+1] = { name=nm, source="scan", frame=f, allowed=false }
        end
    end

    -- Object-tracked frames (e.g. unnamed AceGUI windows like MailBank) that
    -- won't appear in any of the name-based loops above.
    for f in pairs(Tiler.AllowedObjects) do
        local nm = Tiler.AllowedObjectNames[f] or f:GetName()
        if nm and not seen[nm] then
            seen[nm] = true
            list[#list+1] = { name=nm, source="default", frame=f, allowed=true }
        end
    end

    -- Split into three groups:
    --   g1: visible + tiling enabled
    --   g2: visible + tiling disabled
    --   g3: not visible
    local g1, g2, g3 = {}, {}, {}
    for _, d in ipairs(list) do
        local vis   = d.frame and d.frame:IsShown()
        local tiled = (d.source == "default" or d.allowed)
                      and Tiler.GetZone(d.name) ~= "float"
        if vis and tiled then
            g1[#g1+1] = d
        elseif vis then
            g2[#g2+1] = d
        else
            g3[#g3+1] = d
        end
    end

    local function sortGroup(g)
        table.sort(g, function(a, b)
            local pa = Tiler.GetPriority(a.name)
            local pb = Tiler.GetPriority(b.name)
            if pa ~= pb then return pa < pb end
            return a.name < b.name
        end)
    end
    sortGroup(g1); sortGroup(g2); sortGroup(g3)

    local result = {}
    for _, d in ipairs(g1) do result[#result+1] = d end
    if #g1 > 0 and (#g2 > 0 or #g3 > 0) then
        result[#result+1] = { _gap = true }
    end
    for _, d in ipairs(g2) do result[#result+1] = d end
    if #g2 > 0 and #g3 > 0 then
        result[#result+1] = { _gap = true }
    end
    for _, d in ipairs(g3) do result[#result+1] = d end

    for i, d in ipairs(result) do d._idx = i end
    return result
end

------------------------------------------------------------------------
-- NewRow — create one row frame with all its child widgets
-- EnableMouse is set on the row Frame itself.  Child widgets (eb, pb)
-- get priority in hit-testing; row catches hover over text/background.
-- OnLeave uses MouseIsOver(row) to avoid flicker when moving between
-- the row and its children.
------------------------------------------------------------------------
local function NewRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    row:SetWidth(INNER_W)
    row:EnableMouse(true)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)

    row.divider = row:CreateTexture(nil, "ARTWORK")
    row.divider:SetPoint("LEFT",  row, "LEFT",  4, 0)
    row.divider:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.divider:SetHeight(1)
    row.divider:SetColorTexture(0.35, 0.35, 0.35, 0.7)
    row.divider:Hide()

    row.nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.nameFS:SetPoint("LEFT", row, "LEFT", COL_NAME.x, 0)
    row.nameFS:SetWidth(COL_NAME.w)
    row.nameFS:SetJustifyH("LEFT")
    row.nameFS:SetWordWrap(false)

    row.srcFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.srcFS:SetPoint("LEFT", row, "LEFT", COL_SRC.x, 0)
    row.srcFS:SetWidth(COL_SRC.w)
    row.srcFS:SetJustifyH("CENTER")

    local eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    eb:SetPoint("LEFT", row, "LEFT", COL_PRIO.x + 4, 0)
    eb:SetSize(66, ROW_H - 4)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb:SetMaxLetters(3)
    eb:SetJustifyH("CENTER")
    row.prioEB = eb

    row.placeBtn = {}
    local btx = COL_PLACE.x
    for i, opt in ipairs(PLACE_OPTS) do
        local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        b:SetPoint("LEFT", row, "LEFT", btx, 0)
        b:SetSize(BTN_W, ROW_H - 4)
        b:SetText(opt)
        row.placeBtn[i]   = b
        row.placeBtn[opt] = b
        btx = btx + BTN_W + (BTN_GAPS[i] or 0)
    end

    local function setHighlight(on)
        if not row._data or row._data._gap then return end
        if on then
            row.bg:SetColorTexture(0.22, 0.18, 0.06, 0.85)
        elseif row._slotIdx and row._slotIdx % 2 == 0 then
            row.bg:SetColorTexture(0.08, 0.08, 0.10, 0.6)
        else
            row.bg:SetColorTexture(0.05, 0.05, 0.07, 0.4)
        end
    end
    local function onLeave()
        if not MouseIsOver(row) then setHighlight(false) end
    end
    row:SetScript("OnEnter", function() setHighlight(true) end)
    row:SetScript("OnLeave", onLeave)
    eb:SetScript("OnEnter",  function() setHighlight(true) end)
    eb:SetScript("OnLeave",  onLeave)
    for i = 1, #PLACE_OPTS do
        row.placeBtn[i]:SetScript("OnEnter", function() setHighlight(true) end)
        row.placeBtn[i]:SetScript("OnLeave", onLeave)
    end

    return row
end

------------------------------------------------------------------------
-- UpdateRow — populate row with data entry d (display slot idx, 1-based)
------------------------------------------------------------------------
local function UpdateRow(row, d, idx)
    row._data    = d
    row._slotIdx = idx

    -- Gap/separator row
    if d._gap then
        row.bg:SetColorTexture(0, 0, 0, 0)
        row.divider:Show()
        row.nameFS:SetText("")
        row.srcFS:SetText("")
        row.prioEB:Hide()
        for i = 1, #PLACE_OPTS do row.placeBtn[i]:Hide() end
        return
    end

    row.divider:Hide()
    row.prioEB:Show()
    for i = 1, #PLACE_OPTS do row.placeBtn[i]:Show() end

    local f   = d.frame
    local vis = f and f:IsShown()

    if idx % 2 == 0 then
        row.bg:SetColorTexture(0.08, 0.08, 0.10, 0.6)
    else
        row.bg:SetColorTexture(0.05, 0.05, 0.07, 0.4)
    end

    row.nameFS:SetText(vis and ("|cffffdd00"..d.name.."|r") or ("|cffaaaaaa"..d.name.."|r"))
    row.srcFS:SetText((SRC_COL[d.source] or "")..d.source.."|r")

    local function refreshPrio()
        local hp = TilerDB.priorities and TilerDB.priorities[d.name]
        local np = Tiler.GetPriority(d.name)
        row.prioEB:SetText(tostring(np))
        if hp then
            row.prioEB:SetTextColor(1, 0.87, 0, 1)
        else
            row.prioEB:SetTextColor(0.5, 0.5, 0.5, 1)
        end
    end
    refreshPrio()

    row.prioEB:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            Tiler.SetPriority(d.name, val)
        end
        self:ClearFocus()
        refreshPrio()
    end)
    row.prioEB:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        refreshPrio()
    end)

    local function refreshPlace()
        local p = GetPlacement(d)
        for _, opt in ipairs(PLACE_OPTS) do
            if p == opt then
                row.placeBtn[opt]:GetFontString():SetTextColor(1, 0.82, 0, 1)
            else
                row.placeBtn[opt]:GetFontString():SetTextColor(0.4, 0.4, 0.4, 1)
            end
        end
    end
    refreshPlace()
    for _, opt in ipairs(PLACE_OPTS) do
        local captOpt = opt
        row.placeBtn[captOpt]:SetScript("OnClick", function()
            SetPlacement(d, captOpt)
            refreshPlace()
        end)
    end

end

------------------------------------------------------------------------
-- RefreshRows — repaint the NUM_VIS fixed rows from _data + _scrollOffset
------------------------------------------------------------------------
local function RefreshRows()
    for i = 1, NUM_VIS do
        local di  = _scrollOffset + i
        local row = _rows[i]
        if di <= #_data then
            UpdateRow(row, _data[di], i)
            row:Show()
        else
            row:Hide()
        end
    end

    if _win then
        local total    = 0
        local nAllowed = 0
        for _, d in ipairs(_data) do
            if not d._gap then
                total = total + 1
                if (d.source == "default" or d.allowed) and Tiler.GetZone(d.name) ~= "float" then nAllowed = nAllowed + 1 end
            end
        end
        local maxOff = math.max(0, #_data - NUM_VIS)
        if _win.scrollbar then
            _win.scrollbar:SetMinMaxValues(0, maxOff)
            _win.scrollbar:SetShown(maxOff > 0)
        end
        local scroll = total > NUM_VIS
            and ("  ["..(  _scrollOffset + 1).."-"
                 ..math.min(_scrollOffset + NUM_VIS, total).." / "..total.."]")
            or  ""
        _win.statusFS:SetText(total.." windows · "..nAllowed.." allowed"..scroll)
    end
end

------------------------------------------------------------------------
-- ScrollTo — clamp offset and redraw rows
------------------------------------------------------------------------
local function ScrollTo(offset)
    local maxOff  = math.max(0, #_data - NUM_VIS)
    _scrollOffset = math.max(0, math.min(offset, maxOff))
    if _win and _win.scrollbar then
        _win.scrollbar:SetValue(_scrollOffset)
    end
    RefreshRows()
end

------------------------------------------------------------------------
-- Build — construct the window once; left hidden
------------------------------------------------------------------------
local function Build()
    local win = CreateFrame("Frame", "TilerUIWindow", UIParent)
    win:SetSize(WIN_W, WIN_H)
    win:SetPoint("CENTER")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:EnableMouseWheel(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop",  win.StopMovingOrSizing)
    win:SetScript("OnMouseWheel", function(_, delta)
        ScrollTo(_scrollOffset - delta * 3)
    end)
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    if BackdropTemplateMixin then Mixin(win, BackdropTemplateMixin) end
    win:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left=11, right=12, top=12, bottom=11 },
    })
    win:SetBackdropColor(0, 0, 0, 1)
    tinsert(UISpecialFrames, "TilerUIWindow")

    -- Title
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", win, "TOP", 0, -15)
    title:SetText("Tiler — Window Manager")

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -5, -5)
    close:SetScript("OnClick", function() win:Hide() end)

    -- Column headers
    local function Hdr(text, cx, cw, justify)
        local fs = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + cx, -(TITLE_H + 2))
        fs:SetWidth(cw)
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText("|cffaaaaaa"..text.."|r")
    end
    Hdr("Window",    COL_NAME.x,  COL_NAME.w,  "LEFT")
    Hdr("Source",    COL_SRC.x,   COL_SRC.w,   "CENTER")
    Hdr("Priority",  COL_PRIO.x,  COL_PRIO.w,  "CENTER")
    Hdr("Placement", COL_PLACE.x, COL_PLACE.w, "CENTER")

    -- Divider under headers
    local div = win:CreateTexture(nil, "ARTWORK")
    div:SetPoint("TOPLEFT",  win, "TOPLEFT",  PAD,  -(TITLE_H + HDR_H + 4))
    div:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, -(TITLE_H + HDR_H + 4))
    div:SetHeight(1)
    div:SetColorTexture(0.4, 0.4, 0.4, 0.8)

    -- Footer
    local arrBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    arrBtn:SetSize(110, 22)
    arrBtn:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", PAD + 8, 10)
    arrBtn:SetText("Arrange Now")
    arrBtn:SetScript("OnClick", function() Tiler.Arrange() end)

    local refBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    refBtn:SetSize(80, 22)
    refBtn:SetPoint("LEFT", arrBtn, "RIGHT", 6, 0)
    refBtn:SetText("Refresh")
    refBtn:SetScript("OnClick", function() TilerUI.Refresh() end)

    win.statusFS = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    win.statusFS:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD, 13)
    win.statusFS:SetJustifyH("RIGHT")

    -- Column header tooltips (FontStrings can't receive mouse events;
    -- invisible button overlays handle hover)
    local function TipBtn(cx, cw, title, lines)
        local btn = CreateFrame("Button", nil, win)
        btn:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + cx, -(TITLE_H + 2))
        btn:SetSize(cw, HDR_H)
        btn:EnableMouse(true)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(title)
            for _, line in ipairs(lines) do
                GameTooltip:AddLine(line, 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    TipBtn(COL_PRIO.x, COL_PRIO.w, "Priority", {
        "Controls tiling order, left to right.",
        " ",
        "|cffaaaaaa0|r   — tile this window first (far left)",
        "|cffaaaaaa100|r — tile this window last (far right)",
        "Default is |cffaaaaaa50|r.",
    })

    TipBtn(COL_PLACE.x, COL_PLACE.w, "Placement", {
        "Click a mode to apply it immediately.",
        " ",
        "auto   — tiled, layout engine decides position",
        "left   — pinned to the left column",
        "center — pinned to the center column",
        "right  — pinned to the right column",
        "float  — not tiled (window floats freely)",
    })

    -- Scrollbar (visible only when list overflows NUM_VIS rows)
    local SB_W = 14
    local sb = CreateFrame("Slider", nil, win)
    sb:SetOrientation("VERTICAL")
    sb:SetPoint("TOPRIGHT",    win, "TOPRIGHT",    -PAD, -LIST_TOP)
    sb:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD,  FOOT_H)
    sb:SetWidth(SB_W)
    sb:SetMinMaxValues(0, 0)
    sb:SetValue(0)
    sb:SetValueStep(1)
    local sbBg = sb:CreateTexture(nil, "BACKGROUND")
    sbBg:SetAllPoints()
    sbBg:SetColorTexture(0.08, 0.08, 0.10, 0.8)
    sb:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    sb:GetThumbTexture():SetSize(SB_W, 20)
    sb:SetScript("OnValueChanged", function(self, value, userInput)
        if userInput then ScrollTo(math.floor(value + 0.5)) end
    end)
    sb:Hide()
    win.scrollbar = sb

    -- List area: plain Frame with NUM_VIS rows at fixed positions
    local lf = CreateFrame("Frame", nil, win)
    lf:SetPoint("TOPLEFT",     win, "TOPLEFT",     PAD,  -LIST_TOP)
    lf:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD,  FOOT_H)

    for i = 1, NUM_VIS do
        local row = NewRow(lf)
        row:SetPoint("TOPLEFT", lf, "TOPLEFT", 0, -(i - 1) * ROW_H)
        _rows[i] = row
        row:Hide()
    end

    win:Hide()
    _win = win
end

------------------------------------------------------------------------
-- Refresh — rebuild data and repaint rows
------------------------------------------------------------------------
function TilerUI.Refresh()
    if not _win or not _win:IsShown() then return end
    _data = GetRows()
    ScrollTo(_scrollOffset)
end

------------------------------------------------------------------------
-- Toggle — show or hide the window
------------------------------------------------------------------------
function TilerUI.Toggle()
    if not _win then Build() end
    if _win:IsShown() then
        _win:Hide()
    else
        _win:Show()
        TilerUI.Refresh()
        Tiler.Schedule()   -- re-resolve hooks (TilerUIWindow is lazily created)
    end
end
