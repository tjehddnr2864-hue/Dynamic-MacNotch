# 전체 점검 가이드라인 (코드 정리 · 오류 · 누수 · 불필요한 동작 · 목표 대조)

버전 1.4.2 (`main` 40c33fb) 기준. 이 문서는 **점검을 어떻게 할지 정한 계획서**다. 이 문서를 쓰는 동안 코드는 바뀌지 않았다. 점검 실행(시험과 정리)은 단계마다 Fable이 하고, 이 문서의 합격 기준으로 판정한다.

구분: **[확인]** = 이 문서를 쓰며 명령으로 확인한 사실, **[의심]** = 근거는 있으나 실행으로 확인 못 함, **[미확인]** = 아직 보지 않음. 점검자는 [의심]과 [미확인]을 먼저 사실로 바꾼 뒤 고친다.

---

## 0. 결론

1. 코드는 Swift 23,423줄(`Sources/`). 자동 시험 대상(`Tests/`)은 **없다** [확인: `Tests` 폴더와 `Package.swift`의 `testTarget` 모두 없음]. 자동 점검은 개발 빌드의 **probe 5종**뿐이다 (§2.3). 그래서 이 점검은 "probe 통과 + 측정 + 읽기" 세 가지로 한다.
2. 점검은 **9단계**, 위험이 낮은 것부터 한다. 앞 단계(0~3)는 읽기와 측정뿐이고 코드를 바꾸지 않는다. 코드를 바꾸는 단계(4~7)는 단계마다 커밋 하나, 빌드와 probe가 통과해야 다음으로 간다.
3. 이번 조사에서 **죽은 코드는 거의 나오지 않았다** [확인]: 설정 키 110개 중 사용처가 없는 것 0개(바깥에서 안 보이는 7개는 `AppSettings.swift` 안에서 쓰임), 한 번만 정의되고 어디서도 안 불리는 함수는 14개인데 모두 시스템이 부르는 콜백이다. 즉 "지울 것"보다 **"멈춰야 하는 것이 멈추는지"**, **"수명 정리"**, **"큰 파일 분리"**가 이 점검의 중심이다.
4. 제일 먼저 볼 [의심]은 §3에 모았다. 특히 ① 항상 도는 타이머(Mission Control 안전 점검, 메모리 지킴이, 업데이트), ② 정리 없이 등록된 관찰자 9개 파일, ③ 숨겨졌을 때 감시기가 멈추는지(8개 감시기 파일에 숨김 신호 참조가 0개).

| 단계 | 이름 | 코드 변경 | 위험 | 예상 효과 |
|---|---|---|---|---|
| 0 | 기준선 측정 | 없음 | 없음 | 이후 모든 비교의 기준 |
| 1 | 정적 점검 (죽은 코드·중복·주석·로그) | 없음(목록만) | 없음 | 지울 후보 확정 |
| 2 | 설정 저장소 점검 | 없음(목록만) | 없음 | 설정 오류·키 충돌 발견 |
| 3 | 수명·누수·불필요한 동작 | 없음(측정만) | 없음 | 가장 큰 이득이 나올 단계 |
| 4 | 안전한 삭제 | 있음 | 낮음 | 코드 감소 |
| 5 | 수명 정리 수정 | 있음 | 중간 | 누수·불필요한 깨어남 제거 |
| 6 | 기능별 목표 대조 | 있음(버그 수정) | 중간 | 문서와 동작 일치 |
| 7 | 구조 정리·분리 | 있음 | 높음 | 이후 기능 추가가 쉬워짐 |
| 8 | 다중 디스플레이·실제 입력 | 없음 | 없음 | 자동으로 못 보는 것 확인 |
| 9 | 배포 전 검증 | 없음 | 없음 | 1.4.3 배포 근거 |

---

## 1. 지켜야 할 규칙 (모든 단계 공통)

### 1.1 시험 안전

| 규칙 | 이유 |
|---|---|
| 사용자의 실제 설정(`defaults`)을 바꾸는 시험은 **키마다 따로 변수에 저장**하고, 끝나면 **키마다 읽어서 확인** | 2026-11-09, 복원 실패로 사용자 설정 5개가 깨진 적이 있음 |
| macOS `bash`는 3.2: `declare -A` 없음. 스크립트는 `bash script.sh`로 실행 | 연상 배열이 없어 모든 키가 한 칸에 겹침 |
| `defaults read`는 불리언을 `1/0`으로 주고 `defaults write -bool`은 `true/false`만 받음. 복원 전에 변환 | 1.4.2 시험 중 상시 표시 스위치가 꺼진 채 남음 |
| 배열 값은 `plistlib.loads(sys.stdin.buffer.read())` | `plistlib.load`는 파이프에서 실패 |
| 개발 앱을 백그라운드로 띄웠으면 **맨 `wait` 금지**, PID를 지정. INT/TERM/HUP 트랩 | 세션이 죽으면 트랩이 안 돌아 앱이 꺼진 채로 남음 |
| 결과는 파이프 말고 **파일에 바로** 기록 | 중단되어도 출력이 남음 |
| 사용자의 실제 채팅·메모는 건드리지 않음. 채팅 시험은 `DMN_CHAT_FOLDER`로 시험 폴더 사용 | 사용자 데이터 보호 |
| 화면을 덮는 시험, 클립보드 덮어쓰기, 키체인·자격증명 읽기 금지 | 사용자 환경 보호 |
| 실패한 빌드 뒤에 probe를 실행하지 않음 | 배포 빌드는 인자를 무시하고 앱이 하나 더 뜸 |
| 시험이 끝나면 `defaults read`로 `monitorContent`, `aiUsagePinned`, `homeOrder`, `homeDisabled`, `homeOptionKey`, `persistentOrder`를 시작 전 값과 대조 | 이번 세션에서 실제로 바뀌었던 키들 |

### 1.2 코드 변경 규칙

- 단계 하나 = 커밋 하나. 커밋 전에 `scripts/build.sh --dev`가 **경고 0건**으로 끝나고 §2.3의 probe 전부 실패 0건이어야 한다.
- 설정 키 이름과 `rawValue`는 바꾸지 않는다 (`CLAUDE.md`). 지우는 것은 "읽는 곳이 없는 키"뿐이고, 저장된 값은 그대로 둔다.
- 사용자에게 보이는 글은 `T("한국어","English")`. 용어는 `docs/ARCHITECTURE.md`의 표를 따른다.
- `main`과 공개 저장소에는 CLI 호출·구독 자격증명 코드를 두지 않는다. `local-cli`는 푸시하지 않는다. (OAuth Session / Cookie Scraping 코드 금지, CLI 바이너리 호출 방식만 — 개인 빌드에만 해당.)
- 점검은 `main`에서 작업 브랜치를 따서 하고, 끝나면 `local-cli`에 `main`을 합친다.
- 배포는 사용자가 요청할 때만. 배포 전 자원 시험 결과를 영·한 릴리즈 노트에 넣는다. 번호는 `CLAUDE.md` 규칙(지정 없으면 +0.0.1).

### 1.3 하지 말 것

- 동작을 바꾸는 "정리". 정리 커밋은 동작이 같아야 하고, 같음을 probe와 측정으로 보인다.
- 추측으로 지우기. 호출처를 `grep -rnw`로 확인하고도 남는 의심(KVO, `#selector`, 문자열 키, SwiftUI 바인딩)은 지우지 않고 목록에 남긴다.
- 한 커밋에 여러 단계 섞기.

---

## 2. 현황 [확인]

### 2.1 규모

| 폴더 (`Sources/DynamicMacNotch/`) | 파일 | 줄 |
|---|---|---|
| Activity | 5 | 1,019 |
| App | 11 | 1,461 |
| Monitors | 9 | 3,402 |
| Notch | 13 | 2,528 |
| Permissions | 2 | 628 |
| Settings (+ Pages) | 9 | 1,467 |
| Features/Agent | 1 | 319 |
| Features/Call | 1 | 139 |
| Features/Chat | 10 | 3,870 |
| Features/Home | 3 | 806 |
| Features/LockScreen | 4 | 903 |
| Features/Media | 3 | 1,489 |
| Features/Memo | 2 | 592 |
| Features/Monitor | 3 | 524 |
| Features/Preview | 1 | 368 |
| Features/Screenshot | 2 | 454 |
| Features/Timer | 1 | 237 |
| Features/Tray | 4 | 1,011 |
| Features/Usage | 3 | 915 |
| 합계 | | 23,423 |

표의 줄 수는 폴더 바로 아래 파일만 센 값이라 `Settings/Pages/` 아래 파일은 위 합계에 일부만 들어 있을 수 있다. 정확한 값은 단계 0에서 `find Sources -name '*.swift' | xargs wc -l`로 다시 잰다.

큰 파일 (분리 후보, 단계 7): `Chat/MathTypesetter.swift` 799, `Notch/DisplayNotchState.swift` 688, `Media/MediaController.swift` 684, `Chat/ChatStore.swift` 661, `Chat/ChatPage.swift` 566, `Chat/ChatMarkdown.swift` 538, `Activity/ActivityViews.swift` 507, `Monitors/CallMonitor.swift` 494, `Notch/DisplayNotch.swift` 490.

### 2.2 구조

- 설정은 `@Setting` 110개 (`Settings/AppSettings.swift`). 변경은 분산 알림 `com.dynamicmacnotch.app.settingsChanged`로 설정 창(도우미 프로세스)과 본 앱이 주고받는다.
- 감시기 8개(`Monitors/`: Battery, Bluetooth, Call, Download, Focus, HUD, Network, Recording)와 자원 측정(`ResourceSampler`)이 있다. `AppDelegate`가 시작 때 **모두 `start()`** 한다 (`App/AppDelegate.swift:58~150`). 각 감시기가 안에서 자기 설정을 보고 동작 여부를 정한다.
- 자원 측정만은 `NotchHub.updateResourceDemand`가 "보이는 것만" 읽도록 수요를 계산한다. 다른 감시기는 이런 수요 계산이 없다.
- 외부 프로세스를 띄우는 곳 15곳 (`Process()` 13곳 + `openApplication` 2곳): Bluetooth 2, Updater 2, AppDelegate 1, AppDelegate+Menu 1, ImageTool 1, ChatAttachment 1, AIUsage 1, AgentNotify 1(+`openApplication`), FilePicker 1, MediaController 1(+`openApplication`), PermissionsManager 1.
- `#if DEV` 블록 35개. 가장 많은 파일: HelperApp 4, NetworkMonitor 3, AppDelegate 3.

### 2.3 점검 도구

| 도구 | 실행 (개발 빌드 `scripts/build.sh --dev` 후) | 확인하는 것 | 이전 결과 |
|---|---|---|---|
| `--display-probe` | `build/Dynamic\ MacNotch.app/Contents/MacOS/DynamicMacNotch --display-probe` | 디스플레이별 표시 규칙 전체 조합 | 6,257건 통과 (1.4.2) |
| `--settings-probe` | 위와 같은 방식 | 설정 저장·복원·연동 | 17건 통과 |
| `--monitor-probe` | | 실시간 모니터링 규칙 | 386건 통과 |
| `--tray-probe` | | 트레이 선택 규칙 | 30건 통과 (1.4.1) |
| `--chat-probe=<서비스>:<명령>:<값>` | | 채팅 서비스·키체인·첨부 (`Chat/ChatProbe.swift`) | 단계 6에서 사용법 확인 |
| `scripts/notchctl <명령>` | `home`, `collapse`, `media`, `settings`, `lock`, `hide`, `monitorstate`, `displaystate`, `mcstate`, `traystate` 등 35개 이상 (`App/AppDelegate+Dev.swift`) | 노치를 사람 없이 조작·상태 기록 | |
| `scripts/resource-bench.swift` | 직접 컴파일 | 자원 읽기 비용 | |

주의: probe는 사용자의 실제 설정 파일을 읽는다. 실행 전후 §1.1 점검을 한다.

### 2.4 타이머 목록 (등록 위치)

| 타이머 | 주기 | 위치 | 언제 도나 |
|---|---|---|---|
| Mission Control 안전 점검 | 3초(이벤트 신뢰 시) / 0.5초(아닐 때) | `Notch/MissionControlMonitor.swift:20-21,115` | **항상** [확인: 등록은 항상, 실제 정지 조건은 단계 3에서 측정] |
| Mission Control 빠른 점검 | 0.1초 | 같은 파일 `:19,102` | 이벤트 직후 1.2초, 열려 있는 동안 |
| 메모리 지킴이 | 300초 (+ 쉬는 순간 대기 20초, 최대 30분) | `App/MemoryGuard.swift:35,77` | 항상 |
| 업데이트 확인 | 3600초 | `App/Updater.swift:27` | 항상(자동 업데이트 꺼짐이면 [미확인]) |
| 통화 | 1초 | `Monitors/CallMonitor.swift:304` | 통화 중에만 [확인: 코드 `:296-309`] |
| 다운로드 | 0.5초 | `Monitors/DownloadMonitor.swift:243` | 진행 중인 항목이 있을 때만 [확인] |
| 스크린샷 클립보드 감시 | 0.5초 | `Features/Screenshot/ScreenshotMonitor.swift:56` | 해당 기능이 켜졌을 때(`updatePasteboardWatch`) [확인] |
| 집중 모드 | 5초 | `Monitors/FocusMonitor.swift:32` | DB 폴더를 못 읽을 때의 대체 수단만 [확인] |
| 블루투스·HUD 재시도 | 3초 | `BluetoothMonitor.swift:55`, `HUDMonitor.swift:34` | 권한이 허용될 때까지만 [확인] |
| 녹화 | 가변 | `Monitors/RecordingMonitor.swift:44` | [미확인] |
| 네트워크 국가 조회 | `countryPollInterval` | `Monitors/NetworkMonitor.swift:100` | VPN 국가 표시가 켜졌을 때 [미확인] |
| 자원 측정 | 1/2/5/10초 | `Monitors/ResourceSampler.swift:130` | 보이는 칸이 있을 때만 [확인: 수요 계산] |
| AI 사용량 새로고침 | 1/2/5/10분 | `Features/Usage/AIUsage.swift:211` | 상시 표시가 켜졌을 때 [미확인: 조건 전부] |
| 타이머 기능 | 0.25초 | `Features/Timer/TimerController.swift:167` | 타이머가 돌 때만 [미확인] |
| 미디어 시험 | 5초 | `MediaController.swift:597` | 시험 모드만 |
| 권한 상태 | 1초 | `Permissions/PermissionsManager.swift:158` | 권한 창이 열려 있을 때만 [의심: 닫힐 때 `invalidate` 확인] |
| 로그인 확인 | 1초 | `Usage/UsageWeb.swift:373` | 로그인 창이 열려 있을 때만 [의심] |
| 도우미 HUD 상태 | 1초 | `App/HelperApp.swift:30` | 설정 창(도우미)이 열려 있는 동안 |
| 자동 닫기 | 가변 | `Media/OutputRoute.swift:328` | 메뉴가 열려 있을 때 |

---

## 3. 먼저 확인할 의심 지점

| # | 의심 | 근거 | 확인 방법 | 단계 |
|---|---|---|---|---|
| S1 | 숨겨져도 감시기가 돈다 | 감시기 8개 파일에 숨김 신호(`persistentHidden`, `panelsHidden`, 잠자기, 잠금) 참조가 **0개**. 숨김 신호를 쓰는 곳은 `ActivityCenter`, `LockScreenManager`, `DisplayNotch`, `NotchHub`뿐 | 감시기마다 "노치 숨김·Mission Control·화면 잠금·잠자기" 상태에서 깨어남 수를 §3.2 방법으로 잼 | 3 |
| S2 | 항상 도는 타이머가 idle 깨어남을 만든다 | Mission Control 안전 점검(3초, 허용 오차 1.5초), 메모리 지킴이, 업데이트가 항상 등록 | 이 셋만 켠 상태(모든 기능 끔)에서 `ri_pkg_idle_wkups`, `ri_interrupt_wkups` 차이 측정 | 3 |
| S3 | 정리 없는 관찰자 | `addObserver(`가 있고 `removeObserver`가 없는 파일: MissionControlMonitor 2/0, CallMonitor 3/0, NetworkMonitor 1/0, HelperApp 2/0, AppDelegate 2/0, LockScreenManager 4/0, MediaController 2/0, AgentNotify 1/0, CameraAndCalendar 3/1 | 각 관찰자의 소유자가 **앱 수명 싱글톤**인지 확인. 싱글톤이면 합격(앱 종료 때 정리됨). 디스플레이·페이지·창처럼 **생겼다 없어지는** 객체가 소유하면 누수 후보 | 3·5 |
| S4 | 디스플레이 이벤트 감시 정리 | `Notch/DisplayNotch.swift`에 `NSEvent` 감시 7개 등록(`:219~252`), 제거는 `:76` 한 곳(`forEach(removeMonitor)`) | 디스플레이를 뽑았다 꽂을 때(`notchctl screenparams`) 감시 개수가 늘지 않는지, `deinit` 경로가 `:76`을 지나는지 | 3·8 |
| S5 | 이벤트 탭 정리 | `Monitors/HUDMonitor.swift:57` `CGEvent.tapCreate` | 탭을 끄는 경로(`CFMachPortInvalidate`, 실행 루프에서 제거)가 있는지 읽기. 손쉬운 사용 권한을 껐다 켰을 때 탭이 중복되지 않는지 | 3·5 |
| S6 | 로그·출력 | 로그는 `NSLog` 2곳뿐 [확인]: 도우미 실행 실패 `Tray/FilePicker.swift:34`, `App/AppDelegate.swift:311` (오류 객체만 출력). `print`는 probe 결과 출력(`TraySelection.swift:159-160`, `MonitorLayout.swift`)이라 probe 인자 없이는 실행되지 않음 | 두 `NSLog`의 `\(error)`에 경로·개인정보가 섞이는지, probe 코드가 배포 빌드에 들어가도 인자 없이 실행되지 않는지 | 1 |
| S7 | 외부 프로세스 15곳 (`Process()` 13 + `openApplication` 2) | §2.2 | 각 호출이 **종료를 기다리는지**, 시간 제한이 있는지, 메인 스레드를 막는지, 실패 때 좀비가 남는지 | 3 |
| S8 | 시작 때 모든 감시기를 켜고 안에서 거른다 | `AppDelegate.swift:135~150` | 기능을 끈 사용자에게 감시기 객체·관찰자가 남는지. 끈 기능의 idle 비용이 0인지 §3.2로 측정. 비용이 있으면 "끄면 `stop()`" 후보 | 3·5 |
| S9 | 옛 마이그레이션 | `App/Migration.swift` | 어느 버전 사용자를 위한 코드인지, 지금도 필요한지. 1.0.1 이상이 자동 업데이트 대상이라 삭제는 사용자 결정 | 1 |
| S10 | 형제 폴더 `NotchIsland/` | 같은 상위 폴더에 별도 `Package.swift` 프로젝트. 이 저장소(git) **밖** [확인] | 사용자에게 보관·삭제 여부를 묻는다. 이 점검에서는 건드리지 않음 | 0 |

### 3.1 소유자 수명 판정표 (S3 용)

| 소유자 | 수명 | 관찰자를 남겨도 되는가 |
|---|---|---|
| `AppDelegate`가 가진 싱글톤·감시기 | 앱 전체 | 예 |
| `DisplayNotch`, `DisplayNotchState` | 디스플레이가 있는 동안 (뽑으면 사라짐) | **아니오** — `deinit`에서 해제 필요 |
| SwiftUI `View`, `NSViewRepresentable` | 페이지가 보이는 동안 | **아니오** — `onDisappear`·`dismantleNSView`에서 해제 |
| 도우미 프로세스 객체 | 창이 열려 있는 동안 (닫으면 프로세스째 사라짐) | 예 |

### 3.2 깨어남·CPU 측정 방법 (공통)

`footprint`, `leaks`, `ps -o time=`만으로는 깨어남을 못 본다. `proc_pid_rusage`의 `ri_pkg_idle_wkups`, `ri_interrupt_wkups` 차이를 쓴다 (`top -stats idlew`는 초당 값이 아니라 쓰지 않는다). 절차:

1. 앱 PID를 구한다 (`pgrep -x DynamicMacNotch`).
2. 60초 간격으로 두 번 읽어 **차이 ÷ 60**을 초당 값으로 쓴다.
3. 같은 방법으로 CPU 시간(`ps -o time=`) 차이도 적는다.
4. 결과는 파일에 바로 쓴다.

---

## 4. 단계별 계획

각 단계는 **목적 / 대상 / 방법 / 합격 기준 / 되돌리기 / 하지 말 것** 순서다.

### 단계 0 — 기준선 측정

- **목적:** 정리 전 수치를 고정해 이후 변화를 비교한다.
- **방법:**
  1. 작업 브랜치 생성 (`git switch -c audit/1.4.3`).
  2. 배포 빌드(`scripts/build.sh`)와 개발 빌드(`scripts/build.sh --dev`)를 각각 만들어 **경고 건수**를 센다 (`grep -c 'warning:'`에서 SDK 모듈 캐시 경고는 제외: `grep -v SDKExplicitPrecompiledModules`).
  3. 개발 빌드로 probe 4종(`display`, `settings`, `monitor`, `tray`)을 돌려 건수를 기록.
  4. 배포 빌드로 §3.2 방법의 **idle 측정**: (a) 기본 설정 60초, (b) 모든 홈 기능·알림 끔 60초. 메모리(`footprint`), CPU, 깨어남, `leaks`.
  5. `find Sources -name '*.swift' | xargs wc -l`로 줄 수 확정.
  6. `git ls-files | wc -l`(현재 116개), `docs/` 문서 5개 확인.
- **합격 기준:** 경고 0건(프로젝트 코드), probe 전부 실패 0건, idle 메모리·CPU·깨어남 수치가 표로 남음. 이전 값(1.4.2): 메모리 17~18MB, 대기 CPU 0.07%, 누수 0.
- **되돌리기:** 해당 없음(변경 없음).
- **하지 말 것:** 사용자 설정을 바꾸는 (b) 측정을 설정 복원 스크립트 없이 하기.

### 단계 1 — 정적 점검 (읽기)

- **목적:** 지울 후보와 고칠 후보를 근거와 함께 확정한다.
- **방법 (복사해 실행):**

```bash
# 설정 키 중 바깥 사용처가 없는 것 (이번 조사: 0개 — AppSettings 내부 사용 7개는 제외 확인)
bash /tmp/dmn_scan.sh "$PWD"   # 또는 아래 §부록 A 스크립트

# 한 번만 정의되고 어디서도 안 불리는 함수 (이번 조사: 14개, 모두 시스템 콜백)
grep -rhno --include='*.swift' 'func [a-z][A-Za-z0-9]*' Sources | sed -E 's/.*func //' | sort | uniq -c | awk '$1==1{print $2}' \
  | while read f; do c=$(grep -rnw --include='*.swift' "$f" Sources | wc -l); [ "$c" = 1 ] && echo "$f"; done

# 주석 처리된 코드, TODO (이번 조사: 0건)
grep -rnE '^\s*//\s*(let|var|func|if|for|guard|self\.|center\.)' Sources
grep -rn 'TODO\|FIXME\|HACK\|XXX' Sources

# 개발 코드가 새는지
grep -rn '#if DEV' Sources | wc -l            # 35
grep -rn --include='*.swift' 'print(\|NSLog(' Sources
```

  - 함수만이 아니라 **타입(struct/class/enum), 열거형 case, 지역화 문자열**도 같은 방식으로 한다. 이번 조사는 함수와 설정 키만 봤다 [한계].
  - 같은 이름 함수가 두 곳에 정의되면 위 방법은 놓친다. 정의가 둘인 이름은 별도로 호출처를 본다.
  - 중복 구현 찾기: 비슷한 이름의 헬퍼(`rate`, `gigabytes`, 시간 포맷, 파일 크기 포맷 등)를 `grep -rn 'func .*format\|func .*human\|func .*bytes'`로 찾아 한곳으로 모을 수 있는지 본다.
  - S6, S9 확인.
- **합격 기준:** 후보마다 `파일:줄`, 근거 명령, 제거해도 안전한 이유(또는 남기는 이유)가 표에 있다. "확신 없음"은 지우지 않고 목록에 둔다.
- **하지 말 것:** KVO·`#selector`·SwiftUI 바인딩·`@objc`·시스템 콜백을 "안 쓰임"으로 판정하기.

### 단계 2 — 설정 저장소 점검 (읽기 + probe)

- **목적:** 설정 오류와 키 충돌, 연동 규칙 위반을 찾는다.
- **방법:**
  1. `@Setting` 110개 표 만들기: 키, 기본값, 정리 함수(sanitize) 유무, 읽는 곳 수, 설정 화면 연결 여부.
  2. **설정 화면에 없는 키**와 **화면에는 있는데 읽는 곳이 없는 키** 대조. (설정 화면: `Settings/Pages/*.swift`)
  3. 키 중복: `grep -o '@Setting("[^"]*"' Sources/DynamicMacNotch/Settings/AppSettings.swift | sort | uniq -d` — 비어 있어야 한다.
  4. 연동 규칙 점검 (각각 probe가 있으면 probe, 없으면 읽기):
     - 홈 기능 스위치 ↔ 실시간 모니터링 "둘 다" (`setHomeFeature`, `MonitorLayout.contentAfterTurningOff`): `--monitor-probe`.
     - `homeOrder`, `persistentOrder`의 정리 함수가 새 키를 앞 항목 뒤에 끼워 넣는지 (`fixedHomeOrder`, `fixedPersistentOrder`).
     - 디스플레이별 설정 `displayContent`, `notchDisplays`: `--display-probe`.
  5. 설정 창(도우미)에서 바꾼 값이 본 앱에 반영되는 경로(분산 알림 → `reload()`)에서 **무한 알림 루프**가 없는지: 값이 같으면 쓰지 않는지(`Setting.swift`) 읽기.
  6. 기본값을 새 설치 상태에서 확인: 임시 `HOME`으로 앱 실행은 하지 말고(사용자 환경 위험) `--settings-probe`의 기본값 검사 항목이 있는지 읽고, 없으면 probe에 추가를 제안만 한다.
- **합격 기준:** 키 중복 0, 읽는 곳 없는 키 0(또는 사용자가 남기기로 한 목록), 화면에 없는 키는 모두 "내부 상태"라는 설명이 붙음, `--settings-probe` 실패 0.
- **되돌리기:** 변경 없음(제안만).

### 단계 3 — 수명·누수·불필요한 동작 (측정)

가장 큰 이득이 나올 것으로 보는 단계다. 코드는 바꾸지 않고 **측정 결과표**를 만든다.

- **3-A 정적 수명 점검:** §3의 S3, S4, S5, S7을 읽기로 판정한다. 관찰자·타이머·`Task`마다 소유자의 수명(§3.1), 해제 위치, `[weak self]` 여부를 표로 만든다. (`[weak self]`는 타이머 클로저 22곳 모두 이미 있음 [확인]. 관찰자·`Task` 클로저는 [미확인].)
- **3-B 누수 측정:** 배포 빌드에서 `leaks <pid>` (대기, 미리보기 대량 실행 후, 각 페이지를 열고 닫은 후). 기준: **0 leaks**. 이전 결과(1.4.2): 대기·미리보기 390회 후·1시간 후 0건.
- **3-C 반복 시험 (수명이 있는 객체):**

| 시험 | 방법 | 합격 기준 |
|---|---|---|
| 페이지 열기·닫기 100회 | `notchctl home`/`collapse`와 `next`/`prev` 반복 | 메모리 증가 ≤ 2MB (5회 뒤 기준), 누수 0 |
| 설정 창 열기·닫기 20회 | `notchctl settings`/`closewin` | 도우미 프로세스 0개 남음, 본 앱 메모리 증가 ≤ 1MB |
| 디스플레이 구성 변경 20회 | `notchctl screenparams` | `NSEvent` 감시·패널 수가 늘지 않음 (`notchctl displaystate`) |
| 미리보기 대량 | 설정 화면 미리보기 반복 | 끝난 뒤 메모리가 시작 + 25MB 이내로 복귀(이전 40.3MB 근처 = 정상), 누수 0 |
| 채팅 열기·닫기 20회 | 시험 채팅 폴더(`DMN_CHAT_FOLDER`) | 증가 ≤ 2MB, 대화 데이터가 메모리에 남지 않음 |
| 트레이에 파일 추가·삭제 | `notchctl pick`/`trayclear` | 증가 ≤ 1MB, 열린 파일 0개 (`lsof -p`) |

- **3-D 불필요한 동작 (S1, S2, S8):** 아래 **상태 × 감시기 표**를 채운다. 각 칸은 §3.2 방법의 "초당 깨어남"과 "CPU %". 기준선은 모든 기능이 꺼진 상태.

| 상태 ↓ / 감시기 → | 기본(모두 켬) | 모두 끔 | 노치 숨김 (`notchctl hide`) | Mission Control (`mcstate`) | 화면 잠금 (`notchctl lock`) | 디스플레이 잠자기 |
|---|---|---|---|---|---|---|
| 깨어남/초 | | | | | | |
| CPU % | | | | | | |

  감시기별로 해당 기능만 끄고 켠 차이도 잰다: Battery, Bluetooth, Call, Download, Focus, HUD, Network, Recording, Screenshot, Media(NowPlaying), AI 사용량, 일정(calendar).
  - **판정:** 기능을 끈 상태의 깨어남이 "모두 끔" 기준선과 같아야 한다 (차이 ≤ 0.1회/초). 숨김·잠금 상태가 기본보다 **낮아야** 한다 (감시기는 이벤트 구동이면 같아도 합격, 폴링이면 낮아야 함).
  - 화면 잠금과 잠자기는 사용자 화면에 영향이 있으므로 §1.1을 지키고 실제 잠금은 사람이 한다(단계 8).
- **3-E 외부 프로세스:** 15곳을 호출 조건별로 실행해(예: 블루투스 연결, 업데이트 확인, 파일 선택, 채팅 첨부 변환) 호출 뒤 `pgrep`으로 프로세스가 남지 않는지 본다.
- **3-F 장시간:** 개발 빌드(`-DDEV`)로 기본 설정 1시간. 시작 직후, 10분, 60분의 메모리·CPU·누수. 기준: 10분 이후 증가 ≤ 2MB (1.4.2는 +3.0MB로 못 지킨 적이 있다 — 원인이 화면 메모리 안착인지 확인하고 기준을 "10분 이후"로 확정할지 사용자에게 묻는다).
- **합격 기준 요약:** 누수 0, 위 증가 기준 충족, 꺼진 기능의 깨어남 = 기준선, 외부 프로세스 잔여 0.

### 단계 4 — 안전한 삭제 (코드 변경, 위험 낮음)

- **대상:** 단계 1에서 "안전"으로 확정된 것만. 예: 읽는 곳 없는 함수·타입, 주석 처리된 코드, 중복 헬퍼.
- **방법:** 후보를 하나씩 지우고 `scripts/build.sh --dev` → 경고 0 → probe 전부 통과 → 커밋. 한 커밋에 한 묶음(같은 폴더, 같은 종류).
- **합격 기준:** 줄 수 감소량을 커밋 메시지에 적고, 동작 변화 0 (probe 건수 동일, 단계 0의 idle 수치가 오르지 않음).
- **되돌리기:** `git revert <커밋>`.
- **하지 말 것:** 저장된 설정 키 삭제(읽지 않아도 사용자 plist에 값이 남아 있을 수 있음. 지우는 것은 코드뿐), `Migration.swift`의 사용자 결정 전 삭제.

### 단계 5 — 수명 정리 수정 (코드 변경, 위험 중간)

- **대상:** 단계 3에서 "문제 있음"으로 판정된 항목.
- **방법:** 문제마다 **재현 측정 → 수정 → 같은 측정**의 순서로 하고 전후 수치를 커밋 메시지에 적는다.
  - 폴링을 이벤트로 바꿀 수 있으면 바꾸되(예: 집중 모드는 이미 DB 감시로 바뀜 `FocusMonitor.swift:32`), 동작이 달라지면 단계 6의 목표 대조를 다시 한다.
  - "숨기면 멈춤"을 추가할 때는 `NotchHub.updateResourceDemand`(숨김·Mission Control·잠금·잠자기 때 멈춤)와 **같은 신호**를 쓴다. 감시기마다 자기 방식을 만들지 않는다.
  - "기능을 끄면 `stop()`"을 추가할 때는 다시 켤 때 상태가 복원되는지(`start()` 멱등) 확인.
- **합격 기준:** 수정한 항목의 측정이 §3 판정을 통과, 다른 항목의 측정은 악화 없음, 알림이 필요한 순간(예: 배터리 낮음, 통화 시작)이 숨김 해제·기능 켜기 직후 **놓치지 않고** 나옴 (단계 6 시험으로 확인).
- **하지 말 것:** 알림을 놓칠 수 있는 정지(예: 숨김 중 배터리 이벤트를 영영 버림). 정지한 동안의 이벤트는 재개 때 한 번 현재 값을 읽어 따라잡아야 한다.

### 단계 6 — 기능별 목표 대조

§5의 점검표를 기능마다 실행한다. 목표의 근거는 `README.md`(영·한), `docs/*_GUIDELINE.md`다. 문서에 목표가 없는 기능은 **"목표 미정의"**로 표시하고 사용자에게 목표를 묻는다.

- **방법:** 문서의 문장 하나 = 점검 항목 하나. 가능한 것은 `notchctl`과 probe로 자동 확인하고, 사람이 입력해야 하는 것은 단계 8로 넘긴다.
- **합격 기준:** 점검표의 "합격 기준" 열 충족. 어긋남은 §6의 양식으로 기록 → 버그면 수정 커밋, 문서가 틀렸으면 문서 수정 커밋(코드와 문서 중 어느 쪽이 맞는지는 사용자에게 확인).

### 단계 7 — 구조 정리·분리 (코드 변경, 위험 높음)

- **목적:** 이후 기능 추가·수정이 쉬워지게 한다. **동작은 바뀌면 안 된다.**
- **후보 (§2.1 큰 파일):** `DisplayNotchState.swift`(688줄: 크기·페이지·긴 누르기·수요 계산이 한 파일), `MediaController.swift`(684: 재생 정보·시험 모드·출력 경로), `ChatStore.swift`(661), `ActivityViews.swift`(507), `CallMonitor.swift`(494), `DisplayNotch.swift`(490). `MathTypesetter.swift`(799)는 독립된 모듈이라 분리 이득이 작으면 그대로 둔다.
- **방법:** 분리 기준은 `docs/ARCHITECTURE.md`의 폴더 규칙. 한 번에 파일 하나, 파일 이동·이름 변경만 하고 로직은 건드리지 않는 커밋을 먼저, 로직 정리는 다음 커밋. 감시기 8개가 같은 모양(`start()`, 설정 보기, 타이머 관리)이면 공통 수명 규칙을 문서화만 하고, 공통 부모 클래스는 **만들지 않는다**(감시기마다 사정이 달라 이득보다 위험이 크다는 가정 — 단계 3 결과를 보고 사용자에게 제안).
- **합격 기준:** 분리 전후 `swift build` 경고 0, probe 건수 동일, **배포 빌드 실행 파일 크기와 idle 수치가 같음**(±2%), `docs/ARCHITECTURE.md` 갱신.
- **되돌리기:** 커밋 단위 `git revert`. 한 파일 분리가 실패하면 그 커밋만 되돌리고 다음으로.
- **하지 말 것:** 분리하면서 이름 바꾸기·동작 변경·새 기능 넣기.

### 단계 8 — 다중 디스플레이·실제 입력 (사람이 확인)

자동 시험이 못 보는 것이다. 사용자가 직접 하거나 사용자 입회하에 한다.

| 항목 | 방법 | 합격 기준 |
|---|---|---|
| 디스플레이 2개 | 외부 디스플레이 연결 후 `--display-probe` 외에 실제 표시 확인 | 디스플레이마다 선택한 상시 항목이 보이고, 뽑았다 꽂아도 설정 유지 (`docs/DISPLAY_GUIDELINE.md` §3, §5) |
| Mission Control | 실제 실행 | 노치가 Spaces 막대를 가리지 않음 |
| 실제 마우스·키 | 길게 누르기, 두 손가락 스크롤, 파일 끌기, 트레이 선택, 메모 입력 | 각 기능 문서 설명대로 동작 |
| 잠금 화면 | 실제 잠금·해제 | 잠금 화면 위젯 표시, 해제 뒤 노치 복귀, 잠금 중 자원 측정 정지 |
| 잠자기·깨우기 | 디스플레이 잠자기 후 깨우기 | 측정 재개, 알림 놓침 없음 |
| 권한 변경 | 손쉬운 사용·블루투스·캘린더 권한을 껐다 켜기 | 감시 재개(HUD·블루투스는 3초 재시도), 중복 등록 없음 (S5) |

### 단계 9 — 배포 전 검증

- **방법:**
  1. 배포 빌드 `scripts/build.sh --zip`.
  2. 개발·CLI 문자열 검사 (`strings`로 15바이트 이상 문자열로 확인한다. Swift는 짧은 문자열을 인라인하므로 `--chat-probe=` 같은 짧은 것은 안 보인다):

```bash
B="build/Dynamic MacNotch.app/Contents/MacOS/DynamicMacNotch"
strings "$B" | grep -c -E "DMN_TEST_PASTEBOARD|monitordemand|monitorsample|claude -p|/Users/"   # 0이어야 함
strings "$B" | grep -ci "gmail"                                                                     # 0이어야 함
git grep -n -i -E "<내 이메일>|claude -p|oauth|cookie.*scrap" main -- Sources                     # 비어 있어야 함
git log --format='%ae' origin/main..main | sort -u                                                  # noreply 주소만
```

  3. 단계 0과 같은 측정(메모리, idle CPU, 깨어남, 누수)을 배포 빌드로 다시 하고 단계 0 값과 비교.
  4. 영·한 릴리즈 노트에 "Memory & resource tests · 메모리·자원 테스트" 표.
  5. 사용자가 배포를 요청하면 `gh release create`(제목 "Dynamic MacNotch X.Y.Z"), 개인 빌드는 `local-cli`에 `main`을 합쳐 설치.
- **합격 기준:** 위 검사 전부 0/비어 있음, 측정이 단계 0 이하, 경고 0.

---

## 5. 기능별 점검표

열: **목표(근거)** / **확인 방법** / **합격 기준** / **숨겨졌을 때 멈춰야 하는가**. "멈춰야 하는가"의 값은 §3.2 측정으로 단계 3에서 채운다. 괄호 안 문서가 근거이고, 문서에 없으면 "목표 미정의"로 두었다.

### 5.1 일회성 알림·상시 표시 (감시기)

| 기능 | 목표 (근거) | 확인 방법 | 합격 기준 | 숨김 때 멈춤 |
|---|---|---|---|---|
| 배터리 | 낮음·충전기·완충 알림, 충전 상시 표시 (README) | 설정 `battery*` 조합 시험, 임계값 `batteryLowThreshold` | 설정대로 알림, 끄면 알림 0 | 이벤트 구동이면 불필요 [미확인] |
| 블루투스 | 연결 알림, 기기 종류 아이콘, 차단 목록 (README) | 연결 시 알림, `btBlocklist` 항목은 알림 없음 | 권한 없을 때 메인 스레드가 멈추지 않음(주석 `BluetoothMonitor.swift:51`) | [미확인] |
| 네트워크 | Wi-Fi 연결·전원, 핫스팟, VPN, VPN 국가(기본 꺼짐) (README) | 개별 스위치 시험 | VPN 국가 꺼짐이면 외부 요청 0 (`NetworkMonitor.swift:100` 타이머 조건 확인) | [미확인] |
| 집중 모드 | 켜짐·꺼짐 알림, 제외 목록, 상시 표시 (README) | `focusExcluded` 시험 | DB 감시가 되면 폴링 0 (`FocusMonitor.swift:32`) | 이벤트 구동 |
| 통화 | 수신·진행·종료 (README) | 통화 시뮬레이션은 어려움 → 사람 확인 | `callEnabled` 꺼짐이면 상태 `idle`, 타이머 0 (`CallMonitor.swift:296`) | 통화 없으면 타이머 없음 [확인] |
| 다운로드 | 진행 링/바, 폴더 목록 (README) | 임시 폴더에 파일 생성 | 진행 항목 없으면 타이머 0 (`DownloadMonitor.swift:236`) | 항목 없으면 정지 [확인] |
| 녹화 | 화면 녹화 중 표시, 정지 (⌃⌘E) | `notchctl recstop` | 설정 꺼짐이면 폴링 0 | [미확인] |
| HUD | 볼륨·밝기·키보드 밝기, 시스템 HUD 대체 | 손쉬운 사용 권한 있을 때만 | 권한 없으면 3초 재시도만, 권한 후 즉시 정지 (`HUDMonitor.swift:34`). 밝기는 폴링 없이 알림만 | 이벤트 구동 |
| 스크린샷 | 클립보드/폴더 감시, 확인 창, 자동 닫기 | `notchctl shot`, `shotdelete` | 기능 꺼짐이면 클립보드 폴링 0 (`ScreenshotMonitor.swift:51-62`) | 꺼짐 때만 정지 [확인] |
| 에이전트 | Claude Code 등 알림 (`Agent/*`) | **목표 미정의** → 사용자 확인 | | |
| 중요 알림 | 시스템 알림 감시 (`criticalAlert*`) | **목표 미정의** → 사용자 확인 | | |

### 5.2 홈 기능

| 기능 | 목표 (근거) | 확인 방법 | 합격 기준 | 숨김 때 멈춤 |
|---|---|---|---|---|
| 카메라 | 누르기 전까지 꺼짐, 켜면 노치 확대, 끄기·닫기·페이지 전환 시 축소 (README 홈 1번) | `notchctl home`+`next`, 카메라 사용 표시등 | 노치를 닫으면 카메라 세션 정지(녹색 표시등 꺼짐) | 정지해야 함 |
| 타이머 | 시·분·초 입력, 진행 링, 일시정지·재개·취소, 끝나면 소리 (README 2번) | 짧은 타이머 실행 | 끝나면 알림, 타이머 없으면 0.25초 타이머 0 | 타이머 진행 중만 |
| AI 사용량 | 5시간·주간 한도, 단일 한도는 마크+값, 새로고침 1/2/5/10분, 상시 표시 꺼짐이면 페이지를 열 때만 새로고침 (README 3번, RESOURCE_GUIDELINE) | 로그인 필요 → 사람 확인. 로그인 창은 헬퍼 프로세스가 끝나면 웹 메모리 반환 | 새로고침 뒤 `WKWebView` 프로세스 0개(`pgrep -f WebKit`로 앱 관련 확인) | 가려진 동안 새로고침 쉼 (UsageStore) |
| 자원 사용량 | 보이는 지표만 읽음, 숨기면 정지, 메모리 누적 없음 (RESOURCE_GUIDELINE §0,4) | `notchctl monitorstate`, `monitorsample`, `monitordemand` | 수요 0이면 타이머 0, 1시간 +0.9MB 이하(이전 결과) | 정지함 [확인] |
| 메모 | 제목+본문, 자동 저장, 닫힌 몇 초 뒤 메모리에서 내림 (README 4번) | 시험 폴더 없이 사용자 메모를 건드리지 않도록 **메모 시험은 새 메모 1개를 만들어 그것만** | 닫은 뒤 메모리에서 내려감(`footprint` 차이) | 해당 없음 |
| 오늘 일정 | 남은 일정, N분 전 알림, 다음 일정 상시 표시 (README 5번) | 캘린더 권한, 임시 일정은 만들지 않음 | `calendar.stop()`이 홈 기능 끄기에서 불림 (`AppDelegate.swift:257`) | [미확인] |
| 에어드랍·트레이 | 파일 끌기, 선택·키보드 선택, 자동 정리 (README 6번, 1.4.1) | `--tray-probe`, `notchctl pick`/`trayclear`/`traystate` | probe 30건, 20개 1GB 추가 +0.2MB | 해당 없음 |
| AI 채팅 | API 키는 키체인, 대화는 평문 폴더, 켜기 전 기본 꺼짐 (CHAT_GUIDELINE §3) | `--chat-probe`(키 읽기 금지: `readkey`는 쓰지 않음), `DMN_CHAT_FOLDER` | 꺼짐이면 네트워크 요청 0, 로그에 키·본문 0 | 해당 없음 |
| 미디어 | 재생 정보, 건너뛰기, 즐겨찾기, 출력 경로 (README) | `notchctl media`, `skipnext`, `favtoggle` | 재생 없으면 5초 시험 타이머 0 | [미확인] |
| 가사 | 로컬/온라인 가사 (`lyrics*`) | 온라인은 설정 꺼짐이 기본 | `lyricsOnline` 꺼짐이면 외부 요청 0 | |
| 잠금 화면 | 미디어 위젯, 가사, 화면 보호기 연동 (`LockScreen/*`) | `notchctl lock/unlock/lockfull/saveron` | 해제 뒤 윈도 0개 남음 | 정지해야 함 |
| 실시간 모니터링 | AI·자원·둘 다, 디스플레이별 선택 (README, RESOURCE_GUIDELINE) | `--monitor-probe`, `--display-probe` | 386건·6,257건 통과 | 자원은 정지 |

### 5.3 앱 전체

| 항목 | 목표 | 확인 방법 | 합격 기준 |
|---|---|---|---|
| 메모리 지킴이 | 기준(70~150MB) 넘으면 정리·조용히 재시작 (`MemoryGuard`) | `notchctl memtest`(기준을 1MB로 낮춰 동작 확인; 끝나면 설정 복원) | 재시작 뒤 설정·상태 유지, 30분 안에 쉬지 않으면 미룸 |
| 업데이트 | 시간당 확인, 새 버전 내려받기·교체 (`Updater`) | `notchctl update`(개발 빌드) | 실패해도 앱이 정상 동작. 다운로드 파일·임시 폴더 정리 |
| 설정 창 | 도우미 프로세스, 닫으면 프로세스째 메모리 반환 | `notchctl settings`/`closewin` 20회 | 남는 프로세스 0 |
| 권한 창 | 권한 상태 표시, 1초 갱신 | `notchctl permissions` | 창을 닫으면 1초 타이머 정지 (`PermissionsManager.swift:158`) [의심] |
| 메뉴바 아이콘 | `showStatusItem` | 설정 토글 | 끄면 아이콘 사라짐, 우클릭 메뉴 정상 |
| 언어 | 한국어·영어, 시스템 따름 | 설정 → 일반 → 언어 | `T()` 밖의 하드코딩 글 0 (`grep -rn '"[가-힣]' Sources`에서 `T(` 바깥 항목) |
| 온보딩 | 처음 실행 안내 (`onboardingDone`) | **목표 미정의** → 사용자 확인 | |

---

## 6. 결과 기록 양식

### 6.1 단계 결과표 (단계마다 한 장)

| 항목 | 기대 | 실측 | 판정 | 근거 (명령·파일:줄) |
|---|---|---|---|---|
| | | | 합격 / 불합격 / 보류 | |

### 6.2 발견 사항

| ID | 위험도 | 위치 | 증상 | 재현 방법 | 원인 [확인/의심] | 조치 제안 | 상태 |
|---|---|---|---|---|---|---|---|
| A-001 | 높음(데이터 손실·누수) / 중간(불필요한 동작) / 낮음(정리) | `파일:줄` | | | | | 대기 / 수정 / 보류 / 사용자 결정 |

위험도 기준: **높음** = 사용자 데이터 손상·계속 늘어나는 메모리·권한 문제. **중간** = 꺼진 기능이 도는 것, 알림 놓침, 문서와 다른 동작. **낮음** = 죽은 코드, 이름, 중복.

### 6.3 측정 기록 (표준 항목)

모든 측정에 같은 항목을 적는다: 빌드 종류(배포/개발), 커밋 해시, 설정 상태, 시험 시간, 메모리(`footprint`), CPU(`ps -o time=` 차이), 깨어남/초(`ri_pkg_idle_wkups`, `ri_interrupt_wkups`), 누수(`leaks`), 환경(Mac 기종, macOS 버전, 디스플레이 수).

---

## 7. 한계

- 이 문서의 [확인]은 정적 읽기와 `grep`/`wc` 수준이다. 이 문서를 쓰는 동안 앱을 실행한 측정은 하지 않았다. 따라서 §2.4 타이머표의 "언제 도나", §3의 S1·S2·S8은 단계 3의 측정 전까지 **가설**이다.
- 죽은 코드 검사는 **함수와 설정 키**만 했고 타입·열거형 case·문자열 키·`@objc` 선택자는 하지 않았다. 이름이 같은 함수가 여러 곳에 정의된 경우도 놓친다.
- 자동으로 못 보는 것: 실제 키보드·마우스·트랙패드 입력, 실제 잠금 화면, 다중 디스플레이, 로그인이 필요한 AI 사용량, 실제 통화, 실제 블루투스 연결. 단계 8에서 사람이 확인한다.
- `Tests/` 폴더가 없어 회귀를 잡는 것은 probe 4종 + 채팅 probe뿐이다. 단계 7(분리)처럼 동작을 유지해야 하는 작업의 안전망이 약하므로, 필요하면 **단계 2에서 probe 항목 추가를 먼저 제안**한다 (이 점검의 범위를 넘으므로 사용자 결정).
- 외부 서비스(Claude·ChatGPT·Gemini 웹, GitHub 업데이트, 가사·국가 조회)의 응답 변화는 점검하지 못한다.
- 형제 폴더 `NotchIsland/`(이 저장소 밖)는 점검 대상이 아니다.

## 부록 A — 설정 키 사용처 점검 스크립트

`bash 스크립트.sh <프로젝트 폴더>`로 실행. 읽기 전용이며 사용자 설정을 건드리지 않는다. 주의: `grep`의 `--include`는 `--` 앞에 둔다(`--` 뒤에 두면 파일 이름으로 해석되어 실패한다).

```bash
cd "$1"
grep '@Setting(' Sources/DynamicMacNotch/Settings/AppSettings.swift | grep -v '^\s*///' \
  | sed -E 's/.* var ([A-Za-z0-9_]+).*/\1/' | sort -u > /tmp/dmn_keys.txt
echo "keys: $(wc -l < /tmp/dmn_keys.txt)"
echo "== AppSettings.swift 바깥 사용처 0"
while read k; do
  n=$(grep -rnw --include='*.swift' "$k" Sources | grep -v 'Settings/AppSettings.swift' | wc -l | tr -d ' ')
  [ "$n" = 0 ] && echo "  $k (AppSettings 안 사용: $(grep -c "\b$k\b" Sources/DynamicMacNotch/Settings/AppSettings.swift)회)"
done < /tmp/dmn_keys.txt
```

이번 조사 결과: 키 110개, 바깥 사용처 0인 것 7개(`bothLeft`, `bothRight`, `resourceLeft`, `resourceRight`, `chatModelClaude`, `chatModelGemini`, `chatModelOpenAI`) — 모두 `AppSettings.swift` 안의 `monitorSlots`/`setMonitorSlot`/`chatModel(for:)`(`AppSettings.swift:355`) 등에서 쓰이므로 **죽은 키가 아니다**.
