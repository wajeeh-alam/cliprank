import sqlite3
import threading
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS videos (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('session', 'library')),
  label TEXT CHECK (label IN ('good', 'bad')),
  filename TEXT NOT NULL,
  path TEXT NOT NULL,
  duration_ms INTEGER,
  status TEXT NOT NULL DEFAULT 'queued',
  progress TEXT,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS clips (
  id INTEGER PRIMARY KEY,
  video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  text TEXT NOT NULL DEFAULT '',
  ready INTEGER NOT NULL DEFAULT 0,
  score REAL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS swipes (
  id INTEGER PRIMARY KEY,
  a_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
  b_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
  choice TEXT NOT NULL CHECK (choice IN ('a', 'b', 'neither', 'skip')),
  decision_ms INTEGER,
  is_repeat INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS models (
  id INTEGER PRIMARY KEY,
  n_pairs INTEGER NOT NULL,
  metrics TEXT NOT NULL,
  path TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
"""


class DB:
    """Small thread-safe wrapper; the app is single-user so one connection is fine."""

    def __init__(self, path: Path | str):
        self.conn = sqlite3.connect(str(path), check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.execute("PRAGMA foreign_keys=ON")
            self.conn.executescript(SCHEMA)

    def all(self, sql: str, args=()) -> list[dict]:
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def one(self, sql: str, args=()) -> dict | None:
        rows = self.all(sql, args)
        return rows[0] if rows else None

    def run(self, sql: str, args=()) -> int:
        with self.lock:
            cur = self.conn.execute(sql, args)
            self.conn.commit()
            return cur.lastrowid
