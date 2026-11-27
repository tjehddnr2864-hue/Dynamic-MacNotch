import AppKit

// 하위 프로세스(미디어 어댑터·도우미)가 먼저 끝난 파이프에 써도 앱이 종료되지 않게 한다
signal(SIGPIPE, SIG_IGN)

#if DEV
ChatProbe.runIfRequested()
#endif

if let agent = AgentNotify.source(from: CommandLine.arguments) {
    AgentNotify.runHook(agent, arguments: CommandLine.arguments)   // 코딩 에이전트 작업 완료 훅: 알리고 바로 종료
}

if let agent = AgentAsk.source(from: CommandLine.arguments) {
    AgentAsk.runHook(agent, arguments: CommandLine.arguments)   // 코딩 에이전트의 질문: 노치에서 답할 때까지 기다렸다가 답을 돌려줌
}

if let op = ChatAttachTool.op(from: CommandLine.arguments) {
    ChatAttachTool.runHelper(op, arguments: CommandLine.arguments)   // 채팅 첨부 처리 도우미: 처리 후 바로 종료
}

if let op = ImageTool.op(from: CommandLine.arguments) {
    ImageTool.runHelper(op)   // 스크린샷 썸네일·변환 도우미: 처리 후 바로 종료
}

#if DEV
DisplayProbe.runIfRequested()
SettingsProbe.runIfRequested()
TrayProbe.runIfRequested()
AgentProbe.runIfRequested()
MonitorProbe.runIfRequested()
#endif

// 이 빌드에 없는 점검 명령이면 앱을 켜지 않고 끝낸다 (설치된 앱과 겹쳐 개발 빌드가 노치 앱으로 떠 있게 되는 일을 막음)
if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") && $0.contains("-probe") }) { exit(2) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if let services = UsageWeb.services(from: CommandLine.arguments) {
    // AI 사용량 조회 도우미: 웹에서 읽어 JSON을 출력하고 끝남 (WebKit 메모리는 끝나면 반환)
    AppSettings.isHelper = true
    app.setActivationPolicy(.prohibited)
    let fetcher = UsageFetchDelegate(services: services)
    app.delegate = fetcher
    app.run()
} else if let purpose = FilePicker.purpose(from: CommandLine.arguments) {
    // 에어드랍·트레이 파일 선택 창 전용 도우미 프로세스 (고른 경로를 출력하고 끝남)
    AppSettings.isHelper = true
    let picker = FilePickerDelegate(purpose: purpose)
    app.delegate = picker
    app.run()
} else if let mode = Helper.mode(from: CommandLine.arguments) {
    // 설정·권한 창 전용 도우미 프로세스
    AppSettings.isHelper = true
    let helper = HelperDelegate(mode: mode)
    app.delegate = helper
    app.run()
} else {
    #if DEV
    // 개발 빌드는 이름과 번들 ID가 설치된 앱과 같아, Spotlight 등에서 잘못 열릴 수 있다.
    // scripts/build.sh --dev --run으로 켠 것이 아니면 설치된 앱을 대신 열고 끝낸다.
    let installed = URL(fileURLWithPath: "/Applications/Dynamic MacNotch.app")
    if !CommandLine.arguments.contains("--dev-run"), Bundle.main.bundleURL.path != installed.path, FileManager.default.fileExists(atPath: installed.path) {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [installed.path]
        try? opener.run()
        opener.waitUntilExit()
        exit(0)
    }
    #endif
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
