package pdf_inspector_mcp.mcp

import std.collection.*
import std.convert.*
import pdf_inspector_mcp.pdf.*

/**
 * Hand-written JSON helpers for the MCP tool payloads.
 *
 * The tools build their result documents as strings instead of going through
 * `stdx.encoding.json` for two reasons:
 *
 * 1. **Key order and numbers.** `JsonObject` is hash-backed (order is lost) and
 *    `JsonFloat` always prints six decimals (`612.000000`, where the Python
 *    server emits `612.0`), so both the object layout and the number formatting
 *    have to be written out here.
 * 2. **Consistency with the export layer.** The heavy payloads (`pdf_export`,
 *    `pdf_extract_*`) already arrive pre-rendered as JSON text from
 *    `pdf_inspector_mcp.export`; the small wrappers around them should look the
 *    same, so they use the same escaping rules and the same "shortest round-trip"
 *    number text.
 *
 * Everything here is a pure function over strings/`PdfColor`, which is what
 * makes `src/tests/tools_test.cj` able to cover the formatting rules without a
 * PDF fixture.
 */

/** `value` as a JSON string literal, `ensure_ascii=False` style. */
public func jsonQuote(value: String): String {
    let builder = StringBuilder()
    builder.append("\"")
    for (rune in value.runes()) {
        let code = Int64(UInt32(rune))
        if (code == 0x22) {
            builder.append("\\\"")
        } else if (code == 0x5C) {
            builder.append("\\\\")
        } else if (code == 0x08) {
            builder.append("\\b")
        } else if (code == 0x0C) {
            builder.append("\\f")
        } else if (code == 0x0A) {
            builder.append("\\n")
        } else if (code == 0x0D) {
            builder.append("\\r")
        } else if (code == 0x09) {
            builder.append("\\t")
        } else if (code < 0x20) {
            builder.append("\\u00")
            builder.append(hexDigit(code / 16))
            builder.append(hexDigit(code % 16))
        } else {
            builder.append(rune)
        }
    }
    builder.append("\"")
    return builder.toString()
}

/** `["a", "b"]`-style array of JSON strings. */
public func jsonStringArray(values: Array<String>): String {
    let builder = StringBuilder()
    builder.append("[")
    var first = true
    for (value in values) {
        if (!first) {
            builder.append(",")
        }
        first = false
        builder.append(jsonQuote(value))
    }
    builder.append("]")
    return builder.toString()
}

/** `[1, 2, 3]`-style array of JSON integers. */
public func jsonIntArray(values: ArrayList<Int64>): String {
    let builder = StringBuilder()
    builder.append("[")
    var first = true
    for (value in values) {
        if (!first) {
            builder.append(",")
        }
        first = false
        builder.append("${value}")
    }
    builder.append("]")
    return builder.toString()
}

/**
 * `value` the way Python's `str(float)` prints it: shortest round-trip digits,
 * a `.0` on integral values (`1.0`, `0.0`, `10.0`), and scientific notation
 * outside the `1e-4 .. 1e16` range (`1e-07`, `1e+16`).
 *
 * `Float64.toString()` is unusable here (six fixed decimals: `0.500000`), so
 * the digits are recovered by formatting with increasing `%g` precision until
 * the text parses back to the same value. `%g` also picks the shortest form on
 * its own, which keeps the loop cheap in practice (one to three rounds for the
 * sizes and colour components a PDF carries).
 */
public func formatFloatPy(value: Float64): String {
    if (value != value) {
        return "nan"
    }
    if (value == Float64.Inf) {
        return "inf"
    }
    if (value == -Float64.Inf) {
        return "-inf"
    }
    if (value == 0.0) {
        return "0.0"
    }
    var shortest = value.format(".17g")
    for (precision in 1..18) {
        let candidate = value.format(".${precision}g")
        if (Float64.parse(candidate) == value) {
            shortest = candidate
            break
        }
    }
    return pythonFloatText(shortest)
}

/**
 * A colour as Python's `str(tuple)` would print it, for the `colors` array of
 * `pdf_analyze_fonts`.
 *
 * pdfplumber hands back the numbers it read from the content stream, so a
 * `0 g` operand arrives as the *integer* `0` and `str((0,))` is `"(0,)"`, while
 * an RGB operand authored as `1 0 0 RG` yields `"(1, 0, 0)"`. The Cangjie PDF
 * layer stores every component as `Float64`, so the operand's original type is
 * unavailable; the rule applied here keeps the common cases readable: gray
 * components print without a fractional part when they are integral
 * (`"(0,)"`, `"(0.5,)"`), the other colour spaces keep the float form
 * (`"(1.0, 0.0, 0.0)"`). A named colour (a `/DeviceRGB`-style name or a
 * pre-set string) is printed as-is, exactly like `str("name")`.
 */
public func colorStatString(color: PdfColor): String {
    let builder = StringBuilder()
    builder.append("(")
    match (color) {
        case PdfColor.Gray(gray) =>
            builder.append(integralOrPyFloat(gray))
            // A one-element tuple keeps its trailing comma: `str((0,))` == "(0,)".
            builder.append(",")
        case PdfColor.Rgb(red, green, blue) =>
            builder.append(formatFloatPy(red))
            builder.append(", ")
            builder.append(formatFloatPy(green))
            builder.append(", ")
            builder.append(formatFloatPy(blue))
        case PdfColor.Cmyk(cyan, magenta, yellow, black) =>
            builder.append(formatFloatPy(cyan))
            builder.append(", ")
            builder.append(formatFloatPy(magenta))
            builder.append(", ")
            builder.append(formatFloatPy(yellow))
            builder.append(", ")
            builder.append(formatFloatPy(black))
        case PdfColor.Named(name) => return name
    }
    builder.append(")")
    return builder.toString()
}

/**
 * A colour as JSON: `[gray]`, `[r,g,b]`, `[c,m,y,k]`, or `"name"` - the same
 * shapes `export.colorNode` produces for page objects, usable by tests and by
 * any future payload that needs the raw components.
 */
public func colorJson(color: PdfColor): String {
    match (color) {
        case PdfColor.Gray(gray) => return "[" + formatFloatPy(gray) + "]"
        case PdfColor.Rgb(red, green, blue) =>
            return "[" + formatFloatPy(red) + "," + formatFloatPy(green) + "," + formatFloatPy(blue) + "]"
        case PdfColor.Cmyk(cyan, magenta, yellow, black) =>
            return "[" + formatFloatPy(cyan) + "," + formatFloatPy(magenta) + "," +
                formatFloatPy(yellow) + "," + formatFloatPy(black) + "]"
        case PdfColor.Named(name) => return jsonQuote(name)
    }
}

// ---------------------------------------------------------------------------
// Internals

func hexDigit(value: Int64): Rune {
    if (value < 10) {
        return Rune(UInt32(0x30 + value))
    }
    return Rune(UInt32(0x61 + value - 10))
}

/** Integral values without a fractional part, everything else as `str(float)`. */
func integralOrPyFloat(value: Float64): String {
    if (value == value && value != Float64.Inf && value != -Float64.Inf && value != 0.0 &&
        value > -1.0e18 && value < 1.0e18 && value == Float64(Int64(value))) {
        return "${Int64(value)}"
    }
    if (value == 0.0) {
        return "0"
    }
    return formatFloatPy(value)
}

/**
 * Re-lay out a `%g` rendering (`"1.234e+05"`, `"0.0001234"`, `"612"`) the way
 * Python's float `repr` would.
 *
 * `%g` already picked the shortest digits; what it does not match is Python's
 * choice of fixed vs. exponential notation. Python prints fixed notation while
 * the decimal point sits at `-3 .. 17` (i.e. `0.0001 <= |v| < 1e16`) and
 * scientific notation outside it, so the digits and the exponent are recovered
 * from the `%g` text and re-assembled under that rule.
 */
func pythonFloatText(text: String): String {
    var body = text
    var negative = false
    if (body.size > 0 && body[0] == b'-') {
        negative = true
        body = body[1..]
    }
    var exponent: Int64 = 0
    var mantissa = body
    if (let Some(mark) <- body.indexOf("e")) {
        mantissa = body[0..mark]
        var exponentText = body[mark + 1..body.size]
        if (exponentText.size > 0 && exponentText[0] == b'+') {
            exponentText = exponentText[1..]
        }
        exponent = Int64.parse(exponentText)
    }

    var digitsBeforePoint = mantissa.size
    let collected = StringBuilder()
    if (let Some(dot) <- mantissa.indexOf(".")) {
        digitsBeforePoint = dot
        collected.append(mantissa[0..dot])
        collected.append(mantissa[dot + 1..mantissa.size])
    } else {
        collected.append(mantissa)
    }
    let raw = collected.toString()
    // `%g` never emits an all-zero mantissa (that is the value 0, handled by the
    // caller), so the scan below always leaves at least one digit.
    var start = 0
    while (start + 1 < raw.size && raw[start] == b'0') {
        start += 1
    }
    let digits = raw[start..raw.size]
    let count = digits.size
    // `n` is the number of digits before the decimal point in fixed notation.
    let n = exponent - (raw.size - digitsBeforePoint) + count

    let builder = StringBuilder()
    if (negative) {
        builder.append("-")
    }
    if (count <= n && n <= 16) {
        builder.append(digits)
        for (_ in 0..(n - count)) {
            builder.append("0")
        }
        builder.append(".0")
    } else if (0 < n && n <= 16) {
        builder.append(digits[0..n])
        builder.append(".")
        builder.append(digits[n..count])
    } else if (-4 < n && n <= 0) {
        builder.append("0.")
        for (_ in 0..(-n)) {
            builder.append("0")
        }
        builder.append(digits)
    } else {
        builder.append(digits[0..1])
        if (count > 1) {
            builder.append(".")
            builder.append(digits[1..count])
        }
        builder.append("e")
        let scientific = n - 1
        if (scientific < 0) {
            builder.append("-")
        } else {
            builder.append("+")
        }
        let magnitude = if (scientific < 0) {
            -scientific
        } else {
            scientific
        }
        if (magnitude < 10) {
            builder.append("0")
        }
        builder.append("${magnitude}")
    }
    return builder.toString()
}
