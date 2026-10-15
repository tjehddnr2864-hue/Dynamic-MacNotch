import CoreGraphics
import ImageIO
import Accelerate

/// 이미지 디코딩·축소·평균색 계산.
/// 이 macOS에서는 CoreGraphics의 `CGContext.draw(큰 이미지)`가 호출할 때마다 수백 KB를 놓아주지 않으므로
/// (스크린샷·앨범아트가 바뀔 때마다 메모리가 계속 늘어남) Accelerate(vImage)로 픽셀을 직접 다룬다.
enum ImageScaler {
    private static let rgba = CGImageAlphaInfo.premultipliedLast.rawValue

    private static func format() -> vImage_CGImageFormat {
        vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                             colorSpace: Unmanaged.passUnretained(CGColorSpaceCreateDeviceRGB()),
                             bitmapInfo: CGBitmapInfo(rawValue: rgba), version: 0, decode: nil,
                             renderingIntent: .defaultIntent)
    }

    /// 데이터(PNG·JPEG·TIFF)를 캐시 없이 디코딩
    static func decode(_ data: Data) -> CGImage? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, noCache) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, noCache)
    }

    /// 긴 변이 maxPixels를 넘지 않게 고품질로 축소 (이미 작으면 그대로)
    static func scaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let w = image.width, h = image.height
        let scale = min(1, Double(maxPixels) / Double(max(w, h)))
        guard scale < 1 else { return image }
        return resample(image, width: max(1, Int(Double(w) * scale)), height: max(1, Int(Double(h) * scale)))
    }

    static func resample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        var fmt = format()
        var src = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&src, &fmt, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(src.data) }
        var dst = vImage_Buffer()
        guard vImageBuffer_Init(&dst, vImagePixelCount(height), vImagePixelCount(width), 32,
                                vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(dst.data) }
        vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        return vImageCreateCGImageFromBuffer(&dst, &fmt, nil, nil, vImage_Flags(kvImageNoFlags), nil)?.takeRetainedValue()
    }

    /// 배경용 흐린 이미지: 아주 작게(48px) 줄인 뒤 흐리게 한다. 화면 전체로 늘려 써도 원래 흐린 그림이라 티가 나지 않고,
    /// 큰 이미지에 실시간 블러를 거는 것보다 메모리·CPU를 훨씬 적게 쓴다.
    static func blurredBackdrop(_ image: CGImage) -> CGImage? {
        guard let small = resample(image, width: 48, height: 48) else { return nil }
        var fmt = format()
        var src = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&src, &fmt, nil, small, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(src.data) }
        var dst = vImage_Buffer()
        guard vImageBuffer_Init(&dst, 48, 48, 32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(dst.data) }
        vImageTentConvolve_ARGB8888(&src, &dst, nil, 0, 0, 13, 13, nil, vImage_Flags(kvImageEdgeExtend))
        return vImageCreateCGImageFromBuffer(&dst, &fmt, nil, nil, vImage_Flags(kvImageNoFlags), nil)?.takeRetainedValue()
    }

    /// 평균색 (0...1 RGB). 8×8로 줄인 뒤 픽셀을 평균한다.
    static func averageColor(_ image: CGImage) -> (r: Double, g: Double, b: Double)? {
        var fmt = format()
        var src = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&src, &fmt, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(src.data) }
        var dst = vImage_Buffer()
        guard vImageBuffer_Init(&dst, 8, 8, 32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(dst.data) }
        vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in 0..<8 {
            let row = dst.data.advanced(by: y * dst.rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<8 {
                let p = row.advanced(by: x * 4)
                r += Double(p[0]); g += Double(p[1]); b += Double(p[2]); n += 1
            }
        }
        return (r / n / 255, g / n / 255, b / n / 255)
    }
}
