import CodexBarCore
import Foundation

extension UsageStore {
    func refreshClaudeDiscoveredOrganizations(force: Bool = false) async {
        let discovery = self.settings.claudeOrganizationDiscoveryConfiguration()
        let sourceChanged = self.settings.claudeDiscoveredOrganizationsSourceKey != discovery.cacheKey

        if sourceChanged {
            self.settings.replaceClaudeDiscoveredOrganizations(
                [ClaudeOrganizationChoice](),
                sourceKey: discovery.cacheKey)
        }

        if self.claudeOrganizationDiscoveryInFlight {
            if force || self.claudeOrganizationDiscoveryRequestKey != discovery.cacheKey {
                self.claudeOrganizationDiscoveryPendingRefresh = true
            }
            return
        }

        guard force || sourceChanged || self.settings.claudeDiscoveredOrganizations.isEmpty else { return }
        guard discovery.isAvailable else { return }

        if ProviderInteractionContext.current == .userInitiated,
           discovery.manualCookieHeader == nil,
           discovery.allowsBrowserCookies,
           BrowserCookieAccessGate.clearDenied()
        {
            self.providerLogger.info("Cleared browser cookie access cooldown before Claude org discovery")
        }

        self.claudeOrganizationDiscoveryInFlight = true
        self.claudeOrganizationDiscoveryRequestKey = discovery.cacheKey
        defer {
            self.claudeOrganizationDiscoveryInFlight = false
            self.claudeOrganizationDiscoveryRequestKey = nil
            if self.claudeOrganizationDiscoveryPendingRefresh {
                self.claudeOrganizationDiscoveryPendingRefresh = false
                Task { @MainActor [weak self] in
                    await self?.refreshClaudeDiscoveredOrganizations(force: true)
                }
            }
        }

        do {
            let organizations: [ClaudeWebAPIFetcher.OrganizationInfo] = if let manualCookieHeader = discovery
                .manualCookieHeader
            {
                try await ClaudeWebAPIFetcher.fetchOrganizations(cookieHeader: manualCookieHeader)
            } else {
                try await ClaudeWebAPIFetcher.fetchOrganizations(
                    browserDetection: self.browserDetection)
            }

            guard self.settings.claudeOrganizationDiscoveryConfiguration().cacheKey == discovery.cacheKey
            else { return }
            self.settings.replaceClaudeDiscoveredOrganizations(
                organizations,
                sourceKey: discovery.cacheKey)
        } catch {
            self.providerLogger.debug("Claude organization discovery failed: \(error.localizedDescription)")
        }
    }
}
