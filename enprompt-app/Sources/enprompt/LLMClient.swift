import Foundation

enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case openRouter
    case gemini
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openAI: return "OpenAI (Codex / GPT)"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (local)"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-5"
        case .openAI: return "gpt-4o-mini"
        // Pinned free model: "openrouter/free" is a rotating pool that can
        // route to useless models (e.g. content-safety classifiers that
        // answer "User Safety: safe" instead of enhancing text).
        case .openRouter: return "dots-studio/dots-3-note-preview:free"
        // Older Gemini models (2.5-flash, 2.5-flash-lite) are retired for new
        // accounts; gemini-3-flash-preview is current and vision-capable.
        case .gemini: return "gemini-3-flash-preview"
        case .ollama: return "llama3.2"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .ollama: return "http://127.0.0.1:11434/v1"
        }
    }

    /// Infers the provider from the API key prefix, so the user only has to
    /// paste a key - no URLs, no dropdowns.
    /// sk-ant-* Claude · sk-or-v1-* OpenRouter · AIza*/AQ.* Gemini · sk-* OpenAI
    /// · ollama (any case) for the local Ollama server.
    static func providerForAPIKey(_ key: String) -> LLMProvider? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sk-ant-") { return .anthropic }
        if trimmed.hasPrefix("sk-or-v1-") { return .openRouter }
        if trimmed.hasPrefix("AIza") || trimmed.hasPrefix("AQ.") { return .gemini }
        if trimmed.lowercased().hasPrefix("ollama") { return .ollama }
        if trimmed.hasPrefix("sk-") { return .openAI }
        return nil
    }
}

struct LLMConfig {
    var provider: LLMProvider = .anthropic
    var model: String = LLMProvider.anthropic.defaultModel
    var apiKey: String = ""
    var baseURL: String = LLMProvider.anthropic.defaultBaseURL

    var isConfigured: Bool { !apiKey.isEmpty && !model.isEmpty }
}

enum LLMError: LocalizedError {
    case notConfigured
    case unknownProvider
    case http(Int, String)
    case decoding(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No LLM configured - add an API key in Settings"
        case .unknownProvider:
            return "Couldn't detect the provider from this key - keys start with sk-ant- (Claude), sk- (ChatGPT/Codex), sk-or-v1- (OpenRouter), AIza (Gemini) or ollama (local)"
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(300))"
        case .decoding(let message):
            return "Response decoding failed: \(message)"
        case .emptyResponse:
            return "The model returned an empty response"
        }
    }

    /// Friendly, human-readable message for end users - never leaks raw HTTP
    /// bodies, JSON error dumps, or "coding-style" details. Used by the toast
    /// overlay and Settings status rows.
    var userFacingMessage: String {
        switch self {
        case .notConfigured:
            return "No AI provider is set up yet. Open enprompt Settings and paste your API key."
        case .unknownProvider:
            return "We couldn't recognise that API key. Keys start with sk-ant- (Claude), sk- (ChatGPT/Codex), sk-or-v1- (OpenRouter), AIza (Gemini) or ollama (local)."
        case .http(let code, _):
            switch code {
            case 401, 403:
                return "Your API key was rejected. Open Settings and paste a valid key."
            case 402, 429:
                return "You've hit the provider's rate limit or run out of credits. Wait a few minutes or check your plan."
            case 400:
                return "The AI provider rejected that request. Please try again."
            case 404:
                return "That AI model wasn't found. Check the model name in Settings."
            case 500...599:
                return "The AI provider is having issues right now. Please try again in a moment."
            default:
                return "Something went wrong while talking to the AI (HTTP \(code)). Please try again."
            }
        case .decoding:
            return "The AI's response couldn't be read. Please try again."
        case .emptyResponse:
            return "The AI returned an empty response. Please try again."
        }
    }
}

/// Minimal async client for Anthropic's Messages API and any
/// OpenAI-compatible chat completions endpoint (OpenAI, OpenRouter, Ollama,
/// LM Studio, ...).
enum LLMClient {

    /// All calls share a session with a generous timeout: vision requests with
    /// a large screenshot can exceed the default 60s.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 240
        return URLSession(configuration: config)
    }()

    /// Default system prompt: polish the user's exact text - never replace it
    /// with something different.
    static let defaultSystemPrompt = """
    You are enprompt, a writing enhancer embedded directly in the user's text field. \
    The user wrote the text below and wants YOU to improve THAT text - not to \
    answer it, not to explain how to do what it describes, and not to write \
    anything new.

    RULES
    - Improve ONLY the given text: fix grammar, spelling and punctuation, \
    clarify awkward phrasing, tighten weak sentences, improve flow and structure, \
    and choose better words where it helps.
    - Keep the meaning, intent, topic, and tone of the original exactly. Never \
    change the subject, never invent facts, and never add instructions about how \
    to perform the task described in the text.
    - Keep the length natural: roughly the same as the input. Expand slightly \
    only when it genuinely improves clarity; never pad.
    - Respond in the same language as the input.
    - If the input is a short note or command, output the improved version of \
    that note or command - still written as the user wrote it, not as instructions \
    to them.

    OUTPUT FORMAT
    - Output ONLY the enhanced text, exactly as it should appear in the field.
    - No preamble, no commentary, no markdown code fences, no quotes.
    """

/// System prompt for visual capture: turn a screenshot + spoken instruction
    /// into one detailed, production-grade prompt for an AI coding assistant.
    /// Written as a senior prompt engineer: expands a founder's one-line idea
    /// into a complete specification the assistant can execute safely.
    static let visionSystemPrompt = """
    You are enprompt Vision: a senior prompt engineer and software architect. \
    The user circled/annotated an area of their screen - a UI, website, app, or \
    terminal - and spoke a short instruction about a change they want (often a \
    startup founder with a one-line idea: "add an admin panel", "make it \
    mobile-friendly", "add a transfer flow"). The screenshot may contain \
    orange/yellow annotations - circles, arrows, triangles, rectangles, \
    scribbles - that mark exactly which elements they mean. Read the screenshot \
    carefully: understand its context, its visual style, and the element the \
    user is pointing at. Then write ONE complete, self-contained prompt that an \
    AI coding assistant (Claude Code, opencode, Cursor, Copilot, ...) can \
    execute to deliver exactly that change - done well, and production-ready.

    HOW TO WRITE THE PROMPT - PROMPT ENGINEERING RULES
    - Open with a one-sentence objective: what the change is, where, and why.
    - Reference the actual elements visible in the screenshot by name and \
    location ("the login card in the center", "the sidebar on the left", "the \
    submit button under the form") so the assistant edits the right thing.
    - Break the work into numbered, ordered requirements - never one vague \
    sentence. Cover data, UI, behavior, and interactions separately.
    - Expand vague instructions into concrete scope, and label the expansions \
    as suggestions the user can trim ("include: ..."). Examples:
      "Add an admin panel" → authentication + role-based access; a management \
      table with search, filter, and pagination; add/edit/delete with \
      confirmations; an analytics overview (users, revenue, activity); audit \
      logging of admin actions; loading, empty, and error states for every view.
      "Add a transfer flow" → validation of the amount and recipient, a \
      confirmation step, a processing state, success/error feedback, and the \
      transfer recorded in history.
      "Make it mobile-friendly" → responsive breakpoints, touch targets, \
      tap-friendly navigation, and restructured layouts for narrow screens.
    - Specify the desired result for every state: loading, empty, success, \
    error, and edge cases (empty input, invalid values, slow network, \
    duplicate submissions, missing permissions).
    - Include acceptance criteria ("Done when: ...") so the assistant can \
    verify the work before finishing.
    - State constraints explicitly: preserve existing behavior; do not touch \
    unrelated parts of the codebase; do not add features the user did not ask \
    for; keep dependencies minimal; follow the project's existing patterns, \
    architecture, and style.
    - Production safety: prefer backward-compatible changes; validate all user \
    input; handle errors without crashing; never delete data without \
    confirmation; keep migrations additive; mention tests for non-trivial \
    logic.
    - Scalability: favor clean structure - components, services, state - and \
    sensible naming; design so the feature extends rather than hardcodes; \
    never duplicate existing logic.
    - UI quality: good visual hierarchy, consistent spacing and alignment with \
    the screenshot's style, responsive behavior, keyboard access, and basic \
    accessibility (labels, focus, contrast).
    - Be as long as the task needs - typically 300-800 words. Complete over \
    brief, but never pad with filler. Do not invent a tech stack the user \
    never mentioned; if the stack is unclear, ask in one line at the end \
    instead of guessing.
    - If the instruction is ambiguous, pick the most reasonable \
    interpretation, state it in the first sentence ("This prompt builds: ..."), \
    and proceed.

    OUTPUT FORMAT
    - Output ONLY the prompt text. No preamble, no "Here is your prompt", no \
    explanations, no quotes around the whole thing.
    - Light markdown (headings, bullet lists) is allowed and encouraged for \
    readability, but never wrap the prompt in a code fence.
    - The prompt must stand alone: anyone reading it knows exactly what to \
    build, in what order, and what "done" looks like.
    """

    /// Some configured models have no vision support; use a dedicated vision
    /// model for those providers instead.
    static func visionModel(for provider: LLMProvider) -> String {
        switch provider {
        case .openRouter:
            return "nvidia/nemotron-nano-12b-v2-vl:free"
        case .ollama:
            return provider.defaultModel
        case .anthropic, .openAI, .gemini:
            return provider.defaultModel
        }
    }

    /// Sends the circled screenshot plus the spoken instruction to a
    /// vision-capable model and returns the generated prompt.
    static func promptWithVision(
        instruction: String,
        imageData: Data,
        config: LLMConfig
    ) async throws -> String {
        let model = visionModel(for: config.provider)
        let userPrompt: String
        if instruction.isEmpty {
            userPrompt = """
            No spoken instruction was given. Based only on the annotations in the \
            screenshot and the visual context, write the prompt for the change the \
            user is indicating.
            """
        } else {
            userPrompt = """
            Spoken instruction: \(instruction)

            Use the annotations and the screenshot to write the prompt as instructed.
            """
        }
        switch config.provider {
        case .anthropic:
            return try await callAnthropicVision(
                prompt: userPrompt,
                imageData: imageData,
                config: config,
                model: model
            )
        case .openAI, .openRouter, .ollama:
            return try await callOpenAIVision(
                prompt: userPrompt,
                imageData: imageData,
                config: config,
                model: model
            )
        case .gemini:
            return try await callGeminiVision(
                prompt: userPrompt,
                imageData: imageData,
                config: config,
                model: model
            )
        }
    }

    /// Alternative presets selectable in Settings (Admin panel).
    static let promptPresets: [String: String] = [
        "X.com (Twitter) reply": """
        You are enprompt, a social media reply writer. The text below is a post \
        or message the user wants to reply to. Write a natural X/Twitter-style \
        reply TO that text: short, conversational, punchy, and on-topic. Match \
        the tone of the original post (serious stays serious, playful stays \
        playful) and add your own brief point of view - do not just repeat the \
        post back. No hashtags spam, no emojis unless the original uses them, \
        no markdown, no quotes around the reply. Output ONLY the reply text.
        """,
        "Founder reply": """
        You are enprompt, writing replies on behalf of a startup founder. The text \
        below is an incoming message, comment, or review. Write a founder-style \
        reply: warm, direct, personal, confident, and concise - like a real \
        person building their company, not corporate marketing. Acknowledge the \
        person, add one genuine point, and keep it under 3-4 sentences. Never \
        invent facts or commitments. Output ONLY the reply text - no markdown, \
        no quotes.
        """,
        "Email reply": """
        You are enprompt, an email reply writer. The text below is the email or \
        message the user is replying to. Write a clear, polite, professional \
        email reply: greet appropriately, address each point of the original, \
        and end with a clear next step or question. Keep the same language as \
        the original email. Output ONLY the reply text - no subject line, no \
        markdown, no quotes.
        """,
        "Concise & punchy": """
        You are enprompt, a sharp editing assistant embedded in the user's text field. \
        Rewrite the draft to be tighter and punchier while keeping its exact meaning \
        and tone. Cut filler words, shorten sentences, remove repetition, and keep \
        only what matters. Output ONLY the rewritten text - no preamble, no markdown, \
        no quotes.
        """,
        "Ultra detailed": """
        You are enprompt, a deep-dive writing assistant embedded in the user's text field. \
        Expand the draft aggressively: unpack every idea with reasoning, add concrete \
        examples, define implicit terms, and structure longer drafts into clear \
        sections or paragraphs. Stay strictly faithful to the author's intent - never \
        invent facts. Aim for 2-3x the original length when it improves clarity. \
        Output ONLY the rewritten text - no preamble, no markdown, no quotes.
        """,
        "Academic & formal": """
        You are enprompt, an academic writing assistant embedded in the user's text field. \
        Rewrite the draft in a formal, precise register: exact vocabulary, carefully \
        structured arguments, hedged claims where appropriate, and a scholarly tone. \
        Preserve the original meaning and never invent citations or facts. Output ONLY \
        the rewritten text - no preamble, no markdown, no quotes.
        """,
    ]

    static func enhance(
        _ original: String,
        config: LLMConfig,
        systemPrompt: String = defaultSystemPrompt,
        onProgress: ((Int) -> Void)? = nil
    ) async throws -> String {
        guard config.isConfigured else { throw LLMError.notConfigured }
        let userPrompt = """
        Original text:
        \"\"\"
        \(original)
        \"\"\"

        Follow the system prompt's instructions exactly and output only the result.
        """

        switch config.provider {
        case .anthropic:
            return try await callAnthropic(prompt: userPrompt, systemPrompt: systemPrompt, config: config)
        case .openAI, .openRouter, .ollama:
            return try await callOpenAI(prompt: userPrompt, systemPrompt: systemPrompt, config: config, onProgress: onProgress)
        case .gemini:
            return try await callGemini(prompt: userPrompt, systemPrompt: systemPrompt, config: config)
        }
    }

    // MARK: - Validation

    /// Sends a minimal request to the provider to verify the API key is real
    /// and usable. Throws on any failure; the message is shown to the user.
    static func validate(config: LLMConfig) async throws {
        guard let provider = LLMProvider.providerForAPIKey(config.apiKey) else {
            throw LLMError.unknownProvider
        }
        switch provider {
        case .anthropic:
            var request = URLRequest(url: URL(string: "\(config.baseURL)/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]],
            ])
            let (data, response) = try await LLMClient.session.data(for: request)
            try checkHTTP(response: response, data: data)
        case .openAI, .openRouter, .ollama:
            var request = URLRequest(url: URL(string: "\(config.baseURL)/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]],
            ])
            let (data, response) = try await LLMClient.session.data(for: request)
            try checkHTTP(response: response, data: data)
        case .gemini:
            var request = URLRequest(url: URL(string: "\(config.baseURL)/models/\(config.model):generateContent")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "contents": [["role": "user", "parts": [["text": "hi"]]]],
                "generationConfig": ["maxOutputTokens": 1],
            ])
            let (data, response) = try await LLMClient.session.data(for: request)
            try checkHTTP(response: response, data: data)
        }
    }

    // MARK: - Anthropic

    private static func callAnthropic(prompt: String, systemPrompt: String, config: LLMConfig) async throws -> String {
        var request = URLRequest(url: URL(string: "\(config.baseURL)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 2048,
            "system": systemPrompt,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await LLMClient.session.data(for: request)
        try checkHTTP(response: response, data: data)

        struct Response: Decodable {
            struct Content: Decodable { let text: String }
            let content: [Content]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.content.first?.text else { throw LLMError.emptyResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI-compatible (streaming)

    private static func callOpenAI(
        prompt: String,
        systemPrompt: String,
        config: LLMConfig,
        onProgress: ((Int) -> Void)?
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "\(config.baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "authorization")

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.4,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await LLMClient.session.bytes(for: request)
        try checkHTTP(response: response, data: Data())

        var full = ""
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let text = delta["content"] as? String else { continue }
            full += text
            onProgress?(full.count)
        }

        let result = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw LLMError.emptyResponse }
        return result
    }

    // MARK: - Gemini

    private static func callGemini(prompt: String, systemPrompt: String, config: LLMConfig) async throws -> String {
        var request = URLRequest(url: URL(string: "\(config.baseURL)/models/\(config.model):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            // Thinking models are much slower; enprompt's tasks don't need it.
            "generationConfig": ["maxOutputTokens": 2048, "temperature": 0.4, "thinkingConfig": ["thinkingBudget": 0]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await LLMClient.session.data(for: request)
        try checkHTTP(response: response, data: data)

        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                        /// Thinking models may prefix answers with thoughts.
                        let thought: Bool?
                    }
                    let parts: [Part]?
                }
                let content: Content
            }
            let candidates: [Candidate]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.candidates.first?.content.parts?
            .first(where: { $0.thought != true })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    // MARK: - Vision (Anthropic)

    private static func callAnthropicVision(prompt: String, imageData: Data, config: LLMConfig, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(config.baseURL)/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": visionSystemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": imageData.base64EncodedString(),
                            ],
                        ],
                    ],
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await LLMClient.session.data(for: request)
        try checkHTTP(response: response, data: data)

        struct Response: Decodable {
            struct Content: Decodable { let text: String }
            let content: [Content]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.content.first?.text else { throw LLMError.emptyResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Vision (OpenAI-compatible)

    private static func callOpenAIVision(prompt: String, imageData: Data, config: LLMConfig, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(config.baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "authorization")

        let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.4,
            "max_tokens": 2048,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": dataURL]],
                    ],
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await LLMClient.session.data(for: request)
        try checkHTTP(response: response, data: data)

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content else { throw LLMError.emptyResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Vision (Gemini)

    private static func callGeminiVision(prompt: String, imageData: Data, config: LLMConfig, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(config.baseURL)/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": visionSystemPrompt]]],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": imageData.base64EncodedString(),
                            ],
                        ],
                    ],
                ],
            ],
            "generationConfig": ["maxOutputTokens": 2048, "temperature": 0.4, "thinkingConfig": ["thinkingBudget": 0]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await LLMClient.session.data(for: request)
        try checkHTTP(response: response, data: data)

        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                        let thought: Bool?
                    }
                    let parts: [Part]?
                }
                let content: Content
            }
            let candidates: [Candidate]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.candidates.first?.content.parts?
            .first(where: { $0.thought != true })?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    // MARK: - Usage tracking

    /// Rough token estimate (OpenAI-style heuristic: ~4 characters per token).
    /// Used for the on-screen usage counter - never billed against the
    /// provider, so an estimate is all that's needed.
    static func estimateTokens(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    /// Vision image token estimate: OpenAI-style tiles bill ≈85 tokens per
    /// 512×512 tile, i.e. roughly one token per 3084 px².
    static func estimateImageTokens(pixels: Int) -> Int {
        max(1, pixels / 3084)
    }

    // MARK: - Shared

    private static func checkHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(http.statusCode, body)
        }
    }
}