-- Tiler.lua
-- Automatic tiling window manager for WoW Classic Era.
--
-- When a managed window opens it is placed to the right of the rightmost
-- already-open managed window (tops aligned, GAP pixels apart).  If the
-- new window would overflow the right edge of the screen it wraps below
-- all open windows instead.
--
-- Slash command:  /tiler          → show current status
--                 /tiler on|off   → enable or disable

local ADDON_NAME = ...

------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------

local GAP         = 12   -- horizontal gap between windows (px)
local TOP_MARGIN  = 4    -- top of screen gap when no other window is open
local LEFT_MARGIN = 4    -- left edge gap when wrapping to a new row

-- Frames that Tiler will auto-position when they become visible.
-- Any name whose global is nil at show-time is silently skipped.
local MANAGED_NAMES = {
    -- Character / skills
    "CharacterFrame",
    "SpellBookFrame",
    "TalentFrame",
    "InspectFrame",
    -- Social
    "FriendsFrame",
    "GuildFrame",
    -- Quests
    "QuestLogFrame",
    -- Professions / training
    "TradeSkillFrame",
    "CraftFrame",           -- Enchanting and a few others use CraftFrame in 1.x
    "ClassTrainerFrame",
    -- NPC interaction windows worth tiling
    "MerchantFrame",
    "AuctionFrame",
    "TradeFrame",
    "MailFrame",
    "BankFrame",
    "TaxiFrame",
    "PetStableFrame",
    "TabardFrame",
    -- Misc player UI
    "MacroFrame",
    "KeyBindingFrame",
    "VideoOptionsFrame",
    "AudioOptionsFrame",
    "InterfaceOptionsFrame",
    "HelpFrame",
    "LFGFrame",
    -- Bags  (ContainerFrame1 = backpack, 2-5 = bag slots)
    "ContainerFrame1",
    "ContainerFrame2",
    "ContainerFrame3",
    "ContainerFrame4",
    "ContainerFrame5",
}

------------------------------------------------------------------------
-- Saved variables
------------------------------------------------------------------------
TilerDB = TilerDB or {}
if TilerDB.enabled == nil then TilerDB.enabled = true end

------------------------------------------------------------------------
-- C_Timer polyfill
-- Not all Classic Era builds expose C_Timer natively.
------------------------------------------------------------------------
local function After(seconds, func)
    if C_Timer and C_Timer.After then
        C_Timer.After(seconds, func)
        return
    end
    local t = CreateFrame("Frame")
    local elapsed = 0
    t:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= seconds then
            self:SetScript("OnUpdate", nil)
            func()
        end
    end)
end

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------
local managedSet = {}
for _, n in ipairs(MANAGED_NAMES) do managedSet[n] = true end

-- Returns all currently visible managed frames except `skip`.
local function GetVisibleOthers(skip)
    local t = {}
    for _, name in ipairs(MANAGED_NAMES) do
        local f = _G[name]
        -- IsVisible() requires self AND all ancestors to be shown.
        -- GetLeft() is nil when a frame has no valid screen position yet.
        if f and f ~= skip and f:IsVisible() and f:GetLeft() then
            t[#t + 1] = f
        end
    end
    return t
end

------------------------------------------------------------------------
-- Placement
--
-- Coordinate convention used throughout:
--   SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
--     x = pixels from the left edge of the screen  (positive → right)
--     y = pixels from the bottom edge of the screen (positive → up)
--   GetLeft() / GetRight() / GetTop() / GetBottom() all use this origin,
--   so they can be fed directly into SetPoint offsets.
------------------------------------------------------------------------
local function PlaceFrame(frame)
    if not TilerDB.enabled   then return end
    if InCombatLockdown()    then return end

    local fw = frame:GetWidth()
    if not fw or fw <= 0 then return end   -- frame not yet laid out

    local sw = UIParent:GetWidth()
    local sh = UIParent:GetHeight()

    local others = GetVisibleOthers(frame)

    local newX, newY

    if #others == 0 then
        -- Nothing else open: place at the top-left corner.
        newX = LEFT_MARGIN
        newY = sh - TOP_MARGIN
    else
        -- Find the frame with the rightmost right edge; use its top as anchor.
        local maxRight  = 0
        local anchorTop = sh - TOP_MARGIN
        for _, f in ipairs(others) do
            local r = f:GetRight() or 0
            if r > maxRight then
                maxRight  = r
                anchorTop = f:GetTop() or anchorTop
            end
        end

        if maxRight + GAP + fw <= sw then
            -- Fits to the right of the existing strip.
            newX = maxRight + GAP
            newY = anchorTop
        else
            -- Overflows right edge → wrap below the lowest visible frame.
            local minBottom = sh
            for _, f in ipairs(others) do
                local b = f:GetBottom()
                if b and b < minBottom then minBottom = b end
            end
            newX = LEFT_MARGIN
            newY = minBottom - GAP
        end
    end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", newX, newY)
end

-- Defers one tick so the frame has time to compute its final dimensions.
local function Schedule(frame)
    After(0, function()
        if frame:IsVisible() then PlaceFrame(frame) end
    end)
end

------------------------------------------------------------------------
-- Hooks
------------------------------------------------------------------------

-- ShowUIPanel is the standard gateway for most UI panels:
--   CharacterFrame, SpellBookFrame, TalentFrame, QuestLogFrame,
--   FriendsFrame, GuildFrame, BankFrame, MerchantFrame, TradeSkillFrame,
--   AuctionFrame, MailFrame, TradeFrame, MacroFrame, KeyBindingFrame,
--   VideoOptionsFrame, AudioOptionsFrame, InterfaceOptionsFrame,
--   HelpFrame, LFGFrame, TabardFrame, PetStableFrame, TaxiFrame …
hooksecurefunc("ShowUIPanel", function(frame)
    if not frame then return end
    local name = frame:GetName()
    if name and managedSet[name] then
        Schedule(frame)
    end
end)

-- Container frames (bags) are shown via frame:Show() directly, bypassing
-- ShowUIPanel.  Hook each one individually once FrameXML has created them.
local function HookContainerFrames()
    for _, name in ipairs(MANAGED_NAMES) do
        if name:find("^ContainerFrame%d") then
            local f = _G[name]
            if f then
                f:HookScript("OnShow", function(self)
                    Schedule(self)
                end)
            end
        end
    end
end

-- ClassTrainerFrame and InspectFrame may also bypass ShowUIPanel in some
-- builds; hook them directly as a safety net.
local function HookDirectShowFrames()
    local directFrames = { "ClassTrainerFrame", "InspectFrame", "CraftFrame" }
    for _, name in ipairs(directFrames) do
        local f = _G[name]
        if f and managedSet[name] then
            f:HookScript("OnShow", function(self)
                -- Only fire if ShowUIPanel hasn't already handled it
                -- (double-scheduling is harmless but wasteful).
                Schedule(self)
            end)
        end
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, arg1)
    if arg1 == ADDON_NAME then
        HookContainerFrames()
        HookDirectShowFrames()
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

------------------------------------------------------------------------
-- Slash command  (/tiler)
------------------------------------------------------------------------
SLASH_TILER1 = "/tiler"
SlashCmdList["TILER"] = function(msg)
    -- portable trim + lower (strtrim is not available on every build)
    msg = (msg:match("^%s*(.-)%s*$") or ""):lower()

    if msg == "on" then
        TilerDB.enabled = true
        print("|cff00ff00Tiler:|r Enabled.")
    elseif msg == "off" then
        TilerDB.enabled = false
        print("|cff00ff00Tiler:|r Disabled.")
    else
        local status = TilerDB.enabled
            and "|cff00ff00enabled|r"
            or  "|cffff4444disabled|r"
        print("|cff00ff00Tiler:|r " .. status .. "  —  /tiler on | off")
    end
end
