-- TilerUI.lua
-- Management window for Tiler.  Open with /tiler ui.
--
-- Uses virtual row recycling: exactly NUM_VIS row frames sit at fixed
-- positions inside a plain Frame.  Scrolling swaps their data content
-- rather than moving a large content frame, avoiding WoW's scroll-frame
-- mouse-event bleed outside the clip rect.
--
-- Hover-to-highlight (game frame glow + reverse-hover row highlight) is
-- not yet implemented.

local WIN_W   = 560
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
local COL_VIS   = { x = 0,   w = 14  }
local COL_NAME  = { x = 18,  w = 220 }
local COL_SRC   = { x = 242, w = 50  }
local COL_ALLOW = { x = 296, w = 72  }
local COL_PRIO  = { x = 372, w = 70 }
local INNER_W   = COL_PRIO.x + COL_PRIO.w     -- 442

local SRC_COL   = { default = "|cff888888", user = "|cff44aaff", scan = "|cff666666" }
local CHECK_TEX = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14|t"
local CROSS_TEX = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14:14|t"

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

    -- Split into three groups:
    --   g1: visible + tiling enabled
    --   g2: visible + tiling disabled
    --   g3: not visible
    local g1, g2, g3 = {}, {}, {}
    for _, d in ipairs(list) do
        local vis   = d.frame and d.frame:IsShown()
        local tiled = d.source == "default" or d.allowed
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
-- Note: the row Frame itself has NO EnableMouse.  Buttons inside it
-- receive clicks as Button frames independently; a row-level EnableMouse
-- would silently swallow clicks on non-button areas and can interfere
-- with button event dispatch in certain WoW Classic frame hierarchies.
------------------------------------------------------------------------
local function NewRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    row:SetWidth(INNER_W)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)

    row.divider = row:CreateTexture(nil, "ARTWORK")
    row.divider:SetPoint("LEFT",  row, "LEFT",  4, 0)
    row.divider:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.divider:SetHeight(1)
    row.divider:SetColorTexture(0.35, 0.35, 0.35, 0.7)
    row.divider:Hide()

    row.dot = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.dot:SetPoint("LEFT", row, "LEFT", COL_VIS.x, 0)
    row.dot:SetWidth(COL_VIS.w)
    row.dot:SetJustifyH("CENTER")

    row.nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.nameFS:SetPoint("LEFT", row, "LEFT", COL_NAME.x, 0)
    row.nameFS:SetWidth(COL_NAME.w)
    row.nameFS:SetJustifyH("LEFT")
    row.nameFS:SetWordWrap(false)

    row.srcFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.srcFS:SetPoint("LEFT", row, "LEFT", COL_SRC.x, 0)
    row.srcFS:SetWidth(COL_SRC.w)
    row.srcFS:SetJustifyH("CENTER")

    local ab = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    ab:SetPoint("LEFT", row, "LEFT", COL_ALLOW.x, 0)
    ab:SetSize(COL_ALLOW.w, ROW_H - 4)
    row.allowBtn = ab

    local eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    eb:SetPoint("LEFT", row, "LEFT", COL_PRIO.x + 4, 0)
    eb:SetSize(68, ROW_H - 4)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb:SetMaxLetters(3)
    eb:SetJustifyH("CENTER")
    row.prioEB = eb

    return row
end

------------------------------------------------------------------------
-- UpdateRow — populate row with data entry d (display slot idx, 1-based)
------------------------------------------------------------------------
local function UpdateRow(row, d, idx)
    row._data = d

    -- Gap/separator row
    if d._gap then
        row.bg:SetColorTexture(0, 0, 0, 0)
        row.divider:Show()
        row.dot:SetText("")
        row.nameFS:SetText("")
        row.srcFS:SetText("")
        row.allowBtn:Hide()
        row.prioEB:Hide()
        return
    end

    row.divider:Hide()
    row.allowBtn:Show()
    row.prioEB:Show()

    local f   = d.frame
    local vis = f and f:IsShown()

    if idx % 2 == 0 then
        row.bg:SetColorTexture(0.08, 0.08, 0.10, 0.6)
    else
        row.bg:SetColorTexture(0.05, 0.05, 0.07, 0.4)
    end

    row.dot:SetText(vis and "|cff00ff00o|r" or "|cff444444o|r")
    row.nameFS:SetText(vis and ("|cffffdd00"..d.name.."|r") or ("|cffaaaaaa"..d.name.."|r"))
    row.srcFS:SetText((SRC_COL[d.source] or "")..d.source.."|r")

    if d.source == "default" then
        row.allowBtn:SetText("default")
        row.allowBtn:Disable()
    elseif d.allowed then
        row.allowBtn:SetText(CHECK_TEX)
        row.allowBtn:Enable()
        row.allowBtn:SetScript("OnClick", function()
            Tiler.Disallow(d.name)
            d.allowed = false
            UpdateRow(row, d, idx)
        end)
    else
        row.allowBtn:SetText(CROSS_TEX)
        row.allowBtn:Enable()
        row.allowBtn:SetScript("OnClick", function()
            Tiler.Allow(d.name)
            d.allowed = true
            UpdateRow(row, d, idx)
        end)
    end

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
                if d.source == "default" or d.allowed then nAllowed = nAllowed + 1 end
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
    Hdr("",         COL_VIS.x,   COL_VIS.w,   "CENTER")
    Hdr("Window",   COL_NAME.x,  COL_NAME.w,  "LEFT")
    Hdr("Source",   COL_SRC.x,   COL_SRC.w,   "CENTER")
    Hdr("Tile",     COL_ALLOW.x, COL_ALLOW.w, "CENTER")
    Hdr("Priority", COL_PRIO.x,  COL_PRIO.w,  "CENTER")

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

    -- Priority column tooltip (FontStrings can't receive mouse events;
    -- an invisible button overlay handles the hover)
    local prioTipBtn = CreateFrame("Button", nil, win)
    prioTipBtn:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + COL_PRIO.x, -(TITLE_H + 2))
    prioTipBtn:SetSize(COL_PRIO.w, HDR_H)
    prioTipBtn:EnableMouse(true)
    prioTipBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Priority")
        GameTooltip:AddLine("Controls tiling order, left to right.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffaaaaaa0|r   — tile this window first (far left)", 1, 1, 1, true)
        GameTooltip:AddLine("|cffaaaaaa100|r — tile this window last (far right)", 1, 1, 1, true)
        GameTooltip:AddLine("Default is |cffaaaaaa50|r.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    prioTipBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
