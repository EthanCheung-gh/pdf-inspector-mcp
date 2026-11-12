package pdf_inspector_mcp.export

import std.collection.*

/**
 * Suggested download name for an export, mirroring `export.suggest_filename`.
 *
 * The local path's last segment is used with a trailing `.pdf` removed
 * (case-insensitive), so `/docs/report.pdf` becomes `report` and
 * `/docs/report.PDF` becomes `report` as well. `scope == "page"` yields
 * `<stem>-p<page>.<ext>`; anything else falls through to the document form
 * `<stem>-all.<ext>`, like the Python version. An empty path (or a path whose
 * last segment is empty) falls back to `document`.
 *
 * The Python helper also inspects a `source_url` for a nicer stem, because MCP
 * documents loaded from a URL are downloaded to a temp file with a hash in its
 * name. The Cangjie server only ever exports local paths, so that branch is not
 * ported; callers pass the path they were given.
 */
public func suggestFilename(pdfPath: String, scope: String, page: Int64, ext: String): String {
    let stem = localStem(pdfPath)
    if (scope == "page") {
        return "${stem}-p${page}.${ext}"
    }
    return "${stem}-all.${ext}"
}

/** Last path segment without a `.pdf` suffix (`document` when missing). */
func localStem(pdfPath: String): String {
    if (pdfPath.size == 0) {
        return "document"
    }
    let segment = lastPathSegment(pdfPath)
    let stem = stripPdfSuffix(segment)
    if (stem.size == 0) {
        return "document"
    }
    return stem
}

func lastPathSegment(path: String): String {
    // Scan bytes: '/' and '\\' are ASCII, so they never appear inside a
    // multi-byte UTF-8 sequence and a byte offset is a valid slice boundary
    // (counting runes here would cut non-ASCII file names short).
    var start = 0
    for (index in 0..path.size) {
        if (path[index] == b'/' || path[index] == b'\\') {
            start = index + 1
        }
    }
    return path[start..path.size]
}

func stripPdfSuffix(segment: String): String {
    let suffix = ".pdf"
    if (segment.size < suffix.size) {
        return segment
    }
    let tail = segment[segment.size - suffix.size..segment.size]
    if (tail.toAsciiLower() == suffix) {
        return segment[0..segment.size - suffix.size]
    }
    return segment
}
