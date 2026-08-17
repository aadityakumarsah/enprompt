import Foundation

/// Hidden CLI mode: run with `enprompt --self-test` to verify key detection and
/// provider validation against the real APIs. Exits 0 on full pass.
enum SelfTest {

    static func run() async {
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("SELFTEST \(ok ? "PASS" : "FAIL") \(name): \(detail)")
            if !ok { failures += 1 }
        }

        // 1. Key prefix detection
        check("detect claude", LLMProvider.providerForAPIKey("sk-ant-test-123") == .anthropic, "sk-ant-")
        check("detect openrouter", LLMProvider.providerForAPIKey("sk-or-v1-test") == .openRouter, "sk-or-v1-")
        check("detect openai", LLMProvider.providerForAPIKey("sk-proj-test") == .openAI, "sk-proj-")
        check("detect gemini", LLMProvider.providerForAPIKey("AIzaSyTest") == .gemini, "AIza")
        check("detect gemini AQ", LLMProvider.providerForAPIKey("AQ.Ab8RN6LnuthWWq0o90zyhJhmMo9wTw") == .gemini, "AQ.")
        check("detect ollama", LLMProvider.providerForAPIKey("ollama") == .ollama, "ollama")
        check("detect garbage", LLMProvider.providerForAPIKey("hello") == nil, "unknown -> nil")

        // 2. Real endpoint validation with the key currently stored in the
        //    Keychain (provider detected from the key itself). HTTP 429 quota
        //    errors are SKIPped, not failed - the key can be valid but
        //    temporarily out of quota.
        func isQuota(_ error: Error) -> Bool {
            if case LLMError.http(429, _) = error { return true }
            return false
        }

        func skip(_ name: String, _ detail: String) {
            print("SELFTEST SKIP \(name): \(detail)")
        }

        if let realKey = KeychainStore.load(),
           let detected = LLMProvider.providerForAPIKey(realKey),
           !realKey.isEmpty {
            let config = LLMConfig(
                provider: detected,
                model: detected.defaultModel,
                apiKey: realKey,
                baseURL: detected.defaultBaseURL
            )
            do {
                try await LLMClient.validate(config: config)
                check("stored key (\(detected.displayName))", true, "validated")
            } catch where isQuota(error) {
                skip("stored key (\(detected.displayName))", "HTTP 429 quota exceeded - switch to a different provider or wait for reset")
            } catch {
                check("stored key (\(detected.displayName))", false, "unexpected rejection: \(error.localizedDescription)")
            }
        } else {
            check("stored key", false, "no usable key in Keychain")
        }

        let claude = LLMConfig(provider: .anthropic, model: LLMProvider.anthropic.defaultModel, apiKey: "sk-ant-test-invalid", baseURL: LLMProvider.anthropic.defaultBaseURL)
        do {
            try await LLMClient.validate(config: claude)
            check("claude invalid key", false, "invalid key was accepted")
        } catch let LLMError.http(code, _) where (400...403).contains(code) {
            check("claude invalid key", true, "rejected with HTTP \(code)")
        } catch {
            check("claude invalid key", false, "unexpected: \(error.localizedDescription)")
        }

        let openai = LLMConfig(provider: .openAI, model: LLMProvider.openAI.defaultModel, apiKey: "sk-test-invalid", baseURL: LLMProvider.openAI.defaultBaseURL)
        do {
            try await LLMClient.validate(config: openai)
            check("openai invalid key", false, "invalid key was accepted")
        } catch let LLMError.http(code, _) where (400...403).contains(code) {
            check("openai invalid key", true, "rejected with HTTP \(code)")
        } catch {
            check("openai invalid key", false, "unexpected: \(error.localizedDescription)")
        }

        let gemini = LLMConfig(provider: .gemini, model: LLMProvider.gemini.defaultModel, apiKey: "AIzaFakeKey000", baseURL: LLMProvider.gemini.defaultBaseURL)
        do {
            try await LLMClient.validate(config: gemini)
            check("gemini invalid key", false, "invalid key was accepted")
        } catch let LLMError.http(code, _) where (400...403).contains(code) {
            check("gemini invalid key", true, "rejected with HTTP \(code)")
        } catch {
            check("gemini invalid key", false, "unexpected: \(error.localizedDescription)")
        }

        let unknown = LLMConfig(provider: .openAI, model: "x", apiKey: "not-a-key", baseURL: "https://example.com")
        do {
            try await LLMClient.validate(config: unknown)
            check("unknown key", false, "was accepted")
        } catch LLMError.unknownProvider {
            check("unknown key", true, "refused before any request")
        } catch {
            check("unknown key", false, "unexpected: \(error.localizedDescription)")
        }

        // 3. Vision: request screen recording permission, capture a region,
        //    and check the PNG round-trips.
        var screenRecording = ScreenCapture.isAuthorized
        if !screenRecording {
            await ScreenCapture.requestPermission()
            try? await Task.sleep(nanoseconds: 300_000_000)
            screenRecording = ScreenCapture.isAuthorized
        }
        if screenRecording {
            if let png = await ScreenCapture.capturePNG(rect: CGRect(x: 0, y: 0, width: 400, height: 300), maxDimension: 800) {
                let sig = png.prefix(8)
                let isPNG = sig.count == 8 && sig[0] == 0x89 && sig[1] == 0x50
                check("screen capture", isPNG, "png \(png.count) bytes")
            } else {
                check("screen capture", false, "capture returned nil")
            }
        } else {
            check("screen capture", false, "screen recording permission not granted")
        }

        // 4. Vision model produces a prompt from a real image, using the
        //    provider detected from the stored key (ollama uses the local
        //    vision model picked in Settings, falling back to the default).
        if let realKey = KeychainStore.load(),
           let detected = LLMProvider.providerForAPIKey(realKey),
           !realKey.isEmpty {
            let visionOverride = UserDefaults.standard.string(forKey: "visionModel") ?? ""
            let config = LLMConfig(
                provider: detected,
                model: visionOverride.isEmpty ? LLMClient.visionModel(for: detected) : visionOverride,
                apiKey: realKey,
                baseURL: detected.defaultBaseURL
            )
            do {
                let prompt = try await LLMClient.promptWithVision(
                    instruction: "Move the button to the top right corner",
                    imageData: await ScreenCapture.capturePNG(rect: CGRect(x: 0, y: 0, width: 400, height: 300), maxDimension: 800) ?? Data(),
                    config: config
                )
                check("vision prompt", !prompt.isEmpty && prompt.count > 10, prompt.prefix(120).description)
            } catch where isQuota(error) {
                skip("vision prompt", "HTTP 429 quota exceeded")
            } catch {
                check("vision prompt", false, "failed: \(error.localizedDescription)")
            }
        } else {
            check("vision prompt", false, "no usable key in Keychain")
        }

        // 5. Ollama: the local model listing the Settings picker relies on,
        //    plus the vision-capability detection used for the camera icons.
        do {
            let models = try await LLMClient.fetchOllamaModels(baseURL: LLMProvider.ollama.defaultBaseURL)
            check("ollama model list", !models.isEmpty, "\(models.count) models: \(models.joined(separator: ", "))")
            let vision = models.filter(LLMClient.isVisionModel)
            check("ollama vision detection", !vision.isEmpty, "vision-capable: \(vision.joined(separator: ", "))")
        } catch {
            skip("ollama model list", "local Ollama server not running: \(error.localizedDescription)")
        }

        print("SELFTEST \(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")")
    }
}