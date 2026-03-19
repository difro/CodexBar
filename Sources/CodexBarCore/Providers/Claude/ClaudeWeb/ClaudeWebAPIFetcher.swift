import Foundation
import SweetCookieKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches Claude usage data directly from the claude.ai API using browser session cookies.
///
/// This approach mirrors what Claude Usage Tracker does, but automatically extracts the session key
/// from browser cookies instead of requiring manual setup.
///
/// API endpoints used:
/// - `GET https://claude.ai/api/organizations` → get org UUID
/// - `GET https://claude.ai/api/organizations/{org_id}/usage` → usage percentages + reset times
public enum ClaudeWebAPIFetcher {
    private static let baseURL = "https://claude.ai/api"
    private static let maxProbeBytes = 200_000
    #if os(macOS)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.claude]?.browserCookieOrder ?? Browser.defaultImportOrder
    #else
    private static let cookieImportOrder: BrowserCookieImportOrder = []
    #endif

    public struct OrganizationInfo: Sendable {
        public let id: String
        public let name: String?
        public let capabilities: [String]

        public init(id: String, name: String?, capabilities: [String] = []) {
            self.id = id
            self.name = name
            self.capabilities = capabilities
        }

        fileprivate var normalizedCapabilities: Set<String> {
            Set(self.capabilities.map { $0.lowercased() })
        }

        fileprivate var hasChatCapability: Bool {
            self.normalizedCapabilities.contains("chat")
        }

        fileprivate var isApiOnly: Bool {
            let normalized = self.normalizedCapabilities
            return !normalized.isEmpty && normalized == ["api"]
        }
    }

    public struct SessionKeyInfo: Sendable {
        public let key: String
        public let sourceLabel: String
        public let cookieCount: Int

        public init(key: String, sourceLabel: String, cookieCount: Int) {
            self.key = key
            self.sourceLabel = sourceLabel
            self.cookieCount = cookieCount
        }
    }

    public enum FetchError: LocalizedError, Sendable {
        case noSessionKeyFound
        case invalidSessionKey
        case notSupportedOnThisPlatform
        case networkError(Error)
        case invalidResponse
        case unauthorized
        case serverError(statusCode: Int)
        case noOrganization

        public var errorDescription: String? {
            switch self {
            case .noSessionKeyFound:
                "No Claude session key found in browser cookies."
            case .invalidSessionKey:
                "Invalid Claude session key format."
            case .notSupportedOnThisPlatform:
                "Claude web fetching is only supported on macOS."
            case let .networkError(error):
                "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                "Invalid response from Claude API."
            case .unauthorized:
                "Unauthorized. Your Claude session may have expired."
            case let .serverError(code):
                "Claude API error: HTTP \(code)"
            case .noOrganization:
                "No Claude organization found for this account."
            }
        }
    }

    /// Claude usage data from the API
    public struct WebUsageData: Sendable {
        public let sessionPercentUsed: Double?
        public let sessionResetsAt: Date?
        public let weeklyPercentUsed: Double?
        public let weeklyResetsAt: Date?
        public let opusPercentUsed: Double?
        public let extraUsageCost: ProviderCostSnapshot?
        public let accountOrganization: String?
        public let accountEmail: String?
        public let loginMethod: String?

        public init(
            sessionPercentUsed: Double?,
            sessionResetsAt: Date?,
            weeklyPercentUsed: Double?,
            weeklyResetsAt: Date?,
            opusPercentUsed: Double?,
            extraUsageCost: ProviderCostSnapshot?,
            accountOrganization: String?,
            accountEmail: String?,
            loginMethod: String?)
        {
            self.sessionPercentUsed = sessionPercentUsed
            self.sessionResetsAt = sessionResetsAt
            self.weeklyPercentUsed = weeklyPercentUsed
            self.weeklyResetsAt = weeklyResetsAt
            self.opusPercentUsed = opusPercentUsed
            self.extraUsageCost = extraUsageCost
            self.accountOrganization = accountOrganization
            self.accountEmail = accountEmail
            self.loginMethod = loginMethod
        }
    }

    public struct ProbeResult: Sendable {
        public let url: String
        public let statusCode: Int?
        public let contentType: String?
        public let topLevelKeys: [String]
        public let emails: [String]
        public let planHints: [String]
        public let notableFields: [String]
        public let bodyPreview: String?
    }

    private actor OrganizationCache {
        private var organizations: [OrganizationInfo] = []

        func store(_ organizations: [OrganizationInfo]) {
            var seen: Set<String> = []
            self.organizations = organizations.filter { seen.insert($0.id).inserted }
        }

        func snapshot() -> [OrganizationInfo] {
            self.organizations
        }
    }

    private static let organizationCache = OrganizationCache()

    public static func cachedOrganizations() async -> [OrganizationInfo] {
        await self.organizationCache.snapshot()
    }

    // MARK: - Public API

    #if os(macOS)

    /// Attempts to fetch Claude usage data using cookies extracted from browsers.
    /// Tries browser cookies using the standard import order.
    public static func fetchUsage(
        browserDetection: BrowserDetection,
        preferredOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let log: (String) -> Void = { msg in logger?("[claude-web] \(msg)") }

        if let cached = CookieHeaderCache.load(provider: .claude),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            log("Using cached cookie header from \(cached.sourceLabel)")
            do {
                return try await self.fetchUsage(
                    cookieHeader: cached.cookieHeader,
                    preferredOrganizationID: preferredOrganizationID,
                    logger: log)
            } catch let error as FetchError {
                switch error {
                case .unauthorized, .noSessionKeyFound, .invalidSessionKey:
                    CookieHeaderCache.clear(provider: .claude)
                default:
                    throw error
                }
            } catch {
                throw error
            }
        }

        let sessionInfo = try extractSessionKeyInfo(browserDetection: browserDetection, logger: log)
        log("Found session key (\(sessionInfo.cookieCount) cookies)")

        let usage = try await self.fetchUsage(
            using: sessionInfo,
            preferredOrganizationID: preferredOrganizationID,
            logger: log)
        CookieHeaderCache.store(
            provider: .claude,
            cookieHeader: "sessionKey=\(sessionInfo.key)",
            sourceLabel: sessionInfo.sourceLabel)
        return usage
    }

    public static func fetchUsage(
        cookieHeader: String,
        preferredOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let log: (String) -> Void = { msg in logger?("[claude-web] \(msg)") }
        let sessionInfo = try self.sessionKeyInfo(cookieHeader: cookieHeader)
        log("Using manual session key (\(sessionInfo.cookieCount) cookies)")
        return try await self.fetchUsage(
            using: sessionInfo,
            preferredOrganizationID: preferredOrganizationID,
            logger: log)
    }

    public static func fetchUsage(
        using sessionKeyInfo: SessionKeyInfo,
        preferredOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let log: (String) -> Void = { msg in logger?(msg) }
        let sessionKey = sessionKeyInfo.key

        // Fetch organization info
        let organizations = try await fetchOrganizations(sessionKey: sessionKey, logger: log)
        await self.organizationCache.store(organizations)
        let organization = try self.selectOrganization(
            organizations,
            preferredOrganizationID: preferredOrganizationID,
            logger: log)
        log("Organization resolved: \(organization.id)")

        var usage = try await fetchUsageData(orgId: organization.id, sessionKey: sessionKey, logger: log)
        if usage.extraUsageCost == nil,
           let extra = await fetchExtraUsageCost(orgId: organization.id, sessionKey: sessionKey, logger: log)
        {
            usage = WebUsageData(
                sessionPercentUsed: usage.sessionPercentUsed,
                sessionResetsAt: usage.sessionResetsAt,
                weeklyPercentUsed: usage.weeklyPercentUsed,
                weeklyResetsAt: usage.weeklyResetsAt,
                opusPercentUsed: usage.opusPercentUsed,
                extraUsageCost: extra,
                accountOrganization: usage.accountOrganization,
                accountEmail: usage.accountEmail,
                loginMethod: usage.loginMethod)
        }
        if let account = await fetchAccountInfo(sessionKey: sessionKey, orgId: organization.id, logger: log) {
            usage = WebUsageData(
                sessionPercentUsed: usage.sessionPercentUsed,
                sessionResetsAt: usage.sessionResetsAt,
                weeklyPercentUsed: usage.weeklyPercentUsed,
                weeklyResetsAt: usage.weeklyResetsAt,
                opusPercentUsed: usage.opusPercentUsed,
                extraUsageCost: usage.extraUsageCost,
                accountOrganization: usage.accountOrganization,
                accountEmail: account.email,
                loginMethod: account.loginMethod)
        }
        if usage.accountOrganization == nil, let name = organization.name {
            usage = WebUsageData(
                sessionPercentUsed: usage.sessionPercentUsed,
                sessionResetsAt: usage.sessionResetsAt,
                weeklyPercentUsed: usage.weeklyPercentUsed,
                weeklyResetsAt: usage.weeklyResetsAt,
                opusPercentUsed: usage.opusPercentUsed,
                extraUsageCost: usage.extraUsageCost,
                accountOrganization: name,
                accountEmail: usage.accountEmail,
                loginMethod: usage.loginMethod)
        }
        return usage
    }

    /// Probes a list of endpoints using the current claude.ai session cookies.
    /// - Parameters:
    ///   - endpoints: Absolute URLs or "/api/..." paths. Supports "{orgId}" placeholder.
    ///   - includePreview: When true, includes a truncated response preview in results.
    public static func probeEndpoints(
        _ endpoints: [String],
        browserDetection: BrowserDetection,
        includePreview: Bool = false,
        logger: ((String) -> Void)? = nil) async throws -> [ProbeResult]
    {
        let log: (String) -> Void = { msg in logger?("[claude-probe] \(msg)") }
        let sessionInfo = try extractSessionKeyInfo(browserDetection: browserDetection, logger: log)
        let sessionKey = sessionInfo.key
        let organizations = try? await fetchOrganizations(sessionKey: sessionKey, logger: log)
        if let organizations {
            await self.organizationCache.store(organizations)
        }
        let organization = try? organizations.flatMap { orgs in
            try self.selectOrganization(orgs, preferredOrganizationID: nil, logger: log)
        }
        let expanded = endpoints.map { endpoint -> String in
            var url = endpoint
            if let orgId = organization?.id {
                url = url.replacingOccurrences(of: "{orgId}", with: orgId)
            }
            if url.hasPrefix("/") {
                url = "https://claude.ai\(url)"
            }
            return url
        }

        var results: [ProbeResult] = []
        results.reserveCapacity(expanded.count)

        for endpoint in expanded {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json, text/html;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
            request.httpMethod = "GET"
            request.timeoutInterval = 20

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let contentType = http?.allHeaderFields["Content-Type"] as? String
                let truncated = data.prefix(Self.maxProbeBytes)
                let body = String(data: truncated, encoding: .utf8) ?? ""

                let parsed = Self.parseProbeBody(data: data, fallbackText: body, contentType: contentType)
                let preview = includePreview ? parsed.preview : nil

                results.append(ProbeResult(
                    url: endpoint,
                    statusCode: http?.statusCode,
                    contentType: contentType,
                    topLevelKeys: parsed.keys,
                    emails: parsed.emails,
                    planHints: parsed.planHints,
                    notableFields: parsed.notableFields,
                    bodyPreview: preview))
            } catch {
                results.append(ProbeResult(
                    url: endpoint,
                    statusCode: nil,
                    contentType: nil,
                    topLevelKeys: [],
                    emails: [],
                    planHints: [],
                    notableFields: [],
                    bodyPreview: "Error: \(error.localizedDescription)"))
            }
        }

        return results
    }

    /// Checks if we can find a Claude session key in browser cookies without making API calls.
    public static func hasSessionKey(browserDetection: BrowserDetection, logger: ((String) -> Void)? = nil) -> Bool {
        if let cached = CookieHeaderCache.load(provider: .claude),
           self.hasSessionKey(cookieHeader: cached.cookieHeader)
        {
            return true
        }
        do {
            _ = try self.sessionKeyInfo(browserDetection: browserDetection, logger: logger)
            return true
        } catch {
            return false
        }
    }

    public static func hasSessionKey(cookieHeader: String?) -> Bool {
        guard let cookieHeader else { return false }
        return (try? self.sessionKeyInfo(cookieHeader: cookieHeader)) != nil
    }

    public static func sessionKeyInfo(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionKeyInfo
    {
        try self.extractSessionKeyInfo(browserDetection: browserDetection, logger: logger)
    }

    public static func sessionKeyInfo(cookieHeader: String) throws -> SessionKeyInfo {
        let pairs = CookieHeaderNormalizer.pairs(from: cookieHeader)
        if let sessionKey = self.findSessionKey(in: pairs) {
            return SessionKeyInfo(
                key: sessionKey,
                sourceLabel: "Manual",
                cookieCount: pairs.count)
        }
        throw FetchError.noSessionKeyFound
    }

    // MARK: - Session Key Extraction

    private static func extractSessionKeyInfo(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionKeyInfo
    {
        let log: (String) -> Void = { msg in logger?(msg) }

        let cookieDomains = ["claude.ai"]

        // Filter to cookie-eligible browsers to avoid unnecessary keychain prompts
        let installedBrowsers = Self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in installedBrowsers {
            do {
                let query = BrowserCookieQuery(domains: cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources {
                    if let sessionKey = findSessionKey(in: source.records.map { record in
                        (name: record.name, value: record.value)
                    }) {
                        log("Found sessionKey in \(source.label)")
                        return SessionKeyInfo(
                            key: sessionKey,
                            sourceLabel: source.label,
                            cookieCount: source.records.count)
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie load failed: \(error.localizedDescription)")
            }
        }

        throw FetchError.noSessionKeyFound
    }

    private static func findSessionKey(in cookies: [(name: String, value: String)]) -> String? {
        for cookie in cookies where cookie.name == "sessionKey" {
            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Validate it looks like a Claude session key
            if value.hasPrefix("sk-ant-") {
                return value
            }
        }
        return nil
    }

    // MARK: - API Calls

    private static func fetchOrganizations(
        sessionKey: String,
        logger: ((String) -> Void)? = nil) async throws -> [OrganizationInfo]
    {
        let url = URL(string: "\(baseURL)/organizations")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        logger?("Organizations API status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            return try self.parseOrganizationsResponse(data)
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    private static func fetchUsageData(
        orgId: String,
        sessionKey: String,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        let url = URL(string: "\(baseURL)/organizations/\(orgId)/usage")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        logger?("Usage API status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            do {
                return try self.parseUsageResponse(data)
            } catch {
                logger?("Usage parse failed: \(self.debugUsageResponseSummary(data))")
                throw error
            }
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    private static func parseUsageResponse(_ data: Data) throws -> WebUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.invalidResponse
        }

        let sessionWindow = json["five_hour"] as? [String: Any]
        let sessionPercent = sessionWindow.flatMap { self.numericValue($0["utilization"]) }
        let sessionResets = (sessionWindow?["resets_at"] as? String).flatMap(self.parseISO8601Date)

        let weeklyWindow = json["seven_day"] as? [String: Any]
        let weeklyPercent = weeklyWindow.flatMap { self.numericValue($0["utilization"]) }
        let weeklyResets = (weeklyWindow?["resets_at"] as? String).flatMap(self.parseISO8601Date)

        let opusWindow = (json["seven_day_opus"] as? [String: Any]) ?? (json["seven_day_sonnet"] as? [String: Any])
        let opusPercent = opusWindow.flatMap { self.numericValue($0["utilization"]) }
        let extraUsageCost = (json["extra_usage"] as? [String: Any]).flatMap(self.parseExtraUsageCost)

        guard sessionPercent != nil || weeklyPercent != nil || opusPercent != nil || extraUsageCost != nil else {
            throw FetchError.invalidResponse
        }

        return WebUsageData(
            sessionPercentUsed: sessionPercent,
            sessionResetsAt: sessionResets,
            weeklyPercentUsed: weeklyPercent,
            weeklyResetsAt: weeklyResets,
            opusPercentUsed: opusPercent,
            extraUsageCost: extraUsageCost,
            accountOrganization: nil,
            accountEmail: nil,
            loginMethod: nil)
    }

    private static func numericValue(_ raw: Any?) -> Double? {
        switch raw {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            return number.doubleValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let sanitized = trimmed.hasSuffix("%") ? String(trimmed.dropLast()) : trimmed
            return Double(sanitized)
        default:
            return nil
        }
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return nil
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseExtraUsageCost(_ json: [String: Any]) -> ProviderCostSnapshot? {
        if let isEnabled = self.boolValue(json["is_enabled"] ?? json["isEnabled"]),
           !isEnabled
        {
            return nil
        }
        guard let used = self.numericValue(json["used_credits"] ?? json["usedCredits"]),
              let limit = self.numericValue(json["monthly_limit"] ?? json["monthlyCreditLimit"])
        else {
            return nil
        }
        let currency = self.stringValue(json["currency"]) ?? "USD"
        return self.makeExtraUsageCost(used: used, limit: limit, currencyCode: currency)
    }

    private static func debugUsageResponseSummary(_ data: Data) -> String {
        let rawText = String(data: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            if rawText.isEmpty {
                return "non-JSON response"
            }
            return "non-JSON response preview=\(rawText)"
        }

        let keys: [String] = if let dict = json as? [String: Any] {
            dict.keys.sorted()
        } else if let array = json as? [[String: Any]], let first = array.first {
            first.keys.sorted()
        } else {
            []
        }

        let notable = self.extractNotableFields(from: json).prefix(12).joined(separator: ", ")
        let preview = rawText.isEmpty ? "" : " preview=\(rawText)"
        let notableText = notable.isEmpty ? "" : " notable=\(notable)"
        let keyText = keys.isEmpty ? "keys=[]" : "keys=[\(keys.joined(separator: ","))]"
        return "\(keyText)\(notableText)\(preview)"
    }

    // MARK: - Extra usage cost (Claude "Extra")

    private struct OverageSpendLimitResponse: Decodable {
        let monthlyCreditLimit: Double?
        let currency: String?
        let usedCredits: Double?
        let isEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case monthlyCreditLimit = "monthly_credit_limit"
            case currency
            case usedCredits = "used_credits"
            case isEnabled = "is_enabled"
        }
    }

    /// Best-effort fetch of Claude Extra spend/limit (does not fail the main usage fetch).
    private static func fetchExtraUsageCost(
        orgId: String,
        sessionKey: String,
        logger: ((String) -> Void)? = nil) async -> ProviderCostSnapshot?
    {
        let url = URL(string: "\(baseURL)/organizations/\(orgId)/overage_spend_limit")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            logger?("Overage API status: \(httpResponse.statusCode)")
            guard httpResponse.statusCode == 200 else { return nil }
            return Self.parseOverageSpendLimit(data)
        } catch {
            return nil
        }
    }

    private static func parseOverageSpendLimit(_ data: Data) -> ProviderCostSnapshot? {
        guard let decoded = try? JSONDecoder().decode(OverageSpendLimitResponse.self, from: data) else { return nil }
        guard decoded.isEnabled == true else { return nil }
        guard let used = decoded.usedCredits,
              let limit = decoded.monthlyCreditLimit else { return nil }
        let currency = decoded.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currencyCode = (currency?.isEmpty ?? true) ? "USD" : currency!
        return self.makeExtraUsageCost(used: used, limit: limit, currencyCode: currencyCode)
    }

    private static func makeExtraUsageCost(
        used: Double,
        limit: Double,
        currencyCode: String) -> ProviderCostSnapshot
    {
        let normalizedCurrency = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = normalizedCurrency.isEmpty ? "USD" : normalizedCurrency
        return ProviderCostSnapshot(
            used: used / 100.0,
            limit: limit / 100.0,
            currencyCode: code,
            period: "Monthly",
            resetsAt: nil,
            updatedAt: Date())
    }

    #if DEBUG

    // MARK: - Test hooks (DEBUG-only)

    public static func _parseUsageResponseForTesting(_ data: Data) throws -> WebUsageData {
        try self.parseUsageResponse(data)
    }

    public static func _parseOrganizationsResponseForTesting(
        _ data: Data,
        preferredOrganizationID: String? = nil) throws -> OrganizationInfo
    {
        let organizations = try self.parseOrganizationsResponse(data)
        return try self.selectOrganization(organizations, preferredOrganizationID: preferredOrganizationID)
    }

    public static func _parseOverageSpendLimitForTesting(_ data: Data) -> ProviderCostSnapshot? {
        self.parseOverageSpendLimit(data)
    }

    public static func _parseAccountInfoForTesting(_ data: Data, orgId: String?) -> WebAccountInfo? {
        self.parseAccountInfo(data, orgId: orgId)
    }
    #endif

    private static func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private struct OrganizationResponse: Decodable {
        let uuid: String
        let name: String?
        let capabilities: [String]?
    }

    private static func parseOrganizationsResponse(_ data: Data) throws -> [OrganizationInfo] {
        guard let organizations = try? JSONDecoder().decode([OrganizationResponse].self, from: data) else {
            throw FetchError.invalidResponse
        }
        let parsed = organizations.map { organization in
            let name = organization.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = (name?.isEmpty ?? true) ? nil : name
            return OrganizationInfo(
                id: organization.uuid,
                name: sanitized,
                capabilities: organization.capabilities ?? [])
        }
        guard !parsed.isEmpty else {
            throw FetchError.noOrganization
        }
        return parsed
    }

    private static func selectOrganization(
        _ organizations: [OrganizationInfo],
        preferredOrganizationID: String?,
        logger: ((String) -> Void)? = nil) throws -> OrganizationInfo
    {
        guard !organizations.isEmpty else { throw FetchError.noOrganization }

        let preferred = preferredOrganizationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferred, !preferred.isEmpty {
            if let match = organizations.first(where: { $0.id == preferred }) {
                return match
            }
            logger?("Preferred organization \(preferred) not found; falling back to automatic selection")
        }

        return organizations.first(where: { $0.hasChatCapability })
            ?? organizations.first(where: { !$0.isApiOnly })
            ?? organizations[0]
    }

    public struct WebAccountInfo: Sendable {
        public let email: String?
        public let loginMethod: String?

        public init(email: String?, loginMethod: String?) {
            self.email = email
            self.loginMethod = loginMethod
        }
    }

    private struct AccountResponse: Decodable {
        let emailAddress: String?
        let memberships: [Membership]?

        enum CodingKeys: String, CodingKey {
            case emailAddress = "email_address"
            case memberships
        }

        struct Membership: Decodable {
            let organization: Organization

            struct Organization: Decodable {
                let uuid: String?
                let name: String?
                let rateLimitTier: String?
                let billingType: String?

                enum CodingKeys: String, CodingKey {
                    case uuid
                    case name
                    case rateLimitTier = "rate_limit_tier"
                    case billingType = "billing_type"
                }
            }
        }
    }

    private static func fetchAccountInfo(
        sessionKey: String,
        orgId: String?,
        logger: ((String) -> Void)? = nil) async -> WebAccountInfo?
    {
        let url = URL(string: "\(baseURL)/account")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            logger?("Account API status: \(httpResponse.statusCode)")
            guard httpResponse.statusCode == 200 else { return nil }
            return Self.parseAccountInfo(data, orgId: orgId)
        } catch {
            return nil
        }
    }

    private static func parseAccountInfo(_ data: Data, orgId: String?) -> WebAccountInfo? {
        guard let response = try? JSONDecoder().decode(AccountResponse.self, from: data) else { return nil }
        let email = response.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let membership = Self.selectMembership(response.memberships, orgId: orgId)
        let plan = ClaudePlan.webLoginMethod(
            rateLimitTier: membership?.organization.rateLimitTier,
            billingType: membership?.organization.billingType)
        return WebAccountInfo(email: email, loginMethod: plan)
    }

    private static func selectMembership(
        _ memberships: [AccountResponse.Membership]?,
        orgId: String?) -> AccountResponse.Membership?
    {
        guard let memberships, !memberships.isEmpty else { return nil }
        if let orgId {
            if let match = memberships.first(where: { $0.organization.uuid == orgId }) { return match }
        }
        return memberships.first
    }

    private struct ProbeParseResult: Sendable {
        let keys: [String]
        let emails: [String]
        let planHints: [String]
        let notableFields: [String]
        let preview: String?
    }

    private static func parseProbeBody(
        data: Data,
        fallbackText: String,
        contentType: String?) -> ProbeParseResult
    {
        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksJSON = (contentType?.lowercased().contains("application/json") ?? false) ||
            trimmed.hasPrefix("{") || trimmed.hasPrefix("[")

        var keys: [String] = []
        var notableFields: [String] = []
        if looksJSON, let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                keys = dict.keys.sorted()
            } else if let array = json as? [[String: Any]], let first = array.first {
                keys = first.keys.sorted()
            }
            notableFields = Self.extractNotableFields(from: json)
        }

        let emails = Self.extractEmails(from: trimmed)
        let planHints = Self.extractPlanHints(from: trimmed)
        let preview = trimmed.isEmpty ? nil : String(trimmed.prefix(500))
        return ProbeParseResult(
            keys: keys,
            emails: emails,
            planHints: planHints,
            notableFields: notableFields,
            preview: preview)
    }

    private static func extractEmails(from text: String) -> [String] {
        let pattern = #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [String] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 0), in: text) else { return }
            let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { results.append(value) }
        }
        return Array(Set(results)).sorted()
    }

    private static func extractPlanHints(from text: String) -> [String] {
        let pattern = #"(?i)\b(max|pro|team|ultra|enterprise)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [String] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: text) else { return }
            let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { results.append(value) }
        }
        return Array(Set(results)).sorted()
    }

    private static func extractNotableFields(from json: Any) -> [String] {
        let pattern = #"(?i)(plan|tier|subscription|seat|billing|product)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        var results: [String] = []

        func keyMatches(_ key: String) -> Bool {
            let range = NSRange(key.startIndex..<key.endIndex, in: key)
            return regex.firstMatch(in: key, options: [], range: range) != nil
        }

        func appendValue(_ keyPath: String, value: Any) {
            if results.count >= 40 { return }
            let rendered: String
            switch value {
            case let str as String:
                rendered = str
            case let num as NSNumber:
                rendered = num.stringValue
            case let bool as Bool:
                rendered = bool ? "true" : "false"
            default:
                return
            }
            let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            results.append("\(keyPath)=\(trimmed)")
        }

        func walk(_ value: Any, path: String) {
            if let dict = value as? [String: Any] {
                for (key, nested) in dict {
                    let nextPath = path.isEmpty ? key : "\(path).\(key)"
                    if keyMatches(key) {
                        appendValue(nextPath, value: nested)
                    }
                    walk(nested, path: nextPath)
                }
            } else if let array = value as? [Any] {
                for (idx, nested) in array.enumerated() {
                    let nextPath = "\(path)[\(idx)]"
                    walk(nested, path: nextPath)
                }
            }
        }

        walk(json, path: "")
        return results
    }

    #else

    public static func fetchUsage(logger: ((String) -> Void)? = nil) async throws -> WebUsageData {
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func fetchUsage(
        browserDetection: BrowserDetection,
        preferredOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        _ = browserDetection
        _ = preferredOrganizationID
        _ = logger
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func fetchUsage(
        cookieHeader: String,
        preferredOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        _ = cookieHeader
        _ = preferredOrganizationID
        _ = logger
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func fetchUsage(
        using sessionKeyInfo: SessionKeyInfo,
        preferredOrganizationID: String? = nil,
        logger: ((String) -> Void)? = nil) async throws -> WebUsageData
    {
        _ = sessionKeyInfo
        _ = preferredOrganizationID
        _ = logger
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func probeEndpoints(
        _ endpoints: [String],
        includePreview: Bool = false,
        logger: ((String) -> Void)? = nil) async throws -> [ProbeResult]
    {
        throw FetchError.notSupportedOnThisPlatform
    }

    public static func hasSessionKey(browserDetection: BrowserDetection, logger: ((String) -> Void)? = nil) -> Bool {
        _ = browserDetection
        _ = logger
        return false
    }

    public static func hasSessionKey(cookieHeader: String?) -> Bool {
        guard let cookieHeader else { return false }
        for pair in CookieHeaderNormalizer.pairs(from: cookieHeader) where pair.name == "sessionKey" {
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("sk-ant-") {
                return true
            }
        }
        return false
    }

    public static func sessionKeyInfo(logger: ((String) -> Void)? = nil) throws -> SessionKeyInfo {
        throw FetchError.notSupportedOnThisPlatform
    }

    #endif
}
