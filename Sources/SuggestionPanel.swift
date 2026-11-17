import AppKit
import Carbon
import SwiftUI

/// Bulle flottante qui ne vole pas le focus : l'utilisateur garde son curseur dans son champ.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class SuggestionPanel {
    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var hotKeysActive = false

    /// La bulle est-elle affichée à l'écran (et pas seulement cachée en attendant le retour au champ) ?
    var isVisible: Bool { panel?.isVisible ?? false }

    @discardableResult
    func show(original: String, corrected: String, near anchor: CGRect?) -> CGRect {
        hide()
        let view = SuggestionView(
            segments: WordDiff.segments(from: original, to: corrected),
            onAccept: { [weak self] in self?.onAccept?() },
            onDismiss: { [weak self] in self?.onDismiss?() }
        )
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)

        let p = NonKeyPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        // Pas de .canJoinAllSpaces : la bulle reste sur le bureau du champ, au lieu d'apparaître sur
        // l'écran suivant pendant l'animation de changement de bureau.
        p.collectionBehavior = [.fullScreenAuxiliary, .transient]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.contentView = host
        p.setFrameOrigin(Self.origin(for: size, anchor: anchor))
        p.orderFrontRegardless()
        panel = p
        registerHotKeys()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss?() }
        }
        return p.frame
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        unregisterHotKeys()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Cache la bulle sans l'oublier (l'utilisateur a quitté le champ). ⌘⏎ et Échap sont rendus aux autres apps.
    func conceal() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        unregisterHotKeys()
    }

    /// Réaffiche la bulle au niveau du champ (retour dans le champ, ou champ déplacé : défilement, fenêtre…).
    func reveal(near anchor: CGRect?) {
        guard let panel else { return }
        if let anchor {
            let origin = Self.origin(for: panel.frame.size, anchor: anchor)
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        registerHotKeys()
    }

    private func registerHotKeys() {
        guard !hotKeysActive else { return }
        hotKeysActive = true
        HotKeys.shared.register(keyCode: kVK_Return, modifiers: cmdKey) { [weak self] in self?.onAccept?() }
        HotKeys.shared.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.onDismiss?() }
    }

    private func unregisterHotKeys() {
        guard hotKeysActive else { return }
        hotKeysActive = false
        HotKeys.shared.unregisterTemporary()
    }

    /// `anchor` est en coordonnées AX (origine en haut à gauche de l'écran principal).
    private static func origin(for size: CGSize, anchor: CGRect?) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
        let a: CGRect
        if let anchor {
            a = CGRect(x: anchor.minX, y: primaryHeight - anchor.maxY, width: anchor.width, height: anchor.height)
        } else {
            let m = NSEvent.mouseLocation
            a = CGRect(x: m.x, y: m.y, width: 1, height: 1)
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(a) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var x = a.minX
        var y = a.minY - size.height - 8          // sous le texte
        if y < vf.minY { y = a.maxY + 8 }         // sinon au-dessus
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        return CGPoint(x: x, y: y)
    }
}

private struct SuggestionView: View {
    let segments: [DiffSegment]
    let onAccept: () -> Void
    let onDismiss: () -> Void

    private var diffText: Text {
        var result = Text("")
        var atLineStart = true
        for seg in segments {
            let isBreak = seg.text == "\n"
            let part: Text
            switch (seg.kind, isBreak) {
            case (.same, true), (.added, true):
                part = Text("\n")
            case (.removed, true):
                // Retour à la ligne supprimé : on le signale au lieu de le faire disparaître en silence.
                part = Text("⏎").foregroundStyle(.red.opacity(0.7))
            case (.same, false):
                part = Text(seg.text)
            case (.removed, false):
                part = Text(seg.text).strikethrough(true, color: .red).foregroundStyle(.red.opacity(0.7))
            case (.added, false):
                part = Text(seg.text).bold().foregroundStyle(Color(nsColor: .systemGreen))
            }
            // Un espace entre deux mots, mais pas en début de ligne ni autour d'un retour à la ligne.
            let separator = (atLineStart || (isBreak && seg.kind != .removed)) ? "" : " "
            result = Text("\(result)\(separator)\(part)")
            atLineStart = isBreak && seg.kind != .removed
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.badge.checkmark").foregroundStyle(.tint)
                Text("Correction proposée").font(.headline)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Ignorer (Échap)")
            }
            ScrollView {
                diffText
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 170)
            HStack {
                Text("⌘ ⏎ remplacer · Échap ignorer").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remplacer", action: onAccept).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }
}
