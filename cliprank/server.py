"""Web server. Runs on your computer; you use it from your phone on the same Wi-Fi."""

import argparse
import bisect
import json
import logging
import re
import secrets
import socket
import threading
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel

from cliprank import config, media, model, pairs, performance
from cliprank.db import DB
from cliprank.pipeline import Worker, clip_path, thumb_path

log = logging.getLogger("cliprank")
STATIC = Path(__file__).parent / "static"


class Trainer:
    """Retrains in a background thread so swiping never waits on it."""

    def __init__(self, db):
        self.db = db
        self.wake = threading.Event()
        self.busy = False
        self.error = None
        threading.Thread(target=self._loop, daemon=True).start()

    def request(self):
        self.wake.set()

    def _loop(self):
        while True:
            self.wake.wait()
            self.wake.clear()
            self.busy = True
            try:
                m = model.train(self.db)
                self.error = None
                if m:
                    log.info("retrained on %d swipes, new-video accuracy %s", m["n_swipes"], m["new_video_accuracy"])
            except Exception as exc:
                log.exception("training failed")
                self.error = str(exc)
            self.busy = False


class SwipeBody(BaseModel):
    a: int
    b: int
    choice: str
    decision_ms: int | None = None
    is_repeat: bool = False


class LabelBody(BaseModel):
    label: str | None


class PostBody(BaseModel):
    posted_on: str | None = None
    url: str | None = None
    views: int | None = None
    likes: int | None = None
    comments: int | None = None
    shares: int | None = None
    saves: int | None = None
    watched_pct: float | None = None


def create_app() -> FastAPI:
    config.make_dirs()
    db = DB(config.DB_PATH)
    token_file = config.DATA_DIR / "token.txt"
    if not token_file.exists():
        token_file.write_text(secrets.token_urlsafe(16))
    token = token_file.read_text().strip()

    trainer = Trainer(db)
    worker = Worker(db, on_done=trainer.request)
    worker.start()

    app = FastAPI()
    app.state.token = token

    def auth(request: Request):
        given = request.cookies.get("token") or request.headers.get("x-token") or ""
        if not secrets.compare_digest(given, token):
            raise HTTPException(401)

    @app.exception_handler(401)
    async def not_logged_in(request: Request, exc):
        if request.url.path.startswith(("/api", "/media")):
            return JSONResponse({"detail": "not logged in"}, status_code=401)
        return FileResponse(STATIC / "login.html", status_code=401)

    @app.get("/login")
    def login(t: str):
        if not secrets.compare_digest(t, token):
            raise HTTPException(401)
        resp = RedirectResponse("/", status_code=303)
        resp.set_cookie("token", t, max_age=60 * 60 * 24 * 365, httponly=True, samesite="lax")
        return resp

    # Pages
    @app.get("/", dependencies=[Depends(auth)])
    def swipe_page():
        return FileResponse(STATIC / "swipe.html")

    @app.get("/upload", dependencies=[Depends(auth)])
    def upload_page():
        return FileResponse(STATIC / "upload.html")

    @app.get("/stats", dependencies=[Depends(auth)])
    def stats_page():
        return FileResponse(STATIC / "stats.html")

    @app.get("/posted", dependencies=[Depends(auth)])
    def posted_page():
        return FileResponse(STATIC / "posted.html")

    @app.get("/video/{vid}", dependencies=[Depends(auth)])
    def results_page(vid: int):
        return FileResponse(STATIC / "results.html")

    @app.get("/static/{name}")
    def static(name: str):
        path = STATIC / Path(name).name
        if not path.exists():
            raise HTTPException(404)
        return FileResponse(path)

    # Videos
    @app.post("/api/upload", dependencies=[Depends(auth)])
    async def upload(request: Request, filename: str, kind: str = "session", label: str | None = None):
        if kind not in ("session", "edit", "library") or label not in (None, "", "good", "bad"):
            raise HTTPException(400, "bad kind or label")
        name = secrets.token_hex(4) + "-" + (re.sub(r"[^\w.-]", "_", filename)[-80:] or "video.mp4")
        size = 0
        with open(config.UPLOADS / name, "wb") as f:
            async for chunk in request.stream():  # stream to disk; videos can be several GB
                f.write(chunk)
                size += len(chunk)
        if not size:
            (config.UPLOADS / name).unlink()
            raise HTTPException(400, "empty file")
        vid = db.run("INSERT INTO videos (kind, label, filename, path) VALUES (?, ?, ?, ?)",
                     (kind, label or None, filename, name))
        worker.notify()
        return {"id": vid, "bytes": size}

    @app.get("/api/videos", dependencies=[Depends(auth)])
    def videos():
        return db.all("""SELECT v.*, (SELECT COUNT(*) FROM clips c WHERE c.video_id = v.id AND c.ready = 1) AS n_clips
                         FROM videos v ORDER BY v.id DESC""")

    @app.post("/api/videos/{vid}/label", dependencies=[Depends(auth)])
    def set_label(vid: int, body: LabelBody):
        if body.label not in (None, "good", "bad"):
            raise HTTPException(400)
        db.run("UPDATE videos SET label = ? WHERE id = ? AND kind = 'library'", (body.label, vid))
        trainer.request()
        return {}

    @app.post("/api/videos/{vid}/retry", dependencies=[Depends(auth)])
    def retry(vid: int):
        db.run("UPDATE videos SET status = 'queued', error = NULL WHERE id = ? AND status = 'failed'", (vid,))
        worker.notify()
        return {}

    @app.delete("/api/videos/{vid}", dependencies=[Depends(auth)])
    def delete_video(vid: int):
        video = db.one("SELECT * FROM videos WHERE id = ?", (vid,))
        if not video:
            raise HTTPException(404)
        if video["status"] == "processing":
            raise HTTPException(409, "still processing")
        worker.delete_clips(vid)
        (config.UPLOADS / video["path"]).unlink(missing_ok=True)
        db.run("DELETE FROM videos WHERE id = ?", (vid,))
        trainer.request()
        return {}

    # Swiping
    def clip_info(cid):
        c = db.one("SELECT id, start_ms, end_ms, text FROM clips WHERE id = ?", (cid,))
        c["url"], c["poster"] = f"/media/clip/{cid}", f"/media/thumb/{cid}"
        return c

    @app.get("/api/pair", dependencies=[Depends(auth)])
    def get_pair():
        p = pairs.next_pair(db)
        if not p:
            return {"a": None}
        return {"a": clip_info(p["a"]), "b": clip_info(p["b"]), "is_repeat": p["is_repeat"]}

    @app.post("/api/swipe", dependencies=[Depends(auth)])
    def swipe(body: SwipeBody):
        if body.choice not in ("a", "b", "skip"):
            raise HTTPException(400)
        db.run("INSERT INTO swipes (a_id, b_id, choice, decision_ms, is_repeat) VALUES (?, ?, ?, ?, ?)",
               (body.a, body.b, body.choice, body.decision_ms, int(body.is_repeat)))
        n = db.one("SELECT COUNT(*) AS n FROM swipes WHERE choice != 'skip'")["n"]
        if body.choice != "skip" and n % config.RETRAIN_EVERY == 0:
            trainer.request()
        return {"swipes": n}

    @app.post("/api/undo", dependencies=[Depends(auth)])
    def undo():
        """Delete the last swipe and send that pair back so you can redo it."""
        last = db.one("SELECT * FROM swipes ORDER BY id DESC LIMIT 1")
        if last:
            db.run("DELETE FROM swipes WHERE id = ?", (last["id"],))
        n = db.one("SELECT COUNT(*) AS n FROM swipes WHERE choice != 'skip'")["n"]
        if not last:
            return {"swipes": n, "a": None}
        return {"swipes": n, "a": clip_info(last["a_id"]), "b": clip_info(last["b_id"]),
                "is_repeat": bool(last["is_repeat"])}

    # Model
    @app.post("/api/train", dependencies=[Depends(auth)])
    def train_now():
        trainer.request()
        return {}

    @app.get("/api/stats", dependencies=[Depends(auth)])
    def stats():
        counts = db.one("""SELECT
            (SELECT COUNT(*) FROM swipes WHERE choice != 'skip') AS swipes,
            (SELECT COUNT(*) FROM clips WHERE ready = 1) AS clips,
            (SELECT COUNT(*) FROM videos WHERE label = 'good') AS good,
            (SELECT COUNT(*) FROM videos WHERE label = 'bad') AS bad""")
        runs = [json.loads(r["metrics"]) for r in db.all("SELECT metrics FROM models ORDER BY id")]
        ranked = """SELECT c.id, c.text, c.score, v.kind, v.label FROM clips c JOIN videos v ON v.id = c.video_id
                    WHERE c.score IS NOT NULL ORDER BY c.score {} LIMIT {}"""
        return {
            "counts": counts,
            "latest": runs[-1] if runs else None,
            "history": runs,
            "training": trainer.busy,
            "error": trainer.error,
            "top": db.all(ranked.format("DESC", 10)),
            "bottom": db.all(ranked.format("ASC", 5)),
            "performance": performance.summary(db),
        }

    # Posts: clips you actually posted, with the numbers you type in from the app.
    @app.get("/api/posts", dependencies=[Depends(auth)])
    def list_posts():
        not_added = db.all("""SELECT c.id AS clip_id, v.filename, v.label FROM clips c JOIN videos v ON v.id = c.video_id
                            WHERE v.kind = 'library' AND v.status = 'ready' AND c.ready = 1
                              AND c.id NOT IN (SELECT clip_id FROM posts) ORDER BY v.id DESC""")
        return {"posts": performance.posts(db), "old_posts_not_added": not_added}

    @app.post("/api/clips/{cid}/post", dependencies=[Depends(auth)])
    def mark_posted(cid: int):
        if not db.one("SELECT id FROM clips WHERE id = ?", (cid,)):
            raise HTTPException(404)
        db.run("INSERT OR IGNORE INTO posts (clip_id) VALUES (?)", (cid,))
        return db.one("SELECT id FROM posts WHERE clip_id = ?", (cid,))

    @app.patch("/api/posts/{pid}", dependencies=[Depends(auth)])
    def update_post(pid: int, body: PostBody):
        fields = body.model_dump(exclude_unset=True)
        if not db.one("SELECT id FROM posts WHERE id = ?", (pid,)):
            raise HTTPException(404)
        if any(v is not None and v < 0 for k, v in fields.items() if k in performance.NUMBERS):
            raise HTTPException(400, "numbers can't be negative")
        if fields:
            sets = ", ".join(f"{k} = ?" for k in fields)  # keys come from PostBody, not the request
            db.run(f"UPDATE posts SET {sets}, updated_at = CURRENT_TIMESTAMP WHERE id = ?", (*fields.values(), pid))
        return {}

    @app.delete("/api/posts/{pid}", dependencies=[Depends(auth)])
    def delete_post(pid: int):
        db.run("DELETE FROM posts WHERE id = ?", (pid,))
        return {}

    # Results for one video: its takes, best first, and every version of each take.
    @app.get("/api/videos/{vid}/results", dependencies=[Depends(auth)])
    def results(vid: int):
        video = db.one("SELECT id, kind, filename, status, duration_ms FROM videos WHERE id = ?", (vid,))
        if not video:
            raise HTTPException(404)
        # "Better than X% of your clips", compared with every clip you swipe on.
        pool = sorted(r["score"] for r in db.all("""SELECT c.score FROM clips c JOIN videos v ON v.id = c.video_id
                      WHERE c.score IS NOT NULL AND v.kind IN ('session', 'edit') AND v.status = 'ready'"""))
        takes = {}
        for c in db.all("""SELECT c.id, c.start_ms, c.end_ms, c.text, c.take, c.score, p.id AS post_id
                           FROM clips c LEFT JOIN posts p ON p.clip_id = c.id
                           WHERE c.video_id = ? AND c.ready = 1""", (vid,)):
            c["percentile"] = bisect.bisect_left(pool, c["score"]) / len(pool) if c["score"] is not None else None
            c["url"], c["poster"], c["download"] = f"/media/clip/{c['id']}", f"/media/thumb/{c['id']}", f"/media/export/{c['id']}"
            takes.setdefault(c["take"] or 0, []).append(c)

        def best_first(c):
            return (c["score"] is None, -(c["score"] or 0), c["start_ms"])
        out = []
        for t, clips in takes.items():
            clips.sort(key=best_first)
            out.append({"take": t, "start_ms": min(c["start_ms"] for c in clips), "clips": clips})
        out.sort(key=lambda t: best_first(t["clips"][0]))
        return {"video": video, "scored": bool(pool), "takes": out}

    # Media
    @app.get("/media/clip/{cid}", dependencies=[Depends(auth)])
    def media_clip(cid: int):
        if not clip_path(cid).exists():
            raise HTTPException(404)
        return FileResponse(clip_path(cid), media_type="video/mp4")

    def prepare_export(cid):
        """Cut the clip again from the original upload, at full quality. Cached after the first time."""
        c = db.one("""SELECT c.start_ms, c.end_ms, v.path, v.filename FROM clips c JOIN videos v ON v.id = c.video_id
                     WHERE c.id = ?""", (cid,))
        if not c:
            raise HTTPException(404)
        src = config.UPLOADS / c["path"]
        if src.suffix.lower() in media.IMAGE_TYPES:
            src = src.with_suffix(".mp4")
        if not src.exists():
            raise HTTPException(404, "The original upload is gone, so only the 720p clip is left.")
        out = config.EXPORTS / f"{cid}.mp4"
        if not out.exists():
            tmp = out.with_name(f"{cid}-{secrets.token_hex(4)}.mp4")
            media.export(src, c["start_ms"], c["end_ms"], tmp)
            tmp.replace(out)
        return out, f"{Path(c['filename']).stem}-{c['start_ms'] // 1000}s-{c['end_ms'] // 1000}s.mp4"

    @app.post("/api/clips/{cid}/export", dependencies=[Depends(auth)])
    def export(cid: int):
        prepare_export(cid)
        return {"url": f"/media/export/{cid}"}

    @app.get("/media/export/{cid}", dependencies=[Depends(auth)])
    def media_export(cid: int):
        out, name = prepare_export(cid)
        return FileResponse(out, media_type="video/mp4", filename=name)

    @app.get("/media/thumb/{cid}", dependencies=[Depends(auth)])
    def media_thumb(cid: int):
        if not thumb_path(cid).exists():
            raise HTTPException(404)
        return FileResponse(thumb_path(cid), media_type="image/jpeg")

    return app


def local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    import qrcode
    import uvicorn

    parser = argparse.ArgumentParser(description="cliprank: start the app, or `cliprank eval` to compare models")
    parser.add_argument("command", nargs="?", default="serve", choices=["serve", "eval"])
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

    if args.command == "eval":
        import warnings

        from cliprank import evaluate
        warnings.filterwarnings("ignore")  # sklearn convergence chatter
        config.make_dirs()
        evaluate.run(DB(config.DB_PATH))
        return

    app = create_app()
    url = f"http://{local_ip()}:{args.port}/login?t={app.state.token}"
    qr = qrcode.QRCode(border=1)
    qr.add_data(url)
    print("\nScan with your phone (same Wi-Fi):\n")
    qr.print_ascii(invert=True)
    print(f"\n{url}\n")
    uvicorn.run(app, host="0.0.0.0", port=args.port, log_level="warning")
