import AppKit

// 하위 프로세스(미디어 어댑터·도우미)가 먼저 끝난 파이프에 써도 앱이 종료되지 않게 한다
signal(SIGPIPE, SIG_IGN)

if let op = ImageTool.op(from: CommandLine.arguments) {
    ImageTool.runHelper(op)   // 스크린샷 썸네일·변환 도우미: 처리 후 바로 종료
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if let purpose = FilePicker.purpose(from: CommandLine.arguments) {
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
    Migration.run()   // AppSettings를 읽기 전에 예전 설정부터 옮긴다
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
