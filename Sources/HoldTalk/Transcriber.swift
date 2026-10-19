import Foundation

/// Transcribes audio, preferring the keep-warm whisper-server (fast path, ~1.5–3.5s)
/// and falling back to a one-shot whisper-cli subprocess (cold path, ~17s) when the
/// server isn't available.
final class Transcriber {
    private var currentProcess: Process?
    private var cancelled = false
    private let queue = DispatchQueue(label: "holdtalk.transcriber")
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Locates the whisper.cpp CLI binary (Homebrew installs it as whisper-cli).
    static func findWhisperCLI() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cli",
            "/usr/local/bin/whisper-cpp",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func transcribe(audioURL: URL, mode: DictationMode, completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelled = false
            let language = Settings.spokenLanguage

            let text: String?
            if let baseURL = WhisperServerManager.shared.waitForServer(mode: mode) {
                Log.write("transcribe: server path \(baseURL)")
                text = self.transcribeViaServer(baseURL: baseURL, audioURL: audioURL, mode: mode, language: language)
                    ?? self.transcribeViaCLI(audioURL: audioURL, mode: mode, language: language) // server hiccup → CLI
            } else {
                Log.write("transcribe: CLI fallback path")
                text = self.transcribeViaCLI(audioURL: audioURL, mode: mode, language: language)
            }
            Log.write("transcribe: result \(text.map { "\($0.count) chars" } ?? "nil")")
            WhisperServerManager.shared.touch()
            completion(self.cancelled ? nil : text)
        }
    }

    /// Cancels any in-flight transcription (e.g. when a new dictation starts).
    func cancel() {
        cancelled = true
        if let process = currentProcess, process.isRunning {
            currentProcess = nil
            process.terminate()
        }
    }

    /// True when the text is dominated by Devanagari script — the bn→hi misdetection signature.
    static func looksLikeHindiMisdetection(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let devanagari = letters.filter { (0x0900...0x097F).contains($0.value) }
        return Double(devanagari.count) / Double(letters.count) > 0.5
    }

    // MARK: - Server path

    func transcribeViaServer(baseURL: URL, audioURL: URL, mode: DictationMode, language: SpokenLanguage) -> String? {
        let text = postInference(baseURL: baseURL, audioURL: audioURL, mode: mode, language: language)

        // Whisper often misdetects Bangla as Hindi on short clips. If auto-detect
        // produced Devanagari, re-run once forced to Bangla.
        if language == .auto, mode == .transcribe, let text, Self.looksLikeHindiMisdetection(text), !cancelled {
            return postInference(baseURL: baseURL, audioURL: audioURL, mode: mode, language: .bengali) ?? text
        }
        return text
    }

    private func postInference(baseURL: URL, audioURL: URL, mode: DictationMode, language: SpokenLanguage) -> String? {
        guard let audioData = try? Data(contentsOf: audioURL) else { return nil }

        let boundary = "holdtalk-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "text")
        field("language", language.rawValue)
        // The source language and the output task are independent. Send both on
        // every request, including retries and requests to an already-warm server.
        field("translate", mode == .translate ? "true" : "false")
        field("temperature", "0.0")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: baseURL.appendingPathComponent("inference"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        session.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }

    // MARK: - CLI fallback path

    private func transcribeViaCLI(audioURL: URL, mode: DictationMode, language: SpokenLanguage) -> String? {
        let text = runCLI(audioURL: audioURL, mode: mode, language: language)
        if language == .auto, mode == .transcribe, let text, Self.looksLikeHindiMisdetection(text), !cancelled {
            return runCLI(audioURL: audioURL, mode: mode, language: .bengali) ?? text
        }
        return text
    }

    static func cliArguments(audioURL: URL, mode: DictationMode, language: SpokenLanguage) -> [String] {
        var arguments = [
            "-m", ModelManager.modelPath(for: mode).path,
            "-f", audioURL.path,
            "-l", language.rawValue,
            "-nt",          // no timestamps
            "-np",          // no progress/debug prints
            "-t", "4",      // 4 threads — fast on M1 without starving other work
        ]
        if mode == .translate {
            arguments.append("--translate")
        }
        return arguments
    }

    private func runCLI(audioURL: URL, mode: DictationMode, language: SpokenLanguage) -> String? {
        guard let cli = Self.findWhisperCLI() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = Self.cliArguments(audioURL: audioURL, mode: mode, language: language)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // discard

        currentProcess = process
        do {
            try process.run()
        } catch {
            currentProcess = nil
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        currentProcess = nil

        guard !cancelled, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
