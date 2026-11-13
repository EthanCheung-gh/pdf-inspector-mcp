package pdf4cj.test

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import pdf4cj.*

// The font loader only needs reference resolution and stream decoding, so the
// tests build synthetic /Font dictionaries and pass an identity resolver plus a
// "raw bytes are the data" stream decoder. `loadFont(doc, dict)` is a thin
// wrapper over the same code path.

func fontFromDict(dict: HashMap<String, PdfValue>): PdfFont {
    loadFontFromDict(dict, { value: PdfValue => value }, { stream: PdfStream => stream.raw })
}

func fontEmptyDict(): HashMap<String, PdfValue> {
    HashMap<String, PdfValue>()
}

func fontNearly(left: Float64, right: Float64): Bool {
    let diff = left - right
    if (diff < 0.0) {
        return -diff < 0.0001
    }
    diff < 0.0001
}

func fontSingleByte(value: UInt8): Array<UInt8> {
    let bytes = Array<UInt8>(1, repeat: 0)
    bytes[0] = value
    bytes
}

func fontHexBytes(values: Array<Int64>): Array<UInt8> {
    let bytes = Array<UInt8>(values.size, repeat: 0)
    var i: Int64 = 0
    while (i < values.size) {
        bytes[i] = UInt8(values[i])
        i += 1
    }
    bytes
}

func fontNumberList(values: Array<Int64>): ArrayList<PdfValue> {
    let items = ArrayList<PdfValue>()
    for (value in values) {
        items.add(PdfInt(value))
    }
    items
}

// ---------------------------------------------------------------------------
// Simple fonts

@Test
class SimpleFontTests {
    @TestCase
    func helveticaWithoutWidths(): Unit {
        let dict = fontEmptyDict()
        dict.add("Type", PdfName("Font"))
        dict.add("Subtype", PdfName("Type1"))
        dict.add("BaseFont", PdfName("Helvetica"))
        let font = fontFromDict(dict)

        @Expect(font.name, "Helvetica")
        @Expect(font.isCid, false)
        @Expect(font.width(0x61), 556.0)
        @Expect(font.width(0x7A), 500.0)
        @Assert(fontNearly(font.ascent, 0.718))
        @Assert(fontNearly(font.descent, -0.207))

        let word = "alphaword".toArray()
        @Expect(font.codeLength(word, 0), 1)
        let first = font.decode(word, 0)
        @Expect(first[0], 97)
        @Expect(first[1], "a")

        var index: Int64 = 0
        var text = ""
        while (index < word.size) {
            let decoded = font.decode(word, index)
            text += decoded[1]
            index += font.codeLength(word, index)
        }
        @Expect(text, "alphaword")
    }

    @TestCase
    func widthsOverrideBase14(): Unit {
        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type1"))
        dict.add("BaseFont", PdfName("Helvetica"))
        dict.add("FirstChar", PdfInt(65))
        dict.add("Widths", PdfArray(fontNumberList([700, 600])))
        let font = fontFromDict(dict)

        @Expect(font.width(65), 700.0)
        @Expect(font.width(66), 600.0)
        // Outside /Widths with no /MissingWidth: standard-14 metric of 'z'.
        @Expect(font.width(0x7A), 500.0)
    }

    @TestCase
    func missingWidthIsUsedOutsideWidths(): Unit {
        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type1"))
        dict.add("BaseFont", PdfName("Helvetica"))
        dict.add("FirstChar", PdfInt(65))
        dict.add("Widths", PdfArray(fontNumberList([700])))
        let descriptor = fontEmptyDict()
        descriptor.add("Type", PdfName("FontDescriptor"))
        descriptor.add("MissingWidth", PdfInt(333))
        descriptor.add("Ascent", PdfInt(700))
        descriptor.add("Descent", PdfInt(200))
        dict.add("FontDescriptor", PdfDict(descriptor))
        let font = fontFromDict(dict)

        @Expect(font.width(0x41), 700.0)
        @Expect(font.width(0x42), 333.0)
        // /Descent is positive in this file; it must still land negative.
        @Assert(fontNearly(font.ascent, 0.7))
        @Assert(fontNearly(font.descent, -0.2))
    }

    @TestCase
    func winAnsiEncoding(): Unit {
        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type1"))
        dict.add("BaseFont", PdfName("Helvetica"))
        dict.add("Encoding", PdfName("WinAnsiEncoding"))
        let font = fontFromDict(dict)

        let decoded = font.decode(fontSingleByte(0xE9), 0)
        @Expect(decoded[0], 233)
        @Expect(decoded[1], "é")
    }

    @TestCase
    func differencesEncoding(): Unit {
        let differences = ArrayList<PdfValue>()
        differences.add(PdfInt(65))
        differences.add(PdfName("eacute"))
        differences.add(PdfInt(66))
        differences.add(PdfName("space"))
        let encoding = fontEmptyDict()
        encoding.add("Type", PdfName("Encoding"))
        encoding.add("Differences", PdfArray(differences))

        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type1"))
        dict.add("BaseFont", PdfName("Helvetica"))
        dict.add("Encoding", PdfDict(encoding))
        let font = fontFromDict(dict)

        @Expect(font.decode(fontHexBytes([65]), 0)[1], "é")
        @Expect(font.decode(fontHexBytes([66]), 0)[1], " ")
        // Code 67 is untouched by /Differences, so the base (Standard) wins.
        @Expect(font.decode(fontHexBytes([67]), 0)[1], "C")
    }

    @TestCase
    func differencesOverBaseEncoding(): Unit {
        let differences = ArrayList<PdfValue>()
        differences.add(PdfInt(0xE9))
        differences.add(PdfName("alpha"))
        let encoding = fontEmptyDict()
        encoding.add("BaseEncoding", PdfName("WinAnsiEncoding"))
        encoding.add("Differences", PdfArray(differences))

        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type1"))
        dict.add("BaseFont", PdfName("Helvetica"))
        dict.add("Encoding", PdfDict(encoding))
        let font = fontFromDict(dict)

        @Expect(font.decode(fontHexBytes([0xE9]), 0)[1], "α")
        // Still WinAnsi away from the /Differences entry.
        @Expect(font.decode(fontHexBytes([0xE8]), 0)[1], "è")
    }

    @TestCase
    func toUnicodeWinsOverEncoding(): Unit {
        let cmapText = """
            1 begincodespacerange
            <00> <FF>
            endcodespacerange
            1 beginbfchar
            <41> <00E9>
            endbfchar
            """
        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type1"))
        dict.add("BaseFont", PdfName("Helvetica"))
        dict.add("Encoding", PdfName("WinAnsiEncoding"))
        dict.add("ToUnicode", PdfValue.PdfStream(PdfStream(fontEmptyDict(), cmapText.toArray())))
        let font = fontFromDict(dict)

        @Assert(font.hasToUnicode)
        // 0x41 is mapped by /ToUnicode, not by the encoding table.
        @Expect(font.decode(fontHexBytes([0x41]), 0)[1], "é")
        // Unmapped: the encoding table is still the fallback.
        @Expect(font.decode(fontHexBytes([0x61]), 0)[1], "a")
    }

    @TestCase
    func subsetPrefixKeepsName(): Unit {
        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type1"))
        dict.add("BaseFont", PdfName("ABCDEF+Helvetica"))
        let font = fontFromDict(dict)

        @Expect(font.name, "ABCDEF+Helvetica")
        @Expect(font.width(0x61), 556.0)
        @Assert(fontNearly(font.ascent, 0.718))
    }

    @TestCase
    func type3FontMatrixScalesWidths(): Unit {
        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type3"))
        dict.add("BaseFont", PdfName("F3"))
        dict.add("FirstChar", PdfInt(65))
        dict.add("Widths", PdfArray(fontNumberList([50])))
        let matrix: ArrayList<PdfValue> = ArrayList<PdfValue>()
        matrix.add(PdfReal(0.01))
        matrix.add(PdfReal(0.0))
        matrix.add(PdfReal(0.0))
        matrix.add(PdfReal(0.01))
        matrix.add(PdfReal(0.0))
        matrix.add(PdfReal(0.0))
        dict.add("FontMatrix", PdfArray(matrix))
        let font = fontFromDict(dict)

        // 50 glyph units * (0.01 * 1000) = 500/1000 em.
        @Expect(font.width(65), 500.0)
    }

    @TestCase
    func notAFontDictionaryThrows(): Unit {
        var failed = false
        try {
            fontFromDict(fontEmptyDict())
        } catch (e: PdfError) {
            failed = true
        }
        @Assert(failed)
    }

    @TestCase
    func unnamedFontFallsBack(): Unit {
        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type1"))
        let font = fontFromDict(dict)
        @Expect(font.name, "unknown")
        @Assert(fontNearly(font.ascent, 0.8))
        @Assert(fontNearly(font.descent, -0.2))
        @Expect(font.width(0x41), 0.0)
    }
}

// ---------------------------------------------------------------------------
// Composite (Type0) fonts

func fontType0Dict(descendant: HashMap<String, PdfValue>): HashMap<String, PdfValue> {
    let dict = fontEmptyDict()
    dict.add("Type", PdfName("Font"))
    dict.add("Subtype", PdfName("Type0"))
    dict.add("BaseFont", PdfName("TestCID"))
    dict.add("Encoding", PdfName("Identity-H"))
    let descendants = ArrayList<PdfValue>()
    descendants.add(PdfDict(descendant))
    dict.add("DescendantFonts", PdfArray(descendants))
    dict
}

@Test
class CompositeFontTests {
    @TestCase
    func identityWithToUnicode(): Unit {
        let descendant = fontEmptyDict()
        descendant.add("Type", PdfName("Font"))
        descendant.add("Subtype", PdfName("CIDFontType2"))
        descendant.add("BaseFont", PdfName("TestCID"))
        descendant.add("DW", PdfInt(1000))
        let widths = ArrayList<PdfValue>()
        widths.add(PdfInt(1))
        widths.add(PdfArray(fontNumberList([500, 600])))
        widths.add(PdfInt(10))
        widths.add(PdfInt(12))
        widths.add(PdfInt(750))
        descendant.add("W", PdfArray(widths))

        let dict = fontType0Dict(descendant)
        let cmapText = """
            begincmap
            1 begincodespacerange
            <0000> <FFFF>
            endcodespacerange
            1 beginbfchar
            <0001> <0041>
            endbfchar
            1 beginbfrange
            <0002> <0004> <0061>
            endbfrange
            endcmap
            """
        dict.add("ToUnicode", PdfValue.PdfStream(PdfStream(fontEmptyDict(), cmapText.toArray())))
        let font = fontFromDict(dict)

        @Expect(font.isCid, true)
        @Expect(font.name, "TestCID")
        let bytes = fontHexBytes([0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04])
        @Expect(font.codeLength(bytes, 0), 2)
        @Expect(font.codeLength(bytes, 6), 2)

        let first = font.decode(bytes, 0)
        @Expect(first[0], 1)
        @Expect(first[1], "A")
        @Expect(font.decode(bytes, 2)[1], "a")
        @Expect(font.decode(bytes, 4)[1], "b")
        @Expect(font.decode(bytes, 6)[1], "c")

        // /W: `1 [500 600]` then `10 12 750`, /DW 1000.
        @Expect(font.width(1), 500.0)
        @Expect(font.width(2), 600.0)
        @Expect(font.width(11), 750.0)
        @Expect(font.width(99), 1000.0)
    }

    @TestCase
    func withoutToUnicodeTextIsEmpty(): Unit {
        let descendant = fontEmptyDict()
        descendant.add("Subtype", PdfName("CIDFontType2"))
        let dict = fontType0Dict(descendant)
        let font = fontFromDict(dict)

        let bytes = fontHexBytes([0x00, 0x01])
        @Expect(font.codeLength(bytes, 0), 2)
        let decoded = font.decode(bytes, 0)
        @Expect(decoded[0], 1)
        @Expect(decoded[1], "")
        // No /W at all: every CID advances by /DW (1000).
        @Expect(font.width(1), 1000.0)
    }

    @TestCase
    func descriptorMetrics(): Unit {
        let descriptor = fontEmptyDict()
        descriptor.add("Type", PdfName("FontDescriptor"))
        descriptor.add("Ascent", PdfInt(850))
        descriptor.add("Descent", PdfInt(-250))
        let descendant = fontEmptyDict()
        descendant.add("Subtype", PdfName("CIDFontType2"))
        descendant.add("FontDescriptor", PdfDict(descriptor))
        let font = fontFromDict(fontType0Dict(descendant))

        @Assert(fontNearly(font.ascent, 0.85))
        @Assert(fontNearly(font.descent, -0.25))
    }

    @TestCase
    func fontBBoxFallback(): Unit {
        let descendant = fontEmptyDict()
        descendant.add("Subtype", PdfName("CIDFontType2"))
        descendant.add("FontBBox", PdfArray(fontNumberList([-200, -300, 1000, 900])))
        let font = fontFromDict(fontType0Dict(descendant))

        @Assert(fontNearly(font.ascent, 0.9))
        @Assert(fontNearly(font.descent, -0.3))
    }

    @TestCase
    func cmapCodeSpaceDrivesCodeLength(): Unit {
        let descendant = fontEmptyDict()
        descendant.add("Subtype", PdfName("CIDFontType2"))
        descendant.add("DW", PdfInt(1000))
        let widths = ArrayList<PdfValue>()
        widths.add(PdfInt(6))
        widths.add(PdfInt(6))
        widths.add(PdfInt(555))
        descendant.add("W", PdfArray(widths))
        let cmapText = """
            1 begincodespacerange
            <00> <80>
            endcodespacerange
            1 begincodespacerange
            <8140> <9FFC>
            endcodespacerange
            2 begincidchar
            <20> 5
            <8140> 6
            endcidchar
            1 beginbfchar
            <8140> <3042>
            endbfchar
            """
        let dict = fontType0Dict(descendant)
        dict.add("Encoding", PdfValue.PdfStream(PdfStream(fontEmptyDict(), cmapText.toArray())))
        let font = fontFromDict(dict)

        let bytes = fontHexBytes([0x20, 0x81, 0x40])
        @Expect(font.codeLength(bytes, 0), 1)
        @Expect(font.codeLength(bytes, 1), 2)
        let single = font.decode(bytes, 0)
        @Expect(single[0], 0x20)
        @Expect(single[1], "")
        let double = font.decode(bytes, 1)
        @Expect(double[0], 0x8140)
        @Expect(double[1], "あ")
        // 0x8140 maps to CID 6 through begincidchar, and CID 6 is 555 wide.
        @Expect(font.width(0x8140), 555.0)
        // CID 5 has no /W entry, so /DW applies.
        @Expect(font.width(0x20), 1000.0)
    }
}

// ---------------------------------------------------------------------------
// Boundaries and CMap primitives

@Test
class FontBoundaryTests {
    @TestCase
    func outOfRangeOffsets(): Unit {
        let dict = fontEmptyDict()
        dict.add("Subtype", PdfName("Type1"))
        dict.add("BaseFont", PdfName("Helvetica"))
        let font = fontFromDict(dict)

        let empty = Array<UInt8>(0, repeat: 0)
        @Expect(font.decode(empty, 0)[1], "")
        @Expect(font.decode(empty, 0)[0], 0)
        @Expect(font.decode(empty, -3)[1], "")
        @Expect(font.codeLength(empty, 0), 1)

        let one = fontSingleByte(0x41)
        @Expect(font.decode(one, 5)[1], "")
        @Expect(font.decode(one, -1)[0], 0)
    }

    @TestCase
    func type0OutOfRangeOffsets(): Unit {
        let descendant = fontEmptyDict()
        descendant.add("Subtype", PdfName("CIDFontType2"))
        let font = fontFromDict(fontType0Dict(descendant))

        let empty = Array<UInt8>(0, repeat: 0)
        @Expect(font.decode(empty, 0)[1], "")
        @Expect(font.codeLength(empty, 0), 2)
        // A single trailing byte cannot complete a two-byte code.
        let half = fontHexBytes([0x00])
        @Expect(font.codeLength(half, 0), 2)
        @Expect(font.decode(half, 0)[0], 0)
    }

    @TestCase
    func utf16beDecoding(): Unit {
        @Expect(utf16beToString(fontHexBytes([0x00, 0x41])), "A")
        // U+3042 HIRAGANA LETTER A
        @Expect(utf16beToString(fontHexBytes([0x30, 0x42])), "あ")
        // U+1F600 through a surrogate pair.
        @Expect(utf16beToString(fontHexBytes([0xD8, 0x3D, 0xDE, 0x00])), "😀")
        // Lone high surrogate becomes U+FFFD.
        @Expect(utf16beToString(fontHexBytes([0xD8, 0x3D])), "\u{FFFD}")
        // Empty payload stays empty.
        @Expect(utf16beToString(Array<UInt8>(0, repeat: 0)), "")
    }

    @TestCase
    func bfrangeArrayForm(): Unit {
        let cmapText = """
            % comment line
            2 beginbfchar
            <01> <0041>
            <02> <0042>
            endbfchar
            1 beginbfrange
            <10> <12> [<0061> <0062> <0063>]
            endbfrange
            endcmap
            """
        let cmap = parseToUnicode(cmapText.toArray())
        @Expect(cmap.lookup(1).getOrThrow(), "A")
        @Expect(cmap.lookup(2).getOrThrow(), "B")
        @Expect(cmap.lookup(0x10).getOrThrow(), "a")
        @Expect(cmap.lookup(0x11).getOrThrow(), "b")
        @Expect(cmap.lookup(0x12).getOrThrow(), "c")
        // No codespace section: the length is the caller's business.
        @Expect(cmap.hasCodespaces, false)
        @Expect(cmap.codeByteLength(fontHexBytes([0x01]), 0), 0)
        @Expect(cmap.defaultByteLength(), 0)
    }

    @TestCase
    func bfrangeSurrogateDestination(): Unit {
        let cmapText = """
            1 beginbfrange
            <01> <02> <D83DDE00>
            endbfrange
            """
        let cmap = parseToUnicode(cmapText.toArray())
        @Expect(cmap.lookup(1).getOrThrow(), "😀")
        // The code point increments, so the second entry is U+1F601.
        @Expect(cmap.lookup(2).getOrThrow(), "😁")
    }

    @TestCase
    func unterminatedCmapThrows(): Unit {
        var failed = false
        try {
            parseToUnicode("<0001> <0041".toArray())
        } catch (e: PdfError) {
            failed = true
        }
        @Assert(failed)
    }
}
