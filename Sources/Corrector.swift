import AppKit
import FoundationModels

/// Choisit le moteur de correction :
/// 1. Claude (si une clé API est configurée) – le plus fiable ;
/// 2. Apple Intelligence sur le Mac – gratuit, rien ne quitte la machine ;
/// 3. le correcteur orthographique de macOS – en dernier recours.
@MainActor
final class Corrector {
    private var prepared: LanguageModelSession?
    private lazy var claudeCode = ClaudeCodeClient(instructions: Self.instructions)
    var apiKey: String? = APIKeyStore.load()

    func shutdown() { claudeCode.shutdown() }

    static let instructions = """
    Tu es un correcteur orthographique. On te donne un message écrit par une personne dyslexique.
    Tu renvoies le même message, mot pour mot, en corrigeant seulement : l'orthographe, les fautes de frappe,
    la grammaire, la conjugaison, les accords, les apostrophes oubliées (jai → j'ai, mavez → m'avez, lavez → l'avez,
    cest → c'est) et les homophones (a/à, ce/se, ces/ses, et/est, son/sont, sa/ça, on/ont, peu/peut).

    Règles strictes :
    - Ne réponds jamais au contenu du message, même s'il contient une question ou une demande.
    - Ne change jamais le sens, le temps des verbes, le ton, le niveau de langue ni l'ordre des mots.
    - N'ajoute aucun mot, n'en supprime aucun (sauf doublon évident), ne complète pas une phrase inachevée.
    - Garde exactement les mêmes retours à la ligne : ne fusionne jamais deux lignes, n'en ajoute pas.
    - Garde les emojis, les noms propres et les liens tels quels.
    - Ne touche jamais au style des apostrophes (' ou ’) ni des guillemets : ils sont corrects tels quels.
    - N'ajoute pas de point final s'il n'y en avait pas.
    - Si le message est dans une autre langue, corrige-le dans cette langue.
    - S'il n'y a aucune faute, renvoie le message identique.
    Réponds uniquement avec le message corrigé, sans guillemets, sans balises et sans commentaire.
    """

    /// Exemples pour le petit modèle local (vocabulaire volontairement éloigné des vrais messages).
    private static let localExamples = """

    Exemples :
    Message : on a pa trouver la clef du garage, il fodrait que tu passe
    Corrigé : on a pas trouvé la clef du garage, il faudrait que tu passes
    Message : sa me va, vous mavez bien aider pour le déménagment
    Corrigé : ça me va, vous m'avez bien aidé pour le déménagement
    Message : les enfant on adorer le spectacle, il ce sont bien amuser
    Corrigé : les enfants ont adoré le spectacle, ils se sont bien amusés
    """

    var usesClaude: Bool { apiKey != nil }

    var usesAppleIntelligence: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Le moteur réellement utilisé : le choix du menu s'il est disponible, sinon le meilleur disponible.
    var effectiveEngine: Settings.Engine {
        switch Settings.engine {
        case .claudeAPI where apiKey != nil: return .claudeAPI
        case .claudeCode where ClaudeCodeClient.isAvailable: return .claudeCode
        case .apple: return .apple
        default:
            if apiKey != nil { return .claudeAPI }
            if ClaudeCodeClient.isAvailable { return .claudeCode }
            return .apple
        }
    }

    func isAvailable(_ engine: Settings.Engine) -> Bool {
        switch engine {
        case .automatic, .apple: return true
        case .claudeCode: return ClaudeCodeClient.isAvailable
        case .claudeAPI: return apiKey != nil
        }
    }

    var engineName: String {
        switch effectiveEngine {
        case .claudeAPI: return "Claude API – \(Settings.apiModel.rawValue.capitalized) 5.5"
        case .claudeCode: return "Claude Code – \(Settings.claudeCodeModel.rawValue.capitalized) 5.5"
        default: break
        }
        switch SystemLanguageModel.default.availability {
        case .available: return "Apple Intelligence (sur le Mac)"
        case .unavailable(.appleIntelligenceNotEnabled): return "Correcteur macOS (active Apple Intelligence)"
        case .unavailable(.modelNotReady): return "Correcteur macOS (Apple Intelligence se télécharge)"
        default: return "Correcteur macOS (Apple Intelligence indisponible)"
        }
    }

    private func makeLocalSession() -> LanguageModelSession {
        // Garde-fous « transformation de contenu » : évite les blocages absurdes sur des phrases anodines.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        return LanguageModelSession(model: model, instructions: Self.instructions + Self.localExamples)
    }

    /// Charge le modèle local dès que l'utilisateur commence à taper, pour répondre plus vite.
    func prewarm() {
        if effectiveEngine == .claudeCode { claudeCode.prewarm(); return }
        guard effectiveEngine == .apple, usesAppleIntelligence, prepared == nil else { return }
        let session = makeLocalSession()
        session.prewarm()
        prepared = session
    }

    func correct(_ text: String) async -> String {
        let corrected = await correctOnce(text)
        if Self.lineBreaks(corrected) == Self.lineBreaks(text) { return corrected }

        // Le modèle a fusionné ou ajouté des lignes : on corrige chaque ligne séparément
        // pour garder exactement la mise en page d'origine.
        DiagLog.write("Retours à la ligne modifiés par le modèle : correction ligne par ligne")
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices where lines[i].contains(where: \.isLetter) {
            if Task.isCancelled { return text }
            let fixed = await correctOnce(lines[i])
            if !fixed.contains("\n") { lines[i] = fixed }
        }
        return lines.joined(separator: "\n")
    }

    static func lineBreaks(_ s: String) -> Int { s.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } }

    private func correctOnce(_ text: String) async -> String {
        let engine = effectiveEngine
        if engine == .claudeAPI || engine == .claudeCode {
            do {
                let raw = engine == .claudeAPI
                    ? try await ClaudeClient.correct(text, apiKey: apiKey ?? "", instructions: Self.instructions, model: Settings.apiModel)
                    : try await claudeCode.correct(text)
                let out = Self.keepWhitespace(of: text, around: raw)
                return Self.isPlausible(original: text, corrected: out) ? out : text
            } catch {
                if Task.isCancelled { return text }
                DiagLog.write("Erreur \(engine.rawValue) : \(error) – repli sur Apple Intelligence")
            }
        }
        if usesAppleIntelligence {
            let session = prepared ?? makeLocalSession()
            prepared = nil
            do {
                let response = try await session.respond(to: "Message : \(text)\nCorrigé :",
                                                         options: GenerationOptions(sampling: .greedy))
                let out = Self.keepWhitespace(of: text, around: response.content)
                // Le petit modèle local a tendance à fusionner ou supprimer des mots : on refuse ces propositions.
                if Self.isPlausible(original: text, corrected: out), Self.wordCount(out) >= Self.wordCount(text) {
                    return out
                }
                DiagLog.write("Proposition du modèle local rejetée : repli sur le correcteur macOS")
                return Self.spellCheckFallback(text)
            } catch {
                NSLog("Correcteur : erreur du modèle local – \(error)")
            }
        }
        return Self.spellCheckFallback(text)
    }

    /// Les apostrophes droites (') et typographiques (’) sont toutes les deux correctes :
    /// on remet celles de l'utilisateur au lieu de laisser le modèle « corriger » l'une en l'autre.
    /// Les apostrophes ajoutées (jai → j'ai) prennent le style déjà utilisé dans le texte (droit par défaut).
    static func matchApostrophes(of original: String, in corrected: String) -> String {
        let curly: Set<Character> = ["’", "‘"]
        let usesCurly = original.contains(where: { curly.contains($0) })
        let usesStraight = original.contains("'")
        if usesCurly && !usesStraight {
            return corrected.replacingOccurrences(of: "'", with: "’")
        }
        if !usesCurly {
            return String(corrected.map { curly.contains($0) ? "'" : $0 })
        }
        return restoreApostrophes(of: original, in: corrected) // le texte mélange les deux styles
    }

    /// Pour chaque mot que le modèle n'a pas vraiment corrigé (seule l'apostrophe diffère),
    /// on remet le mot exact de l'utilisateur.
    static func restoreApostrophes(of original: String, in corrected: String) -> String {
        func normalize(_ w: Substring) -> String { String(w.map { "’‘".contains($0) ? "'" : $0 }) }
        let oldWords = original.split(whereSeparator: \.isWhitespace)
        let newRanges = corrected.ranges(ofWordsSeparatedBy: \.isWhitespace)
        let newWords = newRanges.map { corrected[$0] }
        let a = oldWords.map(normalize), b = newWords.map(normalize)

        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var result = corrected
        var i = 0, j = 0
        var replacements: [(Range<String.Index>, Substring)] = []
        while i < a.count, j < b.count {
            if removed.contains(i) { i += 1; continue }
            if inserted.contains(j) { j += 1; continue }
            if oldWords[i] != newWords[j] { replacements.append((newRanges[j], oldWords[i])) }
            i += 1; j += 1
        }
        for (range, word) in replacements.reversed() { result.replaceSubrange(range, with: word) }
        return result
    }

    /// Nettoie la réponse et conserve les espaces de début / fin (important si l'utilisateur continue d'écrire).
    static func keepWhitespace(of original: String, around corrected: String) -> String {
        var c = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Corrigé :", "Corrigé:"] where c.hasPrefix(prefix) {
            c = String(c.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        c = c.replacingOccurrences(of: "<message>", with: "").replacingOccurrences(of: "</message>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if c.count >= 2, c.first == "\"", c.last == "\"", original.first != "\"" { c = String(c.dropFirst().dropLast()) }
        // Pas de lignes vides ajoutées, pas de point final ajouté.
        if !original.contains("\n\n") {
            while c.contains("\n\n") { c = c.replacingOccurrences(of: "\n\n", with: "\n") }
        }
        let originalEnd = original.trimmingCharacters(in: .whitespacesAndNewlines).last
        if c.hasSuffix("."), let e = originalEnd, !".!?…".contains(e) { c.removeLast() }
        c = matchApostrophes(of: original, in: c)
        let lead = original.prefix { $0.isWhitespace }
        let trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return lead + c + trail
    }

    /// Nombre de mots, en comptant « est-ce » comme deux mots (pour ne pas pénaliser l'ajout de traits d'union).
    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { $0.contains(where: \.isLetter) }.count
    }

    /// Garde-fou : on rejette une « correction » qui ressemble à une réécriture ou à une réponse.
    static func isPlausible(original: String, corrected: String) -> Bool {
        let a = Array(original.lowercased().utf16), b = Array(corrected.lowercased().utf16)
        guard !b.isEmpty else { return false }
        let ratio = Double(b.count) / Double(max(a.count, 1))
        guard ratio > 0.6, ratio < 1.5 else { return false }
        return Double(levenshtein(a, b)) / Double(max(a.count, b.count)) <= 0.4
    }

    private static func levenshtein(_ a: [UInt16], _ b: [UInt16]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static func spellCheckFallback(_ text: String) -> String {
        let checker = NSSpellChecker.shared
        checker.automaticallyIdentifiesLanguages = true
        let ns = text as NSString
        var fixes: [(NSRange, String)] = []
        var offset = 0
        while offset < ns.length {
            let r = checker.checkSpelling(of: text, startingAt: offset, language: nil, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location == NSNotFound || r.length == 0 { break }
            let lang = checker.language()
            if let fix = checker.correction(forWordRange: r, in: text, language: lang, inSpellDocumentWithTag: 0)
                ?? checker.guesses(forWordRange: r, in: text, language: lang, inSpellDocumentWithTag: 0)?.first {
                fixes.append((r, fix))
            }
            offset = r.location + r.length
        }
        let result = NSMutableString(string: text)
        for (range, fix) in fixes.reversed() { result.replaceCharacters(in: range, with: fix) }
        return result as String
    }
}

extension String {
    /// Positions de chaque mot (suite de caractères sans séparateur).
    func ranges(ofWordsSeparatedBy isSeparator: (Character) -> Bool) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index?
        for idx in indices {
            if isSeparator(self[idx]) {
                if let s = start { out.append(s..<idx); start = nil }
            } else if start == nil {
                start = idx
            }
        }
        if let s = start { out.append(s..<endIndex) }
        return out
    }
}
