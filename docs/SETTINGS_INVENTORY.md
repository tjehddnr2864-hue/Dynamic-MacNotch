# 설정 인벤토리

설정 창 개편 [가이드라인](SETTINGS_REDESIGN_GUIDELINE.md) 단계 1의 결과물. `.private/tools/settings_inventory.py`가 소스에서 만든다 (근사치: 정규식으로 읽음). §1은 사람이 확인해 적은 것이라 다시 만들 때 손으로 옮긴다.

다시 만들기: `python3 -I .private/tools/settings_inventory.py --md <파일>` (도구는 공개 저장소에 없음).

열: **키**(저장 이름, 바꾸지 않음) · **페이지 › 구역** · **줄 이름**(한국어) · **부품** · **선택지**(enum 경우의 수) · **기본값** · **비고**.

## 0. 요약

| 항목 | 수 |
|---|---|
| 선언된 설정 | 118 |
| 설정 화면 한 곳에서 바뀜 | 113 |
| 설정 화면 여러 곳에서 바뀜 | 4 |
| 설정 화면 밖에서만 바뀜(내부 상태) | 1 |
| 아무 데서도 안 읽힘(죽은 설정) | 0 |
| 구역 설명 | 30개 (60자 초과 22, 100자 초과 11) |
| 부품별 사용(설정을 바꾸는 줄) | Toggle 55, (기타) 15, SegmentedChoice 13, Picker 13, ValueMenu 9, ValueSlider 7, Button 5, AlertStylePicker 5, HomePageToggle 4, ListField 4, MenuChoice 3, FolderSetting 3, ReorderList 2, AlertDurationMenu 2, ProgressStylePicker 2 |

## 1. 확인한 것 (2026-11-22, 단계 1)

**① 화면 밖 설정은 1개뿐이다.** `onboardingDone`(처음 실행 때 권한 안내를 마쳤는지)만 설정 창에서 바뀌지 않는다. 검색 색인에서 뺄 **명시 목록 = `onboardingDone` 하나.** 나머지 117개는 모두 설정 창의 어떤 줄에서 바뀐다. 캐시(`aiUsageCache` 등)는 `@Setting`이 아니라 대상이 아니다.

**② 죽은 설정은 0개.** 선언만 있고 어디서도 읽지 않는 키가 없다.

**③ 두 페이지에서 바뀌는 키 4개 — 모두 의도된 지름길이다.**

| 키 | 주 자리 | 지름길 | 방식 |
|---|---|---|---|
| `homeDisabled` | 홈 기능(순서·켜기) | 일정의 '홈에 페이지 표시' | `HomePageToggle` → `setHomeFeature` |
| `monitorContent` | 홈 기능 | 실시간 모니터링의 'AI 사용량'·'시스템 모니터링' | 같음 |
| `chatEnabled` | 홈 기능 | AI 채팅의 '홈에 AI 채팅 페이지' | 같음 |
| `trayMode` | 에어드랍·트레이 | 홈 기능의 트레이 줄(켜기·홈에서 가림·끄기) | 같은 값을 직접 |

→ 검색 색인은 **키 하나에 줄 하나가 아니다.** 색인 항목의 `id`는 `페이지.키`로 하고, 점검은 "모든 키가 **한 줄 이상**"으로 한다 (가이드라인 §10.2·§10.3 수정).

**④ '미리보기' 페이지는 설정을 바꾸지 않는다 — 가이드라인 §2.2-H의 의심은 틀렸다.** 네트워크·블루투스 등 5개 묶음의 '표시 형태' 고르기(`StylePreviewSection`)는 그 화면 안의 임시 값(`State`)만 바꾸고 저장하지 않는다. 그러나 **진짜 설정과 똑같이 생겨서** 바꿨다고 오해하기 쉽다. → 페이지는 합치지 않고 유지하되(§9-③ 결론), 그 고르기의 이름을 "미리 볼 형태"로 바꾸고 모양을 구분한다 (단계 3·4).

**⑤ 부품을 거치지 않고 바뀌는 설정 13개 (직접 쓴 `Picker` 11곳).**

| 키 | 페이지 | 줄 | 단계 3에서 바꿀 부품 |
|---|---|---|---|
| `notchDisplays` | 디스플레이 | 노치를 표시할 디스플레이 | 목록형 `MenuChoice` (연결된 화면에 따라 변함) |
| `displayContent` | 디스플레이 | 디스플레이마다의 상시 표시 | 같음 (줄 이름 = 화면 이름) |
| `cameraDevice` | 홈 기능 | 카메라 | 목록형 `MenuChoice` (기기 목록) |
| `lyricsSize` | 잠금화면 | 가사 글자 크기 | `SegmentedChoice` (선택지 enum으로) |
| `aiUsageService` | 실시간 모니터링 | AI 서비스 | 목록형 `MenuChoice` |
| `aiUsageSides` | 실시간 모니터링 | 왼쪽·오른쪽 (서비스별) | `MenuChoice` 한 쌍 (서로 배타) |
| `resourceLeft/Right`, `bothLeft/Right` | 실시간 모니터링 | 왼쪽·오른쪽 (지표) | `MenuChoice` 한 쌍 (6개 선택지) |
| `monitorExpand` | 실시간 모니터링 | 꾹 눌렀을 때 보일 내용 | `MenuChoice` (4개) |
| `chatService` | AI 채팅 | 서비스 | `SegmentedChoice` (3개, 짧음) |

그 밖에 **버튼으로 바뀌는 키**: `criticalAlertAdded/Removed`(디스플레이의 '기본값으로 되돌리기'), `chatModel*`(AI 채팅의 모델 목록), `chatInstructions`(AI 채팅의 지침 편집). 이 셋은 값 고르기가 아니라 동작이라 버튼이 맞다.

**⑥ 홈 기능 페이지의 트레이 줄**(`trayMode`, PrioritySettingsPage.swift:91)은 이름 없는 `Picker("")`다. 단계 4에서 줄 이름을 붙인다.

**⑦ 묶음 재정렬(단계 2) 때 페이지를 옮기는 키** — 나머지는 페이지와 함께 움직인다.

| 키 | 지금 | 제안 |
|---|---|---|
| `longPressDuration` `forceTouchEnabled` `hapticStrength` `hoverPreview` `hoverToOpen` | 일반 › 노치 조작 | 노치 › **노치 조작**(새 페이지) |
| `transientDuration` | 일반 › 일회성 알림 | 노치 조작 페이지의 '알림' 구역 (알림의 기본 동작이라 노치 쪽) |
| `cameraMirror` `cameraDevice` | 홈 기능 › 카메라 | 그대로 (홈 페이지의 한 항목) |

## 2. 페이지별 목록

### 일반 (`general`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `language` | 앱 | 언어 | MenuChoice | 3 | .system |  |
| `showStatusItem` | 앱 | 메뉴바 아이콘 표시 | Toggle |  | true |  |
| `autoUpdate` | 앱 | 자동 업데이트 (하루 한 번 확인) | Toggle |  | true |  |
| `memoryGuard` | 앱 | 메모리 자동 최적화 | Toggle |  | true |  |
| `memoryLimitMB` | 앱 | 최적화 기준 | ValueMenu |  | 70.0 |  |
| `longPressDuration` | 노치 조작 | 길게 누르기 시간 | ValueSlider |  | 0.35 |  |
| `forceTouchEnabled` | 노치 조작 | 깊게 누르기(포스 터치)로 바로 열기 | Toggle |  | true |  |
| `hapticStrength` | 노치 조작 | 햅틱 강도 | SegmentedChoice | 3 | .weak |  |
| `hoverPreview` | 노치 조작 | 호버하면 살짝 커지기 | Toggle |  | true |  |
| `hoverToOpen` | 노치 조작 | 호버만으로 열기 | Toggle |  | false |  |
| `transientDuration` | 일회성 알림 | 기본 표시 시간 | ValueMenu |  | 2.5 |  |
| `settingsBlur` | 설정 창 모양 | 배경 흐림 | ValueSlider |  | 1.0 |  |
| `settingsTransparency` | 설정 창 모양 | 투명도 | ValueSlider |  | 0.35 |  |

### 디스플레이 (`displays`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `notchDisplays` | 표시 | 노치를 표시할 디스플레이 | Picker |  | (read:) |  |
| `displayFallbackToMain` | 디스플레이별 상시 표시 | 선택한 항목이 비활성이면 주 디스플레이의 상시 표시를 대신 표시 | Toggle |  | true |  |
| `displayContent` | 디스플레이별 상시 표시 |  |  |  | [:] |  |
| `fullscreenCompact` | 전체 화면 | 전체 화면에서 알림·HUD를 컴팩트로 | Toggle |  | false |  |
| `alertScope` | 디스플레이별 알림 | 일회성 알림 범위 | MenuChoice | 2 | .main |  |
| `criticalAlertsEnabled` | 디스플레이별 알림 | 중요한 알림은 노치를 켠 모든 디스플레이에 표시 | Toggle |  | true |  |
| `criticalAlertAdded` | 디스플레이별 알림 | 기본값으로 되돌리기 | Button |  | [] |  |
| `criticalAlertRemoved` | 디스플레이별 알림 | 기본값으로 되돌리기 | Button |  | [] |  |

### 우선순위 (`priority`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `persistentOrder` | 상시 표시 우선순위 | 여러 항목이 동시에 진행 중이면 위에 있는 항목이 노치에 표시됩니다. 노치 위에서 두 손가락으로 위로 쓸면 숨기고, 아래로 쓸면 다시 나타납니다. | ReorderList |  | AppSettings.defaultPersist… |  |

### 홈 기능 (`home`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `homeOrder` | 홈 페이지 (노치를 길게 눌러 열기) | 위에서부터 홈 페이지 순서입니다. 끈 기능은 노치에서 사라지고 백그라운드에서도 동작하지 않습니다. 에어드랍·트레이의 '홈에서 가림'은 페이지만 숨기고 파일을 노치로 끌어오면 그대로 동작하며, '끄기'는 파일을 끌어와도 동작하지 않습니다. | ReorderList |  | AppSettings.defaultHomeOrder |  |
| `cameraMirror` | 카메라 | 좌우 반전(거울) | Toggle |  | true |  |
| `cameraDevice` | 카메라 | 카메라 | Picker |  | "" | 설정 창 밖에서도 씀: Features/Home/CameraAndCalendar.swift:81 |

### 네트워크 (`network`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `netWifiPower` | 표시 | Wi-Fi 켜짐·꺼짐 | Toggle |  | true |  |
| `netWifiConnection` | 표시 | Wi-Fi 연결·해제 | Toggle |  | true |  |
| `netVPN` | 표시 | VPN 연결·해제 | Toggle |  | true |  |
| `netHotspot` | 표시 | 핫스팟 연결·해제 | Toggle |  | true |  |
| `vpnPinned` | 상시 표시 | VPN 연결 중 (왼쪽 아이콘, 오른쪽 연결 국가) | Toggle |  | false |  |
| `hotspotPinned` | 상시 표시 | 핫스팟 연결 중 | Toggle |  | false |  |
| `netStyle` | 표시 방식 |  | AlertStylePicker | 2 | .compact |  |
| `netDuration` | 표시 방식 |  | AlertDurationMenu |  | 0.0 |  |
| `hotspotSSIDs` | 세부 설정 | 핫스팟으로 볼 Wi-Fi 이름 | ListField |  | "" |  |

### 블루투스 (`bluetooth`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `btEnabled` | 표시 | 액세서리가 연결되면 표시 | Toggle |  | true |  |
| `btStyle` | 표시 방식 | 배터리 표시는 컴팩트에 적용되고, 상세에서는 항상 백분율로 보입니다. | AlertStylePicker | 2 | .compact |  |
| `btBattery` | 표시 방식 | 배터리 표시 | SegmentedChoice | 3 | .percent |  |
| `btBlocklist` | 세부 설정 | 알림을 끌 기기 이름 | ListField |  | "" |  |

### 집중 모드 (`focus`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `focusEnabled` | 표시 | 집중 모드 켜짐·꺼짐 | Toggle |  | true |  |
| `focusPinned` | 상시 표시 | 집중 모드가 켜진 동안 | Toggle |  | false |  |
| `focusStyle` | 표시 방식 |  | AlertStylePicker | 2 | .compact |  |
| `focusDuration` | 표시 방식 |  | AlertDurationMenu |  | 0.0 |  |
| `focusExcluded` | 세부 설정 | 표시하지 않을 모드 이름 | ListField |  | "" |  |

### 통화 (`call`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `callEnabled` | 표시 | 수신 전화와 통화 표시 (iPhone 연속성, FaceTime 오디오) | Toggle |  | true |  |

### 미디어 (`media`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `mediaShowTrackChange` | 표시 | 곡이 바뀌면 잠깐 크게 표시 | Toggle |  | true |  |
| `mediaTrackChangeMusicOnly` | 표시 | Apple Music·Spotify에서만 | Toggle |  | true |  |
| `mediaHideAfterPause` | 표시 방식 | 일시정지 후 숨김 | ValueMenu |  | 30.0 |  |
| `mediaSource` | 세부 설정 | 재생 소스 | SegmentedChoice | 3 | .all |  |

### 다운로드 (`download`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `downloadEnabled` | 표시 | 다운로드 진행 표시 | Toggle |  | true |  |
| `downloadStyle` | 표시 방식 |  | ProgressStylePicker | 2 | .ring |  |
| `downloadFolder` | 세부 설정 | 다운로드 폴더 | FolderSetting |  | AppSettings.defaultDownloa… |  |
| `downloadFolders` | 세부 설정 | 추가로 감시할 폴더 경로 | ListField |  | "" |  |

### 에어드랍·트레이 (`airdrop`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `fileDragPage` |  |  |  | 2 | .tray |  |
| `trayMode` | 표시 | 에어드랍·트레이 | SegmentedChoice | 3 | .on | 다른 페이지에서도 바뀜: 홈 기능 |
| `airdropStyle` | 표시 방식 |  | ProgressStylePicker | 2 | .ring |  |
| `trayKeepCopies` | 세부 설정 | 트레이에 복사본 보관 (원본이 옮겨져도 유지) | Toggle |  | false |  |
| `trayCleanupMinutes` | 세부 설정 | 트레이 자동 정리 | ValueMenu |  | (read:) |  |
| `dragZoneHeight` | 세부 설정 | 드래그 감지 높이 | ValueSlider |  | 120.0 |  |

### 스크린샷 (`screenshot`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `screenshotEnabled` | 표시 | 스크린샷 미리보기 | Toggle |  | true |  |
| `screenshotAutoClose` | 표시 방식 | 자동 닫힘 | ValueMenu |  | 10.0 |  |
| `screenshotSource` | 세부 설정 | 감지 대상 | SegmentedChoice | 3 | .clipboard |  |
| `screenshotFolder` | 세부 설정 | 저장 폴더 | FolderSetting |  | "" |  |
| `screenshotJPEG` | 세부 설정 | JPEG로 저장 | Toggle |  | false |  |

### 화면 녹화 (`recording`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `recordingEnabled` | 표시 | 화면 녹화 표시 | Toggle |  | true |  |
| `recordingStyle` | 표시 방식 | 표시 형태 | SegmentedChoice | 2 | .persistent |  |
| `recordingFolder` | 세부 설정 | 저장 폴더 | FolderSetting |  | AppSettings.defaultRecordi… |  |

### 배터리 (`battery`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `batteryChargerAlert` | 표시 | 충전기 연결 | Toggle |  | true |  |
| `batteryFullAlert` | 표시 | 완충 | Toggle |  | true |  |
| `batteryLowAlert` | 표시 | 배터리 부족 | Toggle |  | true |  |
| `batteryLowThreshold` | 표시 | 부족 기준 | ValueSlider |  | 20.0 |  |
| `batteryChargingPinned` | 상시 표시 | 충전 중 (왼쪽 배터리 %, 오른쪽 완충까지 남은 시간) | Toggle |  | true |  |
| `batteryStyle` | 표시 방식 |  | AlertStylePicker | 2 | .compact |  |

### HUD (`hud`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `hudVolume` | 표시 | 음량 | Toggle |  | true |  |
| `hudDisplay` | 표시 | 화면 밝기 | Toggle |  | true |  |
| `hudKeyboard` | 표시 | 키보드 밝기 | Toggle |  | true |  |
| `hudDesign` | 표시 방식 | 디자인 | SegmentedChoice | 2 | .notch |  |
| `hudLiquidValue` | 표시 방식 | 수치 표시 | SegmentedChoice | 2 | .bar |  |
| `hudLiquidBrightness` | 표시 방식 | 명도 | ValueSlider |  | 0.5 |  |
| `hudLiquidClearness` | 표시 방식 | 투명도 | ValueSlider |  | 0.4 |  |
| `hudStyle` | 표시 방식 | 수치 표시 | SegmentedChoice | 3 | .bar |  |
| `hudBrightnessUnit` | 표시 방식 | 화면 밝기 단위 | SegmentedChoice | 2 | .percent |  |
| `hudDuration` | 표시 방식 | 표시 시간 | ValueMenu |  | 1.5 |  |
| `hudOutputIcon` | 세부 설정 | 음량 HUD에 출력 기기 아이콘 표시 | Toggle |  | true |  |
| `hudDisplayExternal` | 세부 설정 | 제어 센터에서 바꾼 화면 밝기도 표시 | Toggle |  | true |  |
| `hudKeyboardExternal` | 세부 설정 | 제어 센터에서 바꾼 키보드 밝기도 표시 | Toggle |  | true |  |

### 잠금화면 (`lock`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `lockNotchEnabled` | 표시 | 잠기면 자물쇠, 풀리면 열림 애니메이션 | Toggle |  | true |  |
| `lockMediaWidget` | 표시 | 음악 재생 중 잠금화면 미디어 위젯 | Toggle |  | true |  |
| `lockHideTrackInfo` | 표시 방식 | 잠금화면에서 곡 정보 숨기기 | Toggle |  | false |  |
| `lyricsEnabled` | 가사 | 전체화면에서 가사 표시 (Apple Music) | Toggle |  | true |  |
| `lyricsOnline` | 가사 | 실시간(시간 동기) 가사 가져오기 | Toggle |  | false | 설정 창 밖에서도 씀: Features/LockScreen/LockMediaViews.swift:205 |
| `lyricsSize` | 가사 | 가사 글자 크기 | Picker |  | 1 |  |

### 일정 (`calendar`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `homeDisabled` | 표시 | 홈에 오늘 일정 페이지 표시 | HomePageToggle |  | [] | 다른 페이지에서도 바뀜: 홈 기능; `HomePageToggle(calendar)` 거침 |
| `calendarAlertMinutes` | 표시 | 일정 알림 | ValueMenu |  | 10.0 |  |
| `calendarPinned` | 상시 표시 | 다음 일정 (시작 시각, 진행 중이면 끝나는 시각) | Toggle |  | false |  |

### 실시간 모니터링 (`aiUsage`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `monitorContent` | 표시 | AI 사용량 | HomePageToggle | 3 | .ai | 다른 페이지에서도 바뀜: 홈 기능; `HomePageToggle(usage)` 거침 |
| `aiUsagePinned` | 상시 표시 | 노치에 상시 표시 | Toggle |  | false |  |
| `aiUsageService` | 상시 표시 | AI 서비스 | Picker |  | "claude" |  |
| `aiUsageStyle` | 표시 방식 | 표시 형태 | SegmentedChoice | 2 | .text |  |
| `aiRefreshMinutes` | 세부 설정 | AI 사용량 새로고침 | ValueMenu |  | 5.0 |  |
| `resourceRefreshSeconds` | 세부 설정 | 시스템 모니터링 새로고침 | ValueMenu |  | 2.0 |  |
| `resourceLeft` | 세부 설정 |  | Picker | 6 | .cpu | `setMonitorSlot` 거침 |
| `resourceRight` | 세부 설정 |  | Picker | 6 | .mem | `setMonitorSlot` 거침 |
| `bothLeft` | 세부 설정 |  | Picker | 6 | .aiPrimary | `setMonitorSlot` 거침 |
| `bothRight` | 세부 설정 |  | Picker | 6 | .cpu | `setMonitorSlot` 거침 |
| `aiUsageSides` | 세부 설정 |  | Picker |  | [:] | `setAISide` 거침 |
| `monitorExpand` | 세부 설정 | 꾹 눌렀을 때 보일 내용 | Picker | 4 | .follow |  |
| `aiConnected` | 세부 설정 |  |  |  | "" | 설정 창 밖에서도 씀: Features/Usage/UsageWeb.swift:445 |

### AI 채팅 (`chat`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `chatEnabled` | 표시 | 홈에 AI 채팅 페이지 표시 | HomePageToggle |  | false | 다른 페이지에서도 바뀜: 홈 기능; `HomePageToggle(chat)` 거침 |
| `chatReopen` | 표시 | 다시 열 때 보여 줄 화면 | SegmentedChoice | 2 | .lastAnswer |  |
| `chatService` | 표시 | 서비스 | Picker | 3 | .claude |  |
| `chatWebSearch` | 답변 | 필요할 때만 웹 검색 (최근 소식, 확실하지 않은 내용) | Toggle |  | true |  |
| `chatModelClaude` | 기타 |  | Button |  | "" | `setChatModel` 거침 |
| `chatModelOpenAI` | 기타 |  | Button |  | "" | `setChatModel` 거침 |
| `chatModelGemini` | 기타 |  | Button |  | "" | `setChatModel` 거침 |
| `chatInstructions` | 기타 |  |  |  | "", notifiesMainApp: false |  |

### Claude Code · Codex (`agent`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `agentAlerts` | 표시 | 작업이 끝나면 알림 (누르면 그 앱 열기) | Toggle |  | true |  |
| `agentStyle` | 표시 방식 |  | AlertStylePicker | 2 | .compact |  |

### (화면 밖) (`(화면 밖)`)

| 키 | 구역 | 줄 이름 | 부품 | 선택지 | 기본값 | 비고 |
|---|---|---|---|---|---|---|
| `onboardingDone` |  |  |  |  | false | 설정 창 밖에서도 씀: Permissions/PermissionsView.swift:145; 내부 상태 |

## 3. 구역 설명 (긴 순서)

| 글자 수 | 위치 | 구역 | 앞부분 |
|---|---|---|---|
| 250 | AgentSettingsPage.swift:20 | 연결 | 연결하면 Claude Code는 ~/.claude/settings.jso… |
| 176 | ChatSettingsPage.swift:119 | 답변 | 웹 검색은 각 서비스의 검색 도구를 쓰며 별도 요금이 붙을 수 있습니다.… |
| 156 | ActivityFeaturePages.swift:73 | 세부 설정 | 자동 정리는 트레이에 넣은 지 그 시간이 지난 항목을 목록에서 뺍니다. … |
| 145 | MonitoringSettingsPage.swift:42 | 세부 설정 | AI 사용량은 각 서비스 웹사이트에 로그인해 읽습니다. 로그인 정보는 이… |
| 132 | PrioritySettingsPage.swift:62 | 홈 페이지 (노치를 길게 눌러 열기) | 위에서부터 홈 페이지 순서입니다. 끈 기능은 노치에서 사라지고 백그라운드… |
| 128 | ChatSettingsPage.swift:37 | 표시 | 입력한 질문, 최근 대화, 직접 첨부한 파일이 아래에서 고른 회사로 전송… |
| 123 | AlertFeaturePages.swift:18 | 상시 표시 | VPN 상시 표시를 켜면 연결된 국가를 알기 위해, VPN이 연결된 동안… |
| 121 | DisplaysSettingsPage.swift:111 | 전체 화면 | 전체 화면 앱이 떠 있는 디스플레이에서만 상세 알림과 HUD(Liquid… |
| 118 | ActivityFeaturePages.swift:151 | 표시 방식 | 위젯은 프로필 사진·암호 입력란 바로 위에 표시됩니다. 앨범아트를 누르면… |
| 113 | DisplaysSettingsPage.swift:55 | 디스플레이별 상시 표시 | 선택한 항목이 비활성일 때 대신 표시하지 않으면 기본 노치만 뜹니다. '… |
| 101 | AlertFeaturePages.swift:114 | 상시 표시 | 완충됐거나, 충전 한도·배터리 최적화로 충전이 멈춰 전원 어댑터로만 동작… |
| 98 | ActivityFeaturePages.swift:64 | 표시 | 에어드랍·트레이와 AI 채팅이 모두 켜져 있으면, 파일을 든 채 노치 옆… |
| 96 | AgentSettingsPage.swift:15 | 표시 방식 | 상세는 '에이전트 · 프로젝트'와 함께 끝난 작업(마지막으로 보낸 요청)… |
| 95 | AlertFeaturePages.swift:27 | 세부 설정 | 핫스팟은 '데이터 절약 네트워크' 여부로 추정합니다. 잘 안 잡히면 iP… |
| 94 | ChatSettingsPage.swift:134 | 저장된 대화 | 대화와 첨부 파일은 메모처럼 이 Mac에 암호화 없이 저장되며, 노치의 … |
| 88 | ActivityFeaturePages.swift:155 | 가사 | 실시간 가사는 곡 제목·아티스트·앨범을 외부 가사 서비스 LRCLIB(l… |
| 83 | PreviewSettingsPage.swift:17 | 미디어 | 테스트 곡이 노치에 재생됩니다. 길게 눌러 플레이어를 열고 재생·다음·이… |
| 81 | PrioritySettingsPage.swift:10 | 상시 표시 우선순위 | 여러 항목이 동시에 진행 중이면 위에 있는 항목이 노치에 표시됩니다. 노… |
| 74 | AlertFeaturePages.swift:171 | 세부 설정 | 자동 밝기로 바뀐 값은 표시하지 않습니다. 니트는 내장 디스플레이의 현재… |
| 66 | AlertFeaturePages.swift:90 | 표시 | 수신 전화는 상세 카드(받기·거절), 통화 중에는 노치 양옆에 경과 시간… |
| 62 | AlertFeaturePages.swift:76 | 세부 설정 | 모드 이름·아이콘은 전체 디스크 접근 권한이 있을 때만 표시됩니다. 없으… |
| 62 | DisplaysSettingsPage.swift:119 | 디스플레이별 알림 | 중요한 알림은 일회성 알림 범위와 상시 표시 선택보다 우선합니다. '노치… |
| 54 | MonitoringSettingsPage.swift:14 | 표시 | 홈 기능의 스위치와 같은 설정입니다. 끄면 그 기능은 노치에서 사라지고 … |
| 42 | GeneralSettingsPage.swift:41 | 일회성 알림 | 기능별 페이지에서 표시 시간을 '일반 설정 따름'으로 둔 알림에 적용됩니… |
| 42 | GeneralSettingsPage.swift:46 | 설정 창 모양 | 흐림을 낮추면 뒤 화면이 또렷하게, 투명도를 높이면 더 많이 비쳐 보입니… |
| 38 | AlertFeaturePages.swift:46 | 표시 방식 | 배터리 표시는 컴팩트에 적용되고, 상세에서는 항상 백분율로 보입니다.… |
| 36 | GeneralSettingsPage.swift:12 | 앱 | 메모리가 최적화 기준을 넘으면 쉬는 동안 조용히 다시 시작합니다.… |
| 33 | ActivityFeaturePages.swift:128 | 표시 방식 | 계속 표시는 녹화하는 동안 노치에 녹화 시간을 보여 줍니다.… |
| 32 | GeneralSettingsPage.swift:32 | 노치 조작 | 마우스는 압력을 알려 주지 않아 길게 누르기만 동작합니다.… |
| 19 | ActivityFeaturePages.swift:182 | 표시 | 끄면 일정 감시와 알림도 멈춥니다.… |
