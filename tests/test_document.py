"""Tests for the document session manager: caching, LRU eviction, locking.

Most of these tests care about *bookkeeping* rather than PDF parsing, so they
swap ``document.PdfExtractor`` for a stub. That keeps eviction and reuse
assertions independent of reportlab/pdfplumber quirks, and lets a stub record
which extracts were closed. The reuse and concurrency tests use real PDFs
because there the extractor's own behaviour (page counts, char counts) is part
of what must stay correct under lock.
"""

from __future__ import annotations

import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

import pdf_fixtures
from pdf_inspector_mcp import document
from pdf_inspector_mcp.document import DocumentManager, get_default_manager


# --- stubs -----------------------------------------------------------------


class StubExtractor:
    """Stand-in for ``PdfExtractor`` that records construction and closing."""

    instances: list['StubExtractor'] = []

    def __init__(self, path: str, password: str | None = None) -> None:
        self.path = path
        self.password = password
        self.closed = False
        self.close_calls = 0
        StubExtractor.instances.append(self)

    def close(self) -> None:
        self.closed = True
        self.close_calls += 1


@pytest.fixture()
def stub_extractor(monkeypatch: pytest.MonkeyPatch) -> type[StubExtractor]:
    """Route ``document.PdfExtractor`` to ``StubExtractor`` for one test."""
    StubExtractor.instances = []
    monkeypatch.setattr(document, 'PdfExtractor', StubExtractor)
    return StubExtractor


@pytest.fixture()
def manager() -> DocumentManager:
    """A manager whose cached sessions are always closed at teardown."""
    instance = DocumentManager()
    yield instance
    instance.close_all()


def _touch_file(path: Path, content: str = 'not really a pdf') -> str:
    """A real regular file the path validator accepts (the stub never parses it)."""
    path.write_text(content, encoding='utf-8')
    return str(path)


# --- path validation -------------------------------------------------------


def test_missing_path_raises_value_error(manager: DocumentManager, tmp_path: Path) -> None:
    missing = tmp_path / 'nope.pdf'

    with pytest.raises(ValueError) as excinfo:
        with manager.session(str(missing)):
            pass

    message = str(excinfo.value)
    assert 'nope.pdf' in message
    assert 'does not exist' in message


def test_directory_path_raises_value_error(manager: DocumentManager, tmp_path: Path) -> None:
    directory = tmp_path / 'folder'
    directory.mkdir()

    with pytest.raises(ValueError) as excinfo:
        with manager.session(str(directory)):
            pass

    message = str(excinfo.value)
    assert 'folder' in message
    assert 'not a regular file' in message


@pytest.mark.parametrize('bad_path', ['', '   ', 123, None])
def test_non_path_input_raises_value_error(manager: DocumentManager, bad_path: object) -> None:
    with pytest.raises(ValueError):
        with manager.session(bad_path):  # type: ignore[arg-type]
            pass


def test_relative_path_and_user_expansion_are_resolved(
    manager: DocumentManager,
    stub_extractor: type[StubExtractor],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _touch_file(tmp_path / 'doc.bin')
    monkeypatch.chdir(tmp_path)

    with manager.session('doc.bin') as session:
        assert Path(session.path).is_absolute()
        assert session.path == str((tmp_path / 'doc.bin').resolve())

    with pytest.raises(ValueError):
        with manager.session(str(tmp_path / 'missing.pdf')):
            pass


def test_non_pdf_suffix_is_accepted(manager: DocumentManager, tmp_path: Path) -> None:
    """Upstream accepts any path; only "existing regular file" is enforced."""
    path = pdf_fixtures.make_text_pdf(tmp_path / 'notes.txt')

    with manager.session(path) as session:
        assert session.extractor.page_count() == 1


def test_regular_file_that_is_not_a_pdf_still_opens(manager: DocumentManager, tmp_path: Path) -> None:
    """Only "existing regular file" is validated; parsing failures surface on open."""
    path = tmp_path / 'broken.pdf'
    path.write_bytes(b'this is not a pdf\n' * 4)

    with pytest.raises(Exception) as excinfo:
        with manager.session(str(path)):
            pass

    # pdfplumber reports the parse failure; the manager does not dress it up.
    from pdfplumber.utils.exceptions import PdfminerException

    assert isinstance(excinfo.value, PdfminerException)
    assert len(manager) == 0, 'a failed open must not be cached'


def test_failed_open_does_not_poison_the_cache(manager: DocumentManager, tmp_path: Path) -> None:
    path = tmp_path / 'later-fixed.pdf'
    path.write_bytes(b'garbage, not a pdf\n' * 4)

    with pytest.raises(Exception):
        with manager.session(str(path)):
            pass

    # Repairing the file makes the same path usable again: no stale entry, no held lock.
    pdf_fixtures.make_text_pdf(path)
    os.utime(path, None)

    with manager.session(str(path)) as session:
        assert session.extractor.page_count() == 1

    assert len(manager) == 1


# --- reuse and cache keys --------------------------------------------------


def test_repeated_sessions_reuse_the_same_extractor(manager: DocumentManager, tmp_path: Path) -> None:
    path = pdf_fixtures.make_text_pdf(tmp_path / 'text.pdf')

    with manager.session(path) as first:
        first_id = id(first.extractor)
        first_extractor = first.extractor

    with manager.session(path) as second:
        assert second.extractor is first_extractor
        assert id(second.extractor) == first_id
        assert second.path == first.path

    assert len(manager) == 1


def test_different_password_opens_a_separate_session(
    manager: DocumentManager, stub_extractor: type[StubExtractor], tmp_path: Path
) -> None:
    path = _touch_file(tmp_path / 'locked.pdf')

    with manager.session(path) as open_session:
        pass
    with manager.session(path, 'secret') as locked_session:
        pass

    assert open_session is not locked_session
    assert open_session.extractor is not locked_session.extractor
    assert locked_session.extractor.password == 'secret'
    assert len(manager) == 2

    # Each key keeps being served by its own extractor.
    with manager.session(path) as again_open:
        assert again_open.extractor is open_session.extractor
    with manager.session(path, 'secret') as again_locked:
        assert again_locked.extractor is locked_session.extractor


def test_rewritten_file_opens_a_new_extractor(manager: DocumentManager, tmp_path: Path) -> None:
    path = tmp_path / 'rewritten.pdf'
    pdf_fixtures.make_multipage_pdf(path, 2)

    with manager.session(str(path)) as first:
        first_extractor = first.extractor
        assert first_extractor.page_count() == 2

    # Same path, different bytes: the cache key (mtime_ns, size) must miss.
    pdf_fixtures.make_multipage_pdf(path, 3)
    os.utime(path, None)

    with manager.session(str(path)) as second:
        assert second.extractor is not first_extractor
        assert second.extractor.page_count() == 3


def test_touching_a_file_without_changing_bytes_reopens_it(
    manager: DocumentManager, stub_extractor: type[StubExtractor], tmp_path: Path
) -> None:
    path = Path(_touch_file(tmp_path / 'touched.pdf'))

    with manager.session(str(path)) as first:
        pass

    os.utime(path, (time.time() + 5, time.time() + 5))

    with manager.session(str(path)) as second:
        assert second.extractor is not first.extractor


# --- LRU eviction ----------------------------------------------------------


def test_lru_eviction_closes_the_oldest_session(
    stub_extractor: type[StubExtractor], tmp_path: Path
) -> None:
    manager = DocumentManager(max_documents=2)
    paths = [_touch_file(tmp_path / f'{name}.pdf') for name in ('a', 'b', 'c')]

    try:
        for path in paths[:2]:
            with manager.session(path):
                pass

        assert len(manager) == 2
        oldest, middle = stub_extractor.instances
        assert oldest.closed is False

        with manager.session(paths[2]):
            pass

        # The least recently used session was closed *before* being dropped.
        assert oldest.closed is True
        assert oldest.close_calls == 1
        assert middle.closed is False
        assert len(manager) == 2
    finally:
        manager.close_all()


def test_evicted_document_is_reopened_on_next_use(
    stub_extractor: type[StubExtractor], tmp_path: Path
) -> None:
    manager = DocumentManager(max_documents=1)
    first_path = _touch_file(tmp_path / 'first.pdf')
    second_path = _touch_file(tmp_path / 'second.pdf')

    try:
        with manager.session(first_path):
            pass
        with manager.session(second_path):
            pass
        assert stub_extractor.instances[0].closed is True

        with manager.session(first_path) as reopened:
            assert reopened.extractor is stub_extractor.instances[2]
            assert reopened.extractor.closed is False
    finally:
        manager.close_all()


def test_eviction_skips_a_session_that_is_in_use(
    stub_extractor: type[StubExtractor], tmp_path: Path
) -> None:
    """A busy session survives even when it is the LRU entry."""
    manager = DocumentManager(max_documents=2)
    busy_path = _touch_file(tmp_path / 'busy.pdf')
    other_path = _touch_file(tmp_path / 'other.pdf')
    third_path = _touch_file(tmp_path / 'third.pdf')

    try:
        with manager.session(busy_path) as busy:
            with manager.session(other_path) as other:
                pass

            with manager.session(third_path) as third:
                pass

            # ``busy`` is both the LRU entry and in use: eviction had to pick ``other``.
            assert busy.closed is False
            assert other.closed is True
            assert third.closed is False
            assert len(manager) == 2
    finally:
        manager.close_all()


def test_nested_sessions_may_exceed_the_bound_without_closing_a_busy_session(
    stub_extractor: type[StubExtractor], tmp_path: Path
) -> None:
    """A one-slot cache holding two nested sessions: nothing in use may be closed."""
    manager = DocumentManager(max_documents=1)
    outer_path = _touch_file(tmp_path / 'outer.pdf')
    inner_path = _touch_file(tmp_path / 'inner.pdf')

    try:
        with manager.session(outer_path) as outer:
            with manager.session(inner_path) as inner:
                # Both are in use, so the cache is briefly over its bound rather
                # than pulling a document out from under the outer scope.
                assert outer.closed is False
                assert inner.closed is False
                assert len(manager) == 2

            # Leaving the inner block released it, so the bound is restored and
            # the useless (LRU) session is the one that went.
            assert inner.closed is True
            assert outer.closed is False
            assert len(manager) == 1
    finally:
        manager.close_all()


# --- concurrency -----------------------------------------------------------


def test_lock_serialises_concurrent_sessions(manager: DocumentManager, tmp_path: Path) -> None:
    path = pdf_fixtures.make_styled_multipage_pdf(tmp_path / 'concurrent.pdf')
    threads = 8
    rounds = 4
    guard = threading.Lock()
    state = {'active': 0, 'max_active': 0}
    results: list[int] = []

    def work() -> None:
        for _ in range(rounds):
            with manager.session(path) as session:
                with guard:
                    state['active'] += 1
                    state['max_active'] = max(state['max_active'], state['active'])
                # Yield the GIL: without the session lock this would interleave.
                time.sleep(0.002)
                page = session.extractor.extract_page(1)
                results.append(len(page['chars']))
                with guard:
                    state['active'] -= 1

    with ThreadPoolExecutor(max_workers=threads) as pool:
        futures = [pool.submit(work) for _ in range(threads)]
        for future in futures:
            future.result(timeout=60)

    assert state['max_active'] == 1, 'two threads used the same extractor at once'
    assert results == [9] * (threads * rounds)
    assert len(manager) == 1


def test_concurrent_sessions_on_different_documents_work(manager: DocumentManager, tmp_path: Path) -> None:
    paths = [pdf_fixtures.make_text_pdf(tmp_path / f'multi{i}.pdf', f'word{i}') for i in range(4)]

    def work(path: str) -> list[str]:
        with manager.session(path) as session:
            return [word['text'] for word in session.extractor.extract_page(1)['words']]

    with ThreadPoolExecutor(max_workers=4) as pool:
        texts = list(pool.map(work, paths))

    assert texts == [[f'word{i}'] for i in range(4)]


def test_lock_is_released_when_the_body_raises(manager: DocumentManager, tmp_path: Path) -> None:
    path = pdf_fixtures.make_text_pdf(tmp_path / 'raising.pdf')

    with pytest.raises(RuntimeError):
        with manager.session(path):
            raise RuntimeError('boom')

    with manager.session(path) as session:
        assert session.lock.locked(), 'the session lock should be held again'
        assert session.extractor.page_count() == 1


# --- lifecycle -------------------------------------------------------------


def test_close_all_closes_sessions_and_is_idempotent(
    stub_extractor: type[StubExtractor], tmp_path: Path
) -> None:
    manager = DocumentManager()
    paths = [_touch_file(tmp_path / f'{name}.pdf') for name in ('a', 'b')]
    for path in paths:
        with manager.session(path):
            pass

    sessions = list(stub_extractor.instances)
    assert [session.closed for session in sessions] == [False, False]

    manager.close_all()
    assert [session.closed for session in sessions] == [True, True]
    assert [session.close_calls for session in sessions] == [1, 1]
    assert len(manager) == 0

    manager.close_all()  # second call is a no-op
    assert [session.close_calls for session in sessions] == [1, 1]
    assert len(manager) == 0


def test_session_closes_idempotently(manager: DocumentManager, tmp_path: Path) -> None:
    path = pdf_fixtures.make_text_pdf(tmp_path / 'idempotent.pdf')

    with manager.session(path) as session:
        pass

    session.close()
    session.close()
    assert session.closed is True


@pytest.mark.parametrize('bad_max', [0, -1, 1.5, '4', True])
def test_max_documents_must_be_a_positive_integer(bad_max: object) -> None:
    with pytest.raises(ValueError):
        DocumentManager(bad_max)  # type: ignore[arg-type]


def test_default_manager_is_a_singleton_with_env_override(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(document, '_default_manager', None)
    monkeypatch.delenv(document.MAX_DOCUMENTS_ENV_VAR, raising=False)

    first = get_default_manager()
    assert first is get_default_manager()
    assert first.max_documents == document.DEFAULT_MAX_DOCUMENTS

    for raw, expected in [('3', 3), (' 12 ', 12), ('nonsense', 8), ('0', 8), ('', 8)]:
        monkeypatch.setenv(document.MAX_DOCUMENTS_ENV_VAR, raw)
        monkeypatch.setattr(document, '_default_manager', None)
        assert get_default_manager().max_documents == expected

    monkeypatch.setattr(document, '_default_manager', None)
    get_default_manager().close_all()
