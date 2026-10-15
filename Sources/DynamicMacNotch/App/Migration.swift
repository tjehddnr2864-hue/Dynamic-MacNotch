import Foundation

/// 예전 이름(NotchIsland, com.local.notchisland)으로 쓰던 설정을 처음 실행할 때 한 번 옮겨 온다.
/// 앱 식별자가 바뀌면 macOS가 다른 앱으로 보므로 설정 저장소도 새로 시작되기 때문이다.
/// (macOS 권한은 옮길 수 없어 권한 관리 창에서 다시 허용해야 한다)
enum Migration {
    private static let doneKey = "migratedFromNotchIsland"
    private static let oldDomain = "com.local.notchisland" as CFString

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        d.set(true, forKey: doneKey)
        // 그 도메인에 저장된 키만 읽는다 (UserDefaults(suiteName:)은 전역 설정까지 섞어 돌려줌)
        guard let keys = CFPreferencesCopyKeyList(oldDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty,
              let values = CFPreferencesCopyMultiple(keys as CFArray, oldDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [String: Any] else { return }
        // 새 앱은 macOS 권한을 다시 받아야 하므로 '처음 안내를 봤음'은 옮기지 않는다 (권한 안내 창이 다시 뜨게)
        let skip: Set<String> = ["onboardingDone"]
        for (key, value) in values where d.object(forKey: key) == nil && !key.hasPrefix("NS") && !skip.contains(key) {
            d.set(value, forKey: key)
        }
    }
}
