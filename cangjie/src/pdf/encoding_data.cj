// GENERATED FILE - DO NOT EDIT BY HAND.
// Regenerate with: python3 cangjie/scripts/gen_font_data.py
// Sources: reportlab.pdfbase._fontdata, pdfminer.fontmetrics, Adobe Glyph List 2.0.

package pdf_inspector_mcp.pdf

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

// WinAnsiEncoding
public let WIN_ANSI_ENCODING: Array<String> = [
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    " ", "!", "\"", "#", "$", "%", "&", "'",
    "(", ")", "*", "+", ",", "-", ".", "/",
    "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", ":", ";", "<", "=", ">", "?",
    "@", "A", "B", "C", "D", "E", "F", "G",
    "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W",
    "X", "Y", "Z", "[", "\\", "]", "^", "_",
    "`", "a", "b", "c", "d", "e", "f", "g",
    "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w",
    "x", "y", "z", "{", "|", "}", "~", "",
    "€", "", "‚", "ƒ", "„", "…", "†", "‡",
    "ˆ", "‰", "Š", "‹", "Œ", "", "Ž", "",
    "", "‘", "’", "“", "”", "•", "–", "—",
    "˜", "™", "š", "›", "œ", "", "ž", "Ÿ",
    " ", "¡", "¢", "£", "¤", "¥", "¦", "§",
    "¨", "©", "ª", "«", "¬", "-", "®", "¯",
    "°", "±", "²", "³", "´", "µ", "¶", "·",
    "¸", "¹", "º", "»", "¼", "½", "¾", "¿",
    "À", "Á", "Â", "Ã", "Ä", "Å", "Æ", "Ç",
    "È", "É", "Ê", "Ë", "Ì", "Í", "Î", "Ï",
    "Ð", "Ñ", "Ò", "Ó", "Ô", "Õ", "Ö", "×",
    "Ø", "Ù", "Ú", "Û", "Ü", "Ý", "Þ", "ß",
    "à", "á", "â", "ã", "ä", "å", "æ", "ç",
    "è", "é", "ê", "ë", "ì", "í", "î", "ï",
    "ð", "ñ", "ò", "ó", "ô", "õ", "ö", "÷",
    "ø", "ù", "ú", "û", "ü", "ý", "þ", "ÿ"
]

// MacRomanEncoding
public let MAC_ROMAN_ENCODING: Array<String> = [
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    " ", "!", "\"", "#", "$", "%", "&", "'",
    "(", ")", "*", "+", ",", "-", ".", "/",
    "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", ":", ";", "<", "=", ">", "?",
    "@", "A", "B", "C", "D", "E", "F", "G",
    "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W",
    "X", "Y", "Z", "[", "\\", "]", "^", "_",
    "`", "a", "b", "c", "d", "e", "f", "g",
    "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w",
    "x", "y", "z", "{", "|", "}", "~", "",
    "Ä", "Å", "Ç", "É", "Ñ", "Ö", "Ü", "á",
    "à", "â", "ä", "ã", "å", "ç", "é", "è",
    "ê", "ë", "í", "ì", "î", "ï", "ñ", "ó",
    "ò", "ô", "ö", "õ", "ú", "ù", "û", "ü",
    "†", "°", "¢", "£", "§", "•", "¶", "ß",
    "®", "©", "™", "´", "¨", "", "Æ", "Ø",
    "", "±", "", "", "¥", "µ", "", "",
    "", "", "", "ª", "º", "", "æ", "ø",
    "¿", "¡", "¬", "", "ƒ", "", "", "«",
    "»", "…", " ", "À", "Ã", "Õ", "Œ", "œ",
    "–", "—", "“", "”", "‘", "’", "÷", "",
    "ÿ", "Ÿ", "⁄", "¤", "‹", "›", "ﬁ", "ﬂ",
    "‡", "·", "‚", "„", "‰", "Â", "Ê", "Á",
    "Ë", "È", "Í", "Î", "Ï", "Ì", "Ó", "Ô",
    "", "Ò", "Ú", "Û", "Ù", "ı", "ˆ", "˜",
    "¯", "˘", "˙", "˚", "¸", "˝", "˛", "ˇ"
]

// StandardEncoding
public let STANDARD_ENCODING: Array<String> = [
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    " ", "!", "\"", "#", "$", "%", "&", "’",
    "(", ")", "*", "+", ",", "-", ".", "/",
    "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", ":", ";", "<", "=", ">", "?",
    "@", "A", "B", "C", "D", "E", "F", "G",
    "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W",
    "X", "Y", "Z", "[", "\\", "]", "^", "_",
    "‘", "a", "b", "c", "d", "e", "f", "g",
    "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w",
    "x", "y", "z", "{", "|", "}", "~", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "¡", "¢", "£", "⁄", "¥", "ƒ", "§",
    "¤", "'", "“", "«", "‹", "›", "ﬁ", "ﬂ",
    "", "–", "†", "‡", "·", "", "¶", "•",
    "‚", "„", "”", "»", "…", "‰", "", "¿",
    "", "`", "´", "ˆ", "˜", "¯", "˘", "˙",
    "¨", "", "˚", "¸", "", "˝", "˛", "ˇ",
    "—", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    "", "Æ", "", "ª", "", "", "", "",
    "Ł", "Ø", "Œ", "º", "", "", "", "",
    "", "æ", "", "", "", "ı", "", "",
    "ł", "ø", "œ", "ß", "", "", "", ""
]

// PDFDocEncoding
public let PDF_DOC_ENCODING: Array<String> = [
    "", "", "", "", "", "", "", "",
    "", "\t", "\n", "", "", "\r", "", "",
    "", "", "", "", "", "", "", "",
    "", "", "", "", "", "", "", "",
    " ", "!", "\"", "#", "$", "%", "&", "'",
    "(", ")", "*", "+", ",", "-", ".", "/",
    "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", ":", ";", "<", "=", ">", "?",
    "@", "A", "B", "C", "D", "E", "F", "G",
    "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W",
    "X", "Y", "Z", "[", "\\", "]", "^", "_",
    "`", "a", "b", "c", "d", "e", "f", "g",
    "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w",
    "x", "y", "z", "{", "|", "}", "~", "",
    "•", "†", "‡", "…", "—", "–", "ƒ", "⁄",
    "‹", "›", "−", "‰", "„", "“", "”", "‘",
    "’", "‚", "™", "ﬁ", "ﬂ", "Ł", "Œ", "Š",
    "Ÿ", "Ž", "ı", "ł", "œ", "š", "ž", "",
    "€", "¡", "¢", "£", "¤", "¥", "¦", "§",
    "¨", "©", "ª", "«", "¬", "", "®", "¯",
    "°", "±", "²", "³", "´", "µ", "¶", "·",
    "¸", "¹", "º", "»", "¼", "½", "¾", "¿",
    "À", "Á", "Â", "Ã", "Ä", "Å", "Æ", "Ç",
    "È", "É", "Ê", "Ë", "Ì", "Í", "Î", "Ï",
    "Ð", "Ñ", "Ò", "Ó", "Ô", "Õ", "Ö", "×",
    "Ø", "Ù", "Ú", "Û", "Ü", "Ý", "Þ", "ß",
    "à", "á", "â", "ã", "ä", "å", "æ", "ç",
    "è", "é", "ê", "ë", "ì", "í", "î", "ï",
    "ð", "ñ", "ò", "ó", "ô", "õ", "ö", "÷",
    "ø", "ù", "ú", "û", "ü", "ý", "þ", "ÿ"
]

// Adobe glyph name -> unicode text, sorted by glyph name.  524 names, 201 unresolved.
// unresolved: a1, a10, a100, a101, a102, a103, a104, a105, a106, a107, a108, a109, a11, a110, a111, a112, a117, a118, a119, a12, a120, a121, a122, a123, a124, a125, a126, a127, a128, a129, a13, a130, a131, a132, a133, a134, a135, a136, a137, a138 ...
private let GLYPH_UNICODE_NAMES: Array<String> = [
    "A", "AE", "AEsmall", "Aacute", "Aacutesmall", "Acircumflex",
    "Acircumflexsmall", "Acutesmall", "Adieresis", "Adieresissmall", "Agrave", "Agravesmall",
    "Alpha", "Aring", "Aringsmall", "Asmall", "Atilde", "Atildesmall",
    "B", "Beta", "Brevesmall", "Bsmall", "C", "Caronsmall",
    "Ccedilla", "Ccedillasmall", "Cedillasmall", "Chi", "Circumflexsmall", "Csmall",
    "D", "Delta", "Dieresissmall", "Dotaccentsmall", "Dsmall", "E",
    "Eacute", "Eacutesmall", "Ecircumflex", "Ecircumflexsmall", "Edieresis", "Edieresissmall",
    "Egrave", "Egravesmall", "Epsilon", "Esmall", "Eta", "Eth",
    "Ethsmall", "Euro", "F", "Fsmall", "G", "Gamma",
    "Gravesmall", "Gsmall", "H", "Hsmall", "Hungarumlautsmall", "I",
    "Iacute", "Iacutesmall", "Icircumflex", "Icircumflexsmall", "Idieresis", "Idieresissmall",
    "Ifraktur", "Igrave", "Igravesmall", "Iota", "Ismall", "J",
    "Jsmall", "K", "Kappa", "Ksmall", "L", "Lambda",
    "Lslash", "Lslashsmall", "Lsmall", "M", "Macronsmall", "Msmall",
    "Mu", "N", "Nsmall", "Ntilde", "Ntildesmall", "Nu",
    "O", "OE", "OEsmall", "Oacute", "Oacutesmall", "Ocircumflex",
    "Ocircumflexsmall", "Odieresis", "Odieresissmall", "Ogoneksmall", "Ograve", "Ogravesmall",
    "Omega", "Omicron", "Oslash", "Oslashsmall", "Osmall", "Otilde",
    "Otildesmall", "P", "Phi", "Pi", "Psi", "Psmall",
    "Q", "Qsmall", "R", "Rfraktur", "Rho", "Ringsmall",
    "Rsmall", "S", "Scaron", "Scaronsmall", "Sigma", "Ssmall",
    "T", "Tau", "Theta", "Thorn", "Thornsmall", "Tildesmall",
    "Tsmall", "U", "Uacute", "Uacutesmall", "Ucircumflex", "Ucircumflexsmall",
    "Udieresis", "Udieresissmall", "Ugrave", "Ugravesmall", "Upsilon", "Upsilon1",
    "Usmall", "V", "Vsmall", "W", "Wsmall", "X",
    "Xi", "Xsmall", "Y", "Yacute", "Yacutesmall", "Ydieresis",
    "Ydieresissmall", "Ysmall", "Z", "Zcaron", "Zcaronsmall", "Zeta",
    "Zsmall", "a", "aacute", "acircumflex", "acute", "adieresis",
    "ae", "agrave", "aleph", "alpha", "ampersand", "ampersandsmall",
    "angle", "angleleft", "angleright", "apple", "approxequal", "aring",
    "arrowboth", "arrowdblboth", "arrowdbldown", "arrowdblleft", "arrowdblright", "arrowdblup",
    "arrowdown", "arrowhorizex", "arrowleft", "arrowright", "arrowup", "arrowvertex",
    "asciicircum", "asciitilde", "asterisk", "asteriskmath", "asuperior", "at",
    "atilde", "b", "backslash", "bar", "beta", "braceex",
    "braceleft", "braceleftbt", "braceleftmid", "bracelefttp", "braceright", "bracerightbt",
    "bracerightmid", "bracerighttp", "bracketleft", "bracketleftbt", "bracketleftex", "bracketlefttp",
    "bracketright", "bracketrightbt", "bracketrightex", "bracketrighttp", "breve", "brokenbar",
    "bsuperior", "bullet", "c", "caron", "carriagereturn", "ccedilla",
    "cedilla", "cent", "centinferior", "centoldstyle", "centsuperior", "chi",
    "circlemultiply", "circleplus", "circumflex", "club", "colon", "colonmonetary",
    "comma", "commainferior", "commasuperior", "congruent", "copyright", "copyrightsans",
    "copyrightserif", "currency", "d", "dagger", "daggerdbl", "degree",
    "delta", "diamond", "dieresis", "divide", "dollar", "dollarinferior",
    "dollaroldstyle", "dollarsuperior", "dotaccent", "dotlessi", "dotmath", "dsuperior",
    "e", "eacute", "ecircumflex", "edieresis", "egrave", "eight",
    "eightinferior", "eightoldstyle", "eightsuperior", "element", "ellipsis", "emdash",
    "emptyset", "endash", "epsilon", "equal", "equivalence", "esuperior",
    "eta", "eth", "exclam", "exclamdown", "exclamdownsmall", "exclamsmall",
    "existential", "f", "ff", "ffi", "ffl", "fi",
    "figuredash", "five", "fiveeighths", "fiveinferior", "fiveoldstyle", "fivesuperior",
    "fl", "florin", "four", "fourinferior", "fouroldstyle", "foursuperior",
    "fraction", "g", "gamma", "germandbls", "gradient", "grave",
    "greater", "greaterequal", "guillemotleft", "guillemotright", "guilsinglleft", "guilsinglright",
    "h", "heart", "hungarumlaut", "hyphen", "hypheninferior", "hyphensuperior",
    "i", "iacute", "icircumflex", "idieresis", "igrave", "infinity",
    "integral", "integralbt", "integralex", "integraltp", "intersection", "iota",
    "isuperior", "j", "k", "kappa", "l", "lambda",
    "less", "lessequal", "logicaland", "logicalnot", "logicalor", "lozenge",
    "lslash", "lsuperior", "m", "macron", "minus", "minute",
    "msuperior", "mu", "multiply", "n", "nine", "nineinferior",
    "nineoldstyle", "ninesuperior", "notelement", "notequal", "notsubset", "nsuperior",
    "ntilde", "nu", "numbersign", "o", "oacute", "ocircumflex",
    "odieresis", "oe", "ogonek", "ograve", "omega", "omega1",
    "omicron", "one", "onedotenleader", "oneeighth", "onefitted", "onehalf",
    "oneinferior", "oneoldstyle", "onequarter", "onesuperior", "onethird", "ordfeminine",
    "ordmasculine", "oslash", "osuperior", "otilde", "p", "paragraph",
    "parenleft", "parenleftbt", "parenleftex", "parenleftinferior", "parenleftsuperior", "parenlefttp",
    "parenright", "parenrightbt", "parenrightex", "parenrightinferior", "parenrightsuperior", "parenrighttp",
    "partialdiff", "percent", "period", "periodcentered", "periodinferior", "periodsuperior",
    "perpendicular", "perthousand", "phi", "phi1", "pi", "plus",
    "plusminus", "product", "propersubset", "propersuperset", "proportional", "psi",
    "q", "question", "questiondown", "questiondownsmall", "questionsmall", "quotedbl",
    "quotedblbase", "quotedblleft", "quotedblright", "quoteleft", "quoteright", "quotesinglbase",
    "quotesingle", "r", "radical", "radicalex", "reflexsubset", "reflexsuperset",
    "registered", "registersans", "registerserif", "rho", "ring", "rsuperior",
    "rupiah", "s", "scaron", "second", "section", "semicolon",
    "seven", "seveneighths", "seveninferior", "sevenoldstyle", "sevensuperior", "sigma",
    "sigma1", "similar", "six", "sixinferior", "sixoldstyle", "sixsuperior",
    "slash", "space", "spade", "ssuperior", "sterling", "suchthat",
    "summation", "t", "tau", "therefore", "theta", "theta1",
    "thorn", "three", "threeeighths", "threeinferior", "threeoldstyle", "threequarters",
    "threequartersemdash", "threesuperior", "tilde", "trademark", "trademarksans", "trademarkserif",
    "tsuperior", "two", "twodotenleader", "twoinferior", "twooldstyle", "twosuperior",
    "twothirds", "u", "uacute", "ucircumflex", "udieresis", "ugrave",
    "underscore", "union", "universal", "upsilon", "v", "w",
    "weierstrass", "x", "xi", "y", "yacute", "ydieresis",
    "yen", "z", "zcaron", "zero", "zeroinferior", "zerooldstyle",
    "zerosuperior", "zeta"
]

private let GLYPH_UNICODE_TEXTS: Array<String> = [
    "A", "Æ", "\u{F7E6}", "Á", "\u{F7E1}", "Â",
    "\u{F7E2}", "\u{F7B4}", "Ä", "\u{F7E4}", "À", "\u{F7E0}",
    "Α", "Å", "\u{F7E5}", "\u{F761}", "Ã", "\u{F7E3}",
    "B", "Β", "\u{F6F4}", "\u{F762}", "C", "\u{F6F5}",
    "Ç", "\u{F7E7}", "\u{F7B8}", "Χ", "\u{F6F6}", "\u{F763}",
    "D", "∆", "\u{F7A8}", "\u{F6F7}", "\u{F764}", "E",
    "É", "\u{F7E9}", "Ê", "\u{F7EA}", "Ë", "\u{F7EB}",
    "È", "\u{F7E8}", "Ε", "\u{F765}", "Η", "Ð",
    "\u{F7F0}", "€", "F", "\u{F766}", "G", "Γ",
    "\u{F760}", "\u{F767}", "H", "\u{F768}", "\u{F6F8}", "I",
    "Í", "\u{F7ED}", "Î", "\u{F7EE}", "Ï", "\u{F7EF}",
    "ℑ", "Ì", "\u{F7EC}", "Ι", "\u{F769}", "J",
    "\u{F76A}", "K", "Κ", "\u{F76B}", "L", "Λ",
    "Ł", "\u{F6F9}", "\u{F76C}", "M", "\u{F7AF}", "\u{F76D}",
    "Μ", "N", "\u{F76E}", "Ñ", "\u{F7F1}", "Ν",
    "O", "Œ", "\u{F6FA}", "Ó", "\u{F7F3}", "Ô",
    "\u{F7F4}", "Ö", "\u{F7F6}", "\u{F6FB}", "Ò", "\u{F7F2}",
    "Ω", "Ο", "Ø", "\u{F7F8}", "\u{F76F}", "Õ",
    "\u{F7F5}", "P", "Φ", "Π", "Ψ", "\u{F770}",
    "Q", "\u{F771}", "R", "ℜ", "Ρ", "\u{F6FC}",
    "\u{F772}", "S", "Š", "\u{F6FD}", "Σ", "\u{F773}",
    "T", "Τ", "Θ", "Þ", "\u{F7FE}", "\u{F6FE}",
    "\u{F774}", "U", "Ú", "\u{F7FA}", "Û", "\u{F7FB}",
    "Ü", "\u{F7FC}", "Ù", "\u{F7F9}", "Υ", "ϒ",
    "\u{F775}", "V", "\u{F776}", "W", "\u{F777}", "X",
    "Ξ", "\u{F778}", "Y", "Ý", "\u{F7FD}", "Ÿ",
    "\u{F7FF}", "\u{F779}", "Z", "Ž", "\u{F6FF}", "Ζ",
    "\u{F77A}", "a", "á", "â", "´", "ä",
    "æ", "à", "ℵ", "α", "&", "\u{F726}",
    "∠", "〈", "〉", "\u{F8FF}", "≈", "å",
    "↔", "⇔", "⇓", "⇐", "⇒", "⇑",
    "↓", "\u{F8E7}", "←", "→", "↑", "\u{F8E6}",
    "^", "~", "*", "∗", "\u{F6E9}", "@",
    "ã", "b", "\\", "|", "β", "\u{F8F4}",
    "{", "\u{F8F3}", "\u{F8F2}", "\u{F8F1}", "}", "\u{F8FE}",
    "\u{F8FD}", "\u{F8FC}", "[", "\u{F8F0}", "\u{F8EF}", "\u{F8EE}",
    "]", "\u{F8FB}", "\u{F8FA}", "\u{F8F9}", "˘", "¦",
    "\u{F6EA}", "•", "c", "ˇ", "↵", "ç",
    "¸", "¢", "\u{F6DF}", "\u{F7A2}", "\u{F6E0}", "χ",
    "⊗", "⊕", "ˆ", "♣", ":", "₡",
    ",", "\u{F6E1}", "\u{F6E2}", "≅", "©", "\u{F8E9}",
    "\u{F6D9}", "¤", "d", "†", "‡", "°",
    "δ", "♦", "¨", "÷", "$", "\u{F6E3}",
    "\u{F724}", "\u{F6E4}", "˙", "ı", "⋅", "\u{F6EB}",
    "e", "é", "ê", "ë", "è", "8",
    "₈", "\u{F738}", "⁸", "∈", "…", "—",
    "∅", "–", "ε", "=", "≡", "\u{F6EC}",
    "η", "ð", "!", "¡", "\u{F7A1}", "\u{F721}",
    "∃", "f", "ﬀ", "ﬃ", "ﬄ", "ﬁ",
    "‒", "5", "⅝", "₅", "\u{F735}", "⁵",
    "ﬂ", "ƒ", "4", "₄", "\u{F734}", "⁴",
    "⁄", "g", "γ", "ß", "∇", "`",
    ">", "≥", "«", "»", "‹", "›",
    "h", "♥", "˝", "-", "\u{F6E5}", "\u{F6E6}",
    "i", "í", "î", "ï", "ì", "∞",
    "∫", "⌡", "\u{F8F5}", "⌠", "∩", "ι",
    "\u{F6ED}", "j", "k", "κ", "l", "λ",
    "<", "≤", "∧", "¬", "∨", "◊",
    "ł", "\u{F6EE}", "m", "¯", "−", "′",
    "\u{F6EF}", "µ", "×", "n", "9", "₉",
    "\u{F739}", "⁹", "∉", "≠", "⊄", "ⁿ",
    "ñ", "ν", "#", "o", "ó", "ô",
    "ö", "œ", "˛", "ò", "ω", "ϖ",
    "ο", "1", "․", "⅛", "\u{F6DC}", "½",
    "₁", "\u{F731}", "¼", "¹", "⅓", "ª",
    "º", "ø", "\u{F6F0}", "õ", "p", "¶",
    "(", "\u{F8ED}", "\u{F8EC}", "₍", "⁽", "\u{F8EB}",
    ")", "\u{F8F8}", "\u{F8F7}", "₎", "⁾", "\u{F8F6}",
    "∂", "%", ".", "·", "\u{F6E7}", "\u{F6E8}",
    "⊥", "‰", "φ", "ϕ", "π", "+",
    "±", "∏", "⊂", "⊃", "∝", "ψ",
    "q", "?", "¿", "\u{F7BF}", "\u{F73F}", "\"",
    "„", "“", "”", "‘", "’", "‚",
    "'", "r", "√", "\u{F8E5}", "⊆", "⊇",
    "®", "\u{F8E8}", "\u{F6DA}", "ρ", "˚", "\u{F6F1}",
    "\u{F6DD}", "s", "š", "″", "§", ";",
    "7", "⅞", "₇", "\u{F737}", "⁷", "σ",
    "ς", "∼", "6", "₆", "\u{F736}", "⁶",
    "/", " ", "♠", "\u{F6F2}", "£", "∋",
    "∑", "t", "τ", "∴", "θ", "ϑ",
    "þ", "3", "⅜", "₃", "\u{F733}", "¾",
    "\u{F6DE}", "³", "˜", "™", "\u{F8EA}", "\u{F6DB}",
    "\u{F6F3}", "2", "‥", "₂", "\u{F732}", "²",
    "⅔", "u", "ú", "û", "ü", "ù",
    "_", "∪", "∀", "υ", "v", "w",
    "℘", "x", "ξ", "y", "ý", "ÿ",
    "¥", "z", "ž", "0", "₀", "\u{F730}",
    "⁰", "ζ"
]

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
