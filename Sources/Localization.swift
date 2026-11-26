import Cocoa

enum FPAppLanguage: String, CaseIterable {
    case auto
    case ru
    case en

    var title: String {
        switch self {
        case .auto: return L("Системный (Авто)", "System (Auto)")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

extension Notification.Name {
    static let fpLanguageDidChange = Notification.Name("QyvroLanguageDidChange")
}

enum FPLocalization {
    private static let key = "FPAppLanguage"
    private static var cachedEnglish: Bool = computeIsEnglish()

    static var selectedLanguage: FPAppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let parsed = FPAppLanguage(rawValue: raw) else {
                return .auto
            }
            return parsed
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            cachedEnglish = computeIsEnglish()
            NotificationCenter.default.post(name: .fpLanguageDidChange, object: nil)
            NotificationCenter.default.post(name: .fpThemeDidChange, object: nil)
        }
    }

    static var isEnglish: Bool { cachedEnglish }

    private static func computeIsEnglish() -> Bool {
        let raw = UserDefaults.standard.string(forKey: key)
        if let raw, let parsed = FPAppLanguage(rawValue: raw) {
            switch parsed {
            case .en: return true
            case .ru: return false
            case .auto: break
            }
        }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return !preferred.hasPrefix("ru")
    }

    static func localizedThemeTitle(_ russianTitle: String) -> String {
        guard isEnglish else { return russianTitle }
        switch russianTitle {
        case "Студия · Титан (V4)": return "Studio · Titanium (V4)"
        case "Студия · Нуар Янтарь (V4)": return "Studio · Noir Amber (V4)"
        case "Студия · Малахит (V4)": return "Studio · Malachite (V4)"
        case "Аврора · Кобальт (V3)": return "Aurora · Cobalt (V3)"
        case "Аврора · Изумруд (V3)": return "Aurora · Emerald (V3)"
        case "Аврора · Горизонт (V3)": return "Aurora · Horizon (V3)"
        case "Аврора · Обсидиан (V3)": return "Aurora · Obsidian (V3)"
        case "Стекло · Vision (V3)": return "Glass · Vision (V3)"
        case "Кислота (V2 — прошлый дизайн)": return "Acid (V2 — Legacy)"
        case "Кислота тёплая": return "Warm Acid"
        case "Графит и янтарь": return "Graphite & Amber"
        case "Ультрамарин": return "Ultramarine"
        case "Магента": return "Magenta"
        case "Токсик": return "Toxic"
        case "Плазма": return "Plasma"
        case "Лава": return "Lava"
        case "Иней": return "Frost"
        default: return russianTitle
        }
    }
}

@inline(__always)
func L(_ ru: String, _ en: String) -> String {
    FPLocalization.isEnglish ? en : ru
}
