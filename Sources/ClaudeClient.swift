import Foundation
import Security

/// Clé API Claude rangée dans le Trousseau macOS (jamais en clair sur le disque).
enum APIKeyStore {
    private static let service = "com.local.correcteur.anthropic"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Appel direct à l'API Messages d'Anthropic (pas de SDK officiel en Swift).
enum ClaudeClient {
    struct Failure: Error { let message: String }

    static func correct(_ text: String, apiKey: String, instructions: String, model: Settings.ClaudeModel) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model.apiID,
            "max_tokens": 4096,
            "output_config": ["effort": "low"], // tâche simple : réponse rapide et peu coûteuse
            "system": instructions,
            "messages": [["role": "user", "content": "<message>\n\(text)\n</message>"]],
        ]
        // Repli automatique sur un autre modèle en cas de refus (Haiku n'a pas cette option côté serveur).
        if model != .haiku {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let json else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw Failure(message: msg)
        }
        if (json["stop_reason"] as? String) == "refusal" { throw Failure(message: "refus") }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let out = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !out.isEmpty else { throw Failure(message: "réponse vide") }
        return out
    }
}
