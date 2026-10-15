import AppKit

/// 잠금화면 위에 창을 띄우기 위한 SkyLight(비공개) 래퍼 (가이드라인 5.12, 8장 리스크).
/// 절대 레벨이 높은 전용 Space를 만들고 창을 그 Space로 옮긴다. 심볼이 없으면 아무것도 하지 않는다.
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void   // 반환값 없음

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private static let mainConnection = sym("SLSMainConnectionID", MainConnection.self)
    private static let spaceCreate = sym("SLSSpaceCreate", SpaceCreate.self)
    private static let setLevel = sym("SLSSpaceSetAbsoluteLevel", SpaceSetLevel.self)
    private static let showSpaces = sym("SLSShowSpaces", ShowSpaces.self)
    private static let addWindows = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self)

    static var available: Bool {
        mainConnection != nil && spaceCreate != nil && setLevel != nil && showSpaces != nil && addWindows != nil
    }

    /// 잠금화면보다 위에 보이는 전용 Space (한 번만 만든다)
    private static var lockSpace: UInt64?

    private static func space() -> (Int32, UInt64)? {
        guard available, let cid = mainConnection?() else { return nil }
        if let s = lockSpace { return (cid, s) }
        guard let s = spaceCreate?(cid, 1, nil), s != 0 else { return nil }
        _ = setLevel?(cid, s, 400)
        _ = showSpaces?(cid, [NSNumber(value: s)] as CFArray)
        lockSpace = s
        return (cid, s)
    }

    /// 창을 잠금화면 위 Space로 옮긴다. 성공하면 true.
    @discardableResult
    static func moveToLockScreenSpace(_ window: NSWindow) -> Bool {
        guard let (cid, s) = space(), window.windowNumber > 0 else { return false }
        guard let addWindows else { return false }
        addWindows(cid, s, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        return true
    }
}
