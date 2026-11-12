package pdf_inspector_mcp.pdf

import std.collection.*
import std.convert.*

/**
 * Content-stream interpreter.
 *
 * [extractPage] runs a page's (already concatenated) content stream through a
 * small PostScript-style machine: operands are pushed on a stack, operators pop
 * them and mutate the graphics/text state or append an object to the [PageData].
 *
 * Coordinate model
 * ----------------
 * The interpreter works in PDF *user* space: origin at the bottom-left of the
 * MediaBox/CropBox, y growing upwards, which is what pdfplumber's `y0`/`y1` mean
 * before its top flip. `/Rotate` is not applied (a view-level transform).
 *
 * `extractPage` then shifts every object once by `-(box.x0, box.y0)`, which is
 * the frame pdfplumber reports in: a page whose MediaBox starts at `[0 100 …]`
 * has its y coordinates reduced by 100. Keeping the shift at the very end means
 * the stream interpreter (and nested Form XObjects) never has to know about it.
 *
 * Text geometry follows pdfminer (the engine pdfplumber is built on) exactly:
 *
 * - a glyph's box is the quad `(0, descent+rise)` .. `(advance, descent+rise+size)`
 *   in text space, mapped through `Tm x CTM x translate(tx, ty)`;
 * - `advance = width/1000 * size * horizScale`, and the TJ kerning numbers move
 *   the pen by `-num/1000 * size * horizScale`;
 * - `size` is the Tf size times the effective matrix scale, recovered as the
 *   height of the mapped box, which is what pdfminer reports as `LTChar.size`.
 *
 * The y range therefore starts at `baseline + descent*size` (pdfminer's formula)
 * rather than at the ascender, so Helvetica 12pt on baseline 700 gives
 * `697.516 .. 709.516`.
 */

/** Maximum nesting depth for Form XObjects. */
let MAX_FORM_DEPTH: Int64 = 8

// ---------------------------------------------------------------------------
// Affine matrices

/**
 * A PDF affine matrix `[a b c d e f]`:
 * `x' = a*x + c*y + e`, `y' = b*x + d*y + f`.
 */
class Mat {
    let a: Float64
    let b: Float64
    let c: Float64
    let d: Float64
    let e: Float64
    let f: Float64

    init(a: Float64, b: Float64, c: Float64, d: Float64, e: Float64, f: Float64) {
        this.a = a
        this.b = b
        this.c = c
        this.d = d
        this.e = e
        this.f = f
    }

    static func identity(): Mat {
        Mat(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    }

    static func translation(tx: Float64, ty: Float64): Mat {
        Mat(1.0, 0.0, 0.0, 1.0, tx, ty)
    }

    /** The matrix that applies [inner] first and [outer] afterwards. */
    static func compose(outer: Mat, inner: Mat): Mat {
        Mat(
            outer.a * inner.a + outer.c * inner.b,
            outer.b * inner.a + outer.d * inner.b,
            outer.a * inner.c + outer.c * inner.d,
            outer.b * inner.c + outer.d * inner.d,
            outer.a * inner.e + outer.c * inner.f + outer.e,
            outer.b * inner.e + outer.d * inner.f + outer.f
        )
    }

    /** `this` followed by a translation: pdfminer's `translate_matrix`. */
    func translated(tx: Float64, ty: Float64): Mat {
        Mat(
            this.a,
            this.b,
            this.c,
            this.d,
            tx * this.a + ty * this.c + this.e,
            tx * this.b + ty * this.d + this.f
        )
    }

    func apply(x: Float64, y: Float64): (Float64, Float64) {
        (this.a * x + this.c * y + this.e, this.b * x + this.d * y + this.f)
    }
}

// ---------------------------------------------------------------------------
// Graphics / text state

/**
 * One level of the graphics state.
 *
 * The whole struct is saved by `q` and restored by `Q`, including the text
 * state parameters. Strictly speaking the PDF spec keeps the text matrix out of
 * the graphics state, but saving it too is what well-behaved producers expect
 * inside `q ... Q` text blocks, and it keeps the stack a single value copy.
 */
class GState {
    var ctm: Mat
    var lineWidth: Float64
    var strokeColor: PdfColor
    var fillColor: PdfColor
    var fontKey: String
    var fontSize: Float64
    var charSpacing: Float64
    var wordSpacing: Float64
    var horizScale: Float64
    var leading: Float64
    var rise: Float64
    var renderMode: Int64
    var textMatrix: Mat
    var textX: Float64
    var textY: Float64
    var resources: HashMap<String, PdfValue>

    init(resources: HashMap<String, PdfValue>, ctm: Mat) {
        this.ctm = ctm
        this.lineWidth = 1.0
        this.strokeColor = PdfColor.Gray(0.0)
        this.fillColor = PdfColor.Gray(0.0)
        this.fontKey = ""
        this.fontSize = 0.0
        this.charSpacing = 0.0
        this.wordSpacing = 0.0
        this.horizScale = 100.0
        this.leading = 0.0
        this.rise = 0.0
        this.renderMode = 0
        this.textMatrix = Mat.identity()
        this.textX = 0.0
        this.textY = 0.0
        this.resources = resources
    }

    func copy(): GState {
        let clone = GState(this.resources, this.ctm)
        clone.lineWidth = this.lineWidth
        clone.strokeColor = this.strokeColor
        clone.fillColor = this.fillColor
        clone.fontKey = this.fontKey
        clone.fontSize = this.fontSize
        clone.charSpacing = this.charSpacing
        clone.wordSpacing = this.wordSpacing
        clone.horizScale = this.horizScale
        clone.leading = this.leading
        clone.rise = this.rise
        clone.renderMode = this.renderMode
        clone.textMatrix = this.textMatrix
        clone.textX = this.textX
        clone.textY = this.textY
        clone
    }
}

// ---------------------------------------------------------------------------
// Path segments

/**
 * One constructed path element, already mapped to user space.
 *
 * Points are transformed when the constructing operator runs (the PDF rule),
 * not when the path is painted. Storing the start point explicitly means a
 * segment needs no path-order bookkeeping at paint time.
 */
enum PathSeg {
    | MoveTo(Float64, Float64)
    | LineTo(Float64, Float64, Float64, Float64)
    | CurveTo(Array<Array<Float64>>)
    | RectPath(Float64, Float64, Float64, Float64)
}

// ---------------------------------------------------------------------------
// Content-stream tokens

enum ContentToken {
    | Operand(PdfValue)
    | OperatorToken(String)
    | EndToken
}

/**
 * Tokenizer for content streams: a stream of operands and operators.
 *
 * The operand syntax (numbers, names, strings, arrays, dictionaries) is the
 * shared [PdfLexer]; the difference from the file lexer is that a bare keyword
 * is an *operator* rather than an error, and that the `n g R` reference
 * lookahead is skipped (content streams contain no indirect references, and the
 * lookahead would mis-read nothing but adds a needless branch).
 */
class ContentReader {
    let lexer: PdfLexer

    init(content: Array<UInt8>) {
        this.lexer = PdfLexer(content)
    }

    func next(): ContentToken {
        this.lexer.skipWhitespace()
        if (this.lexer.eof()) {
            return ContentToken.EndToken
        }
        let b = this.lexer.peek()
        if (b == 47) {
            return ContentToken.Operand(PdfValue.PdfName(this.lexer.parseName()))
        }
        if (b == 40) {
            return ContentToken.Operand(PdfValue.PdfString(this.lexer.parseLiteralString()))
        }
        if (b == 60) {
            if (this.lexer.peekAt(1) == 60) {
                return ContentToken.Operand(PdfValue.PdfDict(this.lexer.parseDictionary()))
            }
            return ContentToken.Operand(PdfValue.PdfString(this.lexer.parseHexString()))
        }
        if (b == 91) {
            return ContentToken.Operand(PdfValue.PdfArray(this.lexer.parseArray()))
        }
        if (b == 93 || b == 62 || b == 123 || b == 125) {
            // A stray closing delimiter: skip the byte instead of failing the
            // whole page, matching the tolerance pdfminer applies.
            this.lexer.advance()
            return ContentToken.OperatorToken("")
        }
        if (isPdfRegular(UInt8(b))) {
            let word = match (this.lexer.readKeywordToken()) {
                case Some(token) => token
                case None => return ContentToken.EndToken
            }
            match (word) {
                case "true" => return ContentToken.Operand(PdfValue.PdfBool(true))
                case "false" => return ContentToken.Operand(PdfValue.PdfBool(false))
                case "null" => return ContentToken.Operand(PdfValue.PdfNull)
                case _ => ()
            }
            match (parseNumberToken(word)) {
                case Some(value) => return ContentToken.Operand(value)
                case None => ()
            }
            return ContentToken.OperatorToken(word)
        }
        this.lexer.advance()
        ContentToken.OperatorToken("")
    }

    /**
     * Read the payload of an inline image, positioned just after `ID`, and
     * consume the terminating `EI`.
     *
     * The spec allows exactly one whitespace byte between `ID` and the payload,
     * so that byte is dropped. `EI` is only accepted when it is delimited by
     * whitespace (or the end of the stream) on both sides, which keeps the
     * common `EI`-inside-binary-data case from truncating the image.
     */
    func readInlineImageData(): Array<UInt8> {
        if (!this.lexer.eof() && isPdfWhitespace(UInt8(this.lexer.peek()))) {
            this.lexer.advance()
        }
        let data = this.lexer.data
        let start = this.lexer.position()
        var index = start
        while (index + 1 < data.size) {
            if (data[index] == 69 && data[index + 1] == 73) {
                var accepted = index > start && isPdfWhitespace(data[index - 1])
                let after = index + 2
                if (accepted) {
                    accepted = after >= data.size || isPdfWhitespace(data[after])
                }
                if (accepted) {
                    this.lexer.setPosition(after)
                    // Exactly one whitespace byte separates the payload from
                    // `EI`; only that byte is dropped, not every trailing
                    // whitespace byte, because NUL (0x00) is both valid image
                    // data and PDF whitespace.
                    return data[start..index - 1].toArray()
                }
            }
            index += 1
        }
        this.lexer.setPosition(data.size)
        data[start..data.size].toArray()
    }
}

/**
 * Parse a content-stream number token.
 *
 * Numbers here are scalars: a token as `1 0 R` is never a reference, so a plain
 * decimal is all that has to be recognised. Anything else (an operator such as
 * `Tf`, or a malformed token) yields `None`.
 */
func parseNumberToken(token: String): Option<PdfValue> {
    let bytes = token.toArray()
    if (bytes.isEmpty()) {
        return None
    }
    var index: Int64 = 0
    if (bytes[0] == 43 || bytes[0] == 45) {
        index = 1
    }
    var digits: Int64 = 0
    var dots: Int64 = 0
    var cursor = index
    while (cursor < bytes.size) {
        let b = bytes[cursor]
        if (b >= 48 && b <= 57) {
            digits += 1
        } else if (b == 46) {
            dots += 1
        } else {
            return None
        }
        cursor += 1
    }
    if (digits == 0 || dots > 1) {
        return None
    }
    // A leading '+' is legal in a real number but not accepted by the parsers.
    let body = if (bytes[0] == 43) {
        String.fromUtf8(bytes[1..bytes.size].toArray())
    } else {
        token
    }
    if (dots == 0) {
        match (Int64.tryParse(body)) {
            case Some(value) => return Some(PdfValue.PdfInt(value))
            case None => ()
        }
    }
    match (Float64.tryParse(body)) {
        case Some(value) => Some(PdfValue.PdfReal(value))
        case None => None
    }
}

// ---------------------------------------------------------------------------
// Page-level context shared by nested content levels

/**
 * The per-page sink: output arrays, the font cache and the Form recursion guard.
 *
 * A Form XObject's content is interpreted by a nested [ContentLevel], which
 * shares this context so that children append to the same [PageData] and reuse
 * loaded fonts.
 */
class ExtractContext {
    let doc: PdfDocument
    let pageNumber: Int64
    let data: PageData
    let fontCache: HashMap<String, Option<PdfFont>>
    let activeForms: HashSet<String>
    var formCounter: Int64

    init(doc: PdfDocument, pageNumber: Int64, data: PageData) {
        this.doc = doc
        this.pageNumber = pageNumber
        this.data = data
        this.fontCache = HashMap<String, Option<PdfFont>>()
        this.activeForms = HashSet<String>()
        this.formCounter = 0
    }
}

// ---------------------------------------------------------------------------
// Interpreter

/**
 * One content level: the top-level page stream or the body of a Form XObject.
 *
 * Each level owns its own graphics-state stack and current path, because a Form
 * draws into the caller's output but starts from a clean stack (the caller's
 * state is unaffected by what the form does with `q`/`Q`).
 */
class ContentLevel {
    let ctx: ExtractContext
    let reader: ContentReader
    let depth: Int64
    var state: GState
    var saved: ArrayList<GState>
    var path: ArrayList<PathSeg>
    var curX: Float64
    var curY: Float64
    var subPathX: Float64
    var subPathY: Float64

    init(
        ctx: ExtractContext,
        content: Array<UInt8>,
        resources: HashMap<String, PdfValue>,
        ctm: Mat,
        depth: Int64
    ) {
        this.ctx = ctx
        this.reader = ContentReader(content)
        this.depth = depth
        this.state = GState(resources, ctm)
        this.saved = ArrayList<GState>()
        this.path = ArrayList<PathSeg>()
        this.curX = 0.0
        this.curY = 0.0
        this.subPathX = 0.0
        this.subPathY = 0.0
    }

    /** Interpret the whole stream; unknown operators are ignored. */
    func run(): Unit {
        let operands = ArrayList<PdfValue>()
        while (true) {
            match (this.reader.next()) {
                case ContentToken.EndToken => break
                case ContentToken.Operand(value) => operands.add(value)
                case ContentToken.OperatorToken(word) =>
                    if (word == "BI") {
                        operands.clear()
                        this.readInlineImage()
                        continue
                    }
                    if (!word.isEmpty()) {
                        this.dispatch(word, operands)
                    }
                    operands.clear()
            }
        }
    }

    // -- operator dispatch ------------------------------------------------

    private func dispatch(op: String, operands: ArrayList<PdfValue>): Unit {
        match (op) {
            // Graphics state
            case "q" => this.saved.add(this.state.copy())
            case "Q" => this.restoreState()
            case "cm" => this.concatMatrix(operands)
            case "w" => this.state.lineWidth = numberAt(operands, 0, this.state.lineWidth)
            case "G" => this.setStrokeColor(operands, 1)
            case "g" => this.setFillColor(operands, 1)
            case "RG" => this.setStrokeColor(operands, 3)
            case "rg" => this.setFillColor(operands, 3)
            case "K" => this.setStrokeColor(operands, 4)
            case "k" => this.setFillColor(operands, 4)
            case "SC" | "SCN" => this.setStrokeColor(operands, 0)
            case "sc" | "scn" => this.setFillColor(operands, 0)
            case "gs" => this.applyExtGState(operands)
            // Text objects
            case "BT" => this.beginText()
            case "ET" => this.endText()
            case "Tf" => this.setTextFont(operands)
            case "Td" => this.moveTextLine(operands, false)
            case "TD" => this.moveTextLine(operands, true)
            case "Tm" => this.setTextMatrix(operands)
            case "T*" => this.nextTextLine()
            case "TL" => this.state.leading = -numberAt(operands, 0, this.state.leading)
            case "Tc" => this.state.charSpacing = numberAt(operands, 0, this.state.charSpacing)
            case "Tw" => this.state.wordSpacing = numberAt(operands, 0, this.state.wordSpacing)
            case "Tz" => this.state.horizScale = numberAt(operands, 0, this.state.horizScale)
            case "Ts" => this.state.rise = numberAt(operands, 0, this.state.rise)
            case "Tr" => this.state.renderMode = intAt(operands, 0, this.state.renderMode)
            case "Tj" => this.showText(operands)
            case "TJ" => this.showTextArray(operands)
            case "'" => this.showTextNextLine(operands)
            case "\"" => this.showTextWordAndCharSpacing(operands)
            // Path construction
            case "m" => this.movePath(operands)
            case "l" => this.linePath(operands)
            case "c" => this.curvePath(operands)
            case "v" => this.curvePathV(operands)
            case "y" => this.curvePathY(operands)
            case "h" => this.closePath()
            case "re" => this.rectPath(operands)
            // Path painting
            case "S" => this.paintPath(true, false)
            case "s" =>
                this.closePath()
                this.paintPath(true, false)
            case "f" | "F" | "f*" => this.paintPath(false, true)
            case "B" | "B*" => this.paintPath(true, true)
            case "b" | "b*" =>
                this.closePath()
                this.paintPath(true, true)
            case "n" => this.path.clear()
            // Clipping: recorded but not applied.
            case "W" | "W*" => ()
            // XObjects
            case "Do" => this.drawXObject(operands)
            // Ignored operators: shading, colour-space selection, line caps and
            // joins, dash patterns, rendering intent, Type 3 glyph metrics,
            // marked content and property lists.
            case "sh" | "CS" | "cs" | "ri" | "i" | "J" | "j" | "M" | "d" | "d0" | "d1" =>
                ()
            case "BMC" | "BDC" | "EMC" | "MP" | "DP" => ()
            case _ => ()
        }
    }

    private func restoreState(): Unit {
        if (this.saved.isEmpty()) {
            return
        }
        let previous = this.saved[this.saved.size - 1]
        this.saved.remove(at: this.saved.size - 1)
        this.state = previous
    }

    private func concatMatrix(operands: ArrayList<PdfValue>): Unit {
        match (numbersAt(operands, 0, 6)) {
            case Some(values) =>
                let added = Mat(values[0], values[1], values[2], values[3], values[4], values[5])
                this.state.ctm = Mat.compose(added, this.state.ctm)
            case None => ()
        }
    }

    private func setStrokeColor(operands: ArrayList<PdfValue>, expected: Int64): Unit {
        match (colorFromOperands(operands, expected)) {
            case Some(color) => this.state.strokeColor = color
            case None => ()
        }
    }

    private func setFillColor(operands: ArrayList<PdfValue>, expected: Int64): Unit {
        match (colorFromOperands(operands, expected)) {
            case Some(color) => this.state.fillColor = color
            case None => ()
        }
    }

    /** `/ExtGState` entries we honour: `/LW` and the `/Font` pair. */
    private func applyExtGState(operands: ArrayList<PdfValue>): Unit {
        if (operands.size < 1) {
            return
        }
        let name = match (operands[0]) {
            case PdfValue.PdfName(value) => value
            case _ => return
        }
        let groups = match (this.state.resources.get("ExtGState")) {
            case Some(value) => value
            case None => return
        }
        let entries = match (this.ctx.doc.asDict(groups)) {
            case Some(value) => value
            case None => return
        }
        let raw = match (entries.get(name)) {
            case Some(value) => value
            case None => return
        }
        let group = match (this.ctx.doc.asDict(raw)) {
            case Some(value) => value
            case None => return
        }
        match (group.get("LW")) {
            case Some(value) =>
                match (numberOf(value)) {
                    case Some(width) => this.state.lineWidth = width
                    case None => ()
                }
            case None => ()
        }
        let fontPair = match (group.get("Font")) {
            case Some(value) => value
            case None => return
        }
        let items = match (this.ctx.doc.asArray(fontPair)) {
            case Some(value) => value
            case None => return
        }
        if (items.size < 2) {
            return
        }
        let key = "gs|${name}|${refKey(Some(this.ctx.doc.resolve(items[0])))}"
        this.ensureFontLoaded(key, Some(items[0]))
        this.state.fontKey = key
        this.state.fontSize = numberAt(items, 1, this.state.fontSize)
    }

    // -- text state -------------------------------------------------------

    private func beginText(): Unit {
        this.state.textMatrix = Mat.identity()
        this.state.textX = 0.0
        this.state.textY = 0.0
    }

    private func endText(): Unit {
        this.state.textMatrix = Mat.identity()
        this.state.textX = 0.0
        this.state.textY = 0.0
    }

    private func setTextFont(operands: ArrayList<PdfValue>): Unit {
        if (operands.size < 2) {
            return
        }
        let name = match (operands[0]) {
            case PdfValue.PdfName(value) => value
            case _ => return
        }
        this.state.fontSize = numberAt(operands, 1, this.state.fontSize)
        let value = this.fontResource(name)
        let key = "res|${name}|${refKey(value)}"
        match (value) {
            case Some(entry) => this.ensureFontLoaded(key, Some(entry))
            case None => this.ensureFontLoaded(key, None)
        }
        this.state.fontKey = key
    }

    private func moveTextLine(operands: ArrayList<PdfValue>, setLeading: Bool): Unit {
        if (operands.size < 2) {
            return
        }
        let tx = numberAt(operands, 0, 0.0)
        let ty = numberAt(operands, 1, 0.0)
        this.state.textMatrix = this.state.textMatrix.translated(tx, ty)
        this.state.textX = 0.0
        this.state.textY = 0.0
        if (setLeading) {
            this.state.leading = -ty
        }
    }

    private func setTextMatrix(operands: ArrayList<PdfValue>): Unit {
        match (numbersAt(operands, 0, 6)) {
            case Some(values) =>
                this.state.textMatrix = Mat(
                    values[0],
                    values[1],
                    values[2],
                    values[3],
                    values[4],
                    values[5]
                )
                this.state.textX = 0.0
                this.state.textY = 0.0
            case None => ()
        }
    }

    private func nextTextLine(): Unit {
        this.state.textMatrix = this.state.textMatrix.translated(0.0, this.state.leading)
        this.state.textX = 0.0
        this.state.textY = 0.0
    }

    private func showText(operands: ArrayList<PdfValue>): Unit {
        if (operands.size < 1) {
            return
        }
        let items = ArrayList<PdfValue>()
        items.add(operands[0])
        this.renderSequence(items)
    }

    private func showTextArray(operands: ArrayList<PdfValue>): Unit {
        if (operands.size < 1) {
            return
        }
        match (operands[0]) {
            case PdfValue.PdfArray(items) => this.renderSequence(items)
            case _ => ()
        }
    }

    private func showTextNextLine(operands: ArrayList<PdfValue>): Unit {
        this.nextTextLine()
        this.showText(operands)
    }

    private func showTextWordAndCharSpacing(operands: ArrayList<PdfValue>): Unit {
        if (operands.size < 3) {
            return
        }
        this.state.wordSpacing = numberAt(operands, 0, this.state.wordSpacing)
        this.state.charSpacing = numberAt(operands, 1, this.state.charSpacing)
        this.nextTextLine()
        let text = ArrayList<PdfValue>()
        text.add(operands[2])
        this.renderSequence(text)
    }

    /**
     * Show one `Tj`/`TJ` sequence, advancing the text position exactly like
     * pdfminer's `render_string_horizontal`.
     */
    private func renderSequence(items: ArrayList<PdfValue>): Unit {
        let font = match (this.currentFont()) {
            case Some(value) => value
            case None => return
        }
        let scaling = this.state.horizScale * 0.01
        let charSpace = this.state.charSpacing * scaling
        let wordSpace = if (font.isCid) { 0.0 } else { this.state.wordSpacing * scaling }
        let dxScale = 0.001 * this.state.fontSize * scaling
        var x = this.state.textX
        var needCharSpace = false
        for (item in items) {
            match (item) {
                case PdfValue.PdfString(bytes) =>
                    x = this.renderGlyphs(font, bytes, x, needCharSpace, charSpace, wordSpace)
                    needCharSpace = true
                case PdfValue.PdfInt(_) | PdfValue.PdfReal(_) =>
                    let kerning = match (numberOf(item)) {
                        case Some(value) => value
                        case None => 0.0
                    }
                    x -= kerning * dxScale
                    needCharSpace = true
                case _ => ()
            }
        }
        this.state.textX = x
    }

    /** Emit one glyph of `bytes` at a time, returning the pen position after. */
    private func renderGlyphs(
        font: PdfFont,
        bytes: Array<UInt8>,
        startX: Float64,
        initialNeedCharSpace: Bool,
        charSpace: Float64,
        wordSpace: Float64
    ): Float64 {
        var x = startX
        var needCharSpace = initialNeedCharSpace
        var offset: Int64 = 0
        while (offset < bytes.size) {
            let length = font.codeLength(bytes, offset)
            let step = if (length > 0) { length } else { 1 }
            var decoded: Option<(Int64, String)> = None
            try {
                decoded = Some(font.decode(bytes, offset))
            } catch (e: Exception) {
                decoded = None
            }
            match (decoded) {
                case Some(decoded) =>
                    let (code, text) = decoded
                    if (needCharSpace) {
                        x += charSpace
                    }
                    // `width` is in 1/1000 em, so the advance is
                    // `width/1000 * size * horizontal scale` (pdfminer's formula).
                    let advance =
                        font.width(code) * 0.001 * this.state.fontSize * (this.state.horizScale * 0.01)
                    this.emitChar(font, text, x, advance)
                    x += advance
                    if (code == 32 && wordSpace != 0.0) {
                        x += wordSpace
                    }
                    needCharSpace = true
                case None => ()
            }
            offset += step
        }
        x
    }

    /**
     * Place one glyph.
     *
     * The quad is built in pdfminer's text space (font size already applied to
     * the box) and mapped through `Tm x CTM x translate(tx, ty)`, then reduced to
     * its axis-aligned bounds. `size` is the mapped box height, so a non-uniform
     * or rotated matrix is reflected the same way pdfminer reflects it.
     */
    private func emitChar(font: PdfFont, text: String, penX: Float64, advance: Float64): Unit {
        let fontSize = this.state.fontSize
        let descent = font.descent * fontSize
        let rise = this.state.rise
        let bottom = descent + rise
        let top = bottom + fontSize
        let matrix = Mat.compose(
            this.state.textMatrix,
            Mat.compose(this.state.ctm, Mat.translation(penX, this.state.textY))
        )
        let (ax, ay) = matrix.apply(0.0, bottom)
        let (bx, by) = matrix.apply(advance, bottom)
        let (cx, cy) = matrix.apply(0.0, top)
        let (dx, dy) = matrix.apply(advance, top)
        let xs: Array<Float64> = [ax, bx, cx, dx]
        let ys: Array<Float64> = [ay, by, cy, dy]
        let x0 = minValue(xs)
        let x1 = maxValue(xs)
        let y0 = minValue(ys)
        let y1 = maxValue(ys)
        this.ctx.data.chars.add(
            CharObj(
                text: text,
                x0: x0,
                y0: y0,
                x1: x1,
                y1: y1,
                fontname: font.name,
                size: y1 - y0,
                color: this.state.strokeColor,
                page: this.ctx.pageNumber
            )
        )
    }

    // -- fonts ------------------------------------------------------------

    /** Raw `/Font` entry for a resource name in the current resources. */
    private func fontResource(name: String): Option<PdfValue> {
        let fontsValue = match (this.state.resources.get("Font")) {
            case Some(value) => value
            case None => return None
        }
        let fonts = match (this.ctx.doc.asDict(fontsValue)) {
            case Some(value) => value
            case None => return None
        }
        fonts.get(name)
    }

    /**
     * Load (once) and cache the font behind a cache key.
     *
     * A font that fails to load is cached as `None` so a broken font dictionary
     * costs one attempt and never fails the page; the glyphs in that font are
     * then skipped because their metrics are unknown.
     */
    private func ensureFontLoaded(key: String, value: Option<PdfValue>): Unit {
        if (this.ctx.fontCache.contains(key)) {
            return
        }
        let entry = match (value) {
            case Some(item) => item
            case None =>
                this.ctx.fontCache.add(key, None<PdfFont>)
                return
        }
        let fontDict = match (this.ctx.doc.asDict(entry)) {
            case Some(item) => item
            case None =>
                this.ctx.fontCache.add(key, None<PdfFont>)
                return
        }
        var loaded: Option<PdfFont> = None
        try {
            loaded = Some(loadFont(this.ctx.doc, fontDict))
        } catch (e: Exception) {
            loaded = None
        }
        this.ctx.fontCache.add(key, loaded)
    }

    private func currentFont(): Option<PdfFont> {
        if (this.state.fontKey.isEmpty()) {
            return None
        }
        match (this.ctx.fontCache.get(this.state.fontKey)) {
            case Some(entry) => entry
            case None => None
        }
    }

    // -- paths ------------------------------------------------------------

    private func movePath(operands: ArrayList<PdfValue>): Unit {
        match (numbersAt(operands, 0, 2)) {
            case Some(values) =>
                let (x, y) = this.state.ctm.apply(values[0], values[1])
                this.curX = x
                this.curY = y
                this.subPathX = x
                this.subPathY = y
                this.path.add(PathSeg.MoveTo(x, y))
            case None => ()
        }
    }

    private func linePath(operands: ArrayList<PdfValue>): Unit {
        match (numbersAt(operands, 0, 2)) {
            case Some(values) =>
                let (x, y) = this.state.ctm.apply(values[0], values[1])
                this.path.add(PathSeg.LineTo(this.curX, this.curY, x, y))
                this.curX = x
                this.curY = y
            case None => ()
        }
    }

    private func curvePath(operands: ArrayList<PdfValue>): Unit {
        match (numbersAt(operands, 0, 6)) {
            case Some(values) =>
                let points = ArrayList<Array<Float64>>()
                points.add(pointOf(this.curX, this.curY))
                addMappedPoint(points, this.state.ctm, values[0], values[1])
                addMappedPoint(points, this.state.ctm, values[2], values[3])
                let (endX, endY) = addMappedPoint(points, this.state.ctm, values[4], values[5])
                this.path.add(PathSeg.CurveTo(points.toArray()))
                this.curX = endX
                this.curY = endY
            case None => ()
        }
    }

    /** `v`: the first control point is the current point. */
    private func curvePathV(operands: ArrayList<PdfValue>): Unit {
        match (numbersAt(operands, 0, 4)) {
            case Some(values) =>
                let points = ArrayList<Array<Float64>>()
                points.add(pointOf(this.curX, this.curY))
                addMappedPoint(points, this.state.ctm, values[0], values[1])
                let (endX, endY) = addMappedPoint(points, this.state.ctm, values[2], values[3])
                this.path.add(PathSeg.CurveTo(points.toArray()))
                this.curX = endX
                this.curY = endY
            case None => ()
        }
    }

    /** `y`: the second control point is the end point. */
    private func curvePathY(operands: ArrayList<PdfValue>): Unit {
        match (numbersAt(operands, 0, 4)) {
            case Some(values) =>
                let points = ArrayList<Array<Float64>>()
                points.add(pointOf(this.curX, this.curY))
                addMappedPoint(points, this.state.ctm, values[0], values[1])
                let (endX, endY) = addMappedPoint(points, this.state.ctm, values[2], values[3])
                points.add(pointOf(endX, endY))
                this.path.add(PathSeg.CurveTo(points.toArray()))
                this.curX = endX
                this.curY = endY
            case None => ()
        }
    }

    private func closePath(): Unit {
        let dx = this.curX - this.subPathX
        let dy = this.curY - this.subPathY
        if (dx * dx + dy * dy > 0.0) {
            this.path.add(PathSeg.LineTo(this.curX, this.curY, this.subPathX, this.subPathY))
        }
        this.curX = this.subPathX
        this.curY = this.subPathY
    }

    private func rectPath(operands: ArrayList<PdfValue>): Unit {
        match (numbersAt(operands, 0, 4)) {
            case Some(values) =>
                let (x0, y0) = this.state.ctm.apply(values[0], values[1])
                let (x1, y1) = this.state.ctm.apply(values[0] + values[2], values[1] + values[3])
                this.path.add(PathSeg.RectPath(x0, y0, x1, y1))
                this.curX = x0
                this.curY = y0
                this.subPathX = x0
                this.subPathY = y0
            case None => ()
        }
    }

    /**
     * Materialise the current path as [RectObj]/[LineObj]/[CurveObj] entries.
     *
     * Fill and stroke flags come from the painting operator; the colour is the
     * stroking colour, which is what pdfplumber reports for a shape.
     */
    private func paintPath(stroke: Bool, fill: Bool): Unit {
        for (segment in this.path) {
            match (segment) {
                case PathSeg.RectPath(x0, y0, x1, y1) =>
                    let left = if (x0 < x1) { x0 } else { x1 }
                    let right = if (x0 < x1) { x1 } else { x0 }
                    let bottom = if (y0 < y1) { y0 } else { y1 }
                    let top = if (y0 < y1) { y1 } else { y0 }
                    this.ctx.data.rects.add(
                        RectObj(
                            x0: left,
                            y0: bottom,
                            x1: right,
                            y1: top,
                            fill: fill,
                            stroke: stroke,
                            color: this.state.strokeColor,
                            width: this.state.lineWidth,
                            page: this.ctx.pageNumber
                        )
                    )
                case PathSeg.LineTo(fromX, fromY, toX, toY) =>
                    this.ctx.data.lines.add(
                        LineObj(
                            x0: fromX,
                            y0: fromY,
                            x1: toX,
                            y1: toY,
                            stroke: stroke,
                            color: this.state.strokeColor,
                            width: this.state.lineWidth,
                            page: this.ctx.pageNumber
                        )
                    )
                case PathSeg.CurveTo(points) =>
                    this.addCurve(points, stroke)
                case PathSeg.MoveTo(_, _) => ()
            }
        }
        this.path.clear()
    }

    private func addCurve(points: Array<Array<Float64>>, stroke: Bool): Unit {
        if (points.isEmpty()) {
            return
        }
        var x0 = points[0][0]
        var y0 = points[0][1]
        var x1 = x0
        var y1 = y0
        for (point in points) {
            if (point[0] < x0) {
                x0 = point[0]
            }
            if (point[1] < y0) {
                y0 = point[1]
            }
            if (point[0] > x1) {
                x1 = point[0]
            }
            if (point[1] > y1) {
                y1 = point[1]
            }
        }
        this.ctx.data.curves.add(
            CurveObj(
                x0: x0,
                y0: y0,
                x1: x1,
                y1: y1,
                points: points,
                stroke: stroke,
                page: this.ctx.pageNumber
            )
        )
    }

    // -- XObjects ---------------------------------------------------------

    private func drawXObject(operands: ArrayList<PdfValue>): Unit {
        if (operands.size < 1) {
            return
        }
        let name = match (operands[0]) {
            case PdfValue.PdfName(value) => value
            case _ => return
        }
        let entry = match (this.xobjectResource(name)) {
            case Some(value) => value
            case None => return
        }
        let stream = match (this.ctx.doc.resolve(entry)) {
            case PdfValue.PdfStream(value) => value
            case _ => return
        }
        match (dictName(stream.dict, "Subtype")) {
            case Some(subtype) =>
                if (subtype == "Image") {
                    this.addImage(stream, decodeStreamOrRaw(this.ctx.doc, stream))
                } else if (subtype == "Form") {
                    this.runForm(stream, entry)
                }
            case None => ()
        }
    }

    private func xobjectResource(name: String): Option<PdfValue> {
        let value = match (this.state.resources.get("XObject")) {
            case Some(entry) => entry
            case None => return None
        }
        let objects = match (this.ctx.doc.asDict(value)) {
            case Some(entry) => entry
            case None => return None
        }
        objects.get(name)
    }

    /**
     * Append an image placed on the unit square and mapped through the CTM.
     *
     * `width`/`height` are the on-page extents (pdfplumber's `width`/`height`),
     * not the pixel dimensions. `format` stays `"unknown"` here: identifying the
     * codec belongs to the image layer, which still has `imageStream`.
     */
    private func addImage(stream: PdfStream, payload: Array<UInt8>): Unit {
        let (ux0, uy0) = this.state.ctm.apply(0.0, 0.0)
        let (ux1, uy1) = this.state.ctm.apply(1.0, 0.0)
        let (ux2, uy2) = this.state.ctm.apply(0.0, 1.0)
        let (ux3, uy3) = this.state.ctm.apply(1.0, 1.0)
        let xs: Array<Float64> = [ux0, ux1, ux2, ux3]
        let ys: Array<Float64> = [uy0, uy1, uy2, uy3]
        let x0 = minValue(xs)
        let x1 = maxValue(xs)
        let y0 = minValue(ys)
        let y1 = maxValue(ys)
        let index = this.ctx.data.images.size
        this.ctx.data.images.add(
            ImageObj(
                x0: x0,
                y0: y0,
                x1: x1,
                y1: y1,
                width: x1 - x0,
                height: y1 - y0,
                streamId: "p${this.ctx.pageNumber}_img_${index}",
                format: "unknown",
                page: this.ctx.pageNumber,
                imageData: Some(payload),
                imageStream: Some(stream)
            )
        )
    }

    private func runForm(stream: PdfStream, entry: PdfValue): Unit {
        if (this.depth >= MAX_FORM_DEPTH) {
            return
        }
        let key = this.formKey(entry)
        if (this.ctx.activeForms.contains(key)) {
            return
        }
        this.ctx.activeForms.add(key)
        let content = try {
            this.ctx.doc.streamData(stream)
        } catch (e: Exception) {
            Array<UInt8>()
        }
        let matrix = match (stream.dict.get("Matrix")) {
            case Some(value) => this.matrixOf(value)
            case None => Mat.identity()
        }
        let resources = match (stream.dict.get("Resources")) {
            case Some(value) =>
                match (this.ctx.doc.asDict(value)) {
                    case Some(entries) => entries
                    case None => this.state.resources
                }
            case None => this.state.resources
        }
        let child = ContentLevel(
            this.ctx,
            content,
            resources,
            Mat.compose(matrix, this.state.ctm),
            this.depth + 1
        )
        child.run()
        if (this.ctx.activeForms.contains(key)) {
            this.ctx.activeForms.remove(key)
        }
    }

    private func formKey(entry: PdfValue): String {
        match (entry) {
            case PdfValue.PdfRef(number, generation) => return "form:${number}:${generation}"
            case _ =>
                this.ctx.formCounter += 1
                return "form:inline:${this.ctx.formCounter}"
        }
    }

    private func matrixOf(value: PdfValue): Mat {
        let items = match (this.ctx.doc.asArray(value)) {
            case Some(entries) => entries
            case None => return Mat.identity()
        }
        match (numbersAt(items, 0, 6)) {
            case Some(values) => Mat(
                values[0],
                values[1],
                values[2],
                values[3],
                values[4],
                values[5]
            )
            case None => Mat.identity()
        }
    }

    /**
     * `BI <dict> ID <data> EI`.
     *
     * The dictionary keys are abbreviations (`/W`, `/H`, `/BPC`, `/CS`, `/F`),
     * kept as-is so the filter chain in [PdfDocument.streamData] can decode the
     * payload the same way it decodes image XObjects.
     */
    private func readInlineImage(): Unit {
        let entries = HashMap<String, PdfValue>()
        var pendingKey = ""
        while (true) {
            match (this.reader.next()) {
                case ContentToken.EndToken => return
                case ContentToken.OperatorToken(word) =>
                    if (word == "ID") {
                        break
                    }
                    if (word.isEmpty()) {
                        continue
                    }
                    if (!pendingKey.isEmpty()) {
                        entries.add(pendingKey, PdfValue.PdfName(word))
                        pendingKey = ""
                    } else {
                        pendingKey = word
                    }
                case ContentToken.Operand(value) =>
                    match (value) {
                        case PdfValue.PdfName(name) =>
                            if (!pendingKey.isEmpty()) {
                                entries.add(pendingKey, value)
                                pendingKey = ""
                            } else {
                                pendingKey = name
                            }
                        case _ =>
                            if (!pendingKey.isEmpty()) {
                                entries.add(pendingKey, value)
                                pendingKey = ""
                            }
                    }
            }
        }
        let raw = this.reader.readInlineImageData()
        let stream = PdfStream(entries, raw)
        this.addImage(stream, decodeStreamOrRaw(this.ctx.doc, stream))
    }
}

// ---------------------------------------------------------------------------
// Small helpers

func pointOf(x: Float64, y: Float64): Array<Float64> {
    let point: Array<Float64> = [x, y]
    point
}

func minValue(values: Array<Float64>): Float64 {
    if (values.isEmpty()) {
        return 0.0
    }
    var result = values[0]
    for (value in values) {
        if (value < result) {
            result = value
        }
    }
    result
}

func maxValue(values: Array<Float64>): Float64 {
    if (values.isEmpty()) {
        return 0.0
    }
    var result = values[0]
    for (value in values) {
        if (value > result) {
            result = value
        }
    }
    result
}

/** Map (x, y) through `matrix`, append it and return the mapped pair. */
func addMappedPoint(
    points: ArrayList<Array<Float64>>,
    matrix: Mat,
    x: Float64,
    y: Float64
): (Float64, Float64) {
    let (mappedX, mappedY) = matrix.apply(x, y)
    points.add(pointOf(mappedX, mappedY))
    (mappedX, mappedY)
}

func numberOf(value: PdfValue): Option<Float64> {
    match (value) {
        case PdfValue.PdfInt(number) => Some(Float64(number))
        case PdfValue.PdfReal(number) => Some(number)
        case _ => None
    }
}

/** `operands[start .. start+count]` as numbers, or `None` if any is not one. */
func numbersAt(operands: ArrayList<PdfValue>, start: Int64, count: Int64): Option<Array<Float64>> {
    if (start < 0 || count < 0 || start + count > operands.size) {
        return None
    }
    let values = ArrayList<Float64>()
    var index = start
    while (index < start + count) {
        match (numberOf(operands[index])) {
            case Some(value) => values.add(value)
            case None => return None
        }
        index += 1
    }
    Some(values.toArray())
}

func numberAt(operands: ArrayList<PdfValue>, index: Int64, fallback: Float64): Float64 {
    if (index < 0 || index >= operands.size) {
        return fallback
    }
    match (numberOf(operands[index])) {
        case Some(value) => value
        case None => fallback
    }
}

func intAt(operands: ArrayList<PdfValue>, index: Int64, fallback: Int64): Int64 {
    if (index < 0 || index >= operands.size) {
        return fallback
    }
    match (operands[index]) {
        case PdfValue.PdfInt(value) => value
        case PdfValue.PdfReal(value) => Int64(value)
        case _ => fallback
    }
}

/**
 * Colour operand decoding for `G/g/RG/rg/K/k/SC/SCN/sc/scn`.
 *
 * `expected` is the operand count implied by the operator (1/3/4), or 0 for the
 * generic `sc`/`SC` operators where 1, 3 or 4 numbers are all valid. A single
 * name operand (pattern colour spaces) becomes [PdfColor.Named].
 */
func colorFromOperands(operands: ArrayList<PdfValue>, expected: Int64): Option<PdfColor> {
    if (operands.isEmpty()) {
        return None
    }
    for (operand in operands) {
        match (operand) {
            case PdfValue.PdfName(name) =>
                return if (expected == 0) {
                    Some(PdfColor.Named(name))
                } else {
                    None
                }
            case _ => ()
        }
    }
    let values = match (numbersAt(operands, 0, operands.size)) {
        case Some(items) => items
        case None => return None
    }
    let count = if (expected == 0) { values.size } else { expected }
    if (values.size != count) {
        return None
    }
    match (count) {
        case 1 => Some(PdfColor.Gray(values[0]))
        case 3 => Some(PdfColor.Rgb(values[0], values[1], values[2]))
        case 4 => Some(PdfColor.Cmyk(values[0], values[1], values[2], values[3]))
        case _ => None
    }
}

/** Cache key fragment for a resource entry: indirect references stay distinct. */
func refKey(value: Option<PdfValue>): String {
    match (value) {
        case Some(PdfValue.PdfRef(number, generation)) => "${number}_${generation}"
        case Some(_) => "direct"
        case None => "missing"
    }
}

func dictName(dict: HashMap<String, PdfValue>, key: String): Option<String> {
    match (dict.get(key)) {
        case Some(PdfValue.PdfName(name)) => Some(name)
        case _ => None
    }
}

/** Decoded stream payload, falling back to the raw bytes if a filter fails. */
func decodeStreamOrRaw(doc: PdfDocument, stream: PdfStream): Array<UInt8> {
    try {
        doc.streamData(stream)
    } catch (e: Exception) {
        stream.raw
    }
}

/** Human-readable colour for diagnostics and tests. */
public func describeColor(color: PdfColor): String {
    match (color) {
        case PdfColor.Gray(value) => "Gray(${formatDecimal(value, 3)})"
        case PdfColor.Rgb(r, g, b) =>
            "Rgb(${formatDecimal(r, 3)},${formatDecimal(g, 3)},${formatDecimal(b, 3)})"
        case PdfColor.Cmyk(c, m, y, k) =>
            "Cmyk(${formatDecimal(c, 3)},${formatDecimal(m, 3)},${formatDecimal(y, 3)},${formatDecimal(k, 3)})"
        case PdfColor.Named(name) => "Named(${name})"
    }
}

/** Fixed-point rendering of a float for logs and debug output. */
public func formatDecimal(value: Float64, digits: Int64): String {
    var magnitude = value
    var negative = false
    if (magnitude < 0.0) {
        negative = true
        magnitude = 0.0 - magnitude
    }
    var factor: Int64 = 1
    var step: Int64 = 0
    while (step < digits) {
        factor *= 10
        step += 1
    }
    let scaled = Int64(magnitude * Float64(factor) + 0.5)
    let whole = scaled / factor
    let fraction = scaled % factor
    if (digits <= 0) {
        let sign = if (negative && scaled != 0) { "-" } else { "" }
        return sign + whole.toString()
    }
    var fractionText = fraction.toString()
    while (fractionText.size < digits) {
        fractionText = "0" + fractionText
    }
    let sign = if (negative && scaled != 0) { "-" } else { "" }
    sign + whole.toString() + "." + fractionText
}

// ---------------------------------------------------------------------------
// Entry point

/**
 * Interpret one page's content stream into [PageData].
 *
 * `chars`, `words`, `rects`, `lines`, `curves` and `images` are filled;
 * `tables` is left empty (table detection is a separate stage). `/Rotate` is not
 * applied, so all coordinates are in unrotated page space.
 *
 * Coordinate origin: pdfplumber reports positions relative to the page box, so
 * every object is shifted once here by `-(box.x0, box.y0)`. A page whose
 * MediaBox starts at a non-zero origin (`[0 100 612 892]`) therefore reports the
 * same numbers as pdfplumber, and `width`/`height` stay the box extents. The
 * shift happens after the whole stream (including nested Forms) has run, so the
 * interpreter itself works in plain unshifted user space and nothing is offset
 * twice.
 *
 * A malformed stream (unterminated string, dictionary or array) raises the
 * lexer's [PdfError] with the byte offset; individual broken fonts or image
 * streams are skipped rather than failing the page.
 */
public func extractPage(doc: PdfDocument, page: PdfPage): PageData {
    let data = PageData(width: page.width, height: page.height)
    let context = ExtractContext(doc, page.number, data)
    let content = page.contents
    if (content.size > 0) {
        let level = ContentLevel(context, content, page.resources, Mat.identity(), 0)
        level.run()
    }
    let box = page.box()
    let offsetX = box[0]
    let offsetY = box[1]
    if (offsetX != 0.0 || offsetY != 0.0) {
        shiftToBoxOrigin(data, offsetX, offsetY)
    }
    // Words are derived from the already-shifted characters, so their boxes
    // match the chars' boxes exactly.
    data.words = buildWords(data.chars)
    data
}

/**
 * Translate every extracted object by `-(offsetX, offsetY)`.
 *
 * `width`/`height` of a rect/image are extents and are left alone; curve control
 * points move together with the curve's bounding box.
 */
func shiftToBoxOrigin(data: PageData, offsetX: Float64, offsetY: Float64): Unit {
    for (char in data.chars) {
        char.x0 -= offsetX
        char.y0 -= offsetY
        char.x1 -= offsetX
        char.y1 -= offsetY
    }
    for (rect in data.rects) {
        rect.x0 -= offsetX
        rect.y0 -= offsetY
        rect.x1 -= offsetX
        rect.y1 -= offsetY
    }
    for (line in data.lines) {
        line.x0 -= offsetX
        line.y0 -= offsetY
        line.x1 -= offsetX
        line.y1 -= offsetY
    }
    for (curve in data.curves) {
        curve.x0 -= offsetX
        curve.y0 -= offsetY
        curve.x1 -= offsetX
        curve.y1 -= offsetY
        let points = ArrayList<Array<Float64>>(curve.points.size)
        for (point in curve.points) {
            let moved: Array<Float64> = [point[0] - offsetX, point[1] - offsetY]
            points.add(moved)
        }
        curve.points = points.toArray()
    }
    for (image in data.images) {
        image.x0 -= offsetX
        image.y0 -= offsetY
        image.x1 -= offsetX
        image.y1 -= offsetY
    }
}
