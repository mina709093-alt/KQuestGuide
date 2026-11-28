-- 쓰지 않는 퀘스트 아이템 표시
-- 가방/은행 슬롯의 퀘스트 아이템 중 "확실히 더 이상 필요 없는 것"에만 빨간 표시를 얹습니다.
-- (0.35.0) 아이템 번호로 판단합니다. 자료: QuestItemData.lua(QuestieDB 포에버 데이터에서 뽑은 "아이템 → 퀘스트")
-- 판정 기준 (보수적, 모르면 표시하지 않음):
--   * 대상: 분류가 '퀘스트'(12)인 아이템, 또는 '기타'(15) 중 QuestItemData.lua에 있는 것(잡동사니 하위 분류만 들어 있음)
--   * 쓰는 퀘스트(목표·필요 아이템·시작할 때 받는 아이템)나 이 아이템으로 시작하는 퀘스트가
--       - 퀘스트 목록에 있거나, 목록에 있는 퀘스트의 목표 글에 아이템 이름이 있으면: 표시 안 함 (쓰는 중)
--       - 아직 안 했고 받을 수 있으면: 표시 안 함 (나중에 씀). 회색(저레벨) 퀘스트도 그대로 둡니다(툴팁에만 알림)
--       - 모두 끝냈거나 받을 수 없으면(종족·직업·진영, 받을 수 없음 표시, 최대 레벨 초과, 같이 할 수 없는 퀘스트를 끝냄): 빨강
--   * 쓰는 퀘스트 없이 보상으로만 받는 기념품: 그 보상 퀘스트 중 하나를 끝냈으면 빨강
--   * 연결된 퀘스트 자료가 없는 아이템(자료에 0): 빨강 (회색 품질은 제외)
--   * 자료에 없는 아이템은 예전처럼 목표 자료(Objectives)의 아이템 이름으로만 판단합니다.
local KQG = KQG
if not KQG then return end

local Q, F = KQG.Q, KQG.F
local OBJ = KQG_OBJ or {}
local QD = KQG.QItemData or {}
local ITEMS = QD.items or {}
local QX = QD.quests or {}

local function db() return KQG.DB() end
local function Print(m) if KQG.Print then KQG.Print(m) end end

-- 이 클라이언트에 전역 아이템 함수가 없을 수 있어 C_Item 쪽도 함께 확인한다
local function InfoInstant(x)
  local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not f then return nil end
  return f(x)
end
local function ItemName(x)
  local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not f then return nil end
  return (f(x))
end
local function ItemQuality(x)
  local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not f then return nil end
  local _, _, q = f(x)
  return q
end
local function SlotItemID(bag, slot)
  if C_Container and C_Container.GetContainerItemID then return C_Container.GetContainerItemID(bag, slot) end
  if GetContainerItemID then return GetContainerItemID(bag, slot) end
  return nil
end

-- 이름 -> 쓰이는 퀘스트 목록 (수집 목표만)
local nameIndex
local function BuildIndex()
  nameIndex = {}
  for qid, list in pairs(OBJ) do
    for _, o in ipairs(list) do
      if o[1] == "i" and o[2] then
        local t = nameIndex[o[2]]
        if not t then t = {} nameIndex[o[2]] = t end
        t[#t + 1] = qid
      end
    end
  end
end

local function QName(qid)
  local r = Q[qid]
  return r and r[F.NAME] or ("퀘스트 " .. tostring(qid))
end

local function PlayerLevel()
  local lv = UnitLevel and UnitLevel("player")
  if type(lv) ~= "number" then return 1 end
  return lv
end

-- 퀘스트 하나의 상태: "log"(목록에 있음) | "done"(끝냄) | "never"(받을 수 없음) | "gray"(회색) | "later"(나중에 할 수 있음)
local function QuestState(qid, log, level)
  if log[qid] then return "log" end
  local r = Q[qid]
  local flags = r and r[F.FLAGS]
  if flags and math.floor(flags) % 2 == 1 then return "later" end -- 반복 퀘스트는 또 할 수 있음
  if KQG.IsDone(qid) then return "done" end
  if r then
    if KQG.Bit then
      if not KQG.Bit(r[F.RACES], KQG.RaceBit()) then return "never" end
      if not KQG.Bit(r[F.CLASSES], KQG.ClassBit()) then return "never" end
    end
    local s = r[F.START]
    local fr = s and s[7]
    local me = KQG.Faction and KQG.Faction()
    if fr and fr ~= "" and me and not string.find(fr, me, 1, true) then return "never" end
    if r.bl == "x" then return "never" end -- BlockData.lua: 받을 수 없음 (축제 "e"는 다시 열리므로 그대로 둠)
    if r[F.MAXLVL] and level > r[F.MAXLVL] then return "never" end
    if type(r[F.EXCL]) == "table" then
      for _, e in ipairs(r[F.EXCL]) do if e ~= qid and KQG.IsDone(e) then return "never" end end
    end
    if KQG.IsGrayLevel and KQG.IsGrayLevel(r[F.LVL], level) then
      if not (KQG.ChainLeadsToFit and KQG.ChainLeadsToFit(qid, level)) then return "gray" end
    end
    return "later"
  end
  local x = QX[qid]
  if x == "x" then return "never" end
  if type(x) == "table" then
    if KQG.Bit then
      if not KQG.Bit(x[2], KQG.RaceBit()) then return "never" end
      if not KQG.Bit(x[3], KQG.ClassBit()) then return "never" end
    end
    if KQG.IsGrayLevel and KQG.IsGrayLevel(x[1], level) then return "gray" end
  end
  return "later" -- 모르는 퀘스트는 나중에 쓰는 것으로 봄
end
-- (0.38.0) StarterIcons.lua(시작 아이템 아이콘)도 같은 판정을 씁니다
KQG.QuestState = QuestState

-- 퀘스트 목록에 있는 퀘스트의 목표 글 (아이템 이름이 들어 있으면 쓰는 중으로 봄)
local logTexts, logTextsAt
local function LogTexts(log)
  local now = GetTime and GetTime() or 0
  if logTexts and logTextsAt and now - logTextsAt < 1 then return logTexts end
  logTexts, logTextsAt = {}, now
  local f = C_QuestLog and C_QuestLog.GetQuestObjectives
  if type(f) ~= "function" then return logTexts end
  for qid in pairs(log) do
    local ok, objs = pcall(f, qid)
    if ok and type(objs) == "table" then
      for _, o in ipairs(objs) do
        local t = type(o) == "table" and o.text
        if type(t) == "string" then logTexts[#logTexts + 1] = { qid, t } end
      end
    end
  end
  return logTexts
end
local function LogMentions(name, log)
  if not name or name == "" then return nil end
  for _, e in ipairs(LogTexts(log)) do
    if string.find(e[2], name, 1, true) then return e[1] end
  end
  return nil
end

-- 판정 결과
--   verdict: "unused"(빨강) | "inuse"(쓰는 중) | "later"(나중에 씀) | "gray"(회색 퀘스트에만 쓰임) | nil(판단 안 함)
--   names: 관련 퀘스트 이름 목록
--   why(빨강일 때): "done"(쓰는 퀘스트를 끝냄) | "never"(받을 수 없음) | "reward"(보상 기념품) | "nodata"(연결된 퀘스트 자료 없음)
local function Judge(id, name)
  local entry = id and ITEMS[id]
  local log = KQG.LogSet and KQG.LogSet() or {}
  local level = PlayerLevel()
  local inLogQ = LogMentions(name, log)
  if inLogQ then return "inuse", { QName(inLogQ) } end

  -- 쓰는 퀘스트: 자료의 번호 + 목표 자료(Objectives)의 이름
  local uses, seen = {}, {}
  local function add(q) if q and not seen[q] then seen[q] = true uses[#uses + 1] = q end end
  if type(entry) == "table" and entry[1] then for _, q in ipairs(entry[1]) do add(q) end end
  if name then
    if not nameIndex then BuildIndex() end
    for _, q in ipairs(nameIndex[name] or {}) do add(q) end
  end
  local start = type(entry) == "table" and entry[3] or nil

  if #uses == 0 and not start then
    if entry == 0 then
      local qual = ItemQuality(id)
      if qual == nil or qual < 1 then return nil end
      return "unused", {}, "nodata"
    end
    if type(entry) == "table" and entry[2] then
      local names, anyDone = {}, false
      for _, q in ipairs(entry[2]) do
        if log[q] then return "inuse", { QName(q) } end
        if KQG.IsDone(q) then anyDone = true names[#names + 1] = QName(q) end
      end
      if anyDone then return "unused", names, "reward" end
    end
    return nil
  end

  local laterN, grayN, doneN, neverN = {}, {}, {}, {}
  local function check(q)
    local st = QuestState(q, log, level)
    if st == "log" then return true end
    if st == "later" then laterN[#laterN + 1] = QName(q)
    elseif st == "gray" then grayN[#grayN + 1] = QName(q)
    elseif st == "done" then doneN[#doneN + 1] = QName(q)
    else neverN[#neverN + 1] = QName(q) end
  end
  for _, q in ipairs(uses) do
    if check(q) then return "inuse", { QName(q) } end
  end
  if start and not seen[start] then
    if check(start) then return "inuse", { QName(start) } end
  end
  if #laterN > 0 then return "later", laterN end
  if #grayN > 0 then return "gray", grayN end
  if #doneN > 0 then return "unused", doneN, "done" end
  return "unused", neverN, "never"
end

-- 판단할 아이템인지: 퀘스트 분류(12), 또는 자료에 있는 기타 분류(15)
local function IsTarget(id)
  local _, _, _, _, _, classID = InfoInstant(id)
  if classID == 12 then return true end
  if classID == 15 and ITEMS[id] ~= nil then return true end
  return false
end

-- 한 번 훑는 동안 같은 아이템은 다시 계산하지 않음
local scanCache
local function Verdict(id)
  if not id or not IsTarget(id) then return nil end
  local name = ItemName(id)
  if not name then return nil end
  if scanCache and scanCache[id] then return unpack(scanCache[id]) end
  local v, names, why = Judge(id, name)
  if scanCache then scanCache[id] = { v, names, why } end
  return v, names, why
end
local function ItemVerdict(id) return (Verdict(id)) end
KQG.ItemVerdict = ItemVerdict
KQG.ItemJudge = Verdict

-- ===== 슬롯 표시 =====
local overlays = {}
local function Overlay(btn)
  local o = rawget(btn, "KQGRed")
  if o then return o end
  o = btn:CreateTexture(nil, "OVERLAY", nil, 7)
  o:SetAllPoints(btn)
  if o.SetColorTexture then o:SetColorTexture(0.85, 0.05, 0.05, 0.50) else o:SetTexture(0.85, 0.05, 0.05, 0.50) end
  o:Hide()
  btn.KQGRed = o
  overlays[#overlays + 1] = o
  return o
end

local stat = { frames = 0, combined = 0, bank = 0, dui = 0, buttons = 0, marked = 0 }

-- (0.35.0) DaylightUI_Bags 가방·은행 창: 공개 API(DaylightUI.API 1.3 이상)의 "bagslot" 칸에 그립니다.
--   API.Frames("bagslot")는 칸과 "가방:칸" 이름을 돌려주고(다른 캐릭터 가방 미리보기는 빠짐),
--   API.Attach(칸)는 그 칸 위에 얹는 KQuestGuide 전용 틀을 돌려줍니다. DaylightUI 칸은 직접 건드리지 않습니다.
local function DUIApi()
  local dui = rawget(_G, "DaylightUI")
  local api = type(dui) == "table" and dui.API
  if type(api) ~= "table" or api.major ~= 1 then return nil end
  if type(api.Frames) ~= "function" or type(api.Attach) ~= "function" then return nil end
  return api
end
local function DUISlot(unit)
  if type(unit) ~= "string" then return nil end
  local b, s = string.match(unit, "^(%-?%d+):(%d+)$")
  if not b then return nil end
  return tonumber(b), tonumber(s)
end
local function AnyDUIShown()
  local api = DUIApi()
  if not api then return false end
  for frame in api.Frames("bagslot") do
    if type(frame) == "table" and frame.IsVisible and frame:IsVisible() then return true end
  end
  return false
end

local function Apply(btn, bag, slot)
  if not (btn and bag and slot) then return end
  stat.buttons = stat.buttons + 1
  local on = db().itemMark ~= false
  local v
  if on then v = ItemVerdict(SlotItemID(bag, slot)) end
  if v == "unused" then
    Overlay(btn):Show()
    stat.marked = stat.marked + 1
  elseif rawget(btn, "KQGRed") then
    rawget(btn, "KQGRed"):Hide()
  end
end

local function ScanFrames()
  stat = { frames = 0, combined = 0, bank = 0, dui = 0, buttons = 0, marked = 0 }
  scanCache = {}
  -- DaylightUI_Bags 칸 (보이는 칸만)
  local api = DUIApi()
  if api then
    for frame, unit in api.Frames("bagslot") do
      if type(frame) == "table" and frame.IsVisible and frame:IsVisible() then
        local bag, slot = DUISlot(unit)
        local holder = bag and api.Attach(frame)
        if holder then
          stat.dui = stat.dui + 1
          Apply(holder, bag, slot)
        end
      end
    end
  end
  -- 가방 창 (이전 방식: ContainerFrameNItemM, 새 방식: EnumerateValidItems)
  local list = {}
  for i = 1, 13 do list[#list + 1] = _G["ContainerFrame" .. i] end
  list[#list + 1] = _G["ContainerFrameCombinedBags"]
  for i, f in ipairs(list) do
    if f and f.IsShown and f:IsShown() then
      local done = false
      if f.EnumerateValidItems then
        local ok = pcall(function()
          for _, b in f:EnumerateValidItems() do
            local bag = b.GetBagID and b:GetBagID() or (b:GetParent() and b:GetParent():GetID())
            Apply(b, bag, b:GetID())
          end
        end)
        done = ok
        if f == _G["ContainerFrameCombinedBags"] then stat.combined = stat.combined + 1 else stat.frames = stat.frames + 1 end
      end
      if not done and i <= 13 then
        stat.frames = stat.frames + 1
        local bag = f:GetID()
        local size = f.size
        if not size and C_Container and C_Container.GetContainerNumSlots then size = C_Container.GetContainerNumSlots(bag) end
        for j = 1, (size or 0) do
          local b = _G["ContainerFrame" .. i .. "Item" .. j]
          if b then Apply(b, bag, b:GetID()) end
        end
      end
    end
  end
  -- 은행 (창고) 기본 슬롯
  local bf = _G["BankFrame"]
  if bf and bf.IsShown and bf:IsShown() then
    local bankBag = BANK_CONTAINER or -1
    for j = 1, 28 do
      local b = _G["BankFrameItem" .. j]
      if b then stat.bank = stat.bank + 1 Apply(b, bankBag, b:GetID()) end
    end
  end
  scanCache = nil
end

local function AnyShown()
  for i = 1, 13 do
    local f = _G["ContainerFrame" .. i]
    if f and f.IsShown and f:IsShown() then return true end
  end
  local c = _G["ContainerFrameCombinedBags"]
  if c and c.IsShown and c:IsShown() then return true end
  local bf = _G["BankFrame"]
  if bf and bf.IsShown and bf:IsShown() then return true end
  return AnyDUIShown()
end

local ticker = CreateFrame("Frame")
local acc = 0
local lastErr
ticker:SetScript("OnUpdate", function(_, el)
  el = el or arg1 or 0
  acc = acc + el
  if acc < 0.4 then return end
  acc = 0
  if not db() then return end
  if InCombatLockdown and InCombatLockdown() then return end
  if db().itemMark == false then
    for _, o in ipairs(overlays) do o:Hide() end
    return
  end
  if not AnyShown() then return end
  local ok, err = pcall(ScanFrames)
  if not ok then scanCache = nil end
  if not ok and err ~= lastErr then
    lastErr = err
    if KQG.ReportBug then KQG.ReportBug("퀘스트아이템", err, "") end
  end
end)

-- ===== 툴팁 =====
local function Join(list, n)
  local out = {}
  for i = 1, math.min(n, #list) do out[#out + 1] = list[i] end
  local s = table.concat(out, ", ")
  if #list > n then s = s .. " 외 " .. (#list - n) .. "개" end
  return s
end

local WHY = {
  done = "끝낸 퀘스트: ",
  never = "받을 수 없는 퀘스트: ",
  reward = "보상으로 받은 퀘스트(끝냄): ",
}

-- 툴팁 줄 (시험에서도 씀): { { 글, 회색이면 true }, ... }
local function TipLines(id)
  local v, names, why = Verdict(id)
  if v == "unused" then
    local out = { { "|cffff5050[퀘스트 길잡이] 지금 쓰이는 퀘스트가 없습니다|r" } }
    if why == "nodata" then
      out[2] = { "|cffaaaaaa연결된 퀘스트 자료가 없습니다 (Questie)|r" }
    elseif names and #names > 0 then
      out[2] = { "|cffaaaaaa" .. (WHY[why] or "") .. Join(names, 3) .. "|r" }
    end
    return out
  elseif v == "later" then
    return { { "|cffaaaaaa[퀘스트 길잡이] 아직 안 한 퀘스트에 쓰임: " .. Join(names, 3) .. "|r" } }
  elseif v == "gray" then
    return { { "|cffaaaaaa[퀘스트 길잡이] 회색(저레벨) 퀘스트에만 쓰임: " .. Join(names, 3) .. "|r" } }
  end
  return nil
end
KQG.ItemTipLines = TipLines

local function TipFor(tt, link)
  if not link or not db() or db().itemMark == false then return end
  local id = tonumber(string.match(link, "item:(%d+)"))
  local lines = id and TipLines(id)
  if not lines then return end
  for _, l in ipairs(lines) do tt:AddLine(l[1], 1, 1, 1, true) end
  tt:Show()
end

local hooked = false
if GameTooltip and GameTooltip.HookScript then
  pcall(function()
    GameTooltip:HookScript("OnTooltipSetItem", function(tt)
      if tt.KQGTip then return end
      local _, link = tt:GetItem()
      if link then
        tt.KQGTip = true
        pcall(TipFor, tt, link)
      end
    end)
    GameTooltip:HookScript("OnTooltipCleared", function(tt) tt.KQGTip = nil end)
    hooked = true
  end)
end
if not hooked and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, function(tt, data)
    if tt ~= GameTooltip then return end
    local link = data and data.hyperlink
    if not link and tt.GetItem then local _, l = tt:GetItem() link = l end
    pcall(TipFor, tt, link)
  end)
end

-- ===== 명령 =====
local VNAME = { unused = "빨강", inuse = "쓰는 중", later = "나중에 씀", gray = "회색 퀘스트" }
KQG.ItemCommand = function(arg)
  arg = arg or ""
  local d = db()
  if arg == "debug" then
    ScanFrames()
    local nData = 0
    for _ in pairs(ITEMS) do nData = nData + 1 end
    Print("퀘스트 아이템 표시 " .. (d.itemMark == false and "꺼짐" or "켜짐")
      .. " / 가방창 " .. stat.frames .. " 통합가방 " .. stat.combined .. " 은행칸 " .. stat.bank
      .. " DaylightUI칸 " .. stat.dui .. (DUIApi() and "" or "(DaylightUI 없음)")
      .. " / 슬롯 " .. stat.buttons .. " 빨간표시 " .. stat.marked
      .. " / 이름색인 " .. (function() local n = 0 for _ in pairs(nameIndex or (BuildIndex() or nameIndex)) do n = n + 1 end return n end)()
      .. " / 아이템 자료 " .. nData)
    local shown = 0
    for bag = 0, 11 do
      local size = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag) or (GetContainerNumSlots and GetContainerNumSlots(bag)) or 0
      for slot = 1, size do
        local id = SlotItemID(bag, slot)
        if id and IsTarget(id) then
          local v, names, why = Verdict(id)
          shown = shown + 1
          if shown <= 15 then
            Print("  [" .. bag .. ":" .. slot .. "] " .. tostring(ItemName(id)) .. " (" .. id .. ") → "
              .. tostring(v and VNAME[v] or "판단 안 함")
              .. (why and (" · " .. why) or "")
              .. (names and #names > 0 and (" (" .. Join(names, 2) .. ")") or ""))
          end
        end
      end
    end
    if shown == 0 then Print("  가방(열린 칸 기준)에서 퀘스트 분류 아이템을 못 찾았습니다.") end
  else
    d.itemMark = (d.itemMark == false)
    Print("쓰지 않는 퀘스트 아이템 표시 " .. (d.itemMark == false and "꺼짐" or "켜짐"))
    if d.itemMark == false then for _, o in ipairs(overlays) do o:Hide() end end
  end
end
