import Carbon

/// Raccourcis clavier globaux.
/// - « temporaires » : actifs seulement pendant que la bulle est affichée (⌥⏎, Échap) ;
/// - « permanents » : toujours actifs (ouvrir le menu de l'app).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var temporary: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    /// Raccourci actif jusqu'au prochain `unregisterTemporary()`.
    func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        if let (id, ref) = add(keyCode: keyCode, modifiers: modifiers, action) { temporary[id] = ref }
    }

    /// Raccourci actif tant que l'app tourne.
    func registerPermanent(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        _ = add(keyCode: keyCode, modifiers: modifiers, action)
    }

    func unregisterTemporary() {
        for (id, ref) in temporary {
            UnregisterEventHotKey(ref)
            handlers[id] = nil
        }
        temporary = [:]
    }

    private func add(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) -> (UInt32, EventHotKeyRef)? {
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x434F_5252), id: id) // 'CORR'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return nil }
        handlers[id] = action
        return (id, ref)
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
