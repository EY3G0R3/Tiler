-- Tiler.lua
-- Dynamic tiling window manager for WoW Classic Era.
-- Discovers visible windows from an explicit allowlist and arranges them
-- left-to-right (tops aligned, GAP px apart), wrapping to a new row when
-- the strip would overflow the screen.
--
-- Commands:
--   /tiler                          arrange all allowed windows
--   /tiler debug                    list every frame that would be tiled
--   /tiler scan                     list all visible candidate frames (allowed or not)
--   /tiler allow     <name>         add a frame to the persistent allowlist
--   /tiler remove    <name>         remove a frame from the persistent allowlist
--   /tiler list                     show hardcoded + user-added allowlist
--   /tiler priority  <name> <n>     set sort priority (lower = further left; default 50)
--   /tiler priority  <name>         clear explicit priority (reset to default)
--   /tiler priorities               list all explicit priorities

local GAP         = 12    -- gap between windows (px)
local TOP_MARGIN  = 50    -- distance from top of screen for the first row
local LEFT_MARGIN = 50    -- left margin for the first column and each wrapped row
local MIN_WIDTH   = 150   -- frames narrower than this are skipped
local MIN_HEIGHT  = 100   -- frames shorter than this are skipped

------------------------------------------------------------------------
-- Saved variables
-- Top-level init is a fallback for the very first run before any saved
-- data exists. The real init happens in ADDON_LOADED, after the saved
-- variables file has been merged into the global namespace.
------------------------------------------------------------------------
TilerDB = TilerDB or {}

local initFrame = CreateFrame("Frame")

-- Frames allowed by object reference rather than name (e.g. unnamed AceGUI frames).
-- Populated by HookAllowedFrames and addon-specific hooks.
local _allowedObjects = {}

-- Forward declaration: defined in the Auto-tile section below, but called
-- from ArrangeWindows so it needs to be declared in scope first.
local HookAllowedFrames

------------------------------------------------------------------------
-- Hardcoded allowlist
-- Only frames listed here (or added via /tiler allow) are ever tiled.
------------------------------------------------------------------------
local ALLOWED_NAMES = {
    -- Standard WoW windows
    CharacterFrame        = true,
    FriendsFrame          = true,
    SpellBookFrame        = true,
    TalentFrame           = true,
    PlayerTalentFrame     = true,
    QuestLogFrame         = true,
    GuildFrame            = true,
    MacroFrame            = true,
    KeyBindingFrame       = true,
    VideoOptionsFrame     = true,
    InterfaceOptionsFrame = true,
    HelpFrame             = true,
    AuctionHouseFrame     = true,
    TradeSkillFrame       = true,
    CraftFrame            = true,
    TradeFrame            = true,
    BankFrame             = true,
    MailFrame             = true,
    MerchantFrame         = true,
    ChannelFrame          = true,
    -- Addon windows
    GrouperMainFrame                           = true,
    SkilletFrame                               = true,
    Questie_BasseFrame                         = true,
    Baganator_CategoryViewBankViewFrameelvui   = true,
    Baganator_CategoryViewBackpackViewFrameelvui = true,
}

local function IsAllowed(name)
    if not name then return false end
    if ALLOWED_NAMES[name] then return true end
    if TilerDB.allowed[name] then return true end
    return false
end

local function GetPriority(name)
    return (name and TilerDB.priorities and TilerDB.priorities[name]) or 50
end

------------------------------------------------------------------------
-- Frame discovery
------------------------------------------------------------------------
local function TryAddFrame(frames, f)
    if f:IsVisible()
    and (IsAllowed(f:GetName()) or _allowedObjects[f])
    and (f:GetWidth()  or 0) >= MIN_WIDTH
    and (f:GetHeight() or 0) >= MIN_HEIGHT
    and f:GetLeft()
    then
        frames[#frames + 1] = f
    end
end

local function DiscoverFrames()
    local frames = {}
    for _, f in ipairs({ UIParent:GetChildren() }) do
        pcall(TryAddFrame, frames, f)
    end
    -- Sort by explicit priority first; ties fall back to current visual order.
    table.sort(frames, function(a, b)
        local pa = GetPriority(a:GetName())
        local pb = GetPriority(b:GetName())
        if pa ~= pb then return pa < pb end
        return (a:GetLeft() or 0) < (b:GetLeft() or 0)
    end)
    return frames
end

------------------------------------------------------------------------
-- Position enforcer
-- After /tiler runs, addon hooks (ElvUI, MoveAny) may fire synchronously
-- or asynchronously and snap frames back. The enforcer re-corrects drift
-- every game frame for ENFORCE_SECS seconds, which outlasts any timer-
-- based restore. If frames still flicker, the competing addon hooks
-- SetPoint directly — a different strategy would be needed.
------------------------------------------------------------------------
local ENFORCE_SECS = 2

local _enforcer = CreateFrame("Frame")
_enforcer:Hide()
local _targets  = {}
local _elapsed  = 0

_enforcer:SetScript("OnUpdate", function(self, dt)
    _elapsed = _elapsed + dt
    if _elapsed >= ENFORCE_SECS then
        _targets = {}
        _elapsed = 0
        self:Hide()
        return
    end
    for _, t in ipairs(_targets) do
        local f = t.frame
        if f:IsShown() then
            local left = f:GetLeft() or 0
            local top  = f:GetTop()  or 0
            if math.abs(left - t.x) > 1 or math.abs(top - t.y) > 1 then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", t.x, t.y)
            end
        end
    end
end)

------------------------------------------------------------------------
-- Placement
------------------------------------------------------------------------
local function ArrangeWindows(silent)
    -- Re-resolve allowlisted names so lazily-created frames (e.g. Grouper's
    -- AceGUI window, which sets _G["GrouperMainFrame"] only on first open)
    -- are registered in _allowedObjects before DiscoverFrames runs.
    HookAllowedFrames()

    if InCombatLockdown() then
        if not silent then print("|cff00ff00Tiler:|r Cannot arrange during combat.") end
        return
    end

    local frames = DiscoverFrames()
    if #frames == 0 then
        if not silent then print("|cff00ff00Tiler:|r No tileable windows found.") end
        return
    end

    local sw        = UIParent:GetWidth()
    local sh        = UIParent:GetHeight()
    local curX      = LEFT_MARGIN
    local curY      = sh - TOP_MARGIN
    local rowBottom = curY

    local placements = {}
    for _, frame in ipairs(frames) do
        local fw = frame:GetWidth()
        local fh = frame:GetHeight()

        if curX > LEFT_MARGIN and curX + fw > sw then
            curY      = rowBottom - GAP
            curX      = LEFT_MARGIN
            rowBottom = curY
        end

        placements[#placements + 1] = { frame = frame, x = curX, y = curY }

        local bottom = curY - fh
        if bottom < rowBottom then rowBottom = bottom end
        curX = curX + fw + GAP
    end

    -- Apply positions immediately, then keep enforcing for ENFORCE_SECS.
    for _, p in ipairs(placements) do
        local frame = p.frame
        local name  = frame:GetName()
        if UIPanelWindows and name and UIPanelWindows[name] then
            UIPanelWindows[name] = nil
        end
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
    end

    _targets = placements
    _elapsed = 0
    _enforcer:Show()

    if not silent then
        print("|cff00ff00Tiler:|r Arranged " .. #placements
              .. " window" .. (#placements == 1 and "" or "s") .. ".")
    end
end

------------------------------------------------------------------------
-- Debug: list what would be tiled right now
------------------------------------------------------------------------
local function DebugFrames()
    local frames = DiscoverFrames()
    if #frames == 0 then
        print("|cff00ff00Tiler:|r No tileable windows found.")
        return
    end
    print("|cff00ff00Tiler:|r " .. #frames
          .. " tileable window" .. (#frames == 1 and "" or "s") .. ":")
    for i, f in ipairs(frames) do
        print(string.format("  %d. %-40s %dx%d  at (%d,%d)",
            i,
            f:GetName() or "(unnamed)",
            math.floor(f:GetWidth()  or 0),
            math.floor(f:GetHeight() or 0),
            math.floor(f:GetLeft()   or 0),
            math.floor(f:GetTop()    or 0)))
    end
end

------------------------------------------------------------------------
-- Scan: list every visible, sizeable UIParent child regardless of allowlist
------------------------------------------------------------------------
local function ScanFrames()
    local found = {}
    for _, f in ipairs({ UIParent:GetChildren() }) do
        local ok, name, w, h, x, y = pcall(function()
            return f:GetName(),
                   f:GetWidth()  or 0,
                   f:GetHeight() or 0,
                   f:GetLeft()   or 0,
                   f:GetTop()    or 0
        end)
        if ok and name and f:IsVisible() and w >= MIN_WIDTH and h >= MIN_HEIGHT then
            found[#found + 1] = { name = name, w = w, h = h, x = x, y = y }
        end
    end
    table.sort(found, function(a, b) return a.name < b.name end)

    if #found == 0 then
        print("|cff00ff00Tiler:|r No visible candidate frames found.")
        return
    end
    print("|cff00ff00Tiler:|r " .. #found .. " visible candidate frame"
          .. (#found == 1 and "" or "s") .. "  (* = already allowed):")
    for _, t in ipairs(found) do
        local marker = IsAllowed(t.name) and "|cff00ff00*|r " or "  "
        print(string.format("  %s%-40s %dx%d  at (%d,%d)",
            marker, t.name,
            math.floor(t.w), math.floor(t.h),
            math.floor(t.x), math.floor(t.y)))
    end
end

------------------------------------------------------------------------
-- List the full effective allowlist
------------------------------------------------------------------------
local function PrintAllowList()
    local hardcoded = {}
    for name in pairs(ALLOWED_NAMES) do hardcoded[#hardcoded + 1] = name end
    table.sort(hardcoded)

    local user = {}
    for name in pairs(TilerDB.allowed or {}) do user[#user + 1] = name end
    table.sort(user)

    print("|cff00ff00Tiler:|r Hardcoded allowlist (" .. #hardcoded .. "):")
    for _, name in ipairs(hardcoded) do
        print("  " .. name)
    end

    if #user == 0 then
        print("|cff00ff00Tiler:|r User allowlist: (empty)")
    else
        print("|cff00ff00Tiler:|r User allowlist (" .. #user .. "):")
        for _, name in ipairs(user) do
            print("  " .. name)
        end
    end
end

------------------------------------------------------------------------
-- List explicit priorities
------------------------------------------------------------------------
local function ListPriorities()
    local list = {}
    for name, p in pairs(TilerDB.priorities or {}) do
        list[#list + 1] = { name = name, p = p }
    end
    if #list == 0 then
        print("|cff00ff00Tiler:|r No explicit priorities set (all frames default to 50).")
        return
    end
    table.sort(list, function(a, b)
        if a.p ~= b.p then return a.p < b.p end
        return a.name < b.name
    end)
    print("|cff00ff00Tiler:|r " .. #list .. " explicit priorit" .. (#list == 1 and "y" or "ies") .. ":")
    for _, t in ipairs(list) do
        print(string.format("  %3d  %s", t.p, t.name))
    end
end

------------------------------------------------------------------------
-- Auto-tile
-- Hooks OnShow/OnHide on every allowlisted frame so tiling re-runs
-- silently whenever a window opens or closes.  A one-frame scheduler
-- coalesces rapid show/hide pairs into a single ArrangeWindows call.
------------------------------------------------------------------------
local _autoTilePending = false
local _autoScheduler = CreateFrame("Frame")
_autoScheduler:Hide()
_autoScheduler:SetScript("OnUpdate", function(self)
    self:Hide()
    _autoTilePending = false
    ArrangeWindows(true)
end)

local function ScheduleAutoTile()
    if InCombatLockdown() or _autoTilePending then return end
    _autoTilePending = true
    _autoScheduler:Show()
end

local _hookedFrames = {}
local function HookFrame(frame)
    if not frame or _hookedFrames[frame] then return end
    _hookedFrames[frame] = true
    frame:HookScript("OnShow", ScheduleAutoTile)
    frame:HookScript("OnHide", ScheduleAutoTile)
    -- If the frame is already visible when we first hook it (lazy creation),
    -- fire auto-tile now so the layout includes it immediately.
    if frame:IsShown() then ScheduleAutoTile() end
end

HookAllowedFrames = function()
    for name in pairs(ALLOWED_NAMES) do
        local f = _G[name]
        if f then _allowedObjects[f] = true end
        HookFrame(f)
    end
    if TilerDB and TilerDB.allowed then
        for name in pairs(TilerDB.allowed) do
            local f = _G[name]
            if f then _allowedObjects[f] = true end
            HookFrame(f)
        end
    end
end

-- Wire up initFrame now that HookAllowedFrames is defined.
-- ADDON_LOADED fires once per addon (before PLAYER_LOGIN) so we can pick
-- up frames the moment each addon creates them.
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" then
        HookAllowedFrames()
        -- Grouper uses AceGUI and re-creates GrouperMainFrame on every open/close
        -- cycle, so we hook CreateMainWindow to re-hook the new frame each time.
        if addonName == "Grouper" and Grouper and Grouper.CreateMainWindow then
            hooksecurefunc(Grouper, "CreateMainWindow", function(g)
                if g.mainFrame and g.mainFrame.frame then
                    local f = g.mainFrame.frame
                    _allowedObjects[f] = true
                    HookFrame(f)
                end
            end)
        end
    elseif event == "PLAYER_LOGIN" then
        TilerDB = TilerDB or {}
        TilerDB.allowed     = TilerDB.allowed     or {}
        TilerDB.priorities  = TilerDB.priorities  or {}
        if not GetBindingKey("CLICK TilerArrangeButton:LeftButton") then
            SetBindingClick("CTRL-T", "TilerArrangeButton", "LeftButton")
        end
        HookAllowedFrames()
        self:UnregisterEvent("ADDON_LOADED")
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

------------------------------------------------------------------------
-- Key binding
-- SetBindingClick is the reliable dispatch path in WoW Classic.
-- A named hidden button receives synthetic clicks; the BINDING_* globals
-- control how the entry appears in the Key Bindings UI.
------------------------------------------------------------------------
BINDING_HEADER_TILER = "Tiler"
_G["BINDING_NAME_CLICK TilerArrangeButton:LeftButton"] = "Arrange Windows"

local _arrangeBtn = CreateFrame("Button", "TilerArrangeButton", UIParent)
_arrangeBtn:RegisterForClicks("AnyUp")
_arrangeBtn:SetScript("OnClick", function() ArrangeWindows() end)

------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------
SLASH_TILER1 = "/tiler"
SlashCmdList["TILER"] = function(msg)
    msg = msg:match("^%s*(.-)%s*$") or ""
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    arg = (arg or ""):match("^%s*(.-)%s*$")

    if cmd == "" then
        ArrangeWindows()

    elseif cmd == "debug" then
        DebugFrames()

    elseif cmd == "scan" then
        ScanFrames()

    elseif cmd == "allow" then
        if arg == "" then
            print("|cff00ff00Tiler:|r Usage: /tiler allow <FrameName>")
        else
            TilerDB.allowed[arg] = true
            HookFrame(_G[arg])
            print("|cff00ff00Tiler:|r Allowed: " .. arg)
        end

    elseif cmd == "remove" then
        if arg == "" then
            print("|cff00ff00Tiler:|r Usage: /tiler remove <FrameName>")
        else
            TilerDB.allowed[arg] = nil
            print("|cff00ff00Tiler:|r Removed from user allowlist: " .. arg)
        end

    elseif cmd == "list" then
        PrintAllowList()

    elseif cmd == "priority" then
        local name, numStr = arg:match("^(%S+)%s*(.*)$")
        name   = name   or ""
        numStr = (numStr or ""):match("^%s*(.-)%s*$")
        if name == "" then
            ListPriorities()
        elseif numStr == "" then
            TilerDB.priorities[name] = nil
            print("|cff00ff00Tiler:|r " .. name .. " priority cleared (back to default 50).")
        else
            local n = tonumber(numStr)
            if not n then
                print("|cff00ff00Tiler:|r Priority must be a number.")
            else
                TilerDB.priorities[name] = n
                print("|cff00ff00Tiler:|r " .. name .. " priority set to " .. n .. ".")
            end
        end

    elseif cmd == "priorities" then
        ListPriorities()

    else
        print("|cff00ff00Tiler:|r /tiler · /tiler debug · /tiler scan · /tiler allow <name> · /tiler remove <name> · /tiler list · /tiler priority <name> [n] · /tiler priorities")
    end
end
