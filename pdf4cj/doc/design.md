# pdf4cj 设计文档

## 描述

`pdf4cj` 是一个纯仓颉实现的 PDF **结构解析与内容抽取**库：输入一个 PDF 文件的字节，输出文档级
元数据与逐页的结构化对象（字符、单词、矩形、线段、曲线、图片、表格）。它不含渲染器，也不做
字体子集化、数字签名、表单填充等写入侧功能。

设计目标按优先级排列：

1. **不依赖 C/FFI**：只允许 `std` 与 `stdx`（`compress.zlib`、`encoding.base64`）。
2. **坏文件不崩**：可恢复的问题降级为「少一点结果」，不可恢复的问题抛带上下文的 `PdfError`。
3. **坐标可对照**：结构与 pdfplumber 的命名和数值约定对齐，便于把已有的 Python 行为/黄金样本
   直接拿来当验收基线。
4. **可被上层复用**：库只产出数据对象（`PageData` 等），不做 JSON/CSV 序列化、不做 MCP 协议、
   不做文件落盘——这些留给调用方。

## 非目标

| 非目标 | 原因 / 现状 |
|--------|-------------|
| 渲染（光栅化、字形轮廓、字体程序执行） | 需要 TrueType/CFF 解释器与抗锯齿，完全超出「结构解析」范围；Type3 glyph 过程也不执行 |
| 加密文档解密 | 需要 RC4/AES 与标准安全处理器（含口令校验算法），v0.1.0 只检测不实现 |
| PDF 写入 / 编辑 / 合并 | 库是只读的；没有对象序列化与 xref 重建 |
| JPX / JBIG2 解码 | 需要 JPEG2000 与 JBIG2 解码器；当前以 `error` 明确拒答 |
| 数字签名、表单、注释、书签语义 | 只作为普通对象/流可读，不解释语义 |
| 增量/流式读取 | `PdfDocument.open` 一次读全文件；大文件内存下限 = 文件大小 |

## 模块分层

```
┌──────────────────────────────────────────────────────────────────────┐
│ 数据模型层   data.cj                                                │
│   PdfColor, CharObj, WordObj, RectObj, LineObj, CurveObj,            │
│   ImageObj, TableObj, PageData, FontStat, PdfMetadata                │
├──────────────────────────────────────────────────────────────────────┤
│ 抽取层       content.cj  text.cj  table.cj  image.cj                 │
│   extractPage → PageData；buildWords；extractTables；imagePayload     │
├──────────────────────────────────────────────────────────────────────┤
│ 字体层       font.cj  cmap.cj  metrics_data.cj  encoding_data.cj     │
│   PdfFont（码宽/Unicode/字宽）、ToUnicodeCMap、标准 14 字体表、编码表  │
├──────────────────────────────────────────────────────────────────────┤
│ 文档层       document.cj  page.cj                                    │
│   PdfDocument（页面树、metadata、值访问器）；PdfPage（框、资源、内容） │
├──────────────────────────────────────────────────────────────────────┤
│ 解析层       parser.cj  lexer.cj  filters.cj  object.cj              │
│   xref/ObjStm、间接对象与缓存、词法、流过滤器、PdfValue/PdfStream     │
└──────────────────────────────────────────────────────────────────────┘
```

依赖方向严格单向向下：抽取层只依赖文档层与数据模型，文档层只依赖解析层，解析层只依赖
`object.cj` 与 `std`/`stdx`。没有任何反向依赖，也没有全局可变状态（`PdfStream.decoded` 的
按流缓存除外，见「性能与安全护栏」）。

| 文件 | 职责 | 关键类型/函数 |
|------|------|---------------|
| `object.cj` | PDF 对象模型与错误类型 | `PdfValue`、`PdfStream`、`PdfError`、`describeValue`、`isPdfNull` |
| `lexer.cj` | 词法：数字、名字、字符串、数组、字典、关键字 | `PdfLexer` |
| `parser.cj` | 交叉引用、间接对象、对象流、解码缓存 | `PdfObjectParser` |
| `filters.cj` | 流过滤器链与 predictor | `decodeStreamData`、`decodeBytes`、`ascii85Decode` 等 |
| `document.cj` | 打开文档、页面树、metadata、值访问、字符串解码 | `PdfDocument` |
| `page.cj` | 单页的有效框/资源/内容 | `PdfPage`（含内部 `PageNodeInfo`） |
| `font.cj` | 字体解码（编码 → Unicode，码宽，字宽） | `PdfFont`、`loadFont`、`loadFontFromDict` |
| `cmap.cj` | `/ToUnicode` 与内嵌 CMap 解析、码空间查询 | `ToUnicodeCMap`、`parseToUnicode` |
| `metrics_data.cj` | 标准 14 字体宽度/ascent/descent | `Base14Metrics`、`base14Metrics` |
| `encoding_data.cj` | WinAnsi/MacRoman/Standard/PDFDoc 编码表、字形名映射 | `WIN_ANSI_ENCODING` 等 |
| `content.cj` | 内容流解释器（文本/图形/Form/内联图） | `extractPage`、`describeColor`、`formatDecimal` |
| `text.cj` | 字符 → 单词 | `buildWords` |
| `table.cj` | 有框线表格检测 | `extractTables` |
| `image.cj` | 图片识别、PNG 转码、base64 载荷 | `imagePayload`、`detectImageFormat`、`encodePng` |
| `data.cj` | 数据模型（本库对外的契约） | `PageData`、`CharObj`、`TableObj` 等 |

## 数据流

```
bytes ──► PdfLexer/PdfObjectParser ──► xref 表（经典 / stream / ObjStm / Prev）
                  │
                  ├─ trailer[/Root] ──► 目录 ──► /Pages 页面树遍历（继承 Resources/Box/Rotate）
                  │                                   │
                  │                                   ▼
                  │                              pageInfos: PageNodeInfo[]
                  ▼
        PdfValue 树（含 PdfStream.raw）
                  │  PdfDocument.streamData
                  ▼
        filters.decodeStreamData（Flate/LZW/A85/AHx/RL + predictor，按流缓存）
                  │
        ┌─────────┴──────────────────────────────┐
        ▼                                        ▼
  页面内容流（page.contents）              /Resources/Font ──► loadFont ──► PdfFont
        │                                                             │
        ▼   content.cj（CTM 栈 + 文本状态机）                          │
   chars / rects / lines / curves / images ◄──────────────────────────┘
        │
        ├─ buildWords(chars) ──────────────► words
        ├─ extractTables(page, PageData) ──► tables（矩形/线段 + chars 几何分析）
        └─ imagePayload(doc, ImageObj) ────► ImagePayload（base64 + mime + byteLength）
                                             │
                                             ▼
                                       PageData（上层取用）
```

一次典型的抽取（`extractPage`）：

1. `PdfObjectParser` 解析 xref（先找 `startxref`，失败则全文件扫描 `N G obj`）。
2. `PdfDocument.open` 遍历页面树，把每页的 `PageNodeInfo`（字典、合并后的 `/Resources`、
   `/MediaBox`、`/CropBox`、`/Rotate`）落在内存里。页面对象本身延迟到 `page(n)` 时构造。
3. `extractPage` 取 `page.contents`（`/Contents` 可以是单流或流数组，按序拼接并解码），
   逐 token 解释：文本算子产出 `CharObj`，路径算子产出 `RectObj`/`LineObj`/`CurveObj`，
   `Do` 进入 Form XObject（换新 CTM 与资源字典），内联图像产出 `ImageObj`。
4. 内容流跑完后，如果页面框原点不是 `(0,0)`，统一把每个对象平移 `-(x0, y0)`，保证坐标相对
   页面框原点（与 pdfplumber 一致）。
5. `buildWords` 在已平移的 `chars` 上切词，因此 `words` 的框与 `chars` 的框严格自洽。
6. `extractTables` 是**完全独立的第二阶段**：只读 `PageData` 里的 `rects`/`lines`/`chars`，
   不重新解释内容流。`extractPage` 返回的 `tables` 永远是空列表，由调用方放入。

## 坐标约定

| 对象 | 坐标系 | 说明 |
|------|--------|------|
| `chars`、`words`、`rects`、`lines`、`curves`、`images` | **PDF 用户空间**，但原点平移到页面框左下角 | `x0`/`y0` = 左下，`x1`/`y1` = 右上，y 向上。页面框原点非零时（如 `/MediaBox [0 100 612 892]`）已减去原点，数值与 pdfplumber 的 `x0`/`bottom` 可直接对照 |
| `tables` | **自上而下**的页面坐标 | `y0` = 表格上边，`y1` = 下边（`y0 < y1`），与 pdfplumber 的 `Table.bbox` 一致；x 与其它对象同向 |
| `PageData.width/height` | 页面框的**宽高**（不是右上角坐标） | `CropBox` 优先，回退 `MediaBox`，再回退 `[0 0 612 792]` |
| `PdfPage.rotate` | 原始 `/Rotate`，归一化到 `[0, 360)` | **不应用**：不交换宽高，也不旋转坐标 |

`CharObj` 的 `y0`/`y1` 是**基线偏移后的字形框**（`y0 = 基线 + descent * size`，
`y1 = y0 + size`），不是行框；因此字形框的高度就是 `size`，而 `y0` 会略低于基线。
例如 Helvetica 12pt、基线 700 得到 `697.52 .. 709.52`（`descent = -0.207`）。

## 错误模型

所有可预期的失败都用 `PdfError <: Exception`，消息面向使用者、带定位信息，且尽量包含「下一步
该怎么做」：

| 阶段 | 典型消息 |
|------|----------|
| 打开 | `cannot open PDF '<path>': the file is empty`、`... no %PDF- header and no readable cross-reference table` |
| 加密 | `password required or incorrect (pass the 'password' argument for encrypted PDFs): '<path>' is encrypted and the Cangjie engine does not support PDF decryption yet` |
| 页面树 | `cannot read the page tree: reference cycle at 6 0 R`、`... page-tree object 6 0 R is missing or unreadable`、`... /Pages node ... has no /Kids array` |
| 页码 | `page 99 is out of range (this document has 1 pages)` |
| 内容流 | `cannot read page 1 contents: the /Contents stream is missing or unreadable: <底层原因>` |
| 词法 | 未闭合字符串/字典/数组时抛带字节偏移的 `PdfError` |
| 解码器 | `ASCIIHexDecode: invalid byte 71`、`ASCII85Decode: invalid byte 12 at offset 7`、`LZWDecode: code 4097 is outside the dictionary`（`RunLengthDecode` 是唯一截断而不抛错的解码器） |
| 解码护栏 | `decoded stream exceeds the safety limit of 268435456 bytes` |

设计原则：

- **结构损坏宁可失败，不要半份数据**：页树引用环、悬空 `/Contents` 引用都抛错，而不是像某些
  实现那样静默截断成 1 页或空白页。合法空页树（`/Kids []`、`/Count 0`）仍正常返回 0 页。
- **单点损坏不拖垮整页**：单个坏字体、坏图片流被跳过（字体回退到默认字体，图片以
  `ImagePayload.error` 表达），页面其余内容照常返回。
- **图片永不抛异常**：`imagePayload` 把一切可恢复问题写进 `payload.error`。
- **未知过滤器/图片编解码器软失败**：`/Filter` 里不认识的过滤器原样透传，避免一个冷门过滤器
  让整页消失；调用方可以自己看 `/Filter`。

## 性能与安全护栏

恶意或畸形 PDF 的常见攻击面是「小文件要求巨大内存/巨大时间」，因此解析链路里设了显式上限：

| 护栏 | 值 | 位置 | 超限行为 |
|------|----|------|----------|
| 解码后单流字节数 | 256 MB | `filters.cj` | 抛 `PdfError` |
| 间接引用解析深度 | 32 | `parser.cj` | 停止跟随，按损坏处理 |
| 页面树嵌套深度 | 256 | `document.cj` | 抛 `PdfError` |
| 页面树引用环 | 活动集合检测 | `document.cj` | 抛 `PdfError`（`reference cycle at ...`） |
| Form XObject 嵌套深度 | 8 | `content.cj` | 停止递归，保留已解释内容 |
| CMap 映射条目 | 131072 / 每个 CMap | `cmap.cj` | 丢弃后续映射 |
| 图片像素数 | 67108864（`MAX_IMAGE_PIXELS = 1 << 26`）/ 每张图 | `image.cj` | `encodeImageStreamToPng` 返回 `None`、`encodePng` 返回空数组（`imagePayload` 转成 `error`） |
| 表格合并边数 | 4000 / 页 | `table.cj` | 整页返回空表格列表 |
| 表格单元格数 | 25000 / 连通分量 | `table.cj` | 跳过该分量，其它分量照常输出 |

图片像素上限的判定逻辑：`/Width`、`/Height` 来自 PDF 文件本身，既可能是
`4294967296 x 4294967296` 这种会让 `width * height` 溢出的值，也可能是看起来合理、实际把几 KB
文件放大成几百 MB 采样缓冲的尺寸。因此在**分配任何缓冲区之前**先按面积判定，且用除法
（`width <= MAX_IMAGE_PIXELS / height`）而不是乘法，避免溢出绕过。上限按像素而非解码字节计，
因为每种受支持的布局（1/8/16-bit，Gray/RGB/CMYK）每像素至少产生一个输出字节。

其它性能设计：

- **xref 一次性建表**：交叉引用存放在 `HashMap<Int64, XrefEntry>` 里，之后每次间接引用查找是
  哈希表查找（均摊 O(1)），命中对象缓存后连解析都省掉。
- **流解码按流缓存**：`PdfStream.decoded` 保证同一流在一次文档生命周期内只解码一次；含
  **间接** `/Filter` 或 `/DecodeParms` 的流不写缓存（该路径无法在此函数里解析引用）。
- **页面对象缓存**：`PdfDocument` 按页码缓存 `PdfPage`，重复抽取同一页不会重建页面信息。
- **不做全文回扫**：只有当 xref 表缺失或整体不可用时才回退全文件扫描。
- **排序用自底向上归并**：`text.cj` 的基线排序与阅读顺序排序都是 O(n log n) 且稳定，避免依赖
  已废弃的 `ArrayList.sort` 重载；表格检测用 `std.sort.sort` + 显式比较器。

## 依赖

| 依赖 | 用途 | 备注 |
|------|------|------|
| `std.collection` | `ArrayList`/`HashMap`/`HashSet` | 数据模型与缓存 |
| `std.fs.File` | `readFrom` 读整份 PDF | 唯一 IO 入口 |
| `std.io` | `ByteBuffer` | 给 zlib 解压喂输入 |
| `stdx.compress.zlib` | Flate 解压与 PNG 的 IDAT 压缩 | 二进制依赖，经 `${CANGJIE_STDX_PATH}` 解析 |
| `stdx.encoding.base64` | 图片载荷 base64 | 同上 |

`cjpm.toml` 的 `bin-dependencies` 为 5 个平台分别写了 `${CANGJIE_STDX_PATH}/...` 路径；
`scripts/setup-stdx.sh` 负责下载 Linux x64 的包，其它平台按脚本注释里的链接自取。

## 扩展点

按「改动最小」排序，后续演进基本都落在这几个位置：

| 想做的事 | 落点 |
|----------|------|
| 标准安全处理器（RC4/AES 解密） | `document.cj::open` 的 `/Encrypt` 分支 + 新的 `crypto.cj`；解密后的对象走 `parser.cj` 的解析入口 |
| JPX / JBIG2 支持 | `image.cj::imagePayload` 的分支；`encodePng` 已是通用编码器，可直接复用 |
| `/Rotate` 与裁剪路径 | `content.cj` 的最终 `shiftToBoxOrigin` 阶段扩展为「变换阶段」，或在 `extractPage` 尾部加矩阵/路径过滤 |
| 无框线表格 | `table.cj` 新增一种「边来源」（文字对齐/空白投影），与现有 `TableEdge` 管线共用 snap/merge |
| 增量/流式读取 | `parser.cj` 的字节访问抽象（当前直接持有 `Array<UInt8>`）；`PdfStream.raw` 需改为惰性读取 |
| 新的过滤器 | `filters.cj::applyFilter` 的 `match` 加分支 + 对应的 `xxxDecode` |
| 更精确的单词切分（方向、标点、连字） | `text.cj`（`buildWords` 的签名不变，参数化容差即可） |
| 输出 JSON/CSV | 不应放进本库：由上层（如 MCP 服务）消费 `PageData` 自行序列化 |

## 展示示例

下面的片段是独立 cjpm 工程里的完整文件（`package` 名要与该工程 `cjpm.toml` 的
`[package] name` 一致，否则 cjpm 会报 `package name ... is wrong`；工程需声明
`pdf4cj = { path = "../pdf4cj" }`）。最小可用流程（与 `example/src/main.cj` 同构）：

```cangjie
package demo

import std.collection.*
import pdf4cj.*

main() {
    let document = PdfDocument.open("tests/fixtures/table.pdf")
    try {
        let page = document.page(1)
        let data = extractPage(document, page)
        let tables = extractTables(page, data)
        println("words=${data.words.size} tables=${tables.size}")
        for (table in tables) {
            for (row in table.cells) {
                println(row.size)
            }
        }
    } finally {
        document.close()
    }
}
```

直接使用底层对象（读取任意 `/Info` 项）：

```cangjie
package demo

import std.collection.*
import pdf4cj.*

main() {
    let document = PdfDocument.open("tests/fixtures/text.pdf")
    try {
        for ((key, value) in document.info) {
            let text = match (document.asText(value)) {
                case Some(decoded) => decoded
                case None => "-"
            }
            println("${key} = ${text}")
        }
    } finally {
        document.close()
    }
}
```
