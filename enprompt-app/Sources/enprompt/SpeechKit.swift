import AVFoundation
import Foundation

/// A language the "Teach me" feature can speak in.
///
/// Most languages use Apple's built-in natural (Siri-quality) voices, which
/// are free, local, and need zero install. A few (Nepali) have no Apple voice,
/// so they fall back to the free Piper neural voice (sherpa-onnx) - the
/// engine + model download once and then work fully offline.
struct TeachLanguage: Identifiable, Equatable {
    let id: String             // BCP-47 tag: "en-US", "hi-IN", "ne-NP", ...
    let displayName: String    // "English", "Hindi", "Nepali", ...
    let nativeName: String     // "English", "हिन्दी", "नेपाली", ...
    /// Extra guidance for the LLM about how to write the explanation
    /// (e.g. Hinglish = Hindi in Roman script mixed with English).
    let spokenHint: String?
    /// True when Apple ships no voice for this language and the Piper engine
    /// must be used instead (a one-time free download).
    let usesPiper: Bool

    init(id: String, displayName: String, nativeName: String, spokenHint: String? = nil, usesPiper: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.nativeName = nativeName
        self.spokenHint = spokenHint
        self.usesPiper = usesPiper
    }

    var label: String { nativeName == displayName ? displayName : "\(nativeName) · \(displayName)" }
    /// The name the LLM is told to answer in.
    var spokenName: String { displayName }
}

/// The free voice engine behind the "Teach me" feature.
///
/// - `.edge`: Microsoft's neural voices via the free edge-tts helper (most
///   natural, every language, unlimited) - one tiny free install.
/// - `.apple`: Apple's built-in natural voices, always offline. Nepali falls
///   back to the free Piper voice here.
enum TeachVoiceEngine: String, CaseIterable, Identifiable {
    case edge
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .edge: return "Neural (most natural)"
        case .apple: return "Apple built-in (offline)"
        }
    }
}

/// All the free, local speech engines behind the "Teach me" feature.
enum SpeechKit {

    // MARK: - Language catalog

    static let languages: [TeachLanguage] = [
        TeachLanguage(id: "en-US", displayName: "English", nativeName: "English"),
        TeachLanguage(id: "hi-IN", displayName: "Hindi", nativeName: "हिन्दी"),
        TeachLanguage(id: "hi-Latn", displayName: "Hinglish", nativeName: "हिंग्लिश", spokenHint: "Hinglish is Hindi written in Roman (Latin) letters, freely mixing English words and phrases exactly how people speak it every day - e.g. \"Yeh concept simple hai, let me explain with one easy example.\" Write naturally like that, not like a translation."),
        TeachLanguage(id: "ne-NP", displayName: "Nepali", nativeName: "नेपाली", usesPiper: true),
        TeachLanguage(id: "es-ES", displayName: "Spanish", nativeName: "Español"),
        TeachLanguage(id: "zh-CN", displayName: "Chinese", nativeName: "中文"),
        TeachLanguage(id: "fr-FR", displayName: "French", nativeName: "Français"),
        TeachLanguage(id: "de-DE", displayName: "German", nativeName: "Deutsch"),
        TeachLanguage(id: "it-IT", displayName: "Italian", nativeName: "Italiano"),
        TeachLanguage(id: "ja-JP", displayName: "Japanese", nativeName: "日本語"),
        TeachLanguage(id: "ko-KR", displayName: "Korean", nativeName: "한국어"),
        TeachLanguage(id: "pt-BR", displayName: "Portuguese", nativeName: "Português"),
        TeachLanguage(id: "ru-RU", displayName: "Russian", nativeName: "Русский"),
        TeachLanguage(id: "ar-SA", displayName: "Arabic", nativeName: "العربية"),
        TeachLanguage(id: "nl-NL", displayName: "Dutch", nativeName: "Nederlands"),
        TeachLanguage(id: "sv-SE", displayName: "Swedish", nativeName: "Svenska"),
        TeachLanguage(id: "tr-TR", displayName: "Turkish", nativeName: "Türkçe"),
        TeachLanguage(id: "th-TH", displayName: "Thai", nativeName: "ไทย"),
    ]

    static func language(for id: String) -> TeachLanguage {
        languages.first(where: { $0.id == id }) ?? languages[0]
    }

    /// A short sentence to preview a voice in its own language.
    static func previewSentence(for language: TeachLanguage) -> String {
        switch language.id {
        case "hi-IN": return "नमस्ते! मैं आपको कुछ भी समझा सकता हूँ।"
        case "hi-Latn": return "Namaste! Main aapko kuch bhi samjha sakta hoon - bilkul simple tarike se, ekdum clear."
        case "ne-NP": return "नमस्ते! म तपाईंलाई जे पनि सिकाउन सक्छु।"
        case "es-ES": return "¡Hola! Puedo enseñarte cualquier cosa."
        case "zh-CN": return "你好！我可以教你任何东西。"
        case "fr-FR": return "Bonjour ! Je peux t'apprendre n'importe quoi."
        case "de-DE": return "Hallo! Ich kann dir alles beibringen."
        case "it-IT": return "Ciao! Posso insegnarti qualsiasi cosa."
        case "ja-JP": return "こんにちは！何でも教えられます。"
        case "ko-KR": return "안녕하세요! 무엇이든 가르쳐 드릴 수 있어요."
        case "pt-BR": return "Olá! Posso te ensinar qualquer coisa."
        case "ru-RU": return "Привет! Я могу научить тебя чему угодно."
        case "ar-SA": return "مرحبًا! يمكنني أن أعلّمك أي شيء."
        case "nl-NL": return "Hallo! Ik kan je alles leren."
        case "sv-SE": return "Hej! Jag kan lära dig vad som helst."
        case "tr-TR": return "Merhaba! Sana her şeyi öğretebilirim."
        case "th-TH": return "สวัสดี! ฉันสอนอะไรก็ได้ให้คุณ"
        default: return "Hi! I can teach you anything."
        }
    }

    // MARK: - Apple natural voices

    /// Voices installed (or downloadable by macOS) for a language tag,
    /// sorted best-first: Siri-quality (premium) first, then enhanced, then
    /// standard - so the Settings picker shows the nicest voice on top.
    static func appleVoices(for languageID: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languageID) || $0.language.hasPrefix(languageID.prefix(2)) }
            .sorted { lhs, rhs in
                let l = Self.qualityRank(lhs.quality) * 10 + (lhs.gender == .female ? 0 : 1)
                let r = Self.qualityRank(rhs.quality) * 10 + (rhs.gender == .female ? 0 : 1)
                return l < r
            }
    }

    /// The single best installed/downloadable voice for a language, or nil if
    /// macOS has none for it. "Best" = highest quality (premium Siri voice),
    /// preferring a female voice for a friendly teacher sound.
    static func bestAppleVoice(for languageID: String) -> AVSpeechSynthesisVoice? {
        let voices = appleVoices(for: languageID)
        if voices.isEmpty {
            // Fall back to the loose language match AVSpeechSynthesisVoice
            // offers directly (it may pick up a locale variant like en-GB).
            return AVSpeechSynthesisVoice(language: languageID)
        }
        return voices.first
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 0
        case .enhanced: return 1
        default: return 2
        }
    }

    // MARK: - Edge neural voices (free, unlimited, most natural)

    /// Microsoft's Edge neural voices - the same premium voices behind Azure
    /// TTS, reachable for free through Edge's public endpoint (no API key, no
    /// length limits, 322 voices). Requires the tiny free `edge-tts` Python
    /// helper, installed once with a single click.
    static func edgeVoice(for languageID: String) -> String {
        switch languageID {
        case "en-US": return "en-US-AriaNeural"
        case "hi-IN": return "hi-IN-SwaraNeural"
        case "hi-Latn": return "hi-IN-SwaraNeural"
        case "ne-NP": return "ne-NP-HemkalaNeural"
        case "es-ES": return "es-ES-ElviraNeural"
        case "zh-CN": return "zh-CN-XiaoxiaoNeural"
        case "fr-FR": return "fr-FR-DeniseNeural"
        case "de-DE": return "de-DE-KatjaNeural"
        case "it-IT": return "it-IT-ElsaNeural"
        case "ja-JP": return "ja-JP-NanamiNeural"
        case "ko-KR": return "ko-KR-SunHiNeural"
        case "pt-BR": return "pt-BR-FranciscaNeural"
        case "ru-RU": return "ru-RU-SvetlanaNeural"
        case "ar-SA": return "ar-SA-ZariyahNeural"
        case "nl-NL": return "nl-NL-ColetteNeural"
        case "sv-SE": return "sv-SE-SofieNeural"
        case "tr-TR": return "tr-TR-EmelNeural"
        case "th-TH": return "th-TH-PremwadeeNeural"
        default: return "en-US-AriaNeural"
        }
    }

    /// Checks that python3 + the free edge-tts helper are available. The
    /// result is cached for the session (the probe takes a few hundred ms).
    private static var edgeInstalledCache: Bool?
    static var edgeInstalled: Bool {
        if let cached = edgeInstalledCache { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import edge_tts"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            edgeInstalledCache = process.terminationStatus == 0
        } catch {
            edgeInstalledCache = false
        }
        return edgeInstalledCache ?? false
    }

    /// One-time free install of the edge-tts helper (~5 MB, via pip into the
    /// user's Python). After this, all 17 languages get the premium neural
    /// voices with no limits.
    static func installEdge() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "pip", "install", "--user", "--quiet", "--disable-pip-version-check", "edge-tts"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            try await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
        }
        guard process.terminationStatus == 0 else { throw SpeechError.edgeInstallFailed }
        edgeInstalledCache = true
    }

    /// Maps the app's speaking-speed slider (0.30...0.55) onto Edge's
    /// percent notation ("+10%", "-15%") - Edge's default sits near 0.45.
    private static func edgeRatePercent(_ rate: Double) -> String {
        let percent = Int(((rate - 0.45) / 0.25 * 30).rounded())
        return percent >= 0 ? "+\(percent)%" : "\(percent)%"
    }

    /// Synthesizes text with the free Edge neural voice (mp3) and plays it.
    /// Cancellation stops generation + playback. `onPlaybackProgress` reports
    /// elapsed playback fraction (0...1). `onWord` fires with the exact
    /// character range of the word about to be spoken (from the voice's own
    /// subtitle timestamps), so the overlay highlight matches the speech.
    static func speakEdge(_ text: String, voice: String, rate: Double, onPlaybackProgress: ((Double) -> Void)? = nil, onWord: ((NSRange) -> Void)? = nil) async throws {
        guard edgeInstalled else { throw SpeechError.edgeNotInstalled }
        let mp3URL = piperRoot.appendingPathComponent("edge-\(UUID().uuidString.prefix(8)).mp3")
        // The text goes through a temp file so any content works verbatim:
        // newlines, quotes, emoji - nothing needs escaping.
        let textURL = piperRoot.appendingPathComponent("edge-\(UUID().uuidString.prefix(8)).txt")
        // The same synth pass emits per-word subtitle cues (WebVTT), which
        // give us exact timestamps for the word highlight.
        let vttURL = piperRoot.appendingPathComponent("edge-\(UUID().uuidString.prefix(8)).vtt")
        try text.write(to: textURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: mp3URL)
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: vttURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-m", "edge_tts",
            "--voice=\(voice)",
            "--rate=\(edgeRatePercent(rate))",
            "--file=\(textURL.path)",
            "--write-media=\(mp3URL.path)",
            "--write-subtitles=\(vttURL.path)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? FileManager.default.removeItem(at: mp3URL) }
        while process.isRunning {
            try await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
        }
        guard process.terminationStatus == 0 else { throw SpeechError.synthesisFailed }

        // Word cues sorted by spoken time: (start time, char range in text).
        let cues: [(time: Double, range: NSRange)]
        if let vtt = try? String(contentsOf: vttURL, encoding: .utf8) {
            cues = Self.parseWordCues(vtt, in: text as NSString)
        } else {
            cues = []
        }

        let player = try AVAudioPlayer(contentsOf: mp3URL)
        player.volume = 1.0
        player.play()
        var cueIndex = 0
        while player.isPlaying {
            let time = player.currentTime
            if !cues.isEmpty, let onWord {
                while cueIndex < cues.count && cues[cueIndex].time <= time {
                    onWord(cues[cueIndex].range)
                    cueIndex += 1
                }
            } else {
                onPlaybackProgress?(time / player.duration)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled {
                player.stop()
                throw CancellationError()
            }
        }
    }

    /// Parses edge-tts's WebVTT subtitles (one cue per spoken word) into
    /// (start time, character range in the original text). Words are matched
    /// sequentially; anything the voice rephrased falls back to a position
    /// estimate so the highlight never stalls.
    private static func parseWordCues(_ vtt: String, in text: NSString) -> [(time: Double, range: NSRange)] {
        var cues: [(time: Double, range: NSRange)] = []
        var searchPos = 0
        var lastEnd = 0.0
        let lines = vtt.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let arrow = line.range(of: "-->") {
                let start = Self.vttTime(String(line[..<arrow.lowerBound]))
                let end = Self.vttTime(String(line[arrow.upperBound...]))
                lastEnd = max(lastEnd, end)
                if index + 1 < lines.count {
                    let raw = lines[index + 1]
                        .replacingOccurrences(of: "<v [^>]*>", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "</v>", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty {
                        let range: NSRange
                        if searchPos < text.length {
                            let found = text.range(
                                of: raw,
                                options: [.caseInsensitive],
                                range: NSRange(location: searchPos, length: text.length - searchPos)
                            )
                            if found.location != NSNotFound {
                                range = found
                                searchPos = found.location + found.length
                            } else {
                                // The voice rephrased the word (numbers, symbols):
                                // estimate by progress and keep going.
                                let fraction = lastEnd > 0 ? start / lastEnd : 0
                                range = NSRange(location: min(Int(Double(text.length) * fraction), text.length - 1), length: 1)
                            }
                        } else {
                            range = NSRange(location: text.length - 1, length: 1)
                        }
                        cues.append((start, range))
                    }
                }
            }
            index += 1
        }
        return cues
    }

    /// "00:01:02.345" or "01:02.345" → seconds.
    private static func vttTime(_ raw: String) -> Double {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
            .compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        var seconds = parts.last ?? 0
        if parts.count >= 2 { seconds += parts[parts.count - 2] * 60 }
        if parts.count >= 3 { seconds += parts[0] * 3600 }
        return seconds
    }

    // MARK: - Piper (sherpa-onnx) for languages Apple doesn't have

    /// The free Piper Nepali voice, converted for sherpa-onnx.
    /// Model: https://huggingface.co/rhasspy/piper-voices (ne_NP chitwan medium)
    private static let piperModelURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-ne_NP-chitwan-medium.tar.bz2")!
    /// The universal2 macOS build of the sherpa-onnx CLI (contains bin/sherpa-onnx-offline-tts).
    private static let piperEngineURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/sherpa-onnx-v1.13.5-osx-universal2-shared.tar.bz2")!

    /// ~/Library/Application Support/enprompt/piper/ - the engine + models
    /// live outside the app bundle so updates never wipe them.
    private static var piperRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("enprompt", isDirectory: true)
            .appendingPathComponent("piper", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var piperEngineDir: URL { piperRoot.appendingPathComponent("engine", isDirectory: true) }
    private static var piperModelDir: URL { piperRoot.appendingPathComponent("model", isDirectory: true) }

    /// Both tarballs extract with a single top-level folder (e.g.
    /// "vits-piper-ne_NP-chitwan-medium/"); this resolves a file inside it.
    private static func piperPath(_ name: String, in dir: URL) -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let top = contents.first(where: { $0.hasDirectoryPath }) {
            return top.appendingPathComponent(name)
        }
        return dir.appendingPathComponent(name)
    }

    private static var piperEngineBinary: URL {
        piperPath("bin/sherpa-onnx-offline-tts", in: piperEngineDir)
    }

    private static var piperModelONNX: URL { piperPath("ne_NP-chitwan-medium.onnx", in: piperModelDir) }
    private static var piperModelTokens: URL { piperPath("tokens.txt", in: piperModelDir) }
    private static var piperModelData: URL { piperPath("espeak-ng-data", in: piperModelDir) }

    static var piperEngineInstalled: Bool {
        FileManager.default.fileExists(atPath: piperEngineBinary.path)
    }

    static var piperModelInstalled: Bool {
        FileManager.default.fileExists(atPath: piperModelONNX.path)
            && FileManager.default.fileExists(atPath: piperModelTokens.path)
            && FileManager.default.fileExists(atPath: piperModelData.path)
    }

    static var piperInstalled: Bool { piperEngineInstalled && piperModelInstalled }

    /// Downloads the Piper engine (~43 MB) and the Nepali voice (~63 MB) into
    /// Application Support, reporting combined progress (0...1). Used once,
    /// then everything is local and offline.
    static func installPiper(progress: @escaping (Double) -> Void) async throws {
        let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 1800
            config.timeoutIntervalForResource = 1800
            return URLSession(configuration: config)
        }()

        if !piperEngineInstalled {
            let tar = try await download(piperEngineURL, to: piperRoot.appendingPathComponent("engine.tar.bz2"), session: session) { fraction in
                progress(fraction * 0.4)
            }
            try extract(tar, into: piperEngineDir)
            try FileManager.default.removeItem(at: tar)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: piperEngineBinary.path)
        }
        progress(0.45)

        if !piperModelInstalled {
            let tar = try await download(piperModelURL, to: piperRoot.appendingPathComponent("model.tar.bz2"), session: session) { fraction in
                progress(0.45 + fraction * 0.55)
            }
            try extract(tar, into: piperModelDir)
            try FileManager.default.removeItem(at: tar)
        }
        progress(1)
    }

    /// Downloads a URL into a local file, reporting download progress.
    private static func download(_ url: URL, to destination: URL, session: URLSession, progress: @escaping (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SpeechError.downloadFailed
        }
        let expected = http.expectedContentLength > 0 ? Double(http.expectedContentLength) : 0
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var received: Double = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Double(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    progress(min(received / expected, 1))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Double(buffer.count)
            if expected > 0 {
                progress(min(received / expected, 1))
            }
        }
        return destination
    }

    /// Extracts a .tar.bz2 into a directory. macOS ships bzip2 + tar, so no
    /// external tools are needed.
    private static func extract(_ archive: URL, into directory: URL) throws {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SpeechError.downloadFailed }
    }

    /// Synthesizes text to a WAV with the Piper engine, then plays it.
    /// Runs on a background task: generation is CPU-bound and can take a few
    /// seconds for long explanations. Cancellation stops generation + playback.
    /// `onPlaybackProgress` reports elapsed playback fraction (0...1).
    static func speakPiper(_ text: String, onPlaybackProgress: ((Double) -> Void)? = nil) async throws {
        guard piperInstalled else { throw SpeechError.piperNotInstalled }
        let wavURL = piperRoot.appendingPathComponent("speak-\(UUID().uuidString.prefix(8)).wav")
        let process = Process()
        process.executableURL = piperEngineBinary
        process.arguments = [
            "--vits-model=\(piperModelONNX.path)",
            "--vits-tokens=\(piperModelTokens.path)",
            "--vits-data-dir=\(piperModelData.path)",
            "--output-filename=\(wavURL.path)",
            text,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? FileManager.default.removeItem(at: wavURL) }
        while process.isRunning {
            try await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
        }
        guard process.terminationStatus == 0 else { throw SpeechError.synthesisFailed }
        try await playWAV(wavURL, onPlaybackProgress: onPlaybackProgress)
    }

    /// Plays a WAV file to completion (used by the Piper engine).
    private static func playWAV(_ url: URL, onPlaybackProgress: ((Double) -> Void)? = nil) async throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = 1.0
        player.play()
        while player.isPlaying {
            onPlaybackProgress?(player.currentTime / player.duration)
            try await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled {
                player.stop()
                throw CancellationError()
            }
        }
    }
}

enum SpeechError: LocalizedError {
    case downloadFailed
    case piperNotInstalled
    case edgeNotInstalled
    case edgeInstallFailed
    case synthesisFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "The voice download failed - check your internet connection and try again"
        case .piperNotInstalled: return "The Nepali voice isn't downloaded yet"
        case .edgeNotInstalled: return "The free neural voices aren't installed yet"
        case .edgeInstallFailed: return "The free neural voice helper couldn't be installed - check your internet connection and try again"
        case .synthesisFailed: return "The voice couldn't be generated - please try again"
        }
    }
}