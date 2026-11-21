-- 퀘스트 정리: 받아 둔 퀘스트 중 더 이상 쓸모없는 회색(저레벨) 퀘스트를 골라 포기합니다.
--
-- 지울 후보 (모두 만족해야 함)
--   · 회색 퀘스트 (게임 기준: 내 레벨 - 퀘스트 레벨 > 회색 범위)
--   · 아직 완료(제출 가능) 상태가 아님
--   · 직업 전용 퀘스트가 아님
--   · 던전 퀘스트(연계 뒤 포함)는 지우지 않고 "(던전)" 표시로 올리되 체크하지 않음 (사용자가 판단)
--     던전 판정: 게임 퀘스트 태그 → KQG 데이터 지역 → Questie 순서
--   · 연계를 따라가도 내 레벨에 맞는(회색이 아닌) 받을 수 있는 퀘스트가 없음
--   · 판정할 데이터가 있음 (KQuestGuide 데이터 → 없으면 Questie 데이터베이스). 둘 다 없으면 남김
-- 바로 지우지 않고 확인 창을 먼저 엽니다. Questie에서 가져온 정보는 화면이나 툴팁에 출처를 꼭 남깁니다.
-- /kqg 정리 : 확인 창 열기   /kqg 정리 버튼 : 퀘스트 목록(L) 창의 버튼 숨기기/보이기
local KQG = KQG
if not KQG then return end

local Q, F = KQG.Q, KQG.F
local function Print(m) if KQG.Print then KQG.Print(m) end end
local function db() return KQG.DB and KQG.DB() end

local SRC_KQG = "KQuestGuide 기본 데이터 (Questie/QuestieDB 기반)"
local SRC_QUESTIE = "Questie 데이터베이스 (실시간 조회)"
local SRC_LOG = "게임 퀘스트 목록"

-- 상수 스타일 색 (KQuestGuide.lua와 같은 값)
local C_TEXT = { 0.93, 0.94, 0.96 }
local C_MUTED = { 0.55, 0.60, 0.63 }
local C_ACCENT = { 0.063, 0.816, 0.627 }
local C_SEL = { 0.045, 0.32, 0.26 }
local C_BG = { 0.035, 0.055, 0.065 }
local C_BTN = { 0.055, 0.085, 0.10 }
local C_WARN = { 1.0, 0.45, 0.35 }
local C_DUNGEON = { 1.0, 0.70, 0.30 }  -- (던전) 표시

local FONT_R = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Regular.ttf"
local FONT_B = "Interface\\AddOns\\KQuestGuide\\fonts\\MaruBuri-Bold.ttf"
local function SetF(fs, size, bold)
  pcall(fs.SetFont, fs, bold and FONT_B or FONT_R, size or 12)
  return fs
end
local function Solid(tex, r, g, b, a)
  if tex.SetColorTexture then
    tex:SetColorTexture(r, g, b, a or 1)
  else
    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    tex:SetVertexColor(r, g, b, a or 1)
  end
end
local function Hex(c)
  return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

local function Plain(v)
  if type(issecretvalue) == "function" then
    local ok, sec = pcall(issecretvalue, v)
    if ok and sec then return nil end
  end
  return v
end

-- 퀘스트 로그 읽기 -------------------------------------------------------------

local function ReadLogEntries()
  local out = {}
  local n = 0
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
    local ok, v = pcall(C_QuestLog.GetNumQuestLogEntries)
    if ok and type(Plain(v)) == "number" then n = v end
  elseif GetNumQuestLogEntries then
    local ok, v = pcall(GetNumQuestLogEntries)
    if ok and type(Plain(v)) == "number" then n = v end
  end
  for i = 1, n do
    local e
    if C_QuestLog and C_QuestLog.GetInfo then
      local ok, info = pcall(C_QuestLog.GetInfo, i)
      if ok and type(info) == "table" and not Plain(info.isHeader) and not Plain(info.isHidden) then
        local qid = Plain(info.questID)
        if type(qid) == "number" and qid > 0 then
          e = { id = qid, title = Plain(info.title), level = Plain(info.level), index = i }
          if C_QuestLog.IsComplete then
            local ok2, c = pcall(C_QuestLog.IsComplete, qid)
            e.complete = ok2 and Plain(c) and true or false
          end
        end
      end
    elseif GetQuestLogTitle then
      local ok, title, level, _, isHeader, _, isComplete, _, qid = pcall(GetQuestLogTitle, i)
      if ok and not isHeader and type(qid) == "number" and qid > 0 then
        e = { id = qid, title = title, level = level, index = i, complete = (isComplete == 1 or isComplete == true) }
      end
    end
    if e then
      if type(e.level) ~= "number" then e.level = nil end
      if not e.complete and KQG.LogComplete and KQG.LogComplete(e.id) then e.complete = true end
      out[#out + 1] = e
    end
  end
  return out
end

-- Questie (읽기만) ------------------------------------------------------------

-- 쓸 수 있으면 QuestieDB 모듈, 아니면 nil과 이유
local function QuestieDBModule()
  local QL = _G.QuestieLoader
  if type(QL) ~= "table" or type(QL.ImportModule) ~= "function" then return nil, "Questie 없음" end
  local qs = _G.Questie
  if type(qs) ~= "table" or qs.started ~= true then return nil, "Questie 준비 중" end
  local ok, mod = pcall(QL.ImportModule, QL, "QuestieDB")
  if not ok or type(mod) ~= "table" or type(mod.QueryQuestSingle) ~= "function" then return nil, "Questie 데이터 없음" end
  return mod
end

local function QField(mod, id, field)
  local ok, v = pcall(mod.QueryQuestSingle, id, field)
  if ok then return Plain(v) end
  return nil
end

-- 판정 ------------------------------------------------------------------------

local SRC_TAG = "게임 퀘스트 태그 (퀘스트 목록의 '던전' 표시)"

local function IsDone(id) return KQG.IsDone and KQG.IsDone(id) or false end
local function IsDungeonZone(area) return KQG.IsDungeonZone and KQG.IsDungeonZone(area) or false end

-- 게임이 퀘스트에 붙인 '던전' 태그 (퀘스트 목록에 보이는 것과 같음)
local function GameDungeonTag(id)
  local QC = Constants and Constants.QuestConsts
  local DUNGEON = (QC and QC.QUEST_INFO_DUNGEON_ID) or 81
  local tag
  if C_QuestLog and C_QuestLog.GetQuestTagInfo then
    local ok, info = pcall(C_QuestLog.GetQuestTagInfo, id)
    if ok and type(info) == "table" then tag = Plain(info.tagID) end
  elseif GetQuestTagInfo then
    local ok, t = pcall(GetQuestTagInfo, id)
    if ok then tag = Plain(t) end
  end
  return tag ~= nil and tag == DUNGEON
end

local function QuestieDungeon(mod, id)
  if not mod then return false end
  if IsDungeonZone(QField(mod, id, "zoneOrSort")) then return true end
  if type(mod.IsDungeonQuest) == "function" then
    local ok, d = pcall(mod.IsDungeonQuest, id)
    return ok and Plain(d) == true
  end
  return false
end

-- 던전 퀘스트이면 판정 출처, 아니면 nil. 받아 둔 퀘스트는 게임 태그를 먼저 봅니다.
local function DungeonSource(id, mod, inLog)
  if inLog and GameDungeonTag(id) then return SRC_TAG end
  local r = Q[id]
  if r and IsDungeonZone(r[F.ZONE]) then return SRC_KQG end
  if QuestieDungeon(mod, id) then return SRC_QUESTIE end
  return nil
end

-- Questie 연계(다음 퀘스트, 안내 퀘스트가 가리키는 퀘스트)를 따라갑니다.
-- 돌려주는 값: "dungeon"(던전 퀘스트가 있음, 출처), "fit"(내 레벨 퀘스트), "unknown"(레벨 모름), nil
local function QuestieChain(mod, id, level)
  local cur, seen = id, { [id] = true }
  for _ = 1, 8 do
    local nx = QField(mod, cur, "nextQuestInChain")
    if type(nx) ~= "number" or nx == 0 then nx = QField(mod, cur, "breadcrumbForQuestId") end
    if type(nx) ~= "number" or nx == 0 or seen[nx] then return nil end
    seen[nx] = true
    if not IsDone(nx) then
      local ds = DungeonSource(nx, mod, false)
      if ds then return "dungeon", ds end
      local r = Q[nx]
      local lv = r and r[F.LVL] or QField(mod, nx, "questLevel")
      if type(lv) ~= "number" or lv <= 0 then return "unknown" end
      if not KQG.IsGrayLevel(lv, level) then return "fit" end
    end
    cur = nx
  end
  return nil
end

-- 한 퀘스트 판정. 돌려주는 값: nil(회색 아님, 목록에 안 나옴) 또는
-- { remove = 목록에 올림, reason = 이유, src = 판정 데이터 출처, lvSrc = 레벨 출처,
--   questie = Questie를 썼는지, dungeon = "던전"/"던전 연계"(처음엔 체크 안 함), dsrc = 던전 판정 출처 }
local function Judge(e, level)
  local r = Q[e.id]
  local lv, lvSrc = e.level, SRC_LOG
  local mod, why = QuestieDBModule()
  if type(lv) ~= "number" or lv <= 0 then
    if r and (r[F.LVL] or 0) > 0 then
      lv, lvSrc = r[F.LVL], SRC_KQG
    else
      lv = mod and QField(mod, e.id, "questLevel")
      lvSrc = SRC_QUESTIE
      if type(lv) ~= "number" or lv <= 0 then return nil end -- 레벨을 모르면 회색인지도 모름
    end
  end
  if not KQG.IsGrayLevel(lv, level) then return nil end
  local res = { lv = lv, lvSrc = lvSrc, questie = (lvSrc == SRC_QUESTIE) }
  local function keep(reason) res.remove = false res.reason = reason return res end
  local function dungeon(kind, dsrc, reason)
    res.remove, res.dungeon, res.dsrc, res.reason = true, kind, dsrc, reason
    if dsrc == SRC_QUESTIE then res.questie = true end
    return res
  end
  if e.complete then res.src = SRC_LOG return keep("완료됨 (제출만 하면 됨)") end

  -- 던전 퀘스트는 지우지 않고 '(던전)' 표시로 올려서 사용자가 판단하게 합니다.
  local DUN_SELF = "던전 안에서 하는 퀘스트입니다. 던전에 다시 갈지 보고 직접 고르세요."
  local DUN_CHAIN = "연계를 따라가면 던전 퀘스트가 나옵니다. 던전에 갈지 보고 직접 고르세요."

  if r then
    res.src = SRC_KQG
    if r[F.CLASSES] and r[F.CLASSES] ~= 0 then return keep("직업 전용 퀘스트") end
    local ds = DungeonSource(e.id, mod, true)
    if ds then return dungeon("던전", ds, DUN_SELF) end
    local chainSrc
    if KQG.ChainHas(e.id, function(n)
      if IsDone(n) then return false end
      chainSrc = DungeonSource(n, mod, false)
      return chainSrc ~= nil
    end) then
      return dungeon("던전 연계", chainSrc, DUN_CHAIN)
    end
    if KQG.ChainLeadsToFit(e.id, level) then return keep("연계 뒤에 내 레벨에 맞는 퀘스트가 있음") end
    res.remove = true
    res.reason = "회색이고 이어지는 연계·던전 퀘스트 없음"
    return res
  end

  -- KQuestGuide 데이터에 없음: Questie로 판정
  res.src = SRC_QUESTIE
  res.questie = true
  if not mod then
    res.src = nil
    if GameDungeonTag(e.id) then return dungeon("던전", SRC_TAG, DUN_SELF) end
    return keep("판정할 데이터 없음 (" .. tostring(why) .. ")")
  end
  if QField(mod, e.id, "name") == nil and QField(mod, e.id, "questLevel") == nil then
    res.src = nil
    if GameDungeonTag(e.id) then return dungeon("던전", SRC_TAG, DUN_SELF) end
    return keep("판정할 데이터 없음 (Questie에도 없음)")
  end
  local cls = QField(mod, e.id, "requiredClasses")
  if type(cls) == "number" and cls ~= 0 then return keep("직업 전용 퀘스트") end
  local ds = DungeonSource(e.id, mod, true)
  if ds then return dungeon("던전", ds, DUN_SELF) end
  local kind, cds = QuestieChain(mod, e.id, level)
  if kind == "dungeon" then return dungeon("던전 연계", cds, DUN_CHAIN) end
  if kind == "fit" then return keep("연계 뒤에 내 레벨에 맞는 퀘스트가 있음") end
  if kind == "unknown" then return keep("연계 다음 퀘스트의 레벨을 알 수 없음") end
  res.remove = true
  res.reason = "회색이고 이어지는 연계·던전 퀘스트 없음"
  return res
end

local function Collect()
  local level = UnitLevel("player") or 1
  local remove, kept = {}, {}
  for _, e in ipairs(ReadLogEntries()) do
    local ok, res = pcall(Judge, e, level)
    if ok and res then
      res.id, res.title = e.id, e.title or (KQG.QName and KQG.QName(e.id)) or ("퀘스트 " .. e.id)
      if res.remove then remove[#remove + 1] = res else kept[#kept + 1] = res end
    end
  end
  return remove, kept
end

-- 포기 ------------------------------------------------------------------------

local function LogIndexOf(id)
  for _, e in ipairs(ReadLogEntries()) do
    if e.id == id then return e.index end
  end
  return nil
end

-- 게임의 기본 포기 절차(선택 → 포기 표시 → 포기)를 그대로 씁니다.
local function AbandonOne(id)
  if not LogIndexOf(id) then return false end
  local QL = C_QuestLog
  if QL and QL.SetSelectedQuest and QL.SetAbandonQuest and QL.AbandonQuest then
    local before
    if QL.GetSelectedQuest then
      local ok, v = pcall(QL.GetSelectedQuest)
      if ok then before = Plain(v) end
    end
    local ok = pcall(QL.SetSelectedQuest, id)
    ok = ok and pcall(QL.SetAbandonQuest)
    ok = ok and pcall(QL.AbandonQuest)
    if type(before) == "number" and before ~= id then pcall(QL.SetSelectedQuest, before) end
    return ok and true or false
  elseif SelectQuestLogEntry and SetAbandonQuest and AbandonQuest then
    local idx = LogIndexOf(id)
    local ok = pcall(SelectQuestLogEntry, idx)
    ok = ok and pcall(SetAbandonQuest)
    ok = ok and pcall(AbandonQuest)
    return ok and true or false
  end
  return false
end

local busy = false
local function AbandonList(ids)
  if busy then return end
  busy = true
  local done, fail, names = 0, 0, {}
  local i = 0
  local function step()
    i = i + 1
    local item = ids[i]
    if not item then
      busy = false
      if done > 0 then
        Print(string.format("퀘스트 정리: %d개를 포기했습니다. [%s]", done, table.concat(names, ", ")))
      end
      if fail > 0 then Print(string.format("퀘스트 정리: %d개는 포기하지 못했습니다.", fail)) end
      if KQG.Compute then pcall(KQG.Compute) end
      return
    end
    if InCombatLockdown and InCombatLockdown() then
      busy = false
      Print("전투가 시작되어 퀘스트 정리를 멈췄습니다. 전투가 끝난 뒤 다시 눌러 주세요.")
      return
    end
    if AbandonOne(item.id) then
      done = done + 1
      names[#names + 1] = item.title
    else
      fail = fail + 1
    end
    C_Timer.After(0.4, step)
  end
  step()
end

-- 확인 창 ---------------------------------------------------------------------

local ROWS, ROW_H, W = 12, 22, 400
local cf
local list, keptList, checked, offset = {}, {}, {}, 0

local function FlatButton(parent, text, w, primary, fn)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, 24)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  local base = primary and C_SEL or C_BTN
  local hover = primary and { 0.06, 0.40, 0.32 } or { 0.08, 0.12, 0.14 }
  Solid(b.bg, base[1], base[2], base[3], 1)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("CENTER")
  SetF(b.label, 12, primary)
  b.label:SetText(text)
  if primary then b.label:SetTextColor(1, 1, 1) else b.label:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3]) end
  b:SetScript("OnEnter", function() Solid(b.bg, hover[1], hover[2], hover[3], 1) end)
  b:SetScript("OnLeave", function() Solid(b.bg, base[1], base[2], base[3], 1) end)
  b:SetScript("OnClick", fn)
  return b
end

local function CountChecked()
  local n = 0
  for _, it in ipairs(list) do if checked[it.id] then n = n + 1 end end
  return n
end

local function SourceLines(it)
  GameTooltip:AddLine("판정 이유: " .. it.reason, C_TEXT[1], C_TEXT[2], C_TEXT[3], true)
  GameTooltip:AddLine("퀘스트 레벨 " .. tostring(it.lv) .. " (출처: " .. it.lvSrc .. ")", C_MUTED[1], C_MUTED[2], C_MUTED[3], true)
  GameTooltip:AddLine("판정 데이터 출처: " .. (it.src or "없음"), C_MUTED[1], C_MUTED[2], C_MUTED[3], true)
  if it.dungeon then
    GameTooltip:AddLine("던전 판정 출처: " .. tostring(it.dsrc), C_DUNGEON[1], C_DUNGEON[2], C_DUNGEON[3], true)
  end
end

local function Redraw()
  if not cf then return end
  local maxOff = math.max(0, #list - ROWS)
  if offset > maxOff then offset = maxOff end
  if offset < 0 then offset = 0 end
  for i = 1, ROWS do
    local row = cf.rows[i]
    local it = list[i + offset]
    if it then
      row.item = it
      local tag = ""
      if it.dungeon then tag = tag .. " " .. Hex(C_DUNGEON) .. "(" .. it.dungeon .. ")|r" end
      if it.questie then tag = tag .. " " .. Hex(C_ACCENT) .. "(Questie)|r" end
      row.name:SetText(it.title .. tag)
      row.lv:SetText(tostring(it.lv))
      if checked[it.id] then
        Solid(row.boxFill, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
      else
        Solid(row.boxFill, C_BG[1], C_BG[2], C_BG[3], 1)
      end
      row:Show()
    else
      row.item = nil
      row:Hide()
    end
  end
  local n = CountChecked()
  if #list == 0 then
    cf.empty:Show()
  else
    cf.empty:Hide()
  end
  cf.more:SetText(#list > ROWS and string.format("%d~%d / %d (마우스 휠로 넘김)", offset + 1, math.min(#list, offset + ROWS), #list) or "")
  cf.keptBtn.label:SetText(string.format("남긴 회색 퀘스트 %d개 (마우스를 올리면 이유)", #keptList))
  cf.go.label:SetText(string.format("선택한 퀘스트 포기 (%d)", n))
  if n > 0 and not busy then cf.go:Enable() cf.go:SetAlpha(1) else cf.go:Disable() cf.go:SetAlpha(0.45) end
end

local function BuildFrame()
  local f = CreateFrame("Frame", "KQGCleanupFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(W, 112 + ROWS * ROW_H + 124)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  Solid(f.bg, C_BG[1], C_BG[2], C_BG[3], 0.96)
  f.line = f:CreateTexture(nil, "BORDER")
  f.line:SetPoint("TOPLEFT") f.line:SetPoint("TOPRIGHT") f.line:SetHeight(2)
  Solid(f.line, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
  if UISpecialFrames then table.insert(UISpecialFrames, "KQGCleanupFrame") end

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  SetF(title, 15, true)
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  title:SetText("퀘스트 정리")

  local close = CreateFrame("Button", nil, f)
  close:SetSize(20, 20)
  close:SetPoint("TOPRIGHT", -8, -10)
  close.label = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  close.label:SetPoint("CENTER")
  SetF(close.label, 15, true)
  close.label:SetText("X")
  close.label:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  close:SetScript("OnEnter", function() close.label:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3]) end)
  close:SetScript("OnLeave", function() close.label:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3]) end)
  close:SetScript("OnClick", function() f:Hide() end)

  local desc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  SetF(desc, 11)
  desc:SetPoint("TOPLEFT", 14, -36)
  desc:SetWidth(W - 28)
  desc:SetJustifyH("LEFT")
  desc:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])
  f.desc = desc

  f.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetSize(W - 28, ROW_H)
    row:SetPoint("TOPLEFT", 14, -112 - (i - 1) * ROW_H)
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints()
    Solid(row.hl, 1, 1, 1, 0.05)
    row.hl:Hide()
    row.box = row:CreateTexture(nil, "ARTWORK")
    row.box:SetSize(12, 12)
    row.box:SetPoint("LEFT", 4, 0)
    Solid(row.box, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 1)
    row.boxFill = row:CreateTexture(nil, "OVERLAY")
    row.boxFill:SetSize(10, 10)
    row.boxFill:SetPoint("CENTER", row.box, "CENTER")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    SetF(row.name, 12)
    row.name:SetPoint("LEFT", row.box, "RIGHT", 8, 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", -34, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
    row.lv = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    SetF(row.lv, 12)
    row.lv:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.lv:SetTextColor(0.62, 0.62, 0.62)
    row:SetScript("OnClick", function(self)
      if not self.item or busy then return end
      checked[self.item.id] = not checked[self.item.id]
      Redraw()
    end)
    row:SetScript("OnEnter", function(self)
      row.hl:Show()
      if not self.item then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(self.item.title, 1, 1, 1)
      SourceLines(self.item)
      GameTooltip:AddLine("클릭: 선택/해제", C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() row.hl:Hide() GameTooltip:Hide() end)
    f.rows[i] = row
  end
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, d)
    offset = offset - d * 3
    Redraw()
  end)

  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  SetF(f.empty, 12)
  f.empty:SetPoint("TOPLEFT", 14, -116)
  f.empty:SetWidth(W - 28)
  f.empty:SetJustifyH("LEFT")
  f.empty:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
  f.empty:SetText("정리할 퀘스트가 없습니다.")

  local listBottom = -112 - ROWS * ROW_H
  f.more = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  SetF(f.more, 10)
  f.more:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, listBottom - 2)
  f.more:SetTextColor(C_MUTED[1], C_MUTED[2], C_MUTED[3])

  f.keptBtn = CreateFrame("Button", nil, f)
  f.keptBtn:SetSize(W - 28, 18)
  f.keptBtn:SetPoint("TOPLEFT", 14, listBottom - 18)
  f.keptBtn.label = f.keptBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  SetF(f.keptBtn.label, 11)
  f.keptBtn.label:SetPoint("LEFT")
  f.keptBtn.label:SetTextColor(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
  f.keptBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("남긴 회색 퀘스트", 1, 1, 1)
    if #keptList == 0 then GameTooltip:AddLine("없음", C_MUTED[1], C_MUTED[2], C_MUTED[3]) end
    for i, it in ipairs(keptList) do
      if i > 25 then
        GameTooltip:AddLine(string.format("… 외 %d개", #keptList - 25), C_MUTED[1], C_MUTED[2], C_MUTED[3])
        break
      end
      local tag = it.questie and " (Questie)" or ""
      GameTooltip:AddDoubleLine(it.title .. tag, it.reason, C_TEXT[1], C_TEXT[2], C_TEXT[3], C_MUTED[1], C_MUTED[2], C_MUTED[3])
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("(Questie) 표시: " .. SRC_QUESTIE .. "로 판정", C_MUTED[1], C_MUTED[2], C_MUTED[3], true)
    GameTooltip:AddLine("표시 없음: " .. SRC_KQG .. " 또는 " .. SRC_LOG .. "로 판정", C_MUTED[1], C_MUTED[2], C_MUTED[3], true)
    GameTooltip:Show()
  end)
  f.keptBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  f.warn = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  SetF(f.warn, 11)
  f.warn:SetPoint("TOPLEFT", 14, listBottom - 40)
  f.warn:SetWidth(W - 28)
  f.warn:SetJustifyH("LEFT")
  f.warn:SetTextColor(C_WARN[1], C_WARN[2], C_WARN[3])
  f.warn:SetText("포기하면 진행도와 퀘스트 아이템이 사라지며 되돌릴 수 없습니다. (같은 NPC에게서 다시 받을 수는 있습니다)")

  f.go = FlatButton(f, "선택한 퀘스트 포기", 180, true, function()
    if busy then return end
    if InCombatLockdown and InCombatLockdown() then
      Print("전투 중에는 퀘스트를 정리할 수 없습니다.")
      return
    end
    local ids = {}
    for _, it in ipairs(list) do if checked[it.id] then ids[#ids + 1] = it end end
    if #ids == 0 then return end
    f:Hide()
    AbandonList(ids)
  end)
  f.go:SetPoint("BOTTOMLEFT", 14, 12)
  f.all = FlatButton(f, "모두 선택/해제", 110, false, function()
    local any = CountChecked() < #list
    for _, it in ipairs(list) do checked[it.id] = any end
    Redraw()
  end)
  f.all:SetPoint("LEFT", f.go, "RIGHT", 6, 0)
  f.cancel = FlatButton(f, "취소", 70, false, function() f:Hide() end)
  f.cancel:SetPoint("BOTTOMRIGHT", -14, 12)
  f:Hide()
  return f
end

local function Open()
  if not db() then return end
  if InCombatLockdown and InCombatLockdown() then
    Print("전투 중에는 퀘스트를 정리할 수 없습니다.")
    return
  end
  if busy then Print("퀘스트 정리가 진행 중입니다.") return end
  if not cf then cf = BuildFrame() end
  list, keptList = Collect()
  table.sort(list, function(a, b) if a.lv ~= b.lv then return a.lv < b.lv end return a.id < b.id end)
  table.sort(keptList, function(a, b) if a.lv ~= b.lv then return a.lv < b.lv end return a.id < b.id end)
  checked, offset = {}, 0
  for _, it in ipairs(list) do checked[it.id] = not it.dungeon end -- 던전 퀘스트는 처음엔 체크 안 함
  local gr = KQG.GrayRange and KQG.GrayRange() or 7
  cf.desc:SetText(string.format("회색 퀘스트(내 레벨보다 %d레벨 넘게 낮음) 중 연계·직업 퀘스트가 아니고 완료되지 않은 것입니다. "
    .. "%s(던전)|r 표시는 던전 퀘스트라 체크하지 않았습니다. 다시 갈지 보고 고르세요. "
    .. "줄에 마우스를 올리면 판정 이유와 출처가 나옵니다. %s(Questie)|r 표시는 Questie 데이터로 판정한 퀘스트입니다.", gr, Hex(C_DUNGEON), Hex(C_ACCENT)))
  Redraw()
  cf:Show()
end

KQG.CleanupOpen = function()
  local ok, err = pcall(Open)
  if not ok then Print("퀘스트 정리 오류: " .. tostring(err)) end
end

-- 퀘스트 목록(L) 창 버튼 -------------------------------------------------------
-- 게임의 퀘스트 패널(QuestMapFrame) 오른쪽 위, 지도 창 제목 줄에 작은 버튼을 둡니다.
-- 버튼은 QuestMapFrame의 자식이 아니라 지도 창(QuestMapFrame의 부모)의 자식입니다. DaylightUI 퀘스트 일지가
-- QuestMapFrame의 자식을 모두 투명하게 만들기 때문입니다. 대신 QuestMapFrame이 보일 때만 보이게 합니다.
-- Shift+끌기로 옮길 수 있고, 위치는 KQGDB.cleanBtnPos에 저장합니다.
local logBtn

local function PlaceLogBtn()
  if not logBtn then return end
  local anchor = logBtn.anchor
  local p = db() and db().cleanBtnPos
  logBtn:ClearAllPoints()
  if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" then
    logBtn:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", p.x, p.y)
  else
    logBtn:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -60, 22)
  end
end

local function ApplyLogBtn()
  if not logBtn then return end
  local off = db() and db().cleanBtnOff
  if not off and logBtn.anchor:IsShown() then logBtn:Show() else logBtn:Hide() end
end

local function BuildLogBtn()
  if logBtn then return true end
  local qm = _G.QuestMapFrame
  if type(qm) ~= "table" or type(qm.GetObjectType) ~= "function" then return false end
  local parent = qm:GetParent() or _G.WorldMapFrame or UIParent
  local b = CreateFrame("Button", nil, parent)
  b.anchor = qm
  b:SetSize(78, 20)
  b:SetFrameLevel(math.max(520, (qm:GetFrameLevel() or 0) + 20))
  b:SetClampedToScreen(true)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  Solid(b.bg, C_BTN[1], C_BTN[2], C_BTN[3], 0.9)
  b.edge = b:CreateTexture(nil, "BORDER")
  b.edge:SetPoint("BOTTOMLEFT") b.edge:SetPoint("BOTTOMRIGHT") b.edge:SetHeight(1)
  Solid(b.edge, C_ACCENT[1], C_ACCENT[2], C_ACCENT[3], 0.9)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("CENTER", 0, 1)
  SetF(b.label, 11, true)
  b.label:SetText("퀘스트 정리")
  b.label:SetTextColor(C_ACCENT[1], C_ACCENT[2], C_ACCENT[3])
  b:SetMovable(true)
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown and IsShiftKeyDown() then self:StartMoving() self.moving = true end
  end)
  b:SetScript("OnDragStop", function(self)
    if not self.moving then return end
    self.moving = nil
    self:StopMovingOrSizing()
    local par = self.anchor
    local r, t = self:GetRight(), self:GetTop()
    local pr, pt = par:GetRight(), par:GetTop()
    local d = db()
    if d and r and t and pr and pt then
      local s = self:GetEffectiveScale() / par:GetEffectiveScale()
      d.cleanBtnPos = { x = math.floor((r * s - pr) + 0.5), y = math.floor((t * s - pt) + 0.5) }
    end
    PlaceLogBtn()
  end)
  b:SetScript("OnClick", function() KQG.CleanupOpen() end)
  b:SetScript("OnEnter", function(self)
    Solid(self.bg, 0.08, 0.12, 0.14, 0.95)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine("퀘스트 정리 (KQuestGuide)", 1, 1, 1)
    GameTooltip:AddLine("더 이상 쓸모없는 회색 퀘스트를 골라 포기합니다. 확인 창이 먼저 열립니다.", C_TEXT[1], C_TEXT[2], C_TEXT[3], true)
    GameTooltip:AddLine("Shift+끌기: 버튼 옮기기   /kqg 정리 버튼: 숨기기", C_MUTED[1], C_MUTED[2], C_MUTED[3], true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self)
    Solid(self.bg, C_BTN[1], C_BTN[2], C_BTN[3], 0.9)
    GameTooltip:Hide()
  end)
  logBtn = b
  PlaceLogBtn()
  ApplyLogBtn()
  qm:HookScript("OnShow", function() pcall(ApplyLogBtn) end)
  qm:HookScript("OnHide", function() pcall(ApplyLogBtn) end)
  return true
end

KQG.CleanupToggleLogButton = function()
  local d = db()
  if not d then return end
  d.cleanBtnOff = not d.cleanBtnOff
  if not d.cleanBtnOff then pcall(BuildLogBtn) end
  ApplyLogBtn()
  Print("퀘스트 목록(L) 창의 [퀘스트 정리] 버튼 " .. (d.cleanBtnOff and "숨김" or "표시"))
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, e, name)
  if e == "ADDON_LOADED" and name ~= "Blizzard_WorldMap" then return end
  local ok, built = pcall(BuildLogBtn)
  if ok and built then self:UnregisterAllEvents() end
end)
