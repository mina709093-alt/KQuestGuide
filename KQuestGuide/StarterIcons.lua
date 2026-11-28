-- 퀘스트 시작 아이템 아이콘 (0.38.0)
-- 퀘스트를 시작하는 아이템을 떨어뜨리는 몬스터의 이름표 위에 그 아이템의 아이콘을 붙입니다.
-- 자료: StarterData.lua(QuestieDB 포에버 데이터에서 뽑은 "몬스터 번호 → 시작 아이템")
-- 판단:
--   * 몬스터는 이름이 아니라 NPC 번호(UnitGUID의 다섯 번째 칸)로 찾습니다. GUID가 비밀값이면 표시하지 않습니다.
--   * 아이템마다 "원하는 아이템"인지 미리 계산해 둡니다(이벤트 때만 다시 계산, 매 프레임 검사 없음).
--     원함 = 시작 퀘스트를 아직 안 했고, 목록에 없고, 받을 수 있고(종족·직업·진영·선행 등),
--            그 아이템을 가방·은행에 가지고 있지 않음(C_Item.GetItemCount(번호, true))
--   * 회색(저레벨) 퀘스트도 표시하되 흐리게 그립니다.
-- 이름표 프레임은 고치지 않고, 우리 프레임의 부모만 이름표로 둡니다. 이름표가 사라지면 프레임을 거둬 다시 씁니다.
-- 이름표가 꺼져 있어도 몬스터에 마우스를 올리면 툴팁에 한 줄이 붙습니다.
-- 명령: /kqg 아이콘 (도움말: /kqg 아이콘 도움)
local KQG = KQG
if not KQG then return end

local SD = KQG.StarterData or {}
local NPC = SD.npc or {}
local ITEM = SD.item or {}
local QX = SD.quests or {}
local Q, F = KQG.Q or {}, KQG.F or {}

local WIDE = 30          -- 떨어뜨리는 몬스터가 이만큼 이상이면 넓은 지역 드롭
local MAX_ICONS = 4      -- 한 이름표에 나란히 그리는 최대 개수
local GRAY_ALPHA = 0.45  -- 회색 퀘스트 아이콘의 투명도
local DEFAULTS = { size = 20, pos = "top", x = 0, y = 0, mode = "row", wide = true, tip = true }
local POS_NAME = { top = "위", left = "왼쪽", right = "오른쪽" }
local MODE_NAME = { row = "나란히", one = "하나" }

local function Print(m) if KQG.Print then KQG.Print(m) end end

-- 설정: KQGDB.starter. 없는 값만 기본값으로 채웁니다(off는 켜짐이 기본이라 채우지 않음).
local function Settings()
  local d = KQG.DB and KQG.DB()
  if type(d) ~= "table" then return nil end
  local s = d.starter
  if type(s) ~= "table" then s = {} d.starter = s end
  for k, v in pairs(DEFAULTS) do if s[k] == nil then s[k] = v end end
  return s
end

-- 비밀값이면 nil
local function Plain(v)
  local f = issecretvalue
  if type(f) == "function" then
    local ok, secret = pcall(f, v)
    if not ok or secret then return nil end
  end
  return v
end

-- 유닛의 NPC 번호 (Creature/Vehicle만)
local function NpcIdOf(unit)
  if type(unit) ~= "string" or type(UnitGUID) ~= "function" then return nil end
  local ok, guid = pcall(UnitGUID, unit)
  if not ok then return nil end
  guid = Plain(guid)
  if type(guid) ~= "string" then return nil end
  local kind, id = guid:match("^(%a+)%-[^-]*%-[^-]*%-[^-]*%-[^-]*%-(%d+)%-")
  if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
  return nil
end

local function Dead(unit)
  if type(UnitIsDead) ~= "function" then return false end
  local ok, d = pcall(UnitIsDead, unit)
  return ok and Plain(d) == true
end

local function ItemIcon(id)
  local f = C_Item and C_Item.GetItemIconByID
  if type(f) == "function" then
    local ok, icon = pcall(f, id)
    if ok and icon then return icon end
  end
  f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if type(f) == "function" then
    local ok, _, _, _, _, icon = pcall(f, id)
    if ok and icon then return icon end
  end
  return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function ItemName(id)
  local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if type(f) == "function" then
    local ok, name = pcall(f, id)
    if ok and type(name) == "string" then return name end
  end
  return "아이템 " .. id
end

local function ItemCount(id)
  local f = (C_Item and C_Item.GetItemCount) or GetItemCount
  if type(f) ~= "function" then return 0 end
  local ok, n = pcall(f, id, true)
  if ok and type(n) == "number" then return n end
  return 0
end

local function QTitle(qid)
  if Q[qid] and KQG.QName then return KQG.QName(qid) end
  local f = C_QuestLog and C_QuestLog.GetTitleForQuestID
  if type(f) == "function" then
    local ok, t = pcall(f, qid)
    if ok and type(t) == "string" and t ~= "" then return t end
  end
  return "퀘스트 " .. qid
end

-- ===== 원하는 아이템 계산 =====
local turned = {}   -- 이번 접속에서 제출한 퀘스트 (완료 목록이 늦게 갱신될 때 대비)

local function ReadLogSet()
  local set = {}
  local n = 0
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
    n = C_QuestLog.GetNumQuestLogEntries() or 0
  elseif GetNumQuestLogEntries then
    n = GetNumQuestLogEntries() or 0
  end
  for i = 1, n do
    local qid, header
    if C_QuestLog and C_QuestLog.GetInfo then
      local info = C_QuestLog.GetInfo(i)
      if info then qid, header = info.questID, info.isHeader end
    elseif GetQuestLogTitle then
      local _, _, _, hdr, _, _, _, id = GetQuestLogTitle(i)
      qid, header = id, hdr
    end
    if qid and not header and qid > 0 then set[qid] = true end
  end
  return set
end

local function Done(qid)
  if turned[qid] then return true end
  if KQG.IsDone and KQG.IsDone(qid) then return true end
  local f = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
  if type(f) == "function" then
    local ok, d = pcall(f, qid)
    if ok and d == true then return true end
  end
  return false
end

-- 선행 퀘스트를 다 했는지 (F.PREG 모두, F.PRES 중 하나)
local function PrereqOK(r)
  local preg = F.PREG and r[F.PREG]
  if type(preg) == "table" then
    for _, p in ipairs(preg) do if not Done(p) then return false end end
  end
  local pres = F.PRES and r[F.PRES]
  if type(pres) == "table" and #pres > 0 then
    for _, p in ipairs(pres) do if Done(p) then return true end end
    return false
  end
  return true
end

local function PlayerLevel()
  local lv = UnitLevel and UnitLevel("player")
  if type(lv) ~= "number" then return 1 end
  return lv
end

-- 퀘스트 상태: "log" | "done" | "never" | "pre"(선행 남음) | "gray" | "later"
local function State(qid, log, level)
  if log[qid] then return "log" end
  if Done(qid) then return "done" end
  local r = Q[qid]
  if r then
    local st = KQG.QuestState and KQG.QuestState(qid, log, level) or "later"
    if st == "never" or st == "done" or st == "log" then return st end
    if not PrereqOK(r) then return "pre" end
    return st
  end
  local x = QX[qid]
  if type(x) == "table" then
    if KQG.Bit then
      if not KQG.Bit(x[2], KQG.RaceBit()) then return "never" end
      if not KQG.Bit(x[3], KQG.ClassBit()) then return "never" end
    end
    if KQG.IsGrayLevel and KQG.IsGrayLevel(x[1], level) then return "gray" end
    return "later"
  end
  return "never" -- 자료에 없는 퀘스트는 판단하지 않음 (표시 안 함)
end

local want = {}     -- [아이템] = "later" | "gray"
local reason = {}   -- [아이템] = 표시하지 않는 이유 (/kqg 아이콘 목록)
local RefreshAll

local function Recompute()
  local s = Settings()
  local log = ReadLogSet()
  local level = PlayerLevel()
  local new, why = {}, {}
  for item, e in pairs(ITEM) do
    local st = State(e[1], log, level)
    if st ~= "later" and st ~= "gray" then
      why[item] = st
    elseif s and s.wide == false and (e[2] or 0) >= WIDE then
      why[item] = "wide"
    elseif ItemCount(item) > 0 then
      why[item] = "have"
    else
      new[item] = st
    end
  end
  want, reason = new, why
  if RefreshAll then RefreshAll() end
end

local pending = false
local function Schedule()
  if pending then return end
  pending = true
  local function run()
    pending = false
    local ok, err = pcall(Recompute)
    if not ok and KQG.ReportBug then KQG.ReportBug("시작아이템", err, "") end
  end
  if C_Timer and C_Timer.After then C_Timer.After(0.5, run) else run() end
end

-- 이 몬스터가 떨어뜨리는 원하는 아이템 목록 (없으면 nil)
local function ItemsFor(npcId)
  local list = npcId and NPC[npcId]
  if not list then return nil end
  local out
  for _, it in ipairs(list) do
    if want[it] then
      out = out or {}
      out[#out + 1] = it
    end
  end
  return out
end

-- ===== 이름표 아이콘 =====
local plates = {}   -- [이름표 유닛] = { npc =, holder = }
local pool = {}

local function IconTip(self)
  local h = self:GetParent()
  local it = self.item
  if not (it and GameTooltip and GameTooltip.SetOwner) then return end
  local e = ITEM[it] or {}
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(ItemName(it), 1, 1, 1)
  GameTooltip:AddLine("퀘스트 시작: " .. QTitle(e[1]), 1, 0.82, 0)
  if want[it] == "gray" then GameTooltip:AddLine("회색(저레벨) 퀘스트입니다", 0.6, 0.6, 0.6) end
  local name = h and h.unit and UnitName and Plain((UnitName(h.unit))) or nil
  local n = e[2] or 0
  local who = (type(name) == "string" and name ~= "") and name or "이 몬스터"
  if n > 1 then
    GameTooltip:AddLine("드롭: " .. who .. " 외 " .. (n - 1) .. "종", 0.8, 0.8, 0.8)
  else
    GameTooltip:AddLine("드롭: " .. who, 0.8, 0.8, 0.8)
  end
  GameTooltip:AddLine("[퀘스트 길잡이] 자료 (Questie)", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end
local function IconLeave() if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end end

local function NewIcon(h)
  local b = CreateFrame("Frame", nil, h)
  b.tex = b:CreateTexture(nil, "ARTWORK")
  b.tex:SetAllPoints(b)
  if b.tex.SetTexCoord then b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
  -- 마우스는 툴팁에만 쓰고, 클릭은 이름표로 지나가게 합니다(함수가 없으면 마우스를 받지 않음).
  if b.SetMouseClickEnabled and b.SetMouseMotionEnabled then
    b:EnableMouse(true)
    b:SetMouseClickEnabled(false)
    b:SetMouseMotionEnabled(true)
    b:SetScript("OnEnter", IconTip)
    b:SetScript("OnLeave", IconLeave)
  else
    b:EnableMouse(false)
  end
  return b
end

local function Acquire()
  local h = table.remove(pool)
  if h then return h end
  h = CreateFrame("Frame", nil, UIParent)
  h.icons = {}
  h.count = h:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  return h
end

local function Detach(unit)
  local p = plates[unit]
  local h = p and p.holder
  if not h then return end
  p.holder = nil
  h:Hide()
  h:ClearAllPoints()
  h:SetParent(UIParent)
  h.unit = nil
  for _, b in ipairs(h.icons) do b.item = nil b:Hide() end
  pool[#pool + 1] = h
end

local function PlateOf(unit)
  local get = C_NamePlate and C_NamePlate.GetNamePlateForUnit
  if type(get) ~= "function" then return nil end
  local ok, plate = pcall(get, unit)
  if ok and type(plate) == "table" then return plate end
  return nil
end

local function Layout(h, items, s, plate)
  local n = #items
  local shown = (s.mode == "one") and 1 or math.min(n, MAX_ICONS)
  local size = s.size or DEFAULTS.size
  if shown > 1 then size = math.floor(size * 0.8 + 0.5) end -- 여러 개면 작게
  local gap = 2
  for i = 1, shown do
    local b = h.icons[i]
    if not b then b = NewIcon(h) h.icons[i] = b end
    b.item = items[i]
    b:SetSize(size, size)
    b:ClearAllPoints()
    b:SetPoint("LEFT", h, "LEFT", (i - 1) * (size + gap), 0)
    b.tex:SetTexture(ItemIcon(items[i]))
    if b.tex.SetAlpha then b.tex:SetAlpha(want[items[i]] == "gray" and GRAY_ALPHA or 1) end
    b:Show()
  end
  for i = shown + 1, #h.icons do h.icons[i].item = nil h.icons[i]:Hide() end
  if s.mode == "one" and n > 1 then
    h.count:ClearAllPoints()
    h.count:SetPoint("BOTTOMRIGHT", h.icons[1], "BOTTOMRIGHT", 2, -2)
    h.count:SetText(tostring(n))
    h.count:Show()
  else
    h.count:Hide()
  end
  h:SetSize(shown * size + (shown - 1) * gap, size)
  h:ClearAllPoints()
  local x, y = s.x or 0, s.y or 0
  if s.pos == "left" then
    h:SetPoint("RIGHT", plate, "LEFT", x - 2, y)
  elseif s.pos == "right" then
    h:SetPoint("LEFT", plate, "RIGHT", x + 2, y)
  else
    h:SetPoint("BOTTOM", plate, "TOP", x, y)
  end
  if h.SetFrameLevel and plate.GetFrameLevel then h:SetFrameLevel((plate:GetFrameLevel() or 0) + 20) end
end

local function Attach(unit)
  local p = plates[unit]
  if not p then return end
  local s = Settings()
  local items = s and not s.off and ItemsFor(p.npc)
  local plate = items and not Dead(unit) and PlateOf(unit)
  if not plate then Detach(unit) return end
  local h = p.holder or Acquire()
  p.holder = h
  h.unit = unit
  h:SetParent(plate)
  Layout(h, items, s, plate)
  h:Show()
end

RefreshAll = function()
  for unit in pairs(plates) do Attach(unit) end
end

local function PlateAdded(unit)
  Detach(unit)
  local npc = NpcIdOf(unit)
  if npc and NPC[npc] then
    plates[unit] = plates[unit] or {}
    plates[unit].npc = npc
    Attach(unit)
  else
    plates[unit] = nil
  end
end

local function PlateRemoved(unit)
  Detach(unit)
  plates[unit] = nil
end

-- ===== 몬스터 툴팁 (이름표가 꺼져 있어도 보임) =====
local function UnitTip(tt)
  local s = Settings()
  if not s or s.off or s.tip == false or tt.kqgStarter then return end
  if not tt.GetUnit then return end
  local ok, _, unit = pcall(tt.GetUnit, tt)
  unit = ok and Plain(unit) or nil
  if not unit then return end
  local items = ItemsFor(NpcIdOf(unit))
  if not items then return end
  tt.kqgStarter = true
  for _, it in ipairs(items) do
    local e = ITEM[it] or {}
    local c = want[it] == "gray" and "|cff999999" or "|cffffd100"
    tt:AddLine("|T" .. tostring(ItemIcon(it)) .. ":14|t " .. c .. ItemName(it) .. "|r |cffaaaaaa→ 퀘스트 「" .. QTitle(e[1]) .. "」 시작 (Questie)|r", 1, 1, 1, true)
  end
  tt:Show()
end

local hooked = false
if GameTooltip and GameTooltip.HookScript then
  pcall(function()
    GameTooltip:HookScript("OnTooltipSetUnit", function(tt) pcall(UnitTip, tt) end)
    GameTooltip:HookScript("OnTooltipCleared", function(tt) tt.kqgStarter = nil end)
    hooked = true
  end)
end
if not hooked and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
    and Enum.TooltipDataType.Unit then
  pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, function(tt)
    if tt ~= GameTooltip then return end
    pcall(UnitTip, tt)
  end)
end

-- ===== 이벤트 =====
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN",
    "QUEST_REMOVED", "BAG_UPDATE_DELAYED", "PLAYER_LEVEL_UP", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
    "UNIT_HEALTH" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, a1)
  local ok, err = pcall(function()
    if event == "NAME_PLATE_UNIT_ADDED" then
      PlateAdded(a1)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
      PlateRemoved(a1)
    elseif event == "UNIT_HEALTH" then
      local p = plates[a1]
      if p and p.holder and Dead(a1) then Detach(a1) end
    else
      if event == "QUEST_TURNED_IN" and type(a1) == "number" then turned[a1] = true end
      Schedule()
    end
  end)
  if not ok and KQG.ReportBug then KQG.ReportBug("시작아이템", err, event) end
end)

-- ===== 명령 =====
local STATE_NAME = { log = "목록에 있음", done = "끝냄", never = "받을 수 없음", pre = "선행 퀘스트 남음",
  gray = "회색", later = "받을 수 있음", have = "가지고 있음", wide = "넓은 지역 드롭 꺼짐" }

local function OnOff(v) return v and "켜짐" or "꺼짐" end

local function Status(s)
  Print("시작 아이템 아이콘 " .. OnOff(not s.off) .. " / 크기 " .. s.size .. " / 위치 " .. (POS_NAME[s.pos] or s.pos)
    .. ((s.x ~= 0 or s.y ~= 0) and (" (" .. s.x .. ", " .. s.y .. ")") or "")
    .. " / 표시 " .. (MODE_NAME[s.mode] or s.mode) .. " / 넓은 지역 드롭 " .. OnOff(s.wide ~= false)
    .. " / 몬스터 툴팁 " .. OnOff(s.tip ~= false))
end

local function Help()
  Print("/kqg 아이콘 — 퀘스트 시작 아이템을 떨어뜨리는 몬스터 이름표 위에 아이템 아이콘을 표시합니다.")
  Print("  /kqg 아이콘 켜기 / 끄기")
  Print("  /kqg 아이콘 크기 숫자 — 12~40 (기본 20)")
  Print("  /kqg 아이콘 위치 위|왼쪽|오른쪽 [가로 세로] — 예: /kqg 아이콘 위치 위 0 8")
  Print("  /kqg 아이콘 표시 나란히|하나 — 한 몬스터가 여러 아이템을 떨어뜨릴 때")
  Print("  /kqg 아이콘 넓은드롭 켜기|끄기 — 몬스터 " .. WIDE .. "종 이상이 떨어뜨리는 아이템")
  Print("  /kqg 아이콘 툴팁 켜기|끄기 — 몬스터에 마우스를 올렸을 때 툴팁 줄")
  Print("  /kqg 아이콘 목록 — 지금 찾는 아이템 / 목록 전체 — 표시하지 않는 이유까지")
  Print("  /kqg 아이콘 진단 — 지금 보이는 이름표")
end

local function SortedItems(t)
  local out = {}
  for it in pairs(t) do out[#out + 1] = it end
  table.sort(out)
  return out
end

KQG.StarterCommand = function(arg)
  local s = Settings()
  if not s then return end
  arg = arg or ""
  local cmd, rest = arg:match("^(%S+)%s*(.-)%s*$")
  cmd = cmd or ""
  local function on(word)
    if word == "켜기" or word == "on" then return true end
    if word == "끄기" or word == "off" then return false end
    return nil
  end
  if cmd == "" then
    Status(s)
    Print("도움말: /kqg 아이콘 도움")
  elseif cmd == "도움" or cmd == "help" then
    Help()
  elseif on(cmd) ~= nil then
    s.off = not on(cmd) or nil
    RefreshAll()
    Status(s)
  elseif cmd == "크기" or cmd == "size" then
    local n = tonumber(rest)
    if not n then Print("크기는 숫자로 적어 주세요. 예: /kqg 아이콘 크기 24") return end
    s.size = math.max(12, math.min(40, math.floor(n + 0.5)))
    RefreshAll()
    Status(s)
  elseif cmd == "위치" or cmd == "pos" then
    local w, x, y = rest:match("^(%S+)%s*(%-?[%d%.]*)%s*(%-?[%d%.]*)$")
    local map = { ["위"] = "top", top = "top", ["왼쪽"] = "left", left = "left", ["오른쪽"] = "right", right = "right" }
    if not (w and map[w]) then Print("위치는 위, 왼쪽, 오른쪽 중 하나입니다. 예: /kqg 아이콘 위치 위 0 8") return end
    s.pos = map[w]
    s.x = tonumber(x) or 0
    s.y = tonumber(y) or 0
    RefreshAll()
    Status(s)
  elseif cmd == "표시" or cmd == "mode" then
    local map = { ["나란히"] = "row", row = "row", ["하나"] = "one", one = "one" }
    if not map[rest] then Print("표시는 나란히 또는 하나입니다.") return end
    s.mode = map[rest]
    RefreshAll()
    Status(s)
  elseif cmd == "넓은드롭" or cmd == "wide" then
    local v = on(rest)
    if v == nil then v = (s.wide == false) end
    s.wide = v
    Schedule()
    Status(s)
  elseif cmd == "툴팁" or cmd == "tip" then
    local v = on(rest)
    if v == nil then v = (s.tip == false) end
    s.tip = v
    Status(s)
  elseif cmd == "목록" or cmd == "list" then
    Recompute()
    local all = (rest == "전체" or rest == "all")
    local list = SortedItems(want)
    Print("찾는 시작 아이템 " .. #list .. "개 (자료 " .. (function() local n = 0 for _ in pairs(ITEM) do n = n + 1 end return n end)() .. "개)")
    for i, it in ipairs(list) do
      if i > 30 then Print("  …") break end
      local e = ITEM[it]
      Print("  " .. ItemName(it) .. " (" .. it .. ") → " .. QTitle(e[1]) .. " / 몬스터 " .. e[2] .. "종"
        .. (want[it] == "gray" and " / 회색" or ""))
    end
    if all then
      local shown = 0
      for _, it in ipairs(SortedItems(reason)) do
        if reason[it] ~= "never" then
          shown = shown + 1
          if shown <= 40 then Print("  [안 보임] " .. ItemName(it) .. " → " .. QTitle(ITEM[it][1]) .. ": " .. (STATE_NAME[reason[it]] or reason[it])) end
        end
      end
    end
  elseif cmd == "진단" or cmd == "debug" then
    local n, shown = 0, 0
    for unit, p in pairs(plates) do
      n = n + 1
      if p.holder then shown = shown + 1 end
      local items = ItemsFor(p.npc)
      Print("  " .. unit .. " NPC " .. tostring(p.npc) .. " / 아이템 " .. (items and #items or 0) .. (p.holder and " / 표시 중" or ""))
    end
    Print("시작 아이템 몬스터 이름표 " .. n .. "개, 아이콘 표시 " .. shown .. "개, 대기 프레임 " .. #pool .. "개"
      .. " / 비밀값 검사 " .. (type(issecretvalue) == "function" and "있음" or "없음")
      .. " / 이름표 API " .. ((C_NamePlate and C_NamePlate.GetNamePlateForUnit) and "있음" or "없음"))
  else
    Help()
  end
end

-- 시험용
KQG.StarterWant = function() return want end
KQG.StarterRecompute = function() Recompute() end
