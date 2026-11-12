import AppKit
import ApplicationServices
import Carbon

struct FocusedField {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let text: String
    /// Champ dans une page web / app Electron (Chrome, Safari, Slack…) : on passe par le copier-coller.
    let isWeb: Bool
}

/// Lecture et écriture du champ texte actif via l'API d'accessibilité de macOS.
enum AXText {
    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ v: AnyObject?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Demande aux apps Chrome / Electron d'exposer leur arbre d'accessibilité.
    static func enableAccessibility(for pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func focusedField() -> FocusedField? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        if let id = app.bundleIdentifier, Settings.excludedBundles.contains(id) { return nil }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let el = element(attr(appEl, kAXFocusedUIElementAttribute)),
              let role = attr(el, kAXRoleAttribute) as? String,
              editableRoles.contains(role) else { return nil }

        // Jamais les champs mot de passe ni les champs de recherche.
        let subrole = attr(el, kAXSubroleAttribute) as? String
        if subrole == "AXSecureTextField" || subrole == "AXSearchField" { return nil }

        guard let text = attr(el, kAXValueAttribute) as? String else { return nil }
        return FocusedField(element: el, pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                            text: text, isWeb: isInsideWebArea(el))
    }

    /// Pour le diagnostic : décrit l'élément qui a le focus.
    static func describeFocus() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "pas d'app active" }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let el = element(value) else { return "focus illisible, erreur AX \(err.rawValue)" }
        let role = attr(el, kAXRoleAttribute) as? String ?? "?"
        let sub = attr(el, kAXSubroleAttribute) as? String ?? "-"
        let hasText = attr(el, kAXValueAttribute) is String
        return "rôle \(role), sous-rôle \(sub), texte lisible: \(hasText)"
    }

    static func currentText(_ el: AXUIElement) -> String? {
        attr(el, kAXValueAttribute) as? String
    }

    private static func isInsideWebArea(_ el: AXUIElement) -> Bool {
        var current: AXUIElement? = el
        for _ in 0..<40 {
            guard let c = current else { return false }
            if (attr(c, kAXRoleAttribute) as? String) == "AXWebArea" { return true }
            current = element(attr(c, kAXParentAttribute))
        }
        return false
    }

    // MARK: - Sélection

    static func selection(_ el: AXUIElement) -> CFRange? {
        guard let v = attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    @discardableResult
    static func setSelection(_ el: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Position (coordonnées écran AX, origine en haut à gauche) où afficher la bulle : le curseur texte si possible.
    static func anchorRect(_ el: AXUIElement) -> CGRect? {
        if let sel = selection(el) {
            var r = CFRange(location: sel.location, length: 0)
            if let param = AXValueCreate(.cfRange, &r) {
                var out: AnyObject?
                if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
                   let out, CFGetTypeID(out) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    if AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin != .zero {
                        return rect
                    }
                }
            }
        }
        // Sinon le cadre du champ, s'il n'est pas trop grand.
        var pos = CGPoint.zero, size = CGSize.zero
        if let p = attr(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
           let s = attr(el, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
           AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(s as! AXValue, .cgSize, &size),
           size.height < 140 {
            return CGRect(origin: pos, size: size)
        }
        return nil
    }

    // MARK: - Remplacement

    /// Remplace uniquement la portion modifiée (pour préserver la mise en forme, les signatures, etc.).
    static func replace(field: FocusedField, original: String, corrected: String) {
        let el = field.element
        let o = Array(original.utf16), n = Array(corrected.utf16)
        func isSep(_ c: UInt16) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 }

        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p, s < n.count - p, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        // On élargit aux limites de mots.
        while p > 0, !isSep(o[p - 1]) { p -= 1 }
        while s > 0, !isSep(o[o.count - s]) { s -= 1 }

        let range = CFRange(location: p, length: o.count - p - s)
        let oldPart = String(decoding: o[p..<(o.count - s)], as: UTF16.self)
        let newPart = String(decoding: n[p..<(n.count - s)], as: UTF16.self)
        let caretWasAtEnd = (selection(el)?.location ?? o.count) >= o.count

        func restoreCaret() {
            if caretWasAtEnd { setSelection(el, CFRange(location: n.count, length: 0)) }
        }

        // 1) Apps natives : écriture directe via l'accessibilité.
        if !field.isWeb, setSelection(el, range) {
            AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, newPart as CFTypeRef)
            let now = currentText(el)
            if now == corrected { restoreCaret(); return }
            if now != original { return } // quelque chose a changé, on ne touche plus à rien
        }

        // 2) Web / Electron : on sélectionne la portion fautive et on colle la correction.
        if setSelection(el, range), (attr(el, kAXSelectedTextAttribute) as? String) == oldPart {
            if newPart.isEmpty {
                sendKey(51) // Effacer
            } else {
                paste(newPart)
            }
        } else {
            // 3) Dernier recours : tout sélectionner puis coller le texte complet.
            guard let a = keyCode(for: "a") else { return }
            sendKey(a, flags: .maskCommand)
            paste(corrected)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { restoreCaret() }
    }

    private static func paste(_ text: String) {
        guard let v = keyCode(for: "v") else { return }
        let pb = NSPasteboard.general
        // Sauvegarde du presse-papiers de l'utilisateur.
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        sendKey(v, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }

    private static func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Trouve la touche physique qui produit `char` dans la disposition clavier actuelle
    /// (indispensable en AZERTY : la touche « A » du QWERTY y est le « Q », et ⌘Q quitterait l'app !).
    private static func keyCode(for char: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, 4, &length, &chars)
                if status == noErr, length > 0,
                   String(utf16CodeUnits: chars, count: length).lowercased() == char {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
