-- KQuestGuide 파티 기능: 파티 명단과 같은 애드온 사용 여부, 지역 진행도 공유, 퀘스트 자동 공유, 파티 퀘스트(공동 계획)
-- (0.33.0) 공동 계획(PartyMerge), 단계별 필요한 파티원(PartyNeed), 새로 받은 퀘스트 계속 공유, 친구 퀘스트의 선행 안내(PrereqTick),
-- 다른 지도의 파티원은 빼고 계산, 나눠 보내는 메시지 C(완료 퀘스트)·L(긴 퀘스트 목록)·A(받을 수 있는 퀘스트)
local KQG = KQG
if not KQG then return end

local PREFIX = "KQGP"
local FONT_R = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Regular.ttf"
local FONT_B = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Bold.ttf"
local C_TEXT = { 0.93, 0.94, 0.96 }
local C_MUTED = { 0.55, 0.60, 0.63 }
-- 상수 스타일 색 (상수팩 공통 색)
local C_ACCENT = { 0.063, 0.816, 0.627 }
local C_SEL = { 0.045, 0.32, 0.26 }
local BG_ALPHA = 0.92
local C_GREEN = { 0.18, 0.64, 0.42 }
local C_RED = { 0.90, 0.25, 0.22 }
local ROWS = 5
local STALE = 120

local dbg = { sent = 0, sendFail = 0, lastResult = "-", recv = 0, recvMine = 0, lastRecv = "-", reg = "-", other = 0, errs = {} }
local lastShare = "-"
local lastActiveKey
local SetPartyQuest, Banner
local lockedOwner, partyAnchor, shareLocked
local syncState, syncCount, syncKey, syncChanged = nil, 0, "", 0   -- nil / "sharing" / "ready"
local roster = {}          -- 짧은 이름 -> 받은 정보
local frame
local lastSent, lastReq = 0, 0
local zoneCache = {}       -- 지도 -> { total, level }
-- (0.33.0) 공동 계획
local SYNC_VER = "1"       -- 새 메시지(C: 완료한 퀘스트, L: 퀘스트 목록, A: 받을 수 있는 퀘스트) 형식 번호. 번호가 다르면 무시합니다
local MAX_MSG = 250        -- 애드온 메시지는 255바이트까지라 여유를 둡니다
local shareKnown = nil     -- 공유가 끝난 뒤의 내 퀘스트 목록 (그 뒤에 새로 받은 퀘스트만 공유)
local shareHinted = {}     -- 자동 공유를 못 해서 "공유하기" 안내를 한 퀘스트
local prereqTold = {}      -- 선행을 안내한 친구 퀘스트
local pendList = {}        -- 조각으로 오는 C/L 메시지 임시 보관

local function Print(t)
  if KQG.Print then KQG.Print(t) end
end

-- 캐릭터 이름만 남깁니다. 이 서버는 보낸 사람 이름 뒤에 칭호("학살자" 등)가 붙어 오기도 해서
-- 공백 뒤는 잘라 내고, 서버 이름(-서버)도 뗍니다. (캐릭터 이름에는 공백이 들어갈 수 없습니다.)
local function Short(name)
  if not name then return "" end
  name = tostring(name)
  name = string.gsub(name, "%-.*$", "")
  name = string.gsub(name, "\194\160", " ")
  name = string.gsub(name, "%s.*$", "")
  return name
end

local function SetF(fs, size, bold)
  pcall(fs.SetFont, fs, bold and FONT_B or FONT_R, size or 12)
  return fs
end
local function Solid(tex, r, g, b, a)
  if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a or 1)
  else tex:SetTexture("Interface\\Buttons\\WHITE8X8") tex:SetVertexColor(r, g, b, a or 1) end
end

local function InParty()
  return (IsInGroup and IsInGroup()) and true or false
end

local function Channel()
  if IsInRaid and IsInRaid() then return "RAID" end
  return "PARTY"
end

local function RawSend(msg, chan, target)
  local fn = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not fn then dbg.lastResult = "함수 없음" return end
  local ok, res = pcall(fn, PREFIX, msg, chan, target)
  dbg.sent = dbg.sent + 1
  if not ok then
    dbg.sendFail = dbg.sendFail + 1
    dbg.lastResult = "오류: " .. tostring(res)
  else
    dbg.lastResult = chan .. " 결과=" .. tostring(res)
    if res ~= nil and res ~= 0 and res ~= true then dbg.sendFail = dbg.sendFail + 1 end
  end
end

-- 파티(레이드) 채널로만 보냅니다. (귓속말 보조 전송은 "접속해 있지 않습니다" 알림이 계속 떠서 뺐습니다.)
local function Send(msg)
  if not InParty() then return end
  RawSend(msg, Channel())
end

-- 내 지역 진행도 (현재 지도의 사용 가능한 퀘스트 중 완료한 수)
local function ZoneProgress(map)
  if not map then return 0, 0 end
  local Q, F = KQG.Q, KQG.F
  local lvl = UnitLevel("player") or 1
  local c = zoneCache[map]
  if not c or c.level ~= lvl then
    local ids = {}
    for id, r in pairs(Q) do
      if type(r) == "table" and (r[F.LVL] or 0) > 0 and r[F.ZONE] and KQG.UiMapOf(r[F.ZONE]) == map
        and (r[F.MIN] or r[F.LVL] or 0) <= lvl + 3
        and KQG.Bit(r[F.RACES], KQG.RaceBit()) and KQG.Bit(r[F.CLASSES], KQG.ClassBit()) then
        ids[#ids + 1] = id
      end
    end
    c = { ids = ids, level = lvl }
    zoneCache[map] = c
  end
  local done = 0
  for _, id in ipairs(c.ids) do
    if KQG.IsDone(id) then done = done + 1 end
  end
  return done, #c.ids
end

local function CurMap()
  local m
  pcall(function() m = C_Map.GetBestMapForUnit("player") end)
  return m
end

local function LogCount()
  local n = 0
  pcall(function()
    local _, q = GetNumQuestLogEntries()
    n = q or 0
  end)
  return n
end

local function MyStatus()
  local map = CurMap()
  local done, total = ZoneProgress(map)
  local ver = "?"
  pcall(function()
    local g = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    ver = g and g("KQuestGuide", "Version") or "?"
  end)
  local d = KQG.DB()
  return { ver = ver, level = UnitLevel("player") or 0, map = map or 0, log = LogCount(), zdone = done, ztotal = total, t = GetTime(), pm = d.partyMode and true or false, pq = d.partyQuest and true or false,
    syncing = (d.partyMode and not shareLocked and syncState ~= "ready") and true or false }
end

local function MyIds()
  local t = {}
  local set = KQG.LogSet and KQG.LogSet() or {}
  for id in pairs(set) do t[#t + 1] = id end
  table.sort(t)
  return table.concat(t, ",")
end

-- 상태 메시지. 퀘스트 목록이 길어 255바이트를 넘으면 목록을 비워 보내고, 목록은 L 메시지로 나눠 보냅니다(0.33.0)
local function Encode(st)
  local function Make(ids)
    return table.concat({ "S", st.ver, st.level, st.map, st.log, st.zdone, st.ztotal, ids, (st.pm and (st.syncing and 2 or 1) or 0), st.pq and 1 or 0 }, "|")
  end
  local msg = Make(MyIds())
  if #msg > MAX_MSG then return Make(""), true end
  return msg, false
end

-- 번호 목록을 30개씩 나눠 보냅니다: "<종류>|<형식 번호>|<조각>|<조각 수>|번호,번호,..." (예전 버전은 모르는 종류라 무시)
local function SendList(kind, ids)
  local per = 30
  local n = math.max(1, math.ceil(#ids / per))
  for i = 1, n do
    local part = {}
    for j = (i - 1) * per + 1, math.min(#ids, i * per) do part[#part + 1] = ids[j] end
    Send(kind .. "|" .. SYNC_VER .. "|" .. i .. "|" .. n .. "|" .. table.concat(part, ","))
  end
end

local function SortedLog(onlyComplete)
  local t = {}
  for id in pairs(KQG.LogSet and KQG.LogSet() or {}) do
    if not onlyComplete or (KQG.LogComplete and KQG.LogComplete(id)) then t[#t + 1] = id end
  end
  table.sort(t)
  return t
end

local function Broadcast(force)
  local now = GetTime()
  if not force and now - lastSent < 5 then return end
  lastSent = now
  local msg, cut = Encode(MyStatus())
  Send(msg)
  if cut then SendList("L", SortedLog(false)) end
  SendList("C", SortedLog(true))   -- (0.33.0) 완료한(제출만 남은) 퀘스트: "필요:" 표시용
  -- (0.33.0) 내 계산으로 지금 받을 수 있는 퀘스트(내 수락 단계, 파티원 단계 제외): 친구의 "필요:" 판단용
  local acc, seen = {}, {}
  for _, g in ipairs(KQG.StepsRaw and KQG.StepsRaw() or {}) do
    if g.kind == "accept" and not g.who then
      for _, q in ipairs(g.quests or {}) do if not seen[q] then seen[q] = true acc[#acc + 1] = q end end
    end
  end
  table.sort(acc)
  SendList("A", acc)
end

-- C/L 메시지 받기 (모든 조각이 모이면 반영)
local function RecvList(sender, msg)
  local kind, ver, i, n, ids = string.match(msg, "^(%a)|(%d+)|(%d+)|(%d+)|([%d,]*)$")
  if not kind or ver ~= SYNC_VER then return end   -- 형식이 다른(새) 버전의 메시지는 무시
  i, n = tonumber(i), tonumber(n)
  local key = sender .. kind
  local pe = pendList[key]
  if i == 1 or not pe or pe.n ~= n then pe = { n = n, parts = {} } pendList[key] = pe end
  pe.parts[i] = ids
  for k = 1, n do if pe.parts[k] == nil then return end end
  pendList[key] = nil
  local set = {}
  for k = 1, n do for id in string.gmatch(pe.parts[k], "%d+") do set[tonumber(id)] = true end end
  local st = roster[sender]
  if not st then return end
  if kind == "C" then st.done = set elseif kind == "L" then st.ids = set elseif kind == "A" then st.acc = set end
end

local function Request()
  local now = GetTime()
  if now - lastReq < 3 then return end
  lastReq = now
  Send("R")
end

local function Members()
  local list = {}
  local me = UnitName("player")
  list[#list + 1] = { name = me, unit = "player", me = true }
  if InParty() then
    local raid = IsInRaid and IsInRaid()
    local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    for i = 1, n do
      local unit = raid and ("raid" .. i) or ("party" .. i)
      if UnitExists(unit) and not UnitIsUnit(unit, "player") then
        list[#list + 1] = { name = UnitName(unit), unit = unit }
      end
    end
  end
  return list
end

local function ClassColor(unit)
  local _, cls = UnitClass(unit)
  local c = RAID_CLASS_COLORS and cls and RAID_CLASS_COLORS[cls]
  if c then return c.r, c.g, c.b end
  return C_TEXT[1], C_TEXT[2], C_TEXT[3]
end

local function Conditions()
  local ms = Members()
  local inParty = InParty() and #ms > 1
  local have, need = 0, #ms
  for _, m in ipairs(ms) do
    if m.me then have = have + 1
    else
      local st = roster[Short(m.name)]
      if st and GetTime() - st.t < STALE then have = have + 1 end
    end
  end
  return inParty, have, need, ms
end

-- 모든 파티원(애드온 사용자)이 나와 같은 지도에 있는지
local function AllSameMap()
  local myMap = CurMap()
  if not myMap then return false, "내 위치를 알 수 없음" end
  local ms = Members()
  for _, m in ipairs(ms) do
    if not m.me then
      local st = roster[Short(m.name)]
      if not st and KQG.DB().partyQuest then
        -- 파티 퀘스트 중에 들어온, 애드온이 없는 사람은 완전히 무시한다
      else
        if not st or GetTime() - st.t >= STALE then return false, "파티원 정보 없음" end
        if st.map ~= myMap then return false, Short(m.name) .. " 님이 다른 지역에 있음" end
      end
    end
  end
  return true
end

-- ===== 3단계: 같은 목표 (공동 수행 순서) =====
-- 같은 지역에서 파티 모드가 켜져 있으면, 지역 진행도가 가장 낮은 사람이 '기준'이 되어
-- 자신의 수행 순서를 보내고, 나머지는 그 순서대로 같은 퀘스트를 진행한다.
local ownerOrder = {}   -- 기준 파티원 이름 -> { rank = {qid=순번}, sig = "", t = 시각, n = 개수 }
local lastOrderSent, lastOrderSig = 0, ""
local pend = {}         -- 조각으로 오는 순서 임시 보관

local function Frac(st)
  if not st or not st.ztotal or st.ztotal <= 0 then return 0 end
  return (st.zdone or 0) / st.ztotal
end

-- 기준 파티원 이름 (같은 지역에 모두 있고 파티 모드일 때만)
local function OwnerName()
  local d = KQG.DB()
  if not (d and d.partyMode) then return nil end
  if not InParty() then return nil end
  if d.partyQuest and lockedOwner then return lockedOwner end
  -- (0.33.0) 다른 지도에 있는 파티원은 빼고 같은 지도의 파티원 중에서 고릅니다 (한 명 때문에 전체가 멈추지 않게)
  local myMap = CurMap()
  if not myMap then return nil end
  local best, bf
  for _, m in ipairs(Members()) do
    local st = m.me and MyStatus() or roster[Short(m.name)]
    if st and not m.me and (GetTime() - st.t >= STALE or st.map ~= myMap) then st = nil end
    if st then
      local nm = Short(m.name)
      local f = Frac(st)
      if not best or f < bf - 0.0001 or (math.abs(f - bf) <= 0.0001 and nm < best) then best, bf = nm, f end
    end
  end
  return best
end

KQG.PartyActive = function()
  local d = KQG.DB()
  return (d and d.partyMode and d.partyQuest and InParty()) and true or false
end

local function FreshOrder()
  local o = OwnerName()
  if not o or o == Short(UnitName("player")) then return nil, o end
  local t = ownerOrder[o]
  if t and GetTime() - t.t < STALE then return t, o end
  return nil, o
end

KQG.PartyAnchor = function()
  local d = KQG.DB()
  return nil
end

-- 퀘스트 갱신 버튼: 파티 퀘스트 중이면 지금 위치를 새 기준 지역으로 삼고, 그 자리에서 공유를 한 번 더 진행한다
KQG.PartyReanchor = function()
  local d = KQG.DB()
  if not (d and d.partyQuest) then return end
  shareLocked = false
  syncState = nil
  if KQG.Print then KQG.Print("기준 지역을 현재 위치로 바꿨습니다. 이 위치에서 퀘스트를 한 번 더 공유합니다.") end
end

KQG.PartyHasOrder = function()
  local t = FreshOrder()
  return t ~= nil
end

KQG.PartyRank = function(qid)
  local t = FreshOrder()
  if not t then return nil end
  return t.rank[qid]
end

KQG.PartyNote = function()
  local d = KQG.DB()
  if d.partyMode and syncState == "sharing" then
    return "|cffe0701f[퀘스트 공유 진행 중]|r 공유가 끝나면 같이 진행합니다. (" .. syncCount .. "개 남음)"
  end
  if not KQG.PartyActive() then return nil end
  if syncState == "sharing" then
    return "|cffe0701f[퀘스트 공유 진행 중]|r 공유가 끝나면 같이 진행합니다. (" .. syncCount .. "개 남음)"
  end
  local t, o = FreshOrder()
  if not o then return nil end
  if o == Short(UnitName("player")) then
    return "|cff4a9fc7[파티 진행]|r 내가 기준입니다. 파티원이 내 순서를 따라옵니다."
  elseif t then
    return "|cff4a9fc7[파티 진행]|r " .. o .. " 님의 순서에 맞춰 같은 퀘스트를 진행합니다."
  end
  return "|cff4a9fc7[파티 진행]|r " .. o .. " 님의 순서를 기다리는 중..."
end

-- ===== 기준 파티원의 현재 단계 (핀/점선 안내용) =====
local ownerSteps = {}   -- 기준 파티원 이름 -> { list = {...}, sig, t }
local pendSteps = {}
local lastStepSig, lastStepSent = "", 0

local function CutText(t, maxBytes)
  t = tostring(t or "")
  t = string.gsub(t, "[|~\n]", " ")
  local out, n = {}, 0
  for ch in string.gmatch(t, "[%z\1-\127\194-\244][\128-\191]*") do
    n = n + #ch
    if n > maxBytes then break end
    out[#out + 1] = ch
  end
  return table.concat(out)
end

local function SendSteps(force)
  if not KQG.PartyActive() then return end
  if OwnerName() ~= Short(UnitName("player")) then return end
  local raw = KQG.StepsRaw and KQG.StepsRaw() or {}
  local list = {}
  for i = 1, math.min(#raw, 6) do
    local g = raw[i]
    if g.map and g.loc and g.loc[4] and g.loc[5] then
      local ids = {}
      for k = 1, math.min(#(g.quests or {}), 3) do ids[#ids + 1] = g.quests[k] end
      list[#list + 1] = { kind = g.kind or "doing", map = g.map, x = g.loc[4], y = g.loc[5], ids = table.concat(ids, ","), name = CutText(g.loc[6], 36) }
    end
  end
  local parts = {}
  for _, e in ipairs(list) do parts[#parts + 1] = e.kind .. e.map .. string.format("%.1f%.1f", e.x, e.y) .. e.ids end
  local sig = table.concat(parts, ";")
  local now = GetTime()
  if not force and sig == lastStepSig and now - lastStepSent < 30 then return end
  lastStepSig, lastStepSent = sig, now
  local n = #list
  if n == 0 then Send("G|0|0|none|0|0|0||") return end
  for i, e in ipairs(list) do
    Send("G|" .. i .. "|" .. n .. "|" .. e.kind .. "|" .. e.map .. "|" .. string.format("%.1f", e.x) .. "|" .. string.format("%.1f", e.y) .. "|" .. e.ids .. "|" .. e.name)
  end
end

local function RecvSteps(sender, msg)
  local i, n, kind, map, x, y, ids, name = string.match(msg, "^G|(%d+)|(%d+)|(%a+)|(%d+)|([%d%.%-]+)|([%d%.%-]+)|([%d,]*)|(.*)$")
  if not i then return end
  i, n = tonumber(i), tonumber(n)
  if n == 0 then
    ownerSteps[sender] = { list = {}, sig = "", t = GetTime() }
    if KQG.Compute then pcall(KQG.Compute) end
    return
  end
  local pe = pendSteps[sender]
  if i == 1 or not pe or pe.n ~= n then pe = { n = n, list = {} } pendSteps[sender] = pe end
  pe.list[i] = { kind = kind, map = tonumber(map), x = tonumber(x), y = tonumber(y), ids = ids, name = name }
  for k = 1, n do if not pe.list[k] then return end end
  pendSteps[sender] = nil
  local parts = {}
  for _, e in ipairs(pe.list) do parts[#parts + 1] = e.kind .. e.map .. e.x .. e.y .. e.ids end
  local sig = table.concat(parts, ";")
  local old = ownerSteps[sender]
  ownerSteps[sender] = { list = pe.list, sig = sig, t = GetTime() }
  if not old or old.sig ~= sig then
    if KQG.Compute then pcall(KQG.Compute) end
  end
end

-- 따라가는 쪽: 기준 파티원의 단계를 내 단계 목록으로 바꿔 준다
KQG.PartyFollowSteps = function()
  if not KQG.PartyActive() then return nil end
  local o = OwnerName()
  if not o or o == Short(UnitName("player")) then return nil end
  local t = ownerSteps[o]
  if not t or GetTime() - t.t >= STALE or #t.list == 0 then return nil end
  local ost = roster[o]
  if ost and ost.map and ost.map ~= CurMap() then return nil end   -- (0.33.0) 기준이 다른 지역이면 내 계획대로
  local out = {}
  for i, e in ipairs(t.list) do
    local ids = {}
    for id in string.gmatch(e.ids or "", "%d+") do
      id = tonumber(id)
      if KQG.Q[id] then ids[#ids + 1] = id end
    end
    local g = {
      kind = e.kind, key = "party" .. i, quests = ids, map = e.map,
      loc = { "p", ids[1], nil, e.x, e.y, e.name, nil },
      who = o,
    }
    if e.kind == "travel" or #ids == 0 then
      g.kind = "travel"
      g.state = "MOVING_TO_NEXT_REGION"
      g.title = "|cffe0701f[파티 이동]|r " .. (KQG.MapName and KQG.MapName(e.map) or "목표 지역") .. "(으)로 이동"
      g.where = o .. " 님의 목표 지점으로 이동하세요."
    elseif e.kind == "turnin" then g.state = "MOVING_TO_TURN_IN_NPC"
    elseif e.kind == "accept" then g.state = "MOVING_TO_QUEST_GIVER"
    else g.state = "MOVING_TO_OBJECTIVE" end
    out[#out + 1] = g
  end
  return out
end

-- (0.33.0) 공동 계획: 기준 파티원의 단계 순서를 따르되, 같은 퀘스트를 다루는 내 단계가 있으면 내 단계를 쓰고
-- (내 위치·내 진행 기준), 기준에게 없는 내 단계는 뒤에 그대로 남깁니다. 예전에는 기준 단계로 통째로 바꿨습니다.
KQG.PartyMerge = function(mine, theirs)
  mine = mine or {}
  if not theirs or #theirs == 0 then return mine end
  local function Overlap(a, b)
    for _, x in ipairs(a.quests or {}) do
      for _, y in ipairs(b.quests or {}) do if x == y then return true end end
    end
    return false
  end
  local out, used = {}, {}
  for _, tg in ipairs(theirs) do
    local hit = false
    for i, mg in ipairs(mine) do
      if Overlap(mg, tg) then
        hit = true
        if not used[i] then used[i] = true out[#out + 1] = mg end
      end
    end
    if not hit then out[#out + 1] = tg end
  end
  for i, mg in ipairs(mine) do if not used[i] then out[#out + 1] = mg end end
  return out
end

-- (0.33.0) 이 단계가 필요한 파티원 이름 ("상수, 친구1"). 파티 모드가 아니거나 혼자면 nil
--   제출: 퀘스트를 들고 있고 완료함 / 수행: 들고 있고 아직 완료 안 함
--   수락: 나는 들고 있지 않고 끝내지 않음, 친구는 그 친구의 받을 수 있는 퀘스트 목록(A 메시지)에 있음
--   친구의 완료 여부는 C 메시지로 받습니다. 예전 버전 친구는 C·A가 없어 "수행"으로만 보이고 "수락"에는 안 나옵니다.
KQG.PartyNeed = function(g)
  local d = KQG.DB()
  if not (d and d.partyMode and InParty()) or type(g) ~= "table" or g.kind == "travel" then return nil end
  if type(g.quests) ~= "table" or #g.quests == 0 then return nil end
  local names, total = {}, 0
  for _, m in ipairs(Members()) do
    local set, done, acc
    if m.me then
      set = KQG.LogSet and KQG.LogSet() or {}
    else
      local st = roster[Short(m.name)]
      if st and st.ids and GetTime() - st.t < STALE then set, done, acc = st.ids, st.done or {}, st.acc end
    end
    if set then
      total = total + 1
      local need = false
      for _, q in ipairs(g.quests) do
        local comp
        if m.me then comp = KQG.LogComplete and KQG.LogComplete(q) else comp = done[q] and true or false end
        if g.kind == "turnin" then
          if set[q] and comp then need = true end
        elseif g.kind == "accept" then
          -- 친구는 그 친구가 보낸 "받을 수 있는 퀘스트"(A)에 있을 때만 (끝낸 퀘스트인지 모르므로 추측하지 않음)
          if m.me then
            if not set[q] and not (KQG.IsDone and KQG.IsDone(q)) then need = true end
          elseif acc and acc[q] then
            need = true
          end
        elseif set[q] and not comp then
          need = true
        end
      end
      if need then names[#names + 1] = Short(m.name) end
    end
  end
  if total < 2 or #names == 0 then return nil end
  return table.concat(names, ", ")
end

local function SendOrder(force)
  if not KQG.PartyActive() then return end
  if OwnerName() ~= Short(UnitName("player")) then return end
  local ids = KQG.StepQuestOrder and KQG.StepQuestOrder() or {}
  local sig = table.concat(ids, ",")
  local now = GetTime()
  if not force and sig == lastOrderSig and now - lastOrderSent < 30 then return end
  lastOrderSig, lastOrderSent = sig, now
  local per = 30
  local total = math.max(1, math.ceil(#ids / per))
  for i = 1, total do
    local part = {}
    for j = (i - 1) * per + 1, math.min(#ids, i * per) do part[#part + 1] = ids[j] end
    Send("P|" .. i .. "|" .. total .. "|" .. #ids .. "|" .. table.concat(part, ","))
  end
end

local function RecvOrder(sender, msg)
  local i, total, n, ids = string.match(msg, "^P|(%d+)|(%d+)|(%d+)|([%d,]*)$")
  if not i then return end
  i, total, n = tonumber(i), tonumber(total), tonumber(n)
  local pe = pend[sender]
  if i == 1 or not pe or pe.total ~= total then pe = { total = total, n = n, parts = {} } pend[sender] = pe end
  pe.parts[i] = ids
  for k = 1, total do if pe.parts[k] == nil then return end end
  local list = {}
  for k = 1, total do
    for id in string.gmatch(pe.parts[k], "%d+") do list[#list + 1] = tonumber(id) end
  end
  pend[sender] = nil
  local sig = table.concat(list, ",")
  local old = ownerOrder[sender]
  local rank = {}
  for r, id in ipairs(list) do rank[id] = r end
  ownerOrder[sender] = { rank = rank, sig = sig, t = GetTime(), n = #list }
  if not old or old.sig ~= sig then
    if KQG.Compute then pcall(KQG.Compute) end
  end
end

-- 나를 포함한 파티원 모두가 파티 모드를 켰는지
local function AllPM()
  if not KQG.DB().partyMode then return false end
  if not InParty() then return false end
  for _, m in ipairs(Members()) do
    if not m.me then
      local st = roster[Short(m.name)]
      if not st and KQG.DB().partyQuest then
        -- 애드온이 없는 파티원은 파티 퀘스트 진행 중에는 무시한다
      elseif not st or GetTime() - st.t >= STALE or not st.pm then return false end
    end
  end
  return true
end

-- 모두 파티 모드를 켜고, 퀘스트 공유까지 끝났는지
local function AllReady()
  if not AllPM() then return false end
  local me = MyStatus()
  if me.syncing then return false end
  for _, m in ipairs(Members()) do
    if not m.me then
      local st = roster[Short(m.name)]
      if st and st.syncing then return false end
    end
  end
  return true
end

KQG.PartyDebugState = function() return syncState, shareLocked, AllReady() end

local function Refresh()
  if not frame or not frame:IsShown() then return end
  local inParty, have, need, ms = Conditions()
  local allOk = inParty and (have == need or KQG.DB().partyQuest and true or false)
  frame.c1:SetText((inParty and "|cff2fa26a✔|r" or "|cffe04a3a✘|r") .. "  파티에 속해 있음")
  frame.c2:SetText((allOk and "|cff2fa26a✔|r" or "|cffe04a3a✘|r") .. "  파티원 모두 이 애드온 사용 (" .. have .. "/" .. need .. ")")
  local on = KQG.DB().partyMode and true or false
  if on and not allOk then
    KQG.DB().partyMode = false
    on = false
  end
  if not on then KQG.DB().partyQuest = false end
  local allPm = AllReady()
  do
    local qon = KQG.DB().partyQuest and true or false
    frame.qbtn.label:SetText(qon and "파티 퀘스트 중지" or "파티 퀘스트 시작")
    local qb = qon and { 0.045, 0.32, 0.26 } or (allPm and { 0.18, 0.64, 0.42 } or { 0.055, 0.085, 0.10 })
    frame.qbtn.base = qb
    frame.qbtn.hover = qon and { 0.06, 0.40, 0.32 } or (allPm and { 0.24, 0.74, 0.50 } or { 0.08, 0.12, 0.14 })
    Solid(frame.qbtn.bg, qb[1], qb[2], qb[3], 1)
    frame.qbtn.label:SetTextColor(allPm and 1 or 0.55, allPm and 1 or 0.58, allPm and 1 or 0.62)
  end
  frame.btn.label:SetText(on and "파티 모드 끄기" or "파티 모드 시작")
  local base = on and { 0.045, 0.32, 0.26 } or (allOk and C_SEL or { 0.055, 0.085, 0.10 })
  frame.btn.base = base
  frame.btn.hover = on and { 0.06, 0.40, 0.32 } or (allOk and { 0.06, 0.40, 0.32 } or { 0.08, 0.12, 0.14 })
  Solid(frame.btn.bg, base[1], base[2], base[3], 1)
  frame.btn.enabled = allOk or on
  local same, why = AllSameMap()
  frame.sameOk = same
  frame.last:SetText((on and not AllPM() and "|cffe6c229모든 파티원이 파티 모드를 켜면 퀘스트 공유가 시작되고, 끝나면 파티 퀘스트를 시작할 수 있습니다.|r\n" or "") .. (syncState == "sharing" and "|cffe0701f퀘스트 공유 진행 중 (" .. syncCount .. "개 남음)|r\n" or (syncState == "ready" and "|cff2fa26a파티 모드 정상 실행|r\n" or "")) .. "최근 공유: " .. lastShare .. (same and "" or ("\n|cffe6c229공유 대기: " .. tostring(why) .. "|r")))
  if frame.tShare and frame.tShare.refresh then frame.tShare.refresh() end
  frame.btn.label:SetTextColor(1, 1, 1)
  for i = 1, ROWS do
    local row = frame.rows[i]
    local m = ms[i]
    if m then
      local st = m.me and MyStatus() or roster[Short(m.name)]
      local fresh = st and (m.me or GetTime() - st.t < STALE)
      row.name:SetText(Short(m.name))
      row.name:SetTextColor(ClassColor(m.unit))
      if fresh then
        row.addon:SetText("|cff2fa26a사용|r")
        row.lv:SetText(tostring(st.level))
        local mn = KQG.MapName and st.map and st.map > 0 and KQG.MapName(st.map) or "-"
        row.zone:SetText(mn)
        row.pm:SetText(st.pm and (st.syncing and "|cffe6c229●|r" or "|cff2fa26a●|r") or "|cffe04a3a●|r")
        row.pq:SetText((st.pm and st.pq) and "|cff2fa26a●|r" or "|cffe04a3a●|r")
      else
        row.addon:SetText("|cffe04a3a미사용|r")
        row.lv:SetText(UnitLevel(m.unit) and tostring(UnitLevel(m.unit)) or "-")
        row.zone:SetText("-")
        row.pm:SetText("|cff666666●|r")
        row.pq:SetText("|cff666666●|r")
      end
      row:Show()
    else
      row:Hide()
    end
  end
end

-- 퀘스트 자동 공유 ---------------------------------------------------------------

local shareTried = {}      -- 퀘스트 번호 -> 마지막 시도 시각

local function QuestTitle(id)
  local r = KQG.Q[id]
  if r then return r[KQG.F.NAME] end
  return "퀘스트 " .. tostring(id)
end

local function Pushable(qid)
  local ok = true
  pcall(function()
    if C_QuestLog and C_QuestLog.IsPushableQuest then ok = C_QuestLog.IsPushableQuest(qid) and true or false
    elseif GetQuestLogPushable then ok = GetQuestLogPushable() and true or false end
  end)
  return ok
end

local function PushQuest(qid)
  local idx = KQG.LogIndex and KQG.LogIndex(qid)
  local okSel = false
  pcall(function()
    if C_QuestLog and C_QuestLog.SetSelectedQuest then C_QuestLog.SetSelectedQuest(qid) okSel = true end
  end)
  if not okSel and idx and SelectQuestLogEntry then pcall(SelectQuestLogEntry, idx) end
  if not Pushable(qid) then return false, "공유 불가" end
  local fn = QuestLogPushQuest or (C_QuestLog and C_QuestLog.PushQuest)
  if not fn then return false, "공유 함수 없음" end
  local ok, err = pcall(fn)
  if not ok then return false, tostring(err) end
  return true
end

-- 보호된 거리 함수(CheckInteractDistance)는 쓰지 않는다 (포에버에서 "기능 차단" 창이 뜰 수 있음)
local function InRange(unit)
  if UnitInRange then
    local ok, r, checked = pcall(UnitInRange, unit)
    if not ok then return true end
    -- 거리 값이 비밀값(secret)이면 참/거짓 검사만 해도 오류가 나므로, 검사 전에 먼저 걸러 낸다
    if issecretvalue then
      local okS, sec = pcall(function() return issecretvalue(r) or issecretvalue(checked) end)
      if not okS or sec then return true end
    end
    if checked then return r and true or false end
  end
  return true
end

-- (0.34.2) 이 지역에서 할 퀘스트인지. 지금 안내 단계에 있거나, 퀘스트 지역·목표 위치·제출 NPC가 이 지도에 있거나,
-- 게임이 이 지도에 표시하는 퀘스트일 때만 그렇다고 봅니다. 알 수 없으면 공유하지 않습니다
-- (0.34.1까지는 알 수 없는 퀘스트도 공유해서, 파티 모드를 켜면 목록 전체를 공유했습니다).
local function HereCheck(map)
  local plan, onMap = {}, {}
  for _, g in ipairs(KQG.Steps and KQG.Steps() or {}) do
    if g.map == map and not g.who then
      for _, q in ipairs(g.quests or {}) do plan[q] = true end
    end
  end
  if map and C_QuestLog and C_QuestLog.GetQuestsOnMap then
    local ok, list = pcall(C_QuestLog.GetQuestsOnMap, map)
    if ok and type(list) == "table" then
      for _, p in ipairs(list) do
        local q = type(p) == "table" and p.questID
        if type(q) == "number" and not (issecretvalue and issecretvalue(q)) then onMap[q] = true end
      end
    end
  end
  local obj = rawget(_G, "KQG_OBJ")
  return function(qid)
    if not map then return false end
    if plan[qid] or onMap[qid] then return true end
    local r = KQG.Q[qid]
    if r then
      local z = r[KQG.F.ZONE]
      if z and KQG.UiMapOf(z) == map then return true end
      local e = r[KQG.F.END]
      if e and e[3] and KQG.UiMapOf(e[3]) == map then return true end
    end
    local rows = type(obj) == "table" and obj[qid]
    if type(rows) == "table" then
      for _, o in ipairs(rows) do
        if o[3] and KQG.UiMapOf(o[3]) == map then return true end
      end
    end
    return false
  end
end

local function ShareTick()
  local db = KQG.DB()
  if not db.partyMode or db.partyShare == false then shareKnown = nil return end
  -- 파티 모드를 켠 직후 공유 단계(sharing)에서는 이 지역 퀘스트를 모두, 공유가 끝난 뒤(ready)에는
  -- 그 뒤에 새로 받은 퀘스트만 공유합니다(0.33.0. 예전에는 공유 단계에서만 공유).
  if syncState ~= "sharing" and syncState ~= "ready" then shareKnown = nil return end
  if InCombatLockdown and InCombatLockdown() then return end
  local set = KQG.LogSet()
  if syncState == "ready" then
    if not shareKnown then
      shareKnown = {}
      for qid in pairs(set) do shareKnown[qid] = true end
      return
    end
  else
    shareKnown = nil
  end
  local ms = Members()
  local map = CurMap()
  local others = {}
  for _, m in ipairs(ms) do
    if not m.me then
      local st = roster[Short(m.name)]
      if not st then return end   -- 애드온이 없는 사람이 파티에 있으면 퀘스트 공유창이 그 사람에게도 가므로 공유하지 않는다
      -- (0.33.0) 다른 지도에 있는 파티원은 빼고 같은 지도의 가까운 파티원에게만
      if st.ids and GetTime() - st.t < STALE and st.map == map and InRange(m.unit) then
        others[#others + 1] = st
      end
    end
  end
  if #others == 0 then return end
  local now = GetTime()
  local Here = HereCheck(map)
  for qid in pairs(set) do
    local inZone = Here(qid)
    local want = (syncState == "sharing") or not shareKnown[qid]
    if inZone and want and not (shareTried[qid] and now - shareTried[qid] < 180) then
      local lacking = false
      for _, st in ipairs(others) do
        if not st.ids[qid] then lacking = true end
      end
      if syncState == "ready" then shareKnown[qid] = true end
      if lacking then
        shareTried[qid] = now
        local ok, why = PushQuest(qid)
        if ok then
          lastShare = QuestTitle(qid) .. " 공유함"
          Print("파티원에게 퀘스트 공유: " .. QuestTitle(qid))
        else
          lastShare = QuestTitle(qid) .. " (" .. tostring(why) .. ")"
          -- 자동으로 못 하면 직접 공유하도록 한 번 안내합니다
          if syncState == "ready" and not shareHinted[qid] then
            shareHinted[qid] = true
            Print("「" .. QuestTitle(qid) .. "」를 자동으로 공유하지 못했습니다(" .. tostring(why) .. "). 퀘스트 목록에서 이 퀘스트를 고르고 [공유] 버튼을 눌러 주세요.")
          end
        end
        return  -- 한 번에 하나씩
      end
    end
  end
end

-- (0.33.0) 친구에게만 있고 나는 선행 퀘스트가 없어 공유받을 수 없는 퀘스트: 선행부터 안내합니다.
-- 이미 다른 지역 선행 안내(db.planTarget)가 있으면 알림만 하고 목표는 바꾸지 않습니다.
local function PrereqTick()
  local d = KQG.DB()
  if not (d.partyMode and InParty() and KQG.PrereqChain) then return end
  local map = CurMap()
  if not map then return end
  local set = KQG.LogSet and KQG.LogSet() or {}
  for _, m in ipairs(Members()) do
    if not m.me then
      local nm = Short(m.name)
      local st = roster[nm]
      if st and st.ids and GetTime() - st.t < STALE and st.map == map then
        local list = {}
        for qid in pairs(st.ids) do list[#list + 1] = qid end
        table.sort(list)
        for _, qid in ipairs(list) do
          if not set[qid] and not prereqTold[qid] then
            local ch = KQG.PrereqChain(qid)
            if ch then
              prereqTold[qid] = true
              Print(nm .. " 님의 「" .. QuestTitle(qid) .. "」는 선행 퀘스트 「" .. QuestTitle(ch[1]) .. "」를 먼저 해야 공유받을 수 있습니다. 선행 퀘스트부터 안내합니다.")
              if not d.planTarget then
                local r = KQG.Q[qid]
                local s = r and r[KQG.F.START]
                local sm = type(s) == "table" and s[3] and KQG.UiMapOf(s[3])
                d.planTarget = { qid = qid, map = sm or map }
                if KQG.Compute then pcall(KQG.Compute) end
              end
            end
          end
        end
      end
    end
  end
end

local function Announce(msg)
  Print(msg)
  pcall(function() if UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage(msg, 1, 0.82, 0.2, 1, 4) end end)
end

-- 공유가 필요한 퀘스트가 남았는지 확인해 "공유 진행 중" / "정상 실행" 상태를 알린다.
local function SyncTick0()
  local d = KQG.DB()
  if not (d.partyMode and InParty()) then
    syncState = nil
    shareLocked = false
    return
  end
  if d.partyQuest then
    for _, m in ipairs(Members()) do
      if not m.me and not roster[Short(m.name)] then shareLocked = true syncState = nil return end
    end
    if shareLocked then return end
  end
  if shareLocked then
    -- 공유가 끝난 상태: 누가 파티 모드를 끄면 처음부터 다시 한다
    if not AllPM() and not d.partyQuest then shareLocked = false syncState = nil end
    return
  end
  if not AllPM() then syncState = nil return end
  local set = KQG.LogSet and KQG.LogSet() or {}
  local map = CurMap()
  if not map then return end
  local pend, n = {}, 0
  local InZone = HereCheck(map)
  for _, m in ipairs(Members()) do
    if not m.me then
      local st = roster[Short(m.name)]
      -- (0.33.0) 다른 지도에 있는 파티원은 기다리지 않습니다
      if st and st.ids and GetTime() - st.t < STALE and st.map == map then
        for qid in pairs(set) do
          if not st.ids[qid] and InZone(qid) and Pushable(qid) then pend[qid] = true end
        end
        for qid in pairs(st.ids) do
          -- 내가 이미 끝낸 퀘스트나 선행이 없어 받을 수 없는 퀘스트는 공유를 기다리지 않음 (선행은 PrereqTick이 안내)
          if not set[qid] and InZone(qid) and not (KQG.IsDone and KQG.IsDone(qid))
            and not (KQG.PrereqChain and KQG.PrereqChain(qid)) then pend[qid] = true end
        end
      end
    end
  end
  local list = {}
  for qid in pairs(pend) do list[#list + 1] = qid end
  table.sort(list)
  n = #list
  local key = table.concat(list, ",")
  local now = GetTime()
  if key ~= syncKey then syncKey, syncChanged = key, now end
  syncCount = n
  local settled = (n == 0) or (now - syncChanged > 60)
  local prev = syncState
  syncState = settled and "ready" or "sharing"
  if syncState == "sharing" and prev ~= "sharing" then
    Print("파티 모드 실행 - 퀘스트 공유중...")
    Banner("파티 모드 실행", "퀘스트 공유중", 8)
  end
  if syncState ~= prev then pcall(Refresh) end
  if syncState == "ready" and prev ~= "ready" then
    Print("퀘스트 공유 종료 - " .. (d.partyQuest and "파티 퀘스트 진행 중" or "파티 퀘스트를 시작하세요"))
    shareLocked = true
    Banner("퀘스트 공유 종료", d.partyQuest and "파티 퀘스트 진행 중" or "파티 퀘스트를 시작하세요", 10)
    if KQG.Compute then pcall(KQG.Compute) end
  end
end

local lastSyncSig
local function SyncTick()
  SyncTick0()
  local sig = tostring(syncState) .. "/" .. tostring(shareLocked)
  if sig ~= lastSyncSig then
    lastSyncSig = sig
    Broadcast(true)
    pcall(Refresh)
  end
end

local bannerF
Banner = function(l1, l2, secs)
  if not bannerF then
    local b = CreateFrame("Frame", "KQGPartyBanner", UIParent)
    b:SetFrameStrata("FULLSCREEN_DIALOG")
    b:SetWidth(700)
    b:SetHeight(110)
    b:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    Solid(b.bg, 0.02, 0.035, 0.042, 0.80)
    b.t1 = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    b.t1:SetPoint("TOP", b, "TOP", 0, -16)
    SetF(b.t1, 32, true)
    b.t2 = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    b.t2:SetPoint("TOP", b.t1, "BOTTOM", 0, -10)
    SetF(b.t2, 24, true)
    b:SetScript("OnUpdate", function(self, el)
      el = el or arg1 or 0
      self.left = (self.left or 0) - el
      if self.left <= 0 then self:Hide() self:SetAlpha(1)
      elseif self.left < 1 then self:SetAlpha(self.left) end
    end)
    bannerF = b
  end
  bannerF.t1:SetText(l1 or "")
  bannerF.t2:SetText(l2 or "")
  bannerF.t1:SetTextColor(1, 0.82, 0.2)
  bannerF.t2:SetTextColor(1, 1, 1)
  bannerF.left = secs or 8
  bannerF:SetAlpha(1)
  bannerF:Show()
end

KQG.Banner = Banner

SetPartyQuest = function(on, remote, ownerArg)
  local db = KQG.DB()
  on = on and true or false
  if (db.partyQuest and true or false) == on then return end
  db.partyQuest = on
  if on then
    if KQG.SetAnchor then KQG.SetAnchor(CurMap()) end
    shareLocked = true   -- 공유는 파티 퀘스트 시작 전에 이미 끝났다
    lockedOwner = (ownerArg and ownerArg ~= "") and ownerArg or OwnerName()
    db.partyPrevGuideOff = KQG.GuideIsOff and KQG.GuideIsOff() or false
    if KQG.GuideSet then KQG.GuideSet(false) end
    Print("파티 퀘스트를 시작했습니다. 진행도가 가장 낮은 파티원의 퀘스트 순서에 맞춰 모두 같은 목표를 안내합니다.")
    Banner("파티 퀘스트 시작", "진행도가 가장 낮은 파티원을 따라 함께 진행합니다", 6)
  else
    partyAnchor, lockedOwner, shareLocked = nil, nil, nil
    if KQG.GuideSet then KQG.GuideSet(db.partyPrevGuideOff and true or false) end
    Print("파티 퀘스트를 중지했습니다. 각자 진행 순서로 돌아갑니다.")
  end
  lastActiveKey = nil
  if KQG.Compute then pcall(KQG.Compute) end
  pcall(SendOrder, true)
  pcall(SendSteps, true)
  if not remote then Send("Q|" .. (on and 1 or 0) .. "|" .. (on and tostring(lockedOwner or "") or "")) end
  Broadcast(true)
  Refresh()
end

local function Build()
  local f = CreateFrame("Frame", "KQGPartyFrame", UIParent)
  f:SetWidth(340)
  f:SetHeight(434)
  f:SetFrameStrata("MEDIUM")
  f:EnableMouse(true)
  f:Hide()
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  Solid(bg, 0.035, 0.055, 0.065, 1)
  local ac = f:CreateTexture(nil, "ARTWORK")
  ac:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  ac:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  ac:SetHeight(3)
  Solid(ac, C_GREEN[1], C_GREEN[2], C_GREEN[3], 1)
  for _, def in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
    { "TOPLEFT", "BOTTOMLEFT", "w" }, { "TOPRIGHT", "BOTTOMRIGHT", "w" } }) do
    local t = f:CreateTexture(nil, "BORDER")
    t:SetPoint(def[1], f, def[1], 0, 0)
    t:SetPoint(def[2], f, def[2], 0, 0)
    if def[3] == "h" then t:SetHeight(1) else t:SetWidth(1) end
    Solid(t, 0, 0, 0, 1)
  end
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
  SetF(title, 16, true)
  title:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  title:SetText("파티 진행")
  local x = CreateFrame("Button", nil, f)
  x:SetWidth(20)
  x:SetHeight(20)
  x:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
  x.l = x:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  x.l:SetPoint("CENTER", x, "CENTER", 0, 0)
  SetF(x.l, 15, true)
  x.l:SetText("X")
  x.l:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  x:SetScript("OnEnter", function() x.l:SetTextColor(1, 1, 1) end)
  x:SetScript("OnLeave", function() x.l:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3]) end)
  x:SetScript("OnClick", function() f:Hide() end)

  local hd = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hd:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -42)
  SetF(hd, 13, true)
  hd:SetTextColor(C_RED[1], C_RED[2], C_RED[3])
  hd:SetText("시작 조건")
  f.c1 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.c1:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -64)
  SetF(f.c1, 12)
  f.c2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.c2:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -84)
  SetF(f.c2, 12)

  local qbtn = CreateFrame("Button", nil, f)
  qbtn:SetWidth(312)
  qbtn:SetHeight(28)
  qbtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -110)
  qbtn.bg = qbtn:CreateTexture(nil, "BACKGROUND")
  qbtn.bg:SetAllPoints()
  qbtn.label = qbtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  qbtn.label:SetPoint("CENTER", qbtn, "CENTER", 0, 0)
  SetF(qbtn.label, 13, true)
  qbtn.base = { 0.055, 0.085, 0.10 }
  qbtn.hover = { 0.08, 0.12, 0.14 }
  qbtn:SetScript("OnEnter", function() Solid(qbtn.bg, qbtn.hover[1], qbtn.hover[2], qbtn.hover[3], 1) end)
  qbtn:SetScript("OnLeave", function() Solid(qbtn.bg, qbtn.base[1], qbtn.base[2], qbtn.base[3], 1) end)
  qbtn:SetScript("OnClick", function()
    local db = KQG.DB()
    if not db.partyMode then
      Print("먼저 아래의 '파티 모드 시작'을 눌러 주세요.")
      return
    end
    if not AllPM() then
      Print("파티원 모두가 파티 모드를 켜야 파티 퀘스트를 시작할 수 있습니다.")
      return
    end
    if not db.partyQuest and not AllReady() then
      Print("퀘스트 공유가 모두 끝나면 파티 퀘스트를 시작할 수 있습니다.")
      return
    end
    if db.partyQuest then
      SetPartyQuest(false, false)
    else
      if not AllSameMap() then
        Print("파티원이 모두 같은 지역에 있어야 시작할 수 있습니다.")
        return
      end
      SetPartyQuest(true, false)
    end
  end)
  f.qbtn = qbtn

  local btn = CreateFrame("Button", nil, f)
  btn:SetWidth(312)
  btn:SetHeight(28)
  btn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -144)
  btn.bg = btn:CreateTexture(nil, "BACKGROUND")
  btn.bg:SetAllPoints()
  btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  btn.label:SetPoint("CENTER", btn, "CENTER", 0, 0)
  SetF(btn.label, 13, true)
  btn.base = { 0.055, 0.085, 0.10 }
  btn.hover = { 0.08, 0.12, 0.14 }
  btn:SetScript("OnEnter", function() Solid(btn.bg, btn.hover[1], btn.hover[2], btn.hover[3], 1) end)
  btn:SetScript("OnLeave", function() Solid(btn.bg, btn.base[1], btn.base[2], btn.base[3], 1) end)
  btn:SetScript("OnClick", function()
    local db = KQG.DB()
    if db.partyMode then
      if db.partyQuest then SetPartyQuest(false, true) end
      db.partyMode = false
      syncState = nil
      shareLocked = false
      Print("파티 모드를 껐습니다.")
      Broadcast(true)
    else
      local inParty, have, need = Conditions()
      if not (inParty and have == need) then
        Print("조건이 충족되지 않았습니다. 파티원 모두 이 애드온을 쓰는지 확인해 주세요.")
        return
      end
      db.partyMode = true
      if KQG.SetAnchor then KQG.SetAnchor(CurMap()) end
      if KQG.Compute then pcall(KQG.Compute) end
      Print("파티 모드를 시작했습니다. 파티원 모두가 파티 모드를 켜면 퀘스트 공유가 시작됩니다.")
      Broadcast(true)
    end
    Refresh()
  end)
  f.btn = btn

  local function Toggle(label, field, x)
    local b = CreateFrame("Button", nil, f)
    b:SetWidth(153)
    b:SetHeight(24)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -178)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
    SetF(b.label, 12)
    b.label:SetTextColor(1, 1, 1)
    b.refresh = function()
      local on = KQG.DB()[field] ~= false
      if field == "partyShare" and frame and frame.sameOk == false then
        b.label:SetText(label .. " 비활성 (다른 지역)")
        b.label:SetTextColor(0.55, 0.57, 0.62)
        Solid(b.bg, 0.03, 0.045, 0.052, 1)
        return
      end
      b.label:SetTextColor(1, 1, 1)
      b.label:SetText(label .. " " .. (on and "켜짐" or "꺼짐"))
      if on then Solid(b.bg, 0.045, 0.32, 0.26, 1) else Solid(b.bg, 0.055, 0.085, 0.10, 1) end
    end
    b:SetScript("OnClick", function()
      if field == "partyShare" and frame and frame.sameOk == false then
        Print("파티원이 모두 같은 지역에 있어야 공유 버튼을 쓸 수 있습니다.")
        return
      end
      local d = KQG.DB()
      d[field] = not (d[field] ~= false)
      b.refresh()
    end)
    b.refresh()
    return b
  end
  f.tShare = Toggle("퀘스트 자동 공유", "partyShare", 14)
  f.tAccept = Toggle("자동 수락", "partyAccept", 173)

  local hd2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hd2:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -218)
  SetF(hd2, 13, true)
  hd2:SetTextColor(C_RED[1], C_RED[2], C_RED[3])
  hd2:SetText("파티원")
  local heads = { "이름", "애드온", "Lv", "지역", "파티 모드", "퀘스트" }
  local hx = { 0, 76, 126, 156, 230, 292 }
  for i, h in ipairs(heads) do
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + hx[i] + 4, -240)
    SetF(fs, 10)
    fs:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
    fs:SetText(h)
  end

  f.rows = {}
  local xs = { 0, 76, 126, 156, 230, 292 }
  local ws = { 74, 48, 28, 72, 60, 24 }
  for i = 1, ROWS do
    local row = CreateFrame("Frame", nil, f)
    row:SetWidth(312)
    row:SetHeight(22)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -256 - (i - 1) * 24)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    Solid(row.bg, 0.02, 0.035, 0.042, 1)
    local function Col(k, idx, just)
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", row, "LEFT", xs[idx] + 4, 0)
      fs:SetWidth(ws[idx])
      fs:SetJustifyH(just or "LEFT")
      SetF(fs, 11)
      fs:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
      pcall(fs.SetWordWrap, fs, false)
      row[k] = fs
    end
    Col("name", 1) Col("addon", 2) Col("lv", 3) Col("zone", 4) Col("pm", 5, "CENTER") Col("pq", 6, "CENTER")
    for _, k in ipairs({ "pm", "pq" }) do pcall(row[k].SetFont, row[k], STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 15, "") end
    row:Hide()
    f.rows[i] = row
  end
  local note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  note:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
  note:SetWidth(312)
  note:SetJustifyH("LEFT")
  SetF(note, 11)
  note:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  note:SetText("파티 모드 중에는 이 지역 퀘스트를 없는 파티원에게 자동으로 공유하고, 같이 하다 새로 받은 퀘스트도 공유해요. 안내 단계 옆 '필요:'는 그 단계가 필요한 파티원이에요. 친구 퀘스트의 선행이 없으면 선행부터 안내해요.")
  f.last = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.last:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 52)
  f.last:SetWidth(312)
  f.last:SetJustifyH("LEFT")
  SetF(f.last, 11)
  f.last:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  f:SetScript("OnShow", function()
    Broadcast(true)
    Request()
    Refresh()
  end)
  local acc = 0
  f:SetScript("OnUpdate", function(_, el)
    acc = acc + (el or arg1 or 0)
    if acc < 1 then return end
    acc = 0
    Refresh()
  end)
  frame = f
  -- 기본 애드온 창을 닫으면 파티 창도 같이 닫습니다.
  local main = _G["KQGFrame"]
  if main and main.HookScript then
    main:HookScript("OnHide", function()
      if frame then frame:Hide() end
      local gf = _G["KQGGearFrame"]
      if gf then gf:Hide() end
    end)
  end
end

local function Dock()
  local main = _G["KQGFrame"]
  if not (frame and main) then return end
  local base, side = main, "right"
  local gf = _G["KQGGearFrame"]
  if gf and gf.IsShown and gf:IsShown() then
    base = gf
    local gl, ml = gf:GetLeft(), main:GetLeft()
    if gl and ml and gl < ml then side = "left" end
  end
  if side == "right" then
    local r = base:GetRight()
    local sw = UIParent:GetWidth()
    if r and sw and r + frame:GetWidth() > sw then
      frame:ClearAllPoints()
      frame:SetPoint("TOPLEFT", base, "BOTTOMLEFT", 0, -2)
      return
    end
  end
  frame:ClearAllPoints()
  if side == "right" then
    frame:SetPoint("TOPLEFT", base, "TOPRIGHT", 0, 0)
  else
    frame:SetPoint("TOPRIGHT", base, "TOPLEFT", 0, 0)
  end
end

KQG.ToggleParty = function()
  if not frame then Build() end
  if frame:IsShown() then frame:Hide() else
    Dock()
    frame:Show()
  end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("QUEST_ACCEPT_CONFIRM")
local pendingAt
ev:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
  if event == "PLAYER_LOGIN" then
    local fn = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if fn then
      local ok, res = pcall(fn, PREFIX)
      dbg.reg = ok and ("결과=" .. tostring(res)) or ("오류: " .. tostring(res))
    else
      dbg.reg = "함수 없음"
    end
  elseif event == "CHAT_MSG_ADDON" then
    dbg.recv = dbg.recv + 1
    dbg.lastRecv = tostring(a1) .. " / " .. tostring(a3) .. " / " .. tostring(a4) .. " / " .. tostring(a2):sub(1, 40)
    if a1 ~= PREFIX then dbg.other = dbg.other + 1 return end
    dbg.recvMine = dbg.recvMine + 1
    local sender = Short(a4)
    if sender == Short(UnitName("player")) then return end
    local kind = string.sub(a2 or "", 1, 1)
    if kind == "S" then
      local ver, lv, map, log, zd, zt, ids, pmf, pqf = string.match(a2, "^S|([^|]*)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|([%d,]*)|(%d)|(%d)$")
      if not ver then
        ver, lv, map, log, zd, zt, ids = string.match(a2, "^S|([^|]*)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|([%d,]*)$")
      end
      if not ver then
        ver, lv, map, log, zd, zt = string.match(a2, "^S|([^|]*)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)")
      end
      if ver then
        local set
        if ids then
          set = {}
          for id in string.gmatch(ids, "%d+") do set[tonumber(id)] = true end
        end
        roster[sender] = { ver = ver, level = tonumber(lv), map = tonumber(map), log = tonumber(log),
          zdone = tonumber(zd), ztotal = tonumber(zt), t = GetTime(), ids = set, pm = (pmf == "1" or pmf == "2"), syncing = (pmf == "2"), pq = (pqf == "1") }
        Refresh()
      end
    elseif kind == "P" then
      RecvOrder(sender, a2)
    elseif kind == "G" then
      RecvSteps(sender, a2)
    elseif kind == "Q" then
      if KQG.DB().partyMode then SetPartyQuest(string.sub(a2, 3, 3) == "1", true, Short(string.match(a2, "^Q|%d|(.*)$") or "")) end
    elseif kind == "R" then
      pendingAt = GetTime() + 0.5
    elseif kind == "C" or kind == "L" or kind == "A" then
      RecvList(sender, a2)   -- (0.33.0) 완료한 퀘스트, 긴 퀘스트 목록, 받을 수 있는 퀘스트
    end
  elseif event == "GROUP_ROSTER_UPDATE" then
    for name in pairs(roster) do
      local still = false
      for _, m in ipairs(Members()) do if Short(m.name) == name then still = true end end
      if not still then roster[name] = nil end
    end
    if InParty() then
      pendingAt = GetTime() + 1.5
      lastReq = 0
    else
      KQG.DB().partyMode = false
      KQG.DB().partyQuest = false
    end
    Refresh()
  elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
    if InParty() then pendingAt = GetTime() + 2 end
  elseif event == "QUEST_ACCEPT_CONFIRM" then
    local d = KQG.DB()
    local from = roster[Short(a1)]
    if d.partyMode and d.partyAccept ~= false and from and GetTime() - from.t < STALE then
      local ok = pcall(ConfirmAcceptQuest)
      lastShare = "받음: " .. tostring(a2) .. (ok and " (자동 수락)" or " (수락 실패)")
      Print("파티원이 공유한 퀘스트를 자동 수락했습니다: " .. tostring(a2))
    end
  elseif event == "QUEST_LOG_UPDATE" then
    if InParty() and not pendingAt then pendingAt = GetTime() + 3 end
  end
end)
local acc2 = 0
local shareAcc = 0
local orderAcc = 0
ev:SetScript("OnUpdate", function(_, el)
  acc2 = acc2 + (el or arg1 or 0)
  if acc2 < 0.5 then return end
  acc2 = 0
  if InParty() and GetTime() - lastSent > 30 then Broadcast(true) end
  shareAcc = (shareAcc or 0) + 0.5
  if shareAcc >= 6 then
    shareAcc = 0
    local okS, errS = pcall(ShareTick)
    if not okS and KQG.ReportBug then KQG.ReportBug("파티공유", errS, "") end
  end
  if frame and frame:IsShown() then pcall(Dock) end
  orderAcc = (orderAcc or 0) + 0.5
  if orderAcc >= 3 then
    orderAcc = 0
    local okA, key = pcall(function() return tostring(KQG.PartyActive()) .. "/" .. tostring(OwnerName()) end)
    if okA and key ~= lastActiveKey then
      lastActiveKey = key
      if KQG.Compute then pcall(KQG.Compute) end
      pcall(SendOrder, true)
    end
    if KQG.DB().partyQuest then
      local stay = (lockedOwner == nil)
      for _, m in ipairs(Members()) do if Short(m.name) == lockedOwner then stay = true end end
      if not AllPM() or not stay then SetPartyQuest(false, true) end
    end
    local okY, errY = pcall(SyncTick)
    if not okY and KQG.ReportBug then KQG.ReportBug("파티동기", errY, "") end
    local okR, errR = pcall(PrereqTick)
    if not okR and KQG.ReportBug then KQG.ReportBug("파티선행", errR, "") end
    pcall(SendSteps, false)
    local okO, errO = pcall(SendOrder, false)
    if not okO and KQG.ReportBug then KQG.ReportBug("파티순서", errO, "") end
  end
  if pendingAt and GetTime() >= pendingAt then
    pendingAt = nil
    Broadcast(true)
    Request()
    pcall(SendOrder, true)
    pcall(SendSteps, true)
  end
end)


KQG.PartyDebugLines = function()
  local L = {}
  local inP = InParty()
  L[#L + 1] = "파티 " .. tostring(inP) .. " / 인원 " .. tostring(GetNumGroupMembers and GetNumGroupMembers()) .. " / 채널 " .. Channel()
  L[#L + 1] = "접두어 등록 " .. dbg.reg .. " / 보낸 수 " .. dbg.sent .. " (실패 " .. dbg.sendFail .. ") / 마지막 전송 " .. dbg.lastResult
  L[#L + 1] = "받은 애드온 메시지 " .. dbg.recv .. " (이 애드온 것 " .. dbg.recvMine .. ", 다른 것 " .. dbg.other .. ")"
  L[#L + 1] = "마지막 수신: " .. dbg.lastRecv
  local n = 0
  for name, st in pairs(roster) do
    n = n + 1
    L[#L + 1] = "명단 " .. name .. " 버전 " .. tostring(st.ver) .. " 지도 " .. tostring(st.map) .. " (" .. string.format("%.0f", GetTime() - st.t) .. "초 전)"
  end
  if n == 0 then L[#L + 1] = "명단: 비어 있음" end
  for _, m in ipairs(Members()) do L[#L + 1] = "파티원: " .. tostring(m.name) .. " [" .. tostring(m.unit) .. "]" end
  return L
end
KQG.PartyCommand = function()
  for _, t in ipairs(KQG.PartyDebugLines()) do Print(t) end
  Broadcast(true)
  Request()
end
