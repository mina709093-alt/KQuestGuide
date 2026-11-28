# 한글 퀘스트 길잡이 (KQuestGuide)

## 데이터 출처와 연락처 (Data sources & contact)

이 애드온은 아래에 적은 프로젝트들의 공개 데이터를 이용해 만들었습니다. 데이터를 만들고 공개해 주신 분들께 깊이 감사드립니다.

저작권자나 데이터를 제공하신 분께서 사용을 원하지 않으시면, 언제든 아래 메일로 알려 주십시오.
요청을 받는 즉시 해당 데이터의 사용을 멈추고, 이후 배포본에서 빼겠습니다. 그 밖에 필요하신 조치가 있으면 성심껏 협조하겠습니다.
미처 허락을 구하지 못한 부분이 있었다면 진심으로 사과드립니다.

- 연락처: mina709093@gmail.com

> This add-on is built with publicly available data from the projects listed below, and we are sincerely grateful to their authors.
> If you are a rights holder or data provider and would prefer that we not use your data, please contact us at any time at mina709093@gmail.com.
> We will stop using it immediately upon request, remove it from future releases, and cooperate fully with any further steps you may need.
> We apologize for any inconvenience this may have caused.

### 어떤 데이터를 어디서 가져오는지

| 데이터 | 가져온 곳 | 조건 | 들어 있는 파일 |
|---|---|---|---|
| 퀘스트·NPC·오브젝트 정보, 퀘스트 연계(선행·다음 퀘스트), 지역 지도 번호, 한글 이름 | [Questie](https://github.com/Questie/Questie) / [QuestieDB](https://github.com/Questie/QuestieDB)의 WoW: Forever 데이터와 koKR 현지화 데이터를 변환 | GPLv3 (`LICENSE-GPL3.md`, `NOTICE.txt`) | `Data.lua`, `Map.lua`, `Objectives.lua` |
| 빠진 퀘스트 보충(0.31.0): Data.lua에 없던 퀘스트의 정보·연계·시작·완료 위치, 한글 이름·목표 글 | [QuestieDB](https://github.com/Questie/QuestieDB)의 WoW: Forever 데이터(`QuestieDB_Forever.toc` 메타데이터)와 그 안의 koKR 번역 블록을 변환(2026-11-24). Forever에서 막힌 퀘스트는 [Questie](https://github.com/Questie/Questie) 블랙리스트(`QuestieQuestBlacklist.lua`)를 Forever 조건으로 읽어 뺌. 한글 번역이 없는 퀘스트는 영어 이름에 "(영문)"을 붙임 | GPLv3 (`LICENSE-GPL3.md`, `NOTICE.txt`) | `DataForever.lua` |
| 안내 제외 목록(0.31.1): Forever에서 받을 수 없는 퀘스트와 축제 퀘스트 번호 | [Questie](https://github.com/Questie/Questie) 블랙리스트(`QuestieQuestBlacklist.lua`)를 Forever 조건으로 읽은 결과와 축제 자료(`Database/Corrections/Holidays/quests`)를 변환(퀘스트 번호와 구분만). 축제가 열렸는지는 실행 중 설치된 Questie의 판단(`QuestieEvent.activeQuests`)을 읽기만 함 | GPLv3 (`LICENSE-GPL3.md`, `NOTICE.txt`) | `BlockData.lua` |
| 안내(브레드크럼) 퀘스트 연결: 어떤 퀘스트가 어떤 퀘스트로 안내하는지(퀘스트 번호 두 개만) | [QuestieDB](https://github.com/Questie/QuestieDB)의 WoW: Forever 데이터(`breadcrumbForQuestId`, `breadcrumbs` 칸)와 Forever 수정 파일을 변환. `KQuestGuide` 퀘스트 데이터에 있는 퀘스트끼리만 남김 | GPLv3 (`LICENSE-GPL3.md`, `NOTICE.txt`) | `BreadcrumbData.lua` |
| 필요 없는 퀘스트 아이템 판정(0.35.0): 아이템 번호별로 그 아이템을 쓰는·보상으로 주는·시작하는 퀘스트 번호 | [QuestieDB](https://github.com/Questie/QuestieDB)의 WoW: Forever 데이터(`QuestieDB_Forever.toc` 메타데이터)에서 번호만 옮김(2026-11-25). 아이템의 시작 퀘스트·보상 퀘스트 칸과 퀘스트의 목표 아이템·시작 때 받는 아이템·필요 아이템 칸을 읽음. 받을 수 없는 퀘스트는 [Questie](https://github.com/Questie/Questie) 블랙리스트를 Forever 조건으로 읽어 표시. 화면의 "연결된 퀘스트 자료가 없습니다" 줄에 "(Questie)"를 붙임 | GPLv3 (`LICENSE-GPL3.md`, `NOTICE.txt`) | `QuestItemData.lua` |
| 퀘스트 시작 아이템 아이콘(0.38.0): 퀘스트를 시작하는 아이템 번호, 그 아이템이 시작하는 퀘스트 번호, 그 아이템을 떨어뜨리는 몬스터 번호 | [QuestieDB](https://github.com/Questie/QuestieDB)의 WoW: Forever 데이터(`QuestieDB_Forever.toc` 메타데이터)에서 번호만 옮김(2026-11-28). 아이템의 시작 퀘스트 칸(startQuest)과 드롭 몬스터 칸(npcDrops)을 읽음. 받을 수 없는 퀘스트는 [Questie](https://github.com/Questie/Questie) 블랙리스트를 Forever 조건으로 읽어 뺌. 드롭 확률은 넣지 않음. 아이콘 툴팁과 몬스터 툴팁 줄에 "(Questie)"를 붙임. 아이템 이름·아이콘은 게임에서 읽음 | GPLv3 (`LICENSE-GPL3.md`, `NOTICE.txt`) | `StarterData.lua` |
| 퀘스트 보상 목록 | 만든 경위가 파일에 기록되어 있지 않아 다시 확인하고 있습니다. 확인되는 대로 이 표에 적겠습니다. | 확인 중 | `Rewards.lua` |
| 게임에서 모은 퀘스트 위치 | 사용자들이 게임 안에서 직접 기록해 보내 준 자료(`/kqg 수집`)를 취합 | 보내 준 분들의 동의 | `FoundData.lua` |
| 퀘스트 정리 판정 (실시간) | 설치된 Questie 애드온의 데이터베이스를 읽기만 함. `KQuestGuide` 데이터에 없는 퀘스트일 때만 사용 | GPLv3 | `Cleanup.lua` |
| 경로안내 위치 (실시간) | 설치된 Questie 애드온의 데이터베이스를 읽기만 함(제출 NPC, 목표 몬스터·오브젝트·아이템을 떨어뜨리는 곳의 위치). `KQuestGuide` 자료에 위치가 없을 때만 사용하고 이름 뒤에 "(Questie)"를 붙임 | GPLv3 | `Route.lua` |
| 추천 퀘스트 관리: 퀘스트 번호, 연계 순서, 레벨, 종족·직업 조건, 보상 아이템 번호 | [QuestieDB](https://github.com/Questie/QuestieDB)의 WoW: Forever 데이터에서 사실값만 옮김(2026-11-24). 시작·완료 NPC와 좌표는 적지 않고 실행 중 KQuestGuide 자료, 없으면 설치된 Questie에서 읽음("(Questie)" 표시) | GPLv3 | `RecommendData.lua`, `Recommend.lua` |
| 추천 퀘스트 관리: 가방 칸 수, 보상 아이템 한글 이름 | 이 게임 클라이언트(빌드 1.60.1.70888)의 게임 테이블 ItemSparse (wago.tools에서 받음). 아이템 이름의 권리는 Blizzard에 있음 | 게임 클라이언트의 사실 정보 | `RecommendData.lua` |
| 추천 퀘스트 관리: 어떤 퀘스트가 쓸모 있는지 고른 기준, Questie에 연결이 없는 보상 3건(튼튼한 도시락, 하이잘 우편 가방, 탈것 퀘스트) | Warcraft Tavern의 WoW: Forever 가이드 [Bags & Bank](https://www.warcrafttavern.com/forever/guides/inventory/), [Cozy Sleeping Bag](https://www.warcrafttavern.com/forever/guides/cozy-sleeping-bag/)를 참고만 함. 문장·표는 옮기지 않았고, 추천 이유와 주의 문구는 직접 씀. 연결이 없는 보상은 창에 "게임 확인 필요"로 표시 | 공개 글의 사실 정보, 출처 표기 | `RecommendData.lua` |
| 던전 목록, 입장·권장 레벨, 입구 위치, 던전별 퀘스트 번호·레벨·진영·선행 번호, (한글이 없을 때만) 영어 퀘스트 제목·NPC 이름 | Dungeon Codex (AeonDungeonJournal) 1.4 (CurseForge 프로젝트 1715265)의 데이터에서 사실 정보만 변환. 전리품·보스·공략·지도 그림은 가져오지 않음 | GPL-2.0 | `DungeonData.lua` |
| 던전 퀘스트 보충과 수락 위치(0.37.0): Dungeon Codex에 없던 던전 퀘스트 번호, 공격대 7곳의 퀘스트 목록, 퀘스트마다 던전 안/밖 수락 위치·선행 퀘스트 시작 지역·검증 상태 | [QuestieDB](https://github.com/Questie/QuestieDB)의 WoW: Forever 데이터(`QuestieDB_Forever.toc` 메타데이터, `support/Forever/Zones/dungeons.lua` 던전 번호·입구)를 읽어 계산(2026-11-28). 퀘스트 소속 지역, 시작 NPC·오브젝트·아이템이 나오는 곳, 목표 몬스터·오브젝트가 있는 곳만 봄. Forever에서 막힌 퀘스트는 [Questie](https://github.com/Questie/Questie) 블랙리스트를 Forever 조건으로 읽어 뺌. 창 툴팁에 "QuestieDB Forever" 출처 표시 | GPLv3 (`LICENSE-GPL3.md`, `NOTICE.txt`) | `DungeonData.lua` |
| 책 반납 퀘스트(0.32.0): 책 위치의 지도 번호·좌표, 책 아이템 번호, 반납 퀘스트 번호 | [QuestieDB](https://github.com/Questie/QuestieDB)의 WoW: Forever 데이터(`QuestieDB_Forever.toc` 메타데이터)에서 사실값만 옮김(2026-11-24). 퀘스트의 수집 아이템·시작 오브젝트, 그 오브젝트의 생성 위치를 읽고 지역 번호를 지도 번호로 바꿈. 아이템 번호 8개는 게임에서 확인 | GPLv3 (`LICENSE-GPL3.md`, `NOTICE.txt`) | `BookData.lua` |
| 책 반납 퀘스트의 처음 책 목록(책 제목 번역, 비고) | 인벤 와우 포에버 게시판 [「책 반납을 위한 수집 위치」](https://www.inven.co.kr/board/wow/6567/1684) (2026-09-25)의 표를 옮겨 적음. 그 글의 원 출처는 [Wowhead 시즌 오브 디스커버리 마법사 주문력 룬 가이드](https://www.wowhead.com/classic/guide/season-of-discovery/classes/mage/spell-power-rune)이고, 책 제목은 제미나이 번역(게임에서 확인한 책은 게임 이름으로 바꿈). 0.31까지는 이 글의 좌표(시즌 오브 디스커버리 기준)를 썼고, 0.32.0부터 좌표는 위 QuestieDB 값을 씀 | 공개 글의 사실 정보, 출처 표기 | `BookData.lua` |
| 책 반납 퀘스트의 반납 장소, 줍는 요령 메모 | 유튜브 영상 [「[와우 포에버] 책 반납 퀘스트 목걸이 반지 얻기」](https://youtu.be/cKsdx2ydH6Y) (시후XIHUGAME, 2026-09-28)의 챕터 제목·자막·고정 댓글에서 사실 정보만 옮김 | 공개 영상의 사실 정보, 출처 표기 | `BookData.lua` |
| 길 안내 (선택) | 설치된 Shortest Path Forever 애드온의 공개 API를 읽기만 함 | 해당 애드온 조건 | `KQuestGuide.lua`, `Route.lua` |
| 퀘스트 메뉴 연동 (선택) | 설치된 DaylightUI 애드온의 공개 API로 메뉴 항목만 추가 | 해당 애드온 조건 | `DaylightBridge.lua` |
| DaylightUI 가방 칸 표시 (선택, 0.35.0) | 설치된 DaylightUI 애드온의 공개 API(`Frames("bagslot")`, `Attach`)로 가방·은행 칸 위에 빨간 표시만 얹음. DaylightUI 코드는 가져오지 않음 | 해당 애드온 조건 | `QuestItems.lua` |
| 글꼴 | 마루부리(MaruBuri), 네이버 배포 | SIL OFL 1.1로 알려져 있음 | `fonts/` |

### 데이터를 어떻게 확인하는지

- **데이터에 있는 값만 쓰고 추측하지 않습니다.** 정보가 없으면 안내하지 않거나 "알 수 없음"으로 둡니다.
- **게임이 알려 주는 정보를 먼저 씁니다.** 예를 들어 회색(저레벨) 퀘스트 기준은 게임의 회색 범위 함수에서, 던전 퀘스트 여부는 게임의 퀘스트 태그에서 가져옵니다.
- **Questie에서 실시간으로 가져온 정보에는 반드시 출처를 남깁니다.** 화면에는 "(Questie)"로 표시하고, 마우스를 올리면 툴팁에 자세한 출처가 나옵니다.
- **사용자 수집 자료는 취합 도구로 합친 뒤 검사합니다.** 기존 항목이 사라지지 않았는지, 좌표가 0~100 안인지, 파일이 정상적으로 읽히는지 확인한 다음에만 넣습니다.
- 퀘스트를 포기하는 기능(퀘스트 정리)은 확인 창에서 사용자가 직접 고른 퀘스트만 처리합니다.
