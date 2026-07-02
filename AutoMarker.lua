--[[--------------------------------------------------------------------
	AutoMarker (WoW 3.3.5a)

	Automatically sets raid target icons on your team (players and,
	optionally, their pets) when you enter an arena. Marks are
	configurable per class and per pet type via the in-game GUI.

	Slash commands:
		/am or /automarker   - toggle the configuration window
		/am mark             - apply marks right now (works anywhere)
		/am clear            - remove all marks from your group
		/am on | off         - enable/disable automatic arena marking
----------------------------------------------------------------------]]

local ADDON_NAME = "AutoMarker"
local VERSION = "2.0"

-- ---------------------------------------------------------------------
-- Constants and defaults
-- ---------------------------------------------------------------------

local ICON_NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }

local CLASS_ORDER = {
	"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
	"DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
}

local PET_ORDER = { "HUNTER", "WARLOCK", "DEATHKNIGHT", "OTHER" }
local PET_LABELS = {
	HUNTER = "Hunter pet",
	WARLOCK = "Warlock pet",
	DEATHKNIGHT = "DK ghoul",
	OTHER = "Other pets",
}

local CLASS_NAMES = {
	WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter",
	ROGUE = "Rogue", PRIEST = "Priest", DEATHKNIGHT = "Death Knight",
	SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
do
	-- Use the client's localized class names when available.
	local localized = LOCALIZED_CLASS_NAMES_MALE
	if type(localized) == "table" then
		for class in pairs(CLASS_NAMES) do
			if localized[class] then
				CLASS_NAMES[class] = localized[class]
			end
		end
	end
end

local DEFAULTS = {
	enabled = true,
	onlyAsLeader = false,
	-- 0 means "no mark". Duplicates between classes are fine: if two
	-- units want the same icon, the later one gets the first free icon.
	classMarks = {
		WARRIOR = 7, PALADIN = 3, HUNTER = 4, ROGUE = 1, PRIEST = 8,
		DEATHKNIGHT = 7, SHAMAN = 6, MAGE = 5, WARLOCK = 3, DRUID = 2,
	},
	petMarks = { HUNTER = 0, WARLOCK = 0, DEATHKNIGHT = 0, OTHER = 0 },
}

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------

local db                    -- points at AutoMarkerDB once loaded
local inArena = false
local pendingClear = false  -- clear leftover marks on the next pass
local gui
local dropdowns = {}
local SetEnabled            -- forward declaration (defined after the GUI)

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99AutoMarker|r: " .. tostring(msg))
end

local function IconLabel(icon)
	if not icon or icon == 0 then
		return "None"
	end
	return string.format("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:16|t %s",
		icon, ICON_NAMES[icon] or icon)
end

local function CopyDefaults(src, dst)
	if type(dst) ~= "table" then
		dst = {}
	end
	for k, v in pairs(src) do
		if type(v) == "table" then
			dst[k] = CopyDefaults(v, dst[k])
		elseif type(dst[k]) ~= type(v) then
			dst[k] = v
		end
	end
	return dst
end

local function SanitizeIcon(value, fallback)
	value = tonumber(value)
	if not value then
		return fallback
	end
	value = math.floor(value)
	if value < 0 or value > 8 then
		return fallback
	end
	return value
end

local function IsLeader()
	if GetNumRaidMembers() > 0 then
		return IsRaidLeader()
	end
	if GetNumPartyMembers() > 0 then
		return IsPartyLeader()
	end
	return true
end

-- Runs the callback for every unit we may put a mark on.
local function ForEachGroupUnit(callback)
	callback("player")
	for i = 1, GetNumPartyMembers() do
		callback("party" .. i)
	end
	callback("pet")
	for i = 1, GetNumPartyMembers() do
		callback("partypet" .. i)
	end
end

-- ---------------------------------------------------------------------
-- Marking engine
-- ---------------------------------------------------------------------

-- Party unit indices differ between clients (you are never your own
-- "party1"), so sort players by name to get an ordering every client
-- agrees on. That way two teammates both running AutoMarker compute
-- identical assignments and never fight over the marks.
local function SortedGroupUnits()
	local players, pets = {}, {}

	local function addPlayer(unit)
		if UnitExists(unit) then
			players[#players + 1] = { unit = unit, name = UnitName(unit) or "" }
		end
	end
	addPlayer("player")
	for i = 1, GetNumPartyMembers() do
		addPlayer("party" .. i)
	end
	table.sort(players, function(a, b)
		if a.name == b.name then
			return a.unit < b.unit
		end
		return a.name < b.name
	end)

	for _, p in ipairs(players) do
		local petUnit
		if p.unit == "player" then
			petUnit = "pet"
		else
			petUnit = "partypet" .. string.sub(p.unit, 6)
		end
		if UnitExists(petUnit) then
			local _, ownerClass = UnitClass(p.unit)
			pets[#pets + 1] = { unit = petUnit, ownerClass = ownerClass }
		end
	end

	return players, pets
end

local function ComputeAssignments()
	local players, pets = SortedGroupUnits()
	local assignments, used = {}, {}

	local function assign(unit, wanted)
		if not wanted or wanted <= 0 then
			return
		end
		local icon
		if not used[wanted] then
			icon = wanted
		else
			for i = 1, 8 do
				if not used[i] then
					icon = i
					break
				end
			end
		end
		if icon then
			used[icon] = true
			assignments[unit] = icon
		end
	end

	-- Players first so they always win their preferred icon over pets.
	for _, p in ipairs(players) do
		local _, class = UnitClass(p.unit)
		if class then
			assign(p.unit, db.classMarks[class])
		end
	end
	for _, p in ipairs(pets) do
		local wanted = p.ownerClass and db.petMarks[p.ownerClass]
		if wanted == nil then
			wanted = db.petMarks.OTHER
		end
		assign(p.unit, wanted)
	end

	return assignments
end

local function ApplyMarks(clearUnassigned)
	local assignments = ComputeAssignments()
	ForEachGroupUnit(function(unit)
		if UnitExists(unit) then
			local wanted = assignments[unit]
			local current = GetRaidTargetIndex(unit)
			if wanted then
				if current ~= wanted then
					SetRaidTarget(unit, wanted)
				end
			elseif clearUnassigned and current then
				-- Only on the first pass after entering an arena, so we
				-- wipe stale marks without fighting manual marking later.
				SetRaidTarget(unit, 0)
			end
		end
	end)
end

-- ---------------------------------------------------------------------
-- Watcher: re-checks the marks every couple of seconds for a while,
-- because SetRaidTarget can silently fail right after a loading screen
-- and pets are often summoned late during arena preparation.
-- ---------------------------------------------------------------------

local watcher = CreateFrame("Frame")
watcher:Hide()
local watchTime, tickTime = 0, 0

local function StopWatch()
	watchTime = 0
	watcher:Hide()
end

local function StartWatch(duration, firstDelay)
	firstDelay = firstDelay or 0.5
	if watcher:IsShown() then
		watchTime = math.max(watchTime, duration)
		tickTime = math.min(tickTime, firstDelay)
	else
		watchTime = duration
		tickTime = firstDelay
		watcher:Show()
	end
end

watcher:SetScript("OnUpdate", function(self, elapsed)
	watchTime = watchTime - elapsed
	tickTime = tickTime - elapsed
	if tickTime <= 0 then
		tickTime = 2
		if db and db.enabled and inArena and (not db.onlyAsLeader or IsLeader()) then
			ApplyMarks(pendingClear)
			pendingClear = false
		end
	end
	if watchTime <= 0 then
		StopWatch()
	end
end)

-- ---------------------------------------------------------------------
-- Manual actions
-- ---------------------------------------------------------------------

local function ManualMark()
	if not db then
		return
	end
	if GetNumRaidMembers() > 0 and not (IsRaidLeader() or IsRaidOfficer()) then
		Print("You must be raid leader or assistant to set marks in a raid.")
		return
	end
	ApplyMarks(true)
	Print("Marks applied.")
end

local function ClearAllMarks()
	ForEachGroupUnit(function(unit)
		if UnitExists(unit) and GetRaidTargetIndex(unit) then
			SetRaidTarget(unit, 0)
		end
	end)
	StopWatch()
	Print("Marks cleared.")
end

-- ---------------------------------------------------------------------
-- GUI
-- ---------------------------------------------------------------------

local function CreateMarkDropdown(name, getValue, setValue)
	local dd = CreateFrame("Frame", name, gui, "UIDropDownMenuTemplate")
	UIDropDownMenu_SetWidth(dd, 110)

	local text = _G[name .. "Text"]
	local function RefreshText()
		text:SetText(IconLabel(getValue()))
	end

	UIDropDownMenu_Initialize(dd, function()
		local current = getValue()
		for value = 0, 8 do
			local info = UIDropDownMenu_CreateInfo()
			info.text = IconLabel(value)
			info.value = value
			info.checked = (current == value)
			info.func = function()
				setValue(value)
				RefreshText()
				CloseDropDownMenus()
			end
			UIDropDownMenu_AddButton(info)
		end
	end)

	dd.RefreshText = RefreshText
	RefreshText()
	return dd
end

local function RefreshGUI()
	if not gui then
		return
	end
	_G["AutoMarkerEnableCheck"]:SetChecked(db.enabled)
	_G["AutoMarkerLeaderCheck"]:SetChecked(db.onlyAsLeader)
	for _, dd in ipairs(dropdowns) do
		dd.RefreshText()
	end
end

local function CreateGUI()
	gui = CreateFrame("Frame", "AutoMarkerFrame", UIParent)
	gui:SetWidth(540)
	gui:SetHeight(445)
	gui:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	gui:SetFrameStrata("DIALOG")
	gui:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	gui:SetMovable(true)
	gui:EnableMouse(true)
	gui:RegisterForDrag("LeftButton")
	gui:SetScript("OnDragStart", gui.StartMoving)
	gui:SetScript("OnDragStop", gui.StopMovingOrSizing)
	gui:Hide()
	tinsert(UISpecialFrames, "AutoMarkerFrame") -- close on Escape

	local title = gui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -20)
	title:SetText("AutoMarker |cff888888v" .. VERSION .. "|r")

	local close = CreateFrame("Button", nil, gui, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -8, -8)

	local enable = CreateFrame("CheckButton", "AutoMarkerEnableCheck", gui, "UICheckButtonTemplate")
	enable:SetPoint("TOPLEFT", 24, -46)
	_G["AutoMarkerEnableCheckText"]:SetText("Automatically mark my team when entering an arena")
	_G["AutoMarkerEnableCheckText"]:SetFontObject(GameFontHighlight)
	enable:SetScript("OnClick", function(self)
		SetEnabled(self:GetChecked() and true or false)
	end)

	local leader = CreateFrame("CheckButton", "AutoMarkerLeaderCheck", gui, "UICheckButtonTemplate")
	leader:SetPoint("TOPLEFT", 24, -72)
	_G["AutoMarkerLeaderCheckText"]:SetText("Only mark when I am the party leader")
	_G["AutoMarkerLeaderCheckText"]:SetFontObject(GameFontHighlight)
	leader:SetScript("OnClick", function(self)
		db.onlyAsLeader = self:GetChecked() and true or false
	end)

	local classHeader = gui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	classHeader:SetPoint("TOPLEFT", 24, -108)
	classHeader:SetText("Class marks")

	for i, class in ipairs(CLASS_ORDER) do
		local col = (i <= 5) and 0 or 1
		local row = (i - 1) % 5
		local x = 30 + col * 250
		local y = -128 - row * 30

		local label = gui:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("TOPLEFT", x, y - 8)
		label:SetText(CLASS_NAMES[class])
		local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
		if color then
			label:SetTextColor(color.r, color.g, color.b)
		end

		local dd = CreateMarkDropdown("AutoMarkerDropClass" .. class,
			function() return db.classMarks[class] end,
			function(v) db.classMarks[class] = v end)
		dd:SetPoint("TOPLEFT", x + 86, y + 2)
		dropdowns[#dropdowns + 1] = dd
	end

	local petHeader = gui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	petHeader:SetPoint("TOPLEFT", 24, -290)
	petHeader:SetText("Pet marks")

	for i, key in ipairs(PET_ORDER) do
		local col = (i <= 2) and 0 or 1
		local row = (i - 1) % 2
		local x = 30 + col * 250
		local y = -310 - row * 30

		local label = gui:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		label:SetPoint("TOPLEFT", x, y - 8)
		label:SetText(PET_LABELS[key])
		local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[key]
		if color then
			label:SetTextColor(color.r, color.g, color.b)
		end

		local dd = CreateMarkDropdown("AutoMarkerDropPet" .. key,
			function() return db.petMarks[key] end,
			function(v) db.petMarks[key] = v end)
		dd:SetPoint("TOPLEFT", x + 86, y + 2)
		dropdowns[#dropdowns + 1] = dd
	end

	local markBtn = CreateFrame("Button", nil, gui, "UIPanelButtonTemplate")
	markBtn:SetWidth(90)
	markBtn:SetHeight(22)
	markBtn:SetPoint("BOTTOMLEFT", 22, 18)
	markBtn:SetText("Mark now")
	markBtn:SetScript("OnClick", ManualMark)

	local clearBtn = CreateFrame("Button", nil, gui, "UIPanelButtonTemplate")
	clearBtn:SetWidth(90)
	clearBtn:SetHeight(22)
	clearBtn:SetPoint("LEFT", markBtn, "RIGHT", 8, 0)
	clearBtn:SetText("Clear marks")
	clearBtn:SetScript("OnClick", ClearAllMarks)

	local defaultsBtn = CreateFrame("Button", nil, gui, "UIPanelButtonTemplate")
	defaultsBtn:SetWidth(90)
	defaultsBtn:SetHeight(22)
	defaultsBtn:SetPoint("LEFT", clearBtn, "RIGHT", 8, 0)
	defaultsBtn:SetText("Defaults")
	defaultsBtn:SetScript("OnClick", function()
		db.enabled = DEFAULTS.enabled
		db.onlyAsLeader = DEFAULTS.onlyAsLeader
		db.classMarks = CopyDefaults(DEFAULTS.classMarks, {})
		db.petMarks = CopyDefaults(DEFAULTS.petMarks, {})
		RefreshGUI()
		Print("Settings restored to defaults.")
	end)

	local closeBtn = CreateFrame("Button", nil, gui, "UIPanelButtonTemplate")
	closeBtn:SetWidth(80)
	closeBtn:SetHeight(22)
	closeBtn:SetPoint("BOTTOMRIGHT", -22, 18)
	closeBtn:SetText("Close")
	closeBtn:SetScript("OnClick", function() gui:Hide() end)

	local hint = gui:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOM", 0, 46)
	hint:SetText("/am mark   -   /am clear   -   /am on|off")
end

local function ToggleGUI()
	if not db then
		Print("Still loading, try again in a moment.")
		return
	end
	if not gui then
		CreateGUI()
	end
	if gui:IsShown() then
		gui:Hide()
	else
		RefreshGUI()
		gui:Show()
	end
end

SetEnabled = function(value)
	if not db then
		return
	end
	db.enabled = value
	if value then
		Print("Automatic arena marking |cff00ff00enabled|r.")
		if inArena then
			pendingClear = true
			StartWatch(120, 0.5)
		end
	else
		Print("Automatic arena marking |cffff0000disabled|r.")
		StopWatch()
	end
	RefreshGUI()
end

-- ---------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------

SLASH_AUTOMARKER1 = "/automarker"
SLASH_AUTOMARKER2 = "/am"
SlashCmdList["AUTOMARKER"] = function(msg)
	local cmd = string.lower(string.match(msg or "", "^%s*(%S*)") or "")
	if cmd == "mark" then
		ManualMark()
	elseif cmd == "clear" then
		ClearAllMarks()
	elseif cmd == "on" then
		SetEnabled(true)
	elseif cmd == "off" then
		SetEnabled(false)
	elseif cmd == "help" then
		Print("/am - options, /am mark - mark now, /am clear - clear marks, /am on|off - toggle auto marking")
	else
		ToggleGUI()
	end
end

-- ---------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("UNIT_PET")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if type(arg1) == "string" and string.lower(arg1) == string.lower(ADDON_NAME) then
			AutoMarkerDB = CopyDefaults(DEFAULTS, AutoMarkerDB)
			db = AutoMarkerDB
			for class, fallback in pairs(DEFAULTS.classMarks) do
				db.classMarks[class] = SanitizeIcon(db.classMarks[class], fallback)
			end
			for key, fallback in pairs(DEFAULTS.petMarks) do
				db.petMarks[key] = SanitizeIcon(db.petMarks[key], fallback)
			end
			self:UnregisterEvent("ADDON_LOADED")
		end
		return
	end

	if not db then
		return
	end

	if event == "PLAYER_ENTERING_WORLD" then
		local _, instanceType = IsInInstance()
		inArena = (instanceType == "arena")
		if inArena then
			if db.enabled then
				if db.onlyAsLeader and not IsLeader() then
					Print("Arena detected - not marking (you are not the leader).")
				else
					Print("Arena detected - marking your team.")
				end
				pendingClear = true
				StartWatch(120, 1)
			end
		else
			StopWatch()
		end
	elseif event == "UNIT_PET" or event == "PARTY_MEMBERS_CHANGED" then
		-- A pet was summoned/dismissed or the group changed: re-check
		-- the marks for a few seconds.
		if inArena and db.enabled then
			StartWatch(8, 0.5)
		end
	end
end)
