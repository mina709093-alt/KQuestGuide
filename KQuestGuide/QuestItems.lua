-- 쓰지 않는 퀘스트 아이템 표시
-- 가방/은행 슬롯의 퀘스트 아이템 중 "확실히 더 이상 필요 없는 것"에만 빨간 표시를 얹습니다.
-- 판정 기준 (보수적):
--   * 아이템 분류가 '퀘스트'이고, 수집 퀘스트 데이터(Objectives)에 그 아이템 이름이 있어야 합니다.
--   * 그 아이템을 쓰는 퀘스트(내 종족/직업이 할 수 있는 것) 중 하나라도 지금 퀘스트 로그에 있으면 표시하지 않습니다.
--   * 쓰는 퀘스트가 전부 이미 완료된 경우에만 빨갛게 표시합니다.
--   * 데이터에 없는 아이템(퀘스트 시작 아이템, 문서, 열쇠 등)과, 아직 안 한 퀘스트에 쓰이는 아이템은 표시하지 않습니다.
local KQG = KQG
if not KQG then return end

local Q, F = KQG.Q, KQG.F
local OBJ = KQG_OBJ or {}

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

local function Relevant(qid)
  local r = Q[qid]
  if not r then return false end
  if KQG.Bit then
    if not KQG.Bit(r[F.RACES], KQG.RaceBit()) then return false end
    if not KQG.Bit(r[F.CLASSES], KQG.ClassBit()) then return false end
  end
  return true
end

local function QName(qid)
  local r = Q[qid]
  return r and r[F.NAME] or ("퀘스트 " .. tostring(qid))
end

-- 반환: verdict("unused" | "inuse" | "later" | nil), 관련 퀘스트 이름 목록
local function Verdict(name)
  if not name then return nil end
  if not nameIndex then BuildIndex() end
  local qs = nameIndex[name]
  if not qs then return nil end
  local log = KQG.LogSet and KQG.LogSet() or {}
  local relevant, doneNames, laterNames = 0, {}, {}
  for _, qid in ipairs(qs) do
    if Relevant(qid) then
      relevant = relevant + 1
      if log[qid] then return "inuse", { QName(qid) } end
      if KQG.IsDone(qid) then doneNames[#doneNames + 1] = QName(qid) else laterNames[#laterNames + 1] = QName(qid) end
    end
  end
  if relevant == 0 then return nil end
  if #laterNames > 0 then return "later", laterNames end
  return "unused", doneNames
end

-- 퀘스트 분류 아이템인지 (classID 12)
local function IsQuestClass(id)
  local _, _, _, _, _, classID = InfoInstant(id)
  return classID == 12
end

local function ItemVerdict(id)
  if not id or not IsQuestClass(id) then return nil end
  return Verdict(ItemName(id))
end
KQG.ItemVerdict = ItemVerdict

-- ===== 슬롯 표시 =====
local overlays = {}
local function Overlay(btn)
  local o = btn.KQGRed
  if o then return o end
  o = btn:CreateTexture(nil, "OVERLAY", nil, 7)
  o:SetAllPoints(btn)
  if o.SetColorTexture then o:SetColorTexture(0.85, 0.05, 0.05, 0.50) else o:SetTexture(0.85, 0.05, 0.05, 0.50) end
  o:Hide()
  btn.KQGRed = o
  overlays[#overlays + 1] = o
  return o
end

local stat = { frames = 0, combined = 0, bank = 0, buttons = 0, marked = 0 }

local function Apply(btn, bag, slot)
  if not (btn and bag and slot) then return end
  stat.buttons = stat.buttons + 1
  local on = db().itemMark ~= false
  local v
  if on then v = ItemVerdict(SlotItemID(bag, slot)) end
  if v == "unused" then
    Overlay(btn):Show()
    stat.marked = stat.marked + 1
  elseif btn.KQGRed then
    btn.KQGRed:Hide()
  end
end

local function ScanFrames()
  stat = { frames = 0, combined = 0, bank = 0, buttons = 0, marked = 0 }
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
end

local function AnyShown()
  for i = 1, 13 do
    local f = _G["ContainerFrame" .. i]
    if f and f.IsShown and f:IsShown() then return true end
  end
  local c = _G["ContainerFrameCombinedBags"]
  if c and c.IsShown and c:IsShown() then return true end
  local bf = _G["BankFrame"]
  return bf and bf.IsShown and bf:IsShown() or false
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

local function TipFor(tt, link)
  if not link or not db() or db().itemMark == false then return end
  local id = tonumber(string.match(link, "item:(%d+)"))
  if not id or not IsQuestClass(id) then return end
  local v, names = Verdict(ItemName(id))
  if v == "unused" then
    tt:AddLine("|cffff5050[퀘스트 길잡이] 지금 쓰이는 퀘스트가 없습니다|r", 1, 1, 1, true)
    tt:AddLine("|cffaaaaaa끝낸 퀘스트: " .. Join(names, 3) .. "|r", 1, 1, 1, true)
    tt:Show()
  elseif v == "later" then
    tt:AddLine("|cffaaaaaa[퀘스트 길잡이] 아직 안 한 퀘스트에 쓰임: " .. Join(names, 3) .. "|r", 1, 1, 1, true)
    tt:Show()
  end
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
KQG.ItemCommand = function(arg)
  arg = arg or ""
  local d = db()
  if arg == "debug" then
    ScanFrames()
    Print("퀘스트 아이템 표시 " .. (d.itemMark == false and "꺼짐" or "켜짐")
      .. " / 가방창 " .. stat.frames .. " 통합가방 " .. stat.combined .. " 은행칸 " .. stat.bank
      .. " / 슬롯 " .. stat.buttons .. " 빨간표시 " .. stat.marked
      .. " / 이름색인 " .. (function() local n = 0 for _ in pairs(nameIndex or (BuildIndex() or nameIndex)) do n = n + 1 end return n end)())
    local shown = 0
    for bag = 0, 11 do
      local size = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag) or (GetContainerNumSlots and GetContainerNumSlots(bag)) or 0
      for slot = 1, size do
        local id = SlotItemID(bag, slot)
        if id and IsQuestClass(id) then
          local v, names = Verdict(ItemName(id))
          shown = shown + 1
          if shown <= 12 then
            Print("  [" .. bag .. ":" .. slot .. "] " .. tostring(ItemName(id)) .. " → " .. tostring(v or "데이터 없음")
              .. (names and (" (" .. Join(names, 2) .. ")") or ""))
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
