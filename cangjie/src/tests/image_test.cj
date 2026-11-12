package pdf_inspector_mcp.tests

import std.collection.*
import std.fs.*
import std.io.*
import std.random.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.compress.zlib.*
import stdx.encoding.base64.*
import pdf_inspector_mcp.pdf.*

/**
 * Tests for the image payload layer: signature detection, pass-through of
 * browser-renderable formats, and the hand-written PNG encoder used for raw
 * samples.
 *
 * The encoded PNG is checked structurally rather than by eyeballing bytes: the
 * chunks must be well formed, every chunk CRC must match an independent CRC32
 * implementation, and IDAT must inflate to exactly the scanlines the encoder was
 * asked to write. That is what makes the output a *PNG* rather than merely a file
 * that starts with `\x89PNG`.
 *
 * A real [PdfDocument] is only needed for `streamData`; the probe PDF below
 * carries no page content at all, while the `/Subtype /Image` streams under test
 * are built in memory and handed to the payload builder directly.
 */

// ---------------------------------------------------------------------------
// Signature detection

@Test
func imageDetectsKnownSignatures(): Unit {
    @Expect(imageFormatOf(imagePngOnePixel()), "png")
    @Expect(imageFormatOf([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]), "jpeg")
    @Expect(imageFormatOf("GIF89a-rest".toArray()), "gif")
    @Expect(imageFormatOf("GIF87a-rest".toArray()), "gif")
    // "RIFF" + chunk size + "WEBP" + "VP8 ".
    let webp: Array<UInt8> = [
        0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
        0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20
    ]
    @Expect(imageFormatOf(webp), "webp")
    // JP2 container signature.
    @Expect(
        imageFormatOf([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]),
        "jpx"
    )
    // Raw JPEG2000 codestream signature.
    @Expect(imageFormatOf([0xFF, 0x4F, 0xFF, 0x51, 0x00]), "jpx")
    // JBIG2 file header.
    @Expect(
        imageFormatOf([0x97, 0x4A, 0x42, 0x32, 0x0D, 0x0A, 0x1A, 0x0A]),
        "jbig2"
    )
    @Expect(imageFormatOf([0x00, 0x01, 0x02, 0x03]), "")
    @Expect(imageFormatOf([0xFF, 0xD8]), "")
}

// ---------------------------------------------------------------------------
// imagePayload over in-memory images

@Test
func imagePayloadPassesPngThroughUnchanged(): Unit {
    let document = imageProbeDocument()
    let png = imagePngOnePixel()
    let payload = imagePayload(
        document,
        ImageObj(
            x0: 50.0,
            y0: 50.0,
            x1: 150.0,
            y1: 150.0,
            width: 100.0,
            height: 100.0,
            streamId: "p1_img_0",
            page: 1,
            imageData: Some(png)
        )
    )
    document.close()

    @Expect(payload.format, "png")
    @Expect(payload.mimeType, "image/png")
    @Expect(payload.byteLength, 70)
    @Expect(imageErrorMessage(payload), "")
    @Expect(imageDecodedPayload(payload).size, 70)
    @Assert(imagePayloadEquals(payload, png))
}

@Test
func imagePayloadPassesJpegThroughUnchanged(): Unit {
    let document = imageProbeDocument()
    // SOI + APP0 marker, then an opaque DCT tail.
    let bytes: Array<UInt8> = [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
    ]
    let payload = imagePayload(
        document,
        ImageObj(streamId: "p1_img_1", page: 1, imageData: Some(bytes))
    )
    document.close()

    @Expect(payload.format, "jpeg")
    @Expect(payload.mimeType, "image/jpeg")
    @Expect(payload.byteLength, Int64(bytes.size))
    @Expect(imageErrorMessage(payload), "")
    @Assert(imagePayloadEquals(payload, bytes))
}

@Test
func imagePayloadRejectsUnrenderableCodecs(): Unit {
    let document = imageProbeDocument()
    // JP2 container signature ("\x00\x00\x00\x0cjP  \r\n\x87\n").
    let jp2: Array<UInt8> = [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
    let jpx = imagePayload(
        document,
        ImageObj(page: 1, imageData: Some(jp2))
    )
    @Expect(imageErrorMessage(jpx), "Unsupported image format: jpx")
    @Expect(jpx.base64, "")
    @Expect(jpx.format, "")

    let jbig2Header: Array<UInt8> = [0x97, 0x4A, 0x42, 0x32, 0x0D, 0x0A, 0x1A, 0x0A]
    let jbig2 = imagePayload(
        document,
        ImageObj(page: 1, imageData: Some(jbig2Header))
    )
    @Expect(imageErrorMessage(jbig2), "Unsupported image format: jbig2")
    @Expect(jbig2.base64, "")
    document.close()
}

@Test
func imagePayloadWithoutDataReportsAnError(): Unit {
    let document = imageProbeDocument()
    let payload = imagePayload(document, ImageObj(streamId: "p1_img_2", page: 1))
    document.close()

    @Expect(imageErrorMessage(payload), "No stream data available")
    @Expect(payload.base64, "")
    @Expect(payload.byteLength, 0)
}

// ---------------------------------------------------------------------------
// Raw samples -> PNG

@Test
func imageEncodesRawRgbSamplesAsPng(): Unit {
    let document = imageProbeDocument()
    let pixels = imageRgbPixels(4, 4)
    let stream = imageStream(
        imageImageDict(4, 4, PdfValue.PdfName("DeviceRGB"), 8),
        pixels
    )
    let payload = imagePayload(
        document,
        ImageObj(
            x0: 0.0,
            y0: 0.0,
            x1: 4.0,
            y1: 4.0,
            streamId: "p1_img_0",
            page: 1,
            imageData: Some(pixels),
            imageStream: Some(stream)
        )
    )
    document.close()

    @Expect(imageErrorMessage(payload), "")
    @Expect(payload.format, "png")
    @Expect(payload.mimeType, "image/png")
    let png = imageDecodedPayload(payload)
    @Expect(payload.byteLength, Int64(png.size))
    @Assert(imageHasPngSignature(png))

    let chunks = imagePngChunks(png)
    @Expect(chunks.size, 3)
    @Expect(chunks[0].kind, "IHDR")
    @Expect(imageUInt32(chunks[0].payload, 0), 4)
    @Expect(imageUInt32(chunks[0].payload, 4), 4)
    @Expect(Int64(chunks[0].payload[8]), 8)
    // Colour type 2 = truecolour RGB.
    @Expect(Int64(chunks[0].payload[9]), 2)
    @Expect(chunks[1].kind, "IDAT")
    @Expect(chunks[2].kind, "IEND")
    @Expect(chunks[2].payload.size, 0)
    // Every scanline starts with filter byte 0 and then the original pixels.
    let rows = imageInflate(chunks[1].payload)
    @Expect(rows.size, Int64(4 * (4 * 3 + 1)))
    var matches = true
    for (row in 0..4) {
        if (rows[row * 13] != UInt8(0)) {
            matches = false
        }
        for (i in 0..12) {
            if (rows[row * 13 + 1 + i] != pixels[row * 12 + i]) {
                matches = false
            }
        }
    }
    @Assert(matches)
    @Assert(imageChunkCrcsAreValid(png))
}

@Test
func imageEncodesGrayAndCmykSamples(): Unit {
    let document = imageProbeDocument()
    // Grayscale stays one channel; CMYK is converted to three.
    let gray = ArrayList<UInt8>()
    for (i in 0..16) {
        gray.add(UInt8(i * 15))
    }
    let grayPayload = imagePayload(
        document,
        ImageObj(
            page: 1,
            imageData: Some(gray.toArray()),
            imageStream: Some(imageStream(imageImageDict(4, 4, PdfValue.PdfName("DeviceGray"), 8), gray.toArray()))
        )
    )
    @Expect(grayPayload.format, "png")
    @Expect(Int64(imagePngChunks(imageDecodedPayload(grayPayload))[0].payload[9]), 0)

    let cmyk = ArrayList<UInt8>()
    for (i in 0..16) {
        cmyk.add(UInt8(i * 4))
    }
    let cmykPayload = imagePayload(
        document,
        ImageObj(
            page: 1,
            imageData: Some(cmyk.toArray()),
            imageStream: Some(imageStream(imageImageDict(2, 2, PdfValue.PdfName("DeviceCMYK"), 8), cmyk.toArray()))
        )
    )
    document.close()

    @Expect(imageErrorMessage(cmykPayload), "")
    @Expect(cmykPayload.format, "png")
    // Converted to RGB, so colour type 2 with one extra byte per scanline.
    let cmykPng = imageDecodedPayload(cmykPayload)
    @Expect(Int64(imagePngChunks(cmykPng)[0].payload[9]), 2)
    @Expect(imageInflate(imagePngChunks(cmykPng)[1].payload).size, Int64(2 * (2 * 3 + 1)))
}

@Test
func imageEncodesBilevelAndSixteenBitSamples(): Unit {
    let document = imageProbeDocument()
    // 8x2 bilevel: one byte per row, bits expanded to 0/255.
    let bilevel: Array<UInt8> = [0xA0, 0x50]
    let bilevelPayload = imagePayload(
        document,
        ImageObj(
            page: 1,
            imageData: Some(bilevel),
            imageStream: Some(imageStream(imageImageDict(8, 2, PdfValue.PdfName("DeviceGray"), 1), bilevel))
        )
    )
    @Expect(imageErrorMessage(bilevelPayload), "")
    let bilevelPng = imageDecodedPayload(bilevelPayload)
    @Expect(Int64(imagePngChunks(bilevelPng)[0].payload[9]), 0)
    let bilevelRows = imageInflate(imagePngChunks(bilevelPng)[1].payload)
    @Expect(bilevelRows.size, Int64(2 * 9))
    @Expect(Int64(bilevelRows[1]), 255)
    @Expect(Int64(bilevelRows[2]), 0)
    @Expect(Int64(bilevelRows[3]), 255)

    // 16-bit RGB keeps the high byte of each sample.
    let sixteen = ArrayList<UInt8>()
    for (i in 0..(2 * 2 * 3 * 2)) {
        sixteen.add(if (i % 2 == 0) { UInt8(0xAB) } else { UInt8(0xCD) })
    }
    let sixteenPayload = imagePayload(
        document,
        ImageObj(
            page: 1,
            imageData: Some(sixteen.toArray()),
            imageStream: Some(imageStream(imageImageDict(2, 2, PdfValue.PdfName("DeviceRGB"), 16), sixteen.toArray()))
        )
    )
    document.close()

    @Expect(imageErrorMessage(sixteenPayload), "")
    let sixteenRows = imageInflate(imagePngChunks(imageDecodedPayload(sixteenPayload))[1].payload)
    @Expect(sixteenRows.size, Int64(2 * (2 * 3 + 1)))
    @Expect(Int64(sixteenRows[1]), 0xAB)
}

@Test
func imageAppliesDecodeArrayInversion(): Unit {
    let document = imageProbeDocument()
    // /Decode [1 0 1 0 1 0] inverts every RGB component.
    let dict = imageImageDict(2, 1, PdfValue.PdfName("DeviceRGB"), 8)
    let decode = ArrayList<PdfValue>()
    for (_ in 0..3) {
        decode.add(PdfValue.PdfInt(1))
        decode.add(PdfValue.PdfInt(0))
    }
    dict.add("Decode", PdfValue.PdfArray(decode))
    let pixels: Array<UInt8> = [0, 10, 250, 255, 128, 1]
    let payload = imagePayload(
        document,
        ImageObj(page: 1, imageData: Some(pixels), imageStream: Some(imageStream(dict, pixels)))
    )
    document.close()

    @Expect(imageErrorMessage(payload), "")
    let rows = imageInflate(imagePngChunks(imageDecodedPayload(payload))[1].payload)
    @Expect(rows.size, Int64(7))
    @Expect(Int64(rows[1]), 255)
    @Expect(Int64(rows[2]), 245)
    @Expect(Int64(rows[3]), 5)
    @Expect(Int64(rows[4]), 0)
    @Expect(Int64(rows[5]), 127)
    @Expect(Int64(rows[6]), 254)
}

@Test
func imageRejectsUnsupportedSampleLayouts(): Unit {
    let document = imageProbeDocument()
    // 4 bits per component is outside the 1/8/16-bit support we promise.
    let fourBitPixels: Array<UInt8> = [0x12, 0x34]
    let fourBit = imagePayload(
        document,
        ImageObj(
            page: 1,
            imageData: Some(fourBitPixels),
            imageStream: Some(imageStream(imageImageDict(2, 1, PdfValue.PdfName("DeviceGray"), 4), fourBitPixels))
        )
    )
    @Expect(imageErrorMessage(fourBit), "Unsupported image format: unknown")

    // /Indexed would need a palette expansion this encoder does not do.
    let indexedSpace = ArrayList<PdfValue>()
    indexedSpace.add(PdfValue.PdfName("Indexed"))
    indexedSpace.add(PdfValue.PdfName("DeviceRGB"))
    indexedSpace.add(PdfValue.PdfInt(1))
    indexedSpace.add(PdfValue.PdfString([0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF]))
    let indexedPixels: Array<UInt8> = [0x00, 0x01]
    let indexed = imagePayload(
        document,
        ImageObj(
            page: 1,
            imageData: Some(indexedPixels),
            imageStream: Some(imageStream(imageImageDict(2, 1, PdfValue.PdfArray(indexedSpace), 8), indexedPixels))
        )
    )
    @Expect(imageErrorMessage(indexed), "Unsupported image format: unknown")

    // A truncated payload must not produce a half-filled image.
    let shortPixels: Array<UInt8> = [0x01, 0x02, 0x03]
    let truncated = imagePayload(
        document,
        ImageObj(
            page: 1,
            imageData: Some(shortPixels),
            imageStream: Some(imageStream(imageImageDict(8, 8, PdfValue.PdfName("DeviceRGB"), 8), shortPixels))
        )
    )
    document.close()
    @Expect(imageErrorMessage(truncated), "Unsupported image format: unknown")
}

@Test
func imageEncodePngRejectsImpossibleInput(): Unit {
    @Expect(encodePng(0, 1, 3, Array<UInt8>()).size, 0)
    @Expect(encodePng(1, 0, 3, Array<UInt8>()).size, 0)
    // Only grayscale and RGB are emitted.
    @Expect(encodePng(1, 1, 4, Array<UInt8>()).size, 0)
    @Assert(encodePng(2, 2, 1, [1, 2, 3, 4]).size > 0)
}

// ---------------------------------------------------------------------------
// Helpers

/** Detected format, or the empty string for "unknown". */
func imageFormatOf(data: Array<UInt8>): String {
    match (detectImageFormat(data)) {
        case Some(format) => format
        case None => ""
    }
}

/** The `error` message, or the empty string when the payload succeeded. */
func imageErrorMessage(payload: ImagePayload): String {
    match (payload.error) {
        case Some(message) => message
        case None => ""
    }
}

func imageDecodedPayload(payload: ImagePayload): Array<UInt8> {
    match (fromBase64String(payload.base64)) {
        case Some(bytes) => bytes
        case None => Array<UInt8>()
    }
}

func imagePayloadEquals(payload: ImagePayload, expected: Array<UInt8>): Bool {
    let decoded = imageDecodedPayload(payload)
    if (decoded.size != expected.size) {
        return false
    }
    for (i in 0..expected.size) {
        if (decoded[i] != expected[i]) {
            return false
        }
    }
    true
}

/** The 1x1 RGB PNG every "already an image file" test starts from. */
func imagePngOnePixel(): Array<UInt8> {
    [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x64, 0x60, 0xF8, 0x5F,
        0x0F, 0x00, 0x02, 0x87, 0x01, 0x80, 0xEB, 0x47, 0xBA, 0x92, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ]
}

/** `width * height` RGB triples with varying components. */
func imageRgbPixels(width: Int64, height: Int64): Array<UInt8> {
    let out = Array<UInt8>(width * height * 3, repeat: 0)
    var index: Int64 = 0
    for (row in 0..height) {
        for (col in 0..width) {
            out[index] = UInt8(row * 40 + col)
            out[index + 1] = UInt8(255 - row * 20)
            out[index + 2] = UInt8(col * 30 + 7)
            index += 3
        }
    }
    out
}

func imageImageDict(
    width: Int64,
    height: Int64,
    colorSpace: PdfValue,
    bits: Int64
): HashMap<String, PdfValue> {
    let dict = HashMap<String, PdfValue>()
    dict.add("Type", PdfValue.PdfName("XObject"))
    dict.add("Subtype", PdfValue.PdfName("Image"))
    dict.add("Width", PdfValue.PdfInt(width))
    dict.add("Height", PdfValue.PdfInt(height))
    dict.add("ColorSpace", colorSpace)
    dict.add("BitsPerComponent", PdfValue.PdfInt(bits))
    dict
}

func imageStream(dict: HashMap<String, PdfValue>, raw: Array<UInt8>): PdfStream {
    PdfStream(dict, raw)
}

func imageHasPngSignature(png: Array<UInt8>): Bool {
    if (png.size < 8) {
        return false
    }
    let expected: Array<UInt8> = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    for (i in 0..8) {
        if (png[i] != expected[i]) {
            return false
        }
    }
    true
}

// ---------------------------------------------------------------------------
// PNG structure helpers (independent of the encoder's own implementation)

class ImagePngChunk {
    let kind: String
    let payload: Array<UInt8>
    let crc: Int64

    init(kind: String, payload: Array<UInt8>, crc: Int64) {
        this.kind = kind
        this.payload = payload
        this.crc = crc
    }
}

/** Walk the chunk list of a PNG, skipping the 8-byte signature. */
func imagePngChunks(png: Array<UInt8>): ArrayList<ImagePngChunk> {
    let chunks = ArrayList<ImagePngChunk>()
    var offset: Int64 = 8
    while (offset + 12 <= Int64(png.size)) {
        let length = imageUInt32(png, offset)
        let typeStart = offset + 4
        let dataStart = offset + 8
        let crcAt = dataStart + length
        if (crcAt + 4 > Int64(png.size)) {
            break
        }
        let kind = String.fromUtf8(png[typeStart..dataStart].toArray())
        let payload = if (length == 0) {
            Array<UInt8>()
        } else {
            png[dataStart..crcAt].toArray()
        }
        chunks.add(ImagePngChunk(kind, payload, imageUInt32(png, crcAt)))
        offset = crcAt + 4
    }
    chunks
}

func imageUInt32(data: Array<UInt8>, offset: Int64): Int64 {
    (Int64(data[offset]) << 24) |
        (Int64(data[offset + 1]) << 16) |
        (Int64(data[offset + 2]) << 8) |
        Int64(data[offset + 3])
}

/** Recompute every chunk CRC32 and compare it with the stored value. */
func imageChunkCrcsAreValid(png: Array<UInt8>): Bool {
    let chunks = imagePngChunks(png)
    var offset: Int64 = 8
    for (chunk in chunks) {
        let length = imageUInt32(png, offset)
        let covered = png[(offset + 4)..(offset + 8 + length)].toArray()
        if (imageCrc32(covered) != chunk.crc) {
            return false
        }
        offset = offset + 12 + length
    }
    true
}

func imageCrc32(data: Array<UInt8>): Int64 {
    var crc: Int64 = 0xFFFFFFFF
    for (byte in data) {
        crc = crc ^ Int64(byte)
        for (_ in 0..8) {
            if ((crc & 1) != 0) {
                crc = 0xEDB88320 ^ (crc >> 1)
            } else {
                crc = crc >> 1
            }
        }
    }
    crc ^ 0xFFFFFFFF
}

/** Inflate a PNG IDAT payload: strip the zlib header, then raw-deflate. */
func imageInflate(data: Array<UInt8>): Array<UInt8> {
    if (data.size <= 2) {
        return Array<UInt8>()
    }
    let input = ByteBuffer(data[2..data.size].toArray())
    let stream = DecompressInputStream(input, wrap: WrapType.DeflateFormat)
    let out = ArrayList<UInt8>()
    let buffer = Array<UInt8>(4096, repeat: 0)
    try {
        while (true) {
            let read = stream.read(buffer)
            if (read <= 0) {
                break
            }
            for (i in 0..read) {
                out.add(buffer[i])
            }
        }
    } finally {
        stream.close()
    }
    out.toArray()
}

// ---------------------------------------------------------------------------
// Probe document

/**
 * Write a unique probe PDF and open it.
 *
 * The path is unique per call (random token + sub-second nanoseconds) so two
 * concurrent `cjpm test` runs cannot read each other's file, and it is deleted
 * in the `finally` - `PdfDocument.open` reads the whole file into memory, so the
 * document stays usable.
 */
func imageProbeDocument(): PdfDocument {
    let token = Random().nextUInt32().toString() + "-" + DateTime.nowUTC().nanosecond.toString()
    let path = "/tmp/cangjie-image-probe-" + token + ".pdf"
    imageWriteProbePdf(path)
    try {
        return PdfDocument.open(path, None)
    } finally {
        removeIfExists(path)
    }
}

/** Minimal one-page PDF: no fonts, no drawing, US Letter. */
func imageWriteProbePdf(path: String): Unit {
    let content = "q Q"
    var text = "%PDF-1.4\n"
    let offsets = ArrayList<Int64>()
    offsets.add(Int64(text.size))
    text = text + "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
    offsets.add(Int64(text.size))
    text = text + "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
    offsets.add(Int64(text.size))
    text = text + "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Contents 4 0 R >>\nendobj\n"
    offsets.add(Int64(text.size))
    text = text + "4 0 obj\n<< /Length ${content.size} >>\nstream\n${content}\nendstream\nendobj\n"
    let xrefPosition = Int64(text.size)
    text = text + "xref\n0 5\n0000000000 65535 f \n"
    for (offset in offsets) {
        text = text + "${imagePadOffset(offset)} 00000 n \n"
    }
    text = text + "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n${xrefPosition}\n%%EOF\n"
    File.writeTo(path, text.toArray())
}

func imagePadOffset(value: Int64): String {
    var text = value.toString()
    while (text.size < 10) {
        text = "0" + text
    }
    text
}
