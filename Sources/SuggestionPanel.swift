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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.contentView = host
        p.setFrameOrigin(Self.origin(for: size, anchor: anchor))
        p.orderFrontRegardless()
        panel = p

        HotKeys.shared.register(keyCode: kVK_Return, modifiers: optionKey) { [weak self] in self?.onAccept?() }
        HotKeys.shared.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.onDismiss?() }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss?() }
        }
        return p.frame
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        HotKeys.shared.unregisterTemporary()
        panel?.orderOut(nil)
        panel = nil
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
        for (i, seg) in segments.enumerated() {
            let part: Text
            switch seg.kind {
            case .same:
                part = Text(seg.text)
            case .removed:
                part = Text(seg.text).strikethrough(true, color: .red).foregroundStyle(.red.opacity(0.7))
            case .added:
                part = Text(seg.text).bold().foregroundStyle(Color(nsColor: .systemGreen))
            }
            result = i == 0 ? part : Text("\(result) \(part)")
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
                Text("⌥ ⏎ remplacer · Échap ignorer").font(.caption).foregroundStyle(.secondary)
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
