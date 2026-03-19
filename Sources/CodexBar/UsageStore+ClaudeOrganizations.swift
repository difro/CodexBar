import CodexBarCore
import Foundation

extension UsageStore {
    func refreshClaudeDiscoveredOrganizations(force: Bool = false) async {
        if !force, !self.settings.claudeDiscoveredOrganizations.isEmpty { return }
        if self.claudeOrganizationDiscoveryInFlight { return }

        let discovery = self.settings.claudeOrganizationDiscoveryConfiguration()
        guard discovery.manualCookieHeader != nil || discovery.allowsBrowserCookies else { return }

        if ProviderInteractionContext.current == .userInitiated,
           discovery.manualCookieHeader == nil,
           discovery.allowsBrowserCookies,
           BrowserCookieAccessGate.clearDenied()
        {
            self.providerLogger.info("Cleared browser cookie access cooldown before Claude org discovery")
        }

        self.claudeOrganizationDiscoveryInFlight = true
        defer { self.claudeOrganizationDiscoveryInFlight = false }

        do {
            let organizations: [ClaudeWebAPIFetcher.OrganizationInfo] = if let manualCookieHeader = discovery
                .manualCookieHeader
            {
                try await ClaudeWebAPIFetcher.fetchOrganizations(cookieHeader: manualCookieHeader)
            } else {
                try await ClaudeWebAPIFetcher.fetchOrganizations(
                    browserDetection: self.browserDetection)
            }

            guard !organizations.isEmpty else { return }
            self.settings.replaceClaudeDiscoveredOrganizations(organizations)
        } catch {
            self.providerLogger.debug("Claude organization discovery failed: \(error.localizedDescription)")
        }
    }
}
