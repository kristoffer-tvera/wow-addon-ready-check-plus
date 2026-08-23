local ADDON_NAME = "ReadyCheckPlus"
local db

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function GetGroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    end
    if IsInRaid() then
        return "RAID"
    end
    if IsInGroup() then
        return "PARTY"
    end
end

local function TrimLower(s)
    return s:lower():match("^%s*(.-)%s*$")
end

local function IsReadyMessage(msg)
    local m = TrimLower(msg)
    return m == "r" or m == "r!" or m == "ready" or m == "ready!" or m == "rdy" or m == "rdy!"
end

-- strips realm suffix for name comparisons
local function BaseName(fullName)
    return (fullName:match("^([^%-]+)") or fullName):lower()
end

-- ─── Leader Frame ───────────────────────────────────────────────────────────

local MAX_ROWS = 40
local ROW_H = 26
local FRAME_W = 280
local HDR_H = 40
local FOOTER_H = 12

local LeaderFrame
local notReadyList = {} -- ordered array of full player names shown in the list

-- populated during an active ready check; keyed by unit token
local rcpTracking = {}

local function SavePosition()
    local point, _, relPoint, x, y = LeaderFrame:GetPoint()
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function ApplyPosition()
    LeaderFrame:ClearAllPoints()
    if db.x then
        LeaderFrame:SetPoint(db.point or "CENTER", UIParent, db.relPoint or "CENTER", db.x, db.y)
    else
        LeaderFrame:SetPoint("CENTER")
    end
end

local function RefreshLeaderFrame()
    local count = #notReadyList
    if count == 0 then
        LeaderFrame:Hide()
        return
    end

    local wasHidden = not LeaderFrame:IsShown()
    LeaderFrame:SetHeight(HDR_H + count * ROW_H + FOOTER_H)

    for i = 1, MAX_ROWS do
        local row = LeaderFrame.rows[i]
        if i <= count then
            local fullName = notReadyList[i]
            row.lbl:SetText(fullName:match("^([^%-]+)") or fullName)
            row.btn.fullName = fullName
            row:SetPoint("TOPLEFT", LeaderFrame, "TOPLEFT", 14, -(HDR_H + (i - 1) * ROW_H))
            row:Show()
        else
            row:Hide()
        end
    end

    -- only reposition when first showing; don't snap the frame while the user has it dragged open
    if wasHidden then
        ApplyPosition()
    end
    LeaderFrame:Show()
end

local function BuildLeaderFrame()
    local f = CreateFrame("Frame", "RCPLeaderFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, 40)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = {
            left = 11,
            right = 12,
            top = 12,
            bottom = 11
        }
    })

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("Not Ready")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    -- pre-allocate a fixed pool of row frames to avoid accumulation across many ready checks
    f.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(FRAME_W - 28, ROW_H)

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", 2, 0)
        lbl:SetPoint("RIGHT", row, "RIGHT", -80, 0)
        lbl:SetJustifyH("LEFT")
        lbl:SetWordWrap(false)
        row.lbl = lbl

        local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(72, 20)
        btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        btn:SetText("Whisper")
        btn:SetScript("OnClick", function(self)
            SendChatMessage("Ready?", "WHISPER", nil, self.fullName)
        end)
        row.btn = btn

        row:Hide()
        f.rows[i] = row
    end

    LeaderFrame = f
    f:Hide()
end

local function RemovePlayerFromList(senderName)
    local inBase = BaseName(senderName)
    for i, full in ipairs(notReadyList) do
        if BaseName(full) == inBase then
            table.remove(notReadyList, i)
            RefreshLeaderFrame()
            return
        end
    end
end

-- ─── Member Popup ───────────────────────────────────────────────────────────

local MemberPopup

local function BuildMemberPopup()
    local f = CreateFrame("Frame", "RCPMemberPopup", UIParent, "BackdropTemplate")
    f:SetSize(200, 100)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = {
            left = 11,
            right = 12,
            top = 12,
            bottom = 11
        }
    })

    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lbl:SetPoint("TOP", 0, -22)
    lbl:SetText("You are not ready!")

    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(120, 28)
    btn:SetPoint("BOTTOM", 0, 16)
    btn:SetText("Ready!")
    btn:SetScript("OnClick", function()
        local ch = GetGroupChannel()
        if ch then
            SendChatMessage("ready!", ch)
        end
        f:Hide()
    end)

    MemberPopup = f
    f:Hide()
end

-- ─── Events ─────────────────────────────────────────────────────────────────

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("READY_CHECK")
ev:RegisterEvent("READY_CHECK_CONFIRM")
ev:RegisterEvent("READY_CHECK_FINISHED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("CHAT_MSG_RAID")
ev:RegisterEvent("CHAT_MSG_RAID_LEADER")
ev:RegisterEvent("CHAT_MSG_INSTANCE_CHAT")
ev:RegisterEvent("CHAT_MSG_INSTANCE_CHAT_LEADER")
ev:RegisterEvent("CHAT_MSG_PARTY")
ev:RegisterEvent("CHAT_MSG_PARTY_LEADER")

ev:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if (...) ~= ADDON_NAME then
            return
        end
        ReadyCheckPlusDB = ReadyCheckPlusDB or {}
        db = ReadyCheckPlusDB
        BuildLeaderFrame()
        BuildMemberPopup()

    elseif event == "READY_CHECK" then
        -- snapshot every group member as "waiting" before anyone has responded
        rcpTracking = {}
        local function trackUnit(unit)
            if not UnitExists(unit) then
                return
            end
            local name, realm = UnitName(unit)
            if name and name ~= "Unknown" then
                rcpTracking[unit] = {
                    name = name,
                    realm = realm,
                    status = "waiting"
                }
            end
        end
        if IsInRaid() then
            for i = 1, 40 do
                trackUnit("raid" .. i)
            end
        elseif IsInGroup() then
            trackUnit("player")
            for i = 1, 4 do
                trackUnit("party" .. i)
            end
        end

    elseif event == "READY_CHECK_CONFIRM" then
        local unit, isReady = ...
        if rcpTracking[unit] then
            rcpTracking[unit].status = isReady and "ready" or "notready"
        end

    elseif event == "READY_CHECK_FINISHED" then
        if UnitIsGroupLeader("player") or UnitIsRaidOfficer("player") then
            notReadyList = {}
            for unit, data in pairs(rcpTracking) do
                if unit ~= "player" and (data.status == "notready" or data.status == "waiting") then
                    local full = (data.realm and data.realm ~= "") and (data.name .. "-" .. data.realm) or data.name
                    table.insert(notReadyList, full)
                end
            end
            table.sort(notReadyList)
            RefreshLeaderFrame()
        else
            local mine = rcpTracking["player"]
            if mine and (mine.status == "notready" or mine.status == "waiting") then
                MemberPopup:Show()
            end
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        if LeaderFrame then
            LeaderFrame:Hide()
        end
        if MemberPopup then
            MemberPopup:Hide()
        end

    elseif event:find("^CHAT_MSG_") then
        if not (LeaderFrame and LeaderFrame:IsShown()) then
            return
        end
        local msg, sender = ...
        if IsReadyMessage(msg) then
            RemovePlayerFromList(sender)
        end
    end
end)

-- ─── Slash Commands ─────────────────────────────────────────────────────────

SLASH_READYCHECKPLUS1 = "/rcp"
SlashCmdList["READYCHECKPLUS"] = function(msg)
    if TrimLower(msg) == "reset" then
        db.point, db.relPoint, db.x, db.y = nil, nil, nil, nil
        if LeaderFrame then
            LeaderFrame:ClearAllPoints()
            LeaderFrame:SetPoint("CENTER")
        end
        print("|cff00ff00ReadyCheckPlus:|r Frame position reset to center.")
    else
        print("|cff00ff00ReadyCheckPlus:|r Commands: /rcp reset")
    end
end
