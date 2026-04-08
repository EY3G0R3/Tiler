-- Tiler.lua
-- Dynamic tiling window manager for WoW Classic Era.
-- Discovers visible windows from an explicit allowlist and arranges them
-- left-to-right (tops aligned, GAP px apart), wrapping to a new row when
-- the strip would overflow the screen.
--
-- Commands:
--   /tiler                    arrange all allowed windows
--   /tiler debug              list every frame that would be tiled
--   /tiler allow  <name>      add a frame to the persistent allowlist
--   /tiler remove <name>      remove a frame from the persistent allowlist
--   /tiler list               show hardcoded + user-added allowlist

local GAP         = 12    -- gap between windows (px)
local TOP_MARGIN  = 4     -- distance from top of screen for the first row
local LEFT_MARGIN = 4     -- left margin for the first column and each wrapped row
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
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    TilerDB = TilerDB or {}
    TilerDB.allowed = TilerDB.allowed or {}
    self:UnregisterEvent("PLAYER_LOGIN")
end)

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
    -- Addon windows
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

------------------------------------------------------------------------
-- Frame discovery
------------------------------------------------------------------------
local function TryAddFrame(frames, f)
    if f:IsVisible()
    and IsAllowed(f:GetName())
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
    -- Preserve the current left-to-right visual order.
    table.sort(frames, function(a, b)
        return (a:GetLeft() or 0) < (b:GetLeft() or 0)
    end)
    return frames
end

------------------------------------------------------------------------
-- Placement
------------------------------------------------------------------------
local function ArrangeWindows()
    if InCombatLockdown() then
        print("|cff00ff00Tiler:|r Cannot arrange during combat.")
        return
    end

    local frames = DiscoverFrames()
    if #frames == 0 then
        print("|cff00ff00Tiler:|r No tileable windows found.")
        return
    end

    local sw        = UIParent:GetWidth()
    local sh        = UIParent:GetHeight()
    local curX      = LEFT_MARGIN
    local curY      = sh - TOP_MARGIN
    local rowBottom = curY

    for _, frame in ipairs(frames) do
        local fw = frame:GetWidth()
        local fh = frame:GetHeight()

        if curX > LEFT_MARGIN and curX + fw > sw then
            curY      = rowBottom - GAP
            curX      = LEFT_MARGIN
            rowBottom = curY
        end

        -- Release from WoW's UI panel system so our SetPoint is not
        -- immediately overridden by UpdateUIPanel().
        local name = frame:GetName()
        if UIPanelWindows and name and UIPanelWindows[name] then
            UIPanelWindows[name] = nil
        end

        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", curX, curY)

        local bottom = curY - fh
        if bottom < rowBottom then rowBottom = bottom end
        curX = curX + fw + GAP
    end

    print("|cff00ff00Tiler:|r Arranged " .. #frames
          .. " window" .. (#frames == 1 and "" or "s") .. ".")
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

    elseif cmd == "allow" then
        if arg == "" then
            print("|cff00ff00Tiler:|r Usage: /tiler allow <FrameName>")
        else
            TilerDB.allowed[arg] = true
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

    else
        print("|cff00ff00Tiler:|r /tiler · /tiler debug · /tiler allow <name> · /tiler remove <name> · /tiler list")
    end
end
