package pdf_inspector_mcp.mcp

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import pdf_inspector_mcp.pdf.*

/**
 * Path validation and the open-document cache behind the six tools.
 *
 * Mirrors `src/pdf_inspector_mcp/document.py` with the concurrency machinery
 * dropped: this server runs one JSON-RPC message at a time on a single thread
 * (`server.cj`'s read/dispatch/write loop), so there is no second thread that
 * could use a session while another one closes it. No lock is needed and none
 * is taken - adding one would only document a race that cannot happen here.
 * Should the loop ever become concurrent, `DocumentManager.session` is the one
 * place that has to grow a lock (and the `users` bookkeeping the Python version
 * keeps to avoid closing an in-use extractor).
 *
 * What is kept is the caching contract, because it is observable:
 *
 * - the cache key is `(resolved path, password)`, so the same document opened
 *   under two passwords is two sessions;
 * - the session records the file's modification time and size, and a changed
 *   one invalidates the entry (close + reopen), so a rewritten PDF is never
 *   read through a stale parse;
 * - the cache is bounded (LRU, default 8, `PDF_INSPECTOR_MCP_MAX_DOCS`
 *   overrides), and eviction closes the document before dropping it.
 */

/** Cache bound used when neither the constructor nor the environment overrides it. */
public let DEFAULT_MAX_DOCUMENTS: Int64 = 8

/** Environment variable that overrides the process-wide manager's cache bound. */
public let MAX_DOCUMENTS_ENV_VAR: String = "PDF_INSPECTOR_MCP_MAX_DOCS"

/**
 * Validate `path` and return its absolute, symlink-resolved form.
 *
 * The path must name an existing regular file. Everything else raises a
 * `PdfToolError` whose message quotes what was received and says why it was
 * rejected, so `pdf_get_metadata` reports "this is not a path" before anything
 * tries to parse the file and reports "this is not a PDF" instead.
 *
 * A `.pdf` suffix is *not* required, matching the Python server, which opens
 * whatever path it is handed.
 */
public func resolveDocumentPath(path: String): String {
    if (path.trimAscii().isEmpty()) {
        throw PdfToolError("Invalid PDF path: " + quoted(path) + " (the path is empty)")
    }
    let absolute = absolutePath(expandUser(path))
    if (!exists(absolute)) {
        throw PdfToolError(
            'Invalid PDF path: ' + quoted(path) + " (resolved to '" + absolute + "', which does not exist)"
        )
    }
    let canonical = try {
        canonicalize(absolute).toString()
    } catch (error: Exception) {
        throw PdfToolError(
            "Invalid PDF path: " + quoted(path) + " (cannot resolve it: " + describe(error) + ")"
        )
    }
    let regular = try {
        FileInfo(canonical).isRegular()
    } catch (error: Exception) {
        throw PdfToolError(
            "Invalid PDF path: " + quoted(path) + " (cannot stat it: " + describe(error) + ")"
        )
    }
    if (!regular) {
        throw PdfToolError(
            'Invalid PDF path: ' + quoted(path) + " (resolved to '" + canonical + "', which is not a regular file)"
        )
    }
    return canonical
}

/** One open document plus the file revision it was parsed from. */
public class DocumentSession {
    /** Absolute, symlink-resolved path of the document. */
    public let path: String
    /** Password the session was opened with, if any. */
    public let password: Option<String>
    /** Modification time of the file the document was parsed from. */
    public var mtimeNs: DateTime
    /** Size in bytes of the file the document was parsed from. */
    public var sizeNs: Int64
    /** The parsed document; only valid while the session stays in the cache. */
    public var doc: PdfDocument

    init(path: String, password: Option<String>, mtimeNs: DateTime, sizeNs: Int64, doc: PdfDocument) {
        this.path = path
        this.password = password
        this.mtimeNs = mtimeNs
        this.sizeNs = sizeNs
        this.doc = doc
    }
}

/**
 * Bounded LRU cache of open documents.
 *
 * `session` resolves and stats the path, returns the cached document when the
 * file is unchanged, and otherwise opens a fresh one - closing the stale
 * document for the same key first. The returned document stays valid as long as
 * the session is cached, so callers must not close it themselves; `closeAll`
 * is the only closer (tests and process shutdown).
 */
public class DocumentManager {
    /** Cache bound; eviction happens after an insert. */
    public let maxDocuments: Int64
    /** Cached sessions in LRU order, least recently used first. */
    var entries: ArrayList<DocumentSession>

    public init(maxDocuments!: Int64 = DEFAULT_MAX_DOCUMENTS) {
        this.maxDocuments = if (maxDocuments < 1) {
            DEFAULT_MAX_DOCUMENTS
        } else {
            maxDocuments
        }
        this.entries = ArrayList<DocumentSession>()
    }

    /** Manager configured from `PDF_INSPECTOR_MCP_MAX_DOCS`, the way the server builds it. */
    public static func fromEnvironment(): DocumentManager {
        return DocumentManager(maxDocuments: maxDocumentsFromEnvironment())
    }

    /** Number of currently cached documents (diagnostics/tests). */
    public prop size: Int64 {
        get() {
            entries.size
        }
    }

    /**
     * Open (or reuse) the document for `path` and return `(resolvedPath, doc)`.
     *
     * Raises `PdfToolError` for an unusable path and lets `PdfError` from
     * `PdfDocument.open` propagate: the tool layer owns the wording of "this is
     * not a PDF" / "password required or incorrect" because it knows which tool
     * is running.
     */
    public func session(path: String, password: Option<String>): (String, PdfDocument) {
        let resolved = resolveDocumentPath(path)
        let info = try {
            FileInfo(resolved)
        } catch (error: Exception) {
            throw PdfToolError("Invalid PDF path: " + quoted(resolved) + " (cannot stat it: " + describe(error) + ")")
        }
        let mtime = info.lastModificationTime
        let size = info.size

        var cachedIndex: Int64 = -1
        for (index in 0..entries.size) {
            if (entries[index].path == resolved && samePassword(entries[index].password, password)) {
                cachedIndex = index
                break
            }
        }
        if (cachedIndex >= 0) {
            let cached = entries[cachedIndex]
            let unchanged = cached.mtimeNs == mtime && cached.sizeNs == size
            entries.remove(at: cachedIndex)
            if (unchanged) {
                entries.add(cached)
                return (resolved, cached.doc)
            }
            // The bytes on disk changed: drop the stale parse before reopening.
            cached.doc.close()
        }

        let doc = PdfDocument.open(resolved, password)
        entries.add(DocumentSession(resolved, password, mtime, size, doc))
        evictOverflow()
        return (resolved, doc)
    }

    /** Close and forget every cached document; idempotent. */
    public func closeAll(): Unit {
        for (entry in entries) {
            entry.doc.close()
        }
        entries.clear()
    }

    /** Close least-recently-used documents until the cache fits its bound. */
    func evictOverflow(): Unit {
        while (entries.size > maxDocuments) {
            let victim = entries[0]
            entries.remove(at: 0)
            victim.doc.close()
        }
    }
}

/** Process-wide manager, created on first use from the environment settings. */
var defaultManager: Option<DocumentManager> = None

/** The manager the tools share, so a document is parsed once per revision. */
public func documentManager(): DocumentManager {
    match (defaultManager) {
        case Some(manager) => return manager
        case None => ()
    }
    let manager = DocumentManager.fromEnvironment()
    defaultManager = Some(manager)
    return manager
}

/** `PDF_INSPECTOR_MCP_MAX_DOCS`, or the default when unset or unusable. */
func maxDocumentsFromEnvironment(): Int64 {
    let raw = match (getVariable(MAX_DOCUMENTS_ENV_VAR)) {
        case Some(value) => value
        case None => return DEFAULT_MAX_DOCUMENTS
    }
    let text = raw.trimAscii()
    let parsed = match (Int64.tryParse(text)) {
        case Some(value) => value
        case None => return DEFAULT_MAX_DOCUMENTS
    }
    if (parsed < 1) {
        return DEFAULT_MAX_DOCUMENTS
    }
    return parsed
}

// ---------------------------------------------------------------------------
// Path helpers

/**
 * `~`/`~/x` expansion with `HOME`, leaving the text untouched when `HOME` is
 * unset (like `Path.expanduser()`, which also has nothing to substitute).
 */
func expandUser(path: String): String {
    if (path == "~") {
        return homeDirectory() ?? path
    }
    if (path.startsWith("~/")) {
        match (homeDirectory()) {
            case Some(home) => return home + path[1..path.size]
            case None => return path
        }
    }
    return path
}

func homeDirectory(): Option<String> {
    match (getVariable("HOME")) {
        case Some(home) =>
            if (!home.isEmpty()) {
                return Some(home)
            }
            return None
        case None => return None
    }
}

/**
 * Absolute, lexically normalized form of `path`: relative input is resolved
 * against the current working directory, mirroring `Path.resolve()` for a file
 * that need not exist yet.
 */
func absolutePath(path: String): String {
    let candidate = Path(path)
    if (candidate.isAbsolute()) {
        return candidate.normalize().toString()
    }
    return getWorkingDirectory().join(candidate).normalize().toString()
}

/** `value` in single quotes, the way the Python messages quote their input. */
func quoted(value: String): String {
    return "'" + value + "'"
}

/**
 * Directory part of `absolute`, for the "parent directory must exist" check.
 *
 * A root path has no parent, so it is reported as itself; a path directly under
 * the root keeps `/` as its parent. `absolutePath` always returns an absolute
 * path, so the `.` fallback only guards against a `Path` quirk rather than a
 * real input.
 */
func parentOf(absolute: String): String {
    let candidate = Path(absolute)
    if (candidate.fileName.isEmpty()) {
        return absolute
    }
    let parent = candidate.parent.toString()
    if (parent.isEmpty()) {
        return "."
    }
    return parent
}

/** `error.message`, with the class name standing in when it is empty. */
func describe(error: Exception): String {
    let message = error.message.trimAscii()
    if (message.isEmpty()) {
        return "unknown error"
    }
    return message
}

func samePassword(left: Option<String>, right: Option<String>): Bool {
    match (left) {
        case Some(leftValue) =>
            match (right) {
                case Some(rightValue) => return leftValue == rightValue
                case None => return false
            }
        case None =>
            match (right) {
                case Some(_) => return false
                case None => return true
            }
    }
}
