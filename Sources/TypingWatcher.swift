import AppKit

/// Détecte quand l'utilisateur commence à taper et quand il s'arrête (pause de `Settings.delay` secondes).
@MainActor
final class TypingWatcher {
    var onTypingStarted: (() -> Void)?
    var onTypingPaused: (() -> Void)?

    private var monitor: Any?
    private var timer: Timer?
    private var typing = false

    var isRunning: Bool { monitor != nil }

    /// Touches qui ne modifient pas le texte : flèches, Échap, Tab, début/fin, page haut/bas.
    private static let ignoredKeys: Set<UInt16> = [123, 124, 125, 126, 53, 48, 115, 119, 116, 121]

    func start() {
        guard monitor == nil else { return }
        // Nécessite l'autorisation « Accessibilité ». On écoute seulement, on ne bloque aucune touche.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags
            let code = event.keyCode
            MainActor.assumeIsolated { self?.keyPressed(flags: flags, keyCode: code) }
        }
    }

    private func keyPressed(flags: NSEvent.ModifierFlags, keyCode: UInt16) {
        // Raccourcis (⌘C, ⌃A…) : ce n'est pas de la frappe.
        if flags.contains(.command) || flags.contains(.control) { return }
        if Self.ignoredKeys.contains(keyCode) { return }

        if !typing {
            typing = true
            onTypingStarted?()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.typing = false
                self.onTypingPaused?()
            }
        }
    }
}
