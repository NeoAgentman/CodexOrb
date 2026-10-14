import Foundation

/// Public status-page data, independent of the selected account and its quota.
public struct OpenAIServiceStatus: Decodable, Equatable, Sendable {
    public struct Summary: Decodable, Equatable, Sendable {
        public let indicator: String
        public let description: String
    }
    public struct Component: Decodable, Equatable, Sendable {
        public let name: String
        public let status: String
    }
    public struct Incident: Decodable, Equatable, Sendable {
        public struct Update: Decodable, Equatable, Sendable {
            public let body: String
            public let created_at: String
        }
        public let id: String
        public let name: String
        public let status: String
        public let impact: String
        public let updated_at: String
        public let incident_updates: [Update]

        public var latestUpdate: Update? {
            incident_updates.max { $0.created_at < $1.created_at }
        }
        public var url: URL {
            OpenAIServiceStatusSource.website.appendingPathComponent("incidents").appendingPathComponent(id)
        }
    }
    public let status: Summary
    public let components: [Component]
    public let incidents: [Incident]

    private enum CodingKeys: String, CodingKey { case status, components, incidents }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Summary.self, forKey: .status)
        components = try container.decode([Component].self, forKey: .components)
        // The live summary omits incidents when all incidents are resolved.
        // Missing/null means no incidents; malformed values must still fail.
        incidents = try container.decodeIfPresent([Incident].self, forKey: .incidents) ?? []
    }

    public var activeIncidents: [Incident] {
        incidents.filter { !["resolved", "postmortem", "scheduled"].contains($0.status) }
    }
    public var affectedComponents: [Component] { components.filter { $0.status != "operational" } }
    public var hasIssues: Bool {
        status.indicator != "none" || !activeIncidents.isEmpty || !affectedComponents.isEmpty
    }
    public var isSevere: Bool {
        ["major", "critical"].contains(status.indicator)
            || activeIncidents.contains { ["major", "critical"].contains($0.impact) }
            || affectedComponents.contains { $0.status == "major_outage" }
    }
}

public struct OpenAIServiceStatusState: Equatable, Sendable {
    public private(set) var snapshot: OpenAIServiceStatus?
    public private(set) var checkedAt: Date?
    public private(set) var refreshFailed = false

    public init() {}
    public mutating func received(_ snapshot: OpenAIServiceStatus, at date: Date = Date()) {
        self.snapshot = snapshot
        checkedAt = date
        refreshFailed = false
    }
    public mutating func failed() { refreshFailed = true }
    public func isStale(at date: Date = Date()) -> Bool {
        refreshFailed || checkedAt.map { date.timeIntervalSince($0) > 150 } ?? true
    }
}

public struct OpenAIServiceStatusSource: Sendable {
    public static let website = URL(string: "https://status.openai.com/")!
    public static let endpoint = website.appendingPathComponent("api/v2/summary.json")
    public init() {}

    public func fetch() async throws -> OpenAIServiceStatus {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // Invalid JSON or missing required status/component fields cannot confirm recovery.
        return try JSONDecoder().decode(OpenAIServiceStatus.self, from: data)
    }
}
