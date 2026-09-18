import Foundation

/// AI provider configuration, mirroring ClassMate's env-var convention so the
/// two apps are configured the same way (ClassMate `support.service.ts`):
///
///   SUPPORT_AI_BASE_URL  (default https://api.groq.com/openai/v1)
///   SUPPORT_AI_API_KEY   (falls back to GROQ_API_KEY)
///   SUPPORT_AI_MODEL     (default openai/gpt-oss-120b)
///
/// Resolution order for each value: process environment (Xcode Run / xcodebuild
/// dev) → Info.plist (injected at build time from `Config/Secrets.xcconfig`,
/// which reaches TestFlight/Release) → for the key only, the user-entered
/// Keychain value. No key is ever stored in source.
public enum AIConfig {
    public static let defaultBaseURL = "https://api.groq.com/openai/v1"
    /// Groq decommissioned `llama-3.3-70b-versatile` on 2026-06-17; a build still
    /// asking for it gets an error for every message, which is what "NOVA isn't
    /// working" looked like. Kept in step with ClassMate's `support.service.ts`.
    public static let defaultModel = "openai/gpt-oss-120b"
    /// A vision-capable Groq model for the magic pen (image prompts). Override
    /// with `SUPPORT_AI_VISION_MODEL` if Groq's lineup changes.
    ///
    /// `meta-llama/llama-4-scout-17b-16e-instruct` (the old default) and
    /// `qwen/qwen3.6-27b` (a value this drifted through) are BOTH gone from
    /// Groq's catalog as of 2026-09-18 — this is the same bug as ClassMate's
    /// `classnotes.ai.service.ts`/`ai.service.ts`, just on the keyless-local
    /// fallback path instead of the server. Kept in step with those.
    public static let defaultVisionModel = "qwen/qwen3.8-27b"

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

    /// Proxy mode (`SUPPORT_AI_MODE = proxy`): the base URL points at our NOVA
    /// proxy, which holds the Groq key server-side. In this mode the app sends
    /// the user's ClassMate session token as the bearer — no key in the binary.
    public static var isProxy: Bool {
        (value("SUPPORT_AI_MODE") ?? "").lowercased() == "proxy"
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
