import Foundation

/// Manages keep-warm whisper-server processes, one per dictation mode.
///
/// Speed strategy:
/// - The server is spawned the moment the user starts holding the hotkey, so the
///   model loads into Metal *while they are speaking* — by release it's usually warm.
/// - The server stays resident between dictations (warm requests are 5–10x faster
///   than cold whisper-cli spawns: ~1.5–3.5s vs ~17s on an M1).
/// - An idle timer shuts the server down after a configurable period, returning
///   ~600 MB of RAM to the system. Important on 8 GB machines.
final class WhisperServerManager {
    static let shared = WhisperServerManager()

    private struct Server {
        let process: Process
        let port: Int
        var ready: Bool
    }

    private var servers: [DictationMode: Server] = [:]
    private var idleTimer: Timer?
    private let queue = DispatchQueue(label: "holdtalk.servermanager")

    private static let ports: [DictationMode: Int] = [.transcribe: 18178, .translate: 18179]

    /// Encoder audio-context: 768 ≈ 15s window. Roughly halves encode time for short
    /// dictations with no measurable accuracy loss; longer audio is processed in chunks.
    private static let audioContext = "768"

    static func findWhisperServer() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private init() {
        // Reap any servers orphaned by a previous crash.
        Self.killStaleServers()
    }

    // MARK: - Lifecycle

    /// Starts (or keeps alive) the server for a mode. Called at hold-start so the
    /// model loads while the user is speaking. Safe to call repeatedly.
    func preload(mode: DictationMode) {
        queue.async { [self] in
            restartIdleTimerLocked()
            guard servers[mode] == nil || servers[mode]?.process.isRunning == false else { return }
            guard let binary = Self.findWhisperServer(),
                  ModelManager.modelInstalled(for: mode),
                  let port = Self.ports[mode] else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = Self.serverArguments(mode: mode, port: port, language: Settings.spokenLanguage)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                servers[mode] = Server(process: process, port: port, ready: false)
            } catch {
                // Fall back to CLI transcription; nothing to clean up.
            }
        }
    }

    /// Returns the base URL for a mode once the server answers HTTP, waiting up to
    /// `timeout` seconds. Returns nil if the server isn't running or never comes up
    /// (caller falls back to whisper-cli).
    func waitForServer(mode: DictationMode, timeout: TimeInterval = 20) -> URL? {
        var port: Int?
        queue.sync {
            if let server = servers[mode], server.process.isRunning {
                port = server.port
            }
        }
        guard let port else { return nil }
        let url = URL(string: "http://127.0.0.1:\(port)")!

        var alreadyReady = false
        queue.sync { alreadyReady = servers[mode]?.ready ?? false }
        if alreadyReady { return url }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ping(url) {
                queue.sync { servers[mode]?.ready = true }
                return url
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }

    /// Resets the idle countdown — call after each completed dictation.
    func touch() {
        queue.async { self.restartIdleTimerLocked() }
    }

    func shutdownAll() {
        queue.sync {
            for (_, server) in servers where server.process.isRunning {
                server.process.terminate()
            }
            servers.removeAll()
        }
    }

    // MARK: - Private

    static func serverArguments(mode: DictationMode, port: Int, language: SpokenLanguage) -> [String] {
        var arguments = [
            "-m", ModelManager.modelPath(for: mode).path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-l", language.rawValue,
            "-t", "4",
            "-ac", Self.audioContext,
        ]
        if mode == .translate {
            arguments.append("-tr")
        }
        return arguments
    }

    private func restartIdleTimerLocked() {
        let interval = Settings.keepWarmDuration
        DispatchQueue.main.async { [self] in
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.shutdownAll()
            }
        }
    }

    private func ping(_ baseURL: URL) -> Bool {
        var request = URLRequest(url: baseURL, timeoutInterval: 0.5)
        request.httpMethod = "GET"
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse) != nil
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return reachable
    }

    /// Kills whisper-server processes left over from a crashed HoldTalk on our ports.
    private static func killStaleServers() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "whisper-server.*--port 1817[89]"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
