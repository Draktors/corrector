import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Correction activée ou en pause.
    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// Remplace directement le texte sans afficher la bulle de validation.
    static var autoReplace: Bool {
        get { defaults.bool(forKey: "autoReplace") }
        set { defaults.set(newValue, forKey: "autoReplace") }
    }

    /// Temps sans frappe (en secondes) après lequel on considère que l'utilisateur a fini d'écrire.
    static var delay: Double {
        get { let v = defaults.double(forKey: "delay"); return v > 0 ? v : 0.25 }
        set { defaults.set(newValue, forKey: "delay") }
    }

    enum Engine: String, CaseIterable {
        case automatic, apple, claudeCode, claudeAPI

        var label: String {
            switch self {
            case .automatic: return "Automatique"
            case .apple: return "Apple Intelligence (gratuit, sur le Mac)"
            case .claudeCode: return "Claude Code (ton abonnement Claude)"
            case .claudeAPI: return "Claude API (clé API)"
            }
        }
    }

    enum ClaudeModel: String, CaseIterable {
        case haiku, sonnet, opus

        var label: String {
            switch self {
            case .haiku: return "Haiku 5.5 (rapide, économique)"
            case .sonnet: return "Sonnet 5.5 (intermédiaire)"
            case .opus: return "Opus 5.5 (le plus puissant)"
            }
        }
        /// Identifiant pour l'API Anthropic.
        var apiID: String { "claude-\(rawValue)-5-5" }
        /// Alias accepté par `claude --model`.
        var cliAlias: String { rawValue }
    }

    /// Modèle utilisé par le moteur Claude Code (Haiku par défaut).
    static var claudeCodeModel: ClaudeModel {
        get { ClaudeModel(rawValue: defaults.string(forKey: "claudeCodeModel") ?? "") ?? .haiku }
        set { defaults.set(newValue.rawValue, forKey: "claudeCodeModel") }
    }

    /// Modèle utilisé par le moteur Claude API (Opus par défaut).
    static var apiModel: ClaudeModel {
        get { ClaudeModel(rawValue: defaults.string(forKey: "apiModel") ?? "") ?? .haiku }
        set { defaults.set(newValue.rawValue, forKey: "apiModel") }
    }

    /// Moteur de correction choisi dans le menu.
    static var engine: Engine {
        get { Engine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "engine") }
    }

    /// Apps où l'on ne corrige jamais (terminaux, éditeurs de code, gestionnaires de mots de passe).
    static let excludedBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.jetbrains.intellij",
        "com.sublimetext.4",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]
}
