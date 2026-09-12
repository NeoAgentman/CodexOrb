import CodexOrbCore
import Foundation

enum ForecastChecks {
    static func run() async throws {
        let json = """
        {
          "mode":"model",
          "updated_at":"2026-09-09T05:49:34.067Z",
          "probabilities":{
            "raw_24h":0.27141786457246714,
            "raw_48h":0.4691680719358562,
            "rounded_24h":25,
            "rounded_48h":45
          },
          "confidence":"low"
        }
        """
        let forecast = try CodexResetForecastSource.parse(data: Data(json.utf8))
        try self.expect(forecast.probability24h == 25, "rounded 24-hour forecast")
        try self.expect(forecast.probability48h == 45, "rounded 48-hour forecast")
        try self.expect(forecast.confidence == "low", "forecast confidence")
        try self.expect(forecast.commitmentPercent == nil, "missing commitment stays hidden")
        try self.expect(forecast.officialSignalURL == nil, "missing signal URL")

        // The commitment and horizon probabilities describe different signals.
        let announced = """
        {"updated_at":"2026-09-12T03:54:09.076Z","probabilities":{"rounded_24h":45,"rounded_48h":70,"commitment":0.83,"signal_percent":83},"confidence":"low","official_signal":{"url":"https://x.com/thsottiaux/status/2098612714704891959"}}
        """
        let commitment = try CodexResetForecastSource.parse(data: Data(announced.utf8))
        try self.expect(commitment.commitmentPercent == 83, "Tibo commitment percent")
        let signalURL = "https://x.com/thsottiaux/status/2098612714704891959"
        try self.expect(commitment.officialSignalURL?.absoluteString == signalURL, "official signal URL")
        for invalidURL in ["", "/relative", "file:///tmp/post", "javascript:alert(1)",
                           "https://x.com.example.org/post", "https://user@x.com/post"] {
            let response = announced.replacingOccurrences(of: signalURL, with: invalidURL)
            let parsed = try CodexResetForecastSource.parse(data: Data(response.utf8))
            try self.expect(parsed.officialSignalURL == nil && parsed.commitmentPercent == 83,
                            "invalid link must not hide forecast data")
        }
        let nullSignal = announced.replacingOccurrences(of: "{\"url\":\"\(signalURL)\"}", with: "null")
        let withoutSignal = try CodexResetForecastSource.parse(data: Data(nullSignal.utf8))
        try self.expect(withoutSignal.officialSignalURL == nil, "null official signal")
        try self.expect(commitment.probability24h == 45 && commitment.probability48h == 70,
                        "commitment must not replace horizon probabilities")
        for value in ["null", "0"] {
            let inactive = announced.replacingOccurrences(of: "\"commitment\":0.83", with: "\"commitment\":\(value)")
            let parsed = try CodexResetForecastSource.parse(data: Data(inactive.utf8))
            try self.expect(parsed.commitmentPercent == nil, "inactive commitment stays hidden despite signal score")
        }
        for value in ["-0.1", "1.1"] {
            let invalid = announced.replacingOccurrences(of: "\"commitment\":0.83", with: "\"commitment\":\(value)")
            do {
                _ = try CodexResetForecastSource.parse(data: Data(invalid.utf8))
                throw ForecastCheckFailure(message: "Invalid commitment was accepted: \(value)")
            } catch CodexResetForecastError.invalidPayload { }
        }

        let rawOnly = """
        {"updated_at":"2026-09-09T05:49:34Z","probabilities":{"raw_24h":0.274,"raw_48h":0.496},"confidence":"future-value"}
        """
        let fallback = try CodexResetForecastSource.parse(data: Data(rawOnly.utf8))
        try self.expect(fallback.probability24h == 27 && fallback.probability48h == 50,
                        "raw probability fallback")
        try self.expect(fallback.confidence == "future-value", "opaque confidence value")

        let recorder = RequestRecorder()
        let responseData = Data(json.utf8)
        let source = CodexResetForecastSource(
            endpoint: URL(string: "https://example.test/api/forecast?source=fixture&tz=UTC")!,
            loader: { request in
                await recorder.save(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json; charset=utf-8"] )!
                return (responseData, response)
            })
        let fetched = try await source.fetch(timeZone: "Asia/Shanghai")
        let request = await recorder.request
        let query = request.flatMap { $0.url }.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        try self.expect(query.first(where: { $0.name == "source" })?.value == "fixture",
                        "preserve forecast query")
        try self.expect(query.first(where: { $0.name == "tz" })?.value == "Asia/Shanghai",
                        "encode local forecast time zone")
        try self.expect(fetched == forecast, "injected forecast response")

        let unavailable = CodexResetForecastSource(
            endpoint: URL(string: "https://example.test/api/forecast")!,
            loader: { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            })
        do {
            _ = try await unavailable.fetch(timeZone: "UTC")
            throw ForecastCheckFailure(message: "forecast HTTP failure was not surfaced")
        } catch CodexResetForecastError.httpStatus(503) { }

        print("ForecastChecks passed: parsing, commitment visibility and validation, raw fallback, confidence fallback, timezone request and HTTP failure")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw ForecastCheckFailure(message: "Failed check: \(label)") }
    }
}

private actor RequestRecorder {
    private(set) var request: URLRequest?

    func save(_ request: URLRequest) {
        self.request = request
    }
}

private struct ForecastCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { self.message }
}
