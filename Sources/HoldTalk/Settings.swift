import AppKit
import Carbon.HIToolbox

/// A configurable hotkey: a primary key (may itself be a modifier key like Right Option)
/// plus required modifier flags that must be held at press time.
struct HotkeyConfig: Equatable {
    var keyCode: UInt16
    var requiredFlags: CGEventFlags

    static let rightOptionKeyCode: UInt16 = 61

    var isModifierKey: Bool { Self.modifierFlag(for: keyCode) != nil }

    /// The generic CGEventFlags bit toggled by a modifier key code, or nil for normal keys.
    static func modifierFlag(for keyCode: UInt16) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand: return .maskCommand
        case kVK_Shift, kVK_RightShift: return .maskShift
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_Function: return .maskSecondaryFn
        default: return nil
        }
    }

    var displayString: String {
        var parts: [String] = []
        if requiredFlags.contains(.maskControl) { parts.append("⌃") }
        if requiredFlags.contains(.maskAlternate) { parts.append("⌥") }
        if requiredFlags.contains(.maskShift) { parts.append("⇧") }
        if requiredFlags.contains(.maskCommand) { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_RightOption: return "Right ⌥"
        case kVK_Option: return "Left ⌥"
        case kVK_RightCommand: return "Right ⌘"
        case kVK_Command: return "Left ⌘"
        case kVK_RightShift: return "Right ⇧"
        case kVK_Shift: return "Left ⇧"
        case kVK_RightControl: return "Right ⌃"
        case kVK_Control: return "Left ⌃"
        case kVK_Function: return "Fn"
        case kVK_Space: return "Space"
        case kVK_Escape: return "Esc"
        default:
            if let name = keyboardLayoutName(for: keyCode) { return name }
            return "Key \(keyCode)"
        }
    }

    private static func keyboardLayoutName(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let error = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
            guard error == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

enum SpokenLanguage: String {
    case bengali = "bn"
    case english = "en"
    case auto = "auto"
}

/// UserDefaults-backed app settings.
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let transcribeKeyCode = "transcribeKeyCode"
        static let transcribeFlags = "transcribeFlags"
        static let translateKeyCode = "translateKeyCode"
        static let translateFlags = "translateFlags"
        static let keepWarmDuration = "keepWarmDuration"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let spokenLanguage = "spokenLanguage"
    }

    /// Pin short Bangla clips to Bengali rather than guessing their language.
    static var spokenLanguage: SpokenLanguage {
        get { SpokenLanguage(rawValue: defaults.string(forKey: Key.spokenLanguage) ?? "") ?? .bengali }
        set { defaults.set(newValue.rawValue, forKey: Key.spokenLanguage) }
    }

    /// Whether to check GitHub for new releases automatically (launch + daily).
    static var autoCheckUpdates: Bool {
        get { defaults.object(forKey: Key.autoCheckUpdates) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoCheckUpdates) }
    }

    /// How long the whisper-server (and its ~600 MB model) stays resident after the
    /// last dictation before being shut down to free RAM.
    static var keepWarmDuration: TimeInterval {
        get {
            let value = defaults.double(forKey: Key.keepWarmDuration)
            return value > 0 ? value : 180 // default 3 minutes
        }
        set { defaults.set(newValue, forKey: Key.keepWarmDuration) }
    }

    static var transcribeHotkey: HotkeyConfig {
        get { hotkey(codeKey: Key.transcribeKeyCode, flagsKey: Key.transcribeFlags,
                     default: HotkeyConfig(keyCode: HotkeyConfig.rightOptionKeyCode, requiredFlags: [])) }
        set { store(newValue, codeKey: Key.transcribeKeyCode, flagsKey: Key.transcribeFlags) }
    }

    static var translateHotkey: HotkeyConfig {
        get { hotkey(codeKey: Key.translateKeyCode, flagsKey: Key.translateFlags,
                     default: HotkeyConfig(keyCode: HotkeyConfig.rightOptionKeyCode, requiredFlags: .maskShift)) }
        set { store(newValue, codeKey: Key.translateKeyCode, flagsKey: Key.translateFlags) }
    }

    private static func hotkey(codeKey: String, flagsKey: String, default defaultValue: HotkeyConfig) -> HotkeyConfig {
        guard defaults.object(forKey: codeKey) != nil else { return defaultValue }
        return HotkeyConfig(
            keyCode: UInt16(defaults.integer(forKey: codeKey)),
            requiredFlags: CGEventFlags(rawValue: UInt64(defaults.integer(forKey: flagsKey)))
        )
    }

    private static func store(_ hotkey: HotkeyConfig, codeKey: String, flagsKey: String) {
        defaults.set(Int(hotkey.keyCode), forKey: codeKey)
        defaults.set(Int(hotkey.requiredFlags.rawValue), forKey: flagsKey)
    }
}
