import Combine
import Foundation

/// AppSettings가 저장값을 다시 읽을 때 쓰는 공통 면
protocol SettingSlot: AnyObject {
    func refresh(from defaults: UserDefaults, owner: AppSettings)
}

/// UserDefaults에 저장되는 설정 하나. 키와 기본값을 한 줄로 선언하면 읽기·저장·다시 읽기·변경 알림이 모두 따라온다.
///
///     @Setting("btEnabled", default: true) var btEnabled: Bool
///
/// `settings.$btEnabled`는 @Published처럼 현재 값으로 시작해 바뀔 때마다 알리는 발행자다.
/// 값이 같으면 저장도 알림도 하지 않으므로, 다시 읽기(reload)는 실제로 바뀐 설정에만 반응한다.
@propertyWrapper
final class Setting<Value: Equatable>: SettingSlot {
    private let key: String
    private let read: (UserDefaults) -> Value
    private let write: (UserDefaults, Value) -> Void
    private let notifiesMainApp: Bool
    private var value: Value
    private var subject: CurrentValueSubject<Value, Never>?

    private init(key: String, notifiesMainApp: Bool, read: @escaping (UserDefaults) -> Value,
                 write: @escaping (UserDefaults, Value) -> Void) {
        self.key = key
        self.notifiesMainApp = notifiesMainApp
        self.read = read
        self.write = write
        value = read(.standard)
    }

    /// 숫자·문자열·목록처럼 그대로 저장되는 값. `sanitize`는 읽을 때 범위를 맞추거나 예전 값을 고친다.
    /// `notifiesMainApp`을 끄면 글자마다 본 앱이 설정을 다시 읽지 않는다 (본 앱은 쓸 때 저장값을 직접 읽어야 한다).
    convenience init(_ key: String, default fallback: @escaping @autoclosure () -> Value,
                     notifiesMainApp: Bool = true, sanitize: ((Value) -> Value)? = nil) {
        self.init(key: key, notifiesMainApp: notifiesMainApp, read: { defaults in
            let saved = defaults.object(forKey: key) as? Value ?? fallback()
            return sanitize?(saved) ?? saved
        }, write: { $0.set($1, forKey: key) })
    }

    /// 예전 저장값을 이어 받는 등 읽는 방법이 특별한 값
    convenience init(_ key: String, read: @escaping (UserDefaults) -> Value) {
        self.init(key: key, notifiesMainApp: true, read: read, write: { $0.set($1, forKey: key) })
    }

    @available(*, unavailable, message: "AppSettings 안에서만 쓴다")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    var projectedValue: AnyPublisher<Value, Never> {
        if let subject { return subject.eraseToAnyPublisher() }
        let created = CurrentValueSubject<Value, Never>(value)
        subject = created
        return created.eraseToAnyPublisher()
    }

    static subscript(_enclosingInstance owner: AppSettings,
                     wrapped _: ReferenceWritableKeyPath<AppSettings, Value>,
                     storage storage: ReferenceWritableKeyPath<AppSettings, Setting<Value>>) -> Value {
        get { owner[keyPath: storage].value }
        set {
            let setting = owner[keyPath: storage]
            guard setting.apply(newValue, owner: owner) else { return }
            setting.write(owner.defaults, newValue)
            owner.didSave(key: setting.key, notifiesMainApp: setting.notifiesMainApp)
        }
    }

    func refresh(from defaults: UserDefaults, owner: AppSettings) {
        _ = apply(read(defaults), owner: owner)
    }

    /// @Published와 같은 순서로 알린다: 알림을 받는 쪽이 값을 직접 읽으면 아직 이전 값이다.
    private func apply(_ newValue: Value, owner: AppSettings) -> Bool {
        guard newValue != value else { return false }
        owner.objectWillChange.send()
        subject?.send(newValue)
        value = newValue
        return true
    }
}

extension Setting where Value: RawRepresentable, Value.RawValue == String {
    /// 문자열로 저장되는 선택지. 저장값이 비었거나 모르는 값이면 기본값.
    convenience init(_ key: String, default fallback: Value) {
        self.init(key: key, notifiesMainApp: true,
                  read: { ($0.string(forKey: key)).flatMap(Value.init(rawValue:)) ?? fallback },
                  write: { $0.set($1.rawValue, forKey: key) })
    }
}
