import SwiftUI
import WebKit

struct HubWebEntry: Codable, Identifiable { var id: String; var url: String; var title: String; var date: Double }
actor HubWebLibrary {
    static let shared = HubWebLibrary()
    private func location(_ name:String) throws -> URL {
        let dir = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("CarCastHub",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return dir.appendingPathComponent(name + ".json")
    }
    func list(_ name:String) throws -> [HubWebEntry] {
        let url = try location(name)
        guard FileManager.default.fileExists(atPath:url.path) else { return [] }
        return try JSONDecoder().decode([HubWebEntry].self,from:Data(contentsOf:url))
    }
    func add(_ name:String,url:URL,title:String) throws {
        guard ["https","http"].contains(url.scheme ?? "") else { return }
        var entries = try list(name); entries.removeAll { $0.url == url.absoluteString }
        entries.insert(HubWebEntry(id:hubID(url.absoluteString),url:url.absoluteString,title:title,date:Date().timeIntervalSince1970),at:0)
        // Bounded browser history; the IPTV database is independent.
        let data = try JSONEncoder().encode(Array(entries.prefix(500)))
        try data.write(to:location(name),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ name:String,id:String) throws { let data = try JSONEncoder().encode(list(name).filter { $0.id != id }); try data.write(to:location(name),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]) }
}
@MainActor final class HubWebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    @Published var address = "https://www.youtube.com"
    @Published var problem: String?
    @Published var title = "Browser"
    @Published var back = false
    @Published var forward = false
    @Published var loading = false
    private var loadingObservation: NSKeyValueObservation?
    override init() {
        let config = WKWebViewConfiguration(); config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true; config.allowsPictureInPictureMediaPlayback = true
        web = WKWebView(frame:.zero,configuration:config)
        super.init(); web.navigationDelegate = self; web.uiDelegate = self; web.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) { web.isInspectable = true }
        loadingObservation = web.observe(\.isLoading,options:[.new]) { [weak self] view,_ in
            let value = view.isLoading
            Task { @MainActor [weak self] in self?.loading = value }
        }
    }
    func open(_ text:String? = nil) {
        do { let url = try hubWebURL(text ?? address); address = url.absoluteString; web.load(URLRequest(url:url)); problem = nil }
        catch { problem = "Enter a complete http/https address." }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        address = webView.url?.absoluteString ?? address; title = webView.title ?? "Browser"
        back = webView.canGoBack; forward = webView.canGoForward
        if let url = webView.url { let title = title; Task { try? await HubWebLibrary.shared.add("history",url:url,title:title) } }
    }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { showFailure(error) }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { showFailure(error) }
    private func showFailure(_ error:Error) { if (error as NSError).code != NSURLErrorCancelled { problem = "This page could not load. Check your connection or try the service's own app." } }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if ["http","https","about","blob"].contains(url.scheme ?? "") { decisionHandler(.allow) }
        else { problem = "The site is requesting its own app. Open that app directly to continue."; decisionHandler(.cancel) }
    }
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for navigationAction:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }; return nil
    }
    func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping ()->Void) { problem = message; completionHandler() }
}
struct HubWebCanvas: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context:Context)->WKWebView { web }
    func updateUIView(_ view:WKWebView,context:Context) {}
}
struct HubBrowser: View {
    @StateObject private var model = HubWebModel()
    @State private var list: String?
    @State private var entries = [HubWebEntry]()
    @State private var showList = false
    var body: some View {
        VStack(spacing:8) {
            HStack {
                TextField("https://…",text:$model.address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).onSubmit { model.open() }
                Button { model.open() } label: { Image(systemName:"arrow.right.circle.fill").font(.title2) }
            }.padding(.horizontal)
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:20) {
                    ForEach([("YouTube","https://www.youtube.com"),("Netflix","https://www.netflix.com"),("TOD","https://www.tod.tv"),("STARZPLAY","https://starzplay.com")],id:\.0) { title,url in Button(title) { model.open(url) }.font(.subheadline.weight(.semibold)) }
                }.padding(.horizontal)
            }
            if model.loading { ProgressView().controlSize(.small) }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            HubWebCanvas(web:model.web)
            HStack(spacing:30) {
                Button { model.web.goBack() } label: { Image(systemName:"chevron.left") }.disabled(!model.back)
                Button { model.web.goForward() } label: { Image(systemName:"chevron.right") }.disabled(!model.forward)
                Button { model.web.reload() } label: { Image(systemName:"arrow.clockwise") }
                Menu {
                    Button("Save bookmark") { if let url = model.web.url { Task { try? await HubWebLibrary.shared.add("bookmarks",url:url,title:model.title) } } }
                    Button("Bookmarks") { load("bookmarks") }
                    Button("History") { load("history") }
                } label: { Image(systemName:"book") }
            }.font(.title3).padding(10)
        }.navigationTitle("Browser").navigationBarTitleDisplayMode(.inline)
            .task { if model.web.url == nil { model.open() } }
            .sheet(isPresented:$showList) {
                NavigationStack {
                    List {
                        ForEach(entries) { entry in
                            Button { model.open(entry.url); showList = false } label: { Text(entry.title.isEmpty ? URL(string:entry.url)?.host ?? "Page" : entry.title).lineLimit(2) }
                        }.onDelete { offsets in
                            let deleting = offsets.map { entries[$0].id }; entries.remove(atOffsets:offsets)
                            if let list = list { Task { for id in deleting { try? await HubWebLibrary.shared.remove(list,id:id) } } }
                        }
                    }.navigationTitle(list == "bookmarks" ? "Bookmarks" : "History").toolbar { Button("Done") { showList = false } }
                }
            }
    }
    private func load(_ name:String) { Task { entries = (try? await HubWebLibrary.shared.list(name)) ?? []; list = name; showList = true } }
}
