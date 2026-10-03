import SwiftUI

@MainActor final class HubStore: ObservableObject {
    @Published var providers: [HubProvider] = []
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var revision = 0
    private var operation: Task<Void,Never>?
    func bootstrap() async {
        do { providers = try await HubDatabase.shared.providers() }
        catch { self.error = "Could not open the saved library." }
    }
    func fail(_ error: Error) {
        if error is CancellationError { status = "Cancelled"; return }
        // Never render NSError userInfo/URLs, which can contain Xtream credentials.
        self.error = (error as? HubFailure)?.errorDescription ?? "The operation could not be completed. Your existing library is retained."
    }
    func cancel() { operation?.cancel() }
    func run(_ label: String, action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; status = label
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action(); await bootstrap(); revision += 1; status = "Completed" }
            catch { fail(error) }
        }
    }
    func add(name: String, type: String, secret: HubSecret) {
        let provider = HubProvider(name:name,type:type)
        run("Importing catalogue…") {
            let items = try await HubService.shared.catalogue(provider,secret:secret)
            try Task.checkCancellation()
            try HubKeychain.save(secret,id:provider.id)
            do { try await HubDatabase.shared.replace(provider,items:items) }
            catch { HubKeychain.delete(provider.id); throw error }
        }
    }
    func addFile(_ url: URL) {
        let p = HubProvider(name:url.deletingPathExtension().lastPathComponent,type:"file")
        run("Reading playlist…") {
            let items = try await Task.detached(priority:.userInitiated) {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size <= 64 * 1024 * 1024 else { throw HubFailure.message("Playlist exceeds 64 MB.") }
                let data = try Data(contentsOf:url)
                return try HubM3U.parse(data,provider:p.id,base:nil)
            }.value
            try Task.checkCancellation(); try await HubDatabase.shared.replace(p,items:items)
        }
    }
    func refresh(_ p: HubProvider) {
        run("Refreshing \(p.name)…") {
            let secret = try HubKeychain.read(p.id)
            let items = try await HubService.shared.catalogue(p,secret:secret)
            try Task.checkCancellation(); try await HubDatabase.shared.replace(p,items:items)
        }
    }
    func epg(_ p: HubProvider) {
        run("Updating programme guide…") {
            let programs = try await HubService.shared.epg(p,secret:HubKeychain.read(p.id))
            try Task.checkCancellation(); try await HubDatabase.shared.setEPG(p.id,programs:programs)
        }
    }
    func remove(_ p: HubProvider) { run("Removing provider…") { try await HubDatabase.shared.remove(p.id) } }
}
