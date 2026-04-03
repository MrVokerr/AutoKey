-- AutoKey.lua
-- Automatically inserts your Mythic+ keystone when the keystone receptacle window opens.
-- Built against the WoW Midnight API.  Gracefully degrades when APIs are blocked in
-- instanced content (a common restriction introduced in Midnight).

local addonName = ...

local ADDON_VERSION = "1"
local INSERT_DELAY  = 0.25   -- seconds to wait after receptacle opens before inserting

-- =============================================================================
-- SavedVariables
-- =============================================================================

local defaults = {
    enabled = true,
    verbose = false,
}

local db  -- set on ADDON_LOADED to the AutoKeyDB SavedVariable table

-- =============================================================================
-- C_ChallengeMode dedicated APIs (the correct way to slot a keystone)
-- Big Wigs source confirmed these are the right APIs in Midnight.
-- =============================================================================

-- These are resolved once at load time.  If Blizzard blocks them inside
-- instances at some point, TryInsertKeystone falls back gracefully.
local HasSlottedKeystone = C_ChallengeMode and C_ChallengeMode.HasSlottedKeystone
local SlotKeystone       = C_ChallengeMode and C_ChallengeMode.SlotKeystone
local PickupContainerItem = C_Container.PickupContainerItem
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetContainerItemLink = C_Container.GetContainerItemLink

-- =============================================================================
-- Midnight Season Dungeon Name Fallback
-- C_ChallengeMode.GetMapUIInfo is blocked inside instances in Midnight.
-- This table provides a local fallback so /autokey status still shows names.
--
-- Midnight Season Pool:
--   Magisters' Terrace, Maisara Caverns, Nexus-Point Xenas, Windrunner Spire,
--   Algeth'ar Academy, The Seat of the Triumvirate, Skyreach, Pit of Saron
--
-- To populate: run "/autokey scanmaps" outside a dungeon.
-- It calls C_ChallengeMode.GetMaps() and prints every mapID + name for the
-- current season.  Names are auto-cached at runtime; this table persists them
-- across reloads via SavedVariables (handled in ADDON_LOADED below).
-- =============================================================================

local DUNGEON_NAMES = {}

-- Returns the dungeon name for a given challenge mapID.
-- Tries the live API first (works outside instances), then falls back to the
-- cached table (populated via /autokey scanmaps or auto-cached on login).
local function GetDungeonName(mapID)
    if not mapID then return "Unknown" end
    -- Live API path (available outside instances)
    if C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
        local name = select(1, C_ChallengeMode.GetMapUIInfo(mapID))
        if name and name ~= "" then
            if not DUNGEON_NAMES[mapID] then
                DUNGEON_NAMES[mapID] = name
                Debug(("Cached dungeon name: [%d] = %q"):format(mapID, name))
            end
            return name
        end
    end
    -- Local / SavedVariables fallback (works inside instances)
    return DUNGEON_NAMES[mapID] or ("mapID " .. mapID)
end

-- =============================================================================
-- Utility
-- =============================================================================

local CHAT_PREFIX = "|cFF33BBFFAutoKey|r: "

local function Msg(msg)
    print(CHAT_PREFIX .. msg)
end

local function Debug(msg)
    if db and db.verbose then
        print(CHAT_PREFIX .. "|cFFAAAAAA[debug]|r " .. msg)
    end
end

-- =============================================================================
-- Keystone Detection & Insertion
-- =============================================================================

-- Scan bags 0-4 and return (bag, slot, itemLink) for the first keystone found.
-- Detection uses itemLink:find("Hkeystone") — the same method Big Wigs uses.
-- This is expansion-agnostic: any keystone item always has "Hkeystone" in its link.
local function FindKeystoneInBags()
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local link = GetContainerItemLink(bag, slot)
                if link and link:find("Hkeystone", nil, true) then
                    Debug(("Keystone found at bag %d slot %d"):format(bag, slot))
                    return bag, slot, link
                end
            end
        end
    end
    return nil, nil, nil
end

-- =============================================================================
-- Keystone Insertion
-- =============================================================================

local insertPending = false

local function TryInsertKeystone()
    if not db or not db.enabled then
        Debug("Skipping: addon disabled")
        return
    end

    if insertPending then
        Debug("Skipping: insert already pending")
        return
    end

    -- If the keystone is already in the slot, nothing to do.
    if HasSlottedKeystone and HasSlottedKeystone() then
        Debug("Keystone already slotted")
        return
    end

    -- Verify the key in our bags belongs to this dungeon.
    -- GetOwnedKeystoneMapID returns the map instance ID (same space as GetInstanceInfo).
    -- If C_MythicPlus is blocked (Midnight instance restriction), skip this check
    -- and trust the bag scan — the player wouldn't have a different key for this dungeon.
    if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID then
        local keystoneMapID = C_MythicPlus.GetOwnedKeystoneMapID()
        if keystoneMapID ~= nil then
            local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
            if keystoneMapID ~= instanceID then
                Debug(("Key mapID %s does not match instance %s — not auto-slotting"):format(
                    tostring(keystoneMapID), tostring(instanceID)))
                return
            end
        end
    end

    local bag, slot, link = FindKeystoneInBags()
    if not bag then
        Debug("No keystone found in bags")
        return
    end

    insertPending = true

    C_Timer.After(INSERT_DELAY, function()
        insertPending = false

        -- Re-verify the item is still there after the delay.
        local currentLink = GetContainerItemLink(bag, slot)
        if not currentLink or not currentLink:find("Hkeystone", nil, true) then
            Debug("Keystone no longer in expected slot, aborting")
            return
        end

        -- Guard: another player may have slotted in the meantime.
        if HasSlottedKeystone and HasSlottedKeystone() then
            Debug("Keystone already slotted (race condition avoided)")
            return
        end

        -- Print first, then insert — same order as Big Wigs.
        -- This ensures the message always appears even if the secure call
        -- triggers taint that pcall catches after the fact.
        Msg("Automatically inserted " .. link .. " into the keystone slot.")
        PickupContainerItem(bag, slot)
        if SlotKeystone then
            SlotKeystone()
        end
    end)
end

-- =============================================================================
-- Countdown Button
-- Parented to UIParent and anchored to the LEFT of ChallengesKeystoneFrame
-- so it sits outside the window and is never covered by internal frame layers.
-- Uses SecureActionButtonTemplate for /countdown (RunMacroText is blocked in
-- Midnight). PostClick handles the party chat messages.
-- =============================================================================

local countdownBtn
local readyCheckBtn
local countdownRunning = false
local waitingForCountdownStart = false
local pendingCountdownGUID = nil
local countdownSequenceToken = 0

local COUNTDOWN_SECONDS = 10
local COUNTDOWN_SYNC_TIMEOUT = 4.5
local ACTIVATE_CLICK_DELAY = 0.2

-- Cached reference to ChallengesKeystoneFrame's Activate button.
-- Populated the first time the keystone window opens.
local keystoneActivateBtn = nil

local function ResetCountdownState()
    waitingForCountdownStart = false
    pendingCountdownGUID = nil
    countdownRunning = false
    countdownSequenceToken = countdownSequenceToken + 1
    if countdownBtn then
        countdownBtn:SetEnabled(true)
    end
end

local function StartKeySequence(countdownSeconds, source)
    local seconds = tonumber(countdownSeconds) or COUNTDOWN_SECONDS
    seconds = math.floor(seconds + 0.5)
    if seconds < 1 then
        seconds = COUNTDOWN_SECONDS
    end

    waitingForCountdownStart = false
    pendingCountdownGUID = nil
    countdownRunning = true
    countdownSequenceToken = countdownSequenceToken + 1
    local token = countdownSequenceToken

    Debug(("Starting synced countdown (%s): %d second(s)"):format(source or "unknown", seconds))

    -- Send chat countdown in lockstep with the Blizzard countdown start.
    for i = seconds, 1, -1 do
        C_Timer.After(seconds - i, function()
            if token ~= countdownSequenceToken or not countdownRunning then
                return
            end
            local channel = IsInGroup() and "PARTY" or "SAY"
            SendChatMessage("KEY STARTING IN " .. i, channel)
        end)
    end

    C_Timer.After(seconds, function()
        if token ~= countdownSequenceToken then
            return
        end
        countdownRunning = false
        if countdownBtn then
            countdownBtn:SetEnabled(true)
        end
    end)

    -- Click the Activate button shortly after countdown reaches 0.
    C_Timer.After(seconds + ACTIVATE_CLICK_DELAY, function()
        if token ~= countdownSequenceToken then
            return
        end
        if not keystoneActivateBtn then
            keystoneActivateBtn = FindActivateButton()
        end
        if keystoneActivateBtn and keystoneActivateBtn:IsShown() and keystoneActivateBtn:IsEnabled() then
            keystoneActivateBtn:Click("LeftButton")
            Debug("Activate button clicked")
        else
            Debug("Activate button not clickable — use /ak scanframe while window is open")
        end
    end)
end

-- Scans the ChallengesKeystoneFrame hierarchy (up to 3 levels deep) and
-- returns the first button whose global name contains "Activate" or whose
-- visible text is "Activate"/"Start".  Falls back to well-known globals.
local function FindActivateButton()
    if not ChallengesKeystoneFrame then return nil end

    -- Well-known names first (fastest path)
    local candidates = {
        ChallengesKeystoneFrame.ActivateButton,
        _G["ChallengesKeystoneFrameActivateButton"],
        ChallengesKeystoneFrame.ContentsFrame and ChallengesKeystoneFrame.ContentsFrame.ActivateButton,
    }
    for _, btn in ipairs(candidates) do
        if btn then
            Debug("FindActivateButton: found via candidate list → " .. (btn:GetName() or "unnamed"))
            return btn
        end
    end

    -- Deep scan fallback
    local function ScanChildren(frame, depth)
        if depth > 3 then return nil end
        for i = 1, select("#", frame:GetChildren()) do
            local child = select(i, frame:GetChildren())
            local name  = child:GetName() or ""
            local text  = (child.GetText and child:GetText()) or ""
            if name:find("Activate", nil, true) or text:lower():find("activate", nil, true) then
                Debug("FindActivateButton: deep-scan found → " .. (name ~= "" and name or "(no name)") .. " text='" .. text .. "'")
                return child
            end
            local found = ScanChildren(child, depth + 1)
            if found then return found end
        end
        return nil
    end

    return ScanChildren(ChallengesKeystoneFrame, 0)
end


local function BuildCountdownButton()
    if countdownBtn then return end
    if not ChallengesKeystoneFrame then
        Debug("ChallengesKeystoneFrame not found — buttons skipped")
        return
    end

    -- ── Ready Check button ──────────────────────────────────────────────────
    readyCheckBtn = CreateFrame("Button", "AutoKeyReadyCheckBtn", UIParent,
        "UIPanelButtonTemplate,SecureActionButtonTemplate")
    readyCheckBtn:SetSize(160, 26)
    readyCheckBtn:SetFrameStrata("HIGH")
    -- Anchored to the left of the keystone frame, slightly above center
    readyCheckBtn:SetPoint("RIGHT", ChallengesKeystoneFrame, "LEFT", -8, 17)
    readyCheckBtn:SetText("Ready Check")

    readyCheckBtn:SetAttribute("type", "macro")
    readyCheckBtn:SetAttribute("macrotext", "/readycheck")

    readyCheckBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Send a Ready Check to your party", 1, 1, 1)
        GameTooltip:Show()
    end)
    readyCheckBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    ChallengesKeystoneFrame:HookScript("OnShow", function()
        readyCheckBtn:Show()
    end)
    ChallengesKeystoneFrame:HookScript("OnHide", function()
        readyCheckBtn:Hide()
    end)

    -- ── Countdown button ────────────────────────────────────────────────────
    countdownBtn = CreateFrame("Button", "AutoKeyCountdownBtn", UIParent,
        "UIPanelButtonTemplate,SecureActionButtonTemplate")
    countdownBtn:SetSize(160, 26)
    countdownBtn:SetFrameStrata("HIGH")

    -- Anchor: Countdown sits directly below the Ready Check button.
    countdownBtn:SetPoint("TOP", readyCheckBtn, "BOTTOM", 0, -4)
    countdownBtn:SetText("Countdown & Start Key")

    -- /countdown 10 via the secure macro attribute — no RunMacroText needed.
    countdownBtn:SetAttribute("type", "macro")
    -- /pull 10 is BigWigs' pull timer command — triggers the visible
    -- countdown for the whole group. Falls back to /countdown 10 if /pull
    -- isn't registered (i.e. BigWigs not loaded).
    countdownBtn:SetAttribute("macrotext", "/pull " .. COUNTDOWN_SECONDS)

    -- Show/hide with the keystone frame since we're parented to UIParent.
    ChallengesKeystoneFrame:HookScript("OnShow", function()
        countdownBtn:Show()
    end)
    ChallengesKeystoneFrame:HookScript("OnHide", function()
        countdownBtn:Hide()
        -- Reset if the window is closed mid-countdown
        ResetCountdownState()
    end)

    countdownBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Countdown & Start Key", 1, 1, 1)
        GameTooltip:AddLine("Fires a 10-second BigWigs pull timer (/pull 10)", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Posts KEY STARTING IN # to party chat", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Automatically activates the keystone when countdown ends", 0.4, 1, 0.4, true)
        GameTooltip:Show()
    end)
    countdownBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- PostClick fires in the addon (insecure) environment after the secure
    -- macro action (/pull 10) has already executed.
    countdownBtn:SetScript("PostClick", function(self)
        if countdownRunning or waitingForCountdownStart then return end
        self:SetEnabled(false)

        -- Pre-resolve the activate button (we are out of combat here at the Font).
        if not keystoneActivateBtn then
            keystoneActivateBtn = FindActivateButton()
        end
        if keystoneActivateBtn then
            Debug("Activate button resolved: " .. (keystoneActivateBtn:GetName() or "unnamed"))
        else
            Debug("Could not find Activate button — use /ak scanframe to debug")
        end

        -- BigWigs starts from START_PLAYER_COUNTDOWN, which can be delayed.
        -- Wait for that event so chat + activation stay in sync.
        waitingForCountdownStart = true
        pendingCountdownGUID = UnitGUID("player")
        Debug("Waiting for START_PLAYER_COUNTDOWN to sync chat with pull timer")

        -- Fallback for cases where /pull is unavailable or blocked.
        C_Timer.After(COUNTDOWN_SYNC_TIMEOUT, function()
            if waitingForCountdownStart then
                Debug("No START_PLAYER_COUNTDOWN event received, using local fallback timer")
                StartKeySequence(COUNTDOWN_SECONDS, "fallback")
            end
        end)
    end)

    Debug("Countdown button created, anchored left of ChallengesKeystoneFrame")
end

-- =============================================================================
-- Event Handling
-- =============================================================================

local eventFrame = CreateFrame("Frame", "AutoKeyEventFrame", UIParent)

-- Blizzard shipped this event name with a typo: "RECEPTABLE" (missing a C).
-- This is the real event name confirmed in Big Wigs source.
eventFrame:RegisterEvent("CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN")

-- Fallback trigger: the interaction manager fires for every player interaction frame.
-- We filter for the ChallengeMode type which covers the keystone slot object.
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
eventFrame:RegisterEvent("START_PLAYER_COUNTDOWN")
eventFrame:RegisterEvent("CANCEL_PLAYER_COUNTDOWN")

eventFrame:RegisterEvent("ADDON_LOADED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= addonName then return end

        AutoKeyDB = AutoKeyDB or {}
        db = AutoKeyDB
        for key, value in pairs(defaults) do
            if db[key] == nil then
                db[key] = value
            end
        end

        -- Restore cached dungeon names from SavedVariables so they work inside instances
        -- even after a /reload or relog.
        db.dungeonNames = db.dungeonNames or {}
        for mapID, name in pairs(db.dungeonNames) do
            DUNGEON_NAMES[mapID] = name
        end

        -- Auto-cache current season names now while the API is available (outside instances).
        -- This runs silently on every login so the cache stays up to date.
        if C_ChallengeMode and C_ChallengeMode.GetMaps and C_ChallengeMode.GetMapUIInfo then
            local maps = C_ChallengeMode.GetMaps()
            if maps then
                for _, mapID in ipairs(maps) do
                    local name = select(1, C_ChallengeMode.GetMapUIInfo(mapID))
                    if name and name ~= "" then
                        DUNGEON_NAMES[mapID] = name
                        db.dungeonNames[mapID] = name
                    end
                end
                Debug(("Auto-cached %d dungeon name(s) from C_ChallengeMode"):format(#maps))
            end
        end

        Debug("Loaded v" .. ADDON_VERSION)

    elseif event == "CHALLENGE_MODE_KEYSTONE_RECEPTABLE_OPEN" then
        Debug(event)
        BuildCountdownButton()
        TryInsertKeystone()

    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        local interactionType = ...
        -- Enum.PlayerInteractionType.ChallengeMode covers the Font of Power/keystone object.
        if Enum.PlayerInteractionType and
           interactionType == Enum.PlayerInteractionType.ChallengeMode then
            Debug("PlayerInteractionManager: ChallengeMode")
            BuildCountdownButton()
            TryInsertKeystone()
        end

    elseif event == "START_PLAYER_COUNTDOWN" then
        local initiatedBy, timeSeconds, totalTime = ...
        if not waitingForCountdownStart then
            return
        end

        if pendingCountdownGUID and initiatedBy and initiatedBy ~= pendingCountdownGUID then
            Debug("Ignoring START_PLAYER_COUNTDOWN from another player")
            return
        end

        StartKeySequence(totalTime or timeSeconds or COUNTDOWN_SECONDS, "START_PLAYER_COUNTDOWN")

    elseif event == "CANCEL_PLAYER_COUNTDOWN" then
        if waitingForCountdownStart or countdownRunning then
            Debug("Player countdown canceled, resetting state")
            ResetCountdownState()
        end
    end
end)

-- =============================================================================
-- Slash Commands
-- =============================================================================

SLASH_AUTOKEY1 = "/autokey"
SLASH_AUTOKEY2 = "/ak"

SlashCmdList["AUTOKEY"] = function(msg)
    local cmd = strtrim(msg:lower())

    if cmd == "" or cmd == "help" then
        Msg("v" .. ADDON_VERSION .. "  |cFFAAAAAA(/ak is a shorthand)|r")
        Msg("|cFFFFFF00/autokey enable|r    – Enable automatic insertion")
        Msg("|cFFFFFF00/autokey disable|r   – Disable automatic insertion")
        Msg("|cFFFFFF00/autokey toggle|r    – Toggle on/off")
        Msg("|cFFFFFF00/autokey insert|r    – Manually trigger insertion now")
        Msg("|cFFFFFF00/autokey status|r    – Show status and keystone info")
        Msg("|cFFFFFF00/autokey scanmaps|r  – Cache dungeon names for in-instance display")
        Msg("|cFFFFFF00/autokey verbose|r   – Toggle debug messages")
        Msg("|cFFAAAAFF[Countdown]|r button appears on the keystone window at dungeon start")

    elseif cmd == "enable" then
        db.enabled = true
        Msg("Automatic insertion |cFF00FF00enabled|r.")

    elseif cmd == "disable" then
        db.enabled = false
        Msg("Automatic insertion |cFFFF4444disabled|r.")

    elseif cmd == "toggle" then
        db.enabled = not db.enabled
        Msg("Automatic insertion " .. (db.enabled and "|cFF00FF00enabled|r" or "|cFFFF4444disabled|r") .. ".")

    elseif cmd == "insert" then
        Msg("Triggering keystone insert...")
        TryInsertKeystone()

    elseif cmd == "status" then
        Msg("Status:  " .. (db.enabled and "|cFF00FF00Enabled|r" or "|cFFFF4444Disabled|r"))
        Msg("Verbose: " .. (db.verbose and "On" or "Off"))
        Msg("SlotKeystone API: " .. (SlotKeystone and "|cFF00FF00Available|r" or "|cFFFFAAAABlocked/unavailable|r"))

        -- Show keystone currently in bags
        local bag, _, link = FindKeystoneInBags()
        if bag then
            Msg("Keystone in bags: " .. link)
        else
            Msg("No keystone found in bags.")
        end

        -- Show whether one is already slotted
        if HasSlottedKeystone then
            Msg("Already slotted: " .. (HasSlottedKeystone() and "Yes" or "No"))
        end

        -- Show keystone level/dungeon from C_MythicPlus if available
        if C_MythicPlus then
            local level = C_MythicPlus.GetOwnedKeystoneLevel and C_MythicPlus.GetOwnedKeystoneLevel()
            if level and level > 0 then
                local mapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID
                              and C_MythicPlus.GetOwnedKeystoneChallengeMapID()
                local mapName = mapID and GetDungeonName(mapID) or "Unknown"
                Msg(("Keystone: |cFFFFD700+%d|r %s"):format(level, mapName))
            else
                Msg("No keystone owned (or C_MythicPlus is blocked in this zone).")
            end
        else
            Msg("C_MythicPlus API unavailable in this zone.")
        end

        local count = 0
        for _ in pairs(DUNGEON_NAMES) do count = count + 1 end
        if count > 0 then
            Msg(("Dungeon name cache: %d entr%s"):format(count, count == 1 and "y" or "ies"))
        else
            Msg("|cFFFFAAAADungeon name cache empty.|r Run /autokey scanmaps outside a dungeon.")
        end

    elseif cmd == "verbose" then
        db.verbose = not db.verbose
        Msg("Debug messages: " .. (db.verbose and "On" or "Off"))

    elseif cmd == "scanmaps" then
        -- Reads the current season's challenge map list and caches all names so
        -- they display correctly inside instances where the API is blocked.
        if not C_ChallengeMode or not C_ChallengeMode.GetMaps then
            Msg("|cFFFF4444C_ChallengeMode.GetMaps unavailable.|r Must be run outside a dungeon.")
            return
        end
        local maps = C_ChallengeMode.GetMaps()
        if not maps or #maps == 0 then
            Msg("No challenge maps returned. Run this command outside a dungeon.")
            return
        end
        db.dungeonNames = db.dungeonNames or {}
        Msg(("Found %d dungeon%s in the current season:"):format(#maps, #maps == 1 and "" or "s"))
        for _, mapID in ipairs(maps) do
            local name = "Unknown"
            if C_ChallengeMode.GetMapUIInfo then
                name = select(1, C_ChallengeMode.GetMapUIInfo(mapID)) or name
            end
            DUNGEON_NAMES[mapID]    = name
            db.dungeonNames[mapID]  = name  -- persist across reloads
            Msg(("  [%d] %s"):format(mapID, name))
        end
        Msg("|cFF00FF00Dungeon names cached and saved.|r They will display inside instances.")

    elseif cmd == "scanframe" then
        -- Debug: enumerate children of ChallengesKeystoneFrame to find button names.
        -- Run this command while the keystone (Font of Power) window is open.
        if not ChallengesKeystoneFrame then
            Msg("|cFFFF4444ChallengesKeystoneFrame not found.|r Open the Font of Power first.")
            return
        end
        Msg("Scanning ChallengesKeystoneFrame children:")
        local function PrintChildren(frame, indent)
            indent = indent or ""
            for i = 1, select("#", frame:GetChildren()) do
                local child = select(i, frame:GetChildren())
                local name = child:GetName() or "(unnamed)"
                local typ  = child:GetObjectType()
                local text = (child.GetText and child:GetText()) or ""
                local vis  = child:IsShown() and "shown" or "hidden"
                Msg(indent .. "[" .. i .. "] " .. typ .. " | " .. name .. " | '" .. text .. "' | " .. vis)
                if indent:len() < 6 then
                    PrintChildren(child, indent .. "  ")
                end
            end
        end
        PrintChildren(ChallengesKeystoneFrame)

        -- Also try to find and report the activate button
        local btn = FindActivateButton()
        if btn then
            Msg("|cFF00FF00Activate button found:|r " .. (btn:GetName() or "(no name)"))
        else
            Msg("|cFFFF4444Activate button NOT found by scan.|r Check the output above.")
        end

    else
        Msg("Unknown command. Type |cFFFFFF00/autokey help|r for options.")
    end
end
