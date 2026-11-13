<div align="center">
<h1>pdf4cj</h1>
</div>

<p align="center">
<img alt="" src="https://img.shields.io/badge/release-v0.1.0-brightgreen" style="display: inline-block;" />
<img alt="" src="https://img.shields.io/badge/cjc-v1.0.0-brightgreen" style="display: inline-block;" />
<img alt="" src="https://img.shields.io/badge/state-孵化-brightgreen" style="display: inline-block;" />
<img alt="" src="https://img.shields.io/badge/domain-Data%2FDocument-brightgreen" style="display: inline-block;" />
<img alt="" src="https://img.shields.io/badge/points-?/100-brightgreen" style="display: inline-block;" />
</p>

- points 将由官方团队给出
- 本库**不提供**覆盖率数据，因此不展示 cjcov 徽章；测试规模见「[测试与验证](#测试与验证)」

## 介绍

`pdf4cj` 是一个**纯仓颉实现的 PDF 结构解析库**：读取 PDF 文件的字节，解析对象模型与交叉引用，
解释页面内容流，输出**字符、单词、矩形、线段、曲线、图片、表格**等结构化数据。

它解决的核心问题是：在仓颉生态里没有可用的 PDF 解析组件，任何「读一份 PDF 里的文字/表格/图片」
的需求都得落到 C 库（mupdf / poppler）再接 FFI。`pdf4cj` 从零实现解析链路，**没有 C 源码、
没有手写 FFI、没有外部动态库**，整个仓库只依赖 `std` 与 `stdx` 的 `compress.zlib`、
`encoding.base64`，用 `cjpm build` 即可产出 `libpdf4cj.so`，其它仓颉工程按 `path` 依赖直接使用。

适用领域：

- **PDF 预览**：按字符/图形坐标自己渲染，或把坐标交给前端 canvas；
- **文档分析**：按字体、字号、颜色统计版面，抽取标题/正文/表格；
- **RAG 预处理**：把 PDF 切成单词/表格单元，喂给向量库或大模型；
- **Agent 工具**：作为 MCP / 函数调用工具的后端，返回 JSON 化的页面结构；
- **数据抽取**：报表、发票、对账单里的有框线表格转成二维字符串数组。

### 项目特性

- **交叉引用全形态**：经典 xref 表、`/Prev` 增量更新链、xref stream（`/Type /XRef`，支持
  `/W`、`/Index`、PNG predictor）、对象流 `/ObjStm`；损坏的 xref 会回退到全文件扫描。
- **流过滤器**：`FlateDecode`（含 PNG/TIFF predictor）、`LZWDecode`（EarlyChange 0/1）、
  `ASCII85Decode`、`ASCIIHexDecode`、`RunLengthDecode`，以及链式过滤器数组。
- **字体与编码**：简单字体（`/Type1`、`/TrueType`、`/MMType1`、`/Type3`）的
  `/Widths`、`/Differences`、base encoding；复合字体（`/Type0`）的 `/W`、`/DW`、`Identity-H/V`
  与内嵌 CMap 码空间；`/ToUnicode` CMap（`bfchar`/`bfrange`/`codespacerange`）；
  标准 14 字体的宽度表与 WinAnsi / MacRoman / Standard / PDFDoc 编码表。
- **内容流解释**：文本状态（`Tf`/`Td`/`TD`/`Tm`/`T*`/`Tz`/`Ts`/`Tc`/`Tw`/`TL`）、
  `Tj`/`TJ`/`'`/`"`、路径与图形（`re`/`m`/`l`/`c`/`v`/`y`/`h`、`f`/`S`/`B` 系列）、
  `cm`/`q`/`Q` 图形栈、`Do` Form XObject（深度上限 8）、内联图像 `BI`/`ID`/`EI`。
- **图片**：`DCTDecode`（JPEG）、`/Subtype /Image` 原始采样（1/8/16-bit、Gray/RGB/CMYK/ICCBased）
  由库内**手写 PNG 编码器**转成 PNG（签名 / IHDR / IDAT / IEND + CRC32，zlib 压缩）；
  JPX / JBIG2 明确报错而不是返回不可显示的字节；声明尺寸受 `MAX_IMAGE_PIXELS`（1 << 26 像素）限制。
- **表格**：按 pdfplumber 默认策略识别**有框线**表格（矩形边 + 横竖线 → snap/merge →
  连通分量 → 单元格），单元格文本按行拼接，容差与上限见「约束与限制」。
- **单词切分**：按基线分行、按空白与水平间隙切词，输出阅读顺序。
- **可预期的错误模型**：所有可预见的失败抛 `PdfError` 并带上下文（路径、页码、字节偏移、
  对象号），不会静默返回半份数据；单个坏字体/坏图片只降级该对象，不拖垮整页。

### 项目计划

| 里程碑 | 内容 | 状态 |
|--------|------|------|
| v0.1.0 | 解析内核 + 字体 + 内容流 + 单词 + 有框线表格 + 图片 PNG 转码，77 个用例 | 已完成 |
| v0.2.0 | 标准安全处理器（RC4 40/128-bit、AES-128/256）解密 | 计划中 |
| v0.2.x | JPX（JPEG2000）/ JBIG2 解码或外置转码接口 | 计划中 |
| v0.3.0 | `/Rotate` 坐标变换、裁剪路径 `W`/`W*` 生效 | 计划中 |
| v0.3.x | 无框线表格（按空白/文字对齐推断网格） | 计划中 |
| v0.4.0 | 增量解析（mmap/按需读取）、对象缓存与内存上限 | 计划中 |
| 持续 | 更多真实 PDF 的回归语料、性能基准、异常样本 | 持续 |

## 项目架构

```
      bytes
        │  lexer.cj + parser.cj           对象模型 / 交叉引用 / 对象流
        ▼
   PdfValue 树  ──►  filters.cj            Flate / LZW / ASCII85 / ASCIIHex / RunLength
        │
        ▼  document.cj + page.cj           页面树、继承属性、资源字典、metadata
    PdfPage
        │  font.cj + cmap.cj               编码 → Unicode，码宽，字宽
        ▼
   content.cj（内容流解释器）              MT(矩阵) × CTM → 字符/路径/图片
        │
        ├──► text.cj                      chars  → words
        ├──► table.cj                     rects/lines + chars → tables
        └──► image.cj                     ImageObj → ImagePayload(PNG/JPEG/GIF/WebP)
        ▼
     PageData  { chars, words, rects, lines, curves, images, tables }
```

分层与数据流的完整说明见 [doc/design.md](./doc/design.md)。

### 源码目录

```shell
.
├── README.md                  # 整体介绍（本文件）
├── README.OpenSource          # 开源合规元数据（JSON）
├── CHANGELOG.md               # 版本记录
├── LICENSE                    # MIT
├── .gitattributes             # fixtures 标为 binary，避免行尾转换破坏 xref
├── cjpm.toml                  # 包配置：dynamic 库，依赖 stdx(zlib/base64)
├── doc
│   ├── design.md              # 设计文档：分层、数据流、坐标约定、护栏
│   └── feature_api.md         # 稳定 public API 的签名与语义
├── src                        # 源码目录（package pdf4cj）
│   ├── object.cj              # PdfValue / PdfStream / PdfError 对象模型
│   ├── lexer.cj               # PDF 词法与基本对象解析（数字/名字/字符串/数组/字典）
│   ├── parser.cj              # 交叉引用（表/xref stream/ObjStm/Prev）、间接对象、缓存
│   ├── filters.cj             # 流过滤器与 predictor
│   ├── document.cj            # PdfDocument：打开、页面树、metadata、字符串解码
│   ├── page.cj                # PdfPage：CropBox/MediaBox/Rotate/Resources/Contents
│   ├── font.cj                # PdfFont：简单字体与 Type0 的文本/宽度解码
│   ├── cmap.cj                # ToUnicode CMap / 码空间解析与查询
│   ├── metrics_data.cj        # 标准 14 字体宽度与 ascent/descent 表
│   ├── encoding_data.cj       # WinAnsi/MacRoman/Standard/PDFDoc 编码表、字形名→Unicode
│   ├── content.cj             # 内容流解释器：extractPage
│   ├── text.cj                # buildWords：chars → words
│   ├── table.cj               # extractTables：有框线表格检测
│   ├── image.cj               # imagePayload / detectImageFormat / encodePng
│   ├── data.cj                # 数据模型：CharObj/WordObj/RectObj/.../PageData
│   └── test                   # 单元测试（cjpm test 的 77 个用例）
├── example                    # 可编译示例（独立 cjpm 模块）
│   ├── cjpm.toml
│   ├── src/main.cj            # 打印 metadata / 页面对象统计 / 单词 / 表格 / 图片
│   └── README.md
├── tests
│   ├── README.md              # fixtures 清单、来源与重生成方式
│   ├── generate_fixtures.py   # 重新生成语料的脚本（reportlab + Pillow）
│   ├── pdf_fixtures.py        # 生成脚本调用的 PDF 构造辅助模块
│   ├── requirements.txt       # 仅开发期依赖（reportlab / Pillow）
│   └── fixtures               # 15 个 PDF 回归语料（含 xref stream、加密、损坏样本）
├── scripts
│   ├── setup-stdx.sh          # 下载并解包 cangjie-stdx 1.0.0.1
│   └── make-submission-zip.sh # 生成 TPC 提交用的 dist/pdf4cj.zip
└── contrib                    # Cangjie-TPC 项目申请材料
    ├── PROJECT_PROPOSAL.md    # STEP 1「项目创建申请」issue 内容
    ├── email-template.md      # 给 cangjie@huawei.com 的申请邮件
    └── PR_TEMPLATE.md         # 后续 PR 的标题/正文模板
```

### 接口说明

主要类与函数接口见 [API 文档](./doc/feature_api.md)。核心入口只有四个：

| 入口 | 作用 |
|------|------|
| `PdfDocument.open(path)` / `PdfDocument.open(path, password)` | 打开文档（读全文件到内存），解析页面树 |
| `extractPage(doc, page): PageData` | 解释一页内容流，得到 chars/words/rects/lines/curves/images |
| `extractTables(page, data): ArrayList<TableObj>` | 从已提取的图形与字符里识别有框线表格 |
| `imagePayload(doc, image): ImagePayload` | 把页面上的图片转成可显示的 base64 载荷 |

## 使用说明

### 编译构建

工具链与依赖（版本是硬要求，低版本编译不过）：

| 组件 | 版本 | 说明 |
|------|------|------|
| Cangjie 工具链 | **LTS 1.0.0** | `cjc` / `cjpm`，通过 `cjv` 安装 |
| cangjie-stdx | **1.0.0.1** | 只用 `compress.zlib`、`encoding.base64` 两个包 |
| 平台 | Linux x86_64（已验证） | cjpm.toml 已列出 aarch64 Linux / macOS / Windows 的路径，但未在本仓库验证 |

```shell
# 1. 安装/确认 LTS 1.0.0（已安装会提示）
~/.cjv/bin/cjv install lts-1.0.0

# 2. 准备 stdx：下载并解包到 pdf4cj/stdx/（幂等，已存在则跳过）
bash scripts/setup-stdx.sh

# 3. 让 cjpm 找到 stdx（每个新 shell 都要设）
export CANGJIE_STDX_PATH="$(pwd)/stdx/cangjie-stdx-linux-x64-1.0.0.1"

# 4. 构建（输出 target/release/pdf4cj/libpdf4cj.so）
~/.cjv/bin/cjv run lts-1.0.0 cjpm build

# 5. 单元测试（77 个用例）
~/.cjv/bin/cjv run lts-1.0.0 cjpm test
```

`${CANGJIE_STDX_PATH}` 在 `cjpm.toml` 的 `bin-dependencies` 里按平台展开；其它平台请从
[cangjie-stdx-bin v1.0.0.1](https://gitcode.com/Cangjie/cangjie-stdx-bin/releases/tag/v1.0.0.1)
下载对应的包解压到 `pdf4cj/stdx/`，再把 `CANGJIE_STDX_PATH` 指向解压目录。

作为依赖使用（本仓库 `cangjie/` 子项目就是这么接的）：

```toml
[dependencies]
  pdf4cj = { path = "../pdf4cj" }
```

`pdf4cj` 的 `output-type` 是 `dynamic`，所以**运行期**还要让加载器找得到 `libpdf4cj.so`
（以及仓颉运行时与 stdx 的 `.so`）：用 `cjpm run` 时它自己会设好；直接执行构建产物时需要手工给
`LD_LIBRARY_PATH`，具体写法见 [example/README.md](./example/README.md#运行)。

### 功能示例

以下代码片段都在 `example/` 里实际编译运行过，输出取自 `tests/fixtures/` 的 fixture。
每个片段都是一个**完整文件**（`package` + `import` + `main`），是照着建一个独立 cjpm 工程的最小
形态：把 `package demo` 换成你工程的包名即可，但包名必须与 `cjpm.toml` 的 `[package] name` 一致
（不一致时 cjpm 会报 `package name ... is wrong`），工程里还要声明
`pdf4cj = { path = "../pdf4cj" }` 依赖；可对照 [`example/cjpm.toml`](./example/cjpm.toml) 与
[`example/src/main.cj`](./example/src/main.cj)。

#### 示例 1：读取文档元数据

```cangjie
package demo

import std.collection.*
import pdf4cj.*

main() {
    let document = PdfDocument.open("tests/fixtures/text.pdf")
    let metadata = document.metadata()
    println("pages=${metadata.pages} version=${metadata.version} encrypted=${metadata.encrypted}")
    println("size=${formatDecimal(metadata.pageW, 2)}x${formatDecimal(metadata.pageH, 2)}pt")
    println("fonts=${metadata.fonts.size}")
    document.close()
}
```

执行结果：

```shell
pages=1 version=1.3 encrypted=false
size=612.00x792.00pt
fonts=1
```

`metadata()` 一次给出页数、版本、首页尺寸、`/Info` 的 Title/Author/Producer 和去重排序后的
`/BaseFont` 名字；它不解释内容流，所以对任何能打开的文件都很快。

#### 示例 2：抽取一页的字符、单词与图形

```cangjie
package demo

import std.collection.*
import pdf4cj.*

main() {
    let document = PdfDocument.open("tests/fixtures/table.pdf")
    let page = document.page(1)
    let data = extractPage(document, page)
    println("chars=${data.chars.size} words=${data.words.size} rects=${data.rects.size} lines=${data.lines.size}")
    var shown = 0
    for (word in data.words) {
        if (shown >= 3) {
            break
        }
        println("'${word.text}' at (${formatDecimal(word.x0, 2)}, ${formatDecimal(word.y0, 2)}) size=${formatDecimal(word.size, 2)}")
        shown += 1
    }
    document.close()
}
```

执行结果：

```shell
chars=22 words=6 rects=1 lines=2
'Header' at (60.00, 697.93) size=10.00
'A' at (95.57, 697.93) size=10.00
'Header' at (210.00, 697.93) size=10.00
```

`chars` 是字形（glyph cluster）级别，`words` 由 `buildWords` 按基线分组、按空白与间隙切分得到，
顺序是阅读顺序（基线降序、`x0` 升序）。

#### 示例 3：识别有框线表格

```cangjie
package demo

import std.collection.*
import pdf4cj.*

main() {
    let document = PdfDocument.open("tests/fixtures/table.pdf")
    let page = document.page(1)
    let data = extractPage(document, page)
    let tables = extractTables(page, data)
    println("tables=${tables.size}")
    for (table in tables) {
        println("${table.rows}x${table.cols} top=${formatDecimal(table.y0, 2)}")
        for (row in table.cells) {
            for (cell in row) {
                print("[${cell}]")
            }
            println("")
        }
    }
    document.close()
}
```

执行结果：

```shell
tables=1
2x2 top=62.00
[Header A][Header B]
[][Row B1]
```

`extractTables` 不重新解释内容流，而是在 `PageData` 的矩形/线段/字符上做几何分析；返回的
`TableObj` 用**自上而下**的 y 坐标（与 pdfplumber 一致），与 `chars`/`words` 的用户空间坐标不同，
详见 [doc/design.md](./doc/design.md#坐标约定)。

#### 示例 4：把图片取成可显示载荷

```cangjie
package demo

import std.collection.*
import pdf4cj.*

main() {
    let document = PdfDocument.open("tests/fixtures/image.pdf")
    let page = document.page(1)
    let data = extractPage(document, page)
    for (image in data.images) {
        let payload = imagePayload(document, image)
        match (payload.error) {
            case Some(reason) => println("image failed: ${reason}")
            case None =>
                println("${image.streamId}: ${payload.mimeType} ${payload.byteLength} bytes, base64 ${payload.base64.size} chars")
        }
    }
    document.close()
}
```

执行结果：

```shell
p1_img_0: image/png 72 bytes, base64 96 chars
```

`imagePayload` **不抛异常**：无法显示的格式（JPX / JBIG2）或缺少数据时把原因写进
`payload.error`，调用方渲染占位图即可继续处理该页。

完整可运行版本见 [`example/`](./example)：

```shell
cd example
export CANGJIE_STDX_PATH="$(cd .. && pwd)/stdx/cangjie-stdx-linux-x64-1.0.0.1"
~/.cjv/bin/cjv run lts-1.0.0 cjpm run --run-args "../tests/fixtures/table.pdf 1"
```

## 测试与验证

```shell
cd pdf4cj
export CANGJIE_STDX_PATH="$(pwd)/stdx/cangjie-stdx-linux-x64-1.0.0.1"
~/.cjv/bin/cjv run lts-1.0.0 cjpm test
```

当前检出（Linux x86_64 / LTS 1.0.0 / stdx 1.0.0.1）：**77 个用例，PASSED 77，FAILED 0，
SKIPPED 0**（61 个原有单测 + 1 个图片像素上限用例 + 15 个 fixture 语料用例）。

| 测试文件 | 用例数 | 覆盖 |
|----------|--------|------|
| `src/test/content_test.cj` | 10 | 单词切分、格式化辅助、手写内容流的 `extractPage` 端到端 |
| `src/test/document_test.cj` | 8 | 空页树、截断文档、页树引用环、悬空 `/Contents`、`/Length` 越界与可恢复 |
| `src/test/font_test.cj` | 22 | CMap、编码表、宽度、标准 14 字体、Type0 |
| `src/test/image_test.cj` | 12 | 魔数识别、PNG/JPEG 透传、原始采样转 PNG、`/Decode`、非法布局、声明尺寸超过像素上限 |
| `src/test/table_test.cj` | 10 | 有框线网格、空单元格、多行单元格、分离网格、无线文本 |
| `src/test/fixtures_test.cj` | 15 | 每个 fixture 至少一条端到端断言（页数/单词/表格/图片格式/损坏文件错误消息） |

回归语料是 `tests/fixtures/` 下的 15 个 PDF（reportlab + Pillow 确定性生成，另含手写
xref stream/ObjStm 与损坏样本），清单与重生成方式见 [tests/README.md](./tests/README.md)。
本库**不提供覆盖率数字**，所以仓库里没有 cjcov 报告，README 也不展示覆盖率徽章。

## 约束与限制

以下是**明确未实现或有意收紧**的行为，不是「已支持但没说」。完整差异清单见上游
[MCP 仓库的 cangjie/README.md](https://github.com/EthanCheung-gh/pdf-inspector-mcp/blob/main/cangjie/README.md)。

| 限制 | 说明 |
|------|------|
| **加密文档** | 只检测 `/Encrypt`，**不支持解密**。`open` 一律失败，`password` 参数目前只是接口占位。 |
| **JPX / JBIG2 图片** | 不转码，`imagePayload` 返回 `error: Unsupported image format: jpx/jbig2`。`DCTDecode` 的 JPEG 原样返回。 |
| **`/Rotate` 不应用** | 页面 `width`/`height` 不交换，所有坐标保持**未旋转**的用户空间；`page.rotate` 只做信息暴露。 |
| **CID 字体无 `/ToUnicode`** | 文本为空串（没有内嵌字体程序就无法从 CID 得到 Unicode），宽度仍按 `/W`/`/DW` 正确计算。 |
| **裁剪路径不生效** | `W`/`W*` 只记录不执行，裁剪区域外的对象仍会出现。 |
| **无框线表格** | 只识别矩形边与横竖线构成的闭合网格；纯空白对齐的表格不识别。 |
| **表格阈值** | snap 容差 2.5pt、最短边 3.0pt、直线容差 0.5pt。合并后**整页**边数 > 4000 时该页直接返回空表格列表；单个连通分量的单元格数 > 25000 时只跳过该分量，同页其它表格照常返回。 |
| **图片像素上限** | 单张图片上限 `MAX_IMAGE_PIXELS = 1 << 26`（约 6700 万像素）。`/Width`/`/Height` 来自文件、不可信，所以先按面积（用除法避免乘法溢出）判定再分配：超限时 `encodeImageStreamToPng` 返回 `None`、`encodePng` 返回空数组，`imagePayload` 转成 `Unsupported image format: unknown`。 |
| **坐标约定** | `chars`/`words`/`rects`/`lines`/`curves`/`images` 用 PDF 用户空间（原点在页面框左下角，y 向上），并按页面框原点平移；`tables` 用自上而下的 y。 |
| **整文件入内存** | `open` 用 `File.readFrom` 读全文件，内存占用下限约等于文件大小；解码后单流上限 256 MB。 |
| **浮点噪声** | `size` 取自字形框高度，可能出现 `12.000000000000002`；坐标末位也可能与其它实现不同，比较时用容差。 |
| **单词切分是近似** | 基线容差 1.0、水平间隙 3.0；没有 `upright`/方向处理（旋转文本按水平处理），没有 `keep_blank_chars`/`split_at_punctuation` 选项。 |
| **类型 3 / 竖排** | Type3 只通过 encoding 与 `/ToUnicode` 映射，不执行 glyph 过程；`Identity-V`、`/W2` 按横排读取。 |
| **内联图像 `EI` 是启发式** | 极端二进制数据里出现 `EI` 仍可能误判。 |
| **平台** | 只在 Linux x86_64 + LTS 1.0.0 上验证过。 |

## 开源协议

[MIT License](./LICENSE)

## 参与贡献

欢迎提交 PR、Issue，或任何形式的贡献。

- 本项目按 [Cangjie-TPC 社区贡献指南](https://gitcode.com/Cangjie-TPC) 的流程申请与维护：
  STEP 1 项目创建申请（见 [`contrib/PROJECT_PROPOSAL.md`](./contrib/PROJECT_PROPOSAL.md)、
  [`contrib/email-template.md`](./contrib/email-template.md)），后续提交走
  [`contrib/PR_TEMPLATE.md`](./contrib/PR_TEMPLATE.md) 的格式。
- 首次贡献前请签署 **CLA**（Cangjie 社区贡献者许可协议）。
- 提交前请在本地跑通 `cjpm build` 与 `cjpm test`（77 个用例应全绿），并保持
  `src/test/` 的用例与 `tests/fixtures/` 的语料同步更新。
- 修改 `tests/fixtures/` 下的二进制 PDF 时请用 `tests/README.md` 里的脚本重新生成，
  **不要手改字节**（xref 偏移会失效）。
