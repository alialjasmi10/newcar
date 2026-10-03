import Foundation
import Security
import SQLite3

// Credentials never go into UserDefaults or diagnostic output.
enum HubKeychain {
    static func save(_ value: HubSecret, id: String) throws {
        let data = try JSONEncoder().encode(value)
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"CarCastHub.provider", kSecAttrAccount as String:id]
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw HubFailure.message("Could not save credentials to Keychain.") }
        } else if status != errSecSuccess { throw HubFailure.message("Keychain is unavailable.") }
    }
    static func read(_ id: String) throws -> HubSecret {
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"CarCastHub.provider", kSecAttrAccount as String:id, kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let d = value as? Data else { throw HubFailure.message("Provider credentials unavailable. Re-add this provider.") }
        return try JSONDecoder().decode(HubSecret.self, from: d)
    }
    static func delete(_ id: String) { SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"CarCastHub.provider",kSecAttrAccount as String:id] as CFDictionary) }
}

// Single actor owns the SQLite connection; queries/import transactions never run on MainActor.
actor HubDatabase {
    static let shared = HubDatabase()
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func connect() throws {
        if db != nil { return }
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CarCastHub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = dir; try folder.setResourceValues(excluded)
        guard sqlite3_open(dir.appendingPathComponent("library.sqlite").path, &db) == SQLITE_OK else { throw HubFailure.message("Cannot open library.") }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("CREATE TABLE IF NOT EXISTS providers(id TEXT PRIMARY KEY, data TEXT NOT NULL);")
        try exec("CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY, provider TEXT, kind TEXT, name TEXT, category TEXT, parent TEXT, season INTEGER, episode INTEGER, data TEXT NOT NULL);")
        try exec("CREATE INDEX IF NOT EXISTS media_filter ON media(provider,kind,category,name);")
        try exec("CREATE INDEX IF NOT EXISTS media_parent ON media(parent,season,episode);")
        try exec("CREATE TABLE IF NOT EXISTS activity(id TEXT PRIMARY KEY, favorite INTEGER DEFAULT 0, seconds REAL DEFAULT 0, duration REAL DEFAULT 0, date REAL DEFAULT 0, watched INTEGER DEFAULT 0);")
        try exec("CREATE TABLE IF NOT EXISTS epg(provider TEXT, channel TEXT, title TEXT, start REAL, end REAL);")
        try exec("CREATE INDEX IF NOT EXISTS epg_time ON epg(provider,channel,start,end);")
    }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HubFailure.message("Library write failed.") } }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s = s else { throw HubFailure.message("Library query failed.") }
        for (i,v) in values.enumerated() { sqlite3_bind_text(s, Int32(i+1), v, -1, transient) }
        return s
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }; var result = [[String]]()
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw HubFailure.message("Library read failed.") }
            result.append((0..<sqlite3_column_count(s)).map { sqlite3_column_text(s, $0).map { String(cString:$0) } ?? "" })
        }
        return result
    }
    private func write(_ sql: String, _ values: [String]) throws {
        let s = try statement(sql,values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw HubFailure.message("Library update failed.") }
    }
    private func json<T:Encodable>(_ x: T) throws -> String { String(decoding: try JSONEncoder().encode(x), as: UTF8.self) }
    func providers() throws -> [HubProvider] { try connect(); return try rows("SELECT data FROM providers ORDER BY rowid").map { try JSONDecoder().decode(HubProvider.self,from:Data($0[0].utf8)) } }
    func replace(_ provider: HubProvider, items: [HubMedia], parent: String? = nil) throws {
        try connect(); try exec("BEGIN IMMEDIATE;")
        do {
            try write("INSERT OR REPLACE INTO providers VALUES (?,?)", [provider.id,try json(provider)])
            if let parent = parent { try write("DELETE FROM media WHERE provider=? AND parent=?",[provider.id,parent]) }
            else if provider.type == "xtream" { try write("DELETE FROM media WHERE provider=? AND kind != 'episode'",[provider.id]) }
            else { try write("DELETE FROM media WHERE provider=?",[provider.id]) }
            let s = try statement("INSERT OR REPLACE INTO media VALUES (?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(s) }
            for m in items {
                try Task.checkCancellation()
                sqlite3_reset(s); sqlite3_clear_bindings(s)
                let v = [m.id,m.provider,m.kind.rawValue,m.name,m.category,m.parent,String(m.season),String(m.episode),try json(m)]
                for (i,x) in v.enumerated() { sqlite3_bind_text(s,Int32(i+1),x,-1,transient) }
                guard sqlite3_step(s) == SQLITE_DONE else { throw HubFailure.message("Import failed; previous catalogue retained.") }
            }
            if parent == nil {
                try write("DELETE FROM media WHERE provider=? AND kind='episode' AND parent NOT IN (SELECT id FROM media WHERE kind='series')",[provider.id])
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }
    func remove(_ id: String) throws {
        try connect(); try exec("BEGIN IMMEDIATE;")
        do {
            try write("DELETE FROM activity WHERE id IN (SELECT id FROM media WHERE provider=?)",[id])
            for table in ["media","epg"] { try write("DELETE FROM \(table) WHERE provider=?",[id]) }
            try write("DELETE FROM providers WHERE id=?",[id]); try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
        HubKeychain.delete(id)
    }
    func categories(provider: String, kind: HubKind) throws -> [String] { try connect(); return try rows("SELECT DISTINCT category FROM media WHERE provider=? AND kind=? ORDER BY category",[provider,kind.rawValue]).map { $0[0] } }
    func page(provider: String = "", kind: HubKind? = nil, category: String = "", search: String = "", collection: String = "", parent: String = "", offset: Int = 0) throws -> HubPage {
        try connect(); var whereSQL = ["1=1"]; var v = [String]()
        if !provider.isEmpty { whereSQL.append("m.provider=?"); v.append(provider) }
        if let kind = kind { whereSQL.append("m.kind=?"); v.append(kind.rawValue) }
        if !category.isEmpty { whereSQL.append("m.category=?"); v.append(category) }
        if !parent.isEmpty { whereSQL.append("m.parent=?"); v.append(parent) }
        if !search.isEmpty { whereSQL.append("instr(lower(m.name),lower(?))>0"); v.append(search) }
        switch collection {
        case "Favorites": whereSQL.append("a.favorite=1")
        case "Continue Watching": whereSQL.append("a.seconds>0 AND a.watched=0 AND m.kind IN ('movie','episode')")
        case "History", "Recently Watched": whereSQL.append("a.date>0")
        default: break
        }
        let order = !parent.isEmpty ? "m.season,m.episode,m.name" : (collection.isEmpty || collection == "Favorites" ? "m.name COLLATE NOCASE,m.id" : "a.date DESC,m.id")
        let raw = try rows("SELECT m.data FROM media m LEFT JOIN activity a ON m.id=a.id WHERE \(whereSQL.joined(separator:" AND ")) ORDER BY \(order) LIMIT 101 OFFSET \(max(0,offset))",v)
        let data = try raw.prefix(100).map { try JSONDecoder().decode(HubMedia.self, from: Data($0[0].utf8)) }
        return HubPage(items:data,hasMore:raw.count>100)
    }
    func progress(_ id: String) throws -> HubProgress {
        try connect(); guard let r = try rows("SELECT seconds,duration,date,watched FROM activity WHERE id=?",[id]).first else { return HubProgress() }
        return HubProgress(seconds:Double(r[0]) ?? 0,duration:Double(r[1]) ?? 0,date:Double(r[2]) ?? 0,watched:r[3] == "1")
    }
    func saveProgress(_ id: String, seconds: Double, duration: Double) throws {
        try connect(); let sec = seconds.isFinite ? max(0,seconds) : 0; let dur = duration.isFinite ? max(0,duration) : 0
        try write("INSERT INTO activity(id,seconds,duration,date,watched) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET seconds=excluded.seconds,duration=excluded.duration,date=excluded.date,watched=excluded.watched",[id,String(sec),String(dur),String(Date().timeIntervalSince1970),(dur>0 && sec/dur>=0.95) ? "1":"0"])
    }
    func favorite(_ id: String) throws -> Bool { try connect(); return try rows("SELECT favorite FROM activity WHERE id=?",[id]).first?[0] == "1" }
    func toggleFavorite(_ id: String) throws { try connect(); try write("INSERT INTO activity(id,favorite) VALUES (?,1) ON CONFLICT(id) DO UPDATE SET favorite=1-favorite",[id]) }
    func clearHistory() throws { try connect(); try exec("UPDATE activity SET seconds=0,duration=0,date=0,watched=0;") }
    func setEPG(_ provider: String, programs: [HubProgram]) throws {
        try connect(); try exec("BEGIN IMMEDIATE;")
        do {
            try write("DELETE FROM epg WHERE provider=?",[provider])
            for p in programs { try Task.checkCancellation(); try write("INSERT INTO epg VALUES (?,?,?,?,?)",[provider,p.channel,p.title,String(p.start),String(p.end)]) }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }
    func nowNext(_ media: HubMedia) throws -> [HubProgram] {
        try connect(); return try rows("SELECT channel,title,start,end FROM epg WHERE provider=? AND channel=? AND end>? ORDER BY start LIMIT 2",[media.provider,media.epgID,String(Date().timeIntervalSince1970)]).map { HubProgram(channel:$0[0],title:$0[1],start:Double($0[2]) ?? 0,end:Double($0[3]) ?? 0) }
    }
}
