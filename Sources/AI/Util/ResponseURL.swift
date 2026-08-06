import Foundation

/// Decides whether a URL that arrived in a provider's response may carry this
/// client's credentials.
///
/// Several providers hand back an absolute URL to follow — Black Forest Labs'
/// `polling_url`, Gladia's `result_url`, Gemini's file `uri` — and that URL
/// legitimately needs the API key. The risk is that the URL comes from the
/// response body, so a compromised, proxied, or MITM'd endpoint can point it at
/// a host it controls and collect the key.
///
/// Exact host equality is too strict to be correct. Black Forest Labs documents
/// that a request to the global endpoint `api.bfl.ai` returns a `polling_url` on
/// a regional cluster (`api.eu.bfl.ai`, `api.us.bfl.ai`) and that you *must*
/// follow it. So the rule is the registrable domain, which still refuses an
/// unrelated host.
enum ResponseURL {

    /// True when `url` is HTTPS and belongs to the same service as `baseURL`.
    static func carriesCredentials(_ url: URL, matching baseURL: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else {
            // The one exception is a local endpoint, where there is no network
            // to eavesdrop on and no TLS to expect.
            guard url.scheme?.lowercased() == "http", isLoopback(url) else { return false }
            return isLoopback(baseURL)
        }
        guard let host = url.host?.lowercased(), let base = baseURL.host?.lowercased() else {
            return false
        }
        if host == base { return true }
        return registrableDomain(host) == registrableDomain(base)
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// The last two labels of a host.
    ///
    /// This is the usual approximation, and it is wrong for multi-label public
    /// suffixes such as `co.uk` — two unrelated `*.co.uk` hosts would compare
    /// equal. None of the providers this guards use one, and the comparison is
    /// only ever a narrowing of today's behaviour, which accepts any host at
    /// all. Swap in a public-suffix list if that ever stops being true.
    static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }
}
