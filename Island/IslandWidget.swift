import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

@main
struct VernessWidgets: WidgetBundle {
    var body: some Widget { VernessActivity() }
}

struct VernessActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            HStack(spacing: 16) {
                Image("Clover").resizable().scaledToFit().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                    Text(context.state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    progress(context.state)
                }
                Button(intent: TogglePlaybackIntent()) { Image(systemName: context.state.playing ? "pause.fill" : "play.fill").frame(width: 28, height: 32) }.tint(.green)
            }.padding(18).activityBackgroundTint(.black.opacity(0.9)).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image("Clover").resizable().scaledToFit().frame(width: 45, height: 45).padding(.leading, 8) }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: TogglePlaybackIntent()) { Image(systemName: context.state.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 40, height: 40) }.tint(.green)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.horizontal, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        progress(context.state)
                        HStack(spacing: 55) {
                            Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.end.fill") }
                            Link(destination: URL(string: "verness://player")!) { Text("verness").font(.caption.bold()) }
                            Button(intent: NextTrackIntent()) { Image(systemName: "forward.end.fill") }
                        }.tint(.green)
                    }.padding(.horizontal, 15).padding(.bottom, 8)
                }
            } compactLeading: {
                Image("Clover").resizable().scaledToFit().frame(width: 24, height: 24)
            } compactTrailing: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill").foregroundStyle(.green)
            } minimal: {
                Image("Clover").resizable().scaledToFit().frame(width: 22, height: 22)
            }.widgetURL(URL(string: "verness://player")).keylineTint(.green)
        }
    }
    @ViewBuilder private func progress(_ state: NowPlayingAttributes.ContentState) -> some View {
        if state.playing { ProgressView(timerInterval: state.interval, countsDown: false).labelsHidden().tint(.green) }
        else { ProgressView(value: state.position, total: max(1, state.duration)).tint(.green) }
    }
}
