import Foundation

/// Which colour scheme Sigil's own windows (hints, switcher, Settings) use.
enum AppearanceMode: String, CaseIterable {
    /// Follow the macOS Light/Dark setting.
    case system
    case light
    case dark
}

/// User-tunable settings, persisted in `UserDefaults`. Read on the main thread (at hint-mode
/// activation, in the Settings window) and handed to background work as plain values.
final class SigilSettings {
    static let shared = SigilSettings()

    /// Visual mode is switched off for now: its hotkey is ignored and its menu item hidden while
    /// it is evaluated. The code stays in place so it can be re-enabled by flipping this flag.
    static let visualModeEnabled = false

    /// Maximum hints shown at once, shared fairly across visible windows (see `HintBudget`).
    static let defaultHintBudget = 800
    /// Lower bound keeps hint mode useful; upper bound is the number of two-character labels the
    /// 35-character alphabet can produce (35 × 35), so every hint stays two keystrokes.
    static let hintBudgetRange = 100...1225
    static let hintBudgetKey = "com.sigil.hintBudget"

    static let appearanceModeKey = "com.sigil.appearanceMode"

    /// Fired after any setting changes value.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hintBudget: Int {
        get {
            guard defaults.object(forKey: Self.hintBudgetKey) != nil else { return Self.defaultHintBudget }
            return Self.clampBudget(defaults.integer(forKey: Self.hintBudgetKey))
        }
        set {
            let clamped = Self.clampBudget(newValue)
            guard clamped != hintBudget else { return }
            defaults.set(clamped, forKey: Self.hintBudgetKey)
            onChange?()
        }
    }

    var appearanceMode: AppearanceMode {
        get {
            defaults.string(forKey: Self.appearanceModeKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        }
        set {
            guard newValue != appearanceMode else { return }
            defaults.set(newValue.rawValue, forKey: Self.appearanceModeKey)
            onChange?()
        }
    }

    func resetHintBudget() {
        let changed = hintBudget != Self.defaultHintBudget
        defaults.removeObject(forKey: Self.hintBudgetKey)
        if changed { onChange?() }
    }

    static func clampBudget(_ value: Int) -> Int {
        min(max(value, hintBudgetRange.lowerBound), hintBudgetRange.upperBound)
    }
}
