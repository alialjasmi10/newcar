import Foundation

// Serial actor: network decoding and playlist parsing stay away from the UI actor.
actor HubService {
    static let shared = HubService()
    private let limit = 64 * 1024 * 1024
    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw HubFailure.message("Server rejected the request. Check your provider and subscription.")
            }
            guard response.expectedContentLength <= Int64(limit) else { throw HubFailure.message("Feed exceeds the 64 MB import limit.") }
            var data = Data(); var chunk = [UInt8](); chunk.reserveCapacity(8192)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 8192 {
                    try Task.checkCancellation()
                    guard data.count + chunk.count <= limit else { throw HubFailure.message("Feed exceeds the 64 MB import limit.") }
                    data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                }
            }
            guard data.count + chunk.count <= limit else { throw HubFailure.message("Feed exceeds the 64 MB import limit.") }
            data.append(contentsOf: chunk); return data
        } catch is CancellationError { throw CancellationError() }
        catch let e as HubFailure { throw e }
        catch { throw HubFailure.message("Connection failed or timed out. Check the network and server address.") }
    }
    private func endpoint(_ secret: HubSecret, file: String, action: String? = nil, extra: [URLQueryItem] = []) throws -> URL {
        let base = try hubWebURL(secret.server)
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "/" + file : c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash + "/" + file
        c.fragment = nil
        c.queryItems = [URLQueryItem(name:"username",value:secret.username),URLQueryItem(name:"password",value:secret.password)] + (action.map { [URLQueryItem(name:"action",value:$0)] } ?? []) + extra
        guard let u = c.url else { throw HubFailure.message("Invalid provider address.") }; return u
    }
    private func api(_ s: HubSecret, _ action: String? = nil, extra: [URLQueryItem] = []) async throws -> Any {
        let data = try await download(endpoint(s, file:"player_api.php", action:action, extra:extra))
        do { return try JSONSerialization.jsonObject(with:data) }
        catch { throw HubFailure.message("Provider returned invalid JSON instead of an Xtream response.") }
    }
    private func string(_ x: Any?) -> String { if let s = x as? String { return s }; if let n = x as? NSNumber { return n.stringValue }; return "" }
    private func categories(_ s: HubSecret, _ action: String) async throws -> [String:String] {
        guard let list = try await api(s,action) as? [[String:Any]] else { throw HubFailure.message("Invalid categories response.") }
        var result = [String:String](); for c in list { result[string(c["category_id"])] = string(c["category_name"]) }; return result
    }
    func catalogue(_ p: HubProvider, secret s: HubSecret) async throws -> [HubMedia] {
        if p.type == "m3u" { let url = try hubWebURL(s.server); return try HubM3U.parse(await download(url),provider:p.id,base:url) }
        guard let auth = try await api(s) as? [String:Any], let user = auth["user_info"] as? [String:Any], string(user["auth"]) == "1",
              string(user["status"]).isEmpty || string(user["status"]).lowercased() == "active" else { throw HubFailure.message("Xtream login rejected or subscription inactive.") }
        var result = [HubMedia]()
        for (kind, categoryAction, listAction) in [(HubKind.live,"get_live_categories","get_live_streams"),(.movie,"get_vod_categories","get_vod_streams"),(.series,"get_series_categories","get_series")] {
            try Task.checkCancellation()
            let cats = try await categories(s, categoryAction)
            guard let list = try await api(s,listAction) as? [[String:Any]] else { throw HubFailure.message("Invalid catalogue response. Previous library retained.") }
            for item in list {
                let remote = string(item[kind == .series ? "series_id" : "stream_id"])
                guard !remote.isEmpty else { continue }
                var m = HubMedia(id:hubID(p.id + kind.rawValue + remote),provider:p.id,remoteID:remote,kind:kind,name:string(item["name"]))
                m.category = cats[string(item["category_id"])] ?? "Uncategorized"
                m.image = string(item[kind == .series ? "cover" : "stream_icon"])
                m.epgID = string(item["epg_channel_id"])
                m.ext = kind == .live ? "m3u8" : (string(item["container_extension"]).isEmpty ? "mp4" : string(item["container_extension"]))
                m.detail = string(item["plot"]); m.year = string(item["year"])
                if m.year.isEmpty { m.year = String(string(item["releaseDate"]).prefix(4)) }
                m.rating = string(item["rating"]); result.append(m)
            }
        }
        return result
    }
    func localPlaylist(_ data: Data, provider: String) throws -> [HubMedia] {
        guard data.count <= limit else { throw HubFailure.message("Playlist exceeds 64 MB.") }
        return try HubM3U.parse(data,provider:provider,base:nil)
    }
    func episodes(_ series: HubMedia, secret: HubSecret) async throws -> [HubMedia] {
        guard let obj = try await api(secret,"get_series_info",extra:[URLQueryItem(name:"series_id",value:series.remoteID)]) as? [String:Any], let seasons = obj["episodes"] as? [String:Any] else { throw HubFailure.message("Provider returned no episode information.") }
        var items = [HubMedia]()
        for (season, value) in seasons {
            guard let episodes = value as? [[String:Any]] else { continue }
            for e in episodes {
                let remote = string(e["id"]); guard !remote.isEmpty else { continue }
                let info = e["info"] as? [String:Any] ?? [:]
                var m = HubMedia(id:hubID(series.provider + "episode" + remote),provider:series.provider,remoteID:remote,kind:.episode,name:string(e["title"]))
                m.parent = series.id; m.category = series.category; m.season = Int(string(e["season"])) ?? Int(season) ?? 0
                m.episode = Int(string(e["episode_num"])) ?? 0
                m.ext = string(e["container_extension"]); if m.ext.isEmpty { m.ext = "mp4" }
                m.image = string(info["movie_image"]); if m.image.isEmpty { m.image = series.image }
                m.detail = string(info["plot"]); m.runtime = string(info["duration"]); items.append(m)
            }
        }
        return items
    }
    func movieDetails(_ media: HubMedia, secret: HubSecret) async throws -> HubMedia {
        guard let obj = try await api(secret,"get_vod_info",extra:[URLQueryItem(name:"vod_id",value:media.remoteID)]) as? [String:Any] else { return media }
        let info = obj["info"] as? [String:Any] ?? [:]; var m = media
        m.detail = string(info["plot"]); m.runtime = string(info["duration"])
        let rating = string(info["rating"]); if !rating.isEmpty { m.rating = rating }
        let year = String(string(info["releasedate"]).prefix(4)); if !year.isEmpty { m.year = year }; return m
    }
    func playback(_ media: HubMedia) throws -> URL {
        if !media.url.isEmpty { return try hubWebURL(media.url) }
        let secret = try HubKeychain.read(media.provider)
        let base = try hubWebURL(secret.server)
        var c = URLComponents(url:base,resolvingAgainstBaseURL:false)!
        let route = media.kind == .live ? "live" : (media.kind == .movie ? "movie" : "series")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        let parts = [route,secret.username,secret.password,media.remoteID + "." + media.ext]
        c.percentEncodedPath = c.percentEncodedPath.trimmingCharacters(in:CharacterSet(charactersIn:"/" )).withOptionalLeadingSlash + "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters:allowed)! }.joined(separator:"/")
        c.query = nil; c.fragment = nil
        guard let url = c.url else { throw HubFailure.message("Invalid stream address.") }; return url
    }
    func epg(_ p: HubProvider, secret: HubSecret) async throws -> [HubProgram] {
        let url: URL
        if !secret.epg.isEmpty { url = try hubWebURL(secret.epg) }
        else if p.type == "xtream" { url = try endpoint(secret,file:"xmltv.php") }
        else { throw HubFailure.message("Add an XMLTV URL when adding the playlist.") }
        return try HubXMLTV.parse(await download(url))
    }
}
private extension String {
    var withLeadingSlash: String { "/" + self }
    var withOptionalLeadingSlash: String { isEmpty ? "" : "/" + self }
}
