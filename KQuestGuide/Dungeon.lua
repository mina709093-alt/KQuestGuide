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
-- 퀘스트 데이터가 던전 번호 대신 "던전 입구 지역" 번호를 쓰는 던전 (데이터 번호 -> 위 목록 번호)
-- 2026-11-21 확인: 아래 번호로는 KQG_DATA에 각각 6, 27, 29, 10, 10개 퀘스트가 있고, 위 목록 번호로는 0개.
local ZONE_ALIAS = {
  [1717] = 491,  -- 가시덩굴 우리
  [133] = 721,   -- 놈리건
  [1517] = 1337, -- 울다만
  [978] = 1176,  -- 줄파락
  [1417] = 1477, -- 아탈학카르 신전
}
-- (0.37.0) 퀘스트 시작 위치로만 쓰는 던전 번호 (IsDungeonZone 판정용, 권장 알림 목록에는 넣지 않음)
--   1585 = 검은바위 나락 안쪽 번호, 10022~10027 = 혈투의 전장 구역, 16xxx = Forever 던전 4곳
local START_ALIAS = {
  [1585] = 1584,
  [10022] = 2557, [10023] = 2557, [10024] = 2557, [10025] = 2557, [10026] = 2557, [10027] = 2557,
  [16544] = 16544, [16611] = 16611, [16732] = 16732, [16919] = 16919,
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
  if r.bl and KQG.Hidden and KQG.Hidden(id) then return false end -- (0.31.1) 받을 수 없음·닫힌 축제
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
    local z = r[F.ZONE]
    local list = index[ZONE_ALIAS[z] or z]
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
-- 던전 퀘스트 창 (0.26.0)
--   왼쪽: 던전 목록 (진영 문장, 이름, 입장 레벨, 내 퀘스트 완료/전체)
--   오른쪽: 고른 던전의 퀘스트
--     · (0.37.0) 맨 앞에 수락 위치 배지: [던전 외부] [던전 내부] [외부 연계] [내부 연계] [위치 확인 필요]
--       정렬은 외부 수락 → 내부 수락 → 확인 필요, 그 안에서 레벨 순. 오른쪽 위 [전체][외부][내부] 필터
--     · 던전 안에서 받는 퀘스트: [던전 내부] 퀘스트명
--     · 밖에서 받는 퀘스트: [던전 외부] NPC명 - 퀘스트명 - 지역 (좌표)
--     · 선행이 있는 퀘스트: [+] 배지 최종 퀘스트명 - 위치 → 펼치면 첫 단계부터 N_1, N_2 …
--     · 완료한 퀘스트는 가로줄과 "완료" 표시
--   좌표가 있는 줄을 누르면 그 NPC로 길 안내 (장비 추천과 같은 방식, 수락하면 자동 해제)
-- 던전 목록·퀘스트 번호·레벨·진영은 DungeonData.lua(Dungeon Codex에서 변환)를 씁니다.
-- 퀘스트 이름·NPC·좌표·연계는 KQuestGuide 기본 데이터(Questie 기반)를 먼저 쓰고,
-- 거기 없는 퀘스트만 게임이 알려 주는 한글 제목, 그것도 없으면 Dungeon Codex의 영어 이름을 씁니다.
---------------------------------------------------------------------------
local FONT = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Regular.ttf"
local FONT_B = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Bold.ttf"

local DD = KQG.DungeonData or {}
local SRC_KQG = "KQuestGuide 기본 데이터 (Questie/QuestieDB 기반)"
local SRC_CODEX = "Dungeon Codex (영문 데이터)"
local SRC_LINE = "던전·레벨: Dungeon Codex · 추가 퀘스트·공격대·수락 위치: QuestieDB Forever · 이름·좌표: KQuestGuide 기본 데이터"

local C_TEXT = { 0.93, 0.94, 0.96 }
local C_MUTED = { 0.55, 0.60, 0.63 }
local C_ACCENT = { 0.063, 0.816, 0.627 }
local C_SEL = { 0.045, 0.32, 0.26 }
local C_BG = { 0.035, 0.055, 0.065 }
local C_DONE = { 0.18, 0.64, 0.42 }
local C_GOLD = { 1.0, 0.82, 0.0 }
-- (0.37.0) 수락 위치 배지: 그 던전 퀘스트를 실제로 받는 곳 기준 (DungeonData의 acc 칸)
local ACC = {
  E = { "[던전 외부]", { 0.30, 0.85, 0.45 } },
  I = { "[던전 내부]", { 1.00, 0.60, 0.20 } },
  EC = { "[외부 연계]", { 0.30, 0.72, 0.88 } },
  IC = { "[내부 연계]", { 0.72, 0.52, 0.96 } },
  U = { "[위치 확인 필요]", C_MUTED },
}
local ACC_DESC = {
  E = "던전 밖에서 받습니다.", I = "던전 안에서 받습니다.",
  EC = "선행 퀘스트를 마친 뒤 던전 밖에서 받습니다.", IC = "선행 퀘스트를 마친 뒤 던전 안에서 받습니다.",
  U = "받는 곳을 자료로 확인하지 못했습니다.",
}
local VS_TEXT = {
  ok = "확인됨 (Dungeon Codex와 QuestieDB Forever 모두 이 던전)",
  hi = "높은 신뢰도 (QuestieDB Forever 자료)",
  chk = "추가 확인 필요",
}
local FILTERS = { { "all", "전체" }, { "ext", "외부" }, { "int", "내부" } }
-- 공격대·Forever 던전 이름 (게임이 이름을 알려 주지 않을 때만 씀)
local EXTRA_NAMES = {
  [1977] = "줄구룹", [2717] = "화산 심장부", [2159] = "오닉시아의 둥지", [2677] = "검은날개 둥지",
  [3429] = "안퀴라즈 폐허", [3428] = "안퀴라즈 사원", [3456] = "낙스라마스",
}
local ICON_A = "Interface\\FriendsFrame\\PlusManz-Alliance"
local ICON_H = "Interface\\FriendsFrame\\PlusManz-Horde"

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
local function IsDungeonZoneAny(a) return KQG.IsDungeonZone and KQG.IsDungeonZone(a) or false end

-- Dungeon Codex 퀘스트를 번호로 찾기 (선행 퀘스트 이름용)
local codexQ = {}
for _, d in ipairs(DD) do
  for _, cq in ipairs(d.q or {}) do codexQ[cq.id] = codexQ[cq.id] or cq end
end
local areaName = {}
for _, d in ipairs(DUNGEONS) do areaName[d[1]] = d[2] end
for a, n in pairs(EXTRA_NAMES) do areaName[a] = areaName[a] or n end

local function DName(d)
  local name
  if d.inst and not d.up and GetRealZoneText then
    local ok, n = pcall(GetRealZoneText, d.inst)
    if ok and type(n) == "string" and n ~= "" then name = n end
  end
  if not name and d.area then name = AreaName(d.area, areaName[d.area]) end
  name = name or d.name or d.key
  if d.wing then name = name .. " - " .. d.wing end
  return name
end

local function MyFaction() return KQG.Faction() == "H" and "h" or "a" end

-- 던전 퀘스트를 받을 수 있는 진영: "A", "H", "AH" 또는 nil (Dungeon Codex의 진영 칸)
local function DungeonFaction(d)
  local a, h = false, false
  for _, cq in ipairs(d.q or {}) do
    if cq.side ~= "h" then a = true end
    if cq.side ~= "a" then h = true end
  end
  if a and h then return "AH" elseif a then return "A" elseif h then return "H" end
  return nil
end

-- 내 종족/직업/진영 조건만 보는 검사 (레벨 제외)
local function MineOK(id)
  local r = Q[id]
  if not r then return false end
  if not KQG.Bit(r[F.RACES], KQG.RaceBit()) then return false end
  if not KQG.Bit(r[F.CLASSES], KQG.ClassBit()) then return false end
  local s = r[F.START]
  local fr = s and s[7]
  if fr and fr ~= "" and not string.find(fr, KQG.Faction(), 1, true) then return false end
  return true
end

-- 내가 받을 수 있는 던전 퀘스트인지 (진영 → KQuestGuide 데이터가 있으면 종족·직업·진영)
local function Mine(cq)
  if cq.vs == "no" then return false end -- (0.37.0) Forever에서 받을 수 없는 퀘스트
  if cq.side and cq.side ~= MyFaction() then return false end
  local r = Q[cq.id]
  if r and r.bl and KQG.Hidden and KQG.Hidden(cq.id) then return false end
  if r then return MineOK(cq.id) end
  return true
end

-- 선행 퀘스트 하나 고르기: 모두 필요(PREG)는 첫 번째, 하나만 필요(PRES)는 완료한 것 → 내가 받을 수 있는 것
local function PickPrereq(r)
  if r[F.PREG] then
    for _, p in ipairs(r[F.PREG]) do if Q[p] then return p end end
  end
  if r[F.PRES] then
    for _, p in ipairs(r[F.PRES]) do if Q[p] and KQG.IsDone(p) then return p end end
    for _, p in ipairs(r[F.PRES]) do if Q[p] and MineOK(p) then return p end end
  end
  return nil
end

-- 첫 단계부터 이 퀘스트까지의 연계 (최대 15단계)
local function ChainTo(id)
  local list, seen, cur = { id }, { [id] = true }, id
  for _ = 1, 15 do
    local p = Q[cur] and PickPrereq(Q[cur])
    if not p then
      local cq = not Q[cur] and codexQ[cur]
      p = cq and cq.pre and cq.pre[1]
    end
    if not p or seen[p] then break end
    seen[p] = true
    table.insert(list, 1, p)
    cur = p
  end
  return list
end

local function QState(id)
  if KQG.IsDone(id) then return "done" end
  if KQG.InLog(id) then return KQG.LogComplete(id) and "complete" or "accepted" end
  return "none"
end
local STATE_BADGE = {
  done = Hex(C_DONE) .. "완료|r",
  complete = Hex(C_GOLD) .. "제출 가능|r",
  accepted = "|cff4db8e0받음|r",
}

local function Coord(s)
  if s and s[4] and s[4] >= 0 then return string.format("(%.0f, %.0f)", s[4], s[5] or 0) end
  return ""
end

-- 게임이 알려 주는 퀘스트 제목 (한 번도 보지 않은 퀘스트는 없을 수 있음)
local function GameTitle(id)
  if C_QuestLog and C_QuestLog.GetTitleForQuestID then
    local ok, t = pcall(C_QuestLog.GetTitleForQuestID, id)
    if ok and type(t) == "string" and t ~= "" then return t end
  end
  return nil
end

local function QTitle(id)
  local r = Q[id]
  if r and r[F.NAME] then return r[F.NAME] end
  local cq = codexQ[id]
  return GameTitle(id) or (cq and cq.t) or ("퀘스트 #" .. id)
end

local function ItemName(item)
  local fn = (C_Item and C_Item.GetItemNameByID) or GetItemInfo
  if fn then
    local ok, n = pcall(fn, item)
    if ok and type(n) == "string" then return n end
  end
  return "시작 아이템"
end

-- 한 줄 글: 받는 곳 형식
local function StartText(id)
  local r = Q[id]
  if r then
    local name = r[F.NAME] or ("#" .. id)
    local s = r[F.START]
    if not s then return name .. " - 받는 곳 정보 없음" end
    if s[3] and IsDungeonZoneAny(s[3]) then return name end -- (0.37.0) 안/밖은 배지가 알려 줌
    if s[1] == "i" then return "아이템「" .. (s[6] or "?") .. "」 - " .. name end
    local where = s[3] and ZoneName(s[3]) or ""
    return (s[6] or "?") .. " - " .. name .. " - " .. where .. " " .. Coord(s)
  end
  local cq = codexQ[id]
  local name = QTitle(id)
  if not cq then return name end
  if cq.item then return "아이템「" .. ItemName(cq.item) .. "」 - " .. name end
  if not cq.zm then return name end
  return (cq.g or "?") .. " - " .. name .. " - " .. (KQG.MapName and KQG.MapName(cq.zm) or "")
end

-- (0.37.0) 수락 위치: "E" | "I" | "EC" | "IC" | "U"
--   DungeonData의 acc 칸(QuestieDB Forever로 계산)을 먼저 쓰고, 없으면 KQG 시작 위치로 판정합니다.
local function AccOf(id, cq)
  cq = cq or codexQ[id]
  if cq and cq.acc and ACC[cq.acc] then return cq.acc end
  local r = Q[id]
  local base = "U"
  local s = r and r[F.START]
  if s then
    if s[3] and IsDungeonZoneAny(s[3]) then base = "I"
    elseif s[1] ~= "i" then base = "E" end
  end
  if base == "U" then return "U" end
  local chain = (r and (r[F.PREG] or r[F.PRES])) or (cq and cq.pre and #cq.pre > 0)
  return chain and (base .. "C") or base
end
local function AccBadge(acc)
  local a = ACC[acc] or ACC.U
  return Hex(a[2]) .. a[1] .. "|r"
end
local ACC_ORDER = { E = 1, EC = 1, I = 2, IC = 2, U = 3 }
local function PassFilter(acc, filter)
  if filter == "ext" then return acc == "E" or acc == "EC" end
  if filter == "int" then return acc == "I" or acc == "IC" end
  return true
end

-- 연계 머리줄의 위치
local function WhereText(id)
  local r = Q[id]
  if r then
    local s = r[F.START]
    if not s then return "" end
    if s[3] and IsDungeonZoneAny(s[3]) then return "" end -- (0.37.0) 배지가 알려 줌
    return (s[3] and ZoneName(s[3]) or "") .. " " .. Coord(s)
  end
  local cq = codexQ[id]
  if not cq then return "" end
  if cq.item then return "아이템으로 시작" end
  if not cq.zm then return "" end
  return KQG.MapName and KQG.MapName(cq.zm) or ""
end

-- 고른 던전의 줄 목록 만들기
local expanded = {}
-- filter: nil/"all" 전체, "ext" 외부 수락(E·EC), "int" 내부 수락(I·IC). 완료/전체 수는 거르기 전 기준
local function BuildRows(d, filter)
  local mine, here = {}, {}
  for _, cq in ipairs(d.q or {}) do
    if Mine(cq) and not here[cq.id] then
      mine[#mine + 1] = cq.id
      here[cq.id] = cq
    end
  end
  local acc = {}
  for _, id in ipairs(mine) do acc[id] = AccOf(id, here[id]) end
  -- (0.37.0) 외부 수락 → 내부 수락 → 위치 확인 필요, 같은 묶음 안에서는 레벨 낮은 순
  table.sort(mine, function(a, b)
    local ga, gb = ACC_ORDER[acc[a]] or 3, ACC_ORDER[acc[b]] or 3
    if ga ~= gb then return ga < gb end
    local la = (Q[a] and Q[a][F.LVL]) or (codexQ[a] and codexQ[a].lv) or 0
    local lb = (Q[b] and Q[b][F.LVL]) or (codexQ[b] and codexQ[b].lv) or 0
    if la ~= lb then return la < lb end
    return a < b
  end)
  -- 다른 던전 퀘스트의 연계 단계로 이미 들어가는 퀘스트는 따로 보여 주지 않음
  local chains, inner = {}, {}
  for _, id in ipairs(mine) do
    local ch = ChainTo(id)
    chains[id] = ch
    for i = 1, #ch - 1 do inner[ch[i]] = true end
  end
  local rows, n, done, total = {}, 0, 0, 0
  local count = { ext = 0, int = 0 }
  for _, id in ipairs(mine) do
    if not inner[id] then
      total = total + 1
      local st = QState(id)
      if st == "done" then done = done + 1 end
      local a = acc[id]
      if a == "E" or a == "EC" then count.ext = count.ext + 1 elseif a == "I" or a == "IC" then count.int = count.int + 1 end
      if PassFilter(a, filter) then
        n = n + 1
        local ch = chains[id]
        if #ch == 1 then
          rows[#rows + 1] = { num = n .. ".", id = id, acc = a, cq = here[id], text = AccBadge(a) .. " " .. StartText(id), state = st }
        else
          local cnt = 0
          for _, c in ipairs(ch) do if KQG.IsDone(c) then cnt = cnt + 1 end end
          local where = WhereText(id)
          rows[#rows + 1] = { num = n .. ".", id = id, chain = ch, header = true, acc = a, cq = here[id],
            text = AccBadge(a) .. " " .. QTitle(id) .. (where ~= "" and (" - " .. where) or ""),
            state = st, progress = st ~= "done" and string.format("%d/%d", cnt, #ch) or nil }
          if expanded[d.key .. ":" .. id] then
            for i, c in ipairs(ch) do
              local ca = AccOf(c, here[c])
              rows[#rows + 1] = { num = n .. "_" .. i, id = c, acc = ca, cq = here[c], text = AccBadge(ca) .. " " .. StartText(c), state = QState(c), child = true }
            end
          end
        end
      end
    end
  end
  return rows, done, total, count
end

local win
local list, offset, offL, sel = {}, 0, 0, nil
local LROWS, RROWS, ROW_H = 19, 16, 22
local W, LEFT_W = 740, 256

-- (0.37.0) 수락 위치 필터: "all" | "ext" | "int" (저장 칸 dungeonFilter, 없으면 전체)
local function CurFilter()
  local db_ = db()
  local f = db_ and db_.dungeonFilter
  if f == "ext" or f == "int" then return f end
  return "all"
end

local function SelD()
  for _, d in ipairs(DD) do if d.key == sel then return d end end
  return DD[1]
end

local function SetForcedTo(id)
  local r = Q[id]
  local s = r and r[F.START]
  if not s or s[1] == "i" or not s[4] or s[4] < 0 then return false end
  local map = KQG.UiMapOf and KQG.UiMapOf(s[3])
  if not map or not KQG.SetForced then return false end
  KQG.SetForced({ kind = "accept", key = "dgq" .. id, loc = s, map = map, quests = { id }, label = "[던전 퀘스트] " .. (r[F.NAME] or "") })
  Print("안내 시작: " .. (s[6] or "?") .. " - " .. (r[F.NAME] or "") .. " " .. Coord(s) .. ", " .. ZoneName(s[3]))
  return true
end

local RenderRight

local function RenderLeft()
  local level = UnitLevel("player") or 1
  local maxOff = math.max(0, #DD - LROWS)
  if offL > maxOff then offL = maxOff end
  if offL < 0 then offL = 0 end
  for i = 1, LROWS do
    local row = win.left[i]
    local d = DD[i + offL]
    row.d = d
    if d then
      local fac = DungeonFaction(d)
      Shown(row.iconA, fac == "A" or fac == "AH")
      Shown(row.iconH, fac == "H" or fac == "AH")
      row.iconA:ClearAllPoints()
      row.iconH:ClearAllPoints()
      if fac == "AH" then
        row.iconA:SetPoint("LEFT", 6, 0) row.iconH:SetPoint("LEFT", 22, 0)
      else
        row.iconA:SetPoint("LEFT", 14, 0) row.iconH:SetPoint("LEFT", 14, 0)
      end
      row.name:SetText(DName(d) .. (d.up and (" " .. Hex(C_MUTED) .. "(개방 예정)|r") or "") .. (d.raid and (" " .. Hex(C_MUTED) .. "(공격대)|r") or ""))
      row.lv:SetText(d.lv and d.lv[1] > 0 and tostring(d.lv[1]) or "")
      local _, dn, tt = BuildRows(d)
      row.cnt:SetText(tt > 0 and (dn .. "/" .. tt) or "-")
      local near = d.lv and level >= d.lv[1] and level <= d.lv[3]
      if near then row.name:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
      else row.name:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3]) end
      if d.key == sel then Solid(row.bg, C_SEL[1], C_SEL[2], C_SEL[3], 1) else Solid(row.bg, 0, 0, 0, 0) end
      row:Show()
    else
      row:Hide()
    end
  end
end

RenderRight = function()
  local d = SelD()
  if not d then return end
  local level = UnitLevel("player") or 1
  local fac = DungeonFaction(d)
  win.title2:SetText(DName(d))
  Shown(win.facA, fac == "A" or fac == "AH")
  Shown(win.facH, fac == "H" or fac == "AH")
  win.facH:ClearAllPoints()
  if fac == "AH" then win.facH:SetPoint("LEFT", win.facA, "RIGHT", 2, 0) else win.facH:SetPoint("LEFT", win.title2, "RIGHT", 8, 0) end
  local facTxt = fac == "AH" and "공통" or fac == "A" and "얼라이언스" or fac == "H" and "호드" or "정보 없음"
  local info = {}
  if d.lv and d.lv[1] > 0 then info[#info + 1] = string.format("입장 %d · 권장 %d~%d", d.lv[1], d.lv[2], d.lv[3]) end
  info[#info + 1] = "진영: " .. facTxt
  if d.up then info[#info + 1] = "개방 예정"
  elseif d.status == "beta" then info[#info + 1] = "베타 데이터" end
  local e = d.area and not d.wing and Evaluate(d.area)
  if e then
    if level >= e.recommend then info[#info + 1] = Hex(C_DONE) .. "퀘스트 몰아서 하기 좋음|r"
    elseif level >= e.recommend - PREP_RANGE then info[#info + 1] = string.format("|cffe6c229%d레벨부터 · 지금은 미리 받기|r", e.recommend)
    else info[#info + 1] = string.format("%d레벨부터 권장", e.recommend) end
  end
  win.info:SetText(table.concat(info, "  ·  "))
  local filter = CurFilter()
  local rows, dn, tt, cnt = BuildRows(d, filter)
  list = rows
  win.sum:SetText(tt > 0 and string.format("내 진영 퀘스트 %d개 · 완료 %d개 · 외부 수락 %d · 내부 수락 %d", tt, dn, cnt.ext, cnt.int)
    or "내가 받을 수 있는 퀘스트가 없습니다.")
  for _, b in ipairs(win.filters or {}) do
    if b.key == filter then b.t:SetTextColor(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3]) Solid(b.bg, C_SEL[1], C_SEL[2], C_SEL[3], 1)
    else b.t:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3]) Solid(b.bg, 1, 1, 1, 0.06) end
  end
  local maxOff = math.max(0, #list - RROWS)
  if offset > maxOff then offset = maxOff end
  if offset < 0 then offset = 0 end
  for i = 1, RROWS do
    local row = win.right[i]
    local it = list[i + offset]
    row.item = it
    if it then
      local x = it.child and 26 or 4
      row.num:ClearAllPoints()
      row.num:SetPoint("LEFT", x, 0)
      row.num:SetText(it.num)
      Shown(row.exp, it.header == true)
      row.exp:SetText(expanded[d.key .. ":" .. it.id] and "[-]" or "[+]")
      row.text:ClearAllPoints()
      row.text:SetPoint("LEFT", row, "LEFT", x + (it.child and 36 or 30) + (it.header and 26 or 0), 0)
      row.text:SetPoint("RIGHT", row, "RIGHT", -70, 0)
      row.text:SetText(it.text)
      local done = it.state == "done"
      if done then row.text:SetTextColor(0.55, 0.55, 0.55) else row.text:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3]) end
      row.badge:SetText(STATE_BADGE[it.state] or (it.progress and (Hex(C_MUTED) .. it.progress .. "|r")) or "")
      Shown(row.strike, done)
      if done then
        local w = math.min(row.text:GetStringWidth() or 0, row.text:GetWidth() or 0)
        if w < 10 then w = row.text:GetWidth() or 100 end
        row.strike:ClearAllPoints()
        row.strike:SetPoint("LEFT", row.text, "LEFT", 0, 0)
        row.strike:SetWidth(w)
      end
      row:Show()
    else
      row:Hide()
    end
  end
  win.more:SetText(#list > RROWS and string.format("%d~%d / %d (마우스 휠로 넘김)", offset + 1, math.min(#list, offset + RROWS), #list) or "")
end

local function Select(key)
  sel = key
  offset = 0
  local db_ = db()
  if db_ then db_.dungeonSel = key end
  RenderLeft()
  RenderRight()
end

local function BestDungeon()
  local db_ = db()
  if db_ and type(db_.dungeonSel) == "string" then
    for _, d in ipairs(DD) do if d.key == db_.dungeonSel then return d.key end end
  end
  local level = UnitLevel("player") or 1
  local best, bestGap
  for _, d in ipairs(DD) do
    if not d.up and not d.raid and d.lv and level >= d.lv[1] then
      local gap = math.abs(level - d.lv[2])
      if not best or gap < bestGap then best, bestGap = d.key, gap end
    end
  end
  return best or (DD[1] and DD[1].key)
end

local function ScrollLeft(dlt) offL = offL - dlt * 3 RenderLeft() end
local function ScrollRight(dlt) offset = offset - dlt * 3 RenderRight() end

local function Build()
  win = CreateFrame("Frame", "KQGDungeonFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  win:SetSize(W, 52 + LROWS * ROW_H + 30)
  win:SetPoint("CENTER", 120, 0)
  win.bg = win:CreateTexture(nil, "BACKGROUND")
  win.bg:SetAllPoints()
  Solid(win.bg, C_BG[1], C_BG[2], C_BG[3], 0.96)
  local top = win:CreateTexture(nil, "BORDER")
  top:SetPoint("TOPLEFT") top:SetPoint("TOPRIGHT") top:SetHeight(2)
  Solid(top, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
  local split = win:CreateTexture(nil, "BORDER")
  split:SetPoint("TOPLEFT", LEFT_W, -44) split:SetPoint("BOTTOMLEFT", LEFT_W, 28) split:SetWidth(1)
  Solid(split, 1, 1, 1, 0.08)
  win:SetMovable(true) win:EnableMouse(true) win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving) win:SetScript("OnDragStop", win.StopMovingOrSizing)
  win:SetFrameStrata("DIALOG") win:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "KQGDungeonFrame")

  local title = SetF(win:CreateFontString(nil, "OVERLAY"), 15, true)
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  title:SetText("던전 퀘스트")
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

  -- 왼쪽 던전 목록
  for _, h in ipairs({ { "던전", "TOPLEFT", 50 }, { "입장", "TOPRIGHT", LEFT_W - 44 }, { "완료", "TOPRIGHT", LEFT_W - 10 } }) do
    local fs = SetF(win:CreateFontString(nil, "OVERLAY"), 10)
    fs:SetPoint(h[2], win, "TOPLEFT", h[3], -34)
    fs:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
    fs:SetText(h[1])
  end
  win.left = {}
  for i = 1, LROWS do
    local row = CreateFrame("Button", nil, win)
    row:SetSize(LEFT_W - 12, ROW_H - 1)
    row:SetPoint("TOPLEFT", 6, -48 - (i - 1) * ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.iconA = row:CreateTexture(nil, "ARTWORK")
    row.iconA:SetSize(16, 16)
    row.iconA:SetTexture(ICON_A)
    row.iconH = row:CreateTexture(nil, "ARTWORK")
    row.iconH:SetSize(16, 16)
    row.iconH:SetTexture(ICON_H)
    row.name = SetF(row:CreateFontString(nil, "OVERLAY"), 12)
    row.name:SetPoint("LEFT", 44, 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", -64, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.lv = SetF(row:CreateFontString(nil, "OVERLAY"), 12)
    row.lv:SetPoint("RIGHT", row, "RIGHT", -38, 0)
    row.lv:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
    row.cnt = SetF(row:CreateFontString(nil, "OVERLAY"), 11)
    row.cnt:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.cnt:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, dlt) ScrollLeft(dlt) end)
    row:SetScript("OnClick", function(self) if self.d then Select(self.d.key) end end)
    row:SetScript("OnEnter", function(self)
      local d = self.d
      if not d then return end
      if d.key ~= sel then Solid(self.bg, 1, 1, 1, 0.05) end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(DName(d), 1, 1, 1)
      if d.lv and d.lv[1] > 0 then GameTooltip:AddLine(string.format("입장 %d레벨 · 권장 %d~%d레벨", d.lv[1], d.lv[2], d.lv[3]), C_TEXT[1], C_TEXT[2], C_TEXT[3]) end
      if d.ent and KQG.MapName then
        GameTooltip:AddLine(string.format("입구: %s (%.0f, %.0f)", KQG.MapName(d.ent[1]), d.ent[2], d.ent[3]), C_TEXT[1], C_TEXT[2], C_TEXT[3], true)
      end
      local fac = DungeonFaction(d)
      GameTooltip:AddLine("진영: " .. (fac == "AH" and "공통" or fac == "A" and "얼라이언스" or fac == "H" and "호드" or "정보 없음")
        .. " (퀘스트를 받을 수 있는 진영 기준)", C_MUTED[1], C_MUTED[2], C_MUTED[3], true)
      if d.up then GameTooltip:AddLine("아직 열리지 않은 던전입니다.", C_MUTED[1], C_MUTED[2], C_MUTED[3]) end
      GameTooltip:AddLine(d.raid and "공격대·퀘스트 출처: QuestieDB Forever" or "던전·레벨 출처: Dungeon Codex", C_MUTED[1], C_MUTED[2], C_MUTED[3])
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
      if self.d and self.d.key ~= sel then Solid(self.bg, 0, 0, 0, 0) end
      GameTooltip:Hide()
    end)
    win.left[i] = row
  end

  -- 오른쪽 퀘스트
  local rx = LEFT_W + 14
  win.title2 = SetF(win:CreateFontString(nil, "OVERLAY"), 14, true)
  win.title2:SetPoint("TOPLEFT", rx, -34)
  win.title2:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
  win.facA = win:CreateTexture(nil, "ARTWORK")
  win.facA:SetSize(18, 18)
  win.facA:SetTexture(ICON_A)
  win.facA:SetPoint("LEFT", win.title2, "RIGHT", 8, 0)
  win.facH = win:CreateTexture(nil, "ARTWORK")
  win.facH:SetSize(18, 18)
  win.facH:SetTexture(ICON_H)
  win.info = SetF(win:CreateFontString(nil, "OVERLAY"), 11)
  win.info:SetPoint("TOPLEFT", rx, -56)
  win.info:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  win.sum = SetF(win:CreateFontString(nil, "OVERLAY"), 11)
  win.sum:SetPoint("TOPLEFT", rx, -74)
  win.sum:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  -- (0.37.0) 수락 위치 필터 버튼 [전체][외부][내부]
  win.filters = {}
  for i = #FILTERS, 1, -1 do
    local fdef = FILTERS[i]
    local b = CreateFrame("Button", nil, win)
    b:SetSize(40, 18)
    b:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14 - (#FILTERS - i) * 44, -71)
    b.key = fdef[1]
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.t = SetF(b:CreateFontString(nil, "OVERLAY"), 11, true)
    b.t:SetPoint("CENTER")
    b.t:SetText(fdef[2])
    b:SetScript("OnClick", function(self)
      local db_ = db()
      if db_ then db_.dungeonFilter = self.key end
      offset = 0
      RenderRight()
    end)
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(self.key == "ext" and "던전 밖에서 받는 퀘스트만 ([던전 외부]·[외부 연계])"
        or self.key == "int" and "던전 안에서 받는 퀘스트만 ([던전 내부]·[내부 연계])" or "모든 퀘스트", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    win.filters[#win.filters + 1] = b
  end
  win.right = {}
  local RW = W - LEFT_W - 22
  for i = 1, RROWS do
    local row = CreateFrame("Button", nil, win)
    row:SetSize(RW, ROW_H)
    row:SetPoint("TOPLEFT", rx - 4, -94 - (i - 1) * ROW_H)
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints()
    Solid(row.hl, 1, 1, 1, 0.05)
    row.hl:Hide()
    row.num = SetF(row:CreateFontString(nil, "OVERLAY"), 12)
    row.num:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
    row.exp = SetF(row:CreateFontString(nil, "OVERLAY"), 12, true)
    row.exp:SetPoint("LEFT", row.num, "RIGHT", 6, 0)
    row.exp:SetTextColor(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
    row.text = SetF(row:CreateFontString(nil, "OVERLAY"), 12)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row.strike = row:CreateTexture(nil, "OVERLAY")
    row.strike:SetHeight(1)
    Solid(row.strike, 0.75, 0.75, 0.75, 0.9)
    row.badge = SetF(row:CreateFontString(nil, "OVERLAY"), 11, true)
    row.badge:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, dlt) ScrollRight(dlt) end)
    row:SetScript("OnClick", function(self)
      local it = self.item
      if not it then return end
      if it.header then
        local k = sel .. ":" .. it.id
        expanded[k] = not expanded[k]
        RenderRight()
      elseif it.state ~= "done" then
        if not SetForcedTo(it.id) then Print("이 퀘스트는 길 안내할 위치 정보가 없습니다.") end
      end
    end)
    row:SetScript("OnEnter", function(self)
      row.hl:Show()
      local it = self.item
      if not it then return end
      local r, cq = Q[it.id], it.cq or codexQ[it.id]
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(QTitle(it.id), 1, 1, 1)
      local a = it.acc or "U"
      local ac = (ACC[a] or ACC.U)[2]
      GameTooltip:AddLine((ACC[a] or ACC.U)[1] .. " " .. (ACC_DESC[a] or ""), ac[1], ac[2], ac[3], true)
      if cq and cq.pz and (a == "EC" or a == "IC") then
        GameTooltip:AddLine("선행 퀘스트 시작 지역: " .. ZoneName(cq.pz), C_TEXT[1], C_TEXT[2], C_TEXT[3], true)
      end
      if cq and cq.vs and VS_TEXT[cq.vs] then GameTooltip:AddLine("검증: " .. VS_TEXT[cq.vs], C_MUTED[1], C_MUTED[2], C_MUTED[3], true) end
      if cq and cq.wu then GameTooltip:AddLine("구역 미확인: 이 던전의 모든 구역에 보여 줍니다.", C_MUTED[1], C_MUTED[2], C_MUTED[3], true) end
      local lv = (r and r[F.LVL]) or (cq and cq.lv) or 0
      local mn = (r and r[F.MIN]) or (cq and cq.min) or 0
      GameTooltip:AddLine(string.format("퀘스트 레벨 %d · 요구 레벨 %d", lv, mn), C_TEXT[1], C_TEXT[2], C_TEXT[3])
      local s = r and r[F.START]
      if s then
        if s[1] == "i" then GameTooltip:AddLine("시작: 아이템「" .. (s[6] or "?") .. "」", C_TEXT[1], C_TEXT[2], C_TEXT[3], true)
        else GameTooltip:AddLine("받는 곳: " .. (s[6] or "?") .. " · " .. ZoneName(s[3]) .. " " .. Coord(s), C_TEXT[1], C_TEXT[2], C_TEXT[3], true) end
      elseif cq then
        if cq.g then GameTooltip:AddLine("주는 NPC: " .. cq.g .. (cq.zm and KQG.MapName and (" · " .. KQG.MapName(cq.zm)) or ""), C_TEXT[1], C_TEXT[2], C_TEXT[3], true) end
        if cq.t then GameTooltip:AddLine("영어 제목: " .. cq.t, C_MUTED[1], C_MUTED[2], C_MUTED[3], true) end
        GameTooltip:AddLine("좌표 정보가 없습니다.", C_MUTED[1], C_MUTED[2], C_MUTED[3])
      end
      if it.header then
        GameTooltip:AddLine(string.format("연계 %d단계 (첫 단계부터)", #it.chain), C_MUTED[1], C_MUTED[2], C_MUTED[3])
        GameTooltip:AddLine("클릭: 연계 펼치기/접기", C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
      elseif it.state ~= "done" and s then
        GameTooltip:AddLine("클릭: 받는 곳으로 길 안내", C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
      end
      GameTooltip:AddLine("퀘스트 정보 출처: " .. (r and SRC_KQG or SRC_CODEX), C_MUTED[1], C_MUTED[2], C_MUTED[3], true)
      if cq and cq.src == "q" then GameTooltip:AddLine("던전 연결·수락 위치 출처: QuestieDB Forever", C_MUTED[1], C_MUTED[2], C_MUTED[3], true)
      elseif cq and cq.acc then GameTooltip:AddLine("던전 연결: Dungeon Codex · 수락 위치: QuestieDB Forever", C_MUTED[1], C_MUTED[2], C_MUTED[3], true) end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() row.hl:Hide() GameTooltip:Hide() end)
    win.right[i] = row
  end
  win:EnableMouseWheel(true)
  win:SetScript("OnMouseWheel", function(_, dlt)
    local x = GetCursorPosition() / (win:GetEffectiveScale() or 1)
    if x < (win:GetLeft() or 0) + LEFT_W then ScrollLeft(dlt) else ScrollRight(dlt) end
  end)
  win.more = SetF(win:CreateFontString(nil, "OVERLAY"), 10)
  win.more:SetPoint("BOTTOMRIGHT", -14, 34)
  win.more:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  local src = SetF(win:CreateFontString(nil, "OVERLAY"), 10)
  src:SetPoint("BOTTOMLEFT", 14, 10)
  src:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  src:SetText(SRC_LINE)
  win:SetScript("OnHide", function() expanded = {} end)
  win:Hide()
end

local function Toggle()
  if not win then Build() end
  if win:IsShown() then win:Hide() else
    if KQG.ReadLog then KQG.ReadLog() end
    if #DD == 0 then Print("던전 데이터(DungeonData.lua)를 읽지 못했습니다.") return end
    win:Show()
    local key = sel or BestDungeon()
    -- 고른 던전이 목록에서 보이게 왼쪽 목록 위치를 맞춤
    for i, d in ipairs(DD) do if d.key == key then offL = math.max(0, i - math.floor(LROWS / 2)) end end
    Select(key)
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
-- 이 지역 번호가 던전(공격대 제외)인지 (Cleanup.lua에서 씀)
local dungeonSet
KQG.IsDungeonZone = function(area)
  if not dungeonSet then
    dungeonSet = {}
    for _, d in ipairs(DUNGEONS) do dungeonSet[d[1]] = true end
  end
  if area == nil then return false end
  if START_ALIAS[area] then return true end
  return dungeonSet[ZONE_ALIAS[area] or area] == true
end
