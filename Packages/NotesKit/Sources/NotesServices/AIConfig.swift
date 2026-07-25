import Foundation

/// AI provider configuration, mirroring ClassMate's env-var convention so the
/// two apps are configured the same way (ClassMate `support.service.ts`):
///
///   SUPPORT_AI_BASE_URL  (default https://api.groq.com/openai/v1)
///   SUPPORT_AI_API_KEY   (falls back to GROQ_API_KEY)
///   SUPPORT_AI_MODEL     (default llama-3.3-70b-versatile)
///
/// Resolution order for each value: process environment (Xcode Run / xcodebuild
/// dev) → Info.plist (injected at build time from `Config/Secrets.xcconfig`,
/// which reaches TestFlight/Release) → for the key only, the user-entered
/// Keychain value. No key is ever stored in source.
public enum AIConfig {
    public static let defaultBaseURL = "https://api.groq.com/openai/v1"
    public static let defaultModel = "llama-3.3-70b-versatile"
    /// A vision-capable Groq model for the magic pen (image prompts). Override
    /// with `SUPPORT_AI_VISION_MODEL` if Groq's lineup changes.
    public static let defaultVisionModel = "meta-llama/llama-4-scout-17b-16e-instruct"

    private static func value(_ name: String) -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment[name] {
            let trimmed = fromEnv.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let fromPlist = Bundle.main.object(forInfoDictionaryKey: name) as? String {
            let trimmed = fromPlist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    public static func baseURL() -> URL {
        let raw = value("SUPPORT_AI_BASE_URL") ?? defaultBaseURL
        return URL(string: raw) ?? URL(string: defaultBaseURL)!
    }

    public static var chatCompletionsURL: URL {
        baseURL().appendingPathComponent("chat/completions")
    }

    public static func model() -> String {
        value("SUPPORT_AI_MODEL") ?? defaultModel
    }

    public static func visionModel() -> String {
        value("SUPPORT_AI_VISION_MODEL") ?? defaultVisionModel
    }

    /// The API key: env / Info.plist (build-injected) first, then the user's
    /// Keychain key from Settings.
    public static func apiKey(secrets: any SecretStore) -> String {
        value("SUPPORT_AI_API_KEY")
            ?? value("GROQ_API_KEY")
            ?? secrets.get(.groqAPIKey)
            ?? ""
    }

    /// A local Ollama-style endpoint is treated as keyless (parity with
    /// ClassMate's `isEnabled`).
    public static func isKeylessLocal() -> Bool {
        let host = (baseURL().host ?? "").lowercased()
        return host.contains("localhost") || host == "127.0.0.1"
    }
}
