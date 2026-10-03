import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct HubRootView: View {
    @StateObject private var store = HubStore()
    var body: some View {
        TabView {
            NavigationStack { HubHome() }.tabItem { Label("Home",systemImage:"square.grid.2x2.fill") }
            NavigationStack { HubLibrary() }.tabItem { Label("IPTV",systemImage:"play.tv.fill") }
            NavigationStack { HubBrowser() }.tabItem { Label("Browser",systemImage:"globe") }
            NavigationStack { HubCarMode() }.tabItem { Label("Car Mode",systemImage:"car.fill") }
            NavigationStack { HubSettings() }.tabItem { Label("Settings",systemImage:"gearshape.fill") }
        }.tint(.cyan).preferredColorScheme(.dark).environmentObject(store)
            .task { await store.bootstrap() }
            .alert("CarCast Hub",isPresented:Binding(get:{ store.error != nil },set:{ if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
            .safeAreaInset(edge:.top) {
                if store.busy { HStack { ProgressView(); Text(store.status).font(.caption); Spacer(); Button("Cancel") { store.cancel() } }.padding(10).background(.ultraThinMaterial) }
            }
    }
}
struct HubHome: View {
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                VStack(alignment:.leading,spacing:12) {
                    Text("YOUR MEDIA. ONE PLACE.").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.cyan)
                    Text("CarCast Hub").font(.largeTitle.bold())
                    Text("Live channels, your library and the open web.").foregroundStyle(.secondary)
                    NavigationLink { HubProviders() } label: { Label("Add your provider",systemImage:"plus.circle.fill").font(.headline).padding(12).background(.cyan.opacity(0.15),in:Capsule()) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(24).background(LinearGradient(colors:[Color.blue.opacity(0.32),Color.indigo.opacity(0.12)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:24))
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:14) {
                    NavigationLink { HubLibrary() } label: { HubTile(name:"Live & on demand",icon:"play.tv.fill",subtitle:"IPTV library") }
                    NavigationLink { HubLocalMedia() } label: { HubTile(name:"Local Media",icon:"folder.fill",subtitle:"Files & Photos") }
                    NavigationLink { HubLibrary(collection:"Continue Watching") } label: { HubTile(name:"Continue Watching",icon:"play.circle.fill",subtitle:"Pick up where you left") }
                    NavigationLink { HubLibrary(collection:"Favorites") } label: { HubTile(name:"Favorites",icon:"heart.fill",subtitle:"Your saved collection") }
                    NavigationLink { HubLibrary(collection:"Recently Watched") } label: { HubTile(name:"Recently Watched",icon:"clock.fill",subtitle:"Recent plays") }
                    NavigationLink { HubLibrary(collection:"History") } label: { HubTile(name:"History",icon:"list.bullet",subtitle:"Viewing history") }
                }.buttonStyle(.plain)
            }.padding()
        }.navigationTitle("Home").navigationBarTitleDisplayMode(.inline)
    }
}
struct HubTile: View {
    let name: String; let icon: String; let subtitle: String
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Image(systemName:icon).font(.title2).foregroundStyle(.cyan)
            Text(name).font(.headline).foregroundStyle(.primary)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,minHeight:130,alignment:.leading).padding(16).background(Color.white.opacity(0.055),in:RoundedRectangle(cornerRadius:20))
    }
}
struct HubPoster: View {
    let url: String
    var body: some View {
        AsyncImage(url:URL(string:url)) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName:"play.rectangle.fill").foregroundStyle(.cyan.opacity(0.6)) }
            .frame(width:64,height:76).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:8)).clipShape(RoundedRectangle(cornerRadius:8))
    }
}
struct HubLibrary: View {
    var collection = ""
    @EnvironmentObject private var store: HubStore
    @State private var provider = ""
    @State private var kind: HubKind = .live
    @State private var category = ""
    @State private var categories = [String]()
    @State private var search = ""
    @State private var items = [HubMedia]()
    @State private var more = false
    @State private var loading = false
    @State private var pageTask: Task<Void,Never>?
    @State private var epoch = UUID()
    private var query: String { [provider,kind.rawValue,category,search,collection,String(store.revision)].joined(separator:"|") }
    var body: some View {
        List {
            if collection.isEmpty {
                Section {
                    Picker("Provider",selection:$provider) { Text("All providers").tag(""); ForEach(store.providers) { Text($0.name).tag($0.id) } }
                    Picker("Library",selection:$kind) { Text("Live TV").tag(HubKind.live); Text("Movies").tag(HubKind.movie); Text("Series").tag(HubKind.series) }.pickerStyle(.segmented)
                    if !categories.isEmpty { Picker("Category",selection:$category) { Text("All categories").tag(""); ForEach(categories,id:\.self) { Text($0).tag($0) } } }
                }
            }
            ForEach(items) { media in
                NavigationLink { HubDetail(media:media,queue:items.filter { $0.kind != .series }) } label: {
                    HStack(spacing:14) { HubPoster(url:media.image); VStack(alignment:.leading,spacing:6) { Text(media.name).font(.headline).lineLimit(2); Text(media.category).font(.caption).foregroundStyle(.secondary) } }
                }.swipeActions { Button { Task { do { try await HubDatabase.shared.toggleFavorite(media.id); store.revision += 1 } catch { store.fail(error) } } } label: { Label("Favorite",systemImage:"heart") }.tint(.pink) }
            }
            if loading { ProgressView().frame(maxWidth:.infinity) }
            if more && !loading { Button("Load more") { nextPage() }.frame(maxWidth:.infinity) }
            if items.isEmpty && !loading {
                ContentUnavailableView(store.providers.isEmpty ? "Add a provider" : "No matching titles",systemImage:"play.tv",description:Text("Import an M3U playlist or connect an Xtream provider in Settings."))
            }
        }.navigationTitle(collection.isEmpty ? "IPTV" : collection).searchable(text:$search,prompt:"Search titles")
            .toolbar { NavigationLink { HubProviders() } label: { Image(systemName:"plus") } }
            .onChange(of:provider) { _,_ in category = "" }
            .onChange(of:kind) { _,_ in category = "" }
            .task(id:query) {
                pageTask?.cancel(); let token = UUID(); epoch = token; loading = true
                do {
                    try await Task.sleep(nanoseconds:250_000_000)
                    let cat = provider.isEmpty ? [] : try await HubDatabase.shared.categories(provider:provider,kind:kind)
                    let page = try await HubDatabase.shared.page(provider:provider,kind:collection.isEmpty ? kind : nil,category:category,search:search,collection:collection)
                    try Task.checkCancellation(); guard token == epoch else { return }
                    categories = cat; items = page.items; more = page.hasMore; loading = false
                } catch is CancellationError {} catch { loading = false; store.fail(error) }
            }
            .onDisappear { pageTask?.cancel() }
    }
    private func nextPage() {
        guard !loading else { return }; loading = true; let token = epoch
        pageTask = Task {
            do {
                let p = try await HubDatabase.shared.page(provider:provider,kind:collection.isEmpty ? kind : nil,category:category,search:search,collection:collection,offset:items.count)
                try Task.checkCancellation(); guard token == epoch else { return }
                items.append(contentsOf:p.items); more = p.hasMore; loading = false
            } catch is CancellationError {} catch { loading = false; store.fail(error) }
        }
    }
}
struct HubDetail: View {
    let media: HubMedia
    var queue: [HubMedia] = []
    @EnvironmentObject private var store: HubStore
    @State private var detail: HubMedia?
    @State private var favorite = false
    @State private var progress = HubProgress()
    @State private var programs = [HubProgram]()
    @State private var play = false
    @State private var episodes = [HubMedia]()
    @State private var loading = false
    @State private var season = 0
    private var current: HubMedia { detail ?? media }
    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    var body: some View {
        List {
            Section {
                HStack(alignment:.top,spacing:18) {
                    HubPoster(url:media.image)
                    VStack(alignment:.leading,spacing:8) { Text(media.name).font(.title2.bold()); Text([current.year,current.runtime,current.rating.isEmpty ? "" : "★ " + current.rating].filter { !$0.isEmpty }.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
                }
                if !current.detail.isEmpty { Text(current.detail).font(.subheadline).foregroundStyle(.secondary) }
                Button { Task { do { try await HubDatabase.shared.toggleFavorite(media.id); favorite.toggle(); store.revision += 1 } catch { store.fail(error) } } } label: { Label(favorite ? "Remove favorite" : "Add favorite",systemImage:favorite ? "heart.fill" : "heart") }
                if media.kind != .series {
                    Button { play = true } label: { Label(progress.seconds > 5 && !progress.watched && media.kind != .live ? "Resume · \(Int(progress.seconds / 60)) min" : "Play",systemImage:"play.fill").font(.headline) }
                    Button { Task {
                        do {
                            guard let route = TDSVideoShared.shared.CarPlayComp else { throw HubFailure.message("Connect a compatible CarPlay session first. This route uses the preserved experimental TDS integration.") }
                            let url = try await HubService.shared.playback(current)
                            route(.init(type:.video, URL:url))
                        } catch { store.fail(error) }
                    } } label: { Label("Send to TDS car player",systemImage:"car") }
                    if progress.duration > 0 { ProgressView(value:min(1,progress.seconds/progress.duration)); if progress.watched { Label("Watched",systemImage:"checkmark.circle.fill").foregroundStyle(.green) } }
                }
            }
            if !programs.isEmpty {
                Section("Programme guide") {
                    ForEach(Array(programs.enumerated()),id:\.offset) { _, p in
                        VStack(alignment:.leading) { Text(p.title); Text("\(Date(timeIntervalSince1970:p.start),style:.time) – \(Date(timeIntervalSince1970:p.end),style:.time)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if media.kind == .series {
                Section("Seasons & episodes") {
                    if loading { ProgressView("Loading episodes…") }
                    if !seasons.isEmpty { Picker("Season",selection:$season) { ForEach(seasons,id:\.self) { Text("Season \($0)").tag($0) } } }
                    ForEach(episodes.filter { $0.season == season }) { episode in
                        NavigationLink { HubDetail(media:episode,queue:episodes) } label: { HubEpisodeRow(media:episode) }
                    }
                    Button("Refresh episodes") { Task { await loadEpisodes(refresh:true) } }.disabled(loading)
                }
            }
        }.navigationTitle(media.kind == .series ? "Series" : "Details").navigationBarTitleDisplayMode(.inline)
            .task {
                do {
                    favorite = try await HubDatabase.shared.favorite(media.id); progress = try await HubDatabase.shared.progress(media.id)
                    if media.kind == .live { programs = try await HubDatabase.shared.nowNext(media) }
                    if media.kind == .movie && media.url.isEmpty { detail = try await HubService.shared.movieDetails(media,secret:HubKeychain.read(media.provider)) }
                    if media.kind == .series { await loadEpisodes(refresh:false) }
                } catch { store.fail(error) }
            }
            .fullScreenCover(isPresented:$play,onDismiss:{ Task { progress = (try? await HubDatabase.shared.progress(media.id)) ?? HubProgress(); store.revision += 1 } }) { HubPlayerScreen(media:current,queue:queue) }
    }
    private func loadEpisodes(refresh:Bool) async {
        loading = true; defer { loading = false }
        do {
            let cached = try await HubDatabase.shared.page(parent:media.id)
            if refresh || cached.items.isEmpty {
                if let p = store.providers.first(where: { $0.id == media.provider }), p.type == "xtream" {
                    let list = try await HubService.shared.episodes(media,secret:HubKeychain.read(p.id))
                    try await HubDatabase.shared.replace(p,items:list,parent:media.id)
                }
            }
            var all = [HubMedia](); var hasMore = true
            while hasMore { try Task.checkCancellation(); let page = try await HubDatabase.shared.page(parent:media.id,offset:all.count); all.append(contentsOf:page.items); hasMore = page.hasMore }
            episodes = all; if !seasons.contains(season) { season = seasons.first ?? 0 }
        } catch { store.fail(error) }
    }
}
struct HubEpisodeRow: View {
    let media: HubMedia
    @State private var progress = HubProgress()
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack { Text("\(media.episode). \(media.name)"); Spacer(); if progress.watched { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) } }
            if progress.duration > 0 { ProgressView(value:min(1,progress.seconds/progress.duration)) }
        }.task { progress = (try? await HubDatabase.shared.progress(media.id)) ?? HubProgress() }
    }
}
struct HubProviders: View {
    @EnvironmentObject private var store: HubStore
    @State private var add = false
    @State private var importing = false
    @State private var deleting: HubProvider?
    var body: some View {
        List {
            Section {
                Button { add = true } label: { Label("Connect provider / playlist URL",systemImage:"plus.circle.fill") }
                Button { importing = true } label: { Label("Import M3U file",systemImage:"doc.badge.plus") }
            }.disabled(store.busy)
            ForEach(store.providers) { p in
                Section(p.name) {
                    Text(p.type == "xtream" ? "Xtream Codes" : "M3U playlist").foregroundStyle(.secondary)
                    if p.type != "file" { Button("Refresh catalogue") { store.refresh(p) }; Button("Update XMLTV guide") { store.epg(p) } }
                    Button("Remove provider",role:.destructive) { deleting = p }
                }.disabled(store.busy)
            }
        }.navigationTitle("Providers")
            .sheet(isPresented:$add) { HubAddProvider() }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.data,.text],allowsMultipleSelection:false) { result in
                do { if let url = try result.get().first { store.addFile(url) } } catch { store.fail(error) }
            }
            .confirmationDialog("Remove this provider and its viewing history?",isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting = nil } }),titleVisibility:.visible) { Button("Remove",role:.destructive) { if let p = deleting { store.remove(p) }; deleting = nil } }
    }
}
struct HubAddProvider: View {
    @EnvironmentObject private var store: HubStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "xtream"
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var epg = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    TextField("Name",text:$name)
                    Picker("Type",selection:$type) { Text("Xtream Codes").tag("xtream"); Text("M3U URL").tag("m3u") }
                    TextField(type == "xtream" ? "https://server.example:port" : "Playlist URL",text:$server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if type == "xtream" { TextField("Username",text:$username).textInputAutocapitalization(.never).autocorrectionDisabled(); SecureField("Password",text:$password) }
                }
                Section("Programme guide") { TextField("XMLTV URL (optional)",text:$epg).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled(); Text("Xtream uses the provider's XMLTV endpoint if left empty. Plain XML feeds up to 64 MB are supported.").font(.caption).foregroundStyle(.secondary) }
                Section { Text("Use content you are authorized to watch. HTTPS protects your login in transit; HTTP providers send it without encryption.").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("Add provider").toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Import") {
                    do {
                        _ = try hubWebURL(server); if !epg.isEmpty { _ = try hubWebURL(epg) }
                        store.add(name:name.trimmingCharacters(in:.whitespacesAndNewlines),type:type,secret:HubSecret(server:server.trimmingCharacters(in:.whitespacesAndNewlines),username:username,password:password,epg:epg)); dismiss()
                    } catch { store.fail(error) }
                }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || server.isEmpty || (type == "xtream" && (username.isEmpty || password.isEmpty))) }
            }
        }
    }
}
struct HubSettings: View {
    @EnvironmentObject private var store: HubStore
    @State private var clear = false
    var body: some View {
        List {
            Section("Library") { NavigationLink("Playlists / Providers") { HubProviders() }; Button("Clear viewing history",role:.destructive) { clear = true } }
            Section("TDS integration") { NavigationLink("Original TDS settings") { AppSettingsView() }; NavigationLink("Original TDS workspace") { MainView() } }
            Section("About") { Text("CarCast Hub · Integration preview 0.1"); Text("Video service support depends on the service, DRM, OS and output route. A successful web page load does not prove protected playback works.").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("Settings").confirmationDialog("Clear history and resume positions? Favorites are kept.",isPresented:$clear,titleVisibility:.visible) { Button("Clear history",role:.destructive) { store.run("Clearing history…") { try await HubDatabase.shared.clearHistory() } } }
    }
}
struct HubCarMode: View {
    var body: some View {
        List {
            Section { Text("Car Mode").font(.largeTitle.bold()); Text("Use video features while parked. Availability depends on the car, iOS version and signing entitlements.").foregroundStyle(.secondary) }
            Section("Preserved TDS tools") {
                NavigationLink("Open TDS workspace") { MainView() }
                NavigationLink("Screen mirroring") { ScreenMirroringView() }
                NavigationLink("Mirroring settings") { ScreenMirroingSettings() }
                NavigationLink("HTTP media server") { WebServerPage() }
                NavigationLink("Car browser controls") { WebViewButtons() }
            }
            Section("Compatibility") { Text("This source includes private/unsupported CarPlay techniques. Building an unsigned IPA does not grant CarPlay permissions or guarantee installation on a stock iPhone."); Text("AVPlayer's AirPlay button uses supported output routes. ReplayKit cannot be assumed to capture protected video.") }.font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("Car Mode").navigationBarTitleDisplayMode(.inline)
    }
}
struct HubMovieTransfer: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType:.movie) { movie in SentTransferredFile(movie.url) } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CarCastHubLocal",isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let target = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at:received.file,to:target); return HubMovieTransfer(url:target)
        }
    }
}
struct HubLocalMedia: View {
    @EnvironmentObject private var store: HubStore
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var url = ""
    @State private var selection: HubLocalSelection?
    var body: some View {
        List {
            Section {
                Button("Open video from Files") { importing = true }
                PhotosPicker("Choose video from Photos",selection:$photo,matching:.videos)
            }
            Section("Stream URL") { TextField("https://…",text:$url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled(); Button("Play URL") { do { selection = HubLocalSelection(url:try hubWebURL(url),scoped:false,temporary:false) } catch { store.fail(error) } } }
            Section { Text("The original TDS Share and Broadcast extensions remain in the project. Installing them requires compatible signing.").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("Local Media")
            .fileImporter(isPresented:$importing,allowedContentTypes:[.movie,.video,.audiovisualContent],allowsMultipleSelection:false) { result in
                do { if let u = try result.get().first { let access = u.startAccessingSecurityScopedResource(); selection = HubLocalSelection(url:u,scoped:access,temporary:false) } } catch { store.fail(error) }
            }
            .task(id:photo) { do { if let value = try await photo?.loadTransferable(type:HubMovieTransfer.self) { selection = HubLocalSelection(url:value.url,scoped:false,temporary:true) } } catch { store.fail(error) } }
            .fullScreenCover(item:$selection) { s in HubLocalPlayer(selection:s) }
    }
}
struct HubLocalSelection: Identifiable { let id = UUID(); let url: URL; let scoped: Bool; let temporary: Bool }
