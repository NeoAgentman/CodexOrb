import Foundation

public struct CodexResetForecast: Equatable, Sendable {
    public let probability24h: Int?
    public let probability48h: Int?
    /// Keep the API-provided value opaque so newly introduced server values
    /// can be displayed without an app update.
    public let confidence: String?
    public let updatedAt: Date

    public init(
        probability24h: Int?,
        probability48h: Int?,
        confidence: String?,
        updatedAt: Date)
    {
        self.probability24h = probability24h
        self.probability48h = probability48h
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}

public protocol CodexResetForecastSourcing: Sendable {
    func fetch(timeZone: String) async throws -> CodexResetForecast
}

public enum CodexResetForecastError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case invalidTimeZone(String)
    case invalidResponse
    case httpStatus(Int)
    case invalidContentType
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Codex reset forecast endpoint is invalid."
        case let .invalidTimeZone(identifier):
            return "Invalid time zone: \(identifier)"
        case .invalidResponse:
            return "Codex reset forecast returned an invalid response."
        case let .httpStatus(status):
            return "Codex reset forecast returned HTTP \(status)."
        case .invalidContentType:
            return "Codex reset forecast returned a non-JSON response."
        case let .invalidPayload(message):
            return "Codex reset forecast payload is invalid: \(message)"
        }
    }
}

public struct CodexResetForecastSource: CodexResetForecastSourcing, Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let defaultEndpoint = URL(string: "https://codex-reset.com/api/forecast")!

    private let endpoint: URL
    private let timeout: TimeInterval
    private let loader: Loader

    public init(
        endpoint: URL = CodexResetForecastSource.defaultEndpoint,
        timeout: TimeInterval = 10,
        loader: Loader? = nil)
    {
        self.endpoint = endpoint
        self.timeout = max(1, timeout)
        self.loader = loader ?? Self.loadFromNetwork
    }

    public func fetch(timeZone: String) async throws -> CodexResetForecast {
        guard let scheme = self.endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme),
              self.endpoint.host?.isEmpty == false else { throw CodexResetForecastError.invalidEndpoint }
        guard TimeZone(identifier: timeZone) != nil else {
            throw CodexResetForecastError.invalidTimeZone(timeZone)
        }
        let components = URLComponents(url: self.endpoint, resolvingAgainstBaseURL: false)
        guard var components else { throw CodexResetForecastError.invalidEndpoint }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("tz") == .orderedSame }
        queryItems.append(URLQueryItem(name: "tz", value: timeZone))
        components.queryItems = queryItems
        guard let url = components.url else { throw CodexResetForecastError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await self.loader(request)
        guard let response = response as? HTTPURLResponse else {
            throw CodexResetForecastError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw CodexResetForecastError.httpStatus(response.statusCode)
        }
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           !contentType.lowercased().hasPrefix("application/json") {
            throw CodexResetForecastError.invalidContentType
        }
        return try Self.parse(data: data)
    }

    public static func parse(data: Data) throws -> CodexResetForecast {
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard let updatedAt = Self.parseDate(payload.updatedAt) else {
                throw CodexResetForecastError.invalidPayload("updated_at is not an ISO-8601 date")
            }
            return CodexResetForecast(
                probability24h: try Self.percent(rounded: payload.probabilities.rounded24h,
                                                 raw: payload.probabilities.raw24h,
                                                 field: "24h"),
                probability48h: try Self.percent(rounded: payload.probabilities.rounded48h,
                                                 raw: payload.probabilities.raw48h,
                                                 field: "48h"),
                confidence: payload.confidence,
                updatedAt: updatedAt)
        } catch let error as CodexResetForecastError {
            throw error
        } catch {
            throw CodexResetForecastError.invalidPayload(error.localizedDescription)
        }
    }

    private static func loadFromNetwork(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }

    private struct Payload: Decodable {
        let updatedAt: String
        let probabilities: Probabilities
        let confidence: String?

        private enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case probabilities, confidence
        }
    }

    private struct Probabilities: Decodable {
        let raw24h: Double?
        let raw48h: Double?
        let rounded24h: Double?
        let rounded48h: Double?

        private enum CodingKeys: String, CodingKey {
            case raw24h = "raw_24h"
            case raw48h = "raw_48h"
            case rounded24h = "rounded_24h"
            case rounded48h = "rounded_48h"
        }
    }

    private static func percent(rounded: Double?, raw: Double?, field: String) throws -> Int? {
        if let rounded {
            guard rounded.isFinite, (0...100).contains(rounded) else {
                throw CodexResetForecastError.invalidPayload("rounded_\(field) is outside 0...100")
            }
            return Int(rounded.rounded())
        }
        guard let raw else { return nil }
        guard raw.isFinite, (0...1).contains(raw) else {
            throw CodexResetForecastError.invalidPayload("raw_\(field) is outside 0...1")
        }
        return Int((raw * 100).rounded())
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
