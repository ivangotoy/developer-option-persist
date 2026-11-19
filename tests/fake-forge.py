"""Fake forge for tests/module-ci-release.sh: the subset of the Forgejo API and web
routes that .forgejo/module-ci.sh release uses, on 127.0.0.1.

  python3 -I fake-forge.py PORT_FILE LOG_FILE ORIGIN_GIT_DIR REPOSITORY

Every request is logged as one JSON line (method, path, Authorization header,
body size). FAKE_FORGE_FAIL=upload answers asset uploads with 500, =publish the publish PATCH,
=publish-lost applies the publish PATCH and then answers 500 (a lost reply).
"""
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PORT_FILE, LOG_FILE, ORIGIN, REPO = sys.argv[1:5]
FAIL = os.environ.get("FAKE_FORGE_FAIL", "")
API = f"/api/v1/repos/{REPO}"
releases = {}
assets = {}
next_id = [1]


def multipart_file(body, ctype):
    boundary = ctype.split("boundary=", 1)[1].strip('"').encode()
    for part in body.split(b"--" + boundary):
        head, sep, data = part.partition(b"\r\n\r\n")
        if sep and b'name="attachment"' in head:
            return data[:-2] if data.endswith(b"\r\n") else data
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, data=b"", ctype="application/json"):
        if isinstance(data, (dict, list)):
            data = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def handle_any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        url = urlsplit(self.path)
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization"), "size": len(body)}) + "\n")
        p, m = url.path, self.command
        base = f"http://127.0.0.1:{self.server.server_port}"
        if m == "GET" and p.startswith(API + "/releases/tags/"):
            tag = p.rsplit("/", 1)[1]
            r = [x for x in releases.values() if x["tag"] == tag and not x["draft"]]
            return self.reply(200, {"id": r[0]["id"]}) if r else self.reply(404, {"message": "not found"})
        if m == "GET" and p.startswith(API + "/tags/"):
            tag = p.rsplit("/", 1)[1]
            r = [x for x in releases.values() if x["tag"] == tag and not x["draft"]]
            return self.reply(200, {"name": tag, "commit": {"sha": r[0]["target"]}}) if r else self.reply(404, {"message": "not found"})
        if m == "POST" and p == API + "/releases":
            req = json.loads(body)
            rid = next_id[0]
            next_id[0] += 1
            releases[rid] = {"id": rid, "tag": req["tag_name"], "target": req["target_commitish"],
                             "draft": req["draft"], "name": req["name"], "body": req["body"]}
            return self.reply(201, {"id": rid})
        parts = p[len(API):].split("/") if p.startswith(API + "/releases/") else []
        if len(parts) == 4 and parts[3] == "assets" and m == "POST":
            if FAIL == "upload":
                return self.reply(500, {"message": "forced failure"})
            rid = int(parts[2])
            name = parse_qs(url.query)["name"][0]
            aid = 100 + len(assets)
            assets[aid] = {"release": rid, "name": name, "data": multipart_file(body, self.headers["Content-Type"])}
            return self.reply(201, {"id": aid})
        if len(parts) == 5 and parts[3] == "assets" and m == "GET":
            a = assets[int(parts[4])]
            tag = releases[a["release"]]["tag"]
            return self.reply(200, {"id": int(parts[4]), "browser_download_url": f"{base}/{REPO}/releases/download/{tag}/{a['name']}"})
        if len(parts) == 3 and m == "GET":
            r = releases.get(int(parts[2]))
            return self.reply(200, {"id": r["id"], "draft": r["draft"]}) if r else self.reply(404, {"message": "not found"})
        if len(parts) == 3 and m == "PATCH":
            if FAIL == "publish":
                return self.reply(500, {"message": "forced failure"})
            req = json.loads(body)
            r = releases[int(parts[2])]
            r["draft"] = req.get("draft", r["draft"])
            r["target"] = req.get("target_commitish", r["target"])
            if FAIL == "publish-lost":
                return self.reply(500, {"message": "forced failure after the change"})
            return self.reply(200, {"id": r["id"]})
        if len(parts) == 3 and m == "DELETE":
            releases.pop(int(parts[2]), None)
            return self.reply(204)
        if m == "GET" and p.startswith(f"/{REPO}/releases/download/"):
            tag, name = p.split("/")[-2:]
            for a in assets.values():
                r = releases.get(a["release"])
                if r and r["tag"] == tag and a["name"] == name and (not r["draft"] or self.headers.get("Authorization")):
                    return self.reply(200, a["data"], "application/zip")
            return self.reply(404, {"message": "not found"})
        if m == "GET" and p.startswith(f"/{REPO}/raw/branch/main/"):
            path = p[len(f"/{REPO}/raw/branch/main/"):]
            out = subprocess.run(["git", "--git-dir", ORIGIN, "show", f"main:{path}"], capture_output=True)
            return self.reply(200, out.stdout, "text/plain") if out.returncode == 0 else self.reply(404, {"message": "not found"})
        return self.reply(404, {"message": "no route"})

    do_GET = do_POST = do_PATCH = do_DELETE = do_HEAD = handle_any


class Server(ThreadingHTTPServer):
    # curl -f hangs up on an error status before reading the body: not a server error
    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


srv = Server(("127.0.0.1", 0), Handler)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write(str(srv.server_port))
os.rename(PORT_FILE + ".tmp", PORT_FILE)
srv.serve_forever()
