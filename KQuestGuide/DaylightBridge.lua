-- DaylightUI 연동: 퀘스트 우클릭 메뉴(DaylightUI 추적창, 퀘스트 일지)에 "경로안내" 항목을 추가합니다.
-- 고르면 KQG.RouteQuest(Route.lua)로 그 퀘스트의 목표 위치까지 기존 핀·점선 경로 안내를 시작합니다.
--
-- DaylightUI 공개 API(DaylightUI.API 1.11 이상의 AddQuestMenu)만 사용합니다.
-- DaylightUI 파일은 고치지 않고, DaylightUI 코드도 가져오지 않습니다. 기존 메뉴 항목과 클릭 동작은 그대로입니다.
-- DaylightUI가 없거나, 꺼져 있거나, 버전이 맞지 않으면 아무 일도 하지 않습니다.
-- 이 항목의 함수에서 오류가 나도 DaylightUI가 이 항목만 빼고 나머지 메뉴는 정상 동작합니다.

local K = KQG
if type(K) ~= "table" then return end

local done = false
-- 메뉴에서 눈에 띄게: 보라색 #8A2BE2 (재료 획득처 툴팁의 전체 습득처 안내와 같은 색)
local LABEL = "|cff8A2BE2» 경로안내|r"

local function Setup()
  if done then return end
  local dui = rawget(_G, "DaylightUI")
  local api = type(dui) == "table" and dui.API
  if type(api) ~= "table" or api.major ~= 1 or type(api.minor) ~= "number" or api.minor < 11 then return end
  if type(api.For) ~= "function" then return end
  local me = api.For("KQuestGuide")
  if type(me) ~= "table" or type(me.AddQuestMenu) ~= "function" then return end
  done = true
  me.AddQuestMenu("route", {
    label = LABEL,
    show = function(quest)
      return type(quest) == "table" and K.CanRoute ~= nil and K.CanRoute(quest.questID) == true
    end,
    onClick = function(quest)
      if type(quest) == "table" and K.RouteQuest then K.RouteQuest(quest.questID) end
    end,
  })
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
  pcall(Setup)
end)
