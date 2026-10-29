"""Document session management for the MCP tool layer.

Every tool takes a *path*, and an MCP client may call the tools repeatedly on the
same document, or interleave calls on several documents. pdfplumber keeps an open
file handle and lazily-built page objects per extractor, so re-opening a file for
every call is wasteful and sharing one extractor between concurrent calls is
unsafe: ``pdfplumber``/``pdfminer`` are not thread-safe.

This module owns both concerns:

* **Caching by file identity.** A session is cached under
  ``(resolved_path, password, st_mtime_ns, st_size)``. If the bytes on disk change
  (a new mtime or size) or the password differs, the cache misses and the file is
  re-opened, so callers never read a stale revision through a stale extractor.
* **One lock per document.** ``session()`` yields while holding the session's
  lock, so two threads can never drive the same extractor at the same time. The
  manager's own ``RLock`` protects the cache dict and LRU order only, so threads
  working on different documents do not block each other.

The cache is bounded (``max_documents``, default 8). Eviction closes the least
recently used session *before* dropping it, and never closes a session another
thread is still using: an in-use session is skipped for that round and the cache
may briefly exceed its bound rather than pull a file handle out from under a
caller.

``get_default_manager()`` provides the process-wide manager the MCP server uses,
with an optional ``PDF_INSPECTOR_MCP_MAX_DOCS`` override.
"""

from __future__ import annotations

import os
import threading
from collections import OrderedDict
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, Optional, Tuple

from .extractor import PdfExtractor

__all__ = [
    'DEFAULT_MAX_DOCUMENTS',
    'MAX_DOCUMENTS_ENV_VAR',
    'DocumentSession',
    'DocumentManager',
    'get_default_manager',
]

#: Cache bound used when neither the constructor nor the environment overrides it.
DEFAULT_MAX_DOCUMENTS = 8

#: Environment variable that overrides ``get_default_manager()``'s cache bound.
MAX_DOCUMENTS_ENV_VAR = 'PDF_INSPECTOR_MCP_MAX_DOCS'

#: ``(resolved_path, password, st_mtime_ns, st_size)``.
SessionKey = Tuple[str, Optional[str], int, int]


def _resolve_document_path(path: str) -> str:
    """Validate ``path`` and return its absolute, symlink-resolved form.

    The path must name an existing regular file; everything else (empty input,
    missing file, directory, unreadable path) raises ``ValueError`` whose message
    quotes what was received and says why it was rejected. A ``.pdf`` suffix is
    *not* required, matching the upstream sidecar, which happily opens whatever
    path it is handed and lets pdfplumber decide.
    """
    if not isinstance(path, str):
        raise ValueError(f'Invalid PDF path: {path!r} (expected a string path)')
    if not path.strip():
        raise ValueError(f'Invalid PDF path: {path!r} (the path is empty)')

    try:
        resolved = Path(path).expanduser().resolve()
    except (OSError, RuntimeError) as exc:
        raise ValueError(f'Invalid PDF path: {path!r} (cannot resolve it: {exc})') from exc

    if not resolved.exists():
        raise ValueError(f'Invalid PDF path: {path!r} (resolved to {str(resolved)}, which does not exist)')
    if not resolved.is_file():
        raise ValueError(
            f'Invalid PDF path: {path!r} (resolved to {str(resolved)}, which is not a regular file)'
        )
    return str(resolved)


def _stat_key(resolved_path: str, password: Optional[str]) -> SessionKey:
    """Cache key for one revision of one document under one password."""
    try:
        stat = os.stat(resolved_path)
    except OSError as exc:
        raise ValueError(f'Invalid PDF path: {resolved_path!r} (cannot stat it: {exc})') from exc
    return (resolved_path, password, stat.st_mtime_ns, stat.st_size)


class DocumentSession:
    """One open document plus the lock that serialises access to it.

    ``lock`` is held by ``DocumentManager.session()`` for the whole ``with``
    block, so callers that already hold a session may use ``extractor`` freely
    without taking it again. ``users`` is manager bookkeeping: the number of
    threads that currently hold (or are waiting for) this session, which is what
    decides whether eviction may close it.
    """

    def __init__(self, key: SessionKey, path: str, extractor: PdfExtractor) -> None:
        self.key = key
        #: Absolute, symlink-resolved path of the document.
        self.path = path
        #: The open extractor; only touch it while holding ``lock``.
        self.extractor = extractor
        #: Serialises every use of ``extractor``.
        self.lock = threading.Lock()
        #: Number of threads using (or about to use) this session; guarded by the manager lock.
        self.users = 0
        self._closed = False

    @property
    def password(self) -> Optional[str]:
        """Password this session was opened with, if any."""
        return self.key[1]

    @property
    def closed(self) -> bool:
        """Whether ``close()`` has already run for this session."""
        return self._closed

    def close(self) -> None:
        """Close the underlying document; safe to call more than once."""
        if self._closed:
            return
        self._closed = True
        self.extractor.close()

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f'DocumentSession(path={self.path!r}, users={self.users}, closed={self._closed})'


class DocumentManager:
    """LRU cache of open ``DocumentSession`` objects, safe for concurrent use."""

    def __init__(self, max_documents: int = DEFAULT_MAX_DOCUMENTS) -> None:
        if isinstance(max_documents, bool) or not isinstance(max_documents, int):
            raise ValueError(
                f'Invalid max_documents: {max_documents!r} (expected a positive integer)'
            )
        if max_documents < 1:
            raise ValueError(
                f'Invalid max_documents: {max_documents} (expected a positive integer)'
            )
        self._max_documents = max_documents
        #: Guards the cache dict, the LRU order and every session's ``users`` count.
        self._lock = threading.RLock()
        #: Cache in LRU order: oldest first.
        self._sessions: 'OrderedDict[SessionKey, DocumentSession]' = OrderedDict()

    @property
    def max_documents(self) -> int:
        """Cache bound; the cache may briefly exceed it while sessions are in use."""
        return self._max_documents

    def __len__(self) -> int:
        with self._lock:
            return len(self._sessions)

    @contextmanager
    def session(self, path: str, password: Optional[str] = None) -> Iterator[DocumentSession]:
        """Yield the cached (or freshly opened) session for ``path``, holding its lock.

        The lock is held for the whole ``with`` block, which serialises concurrent
        calls on the same document while leaving other documents independent.
        ``ValueError`` is raised for a path that is not an existing regular file.
        """
        resolved = _resolve_document_path(path)
        key = _stat_key(resolved, password)

        with self._lock:
            session = self._sessions.get(key)
            if session is None:
                # Opening is deliberately done while holding the manager lock:
                # a failed open must not leave a half-registered entry behind,
                # and it keeps "one extractor per key" true under races.
                session = DocumentSession(key, resolved, PdfExtractor(resolved, password))
                self._sessions[key] = session
            else:
                self._sessions.move_to_end(key)
            session.users += 1

        try:
            session.lock.acquire()
            try:
                yield session
            finally:
                session.lock.release()
        finally:
            with self._lock:
                session.users -= 1
                self._evict_locked()

    def close_all(self) -> None:
        """Close and forget every cached session; idempotent."""
        with self._lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        for session in sessions:
            try:
                session.close()
            except Exception:  # pragma: no cover - shutdown must not stop halfway
                pass

    def _evict_locked(self) -> None:
        """Drop least recently used sessions until the cache fits its bound.

        Callers must hold ``self._lock``. Sessions with ``users > 0`` are skipped:
        closing one would invalidate an extractor a caller is about to use. When
        every cached session is busy the cache is left over its bound instead.
        """
        while len(self._sessions) > self._max_documents:
            victim_key = next(
                (key for key, session in self._sessions.items() if session.users == 0),
                None,
            )
            if victim_key is None:
                return
            victim = self._sessions.pop(victim_key)
            try:
                victim.close()
            except Exception:  # pragma: no cover - one bad close must not leak the rest
                pass


def _max_documents_from_env() -> int:
    """``PDF_INSPECTOR_MCP_MAX_DOCS`` or ``DEFAULT_MAX_DOCUMENTS`` when unusable."""
    raw = os.environ.get(MAX_DOCUMENTS_ENV_VAR)
    if raw is None:
        return DEFAULT_MAX_DOCUMENTS
    try:
        value = int(raw.strip())
    except (TypeError, ValueError):
        return DEFAULT_MAX_DOCUMENTS
    return value if value >= 1 else DEFAULT_MAX_DOCUMENTS


_default_manager: Optional[DocumentManager] = None
_default_manager_lock = threading.Lock()


def get_default_manager() -> DocumentManager:
    """Process-wide manager, created on first use from the environment settings."""
    global _default_manager
    manager = _default_manager
    if manager is not None:
        return manager
    with _default_manager_lock:
        if _default_manager is None:
            _default_manager = DocumentManager(_max_documents_from_env())
        return _default_manager
