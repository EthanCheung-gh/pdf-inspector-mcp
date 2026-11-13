package pdf4cj

import std.collection.*

/**
 * Word grouping over already-positioned characters.
 *
 * This is a deliberately small approximation of pdfplumber's `WordExtractor`
 * (`extract_words`): characters are grouped into lines by their baseline, split
 * into words at whitespace and at horizontal gaps wider than [WORD_X_GAP], and
 * each word's box is the union of its characters' boxes.
 *
 * The tolerances are the pdfplumber defaults (`x_tolerance=3`, `y_tolerance=3`)
 * with a tighter baseline tolerance, because our `y0` is the *baseline* offset
 * glyph box bottom rather than pdfplumber's line box top: characters that share
 * a baseline are exact up to floating point noise, so 1.0pt is already generous.
 *
 * Differences from pdfplumber that are accepted on purpose:
 * - no `upright`/direction handling: rotated text is grouped as if horizontal;
 * - no `keep_blank_chars` / `split_at_punctuation` options;
 * - ligature expansion is not applied (the font layer decides the glyph text).
 */

/** Maximum baseline difference for two characters to share a line. */
let WORD_Y_TOLERANCE: Float64 = 1.0

/** Maximum horizontal gap between two characters of the same word. */
let WORD_X_GAP: Float64 = 3.0

/**
 * Group `chars` into words.
 *
 * The returned words are ordered for reading: descending `y1` (top of the box in
 * PDF user space, i.e. earlier lines first), then ascending `x0`. Within a word
 * the characters keep their input order, so the text matches the content stream.
 */
public func buildWords(chars: ArrayList<CharObj>): ArrayList<WordObj> {
    let words = ArrayList<WordObj>()
    let positioned = ArrayList<CharObj>()
    for (char in chars) {
        if (!char.text.isEmpty()) {
            positioned.add(char)
        }
    }
    if (positioned.isEmpty()) {
        return words
    }
    let lines = groupLines(sortByBaseline(positioned))
    for (line in lines) {
        for (word in splitLine(line)) {
            words.add(word)
        }
    }
    sortWordsForReading(words)
    words
}

/** Whether a glyph is pure whitespace (a hard word separator). */
func isBlankText(text: String): Bool {
    match (text) {
        case " " | "\t" | "\n" | "\r" | "\u{000B}" | "\u{000C}" => true
        case _ => false
    }
}

/**
 * Stable order by descending baseline, then ascending `x0`.
 *
 * A bottom-up merge sort keeps this O(n log n) without relying on the
 * deprecated `ArrayList.sort` overloads; pages can carry thousands of glyphs.
 */
func sortByBaseline(chars: ArrayList<CharObj>): ArrayList<CharObj> {
    var current = ArrayList<CharObj>(chars.size)
    for (char in chars) {
        current.add(char)
    }
    if (current.size < 2) {
        return current
    }
    var width: Int64 = 1
    while (width < current.size) {
        let merged = ArrayList<CharObj>(current.size)
        var start: Int64 = 0
        while (start < current.size) {
            let middle = minInt(start + width, current.size)
            let end = minInt(start + width * 2, current.size)
            var left = start
            var right = middle
            while (left < middle && right < end) {
                if (baselineLess(current[left], current[right])) {
                    merged.add(current[left])
                    left += 1
                } else {
                    merged.add(current[right])
                    right += 1
                }
            }
            while (left < middle) {
                merged.add(current[left])
                left += 1
            }
            while (right < end) {
                merged.add(current[right])
                right += 1
            }
            start = end
        }
        current = merged
        width *= 2
    }
    current
}

func baselineLess(left: CharObj, right: CharObj): Bool {
    if (left.y0 > right.y0) {
        return true
    }
    if (left.y0 < right.y0) {
        return false
    }
    left.x0 <= right.x0
}

func minInt(left: Int64, right: Int64): Int64 {
    if (left < right) {
        left
    } else {
        right
    }
}

/**
 * Cluster baseline-sorted characters into lines.
 *
 * The first character of a line sets the reference baseline; a character joins
 * the line when it is within [WORD_Y_TOLERANCE] of that reference. Comparing
 * against the reference (not the previous character) keeps a slowly drifting
 * line from absorbing the next one.
 */
func groupLines(sorted: ArrayList<CharObj>): ArrayList<ArrayList<CharObj>> {
    let lines = ArrayList<ArrayList<CharObj>>()
    var current = ArrayList<CharObj>()
    var reference: Float64 = 0.0
    for (char in sorted) {
        if (current.isEmpty()) {
            current = ArrayList<CharObj>()
            current.add(char)
            reference = char.y0
            continue
        }
        if (difference(char.y0, reference) <= WORD_Y_TOLERANCE) {
            current.add(char)
        } else {
            lines.add(current)
            current = ArrayList<CharObj>()
            current.add(char)
            reference = char.y0
        }
    }
    if (!current.isEmpty()) {
        lines.add(current)
    }
    lines
}

func difference(left: Float64, right: Float64): Float64 {
    if (left > right) {
        left - right
    } else {
        right - left
    }
}

/**
 * Split one line into words.
 *
 * A whitespace glyph always ends the current word (and is never part of one), so
 * "Header A" stays two words even when the space itself is only ~2.8pt wide; a
 * horizontal gap wider than [WORD_X_GAP] also ends it.
 */
func splitLine(line: ArrayList<CharObj>): ArrayList<WordObj> {
    let words = ArrayList<WordObj>()
    var current = ArrayList<CharObj>()
    for (char in line) {
        if (isBlankText(char.text)) {
            if (!current.isEmpty()) {
                words.add(mergeWord(current))
                current = ArrayList<CharObj>()
            }
            continue
        }
        if (current.isEmpty()) {
            current.add(char)
            continue
        }
        let previous = current[current.size - 1]
        if (char.x0 - previous.x1 > WORD_X_GAP || char.x0 < previous.x0) {
            words.add(mergeWord(current))
            current = ArrayList<CharObj>()
        }
        current.add(char)
    }
    if (!current.isEmpty()) {
        words.add(mergeWord(current))
    }
    words
}

/** Union the boxes of one word's characters; font/size come from the first. */
func mergeWord(chars: ArrayList<CharObj>): WordObj {
    let first = chars[0]
    var x0 = first.x0
    var y0 = first.y0
    var x1 = first.x1
    var y1 = first.y1
    let text = StringBuilder()
    for (char in chars) {
        text.append(char.text)
        if (char.x0 < x0) {
            x0 = char.x0
        }
        if (char.y0 < y0) {
            y0 = char.y0
        }
        if (char.x1 > x1) {
            x1 = char.x1
        }
        if (char.y1 > y1) {
            y1 = char.y1
        }
    }
    WordObj(
        text: text.toString(),
        x0: x0,
        y0: y0,
        x1: x1,
        y1: y1,
        fontname: first.fontname,
        size: first.size,
        page: first.page
    )
}

/** Reading order: top line first (`y1` descending), then left to right. */
func sortWordsForReading(words: ArrayList<WordObj>): Unit {
    if (words.size < 2) {
        return
    }
    var candidates = ArrayList<WordObj>(words.size)
    for (word in words) {
        candidates.add(word)
    }
    var width: Int64 = 1
    while (width < candidates.size) {
        let merged = ArrayList<WordObj>(candidates.size)
        var start: Int64 = 0
        while (start < candidates.size) {
            let middle = minInt(start + width, candidates.size)
            let end = minInt(start + width * 2, candidates.size)
            var left = start
            var right = middle
            while (left < middle && right < end) {
                if (wordLess(candidates[left], candidates[right])) {
                    merged.add(candidates[left])
                    left += 1
                } else {
                    merged.add(candidates[right])
                    right += 1
                }
            }
            while (left < middle) {
                merged.add(candidates[left])
                left += 1
            }
            while (right < end) {
                merged.add(candidates[right])
                right += 1
            }
            start = end
        }
        candidates = merged
        width *= 2
    }
    words.clear()
    for (word in candidates) {
        words.add(word)
    }
}

func wordLess(left: WordObj, right: WordObj): Bool {
    if (left.y1 > right.y1) {
        return true
    }
    if (left.y1 < right.y1) {
        return false
    }
    left.x0 <= right.x0
}
