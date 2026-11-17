-- 퀘스트 수집: 길잡이 데이터에 없는 퀘스트를 직접 겪으면서 기록하고, 바로 안내에 씁니다.
--  - 수락할 때: 퀘스트 번호, 이름, 레벨, 목표 문구, 준 NPC와 위치
--  - 진행할 때: 목표 숫자가 오른 순간의 내 위치 (몬스터/아이템 위치)
--  - 제출할 때: 받은 NPC와 위치
-- 데이터에 있지만 목표 위치가 없는 퀘스트도 목표 위치만 모읍니다.
-- 저장: KQGDB.found[퀘스트번호] (계정 공용). 추측으로 채우는 값은 없습니다.
local KQG = KQG
if not KQG then return end

local AREA_BASE = 100000      -- 수집 데이터의 지역 번호 = 100000 + 지도 번호
local MAX_PTS = 8              -- 목표 하나당 저장할 위치 수
local MIN_GAP = 4              -- 같은 목표의 위치끼리 최소 거리 (지도 % 단위)

local function DB()
  local d = KQG.DB and KQG.DB()
  if not d then return nil end
  d.found = d.found or {}
  return d
end

local function Pos()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local m = C_Map.GetBestMapForUnit("player")
  if not m then return nil end
  local p = C_Map.GetPlayerMapPosition(m, "player")
  if not p then return nil end
  local x, y = p:GetXY()
  if not x or (x == 0 and y == 0) then return nil end
  return m, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
end

local function NpcId(unit)
  local g = UnitGUID and UnitGUID(unit)
  if not g or (issecretvalue and issecretvalue(g)) then return 0, nil end
  local kind, _, _, _, _, id = strsplit("-", g)
  return tonumber(id) or 0, kind
end

-- 지금 퀘스트 창을 띄운 상대 (NPC 또는 물건)
local function Giver()
  for _, u in ipairs({ "questnpc", "npc" }) do
    if UnitExists and UnitExists(u) then
      local name = UnitName(u)
      if name and not (issecretvalue and issecretvalue(name)) then
        local id, kind = NpcId(u)
        return { kind = (kind == "GameObject") and "o" or "n", id = id, name = name }
      end
    end
  end
  return nil
end

local function Loc(g)
  local m, x, y = Pos()
  if not m then return nil end
  return { g and g.kind or "n", g and g.id or 0, m, x, y, g and g.name or "?", UnitFactionGroup and (UnitFactionGroup("player") == "Horde" and "H" or "A") or "A" }
end

local function CleanText(t)
  t = tostring(t or "")
  t = t:gsub("%s*:%s*%d+%s*/%s*%d+%s*$", ""):gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*%(완료%)", "")
  return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

local TYPE = { monster = "k", item = "i", object = "o", event = "e", log = "e" }

local function Objectives(qid)
  local list = {}
  if C_QuestLog and C_QuestLog.GetQuestObjectives then
    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, qid)
    if ok and type(objs) == "table" then
      for i, o in ipairs(objs) do
        list[i] = { type = TYPE[o.type] or "k", name = CleanText(o.text), have = o.numFulfilled or 0, need = o.numRequired or 0 }
      end
    end
  end
  return list
end

local function QuestLevel(qid)
  if C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetInfo then
    local idx = C_QuestLog.GetLogIndexForQuestID(qid)
    local info = idx and C_QuestLog.GetInfo(idx)
    if info and info.level and info.level > 0 then return info.level end
  end
  return nil
end

local function Title(qid)
  if C_QuestLog and C_QuestLog.GetTitleForQuestID then
    local ok, t = pcall(C_QuestLog.GetTitleForQuestID, qid)
    if ok and t and t ~= "" then return t end
  end
  return nil
end

-- 원래 데이터에 있는지 (수집으로 넣은 것은 제외)
local original = {}
local function InOriginal(qid)
  local v = original[qid]
  if v == nil then
    local r = KQG.Q and KQG.Q[qid]
    v = (r ~= nil and not r.found) and true or false
    original[qid] = v
  end
  return v
end

---------------------------------------------------------------------------
-- 길잡이 데이터에 넣기
---------------------------------------------------------------------------
local function Area(m)
  local a = AREA_BASE + m
  if KQG_MAP then KQG_MAP[a] = m end
  return a
end

local function ToLoc(l)
  if not l or not l[3] then return nil end
  return { l[1], l[2], Area(l[3]), l[4], l[5], l[6], l[7] }
end

local function InjectOne(qid, f)
  local Q = KQG_DATA
  if not Q then return end
  if not InOriginal(qid) and f.title then
    local s, e = ToLoc(f.start), ToLoc(f["end"])
    local r = { f.title, f.lvl or 0, nil, 0, nil, nil, nil, nil, nil, s and s[3] or (e and e[3]), s, e,
      f.text or "" }
    r.found = true
    Q[qid] = r
  end
  -- 목표 위치 (원래 데이터에 목표 위치가 없을 때만)
  local OBJ = KQG_OBJ
  if OBJ and f.obj and (not OBJ[qid] or OBJ[qid].found) then
    local list = { found = true }
    for _, o in ipairs(f.obj) do
      for _, p in ipairs(o.pts or {}) do
        list[#list + 1] = { o.type or "k", o.name or "?", Area(p[1]), p[2], p[3] }
      end
    end
    if #list > 0 then OBJ[qid] = list end
  end
end

-- 애드온에 들어 있는 취합 데이터(FoundData.lua)와 내 기록을 합쳐 본 모습
local function View(qid)
  local d = DB()
  local f = d and d.found[qid]
  local b = KQG_FOUND and KQG_FOUND[qid]
  if not b then return f end
  if not f then return b end
  local v = {}
  for k, x in pairs(b) do v[k] = x end
  for k, x in pairs(f) do if k ~= "obj" then v[k] = x end end
  v.obj = {}
  for k, o in pairs(b.obj or {}) do v.obj[k] = o end
  for k, o in pairs(f.obj or {}) do
    if (o.pts and #o.pts > 0) or not v.obj[k] then v.obj[k] = o end
  end
  return v
end

KQG.InjectFound = function()
  local d = DB()
  if not d then return end
  local seen = {}
  for qid in pairs(KQG_FOUND or {}) do seen[qid] = true end
  for qid in pairs(d.found) do seen[qid] = true end
  for qid in pairs(seen) do local v = View(qid) if v then pcall(InjectOne, qid, v) end end
end

local function Changed(qid, received)
  local d = DB()
  if not d or not d.found[qid] then return end
  pcall(InjectOne, qid, View(qid))
  if KQG.RebuildIndex then KQG.RebuildIndex() end
  if not received and SangsuData and SangsuData.Changed then SangsuData:Changed("KQG") end
end

---------------------------------------------------------------------------
-- 이벤트
---------------------------------------------------------------------------
local pendingStart = {}   -- [qid] = 수락 창을 연 상대와 위치
local pendingEnd = {}     -- [qid] = 제출 창을 연 상대와 위치
local lastTurn            -- { qid, npc, t } 직전에 낸 퀘스트 (연계 참고용)
local counts = {}         -- [qid] = { 목표별 숫자 }

local function Entry(qid, create)
  local d = DB()
  if not d then return nil end
  local f = d.found[qid]
  if not f and create then
    f = { t = time and time() or 0 }
    d.found[qid] = f
  end
  return f
end

-- 목표 위치를 모을 퀘스트: 원래 데이터에 없거나, 있어도 목표 위치가 없는 퀘스트
local function WantObjectives(qid)
  if not InOriginal(qid) then return true end
  local OBJ = KQG_OBJ
  return not (OBJ and OBJ[qid] and not OBJ[qid].found)
end

local function SnapshotCounts(qid)
  local c = {}
  for i, o in ipairs(Objectives(qid)) do c[i] = o.have end
  counts[qid] = c
end

local function OnAccept(qid)
  if not qid or qid == 0 then return end
  if not InOriginal(qid) then
    local f = Entry(qid, true)
    f.title = Title(qid) or f.title
    f.lvl = QuestLevel(qid) or f.lvl
    local st = pendingStart[qid]
    if st and not f.start then f.start = st.loc end
    if not f.start then f.start = Loc(nil) end   -- 아이템/자동 수락: 받은 자리
    if lastTurn and st and st.giver and lastTurn.npc == st.giver.id and GetTime() - lastTurn.t < 180 then
      f.after = lastTurn.qid    -- 참고용 (선행 조건으로는 쓰지 않음)
    end
    local objs = Objectives(qid)
    f.obj = f.obj or {}
    for i, o in ipairs(objs) do
      f.obj[i] = f.obj[i] or { type = o.type, name = o.name, need = o.need, pts = {} }
      f.obj[i].name = o.name
    end
    if KQG.Print and not (KQG_FOUND and KQG_FOUND[qid]) then KQG.Print("새 퀘스트 기록: " .. tostring(f.title) .. " (데이터에 없던 퀘스트)") end
    Changed(qid)
  end
  pendingStart[qid] = nil
  if WantObjectives(qid) then SnapshotCounts(qid) end
end

local function AddPoint(qid, i, o)
  local m, x, y = Pos()
  if not m then return end
  local f = Entry(qid, true)
  f.obj = f.obj or {}
  local e = f.obj[i]
  if not e then
    e = { type = o.type, name = o.name, need = o.need, pts = {} }
    f.obj[i] = e
  end
  e.pts = e.pts or {}
  for _, p in ipairs(e.pts) do
    if p[1] == m and math.abs(p[2] - x) < MIN_GAP and math.abs(p[3] - y) < MIN_GAP then return end
  end
  if #e.pts >= MAX_PTS then table.remove(e.pts, 1) end
  e.pts[#e.pts + 1] = { m, x, y }
  return true
end

local function ScanProgress()
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return end
  local changed = {}
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    local qid = info and not info.isHeader and info.questID
    if qid and WantObjectives(qid) then
      local prev = counts[qid]
      local objs = Objectives(qid)
      if prev then
        for k, o in ipairs(objs) do
          if prev[k] and o.have > prev[k] then
            if AddPoint(qid, k, o) then changed[qid] = true end
          end
        end
      end
      local c = {}
      for k, o in ipairs(objs) do c[k] = o.have end
      counts[qid] = c
    end
  end
  for qid in pairs(changed) do Changed(qid) end
end

local function OnTurnIn(qid)
  if not qid or qid == 0 then return end
  local en = pendingEnd[qid]
  pendingEnd[qid] = nil
  if not InOriginal(qid) then
    local f = Entry(qid, true)
    f.title = f.title or Title(qid)
    if en and en.loc then f["end"] = en.loc end
    f.done = (f.done or 0) + 1
    Changed(qid)
  end
  lastTurn = { qid = qid, npc = en and en.giver and en.giver.id, t = GetTime() }
  counts[qid] = nil
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "QUEST_DETAIL", "QUEST_ACCEPTED", "QUEST_COMPLETE", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE", "PLAYER_LOGIN" }) do
  pcall(ev.RegisterEvent, ev, e)
end
local scanAt
ev:SetScript("OnEvent", function(_, e, a1, a2)
  if e == "QUEST_DETAIL" then
    local qid = GetQuestID and GetQuestID()
    if qid and qid ~= 0 then
      local g = Giver()
      pendingStart[qid] = { giver = g, loc = Loc(g) }
    end
  elseif e == "QUEST_ACCEPTED" then
    local qid = a2 or a1      -- 클라이언트마다 (index, questID) 또는 (questID)
    if a2 == nil then qid = a1 end
    pcall(OnAccept, qid)
  elseif e == "QUEST_COMPLETE" then
    local qid = GetQuestID and GetQuestID()
    if qid and qid ~= 0 then
      local g = Giver()
      pendingEnd[qid] = { giver = g, loc = Loc(g) }
    end
  elseif e == "QUEST_TURNED_IN" then
    pcall(OnTurnIn, a1)
  elseif e == "QUEST_LOG_UPDATE" then
    if not scanAt then
      scanAt = true
      C_Timer.After(0.3, function() scanAt = nil pcall(ScanProgress) end)
    end
  elseif e == "PLAYER_LOGIN" then
    C_Timer.After(3, function() pcall(ScanProgress) end)
  end
end)

---------------------------------------------------------------------------
-- /kqg 수집
---------------------------------------------------------------------------
KQG.FoundCommand = function()
  local d = DB()
  if not d then return end
  local nq, np, ne = 0, 0, 0
  for qid, f in pairs(d.found) do
    if f.title and not InOriginal(qid) then nq = nq + 1 end
    if f["end"] then ne = ne + 1 end
    for _, o in ipairs(f.obj or {}) do np = np + #(o.pts or {}) end
  end
  local nb = 0
  for _ in pairs(KQG_FOUND or {}) do nb = nb + 1 end
  KQG.Print(string.format("애드온에 들어 있는 수집 퀘스트 %d개", nb))
  KQG.Print(string.format("수집한 퀘스트 %d개 (제출 위치 아는 것 %d개) / 목표 위치 %d곳", nq, ne, np))
  if SangsuData and SangsuData.Status then KQG.Print(SangsuData:Status()) end
  local shown = 0
  for qid, f in pairs(d.found) do
    if f.title and not InOriginal(qid) and shown < 10 then
      shown = shown + 1
      KQG.Print("  " .. qid .. " " .. f.title .. (f.start and f.start[6] and (" - " .. f.start[6]) or ""))
    end
  end
end

---------------------------------------------------------------------------
-- 파티/길드 공유 (상수팩 공용 공유 SangsuData 사용)
--   q:번호 = 이름/레벨/준 곳, e:번호 = 제출 곳, o:번호:목표 = 목표 위치
---------------------------------------------------------------------------
local function safe(v) return (tostring(v or ""):gsub("[|~%^,;:]", " ")) end
local function encLoc(l)
  if not l then return "" end
  return table.concat({ l[1] or "n", l[2] or 0, l[3] or 0, l[4] or 0, l[5] or 0, safe(l[6]), l[7] or "" }, "^")
end
local function decLoc(s)
  local t = {}
  for part in ((s or "") .. "^"):gmatch("([^%^]*)%^") do t[#t + 1] = part end
  local m, x, y = tonumber(t[3]), tonumber(t[4]), tonumber(t[5])
  if not (m and x and y) then return nil end
  return { t[1] == "o" and "o" or "n", tonumber(t[2]) or 0, m, x, y, t[6] ~= "" and t[6] or "?", t[7] ~= "" and t[7] or nil }
end
local function fields(s)
  local t = {}
  for part in ((s or "") .. "~"):gmatch("([^~]*)~") do t[#t + 1] = part end
  return t
end

local function HasKey(key)
  local kind, qid, i = key:match("^(%a):(%d+):?(%d*)$")
  qid, i = tonumber(qid), tonumber(i)
  if not qid then return true end
  local f = View(qid)
  if kind == "q" then return InOriginal(qid) or (f and f.title and f.start) and true or false
  elseif kind == "e" then return InOriginal(qid) or (f and f["end"]) and true or false
  elseif kind == "o" then
    if not WantObjectives(qid) then return true end
    local o = f and f.obj and f.obj[i]
    return (o and o.pts and #o.pts > 0) and true or false
  end
  return true
end

local function Keys()
  local d = DB()
  local t = {}
  if not d then return t end
  for qid, f in pairs(d.found) do
    local b = KQG_FOUND and KQG_FOUND[qid] or {}
    if not InOriginal(qid) then
      if f.title and f.start and not b.start then t[#t + 1] = "q:" .. qid end
      if f["end"] and not b["end"] then t[#t + 1] = "e:" .. qid end
    end
    if WantObjectives(qid) then
      for i, o in pairs(f.obj or {}) do
        local bo = b.obj and b.obj[i]
        if o.pts and #o.pts > 0 and not (bo and bo.pts and #bo.pts > 0) then t[#t + 1] = "o:" .. qid .. ":" .. i end
      end
    end
  end
  return t
end

local function Encode(key)
  local kind, qid, i = key:match("^(%a):(%d+):?(%d*)$")
  qid, i = tonumber(qid), tonumber(i)
  local d = DB()
  local f = d and qid and d.found[qid]
  if not f then return nil end
  if kind == "q" and f.title and f.start then
    return table.concat({ safe(f.title), f.lvl or 0, encLoc(f.start), f.after or "" }, "~")
  elseif kind == "e" and f["end"] then
    return encLoc(f["end"])
  elseif kind == "o" then
    local o = f.obj and f.obj[i]
    if not (o and o.pts and #o.pts > 0) then return nil end
    local pts = {}
    for _, p in ipairs(o.pts) do pts[#pts + 1] = p[1] .. ":" .. p[2] .. ":" .. p[3] end
    return table.concat({ o.type or "k", safe(o.name), o.need or 0, table.concat(pts, ";") }, "~")
  end
end

local function Apply(key, payload, who)
  local kind, qid, i = key:match("^(%a):(%d+):?(%d*)$")
  qid, i = tonumber(qid), tonumber(i)
  if not qid then return false end
  local f = Entry(qid, true)
  local t = fields(payload)
  if kind == "q" then
    local loc = decLoc(t[3])
    if not (t[1] and t[1] ~= "" and loc) then return false end
    f.title, f.lvl, f.start, f.after = t[1], tonumber(t[2]), loc, tonumber(t[4])
    f.rx = f.rx or who
  elseif kind == "e" then
    local loc = decLoc(payload)
    if not loc then return false end
    f["end"] = loc
    f.rx = f.rx or who
  elseif kind == "o" and i then
    local pts = {}
    for m, x, y in (t[4] or ""):gmatch("([%d.]+):([%d.]+):([%d.]+)") do
      pts[#pts + 1] = { tonumber(m), tonumber(x), tonumber(y) }
    end
    if #pts == 0 then return false end
    f.obj = f.obj or {}
    f.obj[i] = { type = t[1] ~= "" and t[1] or "k", name = t[2], need = tonumber(t[3]), pts = pts, rx = who }
  else
    return false
  end
  Changed(qid, true)
  return true
end

if SangsuData and SangsuData.Register then
  SangsuData:Register("KQG", {
    keys = Keys, has = HasKey, encode = Encode, apply = Apply,
    onReceived = function(total, from)
      KQG.Print(string.format("파티/길드원에게서 퀘스트 데이터 %d건을 받았습니다. (%s)", total, from))
    end,
  })
end
