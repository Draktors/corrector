import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Status { case idle, typing, checking, ok, suggestion, disabled, noPermission }

    private var statusItem: NSStatusItem!
    private let watcher = TypingWatcher()
    private let corrector = Corrector()
    private let panel = SuggestionPanel()

    private var task: Task<Void, Never>?
    private var lastHandled: String?
    private var pending: (field: FocusedField, original: String, corrected: String)?
    private var trustTimer: Timer?
    /// Pendant que la bulle attend, vérifie que l'utilisateur est toujours dans le champ corrigé.
    private var followTimer: Timer?
    /// Empêche macOS de mettre l'app en veille (App Nap) entre la frappe et l'affichage de la correction :
    /// une app de barre de menus en arrière-plan voit sinon ses minuteurs et ses lectures ralentis.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        watcher.onTypingStarted = { [weak self] in self?.typingStarted() }
        watcher.onTypingPaused = { [weak self] in self?.typingPaused() }
        panel.onAccept = { [weak self] in self?.acceptPending() }
        panel.onDismiss = { [weak self] in self?.dismissPending() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                AXText.enableAccessibility(for: app.processIdentifier)
            }
            // Changement d'app : on cache (ou réaffiche) la bulle tout de suite, sans attendre le prochain contrôle.
            MainActor.assumeIsolated { self?.followField() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followField() }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            AXText.enableAccessibility(for: front.processIdentifier)
        }

        // ⌃⌥⌘C ouvre le menu sous la souris (utile si l'icône est cachée par l'encoche ou trop d'icônes).
        HotKeys.shared.registerPermanent(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.showMenuAtMouse()
        }

        ensurePermission()
        rebuildMenu()
    }

    /// Relancer l'app (Spotlight, Launchpad, double-clic) alors qu'elle tourne déjà ouvre son menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuAtMouse()
        return false
    }

    private func showMenuAtMouse() {
        rebuildMenu()
        NSApp.activate()
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        corrector.shutdown() // ferme le Claude Code lancé à l'avance
    }

    // MARK: - Permission Accessibilité

    private func ensurePermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            watcher.start()
            DiagLog.write("Démarrage : accessibilité OK, écoute du clavier active (\(watcher.isRunning))")
            setStatus(Settings.enabled ? .idle : .disabled)
            return
        }
        DiagLog.write("Démarrage : accessibilité NON accordée, en attente")
        setStatus(.noPermission)
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard self != nil, AXIsProcessTrusted() else { return }
                timer.invalidate()
                // macOS n'applique souvent la permission qu'au redémarrage du processus : on se relance.
                DiagLog.write("Accessibilité accordée : redémarrage de l'app")
                let path = Bundle.main.bundlePath
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(path)\""]
                try? p.run()
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Cycle frappe → pause → correction

    private func typingStarted() {
        task?.cancel()
        task = nil
        if pending != nil { DiagLog.write("Bulle fermée : reprise de la frappe"); pending = nil; stopFollowingField(); panel.hide() }
        guard Settings.enabled else { return }
        DiagLog.write("Frappe détectée")
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Correction en cours")
        }
        setStatus(.typing)
        corrector.prewarm()
    }

    private func typingPaused() {
        guard Settings.enabled else { setStatus(.disabled); return }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        guard let field = AXText.focusedField() else {
            DiagLog.write("Pause dans \(app) : aucun champ texte lisible (\(AXText.describeFocus()))")
            setStatus(.idle); return
        }
        let text = field.text
        // Au moins deux mots (évite les URL, recherches, identifiants…), et pas un texte énorme.
        guard WordDiff.words(text).count >= 2, text.count <= 4000, text != lastHandled else {
            DiagLog.write("Pause dans \(app) : ignoré (\(WordDiff.words(text).count) mots, \(text.count) car., déjà traité: \(text == lastHandled))")
            setStatus(.idle); return
        }

        DiagLog.write("Pause dans \(app) : correction de \(text.count) car. (web: \(field.isWeb)) via \(corrector.engineName)")
        setStatus(.checking)
        // Seulement le passage où se trouve le curseur (paragraphe, ou phrase en cours si le paragraphe est long).
        let range = Passage.around(caret: AXText.selection(field.element).map { $0.location }, in: text)
        let passage = String(text[range])
        if passage.count < text.count { DiagLog.write("Passage envoyé : \(passage.count) car. sur \(text.count)") }
        let before = String(text[..<range.lowerBound]), after = String(text[range.upperBound...])
        let started = Date()
        task = Task { [weak self] in
            guard let self else { return }
            let corrected = passage.contains(where: \.isLetter)
                ? before + (await self.corrector.correct(passage)) + after
                : text
            guard !Task.isCancelled else { DiagLog.write("Correction annulée (reprise de la frappe)"); return }
            self.lastHandled = text
            DiagLog.write(String(format: "Correction reçue en %.1fs, modifiée: %@", Date().timeIntervalSince(started), corrected != text ? "oui" : "non"))
            guard corrected != text else { self.setStatus(.ok); return }
            // L'utilisateur a-t-il modifié le texte entre-temps ?
            guard AXText.currentText(field.element) == text else {
                DiagLog.write("Texte modifié entre-temps : correction abandonnée")
                self.setStatus(.idle); return
            }

            self.pending = (field, text, corrected)
            if Settings.autoReplace {
                self.acceptPending()
            } else {
                let anchor = AXText.anchorRect(field.element)
                let frame = self.panel.show(original: text, corrected: corrected, near: anchor)
                DiagLog.write("Bulle affichée : ancre \(anchor.map { "\($0)" } ?? "aucune (souris)"), cadre \(frame)")
                self.setStatus(.suggestion)
                self.startFollowingField()
            }
        }
    }

    /// La bulle reste collée au champ : cachée quand on change d'app, d'onglet, de champ ou qu'on fait
    /// défiler le champ hors de l'écran ; réaffichée (et replacée) quand on y revient.
    private func startFollowingField() {
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followField() }
        }
    }

    private func stopFollowingField() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func followField() {
        guard let p = pending, followTimer != nil else { return }
        var visible = AXText.isStillFocused(p.field)
        let anchor = visible ? AXText.anchorRect(p.field.element) : nil
        if let a = anchor {
            // Champ sorti de l'écran (défilement) ? Coordonnées AX (origine en haut à gauche) → écran AppKit.
            let h = NSScreen.screens.first?.frame.height ?? 0
            let r = CGRect(x: a.minX, y: h - a.maxY, width: max(a.width, 1), height: max(a.height, 1))
            visible = NSScreen.screens.contains { $0.visibleFrame.intersects(r) }
        }
        if visible {
            if !panel.isVisible { DiagLog.write("Bulle réaffichée : retour dans le champ") }
            panel.reveal(near: anchor) // sans ancre lisible, la bulle reste où elle était
        } else if panel.isVisible {
            DiagLog.write("Bulle cachée : le champ n'a plus le focus ou n'est plus visible")
            panel.conceal()
        }
    }

    private func acceptPending() {
        guard let p = pending else { return }
        pending = nil
        stopFollowingField()
        panel.hide()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == p.field.pid,
              AXText.currentText(p.field.element) == p.original else {
            DiagLog.write("Remplacement annulé : app ou texte différent")
            setStatus(.idle); return
        }
        AXText.replace(field: p.field, original: p.original, corrected: p.corrected)
        DiagLog.write("Remplacement effectué : \(AXText.currentText(p.field.element) == p.corrected ? "OK" : "en cours (copier-coller)")")
        lastHandled = p.corrected
        setStatus(.ok)
    }

    private func dismissPending() {
        if pending != nil { DiagLog.write("Bulle fermée sans remplacer") }
        pending = nil
        stopFollowingField()
        panel.hide()
        setStatus(.idle)
    }

    // MARK: - Barre de menus

    private func setStatus(_ status: Status) {
        // Fin du cycle frappe → correction : l'app peut de nouveau être mise en veille.
        if status != .typing && status != .checking, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        let symbol: String
        switch status {
        case .idle: symbol = "text.badge.checkmark"
        case .typing: symbol = "pencil.line"
        case .checking: symbol = "ellipsis.circle"
        case .ok: symbol = "checkmark.circle"
        case .suggestion: symbol = "exclamationmark.bubble"
        case .disabled: symbol = "pause.circle"
        case .noPermission: symbol = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Correcteur")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Moteur : \(corrector.engineName)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠️ Autoriser l'accessibilité…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())

        let enabled = item("Correction active", #selector(toggleEnabled))
        enabled.state = Settings.enabled ? .on : .off
        menu.addItem(enabled)

        let auto = item("Remplacer sans demander", #selector(toggleAutoReplace))
        auto.state = Settings.autoReplace ? .on : .off
        menu.addItem(auto)

        let delayItem = NSMenuItem(title: "Corriger après une pause de…", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        for seconds in [0.5, 1.0, 1.5, 2.5, 4.0] {
            let label = seconds < 1 ? "\(Int(seconds * 1000)) ms"
                : seconds == 1 ? "1 seconde"
                : String(format: "%g secondes", seconds).replacingOccurrences(of: ".", with: ",")
            let i = item(label, #selector(setDelay(_:)))
            i.representedObject = seconds
            i.state = Settings.delay == seconds ? .on : .off
            delayMenu.addItem(i)
        }
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        let engineItem = NSMenuItem(title: "Moteur de correction", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        for engine in Settings.Engine.allCases {
            var title = engine.label
            if engine == .claudeCode && !corrector.isAvailable(.claudeCode) { title += " – non installé" }
            if engine == .claudeAPI && !corrector.isAvailable(.claudeAPI) { title += " – ajoute une clé" }
            let i = item(title, #selector(setEngine(_:)))
            i.representedObject = engine.rawValue
            i.state = Settings.engine == engine ? .on : .off
            i.isEnabled = corrector.isAvailable(engine)
            engineMenu.addItem(i)
        }
        engineMenu.autoenablesItems = false

        // Choix du modèle, séparément pour Claude Code et pour la clé API.
        for (title, engine, current) in [("Modèle pour Claude Code", Settings.Engine.claudeCode, Settings.claudeCodeModel),
                                         ("Modèle pour la clé API", Settings.Engine.claudeAPI, Settings.apiModel)] {
            engineMenu.addItem(.separator())
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            engineMenu.addItem(header)
            for model in Settings.ClaudeModel.allCases {
                let i = item("    " + model.label, #selector(setModel(_:)))
                i.representedObject = "\(engine.rawValue):\(model.rawValue)"
                i.state = current == model ? .on : .off
                i.isEnabled = corrector.isAvailable(engine)
                engineMenu.addItem(i)
            }
        }
        engineMenu.addItem(.separator())
        engineMenu.addItem(item(corrector.usesClaude ? "Modifier la clé API Claude…" : "Ajouter une clé API Claude…", #selector(editAPIKey)))
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        let login = item("Lancer au démarrage du Mac", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if Updater.sourceDir != nil {
            menu.addItem(.separator())
            if Updater.isRunning {
                let busy = NSMenuItem(title: "Mise à jour en cours…", action: nil, keyEquivalent: "")
                busy.isEnabled = false
                menu.addItem(busy)
            } else {
                menu.addItem(item("Mettre à jour (git pull + recompiler)", #selector(update)))
            }
        }

        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Astuce : ⌃⌥⌘C ouvre ce menu n'importe où", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(item("Quitter", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        if !Settings.enabled { task?.cancel(); dismissPending() }
        setStatus(Settings.enabled ? .idle : .disabled)
        rebuildMenu()
    }

    @objc private func toggleAutoReplace() {
        Settings.autoReplace.toggle()
        rebuildMenu()
    }

    @objc private func setDelay(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? Double { Settings.delay = s }
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Correcteur : lancement au démarrage impossible – \(error)")
        }
        rebuildMenu()
    }

    @objc private func setEngine(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let engine = Settings.Engine(rawValue: raw) {
            Settings.engine = engine
            DiagLog.write("Moteur choisi : \(engine.rawValue) → utilisé : \(corrector.effectiveEngine.rawValue)")
        }
        rebuildMenu()
    }

    @objc private func setModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 2, let model = Settings.ClaudeModel(rawValue: parts[1]) else { return }
        if parts[0] == Settings.Engine.claudeCode.rawValue {
            Settings.claudeCodeModel = model
            corrector.shutdown() // le Claude Code lancé à l'avance utilisait l'ancien modèle
        } else {
            Settings.apiModel = model
        }
        DiagLog.write("Modèle \(parts[0]) : \(model.rawValue)")
        rebuildMenu()
    }

    @objc private func editAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Clé API Claude"
        alert.informativeText = """
        Optionnel : avec une clé (console.anthropic.com), la correction est faite par Claude, plus fiable \
        que le modèle intégré au Mac. Les messages sont alors envoyés à Anthropic pour être corrigés. \
        Laisse vide pour revenir à Apple Intelligence (100 % sur le Mac).
        """
        let field = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        field.stringValue = corrector.apiKey ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        APIKeyStore.save(key.isEmpty ? nil : key)
        corrector.apiKey = key.isEmpty ? nil : key
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func update() {
        setStatus(.checking)
        Updater.run { [weak self] in
            self?.setStatus(Settings.enabled ? .idle : .disabled)
            self?.rebuildMenu()
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
