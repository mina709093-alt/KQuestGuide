-- KQuestGuide: 한글 퀘스트 길잡이 (WoW: Forever)
-- 퀘스트 데이터는 Questie / QuestieDB (GPLv3 조건) 의 포에버 데이터에서 만들었습니다. NOTICE.txt 참고.
--
-- 하는 일: 지금 있는 지역에서 "받을 수 있는 퀘스트"와 "제출할 퀘스트"를 가까운 순서로 보여 주고,
--          다음 목적지 방향을 화살표로 알려 줍니다. 퀘스트 이름/NPC/지역은 모두 한글입니다.
-- 명령어: /kqg (창 열기/닫기)  /kqg 던전  /kqg 기록  /kqg 수집  /kqg skip  /kqg back  /kqg arrow  /kqg waypoint  /kqg gray  /kqg gray chain  /kqg 자동기준  /kqg 미리받기  /kqg 정리  /kqg 책  /kqg minimap  /kqg gear  /kqg plan  /kqg debug

local Q = KQG_DATA or {}
local MAP = KQG_MAP or {}

-- 퀘스트 데이터 칸 번호
local F_NAME, F_LVL, F_MIN, F_RACES, F_CLASSES, F_PREG, F_PRES, F_EXCL, F_NEXT, F_ZONE,
  F_START, F_END, F_TEXT, F_FLAGS, F_PARENT, F_MAXLVL = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
-- (0.29.0) 안내(브레드크럼) 퀘스트 칸. BreadcrumbData.lua가 채웁니다(QuestieDB 27·28칸).
--   F_BCFOR: 이 퀘스트가 안내하는 퀘스트 번호, F_BCS: 이 퀘스트로 안내하는 퀘스트 번호 목록
local F_BCFOR, F_BCS = 17, 18

local db
local frame, arrow
local dirty = true
local lastCompute = 0
local steps = {}          -- 계산된 단계 목록
local progress = {}       -- 진행 중인 퀘스트 목록 (이 지역)
local suggestions = {}    -- 이 지역에 할 게 없을 때 추천 지역
local curMap = nil
local inLog, logComplete, logIndex = {}, {}, {}
local logElite = {}
local completedSet = nil
local byMap = {}
local pinned = nil        -- 사용자가 목록에서 고른 단계 키
local lastSkip = {}       -- 되돌리기용
local forced = nil        -- 장비 추천 등에서 사용자가 지정한 목적지(화살표가 우선 따라감)

-- 버그 리포트용 기록 ---------------------------------------------------------
local bugs = {}            -- { key, tag, msg, trace, count, time }
local ringLog = {}         -- 최근 동작 기록 (리포트에 같이 담김)
local ReportBug, UpdateBugButton

local function RingPush(t)
  ringLog[#ringLog + 1] = string.format("%.0f ", GetTime and GetTime() or 0) .. tostring(t)
  if #ringLog > 40 then table.remove(ringLog, 1) end
end

local function Print(t)
  local ok = true
  RingPush((tostring(t):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99퀘스트 길잡이|r " .. tostring(t))
end

local function TraceHandler(e)
  local tr = ""
  if debugstack then tr = debugstack(2, 12, 0)
  elseif debug and debug.traceback then tr = debug.traceback("", 2) end
  return { msg = tostring(e), trace = tr }
end

-- 오류가 나도 조용히 넘어가지 않고 기록합니다 (버그 리포트 버튼이 나타남)
local function Guard(tag, fn)
  local ok, res = xpcall(fn, TraceHandler)
  if not ok then
    if type(res) ~= "table" then res = { msg = tostring(res), trace = "" } end
    if ReportBug then ReportBug(tag, res.msg, res.trace) end
    return false
  end
  return true
end

do
  local prev = geterrorhandler and geterrorhandler()
  if seterrorhandler then
    seterrorhandler(function(msg)
      pcall(function()
        if ReportBug and tostring(msg):find("KQuestGuide", 1, true) then
          ReportBug("lua", tostring(msg), (debugstack and debugstack(2, 12, 0)) or "")
        end
      end)
      if prev then return prev(msg) end
    end)
  end
end

-- 유틸 ----------------------------------------------------------------------

local function Bit(mask, bit)
  if not mask or mask == 0 then return true end
  return math.floor(mask / (2 ^ bit)) % 2 == 1
end

local function UiMapOf(area)
  if not area then return nil end
  return MAP[area]
end

local function MapName(uiMap)
  if C_Map and C_Map.GetMapInfo then
    local ok, info = pcall(C_Map.GetMapInfo, uiMap)
    if ok and info and info.name then return info.name end
  end
  return "지역 " .. tostring(uiMap)
end

local playerFaction, playerRaceBit, playerClassBit = "A", 0, 0
local function InitPlayer()
  local f = UnitFactionGroup and UnitFactionGroup("player")
  playerFaction = (f == "Horde") and "H" or "A"
  local ok, _, _, raceID = pcall(UnitRace, "player")
  if ok and raceID then
    if raceID >= 95 then playerRaceBit = raceID - 63 else playerRaceBit = raceID - 1 end
  end
  local ok2, _, _, classID = pcall(UnitClass, "player")
  if ok2 and classID then playerClassBit = classID - 1 end
end

local function IsDone(id)
  if completedSet then return completedSet[id] and true or false end
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    return C_QuestLog.IsQuestFlaggedCompleted(id) and true or false
  end
  if IsQuestFlaggedCompleted then return IsQuestFlaggedCompleted(id) and true or false end
  return false
end

-- 퀘스트 로그 읽기
local function ReadLog()
  inLog, logComplete, logIndex = {}, {}, {}
  logElite = {}
  local n = 0
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
    n = C_QuestLog.GetNumQuestLogEntries()
  elseif GetNumQuestLogEntries then
    n = GetNumQuestLogEntries()
  end
  for i = 1, n do
    local qid, isHeader, complete, group
    if C_QuestLog and C_QuestLog.GetInfo then
      local info = C_QuestLog.GetInfo(i)
      if info then
        qid = info.questID
        isHeader = info.isHeader
        group = info.suggestedGroup
        if C_QuestLog.IsComplete then complete = C_QuestLog.IsComplete(qid) end
      end
    elseif GetQuestLogTitle then
      local _, _, grp, hdr, _, comp, _, id = GetQuestLogTitle(i)
      group = grp
      qid = id
      isHeader = hdr
      complete = (comp == 1)
    end
    if qid and not isHeader and qid > 0 then
      inLog[qid] = true
      logIndex[qid] = i
      if not complete and C_QuestLog and C_QuestLog.GetQuestObjectives then
        -- 완료 표시가 안 와도 목표가 모두 끝났으면 제출 가능으로 본다
        local ok, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
        if ok and type(objs) == "table" and #objs > 0 then
          local all = true
          for _, ob in ipairs(objs) do
            if not ob.finished then all = false break end
          end
          if all then complete = true end
        end
      end
      if complete then logComplete[qid] = true end
      local elite = (type(group) == "number" and group > 1) or (type(group) == "string" and group ~= "")
      if not elite and C_QuestLog and C_QuestLog.GetQuestTagInfo then
        local ok, tag = pcall(C_QuestLog.GetQuestTagInfo, qid)
        if ok and type(tag) == "table" and (tag.isElite or tag.tagID == 1 or tag.tagID == 62 or tag.tagID == 81) then
          elite = true
        end
      end
      if elite then logElite[qid] = true end
    end
  end
  if GetQuestsCompleted then
    local ok, t = pcall(GetQuestsCompleted)
    if ok and type(t) == "table" then completedSet = t else completedSet = nil end
  else
    completedSet = nil
  end
end

-- 위치 / 거리 -----------------------------------------------------------------

local function PlayerPos()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local m = C_Map.GetBestMapForUnit("player")
  if not m then return nil end
  local p = C_Map.GetPlayerMapPosition(m, "player")
  if not p then return nil end
  local x, y = p:GetXY()
  if not x or (x == 0 and y == 0) then return m, nil, nil end
  return m, x * 100, y * 100
end

local function WorldXY(uiMap, x, y)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
  local ok, inst, pos = pcall(C_Map.GetWorldPosFromMapPos, uiMap, CreateVector2D(x / 100, y / 100))
  if ok and pos then
    local wx, wy = pos:GetXY()
    return wx, wy
  end
  return nil
end

-- 야드 거리(알 수 있을 때), 방향각
local function Measure(uiMap, tx, ty)
  local m, px, py = PlayerPos()
  if not m or m ~= uiMap or not px then return nil, nil end
  local dx, dy = tx - px, ty - py
  local bearing = math.atan2 and math.atan2(dx * 1.5, -dy) or math.atan(dx * 1.5, -dy)
  local ax, ay = WorldXY(uiMap, px, py)
  local bx, by = WorldXY(uiMap, tx, ty)
  local dist
  if ax and bx then
    dist = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
  else
    dist = math.sqrt((dx * 1.5) ^ 2 + dy ^ 2) * 10 -- 대략값
  end
  return dist, bearing
end

-- 퀘스트 판정 -----------------------------------------------------------------

local function Hide_Gray()
  return db.hideGray ~= false
end

-- 회색(저레벨) 판정: 게임의 회색 기준(내 레벨 - 퀘스트 레벨 > 회색 범위)과 같게 합니다.
-- 회색 범위는 쓸 수 있는 게임 함수 순서대로 가져오고, 모두 없으면 7(예전 고정 기준과 같음)을 씁니다.
local GRAY_FALLBACK = 7
local grayRange, grayRangeSrc, grayRangeLevel = nil, nil, nil
local function PlainNum(v)
  if type(issecretvalue) == "function" then
    local ok, sec = pcall(issecretvalue, v)
    if ok and sec then return nil end
  end
  if type(v) == "number" and v >= 0 and v < 100 then return v end
  return nil
end
local function GrayRange()
  local lv = UnitLevel("player") or 0
  if grayRange and grayRangeLevel == lv then return grayRange, grayRangeSrc end
  local r, src
  if C_QuestLog and type(C_QuestLog.GetTrivialRange) == "function" then
    local ok, v = pcall(C_QuestLog.GetTrivialRange)
    if ok then r = PlainNum(v) if r then src = "C_QuestLog.GetTrivialRange" end end
  end
  if not r and type(GetQuestGreenRange) == "function" then
    local ok, v = pcall(GetQuestGreenRange, "player")
    if ok then r = PlainNum(v) if r then src = "GetQuestGreenRange" end end
  end
  if not r and type(UnitQuestTrivialLevelRange) == "function" then
    local ok, v = pcall(UnitQuestTrivialLevelRange, "player")
    if ok then r = PlainNum(v) if r then src = "UnitQuestTrivialLevelRange" end end
  end
  if not r then r, src = GRAY_FALLBACK, "기본값" end
  grayRange, grayRangeSrc, grayRangeLevel = r, src, lv
  return r, src
end
local function IsGrayLevel(ql, level)
  if type(ql) ~= "number" or ql <= 0 then return false end
  return level - ql > GrayRange()
end

-- 연계 판정: 이 퀘스트를 끝내야 열리는 퀘스트(다음 퀘스트, 이 퀘스트를 선행으로 요구하는 퀘스트)
local nextOf = {}         -- 퀘스트 번호 -> 이어지는 퀘스트 번호 목록 (BuildIndex에서 만듦)
local chainCache = {}     -- 계산할 때마다 비움
local CHAIN_DEPTH = 8

-- 내가 나중에 받을 수 있는 퀘스트인지 (레벨·선행 제외)
local function CanTakeLater(id, level)
  local r = Q[id]
  if not r then return false end
  if db.skipped[id] or IsDone(id) then return false end
  if r[F_MAXLVL] and level > r[F_MAXLVL] then return false end
  if r[F_FLAGS] and math.floor(r[F_FLAGS]) % 2 == 1 then return false end
  if not Bit(r[F_RACES], playerRaceBit) then return false end
  if not Bit(r[F_CLASSES], playerClassBit) then return false end
  local s = r[F_START]
  local fr = s and s[7]
  if fr and fr ~= "" and not string.find(fr, playerFaction, 1, true) then return false end
  return true
end

-- id 다음으로 이어지는 퀘스트 중 test(번호)가 참인 것이 있는지 (CHAIN_DEPTH 단계까지)
local function ChainHas(id, test)
  local seen, cur = { [id] = true }, { id }
  for _ = 1, CHAIN_DEPTH do
    local nxt = {}
    for _, q in ipairs(cur) do
      for _, n in ipairs(nextOf[q] or {}) do
        if not seen[n] then
          seen[n] = true
          if test(n) then return true end
          nxt[#nxt + 1] = n
        end
      end
    end
    if #nxt == 0 then break end
    cur = nxt
  end
  return false
end

-- 연계를 따라가면 내 레벨에 맞는(회색이 아닌) 받을 수 있는 퀘스트가 나오는지
local function ChainLeadsToFit(id, level)
  local key = id .. ":" .. level
  local v = chainCache[key]
  if v == nil then
    v = ChainHas(id, function(n)
      return CanTakeLater(n, level) and not IsGrayLevel(Q[n][F_LVL], level)
    end)
    chainCache[key] = v
  end
  return v
end

-- 안내에서 뺄 회색 퀘스트인지 (연계 예외 반영)
local function GrayHidden(id, level)
  if not Hide_Gray() then return false end
  local r = Q[id]
  if not r or not IsGrayLevel(r[F_LVL], level) then return false end
  if db.grayChain ~= false and ChainLeadsToFit(id, level) then return false end
  return true
end

local function BuildIndex()
  byMap = {}
  nextOf = {}
  -- a를 끝내면 b가 열림
  local function AddNext(a, b)
    if a == b then return end
    local t = nextOf[a]
    if not t then t = {} nextOf[a] = t end
    t[#t + 1] = b
  end
  for id, r in pairs(Q) do
    local s = r[F_START]
    if s and s[3] then
      local m = UiMapOf(s[3])
      if m then
        byMap[m] = byMap[m] or {}
        table.insert(byMap[m], id)
      end
    end
    -- 연계 색인: 다음 퀘스트와, 이 퀘스트를 선행으로 요구하는 퀘스트
    if r[F_NEXT] then AddNext(id, r[F_NEXT]) end
    if r[F_PREG] then for _, p in ipairs(r[F_PREG]) do AddNext(p, id) end end
    if r[F_PRES] then for _, p in ipairs(r[F_PRES]) do AddNext(p, id) end end
    -- (0.29.0) 안내 퀘스트 -> 안내받는 퀘스트 (회색 안내 퀘스트도 연계 예외로 남기기 위해)
    if r[F_BCFOR] then AddNext(id, r[F_BCFOR]) end
  end
  chainCache = {}
end

-- 레벨링 엔진 -------------------------------------------------------------------
-- 원칙: 지금 있는 지역이 최우선입니다. 이 지역에서 받을/수행할/제출할 퀘스트를 레벨 적합도와 체인으로 순서를 정합니다.
--  - 다른 지역 추천은 보조 안내(상단 문구)일 뿐, 현재 지역 목록을 지우거나 바꾸지 않습니다.
--  - 이동 추천은 현재 지역의 일이 부족하고, 다른 지역이 확실히 나을 때만 나옵니다.
--  - 순서(1~4순위): 이미 받은 퀘스트 제출/수행 > 새로 받을 적정 레벨 퀘스트 > 이어지는 체인 > 그 밖의 연계 퀘스트
--    5순위: 현재 지역 효율이 낮을 때만 다른 지역 이동 추천(상단 문구)
--  - 경험치 수치는 데이터에 없어서 레벨 차이, 체인, 퀘스트 양으로 효율을 가늠합니다.

local OBJ = KQG_OBJ or {}
local doneCache = {}
local locked = {}         -- 선행이 필요한 퀘스트 안내
local noloc = {}          -- 진행 중이지만 이 지역 목표 위치 데이터가 없는 퀘스트
local levelZone = nil     -- 지금 레벨링할 지역
local zoneRank = {}
local zoneEval = { score = 0, text = "알 수 없음", level = "none" }

local function DoneC(id)
  local v = doneCache[id]
  if v == nil then
    v = IsDone(id) and true or false
    doneCache[id] = v
  end
  return v
end

local function Fit(ql, level)
  if not ql or ql <= 0 then return 0.5 end
  local d = ql - level
  if d >= 5 then return 0.1 end
  if d >= 3 then return 0.5 end
  if d >= 0 then return 1.0 end
  if d >= -2 then return 0.9 end
  if d >= -4 then return 0.6 end
  if d >= -7 then return 0.3 end
  return 0.1
end

-- 종족/직업/진영/레벨/반복/배타 조건 (선행 조건 제외)
local function Basic(id, level)
  local r = Q[id]
  if not r then return false end
  if db.skipped[id] then return false end
  if DoneC(id) or inLog[id] then return false end
  if (r[F_MIN] or 0) > level then return false end
  if r[F_MAXLVL] and level > r[F_MAXLVL] then return false end
  if r[F_FLAGS] and math.floor(r[F_FLAGS]) % 2 == 1 then return false end
  if not Bit(r[F_RACES], playerRaceBit) then return false end
  if not Bit(r[F_CLASSES], playerClassBit) then return false end
  if r[F_EXCL] then
    for _, p in ipairs(r[F_EXCL]) do
      if DoneC(p) or inLog[p] then return false end
    end
  end
  if r[F_NEXT] and (DoneC(r[F_NEXT]) or inLog[r[F_NEXT]]) then return false end
  -- (0.29.0) 안내 퀘스트: 안내하는 퀘스트를 이미 받았거나 끝냈으면 필요 없음 (Questie와 같은 규칙)
  if r[F_BCFOR] and (DoneC(r[F_BCFOR]) or inLog[r[F_BCFOR]]) then return false end
  -- 이 퀘스트로 안내하는 퀘스트를 들고 있으면, 그 퀘스트를 제출하면서 받게 되므로 따로 안내하지 않음
  if r[F_BCS] then
    for _, b in ipairs(r[F_BCS]) do
      if inLog[b] then return false end
    end
  end
  local s = r[F_START]
  if not s or not s[3] then return false end
  local fr = s[7]
  if fr and fr ~= "" and not string.find(fr, playerFaction, 1, true) then return false end
  return true
end

local function PrereqUnmet(r)
  local un = {}
  if r[F_PREG] then
    for _, p in ipairs(r[F_PREG]) do
      if not DoneC(p) then un[#un + 1] = p end
    end
  end
  if r[F_PRES] then
    local any = false
    for _, p in ipairs(r[F_PRES]) do
      if DoneC(p) then any = true break end
    end
    if not any then
      for _, p in ipairs(r[F_PRES]) do un[#un + 1] = p end
    end
  end
  return un
end

-- 레벨 기준 (0.28.0: 목록과 계획이 같은 기준을 씁니다)
-- (0.29.0) 0.28.0 이후 새로 넣은 안내 값과 함수 모음. 이 파일의 바깥 local은 Lua 5.1 제한(200개)에 거의 닿아 있어서
-- 새 이름은 local을 늘리지 말고 이 표에 넣습니다.
local Guide = {}
Guide.ACCEPT_ABOVE = 8    -- 퀘스트 레벨이 내 레벨보다 이만큼 넘게 높으면 아직 수락 안내에 넣지 않음
Guide.HARD_ABOVE = 5      -- 내 레벨보다 이만큼 이상 높으면 어려운 퀘스트(계획에서 뒤로 미루거나 보류)

-- 지금 받을 수 있는 퀘스트 (선행 충족 + 부모/레벨 회색 설정 반영)
local function Avail(id, level)
  if not Basic(id, level) then return false end
  local r = Q[id]
  if GrayHidden(id, level) then return false end
  if (r[F_LVL] or 0) - level > Guide.ACCEPT_ABOVE then return false end -- 너무 높은 레벨은 아직 추천하지 않음
  if r[F_PARENT] and not inLog[r[F_PARENT]] then return false end
  return #PrereqUnmet(r) == 0
end

-- 앞으로 이어지는 후속 퀘스트들
local function NextChain(id)
  local list, cur, seen = {}, id, {}
  while #list < 8 do
    local r = Q[cur]
    local nx = r and r[F_NEXT]
    if not nx or seen[nx] or not Q[nx] then break end
    seen[nx] = true
    list[#list + 1] = nx
    cur = nx
  end
  return list
end

local function ChainBonus(id, level)
  local sum = 0
  for _, nx in ipairs(NextChain(id)) do
    sum = sum + Fit(Q[nx][F_LVL], level) * 0.25
  end
  if sum > 1 then sum = 1 end
  return sum
end

-- (0.29.0) 선행 사슬의 첫 걸음이 얼마나 먼지 (작을수록 가까움). 같은 지도면 지도 좌표 거리,
-- 다른 지도면 100000, 위치를 모르면 1e9. 내 위치(chainPos)는 Compute가 계산할 때마다 채웁니다.
Guide.chainPos = {}
function Guide.ChainCost(ch)
  local first = ch and ch[1]
  local r = first and Q[first]
  local loc = r and (inLog[first] and r[F_END] or r[F_START])
  local mp = loc and loc[3] and UiMapOf(loc[3])
  if not mp then return 1e9 end
  if mp ~= Guide.chainPos.map or not Guide.chainPos.x or not loc[4] then return 100000 end
  return math.sqrt(((loc[4] - Guide.chainPos.x) * 1.5) ^ 2 + (loc[5] - Guide.chainPos.y) ^ 2)
end

-- 거꾸로 따라가 "처음 받을 퀘스트"부터의 사슬을 만듭니다. 불가능하면 nil.
local function Backchain(id, level, depth)
  if depth > 8 then return nil end
  local r = Q[id]
  if not r then return nil end
  if inLog[id] then return { id } end
  if not Basic(id, level + 12) then return nil end
  local un = PrereqUnmet(r)
  if #un == 0 then return { id } end
  -- (0.29.0) 반드시 할 선행(F_PREG)은 다 했고 "아무거나 하나"(F_PRES)만 남았으면, 첫 걸음이 가장 가까운 쪽을 고릅니다
  local pregLeft = false
  for _, p in ipairs(r[F_PREG] or {}) do
    if not DoneC(p) then pregLeft = true break end
  end
  if not pregLeft and #un > 1 then
    local best, bc
    for _, p in ipairs(un) do
      local sub = Backchain(p, level, depth + 1)
      if sub then
        local c = Guide.ChainCost(sub)
        if not best or c < bc then best, bc = sub, c end
      end
    end
    if best then best[#best + 1] = id end
    return best
  end
  for _, p in ipairs(un) do
    local sub = Backchain(p, level, depth + 1)
    if sub then
      sub[#sub + 1] = id
      return sub
    end
  end
  return nil
end

-- 목표 이름 한글화: 데이터에 영어 이름만 있으면, 퀘스트 로그(게임 클라이언트)가 주는 한글 목표 문구를 쓴다
local OBJ_API_TYPE = { k = "monster", i = "item", o = "object", e = "event" }
local function HasHangul(s)
  return type(s) == "string" and s:find("[\234-\237][\128-\191][\128-\191]") ~= nil
end
local function CleanObjText(t)
  if type(t) ~= "string" or t == "" then return nil end
  t = t:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("[:：]%s*%d+%s*/%s*%d+%s*$", ""):gsub("%s*%(%d+/%d+%)%s*$", "")
  t = t:gsub("%s+처치$", ""):gsub("%s+$", "")
  return t ~= "" and t or nil
end
local function LocalObjNames(qid, rows)
  local names = {}
  if not (C_QuestLog and C_QuestLog.GetQuestObjectives) then return names end
  local need = false
  for _, o in ipairs(rows) do if o[1] ~= "e" and not HasHangul(o[2]) then need = true break end end
  if not need then return names end
  local ok, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
  if not ok or type(objs) ~= "table" or #objs == 0 then return names end
  local byType, order, seenName = {}, {}, {}
  for _, ob in ipairs(objs) do
    local t = ob.type or "?"
    byType[t] = byType[t] or {}
    table.insert(byType[t], CleanObjText(ob.text))
  end
  for i, o in ipairs(rows) do
    if o[1] ~= "e" and not HasHangul(o[2]) then
      local t = OBJ_API_TYPE[o[1]] or "?"
      local list = byType[t]
      if not seenName[o[2]] then
        order[t] = (order[t] or 0) + 1
        seenName[o[2]] = order[t]
      end
      local pick = list and (list[seenName[o[2]]] or (#list == 1 and list[1]))
      if not pick and #objs == 1 then pick = CleanObjText(objs[1].text) end
      names[i] = pick
    end
  end
  return names
end

local function ObjectiveSteps(qid, level)
  local rows = OBJ[qid]
  local out = {}
  if not rows then return out end
  local ko = inLog[qid] and LocalObjNames(qid, rows) or {}
  for i, o in ipairs(rows) do
    local map = UiMapOf(o[3])
    if map then
      local name = (o[1] == "e") and "탐험 지점" or (ko[i] or o[2])
      table.insert(out, { kind = "doing", map = map, loc = { "q", qid, o[3], o[4], o[5], name, nil }, otype = o[1] })
    end
  end
  return out
end

local BuildPlan
local QName
-- 계획 엔진 (수집 계획 + 수행 계획 + 외부 선행 퀘스트) ---------------------------------------
-- 순서: [외부 지역 선행 퀘스트 → 복귀] → 완료한 퀘스트 제출 → 수집 계획(수락 순서) → 수행 계획(목표 동선 묶음) → 다음 지역
-- 수락 순서는 NPC 방문 거리가 짧은 순서(가장 가까운 곳부터 이어서)이고,
-- 수행 순서는 "목표가 가까운 퀘스트를 한 구간으로 묶은 뒤" 거리와 난이도를 함께 보고 정합니다.
-- 난이도가 높은 퀘스트(레벨 +5 이상)는 보류하고 레벨이 오르면 다시 평가합니다.
-- 교통수단(비행/배/포탈)은 이 데이터에 없어서 안내하지 않습니다. 이용 가능하다고 가정하지 않습니다.

local STATE_KO = {
  MOVING_TO_QUEST_GIVER = "퀘스트 NPC로 이동",
  ACCEPTING_QUEST = "퀘스트 수락",
  MOVING_TO_NEXT_QUEST_GIVER = "다음 퀘스트 NPC로 이동",
  TRAVELING_TO_PREREQUISITE_REGION = "선행 퀘스트 지역으로 이동",
  COMPLETING_PREREQUISITE_QUEST = "선행 퀘스트 진행",
  RETURNING_TO_TARGET_REGION = "원래 지역으로 복귀",
  MOVING_TO_OBJECTIVE = "목표 지점으로 이동",
  COMPLETING_OBJECTIVE = "목표 수행",
  MOVING_TO_TURN_IN_NPC = "제출 NPC로 이동",
  TURNING_IN_QUEST = "퀘스트 제출",
  MOVING_TO_NEXT_REGION = "다음 지역으로 이동",
}

local planHist = {}       -- 최근 완료한 단계 (최대 3)
local prevSteps = {}
local planDeferred = {}   -- 난이도 때문에 보류한 퀘스트
local planSkippedN = 0
local function SkipKey(g)
  return tostring(g.key) .. ":" .. table.concat(g.quests or {}, ",")
end
local planMode = "normal"
local anchorMap          -- 기준 지역: 퀘스트 갱신/파티 모드 시작 때만 바뀌고, 지역을 옮겨도 유지된다
-- (0.28.0) 기준 지역 자동 전환: 지난 계산에서 이동을 추천한 지역들(지도 번호 -> true).
-- 이 중 한 곳에 도착하면 그 지역을 새 기준으로 삼습니다. 끄기: /kqg 자동기준 (db.autoAnchor == false)
Guide.autoTargets = {}

-- 이동 추천 지역 모으기: [다음 지역] 단계의 지도와 지역 이동 추천(levelZone, 후보 목록).
-- 다른 지역 선행 퀘스트를 하러 가는 중(external)에는 모으지 않습니다(원래 지역으로 돌아와야 하므로).
function Guide.CollectAutoTargets(list, mode, zone, sugg)
  local t = {}
  if mode == "external" then return t end
  for _, g in ipairs(list or {}) do
    if g.state == "MOVING_TO_NEXT_REGION" and g.map and type(g.key) == "string" and string.sub(g.key, 1, 6) == "region" then
      t[g.map] = true
    end
  end
  if zone then t[zone] = true end
  for _, s in ipairs(sugg or {}) do
    if s.map then t[s.map] = true end
  end
  return t
end

-- (0.29.0) 떠나기 전에 받아 가기: 다음에 갈 지역(zones)의 내 레벨 퀘스트 중
--  - 선행 사슬의 첫 퀘스트가 지금 지역(m)에서 시작하면 그 퀘스트("pre"),
--  - 그 퀘스트로 안내하는 퀘스트(브레드크럼)가 지금 지역에서 시작하면 그 퀘스트("bc")를
-- 지금 받을 퀘스트로 고릅니다. 회색이라도 고릅니다(다음 지역 퀘스트를 여는 데 필요하므로).
-- 결과: 퀘스트 번호 -> { target = 다음 지역 퀘스트, map = 다음 지역, why = "pre" | "bc" }. 끄기: /kqg 미리받기
Guide.prepick = {}
function Guide.PrepickTake(out, q, level, m, target, tm, why)
  if out[q] or inLog[q] then return end
  local qr = Q[q]
  local s = qr and qr[F_START]
  if not (s and s[3] and UiMapOf(s[3]) == m) then return end
  if not Basic(q, level) or #PrereqUnmet(qr) > 0 then return end
  if qr[F_PARENT] and not inLog[qr[F_PARENT]] then return end
  if (qr[F_LVL] or 0) - level > Guide.ACCEPT_ABOVE then return end
  out[q] = { target = target, map = tm, why = why }
end
function Guide.FindPrepick(level, m, zones)
  local out = {}
  if not m or db.prepick == false then return out end
  for _, tm in ipairs(zones or {}) do
    if tm ~= m then
      for _, id in ipairs(byMap[tm] or {}) do
        local r = Q[id]
        if Fit(r[F_LVL], level) >= 0.5 and Basic(id, level) then
          if #PrereqUnmet(r) > 0 then
            local ch = Backchain(id, level, 0)
            if ch and #ch > 1 then Guide.PrepickTake(out, ch[1], level, m, id, tm, "pre") end
          else
            for _, b in ipairs(r[F_BCS] or {}) do Guide.PrepickTake(out, b, level, m, id, tm, "bc") end
          end
        end
      end
    end
  end
  return out
end

-- 지도 좌표(%)를 야드로 바꾸는 배율. 지역마다 크기가 달라서 실제 월드 좌표로 보정합니다.
local scaleX, scaleY = 15, 10

local function CalibrateScale(m)
  scaleX, scaleY = 15, 10
  local x1, y1 = WorldXY(m, 0, 50)
  local x2, y2 = WorldXY(m, 100, 50)
  if x1 and x2 then
    local w = math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
    if w > 0 then scaleX = w / 100 end
  end
  local x3, y3 = WorldXY(m, 50, 0)
  local x4, y4 = WorldXY(m, 50, 100)
  if x3 and x4 then
    local h = math.sqrt((x3 - x4) ^ 2 + (y3 - y4) ^ 2)
    if h > 0 then scaleY = h / 100 end
  end
end

local function MapDist(x1, y1, x2, y2)
  return math.sqrt(((x1 - x2) * scaleX) ^ 2 + ((y1 - y2) * scaleY) ^ 2)
end

local function NNOrder(items, getXY, sx, sy, penalty)
  local out, rest = {}, {}
  for i, v in ipairs(items) do rest[i] = v end
  local cx, cy = sx, sy
  while #rest > 0 do
    local bi, bc = 1, 1e18
    for i, v in ipairs(rest) do
      local x, y = getXY(v)
      local c = (cx and x) and MapDist(cx, cy, x, y) or 0
      if penalty then c = c + penalty(v) end
      if c < bc then bi, bc = i, c end
    end
    local v = table.remove(rest, bi)
    out[#out + 1] = v
    local x, y = getXY(v)
    if x then cx, cy = x, y end
  end
  return out
end

local function MkStep(kind, state, key, quests, loc)
  local map = loc and loc[3] and UiMapOf(loc[3])
  return { kind = kind, state = state, key = key, quests = quests, loc = loc, map = map }
end

local function SortedQuests(ids)
  table.sort(ids, function(a, b)
    local la, lb = (Q[a] and Q[a][F_LVL]) or 0, (Q[b] and Q[b][F_LVL]) or 0
    if la ~= lb then return la < lb end
    return a < b
  end)
  return ids
end

-- 한 퀘스트의 "지금 할 행동" 단계 (선행 사슬용)
local function SeqStep(cq)
  local r = Q[cq]
  if not r or DoneC(cq) then return nil end
  if inLog[cq] then
    if logComplete[cq] then
      local e = r[F_END]
      if e and e[3] then return MkStep("turnin", "COMPLETING_PREREQUISITE_QUEST", "pt" .. cq, { cq }, e) end
    else
      local row = OBJ[cq] and OBJ[cq][1]
      if row then
        return MkStep("doing", "COMPLETING_PREREQUISITE_QUEST", "pd" .. cq, { cq }, { "q", cq, row[3], row[4], row[5], (row[1] == "e") and "탐험 지점" or row[2], nil })
      end
      local e = r[F_END]
      if e and e[3] then return MkStep("doing", "COMPLETING_PREREQUISITE_QUEST", "pd" .. cq, { cq }, e) end
    end
    return nil
  end
  local s = r[F_START]
  if s and s[3] then return MkStep("accept", "MOVING_TO_QUEST_GIVER", "pa" .. cq, { cq }, s) end
  return nil
end

-- 현재 지역 퀘스트 중 "다른 지역의 선행 퀘스트"가 필요한 것을 전체 데이터에서 찾는다
local function FindExternal(level, m)
  local t = db.planTarget
  if t then
    local r = Q[t.qid]
    local valid = r and not DoneC(t.qid) and not inLog[t.qid] and not (db.planSkipExt and db.planSkipExt[t.qid])
    if valid and Avail(t.qid, level) then
      if m == t.map then
        valid = false -- 개방 확인됨: 원래 지역에 돌아왔다
      else
        return t, nil -- 개방됨. 복귀만 남음
      end
    end
    if valid then
      local ch = Backchain(t.qid, level, 0)
      if ch and #ch > 1 then return t, ch end
    end
    db.planTarget = nil
  end
  if db.planExternal == false or not m then return nil end
  local best, bch, bf
  for _, id in ipairs(byMap[m] or {}) do
    local r = Q[id]
    local f = Fit(r[F_LVL], level)
    if f >= 0.5 and Basic(id, level) and not (db.planSkipExt and db.planSkipExt[id]) then
      local un = PrereqUnmet(r)
      if #un > 0 then
        local ch = Backchain(id, level, 0)
        if ch and #ch > 1 and #ch <= 4 then
          local fq = Q[ch[1]]
          local fl = inLog[ch[1]] and fq[F_END] or fq[F_START]
          local fm = fl and fl[3] and UiMapOf(fl[3])
          if fm and fm ~= m and (not bf or f > bf) then
            best, bch, bf = id, ch, f
          end
        end
      end
    end
  end
  if best then
    db.planTarget = { qid = best, map = m }
    return db.planTarget, bch
  end
  return nil
end

local function StepDone(g)
  if not g or not g.quests then return false end
  if g.kind == "accept" then
    for _, id in ipairs(g.quests) do
      if not (inLog[id] or DoneC(id)) then return false end
    end
    return true
  elseif g.kind == "doing" then
    for _, id in ipairs(g.quests) do
      if inLog[id] and not logComplete[id] then return false end
    end
    return true
  elseif g.kind == "turnin" then
    for _, id in ipairs(g.quests) do
      if not DoneC(id) then return false end
    end
    return true
  end
  return false
end

local function ClientTurnPoint(qid, m)
  if C_QuestLog and C_QuestLog.GetNextWaypoint then
    local ok, cm, cx, cy = pcall(C_QuestLog.GetNextWaypoint, qid)
    if ok and type(cm) == "number" and type(cx) == "number" and type(cy) == "number" and (not m or cm == m) then
      return cm, cx * 100, cy * 100
    end
  end
  if m and C_QuestLog and C_QuestLog.GetQuestsOnMap then
    local ok, list = pcall(C_QuestLog.GetQuestsOnMap, m)
    if ok and type(list) == "table" then
      for _, q in ipairs(list) do
        if q.questID == qid and type(q.x) == "number" and type(q.y) == "number" then
          return m, q.x * 100, q.y * 100
        end
      end
    end
  end
  return nil
end

-- (0.29.0) 다른 지역 선행을 하러 가는 중에도 미리 받기: 지도 mp에서 받을 미리 받기 퀘스트를
-- NPC별 수락 단계로 묶어 가까운 순서로 돌려줍니다. 고른 퀘스트는 Guide.prepick에도 넣습니다(/kqg debug).
-- pp: FindPrepick 결과, skip: 넣지 않을 퀘스트(선행 사슬)
function Guide.PrepickSteps(pp, mp, skip, sx, sy)
  local hubs, list = {}, {}
  for q, info in pairs(pp) do
    local st = Q[q] and Q[q][F_START]
    if not skip[q] and st and st[3] and UiMapOf(st[3]) == mp then
      Guide.prepick[q] = Guide.prepick[q] or info
      local key = "ppacc" .. st[1] .. st[2]
      local g = hubs[key]
      if not g then
        g = MkStep("accept", "MOVING_TO_NEXT_QUEST_GIVER", key, {}, st)
        g.prepick = info
        hubs[key] = g
        list[#list + 1] = g
      end
      g.quests[#g.quests + 1] = q
    end
  end
  for _, g in ipairs(list) do SortedQuests(g.quests) end
  table.sort(list, function(a, b) return a.key < b.key end)   -- pairs 순서에 흔들리지 않게
  return NNOrder(list, function(g) return g.loc[4], g.loc[5] end, sx, sy)
end

BuildPlan = function(level, m)
  if not m then return end
  CalibrateScale(m)
  db.planSkip = db.planSkip or {}
  local _, px, py = PlayerPos()
  local plan = {}
  planDeferred = {}
  planSkippedN = 0
  planMode = "normal"

  local function Add(g)
    if db.planSkip[SkipKey(g)] then
      planSkippedN = planSkippedN + 1
    else
      plan[#plan + 1] = g
    end
  end

  -- 1) 외부 지역 선행 퀘스트
  local t, chain = FindExternal(level, m)
  if t then
    planMode = "external"
    local seq = {}
    if chain then
      for i = 1, #chain - 1 do
        local g = SeqStep(chain[i])
        if g then
          g.chain = { target = t.qid, map = t.map, idx = i, total = #chain - 1 }
          seq[#seq + 1] = g
        end
      end
    end
    local first = seq[1]
    if first and first.map and first.map ~= m then
      local tr = MkStep("travel", "TRAVELING_TO_PREREQUISITE_REGION", "ptravel" .. t.qid, { chain[1] }, first.loc)
      tr.chain = { target = t.qid, map = t.map, idx = 0, total = #chain - 1 }
      tr.title = "|cffe0701f[이동]|r " .. MapName(first.map) .. "(으)로 이동 (선행 퀘스트: " .. QName(t.qid) .. ")"
      tr.where = "교통수단 정보가 없어 직접 이동하세요. 비행경로/배를 추천하지 않습니다."
      Add(tr)
    end
    -- (0.29.0) 선행을 하러 간 지역에서도 미리 받기: 그 지역의 마지막 선행 단계 뒤에 수락 단계를 넣습니다.
    -- 대상 = 다음에 갈 지역들 + 기준 지역(돌아가서 할 퀘스트의 선행·안내 퀘스트도 그 지역에서 받아 가게)
    local skip = { [t.qid] = true }
    for _, q in ipairs(chain or {}) do skip[q] = true end
    local ppZones = { m }
    for _, z in ipairs(Guide.prepickZones or {}) do ppZones[#ppZones + 1] = z end
    for i, g in ipairs(seq) do
      Add(g)
      local nx = seq[i + 1]
      if g.map and g.map ~= m and not (nx and nx.map == g.map) then
        for _, pg in ipairs(Guide.PrepickSteps(Guide.FindPrepick(level, g.map, ppZones), g.map, skip, g.loc[4], g.loc[5])) do
          Add(pg)
        end
      end
    end
    if m ~= t.map or #seq > 0 then
      local tl = Q[t.qid][F_START]
      if tl and tl[3] then
        local rt = MkStep("travel", "RETURNING_TO_TARGET_REGION", "pret" .. t.qid, { t.qid }, tl)
        rt.chain = { target = t.qid, map = t.map, idx = -1, total = chain and (#chain - 1) or 0 }
        rt.title = "|cffe0701f[복귀]|r " .. MapName(t.map) .. "(으)로 돌아가 " .. QName(t.qid) .. " 수락"
        rt.where = "교통수단 정보가 없어 직접 이동하세요."
        Add(rt)
      end
    end
    -- (0.29.0) 돌아온 기준 지역에서 받을 미리 받기 퀘스트 (평소 수락 목록은 이 모드에서 만들지 않으므로)
    if chain then
      local tl = Q[t.qid][F_START]
      for _, pg in ipairs(Guide.PrepickSteps(Guide.prepick, m, skip, tl and tl[4], tl and tl[5])) do Add(pg) end
    end
  end

  -- 2) 완료했지만 제출하지 않은 퀘스트 (이 지역)
  local turn, turnOrder = {}, {}
  for qid in pairs(inLog) do
    if logComplete[qid] then
      local r = Q[qid]
      local e = r and r[F_END]
      -- 이 서버가 알려주는 실제 제출 위치를 우선 사용 (데이터의 NPC가 다를 수 있음)
      local cm, cx, cy = ClientTurnPoint(qid, m)
      local loc, key
      if cm and cm == m then
        local nm = "퀘스트 제출 NPC"
        if e and e[3] and UiMapOf(e[3]) == m and MapDist(cx, cy, e[4], e[5]) <= 60 then nm = e[6] or nm end
        loc = { "w", qid, nil, cx, cy, nm, nil }
        key = "tw" .. qid
      elseif e and e[3] and UiMapOf(e[3]) == m then
        loc = e
        key = "t" .. e[1] .. e[2]
      end
      if loc then
        local g = turn[key]
        if not g then
          g = MkStep("turnin", "MOVING_TO_TURN_IN_NPC", key, {}, loc)
          g.map = m
          turn[key] = g
          turnOrder[#turnOrder + 1] = g
        end
        g.quests[#g.quests + 1] = qid
      end
    end
  end
  -- 2~3) NPC 방문 경로: 완료한 퀘스트 제출과 새 퀘스트 수락을 한 번에 묶어, 가까운 곳부터 이어서 방문한다
  local stops = {}
  for _, g in ipairs(turnOrder) do
    SortedQuests(g.quests)
    stops[#stops + 1] = g
  end
  if planMode ~= "external" or not chain then
    local hubs = {}
    for _, id in ipairs(byMap[m] or {}) do
      -- 목록(Compute 3번)과 같은 조건(Avail)으로 받을 퀘스트를 고릅니다. (0.29.0) 미리 받기 퀘스트도 넣습니다
      if Avail(id, level) or Guide.prepick[id] then
        local st = Q[id][F_START]
        local key = "acc" .. st[1] .. st[2]
        local g = hubs[key]
        if not g then
          g = MkStep("accept", "MOVING_TO_QUEST_GIVER", key, {}, st)
          hubs[key] = g
          stops[#stops + 1] = g
        end
        g.quests[#g.quests + 1] = id
        if Guide.prepick[id] and not g.prepick then g.prepick = Guide.prepick[id] end
      end
    end
    for _, g in pairs(hubs) do
      SortedQuests(g.quests)
      local easy = g.prepick and true or false   -- 미리 받기는 뒤로 미루지 않음
      for _, id in ipairs(g.quests) do
        if (Q[id][F_LVL] or 0) - level < Guide.HARD_ABOVE then easy = true end
      end
      g.hardOnly = not easy
    end
  end
  local partyOn = KQG.PartyRank and KQG.PartyHasOrder and KQG.PartyHasOrder()
  -- 마을이거나 제출 NPC 근처에 있으면 완료한 퀘스트 제출을 가장 먼저 처리한다
  local resting = IsResting and IsResting() or false
  local near, far = {}, {}
  for _, g in ipairs(stops) do
    local d = (g.kind == "turnin" and px) and MapDist(px, py, g.loc[4], g.loc[5]) or nil
    if d and (d <= 400 or (resting and d <= 900)) then near[#near + 1] = g else far[#far + 1] = g end
  end
  near = NNOrder(near, function(g) return g.loc[4], g.loc[5] end, px, py)
  local fx, fy = px, py
  if #near > 0 then fx, fy = near[#near].loc[4], near[#near].loc[5] end
  far = NNOrder(far, function(g) return g.loc[4], g.loc[5] end, fx, fy, function(g)
    if g.kind == "turnin" then return -300 end
    return g.hardOnly and 600 or 0
  end)
  stops = {}
  for _, g in ipairs(near) do stops[#stops + 1] = g end
  for _, g in ipairs(far) do stops[#stops + 1] = g end
  if partyOn then
    -- 파티 퀘스트: 가장 진행도가 낮은 파티원의 순서를 그대로 따른다
    local dec = {}
    for i, g in ipairs(stops) do
      local best = 999
      for _, qid in ipairs(g.quests or {}) do
        local rk = KQG.PartyRank(qid)
        if rk and rk < best then best = rk end
      end
      dec[i] = { g = g, r = best, i = i }
    end
    table.sort(dec, function(a, b) if a.r ~= b.r then return a.r < b.r end return a.i < b.i end)
    stops = {}
    for _, e in ipairs(dec) do stops[#stops + 1] = e.g end
  end
  local lastX, lastY = px, py
  for i, g in ipairs(stops) do
    if g.kind == "accept" and (i > 1 or #plan > 0) then g.state = "MOVING_TO_NEXT_QUEST_GIVER" end
    Add(g)
    lastX, lastY = g.loc[4], g.loc[5]
  end

  -- 4) 수행 계획: 목표가 가까운 퀘스트를 한 구간으로 묶고, 거리와 난이도로 순서를 정한다
  local items = {}
  for qid in pairs(inLog) do
    if not logComplete[qid] and OBJ[qid] then
      local r = Q[qid]
      local pts = {}
      for _, o in ipairs(OBJ[qid]) do
        if UiMapOf(o[3]) == m then pts[#pts + 1] = { x = o[4], y = o[5], name = (o[1] == "e") and "탐험 지점" or o[2], area = o[3] } end
      end
      if #pts > 0 then
        local ql = r[F_LVL] or 0
        local hard = (ql - level >= Guide.HARD_ABOVE) or logElite[qid]
        if KQG.PartyActive and KQG.PartyActive() then hard = false end
        if hard and not (db.planForce and db.planForce[qid]) then
          planDeferred[#planDeferred + 1] = qid
        else
          items[#items + 1] = { qid = qid, pts = pts, fit = Fit(ql, level) }
        end
      end
    end
  end
  -- 가까운 목표끼리 같은 구간으로 묶기 (연결 요소)
  local CL = 150
  local used, clusters = {}, {}
  for i = 1, #items do
    if not used[i] then
      local comp, queue = {}, { i }
      used[i] = true
      while #queue > 0 do
        local a = table.remove(queue)
        comp[#comp + 1] = items[a]
        for j = 1, #items do
          if not used[j] then
            local near = false
            for _, p in ipairs(items[a].pts) do
              for _, q2 in ipairs(items[j].pts) do
                if MapDist(p.x, p.y, q2.x, q2.y) <= CL then near = true break end
              end
              if near then break end
            end
            if near then used[j] = true queue[#queue + 1] = j end
          end
        end
      end
      clusters[#clusters + 1] = comp
    end
  end
  local cl = {}
  for ci, comp in ipairs(clusters) do
    local sx, sy, n, fit = 0, 0, 0, 0
    for _, it in ipairs(comp) do
      local p = it.pts[1]
      sx, sy, n, fit = sx + p.x, sy + p.y, n + 1, fit + it.fit
    end
    local cx, cy = sx / n, sy / n
    local rep, rd = nil, 1e18
    for _, it in ipairs(comp) do
      for _, p in ipairs(it.pts) do
        local dd = MapDist(cx, cy, p.x, p.y)
        if dd < rd then rep, rd = p, dd end
      end
    end
    local ids = {}
    for _, it in ipairs(comp) do ids[#ids + 1] = it.qid end
    SortedQuests(ids)
    local g = MkStep("doing", "MOVING_TO_OBJECTIVE", "exec" .. ids[1], ids, { "q", ids[1], rep.area, rep.x, rep.y, rep.name, nil })
    g.avgFit = fit / n
    cl[#cl + 1] = g
  end
  -- 각 구간의 제출 NPC (같은 NPC끼리 묶음)
  for ci, g in ipairs(cl) do
    local tg, tOrder = {}, {}
    for _, qid in ipairs(g.quests) do
      local e = Q[qid][F_END]
      if e and e[3] and UiMapOf(e[3]) == m then
        local key = "t" .. e[1] .. e[2] .. "@" .. ci
        local x = tg[key]
        if not x then
          x = MkStep("turnin", "MOVING_TO_TURN_IN_NPC", key, {}, e)
          tg[key] = x
          tOrder[#tOrder + 1] = x
        end
        x.quests[#x.quests + 1] = qid
      end
    end
    g.turns = tOrder
  end
  -- 수행 구간과 제출을 한 경로로 정한다: 구간을 끝내야 그 제출이 후보가 되고,
  -- 이미 멀리 나와 있으면 제출하러 되돌아가지 않고 가까운 다음 구간부터 처리한다.
  local pendDo, pendTurn = {}, {}
  for _, g in ipairs(cl) do pendDo[#pendDo + 1] = g end
  local cx, cy = lastX, lastY
  local function Cost(g, bonus)
    local d = 0
    if cx and cy and g.loc[4] and g.loc[5] then d = MapDist(cx, cy, g.loc[4], g.loc[5]) end
    if partyOn then
      local best = 999
      for _, qid in ipairs(g.quests or {}) do
        local rk = KQG.PartyRank(qid)
        if rk and rk < best then best = rk end
      end
      return best * 1000 + d + bonus
    end
    return d + bonus
  end
  while #pendDo > 0 or #pendTurn > 0 do
    local pick, kind, bc = nil, nil, 1e18
    for i, g in ipairs(pendDo) do
      local c = Cost(g, (1 - g.avgFit) * 400)
      if c < bc then pick, kind, bc = i, "do", c end
    end
    for i, g in ipairs(pendTurn) do
      local c = Cost(g, -150)
      if c < bc then pick, kind, bc = i, "turn", c end
    end
    local g
    if kind == "do" then
      g = table.remove(pendDo, pick)
      for _, x in ipairs(g.turns or {}) do pendTurn[#pendTurn + 1] = x end
    else
      g = table.remove(pendTurn, pick)
    end
    Add(g)
    cx, cy = g.loc[4], g.loc[5]
  end

  -- 5) 할 일이 없으면 다음 지역 (남은 조건을 확인한 뒤)
  if #plan == 0 and planMode ~= "external" then
    local pending = 0
    for qid in pairs(inLog) do pending = pending + 1 end
    local target
    for _, z in ipairs(zoneRank) do
      if z.map ~= m and z.score >= 6 then target = z.map break end
    end
    if target then
      local bestq, bf2
      for _, id in ipairs(byMap[target] or {}) do
        if Avail(id, level) then
          local f = Fit(Q[id][F_LVL], level)
          if not bf2 or f > bf2 then bestq, bf2 = id, f end
        end
      end
      if bestq then
        local g = MkStep("travel", "MOVING_TO_NEXT_REGION", "region" .. target, { bestq }, Q[bestq][F_START])
        g.title = "|cffe0701f[다음 지역]|r " .. MapName(target) .. "(으)로 이동"
        g.where = "이 지역의 퀘스트를 모두 마쳤습니다." .. (pending > 0 and (" (진행 중 퀘스트 " .. pending .. "개는 다른 지역에서 제출/수행)") or "")
          .. " 교통수단 정보가 없어 직접 이동하세요."
        Add(g)
      end
    end
  end

  -- 완료 기록: 이전 계획에 있던 단계 중 실제로 끝난 것
  local keys = {}
  for _, g in ipairs(plan) do keys[g.key] = true end
  for _, g in ipairs(prevSteps) do
    if not keys[g.key] and StepDone(g) and not db.planSkip[SkipKey(g)] then
      table.insert(planHist, g)
      while #planHist > 3 do table.remove(planHist, 1) end
    end
  end
  prevSteps = plan

  if #plan > 0 then
    for _, g in ipairs(plan) do
      if g.map then
        local d, b = Measure(g.map, g.loc[4], g.loc[5])
        g.dist, g.bearing = d, b
      end
    end
    steps = plan
  end
end

local function StateOf(g)
  local st = g.state or "MOVING_TO_QUEST_GIVER"
  local d = g.dist
  if st == "MOVING_TO_QUEST_GIVER" or st == "MOVING_TO_NEXT_QUEST_GIVER" then
    if d and d <= 30 then st = "ACCEPTING_QUEST" end
  elseif st == "MOVING_TO_OBJECTIVE" then
    if d and d <= 60 then st = "COMPLETING_OBJECTIVE" end
  elseif st == "MOVING_TO_TURN_IN_NPC" then
    if d and d <= 30 then st = "TURNING_IN_QUEST" end
  end
  return st
end

local function Compute()
  lastCompute = GetTime and GetTime() or 0
  dirty = false
  doneCache = {}
  chainCache = {}
  ReadLog()
  local level = UnitLevel("player") or 1
  local m, ppx, ppy = PlayerPos()
  Guide.chainPos = { map = m, x = ppx, y = ppy }   -- (0.29.0) 선행 후보 중 가까운 것 고르기(Guide.ChainCost)
  if not m and steps and #steps > 0 then
    -- 지역을 넘어가는 로딩 중에는 위치를 읽을 수 없으므로 기존 안내를 그대로 유지한다
    dirty = true
    return
  end
  curMap = m
  -- 기준 지역: 처음 한 번 현재 지역으로 잡고, 이후에는 갱신 버튼/파티 모드 시작 때만 바꾼다
  if not anchorMap and m then anchorMap = m end
  -- (0.28.0) 이동을 추천한 지역에 도착하면 그 지역을 새 기준으로 삼는다 (파티 퀘스트 중에는 파티 기능이 정함)
  if anchorMap and m and m ~= anchorMap and Guide.autoTargets[m] and db.autoAnchor ~= false
    and not (KQG.PartyActive and KQG.PartyActive()) then
    anchorMap = m
    Guide.autoTargets = {}
    db.planTarget = nil
    prevSteps = {}
    -- 화살표·SPF 안내는 단계 key가 바뀌므로 다음 UpdateArrow에서 새로 걸린다 (지역 이동 때 spfNext도 이미 0)
    Print("|cff4a9fc7[기준 지역]|r 추천 지역 " .. MapName(m) .. "에 도착해서 이 지역을 새 기준으로 안내합니다. (끄기: /kqg 자동기준)")
  end
  if anchorMap then m = anchorMap end
  steps, progress, suggestions, locked, noloc = {}, {}, {}, {}, {}

  -- 1) 지역 평가: 현재 지역이 최우선. 다른 지역은 "이동 추천" 안내에만 쓴다.
  local logHere = {}
  for qid in pairs(inLog) do
    local r = Q[qid]
    if r then
      local maps = {}
      local e = r[F_END]
      if e and e[3] and UiMapOf(e[3]) then maps[UiMapOf(e[3])] = true end
      if OBJ[qid] then
        for _, o in ipairs(OBJ[qid]) do
          local om = UiMapOf(o[3])
          if om then maps[om] = true end
        end
      end
      for mp in pairs(maps) do logHere[mp] = (logHere[mp] or 0) + 1 end
    end
  end
  local function ZoneWork(mp)
    local sc, good, chains = 0, 0, 0
    for _, id in ipairs(byMap[mp] or {}) do
      local f = Fit(Q[id][F_LVL], level)
      if f >= 0.5 and Avail(id, level) then
        sc = sc + f
        good = good + 1
        if #NextChain(id) > 0 then
          chains = chains + 1
          sc = sc + ChainBonus(id, level) * 0.5
        end
      end
    end
    return sc, good, chains
  end
  zoneRank = {}
  local seenMap = {}
  for mp in pairs(byMap) do seenMap[mp] = true end
  for mp in pairs(logHere) do seenMap[mp] = true end
  for mp in pairs(seenMap) do
    local work, good, chains = ZoneWork(mp)
    local score = work + (logHere[mp] or 0)
    if score > 0 then zoneRank[#zoneRank + 1] = { map = mp, score = score, good = good, chains = chains } end
  end
  table.sort(zoneRank, function(a, b) return a.score > b.score end)
  zoneEval = { score = 0, good = 0, text = "알 수 없음", level = "none" }
  levelZone = nil
  if m then
    local work, good, chains = ZoneWork(m)
    local score = work + (logHere[m] or 0)
    -- 이 지역 퀘스트들의 평균 레벨 (너무 낮거나 높은지 판단)
    local sum, n = 0, 0
    for _, id in ipairs(byMap[m] or {}) do
      local r = Q[id]
      if (r[F_LVL] or 0) > 0 and Bit(r[F_RACES], playerRaceBit) and Bit(r[F_CLASSES], playerClassBit) then
        sum = sum + r[F_LVL]
        n = n + 1
      end
    end
    local avg = n > 0 and sum / n or level
    zoneEval = { score = score, good = good, chains = chains, logN = logHere[m] or 0, avg = avg }
    if n == 0 and (logHere[m] or 0) == 0 then
      -- 이 지역 퀘스트 정보가 데이터에 없으면 "퀘스트가 없다"고 단정하지 않고 데이터 부족으로 표시
      zoneEval.level, zoneEval.text = "nodata", "데이터 부족 (이 지역 퀘스트 정보 없음)"
    elseif score >= 6 or good >= 4 then
      zoneEval.level, zoneEval.text = "ok", "적정 레벨 / 퀘스트 충분"
    elseif score >= 3 then
      zoneEval.level, zoneEval.text = "mid", "진행 가능한 퀘스트 있음"
    else
      zoneEval.level = "low"
      if avg < level - 6 then zoneEval.text = "경험치 효율 낮음 (퀘스트 레벨이 낮음)"
      elseif avg > level + 4 then zoneEval.text = "퀘스트 레벨이 높음"
      else zoneEval.text = "수행할 퀘스트 부족" end
      -- 이동 추천: 현재 지역이 부족할 때만, 확실히 나은 지역이 있을 때만
      for _, z in ipairs(zoneRank) do
        if z.map ~= m and z.score >= math.max(8, score * 2) and z.good >= 3 then
          levelZone = z.map
          break
        end
      end
    end
  end

  -- 2) 진행 중 / 제출
  for qid in pairs(inLog) do
    local r = Q[qid]
    if r then
      local e = r[F_END]
      if logComplete[qid] and e and e[3] then
        local em = UiMapOf(e[3])
        if em and (not m or em == m) then
          local key = "t" .. e[1] .. e[2]
          local g
          for _, s in ipairs(steps) do if s.key == key then g = s break end end
          if not g then
            g = { kind = "turnin", key = key, loc = e, map = em, quests = {} }
            table.insert(steps, g)
          end
          table.insert(g.quests, qid)
        end
      elseif not logComplete[qid] then
        table.insert(progress, qid)
        local best
        for _, s in ipairs(ObjectiveSteps(qid, level)) do
          if s.map == m then
            local d = Measure(s.map, s.loc[4], s.loc[5])
            if not best or (d and (not best.d or d < best.d)) then
              s.d = d
              best = s
            end
          end
        end
        if not best then
          local endMap = r[F_END] and r[F_END][3] and UiMapOf(r[F_END][3])
          if not OBJ[qid] or not endMap or endMap == m then table.insert(noloc, qid) end
        end
        if best then
          best.key = "d" .. qid
          best.quests = { qid }
          table.insert(steps, best)
        end
      end
    end
  end

  -- 3) 받을 수 있는 퀘스트: 레벨링 지역 + 현재 지역
  local pool = {}
  if m then table.insert(pool, m) end
  local hubs = {}
  for _, mp in ipairs(pool) do
    for _, id in ipairs(byMap[mp] or {}) do
      if Avail(id, level) then
        local r = Q[id]
        local s = r[F_START]
        local key = "a" .. s[1] .. s[2]
        local g = hubs[key]
        if not g then
          g = { kind = "accept", key = key, loc = s, map = mp, quests = {} }
          hubs[key] = g
          table.insert(steps, g)
        end
        table.insert(g.quests, id)
      end
    end
  end

  -- 4) 점수 계산
  for _, g in ipairs(steps) do
    local d, b = Measure(g.map, g.loc[4], g.loc[5])
    g.dist, g.bearing = d, b
    local bestFit, bestChain, bestTier = 0, 0, 4
    for _, id in ipairs(g.quests) do
      local r = Q[id]
      local f = Fit(r[F_LVL], level)
      if f > bestFit then bestFit = f end
      local cb = ChainBonus(id, level)
      if cb > bestChain then bestChain = cb end
      -- 추천 우선순위: 2=새로 받을 적정 레벨 퀘스트, 3=이어지는 체인(선행을 마친 후속), 4=그 밖의 연계 퀘스트
      local hasPre = (r[F_PREG] and #r[F_PREG] > 0) or (r[F_PRES] and #r[F_PRES] > 0)
      local tier = 4
      if f >= 0.5 then tier = hasPre and 3 or 2 end
      if tier < bestTier then bestTier = tier end
    end
    g.fit, g.chain, g.tier = bestFit, bestChain, bestTier
    local near = (d and d <= 120 and bestFit >= 0.5) and true or false
    if g.kind == "turnin" then
      g.score = 400                                  -- 1순위: 이미 받은 퀘스트 완료
    elseif g.kind == "doing" then
      g.score = 300 + 50 * bestFit                   -- 1순위: 이미 받은 퀘스트 진행
    else
      local base = (bestTier == 2) and 200 or (bestTier == 3) and 150 or 80
      g.score = base + 20 * bestFit + 10 * bestChain + (near and 30 or 0)
    end
    if d then g.score = g.score - math.min(d, 3000) / 100 end
    table.sort(g.quests, function(a, b2)
      local la, lb = Q[a][F_LVL] or 0, Q[b2][F_LVL] or 0
      if la ~= lb then return la < lb end
      return a < b2
    end)
  end
  table.sort(steps, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.key < b.key
  end)

  -- 5) 잠긴 퀘스트: 선행이 필요한 퀘스트의 시작점 안내 (다른 지역 포함)
  local seenStart = {}
  local cand = {}
  for _, id in ipairs(m and byMap[m] or {}) do
    local r = Q[id]
    if Basic(id, level) and Fit(r[F_LVL], level) >= 0.5 and #PrereqUnmet(r) > 0 then
      cand[#cand + 1] = id
    end
  end
  table.sort(cand, function(a, b2) return Fit(Q[a][F_LVL], level) > Fit(Q[b2][F_LVL], level) end)
  for _, id in ipairs(cand) do
    if #locked >= 3 then break end
    local ch = Backchain(id, level, 0)
    if ch and #ch > 1 then
      local first = ch[1]
      if not seenStart[first] then
        seenStart[first] = true
        local fr = Q[first]
        local where = fr[F_START] and fr[F_START][3] and UiMapOf(fr[F_START][3])
        table.insert(locked, { quest = id, chain = ch, first = first, map = where })
      end
    end
  end

  -- 6) 다른 지역 추천(보조): 이동 추천이 나왔을 때만 후보를 보여 준다. 현재 지역 목록은 그대로 둔다.
  if levelZone then
    for _, z in ipairs(zoneRank) do
      if z.map ~= m and z.score >= math.max(8, (zoneEval.score or 0) * 2) and z.good >= 3 then
        table.insert(suggestions, { map = z.map, n = math.floor(z.score) })
        if #suggestions >= 3 then break end
      end
    end
  end

  -- (0.29.0) 떠나기 전에 받아 가기: 다음에 갈 지역 = 지역 순위에서 점수 6 이상인 다른 지역 3곳
  --   ([다음 지역] 단계는 이 중 첫 번째를 고름), 이동 추천 지역, 후보 목록
  do
    local zones = {}
    for _, z in ipairs(zoneRank) do
      if z.map ~= m and z.score >= 6 then
        zones[#zones + 1] = z.map
        if #zones >= 3 then break end
      end
    end
    if levelZone then zones[#zones + 1] = levelZone end
    for _, s in ipairs(suggestions) do zones[#zones + 1] = s.map end
    Guide.prepickZones = zones   -- (0.29.0) 선행을 하러 간 지역의 미리 받기에도 씀(BuildPlan)
    Guide.prepick = Guide.FindPrepick(level, m, zones)
  end
  BuildPlan(level, m)
  -- 이번에 이동을 추천한 지역 (파티원 단계로 바꾸기 전, 내 계산 기준)
  Guide.autoTargets = Guide.CollectAutoTargets(steps, planMode, levelZone, suggestions)
  if KQG.PartyFollowSteps then
    local okF, fs = pcall(KQG.PartyFollowSteps)
    if okF and fs and #fs > 0 then
      for _, g in ipairs(fs) do
        if g.map then
          local d, b = Measure(g.map, g.loc[4], g.loc[5])
          g.dist, g.bearing = d, b
        end
      end
      steps = fs
      planDeferred = {}
    end
  end

  if pinned then
    for i, g in ipairs(steps) do
      if g.key == pinned then
        table.remove(steps, i)
        table.insert(steps, 1, g)
        break
      end
    end
  end
end

-- 문구 --------------------------------------------------------------------------

QName = function(id)
  local r = Q[id]
  if not r then
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
      local ok, t = pcall(C_QuestLog.GetTitleForQuestID, id)
      if ok and type(t) == "string" and t ~= "" then return t end
    end
    return "퀘스트 " .. id
  end
  local lv = r[F_LVL]
  if lv and lv > 0 then return r[F_NAME] .. " (Lv" .. lv .. ")" end
  return r[F_NAME]
end

local function Coord(loc)
  return string.format("%.0f, %.0f", loc[4] or 0, loc[5] or 0)
end

local function StepTitle(g)
  if g.title then return g.title end
  local first = Q[g.quests[1]] or { [F_NAME] = QName(g.quests[1]) }
  local more = #g.quests - 1
  local tag
  if g.kind == "turnin" then tag = "|cff2fa26a[제출]|r "
  elseif g.kind == "doing" then tag = "|cff2f86c8[수행]|r "
  else tag = "|cffd18a00[수락]|r " end
  if g.chain then tag = tag .. "|cff4a9fc7[연계]|r " end
  if g.prepick then tag = tag .. "|cff10d0a0[미리 받기]|r " end
  local t = tag .. first[F_NAME]
  if more > 0 then t = t .. " 외 " .. more .. "개" end
  for _, id in ipairs(g.quests) do
    if logElite[id] then t = t .. " |cffe0701f[정예]|r" break end
  end
  return t
end

-- SPF가 계산한 예상 이동 시간 (첫 단계만, 3초 캐시)
local etaKey, etaVal, etaAt = nil, nil, 0
local function SPFEta(g)
  local sp = rawget(_G, "ShortestPathForever")
  local api = type(sp) == "table" and sp.API or nil
  if not (api and api.Estimate and g and g.map and g.loc) then return nil end
  local key = tostring(g.map) .. ":" .. tostring(g.loc[4]) .. ":" .. tostring(g.loc[5])
  if key == etaKey and GetTime() - etaAt < 3 then return etaVal end
  etaKey, etaAt, etaVal = key, GetTime(), nil
  pcall(function()
    local m, px, py = PlayerPos()
    if not (m and px) then return end
    local sec = api.Estimate(m, px / 100, py / 100, g.map, g.loc[4] / 100, g.loc[5] / 100)
    if type(sec) == "number" then etaVal = sec end
  end)
  return etaVal
end

local function EtaText(sec)
  if not sec then return "" end
  if sec >= 90 then return string.format("  약 %d분", math.floor(sec / 60 + 0.5)) end
  return string.format("  약 %d초", math.floor(sec + 0.5))
end

local function StepWhere(g)
  if g.where then return g.where end
  local nm = g.loc[6]
  if not nm or nm == "" then nm = "목표 지역" end
  local t = nm .. " (" .. Coord(g.loc) .. ")"
  if g.map and g.map ~= curMap then
    t = t .. "  |cffff9966" .. MapName(g.map) .. " 이동 필요|r"
  elseif g.dist then
    t = t .. "  " .. math.floor(g.dist) .. "야드"
  end
  if g == steps[1] then t = t .. EtaText(SPFEta(g)) end
  return t
end

-- 완료 후 이어지는 다음 퀘스트(체인) 한 줄
local function NextLine(g)
  if not g or not g.quests[1] then return nil end
  local r = Q[g.quests[1]]
  if not r then return nil end
  local nx = r[F_NEXT]
  if not nx or not Q[nx] then return nil end
  local nr = Q[nx]
  local s = nr[F_START]
  local where = ""
  if s and s[6] then where = " - " .. s[6] end
  local mp = s and s[3] and UiMapOf(s[3])
  if mp and mp ~= curMap then where = where .. " (" .. MapName(mp) .. ")" end
  return "다음 퀘스트: " .. QName(nx) .. where
end

-- 화살표 --------------------------------------------------------------------------

local lastWpKey
local arrivedKey
local zoneChangeAt = 0   -- 지역 이동(로딩) 직후 안내가 끊기지 않게 다시 거는 시간 창
local function SetWaypoint(g)
  if not (db.waypoint ~= false and g and C_Map and C_Map.SetUserWaypoint and UiMapPoint) then return end
  pcall(function()
    local pt = UiMapPoint.CreateFromCoordinates(g.map, g.loc[4] / 100, g.loc[5] / 100)
    C_Map.SetUserWaypoint(pt)
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
      C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
  end)
end

local function BuildArrow()
  local a = CreateFrame("Frame", "KQGArrow", UIParent)
  a:SetWidth(56)
  a:SetHeight(70)
  a:SetMovable(true)
  a:EnableMouse(true)
  a:SetClampedToScreen(true)
  a:RegisterForDrag("LeftButton")
  a:SetScript("OnDragStart", function(s) s = s or this; s:StartMoving() end)
  a:SetScript("OnDragStop", function(s)
    s = s or this
    s:StopMovingOrSizing()
    local p, _, rp, x, y = s:GetPoint()
    db.arrowPos = { p, rp, x, y }
  end)
  if db.arrowPos then
    a:SetPoint(db.arrowPos[1], UIParent, db.arrowPos[2], db.arrowPos[3], db.arrowPos[4])
  else
    a:SetPoint("TOP", UIParent, "TOP", 0, -160)
  end
  a.tex = a:CreateTexture(nil, "ARTWORK")
  a.tex:SetWidth(48)
  a.tex:SetHeight(48)
  a.tex:SetPoint("TOP", a, "TOP", 0, 0)
  a.tex:SetTexture("Interface\\Minimap\\ROTATING-MINIMAPGUIDEARROW")
  a.text = a:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  a.text:SetPoint("TOP", a.tex, "BOTTOM", 0, -2)
  a:Hide()
  arrow = a
end

-- Shortest Path Forever 연동 (공개 API: ShortestPathForever.API) ---------------------
local SPF_OWNER = "KQuestGuide"
local spfKey, spfNext = nil, 0
local function SPFApi()
  local s = rawget(_G, "ShortestPathForever")
  return type(s) == "table" and type(s.API) == "table" and s.API or nil
end
local function SPFOwned()
  local api = SPFApi()
  if not api or not api.CurrentStop then return false end
  local ok, cur = pcall(api.CurrentStop, SPF_OWNER)
  return ok and cur ~= nil
end
local function SPFArrowOn()
  local d = rawget(_G, "ShortestPathForeverDB")
  return not (type(d) == "table" and d.arrow == false)
end
local KIND_KO = { accept = "수락", turnin = "제출", doing = "수행" }
local function SPFNavigate(g)
  local api = SPFApi()
  if not api or not api.NavigateRoute then return false end
  local ok, res = pcall(function()
    -- 다른 애드온이나 사용자의 길찾기가 진행 중이면 덮어쓰지 않습니다.
    if api.Active and api.Active() and not SPFOwned() then return false end
    local qid = g.quests and g.quests[1]
    local title = (KIND_KO[g.kind] or "이동") .. ": " .. (qid and QName(qid) or "")
    if g.loc[6] then title = title .. " - " .. g.loc[6] end
    local stop = { map = g.map, x = g.loc[4] / 100, y = g.loc[5] / 100, title = title, hold = true }
    if g.quests and (g.kind == "doing" or g.kind == "turnin") then
      local ids = {}
      for _, id in ipairs(g.quests) do if type(id) == "number" and id >= 1 then ids[#ids + 1] = id end end
      if #ids > 0 then stop.questIDs = ids end
    end
    return api.NavigateRoute(SPF_OWNER, { stop })
  end)
  return ok and res == true
end
local function SPFCancel()
  local api = SPFApi()
  if api and api.Cancel and SPFOwned() then pcall(api.Cancel, SPF_OWNER) end
end

local function UpdateArrow()
  if not arrow then return end
  if db.guideOff then
    -- 안내 정지: SPF 경로/내장 핀/화살표를 모두 끄고 다시 시작할 때까지 만들지 않음
    if SPFOwned() then SPFCancel() end
    if spfKey or lastWpKey then
      spfKey, lastWpKey = nil, nil
      if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
    end
    arrow:Hide()
    return
  end
  if forced and forced.key and string.sub(forced.key, 1, 4) == "preq" and forced.quests[1]
    and (inLog[forced.quests[1]] or DoneC(forced.quests[1])) then
    forced = nil
  end
  local g = forced or steps[1]
  local spfOwned = SPFOwned()
  if g and g.map and g.loc then
    local key = tostring(g.map) .. ":" .. tostring(g.loc[4]) .. ":" .. tostring(g.loc[5])
    if SPFApi() and db.spf ~= false then
      -- 지역을 넘어가는 동안 SPF 경로가 끊기면 같은 목적지로 다시 건다.
      if key == spfKey and not spfOwned and GetTime() - zoneChangeAt < 40 then spfKey = nil end
      -- Shortest Path Forever가 있으면 길찾기(도보/비행/배/포털)와 미니맵 경로를 그쪽에 맡깁니다.
      if key ~= spfKey and GetTime() >= spfNext then
        if SPFNavigate(g) then
          spfKey = key
          spfOwned = true
        else
          spfNext = GetTime() + 2
        end
      end
    elseif db.waypoint ~= false then
      if key == lastWpKey and GetTime() - zoneChangeAt < 40 and C_Map and C_Map.GetUserWaypoint then
        local okw, wp = pcall(C_Map.GetUserWaypoint)
        if okw and not wp then lastWpKey = nil end
      end
      if key ~= lastWpKey then
        lastWpKey = key
        SetWaypoint(g)
      end
    end
  elseif spfOwned and not g then
    SPFCancel()
    spfKey, spfOwned = nil, false
  end
  -- 수락 지점에 도착하면 무엇을 해야 하는지 화면 중앙에 한 번 알려 준다
  if g and g.kind == "accept" and g.map and g.loc and db.arriveNotice ~= false then
    local dd = Measure(g.map, g.loc[4], g.loc[5])
    local ak = tostring(g.key) .. ":" .. tostring(g.quests and g.quests[1])
    if dd and dd <= 40 and ak ~= arrivedKey then
      arrivedKey = ak
      local npc = g.loc[6]
      local l1 = "도착!  " .. ((npc and npc ~= "") and (npc .. "에게 말을 걸어 퀘스트를 수락하세요") or "퀘스트를 수락하세요")
      local l2 = "「" .. QName(g.quests[1]) .. "」"
      local c = g.chain
      if c and c.idx and c.idx > 0 then
        l2 = l2 .. "   ◆ 연계 퀘스트 " .. c.idx .. "/" .. c.total .. " (" .. MapName(c.map) .. "의 「" .. QName(c.target) .. "」를 열기 위해)"
      end
      if KQG.Banner then pcall(KQG.Banner, l1, l2, 6)
      elseif UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage(l1 .. " " .. l2, 1, 0.82, 0.2, 1, 5) end
    end
  end
  if not g or not g.map then
    arrow:Hide()
    return
  end
  -- SPF가 우리 목적지를 안내 중이면 SPF 화살표가 대신하므로 우리 화살표는 숨깁니다.
  if (spfOwned and SPFArrowOn()) or not db.arrow then
    arrow:Hide()
    return
  end
  local d, b = Measure(g.map, g.loc[4], g.loc[5])
  if not d then
    arrow:Hide()
    return
  end
  g.dist, g.bearing = d, b
  local facing = (GetPlayerFacing and GetPlayerFacing()) or 0
  local rel = b + facing
  if arrow.tex.SetRotation then arrow.tex:SetRotation(-rel) end
  arrow.text:SetText(math.floor(d) .. "야드" .. (forced and forced.label and ("\n" .. forced.label) or ""))
  arrow:Show()
end

-- 창 ------------------------------------------------------------------------------

local ROWS = 5
local DROWS = 4
local drows = {}
local LROWS = 4
local lrows = {}
local LayoutFrame
local rows = {}

-- 지금 무엇을 하러 가는 중인지 한 문장으로
local function ActionText(g)
  if not g or g.kind == "travel" or not g.quests or not g.quests[1] then return nil end
  local npc = g.loc and g.loc[6]
  local more = #g.quests - 1
  local qs = "|cffffffff「" .. QName(g.quests[1]) .. "」" .. (more > 0 and (" 외 " .. more .. "개") or "") .. "|r"
  local to = (npc and npc ~= "") and ("|cffffd100" .. npc .. "|r에게 ") or ""
  if g.kind == "accept" then return to .. qs .. " 퀘스트를 수락하러 가는 중" end
  if g.kind == "turnin" then return to .. qs .. " 퀘스트를 제출하러 가는 중" end
  return qs .. " 퀘스트를 수행하러 가는 중"
end

-- 이 단계가 다른 퀘스트를 열기 위한 연계 퀘스트일 때의 설명
local function ChainBadge(g)
  -- (0.29.0) 미리 받기: 다음 지역 퀘스트의 선행이거나 안내 퀘스트
  local pp = g and g.prepick
  if pp then
    return "|cff10d0a0◆ 미리 받기|r  " .. MapName(pp.map) .. "의 |cffffffff「" .. QName(pp.target) .. "」|r"
      .. (pp.why == "bc" and "(으)로 안내하는 퀘스트입니다." or "를 열려면 먼저 해야 하는 퀘스트입니다.")
      .. " 이 지역을 떠나기 전에 받아 가세요"
  end
  local c = g and g.chain
  if not c then return nil end
  local target = "|cffffffff「" .. QName(c.target) .. "」|r"
  local zone = MapName(c.map)
  if c.idx and c.idx > 0 then
    return "|cff4a9fc7◆ 연계 퀘스트|r  " .. zone .. "의 " .. target .. "를 열기 위해 먼저 해야 합니다 (" .. c.total .. "개 중 " .. c.idx .. "번째)"
  elseif c.idx == 0 then
    return "|cff4a9fc7◆ 연계 퀘스트|r  " .. zone .. "의 " .. target .. "를 열려면 다른 지역의 선행 퀘스트를 먼저 해야 합니다"
  end
  return "|cff4a9fc7◆ 연계 퀘스트 완료|r  " .. zone .. "로 돌아가 " .. target .. "를 수락합니다"
end

local function ChainText(g)
  -- 이 단계의 첫 퀘스트가 몇 단계 체인의 일부인지
  local id = g.quests[1]
  local nx = NextChain(id)
  if #nx == 0 then return nil end
  return "체인 " .. (#nx + 1) .. "단계 중 시작/진행"
end

local function Refresh()
  if not frame or not frame:IsShown() then return end
  local locText = "현재 위치: " .. (curMap and MapName(curMap) or "알 수 없음")
  if anchorMap and curMap and anchorMap ~= curMap then
    locText = locText .. "\n|cff4a9fc7기준 지역: " .. MapName(anchorMap) .. "|r (갱신 버튼으로 바꿈)"
  end
  local evl = zoneEval.level
  local evcol = "ffaaaaaa"
  if evl ~= "nodata" and evl ~= "none" then
    local av = zoneEval.avg
    local plv = UnitLevel and UnitLevel("player") or 0
    if av and plv > 0 and av > plv + 4 then evcol = "ffe04a3a"      -- 너무 높음: 빨강
    elseif av and plv > 0 and av < plv - 6 then evcol = "ffe6c229"  -- 너무 낮음: 노랑
    elseif evl == "low" then evcol = "ffe6c229"                      -- 퀘스트 부족: 노랑
    else evcol = "ff2fa26a" end                                      -- 적정: 초록
  end
  local ct = "지역 평가: |c" .. evcol .. zoneEval.text .. "|r"
  if levelZone then ct = ct .. "\n추천 이동 지역: |cffe0701f" .. MapName(levelZone) .. "|r" end
  if KQG.PartyNote then
    local pn = KQG.PartyNote()
    if pn then ct = ct .. "\n" .. pn end
  end
  frame.zone:SetText(locText .. "\n" .. ct)
  if levelZone then
    frame.banner:SetText("|cffe0701f[지역 이동 추천]|r\n현재 지역의 적정 레벨 퀘스트가 부족합니다.\n" .. MapName(levelZone) .. "(으)로 이동하면 더 효율적인 레벨업이 가능합니다.")
  elseif evl == "ok" then
    frame.banner:SetText("|cff2fa26a[현재 지역 진행 추천]|r\n현재 지역에서 수행할 수 있는 퀘스트가 충분합니다.\n현재 지역의 퀘스트를 계속 진행하세요.")
  elseif evl == "mid" then
    frame.banner:SetText("|cffc98a00[현재 지역 진행 추천]|r\n현재 지역에서 진행할 수 있는 퀘스트가 있습니다.\n남은 퀘스트를 마무리하세요.")
  elseif evl == "nodata" then
    frame.banner:SetText("|cffa4abb6[데이터 부족]|r\n이 지역의 퀘스트 데이터가 없거나 지도 연결이 안 됩니다.\n퀘스트가 없다는 뜻은 아닙니다.")
  elseif evl == "low" then
    frame.banner:SetText("|cffe0701f[현재 지역 퀘스트 부족]|r\n현재 지역에서 수행할 퀘스트가 적습니다.\n더 나은 이동 지역은 아직 찾지 못했습니다.")
  else
    frame.banner:SetText("")
  end
  local g = steps[1]
  if g then
    frame.cur1:SetText(StepTitle(g))
    frame.cur2:SetText(StepWhere(g))
    do
      local at = (not g.who) and ActionText(g) or nil
      local cb = ChainBadge(g)
      local txt = ""
      if at then txt = at end
      if cb then txt = (txt ~= "" and (txt .. "\n") or "") .. cb end
      frame.curA:SetText(txt)
    end
    local lines = {}
    local brief = {}
    local stt = StateOf(g)
    if g.who then
      -- 파티 퀘스트: 기준 파티원이 하는 일을 보여준다 (같은 퀘스트를 이미 같이 진행 중이면 생략)
      local same = (g.kind == "doing" or g.kind == "turnin") and #g.quests > 0
      for _, id in ipairs(g.quests or {}) do if not inLog[id] then same = false end end
      if not same then
        local npc = (g.loc and g.loc[6] and g.loc[6] ~= "") and g.loc[6] or "목표 지점"
        local nm = "|cff4a9fc7" .. g.who .. "|r"
        local act
        if g.kind == "accept" then act = nm .. "(이)가 " .. npc .. "에게 퀘스트를 수락하러 가는 중"
        elseif g.kind == "turnin" then act = nm .. "(이)가 " .. npc .. "에게 퀘스트를 제출하러 가는 중"
        elseif g.kind == "travel" then act = nm .. "(이)가 " .. (g.map and MapName(g.map) or "다른 지역") .. "(으)로 이동하는 중"
        else act = nm .. "(이)가 " .. npc .. "에서 퀘스트를 수행하러 가는 중" end
        lines[#lines + 1] = act
      end
    end
    lines[#lines + 1] = "|cff6bb8d6현재 상태: " .. (STATE_KO[stt] or stt) .. "|r"
    if g.kind ~= "travel" then
      for i = 1, math.min(3, #g.quests) do lines[#lines + 1] = QName(g.quests[i]) end
      if #g.quests > 3 then lines[#lines + 1] = "..." end
    else
      lines[#lines + 1] = "대상: " .. QName(g.quests[1])
    end
    if g.kind == "doing" then
      for qi = 1, math.min(2, #g.quests) do
        local objs
        if C_QuestLog and C_QuestLog.GetQuestObjectives then
          local ok, o = pcall(C_QuestLog.GetQuestObjectives, g.quests[qi])
          if ok then objs = o end
        end
        if objs then
          for _, ob in ipairs(objs) do
            if ob.text and ob.text ~= "" and not ob.finished then
              lines[#lines + 1] = "  " .. ob.text
              brief[#brief + 1] = ob.text
            end
          end
        end
      end
    end
    for _, id in ipairs(g.quests) do
      if logElite[id] then
        lines[#lines + 1] = "|cffe0701f정예 퀘스트 - 파티 진행 필수|r"
        brief[#brief + 1] = "|cffe0701f정예 퀘스트 - 파티 진행 필수|r"
        break
      end
    end
    local ct = (g.kind == "accept" and not g.title) and ChainText(g) or nil
    if ct then lines[#lines + 1] = "|cff6bb8d6" .. ct .. "|r" end
    local nl = (g.kind ~= "travel") and NextLine(g) or nil
    if nl then lines[#lines + 1] = "|cff6bb8d6" .. nl .. "|r" end
    frame.cur3:SetText(db.min and table.concat(brief, "\n") or table.concat(lines, "\n"))
    frame.icon:SetTexture(g.kind == "turnin" and "Interface\\GossipFrame\\ActiveQuestIcon"
      or "Interface\\GossipFrame\\AvailableQuestIcon")
    frame.icon:Show()
  else
    frame.icon:Hide()
    if #progress > 0 then
      frame.curA:SetText("")
      frame.cur1:SetText("진행 중인 퀘스트를 하세요")
      frame.cur2:SetText("목표를 달성하면 제출 단계가 나옵니다")
      frame.cur3:SetText("")
    elseif #suggestions > 0 then
      frame.curA:SetText("")
      frame.cur1:SetText("이 지역에서 할 퀘스트가 없습니다")
      frame.cur2:SetText("레벨에 맞는 다른 지역을 추천합니다")
      frame.cur3:SetText("")
    else
      frame.curA:SetText("")
      frame.cur1:SetText("할 수 있는 퀘스트가 없습니다")
      frame.cur2:SetText("레벨/지역을 확인하세요")
      frame.cur3:SetText("")
    end
  end
  -- 다음 단계 목록
  for i = 1, ROWS do
    local row = rows[i]
    local st = steps[i + 1]
    if st then
      row.step = st
      row.text:SetText(StepTitle(st))
      row.sub:SetText(StepWhere(st))
      row:Show()
    else
      row.step = nil
      row:Hide()
    end
  end
  -- 보류 퀘스트 (누르면 지금 진행)
  for i = 1, DROWS do
    local row = drows[i]
    local qid = planDeferred[i]
    if qid then
      row.qid = qid
      row.text:SetText("|cffa4abb6[보류]|r " .. QName(qid) .. " (Lv" .. tostring(Q[qid][F_LVL] or "?") .. ")" .. (logElite[qid] and " |cffe0701f[정예]|r" or ""))
      row.sub:SetText(logElite[qid] and "|cffe0701f정예 퀘스트 (파티 진행 필수)|r  누르면 지금 진행" or "레벨이 오른 뒤 권장  누르면 지금 진행")
    else
      row.qid = nil
    end
  end
  frame.dhead:SetText("보류 퀘스트 " .. #planDeferred .. "개 (난이도 높음)")
  local nlock = (planMode ~= "external") and #locked or 0
  for i = 1, LROWS do
    local row = lrows[i]
    local L = (planMode ~= "external") and locked[i] or nil
    if L then
      row.L = L
      local fr = Q[L.first]
      local st0 = fr and fr[F_START]
      local nm = st0 and st0[6] or "?"
      local zn = L.map and (" / " .. MapName(L.map)) or ""
      row.text:SetText("|cff6bb8d6[선행]|r " .. QName(L.quest) .. " (Lv" .. tostring(Q[L.quest][F_LVL] or "?") .. ")")
      row.sub:SetText("먼저 " .. QName(L.first) .. " (" .. nm .. zn .. ") 외 " .. (#L.chain - 1) .. "단계  누르면 안내")
    else
      row.L = nil
    end
  end
  frame.lhead:SetText("선행 퀘스트 필요 " .. nlock .. "개")
  -- 선행 필요 / 진행 중 / 추천 지역
  local lines = {}
  if #planHist > 0 then
    table.insert(lines, "|cffa4abb6완료한 단계|r")
    for i = #planHist, 1, -1 do table.insert(lines, " |cff2fa26a✓|r " .. StepTitle(planHist[i])) end
  end
  if #noloc > 0 then
    table.insert(lines, "|cffa4abb6목표 위치 데이터 없음 (직접 확인)|r")
    for i = 1, math.min(3, #noloc) do table.insert(lines, " - " .. QName(noloc[i])) end
  end
  if #suggestions > 0 then
    table.insert(lines, "|cffa4abb6이동 후보 지역 (보조 안내)|r")
    for _, z in ipairs(suggestions) do
      table.insert(lines, " - " .. MapName(z.map) .. " (" .. z.n .. ")")
    end
  end
  frame.extra:SetText(db.min and "" or table.concat(lines, "\n"))
  if db.min then frame.banner:SetText("") end
  LayoutFrame()
end

local function SkipCurrent()
  local g = steps[1]
  if not g or g.kind ~= "accept" then
    Print("건너뛸 수 있는 건 '수락' 단계뿐입니다.")
    return
  end
  lastSkip = {}
  for _, id in ipairs(g.quests) do
    db.skipped[id] = true
    table.insert(lastSkip, id)
  end
  pinned = nil
  dirty = true
end

local function UndoSkip()
  if #lastSkip == 0 then
    Print("되돌릴 건너뛰기가 없습니다.")
    return
  end
  for _, id in ipairs(lastSkip) do db.skipped[id] = nil end
  lastSkip = {}
  dirty = true
end

-- 지금 있는 위치 기준으로 퀘스트 안내를 처음부터 다시 계산한다 (지역을 옮겼을 때 사용)
local function RefreshQuests()
  do local cm = PlayerPos() if cm then anchorMap = cm end end
  if KQG.PartyReanchor then pcall(KQG.PartyReanchor) end
  db.planTarget = nil
  prevSteps = {}
  spfKey, lastWpKey = nil, nil
  spfNext = 0
  if db.guideOff == nil then db.guideOff = false end
  dirty = true
  Compute()
  local where = curMap and MapName(curMap) or "알 수 없음"
  local g = steps[1]
  Print("퀘스트를 갱신했습니다. 현재 위치: " .. where .. " / 안내 단계 " .. #steps .. "개" .. (g and (" / 첫 단계: " .. StepTitle(g)) or ""))
  if Refresh then pcall(Refresh) end
end

local function PlanNext()
  local g0 = steps[1]
  local before = g0 and g0.key
  dirty = true
  Compute()
  local g = steps[1]
  if before and g and g.key ~= before then
    Print("현재 단계를 마쳤습니다. 다음: " .. StepTitle(g))
  elseif g then
    local hint
    if g.kind == "accept" then
      hint = (g.loc[6] or "NPC") .. "에게 가서 퀘스트를 수락하세요" .. (g.dist and (" (" .. math.floor(g.dist) .. "야드)") or "")
    elseif g.kind == "doing" then
      hint = "퀘스트 목표를 달성하세요 (" .. (g.loc[6] or "목표 지점") .. ")"
    elseif g.kind == "turnin" then
      hint = (g.loc[6] or "NPC") .. "에게 가서 퀘스트를 제출하세요"
    else
      hint = "안내된 지역으로 이동하세요"
    end
    Print("아직 완료되지 않았습니다. " .. hint .. ". (필요하면 '단계 건너뛰기')")
  else
    Print("남은 단계가 없습니다.")
  end
  pcall(UpdateArrow)
  if frame and frame:IsShown() then Refresh() end
end

local function PlanSkip()
  local g = steps[1]
  if not g then return end
  db.planSkip = db.planSkip or {}
  db.planSkip[SkipKey(g)] = true
  Print("건너뜀: " .. StepTitle(g) .. " (퀘스트는 미완료로 보존됩니다. /kqg plan resetskip 으로 다시 안내)")
  dirty = true
end

local function PlanCommand(arg)
  arg = arg or ""
  if arg == "resetskip" then
    db.planSkip = {}
    db.planSkipExt = {}
    db.planForce = {}
    dirty = true
    Print("건너뛴 단계를 모두 되살렸습니다.")
  elseif arg == "ext" then
    db.planExternal = (db.planExternal == false)
    db.planTarget = nil
    dirty = true
    Print("다른 지역 선행 퀘스트 계획: " .. (db.planExternal == false and "꺼짐" or "켜짐"))
  elseif arg == "skipext" then
    if db.planTarget then
      db.planSkipExt = db.planSkipExt or {}
      db.planSkipExt[db.planTarget.qid] = true
      Print("외부 선행 계획을 건너뜁니다: " .. QName(db.planTarget.qid))
      db.planTarget = nil
      dirty = true
    else
      Print("진행 중인 외부 선행 계획이 없습니다.")
    end
  else
    Print("계획 모드: " .. planMode .. " / 단계 " .. #steps)
    for i = 1, math.min(14, #steps) do
      local g = steps[i]
      local st = StateOf(g)
      Print(i .. ". [" .. (STATE_KO[st] or st) .. "] " .. StepTitle(g) .. " - " .. StepWhere(g))
    end
  end
end

local C_TEXT = { 0.93, 0.94, 0.96 }
local C_MUTED = { 0.55, 0.60, 0.63 }
-- 상수 스타일 색 (상수팩 공통 색)
local C_ACCENT = { 0.063, 0.816, 0.627 }
local C_SEL = { 0.045, 0.32, 0.26 }
local BG_ALPHA = 0.92

local FONT_R = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Regular.ttf"
local FONT_B = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Bold.ttf"
local function SetF(fs, size, bold)
  pcall(fs.SetFont, fs, bold and FONT_B or FONT_R, size or 12)
  return fs
end

local function Solid(tex, r, g, b, a)
  if tex.SetColorTexture then
    tex:SetColorTexture(r, g, b, a or 1)
  else
    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    tex:SetVertexColor(r, g, b, a or 1)
  end
end

local function TextH(fs)
  local ok, h = pcall(fs.GetStringHeight, fs)
  if ok and type(h) == "number" and h > 0 then return h end
  return 14
end

local function ApplyBg()
  local f = frame
  if not f then return end
  -- 투명도 0%일 때 상수 스타일 기본 진하기
  local a = 1 - (db.transp or 0) / 100
  Solid(f.bg, 0.035, 0.055, 0.065, BG_ALPHA * a)
  for _, e in ipairs(f.edges or {}) do Solid(e, 0, 0, 0, a) end
  if f.accent then Solid(f.accent, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], a) end
  if f.line then Solid(f.line, 0.20, 0.25, 0.28, a) end
end

local function ForceDeferred(qid)
  db.planForce = db.planForce or {}
  db.planForce[qid] = true
  pinned = nil
  dirty = true
  Print("보류 퀘스트를 진행 목록에 넣었습니다: " .. QName(qid) .. (logElite[qid] and " (정예 - 파티 진행 필수)" or "") .. " (되돌리기: /kqg plan resetskip)")
end

local function GoPrereq(L)
  local fr = Q[L.first]
  local st0 = fr and fr[F_START]
  if not (st0 and st0[3] and UiMapOf(st0[3])) then
    Print("선행 퀘스트의 시작 위치 정보가 없습니다: " .. QName(L.first))
    return
  end
  local g = MkStep("accept", "MOVING_TO_QUEST_GIVER", "preq" .. L.first, { L.first }, st0)
  g.label = "선행: " .. QName(L.first)
  forced = g
  lastWpKey, spfKey = nil, nil
  Print("선행 퀘스트로 안내합니다: " .. QName(L.first) .. " (" .. QName(L.quest) .. "를 받기 위해). 수락하면 자동으로 해제됩니다.")
  pcall(UpdateArrow)
end

local function FlatButton(parent, text, w, primary, fn)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(w)
  b:SetHeight(24)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  local base = primary and C_SEL or { 0.055, 0.085, 0.10 }
  local hover = primary and { 0.06, 0.40, 0.32 } or { 0.08, 0.12, 0.14 }
  Solid(b.bg, base[1], base[2], base[3], 1)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
  SetF(b.label, 12, primary)
  b.label:SetText(text)
  if primary then b.label:SetTextColor(1, 1, 1) else b.label:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3]) end
  b:SetScript("OnEnter", function() Solid(b.bg, hover[1], hover[2], hover[3], 1) end)
  b:SetScript("OnLeave", function() Solid(b.bg, base[1], base[2], base[3], 1) end)
  b:SetScript("OnClick", fn)
  return b
end

local function IconButton(parent, text, fn)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(20)
  b:SetHeight(20)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
  SetF(b.label, 15, true)
  b.label:SetText(text)
  b.label:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  b:SetScript("OnEnter", function() b.label:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3]) end)
  b:SetScript("OnLeave", function() b.label:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3]) end)
  b:SetScript("OnClick", fn)
  return b
end

local function Dark(fs, size, bold)
  SetF(fs, size or 12, bold)
  fs:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  return fs
end
local function Muted(fs, size)
  SetF(fs, size or 11)
  fs:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  return fs
end

local PADX, CW = 14, 312

LayoutFrame = function()
  local f = frame
  if not f then return end
  local min = db.min and true or false
  f.toggle.label:SetText(min and "+" or "-")
  f.count:Hide()
  local y = -12 - TextH(f.title) - 8
  if min then
    f.zone:Hide()
    f.banner:Hide()
    f.head:Hide()
    f.extra:Hide()
    f.dhead:Hide()
    f.lhead:Hide()
    f.dtoggle:Hide()
    f.ltoggle:Hide()
    f.ntoggle:Hide()
    f.tlabel:Hide()
    if f.slider then f.slider:Hide() end
  else
    f.zone:Show()
    f.zone:ClearAllPoints()
    f.zone:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, y)
    y = y - TextH(f.zone) - 6
    f.banner:Show()
    f.banner:ClearAllPoints()
    f.banner:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, y)
    y = y - TextH(f.banner) - 8
  end
  f.line:ClearAllPoints()
  f.line:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, y)
  f.line:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PADX, y)
  y = y - 10
  -- 현재 단계
  f.icon:ClearAllPoints()
  f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, y)
  f.cur1:ClearAllPoints()
  f.cur1:SetPoint("TOPLEFT", f, "TOPLEFT", PADX + 28, y)
  local h = TextH(f.cur1) + 3 + TextH(f.cur2)
  local cA = f.curA:GetText()
  local above = f.cur2
  if cA and cA ~= "" then
    f.curA:Show()
    f.curA:ClearAllPoints()
    f.curA:SetPoint("TOPLEFT", f.cur2, "BOTTOMLEFT", 0, -6)
    h = h + 6 + TextH(f.curA)
    above = f.curA
  else
    f.curA:Hide()
  end
  local c3 = f.cur3:GetText()
  if c3 and c3 ~= "" then
    f.cur3:Show()
    f.cur3:ClearAllPoints()
    f.cur3:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -5)
    h = h + 5 + TextH(f.cur3)
  else
    f.cur3:Hide()
  end
  y = y - math.max(24, h) - 12
  -- 다음 단계 목록
  if not min then
    f.head:Show()
    f.head:ClearAllPoints()
    f.head:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, y)
    f.ntoggle:Show()
    f.ntoggle:ClearAllPoints()
    f.ntoggle:SetPoint("TOPLEFT", f, "TOPLEFT", PADX + CW - 20, y + 3)
    f.ntoggle.label:SetText(db.collapseNext and "+" or "-")
    y = y - 22
  end
  local maxRows = min and 3 or ROWS
  if (not min) and db.collapseNext then maxRows = 0 end
  for i = 1, ROWS do
    local row = rows[i]
    if row.step and i <= maxRows then
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, y)
      if min then
        row.sub:Hide()
        row:SetHeight(20)
        y = y - 22
      else
        row.sub:Show()
        row:SetHeight(34)
        y = y - 36
      end
      row:Show()
    else
      row:Hide()
    end
  end
  -- 접을 수 있는 구역: 보류 퀘스트 / 선행 필요 퀘스트 (클릭 가능)
  local function Section(head, tg, list, key, field)
    local has = false
    for i = 1, #list do if list[i][field] then has = true end end
    if min or not has then
      head:Hide()
      tg:Hide()
      for i = 1, #list do list[i]:Hide() end
      return
    end
    head:Show()
    head:ClearAllPoints()
    head:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, y - 6)
    tg:Show()
    tg:ClearAllPoints()
    tg:SetPoint("TOPLEFT", f, "TOPLEFT", PADX + CW - 20, y - 3)
    tg.label:SetText(db[key] and "+" or "-")
    y = y - 24
    for i = 1, #list do
      local row = list[i]
      if row[field] and not db[key] then
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, y)
        row:SetHeight(34)
        row:Show()
        y = y - 36
      else
        row:Hide()
      end
    end
  end
  Section(f.dhead, f.dtoggle, drows, "collapseDef", "qid")
  Section(f.lhead, f.ltoggle, lrows, "collapseLock", "L")
  -- 선행 / 이동 후보 (창 안에서 이어서 쌓아 버튼에 가려지지 않음)
  if not min then
    local et = f.extra:GetText()
    if et and et ~= "" then
      f.extra:Show()
      f.extra:ClearAllPoints()
      f.extra:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, y - 6)
      y = y - 6 - TextH(f.extra)
    else
      f.extra:Hide()
    end
    f.tlabel:Show()
    f.tlabel:ClearAllPoints()
    f.tlabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PADX, 116)
    if f.slider then
      f.slider:Show()
      f.slider:ClearAllPoints()
      f.slider:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PADX + 86, 112)
    end
  end
  -- 버튼
  f.bNext.label:SetText(db.guideOff and "안내 시작" or "안내 정지")
  f.bNext:ClearAllPoints()
  f.bSkipStep:ClearAllPoints()
  f.bNext:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PADX, min and 12 or 76)
  f.bSkipStep:SetPoint("LEFT", f.bNext, "RIGHT", 6, 0)
  f.bDungeon:ClearAllPoints()
  f.bDungeon:SetPoint("LEFT", f.bSkipStep, "RIGHT", 6, 0)
  if min then f.bDungeon:Hide() else f.bDungeon:Show() end
  if min then
    f.bSkip:Hide() f.bUndo:Hide() f.bRefresh:Hide() f.bClean:Hide() f.bGear:Hide() f.bParty:Hide()
  else
    f.bSkip:Hide() f.bUndo:Show() f.bRefresh:Show() f.bClean:Show() f.bGear:Show() f.bParty:Show()
    f.bSkip:ClearAllPoints() f.bUndo:ClearAllPoints() f.bGear:ClearAllPoints() f.bParty:ClearAllPoints()
    f.bParty:SetPoint("LEFT", f.bGear, "RIGHT", 6, 0)
    f.bGear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PADX, 12)
    f.bSkip:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PADX, 44)
    f.bUndo:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PADX, 44)
    f.bRefresh:ClearAllPoints()
    f.bRefresh:SetPoint("LEFT", f.bUndo, "RIGHT", 6, 0)
    f.bClean:ClearAllPoints()
    f.bClean:SetPoint("LEFT", f.bRefresh, "RIGHT", 6, 0)
  end
  f:SetHeight(-y + 14 + (min and 36 or 136))
end

local reportFrame
local function BuildReportText()
  local L = {}
  local function add(t) L[#L + 1] = t end
  local ver = "?"
  pcall(function()
    local g = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    ver = g and g("KQuestGuide", "Version") or "?"
  end)
  local bv, bb = "?", "?"
  if GetBuildInfo then bv, bb = GetBuildInfo() end
  add("=== KQuestGuide 버그 리포트 ===")
  add("버전 " .. tostring(ver) .. " / 클라이언트 " .. tostring(bv) .. " (" .. tostring(bb) .. ") / 시각 " .. (date and date("%Y-%m-%d %H:%M:%S") or "?"))
  add("캐릭터 레벨 " .. tostring(UnitLevel and UnitLevel("player")) .. " / 지도 " .. tostring(curMap) .. " " .. tostring(curMap and MapName(curMap) or ""))
  local px, py
  pcall(function()
    local pt = C_Map.GetPlayerMapPosition(curMap, "player")
    if pt then px, py = pt:GetXY() end
  end)
  if px then add("내 위치 " .. string.format("%.1f, %.1f", px * 100, py * 100)) end
  add("SPF " .. tostring(SPFApi() and true or false) .. " (소유 " .. tostring(SPFOwned() and true or false) .. ") / 안내정지 " .. tostring(db.guideOff and true or false)
    .. " / 투명도 " .. tostring(db.transp) .. " / 최소화 " .. tostring(db.min and true or false))
  add("단계 " .. #steps .. " / 진행 중 " .. #progress .. " / 선행필요 " .. #locked .. " / 평가 " .. tostring(zoneEval.text) .. " (" .. tostring(zoneEval.level) .. ", 평균 " .. tostring(zoneEval.avg and string.format("%.1f", zoneEval.avg)) .. ")")
  if forced then add("강제 안내: " .. tostring(forced.key) .. " " .. tostring(forced.label)) end
  add("")
  add("[현재 단계 목록]")
  for i = 1, math.min(10, #steps) do
    local g = steps[i]
    local nm = {}
    for _, id in ipairs(g.quests or {}) do nm[#nm + 1] = tostring(id) .. ":" .. tostring(QName(id)) end
    add(i .. ". " .. tostring(g.kind) .. " 키=" .. tostring(g.key) .. " 지도=" .. tostring(g.map) .. " 위치="
      .. (g.loc and (tostring(g.loc[4]) .. "," .. tostring(g.loc[5]) .. " " .. tostring(g.loc[6])) or "?") .. " 퀘스트=" .. table.concat(nm, "/"))
  end
  add("")
  add("[오류 " .. #bugs .. "건]")
  for i, b in ipairs(bugs) do
    add(i .. ") [" .. b.tag .. "] x" .. b.count .. " " .. b.msg)
    if b.trace and b.trace ~= "" then add(b.trace) end
  end
  if KQG.PartyDebugLines then
    add("")
    add("[파티 통신]")
    local okp, lines = pcall(KQG.PartyDebugLines)
    if okp then for _, t in ipairs(lines) do add(t) end else add("오류: " .. tostring(lines)) end
  end
  add("")
  add("[최근 기록]")
  for _, t in ipairs(ringLog) do add(t) end
  return table.concat(L, "\n")
end

local function ShowReport()
  if not reportFrame then
    local f = CreateFrame("Frame", "KQGReportFrame", UIParent)
    f:SetWidth(560)
    f:SetHeight(400)
    f:SetFrameStrata("DIALOG")
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(s) s = s or this s:StartMoving() end)
    f:SetScript("OnDragStop", function(s) s = s or this s:StopMovingOrSizing() end)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    Solid(bg, 0.035, 0.055, 0.065, 1)
    local ac = f:CreateTexture(nil, "ARTWORK")
    ac:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    ac:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    ac:SetHeight(3)
    Solid(ac, 0.90, 0.25, 0.22, 1)
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
    SetF(t, 15, true)
    t:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
    t:SetText("버그 리포트")
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
    SetF(hint, 11)
    hint:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
    hint:SetText("'전체 선택' 후 Ctrl+C 로 복사해서 붙여넣어 주세요.")
    local x = IconButton(f, "X", function() f:Hide() end)
    x:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -10)
    local sf = CreateFrame("ScrollFrame", "KQGReportScroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -58)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 48)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetWidth(510)
    eb:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    SetF(eb, 12)
    eb:SetScript("OnEscapePressed", function(s) s = s or this s:ClearFocus() end)
    eb:SetScript("OnTextChanged", function(s, user)
      s = s or this
      if user and f.text and s:GetText() ~= f.text then s:SetText(f.text) end
    end)
    sf:SetScrollChild(eb)
    f.eb = eb
    f.sel = FlatButton(f, "전체 선택", 90, true, function()
      f.eb:SetFocus()
      f.eb:HighlightText()
    end)
    f.sel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 14)
    f.clr = FlatButton(f, "리포트 지우기", 110, false, function()
      for i = #bugs, 1, -1 do bugs[i] = nil end
      UpdateBugButton()
      f:Hide()
      Print("버그 리포트를 지웠습니다.")
    end)
    f.clr:SetPoint("LEFT", f.sel, "RIGHT", 6, 0)
    f.close = FlatButton(f, "닫기", 70, false, function() f:Hide() end)
    f.close:SetPoint("LEFT", f.clr, "RIGHT", 6, 0)
    f:Hide()
    reportFrame = f
  end
  local txt = BuildReportText()
  reportFrame.text = txt
  reportFrame.eb:SetText(txt)
  reportFrame:Show()
  reportFrame.eb:SetFocus()
  reportFrame.eb:HighlightText()
end

ReportBug = function(tag, msg, trace)
  msg = tostring(msg)
  local key = tag .. ":" .. (msg:gsub("%d+", "#"))
  for _, b in ipairs(bugs) do
    if b.key == key then b.count = b.count + 1 UpdateBugButton() return end
  end
  if #bugs >= 15 then table.remove(bugs, 1) end
  bugs[#bugs + 1] = { key = key, tag = tag, msg = msg, trace = trace or "", count = 1 }
  RingPush("오류 [" .. tag .. "] " .. msg)
  UpdateBugButton()
end
KQG = KQG or {}
KQG.ReportBug = ReportBug
KQG.ShowReport = ShowReport

UpdateBugButton = function()
  if not frame or not frame.bBug then return end
  if #bugs > 0 then
    local n = 0
    for _, b in ipairs(bugs) do n = n + b.count end
    frame.bBug.label:SetText("버그 리포트 (" .. n .. ")")
    frame.bBug:Show()
  else
    frame.bBug:Hide()
  end
end

local function BuildFrame()
  local f = CreateFrame("Frame", "KQGFrame", UIParent)
  f:SetWidth(340)
  f:SetHeight(300)
  f:SetFrameStrata("MEDIUM")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(s) s = s or this; s:StartMoving() end)
  f:SetScript("OnDragStop", function(s)
    s = s or this
    s:StopMovingOrSizing()
    local l, t = s:GetLeft(), s:GetTop()
    local ut = UIParent:GetTop()
    if l and t and ut then
      s:ClearAllPoints()
      s:SetPoint("TOPLEFT", UIParent, "TOPLEFT", l, t - ut)
      db.pos = { "TOPLEFT", "TOPLEFT", l, t - ut }
    end
  end)
  if db.pos and db.pos[1] == "TOPLEFT" then
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db.pos[3], db.pos[4])
  else
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -40, -140)
  end

  -- 바탕: 1px 옅은 테두리 + 흰 면 + 위쪽 포인트 선
  f.edges = {}
  for _, def in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
    { "TOPLEFT", "BOTTOMLEFT", "w" }, { "TOPRIGHT", "BOTTOMRIGHT", "w" } }) do
    local t = f:CreateTexture(nil, "BORDER")
    t:SetPoint(def[1], f, def[1], 0, 0)
    t:SetPoint(def[2], f, def[2], 0, 0)
    if def[3] == "h" then t:SetHeight(1) else t:SetWidth(1) end
    Solid(t, 0, 0, 0, 1)
    f.edges[#f.edges + 1] = t
  end
  f.bg = f:CreateTexture(nil, "BORDER")
  f.bg:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  f.bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
  Solid(f.bg, 0.035, 0.055, 0.065, 1)
  f.accent = f:CreateTexture(nil, "ARTWORK")
  f.accent:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  f.accent:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
  f.accent:SetHeight(3)
  Solid(f.accent, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", PADX, -12)
  SetF(title, 16, true)
  title:SetText("상수의 레벨업 가이드!")
  f.title = title
  title:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])

  f:HookScript("OnHide", function()
    for _, nm in ipairs({ "KQGGearFrame", "KQGPartyFrame", "KQGReportFrame" }) do
      local sf = _G[nm]
      if sf and sf.Hide then sf:Hide() end
    end
  end)
  f.close = IconButton(f, "X", function() f:Hide() end)
  f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -10)
  f.toggle = IconButton(f, "-", function()
    db.min = not db.min
    dirty = true
    Refresh()
  end)
  f.toggle:SetPoint("RIGHT", f.close, "LEFT", -2, 0)
  f.bBug = FlatButton(f, "버그 리포트", 84, false, ShowReport)
  f.bBug:SetHeight(20)
  f.bBug:SetPoint("RIGHT", f.toggle, "LEFT", -6, 0)
  do
    local bb = f.bBug
    Solid(bb.bg, 0.72, 0.16, 0.14, 1)
    bb.label:SetTextColor(1, 1, 1)
    bb:SetScript("OnEnter", function() Solid(bb.bg, 0.88, 0.28, 0.24, 1) end)
    bb:SetScript("OnLeave", function() Solid(bb.bg, 0.72, 0.16, 0.14, 1) end)
    bb:SetWidth(110)
  end
  f.bBug:Hide()

  f.zone = Muted(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
  f.zone:SetWidth(CW)
  f.zone:SetJustifyH("LEFT")
  f.count = Muted(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
  f.count:SetWidth(CW)
  f.count:SetJustifyH("LEFT")
  f.banner = Dark(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
  f.banner:SetWidth(CW)
  f.banner:SetJustifyH("LEFT")
  f.banner:SetJustifyV("TOP")

  f.line = f:CreateTexture(nil, "ARTWORK")
  f.line:SetHeight(1)
  Solid(f.line, 0.20, 0.25, 0.28, 1)

  -- 현재 단계 카드
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetWidth(22)
  f.icon:SetHeight(22)
  f.cur1 = Dark(f:CreateFontString(nil, "OVERLAY", "GameFontNormal"), 13, true)
  f.cur1:SetWidth(CW - 28)
  f.cur1:SetJustifyH("LEFT")
  f.cur2 = Muted(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 12)
  f.cur2:SetPoint("TOPLEFT", f.cur1, "BOTTOMLEFT", 0, -3)
  f.cur2:SetWidth(CW - 28)
  f.cur2:SetJustifyH("LEFT")
  f.curA = Dark(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 13, true)
  f.curA:SetPoint("TOPLEFT", f.cur2, "BOTTOMLEFT", 0, -6)
  f.curA:SetWidth(CW - 28)
  f.curA:SetJustifyH("LEFT")
  f.cur3 = Dark(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
  f.cur3:SetPoint("TOPLEFT", f.cur2, "BOTTOMLEFT", 0, -5)
  f.cur3:SetWidth(CW - 28)
  f.cur3:SetJustifyH("LEFT")

  -- 다음 단계 목록
  f.head = Muted(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
  f.head:SetText("진행 예정 순서 (누르면 먼저 하기)")
  f.ntoggle = nil
  local function MakeRow(onclick)
    local row = CreateFrame("Button", nil, f)
    row:SetWidth(CW)
    row:SetHeight(34)
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints()
    Solid(row.hl, 0.063, 0.816, 0.627, 0)
    row:SetScript("OnEnter", function() Solid(row.hl, 0.063, 0.816, 0.627, 0.22) end)
    row:SetScript("OnLeave", function() Solid(row.hl, 0.063, 0.816, 0.627, 0) end)
    row.text = Dark(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 12)
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -2)
    row.text:SetWidth(CW - 8)
    row.text:SetJustifyH("LEFT")
    pcall(row.text.SetWordWrap, row.text, false)
    row.sub = Muted(row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"))
    row.sub:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, -2)
    row.sub:SetWidth(CW - 8)
    row.sub:SetJustifyH("LEFT")
    pcall(row.sub.SetWordWrap, row.sub, false)
    row:SetScript("OnClick", function(s2) onclick(s2 or this) end)
    row:Hide()
    return row
  end
  for i = 1, ROWS do
    rows[i] = MakeRow(function(r)
      if r.step then
        pinned = r.step.key
        dirty = true
      end
    end)
  end
  f.dhead = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.lhead = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  for _, fs in ipairs({ f.head, f.dhead, f.lhead }) do
    SetF(fs, 13, true)
    fs:SetTextColor(0.90, 0.25, 0.22)
  end
  f.ntoggle = IconButton(f, "-", function()
    db.collapseNext = not db.collapseNext
    dirty = true
    Refresh()
  end)
  f.dtoggle = IconButton(f, "-", function()
    db.collapseDef = not db.collapseDef
    dirty = true
    Refresh()
  end)
  f.ltoggle = IconButton(f, "-", function()
    db.collapseLock = not db.collapseLock
    dirty = true
    Refresh()
  end)
  for _, tg in ipairs({ f.ntoggle, f.dtoggle, f.ltoggle }) do
    SetF(tg.label, 16, true)
    tg.label:SetTextColor(0.90, 0.25, 0.22)
    tg:SetScript("OnLeave", function() tg.label:SetTextColor(0.90, 0.25, 0.22) end)
    tg:SetScript("OnEnter", function() tg.label:SetTextColor(1, 0.55, 0.5) end)
  end
  for i = 1, DROWS do
    drows[i] = MakeRow(function(r)
      if r.qid then ForceDeferred(r.qid) end
    end)
  end
  for i = 1, LROWS do
    lrows[i] = MakeRow(function(r)
      if r.L then GoPrereq(r.L) end
    end)
  end

  f.extra = Muted(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
  f.extra:SetWidth(CW)
  f.extra:SetJustifyH("LEFT")
  f.extra:SetJustifyV("TOP")

  f.bNext = FlatButton(f, "안내 정지", 96, true, function()
    db.guideOff = not db.guideOff
    if not db.guideOff then spfKey, lastWpKey = nil, nil spfNext = 0 end
    dirty = true
    UpdateArrow()
    Refresh()
  end)
  f.bSkipStep = FlatButton(f, "단계 건너뛰기", 104, false, PlanSkip)
  f.bDungeon = FlatButton(f, "던전 퀘스트", 100, false, function() if KQG and KQG.DungeonCommand then KQG.DungeonCommand("") end end)
  f.bSkip = FlatButton(f, "건너뛰기", 70, false, SkipCurrent)
  f.bUndo = FlatButton(f, "되돌리기", 70, false, UndoSkip)
  f.bRefresh = FlatButton(f, "퀘스트 갱신", 96, true, RefreshQuests)
  f.bClean = FlatButton(f, "퀘스트 정리", 96, false, function() if KQG and KQG.CleanupOpen then KQG.CleanupOpen() end end)
  f.bGear = FlatButton(f, "추천 장비 습득 퀘스트", 200, false, function() if KQG and KQG.ToggleGear then KQG.ToggleGear() end end)
  f.bParty = FlatButton(f, "파티", 106, false, function() if KQG and KQG.ToggleParty then KQG.ToggleParty() end end)
  do
    local pb = f.bParty
    Solid(pb.bg, 0.18, 0.64, 0.42, 1)
    pb.label:SetTextColor(1, 1, 1)
    SetF(pb.label, 12, true)
    pb:SetScript("OnEnter", function() Solid(pb.bg, 0.26, 0.76, 0.52, 1) end)
    pb:SetScript("OnLeave", function() Solid(pb.bg, 0.18, 0.64, 0.42, 1) end)
  end
  do
    local gb = f.bGear
    Solid(gb.bg, 0.045, 0.32, 0.26, 1)
    gb.label:SetTextColor(1, 1, 1)
    SetF(gb.label, 12, true)
    gb:SetScript("OnEnter", function() Solid(gb.bg, 0.06, 0.40, 0.32, 1) end)
    gb:SetScript("OnLeave", function() Solid(gb.bg, 0.045, 0.32, 0.26, 1) end)
  end

  f.tlabel = Muted(f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
  f.tlabel:SetText("투명도 " .. (db.transp or 0) .. "%")
  pcall(function()
    local sl = CreateFrame("Slider", nil, f)
    sl:SetOrientation("HORIZONTAL")
    sl:SetWidth(220)
    sl:SetHeight(16)
    sl:SetMinMaxValues(0, 100)
    sl:SetValueStep(5)
    local tr = sl:CreateTexture(nil, "BACKGROUND")
    tr:SetPoint("LEFT", sl, "LEFT", 0, 0)
    tr:SetPoint("RIGHT", sl, "RIGHT", 0, 0)
    tr:SetHeight(4)
    Solid(tr, 0.20, 0.25, 0.28, 1)
    local th = sl:CreateTexture(nil, "OVERLAY")
    th:SetWidth(8)
    th:SetHeight(16)
    Solid(th, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
    sl:SetThumbTexture(th)
    sl:SetValue(db.transp or 0)
    sl:SetScript("OnValueChanged", function(s2, v)
      v = v or arg1
      if not v then return end
      db.transp = math.floor(v / 5 + 0.5) * 5
      f.tlabel:SetText("투명도 " .. db.transp .. "%")
      ApplyBg()
    end)
    f.slider = sl
  end)

  f:SetScript("OnShow", function() dirty = true end)
  frame = f
  ApplyBg()
end

-- 미니맵 버튼 ---------------------------------------------------------------------

local mmBtn
local atan2 = math.atan2 or math.atan

local function UpdateMinimapPos()
  if not mmBtn then return end
  local angle = math.rad(db.mmAngle or 160)
  mmBtn:ClearAllPoints()
  local radius = (Minimap:GetWidth() / 2) + 5
  mmBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function BuildMinimapButton()
  local b = CreateFrame("Button", "KQGMinimapButton", Minimap)
  b:SetWidth(31)
  b:SetHeight(31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  pcall(b.RegisterForClicks, b, "LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")

  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetWidth(20)
  icon:SetHeight(20)
  icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
  icon:SetPoint("CENTER", b, "CENTER", 0, 1)

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetWidth(53)
  border:SetHeight(53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  b:SetScript("OnClick", function(_, btn)
    btn = btn or arg1
    if btn == "RightButton" then
      db.arrow = not db.arrow
      Print("화살표 " .. (db.arrow and "켜짐" or "꺼짐"))
      return
    end
    if frame:IsShown() then frame:Hide() else frame:Show() end
  end)
  b:SetScript("OnDragStart", function(f) f = f or this; f.dragging = true; GameTooltip:Hide() end)
  b:SetScript("OnDragStop", function(f) f = f or this; f.dragging = false end)
  b:SetScript("OnUpdate", function(f)
    f = f or this
    if not f.dragging then return end
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    db.mmAngle = math.deg(atan2(cy / scale - my, cx / scale - mx))
    UpdateMinimapPos()
  end)
  b:SetScript("OnEnter", function(f)
    f = f or this
    GameTooltip:SetOwner(f, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("상수의 레벨업 가이드!", 1, 1, 1)
    GameTooltip:AddLine("왼쪽 클릭: 창 열기/닫기", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("오른쪽 클릭: 화살표 켜기/끄기", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("드래그: 아이콘 위치 이동", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  mmBtn = b
  UpdateMinimapPos()
  if db.mmHide then b:Hide() else b:Show() end
end

-- 이벤트 / 구동 ---------------------------------------------------------------------

local ev = CreateFrame("Frame")
local tick = 0
local lastStepKey = nil
ev:SetScript("OnUpdate", function(_, el)
  el = el or arg1 or 0
  if not db then return end
  tick = tick + el
  if tick < 0.3 then return end
  tick = 0
  local now = GetTime and GetTime() or 0
  if dirty and now - lastCompute >= 1 then
    if not Guard("계산", Compute) then dirty = false end
    Guard("표시", Refresh)
    local g1 = steps[1]
    local k1 = g1 and g1.key or false
    if k1 ~= lastStepKey then
      lastStepKey = k1
      if g1 then RingPush("1단계: " .. tostring(g1.kind) .. " " .. tostring(g1.key)) end
    end
  end
  Guard("화살표", UpdateArrow)
end)

local function MarkDirty() dirty = true end
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
  "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP", "PLAYER_LOGIN" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e)
  e = e or event
  if e == "PLAYER_ENTERING_WORLD" or e == "ZONE_CHANGED_NEW_AREA" then
    zoneChangeAt = GetTime and GetTime() or 0
    spfNext = 0
  end
  if e == "PLAYER_LOGIN" then
    KQGDB = KQGDB or {}
    db = KQGDB
    db.skipped = db.skipped or {}
    -- 접속할 때마다 안내 정지, 파티 모드 꺼짐으로 시작
    db.guideOff = true
    db.partyMode = false
    db.partyQuest = false
    if db.arrow == nil then db.arrow = true end
    InitPlayer()
    if KQG.InjectFound then pcall(KQG.InjectFound) end
    BuildIndex()
    BuildFrame()
    BuildArrow()
    BuildMinimapButton()
    UpdateBugButton()
    Print("로드됨. /kqg 로 창을 열고 닫습니다.")
    frame:Show()
  end
  dirty = true
end)

-- NPC 대화창에 계획된 퀘스트가 없으면 "수락 불가"로 보고 건너뜁니다 (되돌리기: /kqg back 또는 reset)
local function OfferedTitles()
  local t = {}
  if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
    local ok, list = pcall(C_GossipInfo.GetAvailableQuests)
    if ok and type(list) == "table" then
      for _, q in ipairs(list) do if q.title then t[#t + 1] = q.title end end
    end
  end
  if GetNumAvailableQuests and GetAvailableTitle then
    local ok, n = pcall(GetNumAvailableQuests)
    if ok and n then
      for i = 1, n do
        local ok2, tt = pcall(GetAvailableTitle, i)
        if ok2 and tt then t[#t + 1] = tt end
      end
    end
  end
  return t
end

local npcFrame = CreateFrame("Frame")
for _, e in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING" }) do pcall(npcFrame.RegisterEvent, npcFrame, e) end
npcFrame:SetScript("OnEvent", function()
  if not db then return end
  local okn, npcName = pcall(UnitName, "npc")
  if not okn or not npcName then return end
  local titles = OfferedTitles()
  local marked = {}
  for i = 1, math.min(#steps, 8) do
    local g = steps[i]
    if g and g.kind == "accept" and g.loc and g.loc[6] == npcName then
      for _, id in ipairs(g.quests) do
        local name = QName(id)
        local found = false
        for _, tt in ipairs(titles) do
          if string.find(tt, name, 1, true) then found = true break end
        end
        if not found and not db.skipped[id] then
          db.skipped[id] = true
          marked[#marked + 1] = name
        end
      end
    end
  end
  if #marked > 0 then
    lastSkip = {}
    Print(npcName .. "에게 [" .. table.concat(marked, ", ") .. "] 수락 항목이 없어 건너뜁니다. (되돌리기: /kqg reset)")
    pinned = nil
    dirty = true
  end
end)

KQG = KQG or {}
KQG.Q = Q
KQG.F = { NAME = F_NAME, LVL = F_LVL, MIN = F_MIN, RACES = F_RACES, CLASSES = F_CLASSES, PREG = F_PREG, PRES = F_PRES,
  EXCL = F_EXCL, NEXT = F_NEXT, ZONE = F_ZONE, START = F_START, END = F_END, TEXT = F_TEXT, FLAGS = F_FLAGS,
  PARENT = F_PARENT, MAXLVL = F_MAXLVL, BCFOR = F_BCFOR, BCS = F_BCS }
KQG.DB = function() return db end
KQG.IsDone = function(id) return IsDone(id) end
KQG.InLog = function(id) return inLog[id] and true or false end
KQG.LogSet = function() return inLog end
KQG.LogIndex = function(id) return logIndex[id] end
KQG.LogComplete = function(id) return logComplete[id] and true or false end
KQG.UiMapOf = UiMapOf
KQG.MapName = MapName
KQG.Measure = Measure
KQG.Bit = Bit
KQG.Faction = function() return playerFaction end
KQG.RaceBit = function() return playerRaceBit end
KQG.ClassBit = function() return playerClassBit end
KQG.Print = Print
KQG.ReadLog = function() ReadLog() end
KQG.RebuildIndex = function() doneCache = {} BuildIndex() dirty = true end
-- 회색·연계 판정 (Cleanup.lua에서 씀)
KQG.GrayRange = function() return GrayRange() end
KQG.IsGrayLevel = IsGrayLevel
KQG.ChainHas = ChainHas
KQG.ChainLeadsToFit = ChainLeadsToFit
KQG.QName = function(id) return QName(id) end
KQG.SetForced = function(g)
  forced = g
  if g and db.guideOff then db.guideOff = false spfKey, lastWpKey = nil, nil spfNext = 0 pcall(Refresh) end
  if g and not db.guideOff then SetWaypoint(g) end
  pcall(UpdateArrow)
end
KQG.GetForced = function() return forced end
-- 퀘스트를 건너뛰기 목록에 넣기 (NPC가 퀘스트를 주지 않을 때). 되돌리기: /kqg back
KQG.SkipQuests = function(ids)
  local names = {}
  lastSkip = {}
  for _, id in ipairs(ids or {}) do
    if not db.skipped[id] then
      db.skipped[id] = true
      lastSkip[#lastSkip + 1] = id
      names[#names + 1] = QName(id)
    end
  end
  if #names > 0 then
    Print("[" .. table.concat(names, ", ") .. "] 건너뜀. (되돌리기: /kqg back)")
    pinned = nil
    dirty = true
  end
end
KQG.Compute = function() dirty = true Compute() end
KQG.Steps = function() return steps end
KQG.StepsRaw = function() return steps end
KQG.ActionText = ActionText
KQG.ChainBadge = ChainBadge
KQG.SetAnchor = function(map)
  if map then anchorMap = map end
  db.planTarget = nil
  prevSteps = {}
  spfKey, lastWpKey = nil, nil
  spfNext = 0
  dirty = true
end
KQG.GetAnchor = function() return anchorMap end
KQG.GuideSet = function(off)
  db.guideOff = off and true or false
  if not db.guideOff then spfKey, lastWpKey = nil, nil spfNext = 0 end
  dirty = true
  pcall(UpdateArrow)
  pcall(Refresh)
end
KQG.GuideIsOff = function() return db.guideOff and true or false end
KQG.StepQuestOrder = function()
  local out, seen = {}, {}
  for _, g in ipairs(steps or {}) do
    if g.kind == "doing" or g.kind == "turnin" or g.kind == "accept" then
      for _, qid in ipairs(g.quests or {}) do
        if not seen[qid] then seen[qid] = true out[#out + 1] = qid end
      end
    end
  end
  return out
end
KQG.PlanCommand = PlanCommand

-- 비행경로 정보 수집: 비행 조련사 지도를 열 때 발견한 비행경로를 기록합니다. (안내에는 아직 쓰지 않음)
local taxiFrame = CreateFrame("Frame")
pcall(taxiFrame.RegisterEvent, taxiFrame, "TAXIMAP_OPENED")
taxiFrame:SetScript("OnEvent", function()
  pcall(function()
    if not db or not NumTaxiNodes then return end
    db.taxi = db.taxi or {}
    for i = 1, NumTaxiNodes() do
      local nm = TaxiNodeName(i)
      local ty = TaxiNodeGetType(i)
      if nm and ty then db.taxi[nm] = ty end
    end
  end)
end)

SLASH_KQG1 = "/kqg"
SlashCmdList["KQG"] = function(msg)
  if not db then return end
  msg = msg or ""
  if msg == "skip" then SkipCurrent()
  elseif msg == "back" then UndoSkip()
  elseif msg == "refresh" then RefreshQuests()
  elseif msg == "arrow" then
    db.arrow = not db.arrow
    Print("화살표 " .. (db.arrow and "켜짐" or "꺼짐"))
  elseif msg == "why" then
    local n = 0
    for qid in pairs(inLog) do
      if logComplete[qid] then
        n = n + 1
        local r = Q[qid]
        local cm, cx, cy = ClientTurnPoint(qid, curMap)
        Print("완료 " .. qid .. " " .. QName(qid) .. " / 데이터 " .. (r and "있음" or "없음") .. " / 제출NPC " .. tostring(r and r[F_END] and r[F_END][6])
          .. " / 게임위치 " .. (cm and string.format("%d (%.0f,%.0f)", cm, cx, cy) or "없음"))
      end
    end
    Print("완료(제출 가능) 퀘스트 " .. n .. "개 / 현재 지도 " .. tostring(curMap))
  elseif msg == "자동기준" or msg == "auto anchor" then
    db.autoAnchor = (db.autoAnchor == false)
    Print("추천 지역에 도착하면 기준 지역 자동 전환 " .. (db.autoAnchor ~= false and "켜짐" or "꺼짐")
      .. " (꺼져 있으면 갱신 버튼으로 바꿉니다)")
  elseif msg == "미리받기" or msg == "prepick" then
    db.prepick = (db.prepick == false)
    dirty = true
    Print("다음 지역 퀘스트의 선행·안내 퀘스트를 떠나기 전에 받도록 안내 " .. (db.prepick ~= false and "켜짐" or "꺼짐"))
  elseif msg == "min" then
    db.min = not db.min
    dirty = true
    Print("창 최소화 " .. (db.min and "켜짐" or "꺼짐"))
  elseif msg == "spf" then
    db.spf = (db.spf == false)
    spfKey = nil
    if db.spf == false then SPFCancel() end
    Print("Shortest Path Forever 연동 " .. (db.spf == false and "꺼짐" or (SPFApi() and "켜짐" or "켜짐 (SPF 미설치)")))
  elseif msg == "waypoint" then
    db.waypoint = (db.waypoint == false)
    lastWpKey = nil
    Print("지도 핀(목표 위치 표시) " .. (db.waypoint and "켜짐" or "꺼짐"))
  elseif msg == "gray" or msg == "회색" then
    db.hideGray = not Hide_Gray()
    dirty = true
    local gr, src = GrayRange()
    Print("회색(너무 낮은 레벨) 퀘스트 숨김 " .. (Hide_Gray() and "켜짐" or "꺼짐")
      .. string.format(" (회색 기준: 내 레벨보다 %d레벨 넘게 낮음, 출처: %s)", gr, tostring(src)))
  elseif msg == "gray chain" or msg == "회색 연계" then
    db.grayChain = (db.grayChain == false)
    chainCache = {}
    dirty = true
    Print("회색 퀘스트라도 연계가 이어지면 안내 " .. (db.grayChain ~= false and "켜짐" or "꺼짐"))
  elseif msg == "정리" or msg == "clean" then
    if KQG.CleanupOpen then KQG.CleanupOpen() end
  elseif msg == "정리 버튼" or msg == "clean button" then
    if KQG.CleanupToggleLogButton then KQG.CleanupToggleLogButton() end
  elseif msg == "minimap" then
    db.mmHide = not db.mmHide
    if mmBtn then if db.mmHide then mmBtn:Hide() else mmBtn:Show() end end
    Print("미니맵 아이콘 " .. (db.mmHide and "숨김" or "표시"))
  elseif string.sub(msg, 1, 4) == "plan" then
    PlanCommand(string.sub(msg, 6))
  elseif string.sub(msg, 1, 4) == "gear" then
    if KQG.GearCommand then KQG.GearCommand(string.sub(msg, 6)) end
  elseif msg == "범위" or msg == "area" or string.sub(msg, 1, 7) == "범위 " or string.sub(msg, 1, 5) == "area " then
    if KQG.AreaCommand then KQG.AreaCommand(msg:match("^%S+%s+(.*)$") or "") end
  elseif msg == "reset" then
    db.skipped = {}
    pinned = nil
    dirty = true
    Print("건너뛴 퀘스트를 모두 되돌렸습니다.")
  elseif msg == "report" then
    ShowReport()
  elseif msg == "arrive" then
    db.arriveNotice = (db.arriveNotice == false)
    Print("수락 지점 도착 안내 " .. (db.arriveNotice == false and "꺼짐" or "켜짐"))
  elseif string.sub(msg, 1, 4) == "item" then
    if KQG.ItemCommand then KQG.ItemCommand(string.sub(msg, 6)) end
  elseif string.sub(msg, 1, 3) == "npc" then
    if KQG.NpcCommand then KQG.NpcCommand(string.sub(msg, 5)) end
  elseif msg == "party" then
    if KQG.PartyCommand then KQG.PartyCommand() end
  elseif msg == "던전" or msg == "dungeon" or string.sub(msg, 1, 7) == "dungeon" then
    if KQG.DungeonCommand then KQG.DungeonCommand(msg:match("^%S+%s+(.*)$") or "") end
  elseif msg == "기록" or msg == "journal" then
    if KQG.JournalCommand then KQG.JournalCommand() end
  elseif msg == "수집" or msg == "found" then
    if KQG.FoundCommand then KQG.FoundCommand() end
  elseif msg == "책" or msg == "book" or string.sub(msg, 1, 4) == "책 " or string.sub(msg, 1, 5) == "book " then
    if KQG.BookCommand then KQG.BookCommand(msg:match("^%S+%s+(.*)$") or "") end
  elseif msg == "debug" then
    db.debug = not db.debug
    local n = 0
    for _ in pairs(Q) do n = n + 1 end
    Print("디버그 " .. (db.debug and "켜짐" or "꺼짐") .. " / 퀘스트 데이터 " .. n .. "개 / 현재 지도 " .. tostring(curMap)
      .. " / 단계 " .. #steps .. " / 진행 중 " .. #progress .. " / 이동추천 " .. tostring(levelZone) .. " / 평가 " .. tostring(zoneEval.text) .. " 점수 " .. string.format("%.1f", zoneEval.score or 0) .. " / 잠긴 안내 " .. #locked)
    for i = 1, math.min(6, #steps) do
      local g = steps[i]
      Print(i .. ". " .. g.kind .. " 점수 " .. string.format("%.0f", g.score or 0) .. " 지도 " .. tostring(g.map) .. " " .. QName(g.quests[1]) .. " (" .. (g.loc[6] or "?") .. ")")
    end
    for i = 1, math.min(3, #zoneRank) do
      Print("지역순위 " .. i .. ": " .. MapName(zoneRank[i].map) .. " " .. string.format("%.1f", zoneRank[i].score))
    end
    -- (0.29.0) 미리 받기 후보
    local pn = 0
    for qid, pp in pairs(Guide.prepick) do
      pn = pn + 1
      if pn <= 5 then
        Print("미리 받기: " .. QName(qid) .. " -> " .. MapName(pp.map) .. " " .. QName(pp.target) .. (pp.why == "bc" and " (안내 퀘스트)" or " (선행)"))
      end
    end
    Print("미리 받기 후보 " .. pn .. "개" .. (db.prepick == false and " (꺼짐: /kqg 미리받기)" or ""))
  else
    if frame:IsShown() then frame:Hide() else frame:Show() end
  end
end
