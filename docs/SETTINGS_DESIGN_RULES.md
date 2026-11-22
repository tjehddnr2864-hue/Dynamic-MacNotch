# 설정 창 디자인 규칙

[설정 창 개편 가이드라인](SETTINGS_REDESIGN_GUIDELINE.md) 단계 0의 결과물이다. 단계 2~6은 모양을 정할 때 이 문서만 본다. 규칙마다 **무엇을 / 왜 / 근거**를 적는다.

근거 표기: **[HIG]** Apple Human Interface Guidelines(2026-06 갱신본), **[LG]** Apple "Adopting Liquid Glass", **[시스템 설정]** macOS 27.3의 시스템 설정 앱을 직접 캡처해 잰 값, **[지금]** 이 앱의 현재 코드·캡처, **[판단]** 이 프로젝트에 맞춘 결정.

---

## 1. 기준선 (2026-11-22, macOS 27.3, `settings-redesign` 브랜치 시작점)

| 항목 | 값 |
|---|---|
| 캡처 | 24페이지 × 한국어·영어 = 48장(화면 밖, 높이 1500으로 페이지 전체), 화면 위 3장(기본, 투명도 0.9, 흐림 0) → `build/audit/settings-before/` (git에 안 올라감) |
| 설정 창(도우미) 메모리 | 페이지에 따라 31~56MB (정보 31, 우선순위 37, 디스플레이 38, 일반 48, 홈 54, AI 채팅 56). 한국어·영어 차이 1MB 안쪽 |
| 설정 창 대기 | 30초 동안 CPU 0.23ms(약 0.03%), 깨어남 약 1.1회/초, 메모리 변화 없음, 누수 0 |
| 설정값 | 도우미를 띄우고 닫는 동안 설정 파일이 바뀌지 않음 (전후 비교). 같은 시간 본 앱이 쓰는 캐시(`aiUsageCache` 등)만 바뀜 |
| 본 앱 | 1.4.9 배포 빌드 기준 실행 직후 17.8MB, 대기 0.23~0.27% (바뀌면 안 됨) |

캡처 방법(다음 단계에서 같은 방식으로 다시 찍는다):

```bash
# 화면 밖, 페이지 전체. -language는 반드시 --helper 앞에 (뒤에 두면 --helper 값으로 먹혀 무시됨)
DMN_SETTINGS_PAGE=<페이지> DMN_SETTINGS_HEIGHT=1500 "<앱>/Contents/MacOS/DynamicMacNotch" [-language english] --helper=settings
# 창 번호: build/audit/wid <pid>, 캡처: screencapture -x -o -l <창 번호> out.png
# 투명도 확인은 창만 찍으면 뒤 화면이 안 담긴다: build/audit/wbounds <pid>로 영역을 얻어 screencapture -x -R x,y,w,h
```

`-settingsBlur 0`, `-settingsTransparency 0.9`처럼 인자로 주면 저장된 설정을 바꾸지 않고 그 값으로 띄울 수 있다 (시험에 이 방법을 쓴다).

---

## 2. 방향: 표준 부품 위에 이 앱의 개성

조사의 결론은 하나다. **"트렌디한 macOS 설정 창"은 직접 꾸민 것이 아니라 시스템 부품을 그대로 쓴 것**이다.

- [LG] 사이드바·도구 막대 같은 탐색 요소에 직접 만든 배경을 두지 말고, 시스템이 정하게 하라(*"Prefer to remove custom effects and let the system determine…"*). 표준 부품은 Liquid Glass를 저절로 입는다.
- [LG] grouped 폼은 macOS 26에서 **모서리가 더 둥글고 새 간격**을 저절로 얻는다. 구역 제목은 대문자로 바꾸지 않고 제목식 표기.
- [HIG] 사이드바로 탐색하는 앱은 **검색을 사이드바 맨 위**에 둔다. 시스템 설정이 그 예다.
- [시스템 설정] 실제 구조: 사이드바 맨 위 둥근 검색 칸 → 머리글 없이 **간격으로 나눈 묶음** → 오른쪽은 큰 아이콘·제목·한 줄 설명의 **머리 카드** + 둥근 카드형 묶음.

그래서 이번 개편의 기본 방향은:

| 부분 | 지금 | 바꿀 방향 | 근거 |
|---|---|---|---|
| 사이드바 | 직접 그린 `VStack` + `glassEffect` 패널 | **표준 사이드바**(`NavigationSplitView` + `List(.sidebar)`)로. macOS 26 이상은 유리를 저절로 입고, 14·15는 시스템 사이드바 머티리얼 | [LG], [HIG] |
| 검색 | 없음 | `.searchable(placement: .sidebar)` — 사이드바 맨 위 | [HIG], [시스템 설정] |
| 페이지 | `Form(.grouped)` | **`Form(.grouped)` 유지.** 가이드라인 §8의 A안 | [LG]: 새 모양을 저절로 얻음 |
| 행 | 제목 한 줄 + 구역 아래 긴 설명 | 제목 + **행 안의 보조 설명**(폼이 지원하는 두 줄 라벨) | [시스템 설정], [판단] |
| 창 배경 | 흰색 층 + 뒤 화면 흐림 (사용자가 조절) | **유지.** 이 앱의 개성. 단 접근성 설정을 따른다(§7) | [판단] |

> **가이드라인 수정 사항:** 가이드라인 §8은 "직접 만든 카드(B안)"를 권했지만, 조사 결과 macOS 26의 grouped 폼이 이미 그 모양을 내고 키보드·VoiceOver도 그대로 지원한다. **권고를 A안(폼 유지)으로 바꾼다.** B안은 폼으로 안 되는 것이 단계 5에서 확인될 때만 쓴다.

**[미확인 — 단계 2 프로토타입에서 확인]** 표준 사이드바(`NavigationSplitView`)가 이 앱의 **투명·테두리 없는 창**(`fullSizeContentView`, `isOpaque = false`, 창 버튼 자리 40pt)에서 제대로 그려지는지. 안 되면 지금의 직접 그린 사이드바를 유지하고 검색 칸만 직접 만든다 (`TextField` + 둥근 캡슐, 시스템 설정과 같은 모양).

---

## 3. 아이콘 (요청 1 — 바꾸지 않음)

- 기호 이름 24개, 블루투스 직접 그림, 굵기 `.medium`, 사이드바 13pt, 강조색(선택 시 흰색)은 **그대로.** [지금]
- [HIG] 사이드바 아이콘은 강조색을 쓰고, 사용자가 고른 시스템 강조색을 따라야 한다 → 지금 `Color.accentColor`라 이미 맞다.
- [시스템 설정]은 색 있는 둥근 타일 아이콘을 쓰지만, **타일은 넣지 않는다** (가이드라인 §1.2).
- 표준 사이드바로 바꾸면 시스템이 아이콘 크기를 사이드바 크기 설정(작게·중간·크게)에 맞춰 바꾼다 [HIG]. **아이콘을 그대로 두기 위해 행 안의 아이콘은 지금 부품(`SettingsIcon(size: 13)`)을 그대로 넣는다.**
- 머리 카드(§5.2)를 넣으면 같은 기호를 크게 한 번 더 보여 준다. 기호·색은 같고 크기만 커진다 → **사용자 확인 대상** (아래 §9).

---

## 4. 사이드바

| 규칙 | 값 | 근거 |
|---|---|---|
| 너비 | 214pt 유지 | [지금] |
| 맨 위 | 창 버튼 자리 다음에 검색 칸. 높이 28pt, 캡슐 모양, 자리표시 글 "검색" / "Search" | [HIG], [시스템 설정] |
| 묶음 | **짧은 머리글**(앱·노치·연결 …)을 둔다. 시스템 설정은 머리글 없이 간격만 쓰지만, 이 앱은 기능 이름만으로는 묶음의 뜻이 안 보여 머리글이 필요하다. 머리글은 작은 회색 글(11pt, semibold) | [HIG] "group titles: succinct, descriptive", [판단] |
| 단계 | 두 단계까지(머리글 → 페이지). 그 아래 단계는 두지 않는다 | [HIG] "no more than two levels" |
| 접기 | 머리글을 눌러 접기. 처음엔 모두 펼침. 접힘 상태는 창을 닫았다 열어도 유지 | [HIG] disclosure, [판단] |
| 행 | 높이 28pt, 아이콘 칸 20pt, 간격 9pt, 선택은 강조색 채움(시스템 사이드바가 하면 그것을 따름) | [지금] |
| 맨 아래 | 중요한 것을 두지 않는다. 정보·권한은 아래여도 됨 | [HIG] |

---

## 5. 페이지

### 5.1 틀

| 규칙 | 값 | 근거 |
|---|---|---|
| 폼 | `Form` + `.formStyle(.grouped)` + `scrollContentBackground(.hidden)` (지금과 같음). 구역 모서리·간격은 **덮어쓰지 않는다** | [LG] |
| 스크롤 가장자리 | 제목 밑으로 내용이 지나갈 때 시스템의 스크롤 가장자리 효과를 쓴다(macOS 26). 14·15는 지금처럼 자른다 | [LG] scroll-edge |
| 창 제목 | 보이는 페이지 이름으로 바꾼다(창은 제목을 숨기지만 창 메뉴·VoiceOver가 읽음) | [HIG] Settings |
| 다시 열 때 | **마지막에 본 페이지**로 연다 (지금은 늘 일반) | [HIG] Settings |
| 창 버튼 | 최소화·확대 버튼은 흐리게 | [HIG] Settings |

### 5.2 머리 카드 (선택 사항 — 사용자 확인)

[시스템 설정]처럼 페이지 맨 위에 **아이콘(같은 기호, 강조색, 크게) + 제목 + 한 줄 설명**. 지금의 제목 줄(`title2.bold`)을 대신한다. 장점: 페이지마다 "이 페이지가 무엇을 하는지" 한 줄이 생긴다(요청 5). 단점: 화면 높이를 100pt쯤 더 쓴다.

### 5.3 행

| 종류 | 모양 |
|---|---|
| 스위치 | 제목(13pt) + 아래 보조 설명(11pt, 보조색). `Toggle { Text(제목); Text(설명) }`의 두 줄 라벨을 쓴다 [미확인: macOS 14에서도 두 줄로 그려지는지 단계 4에서 확인] |
| 고르기 | 같은 두 줄 라벨 + 오른쪽 컨트롤 |
| 딸린 행 | 들여쓰기 16pt (지금과 같음) + **작은 스위치**(`.controlSize(.mini)`). 주 스위치는 보통 크기 [HIG] "regular switch for the primary setting and mini switches for subordinate settings" |
| 설명이 긴 행 | 보조 설명 한 줄 + 오른쪽에 `?` 버튼(누르면 설명 창). 구역 아래 긴 글 대신 |

**스위치 vs 체크박스:** [HIG]는 macOS에서 "켜기·끄기 하나는 체크박스를 우선"이라 하지만, 시스템 설정 자체는 grouped 폼에서 스위치를 쓴다. 이 앱은 지금처럼 **스위치로 통일**한다 [판단: 시스템 설정과 같은 모양, 사용자가 이미 익숙함].

---

## 6. 글

macOS의 글 크기: body 13, callout 12, subheadline 11, footnote·caption 10.

| 단계 | 쓰임 | 크기·굵기 | 색 |
|---|---|---|---|
| 1 | 페이지 제목 | `title2` 17pt bold (머리 카드면 `title` 22pt bold) | 기본 |
| 2 | 사이드바 묶음 머리글, 구역 제목 | 11pt semibold / 폼 기본 머리글 | 보조색 / 폼 기본 |
| 3 | 행 제목 | 13pt regular (`body`) | 기본 |
| 4 | 행 보조 설명 | **11pt** (`subheadline`) | 보조색 |
| 5 | 값(슬라이더 숫자 등) | 13pt, 숫자 고정폭 | 보조색 |

- **최소 11pt.** [지금] 구역 아래 설명은 `.caption`(10pt)이다 — 6곳. 단계 4에서 11pt로 올리면서 행 안으로 옮긴다.
- 색은 시스템 의미색만: 기본(`.primary`), 보조(`.secondary`), 켜짐·좋음 초록, 주의 주황, 강조색. 직접 정한 RGB는 쓰지 않는다 (라이트·다크·대비 높이기를 저절로 따르게) [LG].

---

## 7. 창 배경과 접근성

| 규칙 | 근거 |
|---|---|
| 흐림·투명도 설정은 유지. 그러나 시스템의 **"투명도 줄이기"가 켜지면 흐림·투명도를 무시하고 불투명 배경**을 쓴다 [지금: 따르지 않음] | [LG] "test with accessibility settings that reduce transparency" |
| **"대비 높이기"** 가 켜지면 구분선·보조색을 진하게 (시스템 색을 쓰면 저절로) | [LG] |
| **"동작 줄이기"** 가 켜지면 사이드바 펼침·페이지 전환 애니메이션을 끈다 [지금: 노치는 따르지만 설정 창은 안 따름] | [LG] |
| 글자 대비: 본문 4.5:1, 보조 설명 3:1 이상. **어두운·복잡한 배경화면 위에서 투명도 0.9**로 확인한다 (단계 0의 화면 캡처는 뒤가 밝은 배경화면이라 판정 못 함) | [판단] |
| 상태를 색으로만 알리지 않는다 ("연결됨" 같은 글을 같이) — 지금도 그렇다 | [HIG] Toggles |

**다크 모드:** 지금 설정 창은 늘 밝은 모양으로 고정돼 있다(`window.appearance = .aqua`). 시스템을 따라 어두운 모양도 지원할지 결정이 필요하다 (§9). 지원하면 흰색 층이 어두운 층으로 바뀌고, 시스템 색만 쓰면 나머지는 저절로 따라온다.

---

## 8. 움직임

- 사이드바 펼침·페이지 전환: `.snappy(duration: 0.25)` 하나 [지금 사이드바와 같음].
- 검색 결과로 이동한 줄의 강조: 강조색 10% 배경이 1.2초 동안 사라짐.
- 동작 줄이기에서는 모두 즉시 (§7).

---

## 9. 사용자 결정 (단계 0 끝)

| | 질문 | 결정 (2026-11-22, 사용자) |
|---|---|---|
| 1 | 방향: **표준 부품**(시스템 사이드바·검색·폼)으로 가고, 창 배경의 흐림·투명도만 이 앱의 개성으로 남기기 | **예** |
| 2 | 페이지 맨 위 **머리 카드**(같은 아이콘을 크게 + 한 줄 설명) | **넣기** — §5.2를 확정 규칙으로 본다 |
| 3 | **다크 모드** 지원 | **지원** — `window.appearance` 고정을 풀고 시스템을 따른다. 흰색 층은 어두운 모양에서 어두운 층으로 |
| 4 | 딸린 항목의 **작은 스위치** | **적용** — §5.3 |

---

## 출처

- Apple HIG — Sidebars: https://developer.apple.com/design/human-interface-guidelines/sidebars
- Apple HIG — Settings: https://developer.apple.com/design/human-interface-guidelines/settings
- Apple HIG — Search fields: https://developer.apple.com/design/human-interface-guidelines/search-fields
- Apple HIG — Toggles: https://developer.apple.com/design/human-interface-guidelines/toggles
- Apple — Adopting Liquid Glass: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- WWDC25 "Build a SwiftUI app with the new design"(323), "Build an AppKit app with the new design"(310)
- macOS 27.3 시스템 설정 앱 직접 캡처 (개인 정보가 보여 저장소에 넣지 않음: `build/audit/settings-before/ref-system-settings.png`)
