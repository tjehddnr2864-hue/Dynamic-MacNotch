# 코드 구조 안내

기능을 추가하거나 고칠 때 어디를 봐야 하는지 정리한 문서입니다. 동작의 세부 결정은 `CHAT_GUIDELINE.md`, `CHAT_ATTACH_GUIDELINE.md`, `DISPLAY_GUIDELINE.md`에 있습니다. 구현 전 설계 문서: `RESOURCE_GUIDELINE.md`(실시간 모니터링: AI + 자원 사용량).

## 프로세스

| 프로세스 | 하는 일 | 시작 |
|---|---|---|
| 본 앱 | 노치, 감시, 기능 전부 | `App/main.swift` → `AppDelegate` |
| 설정·권한 창 | `--helper=settings` 도우미. 창을 닫으면 프로세스째 메모리가 반환된다 | `App/HelperApp.swift` |
| AI 사용량 조회, 파일 선택 창 | 쓰고 끝나는 도우미 | `App/main.swift` |

설정 창이 값을 바꾸면 `AppSettings`가 저장하고 분산 알림을 보내고, 본 앱이 `reload()`로 다시 읽습니다. 미리보기와 다시 시작은 `Helper.sendToMain`으로 보냅니다. 배포 빌드의 본 앱은 `AppDelegate.listenToHelper`에 있는 명령만 받습니다.

## 폴더

```
App/        시작, 조립, 메뉴, 업데이트, 메모리 지킴이
  AppDelegate.swift              기능 객체를 만들고 연결한다
  AppDelegate+NotchActions.swift 길게 누르기, 짧은 클릭
  AppDelegate+Menu.swift         메뉴바 아이콘, 우클릭 메뉴
  AppDelegate+Dev.swift          scripts/notchctl 명령 (개발 빌드만)
Activity/   알림 모델과 큐 (ActivityCenter), 알림 뷰
Monitors/   시스템 상태 감시 (네트워크, 배터리, 블루투스, 집중 모드, 통화, 다운로드, 녹화, HUD)
Features/   기능별 코드 (Home, Timer, Media, Tray, Memo, Chat, Usage, LockScreen, Screenshot, Agent, Preview)
Notch/      노치 창과 상태
Permissions/ 권한 관리
Settings/   설정 값과 설정 창
```

## 노치

```
NotchHub (1개)
├─ SharedNotchState     디스플레이끼리 같아야 하는 값 (마지막 홈 페이지, 채팅 크기, 처리기)
└─ DisplayNotch (디스플레이마다, UUID로 구분)   패널, 이벤트
   └─ DisplayNotchState (변수 이름은 vm)       크기, 상태, 이 디스플레이에 보일 항목
```

- 알림 큐 `ActivityCenter`와 기능 저장소는 앱에 하나씩 있습니다. 무엇을 어느 디스플레이에 보일지는 `DisplayRules`(순수 계산)가 정하고, `DisplayNotchState.displayed`가 그 결과를 씁니다.
- 앱의 나머지 부분은 패널을 직접 만지지 않고 `NotchHub`를 거칩니다.
- 규칙을 바꾸면 개발 빌드의 `--display-probe`로 전체 조합을 확인합니다.

## 자주 하는 작업

### 설정 하나 추가

`Settings/AppSettings.swift`에 한 줄이면 저장, 다시 읽기, 변경 알림까지 됩니다.

```swift
@Setting("btEnabled", default: true) var btEnabled: Bool
@Setting("btStyle", default: AlertStyle.compact) var btStyle: AlertStyle   // String enum
@Setting("memoryLimitMB", default: 70.0, sanitize: { min(150, max(70, $0)) }) var memoryLimitMB: Double
```

선택지 enum은 `Settings/SettingTypes.swift`에 두고 `SettingOption`을 붙입니다(`SettingsComponents.swift`). rawValue와 키는 저장값이므로 바꾸지 않습니다. 변화를 지켜볼 때는 `settings.$btEnabled`를 씁니다. @Published와 같이 현재 값으로 시작하고, 알림을 받는 시점에 `settings.btEnabled`는 아직 이전 값입니다.

### 설정 페이지 추가

1. `Settings/SettingsPage.swift`: case, `title`, `symbol`, `top` 또는 `features` 목록
2. `Settings/Pages/`에 페이지 View
3. `Settings/SettingsView.swift`의 `content`

### 상시 표시 항목 추가

1. `ActivityKind`에 case
2. `AppSettings.defaultPersistentOrder`에 이름
3. `Activity/LiveActivityInfo.swift`: 이름, 아이콘, 꺼진 조건
4. 기능 코드에서 `center.setPersistent(...)`

### 실시간 모니터링 (AI 사용량 + 자원 사용량)

설계와 측정은 `RESOURCE_GUIDELINE.md`. 코드 위치:

- `Features/Monitor/MonitorLayout.swift`: 표시할 항목·칸·홈 기능 연동 규칙 (순수, `--monitor-probe`)
- `Features/Monitor/MonitorActivity.swift`: 활동 조립과 게시(`MonitorCoordinator`)
- `Monitors/ResourceSampler.swift`: 수요가 있는 지표만 타이머 하나로 읽기. 값은 `ResourceReadings`, 칸은 `LiveMetricView`
- `Notch/NotchHub.swift`의 `updateResourceDemand`: 디스플레이마다 보이는 칸·확장 화면으로 수요 계산
- `Notch/DisplayRules.swift`의 `monitorMapped`: 둘 다면 통합, 해제하면 원래 선택

자원 값은 활동(`NotchActivity`)에 넣지 않는다. 매 틱 활동이 바뀌면 노치 전체가 다시 그려져 CPU가 약 10배가 된다.

### 미리보기 추가

`Features/Preview/FeaturePreview.swift`의 `PreviewID`, `layout`, 실행 코드. 설정 화면에서는 `PreviewSection([(.id, "이름")])`으로 씁니다.

## 설정 화면 규칙

**기능 페이지 구역 순서:** 표시 → 상시 표시 → 표시 방식 → 세부 설정 → 미리보기. 없는 구역은 뺍니다. 이름은 `SectionTitle`을 씁니다.

**고르는 방법**

| 값 | 부품 |
|---|---|
| 켜기·끄기 | `Toggle` |
| 종류 2~3개, 글이 짧음 | `SegmentedChoice` |
| 종류가 많거나 글이 긺 | `MenuChoice` |
| 시간·개수 같은 정해진 값 | `ValueMenu` (0 값은 `zero`: 끄기, 일반 설정 따름) |
| 연속된 값 | `ValueSlider` |
| 쉼표 목록 | `ListField` |
| 폴더 | `FolderSetting` |

**꺼졌을 때:** 주 스위치가 꺼지면 거기에 딸린 구역은 `SettingsSection(disabled:)`로 비활성화합니다. 위 항목에 딸린 한 줄은 `Indented`로 들여 씁니다.

**옵션의 자리:** 앱 전체에 적용되는 것만 일반에 둡니다. 한 기능에 속하는 옵션은 그 기능 페이지에 둡니다.

**용어**

| 한국어 | English | 쓰지 않는 말 |
|---|---|---|
| 일회성 알림 | Alert | |
| 상시 표시 | Live Activity | Live Display, Keep showing |
| 컴팩트 / 상세 | Compact / Detailed | |
| 표시 시간 | Duration | |
| 집중 모드 | Focus | 방해금지 모드 (macOS의 모드 이름일 때만 사용) |
| 통화 | Calls | 전화 (수신 전화는 그대로) |
| 미디어 | Media | 음악 (곡 자체를 말할 때는 사용) |
| 에어드랍·트레이 | AirDrop & Tray | 에어드랍 및 파일 트레이 |
| 일정 | Calendar | Events |
| 홈 / 홈 기능 | Home / Home Features | 기본, 기본 노치 |
| 주 디스플레이 | Main Display | |
| 길게 누르기, 깊게 누르기 | Long-press, Force Click | 길게누르기 |
| 끄기 | Off | |
| 실시간 모니터링 | Live Monitoring | 설정 페이지 이름 (AI 사용량 + 자원 사용량) |
| 자원 사용량 | Resource Usage | CPU·GPU·메모리·네트워크 |
| 표시할 항목 | Show | AI 사용량 / 자원 사용량 / 둘 다 |

**영어 표기:** 구역 제목과 버튼은 Title Case, 줄 이름은 첫 글자만 대문자로 씁니다.

## 개발 빌드와 시험

```bash
scripts/build.sh --dev
```

- `scripts/notchctl <명령>`: 노치를 조작합니다. 명령은 `App/AppDelegate+Dev.swift`에 있습니다.
- `--display-probe`, `--settings-probe`: 표시 규칙과 설정 저장을 확인합니다.
- `DMN_SETTINGS_PAGE=<페이지>`, `DMN_SETTINGS_HEIGHT=<높이>`: `--helper=settings`와 함께 쓰면 그 페이지를 화면 밖에 키워 띄웁니다. `screencapture -l`로 페이지 전체를 확인할 수 있습니다.
- `DMN_CHAT_FOLDER`: 시험할 때 실제 채팅이 아닌 폴더를 쓰게 합니다.

배포 전에는 배포용 빌드로 자원 시험(메모리, CPU, 누수)을 돌려 결과를 릴리즈 노트에 적습니다.
