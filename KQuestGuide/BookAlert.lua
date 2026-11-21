-- 책 반납 퀘스트: 책 근처 알림
-- 책 위치(BookData.lua의 KQG.BookData + 게임에서 /kqg 책 추가 로 기록한 지점) 가까이 가면
-- "주변에 책이 있으니 찾아보세요" 창을 띄웁니다.
--   * 1초마다 내 위치를 확인하고, 거리는 야드로 잽니다(KQG.Measure, 본체와 같은 계산).
--   * 반경(기본 40야드) 안에 들어올 때 한 번 알리고(소리·채팅), 창은 가까이 있는 동안 계속 떠 있으며 거리가 바뀝니다.
--     반경의 1.5배 밖으로 멀어지거나, 책을 얻거나, 버튼을 누르면 닫힙니다. 반경의 1.5배 밖으로 나갔다가 다시 들어와야 또 알리고,
--     같은 지점은 120초 안에 다시 알리지 않습니다.
--   * 알리지 않는 경우: 그 책이 가방·은행에 있음, 수집 완료로 표시한 책, 무시로 표시한 지점, 전투 중(끝나면 다시 확인)
--   * 은행: 은행을 열 때 내용을 저장해 두고, 은행이 닫혀 있을 때도 그 기록으로 판단합니다.
--   * 가방이나 은행에서 한 번 본 책은 자동으로 "수집 완료"가 됩니다(반납해서 책이 사라져도 다시 알리지 않게).
-- 저장: KQGDB.book = { off, radius, spots = { 게임에서 기록한 지점 }, chars = { ["이름-서버"] = { done, ignore, bank, bankName, bankTime } } }
-- 명령: /kqg 책 (도움말: /kqg 책 도움)

local K = KQG
if type(K) ~= "table" then return end

local RADIUS_DEF, RADIUS_MIN, RADIUS_MAX = 40, 10, 200
local REARM = 1.5        -- 반경의 몇 배 밖으로 나가야 다시 알릴 수 있는지
local COOLDOWN = 120     -- 같은 지점을 다시 알리기까지 (초)
local CHECK_EVERY = 1    -- 위치 확인 주기 (초)
local POPUP_SECS = 10    -- 시험 알림(/kqg 책 시험) 창이 저절로 닫히기까지 (초)

-- 상수 스타일 색
local C_TEXT = { 0.93, 0.94, 0.96 }
local C_MUTED = { 0.55, 0.60, 0.63 }
local C_ACCENT = { 0.063, 0.816, 0.627 }

local function Print(t) if K.Print then K.Print(t) end end
local function Now() return GetTime and GetTime() or 0 end

local function Secret(v)
  if issecretvalue then
    local ok, r = pcall(issecretvalue, v)
    return ok and r
  end
  return false
end

local function charKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "")
end

-- 저장 데이터 (없으면 기본값을 채움) -----------------------------------------------

local function Store()
  local d = K.DB and K.DB()
  if type(d) ~= "table" then return nil end
  if type(d.book) ~= "table" then d.book = {} end
  local b = d.book
  if type(b.radius) ~= "number" then b.radius = RADIUS_DEF end
  if type(b.spots) ~= "table" then b.spots = {} end
  if type(b.chars) ~= "table" then b.chars = {} end
  return b
end

local function Char()
  local b = Store()
  if not b then return nil end
  local k = charKey()
  local c = b.chars[k]
  if type(c) ~= "table" then c = {} b.chars[k] = c end
  if type(c.done) ~= "table" then c.done = {} end
  if type(c.ignore) ~= "table" then c.ignore = {} end
  if type(c.bank) ~= "table" then c.bank = {} end
  if type(c.bankName) ~= "table" then c.bankName = {} end
  return c
end

-- 지점 ---------------------------------------------------------------------------

local function Num(v) return type(v) == "number" and v == v end
local function Str(v) return type(v) == "string" and v ~= "" end

-- 데이터 표 + 게임에서 기록한 지점을 한 목록으로 (번호는 이 순서)
local function AllSpots()
  local out = {}
  local function add(row, src)
    if type(row) ~= "table" then return end
    local s = {
      map = Num(row.map) and row.map or nil,
      zone = Str(row.zone) and row.zone or nil,
      book = Str(row.book) and row.book or nil,
      item = Num(row.item) and row.item or nil,
      itemName = Str(row.itemName) and row.itemName or nil,
      memo = Str(row.memo) and row.memo or nil,
      src = src,
      row = row,
    }
    if Num(row.x) and Num(row.y) and row.x >= 0 and row.x <= 100 and row.y >= 0 and row.y <= 100 then
      s.x, s.y = row.x, row.y
    end
    if not (s.map or s.zone) then return end
    out[#out + 1] = s
  end
  for _, row in ipairs(type(K.BookData) == "table" and K.BookData or {}) do add(row, "data") end
  local b = Store()
  for _, row in ipairs(b and b.spots or {}) do add(row, "user") end
  return out
end

local function SpotKey(s)
  if not (s.x and s.y) then return nil end
  return string.format("%s:%.1f:%.1f", tostring(s.map or s.zone), s.x, s.y)
end

-- 책 하나를 가리키는 키: 아이템 번호 → 이름 → (둘 다 없으면) 지점
local function BookKey(s)
  if s.item then return "i" .. s.item end
  local n = s.itemName or s.book
  if n then return "n" .. n end
  local sk = SpotKey(s)
  if sk then return "s" .. sk end
  return "z" .. tostring(s.map or s.zone) .. ":" .. tostring(s.memo or "")
end

local function BookTitle(s)
  return s.book or s.itemName or (s.item and ("아이템 " .. s.item)) or "책"
end

local function WhereText(s)
  local z = s.zone or (s.map and K.MapName and K.MapName(s.map)) or "?"
  if s.x then return string.format("%s %.1f, %.1f", z, s.x, s.y) end
  return z .. " (좌표 없음)"
end

-- 위치 -----------------------------------------------------------------------------

local function CurrentMap()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local ok, m = pcall(C_Map.GetBestMapForUnit, "player")
  if not ok or type(m) ~= "number" or Secret(m) then return nil end
  return m
end

local function PlayerXY(m)
  if not (m and C_Map and C_Map.GetPlayerMapPosition) then return nil end
  local ok, pos = pcall(C_Map.GetPlayerMapPosition, m, "player")
  if not ok or type(pos) ~= "table" then return nil end
  local x, y = pos.x, pos.y
  if type(pos.GetXY) == "function" then x, y = pos:GetXY() end
  if type(x) ~= "number" or type(y) ~= "number" or Secret(x) or Secret(y) then return nil end
  if x == 0 and y == 0 then return nil end
  return x * 100, y * 100
end

local function OnMap(s, m, mname)
  if s.map then return s.map == m end
  return s.zone ~= nil and s.zone == mname
end

-- 야드 거리 (같은 지도일 때만)
local function Dist(m, s)
  if not (s.x and K.Measure) then return nil end
  local ok, d = pcall(K.Measure, m, s.x, s.y)
  if ok and type(d) == "number" then return d end
  return nil
end

-- 가방 / 은행 ----------------------------------------------------------------------

local function Slots(bag)
  local f = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  if not f then return 0 end
  local ok, n = pcall(f, bag)
  return (ok and type(n) == "number") and n or 0
end

local function SlotItem(bag, slot)
  local f = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
  if not f then return nil end
  local ok, id = pcall(f, bag, slot)
  if ok and type(id) == "number" and not Secret(id) then return id end
  return nil
end

local function SlotCount(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if ok and type(info) == "table" and type(info.stackCount) == "number" then return info.stackCount end
  end
  return 1
end

local function ItemName(id)
  local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not f then return nil end
  local ok, n = pcall(f, id)
  if ok and type(n) == "string" and not Secret(n) then return n end
  return nil
end

local function ItemCount(id, bank)
  local f = (C_Item and C_Item.GetItemCount) or GetItemCount
  if not f then return 0 end
  local ok, n = pcall(f, id, bank)
  if ok and type(n) == "number" and not Secret(n) then return n end
  return 0
end

local function BagList()
  local n = NUM_BAG_SLOTS or 4
  local t = {}
  for b = 0, n do t[#t + 1] = b end
  return t
end

local function BankBagList()
  local first = (NUM_BAG_SLOTS or 4) + 1
  local t = { BANK_CONTAINER or -1 }
  for b = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do t[#t + 1] = b end
  return t
end

-- 가방 내용 (BAG_UPDATE 때만 다시 읽음)
local bagIds, bagNames = {}, {}
local bagDirty = true
local function ScanBags()
  bagIds, bagNames = {}, {}
  for _, bag in ipairs(BagList()) do
    for slot = 1, Slots(bag) do
      local id = SlotItem(bag, slot)
      if id then
        bagIds[id] = (bagIds[id] or 0) + SlotCount(bag, slot)
        local n = ItemName(id)
        if n then bagNames[n] = true end
      end
    end
  end
  bagDirty = false
end

-- 은행 내용을 저장 (은행이 열려 있을 때만 읽힘). 읽은 칸이 없으면 예전 기록을 그대로 둡니다.
local bankOpen = false
local function SnapshotBank()
  local c = Char()
  if not c then return false end
  local ids, names, slots = {}, {}, 0
  for _, bag in ipairs(BankBagList()) do
    local n = Slots(bag)
    slots = slots + n
    for slot = 1, n do
      local id = SlotItem(bag, slot)
      if id then
        ids[id] = (ids[id] or 0) + SlotCount(bag, slot)
        local nm = ItemName(id)
        if nm then names[nm] = true end
      end
    end
  end
  if slots == 0 then return false end
  c.bank, c.bankName, c.bankTime = ids, names, time and time() or 0
  return true
end

-- 이 책을 가지고 있으면 "가방" / "은행" / "은행(기록)"
local function Owned(s, c)
  if bagDirty then ScanBags() end
  if s.item then
    if bagIds[s.item] or ItemCount(s.item, false) > 0 then return "가방" end
    if ItemCount(s.item, true) > 0 then return "은행" end
    if c and c.bank[s.item] then return "은행(기록)" end
    return nil
  end
  local n = s.itemName or s.book
  if n then
    if bagNames[n] then return "가방" end
    if c and c.bankName[n] then return "은행(기록)" end
  end
  return nil
end

-- 가방·은행에서 본 책은 자동으로 수집 완료
local function MarkSeen()
  local c = Char()
  if not c then return 0 end
  local n = 0
  for _, s in ipairs(AllSpots()) do
    if (s.item or s.itemName or s.book) then
      local key = BookKey(s)
      if not c.done[key] and Owned(s, c) then
        c.done[key] = "auto"
        n = n + 1
      end
    end
  end
  return n
end

-- 상태: "보유:가방" / "완료" / "무시" / nil(알림 대상)
local function StateOf(s, c)
  if not c then return nil end
  local where = Owned(s, c)
  if where then return "보유:" .. where end
  if c.done[BookKey(s)] then return "완료" end
  local sk = SpotKey(s)
  if sk and c.ignore[sk] then return "무시" end
  return nil
end

-- 알림 창 --------------------------------------------------------------------------

local popup
local popupToken = 0
local function BuildPopup()
  local f = CreateFrame("Frame", "KQGBookAlert", UIParent, "BackdropTemplate")
  f:SetSize(380, 132)
  f:SetPoint("TOP", 0, -120)
  f:SetFrameStrata("DIALOG")
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    f:SetBackdropColor(0.035, 0.055, 0.065, 0.96)
    f:SetBackdropBorderColor(0, 0, 0, 1)
  end
  local ac = f:CreateTexture(nil, "ARTWORK")
  ac:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  ac:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  ac:SetHeight(3)
  if ac.SetColorTexture then
    ac:SetColorTexture(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
  else
    ac:SetTexture("Interface\\Buttons\\WHITE8X8")
    ac:SetVertexColor(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
  end
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOP", 0, -12)
  f.title:SetTextColor(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
  f.title:SetText("주변에 책이 있으니 찾아보세요")
  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.text:SetPoint("TOP", 0, -34)
  f.text:SetWidth(350)
  f.text:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  f.memo = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.memo:SetPoint("TOP", f.text, "BOTTOM", 0, -4)
  f.memo:SetWidth(350)
  f.memo:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  local function Btn(label, x, fn)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(108, 22)
    b:SetPoint("BOTTOM", f, "BOTTOM", x, 10)
    b:SetText(label)
    b:SetScript("OnClick", function() local ok, err = pcall(fn) if not ok then Print("책 알림 오류: " .. tostring(err)) end f:Hide() end)
    return b
  end
  Btn("수집 완료", -116, function()
    local c = Char()
    if c and f.spot then
      c.done[BookKey(f.spot)] = true
      Print("「" .. BookTitle(f.spot) .. "」 수집 완료로 표시했습니다. (되돌리기: /kqg 책 목록 → /kqg 책 취소 번호)")
    end
  end)
  Btn("이 지점 무시", 0, function()
    local c = Char()
    local sk = f.spot and SpotKey(f.spot)
    if c and sk then
      c.ignore[sk] = true
      Print("이 지점(" .. WhereText(f.spot) .. ")은 더 알리지 않습니다.")
    end
  end)
  Btn("닫기", 116, function() end)
  tinsert(UISpecialFrames, "KQGBookAlert")
  f:Hide()
  return f
end

local function PopupLine(s, dist, more)
  local line = "「" .. BookTitle(s) .. "」  " .. WhereText(s)
  if dist then line = line .. string.format("  (약 %d야드)", dist) end
  if more and more > 0 then line = line .. string.format("\n근처에 %d곳 더 있습니다.", more) end
  return line
end

-- 알림 창 띄우기. 실제 알림(test 아님)은 가까이 있는 동안 계속 떠 있고 Check가 거리를 고치거나 닫습니다.
-- test(/kqg 책 시험)일 때만 POPUP_SECS 뒤 저절로 닫힙니다.
local function ShowPopup(s, dist, more, test)
  popup = popup or BuildPopup()
  popup.spot, popup.more, popup.test = s, more, test and true or false
  local line = PopupLine(s, dist, more)
  popup.text:SetText(line)
  popup.memo:SetText(s.memo or "")
  popup:Show()
  if PlaySound then pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959) end
  popupToken = popupToken + 1
  local my = popupToken
  if test and C_Timer and C_Timer.After then
    C_Timer.After(POPUP_SECS, function() if popup and popupToken == my then popup:Hide() end end)
  end
  Print("주변에 책이 있으니 찾아보세요: " .. line:gsub("\n", " "))
end

-- 떠 있는 알림 창: 거리 고치기, 멀어지거나(반경의 1.5배 밖) 책을 얻었거나 완료·무시면 닫기
local function UpdatePopup(m, mname, c, radius)
  if not (popup and popup:IsShown() and popup.spot) or popup.test then return end
  local s = popup.spot
  local d = OnMap(s, m, mname) and Dist(m, s) or nil
  if not d or d > radius * REARM or StateOf(s, c) then
    popup:Hide()
    return
  end
  popup.text:SetText(PopupLine(s, d, popup.more))
end

-- 확인 (1초마다) ---------------------------------------------------------------------

local near = {}   -- [지점 키] = { inside = 반경 안에 있다고 본 상태, last = 마지막 알림 시각 }

local function Check()
  local b = Store()
  if not b or b.off then return end
  if InCombatLockdown and InCombatLockdown() then return end -- 전투 중엔 판단 보류 (끝나면 다음 확인에서 알림)
  local m = CurrentMap()
  if not m then return end
  local mname = K.MapName and K.MapName(m) or nil
  local c = Char()
  local radius = b.radius
  local now = Now()
  local hits = {}
  for _, s in ipairs(AllSpots()) do
    local sk = SpotKey(s)
    if sk and OnMap(s, m, mname) then
      local d = Dist(m, s)
      if d then
        local st = near[sk]
        if not st then st = {} near[sk] = st end
        if d > radius * REARM then
          st.inside = false
        elseif d <= radius and not st.inside then
          st.inside = true
          if not StateOf(s, c) and now - (st.last or -COOLDOWN) >= COOLDOWN then
            hits[#hits + 1] = { s = s, d = d, st = st }
          end
        end
      end
    end
  end
  if #hits == 0 then
    UpdatePopup(m, mname, c, radius)
    return
  end
  table.sort(hits, function(a, z) return a.d < z.d end)
  for _, h in ipairs(hits) do h.st.last = now end
  ShowPopup(hits[1].s, hits[1].d, #hits - 1)
end

local drv = CreateFrame("Frame")
local acc = 0
drv:SetScript("OnUpdate", function(_, el)
  acc = acc + (el or 0)
  if acc < CHECK_EVERY then return end
  acc = 0
  if not (K.DB and K.DB()) then return end
  local ok, err = pcall(Check)
  if not ok and K.ReportBug then K.ReportBug("책 알림", err, "") end
end)

for _, e in ipairs({ "BAG_UPDATE", "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED" }) do
  pcall(drv.RegisterEvent, drv, e)
end
drv:SetScript("OnEvent", function(_, e)
  e = e or event
  pcall(function()
    if not (K.DB and K.DB()) then return end
    if e == "BANKFRAME_OPENED" then
      bankOpen = true
      SnapshotBank()
    elseif e == "BANKFRAME_CLOSED" then
      if bankOpen then SnapshotBank() end
      bankOpen = false
    elseif e == "PLAYERBANKSLOTS_CHANGED" then
      if bankOpen then SnapshotBank() end
    else
      bagDirty = true
      if bankOpen then SnapshotBank() end
    end
    MarkSeen()
  end)
end)

-- 내보내기 창 (BookData.lua에 붙여 넣을 줄) --------------------------------------------

local function RowText(s)
  local parts = {}
  if s.map then parts[#parts + 1] = "map = " .. s.map end
  if s.zone then parts[#parts + 1] = string.format("zone = %q", s.zone) end
  if s.x then parts[#parts + 1] = string.format("x = %.1f, y = %.1f", s.x, s.y) end
  if s.book then parts[#parts + 1] = string.format("book = %q", s.book) end
  if s.item then parts[#parts + 1] = "item = " .. s.item end
  if s.itemName then parts[#parts + 1] = string.format("itemName = %q", s.itemName) end
  if s.memo then parts[#parts + 1] = string.format("memo = %q", s.memo) end
  return "  { " .. table.concat(parts, ", ") .. " },"
end

local exportFrame
local function ShowExport(text)
  if not exportFrame then
    local f = CreateFrame("Frame", "KQGBookExport", UIParent, "BackdropTemplate")
    f:SetSize(560, 360)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(s) s:StartMoving() end)
    f:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
    if f.SetBackdrop then
      f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
      f:SetBackdropColor(0.035, 0.055, 0.065, 0.97)
      f:SetBackdropBorderColor(0, 0, 0, 1)
    end
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOPLEFT", 14, -12)
    t:SetTextColor(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
    t:SetText("책 위치 내보내기 (BookData.lua 형식)")
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 14, -32)
    hint:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
    hint:SetText("Ctrl+A 로 전체 선택, Ctrl+C 로 복사합니다.")
    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 14, -52)
    sf:SetPoint("BOTTOMRIGHT", -34, 44)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetWidth(500)
    eb:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() f:Hide() end)
    eb:SetScript("OnTextChanged", function(s, user)
      if user and f.text and s:GetText() ~= f.text then s:SetText(f.text) end
    end)
    sf:SetScrollChild(eb)
    f.eb = eb
    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(80, 22)
    close:SetPoint("BOTTOMRIGHT", -14, 12)
    close:SetText("닫기")
    close:SetScript("OnClick", function() f:Hide() end)
    tinsert(UISpecialFrames, "KQGBookExport")
    exportFrame = f
  end
  exportFrame.text = text
  exportFrame.eb:SetText(text)
  exportFrame:Show()
  exportFrame.eb:SetFocus()
  exportFrame.eb:HighlightText()
end

-- 명령 ------------------------------------------------------------------------------

local function Help()
  Print("책 반납 퀘스트 알림 명령:")
  Print("  /kqg 책 켜기 / 끄기 — 알림 켜고 끄기")
  Print("  /kqg 책 위치 — 지금 위치(지도 번호, 좌표)")
  Print("  /kqg 책 추가 [아이템번호] 책이름 — 지금 위치를 책 지점으로 기록")
  Print("  /kqg 책 삭제 번호 — 기록한 지점 지우기 (직접 기록한 것만)")
  Print("  /kqg 책 목록 [전체] — 이 지역(또는 전체) 지점과 상태")
  Print("  /kqg 책 완료 / 무시 / 취소 번호 — 수집 완료 / 이 지점 무시 / 표시 풀기")
  Print("  /kqg 책 보유 — 책마다 가방·은행 보유와 완료 여부")
  Print("  /kqg 책 가방 [글자] — 가방 아이템 번호 보기 (책 아이템 번호 찾기용)")
  Print("  /kqg 책 반경 숫자 — 알림 반경 (" .. RADIUS_MIN .. "~" .. RADIUS_MAX .. "야드)")
  Print("  /kqg 책 시험 — 알림 창 시험   /kqg 책 내보내기 — BookData.lua 형식으로 보기")
  Print("  /kqg 책 초기화 확인 — 이 캐릭터의 완료·무시 표시 모두 지우기")
end

local function Summary()
  local b, c = Store(), Char()
  local all = AllSpots()
  local withXY, left, seen = 0, 0, {}
  for _, s in ipairs(all) do
    if s.x then withXY = withXY + 1 end
    local key = BookKey(s)
    if not seen[key] then
      seen[key] = true
      if not StateOf(s, c) then left = left + 1 end
    end
  end
  local bank = (c and c.bankTime and c.bankTime > 0 and date) and date("%m-%d %H:%M", c.bankTime) or "없음 (은행을 한 번 열어 주세요)"
  Print(string.format("책 알림 %s / 지점 %d곳 (좌표 있음 %d곳) / 남은 책 %d권 / 반경 %d야드 / 은행 기록: %s",
    b.off and "|cffff6060꺼짐|r" or "|cff10d0a0켜짐|r", #all, withXY, left, b.radius, bank))
  Print("명령 목록: /kqg 책 도움")
end

local function SpotByNum(arg)
  local n = tonumber(arg or "")
  local all = AllSpots()
  if not n or not all[n] then
    Print("번호를 확인해 주세요. (/kqg 책 목록 전체 에서 맨 앞 숫자)")
    return nil
  end
  return all[n], n
end

local function List(all)
  local c = Char()
  local m = CurrentMap()
  local mname = m and K.MapName and K.MapName(m) or nil
  local shown = 0
  for i, s in ipairs(AllSpots()) do
    local here = m and OnMap(s, m, mname)
    if all or here then
      local d = here and Dist(m, s)
      local st = StateOf(s, c) or "알림 대상"
      if not s.x then st = "좌표 없음" end
      Print(string.format("  %d. %s — %s%s [%s]%s", i, BookTitle(s), WhereText(s),
        d and string.format(" %d야드", d) or "", st, s.src == "user" and " (직접 기록)" or ""))
      shown = shown + 1
    end
  end
  if shown == 0 then
    Print(all and "책 지점이 없습니다." or ("이 지역(" .. tostring(mname or m) .. ")에는 책 지점이 없습니다. 전체: /kqg 책 목록 전체"))
  end
end

local function Own()
  local c = Char()
  local seen, n = {}, 0
  for _, s in ipairs(AllSpots()) do
    local key = BookKey(s)
    if not seen[key] and (s.item or s.itemName or s.book) then
      seen[key] = true
      n = n + 1
      local where = Owned(s, c)
      local done = c.done[key]
      Print(string.format("  %s%s — 보유: %s / 완료: %s", BookTitle(s), s.item and (" #" .. s.item) or "",
        where or "없음", done == "auto" and "예 (가방·은행에서 확인)" or (done and "예 (직접 표시)" or "아니요")))
    end
  end
  if n == 0 then Print("이름이나 아이템 번호가 적힌 책이 아직 없습니다. /kqg 책 추가 로 기록하거나 BookData.lua를 채워 주세요.") end
  if c.bankTime and c.bankTime > 0 and date then
    Print("은행 기록: " .. date("%m-%d %H:%M", c.bankTime) .. (bankOpen and " (지금 열려 있음)" or ""))
  else
    Print("은행 기록 없음: 은행을 한 번 열면 저장합니다.")
  end
end

local function BagDump(filter)
  local n = 0
  for _, bag in ipairs(BagList()) do
    for slot = 1, Slots(bag) do
      local id = SlotItem(bag, slot)
      if id then
        local nm = ItemName(id) or "?"
        if not Str(filter) or nm:find(filter, 1, true) then
          n = n + 1
          if n <= 30 then Print(string.format("  [%d:%d] #%d %s", bag, slot, id, nm)) end
        end
      end
    end
  end
  if n == 0 then Print("가방에서 찾은 아이템이 없습니다.") elseif n > 30 then Print("  ... 외 " .. (n - 30) .. "개") end
end

K.BookCommand = function(arg)
  arg = arg or ""
  local b, c = Store(), Char()
  if not (b and c) then return end
  local cmd, rest = arg:match("^(%S+)%s*(.-)%s*$")
  cmd = cmd or ""
  if cmd == "" then
    Summary()
  elseif cmd == "도움" or cmd == "help" then
    Help()
  elseif cmd == "켜기" or cmd == "on" then
    b.off = false
    Print("책 알림 켜짐")
  elseif cmd == "끄기" or cmd == "off" then
    b.off = true
    if popup then popup:Hide() end
    Print("책 알림 꺼짐")
  elseif cmd == "위치" or cmd == "pos" then
    local m = CurrentMap()
    local x, y = PlayerXY(m)
    if not (m and x) then Print("지금 위치를 알 수 없습니다. (인스턴스 안이거나 지도 정보가 없음)") return end
    Print(string.format("지도 %d (%s), 좌표 %.1f, %.1f", m, tostring(K.MapName and K.MapName(m)), x, y))
    Print(RowText({ map = m, zone = K.MapName and K.MapName(m) or nil, x = x, y = y }))
  elseif cmd == "추가" or cmd == "add" then
    local m = CurrentMap()
    local x, y = PlayerXY(m)
    if not (m and x) then Print("지금 위치를 알 수 없어 기록하지 못했습니다.") return end
    local item, name = rest:match("^(%d+)%s*(.-)$")
    item = tonumber(item)
    if not item then name = rest end
    if not Str(name) and item then name = ItemName(item) end
    if not Str(name) then Print("책 이름을 적어 주세요. 예: /kqg 책 추가 낡은 일지  (아이템 번호를 알면 /kqg 책 추가 12345 낡은 일지)") return end
    local row = { map = m, zone = K.MapName and K.MapName(m) or nil, x = math.floor(x * 10 + 0.5) / 10, y = math.floor(y * 10 + 0.5) / 10, book = name, item = item }
    b.spots[#b.spots + 1] = row
    -- 지금 서 있는 곳이라 바로 알리지 않음 (나갔다 다시 오면 알림)
    local sk = string.format("%s:%.1f:%.1f", tostring(row.map), row.x, row.y)
    near[sk] = { inside = true }
    Print(string.format("기록했습니다: 「%s」 %s %.1f, %.1f (번호 %d)", name, tostring(row.zone or m), row.x, row.y, #AllSpots()))
  elseif cmd == "삭제" or cmd == "del" then
    local s, n = SpotByNum(rest)
    if not s then return end
    if s.src ~= "user" then Print(n .. "번은 BookData.lua에 적힌 지점이라 여기서 지울 수 없습니다. 알림이 필요 없으면 /kqg 책 무시 " .. n) return end
    for i, row in ipairs(b.spots) do
      if row == s.row then table.remove(b.spots, i) break end
    end
    Print(n .. "번 지점(「" .. BookTitle(s) .. "」)을 지웠습니다.")
  elseif cmd == "목록" or cmd == "list" then
    List(rest == "전체" or rest == "all")
  elseif cmd == "완료" or cmd == "done" then
    local s = SpotByNum(rest)
    if s then c.done[BookKey(s)] = true Print("「" .. BookTitle(s) .. "」 수집 완료로 표시했습니다.") end
  elseif cmd == "무시" or cmd == "ignore" then
    local s = SpotByNum(rest)
    if s then
      local sk = SpotKey(s)
      if not sk then Print("좌표가 없는 지점은 원래 알리지 않습니다.") return end
      c.ignore[sk] = true
      Print("이 지점(" .. WhereText(s) .. ")은 더 알리지 않습니다.")
    end
  elseif cmd == "취소" or cmd == "undo" then
    local s = SpotByNum(rest)
    if s then
      c.done[BookKey(s)] = nil
      local sk = SpotKey(s)
      if sk then c.ignore[sk] = nil near[sk] = nil end
      Print("「" .. BookTitle(s) .. "」의 완료·무시 표시를 풀었습니다." .. (Owned(s, c) and " (가방·은행에 있어서 알림은 계속 안 뜹니다)" or ""))
    end
  elseif cmd == "보유" or cmd == "own" then
    Own()
  elseif cmd == "가방" or cmd == "bag" then
    BagDump(rest)
  elseif cmd == "반경" or cmd == "radius" then
    local r = tonumber(rest)
    if not r or r < RADIUS_MIN or r > RADIUS_MAX then
      Print(string.format("반경은 %d~%d야드로 적어 주세요. 지금: %d야드", RADIUS_MIN, RADIUS_MAX, b.radius))
      return
    end
    b.radius = math.floor(r)
    near = {}
    Print("책 알림 반경 " .. b.radius .. "야드")
  elseif cmd == "시험" or cmd == "test" then
    local m = CurrentMap()
    local mname = m and K.MapName and K.MapName(m) or nil
    local best, bd
    for _, s in ipairs(AllSpots()) do
      if s.x and m and OnMap(s, m, mname) then
        local d = Dist(m, s)
        if d and (not bd or d < bd) then best, bd = s, d end
      end
    end
    if best then
      ShowPopup(best, bd, 0, true)
    else
      ShowPopup({ book = "시험용 책", zone = mname or "이 지역", memo = "알림 창 시험입니다. 이 지역에 좌표가 있는 책 지점이 없습니다." }, nil, 0, true)
    end
  elseif cmd == "내보내기" or cmd == "export" then
    local lines = {}
    for _, s in ipairs(AllSpots()) do lines[#lines + 1] = RowText(s) end
    ShowExport(table.concat(lines, "\n"))
  elseif cmd == "초기화" or cmd == "reset" then
    if rest ~= "확인" and rest ~= "confirm" then
      Print("이 캐릭터의 수집 완료·무시 표시를 모두 지웁니다. 정말 지우려면 /kqg 책 초기화 확인")
      return
    end
    c.done, c.ignore = {}, {}
    near = {}
    Print("이 캐릭터의 수집 완료·무시 표시를 모두 지웠습니다. (가방·은행에 있는 책은 다음 확인 때 다시 완료가 됩니다)")
  else
    Help()
  end
end
