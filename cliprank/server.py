"""FastAPI app. Run it on your computer; use it from your phone on the same Wi-Fi."""

import argparse
import json
import logging
import re
import secrets
import shutil
import socket
import threading
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, RedirectResponse
from pydantic import BaseModel

from cliprank import config, model, pairs
from cliprank.db import DB
from cliprank.pipeline import Worker, clip_path, thumb_path

log = logging.getLogger("cliprank")
STATIC = Path(__file__).parent / "static"
COOKIE = "cliprank_token"


class Trainer:
    def __init__(self, db: DB):
        self.db = db
        self.wake = threading.Event()
        self.running = False
        self.last_error: str | None = None
        threading.Thread(target=self._loop, daemon=True, name="trainer").start()

    def request(self):
        self.wake.set()

    def _loop(self):
        while True:
            self.wake.wait()
            self.wake.clear()
            self.running = True
            try:
                m = model.train(self.db)
                self.last_error = None
                if m:
                    log.info("trained: cv=%s unseen=%s n=%s", m["cv_accuracy"], m["unseen_clip_accuracy"], m["n_swipes"])
            except Exception as exc:
                log.exception("training failed")
                self.last_error = str(exc)
            finally:
                self.running = False


def load_token() -> str:
    path = config.DATA_DIR / "token.txt"
    if path.exists():
        return path.read_text().strip()
    token = secrets.token_urlsafe(16)
    path.write_text(token)
    return token


def create_app() -> FastAPI:
    config.ensure_dirs()
    db = DB(config.DB_PATH)
    token = load_token()
    trainer = Trainer(db)

    class TrainingWorker(Worker):
        def process(self, video):
            super().process(video)
            trainer.request()  # rescore everything once new clips exist

    worker = TrainingWorker(db)
    worker.start()

    app = FastAPI(title="ClipRank")
    app.state.db, app.state.token = db, token

    def auth(request: Request):
        supplied = request.cookies.get(COOKIE) or request.headers.get("x-token")
        if not supplied or not secrets.compare_digest(supplied, token):
            raise HTTPException(401, "Open the login link printed in the terminal (or scan its QR code).")

    @app.exception_handler(401)
    async def unauthorized(request: Request, exc):
        if request.url.path.startswith("/api") or request.url.path.startswith("/media"):
            from fastapi.responses import JSONResponse
            return JSONResponse({"detail": exc.detail}, status_code=401)
        return FileResponse(STATIC / "login.html", status_code=401)

    # ---------- pages ----------

    @app.get("/login")
    def login(t: str):
        if not secrets.compare_digest(t, token):
            raise HTTPException(401, "bad token")
        resp = RedirectResponse("/", status_code=303)
        resp.set_cookie(COOKIE, t, max_age=60 * 60 * 24 * 365, httponly=True, samesite="lax")
        return resp

    for page in ("swipe", "upload", "stats"):
        def make(name):
            def handler(_=Depends(auth)):
                return FileResponse(STATIC / f"{name}.html")
            return handler
        app.get("/" if page == "swipe" else f"/{page}")(make(page))

    @app.get("/static/{name}")
    def static(name: str):
        path = (STATIC / name).resolve()
        if path.parent != STATIC.resolve() or not path.exists():
            raise HTTPException(404)
        return FileResponse(path)

    # ---------- uploads ----------

    @app.post("/api/upload", dependencies=[Depends(auth)])
    async def upload(request: Request, filename: str, kind: str = "session", label: str | None = None):
        if kind not in ("session", "library"):
            raise HTTPException(400, "kind must be session or library")
        if label not in (None, "", "good", "bad"):
            raise HTTPException(400, "label must be good or bad")
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", filename)[-80:] or "video.mp4"
        name = f"{secrets.token_hex(4)}-{safe}"
        dest = config.UPLOADS / name
        size = 0
        with open(dest, "wb") as f:
            async for chunk in request.stream():
                f.write(chunk)
                size += len(chunk)
        if size == 0:
            dest.unlink(missing_ok=True)
            raise HTTPException(400, "empty upload")
        vid = db.run("INSERT INTO videos (kind, label, filename, path) VALUES (?,?,?,?)",
                     (kind, label or None, filename, name))
        worker.notify()
        return {"id": vid, "bytes": size}

    @app.get("/api/videos", dependencies=[Depends(auth)])
    def videos():
        return db.all("""SELECT v.*, (SELECT COUNT(*) FROM clips c WHERE c.video_id=v.id AND c.ready=1) AS n_clips
                         FROM videos v ORDER BY v.id DESC""")

    class LabelBody(BaseModel):
        label: str | None

    @app.post("/api/videos/{vid}/label", dependencies=[Depends(auth)])
    def set_label(vid: int, body: LabelBody):
        if body.label not in (None, "good", "bad"):
            raise HTTPException(400, "label must be good, bad or null")
        db.run("UPDATE videos SET label=? WHERE id=? AND kind='library'", (body.label, vid))
        trainer.request()
        return {"ok": True}

    @app.post("/api/videos/{vid}/retry", dependencies=[Depends(auth)])
    def retry(vid: int):
        db.run("UPDATE videos SET status='queued', error=NULL WHERE id=?", (vid,))
        worker.notify()
        return {"ok": True}

    @app.delete("/api/videos/{vid}", dependencies=[Depends(auth)])
    def delete_video(vid: int):
        video = db.one("SELECT * FROM videos WHERE id=?", (vid,))
        if not video:
            raise HTTPException(404)
        if video["status"] == "processing":
            raise HTTPException(409, "wait for processing to finish")
        worker._clear_clips(vid)
        (config.UPLOADS / video["path"]).unlink(missing_ok=True)
        db.run("DELETE FROM videos WHERE id=?", (vid,))
        trainer.request()
        return {"ok": True}

    # ---------- swiping ----------

    def clip_json(cid: int):
        c = db.one("SELECT id, video_id, start_ms, end_ms, text, score FROM clips WHERE id=?", (cid,))
        if c:
            c["url"] = f"/media/clip/{cid}"
            c["poster"] = f"/media/thumb/{cid}"
        return c

    @app.get("/api/pair", dependencies=[Depends(auth)])
    def get_pair():
        p = pairs.next_pair(db)
        if not p:
            return {"a": None, "b": None, "reason": "Upload a session video first (it needs at least 2 clips)."}
        return {"a": clip_json(p["a"]), "b": clip_json(p["b"]), "is_repeat": p["is_repeat"]}

    class SwipeBody(BaseModel):
        a: int
        b: int
        choice: str
        decision_ms: int | None = None
        is_repeat: bool = False

    @app.post("/api/swipe", dependencies=[Depends(auth)])
    def swipe(body: SwipeBody):
        if body.choice not in ("a", "b", "neither", "skip"):
            raise HTTPException(400, "bad choice")
        db.run("INSERT INTO swipes (a_id, b_id, choice, decision_ms, is_repeat) VALUES (?,?,?,?,?)",
               (body.a, body.b, body.choice, body.decision_ms, int(body.is_repeat)))
        n = db.one("SELECT COUNT(*) AS n FROM swipes WHERE choice IN ('a','b')")["n"]
        if body.choice in ("a", "b") and n % config.RETRAIN_EVERY == 0:
            trainer.request()
        return {"decisive": n}

    @app.post("/api/undo", dependencies=[Depends(auth)])
    def undo():
        last = db.one("SELECT id FROM swipes ORDER BY id DESC LIMIT 1")
        if last:
            db.run("DELETE FROM swipes WHERE id=?", (last["id"],))
        return {"ok": True}

    # ---------- model ----------

    @app.post("/api/train", dependencies=[Depends(auth)])
    def train_now():
        trainer.request()
        return {"ok": True}

    @app.get("/api/stats", dependencies=[Depends(auth)])
    def stats():
        counts = db.one("""SELECT
            (SELECT COUNT(*) FROM swipes WHERE choice IN ('a','b')) AS decisive,
            (SELECT COUNT(*) FROM swipes) AS total,
            (SELECT COUNT(*) FROM clips WHERE ready=1) AS clips,
            (SELECT COUNT(*) FROM videos WHERE kind='library' AND label='good') AS lib_good,
            (SELECT COUNT(*) FROM videos WHERE kind='library' AND label='bad') AS lib_bad""")
        latest = db.one("SELECT * FROM models ORDER BY id DESC LIMIT 1")
        history = db.all("SELECT n_pairs, metrics, created_at FROM models ORDER BY id")
        top = db.all("""SELECT c.id, c.text, c.score, v.kind, v.label FROM clips c JOIN videos v ON v.id=c.video_id
                        WHERE c.score IS NOT NULL ORDER BY c.score DESC LIMIT 10""")
        bottom = db.all("""SELECT c.id, c.text, c.score, v.kind, v.label FROM clips c JOIN videos v ON v.id=c.video_id
                           WHERE c.score IS NOT NULL ORDER BY c.score ASC LIMIT 5""")
        return {
            "counts": counts,
            "metrics": json.loads(latest["metrics"]) if latest else None,
            "history": [{"n": h["n_pairs"], **json.loads(h["metrics"])} for h in history],
            "training": trainer.running,
            "train_error": trainer.last_error,
            "top": top,
            "bottom": bottom,
        }

    # ---------- media ----------

    @app.get("/media/clip/{cid}", dependencies=[Depends(auth)])
    def media_clip(cid: int):
        p = clip_path(cid)
        if not p.exists():
            raise HTTPException(404)
        return FileResponse(p, media_type="video/mp4")

    @app.get("/media/thumb/{cid}", dependencies=[Depends(auth)])
    def media_thumb(cid: int):
        p = thumb_path(cid)
        if not p.exists():
            raise HTTPException(404)
        return FileResponse(p, media_type="image/jpeg")

    return app


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    import uvicorn

    parser = argparse.ArgumentParser(description="ClipRank: learn your taste from swipes")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")

    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg is required: brew install ffmpeg")
    app = create_app()
    url = f"http://{lan_ip()}:{args.port}/login?t={app.state.token}"
    print("\nOpen this on your phone (same Wi-Fi), or scan the QR code:\n")
    try:
        import qrcode
        qr = qrcode.QRCode(border=1)
        qr.add_data(url)
        qr.print_ascii(invert=True)
    except Exception:
        pass
    print(f"  {url}\n")
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
