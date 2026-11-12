package pdf_inspector_mcp.debug

import std.collection.*
import pdf_inspector_mcp.pdf.*

/**
 * Manual smoke-test driver for the PDF core.
 *
 * Usage: `bash cangjie/scripts/debug-dump.sh /tmp/pc-text.pdf`
 *
 * It prints the document facts the MCP metadata tool will expose, the decoded
 * first-page content size plus a short hex/printable preview, and the object
 * cache size. Exceptions are caught and only `e.message` is printed: calling
 * `toString()` on an exception under this toolchain aborts the process.
 */
main(args: Array<String>) {
    if (args.size < 1) {
        println("usage: debug-dump <file.pdf>")
        return
    }
    let path = args[0]
    try {
        let document = PdfDocument.open(path, None)
        let metadata = document.metadata()
        println("path=${path}")
        println("pages=${metadata.pages}")
        println("version=${metadata.version}")
        println("encrypted=${metadata.encrypted}")
        println("page_w=${metadata.pageW}")
        println("page_h=${metadata.pageH}")
        println("title=${metadata.title}")
        println("author=${metadata.author}")
        println("producer=${metadata.producer}")
        println("fonts=${joinStrings(metadata.fonts)}")
        var contentBytes: Int64 = 0
        var preview: Array<UInt8> = Array<UInt8>()
        if (metadata.pages > 0) {
            let first = document.page(1)
            let contents = first.contents
            contentBytes = contents.size
            let limit = if (contents.size < 200) { contents.size } else { 200 }
            preview = contents[0..limit].toArray()
            println("page1_size=${first.width}x${first.height} rotate=${first.rotate}")
        }
        println("content_bytes=${contentBytes}")
        println("content_hex=${hexOf(preview)}")
        println("content_text=${printableOf(preview)}")
        println("object_cache=${document.objectCacheSize()} xref=${document.xrefSize()}")
        document.close()
    } catch (e: Exception) {
        println("error: ${e.message}")
    }
}

private func joinStrings(values: ArrayList<String>): String {
    if (values.isEmpty()) {
        return ""
    }
    let out = StringBuilder()
    var first = true
    for (value in values) {
        if (!first) {
            out.append(",")
        }
        out.append(value)
        first = false
    }
    out.toString()
}

private let HEX_CHARS: Array<UInt8> = "0123456789abcdef".toArray()

private func hexOf(bytes: Array<UInt8>): String {
    let out = ArrayList<UInt8>(bytes.size * 2)
    for (b in bytes) {
        let value = Int64(b)
        out.add(HEX_CHARS[(value >> 4) & 0x0F])
        out.add(HEX_CHARS[value & 0x0F])
    }
    String.fromUtf8(out.toArray())
}

private func printableOf(bytes: Array<UInt8>): String {
    let out = ArrayList<UInt8>()
    for (b in bytes) {
        if (b == 10 || b == 13) {
            out.add(32)
        } else if (b >= 32 && b <= 126) {
            out.add(b)
        } else {
            out.add(46)
        }
    }
    String.fromUtf8(out.toArray())
}
