import AppKit

/// 에어드랍·트레이 칸을 클릭했을 때 여는 파일 선택 창.
/// 열기 패널은 Finder 사이드바·미리보기 등 무거운 프레임워크를 불러와 본 앱 메모리를 크게 늘리고 돌려주지 않으므로,
/// 같은 실행 파일을 `--pick=airdrop|tray`로 띄운 짧은 도우미 프로세스에서 열고, 고른 경로만 표준 출력(NUL 구분)으로 받는다.
enum FilePicker {
    enum Purpose: String { case airdrop, tray }

    static func purpose(from arguments: [String]) -> Purpose? {
        arguments.first { $0.hasPrefix("--pick=") }.flatMap { Purpose(rawValue: String($0.dropFirst("--pick=".count))) }
    }

    private static var running: Process?

    /// 본 앱: 도우미를 띄우고, 고른 파일을 메인 스레드로 돌려준다 (취소하면 호출하지 않음).
    static func choose(_ purpose: Purpose, completion: @escaping ([URL]) -> Void) {
        // 이미 열려 있으면 새로 띄우지 않는다 (연타 방지)
        if let p = running, p.isRunning { return }
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--pick=" + purpose.rawValue]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            running = p
        } catch {
            NSLog("DynamicMacNotch: failed to launch file picker helper: \(error)")
            return
        }
        // 출력은 백그라운드에서 끝(도우미 종료)까지 읽는다.
        // 끝난 뒤에 읽으면 파일을 아주 많이 골랐을 때 파이프 버퍼가 차서 서로 기다리게 된다.
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let urls = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\0")   // 파일 이름에 줄바꿈이 있어도 안전하도록 NUL로 구분
                .map { URL(fileURLWithPath: String($0)) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            DispatchQueue.main.async {
                running = nil
                if !urls.isEmpty { completion(urls) }
            }
        }
    }
}

/// 도우미 프로세스: 열기 패널을 띄우고 고른 경로를 NUL로 구분해 출력한 뒤 끝난다.
final class FilePickerDelegate: NSObject, NSApplicationDelegate {
    private let purpose: FilePicker.Purpose

    init(purpose: FilePicker.Purpose) {
        self.purpose = purpose
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 본 앱이 끝나면 함께 끝낸다.
        let source = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
        source.setEventHandler { exit(0) }
        source.resume()
        parentWatch = source

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        switch purpose {
        case .airdrop:
            panel.title = T("에어드랍으로 보낼 파일", "Files to AirDrop")
            panel.message = T("에어드랍으로 보낼 파일이나 폴더를 고르세요", "Choose files or folders to send with AirDrop")
            panel.prompt = T("에어드랍", "AirDrop")
        case .tray:
            panel.title = T("트레이에 추가할 파일", "Files to Add to Tray")
            panel.message = T("트레이에 보관할 파일이나 폴더를 고르세요", "Choose files or folders to keep in the tray")
            panel.prompt = T("트레이에 추가", "Add to Tray")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if response == .OK {
            let out = panel.urls.map(\.path).joined(separator: "\0")
            FileHandle.standardOutput.write(Data(out.utf8))
        }
        exit(0)
    }

    private var parentWatch: DispatchSourceProcess?
}
