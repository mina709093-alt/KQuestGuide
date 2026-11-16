-- 지금 수락할 NPC 표시
-- 안내 목록 앞쪽(8단계)의 "수락" 단계에 있는 NPC를 번호로 찾아 표시합니다.
--   1) NPC 툴팁에 "▶ 지금 수락할 NPC: 「퀘스트명」" 줄을 붙입니다.
--   2) NPC를 대상으로 잡으면 채팅창에 한 줄 알립니다 (같은 NPC는 90초에 한 번).
--   3) 이름표(네임플레이트)가 보이면 머리 위에 노란 느낌표를 붙입니다. (이름표가 안 보이는 설정이면 나타나지 않음)
-- 판정은 번호(GUID 안의 NPC 번호)로만 합니다. 게시판 같은 오브젝트는 대상이 아닙니다.
-- /kqg npc : 켜기/끄기   /kqg npc debug : 점검 정보
local KQG = KQG
if not KQG then return end

local Q = KQG.Q
local function db() return KQG.DB() end
local function Print(m) if KQG.Print then KQG.Print(m) end end
local function On() local d = db() return d and d.npcMark ~= false end

local stat = { tip = 0, tipHit = 0, target = 0, plate = 0, plateHit = 0, lastGuid = "-", lastId = "-", lastPlate = "-" }
local told = {}

-- NPC 번호 -> 퀘스트 이름 목록 (수락 단계만)
local function Wanted()
  local out, n = {}, 0
  local steps = KQG.Steps and KQG.Steps() or {}
  for i = 1, math.min(#steps, 8) do
    local g = steps[i]
    if g and g.kind == "accept" and g.loc and g.loc[1] == "n" and g.loc[2] then
      local list = out[g.loc[2]]
      if not list then list = {} out[g.loc[2]] = list end
      for _, qid in ipairs(g.quests or {}) do
        local r = Q[qid]
        list[#list + 1] = (r and r[1]) or ("#" .. tostring(qid))
      end
    end
  end
  return out
end

local function NpcId(guid)
  if type(guid) ~= "string" then return nil end
  local kind, _, _, _, _, id = strsplit("-", guid)
  if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
  return tonumber(id)
end

local function Match(unit)
  if not unit then return nil end
  local ok, guid = pcall(UnitGUID, unit)
  if not ok or not guid then return nil end
  stat.lastGuid = tostring(guid)
  local id = NpcId(guid)
  stat.lastId = tostring(id)
  if not id then return nil end
  local w = Wanted()[id]
  if w and #w > 0 then return w, id end
end

local function Label(names)
  local s = names[1]
  if #names > 1 then s = s .. " 외 " .. (#names - 1) end
  return s
end

-- ===== 툴팁 =====
local function OnUnitTip(tt)
  if not On() then return end
  stat.tip = stat.tip + 1
  local ok, _, unit = pcall(tt.GetUnit, tt)
  if not ok or not unit then return end
  local names = Match(unit)
  if not names then return end
  stat.tipHit = stat.tipHit + 1
  tt:AddLine("▶ 지금 수락할 NPC: 「" .. Label(names) .. "」", 1, 0.82, 0)
  tt:Show()
end

local hooked = false
if GameTooltip and GameTooltip.HookScript then
  local ok = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", OnUnitTip)
  hooked = ok
end
if not hooked and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, function(tt)
    if tt == GameTooltip then OnUnitTip(tt) end
  end)
end

-- ===== 이름표 아이콘 =====
local function PlateIcon(plate)
  local t = plate.KQGNpc
  if t then return t end
  t = plate:CreateTexture(nil, "OVERLAY")
  t:SetSize(18, 18)
  t:SetPoint("BOTTOM", plate, "TOP", 0, 2)
  t:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
  t:Hide()
  plate.KQGNpc = t
  return t
end

local function UpdatePlate(unit)
  if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return end
  local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
  if not ok or not plate then return end
  stat.plate = stat.plate + 1
  stat.lastPlate = tostring(unit)
  local icon = PlateIcon(plate)
  local names = On() and Match(unit)
  if names then icon:Show() stat.plateHit = stat.plateHit + 1 else icon:Hide() end
end

local function RefreshPlates()
  if not C_NamePlate or not C_NamePlate.GetNamePlates then return end
  local ok, plates = pcall(C_NamePlate.GetNamePlates)
  if not ok or type(plates) ~= "table" then return end
  for _, p in ipairs(plates) do
    local u = p.namePlateUnitToken or (p.UnitFrame and p.UnitFrame.unit)
    if u then UpdatePlate(u) end
  end
end
KQG.NpcRefresh = RefreshPlates

local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }) do
  pcall(f.RegisterEvent, f, e)
end
f:SetScript("OnEvent", function(_, event, unit)
  local ok, err = pcall(function()
    if event == "PLAYER_TARGET_CHANGED" then
      if not On() then return end
      local names, id = Match("target")
      if not names then return end
      stat.target = stat.target + 1
      local now = GetTime()
      if told[id] and now - told[id] < 90 then return end
      told[id] = now
      Print("이 NPC에게 퀘스트를 수락하세요: 「" .. Label(names) .. "」")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
      UpdatePlate(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
      if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        local ok2, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
        if ok2 and plate and plate.KQGNpc then plate.KQGNpc:Hide() end
      end
    end
  end)
  if not ok and not stat.err then stat.err = tostring(err) end
end)

KQG.NpcCommand = function(arg)
  arg = arg or ""
  local d = db()
  if not d then return end
  if arg == "debug" then
    local w, c = Wanted(), 0
    for _ in pairs(w) do c = c + 1 end
    Print("NPC 표시 점검: 켜짐=" .. tostring(On()) .. " / 수락 대기 NPC " .. c .. "명")
    Print("툴팁 훅=" .. tostring(hooked) .. " 툴팁 " .. stat.tip .. "회 (일치 " .. stat.tipHit .. ")")
    Print("대상 일치 " .. stat.target .. "회 / 이름표 이벤트 " .. stat.plate .. "회 (일치 " .. stat.plateHit .. ")")
    Print("이름표 API=" .. tostring(C_NamePlate and C_NamePlate.GetNamePlateForUnit and true or false)
      .. " / 마지막 GUID " .. stat.lastGuid .. " 번호 " .. stat.lastId .. " 이름표 " .. stat.lastPlate)
    if stat.err then Print("오류: " .. stat.err) end
    return
  end
  d.npcMark = not On()
  Print("수락 NPC 표시 " .. (On() and "켜짐" or "꺼짐"))
  RefreshPlates()
end

-- 안내 단계가 바뀌면 이름표 표시도 맞춰 줌
if C_Timer and C_Timer.NewTicker then
  C_Timer.NewTicker(3, function() pcall(RefreshPlates) end)
end
