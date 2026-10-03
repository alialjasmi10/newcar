import Foundation
import CryptoKit

enum HubKind: String, Codable, CaseIterable, Sendable { case live, movie, series, episode }
struct HubProvider: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var type: String // m3u or xtream; secrets live in Keychain
}
struct HubSecret: Codable, Sendable { var server: String; var username: String; var password: String; var epg: String }
struct HubMedia: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var provider: String
    var remoteID: String = ""
    var kind: HubKind
    var name: String
    var category: String = "Uncategorized"
    var url: String = ""
    var image: String = ""
    var epgID: String = ""
    var ext: String = "mp4"
    var parent: String = ""
    var season: Int = 0
    var episode: Int = 0
    var detail: String = ""
    var year: String = ""
    var rating: String = ""
    var runtime: String = ""
}
struct HubProgress: Codable, Sendable { var seconds: Double = 0; var duration: Double = 0; var date: Double = 0; var watched: Bool = false }
struct HubProgram: Codable, Sendable { var channel: String; var title: String; var start: Double; var end: Double }
struct HubPage: Sendable { var items: [HubMedia]; var hasMore: Bool }
enum HubFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
func hubID(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
func hubWebURL(_ string: String) throws -> URL {
    guard let u = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["https", "http"].contains(u.scheme?.lowercased() ?? ""), u.host != nil,
          u.user == nil, u.password == nil else { throw HubFailure.message("Enter a valid http/https URL without embedded user:password.") }
    return u
}

// Pure parser: no network, no UI work. Relative playlist entries resolve against source URL.
enum HubM3U {
    static func parse(_ data: Data, provider: String, base: URL?) throws -> [HubMedia] {
        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              decoded.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{feff}", with: "").hasPrefix("#EXTM3U") else {
            throw HubFailure.message("This is not an M3U playlist.")
        }
        let text = decoded.replacingOccurrences(of:"\u{feff}",with:"")
        // An HLS media/master manifest is one playable item, not a channel catalogue.
        if text.contains("#EXT-X-") {
            guard let base = base else { throw HubFailure.message("Import the HLS URL, not a local manifest with missing segments.") }
            return [HubMedia(id: hubID(provider + base.absoluteString), provider: provider, kind: .live, name: "HLS Stream", url: base.absoluteString)]
        }
        let regex = try NSRegularExpression(pattern: "([A-Za-z0-9_-]+)\\s*=\\s*\"([^\"]*)\"")
        let episodePattern = try NSRegularExpression(pattern:"(?i)^(.+?)\\s+[Ss](\\d{1,2})[ ._-]*[Ee](\\d{1,3})(?:\\s.*)?$")
        var seriesIDs = Set<String>()
        var items = [HubMedia](); var seen = Set<String>(); var title = ""; var attrs = [String:String](); var group = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                attrs.removeAll(); group = ""
                let ns = line as NSString
                for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) { attrs[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2)) }
                var quote = false; var split: String.Index?
                for i in line.indices { if line[i] == "\"" { quote.toggle() }; if line[i] == "," && !quote { split = i; break } }
                title = split.map { String(line[line.index(after: $0)...]) } ?? attrs["tvg-name"] ?? "Channel"
            } else if line.hasPrefix("#EXTGRP:") { group = String(line.dropFirst(8)) }
            else if !line.isEmpty && !line.hasPrefix("#") {
                defer { title = ""; attrs = [:]; group = "" }
                guard let u = URL(string: line, relativeTo: base)?.absoluteURL, ["http","https"].contains(u.scheme?.lowercased() ?? "") else { continue }
                let id = hubID(provider + u.absoluteString)
                guard seen.insert(id).inserted else { continue }
                let kind: HubKind = (attrs["type"] == "movie" || attrs["media-type"] == "movie" || u.path.contains("/movie/")) ? .movie : .live
                var media = HubMedia(id: id, provider: provider, kind: kind, name: title.isEmpty ? (attrs["tvg-name"] ?? "Stream") : title,
                                      category: attrs["group-title"] ?? (group.isEmpty ? "Uncategorized" : group), url: u.absoluteString,
                                      image: attrs["tvg-logo"] ?? "", epgID: attrs["tvg-id"] ?? "")
                let nsTitle = media.name as NSString
                if let match = episodePattern.firstMatch(in:media.name,range:NSRange(location:0,length:nsTitle.length)) {
                    let seriesName = nsTitle.substring(with:match.range(at:1))
                    let seriesID = hubID(provider + "series-name:" + media.category + seriesName)
                    if seriesIDs.insert(seriesID).inserted {
                        items.append(HubMedia(id:seriesID,provider:provider,kind:.series,name:seriesName,category:media.category,image:media.image))
                    }
                    media.kind = .episode; media.parent = seriesID
                    media.season = Int(nsTitle.substring(with:match.range(at:2))) ?? 0
                    media.episode = Int(nsTitle.substring(with:match.range(at:3))) ?? 0
                }
                items.append(media)
            }
        }
        guard !items.isEmpty else { throw HubFailure.message("No supported http/https streams found.") }
        return items
    }
}

final class HubXMLTV: NSObject, XMLParserDelegate {
    var result = [HubProgram](); private var current: HubProgram?; private var inTitle = false
    static func parse(_ data: Data) throws -> [HubProgram] {
        let delegate = HubXMLTV(); let p = XMLParser(data: data); p.delegate = delegate; p.shouldResolveExternalEntities = false
        guard p.parse() else { throw HubFailure.message("Invalid XMLTV. Use an uncompressed XML feed.") }
        return delegate.result
    }
    private let zoned: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT:0); f.dateFormat = "yyyyMMddHHmmss Z"; return f }()
    private let utc: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT:0); f.dateFormat = "yyyyMMddHHmmss"; return f }()
    private func date(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        let f = s.contains(" ") ? zoned : utc
        return f.date(from: s)?.timeIntervalSince1970
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        if name == "programme", let channel = attributes["channel"], let start = date(attributes["start"]), let end = date(attributes["stop"]), end > Date().timeIntervalSince1970 - 86400 {
            current = HubProgram(channel: channel, title: "", start: start, end: end)
        }
        if name == "title" { inTitle = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inTitle { current?.title += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "title" { inTitle = false }
        if name == "programme" { if let c = current { result.append(c) }; current = nil }
    }
}
