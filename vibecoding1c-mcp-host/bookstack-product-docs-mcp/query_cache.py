"""Disposable query vectors; the document index remains authoritative."""
import logging
import sqlite3
import sys
import threading
import time
from array import array
from pathlib import Path

from fragment_index import checked_vector


class QueryVectorCache:
    def __init__(self, path, limit, ttl_seconds):
        self.path = path
        self.limit = limit
        self.ttl_seconds = ttl_seconds
        self._lock = threading.Lock()

    def _connect(self):
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.path, timeout=0.1)
        try:
            conn.execute("""CREATE TABLE IF NOT EXISTS query_vectors (
                key TEXT PRIMARY KEY, created REAL NOT NULL, used REAL NOT NULL, vector BLOB NOT NULL)""")
            return conn
        except Exception:
            conn.close()
            raise

    def get(self, key, dimensions=None):
        if not self.path or not self.ttl_seconds:
            return None
        try:
            with self._lock:
                conn = self._connect()
                try:
                    now = time.time()
                    with conn:
                        conn.execute("DELETE FROM query_vectors WHERE created<?", (now - self.ttl_seconds,))
                        row = conn.execute("SELECT vector FROM query_vectors WHERE key=?", (key,)).fetchone()
                        if row is None:
                            return None
                        vector = array("d")
                        vector.frombytes(row[0])
                        if sys.byteorder != "little":
                            vector.byteswap()
                        try:
                            checked_vector(vector, dimensions)
                        except ValueError:
                            conn.execute("DELETE FROM query_vectors WHERE key=?", (key,))
                            return None
                        conn.execute("UPDATE query_vectors SET used=? WHERE key=?", (now, key))
                        return vector
                finally:
                    conn.close()
        except Exception as exc:
            logging.warning("BookStack query vector cache read failed (%s)", type(exc).__name__)
            return None

    def put(self, key, values):
        if not self.path or not self.ttl_seconds or not values:
            return
        try:
            vector = array("d", checked_vector(values))
            if sys.byteorder != "little":
                vector.byteswap()
            with self._lock:
                conn = self._connect()
                try:
                    now = time.time()
                    with conn:
                        conn.execute("DELETE FROM query_vectors WHERE created<?", (now - self.ttl_seconds,))
                        conn.execute("INSERT OR REPLACE INTO query_vectors VALUES (?,?,?,?)",
                                     (key, now, now, vector.tobytes()))
                        conn.execute("""DELETE FROM query_vectors WHERE key IN (
                            SELECT key FROM query_vectors ORDER BY used DESC LIMIT -1 OFFSET ?)""", (self.limit,))
                finally:
                    conn.close()
        except Exception as exc:
            logging.warning("BookStack query vector cache write failed (%s)", type(exc).__name__)
