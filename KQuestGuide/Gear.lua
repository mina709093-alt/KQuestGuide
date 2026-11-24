-- KQuestGuide 장비 추천 모듈
-- 퀘스트 보상 장비 중 지금 착용한 장비보다 좋은 것을 찾아, 받을 곳(선행 퀘스트 포함)을 안내합니다.
-- 점수는 직업/특성에서 정한 "역할"별 능력치 가중치로 계산하고, 근거(능력치 변화)를 같이 보여 줍니다.
-- 아이템 능력치를 아직 읽을 수 없는 보상은 계산하지 않고 "읽는 중"으로 둡니다. 추측하지 않습니다.
-- 명령어: /kqg gear (창)  /kqg gear role (역할 바꾸기)  /kqg gear off (안내 해제)  /kqg gear reset (관심없음 초기화)

local REW = KQG_REW or {}
local K = KQG
local F = K.F
local Q = K.Q

local gframe
local results = {}
-- 이 클라이언트에는 전역 아이템 함수가 없을 수 있어 C_Item 쪽도 함께 확인한다
local function InfoInstant(x)
  local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not f then return nil end
  return f(x)
end
local function ItemInfo(x)
  local f = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not f then return nil end
  return f(x)
end
local function ItemCount(x, bank)
  local f = (C_Item and C_Item.GetItemCount) or GetItemCount
  if not f then return 0 end
  return f(x, bank) or 0
end
local pendingCount = 0
local stat = {}
local gearDirty = true
local lastEval = 0
local offset = 0
local tab = "rec"
local lastEq = {}
local ROWS = 7
local K_SetRoundColor  -- 아래(둥근 버튼 부분)에서 정의. 전역으로 새지 않게 미리 지역 변수로 선언

local function db() return K.DB() end
local function Print(t) K.Print(t) end

-- 역할 / 가중치 ----------------------------------------------------------------

local ROLE_ORDER = { "melee_str", "melee_agi", "melee_hyb", "hunter", "caster", "healer", "tank" }
local ROLE_NAME = {
  melee_str = "근접(힘)", melee_agi = "근접(민첩)", melee_hyb = "근접(혼합)", hunter = "원거리 물리",
  caster = "주문 딜러", healer = "치유", tank = "탱커",
}
local W = {
  melee_str = { STR = 1, AGI = 0.6, STA = 0.3, ARMOR = 0.02, DPS = 3, AP = 0.5, CRIT = 0.8, HIT = 0.8 },
  melee_agi = { STR = 0.4, AGI = 1, STA = 0.3, ARMOR = 0.02, DPS = 3, AP = 0.5, CRIT = 0.8, HIT = 0.8, DODGE = 0.3 },
  melee_hyb = { STR = 0.8, AGI = 0.8, INT = 0.3, STA = 0.3, ARMOR = 0.02, DPS = 3, AP = 0.5, CRIT = 0.8, HIT = 0.8, SP = 0.2 },
  hunter = { AGI = 1, STR = 0.1, INT = 0.35, STA = 0.3, ARMOR = 0.02, DPS = 3, AP = 0.5, CRIT = 0.8, HIT = 0.8, MP5 = 0.3 },
  caster = { INT = 1, SPI = 0.3, STA = 0.4, ARMOR = 0.02, DPS = 0.3, SP = 0.8, CRIT = 0.8, HIT = 0.8, MP5 = 0.4 },
  healer = { INT = 1, SPI = 0.8, STA = 0.4, ARMOR = 0.02, DPS = 0.2, SP = 0.8, MP5 = 0.8, CRIT = 0.5 },
  tank = { STA = 1, STR = 0.4, AGI = 0.4, ARMOR = 0.05, DPS = 0.5, DEFENSE = 1, DODGE = 1, PARRY = 1, BLOCK = 0.5 },
}
local STAT_LABEL = {
  STR = "힘", AGI = "민첩성", STA = "체력", INT = "지능", SPI = "정신력", ARMOR = "방어도", DPS = "초당 공격력",
  AP = "전투력", CRIT = "치명타", HIT = "적중", SP = "주문력", MP5 = "마나 회복", DEFENSE = "방어 숙련",
  DODGE = "회피", PARRY = "무기 막기", BLOCK = "방패 막기",
}

-- 특성 트리의 세 줄기 순서(왼쪽→오른쪽)에 대응하는 기본 역할. 맞지 않으면 /kqg gear role 로 바꾸세요.
local SPEC_ROLE = {
  WARRIOR = { "melee_str", "melee_str", "tank" },
  PALADIN = { "healer", "tank", "melee_str" },
  HUNTER = { "hunter", "hunter", "hunter" },
  ROGUE = { "melee_agi", "melee_agi", "melee_agi" },
  PRIEST = { "healer", "healer", "caster" },
  SHAMAN = { "caster", "melee_hyb", "healer" },
  MAGE = { "caster", "caster", "caster" },
  WARLOCK = { "caster", "caster", "caster" },
  DRUID = { "caster", "melee_agi", "healer" },
}

local function ClassToken()
  local _, token = UnitClass("player")
  return token
end

-- 활성 특성 트리에서 줄기별 투자 포인트를 읽어 가장 많은 줄기를 돌려줍니다.
local function SpecIndex()
  local ok, idx, sums = pcall(function()
    local cfg = C_ClassTalents.GetActiveConfigID()
    local info = C_Traits.GetConfigInfo(cfg)
    local tree = info.treeIDs[1]
    local nodes = C_Traits.GetTreeNodes(tree)
    local infos, minX, maxX = {}, 1e9, -1e9
    for _, id in ipairs(nodes) do
      local ni = C_Traits.GetNodeInfo(cfg, id)
      if ni and type(ni.posX) == "number" then
        infos[#infos + 1] = ni
        if ni.posX < minX then minX = ni.posX end
        if ni.posX > maxX then maxX = ni.posX end
      end
    end
    local third = (maxX - minX) / 3
    local s = { 0, 0, 0 }
    for _, ni in ipairs(infos) do
      local r = ni.currentRank or 0
      if r > 0 then
        local t = 1
        if ni.posX >= minX + 2 * third then t = 3 elseif ni.posX >= minX + third then t = 2 end
        s[t] = s[t] + r
      end
    end
    local best, bv = nil, 0
    for i = 1, 3 do if s[i] > bv then best, bv = i, s[i] end end
    return best, s
  end)
  if ok then return idx, sums end
  return nil
end

local function CurrentRole()
  local d = db()
  if d and d.gearRole and W[d.gearRole] then return d.gearRole, "수동" end
  local list = SPEC_ROLE[ClassToken() or ""]
  if not list then return "melee_str", "기본" end
  local idx = SpecIndex()
  if idx and list[idx] then return list[idx], "특성 " .. idx .. "번 줄기" end
  return list[1], "특성 읽기 실패(기본값)"
end

-- 아이템 능력치 -------------------------------------------------------------------

local function StatsFn()
  return (C_Item and C_Item.GetItemStats) or GetItemStats
end

local function Category(key)
  if string.find(key, "STRENGTH", 1, true) then return "STR" end
  if string.find(key, "AGILITY", 1, true) then return "AGI" end
  if string.find(key, "STAMINA", 1, true) then return "STA" end
  if string.find(key, "INTELLECT", 1, true) then return "INT" end
  if string.find(key, "SPIRIT", 1, true) then return "SPI" end
  if key == "RESISTANCE0_NAME" then return "ARMOR" end
  if string.find(key, "DAMAGE_PER_SECOND", 1, true) then return "DPS" end
  if string.find(key, "SPELL_POWER", 1, true) or string.find(key, "SPELL_DAMAGE", 1, true)
    or string.find(key, "HEALING_POWER", 1, true) then return "SP" end
  if string.find(key, "ATTACK_POWER", 1, true) then return "AP" end
  if string.find(key, "CRIT", 1, true) then return "CRIT" end
  if string.find(key, "_HIT_", 1, true) or string.find(key, "HIT_RATING", 1, true) then return "HIT" end
  if string.find(key, "MANA_REGENERATION", 1, true) or string.find(key, "MP5", 1, true) then return "MP5" end
  if string.find(key, "DEFENSE", 1, true) then return "DEFENSE" end
  if string.find(key, "DODGE", 1, true) then return "DODGE" end
  if string.find(key, "PARRY", 1, true) then return "PARRY" end
  if string.find(key, "BLOCK", 1, true) then return "BLOCK" end
  return nil
end

-- 능력치를 분류별 합계로 바꿉니다.
local function Bucket(stats)
  local b = {}
  for k, v in pairs(stats or {}) do
    local c = Category(k)
    if c and type(v) == "number" then b[c] = (b[c] or 0) + v end
  end
  return b
end

local function ScoreOf(bucket, weights)
  local s = 0
  for c, v in pairs(bucket) do s = s + v * (weights[c] or 0) end
  return s
end

local cache = {}
-- 후보 아이템 능력치. 서버에서 아직 안 왔으면 nil(읽는 중).
local function ItemBucket(id)
  local c = cache[id]
  if c then return c end
  if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  local name = ItemInfo(id)
  if not name then return nil end
  local fn = StatsFn()
  if not fn then return nil end
  local t = fn("item:" .. id)
  if type(t) ~= "table" then return nil end
  c = Bucket(t)
  cache[id] = c
  return c
end

local function LinkBucket(link)
  local fn = StatsFn()
  if not fn or not link then return {} end
  local ok, t = pcall(fn, link)
  if ok and type(t) == "table" then return Bucket(t) end
  return {}
end

-- 착용 부위 -----------------------------------------------------------------------

local SLOT_OF = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
  INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
  INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
  INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_2HWEAPON = { 16, 17 }, INVTYPE_WEAPON = { 16, 17 },
  INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
  INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}
local SLOT_NAME = {
  [1] = "머리", [2] = "목", [3] = "어깨", [5] = "가슴", [6] = "허리", [7] = "다리", [8] = "발", [9] = "손목",
  [10] = "손", [11] = "반지", [12] = "반지", [13] = "장신구", [14] = "장신구", [15] = "등",
  [16] = "주무기", [17] = "보조무기", [18] = "원거리",
}
local LOC_NAME = {
  INVTYPE_2HWEAPON = "양손 무기", INVTYPE_WEAPON = "한손 무기", INVTYPE_WEAPONMAINHAND = "주무기",
  INVTYPE_WEAPONOFFHAND = "보조 무기", INVTYPE_SHIELD = "방패", INVTYPE_HOLDABLE = "보조 장비",
}

local function SlotLabel(loc)
  if LOC_NAME[loc] then return LOC_NAME[loc] end
  local s = SLOT_OF[loc]
  return s and SLOT_NAME[s[1]] or "?"
end

-- 현재 장비 중 후보와 비교할 대상(점수, 능력치 합계)
local function Equipped(loc, weights)
  local slots = SLOT_OF[loc]
  if not slots then return 0, {} end
  local function one(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    local b = LinkBucket(link)
    return ScoreOf(b, weights), b
  end
  if loc == "INVTYPE_FINGER" or loc == "INVTYPE_TRINKET" then
    local s1, b1 = one(slots[1])
    local s2, b2 = one(slots[2])
    if not s1 or not s2 then return 0, {} end -- 빈 칸이 있으면 비교 대상 없음
    if s1 <= s2 then return s1, b1 end
    return s2, b2
  end
  if loc == "INVTYPE_2HWEAPON" then
    local s1, b1 = one(16)
    local s2, b2 = one(17)
    local merged, sc = {}, 0
    for _, bb in ipairs({ b1 or {}, b2 or {} }) do
      for c, v in pairs(bb) do merged[c] = (merged[c] or 0) + v end
    end
    return (s1 or 0) + (s2 or 0), merged
  end
  if loc == "INVTYPE_WEAPON" then
    local s1, b1 = one(16)
    local link2 = GetInventoryItemLink("player", 17)
    local dual = false
    if link2 then
      local _, _, _, l2 = InfoInstant(link2)
      dual = (l2 == "INVTYPE_WEAPON" or l2 == "INVTYPE_WEAPONOFFHAND")
    end
    if dual then
      local s2, b2 = one(17)
      if s1 and s2 then
        if s2 < s1 then return s2, b2 end
        return s1, b1
      end
    end
    return s1 or 0, b1 or {}
  end
  local s, b = one(slots[1])
  return s or 0, b or {}
end

-- 착용 가능 판정 ---------------------------------------------------------------------

local WEAPON_OK = {
  WARRIOR = { [0] = 1, 1, [4] = 1, [5] = 1, [6] = 1, [7] = 1, [8] = 1, [10] = 1, [13] = 1, [15] = 1, [2] = 1, [3] = 1, [16] = 1, [18] = 1 },
  PALADIN = { [0] = 1, 1, [4] = 1, [5] = 1, [6] = 1, [7] = 1, [8] = 1 },
  HUNTER = { [0] = 1, 1, [2] = 1, [3] = 1, [6] = 1, [7] = 1, [8] = 1, [10] = 1, [13] = 1, [15] = 1, [18] = 1, [16] = 1 },
  ROGUE = { [0] = 1, [2] = 1, [3] = 1, [4] = 1, [7] = 1, [13] = 1, [15] = 1, [16] = 1, [18] = 1 },
  PRIEST = { [4] = 1, [10] = 1, [15] = 1, [19] = 1 },
  SHAMAN = { [0] = 1, 1, [4] = 1, [5] = 1, [10] = 1, [13] = 1, [15] = 1 },
  MAGE = { [7] = 1, [10] = 1, [15] = 1, [19] = 1 },
  WARLOCK = { [7] = 1, [10] = 1, [15] = 1, [19] = 1 },
  DRUID = { [4] = 1, [5] = 1, [6] = 1, [10] = 1, [13] = 1, [15] = 1 },
}
local ARMOR_MAX = { WARRIOR = 4, PALADIN = 4, HUNTER = 3, SHAMAN = 3, ROGUE = 2, DRUID = 2, PRIEST = 1, MAGE = 1, WARLOCK = 1 }
local SHIELD_OK = { WARRIOR = 1, PALADIN = 1, SHAMAN = 1 }

local function BestArmorTier(level)
  local tok = ClassToken()
  local mx = ARMOR_MAX[tok] or 1
  if (tok == "WARRIOR" or tok == "PALADIN") and level < 40 then return 3 end
  if (tok == "HUNTER" or tok == "SHAMAN") and level < 40 then return 2 end
  return mx
end

local function Usable(it, level)
  local cls, sub = it[4], it[5]
  local tok = ClassToken()
  if cls == 2 then
    local ok = WEAPON_OK[tok]
    return ok and ok[sub] and true or false
  end
  if cls == 4 then
    if sub == 6 then return SHIELD_OK[tok] and true or false end
    if sub >= 1 and sub <= 4 then return sub == BestArmorTier(level) end
    return true -- 장신구, 반지, 목걸이 등
  end
  return false
end

-- 퀘스트 판정 ------------------------------------------------------------------------

local function BasicOk(id, level, range)
  local r = Q[id]
  if not r then return false end
  local d = db()
  if d.skipped[id] or (d.gearIgnore and d.gearIgnore[id]) then return false end
  if r[F.MIN] and r[F.MIN] > level + range then return false end
  if r[F.MAXLVL] and level > r[F.MAXLVL] then return false end
  if r[F.FLAGS] and math.floor(r[F.FLAGS]) % 2 == 1 then return false end
  if r.bl and K.Hidden and K.Hidden(id) then return false end -- (0.31.1) 받을 수 없음·닫힌 축제
  if r[F.PARENT] then return false end
  if not K.Bit(r[F.RACES], K.RaceBit()) then return false end
  if not K.Bit(r[F.CLASSES], K.ClassBit()) then return false end
  local s = r[F.START]
  local fr = s and s[7]
  if fr and fr ~= "" and not string.find(fr, K.Faction(), 1, true) then return false end
  if r[F.EXCL] then
    for _, p in ipairs(r[F.EXCL]) do
      if K.IsDone(p) or K.InLog(p) then return false end
    end
  end
  return true
end

-- 이 퀘스트까지 가는 선행 퀘스트 사슬(처음 받을 곳부터). 불가능하면 nil.
local function Chain(id, level, range, depth)
  if depth > 8 then return nil end
  local r = Q[id]
  if not r then return nil end
  if K.InLog(id) then return { id } end
  if not BasicOk(id, level, range + 10 * depth) then return nil end
  local unmet = {}
  if r[F.PREG] then
    for _, p in ipairs(r[F.PREG]) do
      if not K.IsDone(p) then unmet[#unmet + 1] = p end
    end
  end
  if r[F.PRES] then
    local any = false
    for _, p in ipairs(r[F.PRES]) do
      if K.IsDone(p) then any = true break end
    end
    if not any then
      for _, p in ipairs(r[F.PRES]) do unmet[#unmet + 1] = p end
    end
  end
  if #unmet == 0 then
    local s = r[F.START]
    if not s or not s[3] then return nil end
    return { id }
  end
  for _, p in ipairs(unmet) do
    local sub = Chain(p, level, range, depth + 1)
    if sub then
      sub[#sub + 1] = id
      return sub
    end
  end
  return nil
end

-- 사슬에서 지금 해야 할 행동(받기/제출)의 위치
local function Action(chain)
  for _, id in ipairs(chain) do
    local r = Q[id]
    if K.InLog(id) then
      local e = r[F.END]
      if e and e[3] then
        return id, "turnin", e
      end
    else
      local s = r[F.START]
      if s and s[3] then return id, "accept", s end
    end
  end
  return nil
end

-- 평가 -------------------------------------------------------------------------------

local function Grade(diff, eq)
  if eq <= 0 then
    if diff >= 6 then return "높음", "ff66ff66" end
    return "보통", "ffffd100"
  end
  local pct = diff / eq
  if pct >= 0.4 and diff >= 8 then return "매우 높음", "ff33ff99" end
  if pct >= 0.2 and diff >= 4 then return "높음", "ff66ff66" end
  if diff >= 1 then return "보통", "ffffd100" end
  return "낮음", "ffaaaaaa"
end

local function DiffText(cb, eb, weights)
  local parts = {}
  local cats = {}
  for c in pairs(cb) do cats[c] = true end
  for c in pairs(eb) do cats[c] = true end
  local list = {}
  for c in pairs(cats) do
    local delta = (cb[c] or 0) - (eb[c] or 0)
    local w = weights[c] or 0
    if delta ~= 0 and w > 0 then list[#list + 1] = { c = c, d = delta, v = math.abs(delta * w) } end
  end
  table.sort(list, function(a, b) return a.v > b.v end)
  for i = 1, math.min(3, #list) do
    local e = list[i]
    local v = e.d
    if math.floor(v) ~= v then v = string.format("%.1f", v) end
    parts[#parts + 1] = (STAT_LABEL[e.c] or e.c) .. " " .. (e.d > 0 and "+" or "") .. v
  end
  return table.concat(parts, ", ")
end

local function Evaluate()
  local d = db()
  if not d then return end
  d.skipped = d.skipped or {}
  d.gearIgnore = d.gearIgnore or {}
  K.ReadLog()
  local level = UnitLevel("player") or 1
  local range = d.gearRange or 2
  local role = CurrentRole()
  local weights = W[role]
  local tmp = {}
  pendingCount = 0
  stat = { total = 0, done = 0, lvl = 0, items = 0, req = 0, unusable = 0, slot = 0, owned = 0, pend = 0, weak = 0, nochain = 0, nomap = 0, ok = 0, level = level, role = role }

  for qid, items in pairs(REW) do
    local r = Q[qid]
    stat.total = stat.total + 1
    if r and K.IsDone(qid) then stat.done = stat.done + 1 end
    if r and (r[F.LVL] or 0) > level + range + 3 then stat.lvl = stat.lvl + 1 end
    if r and not K.IsDone(qid) and (r[F.LVL] or 0) <= level + range + 3 then
      local best
      for _, it in ipairs(items) do
        stat.items = stat.items + 1
        local req = it[3] > 0 and it[3] or (r[F.MIN] or 0)
        if req > level + range then stat.req = stat.req + 1 end
        if req <= level + range and not Usable(it, level) then stat.unusable = stat.unusable + 1 end
        if req <= level + range and Usable(it, level) then
          local _, _, _, loc = InfoInstant(it[1])
          if not (loc and SLOT_OF[loc]) then stat.slot = stat.slot + 1
          elseif ItemCount(it[1], true) ~= 0 then stat.owned = stat.owned + 1 end
          if loc and SLOT_OF[loc] and ItemCount(it[1], true) == 0 then
            local cb = ItemBucket(it[1])
            if not cb then
              pendingCount = pendingCount + 1
              stat.pend = stat.pend + 1
            else
              local cs = ScoreOf(cb, weights)
              local es, eb = Equipped(loc, weights)
              local diff = cs - es
              if not best or diff > best.diff then
                best = { id = it[1], loc = loc, diff = diff, eq = es, cb = cb, eb = eb, req = req }
              end
            end
          end
        end
      end
      if best and best.diff < 1 then stat.weak = stat.weak + 1 end
      if best and best.diff >= 1 then
        local chain = Chain(qid, level, range, 0)
        if not chain then stat.nochain = stat.nochain + 1 end
        if chain then
          local aq, kind, loc = Action(chain)
          local map = loc and K.UiMapOf(loc[3])
          if not (aq and map) then stat.nomap = stat.nomap + 1 end
          if aq and map then
            stat.ok = stat.ok + 1
            best.qid = qid
            best.chain = chain
            best.actionQuest = aq
            best.kind = kind
            best.loc = best.loc
            best.target = loc
            best.map = map
            best.value = best.diff / (1 + 0.12 * (#chain - 1))
            tmp[#tmp + 1] = best
          end
        end
      end
    end
  end

  -- 같은 아이템을 주는 퀘스트가 여럿이면 가장 짧은 경로만 남김
  table.sort(tmp, function(a, b) return a.value > b.value end)
  local seen, out = {}, {}
  for _, e in ipairs(tmp) do
    if not seen[e.id] then
      seen[e.id] = true
      out[#out + 1] = e
    end
  end
  results = out
  gearDirty = false
  lastEval = GetTime()
end

-- 목적지 안내 --------------------------------------------------------------------------

local function Target(e)
  local loc = e.target
  local aq = Q[e.actionQuest]
  local label = (e.kind == "turnin" and "[제출] " or "[수락] ") .. aq[F.NAME]
  K.SetForced({ kind = e.kind, key = "gear" .. e.qid, loc = loc, map = e.map, quests = { e.actionQuest }, label = label })
  Print("안내 시작: " .. label .. " - " .. loc[6] .. " (" .. string.format("%.0f, %.0f", loc[4], loc[5]) .. ", " .. K.MapName(e.map) .. ")")
end

-- 창 -----------------------------------------------------------------------------------

local rows = {}
local logRows = {}

local function RoleLine()
  local role, why = CurrentRole()
  return "역할: |cff66ccff" .. (ROLE_NAME[role] or role) .. "|r (" .. why .. ")"
end

local function ItemLinkOf(id)
  local _, link = ItemInfo(id)
  return link or ("아이템 " .. id)
end

local function IconOf(id)
  local _, _, _, _, icon = InfoInstant(id)
  return icon or 134400
end

local syncing = false
local function DockGear()
  if not gframe then return end
  local main = _G["KQGFrame"]
  gframe:ClearAllPoints()
  if main then
    local right = main:GetRight()
    local sw = UIParent:GetWidth()
    if right and sw and right + gframe:GetWidth() > sw then
      gframe:SetPoint("TOPRIGHT", main, "TOPLEFT", 0, 0)
    else
      gframe:SetPoint("TOPLEFT", main, "TOPRIGHT", 0, 0)
    end
  else
    gframe:SetPoint("LEFT", UIParent, "LEFT", 60, 0)
  end
end

local function SyncScroll(total)
  local sb = gframe and gframe.scroll
  if not sb then return end
  local mx = total - ROWS
  if mx < 0 then mx = 0 end
  syncing = true
  sb:SetMinMaxValues(0, math.max(mx, 1))
  sb:SetValue(offset)
  syncing = false
  if mx == 0 then sb.thumb:SetAlpha(0.25) else sb.thumb:SetAlpha(1) end
  local sz = (ROWS / math.max(total, ROWS)) * 420
  if sz < 24 then sz = 24 end
  sb.thumb:SetHeight(sz)
end

local function RefreshGear()
  if not gframe or not gframe:IsShown() then return end
  DockGear()
  gframe.role:SetText(RoleLine() .. "  |cffaaaaaa▼|r")
  if tab == "rec" then
    for i = 1, ROWS do logRows[i]:Hide() end
    local total = #results
    if offset > total - ROWS then offset = total - ROWS end
    if offset < 0 then offset = 0 end
    for i = 1, ROWS do
      local row = rows[i]
      local e = results[offset + i]
      if e then
        row.e = e
        row.icon:SetTexture(IconOf(e.id))
        local fo = K.GetForced and K.GetForced()
        local active = fo and fo.key == ("gear" .. e.qid) and true or false
        row.active = active
        if active then
          K_SetRoundColor(row.start, { 0.70, 0.18, 0.18 }, { 0.85, 0.28, 0.28 })
          row.start.label:SetText("취소")
          row.sel:SetAlpha(1)
        else
          K_SetRoundColor(row.start, { 0.20, 0.45, 0.70 }, { 0.30, 0.58, 0.85 })
          row.start.label:SetText("시작")
          row.sel:SetAlpha(0)
        end
        local g, col = Grade(e.diff, e.eq)
        row.t1:SetText(ItemLinkOf(e.id) .. "  |c" .. col .. g .. " +" .. string.format("%.1f", e.diff) .. "|r")
        local q = Q[e.qid]
        local prefix = ""
        if #e.chain > 1 then prefix = "선행 " .. (#e.chain - 1) .. "단계 → " end
        row.t2:SetText(SlotLabel(e.loc) .. " | " .. prefix .. q[F.NAME] .. " (Lv" .. (q[F.LVL] or "?") .. ")")
        local dist = K.Measure(e.map, e.target[4], e.target[5])
        local where = e.target[6] .. " (" .. string.format("%.0f, %.0f", e.target[4], e.target[5]) .. ") " .. K.MapName(e.map)
        if dist then where = where .. " " .. math.floor(dist) .. "야드" end
        local why = DiffText(e.cb, e.eb, W[(CurrentRole())])
        row.t3:SetText((e.kind == "turnin" and "|cff66ff66[제출]|r " or "|cffffd100[수락]|r ") .. where
          .. ((why ~= "") and ("\n|cffaaaaaa근거: " .. why .. "|r") or ""))
        row:Show()
      else
        row.e = nil
        row:Hide()
      end
    end
    local msg = #results .. "개 추천"
    if pendingCount > 0 then msg = msg .. " / 아이템 정보 읽는 중 " .. pendingCount .. "개" end
    gframe.count:SetText(msg)
    SyncScroll(#results)
    if #results == 0 then
      local dg = ""
      if stat and stat.total then
        dg = "\n\n|cff888888진단: 보상퀘스트 " .. stat.total .. " / 완료 " .. stat.done .. " / 레벨초과 " .. stat.lvl
          .. "\n보상 " .. stat.items .. " / 요구레벨초과 " .. stat.req .. " / 사용불가 " .. stat.unusable .. " / 슬롯없음 " .. stat.slot
          .. " / 보유 " .. stat.owned .. "\n읽는중 " .. stat.pend .. " / 개선부족 " .. stat.weak .. " / 선행없음 " .. stat.nochain .. " / 위치없음 " .. stat.nomap .. "|r"
      end
      gframe.empty:SetText((pendingCount > 0 and "아이템 정보를 읽는 중입니다. 잠시 후 자동으로 갱신됩니다."
        or "지금 착용한 장비보다 확실히 좋은 퀘스트 보상이 없습니다.") .. dg)
      gframe.empty:Show()
    else
      gframe.empty:Hide()
    end
  else
    for i = 1, ROWS do rows[i]:Hide() end
    gframe.empty:Hide()
    local log = db().gearLog or {}
    gframe.count:SetText("장비 교체 기록 " .. #log .. "개")
    do
      local mxo = #log - ROWS
      if mxo < 0 then mxo = 0 end
      if offset > mxo then offset = mxo end
      if offset < 0 then offset = 0 end
    end
    SyncScroll(#log)
    for i = 1, ROWS do
      local row = logRows[i]
      local e = log[#log - i + 1 - offset]
      if e then
        local newl = e.new or "(비움)"
        local oldl = e.old or "(없음)"
        row.t1:SetText("[" .. (SLOT_NAME[e.slot] or e.slot) .. "] " .. newl)
        row.t2:SetText("이전: " .. oldl)
        row.t3:SetText((e.text and e.text ~= "") and ("|cffaaaaaa변화: " .. e.text .. "|r") or "")
        row:Show()
      else
        row:Hide()
      end
    end
  end
end

local function Rounded(b, r, g, bl, a)
  if b.SetBackdrop then
    b:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Buttons\\WHITE8X8",
      tile = false, edgeSize = 1,
    })
    b:SetBackdropColor(r, g, bl, a or 1)
    b:SetBackdropBorderColor(0.20, 0.25, 0.28, 1)
  elseif b.bgtex then
    b.bgtex:SetTexture("Interface\\Buttons\\WHITE8X8")
    b.bgtex:SetVertexColor(r, g, bl, a or 1)
  end
end
local function RoundButton(parent, text, w, h, base, hover, fn)
  local b = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  b:SetWidth(w)
  b:SetHeight(h)
  if not b.SetBackdrop then
    b.bgtex = b:CreateTexture(nil, "BACKGROUND")
    b.bgtex:SetAllPoints()
  end
  b.base, b.hover = base, hover
  Rounded(b, base[1], base[2], base[3])
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
  b.label:SetText(text)
  b:SetScript("OnEnter", function(self) local c = b.hover Rounded(b, c[1], c[2], c[3]) end)
  b:SetScript("OnLeave", function(self) local c = b.base Rounded(b, c[1], c[2], c[3]) end)
  b:SetScript("OnClick", fn)
  return b
end
function K_SetRoundColor(b, base, hover)
  b.base, b.hover = base, hover
  Rounded(b, base[1], base[2], base[3])
end

local function MakeBtn(parent, text, w, x, y, fn)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetWidth(w)
  b:SetHeight(22)
  b:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", x, y)
  b:SetText(text)
  b:SetScript("OnClick", fn)
  return b
end

local function CycleRole()
  local d = db()
  local cur = d.gearRole
  if not cur then
    d.gearRole = ROLE_ORDER[1]
  else
    local idx
    for i, r in ipairs(ROLE_ORDER) do if r == cur then idx = i end end
    if not idx or idx >= #ROLE_ORDER then d.gearRole = nil else d.gearRole = ROLE_ORDER[idx + 1] end
  end
  gearDirty = true
end

local function BuildGear()
  local f = CreateFrame("Frame", "KQGGearFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetWidth(420)
  f:SetHeight(560)
  f:EnableMouse(true)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    delta = delta or arg1 or 0
    offset = offset - delta
    RefreshGear()
  end)
  f:SetPoint("LEFT", UIParent, "LEFT", 60, 0)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Buttons\\WHITE8X8",
      tile = false, edgeSize = 1,
    })
    f:SetBackdropColor(0.035, 0.055, 0.065, 0.92)
    f:SetBackdropBorderColor(0, 0, 0, 1)
  end
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -16)
  title:SetText("장비 업그레이드 추천")
  f.count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.count:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -44)
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -90)
  f.empty:SetWidth(370)
  f.empty:SetJustifyH("LEFT")

  for i = 1, ROWS do
    local y = -64 - (i - 1) * 62
    local row = CreateFrame("Button", nil, f)
    row:SetWidth(384)
    row:SetHeight(60)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 18, y)
    row.sel = row:CreateTexture(nil, "BACKGROUND")
    row.sel:SetAllPoints()
    row.sel:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.sel:SetVertexColor(0.85, 0.72, 0.10, 0.32)
    row.sel:SetAlpha(0)
    row.hov = row:CreateTexture(nil, "BACKGROUND")
    row.hov:SetAllPoints()
    row.hov:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.hov:SetVertexColor(0.85, 0.72, 0.10, 0.22)
    row.hov:Hide()
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnEnter", function(s)
      s = s or this
      s.hov:Show()
      if s.e and s.e.id then
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. s.e.id)
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function(s)
      s = s or this
      s.hov:Hide()
      GameTooltip:Hide()
    end)
    row.start = RoundButton(row, "시작", 46, 20, { 0.20, 0.45, 0.70 }, { 0.30, 0.58, 0.85 }, function()
      local e = row.e
      if not e then return end
      if row.active then
        K.SetForced(nil)
        Print("안내 취소")
      else
        Target(e)
      end
      RefreshGear()
    end)
    row.start:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -3)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(34)
    row.icon:SetHeight(34)
    row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -3)
    row.t1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.t1:SetPoint("TOPLEFT", row, "TOPLEFT", 42, -2)
    row.t1:SetWidth(288)
    row.t1:SetJustifyH("LEFT")
    pcall(row.t1.SetWordWrap, row.t1, false)
    row.t2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.t2:SetPoint("TOPLEFT", row.t1, "BOTTOMLEFT", 0, -1)
    row.t2:SetWidth(288)
    row.t2:SetJustifyH("LEFT")
    pcall(row.t2.SetWordWrap, row.t2, false)
    row.t3 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.t3:SetPoint("TOPLEFT", row.t2, "BOTTOMLEFT", 0, -1)
    row.t3:SetWidth(340)
    row.t3:SetJustifyH("LEFT")
    row:SetScript("OnClick", function(s, button)
      s = s or this
      button = button or arg1
      if not s.e then return end
      if button == "RightButton" then
        db().gearIgnore[s.e.qid] = true
        Print("관심 없음: " .. Q[s.e.qid][F.NAME] .. " (/kqg gear reset 으로 되돌리기)")
        gearDirty = true
      end
    end)
    row:Hide()
    rows[i] = row

    local lr = CreateFrame("Frame", nil, f)
    lr:SetWidth(384)
    lr:SetHeight(60)
    lr:SetPoint("TOPLEFT", f, "TOPLEFT", 18, y)
    lr.t1 = lr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lr.t1:SetPoint("TOPLEFT", lr, "TOPLEFT", 4, -2)
    lr.t1:SetWidth(376)
    lr.t1:SetJustifyH("LEFT")
    lr.t2 = lr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lr.t2:SetPoint("TOPLEFT", lr.t1, "BOTTOMLEFT", 0, -1)
    lr.t2:SetWidth(376)
    lr.t2:SetJustifyH("LEFT")
    lr.t3 = lr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lr.t3:SetPoint("TOPLEFT", lr.t2, "BOTTOMLEFT", 0, -1)
    lr.t3:SetWidth(376)
    lr.t3:SetJustifyH("LEFT")
    lr:Hide()
    logRows[i] = lr
  end

  do
    local sb = CreateFrame("Slider", nil, f)
    sb:SetOrientation("VERTICAL")
    sb:SetWidth(12)
    sb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -64)
    sb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 40)
    sb.track = sb:CreateTexture(nil, "BACKGROUND")
    sb.track:SetAllPoints()
    if sb.track.SetColorTexture then sb.track:SetColorTexture(0, 0, 0, 0.55)
    else sb.track:SetTexture("Interface\\Buttons\\WHITE8X8") sb.track:SetVertexColor(0, 0, 0, 0.55) end
    sb.thumb = sb:CreateTexture(nil, "OVERLAY")
    sb.thumb:SetWidth(12)
    sb.thumb:SetHeight(40)
    if sb.thumb.SetColorTexture then sb.thumb:SetColorTexture(0.045, 0.32, 0.26, 1)
    else sb.thumb:SetTexture("Interface\\Buttons\\WHITE8X8") sb.thumb:SetVertexColor(0.045, 0.32, 0.26, 1) end
    sb:SetThumbTexture(sb.thumb)
    sb:SetMinMaxValues(0, 1)
    sb:SetValueStep(1)
    sb:SetValue(0)
    sb:SetScript("OnValueChanged", function(self, v)
      if syncing then return end
      v = v or arg1 or 0
      offset = math.floor(v + 0.5)
      RefreshGear()
    end)
    f.scroll = sb
  end

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 18)
  hint:SetText("시작: 길 안내(다시 누르면 취소) / 오른쪽 클릭: 관심 없음 / 휠: 스크롤")

  -- 닫기 (X)
  local x = RoundButton(f, "X", 22, 22, { 0.35, 0.12, 0.12 }, { 0.70, 0.18, 0.18 }, function() f:Hide() end)
  x:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
  -- 역할 선택 콤보
  local rb = RoundButton(f, "", 250, 22, { 0.02, 0.035, 0.042 }, { 0.08, 0.12, 0.14 }, function()
    if f.menu:IsShown() then f.menu:Hide() else f.menu:Show() end
  end)
  rb:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -38)
  rb.label:ClearAllPoints()
  rb.label:SetPoint("LEFT", rb, "LEFT", 8, 0)
  f.role = rb.label
  local menu = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetWidth(250)
  local opts = { { nil, "자동 (특성 기준)" } }
  for _, r in ipairs(ROLE_ORDER) do opts[#opts + 1] = { r, ROLE_NAME[r] or r } end
  menu:SetHeight(#opts * 22 + 8)
  menu:SetPoint("TOPLEFT", rb, "BOTTOMLEFT", 0, 0)
  if menu.SetBackdrop then
    menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8",
      tile = false, edgeSize = 1 })
    menu:SetBackdropBorderColor(0, 0, 0, 1)
    menu:SetBackdropColor(0.02, 0.035, 0.042, 1)
  end
  for i, o in ipairs(opts) do
    local ob = CreateFrame("Button", nil, menu)
    ob:SetWidth(240)
    ob:SetHeight(22)
    ob:SetPoint("TOPLEFT", menu, "TOPLEFT", 5, -4 - (i - 1) * 22)
    local hl = ob:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Buttons\\WHITE8X8")
    hl:SetVertexColor(0.30, 0.55, 0.80, 0.35)
    hl:Hide()
    ob.label = ob:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ob.label:SetPoint("LEFT", ob, "LEFT", 6, 0)
    ob.label:SetText(o[2])
    ob:SetScript("OnEnter", function() hl:Show() end)
    ob:SetScript("OnLeave", function() hl:Hide() end)
    ob:SetScript("OnClick", function()
      db().gearRole = o[1]
      menu:Hide()
      gearDirty = true
      RefreshGear()
    end)
  end
  menu:Hide()
  f.menu = menu
  f:SetScript("OnHide", function() menu:Hide() GameTooltip:Hide() end)
  local acc, lastKey = 0, nil
  f:SetScript("OnUpdate", function(_, el)
    acc = acc + (el or arg1 or 0)
    if acc < 0.5 then return end
    acc = 0
    local fo = K.GetForced and K.GetForced()
    local k = fo and fo.key or false
    if k ~= lastKey then lastKey = k RefreshGear() end
  end)
  f:SetScript("OnShow", function() gearDirty = true end)
  f:Hide()
  gframe = f
end

function K.ToggleGear()
  if not gframe then return end
  if gframe:IsShown() then gframe:Hide() else gframe:Show() end
end

function K.GearCommand(arg)
  arg = arg or ""
  if arg == "role" then
    CycleRole()
    Print(RoleLine())
  elseif arg == "off" then
    K.SetForced(nil)
    Print("안내를 해제했습니다.")
  elseif arg == "reset" then
    db().gearIgnore = {}
    gearDirty = true
    Print("관심 없음 표시를 모두 되돌렸습니다.")
  elseif arg == "debug" then
    local role, why = CurrentRole()
    local idx, sums = SpecIndex()
    Print("역할 " .. role .. " (" .. why .. ") / 줄기 투자 " .. (sums and (sums[1] .. "," .. sums[2] .. "," .. sums[3]) or "읽기 실패")
      .. " / 추천 " .. #results .. " / 읽는 중 " .. pendingCount)
    if stat and stat.total then
      Print("진단 레벨 " .. tostring(stat.level) .. " 역할 " .. tostring(stat.role) .. " / 보상퀘스트 " .. stat.total .. " 완료 " .. stat.done .. " 레벨초과 " .. stat.lvl
        .. " / 보상 " .. stat.items .. " 요구초과 " .. stat.req .. " 사용불가 " .. stat.unusable .. " 슬롯없음 " .. stat.slot .. " 보유 " .. stat.owned
        .. " / 읽는중 " .. stat.pend .. " 개선부족 " .. stat.weak .. " 선행없음 " .. stat.nochain .. " 위치없음 " .. stat.nomap .. " 통과 " .. stat.ok)
    end
    for i = 1, math.min(5, #results) do
      local e = results[i]
      local q = Q[e.qid]
      Print(i .. ". 아이템 " .. e.id .. " " .. e.loc .. " +" .. string.format("%.1f", e.diff) .. " (현재 " .. string.format("%.1f", e.eq) .. ") / 퀘스트 "
        .. q[F.NAME] .. " Lv" .. tostring(q[F.LVL]) .. " / 사슬 " .. #e.chain .. "단계 / " .. e.kind .. " " .. e.target[6])
    end
  else
    K.ToggleGear()
  end
end

-- 장비 교체 이력 ------------------------------------------------------------------------

local function SnapshotEquip()
  for slot = 1, 19 do lastEq[slot] = GetInventoryItemLink("player", slot) end
end

local function RecordChange(slot)
  local newl = GetInventoryItemLink("player", slot)
  local oldl = lastEq[slot]
  if newl == oldl then return end
  lastEq[slot] = newl
  local d = db()
  d.gearLog = d.gearLog or {}
  local role = CurrentRole()
  local text = ""
  if newl and oldl then
    text = DiffText(LinkBucket(newl), LinkBucket(oldl), W[role])
  elseif newl then
    text = "새로 착용"
  end
  table.insert(d.gearLog, { t = time and time() or 0, slot = slot, new = newl, old = oldl, text = text })
  while #d.gearLog > 60 do table.remove(d.gearLog, 1) end
end

-- 이벤트 ---------------------------------------------------------------------------------

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "QUEST_TURNED_IN", "QUEST_ACCEPTED",
  "QUEST_REMOVED", "QUEST_LOG_UPDATE", "GET_ITEM_INFO_RECEIVED", "BAG_UPDATE_DELAYED", "TRAIT_CONFIG_UPDATED",
  "PLAYER_REGEN_ENABLED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
local acc = 0
ev:SetScript("OnEvent", function(_, e, a1)
  e = e or event
  a1 = a1 or arg1
  if e == "PLAYER_LOGIN" then
    if not db() then return end
    BuildGear()
    SnapshotEquip()
    return
  end
  if e == "PLAYER_EQUIPMENT_CHANGED" then
    if a1 and a1 >= 1 and a1 <= 19 then pcall(RecordChange, a1) end
  end
  if e == "QUEST_ACCEPTED" then
    local f = K.GetForced()
    if f and f.kind == "accept" and f.quests and f.quests[1] and (a1 == f.quests[1]) then K.SetForced(nil) end
  end
  gearDirty = true
end)
ev:SetScript("OnUpdate", function(_, elapsed)
  elapsed = elapsed or arg1 or 0
  acc = acc + elapsed
  if acc < 1 then return end
  acc = 0
  if not gframe or not gframe:IsShown() then return end
  if InCombatLockdown and InCombatLockdown() then return end
  if gearDirty and GetTime() - lastEval >= 1.5 then
    local ok, err = pcall(Evaluate)
    if not ok then
      gearDirty = false
      Print("장비 추천 계산 오류: " .. tostring(err))
    end
  end
  local ok2, err2 = pcall(RefreshGear)
  if not ok2 and db() and db().debug then Print("장비 창 오류: " .. tostring(err2)) end
end)
