import XCTest
@testable import HoldTalk

final class LanguageHandlingTests: XCTestCase {
    private let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("holdtalk-language-tests-\(UUID().uuidString).wav")
    private var session: URLSession!

    override func setUpWithError() throws {
        // Transport tests use inert bytes, not a model or microphone recording.
        try Data("test audio".utf8).write(to: audioURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WhisperProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        WhisperProtocol.handler = nil
        try FileManager.default.removeItem(at: audioURL)
    }

    func testStoredLanguagesAndInvalidValueFallback() {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for (value, expected) in [("bn", SpokenLanguage.bengali), ("en", .english),
                                  ("auto", .auto), ("", .bengali), ("unknown", .bengali)] {
            var domain = original
            domain["spokenLanguage"] = value
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            XCTAssertEqual(Settings.spokenLanguage, expected)
        }
    }

    func testRequestsKeepSourceLanguageSeparateFromTranslationTask() {
        // In particular, Bengali translation must send bn, never en or auto.
        for language in [SpokenLanguage.bengali, .english, .auto] {
            for mode in [DictationMode.transcribe, .translate] {
                var requests = [URLRequest]()
                WhisperProtocol.handler = { request in
                    requests.append(request)
                    return (200, mode == .translate ? "Mom didn't go today." : "আম্মু যায় নাই আজকে")
                }
                let result = Transcriber(session: session).transcribeViaServer(
                    baseURL: URL(string: "http://localhost:18178")!, audioURL: audioURL,
                    mode: mode, language: language
                )
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(result, mode == .translate ? "Mom didn't go today." : "আম্মু যায় নাই আজকে")
                XCTAssertEqual(requests.first?.url?.path, "/inference")
                XCTAssertEqual(requests.first?.httpMethod, "POST")
                assertField("language", language.rawValue, in: requests.first)
                assertField("translate", mode == .translate ? "true" : "false", in: requests.first)
            }
        }
    }

    func testWarmServerRequestsOverridePreviousLanguageAndTask() {
        var requests = [URLRequest]()
        WhisperProtocol.handler = { request in
            requests.append(request)
            return (200, "test result")
        }
        let transcriber = Transcriber(session: session)
        let baseURL = URL(string: "http://localhost:18179")!
        _ = transcriber.transcribeViaServer(baseURL: baseURL, audioURL: audioURL,
                                            mode: .translate, language: .bengali)
        _ = transcriber.transcribeViaServer(baseURL: baseURL, audioURL: audioURL,
                                            mode: .transcribe, language: .english)
        XCTAssertEqual(requests.count, 2)
        assertField("language", "bn", in: requests.first)
        assertField("translate", "true", in: requests.first)
        assertField("language", "en", in: requests.last)
        assertField("translate", "false", in: requests.last)
    }

    func testAutoTranscriptionRetriesHindiWithBengali() {
        var requests = [URLRequest]()
        WhisperProtocol.handler = { request in
            requests.append(request)
            return (200, requests.count == 1 ? "आज घर जाना है" : "আম্মু যায় নাই আজকে")
        }
        let result = Transcriber(session: session).transcribeViaServer(
            baseURL: URL(string: "http://localhost:18178")!, audioURL: audioURL,
            mode: .transcribe, language: .auto
        )
        XCTAssertEqual(result, "আম্মু যায় নাই আজকে")
        XCTAssertEqual(requests.count, 2)
        assertField("language", "auto", in: requests.first)
        assertField("language", "bn", in: requests.last)
        assertField("translate", "false", in: requests.last)
    }

    func testExplicitLanguagesAndTranslationDoNotRetryBasedOnOutputScript() {
        for (language, mode) in [(SpokenLanguage.bengali, DictationMode.transcribe),
                                  (.english, .transcribe), (.auto, .translate)] {
            var count = 0
            WhisperProtocol.handler = { _ in
                count += 1
                return (200, "आज घर जाना है")
            }
            _ = Transcriber(session: session).transcribeViaServer(
                baseURL: URL(string: "http://localhost:18178")!, audioURL: audioURL,
                mode: mode, language: language
            )
            XCTAssertEqual(count, 1)
        }
    }

    func testFailedBengaliRetryKeepsOriginalAutoResult() {
        var count = 0
        WhisperProtocol.handler = { _ in
            count += 1
            return count == 1 ? (200, "आज घर जाना है") : (500, "error")
        }
        let result = Transcriber(session: session).transcribeViaServer(
            baseURL: URL(string: "http://localhost:18178")!, audioURL: audioURL,
            mode: .transcribe, language: .auto
        )
        XCTAssertEqual(result, "आज घर जाना है")
        XCTAssertEqual(count, 2)
    }

    func testServerFailureReturnsNilForCLIFallback() {
        WhisperProtocol.handler = { _ in (500, "error") }
        let result = Transcriber(session: session).transcribeViaServer(
            baseURL: URL(string: "http://localhost:18178")!, audioURL: audioURL,
            mode: .translate, language: .bengali
        )
        XCTAssertNil(result)
    }

    func testCLIAndServerArgumentsUseSelectedLanguageAndModeModel() {
        for language in [SpokenLanguage.bengali, .english, .auto] {
            for mode in [DictationMode.transcribe, .translate] {
                let cli = Transcriber.cliArguments(audioURL: audioURL, mode: mode, language: language)
                let server = WhisperServerManager.serverArguments(mode: mode, port: 18179, language: language)
                for arguments in [cli, server] {
                    XCTAssertEqual(value(after: "-l", in: arguments), language.rawValue)
                    XCTAssertEqual(value(after: "-m", in: arguments), ModelManager.modelPath(for: mode).path)
                }
                XCTAssertEqual(cli.contains("--translate"), mode == .translate)
                XCTAssertEqual(server.contains("-tr"), mode == .translate)
                XCTAssertEqual(value(after: "-f", in: cli), audioURL.path)
                XCTAssertEqual(value(after: "--host", in: server), "127.0.0.1")
            }
        }
    }

    func testHindiHeuristicDoesNotTreatEnglishOrBengaliAsHindi() {
        XCTAssertTrue(Transcriber.looksLikeHindiMisdetection("आज घर जाना है"))
        for text in ["", "123?!", "আম্মু যায় নাই আজকে", "Now we will go to her.", "Node.js API"] {
            XCTAssertFalse(Transcriber.looksLikeHindiMisdetection(text))
        }
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func assertField(_ name: String, _ value: String, in request: URLRequest?,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let body = request?.httpBody else {
            return XCTFail("Missing multipart body", file: file, line: line)
        }
        XCTAssertTrue(String(decoding: body, as: UTF8.self)
            .contains("name=\"\(name)\"\r\n\r\n\(value)\r\n"), file: file, line: line)
    }
}

private final class WhisperProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // URLSession may expose multipart data as a stream. Snapshot it once so
        // several assertions can inspect the same captured request on any SDK.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        let (status, text) = handler(captured)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
