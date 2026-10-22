"""Security smoke tests: python tests/test_security.py <empty-data-dir>"""
import os, re, sys, time
os.environ.update(STUDIO_DATA=sys.argv[1], STUDIO_SECRET_KEY="test-secret", STUDIO_LINK_SECRET="link-secret",
                  STUDIO_ADMIN_PASSWORD="admin-pass-123456", STUDIO_SEED_STREAM_KEY="seedkey123")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import app as studio
c = studio.app.test_client()
def csrf(html): return re.search(r'name="csrf_token" value="([^"]+)"', html).group(1)
def check(label, cond): print(("PASS " if cond else "FAIL ") + label); assert cond

r = c.get("/studio/"); check("dashboard requires login (redirect)", r.status_code == 302)
tok = csrf(c.get("/studio/login").text)
r = c.post("/studio/login", data={"username": "admin", "password": "x"}); check("POST without CSRF token -> 400", r.status_code == 400)
r = c.post("/studio/login", data={"csrf_token": tok, "username": "admin", "password": "wrong"}); check("wrong password rejected", "Invalid username or password" in r.text)
r = c.post("/studio/login", data={"csrf_token": tok, "username": "admin", "password": "admin-pass-123456"}); check("admin login ok", r.status_code == 302)
d = c.get("/studio/").text; tok = csrf(d); check("system channel 'stream' seeded", ">stream" in d or "stream\n" in d)
r = c.post("/studio/channels", data={"csrf_token": tok, "name": "Bad Name!"}); check("invalid channel name refused", "Channel names" in c.get("/studio/").text)
c.post("/studio/channels", data={"csrf_token": tok, "name": "demo"})
c.post("/studio/channels", data={"csrf_token": tok, "name": "secret-cam", "private": "1"})
for url, why in [("http://169.254.169.254/latest/meta-data/", "metadata IP"),
                 ("http://127.0.0.1/x.mp4", "loopback"), ("http://192.168.0.10/x.mp4", "VPC"),
                 ("file:///etc/passwd", "file scheme"), ("http://example.com:8080/x", "odd port"),
                 ("http://localhost/x", "localhost name"), ("http://user:pw@example.com/x", "creds")]:
    c.post("/studio/channels/demo/import", data={"csrf_token": tok, "url": url})
    check(f"SSRF import blocked: {why}", "Import blocked" in c.get("/studio/").text)
# publish auth (direct, as nginx-rtmp would call it)
def pa(**a): return c.get("/studio/internal/publish-auth", query_string=a, environ_base={"REMOTE_ADDR": "127.0.0.1"}).status_code
key = studio.connect().execute("select stream_key from channels where name='demo'").fetchone()[0]
check("publish: right key -> 200", pa(app="live", name="demo", key=key) == 200)
check("publish: wrong key -> 403", pa(app="live", name="demo", key="nope") == 403)
check("publish: public channel on private app -> 403", pa(app="private", name="demo", key=key) == 403)
check("publish: seeded system key -> 200", pa(app="live", name="stream", key="seedkey123") == 200)
r = c.get("/studio/internal/publish-auth", query_string={"app":"live","name":"demo","key":key}, headers={"X-Forwarded-For": "1.2.3.4"}, environ_base={"REMOTE_ADDR": "127.0.0.1"})
check("publish-auth via reverse proxy (X-Forwarded-For) -> 404", r.status_code == 404)
# private channel: share link
r = c.post("/studio/channels/secret-cam/share", data={"csrf_token": tok}, follow_redirects=True)
link = re.search(r'(http://[^<"]+/studio/watch/secret-cam\?[^<"]+)', r.text).group(1).replace("&amp;", "&")
anon = studio.app.test_client()
check("private watch without link -> 404", anon.get("/studio/watch/secret-cam").status_code == 404)
w = anon.get(link.split("localhost", 1)[1]); check("private watch with share link -> 200 + signed src", w.status_code == 200 and "/private/" in w.text)
check("tampered share link -> 404", anon.get(link.split("localhost",1)[1].replace("s=", "s=0")).status_code == 404)
src = re.search(r'data-src="([^"]+)"', w.text).group(1)
def pb(uri): return anon.get("/studio/internal/playback-auth", headers={"X-Original-URI": uri}, environ_base={"REMOTE_ADDR": "127.0.0.1"}).status_code
check("signed playlist URL -> 204", pb(src) == 204)
check("segment under same signed prefix -> 204", pb(src.replace("secret-cam.m3u8", "secret-cam-17.ts")) == 204)
check("token reused for another channel -> 403", pb(src.replace("secret-cam.m3u8", "demo.m3u8")) == 403)
check("tampered token -> 403", pb(src.replace("/private/", "/private/A", 1)[:-1]) == 403 or pb("/private/" + "A"*43 + src.split("/private/")[1][43:]) == 403)
exp = src.split("/")[3]
check("expired token -> 403", pb(src.replace(exp, "1700000000")) == 403)
c.post("/studio/channels/secret-cam/revoke-links", data={"csrf_token": tok})
check("revoked share link -> 404", anon.get(link.split("localhost", 1)[1]).status_code == 404)
# users / roles
c.post("/studio/admin/users", data={"csrf_token": tok, "username": "alice", "password": "short"})
check("weak password refused", "at least 12" in c.get("/studio/admin").text)
c.post("/studio/admin/users", data={"csrf_token": tok, "username": "alice", "password": "alice-password-1"})
u = studio.app.test_client(); t2 = csrf(u.get("/studio/login").text)
u.post("/studio/login", data={"csrf_token": t2, "username": "alice", "password": "alice-password-1"})
check("normal user can't open admin -> 403", u.get("/studio/admin").status_code == 403)
t2 = csrf(u.get("/studio/").text)
check("normal user can't touch admin's channel -> 404", u.post("/studio/channels/demo/rotate-key", data={"csrf_token": t2}).status_code == 404)
check("normal user doesn't see others' channels", "secret-cam" not in u.get("/studio/").text)
# brute force lockout
b = studio.app.test_client(); t3 = csrf(b.get("/studio/login").text)
for _ in range(5): b.post("/studio/login", data={"csrf_token": t3, "username": "alice", "password": "bad"})
r = b.post("/studio/login", data={"csrf_token": t3, "username": "alice", "password": "alice-password-1"})
check("account locked after 5 failures (even with right password) -> 429", r.status_code == 429)
log = c.get("/studio/admin").text
check("audit log records denials", "publish_denied" in log and "import_blocked" in log and "login_failed" in log)
check("stream key never written to audit log", key not in log and "seedkey123" not in log)
print("ALL TESTS PASSED")
