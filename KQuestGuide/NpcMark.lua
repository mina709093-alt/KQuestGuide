-- 지금 수락할 NPC 표시
-- 안내 목록 앞쪽(8단계)의 "수락" 단계에 있는 NPC를 번호로 찾아 표시합니다.
--   1) NPC 툴팁에 "▶ 지금 수락할 NPC: 「퀘스트명」" 줄을 붙입니다.
--   2) NPC를 대상으로 잡으면 채팅창에 한 줄 알립니다 (같은 NPC는 90초에 한 번).
--   3) 대상으로 잡고 가까이 섰는데 대화창이 안 열리면(줄 퀘스트가 없음) 건너뛸지 물어봅니다.
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

-- ===== 퀘스트를 주지 않는 NPC 감지 =====
-- 수락할 NPC를 대상으로 잡고 가까이(약 10미터) 섰는데 6초 동안 대화창이 열리지 않으면
-- "이 NPC는 지금 그 퀘스트를 주지 않는 것 같아요. 건너뛸까요?"를 묻습니다. (NPC마다 한 번만)
-- 대화창이 열리는 경우는 기존 기능(대화창에 퀘스트가 없으면 자동 건너뛰기)이 처리합니다.
local watch            -- { id, name, quests, since }
local asked = {}       -- NPC 번호 -> 이미 물어봄
local DIALOG_EVENTS = { "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "MERCHANT_SHOW", "TRAINER_SHOW", "BANKFRAME_OPENED", "TAXIMAP_OPENED" }

local function WantedQuests(id)
  local ids = {}
  local steps = KQG.Steps and KQG.Steps() or {}
  for i = 1, math.min(#steps, 8) do
    local g = steps[i]
    if g and g.kind == "accept" and g.loc and g.loc[1] == "n" and g.loc[2] == id then
      for _, qid in ipairs(g.quests or {}) do ids[#ids + 1] = qid end
    end
  end
  return ids
end

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["KQG_NPC_NO_QUEST"] = {
  text = "%s",
  button1 = "건너뛰기",
  button2 = "아니요",
  OnAccept = function(_, data)
    if data and KQG.SkipQuests then KQG.SkipQuests(data) end
  end,
  timeout = 30,
  whileDead = false,
  hideOnEscape = true,
  preferredIndex = 3,
}

local function InRange()
  if not CheckInteractDistance then return false end
  local ok, r = pcall(CheckInteractDistance, "target", 3)
  return ok and r and true or false
end

local wf = CreateFrame("Frame")
for _, e in ipairs(DIALOG_EVENTS) do pcall(wf.RegisterEvent, wf, e) end
wf:SetScript("OnEvent", function() watch = nil end) -- 대화창이 열렸으면 감지 끝
local wacc = 0
wf:SetScript("OnUpdate", function(_, el)
  wacc = wacc + el
  if wacc < 0.5 then return end
  wacc = 0
  if not watch then return end
  if InCombatLockdown() or not On() then watch = nil return end
  local _, id = Match("target")
  if id ~= watch.id then watch = nil return end
  if not InRange() then watch.since = nil return end
  watch.since = watch.since or GetTime()
  if GetTime() - watch.since >= 6 then
    local w = watch
    watch = nil
    asked[w.id] = true
    local qs = WantedQuests(w.id)
    if #qs == 0 then return end
    local npc = UnitName("target") or "이 NPC"
    if issecretvalue and issecretvalue(npc) then npc = "이 NPC" end
    StaticPopup_Show("KQG_NPC_NO_QUEST", ("%s에게 다가갔지만 대화창이 열리지 않았어요.\n「%s」를 지금 받을 수 없는 것 같아요. 이 퀘스트를 건너뛸까요?\n(되돌리기: /kqg back)"):format(npc, w.label), nil, qs)
  end
end)

KQG.NpcRefresh = function() end -- 예전 이름표 표시는 없앰 (호환용)

local f = CreateFrame("Frame")
pcall(f.RegisterEvent, f, "PLAYER_TARGET_CHANGED")
f:SetScript("OnEvent", function(_, event)
  local ok, err = pcall(function()
    if not On() then return end
    local names, id = Match("target")
    if not names then return end
    stat.target = stat.target + 1
    if not asked[id] then watch = { id = id, label = Label(names) } end
    local now = GetTime()
    if told[id] and now - told[id] < 90 then return end
    told[id] = now
    Print("이 NPC에게 퀘스트를 수락하세요: 「" .. Label(names) .. "」")
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
    Print("대상 일치 " .. stat.target .. "회 / 마지막 GUID " .. stat.lastGuid .. " 번호 " .. stat.lastId)
    if stat.err then Print("오류: " .. stat.err) end
    return
  end
  d.npcMark = not On()
  Print("수락 NPC 표시 " .. (On() and "켜짐" or "꺼짐"))
end
