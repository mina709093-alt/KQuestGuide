-- 위험 구간 경고: 전투 중이 아닐 때 주변 적 이름표를 보고 위험해 보이면 화면 가운데에 짧게 알립니다.
--   혼자일 때: 적 3마리 이상, 또는 나보다 2레벨 이상 높은 적, 또는 정예
--   파티일 때: 적 5마리 이상, 또는 나보다 3레벨 이상 높은 적, 또는 정예
--   같은 곳(지도 위 가까운 범위)에서는 2분에 한 번만 알립니다.
-- 검증(DangerProbe, 2026-11-17): 적 이름표로 수·레벨·정예를 읽을 수 있고 전투 중에도 숨겨지지 않음.
-- 적 이름표가 켜져 있어야 동작합니다. (아군 이름표는 필요 없음)
-- /kqg 위험 : 켜기/끄기
local KQG = KQG
if not KQG then return end

local function db() return KQG.DB and KQG.DB() end
local function Print(m) if KQG.Print then KQG.Print(m) end end
local isSecret = issecretvalue or function() return false end

local RULE = {
  solo = { count = 3, level = 2 },
  party = { count = 5, level = 3 },
}
local COOLDOWN = 120
local INTERVAL = 1.5

local function usable(v)
  if v == nil then return false end
  local ok, s = pcall(isSecret, v)
  return not (ok and s)
end

local function On()
  local d = db()
  return d and d.danger ~= false
end

-- 화면 가운데 알림
local msg = CreateFrame("Frame", nil, UIParent)
msg:SetSize(600, 40)
msg:SetPoint("CENTER", 0, 180)
msg:SetFrameStrata("HIGH")
msg:Hide()
msg.text = msg:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
msg.text:SetPoint("CENTER")
pcall(msg.text.SetFont, msg.text, "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Bold.ttf", 20, "OUTLINE")
msg.text:SetTextColor(1, 0.55, 0.2)
local shownAt = 0
msg:SetScript("OnUpdate", function(self)
  local t = GetTime() - shownAt
  if t > 4 then self:Hide() return end
  self:SetAlpha(t < 3 and 1 or (4 - t))
end)

local function Show(text)
  msg.text:SetText(text)
  shownAt = GetTime()
  msg:SetAlpha(1)
  msg:Show()
end

-- 같은 곳 판단: 지도 번호 + 좌표를 4% 칸으로 나눈 값
local told = {}
local function SpotKey()
  local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if not m then return "?" end
  local ok, pos = pcall(C_Map.GetPlayerMapPosition, m, "player")
  if not ok or not pos then return tostring(m) end
  local x, y = pos:GetXY()
  return ("%d:%d:%d"):format(m, math.floor((x or 0) * 25), math.floor((y or 0) * 25))
end

local function Scan()
  if not On() or InCombatLockdown() or UnitIsDeadOrGhost("player") then return end
  if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
  local rule = IsInGroup() and RULE.party or RULE.solo
  local my = UnitLevel("player") or 1
  local count, elite, high, highLv = 0, 0, 0, 0
  for _, p in ipairs(C_NamePlate.GetNamePlates() or {}) do
    local u = p.namePlateUnitToken or (p.UnitFrame and p.UnitFrame.unit)
    if u then
      local atk, react, lvl, cls, dead = UnitCanAttack("player", u), UnitReaction(u, "player"), UnitLevel(u), UnitClassification(u), UnitIsDead(u)
      if usable(atk) and usable(react) and usable(lvl) and usable(cls) and atk and not dead and react <= 3
        and cls ~= "trivial" and cls ~= "minus" and not UnitIsPlayer(u) then
        count = count + 1
        if cls == "elite" or cls == "rareelite" or cls == "worldboss" then elite = elite + 1 end
        if lvl == -1 or lvl - my >= rule.level then
          high = high + 1
          highLv = math.max(highLv, lvl == -1 and 99 or lvl)
        end
      end
    end
  end
  local parts = {}
  if count >= rule.count then parts[#parts + 1] = ("적 %d마리"):format(count) end
  if elite > 0 then parts[#parts + 1] = ("정예 %d"):format(elite) end
  if high > 0 then parts[#parts + 1] = highLv == 99 and "해골 레벨 몹" or ("%d레벨 몹"):format(highLv) end
  if #parts == 0 then return end
  local key = SpotKey()
  local now = GetTime()
  if told[key] and now - told[key] < COOLDOWN then return end
  told[key] = now
  Show("⚠ 주변 위험: " .. table.concat(parts, " · "))
end

local acc = 0
local f = CreateFrame("Frame")
f:SetScript("OnUpdate", function(_, e)
  acc = acc + e
  if acc < INTERVAL then return end
  acc = 0
  pcall(Scan)
end)

KQG.DangerCommand = function()
  local d = db()
  if not d then return end
  d.danger = not On()
  Print("위험 구간 경고 " .. (On() and "켜짐 (혼자: 3마리/2레벨↑, 파티: 5마리/3레벨↑, 정예는 항상)" or "꺼짐"))
end
