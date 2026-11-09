import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var token = ""
    @State private var busy = false
    @State private var status = ""
    private func bind<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> { Binding(get: { store.prefs[keyPath: key] }, set: { value in store.update { $0[keyPath: key] = value } }) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(store.t("Тема"), selection: bind(\.theme)) { Text(store.t("Тёмная")).tag("dark"); Text(store.t("Светлая")).tag("light") }
                    Picker(store.t("Язык"), selection: bind(\.language)) { Text("Русский").tag("ru"); Text("English").tag("en") }
                    HStack {
                        Text(store.t("Акцент")); Spacer()
                        ForEach(["#66db1b", "#ad9aef", "#ef9db7", "#7bbced", "#f3bd6b"], id: \.self) { color in
                            Button { store.update { $0.accent = color } } label: { Circle().fill(Color(hex: color)).frame(width: 25, height: 25).overlay { if store.prefs.accent == color { Circle().stroke(.primary, lineWidth: 1).padding(-3) } } }.buttonStyle(.plain).accessibilityLabel(color)
                        }
                    }
                    Toggle(store.t("Live Activity"), isOn: bind(\.liveActivity))
                    Text(store.t("Нужен совместимый iPhone и разрешение Live Activities.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(store.t("Эквалайзер")) {
                    Toggle(store.t("Эквалайзер"), isOn: bind(\.eqEnabled))
                    EqualizerView()
                    HStack {
                        preset("Ровный", [0,0,0,0,0,0,0,0,0,0])
                        preset("Бас", [6,5,4,2,0,0,0,0,0,0])
                        preset("Вокал", [-3,-2,-1,0,2,4,3,1,0,-1])
                    }.buttonStyle(.bordered)
                    HStack { Text(store.t("Предусиление")).font(.caption); Slider(value: Binding(get: { Double(store.prefs.preamp) }, set: { v in store.update { $0.preamp = Float(v) } }), in: -12...12, step: 1); Text("\(Int(store.prefs.preamp)) dB").font(.caption).frame(width: 46) }
                    Toggle(store.t("Защита от перегруза"), isOn: bind(\.protect))
                }
                Section(store.t("Сервер музыки")) {
                    TextField(store.t("Адрес сервера"), text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField(store.t("Ключ доступа"), text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(store.t("Сохранить")) { saveServer() }
                    Button { check() } label: { HStack { Text(store.t("Проверить подключение")); if busy { Spacer(); ProgressView() } } }.disabled(busy)
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                    Text(store.t("Локальные файлы работают без сервера.")).font(.caption).foregroundStyle(.secondary)
                }
                Section { Text("verness 0.1.2 / iOS\nSwiftUI · AVAudioEngine · ActivityKit\nLRCLIB · yt-dlp server").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle(store.t("Настройки")).toolbar { Button(store.t("Готово")) { dismiss() } }
                .onAppear { server = store.prefs.server; token = Secrets.token() }
        }
    }
    private func saveServer() {
        do { try Secrets.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines)); store.update { $0.server = server.trimmingCharacters(in: .whitespacesAndNewlines) }; status = store.t("Сохранить") + " ✓" }
        catch { status = error.localizedDescription }
    }
    private func check() {
        saveServer(); busy = true
        Task {
            defer { busy = false }
            do { let reply: HealthReply = try await store.api.request("health"); status = store.t("Сервер подключён") + " · yt-dlp " + reply.engine }
            catch { status = error.localizedDescription }
        }
    }
    private func preset(_ title: String, _ values: [Float]) -> some View { Button(store.t(title)) { store.update { $0.eqEnabled = true; $0.bands = values; $0.preamp = 0 } }.font(.caption) }
}

@MainActor
struct EqualizerView: View {
    @EnvironmentObject private var store: AppModel
    private let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(labels.indices, id: \.self) { i in
                    VStack(spacing: 10) {
                        let gain = store.prefs.bands.indices.contains(i) ? store.prefs.bands[i] : 0
                        Text("\(Int(gain))").font(.caption2.monospacedDigit()).foregroundStyle(store.accent)
                        Slider(value: Binding(get: { Double(store.prefs.bands.indices.contains(i) ? store.prefs.bands[i] : 0) }, set: { value in store.update { prefs in if prefs.bands.count != 10 { prefs.bands = Array(repeating: 0, count: 10) }; prefs.bands[i] = Float(value); prefs.eqEnabled = true } }), in: -12...12, step: 1)
                            .frame(width: 140).rotationEffect(.degrees(-90)).frame(width: 28, height: 150).accessibilityLabel(labels[i] + " Hz")
                        Text(labels[i]).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }.padding(.vertical, 15)
        }.scrollIndicators(.hidden)
    }
}

@MainActor
struct PulseSetup: View {
    @EnvironmentObject private var store: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []
    @State private var name = ""
    private let suggestions = ["Daft Punk", "The Weeknd", "GONE.Fludd", "Кино", "Молчат Дома", "Баста", "ЛСП", "Макс Корж", "Скриптонит", "Oxxxymiron", "ATL", "Boulevard Depo", "Miyagi & Эндшпиль", "Noize MC", "Земфира", "Сплин", "Би-2", "Дайте танк (!)", "Пошлая Молли", "ssshhhiiittt!", "Tame Impala", "Arctic Monkeys", "Radiohead", "Gorillaz", "Lana Del Rey", "Billie Eilish", "Kendrick Lamar", "Tyler, The Creator", "Joji", "Frank Ocean", "Travis Scott", "A$AP Rocky", "Massive Attack", "Portishead", "Deftones", "Linkin Park", "Bring Me The Horizon", "The Neighbourhood", "Cigarettes After Sex", "Crystal Castles"]
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(store.t("Выбери любимых артистов")).font(.title2.bold())
                    Text("\(selected.count) / 40").font(.caption).foregroundStyle(.secondary)
                    HStack { TextField(store.t("Исполнитель"), text: $name).autocorrectionDisabled(); Button(store.t("Добавить")) { let value = name.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty && !selected.contains(value) && selected.count < 40 { selected.append(value); name = "" } } }
                }
                Section {
                    ForEach(Array(Set(selected + suggestions)).sorted(), id: \.self) { artist in
                        Button { if selected.contains(artist) { selected.removeAll { $0 == artist } } else if selected.count < 40 { selected.append(artist) } } label: {
                            HStack(spacing: 13) { Text(String(artist.prefix(1))).font(.headline).frame(width: 38, height: 38).background(store.accent.opacity(0.12), in: Circle()); Text(artist).foregroundStyle(.primary); Spacer(); if selected.contains(artist) { Image(systemName: "checkmark.circle.fill").foregroundStyle(store.accent) } }
                        }
                    }
                }
            }.navigationTitle(store.t("Настроить Пульс")).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(store.t("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(store.t("Начать слушать")) { store.update { $0.artists = selected }; Player.shared.startPulse(selected); dismiss() }.disabled(selected.isEmpty) }
            }.onAppear { selected = store.prefs.artists }
        }
    }
}
