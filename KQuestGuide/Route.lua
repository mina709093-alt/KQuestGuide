-- 경로 안내 공통 함수: KQG.RouteQuest(questID)
-- 선택한 퀘스트의 목표 위치(완료했으면 제출 NPC 위치)로 기존 길 안내를 돌립니다.
--   * 핀과 점선 경로: 기존 연동 그대로 (KQG.SetForced → Shortest Path Forever 공개 API).
--     SPF가 없으면 게임 지도 핀과 KQuestGuide 화살표로 안내합니다.
--   * 위치 데이터: KQuestGuide 목표 자료(KQG_OBJ, 게임에서 수집한 자료 포함) 중 내 위치에서 가장 가까운 목표.
--     자료에 없으면 게임이 주는 퀘스트 지도 위치(C_QuestLog.GetQuestsOnMap, 지금 있는 지도만)를 씁니다.
--   * (0.29.1) 그래도 없으면: 전달·대화 퀘스트(목표 없음)는 제출 NPC, Questie 자료(읽기만: 제출 NPC, 목표 몬스터·오브젝트·
--     아이템을 떨어뜨리는 곳), 게임의 퀘스트 지도(GetQuestUiMapID) 위치, 게임의 다음 목적지(C_QuestLog.GetNextWaypoint) 순서.
--     제출 NPC도 KQuestGuide 자료 → Questie → 게임 순서로 찾습니다(던전 퀘스트처럼 KQuestGuide 자료에 없는 퀘스트).
--   * 위치를 모르면 임의의 곳을 안내하지 않고 "위치 정보가 없습니다"라고 알립니다.
-- 안내가 끝나는 때 (주변 퀘스트를 이어서 할 수 있게 자동으로 다른 곳으로 넘기지 않습니다)
--   * 도착: 목표 지역 대표 위치 30야드 이내, 제출 NPC 5야드 이내
--   * 퀘스트 완료(목표를 모두 끝냄), 제출, 포기
--   * 다른 안내(장비 추천 등)가 목적지를 가져감 → 조용히 손을 뗌
-- 끝나면 KQuestGuide 평소 안내로 돌아갑니다. 경로안내 전에 평소 안내가 꺼져 있었다면 다시 끕니다.
-- 완료된 퀘스트를 메뉴에서 고르면 제출 NPC로 안내합니다.
-- 이 함수를 부르는 곳: DaylightBridge.lua (DaylightUI 퀘스트 우클릭 메뉴 "경로안내").
-- 다른 입력 방식을 추가할 때도 이 함수만 부릅니다 (경로 안내 로직을 따로 만들지 않음).

local K = KQG
if type(K) ~= "table" then return end

local KEY = "route"   -- 강제 안내(forced)의 key 앞부분: 이 파일이 시작한 안내인지 구분
local ARRIVE_DOING = 30   -- 목표 지역 대표 위치까지 (야드). 몬스터/오브젝트가 퍼져 있는 지역이라 넉넉하게
local ARRIVE_TURNIN = 5   -- 제출 NPC까지 (야드)

local route = nil     -- 진행 중인 경로안내: { q, kind, key, inst, wx, wy, prevOff }

local function Print(t) if K.Print then K.Print(t) end end

local function Secret(v)
  if issecretvalue then
    local ok, r = pcall(issecretvalue, v)
    return ok and r
  end
  return false
end

local function Title(q)
  local r = K.Q and K.Q[q]
  local n = r and K.F and r[K.F.NAME]
  if type(n) == "string" and n ~= "" then return n end
  if C_QuestLog and C_QuestLog.GetTitleForQuestID then
    local ok, t = pcall(C_QuestLog.GetTitleForQuestID, q)
    if ok and type(t) == "string" and t ~= "" and not Secret(t) then return t end
  end
  return "퀘스트 " .. q
end

-- 내 위치: 지도 번호, x, y (0~100)
local function PlayerSpot()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
  local ok, m = pcall(C_Map.GetBestMapForUnit, "player")
  if not ok or type(m) ~= "number" or Secret(m) then return nil end
  local ok2, pos = pcall(C_Map.GetPlayerMapPosition, m, "player")
  if not ok2 or type(pos) ~= "table" then return m end
  local x, y = pos.x, pos.y
  if type(pos.GetXY) == "function" then x, y = pos:GetXY() end
  if type(x) ~= "number" or type(y) ~= "number" or Secret(x) or Secret(y) then return m end
  return m, x * 100, y * 100
end

-- KQuestGuide 목표 자료의 후보: { map, loc = { "q", 퀘스트, 지역, x, y, 이름 } }
local function DataSpots(q)
  local out = {}
  local all = rawget(_G, "KQG_OBJ")
  local rows = type(all) == "table" and all[q]
  if type(rows) ~= "table" then return out end
  for _, o in ipairs(rows) do
    local map = K.UiMapOf and K.UiMapOf(o[3])
    if map and type(o[4]) == "number" and type(o[5]) == "number" then
      local name = (o[1] == "e") and "탐험 지점" or tostring(o[2] or "목표")
      out[#out + 1] = { map = map, loc = { "q", q, o[3], o[4], o[5], name } }
    end
  end
  return out
end

-- 게임이 주는 퀘스트 지도 위치 (지금 있는 지도만)
local function GameSpot(q)
  local m = PlayerSpot()
  if not (m and C_QuestLog and C_QuestLog.GetQuestsOnMap) then return nil end
  local ok, list = pcall(C_QuestLog.GetQuestsOnMap, m)
  if not ok or type(list) ~= "table" then return nil end
  for _, p in ipairs(list) do
    if p.questID == q and type(p.x) == "number" and type(p.y) == "number" and not Secret(p.x) and not Secret(p.y) then
      return { map = m, loc = { "q", q, nil, p.x * 100, p.y * 100, "퀘스트 위치(게임 정보)" } }
    end
  end
  return nil
end

-- 지금 있는 지도의 가장 가까운 후보, 없으면 자료 순서상 첫 후보
local function Nearest(spots)
  local m, px, py = PlayerSpot()
  local best, bestD
  for _, s in ipairs(spots) do
    if m and px and s.map == m then
      local dx, dy = s.loc[4] - px, s.loc[5] - py
      local d = dx * dx + dy * dy
      if not bestD or d < bestD then best, bestD = s, d end
    end
  end
  return best or spots[1]
end

-- (0.29.1) KQuestGuide 자료에 위치가 없을 때 쓰는 보조 위치 ------------------------------
-- 순서: Questie 자료(읽기만) → 게임이 주는 퀘스트 지도 위치(퀘스트 지도) → 게임의 다음 목적지(GetNextWaypoint)

-- Questie의 QuestieDB 모듈 (Questie가 없거나 준비 전이면 nil). Cleanup.lua와 같은 방식
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

-- Questie 지역 번호 → 지도 번호 (KQuestGuide 표 먼저, 없으면 Questie ZoneDB)
local function AreaMap(area)
  local m = K.UiMapOf and K.UiMapOf(area)
  if m then return m end
  local QL = rawget(_G, "QuestieLoader")
  if type(QL) ~= "table" or type(QL.ImportModule) ~= "function" then return nil end
  local ok, Z = pcall(QL.ImportModule, QL, "ZoneDB")
  if not ok or type(Z) ~= "table" or type(Z.GetUiMapIdByAreaId) ~= "function" then return nil end
  local ok2, mm = pcall(Z.GetUiMapIdByAreaId, Z, area)
  if ok2 and type(mm) == "number" and mm > 0 then return mm end
  return nil
end

-- Questie 출현 위치 표 { [지역] = { {x, y}, ... } }를 후보 목록에 넣습니다 (최대 40개)
local function AddSpawns(out, spawns, q, name)
  if type(spawns) ~= "table" then return end
  for area, list in pairs(spawns) do
    local map = type(area) == "number" and AreaMap(area)
    if map and type(list) == "table" then
      for _, p in ipairs(list) do
        if #out >= 40 then return end
        if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and p[1] > 0 and p[2] > 0 then
          out[#out + 1] = { map = map, loc = { "q", q, area, p[1], p[2], tostring(name) .. " (Questie)" } }   -- 출처 표시(README 규칙)
        end
      end
    end
  end
end

-- NPC(npcs)와 오브젝트(objs) 번호들의 출현 위치
local function AddUnits(out, db, npcs, objs, q, label)
  for _, id in ipairs(type(npcs) == "table" and npcs or {}) do
    if type(id) == "number" then
      local nm = QGet(db.QueryNPCSingle, id, "name")
      AddSpawns(out, QGet(db.QueryNPCSingle, id, "spawns"), q, (type(nm) == "string" and nm) or label)
    end
  end
  for _, id in ipairs(type(objs) == "table" and objs or {}) do
    if type(id) == "number" then
      local nm = QGet(db.QueryObjectSingle, id, "name")
      AddSpawns(out, QGet(db.QueryObjectSingle, id, "spawns"), q, (type(nm) == "string" and nm) or label)
    end
  end
end

-- Questie: 제출 NPC(finishedBy) 위치
local function QuestieTurnIn(q)
  local db = QDB()
  if not db then return {} end
  local out = {}
  local fb = QGet(db.QueryQuestSingle, q, "finishedBy")
  if type(fb) == "table" then AddUnits(out, db, fb[1], fb[2], q, "퀘스트 제출 NPC") end
  return out
end

-- Questie: 목표(objectives = { 몬스터, 오브젝트, 아이템, ... }) 위치. 아이템은 떨어뜨리는 몬스터·오브젝트로 찾습니다
local function QuestieGoals(q)
  local db = QDB()
  if not db then return {} end
  local out = {}
  local o = QGet(db.QueryQuestSingle, q, "objectives")
  if type(o) ~= "table" then return out end
  local npcs, objs = {}, {}
  for _, e in ipairs(type(o[1]) == "table" and o[1] or {}) do npcs[#npcs + 1] = type(e) == "table" and e[1] or nil end
  for _, e in ipairs(type(o[2]) == "table" and o[2] or {}) do objs[#objs + 1] = type(e) == "table" and e[1] or nil end
  AddUnits(out, db, npcs, objs, q, "목표")
  for _, e in ipairs(type(o[3]) == "table" and o[3] or {}) do
    local item = type(e) == "table" and e[1]
    if type(item) == "number" then
      AddUnits(out, db, QGet(db.QueryItemSingle, item, "npcDrops"), QGet(db.QueryItemSingle, item, "objectDrops"), q, "목표")
    end
  end
  return out
end

-- 게임: 퀘스트가 속한 지도의 퀘스트 위치, 없으면 다음 목적지. 다른 지도에 있어도 찾습니다
local function GameAnySpot(q, name)
  if C_QuestLog and C_QuestLog.GetQuestsOnMap then
    local maps = {}
    local m = PlayerSpot()
    if m then maps[#maps + 1] = m end
    local fn = rawget(_G, "GetQuestUiMapID")
    if type(fn) == "function" then
      local ok, qm = pcall(fn, q)
      if ok and type(qm) == "number" and qm > 0 and not Secret(qm) and qm ~= m then maps[#maps + 1] = qm end
    end
    for _, mp in ipairs(maps) do
      local ok, list = pcall(C_QuestLog.GetQuestsOnMap, mp)
      if ok and type(list) == "table" then
        for _, p in ipairs(list) do
          if p.questID == q and type(p.x) == "number" and type(p.y) == "number" and not Secret(p.x) and not Secret(p.y) then
            return { map = mp, loc = { "q", q, nil, p.x * 100, p.y * 100, name } }
          end
        end
      end
    end
  end
  if C_QuestLog and C_QuestLog.GetNextWaypoint then
    local ok, mp, x, y = pcall(C_QuestLog.GetNextWaypoint, q)
    if ok and type(mp) == "number" and type(x) == "number" and type(y) == "number"
      and not Secret(mp) and not Secret(x) and not Secret(y) and x > 0 and y > 0 then
      return { map = mp, loc = { "q", q, nil, x * 100, y * 100, name } }
    end
  end
  return nil
end

-- 목표가 없는 퀘스트(전달·대화)인지: 게임이 목표 목록을 비워서 주면 그렇다고 봅니다
local function NoObjectives(q)
  if not (C_QuestLog and C_QuestLog.GetQuestObjectives) then return false end
  local ok, objs = pcall(C_QuestLog.GetQuestObjectives, q)
  return ok and type(objs) == "table" and #objs == 0
end

-- 제출 NPC 위치: KQuestGuide 자료 → Questie → 게임 순서
local function TurnInSpot(q)
  local r = K.Q and K.Q[q]
  local e = r and K.F and r[K.F.END]
  local map = type(e) == "table" and K.UiMapOf and K.UiMapOf(e[3])
  if map and type(e[4]) == "number" and type(e[5]) == "number" then return { map = map, loc = e } end
  local spots = QuestieTurnIn(q)
  if #spots > 0 then return Nearest(spots) end
  return GameAnySpot(q, "퀘스트 제출 위치(게임 정보)")
end

-- 이 퀘스트로 안내할 단계를 만듭니다. 위치를 모르면 nil과 이유
local function BuildStep(q)
  if K.LogComplete and K.LogComplete(q) then
    local s = TurnInSpot(q)
    if s then
      return { kind = "turnin", key = KEY .. q, loc = s.loc, map = s.map, quests = { q }, label = "[경로안내] 제출: " .. Title(q) }
    end
    return nil, "제출할 NPC의 위치 정보가 없습니다"
  end
  local spots = DataSpots(q)
  local s = (#spots > 0) and Nearest(spots) or GameSpot(q)
  if not s then
    -- (0.29.1) 목표가 없는 전달·대화 퀘스트는 제출 NPC가 목적지입니다
    if NoObjectives(q) then
      local t = TurnInSpot(q)
      if t then
        return { kind = "turnin", key = KEY .. q, loc = t.loc, map = t.map, quests = { q }, label = "[경로안내] 전달: " .. Title(q) }
      end
    end
    local qs = QuestieGoals(q)
    s = (#qs > 0) and Nearest(qs) or GameAnySpot(q, "퀘스트 위치(게임 정보)")
  end
  if not s then return nil, "목표 위치 정보가 없습니다" end
  return { kind = "doing", key = KEY .. q, loc = s.loc, map = s.map, quests = { q }, label = "[경로안내] " .. Title(q) }
end

-- 안내할 수 있는 퀘스트인지 (메뉴에 항목을 보일지 정할 때)
-- (0.35.3) 제출 위치 (Extras.lua 완료 가능 목록이 지역을 나눌 때 씀)
K.TurnInSpot = function(q)
  local ok, s = pcall(TurnInSpot, q)
  return ok and s or nil
end

K.CanRoute = function(q)
  if type(q) ~= "number" or Secret(q) or q <= 0 then return false end
  local ok, g = pcall(BuildStep, q)
  return ok and g ~= nil
end

-- 지도 위치 → 게임 세계 좌표(야드): 대륙 번호, x, y
local function WorldPos(map, x, y)
  if not (map and x and y and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
  local ok, inst, pos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x / 100, y / 100))
  if not ok or not inst or type(pos) ~= "table" then return nil end
  local wx, wy = pos:GetXY()
  if type(wx) ~= "number" or type(wy) ~= "number" or Secret(wx) or Secret(wy) then return nil end
  return inst, wx, wy
end

-- 경로안내 끝내기. reason: 채팅에 보일 이유
local function EndRoute(reason)
  local r = route
  route = nil
  if not r then return end
  local f = K.GetForced and K.GetForced()
  if f and f.key == r.key then
    K.SetForced(nil)
    -- 경로안내를 시작하면서 켜진 평소 안내는 원래대로 끕니다.
    if r.prevOff and K.GuideSet then K.GuideSet(true) end
  end
  if reason then Print(reason .. ": " .. Title(r.q)) end
end

-- 공통 경로 안내 함수
K.RouteQuest = function(q)
  if type(q) ~= "number" or Secret(q) or q <= 0 then return false end
  if not K.SetForced then return false end
  local g, why = BuildStep(q)
  if not g then
    Print(why .. ": " .. Title(q))
    return false
  end
  local prevOff = (route and route.prevOff) or (K.GuideIsOff and K.GuideIsOff()) or false
  local inst, wx, wy = WorldPos(g.map, g.loc[4], g.loc[5])
  route = { q = q, kind = g.kind, key = g.key, inst = inst, wx = wx, wy = wy, prevOff = prevOff }
  K.SetForced(g)
  local where = K.MapName and K.MapName(g.map) or tostring(g.map)
  Print("경로 안내: " .. Title(q) .. " - " .. tostring(g.loc[6] or "")
    .. string.format(" (%.0f, %.0f, %s)", g.loc[4], g.loc[5], tostring(where)))
  return true
end

-- 다른 안내가 목적지를 가져갔으면 손을 뗍니다 (그 안내는 건드리지 않음).
local function StillOurs()
  if not route then return false end
  local f = K.GetForced and K.GetForced()
  if f and f.key == route.key then return true end
  route = nil
  return false
end

-- 퀘스트 상태 확인 (퀘스트 목록이 갱신된 뒤 확인하도록 조금 늦게)
local function CheckQuest()
  if not StillOurs() then return end
  local q = route.q
  if K.InLog and not K.InLog(q) then
    EndRoute("퀘스트가 목록에서 사라져 경로 안내를 마쳤습니다")
  elseif route.kind == "doing" and K.LogComplete and K.LogComplete(q) then
    EndRoute("퀘스트를 완료해서 경로 안내를 마쳤습니다")
  end
end

-- 도착 확인
local function CheckArrive()
  if not StillOurs() or not route.inst then return end
  local m, px, py = PlayerSpot()
  local inst, wx, wy = WorldPos(m, px, py)
  if not inst or inst ~= route.inst then return end
  local limit = (route.kind == "turnin") and ARRIVE_TURNIN or ARRIVE_DOING
  local dx, dy = wx - route.wx, wy - route.wy
  if dx * dx + dy * dy <= limit * limit then
    EndRoute(route.kind == "turnin" and "제출 NPC에 도착해서 경로 안내를 마쳤습니다"
      or "목표 지역에 도착해서 경로 안내를 마쳤습니다")
  end
end

local watcher = CreateFrame("Frame")
local checkAt = nil
local arriveAcc = 0
watcher:RegisterEvent("QUEST_LOG_UPDATE")
pcall(watcher.RegisterEvent, watcher, "QUEST_TURNED_IN")
pcall(watcher.RegisterEvent, watcher, "QUEST_REMOVED")
watcher:SetScript("OnEvent", function()
  if route then checkAt = GetTime() + 0.5 end
end)
watcher:SetScript("OnUpdate", function(_, el)
  if not route then return end
  if checkAt and GetTime() >= checkAt then
    checkAt = nil
    pcall(CheckQuest)
  end
  arriveAcc = arriveAcc + (el or 0)
  if arriveAcc >= 0.25 then
    arriveAcc = 0
    pcall(CheckArrive)
  end
end)
