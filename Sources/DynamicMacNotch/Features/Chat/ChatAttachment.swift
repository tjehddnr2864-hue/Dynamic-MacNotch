import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 채팅에 붙인 파일 하나. 메모리에는 이 정보만 두고, 내용은 항상 파일로 다룬다.
struct ChatAttachment: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case image, pdf, text }

    var id: UUID
    /// 사용자가 본 파일 이름
    var name: String
    var kind: Kind
    /// 저장 폴더 안의 파일 이름
    var file: String
    var mime: String
    var bytes: Int64
    var pages: Int?
    var hasPreview: Bool

    var previewFile: String { id.uuidString + ".preview.jpg" }

    /// 요청 본문에서 차지하는 크기 (base64)
    var requestBytes: Int64 { kind == .text ? bytes : bytes * 4 / 3 }

    /// 모델에게 보여 줄 이름 (줄바꿈·기호로 지시문을 꾸밀 수 없게 한다)
    var safeName: String {
        let cleaned = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"<>[]\"`".unicodeScalars.contains($0) }
        return String(String.UnicodeScalarView(cleaned).prefix(80))
    }
}

enum ChatAttachLimit {
    static let images = 4
    static let imageSourceBytes: Int64 = 20 * 1024 * 1024
    static let pdfs = 1
    static let pdfBytes: Int64 = 10 * 1024 * 1024
    static let pdfPages = 30
    static let textBytes: Int64 = 200 * 1024
    static let textTotalBytes: Int64 = 400 * 1024
    static let wordSourceBytes: Int64 = 10 * 1024 * 1024
    /// 세 서비스를 모두 통과하는 요청 본문 크기
    static let requestBytes: Int64 = 18 * 1024 * 1024
    /// 이미지 긴 변
    static let imageLongEdge = 1568
}

enum ChatAttachError: String, Error {
    case requestTooLarge, unsupported, tooManyImages, tooManyPDFs, imageTooLarge, pdfTooLarge, pdfTooManyPages, pdfLocked, textTooLarge, textTotalTooLarge, wordTooLarge, unreadable

    var message: String {
        switch self {
        case .requestTooLarge: return T("첨부가 너무 큽니다. 질문당 합계 약 13MB까지입니다", "Attachments are too large. About 13 MB in total per question")
        case .unsupported: return T("이미지, PDF, 텍스트, 워드 파일만 첨부할 수 있습니다", "Only images, PDF, text and Word files can be attached")
        case .tooManyImages: return T("이미지는 질문당 \(ChatAttachLimit.images)장까지입니다", "Up to \(ChatAttachLimit.images) images per question")
        case .tooManyPDFs: return T("PDF는 질문당 \(ChatAttachLimit.pdfs)개까지입니다", "Up to \(ChatAttachLimit.pdfs) PDF per question")
        case .imageTooLarge: return T("이미지는 20MB까지입니다", "Images can be up to 20 MB")
        case .pdfTooLarge: return T("PDF는 10MB까지입니다", "PDFs can be up to 10 MB")
        case .pdfTooManyPages: return T("PDF는 \(ChatAttachLimit.pdfPages)쪽까지입니다", "PDFs can have up to \(ChatAttachLimit.pdfPages) pages")
        case .pdfLocked: return T("암호가 걸린 PDF는 첨부할 수 없습니다", "Password-protected PDFs can't be attached")
        case .textTooLarge: return T("텍스트는 파일당 200KB까지입니다", "Text can be up to 200 KB per file")
        case .textTotalTooLarge: return T("텍스트는 합계 400KB까지입니다", "Text can be up to 400 KB in total")
        case .wordTooLarge: return T("워드 파일은 10MB까지입니다", "Word files can be up to 10 MB")
        case .unreadable: return T("파일을 읽지 못했습니다", "Couldn't read the file")
        }
    }
}

/// 첨부 파일의 저장 위치. 채팅마다 `Chats/<채팅 ID>/`, 보내기 전에는 `Chats/Pending/`.
enum ChatFiles {
    static var pending: URL { ChatStore.folder.appendingPathComponent("Pending", isDirectory: true) }

    static func folder(_ chat: UUID) -> URL { ChatStore.folder.appendingPathComponent(chat.uuidString, isDirectory: true) }

    /// 내 계정만 읽을 수 있는 폴더를 만든다
    @discardableResult
    static func prepare(_ url: URL) -> URL {
        let manager = FileManager.default
        try? manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ChatStore.folder.path)
        return url
    }

    static func move(_ attachment: ChatAttachment, from source: URL, to destination: URL) {
        prepare(destination)
        let names = [attachment.file] + (attachment.hasPreview ? [attachment.previewFile] : [])
        for name in names {
            try? FileManager.default.moveItem(at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
    }

    static func remove(_ attachment: ChatAttachment, in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(attachment.file))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(attachment.previewFile))
    }

    /// 앱을 시작할 때: 보내지 않은 첨부와 대화가 사라진 폴더, 남은 요청 본문을 지운다
    static func sweep() {
        let manager = FileManager.default
        try? manager.removeItem(at: pending)
        try? manager.removeItem(at: ChatBody.folder)
        let items = (try? manager.contentsOfDirectory(at: ChatStore.folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard UUID(uuidString: item.lastPathComponent) != nil else { continue }
            let record = ChatStore.folder.appendingPathComponent(item.lastPathComponent + ".json")
            if !manager.fileExists(atPath: record.path) { try? manager.removeItem(at: item) }
        }
    }

    /// 파일 이름만 보고 종류를 정한다 (내용은 도우미가 읽는다)
    static func classify(_ url: URL) -> ChatAttachTool.Op? {
        let ext = url.pathExtension.lowercased()
        if ["docx", "doc", "rtf", "odt"].contains(ext) { return .word }
        guard let type = UTType(filenameExtension: ext) else { return ext.isEmpty ? nil : nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || type.conforms(to: .commaSeparatedText) || type.conforms(to: .xml) || type.conforms(to: .propertyList) { return .text }
        return nil
    }
}

/// 후속 질문에서 지난 첨부를 다시 보낼지 정한다.
/// ① 질문이 파일을 가리키면 바로 함께 보내고 ② 나머지는 이름만 알려 모델이 필요할 때 요청하게 한다.
/// 파일을 매번 보내면 요금·구독 한도를 쓰고, 안 보내면 "아까 그 그림"에 답하지 못하기 때문이다.
enum ChatAttachPolicy {
    private static let imageWords = ["사진", "그림", "이미지", "스크린샷", "캡처", "photo", "picture", "image", "screenshot"]
    private static let documentWords = ["pdf", "문서", "보고서", "페이지", "워드", "document", "report", "page"]
    private static let textWords = ["문서", "텍스트", "워드", "파일 내용", "document", "text file", "word file"]
    private static let anyWords = ["첨부", "올린 파일", "보낸 파일", "그 파일", "이 파일", "위 파일", "아까 파일", "attached", "attachment", "uploaded", "that file", "this file", "the file"]

    /// earlier: 오래된 것부터. 돌려줄 때 direct는 바로 보낼 것, offered는 이름만 알릴 것.
    static func plan(question: String, earlier: [ChatAttachment], budget: Int64) -> (direct: [ChatAttachment], offered: [ChatAttachment]) {
        guard !earlier.isEmpty else { return ([], []) }
        let q = question.lowercased()
        var chosen = Set<UUID>()
        for item in earlier {
            let stem = (item.name as NSString).deletingPathExtension.lowercased()
            if q.contains(item.name.lowercased()) || (stem.count >= 3 && q.contains(stem)) { chosen.insert(item.id) }
        }
        func newest(_ kind: ChatAttachment.Kind) {
            if let last = earlier.last(where: { $0.kind == kind }) { chosen.insert(last.id) }
        }
        if imageWords.contains(where: q.contains) { newest(.image) }
        if documentWords.contains(where: q.contains) { newest(.pdf) }
        if textWords.contains(where: q.contains) { newest(.text) }
        if chosen.isEmpty, anyWords.contains(where: q.contains), let last = earlier.last { chosen.insert(last.id) }
        // 최근 것부터 예산 안에서
        var direct: [ChatAttachment] = []
        var left = budget
        for item in earlier.reversed() where chosen.contains(item.id) && item.requestBytes <= left {
            direct.insert(item, at: 0)
            left -= item.requestBytes
        }
        let directIDs = Set(direct.map(\.id))
        return (direct, earlier.filter { !directIDs.contains($0.id) })
    }

    /// 모델에게 알리는 지난 첨부 목록과 요청 방법
    static func notice(_ offered: [ChatAttachment]) -> String? {
        guard !offered.isEmpty else { return nil }
        let lines = offered.enumerated().map { index, item -> String in
            let kind: String
            switch item.kind {
            case .image: kind = "image"
            case .pdf: kind = "PDF" + (item.pages.map { ", \($0) pages" } ?? "")
            case .text: kind = "text"
            }
            return "[\(index + 1)] \(item.safeName) (\(kind))"
        }.joined(separator: "\n")
        return """
        The user attached these files earlier in this conversation. You can't see them in this message:
        \(lines)
        Earlier answers may already contain what you need, and many questions don't need them at all. \
        Only if you must read a file to answer correctly, reply with exactly [[NEED_FILES: 1]] (listing the numbers) and nothing else. \
        You'll then receive the files and can answer. Never mention this mechanism to the user.
        """
    }

    private static let marker = try? NSRegularExpression(pattern: #"\[\[NEED_FILES:\s*([0-9,\s]*)\]\]"#)

    /// 답변에서 파일 요청을 찾는다. 요청이 없으면 nil.
    static func requested(in answer: String) -> [Int]? {
        let range = NSRange(location: 0, length: (answer as NSString).length)
        guard let match = marker?.firstMatch(in: answer, range: range) else { return nil }
        return (answer as NSString).substring(with: match.range(at: 1)).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    static func withoutMarker(_ answer: String) -> String {
        let range = NSRange(location: 0, length: (answer as NSString).length)
        return (marker?.stringByReplacingMatches(in: answer, range: range, withTemplate: "") ?? answer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 첨부 처리 도우미 프로세스 (`--attach=<종류> 원본 폴더 ID`).
/// 큰 이미지를 푸는 메모리는 본 앱으로 돌아오지 않으므로(ImageTool과 같은 이유) 짧은 프로세스에서 처리하고
/// 결과 파일과 정보만 받는다. 이미지는 다시 인코딩하므로 위치·카메라 정보가 함께 사라진다.
enum ChatAttachTool {
    enum Op: String { case image, pdf, word, text }

    static func op(from arguments: [String]) -> Op? {
        arguments.first { $0.hasPrefix("--attach=") }.flatMap { Op(rawValue: String($0.dropFirst("--attach=".count))) }
    }

    private struct Output: Codable {
        var attachment: ChatAttachment?
        var error: String?
    }

    // MARK: 도우미 쪽

    static func runHelper(_ op: Op, arguments: [String]) -> Never {
        let parts = Array(arguments.drop { !$0.hasPrefix("--attach=") }.dropFirst())
        guard parts.count >= 3, let id = UUID(uuidString: parts[2]) else { exit(2) }
        let source = URL(fileURLWithPath: parts[0]), folder = URL(fileURLWithPath: parts[1])
        let name = parts.count > 3 ? parts[3] : source.lastPathComponent
        var output = Output()
        do {
            switch op {
            case .image: output.attachment = try image(source, folder, id, name)
            case .pdf: output.attachment = try pdf(source, folder, id, name)
            case .word: output.attachment = try word(source, folder, id, name)
            case .text: output.attachment = try text(source, folder, id, name)
            }
        } catch {
            output.error = (error as? ChatAttachError)?.rawValue ?? ChatAttachError.unreadable.rawValue
        }
        if let data = try? JSONEncoder().encode(output) { FileHandle.standardOutput.write(data) }
        exit(0)
    }

    private static func write(_ image: CGImage, to url: URL, png: Bool) throws {
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { throw ChatAttachError.unreadable }
        CGImageDestinationAddImage(destination, image, (png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.8]) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ChatAttachError.unreadable }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func image(_ source: URL, _ folder: URL, _ id: UUID, _ name: String) throws -> ChatAttachment {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw ChatAttachError.unreadable }
        func scaled(_ edge: Int) -> CGImage? {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: edge,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        }
        guard let reduced = scaled(ChatAttachLimit.imageLongEdge) else { throw ChatAttachError.unreadable }
        // 투명한 그림만 PNG로 두고 나머지는 JPEG (세 서비스가 모두 받는다)
        let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let png = properties?[kCGImagePropertyHasAlpha] as? Bool == true && CGImageSourceGetType(src) as String? == UTType.png.identifier
        var file = id.uuidString + (png ? ".png" : ".jpg")
        var isPNG = png
        try write(reduced, to: folder.appendingPathComponent(file), png: png)
        // 투명 PNG가 크면 흰 배경에 얹어 JPEG로 바꾼다 (사진을 PNG로 저장한 경우 등)
        if png, size(folder.appendingPathComponent(file)) > 1_500_000, let flat = flattened(reduced) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            file = id.uuidString + ".jpg"
            isPNG = false
            try write(flat, to: folder.appendingPathComponent(file), png: false)
        }
        let attachment = ChatAttachment(id: id, name: name, kind: .image, file: file, mime: isPNG ? "image/png" : "image/jpeg",
                                        bytes: size(folder.appendingPathComponent(file)), pages: nil, hasPreview: true)
        if let preview = scaled(96) { try write(preview, to: folder.appendingPathComponent(attachment.previewFile), png: false) }
        return attachment
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    private static func pdf(_ source: URL, _ folder: URL, _ id: UUID, _ name: String) throws -> ChatAttachment {
        guard let document = CGPDFDocument(source as CFURL) else { throw ChatAttachError.unreadable }
        guard document.isUnlocked, !document.isEncrypted else { throw ChatAttachError.pdfLocked }
        guard document.numberOfPages <= ChatAttachLimit.pdfPages else { throw ChatAttachError.pdfTooManyPages }
        let file = id.uuidString + ".pdf"
        let destination = folder.appendingPathComponent(file)
        try FileManager.default.copyItem(at: source, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var attachment = ChatAttachment(id: id, name: name, kind: .pdf, file: file, mime: "application/pdf",
                                        bytes: size(destination), pages: document.numberOfPages, hasPreview: false)
        if let page = document.page(at: 1) {
            let box = page.getBoxRect(.mediaBox)
            let scale = 96 / max(box.width, box.height, 1)
            let width = max(Int(box.width * scale), 1), height = max(Int(box.height * scale), 1)
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -box.minX, y: -box.minY)
                context.drawPDFPage(page)
                if let image = context.makeImage() {
                    try write(image, to: folder.appendingPathComponent(attachment.previewFile), png: false)
                    attachment.hasPreview = true
                }
            }
        }
        return attachment
    }

    /// 워드 파일은 Claude가 직접 읽지 못하므로 글자만 뽑아 텍스트로 보낸다 (이미지·표 모양은 빠진다)
    private static func word(_ source: URL, _ folder: URL, _ id: UUID, _ name: String) throws -> ChatAttachment {
        guard let document = try? NSAttributedString(url: source, options: [:], documentAttributes: nil) else { throw ChatAttachError.unreadable }
        return try saveText(document.string, folder, id, name)
    }

    private static func text(_ source: URL, _ folder: URL, _ id: UUID, _ name: String) throws -> ChatAttachment {
        let data = try Data(contentsOf: source)
        guard !data.contains(0) else { throw ChatAttachError.unsupported }
        let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: korean) else { throw ChatAttachError.unreadable }
        return try saveText(string, folder, id, name)
    }

    private static func saveText(_ string: String, _ folder: URL, _ id: UUID, _ name: String) throws -> ChatAttachment {
        let data = Data(string.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { throw ChatAttachError.unreadable }
        guard Int64(data.count) <= ChatAttachLimit.textBytes else { throw ChatAttachError.textTooLarge }
        let file = id.uuidString + ".txt"
        let destination = folder.appendingPathComponent(file)
        try data.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return ChatAttachment(id: id, name: name, kind: .text, file: file, mime: "text/plain", bytes: Int64(data.count), pages: nil, hasPreview: false)
    }

    // MARK: 본 앱 쪽

    /// 도우미를 돌려 결과를 받는다 (백그라운드에서 부른다, 최대 30초)
    static func process(_ op: Op, source: URL, folder: URL, name: String) -> Result<ChatAttachment, ChatAttachError> {
        guard let executable = Bundle.main.executableURL else { return .failure(.unreadable) }
        ChatFiles.prepare(folder)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--attach=" + op.rawValue, source.path, folder.path, UUID().uuidString, name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(.unreadable) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard let result = try? JSONDecoder().decode(Output.self, from: data) else { return .failure(.unreadable) }
        if let attachment = result.attachment { return .success(attachment) }
        return .failure(result.error.flatMap(ChatAttachError.init(rawValue:)) ?? .unreadable)
    }
}

/// 첨부가 있는 요청 본문을 파일로 만든다. 원본·base64·JSON을 메모리에 올리지 않으므로 파일이 커도 메모리가 늘지 않는다.
enum ChatBody {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("DynamicMacNotchChatBody", isDirectory: true) }

    static func token(_ index: Int) -> String { "@@DMNFILE\(index)@@" }

    /// json 안의 표식 자리에 파일의 base64를 끼워 쓴다
    static func write(json: Data, files: [URL]) -> URL? {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(UUID().uuidString)
        guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let writer = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? writer.close() }
        var rest = json[...]
        do {
            for (index, file) in files.enumerated() {
                guard let range = rest.range(of: Data(token(index).utf8)) else { throw ChatAttachError.unreadable }
                try writer.write(contentsOf: rest[..<range.lowerBound])
                let reader = try FileHandle(forReadingFrom: file)
                defer { try? reader.close() }
                // 3의 배수 단위로 읽어야 조각을 이어 붙여도 올바른 base64가 된다
                while true {
                    var finished = false
                    try autoreleasepool {
                        guard let chunk = try reader.read(upToCount: 192 * 1024), !chunk.isEmpty else {
                            finished = true
                            return
                        }
                        try writer.write(contentsOf: chunk.base64EncodedData())
                    }
                    if finished { break }
                }
                rest = rest[range.upperBound...]
            }
            try writer.write(contentsOf: rest)
        } catch {
            try? manager.removeItem(at: url)
            return nil
        }
        return url
    }

    static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
