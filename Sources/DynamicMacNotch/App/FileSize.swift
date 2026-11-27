import Foundation

extension FileManager {
    /// 파일 크기(바이트). 읽을 수 없으면 0. (다운로드·채팅 첨부·요청 본문이 함께 쓴다)
    func fileSize(_ url: URL) -> Int64 {
        (try? attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
