import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 스크린샷 이미지 처리 도우미 프로세스.
/// 전체 화면 스크린샷을 디코딩하면 수십 MB를 쓰는데, 최신 macOS 할당기는 해제한 메모리를 운영체제에 돌려주지 않아
/// 본 앱의 사용량이 그대로 남는다. 그래서 썸네일·PNG·JPEG 변환은 같은 실행 파일을 `--imgtool=<작업>`으로 띄운
/// 짧은 도우미가 하고, 결과만 받는다. 도우미가 끝나면 그 메모리는 통째로 운영체제에 돌아간다.
enum ImageTool {
    enum Op: String { case thumb, png, jpeg }

    static func op(from arguments: [String]) -> Op? {
        arguments.first { $0.hasPrefix("--imgtool=") }.flatMap { Op(rawValue: String($0.dropFirst("--imgtool=".count))) }
    }

    // MARK: 도우미 쪽 (표준 입력 → 처리 → 표준 출력)

    static func runHelper(_ op: Op) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let out = convert(input, op) { FileHandle.standardOutput.write(out) }
        exit(0)
    }

    private static func convert(_ data: Data, _ op: Op) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let image: CGImage?
        switch op {
        case .thumb:
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 480,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        case .png, .jpeg:
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let image else { return nil }
        let out = NSMutableData()
        let type = (op == .jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let props: [CFString: Any] = op == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: 본 앱 쪽

    /// 백그라운드에서 도우미를 돌리고 결과를 메인 스레드로 돌려준다 (실패하면 nil, 최대 20초).
    static func process(_ op: Op, _ data: Data, completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = processSync(op, data)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 동기 실행 (끌어 놓기처럼 바로 파일이 필요할 때만)
    static func processSync(_ op: Op, _ data: Data) -> Data? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--imgtool=" + op.rawValue]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // 입력 쓰기와 출력 읽기를 따로 해야 큰 이미지에서 파이프가 막히지 않는다
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
            try? stdin.fileHandleForWriting.close()
        }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        return p.terminationStatus == 0 && !out.isEmpty ? out : nil
    }
}
