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

        print("ForecastChecks passed: parsing, raw fallback, confidence fallback, timezone request and HTTP failure")
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
