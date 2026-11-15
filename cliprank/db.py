import sqlite3
import threading

SCHEMA = """
CREATE TABLE IF NOT EXISTS videos (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,              -- 'session' (cut into clips), 'edit' (kept whole) or 'library' (old post)
  label TEXT,                      -- old posts only: 'good' or 'bad'
  filename TEXT NOT NULL,
  path TEXT NOT NULL,
  duration_ms INTEGER,
  status TEXT NOT NULL DEFAULT 'queued',   -- queued, processing, ready, failed
  progress TEXT,
  error TEXT,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS clips (
  id INTEGER PRIMARY KEY,
  video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  text TEXT NOT NULL DEFAULT '',
  ready INTEGER NOT NULL DEFAULT 0,
  score REAL                       -- from the latest model
);
CREATE TABLE IF NOT EXISTS swipes (
  id INTEGER PRIMARY KEY,
  a_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
  b_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
  choice TEXT NOT NULL,            -- 'a', 'b' or 'skip'
  decision_ms INTEGER,
  is_repeat INTEGER NOT NULL DEFAULT 0,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS models (
  id INTEGER PRIMARY KEY,
  n_pairs INTEGER NOT NULL,
  metrics TEXT NOT NULL,
  path TEXT NOT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
"""


class DB:
    """One shared SQLite connection behind a lock. Fine for a single user."""

    def __init__(self, path):
        self.conn = sqlite3.connect(str(path), check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.conn.execute("PRAGMA foreign_keys = ON")
        self.conn.executescript(SCHEMA)

    def all(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, args)]

    def one(self, sql, args=()):
        rows = self.all(sql, args)
        return rows[0] if rows else None

    def run(self, sql, args=()):
        with self.lock:
            cur = self.conn.execute(sql, args)
            self.conn.commit()
            return cur.lastrowid
