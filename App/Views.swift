import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

@main
@MainActor
struct VernessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).tint(model.accent)
                .preferredColorScheme(model.prefs.theme == "light" ? .light : .dark)
                .task { Player.shared.configure(model.prefs, api: model.api) }
                .onChange(of: phase) { _, value in if value != .active { model.flush() } }
        }
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject private var store: AppModel
    @ObservedObject private var player = Player.shared
    @State private var tab = 0
    @State private var settings = false
    @State private var fullPlayer = false
    @State private var pulseSetup = false
    @State private var importer = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image("Clover").resizable().scaledToFit().frame(width: 32, height: 32)
                    Text("verness").font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-1.5)
                    Text(".").font(.title.bold()).foregroundStyle(store.accent).padding(.leading, -8)
                    Spacer()
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.foregroundStyle(Color.secondary).accessibilityLabel(store.t("Настройки"))
                }.padding(.horizontal, 22).padding(.top, 8)
                Group {
                    switch tab {
                    case 1: SearchView()
                    case 2: LibraryView(importer: $importer)
                    case 3: PlaylistsView()
                    default: HomeView(pulseSetup: $pulseSetup, importer: $importer, tab: $tab)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let track = player.current {
                    MiniPlayer(track: track) { fullPlayer = true }.padding(.horizontal, 12).padding(.bottom, 10)
                }
                HStack {
                    ForEach(Array([("house", "Главная"), ("magnifyingglass", "Поиск"), ("books.vertical", "Библиотека"), ("square.grid.2x2", "Плейлисты")].enumerated()), id: \.offset) { i, item in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { tab = i } } label: {
                            VStack(spacing: 5) { Image(systemName: item.0).font(.system(size: 20)); Text(store.t(item.1)).font(.system(size: 9)) }.frame(maxWidth: .infinity).frame(height: 48)
                        }.foregroundStyle(tab == i ? store.accent : Color.secondary)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 5)
            }.background(background).toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $settings) { SettingsView() }
                .sheet(isPresented: $fullPlayer) { PlayerView() }
                .sheet(isPresented: $pulseSetup) { PulseSetup() }
                .fileImporter(isPresented: $importer, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                    switch result { case .success(let urls): store.importFiles(urls); case .failure(let error): store.error = error.localizedDescription }
                }
                .alert("verness", isPresented: Binding(get: { store.error != nil || player.error != nil }, set: { if !$0 { store.error = nil; player.error = nil } })) {
                    Button(store.t("Готово")) { store.error = nil; player.error = nil }
                } message: { Text(store.error ?? player.error ?? "") }
                .onOpenURL { url in if url.scheme == "verness" { fullPlayer = true } else { store.importFiles([url]) } }
        }
    }
    private var background: Color { store.prefs.theme == "light" ? Color(red: 0.95, green: 0.97, blue: 0.93) : Color(red: 0.035, green: 0.047, blue: 0.035) }
}

@MainActor
struct Artwork: View {
    var track: Track?
    var size: CGFloat
    @EnvironmentObject private var store: AppModel
    var body: some View {
        Group {
            if let cover = track?.cover, let url = URL(string: cover), url.scheme == "https" {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { fallback }
            } else if let cover = track?.cover, let url = try? Files.local(cover), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { fallback }
        }.frame(width: size, height: size).clipped().clipShape(RoundedRectangle(cornerRadius: size * 0.18))
    }
    private var fallback: some View { ZStack { store.accent.opacity(0.1); Image(systemName: "music.note").font(.system(size: size * 0.36)).foregroundStyle(store.accent) } }
}

@MainActor
struct HomeView: View {
    @EnvironmentObject private var store: AppModel
    @ObservedObject private var player = Player.shared
    @Binding var pulseSetup: Bool
    @Binding var importer: Bool
    @Binding var tab: Int
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    eyebrow("VERNESS / iOS")
                    Text(store.t("На своей волне.")).font(.system(size: 33, weight: .semibold)).tracking(-1.4)
                    Text(store.t("Любимые звуки. Твой ритм.")).font(.caption).foregroundStyle(.secondary)
                }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 27).fill(store.accent.opacity(0.075))
                    OrbitArt().frame(width: 260, height: 260).offset(x: 130, y: -15).allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 14) {
                        eyebrow(store.t("Твой личный поток"))
                        HStack(spacing: 0) { Text(store.t("Пульс")); Text(".").foregroundStyle(store.accent) }.font(.system(size: 61, weight: .medium)).tracking(-3).padding(.top, 15)
                        Text(store.prefs.artists.isEmpty ? store.t("Выбери любимых артистов") : store.prefs.artists.prefix(4).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 210, alignment: .leading)
                        HStack {
                            Button {
                                if player.pulse { player.toggle() }
                                else if store.prefs.artists.isEmpty { pulseSetup = true }
                                else { player.startPulse(store.prefs.artists) }
                            } label: { Label(store.t(player.pulse && player.playing ? "Пауза" : "Слушать"), systemImage: player.pulse && player.playing ? "pause.fill" : "play.fill").font(.subheadline.bold()).padding(.horizontal, 13).padding(.vertical, 8) }.buttonStyle(.borderedProminent).tint(store.accent).foregroundStyle(.black)
                            Spacer()
                            Button { pulseSetup = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 40, height: 40) }.foregroundStyle(Color.secondary).accessibilityLabel(store.t("Настроить Пульс"))
                        }
                    }.padding(25)
                }.frame(minHeight: 285).clipShape(RoundedRectangle(cornerRadius: 27)).overlay { RoundedRectangle(cornerRadius: 27).stroke(Color.primary.opacity(0.06)) }
                Text(store.t("Продолжим слушать?")).font(.title3.bold())
                HStack(spacing: 12) {
                    card("heart", "Любимые треки", store.data.favorites.count) { tab = 2 }
                    card("square.grid.2x2", "Плейлисты", store.data.playlists.count) { tab = 3 }
                }
                HStack { Text(store.t("Недавно добавлено")).font(.title3.bold()); Spacer(); Button { importer = true } label: { Image(systemName: "plus").frame(width: 35, height: 35) }.accessibilityLabel(store.t("Добавить музыку")) }
                if store.data.tracks.isEmpty { EmptyState() }
                else { TrackRows(tracks: Array(store.data.tracks.suffix(5).reversed())) }
            }.padding(22)
        }.scrollIndicators(.hidden)
    }
    private func card(_ icon: String, _ title: String, _ count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(alignment: .leading, spacing: 15) { Image(systemName: icon).font(.title2).foregroundStyle(store.accent); Text(store.t(title)).font(.caption.bold()).foregroundStyle(.primary); Text("\(count)").font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20)) }.buttonStyle(.plain)
    }
}

@MainActor
struct OrbitArt: View {
    @EnvironmentObject private var store: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var rotate = false
    var body: some View {
        ZStack {
            Circle().fill(store.accent.opacity(0.15)).blur(radius: 35)
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 80).stroke(store.accent.opacity(0.25), lineWidth: 1)
                    .padding(CGFloat(i * 20 + 15)).rotationEffect(.degrees(rotate && !reduce ? (i.isMultiple(of: 2) ? 360 : -360) : 0))
                    .animation(reduce ? nil : .linear(duration: Double(20 + i * 7)).repeatForever(autoreverses: false), value: rotate)
            }
        }.onAppear { rotate = true }
    }
}

func eyebrow(_ text: String) -> some View { Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary) }

@MainActor
struct EmptyState: View {
    @EnvironmentObject private var store: AppModel
    var body: some View { VStack(spacing: 12) { Image(systemName: "music.note").font(.largeTitle); Text(store.t("Здесь будет твоя музыка")).font(.subheadline); Text(store.t("Найди трек или добавь аудиофайлы.")).font(.caption) }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40) }
}

@MainActor
struct TrackRows: View {
    var tracks: [Track]
    @EnvironmentObject private var store: AppModel
    @ObservedObject private var player = Player.shared
    @State private var editing: Track?
    @State private var adding: Track?
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                HStack(spacing: 12) {
                    Button { player.play(tracks, at: i) } label: {
                        HStack(spacing: 12) { Artwork(track: track, size: 48); VStack(alignment: .leading, spacing: 6) { Text(track.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(player.current?.id == track.id ? store.accent : Color.primary).lineLimit(1); Text(track.artist + " · " + clock(track.duration)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) } }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button { store.favorite(track) } label: { Image(systemName: store.data.favorites.contains(track.id) ? "heart.fill" : "heart").font(.system(size: 16)).frame(width: 30, height: 40) }.foregroundStyle(store.data.favorites.contains(track.id) ? store.accent : Color.secondary).accessibilityLabel(store.t("Любимые треки"))
                    Menu {
                        Button(store.t("Сохранить"), systemImage: "plus") { store.remember(track) }
                        Button(store.t("Редактировать"), systemImage: "pencil") { editing = track }
                        Button(store.t("В плейлист"), systemImage: "text.badge.plus") { adding = track }
                        Button(store.t("Удалить из библиотеки"), role: .destructive) { store.remove(track) }
                    } label: { Image(systemName: "ellipsis").frame(width: 26, height: 40).foregroundStyle(Color.secondary) }
                }.padding(.vertical, 11)
                Divider().opacity(0.4)
            }
        }.sheet(item: $editing) { TrackEditor(track: $0) }.sheet(item: $adding) { AddToPlaylist(track: $0) }
    }
}

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var store: AppModel
    @Binding var importer: Bool
    @State private var liked = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(store.t("Библиотека")).font(.largeTitle.bold()).tracking(-1)
                Picker("", selection: $liked) { Text(store.t("Вся музыка")).tag(false); Text(store.t("Любимые треки")).tag(true) }.pickerStyle(.segmented)
                Button { importer = true } label: { Label(store.t("Добавить музыку"), systemImage: "plus").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.bordered)
                Text(store.t("Файлы копируются в библиотеку приложения.")).font(.caption).foregroundStyle(.secondary)
                if store.importing { ProgressView() }
                let rows = store.data.tracks.filter { !liked || store.data.favorites.contains($0.id) }
                if rows.isEmpty { EmptyState() } else { TrackRows(tracks: rows) }
            }.padding(22)
        }.scrollIndicators(.hidden)
    }
}

@MainActor
struct SearchView: View {
    @EnvironmentObject private var store: AppModel
    @State private var query = ""
    @State private var rows: [Track] = []
    @State private var page = 0
    @State private var more = false
    @State private var busy = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(store.t("Поиск")).font(.largeTitle.bold()).tracking(-1)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(store.t("Поиск треков и артистов"), text: $query).submitLabel(.search).onSubmit { search(reset: true) }.autocorrectionDisabled()
                    Button { search(reset: true) } label: { Image(systemName: "arrow.right").padding(8) }.buttonStyle(.borderedProminent).accessibilityLabel(store.t("Найти"))
                }.padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                if store.prefs.server.isEmpty { Text(store.t("Сначала настрой сервер музыки")).font(.subheadline); Text(store.t("Локальные файлы работают без сервера.")).font(.caption).foregroundStyle(.secondary) }
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
                TrackRows(tracks: rows)
                if busy { ProgressView().frame(maxWidth: .infinity) }
                else if more { Button(store.t("Показать ещё")) { search(reset: false) }.buttonStyle(.bordered).frame(maxWidth: .infinity) }
            }.padding(22)
        }.scrollIndicators(.hidden).onDisappear { task?.cancel(); busy = false }
    }
    private func search(reset: Bool) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, reset || !busy else { return }
        task?.cancel(); generation = UUID(); let stamp = generation
        if reset { page = 0; rows = [] }; busy = true; message = nil
        task = Task {
            do {
                let result = try await store.api.search(value, page: page)
                try Task.checkCancellation(); guard generation == stamp else { return }
                let ids = Set(rows.map(\.id)); rows.append(contentsOf: result.tracks.filter { !ids.contains($0.id) })
                more = result.hasMore; page += 1
                if rows.isEmpty { message = store.t("Ничего не найдено") }
            } catch is CancellationError {} catch { if generation == stamp { message = error.localizedDescription } }
            if generation == stamp { busy = false }
        }
    }
}

@MainActor
struct MiniPlayer: View {
    var track: Track
    var open: () -> Void
    @EnvironmentObject private var store: AppModel
    @ObservedObject private var player = Player.shared
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 11) {
                Button(action: open) { HStack(spacing: 11) { Artwork(track: track, size: 43); VStack(alignment: .leading, spacing: 5) { Text(track.title).font(.system(size: 12, weight: .semibold)).lineLimit(1); Text(track.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading) } }.buttonStyle(.plain)
                Button { player.toggle() } label: { Group { if player.loading { ProgressView().tint(.black) } else { Image(systemName: player.playing ? "pause.fill" : "play.fill") } }.frame(width: 43, height: 43).background(store.accent, in: Circle()).foregroundStyle(.black) }.accessibilityLabel(store.t(player.playing ? "Пауза" : "Слушать"))
                Button { player.step(1) } label: { Image(systemName: "forward.end").frame(width: 30, height: 40) }.foregroundStyle(Color.secondary).accessibilityLabel(store.t("Следующий"))
            }
            ProgressView(value: player.position, total: max(1, player.duration)).tint(store.accent).scaleEffect(y: 0.6)
        }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).overlay { RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.06)) }
    }
}

@MainActor
struct PlaylistsView: View {
    @EnvironmentObject private var store: AppModel
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(store.t("Плейлисты")).font(.largeTitle.bold()).tracking(-1)
                Button { creating = true } label: { Label(store.t("Новый плейлист"), systemImage: "plus").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.bordered)
                ForEach(store.data.playlists) { list in
                    NavigationLink {
                        PlaylistDetail(id: list.id)
                    } label: {
                        HStack { Image(systemName: "square.grid.2x2").font(.title2).foregroundStyle(store.accent); Text(list.name).font(.headline); Spacer(); Text("\(list.tracks.count)").foregroundStyle(.secondary); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(22).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
                    }.buttonStyle(.plain).contextMenu { Button(store.t("Удалить из библиотеки"), role: .destructive) { store.data.playlists.removeAll { $0.id == list.id }; store.save() } }
                }
            }.padding(22)
        }.alert(store.t("Новый плейлист"), isPresented: $creating) {
            TextField(store.t("Название"), text: $name)
            Button(store.t("Сохранить")) { let value = name.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { store.data.playlists.append(Playlist(name: value)); store.save() }; name = "" }
            Button(store.t("Отмена"), role: .cancel) { name = "" }
        }
    }
}

@MainActor
struct PlaylistDetail: View {
    var id: String
    @EnvironmentObject private var store: AppModel
    @ObservedObject private var player = Player.shared
    @State private var fullPlayer = false
    private var playlist: Playlist? { store.data.playlists.first { $0.id == id } }
    private var tracks: [Track] { (playlist?.tracks ?? []).compactMap { id in store.data.tracks.first { $0.id == id } } }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Button { player.play(tracks, at: 0) } label: { Label(store.t("Слушать"), systemImage: "play.fill").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.borderedProminent).disabled(tracks.isEmpty)
                if tracks.isEmpty { EmptyState() } else { TrackRows(tracks: tracks) }
            }.padding(22)
        }.navigationTitle(playlist?.name ?? store.t("Плейлисты")).toolbar(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { if let track = player.current { MiniPlayer(track: track) { fullPlayer = true }.padding(12) } }
            .sheet(isPresented: $fullPlayer) { PlayerView() }
    }
}

@MainActor
struct AddToPlaylist: View {
    var track: Track
    @EnvironmentObject private var store: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.data.playlists) { list in
                    Button(list.name) {
                        store.remember(track)
                        if let i = store.data.playlists.firstIndex(where: { $0.id == list.id }), !store.data.playlists[i].tracks.contains(track.id) { store.data.playlists[i].tracks.append(track.id); store.save() }
                        dismiss()
                    }
                }
                if store.data.playlists.isEmpty { Text(store.t("Новый плейлист")).foregroundStyle(.secondary) }
            }.navigationTitle(store.t("В плейлист")).toolbar { Button(store.t("Закрыть")) { dismiss() } }
        }.presentationDetents([.medium, .large])
    }
}

@MainActor
struct TrackEditor: View {
    var track: Track
    @EnvironmentObject private var store: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var photo: PhotosPickerItem?
    var body: some View {
        NavigationStack {
            Form {
                PhotosPicker(selection: $photo, matching: .images) { HStack { Artwork(track: store.data.tracks.first(where: { $0.id == track.id }) ?? track, size: 70); Text(store.t("Обложка")) } }
                TextField(store.t("Название"), text: $title)
                TextField(store.t("Исполнитель"), text: $artist)
            }.navigationTitle(store.t("Редактировать")).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(store.t("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.t("Сохранить")) {
                        store.remember(track)
                        if let i = store.data.tracks.firstIndex(where: { $0.id == track.id }) { store.data.tracks[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines); store.data.tracks[i].artist = artist; Player.shared.updateMetadata(store.data.tracks[i]); store.save() }
                        dismiss()
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.onAppear { title = track.title; artist = track.artist }
                .onChange(of: photo) { _, item in Task { if let bytes = try? await item?.loadTransferable(type: Data.self) { store.artwork(bytes, for: track) } } }
        }
    }
}
