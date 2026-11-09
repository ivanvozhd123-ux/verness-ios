import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import ActivityKit
import AudioToolbox

private func peakLimiter() -> AVAudioUnitEffect {
    AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0))
}

@MainActor
final class Player: ObservableObject {
    static let shared = Player()
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var error: String?
    @Published private(set) var pulse = false
    private var engine = AVAudioEngine()
    private var node = AVAudioPlayerNode()
    private var eq = AVAudioUnitEQ(numberOfBands: 10)
    private var pitch = AVAudioUnitTimePitch()
    private var limiter = peakLimiter()
    private var file: AVAudioFile?
    private var offset: AVAudioFramePosition = 0
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var fillTask: Task<Void, Never>?
    private var pulseGeneration = UUID()
    private var pulseArtists: [String] = []
    private var pulseBatch = 0
    private var history: [String] = []
    private var played: Set<String> = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var interrupted = false
    private var prefs = Preferences()
    private var api = MusicAPI(endpoint: "", token: "")
    private var activity: Activity<NowPlayingAttributes>?
    private var activityStamp = Date.distantPast
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private init() {
        buildGraph()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.interruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let resume = self.playing, at = self.position
                self.buildGraph(); self.applyAudio(); self.prepare(seek: at, autoplay: resume)
            }
        })
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { _ in Task { @MainActor in Player.shared.resume() }; return .success }
        commands.pauseCommand.addTarget { _ in Task { @MainActor in Player.shared.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in Player.shared.toggle() }; return .success }
        commands.nextTrackCommand.addTarget { _ in Task { @MainActor in Player.shared.step(1) }; return .success }
        commands.previousTrackCommand.addTarget { _ in Task { @MainActor in Player.shared.step(-1) }; return .success }
        commands.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in Player.shared.seek(event.positionTime) }; return .success
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func buildGraph() {
        engine.stop()
        engine = AVAudioEngine(); node = AVAudioPlayerNode(); eq = AVAudioUnitEQ(numberOfBands: 10); pitch = AVAudioUnitTimePitch(); limiter = peakLimiter()
        engine.attach(node); engine.attach(pitch); engine.attach(eq); engine.attach(limiter)
        engine.connect(node, to: pitch, format: nil); engine.connect(pitch, to: eq, format: nil)
        engine.connect(eq, to: limiter, format: nil); engine.connect(limiter, to: engine.mainMixerNode, format: nil)
    }
    func configure(_ preferences: Preferences, api: MusicAPI) {
        prefs = preferences; self.api = api; applyAudio()
        if !prefs.liveActivity { endActivity() }
        publish(force: true)
    }
    private func applyAudio() {
        let hz: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        for (i, band) in eq.bands.enumerated() {
            band.filterType = i == 0 ? .lowShelf : i == hz.count - 1 ? .highShelf : .parametric
            band.frequency = min(hz[i], Float((file?.processingFormat.sampleRate ?? 48000) * 0.49)); band.bandwidth = 1
            band.gain = min(12, max(-12, prefs.bands.indices.contains(i) ? prefs.bands[i] : 0)); band.bypass = !prefs.eqEnabled
        }
        let peak = max(0, prefs.bands.max() ?? 0)
        eq.globalGain = prefs.eqEnabled ? (prefs.protect ? min(prefs.preamp, -peak) : prefs.preamp) : 0
        limiter.bypass = !prefs.protect
        pitch.rate = min(2, max(0.5, prefs.speed)); pitch.pitch = 0
        engine.mainMixerNode.outputVolume = min(1, max(0, prefs.volume))
    }
    func play(_ tracks: [Track], at selected: Int) {
        pulse = false; pulseGeneration = UUID(); fillTask?.cancel(); fillTask = nil; prefetch?.cancel()
        queue = tracks; index = min(max(0, selected), max(0, tracks.count - 1)); played = []
        prepare()
    }
    private func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        if !engine.isRunning { try engine.start() }
    }
    private func prepare(seek: Double = 0, autoplay: Bool = true) {
        guard let track = current else { return }
        task?.cancel(); prefetch?.cancel(); generation = UUID(); node.stop(); file = nil
        loading = true; playing = false; error = nil; position = seek; duration = track.duration
        played.insert(track.id); history.append(track.id); history = Array(history.suffix(200))
        publish(force: true)
        let stamp = generation, client = api
        task = Task {
            do {
                let url = try await client.audio(track)
                try Task.checkCancellation()
                guard stamp == generation else { return }
                let audio = try AVAudioFile(forReading: url)
                guard audio.length > 0, audio.length <= Int64(UInt32.max), (1...2).contains(audio.processingFormat.channelCount), (8000...192000).contains(audio.processingFormat.sampleRate) else {
                    throw AppError.message("Unsupported audio format or duration")
                }
                file = audio; duration = Double(audio.length) / audio.processingFormat.sampleRate
                queue[index].duration = duration
                engine.stop()
                engine.disconnectNodeOutput(node); engine.disconnectNodeOutput(pitch); engine.disconnectNodeOutput(eq); engine.disconnectNodeOutput(limiter)
                engine.connect(node, to: pitch, format: audio.processingFormat)
                engine.connect(pitch, to: eq, format: audio.processingFormat)
                engine.connect(eq, to: limiter, format: audio.processingFormat)
                engine.connect(limiter, to: engine.mainMixerNode, format: audio.processingFormat)
                try activate(); applyAudio(); loading = false; schedule(at: seek, play: autoplay)
                loadArtwork(track)
                if pulse && queue.count - index < 8 { fillPulse() }
                prefetchNext()
            } catch is CancellationError {} catch {
                guard stamp == generation else { return }
                loading = false; playing = false; self.error = error.localizedDescription; publish(force: true)
            }
        }
    }
    private func schedule(at seconds: Double, play: Bool) {
        guard let file else { return }
        if play { do { try activate() } catch { self.error = error.localizedDescription; playing = false; return } }
        generation = UUID(); let stamp = generation
        node.stop()
        let frame = AVAudioFramePosition(max(0, min(seconds, max(0, duration - 0.01))) * file.processingFormat.sampleRate)
        offset = frame; position = Double(frame) / file.processingFormat.sampleRate
        let remaining = file.length - frame
        guard remaining > 0 else { return }
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(min(remaining, Int64(UInt32.max))), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == stamp, self.playing else { return }
                self.step(1, automatic: true)
            }
        }
        playing = play
        if play { node.play() }
        publish(force: true)
    }
    func resume() {
        guard !loading else { return }
        if file == nil || error != nil { prepare(seek: position); return }
        if position >= duration - 0.05 { schedule(at: 0, play: true); return }
        do { try activate(); node.play(); playing = true; publish(force: true) } catch { self.error = error.localizedDescription }
    }
    func pause() {
        node.pause(); engine.pause(); playing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        publish(force: true)
    }
    func toggle() {
        if loading {
            generation = UUID(); pulseGeneration = UUID(); task?.cancel(); fillTask?.cancel(); fillTask = nil
            if queue.isEmpty { pulse = false }
            loading = false; playing = false; publish(force: true)
        } else if playing { pause() } else { resume() }
    }
    func seek(_ seconds: Double) { guard file != nil else { return }; schedule(at: seconds, play: playing) }
    func step(_ direction: Int, automatic: Bool = false) {
        guard !queue.isEmpty else { return }
        if direction < 0 && position > 3 { seek(0); return }
        if automatic && prefs.repeatMode == .one { seek(0); return }
        var next: Int?
        if prefs.shuffle && direction > 0 {
            var candidates = queue.indices.filter { !played.contains(queue[$0].id) && $0 != index }
            if candidates.isEmpty && prefs.repeatMode == .all { played = []; candidates = queue.indices.filter { $0 != index } }
            next = candidates.randomElement()
        } else { next = QueueRules.next(index: index, count: queue.count, direction: direction, automatic: automatic, repeatMode: prefs.repeatMode) }
        if let next { index = next; prepare() }
        else if pulse { if index + 1 < queue.count { index += 1; prepare() } else { fillPulse(); if queue.count > 1 { index = 0; prepare() } } }
        else { pause(); if automatic { position = duration; publish(force: true) } }
    }
    func startPulse(_ artists: [String]) {
        guard !artists.isEmpty else { return }
        task?.cancel(); prefetch?.cancel(); fillTask?.cancel(); fillTask = nil; node.stop(); file = nil
        queue = []; index = 0; pulse = true; playing = false; pulseArtists = Array(artists.prefix(40)); pulseBatch = 0
        pulseGeneration = UUID(); loading = true; fillPulse()
    }
    private func fillPulse() {
        guard fillTask == nil, !pulseArtists.isEmpty else { return }
        let stamp = pulseGeneration, name = pulseArtists[pulseBatch % pulseArtists.count], page = pulseBatch / pulseArtists.count % 8, client = api
        fillTask = Task {
            defer { if stamp == pulseGeneration { fillTask = nil } }
            do {
                let result = try await client.search(name + " music", page: page)
                try Task.checkCancellation(); guard pulse, stamp == pulseGeneration else { return }
                pulseBatch += 1
                let upcoming = Set(queue.dropFirst(index).map(\.id))
                var rows = result.tracks.filter { !upcoming.contains($0.id) && !history.suffix(60).contains($0.id) }
                if rows.isEmpty { rows = result.tracks.filter { !upcoming.contains($0.id) } }
                let initial = queue.isEmpty
                queue.append(contentsOf: rows)
                if queue.count > 160 && index > 60 { queue = Array(queue.dropFirst(index)); index = 0 }
                if initial && !queue.isEmpty { index = 0; prepare() }
                else if initial { loading = false; error = "No tracks found for this artist" }
            } catch is CancellationError {} catch { if stamp == pulseGeneration { loading = false; self.error = error.localizedDescription } }
        }
    }
    private func prefetchNext() {
        guard index + 1 < queue.count else { return }
        let next = queue[index + 1], client = api
        prefetch = Task { _ = try? await client.audio(next) }
    }
    private func tick() {
        if playing, let file, let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) {
            position = min(duration, Double(offset) / file.processingFormat.sampleRate + Double(time.sampleTime) / max(1, time.sampleRate))
            publish(force: false)
        }
    }
    private func interruption(_ note: Notification) {
        let kind = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
        if kind == AVAudioSession.InterruptionType.began.rawValue { interrupted = playing; pause() }
        else {
            let options = AVAudioSession.InterruptionOptions(rawValue: (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            if interrupted && options.contains(.shouldResume) { resume() }; interrupted = false
        }
    }
    private func loadArtwork(_ track: Track) {
        artworkTask?.cancel(); artwork = nil
        artworkTask = Task {
            var image: UIImage?
            if let cover = track.cover {
                if let url = URL(string: cover), url.scheme == "https" {
                    if let (bytes, _) = try? await URLSession.shared.data(from: url), bytes.count < 5_000_000 { image = UIImage(data: bytes) }
                } else if let url = try? Files.local(cover) { image = UIImage(contentsOfFile: url.path) }
            }
            guard !Task.isCancelled, current?.id == track.id else { return }
            if let image = image ?? UIImage(named: "Clover") { artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
            publish(force: true)
        }
    }
    private func publish(force: Bool) {
        guard let track = current else { return }
        if force || Date().timeIntervalSince(activityStamp) > 15 {
            var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
                MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
                MPNowPlayingInfoPropertyPlaybackRate: playing ? prefs.speed : 0]
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            updateActivity(track); activityStamp = Date()
        }
    }
    func showActivity() { if let track = current { updateActivity(track, create: true) } }
    func updateMetadata(_ track: Track) {
        for i in queue.indices where queue[i].id == track.id { queue[i].title = track.title; queue[i].artist = track.artist; queue[i].cover = track.cover }
        if current?.id == track.id { loadArtwork(track); publish(force: true) }
    }
    private func updateActivity(_ track: Track, create: Bool = false) {
        guard prefs.liveActivity else { return }
        let state = NowPlayingAttributes.ContentState(title: String(track.title.prefix(150)), artist: String(track.artist.prefix(100)), playing: playing,
            position: position, duration: duration, rate: Double(prefs.speed), date: Date(), accent: prefs.accent)
        if let activity { Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(90))) } }
        else if (create || playing) && ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(attributes: NowPlayingAttributes(), content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(90)), pushType: nil)
        }
    }
    private func endActivity() {
        if let activity { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
        activity = nil
    }
}
