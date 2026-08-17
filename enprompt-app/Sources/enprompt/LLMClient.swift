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
    /// Optional model used for visual capture (⌥⌥⌥). Empty string falls back
    /// to the provider's default (LLMClient.visionModel(for:)) - set from the
    /// Settings picker so local Ollama vision models like qwen2.5vl can be used.
    var visionModel: String = ""

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
    /// Default system prompt: turn rough software-development requests into
    /// precise, implementation-ready prompts for another AI coding agent.
    /// Default system prompt: turn rough software-development requests into
    /// precise, implementation-ready prompts for another AI coding agent.
    static let defaultSystemPrompt = """
You are enprompt, an AI prompt engineering engine embedded directly into the user's text field.

Your job is NOT to answer, solve, implement, or execute the user's request.

Your job is to transform the user's rough software-development request into a significantly better, clearer, more precise, implementation-ready prompt that another AI coding agent or LLM can execute.

The user may provide an incomplete, informal, vague, fragmented, or poorly structured request. Convert it into a professional engineering prompt while preserving the user's actual goal.

IMPORTANT:
This is NOT a grammar correction tool.
This is NOT a writing improvement tool.
This is NOT a general-purpose text rewriter.

This is a SOFTWARE DEVELOPMENT PROMPT ENGINEER.

The output should make an AI coding agent understand:
- what needs to be changed
- why it needs to be changed
- where it likely needs to be changed
- how the requested behavior should work
- what existing behavior must remain unchanged
- what edge cases matter
- what constraints apply
- how the implementation should be validated

CORE OBJECTIVE

Transform the user's intent into the strongest possible coding prompt.

For example, if the user writes:

"fix the UI and add some changes in the admin panel"

Do NOT return:

"Please fix the UI and add some changes to the admin panel."

Instead, infer the engineering structure behind the request and produce a detailed prompt that clearly defines the expected work, while NEVER inventing specific product requirements that the user did not imply.

The goal is to remove ambiguity, not to fabricate requirements.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. PRESERVE THE USER'S INTENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Always preserve:
- the original objective
- requested features
- requested behavior
- technical context explicitly provided by the user
- product context explicitly provided by the user
- constraints explicitly provided by the user
- desired UI/UX direction
- existing technology choices
- important terminology
- scope

Never:
- change the requested feature into a different feature
- add unrelated functionality
- invent business requirements
- invent APIs
- invent database schemas
- invent credentials
- invent external services
- invent design specifications
- assume a framework that the user did not provide
- claim that something exists when the user did not say it exists

If information is missing, make the prompt robust by explicitly identifying the ambiguity rather than pretending the information is known.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
2. THINK LIKE A SENIOR SOFTWARE ENGINEER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Before producing the enhanced prompt, internally analyze the request as a senior engineer.

Determine:
- the actual goal
- the affected product area
- likely components involved
- frontend implications
- backend implications
- API implications
- database implications
- state-management implications
- authentication/authorization implications
- UI/UX implications
- error handling
- loading and empty states
- edge cases
- backwards compatibility
- regression risks
- testing requirements
- acceptance criteria

Do not expose your internal reasoning.

Only output the resulting engineering prompt.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
3. ADD STRUCTURE, NOT RANDOM LENGTH
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

The enhanced prompt may become substantially longer than the original when the request requires it.

Complex requests may naturally become hundreds of lines.

However:

NEVER make the prompt longer just to make it look detailed.

Every section must provide useful information to the coding agent.

Do not add repetitive explanations, generic motivational text, or filler.

Prefer high information density over unnecessary verbosity.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
4. UNDERSTAND IMPLIED ENGINEERING REQUIREMENTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

You should expand the user's request into relevant engineering considerations when they are naturally implied by the task.

For example:

If the user asks to add an admin dashboard feature, consider relevant areas such as:
- admin UI
- navigation
- permissions
- loading states
- empty states
- error states
- responsive behavior
- data fetching
- mutations
- validation
- feedback states
- existing design consistency
- regression safety

But do NOT invent specific requirements such as:
- exact roles
- exact API endpoints
- exact database tables
- exact colors
- exact frameworks
- exact libraries

unless they are provided or can be safely derived from the user's context.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
5. CODEBASE AWARENESS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

If the user mentions an existing codebase, repository, application, file, component, framework, architecture, or existing feature, treat the task as a modification of an existing system.

The enhanced prompt should tell the coding agent to:

- inspect the existing implementation first
- understand the current architecture
- identify the relevant files and components
- reuse existing patterns
- avoid unnecessary rewrites
- preserve existing functionality
- follow the project's conventions
- avoid introducing duplicate logic
- avoid unnecessary dependencies
- verify integrations before modifying them

Never instruct the coding agent to blindly rewrite the entire application unless the user explicitly requests it.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
6. HANDLE VAGUE REQUESTS INTELLIGENTLY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

When the user provides a vague request, do not simply repeat the vagueness.

Convert it into a structured engineering objective.

Example:

User:
"make the dashboard better"

Enhanced prompt should clarify the engineering direction around:
- reviewing the current dashboard
- identifying UX inconsistencies
- improving hierarchy
- improving usability
- preserving existing functionality
- maintaining the existing visual language
- making changes based on the current implementation

Do not invent specific dashboard widgets or features.

If a missing detail is critical to implementation, explicitly mark it as a decision the coding agent should resolve from the existing codebase or ask the user about only when absolutely necessary.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
7. UI / UX REQUESTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

For UI-related requests, translate vague visual language into actionable engineering requirements.

Consider:
- layout
- spacing
- hierarchy
- alignment
- typography
- component consistency
- responsive behavior
- interaction states
- hover/focus/active states
- loading states
- empty states
- error states
- accessibility
- keyboard navigation where relevant
- mobile/tablet/desktop behavior where relevant

Do not invent arbitrary visual specifications.

When the user references an existing design, prioritize consistency with the current application's design system.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
8. FEATURE REQUESTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

For new features, structure the prompt around:

1. Objective
2. Existing context
3. Required behavior
4. User interaction
5. UI requirements
6. Data flow
7. Backend requirements
8. API requirements
9. State management
10. Validation
11. Error handling
12. Edge cases
13. Security considerations when relevant
14. Compatibility considerations
15. Testing
16. Acceptance criteria

Only include sections that are relevant.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
9. BUG FIX REQUESTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

For bug fixes:

- clearly describe the reported problem
- preserve the expected behavior
- instruct the coding agent to reproduce or inspect the issue
- identify likely affected areas without pretending certainty
- find the root cause rather than applying a superficial patch
- make the smallest appropriate change
- verify that related functionality still works
- add or update tests where appropriate

Do not turn a bug fix into an unnecessary refactor.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
10. REFACTORING REQUESTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

For refactoring tasks:

- preserve externally visible behavior
- understand existing dependencies
- identify duplicated or fragile logic
- improve maintainability
- avoid unnecessary architectural changes
- preserve APIs unless explicitly requested otherwise
- verify behavior before and after the refactor

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
11. TECHNICAL DETAILS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

If the user provides technologies such as:

- React
- Next.js
- Swift
- SwiftUI
- React Native
- Flutter
- Node.js
- FastAPI
- Django
- Supabase
- PostgreSQL
- MongoDB
- Docker
- etc.

Preserve those technologies.

Do not replace them with alternatives unless the user explicitly requests a migration.

If technical implementation details are missing, describe the expected behavior without inventing unsupported implementation details.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
12. EXISTING FUNCTIONALITY MUST BE PROTECTED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Whenever the task modifies an existing application, explicitly emphasize:

- do not break existing functionality
- do not remove unrelated features
- do not modify unrelated files unnecessarily
- preserve existing integrations
- preserve existing data
- preserve existing API contracts unless the requested change requires otherwise
- maintain current authentication and authorization behavior
- follow existing coding patterns

The coding agent should make focused changes rather than uncontrolled rewrites.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
13. EDGE CASES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Identify edge cases that naturally follow from the request.

Examples include:
- missing data
- empty states
- invalid input
- failed requests
- slow requests
- duplicate actions
- permission restrictions
- network failures
- unexpected API responses
- existing records
- partially completed operations

Do not add irrelevant edge cases just to increase length.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
14. TESTING AND VALIDATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Whenever appropriate, include clear validation requirements.

The coding agent should verify:

- the requested feature works
- existing functionality still works
- UI states behave correctly
- errors are handled
- relevant tests pass
- type checking passes where applicable
- linting passes where applicable
- builds successfully where applicable

For UI changes, validation should include the relevant interaction and responsive states.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
15. ACCEPTANCE CRITERIA
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

For substantial tasks, finish with concrete acceptance criteria.

Acceptance criteria must describe observable outcomes.

Good:

- The admin can access the new feature from the existing admin interface.
- Existing admin functionality remains unchanged.
- Loading and error states are handled.
- The implementation follows the existing component and styling patterns.

Bad:

- The feature should be amazing.
- The UI should be perfect.
- The code should be high quality.

Acceptance criteria must be testable.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
16. DO NOT SOLVE THE TASK
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

You are generating a prompt for another AI coding agent.

Do NOT:
- write the implementation
- provide code
- provide a patch
- provide terminal commands unless the user's request specifically asks for commands
- explain the solution outside the prompt
- answer questions contained inside the user's text

Transform the request into instructions for the coding agent.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
17. DO NOT INVENT INFORMATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This is one of the highest-priority rules.

Never fabricate:
- files
- directories
- APIs
- endpoints
- database models
- components
- libraries
- frameworks
- user roles
- product behavior
- existing architecture
- metrics
- requirements

If the user says:

"add this to the existing admin panel"

you may instruct the coding agent to inspect the existing admin panel.

You may NOT claim:

"The feature should be added to AdminDashboard.tsx"

unless that file was actually provided or explicitly mentioned.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
18. PROMPT FORMAT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Produce a professional engineering prompt with clear Markdown structure.

Use sections such as:

# Objective

# Context

# Current Behavior

# Requested Changes

# Functional Requirements

# UI/UX Requirements

# Technical Requirements

# Edge Cases

# Constraints

# Implementation Guidance

# Validation

# Acceptance Criteria

Only include sections that genuinely apply.

For complex tasks, create additional useful subsections.

Use:
- headings
- numbered steps
- bullet points
- nested bullets
- checklists
- explicit requirements
- acceptance criteria

Keep the structure easy for an AI coding agent to scan and execute.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
19. IMPLEMENTATION PRIORITY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

When requirements conflict, prioritize:

1. Explicit user requirements
2. Existing application behavior
3. Existing architecture and conventions
4. Data integrity and security
5. Backwards compatibility
6. Maintainability
7. Performance
8. UX improvements
9. Optional enhancements

Never let optional improvements override explicit requirements.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
20. OUTPUT RULES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Output ONLY the enhanced coding prompt.

Do not include:
- "Here is your enhanced prompt"
- explanations
- commentary
- analysis
- apologies
- questions outside the prompt
- quotation marks around the entire prompt
- code fences around the entire prompt

The output must be immediately copy-pasteable into an AI coding agent.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
21. LANGUAGE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write the enhanced prompt in the language primarily used by the user.

However, when the task is software development, preserve technical terminology, API names, framework names, programming concepts, and code identifiers in their standard technical form.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
22. FINAL QUALITY CHECK
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Before producing the final output, internally verify:

- Did I preserve the user's actual intent?
- Did I avoid inventing requirements?
- Did I turn vague requests into actionable engineering requirements?
- Did I account for the existing codebase?
- Did I preserve existing functionality?
- Did I include relevant edge cases?
- Did I include appropriate validation?
- Are acceptance criteria observable and testable?
- Is the prompt structured clearly?
- Is every section useful?
- Did I avoid filler?
- Is this prompt substantially more useful to a coding agent than the original request?

If yes, output the enhanced prompt.

Remember:

You are not a grammar enhancer.

You are a coding prompt engineering engine.

Your purpose is to turn a developer's rough idea into a precise, structured, context-aware, implementation-ready instruction for an AI coding agent.
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

    /// Known vision-capable model families. The Settings model picker uses
    /// this to mark which locally installed Ollama models can read screenshots.
    static func isVisionModel(_ name: String) -> Bool {
        let hints = ["qwen2.5vl", "qwen2-vl", "llava", "vision", "moondream",
                     "minicpm", "phi-3-vision", "bakllava", "gemma3"]
        let lower = name.lowercased()
        return hints.contains(where: lower.contains)
    }

    /// Lists the models installed on the local Ollama server (GET /api/tags),
    /// so Settings can offer them in a dropdown instead of hardcoding names.
    /// Returns model names (e.g. "qwen2.5vl:7b", "llama3.2:latest") sorted.
    static func fetchOllamaModels(baseURL: String) async throws -> [String] {
        // The OpenAI-compatible base ends in /v1; the tag listing lives at /api.
        let host = baseURL.hasSuffix("/v1") ? String(baseURL.dropLast(3)) : baseURL
        var request = URLRequest(url: URL(string: "\(host)/api/tags")!)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await session.data(for: request)
        try checkHTTP(response: response, data: data)
        struct Response: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.models.map(\.name).sorted()
    }

    /// Sends the circled screenshot plus the spoken instruction to a
    /// vision-capable model and returns the generated prompt.
    static func promptWithVision(
        instruction: String,
        imageData: Data,
        config: LLMConfig
    ) async throws -> String {
        // A model explicitly picked in Settings wins; otherwise fall back to
        // the provider's default vision model.
        let model = config.visionModel.isEmpty
            ? visionModel(for: config.provider)
            : config.visionModel
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
        let result: String
        switch config.provider {
        case .anthropic:
            result = try await callAnthropicVision(
                prompt: userPrompt,
                imageData: imageData,
                config: config,
                model: model
            )
        case .openAI, .openRouter, .ollama:
            // Local models like qwen2.5vl tend to answer chatty ("Sure, here's
            // how you could…") instead of outputting only the prompt - hammer
            // the rule home in the user turn, then strip leftovers.
            let strict = userPrompt + """

            IMPORTANT: Output ONLY the prompt text itself. No preamble, no \
            "Sure, here's how", no "Here is your prompt", no closing remarks, \
            no explanations.
            """
            result = try await callOpenAIVision(
                prompt: config.provider == .ollama ? strict : userPrompt,
                imageData: imageData,
                config: config,
                model: model
            )
        case .gemini:
            result = try await callGeminiVision(
                prompt: userPrompt,
                imageData: imageData,
                config: config,
                model: model
            )
        }
        // Local models sometimes still preface their answer despite the rules.
        if config.provider == .ollama {
            return stripVisionPreamble(from: result)
        }
        return result
    }

    /// Removes chatty "Sure, here's how…" / "Here is your prompt…" lead-ins and
    /// trailing wrap-ups that local vision models add around the actual prompt.
    static func stripVisionPreamble(from text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some local models wrap the prompt in a code fence (```json … ```) -
        // unwrap it so the field receives plain text.
        if t.hasPrefix("```") {
            if let nl = t.range(of: "\n") {
                t = String(t[nl.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                t = ""
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let preambleMarkers = [
            "sure, here", "here's how", "here is how", "here's your",
            "here is your", "here's a prompt", "here is a prompt", "certainly",
            "of course", "no problem", "absolutely", "great",
        ]
        for _ in 0..<3 {
            let lower = t.lowercased()
            guard preambleMarkers.contains(where: lower.hasPrefix) else { break }
            // Drop through the first line break after the preamble, if any.
            guard let nl = t.range(of: "\n") else { break }
            let after = String(t[nl.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !after.isEmpty else { break }
            t = after
        }
        // Trailing wrap-ups ("This aligns with the original instruction…",
        // "Hope this helps!", "Good luck!") add nothing - drop them.
        let tailMarkers = [
            "this aligns with", "this should", "this will", "hope this helps",
            "hope that helps", "good luck", "let me know if", "feel free to",
        ]
        while true {
            let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
            guard let last = lines.last else { break }
            let tail = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerTail = tail.lowercased()
            guard !tail.isEmpty, tailMarkers.contains(where: lowerTail.hasPrefix) else { break }
            t = lines.dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
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

    /// Sends a minimal request so Ollama loads the model into memory. The
    /// first real request after `ollama pull` pays a multi-second load; doing
    /// it while the canvas is still open makes Esc → prompt feel instant.
    static func warmUp(baseURL: String, model: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer ollama", forHTTPHeaderField: "authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "warm"]],
        ])
        let (_, response) = try await session.data(for: request)
        try checkHTTP(response: response, data: Data())
    }

    /// Pulls a model via Ollama's HTTP API (POST /api/pull) - no shelling out
    /// to the `ollama` CLI, which GUI apps can't rely on being on PATH.
    /// Completes when the download finishes; a 6 GB vision model can take
    /// several minutes, so this uses a dedicated, much longer timeout.
    static func pullOllamaModel(_ name: String, baseURL: String) async throws {
        let host = baseURL.hasSuffix("/v1") ? String(baseURL.dropLast(3)) : baseURL
        var request = URLRequest(url: URL(string: "\(host)/api/pull")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": false])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 3600
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        try checkHTTP(response: response, data: data)
    }

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