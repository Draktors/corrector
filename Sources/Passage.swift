import Foundation

/// Choisit le morceau de texte à envoyer au correcteur : seulement là où l'utilisateur écrit, pas tout le champ.
/// Moins de texte envoyé = réponse plus rapide sur les longs messages (le modèle réécrit moins de mots).
enum Passage {
    /// Au-delà, on ne garde que la phrase en cours et la précédente (pour les accords d'une phrase à l'autre).
    static let maxParagraph = 400

    /// `caret` : position du curseur en unités UTF-16 (comme l'API Accessibilité). Sans curseur : fin du texte.
    static func around(caret: Int?, in text: String) -> Range<String.Index> {
        let utf16 = text.utf16.count
        let offset = min(max(caret ?? utf16, 0), utf16)
        let c = String.Index(utf16Offset: offset, in: text)

        // Le paragraphe du curseur (entre deux retours à la ligne).
        let start = text[..<c].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let end = text[c...].firstIndex(of: "\n") ?? text.endIndex
        guard text.distance(from: start, to: end) > maxParagraph else { return start..<end }

        // Paragraphe long : débuts de phrase (après . ! ? … suivi d'un espace).
        var starts: [String.Index] = [start]
        var i = start
        while i < end {
            let ch = text[i]
            let next = text.index(after: i)
            if ".!?…".contains(ch), next < end, text[next].isWhitespace {
                var s = next
                while s < end, text[s].isWhitespace { s = text.index(after: s) }
                if s < end { starts.append(s) }
                i = s
            } else {
                i = next
            }
        }
        // Phrase du curseur, et la précédente.
        let current = starts.lastIndex { $0 <= c } ?? 0
        let from = starts[max(current - 1, 0)]
        let to = current + 1 < starts.count ? starts[current + 1] : end
        return from..<to
    }
}
