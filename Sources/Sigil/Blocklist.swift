import Foundation

/// A blocked application, identified by its stable bundle ID. The display name is cached purely so
/// the menu can label it without re-resolving the bundle.
struct BlockedApp: Equatable {
    let bundleID: String
    let name: String
}

/// User-managed list of apps and sites where Visual mode should *not* interfere. Persisted in
/// `UserDefaults`. Domains are normalised on entry so equivalent inputs collapse, and matching is
/// suffix-based so a domain covers its subdomains.
///
/// All access is expected on the main thread (the menu mutates it; the controller reads it during
/// its off-main suppression refresh, which only reads immutable snapshots of small arrays).
final class Blocklist {
    private let defaults: UserDefaults
    private let appsKey = "com.sigil.blockedApps"
    private let domainsKey = "com.sigil.blockedDomains"

    private(set) var apps: [BlockedApp]
    private(set) var domains: [String]

    /// Fired on every mutation so observers (the menu) can rebuild.
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Apps persist as parallel [bundleID, name] pairs encoded as a flat dictionary array.
        let rawApps = defaults.array(forKey: appsKey) as? [[String: String]] ?? []
        self.apps = rawApps.compactMap { dict in
            guard let id = dict["bundleID"], let name = dict["name"] else { return nil }
            return BlockedApp(bundleID: id, name: name)
        }
        self.domains = defaults.stringArray(forKey: domainsKey) ?? []
    }

    // MARK: - Mutation

    func addApp(bundleID: String, name: String) {
        guard !bundleID.isEmpty, !apps.contains(where: { $0.bundleID == bundleID }) else { return }
        apps.append(BlockedApp(bundleID: bundleID, name: name))
        persistApps()
    }

    func removeApp(bundleID: String) {
        let before = apps.count
        apps.removeAll { $0.bundleID == bundleID }
        if apps.count != before { persistApps() }
    }

    /// Add a site from raw user input (a URL or bare domain). No-op if it normalises to empty or is
    /// already present.
    func addDomain(raw: String) {
        guard let domain = Self.normalize(raw), !domains.contains(domain) else { return }
        domains.append(domain)
        persistDomains()
    }

    func removeDomain(_ domain: String) {
        let before = domains.count
        domains.removeAll { $0 == domain }
        if domains.count != before { persistDomains() }
    }

    // MARK: - Matching

    func blocksApp(bundleID: String) -> Bool {
        apps.contains { $0.bundleID == bundleID }
    }

    /// True if `host` equals a blocked domain or is a subdomain of one (e.g. `m.youtube.com` is
    /// covered by `youtube.com`).
    func blocks(host: String) -> Bool {
        let h = host.lowercased()
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    // MARK: - Normalisation

    /// Reduce a URL or bare domain to a registrable host: lowercased, no scheme, no path/query, no
    /// leading `www.`. Returns nil if nothing usable remains.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        // Strip scheme.
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        // Drop credentials (user:pass@host) if present.
        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        // Cut path / query / fragment.
        for separator in ["/", "?", "#"] {
            if let idx = s.firstIndex(of: Character(separator)) {
                s = String(s[..<idx])
            }
        }
        // Drop a port.
        if let colon = s.firstIndex(of: ":") {
            s = String(s[..<colon])
        }
        // Drop a leading www.
        if s.hasPrefix("www.") {
            s = String(s.dropFirst(4))
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return s.isEmpty ? nil : s
    }

    // MARK: - Persistence

    private func persistApps() {
        let raw = apps.map { ["bundleID": $0.bundleID, "name": $0.name] }
        defaults.set(raw, forKey: appsKey)
        onChange?()
    }

    private func persistDomains() {
        defaults.set(domains, forKey: domainsKey)
        onChange?()
    }
}
