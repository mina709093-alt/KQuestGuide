-- 추천 퀘스트 관리 (0.30.0): 레벨링에 꼭 필요하지는 않지만 오래 도움이 되는 퀘스트를 모아 보여 주는 창 KQGRecommendFrame
--   * 목록은 RecommendData.lua(직접 고른 표)만 씁니다. 데이터만 추가하면 창에 나옵니다.
--   * 받을 수 있는지: 각 단계의 퀘스트 종족·직업 조건(QuestieDB 사실값, D.quests)으로 판정합니다.
--     한 단계라도 내가 받을 수 있는 퀘스트가 없으면 그 항목은 보이지 않습니다(진영 전용 퀘스트가 자동으로 빠짐).
--     보상을 쓸 수 있는 직업 제한(classes, 예: 사냥꾼 화살통)도 봅니다.
--   * 진행 상태: 퀘스트 로그(진행 중·완료 가능)와 C_QuestLog.IsQuestFlaggedCompleted(없으면 IsQuestFlaggedCompleted).
--     완료 여부를 물을 수 없거나 비밀값이면 추측하지 않고 "확인 불가"로 둡니다.
--     반복 퀘스트(완료 기록이 남지 않음)는 보상 아이템을 가지고 있으면 "보유"로 표시합니다.
--   * 이름·NPC·위치: KQuestGuide 자료(한글) → 게임이 아는 제목 → 설치된 Questie 자료(읽기만, "(Questie)" 표시) 순서.
--   * 길 안내: 진행 중이면 KQG.RouteQuest(목표·제출), 아직 안 받았으면 시작 NPC·물건으로 KQG.SetForced(kind "accept").
-- 명령: /kqg 추천 (창 열기/닫기). 저장: KQGDB.recommend = { tab, showDone, sel, pos }
local KQG = KQG
if not KQG then return end

local D = KQG.RecommendData
local Q, F = KQG.Q, KQG.F
local function Print(m) if KQG.Print then KQG.Print(m) end end
local function db()
  local d = KQG.DB and KQG.DB()
  if type(d) ~= "table" then return nil end
  if type(d.recommend) ~= "table" then d.recommend = {} end
  local r = d.recommend
  if r.tab == nil then r.tab = "all" end
  if r.showDone == nil then r.showDone = false end
  return r
end

local function Secret(v)
  if issecretvalue then
    local ok, r = pcall(issecretvalue, v)
    return ok and r
  end
  return false
end

---------------------------------------------------------------------------
-- 판정 (창 없이도 쓰는 부분. 오프라인 시험에서 직접 부름)
---------------------------------------------------------------------------
local function MyClassFile()
  local ok, _, file = pcall(UnitClass, "player")
  if ok and type(file) == "string" then return file end
  return nil
end

-- 이 퀘스트를 내 종족·직업이 받을 수 있는지 (D.quests의 Questie 마스크. 자료가 없으면 KQG 자료, 그것도 없으면 받을 수 있다고 봄)
local function QuestOK(id)
  local qi = D and D.quests and D.quests[id]
  local races, classes
  if qi then
    races, classes = qi[4], qi[5]
  elseif Q and Q[id] then
    races, classes = Q[id][F.RACES], Q[id][F.CLASSES]
  end
  if not KQG.Bit(races, KQG.RaceBit()) then return false end
  if not KQG.Bit(classes, KQG.ClassBit()) then return false end
  return true
end

-- 한 단계(번호 또는 { 번호, 번호 })에서 내가 받을 수 있는 퀘스트 목록
local function StepPick(step)
  local out = {}
  if type(step) == "table" then
    for _, id in ipairs(step) do if QuestOK(id) then out[#out + 1] = id end end
  elseif type(step) == "number" and QuestOK(step) then
    out[1] = step
  end
  return out
end

-- 이 항목을 지금 캐릭터에게 보여 줄지
local function EntryOK(e)
  if type(e) ~= "table" or type(e.steps) ~= "table" or #e.steps == 0 then return false end
  if e.classes then
    local mine, hit = MyClassFile(), false
    for _, c in ipairs(e.classes) do if c == mine then hit = true end end
    if not hit then return false end
  end
  for _, s in ipairs(e.steps) do
    if #StepPick(s) == 0 then return false end
  end
  return true
end

-- 완료 기록: true / false / nil(물을 수 없음)
local function Completed(id)
  local fn = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or rawget(_G, "IsQuestFlaggedCompleted")
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, id)
  if not ok or Secret(v) then return nil end
  return v and true or false
end

-- 퀘스트 하나의 상태: "done" "complete"(제출 가능) "accepted"(진행 중) "none"(미수락) "unknown"(확인 불가)
local function QState(id)
  if KQG.InLog and KQG.InLog(id) then
    return (KQG.LogComplete and KQG.LogComplete(id)) and "complete" or "accepted"
  end
  local c = Completed(id)
  if c == nil then return "unknown" end
  return c and "done" or "none"
end

-- 한 단계의 상태 (내가 받을 수 있는 퀘스트 중 하나라도 끝냈으면 끝)
local STEP_RANK = { done = 5, complete = 4, accepted = 3, none = 2, unknown = 1 }
local function StepState(step)
  local best, bestId = nil, nil
  local list = StepPick(step)
  local anyUnknown = false
  for _, id in ipairs(list) do
    local s = QState(id)
    if s == "unknown" then anyUnknown = true end
    if not best or STEP_RANK[s] > STEP_RANK[best] then best, bestId = s, id end
  end
  -- 끝낸 것이 없고, 어느 하나라도 확인 불가이면 단계도 확인 불가
  if best == "none" and anyUnknown then best = "unknown" end
  return best or "unknown", bestId or list[1]
end

local function HasItem(item)
  local fn = (C_Item and C_Item.GetItemCount) or rawget(_G, "GetItemCount")
  if type(fn) ~= "function" then return nil end
  local ok, n = pcall(fn, item, true)
  if not ok or Secret(n) or type(n) ~= "number" then return nil end
  return n > 0
end

-- 내 진영에 해당하는 보상만 (side가 없으면 공통)
local function MyRewards(e)
  local out, fac = {}, KQG.Faction and KQG.Faction()
  for _, r in ipairs(e.rewards or {}) do
    if not r.side or r.side == fac then out[#out + 1] = r end
  end
  return out
end

-- 이 항목 보상 중 가장 큰 가방 칸 수 (가방이 아니면 0)
local function MaxSlots(e)
  local m = 0
  for _, r in ipairs(MyRewards(e)) do
    local s = r.slots or (D.items[r.item] and D.items[r.item][2]) or 0
    if s > m then m = s end
  end
  return m
end

-- 항목 상태: state("done" "progress" "none" "unknown" "owned"), 끝낸 단계 수, 전체 단계 수, 지금 단계 번호
local function EntryState(e)
  local n = #e.steps
  if e.repeatable then
    for _, r in ipairs(MyRewards(e)) do
      if HasItem(r.item) then return "owned", n, n, n end
    end
    local s = StepState(e.steps[1])
    if s == "complete" or s == "accepted" then return "progress", 0, n, 1 end
    return "unknown", 0, n, 1
  end
  local doneN, cur, anyLog, anyUnknown = 0, nil, false, false
  for i, step in ipairs(e.steps) do
    local s = StepState(step)
    if s == "done" then
      doneN = doneN + 1
    else
      if not cur then cur = i end
      if s == "complete" or s == "accepted" then anyLog = true end
      if s == "unknown" then anyUnknown = true end
    end
  end
  if StepState(e.steps[n]) == "done" then return "done", n, n, n end
  if anyLog or doneN > 0 then return "progress", doneN, n, cur or n end
  if anyUnknown then return "unknown", doneN, n, cur or 1 end
  return "none", doneN, n, cur or 1
end

-- 탭과 완료 보기 설정으로 목록 만들기 (보이는 순서 = 자료 순서)
local function BuildList(tab, showDone)
  local out = {}
  for _, e in ipairs(D and D.list or {}) do
    if (tab == "all" or e.cat == tab) and EntryOK(e) then
      local st = EntryState(e)
      if showDone or (st ~= "done" and st ~= "owned") then out[#out + 1] = e end
    end
  end
  return out
end

-- 탭마다 보이는 항목 수 (완료 포함 전체, 완료)
local function CountTab(tab)
  local all, done = 0, 0
  for _, e in ipairs(D and D.list or {}) do
    if (tab == "all" or e.cat == tab) and EntryOK(e) then
      all = all + 1
      local st = EntryState(e)
      if st == "done" or st == "owned" then done = done + 1 end
    end
  end
  return all, done
end

---------------------------------------------------------------------------
-- 이름·위치 (KQG 자료 → 게임 → Questie)
---------------------------------------------------------------------------
local function QDB()
  local QL = rawget(_G, "QuestieLoader")
  local qs = rawget(_G, "Questie")
  if type(QL) ~= "table" or type(QL.ImportModule) ~= "function" then return nil end
  if type(qs) ~= "table" or qs.started ~= true then return nil end
  local ok, mod = pcall(QL.ImportModule, QL, "QuestieDB")
  if ok and type(mod) == "table" and type(mod.QueryQuestSingle) == "function" then return mod end
  return nil
end

local function QGet(fn, id, field)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, id, field)
  if ok then return v end
  return nil
end

local function AreaMap(area)
  local m = KQG.UiMapOf and KQG.UiMapOf(area)
  if m then return m end
  local QL = rawget(_G, "QuestieLoader")
  if type(QL) ~= "table" or type(QL.ImportModule) ~= "function" then return nil end
  local ok, Z = pcall(QL.ImportModule, QL, "ZoneDB")
  if not ok or type(Z) ~= "table" or type(Z.GetUiMapIdByAreaId) ~= "function" then return nil end
  local ok2, mm = pcall(Z.GetUiMapIdByAreaId, Z, area)
  if ok2 and type(mm) == "number" and mm > 0 then return mm end
  return nil
end

local function ZoneText(area)
  if type(area) ~= "number" or area <= 0 then return nil end
  local map = AreaMap(area)
  if map and KQG.MapName then return KQG.MapName(map) end
  if C_Map and C_Map.GetAreaInfo then
    local ok, n = pcall(C_Map.GetAreaInfo, area)
    if ok and type(n) == "string" and n ~= "" and not Secret(n) then return n end
  end
  return nil
end

local function GameTitle(id)
  if C_QuestLog and C_QuestLog.GetTitleForQuestID then
    local ok, t = pcall(C_QuestLog.GetTitleForQuestID, id)
    if ok and type(t) == "string" and t ~= "" and not Secret(t) then return t end
  end
  return nil
end

-- 퀘스트 이름과 출처("kqg" "game" "data")
local function QTitle(id)
  local r = Q and Q[id]
  if r and r[F.NAME] then return r[F.NAME], "kqg" end
  local g = GameTitle(id)
  if g then return g, "game" end
  local qi = D.quests[id]
  if qi and qi[1] then return qi[1], "data" end
  return "퀘스트 #" .. id, "data"
end

local function ItemName(item)
  local fn = (C_Item and C_Item.GetItemNameByID) or rawget(_G, "GetItemInfo")
  if type(fn) == "function" then
    local ok, n = pcall(fn, item)
    if ok and type(n) == "string" and n ~= "" and not Secret(n) then return n end
  end
  local it = D.items[item]
  return (it and it[1]) or ("아이템 #" .. item)
end

-- Questie 시작/완료 대상({ {npc...}, {object...}, {item...} })의 첫 위치: { kind, id, area, x, y, name }
local function QuestieUnit(list)
  local qdb = QDB()
  if not qdb or type(list) ~= "table" then return nil end
  local kinds = { { "n", qdb.QueryNPCSingle }, { "o", qdb.QueryObjectSingle } }
  for k, kind in ipairs(kinds) do
    for _, uid in ipairs(type(list[k]) == "table" and list[k] or {}) do
      if type(uid) == "number" then
        local nm = QGet(kind[2], uid, "name")
        local sp = QGet(kind[2], uid, "spawns")
        if type(sp) == "table" then
          for area, pts in pairs(sp) do
            local p = type(pts) == "table" and pts[1]
            if type(area) == "number" and type(p) == "table" and type(p[1]) == "number" and p[1] > 0 then
              return { kind[1], uid, area, p[1], p[2], type(nm) == "string" and nm or "?" }
            end
          end
        end
        if type(nm) == "string" then return { kind[1], uid, nil, nil, nil, nm } end
      end
    end
  end
  local items = type(list[3]) == "table" and list[3] or {}
  if type(items[1]) == "number" then return { "i", items[1], nil, nil, nil, ItemName(items[1]) } end
  return nil
end

-- 시작(which = "start") 또는 완료("end") 위치. 두 번째 값 = "(Questie)" 출처 표시 여부
local function Spot(id, which)
  local r = Q and Q[id]
  local s = r and r[which == "start" and F.START or F.END]
  if type(s) == "table" then return s, false end
  local qdb = QDB()
  if qdb then
    local u = QuestieUnit(QGet(qdb.QueryQuestSingle, id, which == "start" and "startedBy" or "finishedBy"))
    if u then return u, true end
  end
  return nil, false
end

local function SpotText(s, fromQ)
  if not s then return "정보 없음" end
  local name = tostring(s[6] or "?")
  if s[1] == "i" then return "아이템「" .. name .. "」" .. (fromQ and " (Questie)" or "") end
  local t = name
  local z = ZoneText(s[3])
  if z then t = t .. " · " .. z end
  if type(s[4]) == "number" and s[4] >= 0 and type(s[5]) == "number" then t = t .. string.format(" (%.0f, %.0f)", s[4], s[5]) end
  if fromQ then t = t .. " (Questie)" end
  return t
end

local function GoalText(id)
  local r = Q and Q[id]
  if r and type(r[F.TEXT]) == "string" and r[F.TEXT] ~= "" then return r[F.TEXT], false end
  local qdb = QDB()
  local t = qdb and QGet(qdb.QueryQuestSingle, id, "objectivesText")
  if type(t) == "table" and type(t[1]) == "string" and t[1] ~= "" then return t[1], true end
  return nil, false
end

-- 지금 할 단계의 퀘스트로 길 안내
local function GuideTo(id)
  if type(id) ~= "number" then return false end
  if KQG.InLog and KQG.InLog(id) then
    if KQG.RouteQuest then return KQG.RouteQuest(id) end
    return false
  end
  local s, fromQ = Spot(id, "start")
  if not s or s[1] == "i" then
    Print((s and "아이템으로 시작하는 퀘스트입니다: " or "시작 위치 정보가 없습니다: ") .. (QTitle(id)))
    return false
  end
  local map = AreaMap(s[3])
  if not map or type(s[4]) ~= "number" or s[4] < 0 or not KQG.SetForced then
    Print("시작 위치 정보가 없습니다: " .. (QTitle(id)))
    return false
  end
  local name = QTitle(id)
  local loc = { s[1], s[2], s[3], s[4], s[5], tostring(s[6] or "?") .. (fromQ and " (Questie)" or ""), s[7] }
  KQG.SetForced({ kind = "accept", key = "rcm" .. id, loc = loc, map = map, quests = { id }, label = "[추천 퀘스트] " .. name })
  Print("안내 시작: " .. SpotText(s, fromQ) .. " - " .. name)
  return true
end

---------------------------------------------------------------------------
-- 창
---------------------------------------------------------------------------
local FONT = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Regular.ttf"
local FONT_B = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Bold.ttf"
local C_TEXT = { 0.93, 0.94, 0.96 }
local C_MUTED = { 0.55, 0.60, 0.63 }
local C_ACCENT = { 0.063, 0.816, 0.627 }
local C_SEL = { 0.045, 0.32, 0.26 }
local C_BG = { 0.035, 0.055, 0.065 }
local C_DONE = { 0.18, 0.64, 0.42 }
local C_GOLD = { 1.0, 0.82, 0.0 }
local W, H, LEFT_W, ROW_H, LROWS, SROW_H = 820, 560, 360, 36, 12, 20
local SRC_LINE = "목록: 직접 고름 · 조건·연계: QuestieDB · 가방 칸 수: 게임 테이블 · 위치: KQuestGuide 자료, 없으면 Questie"

local function SetF(fs, size, bold)
  if not pcall(fs.SetFont, fs, bold and FONT_B or FONT, size or 12, "") then fs:SetFontObject(GameFontHighlight) end
  return fs
end
local function Solid(tex, r, g, b, a)
  if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a or 1)
  else tex:SetTexture("Interface\\Buttons\\WHITE8X8") tex:SetVertexColor(r, g, b, a or 1) end
end
local function Hex(c) return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255)) end
local function Shown(obj, on) if on then obj:Show() else obj:Hide() end end

local STATE_TEXT = {
  done = Hex(C_DONE) .. "완료|r",
  owned = Hex(C_DONE) .. "보유|r",
  progress = "|cff4db8e0진행 중|r",
  none = Hex(C_TEXT) .. "미수락|r",
  unknown = Hex(C_MUTED) .. "확인 불가|r",
}
local QSTATE_TEXT = {
  done = Hex(C_DONE) .. "완료|r",
  complete = Hex(C_GOLD) .. "제출 가능|r",
  accepted = "|cff4db8e0진행 중|r",
  none = Hex(C_MUTED) .. "미수락|r",
  unknown = Hex(C_MUTED) .. "확인 불가|r",
}
-- 꼬리표 색 (열쇠·입장은 금색, 기간한정은 주황 등)
local TAG_COLOR = {
  ["열쇠"] = "|cffffd200", ["입장"] = "|cffffd200", ["지름길"] = "|cffffd200", ["공격대"] = "|cffff8c40",
  ["탈것"] = "|cff10d0a0", ["장비"] = "|cff4db8e0", ["기간한정"] = "|cffff8c40", ["평판 필요"] = "|cffc080ff",
  ["직업 전용"] = "|cffe0c070", ["재료 필요"] = "|cffb0b8bc", ["숨은 연계"] = "|cff10d0a0", ["Forever 신규"] = "|cff80c8ff",
}
local function TagText(e)
  local t = {}
  for _, g in ipairs(e.tags or {}) do t[#t + 1] = (TAG_COLOR[g] or "|cffb0b8bc") .. "[" .. g .. "]|r" end
  for _, r in ipairs(MyRewards(e)) do
    if r.check then t[#t + 1] = "|cffff6060[게임 확인 필요]|r" break end
  end
  return table.concat(t, " ")
end
local CAT_NAME = {}
for _, c in ipairs(D and D.cats or {}) do CAT_NAME[c[1]] = c[2] end

local function RewardShort(e)
  local best, bestSlots = nil, -1
  for _, r in ipairs(MyRewards(e)) do
    local s = r.slots or (D.items[r.item] and D.items[r.item][2]) or 0
    if s > bestSlots then best, bestSlots = r, s end
  end
  if not best then return "" end
  return ItemName(best.item) .. (bestSlots > 0 and (" " .. bestSlots .. "칸") or "")
end

local function EntryTitle(e)
  local last = StepPick(e.steps[#e.steps])
  return (QTitle(last[1] or 0))
end

local function EntryLevels(e)
  local first = StepPick(e.steps[1])[1]
  local last = StepPick(e.steps[#e.steps])[1]
  local qf, ql = first and D.quests[first], last and D.quests[last]
  local minL = qf and qf[3]
  local recL = ql and ql[2]
  if Q and first and Q[first] and Q[first][F.MIN] then minL = Q[first][F.MIN] end
  return minL, recL
end

local win, list, sel, offL, offS = nil, {}, nil, 0, 0
local stepRows = {}
local RenderRight

local function SelEntry()
  for _, e in ipairs(list) do if e.key == sel then return e end end
  return list[1]
end

local function RenderLeft()
  local r = db() or { tab = "all", showDone = false }
  list = BuildList(r.tab, r.showDone)
  local level = UnitLevel("player") or 1
  local maxOff = math.max(0, #list - LROWS)
  if offL > maxOff then offL = maxOff end
  if offL < 0 then offL = 0 end
  for i = 1, LROWS do
    local row = win.left[i]
    local e = list[i + offL]
    row.e = e
    if e then
      local st = EntryState(e)
      row.state:SetText(STATE_TEXT[st] or "")
      row.name:SetText(EntryTitle(e))
      local minL, recL = EntryLevels(e)
      row.lv:SetText(recL and recL > 0 and ("Lv " .. recL) or "")
      if minL and level < minL then row.lv:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
      else row.lv:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3]) end
      local sub = (CAT_NAME[e.cat] or "")
      local rw = RewardShort(e)
      if rw ~= "" then sub = sub .. " · " .. rw end
      row.sub:SetText(Hex(C_MUTED) .. sub .. "|r")
      row.tags:SetText(TagText(e))
      if st == "done" or st == "owned" then row.name:SetTextColor(0.55, 0.55, 0.55)
      else row.name:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3]) end
      if e.key == sel then Solid(row.bg, C_SEL[1], C_SEL[2], C_SEL[3], 1) else Solid(row.bg, 0, 0, 0, 0) end
      row:Show()
    else
      row:Hide()
    end
  end
  win.empty:SetText(#list == 0 and "이 분류에 지금 캐릭터가 할 수 있는 추천 퀘스트가 없습니다." or "")
  for _, b in ipairs(win.tabs) do
    local all, done = CountTab(b.cat)
    b.label:SetText(b.title .. " " .. (all - done))
    if b.cat == r.tab then Solid(b.bg, C_SEL[1], C_SEL[2], C_SEL[3], 1) else Solid(b.bg, 0.055, 0.085, 0.10, 1) end
  end
  win.bDone.label:SetText(r.showDone and "완료 숨기기" or "완료 보기")
  win.more:SetText(#list > LROWS and string.format("%d~%d / %d (마우스 휠)", offL + 1, math.min(#list, offL + LROWS), #list) or "")
end

-- 상세의 단계 줄 목록: { id, n, state, text, alt }
local function StepLines(e)
  local out = {}
  for i, step in ipairs(e.steps) do
    local s, id = StepState(step)
    local name = QTitle(id or 0)
    local sp, fromQ = Spot(id, "start")
    local qi = D.quests[id]
    local lv = qi and qi[3] and ("수락 " .. qi[3] .. " · ") or ""
    out[#out + 1] = { id = id, n = i, state = s, alt = #StepPick(step) > 1,
      text = string.format("%d. %s", i, name), sub = lv .. "시작: " .. SpotText(sp, fromQ) }
  end
  return out
end

RenderRight = function()
  local e = SelEntry()
  Shown(win.detail, e ~= nil)
  if not e then return end
  local st, dn, total, cur = EntryState(e)
  local minL, recL = EntryLevels(e)
  win.dTitle:SetText(EntryTitle(e))
  local info = { (CAT_NAME[e.cat] or "") }
  if recL and recL > 0 then info[#info + 1] = "추천 Lv " .. recL end
  if minL and minL > 0 then info[#info + 1] = "수락 Lv " .. minL end
  local firstZone = D.quests[StepPick(e.steps[1])[1] or 0]
  local z = firstZone and ZoneText(firstZone[6])
  if z then info[#info + 1] = "시작 지역: " .. z end
  info[#info + 1] = (STATE_TEXT[st] or "") .. (total > 1 and string.format(" (%d/%d 단계)", dn, total) or "")
  win.dInfo:SetText(table.concat(info, "  ·  "))
  local tags = TagText(e)
  win.dTags:SetText(tags ~= "" and tags or (Hex(C_MUTED) .. "꼬리표 없음|r"))
  win.dWhy:SetText(e.why or "")
  local rw = {}
  for _, r in ipairs(MyRewards(e)) do
    local s = r.slots or (D.items[r.item] and D.items[r.item][2])
    local t = "• " .. ItemName(r.item) .. (s and s > 0 and (" " .. Hex(C_GOLD) .. s .. "칸|r") or "")
    if r.choice then t = t .. Hex(C_MUTED) .. " (고르는 보상)|r" end
    if r.check then t = t .. " |cffff6060(Questie 연결 없음, 게임 확인 필요)|r" end
    local have = HasItem(r.item)
    if have then t = t .. " " .. Hex(C_DONE) .. "보유 중|r" end
    rw[#rw + 1] = t
  end
  win.dRew:SetText(#rw > 0 and ("보상\n" .. table.concat(rw, "\n")) or "")
  win.dNote:SetText(e.note and (Hex(C_MUTED) .. "주의: " .. e.note .. "|r") or "")
  -- 단계 목록 위치: 위 글 높이에 맞춰 내려 놓음
  local y = -8
  local function place(fs, gap)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", win.detail, "TOPLEFT", 0, y)
    local h = (fs:GetText() and fs:GetText() ~= "") and (fs:GetStringHeight() or 14) or 0
    if h < 1 and fs:GetText() and fs:GetText() ~= "" then h = 14 end
    if h > 0 then y = y - h - (gap or 6) end
  end
  place(win.dTitle, 6) place(win.dInfo, 4) place(win.dTags, 8) place(win.dWhy, 8) place(win.dRew, 8) place(win.dNote, 10)
  win.dStepHead:ClearAllPoints()
  win.dStepHead:SetPoint("TOPLEFT", win.detail, "TOPLEFT", 0, y)
  win.dStepHead:SetText(total > 1 and string.format("단계 (%d개, 줄을 누르면 그 단계로 길 안내)", total) or "퀘스트 (줄을 누르면 길 안내)")
  y = y - 18
  local lines = StepLines(e)
  local room = math.max(1, math.floor((H - 76 + y - 40) / (SROW_H * 2)))
  local maxOff = math.max(0, #lines - room)
  if offS > maxOff then offS = maxOff end
  if offS < 0 then offS = 0 end
  for i, row in ipairs(stepRows) do
    local ln = lines[i + offS]
    row.ln = ln
    if ln and i <= room then
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", win.detail, "TOPLEFT", -4, y - (i - 1) * SROW_H * 2)
      row.text:SetText(ln.text .. (ln.n == cur and st ~= "done" and (" " .. Hex(C_ACCENT) .. "◀ 지금|r") or ""))
      row.sub:SetText(Hex(C_MUTED) .. ln.sub .. "|r")
      row.badge:SetText(QSTATE_TEXT[ln.state] or "")
      if ln.state == "done" then row.text:SetTextColor(0.55, 0.55, 0.55) else row.text:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3]) end
      row:Show()
    else
      row:Hide()
    end
  end
  win.dMore:SetText(#lines > room and string.format("%d~%d / %d단계 (마우스 휠)", offS + 1, math.min(#lines, offS + room), #lines) or "")
  win.curId = (lines[cur] and lines[cur].id) or nil
  Shown(win.bGo, st ~= "done" and st ~= "owned" and win.curId ~= nil)
end

local function Refresh()
  if not win or not win:IsShown() then return end
  if KQG.ReadLog then pcall(KQG.ReadLog) end
  RenderLeft()
  local found = false
  for _, e in ipairs(list) do if e.key == sel then found = true end end
  if not found then sel = list[1] and list[1].key or nil offS = 0 end
  RenderRight()
end

local function Select(key)
  sel = key
  offS = 0
  local r = db()
  if r then r.sel = key end
  RenderLeft()
  RenderRight()
end

local function SetTab(cat)
  local r = db()
  if r then r.tab = cat end
  offL = 0
  Refresh()
end

local function Btn(parent, text, w, fn)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, 22)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  Solid(b.bg, 0.055, 0.085, 0.10, 1)
  b.label = SetF(b:CreateFontString(nil, "OVERLAY"), 11)
  b.label:SetPoint("CENTER")
  b.label:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  b.label:SetText(text)
  b:SetScript("OnClick", fn)
  return b
end

local function SavePos()
  local r = db()
  if not r or not win then return end
  local x, y = win:GetCenter()
  local ux, uy = UIParent:GetCenter()
  if x and y and ux and uy then r.pos = { x - ux, y - uy } end
end

local function Build()
  win = CreateFrame("Frame", "KQGRecommendFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  win:SetSize(W, H)
  local r = db()
  if r and type(r.pos) == "table" and type(r.pos[1]) == "number" then win:SetPoint("CENTER", UIParent, "CENTER", r.pos[1], r.pos[2])
  else win:SetPoint("CENTER", 80, 0) end
  win.bg = win:CreateTexture(nil, "BACKGROUND")
  win.bg:SetAllPoints()
  Solid(win.bg, C_BG[1], C_BG[2], C_BG[3], 0.96)
  local top = win:CreateTexture(nil, "BORDER")
  top:SetPoint("TOPLEFT") top:SetPoint("TOPRIGHT") top:SetHeight(2)
  Solid(top, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
  local split = win:CreateTexture(nil, "BORDER")
  split:SetPoint("TOPLEFT", LEFT_W, -66) split:SetPoint("BOTTOMLEFT", LEFT_W, 28) split:SetWidth(1)
  Solid(split, 1, 1, 1, 0.08)
  win:SetMovable(true) win:EnableMouse(true) win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", function() win:StopMovingOrSizing() SavePos() end)
  win:SetFrameStrata("DIALOG") win:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "KQGRecommendFrame")

  local title = SetF(win:CreateFontString(nil, "OVERLAY"), 15, true)
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  title:SetText("추천 퀘스트 관리")
  local hint = SetF(win:CreateFontString(nil, "OVERLAY"), 10)
  hint:SetPoint("LEFT", title, "RIGHT", 10, -1)
  hint:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  hint:SetText("레벨링 필수는 아니지만 오래 도움이 되는 퀘스트 · 지금 캐릭터가 할 수 있는 것만")
  local close = CreateFrame("Button", nil, win)
  close:SetSize(20, 20)
  close:SetPoint("TOPRIGHT", -8, -10)
  close.t = SetF(close:CreateFontString(nil, "OVERLAY"), 15, true)
  close.t:SetPoint("CENTER")
  close.t:SetText("X")
  close.t:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  close:SetScript("OnEnter", function() close.t:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3]) end)
  close:SetScript("OnLeave", function() close.t:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3]) end)
  close:SetScript("OnClick", function() win:Hide() end)

  -- 분류 탭
  win.tabs = {}
  local x = 14
  for _, c in ipairs(D.cats) do
    local cat = c[1]
    local b = Btn(win, c[2], 78, function() SetTab(cat) end)
    b.cat, b.title = cat, c[2]
    b:SetPoint("TOPLEFT", x, -38)
    x = x + 82
    win.tabs[#win.tabs + 1] = b
  end
  win.bDone = Btn(win, "완료 보기", 90, function()
    local rr = db()
    if rr then rr.showDone = not rr.showDone end
    Refresh()
  end)
  win.bDone:SetPoint("TOPRIGHT", -14, -38)

  -- 왼쪽 목록
  win.left = {}
  for i = 1, LROWS do
    local row = CreateFrame("Button", nil, win)
    row:SetSize(LEFT_W - 12, ROW_H - 2)
    row:SetPoint("TOPLEFT", 6, -68 - (i - 1) * ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.state = SetF(row:CreateFontString(nil, "OVERLAY"), 11, true)
    row.state:SetPoint("TOPLEFT", 6, -3)
    row.state:SetWidth(58)
    row.state:SetJustifyH("LEFT")
    row.name = SetF(row:CreateFontString(nil, "OVERLAY"), 12)
    row.name:SetPoint("TOPLEFT", 66, -3)
    row.name:SetPoint("RIGHT", row, "RIGHT", -52, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.lv = SetF(row:CreateFontString(nil, "OVERLAY"), 11)
    row.lv:SetPoint("TOPRIGHT", -6, -3)
    row.sub = SetF(row:CreateFontString(nil, "OVERLAY"), 10)
    row.sub:SetPoint("BOTTOMLEFT", 66, 3)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.tags = SetF(row:CreateFontString(nil, "OVERLAY"), 10, true)
    row.tags:SetPoint("BOTTOMRIGHT", -6, 3)
    row.tags:SetJustifyH("RIGHT")
    row.tags:SetWordWrap(false)
    row.sub:SetPoint("RIGHT", row.tags, "LEFT", -6, 0)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, dlt) offL = offL - dlt * 3 RenderLeft() end)
    row:SetScript("OnClick", function(self) if self.e then Select(self.e.key) end end)
    row:SetScript("OnEnter", function(self) if self.e and self.e.key ~= sel then Solid(self.bg, 1, 1, 1, 0.05) end end)
    row:SetScript("OnLeave", function(self) if self.e and self.e.key ~= sel then Solid(self.bg, 0, 0, 0, 0) end end)
    win.left[i] = row
  end
  win.empty = SetF(win:CreateFontString(nil, "OVERLAY"), 11)
  win.empty:SetPoint("TOPLEFT", 14, -80)
  win.empty:SetWidth(LEFT_W - 28)
  win.empty:SetJustifyH("LEFT")
  win.empty:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  win.more = SetF(win:CreateFontString(nil, "OVERLAY"), 10)
  win.more:SetPoint("BOTTOMLEFT", 14, 32)
  win.more:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])

  -- 오른쪽 상세
  local RW = W - LEFT_W - 28
  win.detail = CreateFrame("Frame", nil, win)
  win.detail:SetPoint("TOPLEFT", LEFT_W + 14, -66)
  win.detail:SetSize(RW, H - 66 - 30)
  local function Txt(size, bold, color)
    local fs = SetF(win.detail:CreateFontString(nil, "OVERLAY"), size, bold)
    fs:SetWidth(RW)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetTextColor(color[1], color[2], color[3])
    return fs
  end
  win.dTitle = Txt(14, true, C_GOLD)
  win.dInfo = Txt(11, false, C_TEXT)
  win.dTags = Txt(11, true, C_TEXT)
  win.dWhy = Txt(12, false, C_TEXT)
  win.dRew = Txt(11, false, C_TEXT)
  win.dNote = Txt(11, false, C_MUTED)
  win.dStepHead = Txt(11, true, C_ACCENT)
  for i = 1, 16 do
    local row = CreateFrame("Button", nil, win.detail)
    row:SetSize(RW + 4, SROW_H * 2 - 2)
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints()
    Solid(row.hl, 1, 1, 1, 0.05)
    row.hl:Hide()
    row.text = SetF(row:CreateFontString(nil, "OVERLAY"), 12)
    row.text:SetPoint("TOPLEFT", 4, -2)
    row.text:SetPoint("RIGHT", row, "RIGHT", -70, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row.sub = SetF(row:CreateFontString(nil, "OVERLAY"), 10)
    row.sub:SetPoint("BOTTOMLEFT", 18, 2)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.badge = SetF(row:CreateFontString(nil, "OVERLAY"), 11, true)
    row.badge:SetPoint("TOPRIGHT", -6, -2)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, dlt) offS = offS - dlt * 2 RenderRight() end)
    row:SetScript("OnClick", function(self)
      local ln = self.ln
      if not ln then return end
      if ln.state == "done" then Print("이미 끝낸 단계입니다: " .. (QTitle(ln.id))) return end
      GuideTo(ln.id)
    end)
    row:SetScript("OnEnter", function(self)
      self.hl:Show()
      local ln = self.ln
      if not ln then return end
      local name, src = QTitle(ln.id)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(name, 1, 1, 1)
      local qi = D.quests[ln.id]
      if qi then GameTooltip:AddLine(string.format("퀘스트 레벨 %s · 수락 레벨 %s", tostring(qi[2] or "?"), tostring(qi[3] or "?")), C_TEXT[1], C_TEXT[2], C_TEXT[3]) end
      local s1, q1 = Spot(ln.id, "start")
      GameTooltip:AddLine("시작: " .. SpotText(s1, q1), C_TEXT[1], C_TEXT[2], C_TEXT[3], true)
      local s2, q2 = Spot(ln.id, "end")
      GameTooltip:AddLine("완료: " .. SpotText(s2, q2), C_TEXT[1], C_TEXT[2], C_TEXT[3], true)
      local goal, gq = GoalText(ln.id)
      if goal then GameTooltip:AddLine("목표: " .. goal .. (gq and " (Questie)" or ""), C_MUTED[1], C_MUTED[2], C_MUTED[3], true) end
      if ln.alt then GameTooltip:AddLine("진영·종족에 따라 같은 단계 퀘스트가 여러 개입니다. 지금 캐릭터 것을 보여 줍니다.", C_MUTED[1], C_MUTED[2], C_MUTED[3], true) end
      if src ~= "kqg" and qi and qi[1] then GameTooltip:AddLine("영어 이름: " .. qi[1], C_MUTED[1], C_MUTED[2], C_MUTED[3], true) end
      GameTooltip:AddLine("번호 " .. ln.id .. " · 정보 출처: " .. (src == "kqg" and "KQuestGuide 자료" or src == "game" and "게임" or "QuestieDB"), C_MUTED[1], C_MUTED[2], C_MUTED[3], true)
      if ln.state ~= "done" then GameTooltip:AddLine("클릭: 이 단계로 길 안내", C_ACCENT[1], C_ACCENT[2], C_ACCENT[3]) end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self) self.hl:Hide() GameTooltip:Hide() end)
    stepRows[i] = row
  end
  win.dMore = SetF(win:CreateFontString(nil, "OVERLAY"), 10)
  win.dMore:SetPoint("BOTTOMRIGHT", -120, 34)
  win.dMore:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  win.bGo = Btn(win, "지금 단계 길 안내", 110, function() if win.curId then GuideTo(win.curId) end end)
  win.bGo:SetPoint("BOTTOMRIGHT", -14, 30)
  Solid(win.bGo.bg, C_SEL[1], C_SEL[2], C_SEL[3], 1)
  win.bGo.label:SetTextColor(1, 1, 1)
  win.detail:EnableMouseWheel(true)
  win.detail:SetScript("OnMouseWheel", function(_, dlt) offS = offS - dlt * 2 RenderRight() end)

  local src = SetF(win:CreateFontString(nil, "OVERLAY"), 10)
  src:SetPoint("BOTTOMLEFT", 14, 10)
  src:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  src:SetText(SRC_LINE)
  win:SetScript("OnShow", function() Refresh() end)
  win:Hide()
end

local function Toggle()
  if not D or not D.list then Print("추천 퀘스트 자료(RecommendData.lua)를 읽지 못했습니다.") return end
  if not win then Build() end
  if win:IsShown() then win:Hide() return end
  local r = db()
  sel = sel or (r and r.sel)
  win:Show()
  Refresh()
end
KQG.RecommendToggle = function() local ok, err = pcall(Toggle) if not ok then Print("추천 퀘스트 창 오류: " .. tostring(err)) end end

-- 퀘스트 로그·완료·가방이 바뀌면 열려 있는 창을 0.5초 뒤 한 번 다시 그림
local ev = CreateFrame("Frame")
local dueAt = nil
for _, e in ipairs({ "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED", "BAG_UPDATE_DELAYED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function()
  if win and win:IsShown() then dueAt = GetTime() + 0.5 end
end)
ev:SetScript("OnUpdate", function()
  if dueAt and GetTime() >= dueAt then
    dueAt = nil
    pcall(Refresh)
  end
end)
