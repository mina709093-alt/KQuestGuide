-- 차단 기록: 게임이 KQuestGuide의 어떤 동작을 막았는지 남긴다 (원인 확인용)
-- 게임이 알려 주는 함수 이름과 그때 상황(전투/파티/지역)을 KQGDB.blockLog 에 저장한다.
local KQG = KQG
local f = CreateFrame("Frame")
pcall(f.RegisterEvent, f, "ADDON_ACTION_FORBIDDEN")
pcall(f.RegisterEvent, f, "ADDON_ACTION_BLOCKED")
local told = {}
f:SetScript("OnEvent", function(_, e, addon, func)
  if addon ~= "KQuestGuide" then return end
  local d = KQG and KQG.DB and KQG.DB()
  if not d then return end
  d.blockLog = d.blockLog or {}
  local entry = {
    t = date and date("%m-%d %H:%M:%S") or "",
    kind = (e == "ADDON_ACTION_FORBIDDEN") and "금지" or "전투중차단",
    func = tostring(func),
    combat = (InCombatLockdown and InCombatLockdown()) and true or false,
    group = (IsInGroup and IsInGroup()) and true or false,
    zone = GetZoneText and GetZoneText() or "",
  }
  table.insert(d.blockLog, entry)
  while #d.blockLog > 30 do table.remove(d.blockLog, 1) end
  if not told[entry.func] and KQG.Print then
    told[entry.func] = true
    KQG.Print("차단 기록: " .. entry.func .. " (" .. entry.kind .. ") - 상수에게 알려 주세요")
  end
end)
