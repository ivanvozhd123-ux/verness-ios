import http.client
import io
import json
import secrets
import threading
import unittest
import urllib.error
from unittest.mock import patch
from server import Catalog, MusicError, Server, media_url


class FakeMedia(io.BytesIO):
    status = 206
    headers = {"Content-Type": "audio/mp4", "Content-Length": "4", "Content-Range": "bytes 0-3/4"}


class FakeCatalog:
    def health(self):
        return {"version": "0.1.2", "engine": "test"}

    def search(self, query, page):
        return {"tracks": [{"id": "yt:abcdefghijk", "title": query, "artist": "Artist", "duration": 1}], "hasMore": page == 0}

    def resolve(self, video):
        return {"path": "/v1/audio/" + "a" * 32, "duration": 1, "title": "Test", "artist": "Artist"}

    def audio(self, token, range_header):
        if token != "a" * 32:
            raise MusicError("Expired", 404)
        return FakeMedia(b"test")

    def lyrics(self, *args):
        return {"syncedLyrics": "[00:00.00]Test", "plainLyrics": "Test", "instrumental": False}


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.token = secrets.token_urlsafe(24)
        cls.server = Server(("127.0.0.1", 0), cls.token, FakeCatalog())
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join()

    def get(self, route, auth=True, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        headers = dict(headers or {})
        if auth:
            headers["Authorization"] = "Bearer " + self.token
        connection.request("GET", route, headers=headers)
        response = connection.getresponse()
        result = response.status, response.read(), dict(response.getheaders())
        connection.close()
        return result

    def test_authentication(self):
        self.assertEqual(self.get("/v1/health", False)[0], 401)
        self.assertEqual(self.get("/v1/health")[0], 200)

    def test_routes_and_pagination(self):
        status, body, _ = self.get("/v1/search?q=artist&page=1")
        self.assertEqual(status, 200)
        self.assertFalse(json.loads(body)["hasMore"])
        self.assertEqual(self.get("/v1/search?q=artist&page=bad")[0], 400)
        self.assertEqual(self.get("/missing")[0], 404)

    def test_stream_is_scoped_and_preserves_range(self):
        status, body, headers = self.get("/v1/audio/" + "a" * 32, False, {"Range": "bytes=0-3"})
        self.assertEqual((status, body), (206, b"test"))
        self.assertEqual(headers["Content-Range"], "bytes 0-3/4")
        self.assertEqual(self.get("/v1/audio/" + "b" * 32, False)[0], 404)
        self.assertEqual(self.get("/v1/audio/../private", False)[0], 404)

    def test_real_catalog_validation_and_page_arguments(self):
        catalog = Catalog()
        with self.assertRaises(MusicError):
            catalog.resolve("not-a-video")
        with self.assertRaises(MusicError):
            catalog.search("query", 100)
        entries = [{"id": "abcdefghijk", "title": "Track", "duration": 10}] * 21
        with patch.object(catalog, "run", return_value=json.dumps({"entries": entries})) as run:
            result = catalog.search("query", 2)
            self.assertEqual(len(result["tracks"]), 20)
            self.assertTrue(result["hasMore"])
            args = run.call_args.args[0]
            self.assertEqual(args[args.index("--playlist-start") + 1], "41")
            self.assertIn("ytsearch61:query", args)

    def test_media_host_validation(self):
        self.assertTrue(media_url("https://r1.googlevideo.com/videoplayback"))
        self.assertFalse(media_url("http://r1.googlevideo.com/audio"))
        self.assertFalse(media_url("https://googlevideo.com.attacker.example/audio"))

    def test_lyrics_fallback_checks_duration_and_metadata(self):
        catalog = Catalog()
        missing = urllib.error.HTTPError("https://lrclib.net/api/get", 404, "missing", {}, None)
        rows = [
            {"trackName": "Get Lucky", "artistName": "Daft Punk", "duration": 249, "syncedLyrics": "[00:01.00]Line"},
            {"trackName": "Get Lucky", "artistName": "Daft Punk", "duration": 500, "syncedLyrics": "wrong version"},
        ]
        with patch("urllib.request.urlopen", side_effect=[missing, io.BytesIO(json.dumps(rows).encode())]):
            result = catalog.lyrics("Get Lucky (Official Audio)", "Daft Punk", 249)
        self.assertEqual(result["syncedLyrics"], "[00:01.00]Line")


if __name__ == "__main__":
    unittest.main()
