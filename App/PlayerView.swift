import SwiftUI

@MainActor
struct PlayerView: View {
    @EnvironmentObject private var store: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = Player.shared
    @State private var queue = false
    @State private var seek: Double = 0
    @State private var scrubbing = false
    var body: some View {
        NavigationStack {
            ScrollView {
                if let track = player.current {
                    VStack(spacing: 22) {
                        Artwork(track: track, size: min(UIScreen.main.bounds.width - 80, 340)).shadow(color: .black.opacity(0.2), radius: 25, y: 15)
                        VStack(spacing: 10) { Text(track.title).font(.title2.bold()).multilineTextAlignment(.center); Text(track.artist).font(.subheadline).foregroundStyle(.secondary) }
                        VStack(spacing: 6) {
                            Slider(value: Binding(get: { scrubbing ? seek : player.position }, set: { seek = $0 }), in: 0...max(1, player.duration)) { editing in
                                scrubbing = editing
                                if !editing { player.seek(seek) }
                            }.disabled(player.loading)
                            HStack { Text(clock(scrubbing ? seek : player.position)); Spacer(); Text(clock(player.duration)) }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button { store.update { $0.shuffle.toggle() } } label: { Image(systemName: "shuffle").frame(width: 40, height: 44) }.foregroundStyle(store.prefs.shuffle ? store.accent : Color.secondary).accessibilityLabel(store.t("Случайный порядок"))
                            Spacer()
                            Button { player.step(-1) } label: { Image(systemName: "backward.end.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel(store.t("Предыдущий"))
                            Spacer()
                            Button { player.toggle() } label: { Group { if player.loading { ProgressView().tint(.black) } else { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title) } }.frame(width: 70, height: 70).background(store.accent, in: Circle()).foregroundStyle(.black) }.accessibilityLabel(store.t(player.playing ? "Пауза" : "Слушать"))
                            Spacer()
                            Button { player.step(1) } label: { Image(systemName: "forward.end.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel(store.t("Следующий"))
                            Spacer()
                            Button {
                                store.update { value in value.repeatMode = value.repeatMode == .off ? .all : value.repeatMode == .all ? .one : .off }
                            } label: { Image(systemName: store.prefs.repeatMode == .one ? "repeat.1" : "repeat").frame(width: 40, height: 44) }.foregroundStyle(store.prefs.repeatMode == .off ? Color.secondary : store.accent).accessibilityLabel(store.t("Повтор"))
                        }
                        if player.loading { Text(store.t("Подготовка трека…")).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button { store.favorite(track) } label: { Image(systemName: store.data.favorites.contains(track.id) ? "heart.fill" : "heart") }.accessibilityLabel(store.t("Любимые треки"))
                            Spacer()
                            Button { queue = true } label: { Label(store.t("Очередь"), systemImage: "text.line.first.and.arrowtriangle.forward") }
                            Spacer()
                            Button { store.remember(track) } label: { Image(systemName: "plus") }.accessibilityLabel(store.t("Сохранить"))
                        }.font(.subheadline).padding(.vertical, 8)
                        HStack { Text(store.t("Скорость")).font(.caption); Slider(value: Binding(get: { Double(store.prefs.speed) }, set: { v in store.update { $0.speed = Float(v) } }), in: 0.5...2, step: 0.05); Text(String(format: "%.2g×", store.prefs.speed)).font(.caption.monospacedDigit()).frame(width: 42) }
                        HStack { Image(systemName: "speaker.wave.1"); Slider(value: Binding(get: { Double(store.prefs.volume) }, set: { v in store.update { $0.volume = Float(v) } }), in: 0...1); Image(systemName: "speaker.wave.3") }.foregroundStyle(.secondary).accessibilityLabel(store.t("Громкость"))
                        Button { player.showActivity() } label: { Label(store.t("Показать Island"), systemImage: "capsule.portrait") }.buttonStyle(.bordered)
                        Text(store.t("Нужен совместимый iPhone и разрешение Live Activities.")).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        LyricsView(track: track)
                    }.padding(25)
                } else { EmptyState() }
            }.navigationTitle("verness").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel(store.t("Закрыть")) } }
                .sheet(isPresented: $queue) { NavigationStack { ScrollView { TrackRows(tracks: Array(player.queue.dropFirst(player.index))).padding(22) }.navigationTitle(store.t("Сейчас и далее")).toolbar { Button(store.t("Закрыть")) { queue = false } } } }
        }.presentationDragIndicator(.visible)
    }
}

@MainActor
struct LyricsView: View {
    var track: Track
    @EnvironmentObject private var store: AppModel
    @ObservedObject private var player = Player.shared
    @State private var rows: [LyricLine] = []
    @State private var message = ""
    @State private var busy = false
    @State private var following = true
    private var active: Int? { rows.last(where: { ($0.time ?? .infinity) <= player.position })?.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Lyrics").font(.title2.bold()); Spacer(); Text("LRCLIB").font(.caption2).foregroundStyle(.secondary) }
            if busy { ProgressView() }
            else if rows.isEmpty { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            else {
                if !following && rows.contains(where: { $0.time != nil }) { Button(store.t("Вернуться к строке")) { following = true }.font(.caption) }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 25) {
                            ForEach(rows) { row in
                                Button { if let time = row.time { player.seek(time) } } label: { Text(row.text.isEmpty ? "♪" : row.text).font(.system(size: 25, weight: .semibold)).multilineTextAlignment(.leading).foregroundStyle(row.id == active ? store.accent : Color.secondary).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).disabled(row.time == nil).id(row.id)
                            }
                        }.padding(.vertical, 12)
                    }.frame(height: 340).simultaneousGesture(DragGesture().onChanged { _ in following = false })
                        .onChange(of: active) { _, value in if following, let value { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(value, anchor: .center) } } }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).task(id: track.id) {
            rows = []; busy = true; message = ""; following = true
            defer { busy = false }
            do {
                let reply = try await store.api.lyrics(track)
                try Task.checkCancellation()
                if reply.instrumental == true { message = store.t("Инструментальная композиция") }
                else {
                    rows = LRC.parse(reply.syncedLyrics ?? "")
                    if rows.isEmpty { rows = (reply.plainLyrics ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty }.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) } }
                    if rows.isEmpty { message = store.t("Текст не найден") }
                }
            } catch is CancellationError {} catch { message = error.localizedDescription }
        }
    }
}
