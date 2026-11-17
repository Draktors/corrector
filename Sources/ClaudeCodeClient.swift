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
    private final class Worker: @unchecked Sendable {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let started = Date()
        var model: Settings.ClaudeModel = .haiku
        var errorTail = Data()

        /// Arrêt immédiat (SIGKILL) : avec un simple SIGTERM, Claude Code met ~0,4 s à se fermer, et on
        /// attendrait ce temps-là avant d'afficher la correction. Rien à sauvegarder : pas de session.
        func kill() {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Processus prêts à servir. On en garde deux : chaque texte est envoyé aux deux en même temps et on
    /// prend la première réponse. Le temps de réponse de Claude varie beaucoup (de 1,3 s à plus de 3 s) :
    /// doubler la demande coupe la plupart des réponses lentes, pour un coût minime avec Haiku.
    ///
    /// On en garde quatre prêts : quand l'utilisateur reprend la frappe, les deux processus déjà utilisés
    /// sont perdus, et la pause suivante arrive souvent avant que leurs remplaçants aient fini de démarrer
    /// (un processus « froid » ajoute 0,5 à 1 s). On prend toujours les deux plus anciens.
    private var spares: [Worker] = []
    private let parallelRequests = 2
    private let poolSize = 4
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

    private func isUsable(_ w: Worker) -> Bool {
        w.process.isRunning && Date().timeIntervalSince(w.started) < maxSpareAge && w.model == Settings.claudeCodeModel
    }

    /// Lance des Claude Code en attente, jusqu'à en avoir `poolSize` encore frais.
    func prewarm() {
        spares.removeAll { w in
            if isUsable(w) { return false }
            w.process.terminate()
            return true
        }
        while spares.count < poolSize, let w = launch() { spares.append(w) }
    }

    /// Arrête les processus en attente (à la fermeture de l'app).
    func shutdown() {
        spares.forEach { $0.process.terminate() }
        spares = []
    }

    func correct(_ text: String) async throws -> String {
        prewarm() // complète si un processus manque (il démarrera pendant que l'autre répond)
        let workers = Array(spares.prefix(parallelRequests)) // les plus anciens, donc les mieux démarrés
        guard !workers.isEmpty else { throw Failure(message: "Claude Code introuvable ou impossible à lancer") }
        spares.removeFirst(workers.count) // chaque processus ne sert qu'une fois (pas d'historique)
        prewarm()    // on prépare tout de suite les suivants (prochaine pause)

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": "<message>\n\(text)\n</message>"],
        ]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        let sent = Date()
        for w in workers {
            w.input.fileHandleForWriting.write(line)
            try? w.input.fileHandleForWriting.close()
        }

        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            workers.forEach { $0.kill() }
        }
        defer {
            timeout.cancel()
            workers.forEach { $0.kill() }
        }

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (i, w) in workers.enumerated() {
                    group.addTask { (i, try await Self.readAnswer(from: w)) }
                }
                var lastError: Error?
                while let next = await group.nextResult() {
                    switch next {
                    case .success(let (i, answer)):
                        // On arrête tout de suite l'autre processus : sinon le groupe attendrait sa réponse.
                        workers.forEach { $0.kill() }
                        group.cancelAll()
                        DiagLog.write(String(format: "Claude Code : réponse en %.2fs (processus %d/%d, lancé %.1fs avant)",
                                             Date().timeIntervalSince(sent), i + 1, workers.count,
                                             sent.timeIntervalSince(workers[i].started)))
                        return answer
                    case .failure(let error):
                        lastError = error
                    }
                }
                throw lastError ?? Failure(message: "Claude Code : aucune réponse")
            }
        } onCancel: {
            // L'utilisateur a repris la frappe : on arrête les appels en cours.
            workers.forEach { $0.kill() }
        }
    }

    /// Lit la sortie d'un processus jusqu'à la réponse.
    private nonisolated static func readAnswer(from worker: Worker) async throws -> String {
        for try await raw in worker.output.fileHandleForReading.bytes.lines {
            guard let data = raw.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "assistant":
                // La réponse arrive ici ; l'événement « result » ne vient que 2 à 4 s plus tard
                // (Claude Code finit sa session). On prend donc la réponse tout de suite.
                let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let text = content.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue } // bloc de réflexion seul : on attend le texte
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
        // Priorité « action de l'utilisateur » : l'app tourne en arrière-plan, macOS ralentirait sinon le processus.
        p.qualityOfService = .userInitiated
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
