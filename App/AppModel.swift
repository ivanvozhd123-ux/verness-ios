import SwiftUI
import PhotosUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var data = LibraryData()
    @Published var error: String?
    @Published var importing = false
    private var saveTask: Task<Void, Never>?
    var prefs: Preferences { data.preferences }
    var api: MusicAPI { MusicAPI(endpoint: prefs.server, token: Secrets.token()) }
    var accent: Color { Color(hex: prefs.accent) }
    private init() {
        do { data = try Files.read() }
        catch {
            let original = Files.root.appendingPathComponent("library.json")
            try? FileManager.default.copyItem(at: original, to: Files.root.appendingPathComponent("library-backup-\(UUID().uuidString).json"))
            self.error = "Library could not be read. A backup has been kept."
        }
    }
    func update(_ body: (inout Preferences) -> Void) {
        body(&data.preferences)
        Player.shared.configure(prefs, api: api)
        save()
    }
    func save() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(250)); if !Task.isCancelled { flush() } }
    }
    func flush() { do { try Files.save(data) } catch { self.error = error.localizedDescription } }
    func remember(_ track: Track) {
        if !data.tracks.contains(where: { $0.id == track.id }) { data.tracks.append(track) }
        save()
    }
    func favorite(_ track: Track) {
        remember(track)
        if data.favorites.contains(track.id) { data.favorites.remove(track.id) } else { data.favorites.insert(track.id) }
        save()
    }
    func remove(_ track: Track) {
        data.tracks.removeAll { $0.id == track.id }; data.favorites.remove(track.id)
        for i in data.playlists.indices { data.playlists[i].tracks.removeAll { $0 == track.id } }
        save()
    }
    func importFiles(_ urls: [URL]) {
        importing = true
        Task {
            defer { importing = false }
            for url in urls {
                do { let track = try await Files.importAudio(url); remember(track) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    func artwork(_ bytes: Data, for track: Track) {
        guard let image = UIImage(data: bytes), let data = Files.thumbnail(image) else { return }
        do {
            remember(track)
            let name = UUID().uuidString + ".jpg"
            try data.write(to: Files.local(name), options: .atomic)
            if let index = self.data.tracks.firstIndex(where: { $0.id == track.id }) { self.data.tracks[index].cover = name; Player.shared.updateMetadata(self.data.tracks[index]) }
            save()
        } catch { self.error = error.localizedDescription }
    }
    func t(_ key: String) -> String { prefs.language == "en" ? (english[key] ?? key) : key }
    private let english: [String: String] = [
        "Главная":"Home", "Поиск":"Search", "Библиотека":"Library", "Плейлисты":"Playlists", "Настройки":"Settings",
        "На своей волне.":"On your wavelength.", "Любимые звуки. Твой ритм.":"Your music. Your rhythm.", "Пульс":"Pulse",
        "Слушать":"Listen", "Пауза":"Pause", "Настроить Пульс":"Set up Pulse", "Выбери любимых артистов":"Pick your favorite artists",
        "Добавить":"Add", "Начать слушать":"Start listening", "Любимые треки":"Liked tracks", "Вся музыка":"All music",
        "Недавно добавлено":"Recently added", "Добавить музыку":"Add music", "Твой личный поток":"Your personal flow",
        "Продолжим слушать?":"Keep listening?", "Здесь будет твоя музыка":"Your music will live here", "Найди трек или добавь аудиофайлы.":"Find a track or import audio files.",
        "Поиск треков и артистов":"Search tracks and artists", "Найти":"Search", "Показать ещё":"Show more", "Ничего не найдено":"No results",
        "Сохранить":"Save", "Отмена":"Cancel", "Готово":"Done", "Название":"Title", "Исполнитель":"Artist", "Обложка":"Artwork",
        "Редактировать":"Edit", "Удалить из библиотеки":"Remove from library", "В плейлист":"Add to playlist", "Новый плейлист":"New playlist",
        "Очередь":"Queue", "Сейчас и далее":"Now and next", "Подготовка трека…":"Preparing audio…", "Текст не найден":"Lyrics not found",
        "Ищем текст…":"Finding lyrics…", "Инструментальная композиция":"Instrumental track", "Вернуться к строке":"Follow current line",
        "Тема":"Theme", "Тёмная":"Dark", "Светлая":"Light", "Язык":"Language", "Акцент":"Accent", "Скорость":"Speed", "Громкость":"Volume",
        "Эквалайзер":"Equalizer", "Ровный":"Flat", "Бас":"Bass", "Вокал":"Vocals", "Предусиление":"Preamp", "Защита от перегруза":"Headroom protection",
        "Сервер музыки":"Music server", "Адрес сервера":"Server URL", "Ключ доступа":"Access key", "Проверить подключение":"Test connection",
        "Сервер подключён":"Server connected", "Сначала настрой сервер музыки":"Set up the music server first", "Открыть настройки":"Open Settings",
        "Локальные файлы работают без сервера.":"Local files work without a server.", "Island и экран блокировки":"Island and Lock Screen",
        "Live Activity":"Live Activity", "Показать Island":"Show Island", "Нужен совместимый iPhone и разрешение Live Activities.":"Requires a compatible iPhone and Live Activities permission.",
        "Файлы копируются в библиотеку приложения.":"Files are copied into the app library.", "Пока тихо":"Nothing playing yet", "Закрыть":"Close",
        "Вернуться к музыке":"Back to music", "Текст":"Lyrics", "Следующий":"Next", "Предыдущий":"Previous", "Повтор":"Repeat", "Случайный порядок":"Shuffle"
    ]
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x66db1b
        self.init(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
}
