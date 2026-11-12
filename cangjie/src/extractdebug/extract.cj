package pdf_inspector_mcp.extractdebug

import std.collection.*
import std.convert.*
import pdf_inspector_mcp.pdf.*

/**
 * Manual smoke-test driver for the content-stream interpreter.
 *
 * Usage: `bash cangjie/scripts/extract-dump.sh /tmp/pc-text.pdf [page]`
 *
 * It prints the page box, the number of objects of every kind, the first words
 * (text/bbox/font/size), the first characters and each image's placement, so a
 * fixture can be compared against pdfplumber by eye. `tables` is always 0: table
 * detection is a separate stage.
 *
 * Exceptions print only `e.message`: calling `toString()` on an exception under
 * this toolchain aborts the process.
 */
main(args: Array<String>) {
    if (args.size < 1) {
        println("usage: extract-dump <file.pdf> [page]")
        return
    }
    let path = args[0]
    var pageNumber: Int64 = 1
    if (args.size >= 2) {
        pageNumber = match (Int64.tryParse(args[1])) {
            case Some(value) => value
            case None => 1
        }
    }
    try {
        let document = PdfDocument.open(path, None)
        let page = document.page(pageNumber)
        let data = extractPage(document, page)
        println("path=${path}")
        println("page=${pageNumber}/${document.pageCount}")
        println(
            "size=${formatDecimal(data.width, 2)}x${formatDecimal(data.height, 2)} rotate=${page.rotate}"
        )
        println(
            "counts chars=${data.chars.size} words=${data.words.size} rects=${data.rects.size} lines=${data.lines.size} curves=${data.curves.size} images=${data.images.size} tables=${data.tables.size}"
        )
        println("text=${joinedText(data.chars)}")
        var shown = 0
        for (word in data.words) {
            if (shown >= 5) {
                break
            }
            println(
                "word[${shown}] text='${word.text}' bbox=(${formatDecimal(word.x0, 3)},${formatDecimal(word.y0, 3)},${formatDecimal(word.x1, 3)},${formatDecimal(word.y1, 3)}) font=${word.fontname} size=${formatDecimal(word.size, 2)}"
            )
            shown += 1
        }
        shown = 0
        for (char in data.chars) {
            if (shown >= 3) {
                break
            }
            println(
                "char[${shown}] text='${char.text}' bbox=(${formatDecimal(char.x0, 3)},${formatDecimal(char.y0, 3)},${formatDecimal(char.x1, 3)},${formatDecimal(char.y1, 3)}) font=${char.fontname} size=${formatDecimal(char.size, 2)} color=${describeColor(char.color)}"
            )
            shown += 1
        }
        for (image in data.images) {
            let payloadSize = match (image.imageData) {
                case Some(payload) => payload.size
                case None => 0
            }
            println(
                "image ${image.streamId} bbox=(${formatDecimal(image.x0, 3)},${formatDecimal(image.y0, 3)},${formatDecimal(image.x1, 3)},${formatDecimal(image.y1, 3)}) size=${formatDecimal(image.width, 2)}x${formatDecimal(image.height, 2)} format=${image.format} bytes=${payloadSize} stream=${image.imageStream.isSome()}"
            )
        }
        for (rect in data.rects) {
            println(
                "rect bbox=(${formatDecimal(rect.x0, 3)},${formatDecimal(rect.y0, 3)},${formatDecimal(rect.x1, 3)},${formatDecimal(rect.y1, 3)}) fill=${rect.fill} stroke=${rect.stroke} color=${describeColor(rect.color)} width=${formatDecimal(rect.width, 3)}"
            )
        }
        for (line in data.lines) {
            println(
                "line bbox=(${formatDecimal(line.x0, 3)},${formatDecimal(line.y0, 3)},${formatDecimal(line.x1, 3)},${formatDecimal(line.y1, 3)}) stroke=${line.stroke} color=${describeColor(line.color)} width=${formatDecimal(line.width, 3)}"
            )
        }
        for (curve in data.curves) {
            println(
                "curve bbox=(${formatDecimal(curve.x0, 3)},${formatDecimal(curve.y0, 3)},${formatDecimal(curve.x1, 3)},${formatDecimal(curve.y1, 3)}) points=${curve.points.size} stroke=${curve.stroke}"
            )
        }
        document.close()
    } catch (e: Exception) {
        println("error: ${e.message}")
    }
}

/** Concatenate every glyph's text, the way pdfplumber's `extract_text` reads. */
private func joinedText(chars: ArrayList<CharObj>): String {
    let out = StringBuilder()
    for (char in chars) {
        out.append(char.text)
    }
    out.toString()
}
