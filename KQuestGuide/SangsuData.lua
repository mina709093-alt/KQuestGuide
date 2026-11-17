-- 상수팩 공용 데이터 공유 (SangsuData.lua)
-- 데이터를 모으는 상수팩 애드온(퀘스트 길잡이, 마력 추출 도우미 ...)에 같은 파일로 들어 있습니다.
-- 여러 애드온에 들어 있어도 한 번만 동작하며, 번호가 가장 높은 파일의 코드가 쓰입니다.
--
-- 하는 일: 같은 파티/길드의 상수팩 사용자끼리, 각 애드온이 모은 데이터 중 상대에게 없는 것만 주고받습니다.
--   1) 인사(H): 내 데이터 요약(해시)을 알림
--   2) 목록(I): 요약이 다르면 애드온별로 내가 가진 키 목록을 보냄
--   3) 요청(Q): 상대 목록에서 내가 모르는 키를 요청
--   4) 데이터(D): 가진 사람이 보내 주고, 받은 쪽 애드온이 자기 기록에 합침
-- 모든 애드온이 한 줄로 보내므로 게임의 메시지 제한(약 1초에 1개)에 서로 걸리지 않습니다.
--
-- 애드온 쪽 사용법
--   SangsuData:Register("KQG", {
--     keys  = function() return { "q:123", ... } end,  -- 내가 줄 수 있는 키
--     has   = function(key) return true/false end,     -- 이미 가진 키인지 (애드온 기본 자료 포함)
--     encode = function(key) return "내용" end,        -- 키 → 보낼 내용 (200자 이하)
--     apply = function(key, payload, who) end,          -- 받은 내용 합치기
--   })
--   SangsuData:Changed("KQG")  -- 내 데이터가 늘었을 때 (1분 안에 목록을 다시 알림)

local VERSION = 1

local SD = _G.SangsuData
if SD and (SD.version or 0) >= VERSION then return end
SD = SD or {}
_G.SangsuData = SD
SD.version = VERSION
SD.spaces = SD.spaces or {}
SD.stats = SD.stats or { sent = 0, got = 0, peers = {} }

local PREFIX = "SangsuData"
local SEND_GAP, THROTTLE_WAIT, ERROR_WAIT = 1.1, 3, 30
local INV_GAP = 10 * 60
local MAX_LEN = 240
local MAX_WANT = 300

local format, concat, sort = string.format, table.concat, table.sort
local issecret = rawget(_G, "issecretvalue")
local function usable(v) return v ~= nil and not (issecret and issecret(v)) end
local token = format("%04x", math.random(0, 65535))

function SD:Register(name, p)
  self.spaces[name] = p
  p.list = nil
  self.hashAll = nil
end

---------------------------------------------------------------------------
-- 보내기 대기열
---------------------------------------------------------------------------
local queue, queued = {}, {}
local pauseUntil = 0
local function enqueue(msg, ch, dedupe)
  if not ch or #queue > 800 then return end
  local k = dedupe and (ch .. dedupe)
  if k then
    if queued[k] then return end
    queued[k] = true
  end
  queue[#queue + 1] = { msg = msg, ch = ch, key = k }
end

local pump = CreateFrame("Frame")
local acc = 0
pump:SetScript("OnUpdate", function(_, e)
  acc = acc + e
  if acc < SEND_GAP then return end
  acc = 0
  if #queue == 0 or GetTime() < pauseUntil then return end
  local item = queue[1]
  local fn = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not fn then return end
  local ok, res = pcall(fn, PREFIX, item.msg, item.ch)
  if ok and (res == nil or res == true or res == 0) then
    table.remove(queue, 1)
    if item.key then queued[item.key] = nil end
    SD.stats.sent = SD.stats.sent + 1
  elseif ok and res == 3 then
    pauseUntil = GetTime() + THROTTLE_WAIT
  else
    table.remove(queue, 1)
    if item.key then queued[item.key] = nil end
    pauseUntil = GetTime() + ERROR_WAIT
  end
end)

local function groupChannel()
  if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
  if IsInRaid and IsInRaid() then return "RAID" end
  if IsInGroup and IsInGroup() then return "PARTY" end
end
local function channels()
  local t = {}
  local g = groupChannel()
  if g then t[#t + 1] = g end
  if IsInGuild and IsInGuild() then t[#t + 1] = "GUILD" end
  return t
end

---------------------------------------------------------------------------
-- 내 키 목록
---------------------------------------------------------------------------
local function checksum(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 16777213 end
  return h
end

local function listOf(name)
  local p = SD.spaces[name]
  if not p then return {}, {} end
  if not p.list then
    local ok, keys = pcall(p.keys)
    local list, set = {}, {}
    if ok and type(keys) == "table" then
      for _, k in ipairs(keys) do
        k = tostring(k):gsub("[|,]", "")
        if not set[k] then set[k] = true list[#list + 1] = k end
      end
    end
    sort(list)
    p.list, p.set = list, set
  end
  return p.list, p.set
end

local function hashAll()
  if not SD.hashAll then
    local names = {}
    for n in pairs(SD.spaces) do names[#names + 1] = n end
    sort(names)
    local parts = {}
    for _, n in ipairs(names) do parts[#parts + 1] = n .. "=" .. concat(listOf(n), ",") end
    SD.hashAll = checksum(concat(parts, ";"))
  end
  return SD.hashAll
end

function SD:Changed(name)
  local p = self.spaces[name]
  if p then p.list = nil end
  self.hashAll = nil
  self.changedAt = self.changedAt or (GetTime() + 60)
end

---------------------------------------------------------------------------
-- 인사 / 목록
---------------------------------------------------------------------------
local lastHello, lastInv = {}, {}
local function sendHello(ch, force)
  if not force and lastHello[ch] and GetTime() - lastHello[ch] < 60 then return end
  lastHello[ch] = GetTime()
  enqueue(format("H|%s|%d", token, hashAll()), ch, "H")
end

local function sendInventory(ch, force)
  if not force and lastInv[ch] and GetTime() - lastInv[ch] < INV_GAP then return end
  lastInv[ch] = GetTime()
  for name in pairs(SD.spaces) do
    local list = listOf(name)
    if #list > 0 then
      local head = format("I|%s|%s|", token, name)
      local cur = head
      for _, k in ipairs(list) do
        if #cur + #k + 1 > MAX_LEN then enqueue(cur, ch) cur = head end
        cur = cur .. (cur == head and "" or ",") .. k
      end
      if cur ~= head then enqueue(cur, ch) end
    end
  end
end

function SD:Hello()
  for _, ch in ipairs(channels()) do sendHello(ch, true) end
end

---------------------------------------------------------------------------
-- 받기
---------------------------------------------------------------------------
local wants = {}   -- token -> { ch, spaces = { name -> { keys, n } } }
local gotFrom, summaryAt = {}, nil

local function split(msg, n)
  local f, pos = {}, 1
  for i = 1, n - 1 do
    local s, e = msg:find("|", pos, true)
    if not s then f[i] = msg:sub(pos) return f end
    f[i] = msg:sub(pos, s - 1)
    pos = e + 1
  end
  f[n] = msg:sub(pos)
  return f
end

local function onMessage(prefix, msg, ch, sender)
  if prefix ~= PREFIX or not usable(msg) or type(msg) ~= "string" then return end
  local kind = msg:sub(1, 1)
  local who = usable(sender) and sender or "?"
  if Ambiguate then who = Ambiguate(who, "none") end
  if kind == "H" then
    local f = split(msg, 3)
    if f[2] == token then return end
    SD.stats.peers[f[2]] = { who = who, at = GetTime() }
    if tonumber(f[3]) ~= hashAll() then
      sendHello(ch)
      sendInventory(ch)
    end
  elseif kind == "I" then
    local f = split(msg, 4)
    local from, name, csv = f[2], f[3], f[4] or ""
    if from == token then return end
    local p = SD.spaces[name]
    if not p then return end
    local _, mine = listOf(name)
    local w = wants[from] or { ch = ch, spaces = {} }
    wants[from] = w
    local s = w.spaces[name] or { keys = {}, n = 0 }
    w.spaces[name] = s
    for k in csv:gmatch("[^,]+") do
      if s.n < MAX_WANT and not mine[k] and not s.keys[k] then
        local ok, has = pcall(p.has, k)
        if ok and not has then s.keys[k] = true s.n = s.n + 1 end
      end
    end
    w.at = GetTime() + 3
  elseif kind == "Q" then
    local f = split(msg, 5)
    if f[2] == token or f[3] ~= token then return end
    local p = SD.spaces[f[4]]
    if not p then return end
    for k in (f[5] or ""):gmatch("[^,]+") do
      local ok, payload = pcall(p.encode, k)
      if ok and payload then
        local m = format("D|%s|%s|%s|%s", token, f[4], k, payload)
        if #m <= 254 then enqueue(m, ch, f[4] .. k) end
      end
    end
  elseif kind == "D" then
    local f = split(msg, 5)
    if f[2] == token then return end
    local p = SD.spaces[f[3]]
    if not p then return end
    local ok, has = pcall(p.has, f[4])
    if ok and not has then
      local ok2, applied = pcall(p.apply, f[4], f[5] or "", who)
      if ok2 and applied ~= false then
        p.list = nil
        SD.hashAll = nil
        SD.stats.got = SD.stats.got + 1
        local g = gotFrom[f[3]] or {}
        gotFrom[f[3]] = g
        g[who] = (g[who] or 0) + 1
        summaryAt = GetTime() + 10
      end
    end
  end
end

local ticker = CreateFrame("Frame")
local tacc = 0
ticker:SetScript("OnUpdate", function(_, e)
  tacc = tacc + e
  if tacc < 1 then return end
  tacc = 0
  local now = GetTime()
  for tok, w in pairs(wants) do
    if w.at and now >= w.at then
      for name, s in pairs(w.spaces) do
        local head = format("Q|%s|%s|%s|", token, tok, name)
        local cur = head
        for k in pairs(s.keys) do
          if #cur + #k + 1 > MAX_LEN then enqueue(cur, w.ch) cur = head end
          cur = cur .. (cur == head and "" or ",") .. k
        end
        if cur ~= head then enqueue(cur, w.ch) end
      end
      wants[tok] = nil
    end
  end
  if summaryAt and now >= summaryAt then
    summaryAt = nil
    for name, g in pairs(gotFrom) do
      local p = SD.spaces[name]
      local total, parts = 0, {}
      for who, n in pairs(g) do total = total + n parts[#parts + 1] = who .. " " .. n .. "건" end
      if total > 0 and p and p.onReceived then pcall(p.onReceived, total, concat(parts, ", ")) end
    end
    wipe(gotFrom)
  end
  if SD.changedAt and now >= SD.changedAt then
    SD.changedAt = nil
    for _, ch in ipairs(channels()) do sendHello(ch, true) end
  end
end)

local lastGroupSize = 0
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:SetScript("OnEvent", function(_, event, ...)
  if SD.version ~= VERSION then return end   -- 더 새 파일이 대신 동작 중
  if event == "CHAT_MSG_ADDON" then
    onMessage(...)
  elseif event == "PLAYER_LOGIN" then
    local reg = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if reg then pcall(reg, PREFIX) end
    lastGroupSize = GetNumGroupMembers and GetNumGroupMembers() or 0
    C_Timer.After(25, function() SD:Hello() end)
  elseif event == "GROUP_ROSTER_UPDATE" then
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    if n > lastGroupSize then
      local g = groupChannel()
      if g then C_Timer.After(6, function() sendHello(g, true) end) end
    end
    lastGroupSize = n
  end
end)

function SD:Status()
  local peers = 0
  for _, p in pairs(self.stats.peers) do if GetTime() - p.at < 3600 then peers = peers + 1 end end
  local mine = 0
  for name in pairs(self.spaces) do mine = mine + #listOf(name) end
  return format("상수팩 공유: 내 공유 목록 %d건 · 보낸 메시지 %d · 받은 데이터 %d건 · 대기 %d · 최근 1시간 만난 사용자 %d명",
    mine, self.stats.sent, self.stats.got, #queue, peers)
end
