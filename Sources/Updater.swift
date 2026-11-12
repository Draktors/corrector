import AppKit

/// Mise à jour depuis le code source : `git pull`, `./build.sh`, puis relance de la nouvelle version.
/// Disponible seulement pour une app compilée sur ce Mac (`build.sh` y note le dossier du code).
@MainActor
enum Updater {
    private(set) static var isRunning = false

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Correcteur-update.log")

    /// Dossier du dépôt git d'où l'app a été compilée, s'il existe encore.
    static var sourceDir: String? {
        guard let dir = Bundle.main.object(forInfoDictionaryKey: "CorrecteurSourceDir") as? String else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir + "/.git"), fm.isExecutableFile(atPath: dir + "/build.sh") else { return nil }
        return dir
    }

    /// `onFinish` est appelé en cas d'échec (en cas de succès, l'app se relance).
    static func run(onFinish: @escaping () -> Void) {
        guard !isRunning, let dir = sourceDir else { return }
        isRunning = true
        DiagLog.write("Mise à jour : git pull + build dans \(dir)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Shell de connexion : même PATH que dans le Terminal (git, swiftc, codesign…).
        p.arguments = ["-lc", "{ git pull --ff-only && ./build.sh; } > \"$CORRECTEUR_LOG\" 2>&1"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["CORRECTEUR_LOG"] = logURL.path
        env["GIT_TERMINAL_PROMPT"] = "0"                 // jamais de question dans un terminal invisible
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"  // échoue au lieu d'attendre un mot de passe
        p.environment = env
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    isRunning = false
                    if status == 0 {
                        DiagLog.write("Mise à jour : compilation OK, relance")
                        relaunch(built: dir + "/build/Correcteur.app")
                    } else {
                        DiagLog.write("Mise à jour : échec (code \(status))")
                        showFailure()
                        onFinish()
                    }
                }
            }
        }
        do {
            try p.run()
        } catch {
            isRunning = false
            DiagLog.write("Mise à jour : impossible de lancer le shell – \(error)")
            showFailure()
            onFinish()
        }
    }

    /// Attend la fin de l'app, remplace l'app installée (si elle n'est pas lancée depuis build/) et la relance.
    private static func relaunch(built: String) {
        let target = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        if [ "$TARGET" != "$BUILT" ]; then rm -rf "$TARGET" && /usr/bin/ditto "$BUILT" "$TARGET"; fi
        /usr/bin/open -n "$TARGET"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["TARGET"] = target
        env["BUILT"] = built
        p.environment = env
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func showFailure() {
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let tail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "La mise à jour a échoué"
        alert.informativeText = (tail.isEmpty ? "Aucun détail." : tail) + "\n\nJournal complet : ~/Library/Logs/Correcteur-update.log"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Ouvrir le journal")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(logURL) }
    }
}
