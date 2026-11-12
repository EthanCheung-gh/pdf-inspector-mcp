package pdf_inspector_mcp.pdf

import std.collection.*
import std.io.*
import stdx.compress.zlib.*
import stdx.encoding.base64.*

/**
 * Image payloads for `pdf_get_image` and the `pdf_extract_*` image objects.
 *
 * An embedded image reaches us in one of three shapes:
 *
 * - a self-describing file (PNG, JPEG, GIF, WebP) that the MCP layer can hand
 *   straight to the renderer as a `data:` URL;
 * - a PDF-native codec we cannot display (JPEG2000, JBIG2), which is reported as
 *   an `error` instead of being returned as unusable bytes;
 * - raw samples (`/Subtype /Image` with 8/16/1-bit components), which are
 *   re-encoded as a PNG here so every successful payload is displayable.
 *
 * PNG encoding is written out by hand - signature, IHDR, IDAT, IEND with CRC32 -
 * because the toolchain has no image library; the pixel data is deflated with
 * `stdx.compress.zlib` and wrapped in the zlib container PNG's IDAT requires.
 *
 * Nothing in this file throws for bad input: [imagePayload] reports every
 * recoverable problem through [ImagePayload.error] so a single broken image
 * never fails a whole page or document request.
 */

/** Decoded image payload, or an `error` when the bytes cannot be displayed. */
public class ImagePayload {
    public var base64: String = ""
    public var format: String = ""
    public var mimeType: String = ""
    public var byteLength: Int64 = 0
    public var error: Option<String> = None
}

/** PNG magic, the first eight bytes of every PNG file. */
let PNG_SIGNATURE: Array<UInt8> = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

/** JPEG2000 codestream / JP2 container prefixes. */
let JPX_SIGNATURES: Array<Array<UInt8>> = [
    [0xFF, 0x4F, 0xFF, 0x51],
    [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
]

/** JBIG2 file header. */
let JBIG2_SIGNATURE: Array<UInt8> = [0x97, 0x4A, 0x42, 0x32, 0x0D, 0x0A, 0x1A, 0x0A]

/** Filters whose output is not raw samples, so it must not be PNG-encoded. */
let IMAGE_CODEC_FILTERS: Array<String> = [
    "DCTDecode", "DCT", "JPXDecode", "JBIG2Decode", "CCITTFaxDecode", "CCF"
]

// ---------------------------------------------------------------------------
// Public entry point

/**
 * Build the transferable payload for `image`.
 *
 * Bytes come from `image.imageData` when the content layer already decoded them,
 * else from `image.imageStream`; failures are reported in `error` instead of
 * raising, so callers can render a placeholder and keep going.
 */
public func imagePayload(doc: PdfDocument, image: ImageObj): ImagePayload {
    let payload = ImagePayload()
    try {
        let data = imageBytes(doc, image)
        if (data.size == 0) {
            payload.error = Some("No stream data available")
            return payload
        }
        match (detectImageFormat(data)) {
            case Some(format) =>
                if (format == "jpx" || format == "jbig2") {
                    payload.error = Some("Unsupported image format: ${format}")
                    return payload
                }
                return imageFill(payload, data, format)
            case None => ()
        }
        // Raw samples: re-encode them as PNG so the result stays displayable.
        var encoded: Option<Array<UInt8>> = None
        match (image.imageStream) {
            case Some(stream) => encoded = encodeImageStreamToPng(doc, stream)
            case None => ()
        }
        match (encoded) {
            case Some(png) => imageFill(payload, png, "png")
            case None =>
                payload.error = Some("Unsupported image format: unknown")
                payload
        }
    } catch (e: Exception) {
        let failed = ImagePayload()
        failed.error = Some("Failed to encode image payload: ${e.message}")
        failed
    }
}

/** Prefer the already-decoded bytes, then the stream payload. */
func imageBytes(doc: PdfDocument, image: ImageObj): Array<UInt8> {
    match (image.imageData) {
        case Some(bytes) =>
            if (bytes.size > 0) {
                return bytes
            }
        case None => ()
    }
    match (image.imageStream) {
        case Some(stream) => doc.streamData(stream)
        case None => Array<UInt8>()
    }
}

/** Fill a payload for `bytes` reported as `format` and return it. */
func imageFill(payload: ImagePayload, bytes: Array<UInt8>, format: String): ImagePayload {
    payload.base64 = toBase64String(bytes)
    payload.format = format
    payload.mimeType = imageMimeType(format)
    payload.byteLength = Int64(bytes.size)
    payload
}

/** MIME type of a detected format, `application/octet-stream` when unknown. */
public func imageMimeType(format: String): String {
    match (format) {
        case "png" => "image/png"
        case "jpeg" | "jpg" => "image/jpeg"
        case "gif" => "image/gif"
        case "webp" => "image/webp"
        case _ => "application/octet-stream"
    }
}

// ---------------------------------------------------------------------------
// Signature detection

/**
 * Identify an image by its magic bytes.
 *
 * Returns `png`/`jpeg`/`gif`/`webp` for formats a browser can display, `jpx` and
 * `jbig2` for the PDF-native codecs that cannot be handed to a renderer, and
 * `None` when the signature is missing (usually raw pixel samples).
 */
public func detectImageFormat(data: Array<UInt8>): Option<String> {
    if (imageStartsWith(data, PNG_SIGNATURE)) {
        return Some("png")
    }
    if (data.size >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) {
        return Some("jpeg")
    }
    if (imageStartsWithAscii(data, "GIF87a") || imageStartsWithAscii(data, "GIF89a")) {
        return Some("gif")
    }
    if (data.size >= 12 && imageStartsWithAscii(data, "RIFF") &&
        imageEqualsAsciiAt(data, 8, "WEBP")) {
        return Some("webp")
    }
    for (signature in JPX_SIGNATURES) {
        if (imageStartsWith(data, signature)) {
            return Some("jpx")
        }
    }
    if (imageStartsWith(data, JBIG2_SIGNATURE)) {
        return Some("jbig2")
    }
    None
}

func imageStartsWith(data: Array<UInt8>, prefix: Array<UInt8>): Bool {
    if (data.size < prefix.size) {
        return false
    }
    for (i in 0..prefix.size) {
        if (data[i] != prefix[i]) {
            return false
        }
    }
    true
}

func imageStartsWithAscii(data: Array<UInt8>, text: String): Bool {
    imageEqualsAsciiAt(data, 0, text)
}

/** Whether `text` (ASCII) occupies `data` starting at `offset`. */
func imageEqualsAsciiAt(data: Array<UInt8>, offset: Int64, text: String): Bool {
    let bytes = text.toArray()
    if (offset < 0 || data.size < offset + bytes.size) {
        return false
    }
    for (i in 0..bytes.size) {
        if (data[offset + i] != UInt8(bytes[i])) {
            return false
        }
    }
    true
}

// ---------------------------------------------------------------------------
// Raw samples -> PNG

/**
 * Re-encode a PDF image XObject's raw samples as PNG.
 *
 * Handles `/DeviceGray`, `/DeviceRGB`, `/DeviceCMYK` (converted to RGB) and
 * `/ICCBased` colour spaces with 1, 8 or 16 bits per component; anything else
 * (notably `/Indexed`, `/Separation`, `/DeviceN`, 2/4-bit samples and payloads
 * still in a codec filter) yields `None` instead of a corrupt image.
 */
public func encodeImageStreamToPng(doc: PdfDocument, stream: PdfStream): Option<Array<UInt8>> {
    let subtype = imageDictName(doc, stream, "Subtype")
    match (subtype) {
        case Some(name) =>
            if (name != "Image") {
                return None
            }
        case None => return None
    }
    if (imageHasCodecFilter(doc, stream)) {
        return None
    }
    let width = imageDictInt(doc, stream, "Width", 0)
    let height = imageDictInt(doc, stream, "Height", 0)
    if (width <= 0 || height <= 0) {
        return None
    }
    let bits = imageDictInt(doc, stream, "BitsPerComponent", 8)
    if (bits != 1 && bits != 8 && bits != 16) {
        return None
    }
    let data = doc.streamData(stream)
    if (data.size == 0) {
        return None
    }
    let components = match (imageColorSpace(doc, stream.dict.get("ColorSpace"))) {
        case ImageColorSpace.Known(count) => count
        case ImageColorSpace.Missing =>
            // A missing colour space is not legal PDF, but inferring it from the
            // payload length rescues otherwise readable images.
            imageGuessComponents(data.size, width, height, bits)
        case ImageColorSpace.Unsupported => return None
    }
    if (components <= 0) {
        return None
    }
    let samples = match (imageSamples(data, width, height, components, bits)) {
        case Some(values) => values
        case None => return None
    }
    let decoded = imageApplyDecode(doc, stream, samples, components)
    let png = if (components == 4) {
        // CMYK has no PNG colour type; convert instead of shipping raw channels.
        encodePng(width, height, 3, imageCmykToRgb(decoded))
    } else {
        encodePng(width, height, components, decoded)
    }
    if (png.size == 0) {
        return None
    }
    Some(png)
}

func imageDictName(doc: PdfDocument, stream: PdfStream, key: String): Option<String> {
    match (stream.dict.get(key)) {
        case Some(value) => doc.asName(value)
        case None => None
    }
}

func imageDictInt(doc: PdfDocument, stream: PdfStream, key: String, fallback: Int64): Int64 {
    match (stream.dict.get(key)) {
        case Some(value) =>
            match (doc.asInt(value)) {
                case Some(number) => number
                case None => fallback
            }
        case None => fallback
    }
}

/** Whether `/Filter` names a codec whose output is not raw samples. */
func imageHasCodecFilter(doc: PdfDocument, stream: PdfStream): Bool {
    let value = match (stream.dict.get("Filter")) {
        case Some(entry) => doc.resolve(entry)
        case None => return false
    }
    let names = filterNames(value)
    for (name in names) {
        for (codec in IMAGE_CODEC_FILTERS) {
            if (name == codec) {
                return true
            }
        }
    }
    false
}

/**
 * What `/ColorSpace` said: a component count, "nothing there, guess it", or a
 * space this encoder cannot expand.
 */
enum ImageColorSpace {
    | Known(Int64)
    | Missing
    | Unsupported
}

/**
 * Classify a `/ColorSpace` entry.
 *
 * `/Indexed`, `/Separation`, `/DeviceN`, `/Lab` and `/Pattern` are reported as
 * unsupported instead of being guessed at: their samples are palette indices or
 * device-independent channels, not RGB/gray bytes.
 */
func imageColorSpace(doc: PdfDocument, value: Option<PdfValue>): ImageColorSpace {
    let resolved = match (value) {
        case Some(entry) => doc.resolve(entry)
        case None => return ImageColorSpace.Missing
    }
    match (resolved) {
        case PdfValue.PdfName(name) => imageColorSpaceOfName(name)
        case PdfValue.PdfArray(items) =>
            if (items.isEmpty()) {
                return ImageColorSpace.Unsupported
            }
            match (doc.asName(items[0])) {
                case Some(name) =>
                    match (name) {
                        case "ICCBased" =>
                            if (items.size < 2) {
                                ImageColorSpace.Unsupported
                            } else {
                                imageIccComponents(doc, items[1])
                            }
                        case _ => imageColorSpaceOfName(name)
                    }
                case None => ImageColorSpace.Unsupported
            }
        case _ => ImageColorSpace.Unsupported
    }
}

func imageColorSpaceOfName(name: String): ImageColorSpace {
    match (name) {
        case "DeviceRGB" | "RGB" | "CalRGB" => ImageColorSpace.Known(3)
        case "DeviceGray" | "G" | "CalGray" => ImageColorSpace.Known(1)
        case "DeviceCMYK" | "CMYK" => ImageColorSpace.Known(4)
        case "Indexed" | "I" | "Separation" | "DeviceN" | "Lab" | "Pattern" =>
            ImageColorSpace.Unsupported
        case _ => ImageColorSpace.Unsupported
    }
}

/** `/ICCBased` carries its component count as `/N` on the profile stream. */
func imageIccComponents(doc: PdfDocument, value: PdfValue): ImageColorSpace {
    match (doc.resolve(value)) {
        case PdfValue.PdfStream(profile) =>
            let count = match (profile.dict.get("N")) {
                case Some(entry) =>
                    match (doc.asInt(entry)) {
                        case Some(number) => number
                        case None => 0
                    }
                case None => 0
            }
            if (count == 1 || count == 3 || count == 4) {
                ImageColorSpace.Known(count)
            } else {
                ImageColorSpace.Unsupported
            }
        case _ => ImageColorSpace.Unsupported
    }
}

/** Infer the component count from the payload size; 0 when no guess fits. */
func imageGuessComponents(byteCount: Int64, width: Int64, height: Int64, bits: Int64): Int64 {
    let pixels = width * height
    if (pixels <= 0) {
        return 0
    }
    let expectedPerComponent = pixels * bits / 8
    if (expectedPerComponent <= 0) {
        return 0
    }
    for (count in [3, 4, 1]) {
        if (byteCount >= expectedPerComponent * count) {
            return count
        }
    }
    0
}

/**
 * Expand the raw payload to one byte per sample, row by row.
 *
 * 1-bit samples become 0/255 (PDF's `/DeviceGray` bilevel convention) and 16-bit
 * samples keep their high byte, which is what an 8-bit PNG can represent.
 */
func imageSamples(
    data: Array<UInt8>,
    width: Int64,
    height: Int64,
    components: Int64,
    bits: Int64
): Option<Array<UInt8>> {
    let rowSamples = width * components
    if (rowSamples <= 0) {
        return None
    }
    if (bits == 8) {
        let needed = rowSamples * height
        if (Int64(data.size) < needed) {
            return None
        }
        let out = Array<UInt8>(needed, repeat: 0)
        for (i in 0..needed) {
            out[i] = data[i]
        }
        return Some(out)
    }
    if (bits == 16) {
        let needed = rowSamples * height * 2
        if (Int64(data.size) < needed) {
            return None
        }
        let out = Array<UInt8>(rowSamples * height, repeat: 0)
        for (i in 0..(rowSamples * height)) {
            out[i] = data[i * 2]
        }
        return Some(out)
    }
    // 1 bit per component: only bilevel gray images are defined here.
    if (components != 1) {
        return None
    }
    let rowBytes = (width + 7) / 8
    if (Int64(data.size) < rowBytes * height) {
        return None
    }
    let out = Array<UInt8>(width * height, repeat: 0)
    for (row in 0..height) {
        for (col in 0..width) {
            let byte = data[row * rowBytes + col / 8]
            let bit = (Int64(byte) >> (7 - (col % 8))) & 1
            out[row * width + col] = if (bit == 1) { 255 } else { 0 }
        }
    }
    Some(out)
}

/**
 * Apply `/Decode` to the samples.
 *
 * `/Decode [1 0]` inverts a colour component and `[0 1]` is the identity, which
 * covers every real-world case; arbitrary ranges are mapped linearly so an
 * unusual `/Decode` still produces sane output.
 */
func imageApplyDecode(
    doc: PdfDocument,
    stream: PdfStream,
    samples: Array<UInt8>,
    components: Int64
): Array<UInt8> {
    let entry = match (stream.dict.get("Decode")) {
        case Some(value) => doc.resolve(value)
        case None => return samples
    }
    let items = match (entry) {
        case PdfValue.PdfArray(values) => values
        case _ => return samples
    }
    if (items.size < components * 2) {
        return samples
    }
    var identity = true
    for (component in 0..components) {
        let low = imageDecodeBound(doc, items, component * 2, 0.0)
        let high = imageDecodeBound(doc, items, component * 2 + 1, 1.0)
        if (imageAbs(low) > 0.0001 || imageAbs(high - 1.0) > 0.0001) {
            identity = false
        }
    }
    if (identity) {
        return samples
    }
    let out = samples.clone()
    for (index in 0..out.size) {
        let component = index % components
        let low = imageDecodeBound(doc, items, component * 2, 0.0)
        let high = imageDecodeBound(doc, items, component * 2 + 1, 1.0)
        let normalized = Float64(out[index]) / 255.0
        let mapped = (low + normalized * (high - low)) * 255.0
        let clamped = if (mapped < 0.0) { 0.0 } else if (mapped > 255.0) { 255.0 } else { mapped }
        out[index] = UInt8(Int64(clamped + 0.5))
    }
    out
}

/** One `/Decode` entry as a number, `fallback` when it is not numeric. */
func imageDecodeBound(doc: PdfDocument, items: ArrayList<PdfValue>, index: Int64, fallback: Float64): Float64 {
    if (index < 0 || index >= items.size) {
        return fallback
    }
    match (doc.asNumber(items[index])) {
        case Some(value) => value
        case None => fallback
    }
}

/** Naive CMYK -> RGB, matching the usual `(255 - C) * (255 - K) / 255` formula. */
func imageCmykToRgb(samples: Array<UInt8>): Array<UInt8> {
    let pixels = samples.size / 4
    let out = Array<UInt8>(pixels * 3, repeat: 0)
    for (pixel in 0..pixels) {
        let c = Int64(samples[pixel * 4])
        let m = Int64(samples[pixel * 4 + 1])
        let y = Int64(samples[pixel * 4 + 2])
        let k = Int64(samples[pixel * 4 + 3])
        out[pixel * 3] = UInt8((255 - c) * (255 - k) / 255)
        out[pixel * 3 + 1] = UInt8((255 - m) * (255 - k) / 255)
        out[pixel * 3 + 2] = UInt8((255 - y) * (255 - k) / 255)
    }
    out
}

// ---------------------------------------------------------------------------
// PNG encoder

/**
 * Encode 8-bit pixels as a PNG file.
 *
 * `channels` is 1 (grayscale, colour type 0) or 3 (RGB, colour type 2); any other
 * value, or a non-positive size, returns an empty array so callers can report
 * "unsupported" rather than ship a broken file. The row filter byte is always 0
 * (None): filtering only helps compression ratio, and raw samples from a PDF are
 * already byte-aligned.
 */
public func encodePng(width: Int64, height: Int64, channels: Int64, pixels: Array<UInt8>): Array<UInt8> {
    if (width <= 0 || height <= 0) {
        return Array<UInt8>()
    }
    if (channels != 1 && channels != 3) {
        return Array<UInt8>()
    }
    let rowBytes = width * channels
    let raw = Array<UInt8>(height * (rowBytes + 1), repeat: 0)
    for (row in 0..height) {
        let target = row * (rowBytes + 1)
        raw[target] = 0
        for (i in 0..rowBytes) {
            let index = row * rowBytes + i
            raw[target + 1 + i] = if (index < Int64(pixels.size)) { pixels[index] } else { 0 }
        }
    }
    let compressed = pngZlibCompress(raw)
    let out = ArrayList<UInt8>()
    for (b in PNG_SIGNATURE) {
        out.add(b)
    }
    let header = Array<UInt8>(13, repeat: 0)
    imageWriteUInt32(header, 0, width)
    imageWriteUInt32(header, 4, height)
    header[8] = 8
    header[9] = if (channels == 1) { 0 } else { 2 }
    header[10] = 0
    header[11] = 0
    header[12] = 0
    pngAppendChunk(out, "IHDR", header)
    pngAppendChunk(out, "IDAT", compressed)
    pngAppendChunk(out, "IEND", Array<UInt8>())
    out.toArray()
}

/** Append one PNG chunk: length, 4-byte type, payload, CRC32 over type+payload. */
func pngAppendChunk(out: ArrayList<UInt8>, kind: String, payload: Array<UInt8>): Unit {
    let typeBytes = kind.toArray()
    let length = Array<UInt8>(4, repeat: 0)
    imageWriteUInt32(length, 0, Int64(payload.size))
    for (b in length) {
        out.add(b)
    }
    for (b in typeBytes) {
        out.add(b)
    }
    for (b in payload) {
        out.add(b)
    }
    let table = pngCrcTable()
    var crc: Int64 = 0xFFFFFFFF
    crc = pngCrcUpdate(table, crc, typeBytes)
    crc = pngCrcUpdate(table, crc, payload)
    crc = crc ^ 0xFFFFFFFF
    let crcBytes = Array<UInt8>(4, repeat: 0)
    imageWriteUInt32(crcBytes, 0, crc)
    for (b in crcBytes) {
        out.add(b)
    }
}

/** Deflate `data` and wrap it in the zlib container PNG's IDAT requires. */
func pngZlibCompress(data: Array<UInt8>): Array<UInt8> {
    let sink = ByteBuffer()
    let deflater = CompressOutputStream(sink, wrap: WrapType.DeflateFormat)
    try {
        deflater.write(data)
        deflater.flush()
    } finally {
        deflater.close()
    }
    let header = pngZlibHeader()
    let adler = pngAdler32(data)
    let out = ArrayList<UInt8>()
    out.add(header[0])
    out.add(header[1])
    for (b in sink.bytes()) {
        out.add(b)
    }
    out.add(UInt8((adler >> 24) & 0xFF))
    out.add(UInt8((adler >> 16) & 0xFF))
    out.add(UInt8((adler >> 8) & 0xFF))
    out.add(UInt8(adler & 0xFF))
    out.toArray()
}

/**
 * Two-byte RFC 1950 header: deflate, 32K window, no preset dictionary.
 *
 * The check value `(CMF * 256 + FLG) % 31 == 0` is part of the format; the values
 * below are the ones zlib itself emits for its default compression level.
 */
func pngZlibHeader(): Array<UInt8> {
    [0x78, 0x01]
}

/** Adler-32 checksum of the *uncompressed* data, as zlib trailers require. */
func pngAdler32(data: Array<UInt8>): Int64 {
    var first: Int64 = 1
    var second: Int64 = 0
    for (byte in data) {
        first = (first + Int64(byte)) % 65521
        second = (second + first) % 65521
    }
    (second << 16) | first
}

/** CRC32 lookup table for the PNG chunk checksums (polynomial 0xEDB88320). */
func pngCrcTable(): Array<Int64> {
    let table = Array<Int64>(256, repeat: 0)
    for (n in 0..256) {
        var value = Int64(n)
        for (_ in 0..8) {
            if ((value & 1) != 0) {
                value = 0xEDB88320 ^ (value >> 1)
            } else {
                value = value >> 1
            }
        }
        table[n] = value
    }
    table
}

func pngCrcUpdate(table: Array<Int64>, crc: Int64, data: Array<UInt8>): Int64 {
    var value = crc
    for (byte in data) {
        let index = Int64((value ^ Int64(byte)) & 0xFF)
        value = table[index] ^ (value >> 8)
    }
    value
}

/** Write `value` big-endian into `target` starting at `offset`. */
func imageWriteUInt32(target: Array<UInt8>, offset: Int64, value: Int64): Unit {
    target[offset] = UInt8((value >> 24) & 0xFF)
    target[offset + 1] = UInt8((value >> 16) & 0xFF)
    target[offset + 2] = UInt8((value >> 8) & 0xFF)
    target[offset + 3] = UInt8(value & 0xFF)
}

func imageAbs(value: Float64): Float64 {
    if (value < 0.0) { -value } else { value }
}
