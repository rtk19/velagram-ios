import Foundation

struct LiveResolver: Sendable {
    func resolve(_ channel: LiveChannel) async throws -> LiveChannel {
        var result = channel
        // The APK ships both DASH and HLS endpoints. Apple playback uses HLS.
        if channel.resolver == "kan" || channel.url.host == "r.il.cdn-redge.media" {
            var components = URLComponents(url: channel.url, resolvingAgainstBaseURL: false)!
            components.path = components.path.replacingOccurrences(of: "/livedash/", with: "/livehls/")
            if components.path.hasSuffix(".livx") { components.path += "/playlist.m3u8" }
            result.url = components.url!
            result.headers["Referer"] = "https://www.kan.org.il/"
        }
        result.headers["User-Agent"] = result.headers["User-Agent"] ?? "Mozilla/5.0 Velagram-iOS/1.0"
        if channel.resolver == "keshet" {
            var ticketURL = URLComponents(string: "https://mass.mako.co.il/ClicksStatistics/entitlementsServicesV2.jsp")!
            var path = URLComponents(url: channel.url, resolvingAgainstBaseURL: false)!.percentEncodedPath
            if let query = channel.url.query { path += "?" + query }
            ticketURL.queryItems = [URLQueryItem(name: "et", value: "ngt"), URLQueryItem(name: "lp", value: path), URLQueryItem(name: "rv", value: channel.resolverData?["cdn"] ?? "AKAMAI")]
            let data = try await VelagramHTTP().data(ticketURL.url!, headers: ["Referer": "https://www.mako.co.il/", "Origin": "https://www.mako.co.il"])
            struct Entitlement: Decodable { let tickets: [Ticket]?
                struct Ticket: Decodable { let ticket: String? }
            }
            let entitlement = try JSONDecoder().decode(Entitlement.self, from: data)
            guard let ticket = entitlement.tickets?.first?.ticket, !ticket.isEmpty else { throw VelagramNetworkError.invalidResponse }
            let decoded = ticket.removingPercentEncoding ?? ticket
            guard let signed = URL(string: channel.url.absoluteString + (channel.url.query == nil ? "?" : "&") + decoded) else { throw VelagramNetworkError.invalidResponse }
            result.url = signed
        } else if channel.resolver == "hidabroot" {
            result.url = try await extract(channel.url, pattern: #"<source\s+src=["']([^"']+)["']"#)
        } else if let regex = channel.resolverData?["regex"], !regex.isEmpty {
            result.url = try await extract(channel.url, pattern: regex)
        }
        return result
    }
    private func extract(_ url: URL, pattern: String) async throws -> URL {
        let data = try await VelagramHTTP().data(url)
        let text = String(decoding: data, as: UTF8.self)
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text),
              let resolved = URL(string: String(text[range]).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: url)?.absoluteURL else { throw VelagramNetworkError.invalidResponse }
        return resolved
    }
}
