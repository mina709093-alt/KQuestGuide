-- 레벨 구간 기록 (리포트): 레벨마다 걸린 시간, 완료한 퀘스트 수, 시간당 경험치, 경험치를 많이 얻은 지역
-- 자동으로 뜨는 창은 없습니다. /kqg 기록 으로 열 때만 보입니다.
-- 모든 값은 게임에서 직접 잰 값입니다. (접속해 있던 시간 기준, 캐릭터별 저장)
local KQG = KQG
if not KQG then return end

local function db() return KQG.DB and KQG.DB() end
local MAX_KEEP = 60

local J            -- 이 캐릭터의 기록 { levels = { [레벨] = 구간 }, cur = 레벨 }
local lastXP, lastMax, lastTick

local function charKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "")
end

local function zoneName()
  local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if m and KQG.MapName then return KQG.MapName(m) end
  return GetZoneText and GetZoneText() or "?"
end

local function seg(level)
  J.levels[level] = J.levels[level] or { secs = 0, xp = 0, questXP = 0, quests = 0, zones = {}, started = time() }
  return J.levels[level]
end

-- 접속 시간 누적 (1초 단위로, 자리 비움도 포함되는 접속 시간 기준)
local function tick()
  if not J then return end
  local now = GetTime()
  if lastTick then
    local d = now - lastTick
    if d > 0 and d < 60 then seg(J.cur).secs = seg(J.cur).secs + d end
  end
  lastTick = now
end

local function onXP()
  if not J then return end
  local xp, mx = UnitXP("player"), UnitXPMax("player")
  if lastXP and lastMax then
    local gain = xp - lastXP
    if gain < 0 then gain = (lastMax - lastXP) + xp end -- 레벨업으로 넘어감
    if gain > 0 then
      local s = seg(J.cur)
      s.xp = s.xp + gain
      local z = zoneName()
      s.zones[z] = (s.zones[z] or 0) + gain
    end
  end
  lastXP, lastMax = xp, mx
end

local function prune()
  local keys = {}
  for lv in pairs(J.levels) do keys[#keys + 1] = lv end
  table.sort(keys)
  while #keys > MAX_KEEP do J.levels[table.remove(keys, 1)] = nil end
end

---------------------------------------------------------------------------
-- 창
---------------------------------------------------------------------------
local FONT = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Regular.ttf"
local FONT_B = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Bold.ttf"
local win, text

local function fmtTime(s)
  s = math.floor(s or 0)
  if s >= 3600 then return ("%d시간 %d분"):format(math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  return ("%d분"):format(math.floor(s / 60))
end

local function topZone(z)
  local best, bv = nil, 0
  for k, v in pairs(z or {}) do if v > bv then best, bv = k, v end end
  return best or "-"
end

local function Build()
  win = CreateFrame("Frame", "KQGJournalFrame", UIParent, "BackdropTemplate")
  win:SetSize(500, 400)
  win:SetPoint("CENTER", -220, 0)
  win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  win:SetBackdropColor(0.035, 0.055, 0.065, 0.96)
  win:SetBackdropBorderColor(0, 0, 0, 1)
  win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)
  win:SetFrameStrata("DIALOG"); win:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "KQGJournalFrame")
  local title = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if not pcall(title.SetFont, title, FONT_B, 15, "") then title:SetFontObject(GameFontHighlightLarge) end
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("레벨 구간 기록")
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)
  local sf = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 12, -40); sf:SetPoint("BOTTOMRIGHT", -30, 12)
  local child = CreateFrame("Frame", nil, sf)
  child:SetSize(450, 10)
  sf:SetScrollChild(child)
  text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if not pcall(text.SetFont, text, FONT, 12, "") then text:SetFontObject(GameFontHighlight) end
  text:SetPoint("TOPLEFT"); text:SetWidth(450); text:SetJustifyH("LEFT"); text:SetSpacing(3)
  win.child = child
end

local function Render()
  tick()
  local out = {}
  local function add(t) out[#out + 1] = t end
  local lv = J.cur
  local s = seg(lv)
  local xp, mx = UnitXP("player"), UnitXPMax("player")
  local rate = s.secs > 120 and (s.xp / s.secs * 3600) or nil
  add(("|cffffd200지금 %d레벨|r  경험치 %d / %d (%.0f%%)"):format(lv, xp, mx, mx > 0 and xp / mx * 100 or 0))
  add(("  이 레벨에서: 접속 %s · 퀘스트 %d개 · 경험치 %d%s"):format(fmtTime(s.secs), s.quests, s.xp,
    rate and (" · 시간당 %d"):format(rate) or ""))
  if rate and rate > 0 then
    add(("  |cff4db8e0지금 속도면 다음 레벨까지 약 %s|r"):format(fmtTime((mx - xp) / rate * 3600)))
  else
    add("  |cff8fa0b0속도는 2분 이상 기록되면 계산됩니다.|r")
  end
  add("")
  add("|cffffd200지난 레벨|r  |cff8fa0b0(레벨 · 걸린 접속 시간 · 퀘스트 · 시간당 경험치 · 경험치를 가장 많이 얻은 지역)|r")
  local keys = {}
  for k, v in pairs(J.levels) do if k ~= lv and v.secs > 0 then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return a > b end)
  if #keys == 0 then add("  아직 기록이 없습니다. 레벨이 오르면 여기에 쌓입니다.") end
  local totalS, totalQ = 0, 0
  for _, k in ipairs(keys) do
    local v = J.levels[k]
    local r = v.secs > 60 and math.floor(v.xp / v.secs * 3600) or 0
    add(("  %2d → %d레벨  %s · 퀘스트 %d개 · 시간당 %d · %s"):format(k, k + 1, fmtTime(v.secs), v.quests, r, topZone(v.zones)))
    totalS, totalQ = totalS + v.secs, totalQ + v.quests
  end
  if #keys > 0 then
    add("")
    add(("|cff8fa0b0기록된 %d개 레벨 합계: 접속 %s · 퀘스트 %d개|r"):format(#keys, fmtTime(totalS), totalQ))
  end
  text:SetText(table.concat(out, "\n"))
  win.child:SetHeight(text:GetStringHeight() + 10)
end

---------------------------------------------------------------------------
-- 이벤트
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_XP_UPDATE")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("QUEST_TURNED_IN")
ev:SetScript("OnEvent", function(_, e, a1, a2)
  if e == "PLAYER_LOGIN" then
    local d = db()
    if not d then return end
    d.journal = d.journal or {}
    local key = charKey()
    d.journal[key] = d.journal[key] or { levels = {} }
    J = d.journal[key]
    J.cur = UnitLevel("player") or 1
    lastXP, lastMax, lastTick = UnitXP("player"), UnitXPMax("player"), GetTime()
    seg(J.cur)
    return
  end
  if not J then return end
  tick()
  if e == "PLAYER_XP_UPDATE" then
    onXP()
  elseif e == "PLAYER_LEVEL_UP" then
    onXP()
    J.cur = tonumber(a1) or (J.cur + 1)
    seg(J.cur)
    prune()
    lastXP, lastMax = UnitXP("player"), UnitXPMax("player")
  elseif e == "QUEST_TURNED_IN" then
    local s = seg(J.cur)
    s.quests = s.quests + 1
    if type(a2) == "number" then s.questXP = s.questXP + a2 end
  end
end)

local tk = CreateFrame("Frame")
local acc = 0
tk:SetScript("OnUpdate", function(_, el)
  acc = acc + el
  if acc >= 5 then acc = 0; tick(); if win and win:IsShown() then Render() end end
end)

KQG.JournalCommand = function()
  if not J then return end
  if not win then Build() end
  if win:IsShown() then win:Hide() else Render(); win:Show() end
end
