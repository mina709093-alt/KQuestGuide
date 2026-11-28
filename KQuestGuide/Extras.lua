-- (0.34.0) 첫 단계 설명에 덧붙이는 줄: KQG.ExtraLines(g)
--   * 근처에서 같이: 첫 단계 목적지에서 약 80야드 안에 있는 다른 단계(다른 퀘스트의 목표·제출)
--   * 지역을 떠나기 전 요약([다음 지역] 단계일 때): 진행 중 퀘스트를 제출할 지역별로 묶어서 보여 줌
--   * 귀환석([이동]/[복귀]/[다음 지역] 단계, Shortest Path Forever가 없을 때만):
--     귀환 장소와 사용 가능 여부. SPF가 있으면 SPF가 귀환석까지 넣어 길을 찾으므로 보이지 않습니다.
-- KQuestGuide.lua의 화면 갱신에서만 부릅니다. 오류가 나도 안내가 멈추지 않게 부르는 쪽에서 pcall로 감쌉니다.

local K = KQG
if type(K) ~= "table" then return end

local NEAR_YARDS = 80   -- 근처로 보는 거리 (야드)
local NEAR_MAX = 3      -- 근처 줄 최대 개수
local HEARTH = 6948     -- 귀환석 아이템 번호

local KIND_KO = { accept = "수락", turnin = "제출", doing = "수행" }

local function Plain(v)
  if type(issecretvalue) == "function" then
    local ok, sec = pcall(issecretvalue, v)
    if not ok or sec then return nil end
  end
  return v
end

local function WorldXY(uiMap, x, y)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
  local ok, _, pos = pcall(C_Map.GetWorldPosFromMapPos, uiMap, CreateVector2D(x / 100, y / 100))
  if ok and pos then
    local wx, wy = pos:GetXY()
    return Plain(wx), Plain(wy)
  end
  return nil
end

-- 같은 지도 위 두 지점 사이 야드 (월드 좌표가 없으면 대략값)
local function Yards(map, ax, ay, bx, by)
  local wx1, wy1 = WorldXY(map, ax, ay)
  local wx2, wy2 = WorldXY(map, bx, by)
  if wx1 and wy1 and wx2 and wy2 then
    return math.sqrt((wx1 - wx2) ^ 2 + (wy1 - wy2) ^ 2)
  end
  return math.sqrt(((ax - bx) * 1.5) ^ 2 + (ay - by) ^ 2) * 10
end

local function HasLoc(g)
  return g and g.map and g.loc and type(g.loc[4]) == "number" and type(g.loc[5]) == "number"
    and g.loc[4] >= 0 and g.loc[5] >= 0   -- (0.38.1) (-1, -1)은 인스턴스 안이라 좌표 없음
end

local function SharesQuest(a, b)
  for _, x in ipairs(a.quests or {}) do
    for _, y in ipairs(b.quests or {}) do
      if x == y then return true end
    end
  end
  return false
end

-- 근처에서 같이 할 수 있는 다른 단계
local function NearLines(g, steps)
  local out = {}
  if not HasLoc(g) or g.kind == "travel" then return out end
  local found = {}
  for i = 2, #steps do
    local s = steps[i]
    if HasLoc(s) and s.map == g.map and s.kind ~= "travel" and not s.who and not SharesQuest(g, s) then
      local d = Yards(g.map, g.loc[4], g.loc[5], s.loc[4], s.loc[5])
      if d <= NEAR_YARDS then found[#found + 1] = { s = s, d = d } end
    end
  end
  table.sort(found, function(a, b) return a.d < b.d end)
  for i = 1, math.min(NEAR_MAX, #found) do
    local s, d = found[i].s, found[i].d
    local qid = s.quests and s.quests[1]
    local name = qid and K.QName(qid) or ""
    if s.quests and #s.quests > 1 then name = name .. " 외 " .. (#s.quests - 1) .. "개" end
    out[#out + 1] = "  [" .. (KIND_KO[s.kind] or "이동") .. "] " .. name
      .. string.format(" (%d야드)", math.floor(d + 0.5))
  end
  if #out > 0 then table.insert(out, 1, "|cff10d0a0근처에서 같이 할 일|r") end
  return out
end

-- 지역을 떠나기 전: 진행 중 퀘스트를 제출할 지역별로
local function LeaveLines()
  local out = {}
  local Q, F = K.Q, K.F
  local log = K.LogSet and K.LogSet() or {}
  local byMap, order = {}, {}
  for id in pairs(log) do
    local r = Q and Q[id]
    local e = r and r[F.END]
    local m = e and e[3] and K.UiMapOf(e[3])
    local key = m or 0
    if not byMap[key] then byMap[key] = { done = 0, list = {} } order[#order + 1] = key end
    local b = byMap[key]
    b.list[#b.list + 1] = id
    if K.LogComplete(id) then b.done = b.done + 1 end
  end
  if #order == 0 then return out end
  table.sort(order, function(a, b)
    local da, db = byMap[a].done, byMap[b].done
    if da ~= db then return da > db end
    if (a == 0) ~= (b == 0) then return b == 0 end
    return a < b
  end)
  out[#out + 1] = "|cff10d0a0진행 중 퀘스트 제출 지역|r"
  for i = 1, math.min(3, #order) do
    local key = order[i]
    local b = byMap[key]
    table.sort(b.list)
    local nm = key == 0 and "제출 위치 모름" or K.MapName(key)
    local t = "  " .. nm .. ": " .. #b.list .. "개"
    if b.done > 0 then t = t .. " (완료 " .. b.done .. "개)" end
    t = t .. " - " .. K.QName(b.list[1])
    if #b.list > 1 then t = t .. " 등" end
    out[#out + 1] = t
  end
  if #order > 3 then out[#out + 1] = "  그 밖의 지역 " .. (#order - 3) .. "곳" end
  return out
end

local function Call(f, ...)
  if type(f) ~= "function" then return nil end
  local ok, a, b = pcall(f, ...)
  if not ok then return nil end
  return Plain(a), Plain(b)
end

local function HasSPF()
  local s = rawget(_G, "ShortestPathForever")
  return type(s) == "table" and type(s.API) == "table"
end

-- 귀환석 줄 (SPF가 없고, 가방에 귀환석이 있을 때만)
local function HearthLine()
  if HasSPF() then return nil end
  local countF = (C_Item and C_Item.GetItemCount) or rawget(_G, "GetItemCount")
  local n = Call(countF, HEARTH)
  if type(n) ~= "number" or n < 1 then return nil end
  local home = Call(rawget(_G, "GetBindLocation"))
  if type(home) ~= "string" or home == "" then return nil end
  local cdF = (C_Container and C_Container.GetItemCooldown) or (C_Item and C_Item.GetItemCooldown)
  local start, dur = Call(cdF, HEARTH)
  local left = 0
  if type(start) == "number" and type(dur) == "number" and dur > 1.5 and start > 0 then
    left = math.max(0, start + dur - GetTime())
  end
  local st = left > 0 and string.format("%d분 뒤 사용 가능", math.ceil(left / 60)) or "지금 사용 가능"
  return "|cff6bb8d6귀환석: " .. home .. " (" .. st .. ")|r"
end

function K.ExtraLines(g)
  local out = {}
  if not g then return out end
  local steps = K.Steps and K.Steps() or {}
  if steps[1] == g then
    for _, l in ipairs(NearLines(g, steps)) do out[#out + 1] = l end
  end
  if g.state == "MOVING_TO_NEXT_REGION" and type(g.key) == "string" and string.sub(g.key, 1, 6) == "region" then
    for _, l in ipairs(LeaveLines()) do out[#out + 1] = l end
  end
  if g.kind == "travel" then
    local h = HearthLine()
    if h then out[#out + 1] = h end
  end
  return out
end

-- 이동 단계의 안내 문구: SPF가 있으면 SPF가 비행·배·귀환석까지 넣어 길을 찾습니다.
function K.TravelHint(noSPF)
  if HasSPF() then return "Shortest Path Forever가 비행경로·배·귀환석을 포함한 길을 안내합니다." end
  return noSPF
end

-- (0.35.3) 완료 가능 퀘스트: 퀘스트 목록에서 목표를 다 채운 퀘스트를 제출 지역별로 묶습니다.
--   반환: { { map=, name=, items = { { qid=, next=다음 퀘스트(연계일 때), npc=제출 NPC 이름 }, ... } }, ... }
--   순서: 지금 있는 지역 → 퀘스트가 많은 지역 → 지역 이름 순, 제출 위치를 모르는 퀘스트는 맨 뒤.
--   [연계]: 우리 자료의 다음 퀘스트(F.NEXT)가 있고 내 종족·직업이 받을 수 있으며 아직 안 한 것. 없으면 [종료].
local spotCache = {}   -- [퀘스트] = { map, npc } 또는 false(못 찾음) / 못 찾은 것은 30초 뒤 다시
local spotMiss = {}
local function ReadySpot(qid)
  local c = spotCache[qid]
  if c then return c end
  if c == false and GetTime() - (spotMiss[qid] or 0) < 30 then return nil end
  local s = K.TurnInSpot and K.TurnInSpot(qid)
  if s and s.map then
    c = { map = s.map, npc = s.loc and s.loc[6] }
    spotCache[qid] = c
    return c
  end
  spotCache[qid], spotMiss[qid] = false, GetTime()
  return nil
end

local function NextOf(qid)
  local Q, F = K.Q, K.F
  local nx = K.NextChain and K.NextChain(qid)[1]
  local r = nx and Q[nx]
  if r and K.Bit(r[F.RACES], K.RaceBit()) and K.Bit(r[F.CLASSES], K.ClassBit())
    and not (K.IsDone and K.IsDone(nx)) then
    return nx
  end
  return nil
end

function K.ReadyList()
  local log = K.LogSet and K.LogSet() or {}
  local here
  if C_Map and C_Map.GetBestMapForUnit then
    local ok, m = pcall(C_Map.GetBestMapForUnit, "player")
    if ok then here = Plain(m) end
  end
  local byMap, order = {}, {}
  for qid in pairs(log) do
    if K.LogComplete(qid) then
      local s = ReadySpot(qid)
      local key = s and s.map or 0
      local gr = byMap[key]
      if not gr then
        gr = { map = s and s.map or nil, name = s and K.MapName(s.map) or "제출 위치 모름", items = {} }
        byMap[key] = gr
        order[#order + 1] = gr
      end
      gr.items[#gr.items + 1] = { qid = qid, next = NextOf(qid), npc = s and s.npc }
    end
  end
  table.sort(order, function(a, b)
    local ra = (a.map == nil) and 2 or ((here and a.map == here) and 0 or 1)
    local rb = (b.map == nil) and 2 or ((here and b.map == here) and 0 or 1)
    if ra ~= rb then return ra < rb end
    if #a.items ~= #b.items then return #a.items > #b.items end
    return a.name < b.name
  end)
  for _, gr in ipairs(order) do
    table.sort(gr.items, function(a, b) return a.qid < b.qid end)
  end
  return order
end
