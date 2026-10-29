# Dynamic MacNotch

**Turn your MacBook's notch into a Dynamic Island.**
Live activities, media controls, HUDs, alerts, a file tray and more — all animated in and around the notch.

[한국어 설명은 아래에 있습니다 ↓](#한국어)

---

## Requirements

| | |
|---|---|
| **Mac** | Apple Silicon (M1 or later: M1 · M2 · M3 · M4 and their Pro/Max/Ultra variants) |
| **macOS** | macOS 14 Sonoma or later (Sonoma 14, Sequoia 15, Tahoe 26 and newer) |
| **Display** | Best on MacBooks with a notch (14"/16" MacBook Pro 2021+, MacBook Air 2022+). Macs without a notch (M1 MacBook Air/Pro 13", iMac, Mac mini, Mac Studio, external displays) get a virtual notch centered in the menu bar. |
| **Intel Macs** | Not supported (the build is arm64 only). |

## Installation

1. Download `Dynamic-MacNotch-x.y.z.zip` from [Releases](https://github.com/tjehddnr2864-hue/Dynamic-MacNotch/releases) and unzip it.
2. Move **Dynamic MacNotch.app** to your **Applications** folder.
3. The app is ad-hoc signed and not notarized by Apple, so macOS blocks it the first time:
   - Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**, **or**
   - run `xattr -dr com.apple.quarantine "/Applications/Dynamic MacNotch.app"` in Terminal.
4. On first launch the **Welcome / Permissions** window opens. Allow the permissions for the features you want (see below).

To verify the download, compare it with the `.sha256` file attached to the release: `shasum -a 256 Dynamic-MacNotch-x.y.z.zip`.

### Updating
From 1.0.1 the app **updates itself**: it checks GitHub once a day, verifies the download (SHA-256, code signature, bundle ID, newer version), replaces itself and relaunches. Check manually from **right-click the notch → Check for Updates…**, or turn it off in Settings → General.
To update by hand, quit the app, replace it in Applications, and open it again.
If Accessibility or Input Monitoring stop working after an update, remove Dynamic MacNotch from that list in System Settings (−) and allow it again.

## Permissions

Every permission is optional — without one, only the matching feature turns off. Manage them anytime from **right-click the notch → Permissions…**.

| Permission | Used for |
|---|---|
| Accessibility | Replacing the volume/brightness HUD, stopping screen recordings, detecting file drags, answering/ending calls |
| Input Monitoring | Intercepting the brightness and volume keys |
| Screen & System Audio Recording | Detecting that the screen is being recorded |
| Camera | The camera mirror on the Home screen (off until you click it) |
| Calendars (Full Access) | Today's events and upcoming-event alerts |
| Bluetooth | Accessory connections and battery levels |
| Location Services | Showing the connected Wi-Fi name (macOS requires this for SSIDs) |
| Automation (Music, Spotify) | Media control, favorites, lyrics |
| Focus Status | Showing when a Focus turns on/off |
| Full Disk Access | Showing the Focus *name and icon* (Work, Sleep, …) |
| Files & Folders | Watching Downloads, saving screenshots to Desktop |
| Open at Login | Starting automatically when you log in |

## How it works & how to use it

### The notch
The notch has four states and morphs between them with spring animations:

- **Idle** — looks like the normal notch (it grows slightly on hover, optional).
- **Compact** — widens left and right: an icon on the left, a value on the right (e.g. 🔋 `82%`).
- **Detail** — a larger card under the notch with a title and subtitle, used for important alerts.
- **Expanded** — the Home screen or a full popup (music, timer, download…).

When two compact alerts follow each other, the notch briefly tucks in and comes back out with the new one.

### Gestures
| Action | Result |
|---|---|
| **Long-press** the notch (default 0.35 s) | Opens Home, or the popup of the activity currently shown (e.g. the music player) |
| **Force click** (Force Touch trackpad) | Opens immediately |
| **Click** a compact activity | Opens its app or page (battery → Battery settings, timer → timer, …) |
| **Two-finger swipe left/right** while open | Switches Home pages (or click the dots under the notch) |
| **Two-finger swipe up** while open | Closes |
| **Two-finger swipe up / down** on a compact live activity | Hides / shows live activities |
| **Two-finger swipe left / right** while music shows | Next / previous track (does nothing if the app or video has no next/previous) |
| **Right-click** the notch | Menu: Open Home, Settings, Permissions, Preview alerts, Restart, Quit |
| **Hover** | Optional: grow slightly, or open on hover (Settings → General) |

### Home (6 pages)
Reorder the pages or turn features off in **Settings → Interactions → Basics**. A feature that's off disappears from the notch and stops running in the background. AirDrop & Tray can also be hidden from Home while dragging files to the notch still works.

1. **Camera** — a mirror using your FaceTime camera. It stays off until you click it; when it turns on, the notch grows for a bigger picture, and it shrinks back when you turn it off, close the notch or change pages.
2. **Timer** — set hours : minutes : seconds by **clicking a field and typing** (Tab/Enter moves on, Esc cancels; clicking the background confirms, an empty field becomes 00) or by **two-finger scrolling** over a field. While running, a ring shows progress; it pauses/resumes/cancels from the notch and alerts with a sound when done.
3. **AI Usage** — 5-hour and weekly limits for **Claude, ChatGPT (Codex) and Gemini**, with reset times. Sign in to each website once in Settings → Interactions → AI Usage; sign-in data stays in the app's own web storage. Optionally **keep it in the notch**: 5-hour on the left, weekly on the right, as text or rings. Services with a single limit (e.g. ChatGPT Free's 30-day limit) show one bar, and the notch shows that limit with the time to reset. If AI usage is the only live activity, long-pressing it opens Home on this page (swipe or use the dots for the other Home pages); with other live activities it opens in the live-activity popup. Choose how often it refreshes (1, 2, 5 or 10 min). When it isn't kept in the notch, nothing runs in the background: it refreshes only when you open the page. While a higher-priority live activity covers it, refreshing pauses and resumes once it's visible again. Each refresh runs in a short-lived helper process, so the web memory is released right after.
4. **Memo** — a simple text memo: a fixed title on top and a scrolling body below. Click the title or body to type (it continues where you clicked); ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z work. It saves automatically as you type and when you leave, and reopens where you left off. The list icon (top right) slides the memo over and shows your memos on the right third; click one to open it, right-click to delete. Memos are kept on disk, not in memory: a few seconds after the notch closes they're unloaded, and they're read again only when you open the memo page.
5. **Today** — your remaining events today; click one to open it in Calendar. Optional alert N minutes before an event starts.
6. **AirDrop · Tray**
   - **Click** the AirDrop or Tray box to choose files; **or drag files** onto the notch — while dragging, the boxes only act as drop zones.
   - Dragging a file toward the top of the screen opens the notch *before* you reach the edge, so Mission Control doesn't trigger.
   - Tray files: click / ⌘-click / ⇧-click to select, double-click to open, **drag them out** to attach anywhere (they leave the tray), right-click for Open / Show in Finder / AirDrop / Remove. `+` adds more, the trash button clears.
   - Options: keep copies in the tray, auto-clean after 1 or 7 days.

### Music
- Works with **all apps** (Safari/YouTube, Chrome, Spotify, Apple Music, …) or only Apple Music / Spotify (Settings → Interactions → Media).
- **Compact**: album art on the left, an animated waveform tinted by the artwork on the right.
- **Song change**: a short card with the new song (optional; by default only for Apple Music and Spotify).
- **Player** (long-press while music shows):
  - Scrolling title, artist, waveform; click the artwork to open the source app.
  - Progress bar: drag to seek. Hovering makes it slightly thicker; while you hold it, it grows and the times slide outward.
  - Previous / Play-Pause / Next — the artwork flips to the new song (opposite directions for next/previous).
  - ⭐ **Favorite** — synced with Apple Music's Favorite.
  - **Output** icon (MacBook speakers, headphones, AirPods, display, AirPlay…): **click** to pick an output (paired Bluetooth headphones that aren't connected are listed too and get connected); **long-press** to show a volume bar under the controls.
- Hides N seconds after pausing (optional).
- When two apps play at the same time, the one that **started first stays** in the notch; when it pauses or stops, the notch switches to the other one. With the source set to Apple Music or Spotify, other apps (YouTube in a browser, …) never replace it.

### Phone calls
Calls from your iPhone (Continuity) and FaceTime audio calls appear in the notch.
- **Incoming** — the notch expands with the caller (saved contact name, otherwise the number; long numbers scroll) and red **Decline** / green **Accept** buttons. **Swipe up with two fingers** to tuck the card away without declining — a small ringing indicator stays; click it to bring the card back.
- **On a call** — call time on the left, a voice waveform on the right.
- **Long-press** — the caller's avatar and name, **Mute** and **End** buttons. While muted the waveform stops, like paused music.
- Uses Accessibility to read macOS's call banner and press its buttons (the system call service is reserved for Apple apps). Turn it off in Settings → Interactions → Phone Calls.

### System HUD replacement
Volume, display brightness and keyboard brightness keys show a notch HUD instead of the macOS one: icon on the left, value on the right as a number, bar or ring. The volume HUD can show the output device icon. Changes made in Control Center can be shown too.

### Alerts
- **Network** — Wi-Fi on/off, connected/disconnected (with network name), **VPN** connected/disconnected (system VPNs and app VPNs like NordVPN/WireGuard), personal hotspot (can stay pinned), and a card when every network is lost.
- **Bluetooth** — accessory connected with a device-specific icon (AirPods models, headphones, mice, keyboards, game controllers) and battery (AirPods: left/right/case). Battery shown as percent, ring or both; under 15% turns red. iPhone/iPad are ignored.
- **Focus** — the mode's own icon and color when it turns on; the same icon, translucent, when it turns off. Can stay pinned while on.
- **Battery** — charger connected (level + ⚡ and time to full), fully charged, low battery warning (threshold configurable).
- **Downloads** — progress for Safari, Chrome and Firefox downloads in your downloads folder (Downloads by default; change it in Settings → Interactions → Downloads, plus extra folders); a **Show in Finder** button when done.
- **AirDrop** — sending progress and result; an alert when files arrive.
- **Screenshots** — after ⌘⇧3 / ⌘⇧4 / ⌘⇧5 (to clipboard or file) a preview card appears: **Copy**, **Save** (as `Screenshot_YYYY_MM_DD_HH_MM_SS`, PNG or JPEG, Desktop or a folder you choose), **Delete**, or drag the thumbnail into another app.
- **Screen recording** (⌘⇧5, QuickTime) — choose in Settings → Interactions → Screen Recording: a **brief alert** when recording starts, or **keep showing** a red dot on the left and the recording time on the right. **Click the red dot** (left side) to stop and save (macOS saves the file as usual); long-press opens the recording page, where the stop icon does the same and then shows **Recording Saved** with a **Show in Finder** button. Set the folder it opens (Desktop by default) in the same page to match where macOS saves your recordings.

Every alert can be **compact or detailed**, and durations are configurable. **Long-press a compact alert** to see its detailed card; detailed alerts only respond to a click.

### Live activity priority
When several activities run at once (screen recording, timer, AirDrop, download, music, hotspot, Focus), the one highest in **Settings → Priority** is shown. Reorder with the arrows. Long-press it to open its popup, then use the dots or a two-finger swipe to page through the other live activities (on the music player, the swipe skips songs; use the dots instead). When it closes, the notch again shows the highest-priority one.

### Claude Code · Codex
When a Claude Code or Codex task finishes, the notch shows **Done**; click it to bring up the app it ran in (Terminal, VS Code, Claude, Codex…). Choose Compact (icon and Done) or Detailed ("Claude Code · project" plus the finished task, i.e. your last request). Turn it on in Settings → Interactions → Claude Code · Codex with **Connect**: this adds a Stop hook to `~/.claude/settings.json`, and sets `notify` in `~/.codex/config.toml`. If Codex already had a `notify` command, that command still runs, and Disconnect restores it. A backup (`.dynamicmacnotch.bak`) is kept before the first change.

### Lock screen
- Locking shows a padlock in the notch; unlocking swings the shackle open.
- While music plays, a **media widget** appears above your profile picture and password field. Click the artwork for a full-screen player with the album art, controls and **lyrics** (Apple Music; time-synced lyrics from LRCLIB are opt-in). Drag the progress and volume bars to seek or change volume, and click the output icon to switch speakers or headphones. Song info can be hidden. The widget is hidden while the screen saver runs.

### Test & preview
**Settings → Test** previews every feature in the notch — network, Bluetooth, Focus, HUDs, battery, downloads, AirDrop, screenshots, screen recording, timer, events, phone calls and the lock screen — without touching your real settings, files or calls. Alerts that can be compact or detailed have a Compact/Detailed switch; the rest are grouped as Compact Only or Detailed Only.
- **Music playback test** plays a test song you can control from the player. Stop it with **Stop Test**; it also stops by itself after 30 seconds without interaction.
- **Stop All Previews** ends everything at once. Each preview fully cleans up after itself (timers, fake items), so nothing keeps running.

### Settings window
A sidebar with **General**, **Priority**, **Interactions**, **Test**, **Permissions** and **About**. Click the arrow next to Interactions to expand one page per feature (Network, Bluetooth, Focus, Phone Calls, Media, Downloads, AirDrop & File Tray, Screenshots, Screen Recording, Battery & Charging, HUD, Lock Screen). Every feature page uses the same order: Show → Appearance → Details → Preview. The sidebar uses Liquid Glass on macOS 26 and later, and you can set the window's blur and transparency in Settings → General.

### Language
Korean and English. Settings → General → Language (System default / 한국어 / English), then **Restart Now**.

## Privacy

- No analytics, no accounts, no tracking. Settings and tray items stay on your Mac.
- Network access only happens for:
  - **Update checks** (once a day, can be turned off): GitHub's releases API.
  - **Live lyrics** (off by default): the song title, artist and album are sent to [LRCLIB](https://lrclib.net).
  - **Spotify artwork**: the cover image URL that Spotify provides (HTTPS only).
- Data is stored in `~/Library/Preferences/com.dynamicmacnotch.app.plist` and `~/Library/Application Support/Dynamic MacNotch/`. Delete both to reset.

## Memory

- Screenshot thumbnails and PNG/JPEG conversion run in a short-lived helper process, so a full-screen image never inflates the app's memory.
- **Automatic memory cleanup** (Settings → General, on by default): every 5 minutes and after heavy work the app checks its memory. Above the limit you choose (70–150 MB, default 70) it clears its caches, and if that isn't enough it restarts itself quietly while idle (nothing open, playing in the notch or in progress). Music keeps playing in its own app; the notch is back within a second.

## Notes & limitations

- Some features use private macOS APIs (lock screen windows, now-playing info, brightness, keyboard backlight). They are loaded dynamically and fail safely, but may stop working after a macOS update.
- AirPods listening modes (noise cancellation / transparency) can't be read by third-party apps on macOS.
- The app is not sandboxed (it needs system-wide key and window access) and is not notarized.

## Building from source

Requires Xcode Command Line Tools (Swift 5.10+) on an Apple Silicon Mac.

```bash
git clone https://github.com/tjehddnr2864-hue/Dynamic-MacNotch.git
cd Dynamic-MacNotch
scripts/build.sh --run            # build/Dynamic MacNotch.app
scripts/build.sh --zip            # + release zip and SHA-256
scripts/build.sh --install --run  # install to /Applications
```

`--dev` builds a development version that also accepts test commands from `scripts/notchctl` (never ship it).


---

<a id="한국어"></a>
# 한국어

**맥북 노치를 다이내믹 아일랜드처럼.**
라이브 액티비티, 음악 제어, HUD, 알림, 파일 트레이 등이 노치 안팎에서 애니메이션으로 나타납니다.

## 지원 사양

| | |
|---|---|
| **Mac** | Apple Silicon (M1 이상: M1 · M2 · M3 · M4 및 Pro/Max/Ultra) |
| **macOS** | macOS 14 Sonoma 이상 (Sonoma 14, Sequoia 15, Tahoe 26 이후) |
| **화면** | 노치가 있는 맥북(14·16형 MacBook Pro 2021 이후, MacBook Air 2022 이후)에 최적화. 노치가 없는 Mac(M1 MacBook Air/Pro 13형, iMac, Mac mini, Mac Studio, 외장 모니터)에서는 메뉴바 가운데에 가상 노치로 동작합니다. |
| **Intel Mac** | 지원하지 않습니다 (arm64 전용 빌드). |

## 설치

1. [Releases](https://github.com/tjehddnr2864-hue/Dynamic-MacNotch/releases)에서 `Dynamic-MacNotch-x.y.z.zip`을 받아 압축을 풉니다.
2. **Dynamic MacNotch.app**을 **응용 프로그램** 폴더로 옮깁니다.
3. Apple 공증을 받지 않은 애드혹 서명 앱이라 처음에는 macOS가 실행을 막습니다.
   - 한 번 실행한 뒤 **시스템 설정 → 개인정보 보호 및 보안**에서 **그래도 열기**를 누르거나,
   - 터미널에서 `xattr -dr com.apple.quarantine "/Applications/Dynamic MacNotch.app"`을 실행하세요.
4. 처음 실행하면 **환영 / 권한 관리** 창이 열립니다. 쓰려는 기능의 권한을 허용하세요.

받은 파일은 릴리스에 함께 올린 `.sha256` 값과 비교해 확인할 수 있습니다: `shasum -a 256 Dynamic-MacNotch-x.y.z.zip`

### 업데이트
1.0.1부터 **자동 업데이트**됩니다. 하루 한 번 GitHub에서 새 버전을 확인하고, 내려받은 파일을 검증(SHA-256, 코드 서명, 번들 ID, 더 높은 버전)한 뒤 스스로 교체하고 다시 실행합니다. **노치 우클릭 → 업데이트 확인…**으로 바로 확인할 수 있고, 설정 → 일반에서 끌 수 있습니다.
직접 업데이트하려면 앱을 종료하고 응용 프로그램 폴더의 앱을 새 버전으로 바꾼 뒤 다시 실행합니다.
업데이트 후 손쉬운 사용·입력 모니터링이 허용돼 있는데도 동작하지 않으면, 시스템 설정의 해당 목록에서 Dynamic MacNotch를 지우고(−) 다시 허용하세요.

## 권한

모든 권한은 선택 사항이며, 없으면 해당 기능만 꺼집니다. **노치 우클릭 → 권한 관리…**에서 언제든 바꿀 수 있습니다.

| 권한 | 쓰는 곳 |
|---|---|
| 손쉬운 사용 | 음량·밝기 HUD 대체, 화면 녹화 정지, 파일 드래그 감지, 전화 받기·끊기 |
| 입력 모니터링 | 밝기·음량 키 가로채기 |
| 화면 및 시스템 오디오 녹음 | 화면 녹화 중인지 감지 |
| 카메라 | 홈 화면의 카메라 거울 (누르기 전까지 꺼져 있음) |
| 캘린더(전체 접근) | 오늘 일정, 일정 시작 전 알림 |
| 블루투스 | 액세서리 연결·배터리 표시 |
| 위치 서비스 | 연결된 Wi-Fi 이름 표시 (macOS가 SSID에 요구) |
| 자동화(Music, Spotify) | 미디어 제어, 즐겨찾기, 가사 |
| 집중 모드 상태 | 집중 모드 켜짐/꺼짐 표시 |
| 전체 디스크 접근 | 집중 모드 *이름·아이콘*(업무, 수면 등) 표시 |
| 파일 및 폴더 | 다운로드 폴더 감시, 데스크탑에 스크린샷 저장 |
| 로그인 시 실행 | 로그인하면 자동 실행 |

## 기능과 사용법

### 노치
노치는 네 가지 상태를 스프링 애니메이션으로 오갑니다.

- **기본** — 평소 노치 모양 (커서를 올리면 살짝 커짐, 선택).
- **컴팩트** — 좌우로 넓어져 왼쪽에 아이콘, 오른쪽에 값을 보여 줍니다 (예: 🔋 `82%`).
- **상세** — 노치 아래로 커진 카드에 제목과 설명. 중요한 알림에 씁니다.
- **확장** — 홈 화면 또는 음악·타이머·다운로드 등의 팝업.

컴팩트 알림이 연달아 오면 노치가 잠깐 들어갔다가 새 알림으로 다시 나옵니다.

### 조작
| 동작 | 결과 |
|---|---|
| 노치를 **길게 누르기** (기본 0.35초) | 홈 화면, 또는 지금 표시 중인 활동의 팝업(예: 음악 플레이어) 열기 |
| **깊게 누르기** (포스터치 트랙패드) | 바로 열기 |
| 컴팩트 활동 **클릭** | 해당 앱·화면 열기 (배터리 → 배터리 설정, 타이머 → 타이머 등) |
| 열린 상태에서 **두 손가락 좌우 쓸기** | 홈 페이지 넘기기 (노치 아래 점을 눌러도 됨) |
| 열린 상태에서 **두 손가락 위로 쓸기** | 닫기 |
| 컴팩트 라이브 활동 위에서 **두 손가락 위 / 아래** | 라이브 활동 숨기기 / 다시 보이기 |
| 음악이 떠 있을 때 **두 손가락 좌 / 우** | 다음 / 이전 곡 (앱·영상에 다음·이전이 없으면 아무 동작 안 함) |
| 노치 **우클릭** | 메뉴: 홈 열기, 설정, 권한 관리, 알림 미리보기, 다시 시작, 종료 |
| **호버** | 선택: 살짝 커지기, 호버만으로 열기 (설정 → 일반) |

### 홈 (6페이지)
**설정 → 상호작용 → 기본**에서 페이지 순서를 바꾸거나 기능을 끌 수 있습니다. 끈 기능은 노치에서 사라지고 백그라운드에서도 동작하지 않습니다. 에어드랍·트레이는 홈에서만 가리고 파일을 노치로 끌어오면 동작하게 할 수도 있습니다.

1. **카메라** — FaceTime 카메라로 보는 거울. 누르기 전까지 꺼져 있고, 켜면 노치가 더 커져 화면을 크게 보여 줍니다. 끄거나 노치를 닫거나 다른 페이지로 넘기면 다시 작아집니다.
2. **타이머** — 시 : 분 : 초를 **칸을 눌러 키보드로 입력**(Tab/Enter 다음 칸, Esc 취소, 배경을 누르면 확정, 빈칸은 00)하거나 칸 위에서 **두 손가락 스크롤**로 맞춥니다. 진행 중에는 원형 게이지로 표시되고, 노치에서 일시정지·재개·취소할 수 있으며 끝나면 소리와 함께 알립니다.
3. **AI 사용량** — **Claude, ChatGPT(Codex), Gemini**의 5시간·주간 한도와 초기화 시각. 설정 → 상호작용 → AI 사용량에서 각 웹사이트에 한 번 로그인합니다. 로그인 정보는 앱 전용 웹 저장소에만 남습니다. **노치에 상시 표시**(왼쪽 5시간, 오른쪽 주간 · 텍스트 또는 원형)를 켤 수 있고, 한도가 하나뿐인 서비스(예: ChatGPT 무료 30일 한도)는 바 하나로, 노치에는 그 한도와 초기화까지 남은 시간이 나옵니다. 상시 항목이 AI 사용량뿐이면 길게 눌렀을 때 홈의 이 페이지가 열리고(점·스와이프로 다른 홈 기능), 다른 상시 항목과 함께면 상시 항목 팝업에서 열립니다. 새로고침 빈도(1·2·5·10분)를 고릅니다. 상시 표시를 끄면 백그라운드에서는 아무것도 하지 않고 이 페이지를 열 때만 새로고침합니다. 우선순위가 더 높은 상시 항목에 가려진 동안에는 쉬었다가 다시 보이면 이어서 합니다. 새로고침은 잠깐 뜨는 도우미 프로세스가 하므로 끝나면 웹 메모리가 바로 반환됩니다.
4. **메모** — 텍스트만 쓰는 간단한 메모. 위에 고정된 제목, 아래에 스크롤되는 본문. 제목이나 본문을 누르면 그 자리부터 이어서 씁니다. ⌘A·⌘C·⌘V·⌘X·⌘Z를 쓸 수 있습니다. 쓰는 동안과 나갈 때 자동 저장되고, 다시 열면 마지막으로 쓰던 메모가 그대로 열립니다. 오른쪽 위 목록 아이콘을 누르면 메모가 밀리며 오른쪽 1/3에 메모 목록이 나오고, 눌러서 불러오거나 우클릭으로 지웁니다. 메모는 메모리가 아니라 디스크에 두며, 노치가 닫히고 몇 초 뒤 메모리에서 내리고 메모 페이지를 열 때만 다시 읽습니다.
5. **오늘 일정** — 오늘 남은 일정. 누르면 캘린더에서 열립니다. 일정 시작 N분 전 알림(선택).
6. **에어드랍 · 트레이**
   - 에어드랍·트레이 칸을 **클릭**해 파일을 고르거나, 파일을 노치로 **끌어다 놓습니다**. 끄는 동안에는 칸이 놓는 곳으로만 동작합니다.
   - 파일을 들고 화면 위쪽으로 가면 가장자리에 닿기 전에 노치가 먼저 열려 미션 컨트롤이 뜨지 않습니다.
   - 트레이 파일: 클릭·⌘클릭·⇧클릭으로 선택, 더블클릭으로 열기, **끌어내서** 다른 앱에 첨부(트레이에서 빠짐), 우클릭으로 열기 / Finder에서 보기 / 에어드랍 / 빼기. `+`로 추가, 휴지통으로 비우기.
   - 옵션: 트레이에 복사본 보관, 1일·7일 뒤 자동 정리.

### 음악
- **모든 앱**(Safari·유튜브, Chrome, Spotify, Apple Music 등) 또는 Apple Music / Spotify만 (설정 → 상호작용 → 미디어).
- **컴팩트**: 왼쪽 앨범아트, 오른쪽에 앨범아트 색의 파형.
- **곡 변경**: 새 곡을 잠깐 크게 보여 줍니다 (선택, 기본은 Apple Music·Spotify에서만).
- **플레이어** (음악 표시 중 길게 누르기):
  - 흐르는 제목, 아티스트, 파형. 앨범아트를 누르면 재생 중인 앱이 열립니다.
  - 재생 바: 끌어서 이동. 커서를 올리면 살짝 굵어지고, 누른 채 조절하면 커지며 양옆 시간이 밀려납니다.
  - 이전 / 재생·일시정지 / 다음 — 앨범아트가 돌아가며 새 곡으로 바뀝니다 (다음·이전은 반대 방향).
  - ⭐ **즐겨찾기** — Apple Music의 즐겨찾기와 연동.
  - **출력 기기** 아이콘(맥북 스피커, 헤드폰, AirPods, 디스플레이, AirPlay 등): **클릭**하면 출력 기기 선택(연결이 끊긴 블루투스 헤드폰도 목록에 나오고 고르면 연결), **길게 누르면** 아래에 음량 바가 펼쳐집니다.
- 일시정지 후 N초 뒤 숨기기 (선택).
- 두 앱이 동시에 재생되면 **먼저 재생한 앱이 계속** 노치에 남고, 그 앱이 멈추거나 일시정지되면 다른 앱으로 넘어갑니다. 재생 소스를 Apple Music이나 Spotify로 정하면 다른 앱(브라우저의 유튜브 등)이 대신 표시되지 않습니다.

### 전화
iPhone 전화(연속성)와 FaceTime 오디오 통화가 노치에 나타납니다.
- **수신** — 노치가 확장되며 상대(저장된 연락처면 이름, 아니면 번호. 긴 번호는 흐름)와 빨간 **거절** / 초록 **받기** 버튼이 뜹니다. **두 손가락으로 위로 올리면** 거절하지 않고 카드만 접히고 작은 수신 표시가 남습니다. 누르면 다시 펼쳐집니다.
- **통화 중** — 왼쪽에 통화 시간, 오른쪽에 음성 파형.
- **길게 누르기** — 상대 아이콘과 이름, **음소거**·**끊기** 버튼. 음소거하면 파형이 일시정지한 음악처럼 멈춥니다.
- macOS 통화 배너를 손쉬운 사용으로 읽고 그 버튼을 눌러 동작합니다(시스템 통화 서비스는 Apple 앱 전용). 설정 → 상호작용 → 전화에서 끌 수 있습니다.

### 시스템 HUD 대체
음량·화면 밝기·키보드 밝기 키를 누르면 macOS HUD 대신 노치 HUD가 뜹니다. 왼쪽 아이콘, 오른쪽 숫자·가로 바·원형 중 선택. 음량 HUD에 출력 기기 아이콘을 표시할 수 있고, 제어 센터에서 바꾼 값도 표시할 수 있습니다.

### 알림
- **네트워크** — Wi-Fi 켜짐/꺼짐, 연결/해제(네트워크 이름), **VPN** 연결/해제(시스템 VPN과 NordVPN·WireGuard 같은 앱 VPN), 개인용 핫스팟(상시 표시 가능), 모든 네트워크가 끊기면 카드로 알림.
- **블루투스** — 기기별 아이콘(AirPods 모델, 헤드폰, 마우스, 키보드, 게임패드)과 배터리(AirPods: 왼쪽/오른쪽/케이스). 백분율·원형·둘 다 중 선택, 15% 미만은 빨간색. iPhone·iPad는 제외.
- **집중 모드** — 켜지면 모드 고유 아이콘·색, 꺼지면 같은 아이콘을 반투명하게. 켜진 동안 상시 표시 가능.
- **배터리** — 충전기 연결(잔량 + ⚡, 완충까지 남은 시간), 완충, 배터리 부족 경고(기준 조절 가능).
- **다운로드** — 다운로드 폴더(기본은 다운로드, 설정 → 상호작용 → 다운로드에서 바꿀 수 있고 추가 폴더도 지정 가능)의 Safari·Chrome·Firefox 다운로드 진행률, 끝나면 **Finder에서 보기** 버튼.
- **에어드랍** — 보내기 진행률과 결과, 받으면 알림.
- **스크린샷** — ⌘⇧3 / ⌘⇧4 / ⌘⇧5(클립보드·파일 모두) 후 미리보기 카드: **복사**, **저장**(`스크린샷_년_월_일_시_분_초`, PNG·JPEG, 데스크탑 또는 지정 폴더), **삭제**, 썸네일을 끌어 다른 앱에 첨부.
- **화면 녹화**(⌘⇧5, QuickTime) — 설정 → 상호작용 → 화면 녹화에서 녹화 시작 시 **잠깐 알림**만 띄울지, 노치에 **계속 표시**(왼쪽 빨간 점, 오른쪽 녹화 시간)할지 고릅니다. **왼쪽 빨간 점을 누르면 녹화가 멈추고 저장**됩니다(파일은 macOS가 평소처럼 저장). 길게 눌러 연 녹화 화면의 정지 아이콘도 같고, 누르면 **녹화 완료**와 **Finder에서 보기** 버튼이 나옵니다. 이 버튼이 여는 폴더(기본은 데스크탑)는 macOS 녹화 저장 위치에 맞춰 같은 페이지에서 바꿀 수 있습니다.

모든 알림은 **컴팩트·상세** 중 고를 수 있고 표시 시간도 바꿀 수 있습니다. **컴팩트 알림을 길게 누르면** 상세 카드로 바뀌고, 상세 알림은 클릭에만 반응합니다.

### 라이브 활동 우선순위
여러 활동(화면 녹화, 타이머, 에어드랍, 다운로드, 음악, 핫스팟, 집중 모드)이 동시에 진행되면 **설정 → 우선순위**에서 위에 있는 것이 표시됩니다. 화살표로 순서를 바꿉니다. 길게 눌러 팝업을 열면 아래 점이나 두 손가락 좌우로 다른 상시 항목을 넘겨 볼 수 있습니다(음악 팝업에서는 좌우가 곡 넘기기라 점을 누르세요). 닫으면 다시 우선순위가 가장 높은 항목이 표시됩니다.

### Claude Code · Codex
Claude Code·Codex 작업이 끝나면 노치에 **완료**가 뜨고, 누르면 그 작업이 돌던 앱(터미널·VS Code·Claude·Codex 등)이 열립니다. 컴팩트(아이콘·완료) 또는 상세("Claude Code · 프로젝트"와 끝난 작업 = 마지막으로 보낸 요청)를 고를 수 있습니다. 설정 → 상호작용 → Claude Code · Codex에서 **연결**을 누르면 `~/.claude/settings.json`에 작업 완료(Stop) 훅을, `~/.codex/config.toml`의 `notify`에 이 앱을 넣습니다. Codex에 원래 notify가 있었다면 그 명령도 그대로 실행되고, 연결 해제 시 원래대로 돌아갑니다. 처음 바꾸기 전 원본은 `.dynamicmacnotch.bak`으로 남깁니다.

### 잠금화면
- 잠그면 노치에 자물쇠가, 풀면 고리가 열리는 애니메이션이 나옵니다.
- 음악 재생 중에는 프로필 사진·암호 입력란 위에 **미디어 위젯**이 뜹니다. 앨범아트를 누르면 전체화면 플레이어(앨범아트, 조작 버튼, **가사**: Apple Music, LRCLIB 실시간 가사는 선택)로 커집니다. 진행 바·음량 바를 끌어 이동·조절하고, 출력 아이콘을 눌러 스피커·이어폰을 바꿀 수 있습니다. 곡 정보 숨기기 가능. 화면 보호기가 도는 동안에는 숨겨집니다.

### 테스트·미리보기
**설정 → 테스트**에서 모든 기능(네트워크, 블루투스, 집중 모드, HUD, 배터리, 다운로드, 에어드랍, 스크린샷, 화면 녹화, 타이머, 일정, 전화, 잠금화면)을 노치에 미리 띄워 볼 수 있습니다. 실제 설정·파일·통화에는 영향이 없습니다. 컴팩트·상세를 고를 수 있는 알림은 묶음마다 형태를 골라 볼 수 있고, 나머지는 "컴팩트로만 표시"·"상세로만 표시"로 나뉘어 있습니다.
- **음악 재생 테스트**는 테스트 곡을 재생하며 플레이어 조작을 시험할 수 있습니다. **테스트 중지**로 끝내거나, 30초 동안 조작이 없으면 자동으로 중지됩니다.
- **모든 미리보기 중지**로 한 번에 끝낼 수 있습니다. 미리보기는 끝나면 타이머·가짜 항목을 모두 정리해 계속 실행되는 것이 남지 않습니다.

### 설정 창
왼쪽 사이드바에 **일반**, **우선순위**, **상호작용**, **테스트**, **권한 관리**, **정보**가 있습니다. 상호작용 옆 화살표를 누르면 기능별 페이지(네트워크, 블루투스, 방해금지 모드, 전화, 미디어, 다운로드, 에어드랍 및 파일 트레이, 스크린샷, 화면 녹화, 배터리 및 충전, HUD, 잠금화면)가 펼쳐집니다. 모든 기능 페이지는 표시 → 표시 방식 → 세부 설정 → 미리보기 순서로 같습니다. 사이드바는 macOS 26 이상에서 Liquid Glass로 그려지고, 창의 흐림과 투명도는 설정 → 일반에서 조절합니다.

### 언어
한국어와 영어. 설정 → 일반 → 언어(시스템 설정 따름 / 한국어 / English) 선택 후 **지금 다시 시작**.

## 개인정보

- 분석·계정·추적이 없습니다. 설정과 트레이 항목은 내 Mac에만 저장됩니다.
- 네트워크는 다음 경우에만 씁니다.
  - **업데이트 확인**(하루 한 번, 끌 수 있음): GitHub 릴리스 API.
  - **실시간 가사**(기본 꺼짐): 곡 제목·아티스트·앨범을 [LRCLIB](https://lrclib.net)로 보냅니다.
  - **Spotify 앨범아트**: Spotify가 알려 주는 표지 이미지 주소(HTTPS만).
- 저장 위치: `~/Library/Preferences/com.dynamicmacnotch.app.plist`, `~/Library/Application Support/Dynamic MacNotch/`. 둘 다 지우면 초기화됩니다.

## 메모리

- 스크린샷 썸네일과 PNG·JPEG 변환은 잠깐 떴다 끝나는 도우미 프로세스가 처리해, 전체 화면 이미지 때문에 앱 메모리가 늘지 않습니다.
- **메모리 자동 최적화**(설정 → 일반, 기본 켬): 5분마다, 그리고 큰 작업 뒤에 앱의 메모리를 확인합니다. 정한 기준(70~150MB, 기본 70)을 넘으면 캐시를 비우고, 그래도 넘으면 쉬는 동안(노치가 닫혀 있고 진행 중인 작업이 없을 때) 조용히 다시 시작합니다. 음악은 원래 앱에서 계속 재생되고, 노치는 1초 안에 돌아옵니다.

## 참고 및 제한

- 일부 기능(잠금화면 창, 재생 정보, 밝기, 키보드 백라이트)은 macOS 비공개 API를 씁니다. 동적으로 불러와 실패해도 앱이 멈추지 않지만, macOS 업데이트 후 동작하지 않을 수 있습니다.
- AirPods 듣기 모드(노이즈 캔슬링·주변음 허용)는 macOS에서 다른 앱이 읽을 수 없어 지원하지 않습니다.
- 시스템 전체의 키·창 접근이 필요해 샌드박스가 아니며, 공증되지 않았습니다.

## 소스에서 빌드

Apple Silicon Mac과 Xcode Command Line Tools(Swift 5.10 이상)가 필요합니다.

```bash
git clone https://github.com/tjehddnr2864-hue/Dynamic-MacNotch.git
cd Dynamic-MacNotch
scripts/build.sh --run            # build/Dynamic MacNotch.app
scripts/build.sh --zip            # + 배포용 zip과 SHA-256
scripts/build.sh --install --run  # /Applications 에 설치
```

`--dev`는 `scripts/notchctl` 테스트 명령을 받는 개발용 빌드입니다 (배포하지 마세요).
