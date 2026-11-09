"""Small authenticated yt-dlp bridge for the iOS app."""
import argparse
import difflib
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_AUDIO = 100_000_000
VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{11}\Z")


class MusicError(Exception):
    def __init__(self, message, status=502):
        super().__init__(message)
        self.status = status


def media_url(url):
    parsed = urllib.parse.urlsplit(url)
    return parsed.scheme == "https" and parsed.hostname and parsed.hostname.endswith(".googlevideo.com")


class MediaRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not media_url(newurl):
            raise MusicError("Invalid media redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Catalog:
    def __init__(self, executable=None):
        bundled = next((parent / "modules/mus/yt-dlp.exe" for parent in Path(__file__).resolve().parents
                        if (parent / "modules/mus/yt-dlp.exe").is_file()), None)
        executable = executable or os.environ.get("VERNESS_YTDLP")
        if executable:
            self.command = [executable]
        elif os.name == "nt" and bundled is not None:
            self.command = [str(bundled)]
        elif shutil.which("yt-dlp"):
            self.command = [shutil.which("yt-dlp")]
        else:
            self.command = [sys.executable, "-m", "yt_dlp"]
        self.lock = threading.Lock()
        self.jobs = threading.BoundedSemaphore(2)
        self.searches = {}
        self.tokens = {}
        self.lyrics_cache = {}
        self.engine_version = None

    def run(self, args, timeout=75):
        if not self.jobs.acquire(timeout=2):
            raise MusicError("Music server is busy. Try again shortly.", 503)
        try:
            command = self.command + ["--ignore-config", "--no-warnings", "--no-progress", "--socket-timeout", "12", "--retries", "1", "--extractor-retries", "1"]
            node = shutil.which("node")
            if node:
                command += ["--js-runtimes", "node:" + node]
            options = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
            result = subprocess.run(command + args, shell=False, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", timeout=timeout,
                                    env={**os.environ, "PYTHONIOENCODING": "utf-8"}, **options)
            if result.returncode:
                if re.search(r"not a bot|sign in|login|cookies", result.stderr, re.I):
                    raise MusicError("Source requires authentication or rate limit recovery")
                raise MusicError("The source could not prepare this track. Try another result.")
            return result.stdout
        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            raise MusicError("yt-dlp is missing or the request timed out") from error
        finally:
            self.jobs.release()

    def health(self):
        if not self.engine_version:
            self.engine_version = self.run(["--version"], 15).strip()
        return {"version": "0.1.2", "engine": self.engine_version}

    def search(self, query, page):
        query = query.strip()
        if not query or len(query) > 150 or page < 0 or page > 99:
            raise MusicError("Invalid search query", 400)
        key = (query, page)
        with self.lock:
            cached = self.searches.get(key)
            if cached and time.time() - cached[0] < 21600:
                return cached[1]
        start, end = page * 20 + 1, (page + 1) * 20
        raw = self.run(["--flat-playlist", "--dump-single-json", "--skip-download", "--playlist-start", str(start),
                        "--playlist-end", str(end + 1), "--", f"ytsearch{end + 1}:{query}"])
        entries = [item for item in (json.loads(raw).get("entries") or []) if isinstance(item, dict)]
        tracks = []
        for item in entries[:20]:
            video = str(item.get("id", ""))
            if not VIDEO_ID.fullmatch(video):
                continue
            duration = item.get("duration") or 0
            tracks.append({"id": "yt:" + video, "videoId": video, "title": str(item.get("title") or "Track")[:300],
                           "artist": str(item.get("channel") or item.get("uploader") or "Verness")[:200],
                           "duration": float(duration) if isinstance(duration, (int, float)) else 0,
                           "cover": f"https://i.ytimg.com/vi/{video}/hqdefault.jpg"})
        result = {"tracks": tracks, "hasMore": len(entries) > 20}
        with self.lock:
            if len(self.searches) >= 256:
                self.searches.pop(next(iter(self.searches)))
            self.searches[key] = (time.time(), result)
        return result

    def resolve(self, video):
        if not VIDEO_ID.fullmatch(video):
            raise MusicError("Invalid video ID", 400)
        info = json.loads(self.run(["--no-playlist", "--dump-single-json", "--skip-download", "-f", "bestaudio[ext=m4a]",
                                    "--", "https://music.youtube.com/watch?v=" + video]))
        url = info.get("url", "")
        if not media_url(url):
            raise MusicError("No compatible AAC audio is available")
        ready = float(info.get("available_at") or 0) - time.time() + 0.2
        if ready > 60:
            raise MusicError("Track is not ready yet. Try again shortly.", 503)
        if ready > 0:
            time.sleep(ready)
        headers = {}
        for name in ("User-Agent", "Referer", "Origin"):
            value = info.get("http_headers", {}).get(name)
            if isinstance(value, str) and "\r" not in value and "\n" not in value:
                headers[name] = value
        token = secrets.token_urlsafe(24)
        with self.lock:
            now = time.time()
            self.tokens = {key: value for key, value in self.tokens.items() if value[0] > now}
            if len(self.tokens) >= 128:
                self.tokens.pop(next(iter(self.tokens)))
            self.tokens[token] = (now + 900, url, headers)
        return {"path": "/v1/audio/" + token, "duration": float(info.get("duration") or 0),
                "title": str(info.get("track") or info.get("title") or "Track"),
                "artist": str(info.get("artist") or info.get("channel") or "Verness")}

    def audio(self, token, range_header):
        with self.lock:
            entry = self.tokens.get(token)
        if not entry or entry[0] < time.time():
            raise MusicError("Stream expired. Prepare the track again.", 404)
        headers = dict(entry[2])
        if range_header:
            if not re.fullmatch(r"bytes=\d*-\d*", range_header):
                raise MusicError("Invalid byte range", 416)
            headers["Range"] = range_header
        return urllib.request.build_opener(MediaRedirect()).open(urllib.request.Request(entry[1], headers=headers), timeout=30)

    def lyrics(self, title, artist, duration):
        if not title or len(title) > 300 or len(artist) > 200:
            raise MusicError("Invalid track metadata", 400)
        key = (title, artist, duration)
        with self.lock:
            cached = self.lyrics_cache.get(key)
            if cached and time.time() - cached[0] < 86400:
                return cached[1]
        params = urllib.parse.urlencode({"track_name": title, "artist_name": artist, "duration": duration})
        req = urllib.request.Request("https://lrclib.net/api/get?" + params, headers={"User-Agent": "verness-ios/0.1.2"})
        try:
            with urllib.request.urlopen(req, timeout=20) as response:
                data = json.load(response)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise MusicError("Lyrics service is unavailable") from error
            data = {"syncedLyrics": None, "plainLyrics": None, "instrumental": False}
            query = urllib.parse.urlencode({"q": title + " " + artist})
            search = urllib.request.Request("https://lrclib.net/api/search?" + query, headers={"User-Agent": "verness-ios/0.1.2"})
            try:
                with urllib.request.urlopen(search, timeout=15) as response:
                    candidates = json.load(response)
                ranked = []
                for candidate in candidates:
                    if duration and abs((candidate.get("duration") or 0) - duration) > 3:
                        continue
                    title_score = difflib.SequenceMatcher(None, title.casefold(), str(candidate.get("trackName", "")).casefold()).ratio()
                    artist_score = difflib.SequenceMatcher(None, artist.casefold(), str(candidate.get("artistName", "")).casefold()).ratio()
                    if title_score >= 0.5 and artist_score >= 0.5:
                        ranked.append((title_score + artist_score + (0.1 if candidate.get("syncedLyrics") else 0), candidate))
                if ranked:
                    data = max(ranked, key=lambda item: item[0])[1]
            except (urllib.error.URLError, ValueError, TypeError):
                pass
        result = {key: data.get(key) for key in ("syncedLyrics", "plainLyrics", "instrumental")}
        with self.lock:
            if len(self.lyrics_cache) >= 512:
                self.lyrics_cache.pop(next(iter(self.lyrics_cache)))
            self.lyrics_cache[key] = (time.time(), result)
        return result


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(20)
        return connection, address

    def __init__(self, address, token, catalog=None):
        self.token = token
        self.catalog = catalog or Catalog()
        self.connections = threading.BoundedSemaphore(12)
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server_version = "verness/0.1.2"

    def log_message(self, format, *args):
        pass

    def json(self, status, value):
        data = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.connection.settimeout(150)
        self.streaming = False
        if not self.server.connections.acquire(blocking=False):
            self.json(503, {"error": "Server is busy"})
            return
        try:
            self.handle_get()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except MusicError as error:
            if not self.streaming:
                self.json(error.status, {"error": str(error)})
            else:
                self.close_connection = True
        except Exception:
            if not self.streaming:
                self.json(502, {"error": "The request could not be completed"})
            else:
                self.close_connection = True
        finally:
            self.server.connections.release()

    def handle_get(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path.startswith("/v1/audio/"):
            token = parsed.path.removeprefix("/v1/audio/")
            if not re.fullmatch(r"[A-Za-z0-9_-]{32}", token):
                raise MusicError("Invalid stream", 404)
            with self.server.catalog.audio(token, self.headers.get("Range")) as source:
                length = source.headers.get("Content-Length")
                if length and int(length) > MAX_AUDIO:
                    raise MusicError("Audio file exceeds 100 MB", 413)
                self.send_response(source.status)
                self.streaming = True
                for name in ("Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"):
                    if source.headers.get(name):
                        self.send_header(name, source.headers[name])
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                total = 0
                while True:
                    chunk = source.read(65536)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_AUDIO:
                        self.close_connection = True
                        return
                    self.wfile.write(chunk)
            return
        expected = "Bearer " + self.server.token
        if not hmac.compare_digest(self.headers.get("Authorization", ""), expected):
            self.json(401, {"error": "Invalid access key"})
            return
        params = urllib.parse.parse_qs(parsed.query)
        value = lambda key, default="": params.get(key, [default])[0]
        if parsed.path == "/v1/health":
            result = self.server.catalog.health()
        elif parsed.path == "/v1/search":
            try:
                page = int(value("page", "0"))
            except ValueError:
                raise MusicError("Invalid search page", 400)
            result = self.server.catalog.search(value("q"), page)
        elif parsed.path == "/v1/resolve":
            result = self.server.catalog.resolve(value("id"))
        elif parsed.path == "/v1/lyrics":
            try:
                duration = min(86400, max(0, int(value("duration", "0"))))
            except ValueError:
                raise MusicError("Invalid duration", 400)
            result = self.server.catalog.lyrics(value("title"), value("artist"), duration)
        else:
            raise MusicError("Not found", 404)
        self.json(200, result)


def main():
    parser = argparse.ArgumentParser(description="verness music bridge for iOS")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--yt-dlp", dest="executable")
    args = parser.parse_args()
    token = os.environ.get("VERNESS_API_TOKEN", "")
    if len(token) < 24:
        parser.error("Set VERNESS_API_TOKEN to a random access key of at least 24 characters")
    server = Server((args.host, args.port), token, Catalog(args.executable))
    print(f"verness bridge listening on {args.host}:{args.port}; authentication enabled", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
