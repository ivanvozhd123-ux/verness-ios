"""Optional network check: real yt-dlp search, resolve and a small audio range."""
import http.client
import json
import secrets
import threading
import urllib.parse
from server import Server


def main():
    token = secrets.token_urlsafe(24)
    server = Server(("127.0.0.1", 0), token)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def request(path):
        connection = http.client.HTTPConnection(*server.server_address, timeout=150)
        connection.request("GET", path, headers={"Authorization": "Bearer " + token})
        response = connection.getresponse()
        body = response.read()
        connection.close()
        if response.status != 200:
            raise RuntimeError(body.decode("utf-8"))
        return json.loads(body)

    try:
        health = request("/v1/health")
        print("Engine:", health["engine"], flush=True)
        result = request("/v1/search?" + urllib.parse.urlencode({"q": "Daft Punk Get Lucky official audio", "page": 0}))
        assert result["tracks"]
        print("Search:", len(result["tracks"]), "real results", flush=True)
        resolved = request("/v1/resolve?id=" + result["tracks"][0]["videoId"])
        connection = http.client.HTTPConnection(*server.server_address, timeout=45)
        connection.request("GET", resolved["path"], headers={"Range": "bytes=0-1023"})
        response = connection.getresponse()
        data = response.read(1024)
        assert response.status in (200, 206), response.status
        assert len(data) == 1024 and b"ftyp" in data[:32]
        connection.close()
        print("PASS authenticated search/resolve and playable M4A proxy bytes", flush=True)
    finally:
        server.shutdown(); server.server_close(); thread.join()


if __name__ == "__main__":
    main()
