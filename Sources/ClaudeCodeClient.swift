import Foundation

/// Correction via Claude Code (`claude -p`) : utilise l'abonnement Claude de la personne connectée
/// dans Claude Code, sans clé API.
///
/// Pour aller plus vite, un processus Claude Code est lancé **à l'avance** dès que l'utilisateur commence
/// à taper (mode « stream-json », qui attend sans limite de temps). Au moment de la pause, il n'y a plus
/// qu'à lui envoyer le texte : le temps de démarrage (1 à 3 s) se fait pendant la frappe.
@MainActor
final class ClaudeCodeClient {
    struct Failure: Error { let message: String }

    /// Un processus lancé, prêt à recevoir un seul message.
    private final class Worker {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let started = Date()
        var model: Settings.ClaudeModel = .haiku
        var errorTail = Data()
    }

    private var spare: Worker?
    private let instructions: String
    /// Au-delà, le processus en attente est remplacé (évite un processus « endormi » trop longtemps).
    private let maxSpareAge: TimeInterval = 600

    init(instructions: String) { self.instructions = instructions }

    /// Chemin de l'exécutable `claude`, s'il est installé. Une app lancée depuis le Finder n'a pas le PATH
    /// du terminal, donc on regarde aux emplacements habituels.
    nonisolated static let executable: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    nonisolated static var isAvailable: Bool { executable != nil }

    /// Lance un Claude Code en attente s'il n'y en a pas déjà un, encore frais.
    private func isUsable(_ w: Worker) -> Bool {
        w.process.isRunning && Date().timeIntervalSince(w.started) < maxSpareAge && w.model == Settings.claudeCodeModel
    }

    func prewarm() {
        if let s = spare, isUsable(s) { return }
        spare?.process.terminate()
        spare = launch()
    }

    /// Arrête le processus en attente (à la fermeture de l'app).
    func shutdown() {
        spare?.process.terminate()
        spare = nil
    }

    func correct(_ text: String) async throws -> String {
        let worker: Worker
        if let s = spare, isUsable(s) {
            worker = s
        } else {
            spare?.process.terminate()
            guard let w = launch() else { throw Failure(message: "Claude Code introuvable ou impossible à lancer") }
            worker = w
        }
        spare = nil // chaque processus ne sert qu'une fois (pas d'historique entre deux messages)
        prewarm()   // on prépare tout de suite le suivant (ligne suivante, ou prochaine pause)

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": "<message>\n\(text)\n</message>"],
        ]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        worker.input.fileHandleForWriting.write(line)
        try? worker.input.fileHandleForWriting.close()

        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            if worker.process.isRunning { worker.process.terminate() }
        }
        defer { timeout.cancel() }

        return try await withTaskCancellationHandler {
            for try await raw in worker.output.fileHandleForReading.bytes.lines {
                guard let data = raw.data(using: .utf8),
                      let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "assistant":
                    // La réponse arrive ici en ~0,7 s ; l'événement « result » ne vient que 2 à 4 s plus tard
                    // (Claude Code finit sa session). On prend donc la réponse tout de suite.
                    let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    let text = content.filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }.joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue } // bloc de réflexion seul : on attend le texte
                    worker.process.terminate()
                    return text
                case "result":
                    let result = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if (event["is_error"] as? Bool) == true || result.isEmpty {
                        throw Failure(message: "Claude Code : \(result.isEmpty ? "réponse vide" : result)")
                    }
                    return result
                default:
                    continue
                }
            }
            let err = String(decoding: worker.errorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "Claude Code s'est arrêté sans répondre. \(err)")
        } onCancel: {
            // L'utilisateur a repris la frappe : on arrête l'appel en cours.
            if worker.process.isRunning { worker.process.terminate() }
        }
    }

    private func launch() -> Worker? {
        guard let executable = Self.executable else { return nil }
        let w = Worker()
        w.model = Settings.claudeCodeModel
        let p = w.process
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = [
            "-p",
            "--model", w.model.cliAlias,     // Haiku par défaut : largement suffisant pour l'orthographe, économe en quota
            "--system-prompt", instructions,
            "--tools", "",                   // aucun outil : il ne fait que répondre
            "--no-session-persistence",      // pas d'historique enregistré
            "--strict-mcp-config",           // aucun serveur MCP chargé
            "--disable-slash-commands",
            "--setting-sources", "",         // ignore les réglages et CLAUDE.md
            "--effort", "low",               // tâche simple : réponse plus rapide
            "--input-format", "stream-json", // attend le message sans limite de temps
            "--output-format", "stream-json",
            "--verbose",                     // requis par stream-json
        ]
        // Dossier neutre, pour ne lire aucun fichier de projet.
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        p.environment = env
        p.standardInput = w.input
        p.standardOutput = w.output
        p.standardError = w.errors
        // On vide stderr au fil de l'eau (en gardant la fin pour le diagnostic).
        w.errors.fileHandleForReading.readabilityHandler = { [weak w] handle in
            let chunk = handle.availableData
            guard let w, !chunk.isEmpty else { return }
            w.errorTail = (w.errorTail + chunk).suffix(500)
        }
        do {
            try p.run()
            return w
        } catch {
            DiagLog.write("Impossible de lancer Claude Code : \(error)")
            return nil
        }
    }
}
