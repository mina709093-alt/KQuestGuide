-- 추적 퀘스트 범위 표시 (세계 지도, 미니맵)
-- 오른쪽 추적 목록에 올린 퀘스트 전체의 목표 범위를 세계 지도와 미니맵에 칠하고,
-- 범위 위에 마우스를 올리면 퀘스트 이름과 목표 진행도를 툴팁으로 보여 줍니다.
--
-- 원칙
--   * 범위 모양은 게임이 가진 퀘스트 범위 데이터를 그대로 씁니다 (QuestPOIFrame: questPOI 설정과 같은 그림).
--     게임이 범위를 주지 않는 퀘스트는 그리지 않습니다. 추측해서 그리지 않습니다.
--   * 지도의 Lua 함수는 부르지 않고(지도 오염 방지), 지도 캔버스와 지도 번호만 읽습니다.
--   * 범위 그림은 마우스를 받지 않습니다. 지도 클릭, 핀 클릭, 지도 이동을 막지 않습니다.
--   * 퀘스트마다 범위 그림을 하나씩 만들어서, 범위가 겹치는 곳에서는 해당 퀘스트를 모두 툴팁에 보여 줍니다.
-- 명령: /kqg 범위 (전체 켜기/끄기)   /kqg 범위 미니맵 (미니맵만 켜기/끄기)
--       /kqg 범위 진단 (이 클라이언트에서 무엇이 동작하는지 확인)
-- 설정: KQGDB.areaOff = true 이면 모두 꺼짐, KQGDB.areaMinimapOff = true 이면 미니맵만 꺼짐 (없으면 켜짐)

local K = KQG
if type(K) ~= "table" then return end

local FILL_TEX = "Interface\\WorldMap\\UI-QuestBlob-Inside"
local BORDER_TEX = "Interface\\WorldMap\\UI-QuestBlob-Outside"
local FILL_ALPHA, BORDER_ALPHA = 110, 190   -- 0~255
local LEVEL_FALLBACK = 2007                 -- 게임의 퀘스트 범위 층 번호를 못 읽었을 때
local DRAW_EVERY = 0.25                     -- 지도가 열려 있을 때 다시 그릴지 확인하는 간격(초)
local HOVER_EVERY = 0.05                    -- 마우스 확인 간격(초)
local MAX_AREAS = 25

local C_DONE = "|cff2fa26a"
local C_TODO = "|cffeeeeee"

local blobs = {}         -- [i] = QuestPOIFrame (퀘스트 하나씩)
local blobQuest = {}     -- [i] = 그 그림이 그리는 questID
local canMake = nil      -- nil = 아직 모름, false = 이 클라이언트에서 만들 수 없음
local drawnKey = nil
local dirty = true
local lastDraw = 0
local hoverMode = nil    -- nil = 아직 모름, "screen" = 화면 좌표, "map" = 지도 비율 좌표
local tipShown = false
local lastHoverKey = nil

local function Print(t) if K.Print then K.Print(t) end end
local function DB() return K.DB and K.DB() end

local function IsOn()
  local d = DB()
  return d ~= nil and not d.areaOff
end

local function Secret(v)
  if issecretvalue then
    local ok, r = pcall(issecretvalue, v)
    return ok and r
  end
  return false
end

-- 추적 목록의 퀘스트 번호들 (오른쪽 목록 순서)
local function Watched()
  local out = {}
  local QL = C_QuestLog
  if not (QL and QL.GetNumQuestWatches and QL.GetQuestIDForQuestWatchIndex) then return out end
  local ok, n = pcall(QL.GetNumQuestWatches)
  if not ok or type(n) ~= "number" or Secret(n) then return out end
  for i = 1, math.min(n, MAX_AREAS) do
    local ok2, id = pcall(QL.GetQuestIDForQuestWatchIndex, i)
    if ok2 and type(id) == "number" and not Secret(id) and id > 0 then out[#out + 1] = id end
  end
  return out
end

local function Canvas()
  local map = _G.WorldMapFrame
  local sc = type(map) == "table" and map.ScrollContainer
  local child = type(sc) == "table" and sc.Child
  if type(child) ~= "table" then return nil end
  return child, map, sc
end

local function MapID(map)
  local id = rawget(map, "mapID")
  if type(id) == "number" then return id end
  return nil
end

-- 게임 규칙과 같게: 세계, 대륙, 우주 지도에는 범위를 그리지 않습니다.
local function MapShowsQuests(mapID)
  if not (C_Map and C_Map.GetMapInfo and Enum and Enum.UIMapType) then return false end
  local ok, info = pcall(C_Map.GetMapInfo, mapID)
  local kind = ok and type(info) == "table" and info.mapType
  if type(kind) ~= "number" then return false end
  local T = Enum.UIMapType
  return kind ~= T.World and kind ~= T.Continent and kind ~= T.Cosmic
end

local function AreaLevel(map)
  local level = LEVEL_FALLBACK
  local m = rawget(map, "pinFrameLevelsManager")
  local defs = type(m) == "table" and m.definitions
  local d = type(defs) == "table" and defs.PIN_FRAME_LEVEL_QUEST_BLOB
  if type(d) == "table" and type(d.startLevel) == "number" then level = d.startLevel end
  -- OpenMap(이어 붙인 지도)이 켜져 있으면 그 지도 그림보다 위에 둡니다 (공개 API: OpenMapAPI, 읽기만).
  local om = rawget(_G, "OpenMapAPI")
  if type(om) == "table" and type(om.IsStitched) == "function" and type(om.ArtTopLevel) == "function" then
    local ok, stitched = pcall(om.IsStitched)
    local ok2, top = pcall(om.ArtTopLevel)
    if ok and stitched == true and ok2 and type(top) == "number" and not Secret(top) then
      level = math.max(level, top + 2)
    end
  end
  return level
end

-- 지도가 흐려질 때(이동 중 투명도) 범위도 같이 흐려지게 합니다.
local function FollowAlpha(b, map)
  local a = map:GetEffectiveAlpha()
  if type(a) ~= "number" or Secret(a) then a = 1 end
  a = math.floor(a * 20 + 0.5) / 20
  if b.kqgAlpha == a then return end
  b.kqgAlpha = a
  pcall(b.SetFillAlpha, b, math.floor(FILL_ALPHA * a + 0.5))
  pcall(b.SetBorderAlpha, b, math.floor(BORDER_ALPHA * a + 0.5))
end

-- 부모 없이 만든 뒤 지도 캔버스로 옮깁니다 (전투 중에도 문제없게).
local function MakeBlob(child, map)
  if canMake == false then return nil end
  local ok, b = pcall(CreateFrame, "QuestPOIFrame")
  if not ok or type(b) ~= "table" or type(b.DrawBlob) ~= "function" then
    canMake = false
    return nil
  end
  canMake = true
  b:SetParent(child)
  b:SetAllPoints(child)
  b:EnableMouse(false)
  pcall(b.SetFillTexture, b, FILL_TEX)
  pcall(b.SetBorderTexture, b, BORDER_TEX)
  pcall(b.SetBorderScalar, b, 1)
  b.kqgAlpha = nil
  FollowAlpha(b, map)
  return b
end

local function HideAll()
  for i, b in ipairs(blobs) do
    pcall(b.DrawNone, b)
    b:Hide()
    blobQuest[i] = nil
  end
  drawnKey = nil
end

local tipOwner = nil      -- 툴팁을 띄울 때 쓴 소유 프레임 (우리가 띄운 툴팁만 닫기 위해)

local function OwnTip()
  return tipOwner ~= nil and GameTooltip and GameTooltip:IsShown() and GameTooltip:GetOwner() == tipOwner
end

-- owner: 이 프레임이 띄운 툴팁만 닫음 (세계 지도와 미니맵이 서로의 툴팁을 닫지 않게). nil이면 무엇이든.
local function HideTip(owner)
  if tipShown and (owner == nil or owner == tipOwner) then
    -- 그사이 다른 것(지도 핀 등)이 툴팁을 가져갔으면 그 툴팁은 닫지 않습니다.
    if OwnTip() then GameTooltip:Hide() end
    tipShown = false
    lastHoverKey = nil
  end
end

local function Draw()
  local child, map = Canvas()
  if not child then return end
  local mapID = MapID(map)
  if not (IsOn() and mapID and MapShowsQuests(mapID)) then
    if drawnKey then HideAll() end
    HideTip(child)
    return
  end
  local ids = Watched()
  local key = mapID .. ":" .. table.concat(ids, ",")
  if key == drawnKey then
    -- 같은 지도, 같은 목록: 목표 진행으로 다시 그릴 때도 1초에 한 번까지만
    if not dirty or GetTime() - lastDraw < 1 then return end
  end
  dirty = false
  lastDraw = GetTime()
  HideAll()
  local level = AreaLevel(map)
  for i, q in ipairs(ids) do
    local b = blobs[i]
    if not b then
      b = MakeBlob(child, map)
      if not b then break end
      blobs[i] = b
    end
    b:SetFrameLevel(level)
    pcall(b.SetMapID, b, mapID)
    pcall(b.DrawNone, b)
    pcall(b.DrawBlob, b, q, true)
    b:Show()
    blobQuest[i] = q
  end
  drawnKey = key
end

-- 지도 배율이 바뀌었을 때(확대/축소, OpenMap 휠 포함) 같은 범위를 새 배율로 다시 그립니다.
-- 범위 그림은 그릴 때의 화면 위치로 그려지므로, 배율이 바뀐 뒤 다시 그리지 않으면 틀어집니다.
local function Redraw(child)
  if not drawnKey then return end
  child:GetRect()   -- 새 배율의 위치를 먼저 계산시킵니다
  for i, b in ipairs(blobs) do
    local q = blobQuest[i]
    if q and b:IsShown() then
      b:GetRect()
      pcall(b.DrawNone, b)
      pcall(b.DrawBlob, b, q, true)
    end
  end
end

local lastScale, lastW, lastH = nil, nil, nil
local function ViewChanged(child)
  local s, w, h = child:GetScale(), child:GetWidth(), child:GetHeight()
  if s == lastScale and w == lastW and h == lastH then return false end
  lastScale, lastW, lastH = s, w, h
  return true
end

-- 퀘스트 이름
local function Title(q)
  local QL = C_QuestLog
  if QL and QL.GetTitleForQuestID then
    local ok, t = pcall(QL.GetTitleForQuestID, q)
    if ok and type(t) == "string" and t ~= "" and not Secret(t) then return t end
  end
  return "퀘스트 " .. q
end

-- 목표 목록: { text, done }
local function Objectives(q)
  local out = {}
  local QL = C_QuestLog
  if not (QL and QL.GetQuestObjectives) then return out end
  local ok, objs = pcall(QL.GetQuestObjectives, q)
  if not ok or type(objs) ~= "table" then return out end
  for _, o in ipairs(objs) do
    local t = o.text
    if type(t) == "string" and t ~= "" and not Secret(t) then
      out[#out + 1] = { text = t, done = o.finished and true or false }
    end
  end
  return out
end

-- 이 범위 그림이 커서 위치에 퀘스트를 가지고 있는지 (게임의 범위 판정 사용)
local function Ask(b, x, y)
  local ok, id = pcall(b.UpdateMouseOverTooltip, b, x, y)
  if ok and type(id) == "number" and not Secret(id) and id > 0 then return id end
  return nil
end

-- 커서 위치: 화면 좌표(UI 단위)와 캔버스 안 비율(0~1) 두 가지
local function CursorPoints(child)
  local cx, cy = GetCursorPosition()
  local ui = UIParent:GetEffectiveScale()
  local sx, sy = cx / ui, cy / ui
  local mx, my
  local s = child:GetEffectiveScale()
  local l, t, w, h = child:GetLeft(), child:GetTop(), child:GetWidth(), child:GetHeight()
  if l and t and w and h and w > 0 and h > 0 and s and s > 0 then
    mx = (cx / s - l) / w
    my = (t - cy / s) / h
  end
  return sx, sy, mx, my
end

local function Hovered(child)
  local sx, sy, mx, my = CursorPoints(child)
  local hits = {}
  local function Try(mode, x, y)
    if not x then return false end
    local found = false
    for i, b in ipairs(blobs) do
      local q = blobQuest[i]
      if q and b:IsShown() and Ask(b, x, y) == q then
        hits[#hits + 1] = q
        found = true
      end
    end
    if found and not hoverMode then hoverMode = mode end
    return found
  end
  if hoverMode == "screen" then Try("screen", sx, sy)
  elseif hoverMode == "map" then Try("map", mx, my)
  elseif not Try("screen", sx, sy) then Try("map", mx, my) end
  return hits
end

local function ShowTip(child, hits)
  local key = table.concat(hits, ",")
  if tipShown and key == lastHoverKey and OwnTip() then return end
  -- 다른 툴팁(핀, 아이콘 등)이 떠 있으면 그것을 덮지 않습니다.
  if GameTooltip:IsShown() and not OwnTip() then
    tipShown = false
    return
  end
  tipOwner = child
  GameTooltip:SetOwner(child, "ANCHOR_CURSOR")
  GameTooltip:ClearLines()
  for n, q in ipairs(hits) do
    if n > 1 then GameTooltip:AddLine(" ") end
    GameTooltip:AddLine(Title(q), 1, 0.82, 0)
    local objs = Objectives(q)
    if #objs == 0 then
      GameTooltip:AddLine("목표 정보 없음", 0.6, 0.6, 0.6)
    end
    for _, o in ipairs(objs) do
      GameTooltip:AddLine((o.done and C_DONE or C_TODO) .. o.text .. "|r", 1, 1, 1, true)
    end
  end
  GameTooltip:Show()
  tipShown = true
  lastHoverKey = key
end

local function Hover()
  local child, map, sc = Canvas()
  if not child then return end
  if not drawnKey or not IsOn() then HideTip(child) return end
  for _, b in ipairs(blobs) do if b:IsShown() then FollowAlpha(b, map) end end
  -- 확대하면 캔버스가 보이는 영역보다 커지므로, 실제로 보이는 지도 영역 안일 때만 확인합니다.
  if not sc:IsMouseOver() then HideTip(child) return end
  local hits = Hovered(child)
  if #hits > 0 then ShowTip(child, hits) else HideTip(child) end
end

-- 지도가 열려 있을 때만 일합니다.
local driver = CreateFrame("Frame")
local drawAcc, hoverAcc = 0, 0
local seenMap = nil
driver:SetScript("OnUpdate", function(_, el)
  local map = _G.WorldMapFrame
  if not (map and map:IsShown()) then
    local c = tipShown and Canvas()
    if c then HideTip(c) end
    return
  end
  el = el or 0
  drawAcc, hoverAcc = drawAcc + el, hoverAcc + el
  -- 지도 번호가 바뀌면 바로 다시 그립니다 (OpenMap은 확대하는 동안 아래 지역 지도가 바뀝니다)
  local mid = MapID(map)
  if mid ~= seenMap then
    seenMap = mid
    drawAcc = DRAW_EVERY
  end
  -- 배율 변화는 매 프레임 확인 (확대 중에 범위가 늦게 따라오지 않게)
  local child = drawnKey and Canvas()
  if child and ViewChanged(child) then pcall(Redraw, child) end
  if drawAcc >= DRAW_EVERY then
    drawAcc = 0
    pcall(Draw)
  end
  if hoverAcc >= HOVER_EVERY then
    hoverAcc = 0
    pcall(Hover)
  end
end)
driver:RegisterEvent("QUEST_LOG_UPDATE")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
pcall(driver.RegisterEvent, driver, "QUEST_WATCH_LIST_CHANGED")
local mmDirty = true
driver:SetScript("OnEvent", function()
  -- 목표가 진행되면 범위 모양이 바뀌므로 다음 확인 때 다시 그립니다.
  dirty = true
  mmDirty = true
end)

-- 미니맵 --------------------------------------------------------------------------
-- 미니맵 위에 "지역 지도 전체 크기"의 범위 그림을 놓고, 내 위치가 미니맵 가운데 오도록 매 프레임 옮깁니다.
--   크기(픽셀) = 지역의 실제 크기(야드) / 미니맵 반경(야드) × 미니맵 반지름(픽셀)
--   지역 크기: C_Map.GetWorldPosFromMapPos (지도 모서리의 실제 좌표), 미니맵 반경: C_Minimap.GetViewRadius
--   (Shortest Path Forever 가 이 클라이언트에서 미니맵 경로를 그릴 때 쓰는 것과 같은 게임 API입니다.
--    SPF 공개 API에는 미니맵 그리기나 좌표 변환 함수가 없어서 SPF 내부 함수는 쓰지 않습니다.)
-- 미니맵 밖으로 나간 부분은 잘라서 보이지 않게 합니다. 범위 그림은 마우스를 받지 않습니다.
-- 미니맵 회전 설정(rotateMinimap)이 켜져 있으면 범위 그림을 돌릴 수 없어서 표시하지 않습니다.
-- 설정: KQGDB.areaMinimapOff = true 이면 미니맵만 꺼짐

local mmBox                   -- 미니맵 영역으로 잘라 주는 틀
local mmBlobs, mmQuest = {}, {}
local mmKey = nil             -- 그린 퀘스트 목록 (번호를 이은 글자)
local mmMap = nil             -- 그린 지도 번호
local mmSizeW, mmSizeH = nil, nil
local mmLastDraw = 0
local mmWhy = "아직 확인 안 됨"   -- 진단용: 지금 표시하지 않는 이유
local yardCache = {}

local function MinimapOn()
  local d = DB()
  return d ~= nil and not d.areaOff and not d.areaMinimapOff
end

-- 지역 지도의 실제 크기(야드): 가로, 세로. 모를 때 nil
local function MapYards(mapID)
  local c = yardCache[mapID]
  if c == nil then
    yardCache[mapID] = false
    if C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D then
      local ok, cont1, tl = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(0, 0))
      local ok2, cont2, br = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(1, 1))
      if ok and ok2 and cont1 and cont1 == cont2 and tl and br then
        local x0, y0 = tl:GetXY()
        local x1, y1 = br:GetXY()
        -- 게임 좌표: 첫 값은 북쪽, 둘째 값은 서쪽으로 커집니다. 지도 가로 = 둘째 값 차이, 세로 = 첫 값 차이
        local w, h = math.abs(y0 - y1), math.abs(x0 - x1)
        if w > 0 and h > 0 then yardCache[mapID] = { w = w, h = h } end
      end
    end
    c = yardCache[mapID]
  end
  return c or nil
end

-- 내 위치: 지도 번호, 지도 안 x, y (0~1)
local function PlayerSpot()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
  local ok, m = pcall(C_Map.GetBestMapForUnit, "player")
  if not ok or type(m) ~= "number" or Secret(m) then return nil end
  local ok2, pos = pcall(C_Map.GetPlayerMapPosition, m, "player")
  if not ok2 or type(pos) ~= "table" then return nil end
  local x, y = pos.x, pos.y
  if type(pos.GetXY) == "function" then x, y = pos:GetXY() end
  if type(x) ~= "number" or type(y) ~= "number" or Secret(x) or Secret(y) then return nil end
  return m, x, y
end

local function MinimapRadius()
  if not (C_Minimap and C_Minimap.GetViewRadius) then return nil end
  local ok, r = pcall(C_Minimap.GetViewRadius)
  if ok and type(r) == "number" and not Secret(r) and r > 0 then return r end
  return nil
end

local function MMHideAll()
  for i, b in ipairs(mmBlobs) do
    pcall(b.DrawNone, b)
    b:Hide()
    mmQuest[i] = nil
  end
  mmKey, mmMap, mmSizeW, mmSizeH = nil, nil, nil, nil
end

-- 추적 목록은 이벤트가 왔거나 0.5초가 지났을 때만 다시 읽습니다 (매 프레임 읽지 않게).
local mmIds, mmIdsKey, mmIdsAt = {}, "", -1
local function MMWatched()
  local now = GetTime()
  if mmDirty or now - mmIdsAt > 0.5 then
    mmIds = Watched()
    mmIdsKey = table.concat(mmIds, ",")
    mmIdsAt = now
  end
  return mmIds, mmIdsKey
end

local function MMBox()
  if mmBox then return mmBox end
  local mm = _G.Minimap
  if type(mm) ~= "table" then return nil end
  local f = CreateFrame("Frame", nil, mm)
  f:SetAllPoints(mm)
  f:EnableMouse(false)
  pcall(f.SetClipsChildren, f, true)
  f:SetFrameLevel((mm:GetFrameLevel() or 1) + 1)
  mmBox = f
  return f
end

local function MMMakeBlob(box)
  if canMake == false then return nil end
  local ok, b = pcall(CreateFrame, "QuestPOIFrame")
  if not ok or type(b) ~= "table" or type(b.DrawBlob) ~= "function" then
    canMake = false
    return nil
  end
  canMake = true
  b:SetParent(box)
  b:EnableMouse(false)
  pcall(b.SetFillTexture, b, FILL_TEX)
  pcall(b.SetBorderTexture, b, BORDER_TEX)
  pcall(b.SetBorderScalar, b, 1)
  pcall(b.SetFillAlpha, b, FILL_ALPHA)
  pcall(b.SetBorderAlpha, b, BORDER_ALPHA)
  b:SetFrameLevel(box:GetFrameLevel())
  return b
end

-- 매 프레임: 크기와 위치를 맞추고, 필요할 때만 다시 그립니다.
local function MMUpdate()
  local mm = _G.Minimap
  if not (MinimapOn() and mm and mm:IsVisible()) then
    mmWhy = not MinimapOn() and "설정에서 꺼짐" or "미니맵이 보이지 않음"
    if mmKey then MMHideAll() end
    return
  end
  if GetCVar and GetCVar("rotateMinimap") == "1" then
    mmWhy = "미니맵 회전 설정이 켜져 있음"
    if mmKey then MMHideAll() end
    return
  end
  local mapID, px, py = PlayerSpot()
  local yards = mapID and MapYards(mapID)
  local radius = MinimapRadius()
  if not (mapID and yards and radius) then
    mmWhy = not mapID and "내 위치를 알 수 없음 (던전 등)" or (not yards and "이 지역의 크기 정보가 없음" or "미니맵 반경을 알 수 없음")
    if mmKey then MMHideAll() end
    return
  end
  local box = MMBox()
  if not box then mmWhy = "미니맵 틀을 만들 수 없음" return end
  local perYard = (mm:GetWidth() / 2) / radius
  local w, h = yards.w * perYard, yards.h * perYard

  local ids, idsKey = MMWatched()
  local sizeChanged = (mmSizeW == nil) or math.abs(w - mmSizeW) > 0.5 or math.abs(h - mmSizeH) > 0.5
  local listChanged = mapID ~= mmMap or idsKey ~= mmKey
  local redraw = listChanged or sizeChanged or (mmDirty and GetTime() - mmLastDraw >= 1)

  for i, q in ipairs(ids) do
    local b = mmBlobs[i]
    if not b then
      b = MMMakeBlob(box)
      if not b then mmWhy = "범위 그림 도구를 만들 수 없음" return end
      mmBlobs[i] = b
    end
    b:SetSize(w, h)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", mm, "CENTER", -px * w, py * h)
    if redraw then
      b:Show()
      b:GetRect()
      pcall(b.SetMapID, b, mapID)
      pcall(b.DrawNone, b)
      pcall(b.DrawBlob, b, q, true)
      mmQuest[i] = q
    end
  end
  if redraw then
    for i = #ids + 1, #mmBlobs do
      pcall(mmBlobs[i].DrawNone, mmBlobs[i])
      mmBlobs[i]:Hide()
      mmQuest[i] = nil
    end
    mmKey, mmMap, mmSizeW, mmSizeH = idsKey, mapID, w, h
    mmDirty = false
    mmLastDraw = GetTime()
  end
  mmWhy = "표시 중 (" .. #ids .. "개)"
end

-- 미니맵 위 마우스: 범위 그림이 지역 지도 전체 크기이므로 그 안의 비율 좌표 = 지도 좌표
local function MMHover()
  local mm = _G.Minimap
  if not (mm and mmKey and MinimapOn() and mm:IsVisible() and mm:IsMouseOver()) then
    HideTip(mm)
    return
  end
  local b1 = mmBlobs[1]
  if not (b1 and b1:IsShown()) then HideTip(mm) return end
  local s = b1:GetEffectiveScale()
  local l, t, w, h = b1:GetLeft(), b1:GetTop(), b1:GetWidth(), b1:GetHeight()
  if not (l and t and w and h and w > 0 and h > 0 and s and s > 0) then HideTip(mm) return end
  local cx, cy = GetCursorPosition()
  local mx, my = (cx / s - l) / w, (t - cy / s) / h
  local hits = {}
  for i, b in ipairs(mmBlobs) do
    local q = mmQuest[i]
    if q and b:IsShown() and Ask(b, mx, my) == q then hits[#hits + 1] = q end
  end
  if #hits > 0 then ShowTip(mm, hits) else HideTip(mm) end
end

local mmDriver = CreateFrame("Frame")
local mmHoverAcc = 0
mmDriver:SetScript("OnUpdate", function(_, el)
  pcall(MMUpdate)
  mmHoverAcc = mmHoverAcc + (el or 0)
  if mmHoverAcc >= HOVER_EVERY then
    mmHoverAcc = 0
    pcall(MMHover)
  end
end)

-- 명령 ---------------------------------------------------------------------------

local function Diagnose()
  local child, map = Canvas()
  local mapID = map and MapID(map)
  local ids = Watched()
  local poi = GetCVar and GetCVar("questPOI")
  Print("범위 표시 진단")
  Print("  설정: " .. (IsOn() and "켜짐" or "꺼짐") .. " / 게임 questPOI = " .. tostring(poi))
  Print("  추적 퀘스트: " .. #ids .. "개" .. (#ids > 0 and (" (" .. table.concat(ids, ", ") .. ")") or ""))
  Print("  세계 지도 캔버스: " .. (child and "있음" or "없음") .. " / 지도 번호: " .. tostring(mapID)
    .. (mapID and (MapShowsQuests(mapID) and " (범위 표시 지도)" or " (세계/대륙 지도라 표시 안 함)") or ""))
  local ok, b = true, blobs[1]
  if not b then ok, b = pcall(CreateFrame, "QuestPOIFrame") end
  if ok and type(b) == "table" then
    local names = { "SetMapID", "DrawBlob", "DrawNone", "UpdateMouseOverTooltip", "SetFillTexture", "SetBorderTexture" }
    local have = {}
    for _, nm in ipairs(names) do have[#have + 1] = nm .. (type(b[nm]) == "function" and " O" or " X") end
    Print("  범위 그림 도구(QuestPOIFrame): 만들 수 있음 / " .. table.concat(have, ", "))
    if b ~= blobs[1] then b:Hide() end
  else
    Print("  범위 그림 도구(QuestPOIFrame): 이 클라이언트에서 만들 수 없음")
  end
  local shown = 0
  for i, bb in ipairs(blobs) do if blobQuest[i] and bb:IsShown() then shown = shown + 1 end end
  Print("  지금 그린 범위: " .. shown .. "개 / 마우스 판정 방식: "
    .. (hoverMode == "screen" and "화면 좌표" or hoverMode == "map" and "지도 좌표" or "아직 확인 안 됨 (지도를 열고 범위 위에 마우스를 올려 보세요)"))
  -- 미니맵
  local m, px, py = PlayerSpot()
  local yards = m and MapYards(m)
  local shape = GetMinimapShape and GetMinimapShape() or "ROUND(기본)"
  Print("  미니맵: " .. mmWhy .. " / 설정 " .. (MinimapOn() and "켜짐" or "꺼짐")
    .. " / 모양 " .. tostring(shape) .. " / 회전 " .. tostring(GetCVar and GetCVar("rotateMinimap")))
  Print("  미니맵 계산: 반경 " .. tostring(MinimapRadius() and string.format("%.0f야드", MinimapRadius()) or "모름")
    .. " / 지역 " .. tostring(m) .. (yards and string.format(" (%.0f x %.0f야드)", yards.w, yards.h) or " (크기 모름)")
    .. (px and string.format(" / 내 위치 %.1f, %.1f", px * 100, py * 100) or "")
    .. (mmSizeW and string.format(" / 그림 크기 %.0f x %.0f", mmSizeW, mmSizeH) or ""))
end

K.AreaCommand = function(arg)
  arg = arg or ""
  local d = DB()
  if not d then return end
  if arg == "진단" or arg == "diag" then
    Diagnose()
    return
  end
  if arg == "미니맵" or arg == "minimap" then
    d.areaMinimapOff = not d.areaMinimapOff or nil
    mmDirty = true
    if d.areaMinimapOff then
      MMHideAll()
      HideTip(_G.Minimap)
    end
    Print("추적 퀘스트 범위 표시(미니맵) " .. (d.areaMinimapOff and "꺼짐" or "켜짐"))
    return
  end
  d.areaOff = not d.areaOff or nil
  dirty = true
  mmDirty = true
  if d.areaOff then
    HideAll()
    MMHideAll()
    HideTip()
  end
  Print("추적 퀘스트 범위 표시(세계 지도·미니맵) " .. (d.areaOff and "꺼짐" or "켜짐"))
end
