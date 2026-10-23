"""Disposable fake GitHub for the fm-lab: serves api.github.localhost through an HTTP proxy port.

Identity comes only from the Authorization header the real gh sends. acme-corp/private-repo
is private (only the company account reads it); fmlab-personal/public-repo is public.
While each request is in flight it snapshots every process command line and records
whether any lab token appears in one.
"""
import http.server, json, os, re, subprocess, sys, time
from urllib.parse import urlsplit

TOKENS = {os.environ["FMLAB_ACME_TOKEN"]: "acme", os.environ["FMLAB_PERSONAL_TOKEN"]: "personal"}
LOG = os.environ["FMLAB_REQUEST_LOG"]
NOW = "2026-10-23T08:00:00Z"
REPOS = {
    "acme-corp/private-repo": {"private": True, "readers": {"acme"}, "push": {"acme": True},
                               "pulls": {42: "1" * 40}},
    "fmlab-personal/public-repo": {"private": False, "readers": None, "push": {"personal": True},
                                   "pulls": {7: "2" * 40}},
}

SCAN = os.environ["FMLAB_SCAN_DIR"]

def file_hits():
    hits = []
    for root, _, files in os.walk(SCAN):
        for name in files:
            path = os.path.join(root, name)
            try:
                data = open(path, "rb").read()
            except OSError:
                continue
            for tok, who in TOKENS.items():
                if tok.encode() in data:
                    hits.append("%s holds the %s token" % (path, who))
    return hits

def argv_hits():
    out = subprocess.run(["ps", "-axww", "-o", "pid=,args="], capture_output=True, text=True).stdout
    hits = []
    for line in out.splitlines():
        for tok, who in TOKENS.items():
            if tok in line:
                hits.append(line.replace(tok, "<%s-token>" % who)[:300])
    return hits

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def identity(self):
        auth = self.headers.get("Authorization") or ""
        m = re.match(r"(?i)(token|bearer)\s+(.+)", auth)
        if not m:
            return "anonymous"
        return TOKENS.get(m.group(2).strip(), "unknown")

    def reply(self, status, body, who, extra=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        rec = {"t": time.time(), "method": self.command, "path": urlsplit(self.path).path,
               "query": urlsplit(self.path).query, "identity": who, "status": status,
               "token_in_any_argv": bool(self._hits), "argv_hits": self._hits,
               "token_in_product_tmp_file": bool(self._fhits), "file_hits": self._fhits,
               "product_tmp_dirs_scanned": sorted(d for d in os.listdir(SCAN) if d.startswith("fm-contributions."))}
        if extra:
            rec.update(extra)
        with open(LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")

    def repo(self, owner, name):
        return REPOS.get(("%s/%s" % (owner, name)).lower())

    def readable(self, r, who):
        return r is not None and (r["readers"] is None or who in r["readers"])

    def do_GET(self):
        self._hits = argv_hits()
        self._fhits = file_hits()
        who = self.identity()
        u = urlsplit(self.path)
        if u.hostname != "api.github.localhost":
            return self.reply(502, {"message": "lab refuses non-lab host %s" % u.hostname}, who)
        parts = u.path.strip("/").split("/")
        if len(parts) < 3 or parts[0] != "repos":
            return self.reply(404, {"message": "Not Found"}, who)
        r = self.repo(parts[1], parts[2])
        if not self.readable(r, who):
            return self.reply(404, {"message": "Not Found", "documentation_url": "https://docs.github.com/rest", "status": "404"}, who)
        rest = parts[3:]
        full = "%s/%s" % (parts[1], parts[2])
        if not rest:
            return self.reply(200, {"full_name": full, "private": r["private"],
                                    "permissions": {"admin": False, "push": r["push"].get(who, False), "pull": True}}, who)
        if rest[0] == "pulls" and len(rest) == 2:
            n = int(rest[1]); head = r["pulls"].get(n)
            if head is None:
                return self.reply(404, {"message": "Not Found"}, who)
            return self.reply(200, {"number": n, "state": "open", "user": {"login": "lab-author"}, "head": {"sha": head},
                                    "draft": False, "mergeable": True, "merged_at": None}, who)
        if rest[0] == "pulls" and len(rest) == 3 and rest[2] in ("reviews", "comments"):
            return self.reply(200, [], who)
        if rest[0] == "issues" and len(rest) == 3 and rest[2] == "comments":
            return self.reply(200, [], who)
        if rest[0] == "commits" and len(rest) == 3 and rest[2] == "check-runs":
            return self.reply(200, {"total_count": 1, "check_runs": [{"name": "test", "id": 1, "status": "completed",
                                                                       "conclusion": "success", "started_at": NOW}]}, who)
        if rest[0] == "commits" and len(rest) == 3 and rest[2] == "statuses":
            return self.reply(200, [], who)
        return self.reply(404, {"message": "Not Found"}, who)

    def do_POST(self):
        self._hits = argv_hits()
        self._fhits = file_hits()
        who = self.identity()
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        v = body.get("variables", {})
        r = self.repo(v.get("owner", ""), v.get("repo", ""))
        if not self.readable(r, who):
            return self.reply(200, {"data": {"repository": None}, "errors": [{"type": "NOT_FOUND", "path": ["repository"],
                "message": "Could not resolve to a Repository with the name '%s/%s'." % (v.get("owner"), v.get("repo"))}]},
                who, {"graphql": "PullRequestByNumber"})
        head = r["pulls"].get(v.get("pr_number"))
        return self.reply(200, {"data": {"repository": {"pullRequest": {"headRefOid": head, "reviewDecision": "APPROVED",
                                "id": "PR_lab", "number": v.get("pr_number")}}}}, who, {"graphql": "PullRequestByNumber"})

    def log_message(self, *a):
        pass

s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
