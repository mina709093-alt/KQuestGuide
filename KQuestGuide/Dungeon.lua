-- 던전 안내: "갈 수 있는 레벨"이 아니라 "던전 퀘스트를 한 번에 끝낼 수 있는 레벨"에 안내합니다.
--
-- 기준 (퀘스트 데이터에 있는 값만 사용, 추측 없음)
--   · 던전 퀘스트 = 퀘스트 데이터에서 소속 지역이 그 던전인 퀘스트 중, 내 진영/종족/직업이 받을 수 있는 것
--   · 권장 레벨   = 남은 던전 퀘스트 중 가장 높은 퀘스트 레벨 - 1  (가장 어려운 퀘스트까지 같이 끝낼 수 있는 때)
--   · 준비 단계   = 권장 레벨 4레벨 전부터: 미리 받아 둘 퀘스트와 선행 퀘스트를 목록으로 보여 줌
--   · 권장 레벨에 도달하면 채팅창에 한 번만 알림 (같은 캐릭터·같은 던전은 다시 알리지 않음)
-- /kqg 던전 : 던전 안내 창 열기/닫기   /kqg dungeon off|on : 권장 알림 끄기/켜기
local KQG = KQG
if not KQG then return end

local Q, F = KQG.Q, KQG.F
local function Print(m) if KQG.Print then KQG.Print(m) end end
local function db() return KQG.DB and KQG.DB() end

-- 던전 지역 번호 (공격대 제외). 이름은 게임 클라이언트에서 가져오고, 없을 때만 아래 이름을 씀
local DUNGEONS = {
  { 2437, "성난불길 협곡" }, { 1581, "죽음의 폐광" }, { 718, "통곡의 동굴" }, { 209, "그림자송곳니 성채" },
  { 719, "검은심연의 나락" }, { 717, "스톰윈드 지하감옥" }, { 721, "놈리건" }, { 491, "가시덩굴 우리" },
  { 796, "붉은십자군 수도원" }, { 722, "가시덩굴 구릉" }, { 1337, "울다만" }, { 1176, "줄파락" },
  { 2100, "마라우돈" }, { 1477, "아탈학카르 신전" }, { 1584, "검은바위 나락" }, { 1583, "검은바위 첨탑" },
  { 2557, "혈투의 전장" }, { 2017, "스트라솔름" }, { 2057, "스칼로맨스" },
}
local PREP_RANGE = 4

local function AreaName(area, fallback)
  if C_Map and C_Map.GetAreaInfo then
    local ok, n = pcall(C_Map.GetAreaInfo, area)
    if ok and type(n) == "string" and n ~= "" then return n end
  end
  return fallback or ("지역 " .. tostring(area))
end

local function ZoneName(area)
  local map = KQG.UiMapOf and KQG.UiMapOf(area)
  if map and KQG.MapName then return KQG.MapName(map) end
  return AreaName(area)
end

local function CanEverTake(id)
  local r = Q[id]
  if not r then return false end
  if r[F.FLAGS] and math.floor(r[F.FLAGS]) % 2 == 1 then return false end -- 반복 퀘스트
  if (r[F.LVL] or 0) < 10 then return false end                               -- 이벤트성 저레벨 항목 제외
  if not KQG.Bit(r[F.RACES], KQG.RaceBit()) then return false end
  if not KQG.Bit(r[F.CLASSES], KQG.ClassBit()) then return false end
  local s = r[F.START]
  if not s then return false end
  local fr = s[7]
  if fr and fr ~= "" and not string.find(fr, KQG.Faction(), 1, true) then return false end
  if r[F.EXCL] then
    for _, p in ipairs(r[F.EXCL]) do if KQG.IsDone(p) then return false end end
  end
  return true
end

local function UnmetPrereq(r)
  if r[F.PREG] then
    for _, p in ipairs(r[F.PREG]) do if not KQG.IsDone(p) then return p end end
  end
  if r[F.PRES] then
    for _, p in ipairs(r[F.PRES]) do if KQG.IsDone(p) then return nil end end
    return r[F.PRES][1]
  end
  return nil
end

-- 던전 지역 -> 퀘스트 번호 목록 (한 번만 만든다)
local index
local function BuildIndex()
  index = {}
  for _, d in ipairs(DUNGEONS) do index[d[1]] = {} end
  for id, r in pairs(Q) do
    local list = index[r[F.ZONE]]
    if list then list[#list + 1] = id end
  end
end

-- 던전 하나의 상태
local function Evaluate(area)
  if not index then BuildIndex() end
  local quests, maxLvl, minLvl = {}, 0, 99
  for _, id in ipairs(index[area] or {}) do
    if CanEverTake(id) and not KQG.IsDone(id) then
      local r = Q[id]
      local st
      if KQG.InLog(id) then
        st = KQG.LogComplete(id) and "complete" or "accepted"
      else
        local pre = UnmetPrereq(r)
        st = pre and "locked" or "open"
        quests[#quests + 1] = { id = id, r = r, state = st, pre = pre }
        maxLvl = math.max(maxLvl, r[F.LVL] or 0)
        minLvl = math.min(minLvl, r[F.MIN] or 0)
        st = nil
      end
      if st then
        quests[#quests + 1] = { id = id, r = r, state = st }
        maxLvl = math.max(maxLvl, r[F.LVL] or 0)
        minLvl = math.min(minLvl, r[F.MIN] or 0)
      end
    end
  end
  if #quests == 0 then return nil end
  table.sort(quests, function(a, b)
    if (a.r[F.LVL] or 0) ~= (b.r[F.LVL] or 0) then return (a.r[F.LVL] or 0) < (b.r[F.LVL] or 0) end
    return a.id < b.id
  end)
  local have = 0
  for _, q in ipairs(quests) do if q.state ~= "open" and q.state ~= "locked" then have = have + 1 end end
  return { area = area, quests = quests, maxLvl = maxLvl, minLvl = minLvl, recommend = math.max(maxLvl - 1, minLvl), have = have }
end

---------------------------------------------------------------------------
-- 창
---------------------------------------------------------------------------
local FONT = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Regular.ttf"
local FONT_B = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Bold.ttf"
local win, text

local function Build()
  win = CreateFrame("Frame", "KQGDungeonFrame", UIParent, "BackdropTemplate")
  win:SetSize(460, 420)
  win:SetPoint("CENTER", 220, 0)
  win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  win:SetBackdropColor(0.035, 0.055, 0.065, 0.96)
  win:SetBackdropBorderColor(0, 0, 0, 1)
  win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)
  win:SetFrameStrata("DIALOG"); win:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "KQGDungeonFrame")
  local title = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if not pcall(title.SetFont, title, FONT_B, 15, "") then title:SetFontObject(GameFontHighlightLarge) end
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("던전 안내")
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)
  local sf = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 12, -40); sf:SetPoint("BOTTOMRIGHT", -30, 12)
  local child = CreateFrame("Frame", nil, sf)
  child:SetSize(410, 10)
  sf:SetScrollChild(child)
  text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if not pcall(text.SetFont, text, FONT, 12, "") then text:SetFontObject(GameFontHighlight) end
  text:SetPoint("TOPLEFT"); text:SetWidth(410); text:SetJustifyH("LEFT"); text:SetSpacing(3)
  win.child = child
end

local STATE_TXT = {
  complete = "|cff2fa26a[완료 - 제출만 남음]|r",
  accepted = "|cff4db8e0[받음]|r",
  open = "|cffe6c229[미리 받기]|r",
  locked = "|cffa0a0a0[선행 필요]|r",
}

local function QuestLine(q)
  local r = q.r
  local line = ("  %s %s |cff8fa0b0(%d레벨)|r"):format(STATE_TXT[q.state] or "", r[F.NAME] or ("#" .. q.id), r[F.LVL] or 0)
  local s = r[F.START]
  if q.state == "open" and s then
    if s[1] == "n" then
      line = line .. ("\n      받는 곳: %s · %s%s"):format(s[6] or "?", ZoneName(s[3]),
        (s[4] and s[4] >= 0) and (" (%.0f, %.0f)"):format(s[4], s[5] or 0) or "")
    elseif s[1] == "i" then
      line = line .. ("\n      시작: 아이템 「%s」"):format(s[6] or "?")
    elseif s[1] == "o" then
      line = line .. ("\n      시작: %s"):format(s[6] or "?")
    end
  elseif q.state == "locked" and q.pre then
    local pr = Q[q.pre]
    line = line .. ("\n      먼저 할 퀘스트: %s"):format(pr and pr[F.NAME] or ("#" .. q.pre))
  end
  return line
end

local function Render()
  local level = UnitLevel("player") or 1
  local out = {}
  local function add(t) out[#out + 1] = t end
  add(("|cff8fa0b0내 레벨 %d · 권장 레벨 = 남은 던전 퀘스트 중 가장 높은 퀘스트 레벨 - 1|r"):format(level))
  add("")
  local shown = 0
  for _, d in ipairs(DUNGEONS) do
    local e = Evaluate(d[1])
    if e and e.recommend >= level - 3 and e.recommend <= level + 8 then
      shown = shown + 1
      local tag
      if level >= e.recommend then tag = "|cff2fa26a지금 가기 좋음|r"
      elseif level >= e.recommend - PREP_RANGE then tag = ("|cffe6c229%d레벨부터 권장 · 지금은 퀘스트 미리 받기|r"):format(e.recommend)
      else tag = ("|cffa0a0a0%d레벨부터 권장|r"):format(e.recommend) end
      add(("|cffffd200%s|r  %s"):format(AreaName(d[1], d[2]), tag))
      add(("  |cff8fa0b0퀘스트 %d개 중 %d개 받음 · 퀘스트 레벨 %d~%d|r"):format(#e.quests, e.have, e.minLvl, e.maxLvl))
      for _, q in ipairs(e.quests) do add(QuestLine(q)) end
      add("")
    end
  end
  if shown == 0 then add("지금 레벨 근처에 안내할 던전 퀘스트가 없습니다.") end
  text:SetText(table.concat(out, "\n"))
  win.child:SetHeight(text:GetStringHeight() + 10)
end

local function Toggle()
  if not win then Build() end
  if win:IsShown() then win:Hide() else
    if KQG.ReadLog then KQG.ReadLog() end
    Render(); win:Show()
  end
end

---------------------------------------------------------------------------
-- 권장 레벨 도달 알림 (한 번만)
---------------------------------------------------------------------------
local function CheckNotify()
  local d = db()
  if not d or d.dungeonNotice == false then return end
  local level = UnitLevel("player") or 1
  local key = (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "")
  d.dungeonTold = d.dungeonTold or {}
  d.dungeonTold[key] = d.dungeonTold[key] or {}
  local told = d.dungeonTold[key]
  for _, dg in ipairs(DUNGEONS) do
    local e = Evaluate(dg[1])
    if e and not told[dg[1]] and level >= e.recommend and level <= e.maxLvl + 3 then
      told[dg[1]] = true
      local missing = 0
      for _, q in ipairs(e.quests) do if q.state == "open" or q.state == "locked" then missing = missing + 1 end end
      Print(("|cffffd200%s|r 퀘스트를 한 번에 끝내기 좋은 레벨이 됐어요. (던전 퀘스트 %d개%s) /kqg 던전 으로 준비 목록을 확인하세요.")
        :format(AreaName(dg[1], dg[2]), #e.quests, missing > 0 and (", 아직 안 받은 퀘스트 " .. missing .. "개") or ""))
    end
  end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, e)
  C_Timer.After(e == "PLAYER_LEVEL_UP" and 3 or 15, function() pcall(CheckNotify) end)
end)

KQG.DungeonCommand = function(arg)
  local d = db()
  if arg == "off" then d.dungeonNotice = false; Print("던전 권장 알림 꺼짐")
  elseif arg == "on" then d.dungeonNotice = true; Print("던전 권장 알림 켜짐")
  else Toggle() end
end
KQG.DungeonEvaluate = Evaluate
