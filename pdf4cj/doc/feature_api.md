# pdf4cj 特性接口文档

本文档列出 `package pdf4cj` 的全部 public API。全部接口位于单一包内，使用方式：

```cangjie
import pdf4cj.*
```

## 稳定性分级

| 级别 | 含义 | 章节 |
|------|------|------|
| **稳定** | 对外承诺的接口，破坏性变更走主版本号 | [PdfDocument](#pdfdocument)、[PdfPage](#pdfpage)、[抽取入口](#抽取入口)、[数据模型](#数据模型)、[图片载荷](#图片载荷) |
| **进阶** | 稳定但偏内部/偏底层，正常使用抽取入口时无需直接调用 | [字体解码](#字体解码)、[底层对象](#底层对象与工具函数)、[图片编码器](#图片编码器) |
| **底层** | 解析器/词法/过滤器/编码表：给需要自己走一遍解析链路的调用方，不保证跨版本兼容 | [过滤器](#过滤器)、[解析器与词法](#解析器与词法)、[内置表数据](#内置表数据) |

约定：

- 所有函数**不修改**入参（`extractPage` 会把结果写进新建的 `PageData`）；
- 所有失败都是 `PdfError`（`PdfError <: Exception`），除 `imagePayload` 明确不抛异常外；
- 坐标与单位的约定见 [design.md](./design.md#坐标约定)。

---

## PdfDocument

### 类描述

一份已加载的 PDF：交叉引用/对象访问、页面树、文档元数据。`open` 会把**整个文件读入内存**，
因此没有需要释放的 OS 文件句柄；`close` 只把文档标记为已关闭，用于表达会话生命周期。

加密文档会在打开阶段直接失败：`/Encrypt` 只检测、不解密（v0.1.0 未实现标准安全处理器）。

### 类 API

```cangjie
public class PdfDocument {
    public static func open(path: String): PdfDocument
    public static func open(path: String, password: Option<String>): PdfDocument

    public prop pageCount: Int64
    public prop version: String
    public prop encrypted: Bool
    public prop info: HashMap<String, PdfValue>

    public func page(number: Int64): PdfPage
    public func metadata(): PdfMetadata

    public func resolve(value: PdfValue): PdfValue
    public func resolutionError(value: PdfValue): Option<String>
    public func asDict(value: PdfValue): Option<HashMap<String, PdfValue>>
    public func asArray(value: PdfValue): Option<ArrayList<PdfValue>>
    public func asName(value: PdfValue): Option<String>
    public func asInt(value: PdfValue): Option<Int64>
    public func asNumber(value: PdfValue): Option<Float64>
    public func asText(value: PdfValue): Option<String>
    public func streamData(stream: PdfStream): Array<UInt8>

    public func close(): Unit
    public func isClosed(): Bool
    public func objectCacheSize(): Int64
    public func xrefSize(): Int64
}
```

### `open`

```cangjie
/*
* 打开一个 PDF 文件并解析其交叉引用与页面树。
* 参数 path-文件路径；不做 ~user 展开，空字符串会直接报错
* 参数 password-加密文档的口令。v0.1.0 只用于接口占位：
*              传与不传都会因为"引擎不支持解密"而失败
* 返回 可用的 PdfDocument；页面对象在 page(n) 时惰性构造
* 异常 PdfError-路径为空、文件不存在/不可读、文件为空、不是 PDF、
*               交叉引用与全文件扫描都失败、页面树损坏或有引用环、文档加密
*/
public static func open(path: String): PdfDocument
public static func open(path: String, password: Option<String>): PdfDocument
```

`open(path)` 等价于 `open(path, None)`。

典型错误消息：

```text
cannot open PDF 'a.pdf': the file is empty
cannot open PDF 'a.pdf': no %PDF- header and no readable cross-reference table
cannot open PDF 'a.pdf': cannot read the page tree: reference cycle at 3 0 R
password required or incorrect (pass the 'password' argument for encrypted PDFs): 'a.pdf' is encrypted and the Cangjie engine does not support PDF decryption yet
```

### `pageCount` / `version` / `encrypted` / `info`

```cangjie
/*
* pageCount-页面树里的页数；合法空页树（/Kids [] 或 /Count 0）返回 0 而不是报错
* version-文件头的 PDF 版本，如 "1.7"；没有 %PDF- 头时为 "unknown"
* encrypted-trailer 里是否有 /Encrypt（能检测，不能解密）
* info-文档信息字典 /Info 的原始条目（未解码的 PdfValue，用 asText 取文本）
*/
public prop pageCount: Int64
public prop version: String
public prop encrypted: Bool
public prop info: HashMap<String, PdfValue>
```

### `page`

```cangjie
/*
* 按 1-based 页码取页面对象；同一页重复获取返回同一个缓存的 PdfPage
* 参数 number-页码，从 1 开始
* 返回 PdfPage
* 异常 PdfError-页码越界（消息含文档页数）
*/
public func page(number: Int64): PdfPage
```

### `metadata`

```cangjie
/*
* 汇总文档级信息，不解释任何内容流，因此对"能打开的文件"都很快。
* 返回 PdfMetadata：pages/version/encrypted、首页 pageW/pageH、
*      /Info 的 Title/Author/Producer（缺失时为空串）、
*      所有页 /Resources/Font 里的 /BaseFont 名字（去重 + 升序）
*/
public func metadata(): PdfMetadata
```

### 值访问器

```cangjie
/*
* resolve-沿交叉引用跟随间接引用，得到最终值；无法解析时返回 PdfNull
* resolutionError-当 resolve 返回 PdfNull 时，给出底层解析失败原因（诊断用）
* asDict/asArray/asName/asInt/asNumber/asText-先 resolve 再按类型取值，
*     类型不符返回 None（不抛异常）；asInt 接受 PdfReal 并截断，asText 支持
*     UTF-16BE/LE BOM 与 PDFDocEncoding
* streamData-按 /Filter + /DecodeParms 解码流，并缓存到 PdfStream.decoded
* 参数 value-任意 PdfValue，可以直接传间接引用
* 异常 streamData 在解码失败或超限时抛 PdfError
*/
public func resolve(value: PdfValue): PdfValue
public func resolutionError(value: PdfValue): Option<String>
public func asDict(value: PdfValue): Option<HashMap<String, PdfValue>>
public func asArray(value: PdfValue): Option<ArrayList<PdfValue>>
public func asName(value: PdfValue): Option<String>
public func asInt(value: PdfValue): Option<Int64>
public func asNumber(value: PdfValue): Option<Float64>
public func asText(value: PdfValue): Option<String>
public func streamData(stream: PdfStream): Array<UInt8>
```

### `close` / `isClosed` / 诊断计数

```cangjie
/*
* close-标记文档已关闭；之后继续调用读取接口不会自动报错，
*       是否使用 isClosed 判断由调用方决定（库内不做强制校验）
* isClosed-是否已 close
* objectCacheSize-已缓存的间接对象数量，用于诊断内存占用
* xrefSize-交叉引用表条目数量，用于诊断
*/
public func close(): Unit
public func isClosed(): Bool
public func objectCacheSize(): Int64
public func xrefSize(): Int64
```

---

## PdfPage

### 类描述

一页的有效属性。继承来的属性（`/Resources`、`/MediaBox`、`/CropBox`、`/Rotate`）在页面树遍历
阶段已经合并好，这里拿到的是**最终生效值**。

`width`/`height` 优先取 `/CropBox`，其次 `/MediaBox`，都没有时用 PDF 默认的
`[0 0 612 792]`；`/Rotate` 单独暴露，**不交换**宽高。

### 类 API

```cangjie
public class PdfPage {
    public prop number: Int64
    public prop width: Float64
    public prop height: Float64
    public prop rotate: Int64
    public prop resources: HashMap<String, PdfValue>
    public prop contents: Array<UInt8>

    public func box(): Array<Float64>
}
```

```cangjie
/*
* number-页码，1-based
* width/height-页面框宽高（pt），不随 /Rotate 交换
* rotate-/Rotate 归一化到 [0, 360)；只暴露，不应用
* resources-合并后的 /Resources 字典（原始 PdfValue，可用 document.asDict 取值）
* contents-解码后的内容流；/Contents 是流数组时按顺序用 '\n' 拼接
*             没有 /Contents 时返回空数组
* 异常 contents 在 /Contents 缺失/不可读时抛 PdfError
*          （消息含底层原因，避免把损坏误判成空白页）
*/
public prop number: Int64
public prop width: Float64
public prop height: Float64
public prop rotate: Int64
public prop resources: HashMap<String, PdfValue>
public prop contents: Array<UInt8>

/*
* 返回有效页面框 [x0, y0, x1, y1]；无框时返回 [0.0, 0.0, 612.0, 792.0]
*/
public func box(): Array<Float64>
```

---

## 抽取入口

### `extractPage`

```cangjie
/*
* 解释一页的内容流，产出结构化的 PageData。
* 参数 doc-拥有该页的文档（用于解析资源与解码流）
* 参数 page-由 doc.page(n) 取得的页面
* 返回 PageData：chars/words/rects/lines/curves/images 已填充；
*      tables 恒为空（表格检测是独立的第二阶段，见 extractTables）
* 异常 PdfError-内容流词法损坏（未闭合字符串/字典/数组）时抛出，
*               消息带字节偏移；单个坏字体或坏图片不会失败，会被跳过
*/
public func extractPage(doc: PdfDocument, page: PdfPage): PageData
```

说明：

- `/Rotate` 不应用，所有坐标都在未旋转的页面空间；
- 页面框原点非零时，所有对象坐标会平移 `-(box.x0, box.y0)`；
- `words` 在平移后的 `chars` 上计算，两者框严格自洽；
- Form XObject 递归深度上限 8，内联图像 `BI`/`ID`/`EI` 支持。

### `buildWords`

> 进阶：签名稳定，但语义是 pdfplumber `extract_words` 的近似实现，边界排版可能与其不同。

```cangjie
/*
* 把字符分组成单词。
* 参数 chars-字符列表；text 为空的字形会被忽略
* 返回 单词列表，按阅读顺序（y1 降序、x0 升序）排列；词内字符保持输入顺序
* 规则-基线差 <= 1.0pt 视为同一行；空白字形与水平间隙 > 3.0pt 断词；
*      不支持 upright/方向处理，也不做连字展开
*/
public func buildWords(chars: ArrayList<CharObj>): ArrayList<WordObj>
```

### `extractTables`

```cangjie
/*
* 从已抽取的图形与字符里识别"有框线"表格。
* 参数 page-用于取页面高度与页码
* 参数 data-extractPage 的返回值；本函数不修改它
* 返回 表格列表，按自上而下、同高按左到右排序；没有表格时返回空列表
* 规则-矩形四条边 + 横竖线 → 容差 2.5pt 聚类合并 → 相交边归并成连通分量
*      → 四边齐备的矩形才成为单元格（至少 2x2 才算表格）；
*      单页合并边 > 4000 或单分量单元格 > 25000 时放弃该页/该分量
*/
public func extractTables(page: PdfPage, data: PageData): ArrayList<TableObj>
```

---

## 数据模型

本库对外的数据契约（`src/data.cj`）。所有类都是可变字段 + 全默认值的命名参数构造器，方便逐步
填充与测试。

### `PdfColor`

```cangjie
public enum PdfColor {
    | Gray(Float64)
    | Rgb(Float64, Float64, Float64)
    | Cmyk(Float64, Float64, Float64, Float64)
    | Named(String)
}
```

`Gray` 是 0..1 的灰度；`Rgb`/`Cmyk` 是 0..1 的分量；`Named` 用于默认值（如 `"black"`）。

### `CharObj`

```cangjie
/*
* 参数 text-字形的 Unicode 文本（无法映射时为空串）
* 参数 x0/y0/x1/y1-字形框，PDF 用户空间，y 向上；y0 低于基线（基线 + descent*size）
* 参数 fontname-/BaseFont 名字，可能带子集前缀 "ABCDEF+"
* 参数 size-字号（pt）= 字形框高度，是 Tf 字号乘有效矩阵缩放；可能有浮点噪声
* 参数 color-填充色
* 参数 page-1-based 页码
*/
public class CharObj {
    public var text: String
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var fontname: String
    public var size: Float64
    public var color: PdfColor
    public var page: Int64

    public init(
        text!: String = "", x0!: Float64 = 0.0, y0!: Float64 = 0.0,
        x1!: Float64 = 0.0, y1!: Float64 = 0.0,
        fontname!: String = "", size!: Float64 = 0.0,
        color!: PdfColor = PdfColor.Named("black"), page!: Int64 = 0
    )
}
```

### `WordObj`

```cangjie
/*
* 与 CharObj 同构，去掉 color，增加"多个字符合并后的框"语义：
* x0/x1 取字符框并集，fontname/size 取词内第一个字符的值
*/
public class WordObj {
    public var text: String
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var fontname: String
    public var size: Float64
    public var page: Int64

    public init(
        text!: String = "", x0!: Float64 = 0.0, y0!: Float64 = 0.0,
        x1!: Float64 = 0.0, y1!: Float64 = 0.0,
        fontname!: String = "", size!: Float64 = 0.0, page!: Int64 = 0
    )
}
```

### `RectObj`

```cangjie
/*
* 参数 fill-由实际绘制算子决定（f/F/f*/B/B*/b/b* 为 true，S/s 为 false）
* 参数 stroke-是否被描边
* 参数 color-填充色（描边色不单独暴露）
* 参数 width-线宽（pt）
*/
public class RectObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var fill: Bool
    public var stroke: Bool
    public var color: PdfColor
    public var width: Float64
    public var page: Int64

    public init(
        x0!: Float64 = 0.0, y0!: Float64 = 0.0, x1!: Float64 = 0.0, y1!: Float64 = 0.0,
        fill!: Bool = false, stroke!: Bool = false,
        color!: PdfColor = PdfColor.Named("black"), width!: Float64 = 0.0, page!: Int64 = 0
    )
}
```

### `LineObj`

```cangjie
/* 一条直连线；stroke 默认 true，width 为线宽（pt） */
public class LineObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var stroke: Bool
    public var color: PdfColor
    public var width: Float64
    public var page: Int64

    public init(
        x0!: Float64 = 0.0, y0!: Float64 = 0.0, x1!: Float64 = 0.0, y1!: Float64 = 0.0,
        stroke!: Bool = true, color!: PdfColor = PdfColor.Named("black"),
        width!: Float64 = 0.0, page!: Int64 = 0
    )
}
```

### `CurveObj`

```cangjie
/*
* 一条 Bezier 曲线；x0/y0/x1/y1 是控制点包围盒，
* points 是控制点序列，每个元素是 [x, y]（2 元素）
*/
public class CurveObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var points: Array<Array<Float64>>
    public var stroke: Bool
    public var page: Int64

    public init(
        x0!: Float64 = 0.0, y0!: Float64 = 0.0, x1!: Float64 = 0.0, y1!: Float64 = 0.0,
        points!: Array<Array<Float64>> = Array<Array<Float64>>(),
        stroke!: Bool = true, page!: Int64 = 0
    )
}
```

### `ImageObj`

```cangjie
/*
* 参数 x0/y0/x1/y1-图片在页面上的位置（受 CTM 影响）
* 参数 width/height-图片的原始像素尺寸（来自 /Width、/Height），不是显示尺寸
* 参数 streamId-稳定标识，形如 "p<页码>_img_<序号>"，可用来回查图片
* 参数 format-内容层判断的格式（可能为空串，最终格式以 imagePayload 为准）
* 参数 imageData-已解码的原始字节句柄，通常为 None
* 参数 imageStream-底层流对象，交给 imagePayload 选择解码路径
*/
public class ImageObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var width: Float64
    public var height: Float64
    public var streamId: String
    public var format: String
    public var page: Int64
    public var imageData: Option<Array<UInt8>>
    public var imageStream: Option<PdfStream>

    public init(
        x0!: Float64 = 0.0, y0!: Float64 = 0.0, x1!: Float64 = 0.0, y1!: Float64 = 0.0,
        width!: Float64 = 0.0, height!: Float64 = 0.0,
        streamId!: String = "", format!: String = "", page!: Int64 = 0,
        imageData!: Option<Array<UInt8>> = None, imageStream!: Option<PdfStream> = None
    )
}
```

### `TableObj`

```cangjie
/*
* 参数 x0/y0/x1/y1-表格包围盒，y 轴自上而下（y0 是上边）
* 参数 rows/cols-行列数（= cells.size 与每行长度）
* 参数 cells-单元格文本，cells[r][c]；单元格内多行用 '\n' 连接
* 参数 page-1-based 页码
*/
public class TableObj {
    public var x0: Float64
    public var y0: Float64
    public var x1: Float64
    public var y1: Float64
    public var rows: Int64
    public var cols: Int64
    public var cells: Array<Array<String>>
    public var page: Int64

    public init(
        x0!: Float64 = 0.0, y0!: Float64 = 0.0, x1!: Float64 = 0.0, y1!: Float64 = 0.0,
        rows!: Int64 = 0, cols!: Int64 = 0,
        cells!: Array<Array<String>> = Array<Array<String>>(), page!: Int64 = 0
    )
}
```

### `PageData`

```cangjie
/*
* 一页的抽取结果。tables 永远由调用方填入（extractTables 的返回值），
* extractPage 不会填它。
*/
public class PageData {
    public var width: Float64
    public var height: Float64
    public var chars: ArrayList<CharObj>
    public var words: ArrayList<WordObj>
    public var rects: ArrayList<RectObj>
    public var lines: ArrayList<LineObj>
    public var curves: ArrayList<CurveObj>
    public var images: ArrayList<ImageObj>
    public var tables: ArrayList<TableObj>

    public init(width!: Float64 = 0.0, height!: Float64 = 0.0)
}
```

### `PdfMetadata`

```cangjie
/*
* 文档级信息；title/author/producer 缺失时为空串，fonts 为去重升序的 /BaseFont 名
*/
public class PdfMetadata {
    public var pages: Int64
    public var version: String
    public var encrypted: Bool
    public var pageW: Float64
    public var pageH: Float64
    public var title: String
    public var author: String
    public var producer: String
    public var fonts: ArrayList<String>

    public init(
        pages!: Int64 = 0, version!: String = "unknown", encrypted!: Bool = false,
        pageW!: Float64 = 0.0, pageH!: Float64 = 0.0,
        title!: String = "", author!: String = "", producer!: String = "",
        fonts!: ArrayList<String> = ArrayList<String>()
    )
}
```

### `FontStat`

```cangjie
/*
* 单字体聚合统计（供上层"字体分析"功能使用，本库不负责跨页聚合）：
* pages-出现过的页码、charCount-字符数、sizeMin/sizeMax-字号范围、
* colors-出现过的颜色描述（describeColor 的文本形式）
*/
public class FontStat {
    public var fontname: String
    public var pages: ArrayList<Int64>
    public var charCount: Int64
    public var sizeMin: Float64
    public var sizeMax: Float64
    public var colors: ArrayList<String>

    public init(
        fontname!: String = "", pages!: ArrayList<Int64> = ArrayList<Int64>(),
        charCount!: Int64 = 0, sizeMin!: Float64 = 0.0, sizeMax!: Float64 = 0.0,
        colors!: ArrayList<String> = ArrayList<String>()
    )
}
```

---

## 图片载荷

### `ImagePayload`

```cangjie
/*
* 图片的可传输形式：base64 + MIME + 字节数；失败时 error 有值而 base64 为空。
*/
public class ImagePayload {
    public var base64: String = ""      // 纯 base64，不含 data: 前缀
    public var format: String = ""      // "png" / "jpeg" / "gif" / "webp"
    public var mimeType: String = ""    // 对应 MIME，未知时为 application/octet-stream
    public var byteLength: Int64 = 0    // 解码后原始字节数
    public var error: Option<String> = None
}
```

### `imagePayload`

```cangjie
/*
* 把页面上的图片转成可显示载荷。本函数不抛异常：所有可恢复问题写进 payload.error。
* 参数 doc-拥有该图片的文档
* 参数 image-extractPage 得到的 ImageObj
* 返回 ImagePayload：
*   - PNG/JPEG/GIF/WebP 原样透传（format 为检测到的格式）
*   - 原始采样（无魔数）用库内 PNG 编码器转码，format="png"
*   - JPX/JBIG2 返回 error="Unsupported image format: jpx|jbig2"
*   - 无数据返回 error="No stream data available"
*   - 不支持的采样布局返回 error="Unsupported image format: unknown"
*   - /Width * /Height 超过 MAX_IMAGE_PIXELS（文件声明的尺寸不可信）同样返回
*     error="Unsupported image format: unknown"，不会分配到内存
*/
public func imagePayload(doc: PdfDocument, image: ImageObj): ImagePayload
```

### `detectImageFormat`

```cangjie
/*
* 按魔数识别格式。
* 参数 data-原始字节
* 返回 Some("png"|"jpeg"|"gif"|"webp"|"jpx"|"jbig2")；
*      无魔数（通常是原始像素采样）时返回 None
*/
public func detectImageFormat(data: Array<UInt8>): Option<String>
```

### `imageMimeType`

```cangjie
/*
* 格式名到 MIME 的映射；png/jpeg/jpg/gif/webp 有对应值，
* 其它（含 jpx/jbig2）返回 "application/octet-stream"
*/
public func imageMimeType(format: String): String
```

### 图片编码器

> 进阶：`encodePng` 是通用 PNG 编码器，`encodeImageStreamToPng` 负责 PDF 采样布局 → 像素。
> 两者共享同一个像素上限 `MAX_IMAGE_PIXELS`（`1 << 26`，约 6700 万像素）：尺寸来自 PDF 文件的
> `/Width`/`/Height`，不可信，所以先按面积判定再分配缓冲区；判定用除法（`width <= limit / height`）
> 以免 `width * height` 溢出。

```cangjie
/* 单张图片允许展开的最大像素数：1 << 26（约 67M，相当于 8192 x 8192 的整页扫描） */
public let MAX_IMAGE_PIXELS: Int64 = 1 << 26

/*
* 把 8-bit 像素编码成 PNG 文件（签名 + IHDR + IDAT + IEND，CRC32 齐全）。
* 参数 width/height-像素尺寸；必须为正，且 width * height <= MAX_IMAGE_PIXELS
* 参数 channels-1（灰度，colour type 0）或 3（RGB，colour type 2）
* 参数 pixels-按行排列的 8-bit 采样；长度不足时右侧/底部补 0
* 返回 PNG 字节；尺寸/通道非法或超过 MAX_IMAGE_PIXELS 时返回空数组（不抛异常）
*/
public func encodePng(width: Int64, height: Int64, channels: Int64, pixels: Array<UInt8>): Array<UInt8>

/*
* 把一个 /Subtype /Image 流按 PDF 采样布局转成 PNG。
* 支持 DeviceGray / DeviceRGB / DeviceCMYK(转 RGB) / ICCBased(N=1/3/4)，
* 1/8/16 bit，支持 /Decode 反转；
* Indexed/Separation/DeviceN/Lab/Pattern、非法位深、或仍带 codec filter 的流返回 None。
* /Width 或 /Height 非正、或面积超过 MAX_IMAGE_PIXELS 时同样返回 None：
* 尺寸由文件控制，因此在分配任何采样缓冲区之前就拒绝。
*/
public func encodeImageStreamToPng(doc: PdfDocument, stream: PdfStream): Option<Array<UInt8>>
```

---

## 字体解码

> 进阶：`extractPage` 内部已经走完这条链路；只有在做字体分析或自定义文本抽取时才需要直接使用。

### `PdfFont`

```cangjie
public class PdfFont {
    public prop name: String
    public prop isCid: Bool
    public prop ascent: Float64
    public prop descent: Float64
    public prop hasToUnicode: Bool

    public func codeLength(bytes: Array<UInt8>, offset: Int64): Int64
    public func decode(bytes: Array<UInt8>, offset: Int64): (Int64, String)
    public func width(code: Int64): Float64
}
```

```cangjie
/*
* name-/BaseFont 原名（可能带子集前缀）；无名字时为 "unknown"
* isCid-是否 /Type0 复合字体（多字节码）
* ascent/descent-以 em 为单位，descent 恒 <= 0；Symbol/ZapfDingbats 为 0
* hasToUnicode-是否成功解析出 /ToUnicode CMap
* codeLength-返回 offset 处字符代码的字节长度（简单字体恒为 1）
* decode-返回 (代码, Unicode 文本)；无法映射时文本为空串；越界返回 (0, "")
* width-返回字形前进宽度（1/1000 em）；
*       未知代码回退 /MissingWidth 或 /DW（默认 1000）
*/
public prop name: String
public prop isCid: Bool
public prop ascent: Float64
public prop descent: Float64
public prop hasToUnicode: Bool
public func codeLength(bytes: Array<UInt8>, offset: Int64): Int64
public func decode(bytes: Array<UInt8>, offset: Int64): (Int64, String)
public func width(code: Int64): Float64
```

### `loadFont` / `loadFontFromDict`

```cangjie
/*
* 从一个 /Font 字典构造字体。
* 参数 doc-用于解析引用与解码流的文档
* 参数 fontDict-未解析的字体字典（通常来自 page.resources["Font"]）
* 返回 PdfFont
* 异常 PdfError-字典不含 /Subtype、/BaseFont、/Widths、/DescendantFonts 中任一项
*/
public func loadFont(doc: PdfDocument, fontDict: HashMap<String, PdfValue>): PdfFont

/*
* 同 loadFont，但把"解析引用"和"解码流"作为闭包传入，便于在无文档时单测。
* 参数 resolver-跟随间接引用的函数，通常是 { v => doc.resolve(v) }
* 参数 decoder-解码流的函数，通常是 { s => doc.streamData(s) }
*/
public func loadFontFromDict(
    fontDict: HashMap<String, PdfValue>,
    resolver: (PdfValue) -> PdfValue,
    decoder: (PdfStream) -> Array<UInt8>
): PdfFont
```

### `ToUnicodeCMap` / `parseToUnicode`

```cangjie
public class ToUnicodeCMap {
    public func lookup(code: Int64): Option<String>
    public func lookupCid(code: Int64): Option<Int64>
    public prop mappedCount: Int64
    public prop hasCodespaces: Bool
    public func codeByteLength(bytes: Array<UInt8>, offset: Int64): Int64
    public func defaultByteLength(): Int64
}

/*
* 解析 /ToUnicode CMap 流（bfchar / bfrange / codespacerange）。
* 参数 bytes-已解码的 CMap 流字节
* 返回 可直接查询的 CMap；映射条目超过 131072 时丢弃后续条目
* 不抛异常：无法识别的段落被忽略
*/
public func parseToUnicode(bytes: Array<UInt8>): ToUnicodeCMap

/*
* UTF-16BE 字节序列转字符串（代理对合法时合并），供 CMap 目标值解码使用。
*/
public func utf16beToString(bytes: Array<UInt8>): String
```

```cangjie
/*
* lookup-Unicode 文本；没有映射时 None
* lookupCid-CID（仅内嵌 encoding CMap 有）
* mappedCount-已映射的代码数量
* hasCodespaces-是否存在 codespacerange（决定码宽推断方式）
* codeByteLength-返回 offset 处代码的字节长度（最长匹配）；无法匹配返回 0
* defaultByteLength-码空间里最短的码宽；没有 codespacerange 时返回 0
*/
```

### `Base14Metrics` / `base14Metrics`

```cangjie
public class Base14Metrics {
    public let fontName: String
    public let firstChar: Int64
    public let widths: Array<Int64>
    public let ascent: Float64
    public let descent: Float64

    public init(
        fontName: String, firstChar: Int64, widths: Array<Int64>,
        ascent: Float64, descent: Float64
    )

    public func width(code: Int64): Int64
    public func stringWidth(codes: Array<Int64>): Int64
}

/*
* 按名字（含别名与子集前缀）查标准 14 字体度量，找不到返回 None
*/
public func base14Metrics(name: String): Option<Base14Metrics>

/*
* 把标准 14 字体的别名规范化成规范名，例如 "Arial" -> "Helvetica"、
* "Arial-BoldMT" -> "Helvetica-Bold"；非标准字体原样返回
*/
public func normalizeBase14Name(name: String): String
```

---

## 底层对象与工具函数

> 进阶：`PdfValue`/`PdfStream` 是解析层的公共表示，配合 `PdfDocument` 的访问器可以直接读任意
> 对象；`describeColor`/`formatDecimal` 只是格式化辅助。

### `PdfValue`

```cangjie
public enum PdfValue {
    | PdfNull
    | PdfBool(Bool)
    | PdfInt(Int64)
    | PdfReal(Float64)
    | PdfString(Array<UInt8>)          // 原始字节，解码用 document.asText
    | PdfName(String)                 // 不含前导 '/'，#xx 已解码
    | PdfArray(ArrayList<PdfValue>)
    | PdfDict(HashMap<String, PdfValue>)
    | PdfRef(Int64, Int64)            // 对象号、generation，用 resolve 跟随
    | PdfStream(PdfStreamPayload)     // 别名 == PdfStream
}

public type PdfStreamPayload = PdfStream
```

### `PdfStream`

```cangjie
public class PdfStream {
    public let dict: HashMap<String, PdfValue>
    public let raw: Array<UInt8>              // stream 与 endstream 之间的原始字节
    public var decoded: Option<Array<UInt8>>  // 解码缓存，经 streamData 填充
    public init(dict: HashMap<String, PdfValue>, raw: Array<UInt8>)
}
```

### `PdfError`

```cangjie
/*
* 本库唯一的异常类型，携带面向使用者的可读消息。
* 注意：在本工具链下对异常调用 toString() 可能 aborts，打印时只用 e.message。
*/
public class PdfError <: Exception {
    public init(message: String)
    public override func getClassName(): String
}
```

### 辅助函数

```cangjie
/*
* 值的有界、浅层渲染，仅用于诊断/日志，不用于解析
* 例：/Name、<array 3>、12 0 R、null
*/
public func describeValue(v: PdfValue): String

/* 判断值是否 PDF null（调用方需先 resolve） */
public func isPdfNull(v: PdfValue): Bool

/*
* 颜色的文本形式，3 位小数；例：Rgb(1.000,0.000,0.000)、Named(black)
*/
public func describeColor(color: PdfColor): String

/*
* 定点格式化浮点数（四舍五入、补零），用于日志与示例输出
*/
public func formatDecimal(value: Float64, digits: Int64): String
```

---

## 过滤器

> 底层：正常情况下由 `document.streamData` 调用；只有在处理裸字节流时才需要直接用。

```cangjie
/*
* /Filter 可以是单个名字或名字数组；缺失/其它类型返回空列表
*/
public func filterNames(value: PdfValue): ArrayList<String>

/*
* 解码一个流（带按流缓存）。含间接 /Filter 或 /DecodeParms 时不写缓存。
* 异常 PdfError-解码后字节超过 256 MB
*/
public func decodeStreamData(stream: PdfStream): Array<UInt8>

/*
* 用给定的 /Filter 与 /DecodeParms 值解码裸字节；未知过滤器原样透传。
* DCTDecode/JPXDecode/JBIG2Decode/CCITTFaxDecode/Crypt 一律透传。
*/
public func decodeBytes(raw: Array<UInt8>, filterValue: PdfValue, parmsValue: PdfValue): Array<UInt8>

/* 下面三个解码器遇到非法输入会抛 PdfError（与本文"所有失败都是 PdfError"一致），
* 且在经 decodeBytes / decodeStreamData / document.streamData 调用时直接向上传播：
* - asciiHexDecode：非十六进制、非空白的字节 -> "ASCIIHexDecode: invalid byte N"；
*   '>' 是结束符（PDF 十六进制串的终止符），遇到即提前返回；奇数个十六进制数字补 0；
* - ascii85Decode：'!'..'u' 之外的字节 -> "ASCII85Decode: invalid byte N at offset M"；
*   'z' 简写与 '~>' 结束符照常处理（'~>' 只属于 ASCII85，与上面的 '>' 不同）；
* - lzwDecode：码字超出码表 -> "LZWDecode: code N is outside the dictionary"，
*   首个码就是码表尺寸 -> "LZWDecode: invalid first code N"。
*/
public func asciiHexDecode(data: Array<UInt8>): Array<UInt8>
public func ascii85Decode(data: Array<UInt8>): Array<UInt8>

/*
* RunLengthDecode：四个最小解码单元里唯一"截断而不抛错"的一个——
* 128 视为结束；字面量段或重复段越过缓冲区末尾时按已有字节停止。
*/
public func runLengthDecode(data: Array<UInt8>): Array<UInt8>

/*
* LZW 解码；earlyChange 取 0 或 1（/EarlyChange 缺失时为 1）。
* 异常 PdfError-码表外的码、首个码不是字面量（见上）
*/
public func lzwDecode(data: Array<UInt8>, earlyChange: Int64): Array<UInt8>
```

---

## 解析器与词法

> 底层：一般不需要直接构造。适合"想自己遍历对象、或在不建页面树的情况下读结构"的场景。

### `PdfObjectParser`

```cangjie
public class PdfObjectParser {
    public let data: Array<UInt8>
    public var trailer: HashMap<String, PdfValue>
    public var version: String
    public init(data: Array<UInt8>)

    public func parseIndirectObjectAt(offset: Int64): PdfValue
    public func resolve(value: PdfValue): PdfValue
    public func resolveRef(num: Int64, gen: Int64): PdfValue
    public func resolutionError(value: PdfValue): Option<String>
    public func resolveDictEntry(entries: HashMap<String, PdfValue>, key: String): Option<PdfValue>
    public func decodeResolved(stream: PdfStream): Array<UInt8>
    public func cacheSize(): Int64
    public func xrefSize(): Int64
    public func rootValue(): Option<PdfValue>
    public func infoEntries(): HashMap<String, PdfValue>
}
```

```cangjie
/*
* init-立刻解析文件尾部、建立交叉引用（失败时回退全文件扫描），
*      并把 trailer 与 version 填好
* parseIndirectObjectAt-从给定字节偏移解析一个 "N G obj ... endobj"
* resolve/resolveRef-跟随间接引用，深度上限 32
* resolveDictEntry-等价于 resolve 后取 dict 里的 key
* decodeResolved-先解析 /Filter /DecodeParms 的引用，再解码
* rootValue-trailer 的 /Root（已 resolve）
* infoEntries-/Info 字典条目（已 resolve），缺失时为空 map
*/
public init(data: Array<UInt8>)
public func parseIndirectObjectAt(offset: Int64): PdfValue
public func resolve(value: PdfValue): PdfValue
public func resolveRef(num: Int64, gen: Int64): PdfValue
public func resolutionError(value: PdfValue): Option<String>
public func resolveDictEntry(entries: HashMap<String, PdfValue>, key: String): Option<PdfValue>
public func decodeResolved(stream: PdfStream): Array<UInt8>
public func cacheSize(): Int64
public func xrefSize(): Int64
public func rootValue(): Option<PdfValue>
public func infoEntries(): HashMap<String, PdfValue>
```

### `PdfLexer`

```cangjie
public class PdfLexer {
    public let data: Array<UInt8>
    public var pos: Int64
    public init(data: Array<UInt8>, pos!: Int64 = 0)

    public func size(): Int64
    public func eof(): Bool
    public func position(): Int64
    public func setPosition(value: Int64): Unit
    public func peek(): Int64
    public func peekAt(offset: Int64): Int64
    public func advance(): Unit
    public func skipWhitespace(): Unit
    public func peekKeyword(keyword: String): Bool
    public func matchKeyword(keyword: String): Bool
    public func requireKeyword(keyword: String, context: String): Unit
    public func readKeywordToken(): Option<String>

    public func parseValue(): PdfValue
    public func parseName(): String
    public func parseLiteralString(): Array<UInt8>
    public func parseHexString(): Array<UInt8>
    public func parseArray(): ArrayList<PdfValue>
    public func parseDictionary(): HashMap<String, PdfValue>
}
```

```cangjie
/*
* peek/peekAt-返回字节值（0..255），越界返回 -1
* peekKeyword-不移动位置地比较后续关键字
* matchKeyword-匹配则消费关键字并返回 true
* requireKeyword-匹配则消费，否则抛 PdfError（消息含 context 与位置）
* readKeywordToken-读一个裸 token（如 "obj"、"stream"）
* parseValue-解析任意基本对象（引用、字典、数组、字符串、数字、名字、布尔、null）
* 异常 PdfError-字符串/字典/数组未闭合、名字非法、数字格式错误等
*/
```

---

## 内置表数据

> 底层：这些是编码表常量，供实现与少量自定义映射场景使用，一般不需要直接读。

```cangjie
/* 256 项的编码表：code -> Unicode 文本（未映射为空串） */
public let WIN_ANSI_ENCODING: Array<String>
public let MAC_ROMAN_ENCODING: Array<String>
public let STANDARD_ENCODING: Array<String>
public let PDF_DOC_ENCODING: Array<String>

/* 字形名（如 "Aacute"、"uni4E2D"）转 Unicode；无法识别返回 None */
public func glyphNameToUnicode(name: String): Option<String>
```

---

## 相关文档

- [design.md](./design.md)：分层、数据流、坐标约定、错误模型、护栏、扩展点
- [../README.md](../README.md)：介绍、构建、示例
- [../tests/README.md](../tests/README.md)：fixtures 清单与重生成方式
