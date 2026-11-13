#!/usr/bin/env python3
"""Generate the Cangjie font data tables for the standard 14 PDF fonts.

The script writes two generated sources:

  ../pdf4cj/src/metrics_data.cj   -- Base14Metrics + base14Metrics()/normalizeBase14Name()
  ../pdf4cj/src/encoding_data.cj  -- built-in encodings + glyphNameToUnicode()

pdf4cj is a standalone sibling project of this repository (../pdf4cj).

Data sources (read from the project's Python venv; no network access):

  * reportlab.pdfbase._fontdata.encodings
        256-entry code -> glyph name tables for WinAnsi / MacRoman / Standard /
        PDFDoc / MacExpert / Symbol / ZapfDingbats.
  * reportlab.pdfbase._fontdata.widthsByFontGlyph
        per-font glyph name -> advance width in 1/1000 em (Adobe core AFM values).
  * pdfminer.fontmetrics.FONT_METRICS
        Ascender/Descender exactly as pdfminer (and therefore pdfplumber) resolves
        them for a base-14 font that has no /FontDescriptor.  Values that pdfminer
        does not define (Symbol, ZapfDingbats) become 0.0, which reproduces
        pdfplumber's character boxes for those fonts.
  * pdfminer.encodingdb.name2unicode / pdfminer.glyphlist
        Adobe Glyph List 2.0 (plus the uniXXXX / uXXXX / name_components rules).
    reportlab's WinAnsi/MacRoman tables are additionally decoded with cp1252 /
    mac_roman to fill names the AGL does not list.

Reference points used while validating (see the report at the end of a run):
Helvetica space=278 a=556 l=222 p=556, Courier a=600, Helvetica ascent/descent
0.718/-0.207 (pdfplumber puts a 12 pt Helvetica glyph at baseline 700 into
y0=697.516 .. y1=709.516, i.e. descent -0.207 and a box of exactly one em).

The output is deterministic: keys are sorted, no timestamps, LF line endings,
UTF-8, trailing newline.  Run it again to regenerate byte-identical files.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# locate a Python that has the data sources installed
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
VENV_PYTHON = REPO_ROOT / ".venv" / "bin" / "python"
OUT_DIR = REPO_ROOT.parent / "pdf4cj" / "src"
METRICS_PATH = OUT_DIR / "metrics_data.cj"
ENCODING_PATH = OUT_DIR / "encoding_data.cj"


def _ensure_data_sources() -> None:
    """Re-exec under the repo venv when the current interpreter lacks the data."""
    try:
        import pdfminer.fontmetrics  # noqa: F401
        import reportlab.pdfbase._fontdata  # noqa: F401
    except ImportError:
        if VENV_PYTHON.exists() and Path(sys.executable) != VENV_PYTHON:
            os.execv(str(VENV_PYTHON), [str(VENV_PYTHON), *sys.argv])
        raise SystemExit(
            "reportlab and pdfminer.six are required; install them or run this "
            f"script with {VENV_PYTHON}"
        )


_ensure_data_sources()

from pdfminer.encodingdb import name2unicode  # noqa: E402
from pdfminer.fontmetrics import FONT_METRICS  # noqa: E402
from reportlab.pdfbase import _fontdata as fontdata  # noqa: E402

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

#: reportlab's standard font order.
BASE14 = [
    "Courier",
    "Courier-Bold",
    "Courier-Oblique",
    "Courier-BoldOblique",
    "Helvetica",
    "Helvetica-Bold",
    "Helvetica-Oblique",
    "Helvetica-BoldOblique",
    "Times-Roman",
    "Times-Bold",
    "Times-Italic",
    "Times-BoldItalic",
    "Symbol",
    "ZapfDingbats",
]

#: Built-in encoding that a simple font of this family uses when it has no /Encoding.
DEFAULT_ENCODING = {
    "Symbol": "SymbolEncoding",
    "ZapfDingbats": "ZapfDingbatsEncoding",
}
LATIN_DEFAULT_ENCODING = "StandardEncoding"
#: Codes left undefined by the built-in encoding are filled from WinAnsi, which is
#: what most Latin-1 PDFs actually use (0x80-0x9F quotes/dashes, 0xA0, 0xAD, ...).
LATIN_FALLBACK_ENCODING = "WinAnsiEncoding"

#: Cangjie identifier prefix per font (Courier-Bold -> COURIER_BOLD).
IDENT = {
    name: "".join(ch if ch.isalnum() else "_" for ch in name).upper()
    for name in BASE14
}

#: Adobe glyph names the downstream parser is expected to see even when no built-in
#: encoding of this package mentions them.  The AGL resolves nearly all of them; the
#: table exists so the required subset is guaranteed to be present.
MANUAL_GLYPHS = {
    "space": " ",
    "exclam": "!",
    "quotedbl": '"',
    "numbersign": "#",
    "dollar": "$",
    "percent": "%",
    "ampersand": "&",
    "quotesingle": "'",
    "parenleft": "(",
    "parenright": ")",
    "asterisk": "*",
    "plus": "+",
    "comma": ",",
    "hyphen": "-",
    "period": ".",
    "slash": "/",
    "colon": ":",
    "semicolon": ";",
    "less": "<",
    "equal": "=",
    "greater": ">",
    "question": "?",
    "at": "@",
    "bracketleft": "[",
    "backslash": "\\",
    "bracketright": "]",
    "asciicircum": "^",
    "underscore": "_",
    "grave": "`",
    "braceleft": "{",
    "bar": "|",
    "braceright": "}",
    "asciitilde": "~",
    "quoteleft": "\u2018",
    "quoteright": "\u2019",
    "quotedblleft": "\u201c",
    "quotedblright": "\u201d",
    "endash": "\u2013",
    "emdash": "\u2014",
    "bullet": "\u2022",
    "ellipsis": "\u2026",
    "fi": "\ufb01",
    "fl": "\ufb02",
    "ff": "\ufb00",
    "ffi": "\ufb03",
    "ffl": "\ufb04",
    "germandbls": "\u00df",
    "AE": "\u00c6",
    "ae": "\u00e6",
    "OE": "\u0152",
    "oe": "\u0153",
    "Oslash": "\u00d8",
    "oslash": "\u00f8",
    "Lslash": "\u0141",
    "lslash": "\u0142",
    "dotlessi": "\u0131",
    "circumflex": "\u02c6",
    "tilde": "\u02dc",
    "dieresis": "\u00a8",
    "acute": "\u00b4",
    "cedilla": "\u00b8",
    "ring": "\u02da",
    "macron": "\u00af",
    "breve": "\u02d8",
    "dotaccent": "\u02d9",
    "hungarumlaut": "\u02dd",
    "ogonek": "\u02db",
    "caron": "\u02c7",
    "fraction": "\u2044",
    "currency": "\u00a4",
    "sterling": "\u00a3",
    "yen": "\u00a5",
    "Euro": "\u20ac",
}

#: Codes reportlab leaves empty but that the PDF spec does define as themselves.
ADDED_CODES = {
    "PDFDocEncoding": {0x09: "\t", 0x0A: "\n", 0x0D: "\r"},
}

#: Validation gates; a mismatch means the data sources changed under us.
EXPECTED_WIDTHS = {
    ("Helvetica", "space"): 278,
    ("Helvetica", "a"): 556,
    ("Helvetica", "l"): 222,
    ("Helvetica", "p"): 556,
    ("Courier", "a"): 600,
    ("Courier", "M"): 600,
    ("Times-Roman", "a"): 444,
}


# ---------------------------------------------------------------------------
# data collection
# ---------------------------------------------------------------------------

def builtin_encoding(name: str) -> list[str]:
    """reportlab's 256-entry code -> glyph name table, "" for undefined codes."""
    raw = fontdata.encodings[name]
    assert len(raw) == 256, (name, len(raw))
    return [glyph or "" for glyph in raw]


def default_encoding_for(font: str) -> str:
    return DEFAULT_ENCODING.get(font, LATIN_DEFAULT_ENCODING)


def widths_for(font: str) -> list[int]:
    """256 advance widths (1/1000 em) indexed by character code."""
    table = fontdata.widthsByFontGlyph[font]
    primary_name = default_encoding_for(font)
    primary = builtin_encoding(primary_name)
    primary_defined = defined_codes(primary_name)
    fallback_name = (
        LATIN_FALLBACK_ENCODING if primary_name == LATIN_DEFAULT_ENCODING else None
    )
    fallback = builtin_encoding(fallback_name) if fallback_name else None
    fallback_defined = defined_codes(fallback_name) if fallback_name else set()
    widths: list[int] = []
    for code in range(256):
        if code < 0x20 or code == 0x7F:
            widths.append(0)
            continue
        width = 0
        if code in primary_defined:
            glyph = primary[code]
            if glyph and glyph in table:
                width = int(round(table[glyph]))
        if width == 0 and fallback is not None and code in fallback_defined:
            glyph = fallback[code]
            if glyph and glyph in table:
                width = int(round(table[glyph]))
        widths.append(width)
    return widths


def ascent_descent(font: str) -> tuple[float, float]:
    """Ascender/Descender as a fraction of 1 em, as pdfminer resolves them."""
    descriptor = FONT_METRICS[font][0]
    ascent = float(descriptor.get("Ascent", 0.0)) / 1000.0
    descent = float(descriptor.get("Descent", 0.0)) / 1000.0
    return ascent, descent


def _decode_tables() -> dict[str, str]:
    """glyph name -> unicode text, taken from the code tables of the two 8-bit
    encodings whose byte values are plain cp1252 / mac_roman code points."""
    out: dict[str, str] = {}
    for encoding, codec in (
        ("WinAnsiEncoding", "cp1252"),
        ("MacRomanEncoding", "mac_roman"),
    ):
        table = builtin_encoding(encoding)
        for code, glyph in enumerate(table):
            if not glyph or glyph in out:
                continue
            try:
                out[glyph] = bytes([code]).decode(codec)
            except UnicodeDecodeError:
                continue
    return out


def defined_codes(encoding: str) -> set[int]:
    """Codes the encoding really defines.

    reportlab fills the five undefined WinAnsi slots (0x81, 0x8D, 0x8F, 0x90,
    0x9D) with the "bullet" placeholder so that it is never undefined; those
    slots are undefined in the PDF spec, so drop them.  cp1252 marks exactly the
    same five bytes as undefined.
    """
    table = builtin_encoding(encoding)
    if encoding != "WinAnsiEncoding":
        return {code for code, glyph in enumerate(table) if glyph}
    valid: set[int] = set()
    for code, glyph in enumerate(table):
        if not glyph:
            continue
        try:
            bytes([code]).decode("cp1252")
        except UnicodeDecodeError:
            continue
        valid.add(code)
    return valid


def _agl(name: str) -> str | None:
    try:
        return name2unicode(name)
    except KeyError:
        return None


def glyph_to_unicode(name: str, decoded: dict[str, str]) -> str | None:
    """Resolve one Adobe glyph name to unicode text, or None when unknown."""
    if not name or name == ".notdef":
        return None
    base = name.split(".")[0]  # drop a1.sc / a.swash style suffixes
    if not base:
        return None
    if base in MANUAL_GLYPHS:
        return MANUAL_GLYPHS[base]
    value = _agl(base)
    if value is not None:
        return value
    if base in decoded:
        return decoded[base]
    return None


def glyph_names() -> list[str]:
    """Every glyph name the standard 14 fonts or the built-in encodings can use."""
    names: set[str] = set(MANUAL_GLYPHS)
    for encoding in fontdata.encodings.values():
        names.update(glyph for glyph in encoding if glyph)
    for font in BASE14:
        names.update(fontdata.widthsByFontGlyph[font])
    return sorted(names)


# ---------------------------------------------------------------------------
# Cangjie emission helpers
# ---------------------------------------------------------------------------

ESCAPES = {
    "\\": "\\\\",
    '"': '\\"',
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
    "\0": "\\0",
}


def cj_string(value: str) -> str:
    out = ['"']
    for char in value:
        if char in ESCAPES:
            out.append(ESCAPES[char])
        elif 0xE000 <= ord(char) <= 0xF8FF:
            # Private-use characters (the AGL maps pieces of the Symbol font to
            # them): keep them but escape, the compiler warns on raw PUA bytes.
            out.append("\\u{%04X}" % ord(char))
        elif ord(char) < 0x20 or ord(char) == 0x7F:
            raise ValueError(f"unescaped control character {ord(char):#x} in {value!r}")
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def cj_float(value: float) -> str:
    text = f"{value:.6f}".rstrip("0")
    if text.endswith("."):
        text += "0"
    return text


def emit_array(name: str, items: list[str], per_line: int, indent: str = "    ") -> str:
    """Emit `<indent>name = [ ... ]` with a fixed number of items per line.

    Cangjie rejects a trailing comma before ']', so the padding is stripped from
    the last element.
    """
    lines = [f"{indent}{name} = ["]
    for start in range(0, len(items), per_line):
        chunk = items[start : start + per_line]
        lines.append(f"{indent}    " + ", ".join(chunk) + ",")
    lines[-1] = lines[-1][:-1] if lines[-1].endswith(",") else lines[-1]
    lines.append(f"{indent}]")
    return "\n".join(lines)


HEADER = """\
// GENERATED FILE - DO NOT EDIT BY HAND.
// Regenerate with: python3 cangjie/scripts/gen_font_data.py
// Sources: reportlab.pdfbase._fontdata, pdfminer.fontmetrics, Adobe Glyph List 2.0.
"""


# ---------------------------------------------------------------------------
# metrics_data.cj
# ---------------------------------------------------------------------------

METRICS_HEADER = HEADER + """
package pdf4cj

import std.collection.*

/**
 * Metric data for one of the standard 14 PDF fonts.
 *
 * `widths` is indexed by character code (0..255) and holds advance widths in
 * 1/1000 em, so a glyph advance in text space is `widths[code] / 1000.0 * size`.
 * Codes the font's built-in encoding leaves undefined are 0, and codes below 32
 * are always 0.  `ascent`/`descent` are fractions of the em; a glyph drawn at
 * baseline `y` with font size `size` spans `y + descent * size` ..
 * `y + descent * size + size`, which is what pdfminer/pdfplumber use.
 *
 * Generation notes:
 * - widths come from the Adobe core AFM widths (reportlab `widthsByFontGlyph`),
 *   looked up through StandardEncoding first and WinAnsiEncoding for the codes
 *   StandardEncoding leaves undefined (0x80-0x9F, 0xA0, 0xAD);
 * - Symbol and ZapfDingbats use their own built-in encodings;
 * - ascent/descent are the pdfminer `FONT_METRICS` values, i.e. exactly what
 *   pdfminer uses for a base-14 font without a /FontDescriptor.  Courier is
 *   627/-194 there (the raw AFM says 629/-157), and Times variants all report
 *   the Times-Roman pair; pdfplumber output matches these numbers;
 * - Symbol and ZapfDingbats have no ascent/descent in pdfminer, hence 0.0.
 */
public class Base14Metrics {
    /** Canonical standard-14 name, e.g. "Helvetica-Bold". */
    public let fontName: String
    /** Always 32: the metrics table starts at the first printable code. */
    public let firstChar: Int64
    /** 256 advance widths in 1/1000 em, indexed by character code. */
    public let widths: Array<Int64>
    /** Ascender above the baseline in em units (may be 0.0 for Symbol). */
    public let ascent: Float64
    /** Descender below the baseline in em units, always <= 0.0. */
    public let descent: Float64

    public init(
        fontName: String,
        firstChar: Int64,
        widths: Array<Int64>,
        ascent: Float64,
        descent: Float64
    ) {
        this.fontName = fontName
        this.firstChar = firstChar
        this.widths = widths
        this.ascent = ascent
        this.descent = descent
    }

    /** Advance width of one character code in 1/1000 em; 0 when undefined. */
    public func width(code: Int64): Int64 {
        if (code < 0 || code > 255) {
            return 0
        }
        return widths[code]
    }

    /** Advance of a whole string of codes, in 1/1000 em. */
    public func stringWidth(codes: Array<Int64>): Int64 {
        var total = 0
        for (code in codes) {
            total += width(code)
        }
        return total
    }
}
"""


def render_metrics() -> str:
    parts = [METRICS_HEADER]

    for font in BASE14:
        widths = widths_for(font)
        parts.append("")
        parts.append(f"// {font}: {default_encoding_for(font)} widths")
        parts.append(
            emit_array(
                f"private let {IDENT[font]}_WIDTHS: Array<Int64>",
                [str(width) for width in widths],
                per_line=16,
                indent="",
            )
        )

    parts.append("")
    parts.append("private func buildBase14Metrics(): HashMap<String, Base14Metrics> {")
    parts.append("    let table = HashMap<String, Base14Metrics>()")
    for font in BASE14:
        ascent, descent = ascent_descent(font)
        parts.append(
            f'    table["{font}"] = Base14Metrics(\n'
            f'        "{font}",\n'
            f"        32,\n"
            f"        {IDENT[font]}_WIDTHS,\n"
            f"        {cj_float(ascent)},\n"
            f"        {cj_float(descent)}\n"
            f"    )"
        )
    parts.append("    return table")
    parts.append("}")
    parts.append("")
    parts.append("private let BASE_14_METRICS: HashMap<String, Base14Metrics> = buildBase14Metrics()")
    parts.append("""
/** Exact standard-14 name ("Helvetica-Bold") to its metrics; None when unknown. */
public func base14Metrics(name: String): Option<Base14Metrics> {
    return BASE_14_METRICS.get(name)
}
""".rstrip("\n"))

    parts.append("")
    parts.append(NORMALIZE_SOURCE)
    return "\n".join(parts) + "\n"


NORMALIZE_SOURCE = '''
/** True for names carrying a six-character subset tag, e.g. "ABCDEF+Helvetica". */
private func hasSubsetPrefix(name: String): Bool {
    let runes = name.toRuneArray()
    if (runes.size < 7 || runes[6] != r'+') {
        return false
    }
    for (index in 0..6) {
        let rune = runes[index]
        let upper = rune >= r'A' && rune <= r'Z'
        let lower = rune >= r'a' && rune <= r'z'
        if (!upper && !lower) {
            return false
        }
    }
    return true
}

/**
 * Map a common non-standard family name onto a standard-14 name.
 *
 * Arial and ArialMT become Helvetica, TimesNewRoman and Times become
 * Times-Roman, CourierNew becomes Courier, keeping the bold/italic style found in
 * the name: "Arial,BoldItalic", "Arial-BoldItalicMT" and "ArialBI" all become
 * "Helvetica-BoldOblique" (Helvetica has no separate italic face), while
 * "Arial,Bold" becomes "Helvetica-Bold".  Names that are already standard, and
 * names of no known family, are returned unchanged.  A name carrying a subset
 * prefix ("ABCDEF+Helvetica") is returned unchanged as well: removing that
 * prefix is the caller's job, not this function's.
 */
public func normalizeBase14Name(name: String): String {
    let trimmed = name.trimAscii()
    if (trimmed.isEmpty()) {
        return trimmed
    }
    if (BASE_14_METRICS.contains(trimmed) || hasSubsetPrefix(trimmed)) {
        return trimmed
    }
    let lower = trimmed.toAsciiLower()
    let bold = lower.contains("bold")
    let italic = lower.contains("italic") || lower.contains("oblique")
    var family = ""
    if (lower.contains("helvetica") || lower.contains("arial")) {
        family = "Helvetica"
    } else if (lower.contains("times")) {
        family = "Times"
    } else if (lower.contains("courier")) {
        family = "Courier"
    } else if (lower.contains("symbol")) {
        family = "Symbol"
    } else if (lower.contains("dingbat")) {
        family = "ZapfDingbats"
    } else {
        return trimmed
    }
    if (family == "Symbol") {
        return "Symbol"
    }
    if (family == "ZapfDingbats") {
        return "ZapfDingbats"
    }
    if (family == "Times") {
        if (bold && italic) {
            return "Times-BoldItalic"
        }
        if (bold) {
            return "Times-Bold"
        }
        if (italic) {
            return "Times-Italic"
        }
        return "Times-Roman"
    }
    if (bold && italic) {
        return family + "-BoldOblique"
    }
    if (bold) {
        return family + "-Bold"
    }
    if (italic) {
        return family + "-Oblique"
    }
    return family
}
'''.strip("\n")


# ---------------------------------------------------------------------------
# encoding_data.cj
# ---------------------------------------------------------------------------

ENCODING_HEADER = HEADER + """
package pdf4cj

import std.collection.*

/**
 * Built-in 8-bit encodings for simple PDF fonts.
 *
 * Every table has exactly 256 entries indexed by character code and holds the
 * unicode *text* for that code, so a byte string can be turned into text without
 * any further lookup.  Multi-character results only occur for ligature names
 * ("ffi"); undefined or non-mappable codes are "" so callers can skip them.
 *
 * Use these when a font has no /ToUnicode CMap: WinAnsi for /WinAnsiEncoding,
 * MacRoman for /MacRomanEncoding, Standard for the built-in encoding of the
 * Latin text fonts, PDFDoc for the strings of the document information
 * dictionary and for /PDFDocEncoding.  Symbol and ZapfDingbats glyph names have
 * no reliable unicode mapping, so only their widths are provided (in
 * metrics_data.cj).
 */
"""


def render_encoding() -> str:
    parts = [ENCODING_HEADER]

    tables = {
        "WIN_ANSI_ENCODING": "WinAnsiEncoding",
        "MAC_ROMAN_ENCODING": "MacRomanEncoding",
        "STANDARD_ENCODING": "StandardEncoding",
        "PDF_DOC_ENCODING": "PDFDocEncoding",
    }
    decoded = _decode_tables()
    stats: dict[str, list[str]] = {}
    for constant, encoding in tables.items():
        names = builtin_encoding(encoding)
        defined = defined_codes(encoding)
        extras = ADDED_CODES.get(encoding, {})
        texts: list[str] = []
        unmapped: list[str] = []
        for code, glyph in enumerate(names):
            if code < 0x20 or code == 0x7F:
                # Control range: only PDFDocEncoding defines codes here.
                texts.append(extras.get(code, ""))
                continue
            if not glyph or code not in defined:
                texts.append(extras.get(code, ""))
                continue
            text = glyph_to_unicode(glyph, decoded)
            if text is None:
                texts.append("")
                unmapped.append(glyph)
            else:
                texts.append(text)
        stats[encoding] = unmapped
        parts.append(f"// {encoding}")
        parts.append(
            emit_array(
                f"public let {constant}: Array<String>",
                [cj_string(text) for text in texts],
                per_line=8,
                indent="",
            )
        )
        parts.append("")

    names = glyph_names()
    resolved: dict[str, str] = {}
    unresolved: list[str] = []
    for name in names:
        text = glyph_to_unicode(name, decoded)
        if text is None:
            unresolved.append(name)
        else:
            resolved[name] = text

    parts.append(
        "// Adobe glyph name -> unicode text, sorted by glyph name.  "
        f"{len(resolved)} names, {len(unresolved)} unresolved."
    )
    if unresolved:
        preview = ", ".join(unresolved[:40])
        parts.append(f"// unresolved: {preview}{' ...' if len(unresolved) > 40 else ''}")
    parts.append(
        emit_array(
            "private let GLYPH_UNICODE_NAMES: Array<String>",
            [cj_string(name) for name in sorted(resolved)],
            per_line=6,
            indent="",
        )
    )
    parts.append("")
    parts.append(
        emit_array(
            "private let GLYPH_UNICODE_TEXTS: Array<String>",
            [cj_string(resolved[name]) for name in sorted(resolved)],
            per_line=6,
            indent="",
        )
    )
    parts.append("")

    parts.append(ENCODING_TAIL)
    return "\n".join(parts) + "\n"


ENCODING_TAIL = '''
private func buildGlyphUnicodeMap(): HashMap<String, String> {
    let table = HashMap<String, String>()
    for (index in 0..GLYPH_UNICODE_NAMES.size) {
        table[GLYPH_UNICODE_NAMES[index]] = GLYPH_UNICODE_TEXTS[index]
    }
    return table
}

private let GLYPH_UNICODE_TABLE: HashMap<String, String> = buildGlyphUnicodeMap()

/** Cut an Adobe glyph name at its first '.', e.g. "a.sc" -> "a". */
private func glyphNameBase(name: String): String {
    let runes = name.toRuneArray()
    for (index in 0..runes.size) {
        if (runes[index] == r'.') {
            return String(runes[0..index])
        }
    }
    return name
}

private func glyphHexValue(value: UInt8): Int64 {
    if (value >= 48 && value <= 57) {
        return Int64(value - 48)
    }
    if (value >= 65 && value <= 70) {
        return Int64(value - 65) + 10
    }
    if (value >= 97 && value <= 102) {
        return Int64(value - 97) + 10
    }
    return -1
}

/** Decode "uni0041" / "uni00410042" / "u0041" style names; None when malformed. */
private func glyphUnicodeFromHexName(name: String): Option<String> {
    var offset = 0
    var groupSize = 4
    if (name.startsWith("uni")) {
        offset = 3
    } else if (name.startsWith("u")) {
        offset = 1
        groupSize = -1
    } else {
        return None
    }
    let digits = name.toArray()
    let length = digits.size - offset
    if (length <= 0) {
        return None
    }
    for (index in offset..digits.size) {
        if (glyphHexValue(digits[index]) < 0) {
            return None
        }
    }
    if (groupSize > 0 && length % groupSize != 0) {
        return None
    }
    let group = if (groupSize > 0) { groupSize } else { length }
    if (group != 4 && group != 5 && group != 6) {
        return None
    }
    let runes = ArrayList<Rune>()
    var position = offset
    while (position < digits.size) {
        var value = 0
        for (index in position..(position + group)) {
            value = value * 16 + glyphHexValue(digits[index])
        }
        if (value == 0 || (value >= 0xD800 && value <= 0xDFFF)) {
            return None
        }
        runes.add(Rune(value))
        position += group
    }
    return Some(String(runes.toArray()))
}

/**
 * Adobe glyph name to unicode text; None for unknown names and for ".notdef".
 *
 * Handles the full Adobe Glyph List, ".suffix" variants ("alpha.sc" -> "alpha"),
 * component names joined with '_' ("f_f_i" -> "ffi") and the "uniXXXX" /
 * "uXXXX" hex forms that subset fonts use.
 */
public func glyphNameToUnicode(name: String): Option<String> {
    if (name.isEmpty() || name == ".notdef") {
        return None
    }
    match (GLYPH_UNICODE_TABLE.get(name)) {
        case Some(text) => return Some(text)
        case None => ()
    }
    let base = glyphNameBase(name)
    if (base != name) {
        return glyphNameToUnicode(base)
    }
    if (name.contains("_")) {
        let builder = StringBuilder()
        for (part in name.split("_")) {
            match (glyphNameToUnicode(part)) {
                case Some(text) => builder.append(text)
                case None => return None
            }
        }
        return Some(builder.toString())
    }
    return glyphUnicodeFromHexName(name)
}
'''.strip("\n")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def validate() -> None:
    for (font, glyph), expected in EXPECTED_WIDTHS.items():
        table = fontdata.widthsByFontGlyph[font]
        actual = int(round(table[glyph]))
        if actual != expected:
            raise SystemExit(
                f"width check failed for {font}/{glyph}: {actual} != {expected}"
            )


def main() -> None:
    validate()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    metrics = render_metrics()
    encoding = render_encoding()
    METRICS_PATH.write_text(metrics, encoding="utf-8", newline="\n")
    ENCODING_PATH.write_text(encoding, encoding="utf-8", newline="\n")

    helvetica = dict(zip(
        builtin_encoding(default_encoding_for("Helvetica")),
        widths_for("Helvetica"),
    ))
    ascent, descent = ascent_descent("Helvetica")

    # The generated files live outside this repository (../pdf4cj/src), so make
    # the printed paths relative to the repo root explicitly.
    print(f"wrote {os.path.relpath(METRICS_PATH, REPO_ROOT)} "
          f"({len(metrics.splitlines())} lines, {len(metrics.encode()):,} bytes)")
    print(f"wrote {os.path.relpath(ENCODING_PATH, REPO_ROOT)} "
          f"({len(encoding.splitlines())} lines, {len(encoding.encode()):,} bytes)")
    print(f"fonts: {len(BASE14)}")
    defined = {
        encoding: len(defined_codes(encoding))
        for encoding in (
            "WinAnsiEncoding",
            "MacRomanEncoding",
            "StandardEncoding",
            "PDFDocEncoding",
        )
    }
    print("encodings: 4 x 256 entries "
          + ", ".join(f"{name.split('Encoding')[0]} {count} defined"
                      for name, count in defined.items()))
    print(f"helvetica widths: space={helvetica['space']} a={helvetica['a']} "
          f"l={helvetica['l']} p={helvetica['p']} "
          f"ascent={ascent:.3f} descent={descent:.3f}")
    decoded = _decode_tables()
    resolved = [n for n in glyph_names() if glyph_to_unicode(n, decoded) is not None]
    unresolved = [n for n in glyph_names() if glyph_to_unicode(n, decoded) is None]
    print(f"glyph names: {len(resolved)} mapped, {len(unresolved)} unmapped")
    if unresolved:
        shown = " ".join(unresolved[:16])
        print(f"unmapped glyph names: {shown}"
              + (f" ... ({len(unresolved)} total)" if len(unresolved) > 16 else ""))


if __name__ == "__main__":
    main()
