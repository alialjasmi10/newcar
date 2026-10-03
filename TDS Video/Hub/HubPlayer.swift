import SwiftUI
import AVKit

@MainActor final class HubPlayback: ObservableObject {
    let player = AVPlayer()
    @Published var failure: String?
    @Published var title = ""
    private var item: HubMedia?
    private var observer: Any?
    private var status: NSKeyValueObservation?
    private var end: NSObjectProtocol?
    private var generation = UUID()
    private var starting: Task<Void,Never>?
    private var lastSave = Date.distantPast
    init() {
        observer = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:1,preferredTimescale:600),queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, Date().timeIntervalSince(self.lastSave) >= 5 else { return }
                self.persist(); self.lastSave = Date()
            }
        }
    }
    func start(_ media: HubMedia) {
        persist(); starting?.cancel(); player.pause(); status = nil
        if let end = end { NotificationCenter.default.removeObserver(end); self.end = nil }
        let token = UUID(); generation = token; item = media; title = media.name; failure = nil
        player.replaceCurrentItem(with:nil)
        starting = Task {
            do {
                let url = try await HubService.shared.playback(media)
                let progress = try await HubDatabase.shared.progress(media.id)
                guard !Task.isCancelled, generation == token else { return }
                try AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                let avItem = AVPlayerItem(url:url)
                status = avItem.observe(\.status,options:[.initial,.new]) { [weak self] observed, _ in
                    let state = observed.status
                    Task { @MainActor [weak self] in
                        guard let self = self, self.generation == token else { return }
                        if state == .failed { self.failure = "This stream could not play. It may be offline, require a different codec, or reject this device." }
                        if state == .readyToPlay {
                            self.status = nil
                            if media.kind != .live && !progress.watched && progress.seconds > 5 {
                                await self.player.seek(to:CMTime(seconds:progress.seconds,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
                            }
                            guard self.generation == token else { return }; self.player.play()
                        }
                    }
                }
                end = NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:avItem,queue:.main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.persist() }
                }
                player.replaceCurrentItem(with:avItem)
            } catch { if generation == token { failure = (error as? HubFailure)?.errorDescription ?? "Unable to open this stream." } }
        }
    }
    func persist() {
        guard let item = item, player.currentItem?.status == .readyToPlay else { return }
        let seconds = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        Task { try? await HubDatabase.shared.saveProgress(item.id,seconds:item.kind == .live ? 0 : seconds,duration:item.kind == .live ? 0 : duration) }
    }
    func skip(_ seconds: Double) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        player.seek(to:CMTime(seconds:max(0,current+seconds),preferredTimescale:600))
    }
    func stop() {
        persist(); starting?.cancel(); generation = UUID(); player.pause(); player.replaceCurrentItem(with:nil); status = nil; item = nil
        if let observer = observer { player.removeTimeObserver(observer); self.observer = nil }
        if let end = end { NotificationCenter.default.removeObserver(end); self.end = nil }
    }
    deinit {
        if let observer = observer { player.removeTimeObserver(observer) }
        if let end = end { NotificationCenter.default.removeObserver(end) }
    }
}
struct HubNativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let fill: Bool
    func makeUIViewController(context:Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController(); vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController,context:Context) { vc.videoGravity = fill ? .resizeAspectFill : .resizeAspect }
}
struct HubPlayerScreen: View {
    let media: HubMedia
    var queue: [HubMedia] = []
    @StateObject private var playback = HubPlayback()
    @State private var selected: HubMedia?
    @State private var fill = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing:12) {
            HStack {
                Button("Done") { dismiss() }
                Spacer(); Text(playback.title).lineLimit(1); Spacer()
                Button { fill.toggle() } label: { Image(systemName:fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
            }.padding(.horizontal)
            HubNativePlayer(player:playback.player,fill:fill)
            if let failure = playback.failure { Text(failure).foregroundStyle(.orange).padding(); Button("Retry") { playback.start(selected ?? media) } }
            HStack(spacing:35) {
                Button { move(-1) } label: { Image(systemName:"backward.end.fill") }.disabled(!canMove(-1))
                Button { playback.skip(-10) } label: { Image(systemName:"gobackward.10") }
                Button { playback.skip(10) } label: { Image(systemName:"goforward.10") }
                Button { move(1) } label: { Image(systemName:"forward.end.fill") }.disabled(!canMove(1))
            }.font(.title2).padding()
        }.background(.black).foregroundStyle(.white)
            .onAppear { selected = media; playback.start(media) }
            .onDisappear { playback.stop() }
            .onChange(of:phase) { _, phase in if phase != .active { playback.persist() } }
    }
    private func index(_ delta: Int) -> Int? {
        guard let i = queue.firstIndex(where: { $0.id == (selected ?? media).id }), queue.indices.contains(i+delta) else { return nil }; return i+delta
    }
    private func canMove(_ d:Int) -> Bool { index(d) != nil }
    private func move(_ d:Int) { if let i = index(d) { selected = queue[i]; playback.start(queue[i]) } }
}

struct HubLocalPlayer: View {
    let selection: HubLocalSelection
    @State private var player = AVPlayer()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            HStack { Button("Done") { dismiss() }; Spacer() }.padding()
            HubNativePlayer(player:player,fill:false)
        }.background(.black).onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.replaceCurrentItem(with:AVPlayerItem(url:selection.url)); player.play()
        }.onDisappear {
            player.pause(); player.replaceCurrentItem(with:nil)
            if selection.scoped { selection.url.stopAccessingSecurityScopedResource() }
            if selection.temporary { try? FileManager.default.removeItem(at:selection.url) }
        }
    }
}
