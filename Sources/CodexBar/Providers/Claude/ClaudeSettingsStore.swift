import CodexBarCore
import CryptoKit
import Foundation

struct ClaudeOrganizationChoice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String?

    init(id: String, name: String?) {
        self.id = id
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    var displayName: String {
        self.name ?? self.id
    }

    static func makeChoices(from organizations: [ClaudeWebAPIFetcher.OrganizationInfo]) -> [ClaudeOrganizationChoice] {
        var seen: Set<String> = []
        var choices: [ClaudeOrganizationChoice] = []
        choices.reserveCapacity(organizations.count)

        for organization in organizations {
            guard seen.insert(organization.id).inserted else { continue }
            choices.append(ClaudeOrganizationChoice(id: organization.id, name: organization.name))
        }

        return choices
    }
}

struct ClaudeOrganizationDiscoveryConfiguration: Sendable {
    let manualCookieHeader: String?
    let allowsBrowserCookies: Bool
    let cacheKey: String

    var isAvailable: Bool {
        self.manualCookieHeader != nil || self.allowsBrowserCookies
    }
}

extension SettingsStore {
    fileprivate static let claudeDiscoveredOrganizationsDefaultsKey = "claudeDiscoveredOrganizations"
    fileprivate static let claudeDiscoveredOrganizationsSourceKeyDefaultsKey =
        "claudeDiscoveredOrganizationsSourceKey"

    static func loadClaudeDiscoveredOrganizations(userDefaults: UserDefaults) -> [ClaudeOrganizationChoice] {
        guard let data = userDefaults.data(forKey: claudeDiscoveredOrganizationsDefaultsKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([ClaudeOrganizationChoice].self, from: data) else {
            userDefaults.removeObject(forKey: Self.claudeDiscoveredOrganizationsDefaultsKey)
            return []
        }
        return decoded
    }

    static func loadClaudeDiscoveredOrganizationsSourceKey(userDefaults: UserDefaults) -> String? {
        userDefaults.string(forKey: self.claudeDiscoveredOrganizationsSourceKeyDefaultsKey)
    }

    var claudeUsageDataSource: ClaudeUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .claude)?.source
            return Self.claudeUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .web: .web
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .claude) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .claude, field: "usageSource", value: newValue.rawValue)
            if newValue != .cli {
                self.claudeWebExtrasEnabled = false
            }
        }
    }

    var claudeCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .claude)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .claude, field: "cookieHeader", value: newValue)
        }
    }

    var claudeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .claude, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .claude, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var claudePreferredOrganizationID: String {
        get { self.configSnapshot.providerConfig(for: .claude)?.sanitizedOrganizationID ?? "" }
        set {
            let normalized = self.normalizedConfigValue(newValue)
            self.updateProviderConfig(provider: .claude) { entry in
                entry.organizationID = normalized
            }
            self.logProviderModeChange(
                provider: .claude,
                field: "organizationID",
                value: normalized ?? "auto")
        }
    }

    func replaceClaudeDiscoveredOrganizations(
        _ organizations: [ClaudeWebAPIFetcher.OrganizationInfo],
        sourceKey: String? = nil)
    {
        self.replaceClaudeDiscoveredOrganizations(
            ClaudeOrganizationChoice.makeChoices(from: organizations),
            sourceKey: sourceKey)
    }

    func ensureClaudeCookieLoaded() {}

    func claudeOrganizationDiscoveryConfiguration() -> ClaudeOrganizationDiscoveryConfiguration {
        if let account = self.selectedTokenAccount(for: .claude) {
            switch ClaudeCredentialRouting.resolve(tokenAccountToken: account.token, manualCookieHeader: nil) {
            case let .webCookie(header):
                return ClaudeOrganizationDiscoveryConfiguration(
                    manualCookieHeader: header,
                    allowsBrowserCookies: false,
                    cacheKey: self.claudeOrganizationDiscoveryCacheKey(
                        prefix: "token-account-web-\(account.id.uuidString)",
                        secret: header))
            case .oauth, .none:
                return ClaudeOrganizationDiscoveryConfiguration(
                    manualCookieHeader: nil,
                    allowsBrowserCookies: false,
                    cacheKey: "token-account-unavailable-\(account.id.uuidString)")
            }
        }

        switch self.claudeCookieSource {
        case .manual:
            let manualCookieHeader = CookieHeaderNormalizer.normalize(self.claudeCookieHeader)
            return ClaudeOrganizationDiscoveryConfiguration(
                manualCookieHeader: manualCookieHeader,
                allowsBrowserCookies: false,
                cacheKey: self.claudeOrganizationDiscoveryCacheKey(
                    prefix: "manual-cookie",
                    secret: manualCookieHeader ?? ""))
        case .auto:
            return ClaudeOrganizationDiscoveryConfiguration(
                manualCookieHeader: nil,
                allowsBrowserCookies: true,
                cacheKey: "browser-auto")
        case .off:
            return ClaudeOrganizationDiscoveryConfiguration(
                manualCookieHeader: nil,
                allowsBrowserCookies: false,
                cacheKey: "browser-off")
        }
    }

    func replaceClaudeDiscoveredOrganizations(
        _ organizations: [ClaudeOrganizationChoice],
        sourceKey: String? = nil)
    {
        let normalized = organizations
        let organizationsChanged = self.claudeDiscoveredOrganizations != normalized
        let sourceKeyChanged = self.claudeDiscoveredOrganizationsSourceKey != sourceKey
        guard organizationsChanged || sourceKeyChanged else { return }
        self.claudeDiscoveredOrganizations = normalized
        self.claudeDiscoveredOrganizationsSourceKey = sourceKey
        if let sourceKey {
            self.userDefaults.set(sourceKey, forKey: Self.claudeDiscoveredOrganizationsSourceKeyDefaultsKey)
        } else {
            self.userDefaults.removeObject(forKey: Self.claudeDiscoveredOrganizationsSourceKeyDefaultsKey)
        }
        if normalized.isEmpty {
            self.userDefaults.removeObject(forKey: Self.claudeDiscoveredOrganizationsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        self.userDefaults.set(data, forKey: Self.claudeDiscoveredOrganizationsDefaultsKey)
    }

    private func claudeOrganizationDiscoveryCacheKey(prefix: String, secret: String) -> String {
        guard !secret.isEmpty else { return prefix }
        return "\(prefix):\(Self.sha256(secret))"
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension SettingsStore {
    func claudeSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .ClaudeProviderSettings {
        let account = self.selectedClaudeTokenAccount(tokenOverride: tokenOverride)
        let routing = self.claudeCredentialRouting(account: account)
        return ProviderSettingsSnapshot.ClaudeProviderSettings(
            usageDataSource: self.claudeUsageDataSource,
            webExtrasEnabled: self.claudeWebExtrasEnabled,
            cookieSource: self.claudeSnapshotCookieSource(tokenOverride: tokenOverride, routing: routing),
            manualCookieHeader: self.claudeSnapshotCookieHeader(
                routing: routing,
                hasSelectedAccount: account != nil),
            preferredOrganizationID: self.normalizedConfigValue(self.claudePreferredOrganizationID))
    }

    private static func claudeUsageDataSource(from source: ProviderSourceMode?) -> ClaudeUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .api:
            return .auto
        case .web:
            return .web
        case .cli:
            return .cli
        case .oauth:
            return .oauth
        }
    }

    private func claudeSnapshotCookieHeader(
        routing: ClaudeCredentialRouting,
        hasSelectedAccount: Bool) -> String
    {
        switch routing {
        case .none:
            hasSelectedAccount ? "" : self.claudeCookieHeader
        case .oauth:
            ""
        case let .webCookie(header):
            header
        }
    }

    private func claudeSnapshotCookieSource(
        tokenOverride: TokenAccountOverride?,
        routing: ClaudeCredentialRouting) -> ProviderCookieSource
    {
        let fallback = self.claudeCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .claude),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if routing.isOAuth {
            return .off
        }
        if self.tokenAccounts(for: .claude).isEmpty { return fallback }
        return .manual
    }

    private func claudeCredentialRouting(account: ProviderTokenAccount?) -> ClaudeCredentialRouting {
        let manualCookieHeader = account == nil ? self.claudeCookieHeader : nil
        return ClaudeCredentialRouting.resolve(
            tokenAccountToken: account?.token,
            manualCookieHeader: manualCookieHeader)
    }

    private func selectedClaudeTokenAccount(tokenOverride: TokenAccountOverride?) -> ProviderTokenAccount? {
        ProviderTokenAccountSelection.selectedAccount(
            provider: .claude,
            settings: self,
            override: tokenOverride)
    }
}
