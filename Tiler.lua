-- Tiler.lua
-- Dynamic tiling window manager for WoW Classic Era.
-- Discovers all window-like frames at the time /tiler is typed and
-- arranges them left-to-right (tops aligned, GAP px apart), wrapping
-- to a new row when the strip would overflow the screen.
--
-- Commands:
--   /tiler                    arrange all discovered windows
--   /tiler debug              list every frame that would be tiled
--   /tiler ignore  <name>     exclude a frame from tiling permanently
--   /tiler unignore <name>    stop ignoring a frame
--   /tiler ignored            show the current ignore list

local GAP        = 12    -- gap between windows (px)
local TOP_MARGIN = 4     -- distance from top of screen for the first row
local LEFT_MARGIN = 4    -- left margin for the first column and each wrapped row
local MIN_WIDTH  = 150   -- frames narrower than this are skipped
local MIN_HEIGHT = 100   -- frames shorter than this are skipped

------------------------------------------------------------------------
-- Saved variables
------------------------------------------------------------------------
TilerDB = TilerDB or {}
TilerDB.ignored = TilerDB.ignored or {}

------------------------------------------------------------------------
-- Built-in exclusion list
-- Anything here is never tiled regardless of size/visibility.
-- Pattern strings use Lua's string.find (plain = false).
------------------------------------------------------------------------
local EXCLUDED_NAMES = {
    -- Core WoW UI anchors
    UIParent              = true,
    WorldFrame            = true,
    -- Map
    WorldMapFrame         = true,
    -- Tooltips
    GameTooltip           = true,
    ItemRefTooltip        = true,
    ShoppingTooltip1      = true,
    ShoppingTooltip2      = true,
    -- Unit frames
    PlayerFrame           = true,
    TargetFrame           = true,
    TargetFrameToT        = true,
    FocusFrame            = true,
    -- Map / navigation
    Minimap               = true,
    MinimapCluster        = true,
    -- Casting bars
    CastingBarFrame       = true,
    FocusCastingBarFrame  = true,
    -- HUD chrome
    ComboPointPlayerFrame = true,
    RuneFrame             = true,
    DurabilityFrame       = true,
    FramerateLabel        = true,
    UIErrorsFrame         = true,
    -- Status / alerts
    TicketStatusFrame     = true,
    ReadyCheckFrame       = true,
    QuestTimerFrame       = true,
    RaidBossEmoteFrame    = true,
    SubZoneTextFrame      = true,
    ZoneTextFrame         = true,
    AutoFollowStatus      = true,
    LevelUpDisplay        = true,
    PVPReadyDialog        = true,
}

-- Pattern list: any frame whose name matches one of these is excluded.
local EXCLUDED_PATTERNS = {
    -- Action bars (standard + extra)
    "^MainMenuBar",
    "^MultiBar",
    "^BonusActionBar",
    "^PossessBar",
    "^PetActionBar",
    "^ShapeshiftBar",
    "^MicroButton",
    "^ActionButton",
    "^BonusActionButton",
    -- Chat / combat log
    "^ChatFrame",
    "^CombatLog",
    -- Party / raid frames
    "^PartyMember",
    "^CompactRaid",
    "^Boss%d",
    -- Buffs / debuffs
    "BuffFrame$",
    "DebuffFrame$",
    "TempEnchant",
    -- Tooltips (catch-all)
    "Tooltip",
    -- ElvUI bars, chat, and unit frames
    "^ElvUI_Bar",
    "^ElvUI_Chat",
    "^ElvUF_",
    -- Static popups and alerts
    "^StaticPopup",
    "^AlertFrame",
    "^WorldState",
}

local function IsExcluded(name)
    if not name                 then return true end   -- skip anonymous frames
    if EXCLUDED_NAMES[name]     then return true end
    if TilerDB.ignored[name]    then return true end
    for _, pat in ipairs(EXCLUDED_PATTERNS) do
        if name:find(pat) then return true end
    end
    return false
end

------------------------------------------------------------------------
-- Frame discovery
-- UIParent:GetChildren() returns every direct child of UIParent, which
-- covers virtually all addon windows and standard UI panels.
-- Some children are non-Frame widgets (ElvUI objects, etc.) that reject
-- Frame method calls — pcall skips them safely.
------------------------------------------------------------------------
local function TryAddFrame(frames, f)
    if f:IsVisible()
    and not IsExcluded(f:GetName())
    and (f:GetWidth()  or 0) >= MIN_WIDTH
    and (f:GetHeight() or 0) >= MIN_HEIGHT
    and f:GetLeft()                          -- must have valid screen coords
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
-- Coordinate convention for SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y):
--   x = pixels from left edge of screen
--   y = pixels from bottom edge of screen (this is where the frame top lands)
-- GetLeft() / GetTop() use the same origin, so they feed directly into SetPoint.
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
            -- Overflow: wrap below the tallest frame in the current row.
            curY      = rowBottom - GAP
            curX      = LEFT_MARGIN
            rowBottom = curY
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
-- Debug: list what would be tiled
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
-- Slash command
------------------------------------------------------------------------
SLASH_TILER1 = "/tiler"
SlashCmdList["TILER"] = function(msg)
    msg = msg:match("^%s*(.-)%s*$") or ""
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    arg = (arg or ""):match("^%s*(.-)%s*$")   -- trim arg too

    if cmd == "" then
        ArrangeWindows()

    elseif cmd == "debug" then
        DebugFrames()

    elseif cmd == "ignore" then
        if arg == "" then
            print("|cff00ff00Tiler:|r Usage: /tiler ignore <FrameName>")
        else
            TilerDB.ignored[arg] = true
            print("|cff00ff00Tiler:|r Ignoring: " .. arg)
        end

    elseif cmd == "unignore" then
        if arg == "" then
            print("|cff00ff00Tiler:|r Usage: /tiler unignore <FrameName>")
        else
            TilerDB.ignored[arg] = nil
            print("|cff00ff00Tiler:|r No longer ignoring: " .. arg)
        end

    elseif cmd == "ignored" then
        local list = {}
        for name in pairs(TilerDB.ignored) do list[#list + 1] = name end
        table.sort(list)
        if #list == 0 then
            print("|cff00ff00Tiler:|r Ignore list is empty.")
        else
            print("|cff00ff00Tiler:|r Ignored frames:")
            for _, name in ipairs(list) do
                print("  - " .. name)
            end
        end

    else
        print("|cff00ff00Tiler:|r /tiler · /tiler debug · /tiler ignore <name> · /tiler unignore <name> · /tiler ignored")
    end
end
