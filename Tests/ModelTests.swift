import XCTest
@testable import Verness

final class ModelTests: XCTestCase {
    func testLRCMultipleStampsAndOffset() {
        let rows = LRC.parse("[offset:-500]\n[00:01.00][00:03.50]A line\n[00:02.25]Another\n[ar:Artist]")
        XCTAssertEqual(rows.map(\.time), [0.5, 1.75, 3.0])
        XCTAssertEqual(rows.map(\.text), ["A line", "Another", "A line"])
    }
    func testRepeatRules() {
        XCTAssertNil(QueueRules.next(index: 2, count: 3, direction: 1, automatic: true, repeatMode: .off))
        XCTAssertEqual(QueueRules.next(index: 2, count: 3, direction: 1, automatic: true, repeatMode: .all), 0)
        XCTAssertEqual(QueueRules.next(index: 1, count: 3, direction: 1, automatic: true, repeatMode: .one), 1)
        XCTAssertEqual(QueueRules.next(index: 1, count: 3, direction: 1, automatic: false, repeatMode: .one), 2)
        XCTAssertNil(QueueRules.next(index: 0, count: 0, direction: 1, automatic: true, repeatMode: .all))
    }
    func testLibraryRoundtrip() throws {
        let track = Track(id: "local", title: "Name", artist: "Artist", duration: 125, cover: "cover.jpg", file: "music.m4a")
        var data = LibraryData(); data.tracks = [track]; data.favorites = [track.id]
        data.playlists = [Playlist(name: "Evening", tracks: [track.id])]
        data.preferences.bands[2] = 6
        let result = try JSONDecoder().decode(LibraryData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(result.tracks, [track]); XCTAssertTrue(result.favorites.contains(track.id))
        XCTAssertEqual(result.playlists.first?.tracks, [track.id]); XCTAssertEqual(result.preferences.bands[2], 6)
    }
    func testFileTraversalRejected() {
        XCTAssertThrowsError(try Files.local("../private"))
        XCTAssertThrowsError(try Files.local("folder/file.mp3"))
        XCTAssertNoThrow(try Files.local("file.mp3"))
    }
    func testPublicServerRequiresHTTPS() {
        XCTAssertThrowsError(try MusicAPI(endpoint: "http://example.com", token: "").base)
        XCTAssertThrowsError(try MusicAPI(endpoint: "http://10.1.1.1.example.com", token: "").base)
        XCTAssertNoThrow(try MusicAPI(endpoint: "http://192.168.1.10:8766", token: "").base)
        XCTAssertNoThrow(try MusicAPI(endpoint: "https://music.example.com", token: "").base)
    }
}
