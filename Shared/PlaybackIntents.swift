import AppIntents

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    func perform() async throws -> some IntentResult {
        #if APP_TARGET
        await MainActor.run { Player.shared.toggle() }
        #endif
        return .result()
    }
}
struct NextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next track"
    func perform() async throws -> some IntentResult {
        #if APP_TARGET
        await MainActor.run { Player.shared.step(1) }
        #endif
        return .result()
    }
}
struct PreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous track"
    func perform() async throws -> some IntentResult {
        #if APP_TARGET
        await MainActor.run { Player.shared.step(-1) }
        #endif
        return .result()
    }
}
