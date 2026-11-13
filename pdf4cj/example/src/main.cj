package pdf4cj_example

import std.collection.*
import std.convert.*
import pdf4cj.*

/**
 * `pdf4cj` 用法示例：打印文档级元数据、指定页面的对象统计与前几个单词，
 * 以及该页检测到的有框线表格。
 *
 * 用法：`pdf4cj_example <file.pdf> [page]`
 *
 * 这里刻意只用库的公开 API（`PdfDocument.open` / `extractPage` /
 * `extractTables` / `imagePayload`），不做任何解析细节的假设，因此可以
 * 直接当作文档示例运行。
 *
 * 工具链注意：本环境下对异常类调用 `toString()` 会让进程 abort，所以错误
 * 分支只打印 `e.message`。
 */
main(args: Array<String>) {
    if (args.size < 1) {
        println("usage: pdf4cj_example <file.pdf> [page]")
        return
    }
    let path = args[0]
    var pageNumber: Int64 = 1
    if (args.size >= 2) {
        pageNumber = match (Int64.tryParse(args[1])) {
            case Some(value) => value
            case None =>
                println("error: page '${args[1]}' is not a number")
                return
        }
    }
    var document: Option<PdfDocument> = None
    try {
        let opened = PdfDocument.open(path, None)
        document = Some(opened)
        printMetadata(path, opened)
        let total = opened.pageCount
        if (total == 0) {
            println("page: (the document has an empty page tree)")
        } else if (pageNumber < 1 || pageNumber > total) {
            println("error: page ${pageNumber} is out of range (1..${total})")
        } else {
            printPage(opened, pageNumber)
        }
    } catch (e: PdfError) {
        println("error: ${e.message}")
    } catch (e: Exception) {
        println("error: ${e.message}")
    } finally {
        match (document) {
            case Some(opened) => opened.close()
            case None => ()
        }
    }
}

/** 文档级信息：页数、版本、首页尺寸、字体、文档信息字典。 */
func printMetadata(path: String, document: PdfDocument): Unit {
    let metadata = document.metadata()
    println("file: ${path}")
    println(
        "document: pages=${metadata.pages} version=${metadata.version} encrypted=${metadata.encrypted} size=${formatDecimal(metadata.pageW, 2)}x${formatDecimal(metadata.pageH, 2)}pt"
    )
    println("title: ${quoted(metadata.title)}")
    println("author: ${quoted(metadata.author)}")
    println("producer: ${quoted(metadata.producer)}")
    var fontText = "(none)"
    if (!metadata.fonts.isEmpty()) {
        let builder = StringBuilder()
        for (font in metadata.fonts) {
            if (builder.size > 0) {
                builder.append(", ")
            }
            builder.append(font)
        }
        fontText = builder.toString()
    }
    println("fonts: ${fontText}")
}

/** 单页信息：页面框、各类对象数量、前 5 个单词、表格单元格。 */
func printPage(document: PdfDocument, pageNumber: Int64): Unit {
    let page = document.page(pageNumber)
    let data = extractPage(document, page)
    let tables = extractTables(page, data)
    let box = page.box()
    println(
        "page ${pageNumber}/${document.pageCount}: box=[${formatDecimal(box[0], 2)}, ${formatDecimal(box[1], 2)}, ${formatDecimal(box[2], 2)}, ${formatDecimal(box[3], 2)}] rotate=${page.rotate}"
    )
    println(
        "counts: chars=${data.chars.size} words=${data.words.size} rects=${data.rects.size} lines=${data.lines.size} curves=${data.curves.size} images=${data.images.size} tables=${tables.size}"
    )
    var shown = 0
    for (word in data.words) {
        if (shown >= 5) {
            break
        }
        println(
            "word[${shown}]: '${word.text}' bbox=(${formatDecimal(word.x0, 2)}, ${formatDecimal(word.y0, 2)}, ${formatDecimal(word.x1, 2)}, ${formatDecimal(word.y1, 2)}) font=${word.fontname} size=${formatDecimal(word.size, 2)}"
        )
        shown += 1
    }
    var tableIndex = 0
    for (table in tables) {
        println(
            "table[${tableIndex}]: ${table.rows}x${table.cols} bbox=(${formatDecimal(table.x0, 2)}, ${formatDecimal(table.y0, 2)}, ${formatDecimal(table.x1, 2)}, ${formatDecimal(table.y1, 2)})"
        )
        for (row in table.cells) {
            var line = "  |"
            for (cell in row) {
                line = line + " " + escaped(cell) + " |"
            }
            println(line)
        }
        tableIndex += 1
    }
    var imageIndex = 0
    for (image in data.images) {
        // imagePayload 失败时不抛异常，错误放在 payload.error 里。
        let payload = imagePayload(document, image)
        let note = match (payload.error) {
            case Some(reason) => "error=${reason}"
            case None => "${payload.mimeType} bytes=${payload.byteLength}"
        }
        println(
            "image[${imageIndex}]: ${image.streamId} format=${image.format} bbox=(${formatDecimal(image.x0, 2)}, ${formatDecimal(image.y0, 2)}, ${formatDecimal(image.x1, 2)}, ${formatDecimal(image.y1, 2)}) ${note}"
        )
        imageIndex += 1
    }
}

/** 空字符串在输出里显示为 `(empty)`，避免出现 `title: ''` 这样的歧义。 */
func quoted(value: String): String {
    if (value.isEmpty()) {
        return "(empty)"
    }
    "'" + escaped(value) + "'"
}

/** 把单元格里的换行/制表符展开成可见转义，保证一行一条记录。 */
func escaped(value: String): String {
    let builder = StringBuilder()
    for (rune in value.runes()) {
        // 只需要处理会破坏单行输出的控制字符，其余原样保留。
        let code = Int64(UInt32(rune))
        if (code == 0x0A) {
            builder.append("\\n")
        } else if (code == 0x0D) {
            builder.append("\\r")
        } else if (code == 0x09) {
            builder.append("\\t")
        } else {
            builder.append(rune)
        }
    }
    builder.toString()
}
