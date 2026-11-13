# [0.1.0]

首个公开版本：从 `pdf-inspector-mcp` 的仓颉实现中抽出的独立 PDF 解析库
（`package pdf4cj`，输出 `libpdf4cj.so`）。

## Feature

+ **对象模型与交叉引用**：`PdfValue`（null/bool/int/real/string/name/array/dict/ref/stream）、
  `PdfStream`、`PdfError`；经典 xref 表、`/Prev` 增量链、xref stream（`/W`、`/Index`、PNG predictor）、
  对象流 `/ObjStm`，xref 损坏时回退全文件扫描
+ **流过滤器**：`FlateDecode`（含 1/2/10/11/12/13/14/15 predictor）、`LZWDecode`（EarlyChange）、
  `ASCII85Decode`、`ASCIIHexDecode`、`RunLengthDecode`，支持过滤器数组串联；解码单流上限 256 MB
+ **文档与页面**：`PdfDocument.open(path[, password])`、页面树遍历与继承属性
  （`/Resources`、`/MediaBox`、`/CropBox`、`/Rotate`）、`metadata()`、`page(n)`、`box()`、
  值访问器 `resolve`/`asDict`/`asArray`/`asName`/`asInt`/`asNumber`/`asText`/`streamData`
+ **字体**：简单字体（`/Type1`、`/TrueType`、`/MMType1`、`/Type3`）的 `/Widths`、`/Widths` 区间、
  `/Differences` 与 base encoding；`/Type0` 的 `/W`、`/DW`、`Identity-H/V` 与内嵌 CMap 码空间；
  `/ToUnicode` CMap（`bfchar`/`bfrange`/`codespacerange`）；标准 14 字体宽度表与
  WinAnsi/MacRoman/Standard/PDFDoc 编码表
+ **内容流解释**：文本状态与文本显示算子、路径构造与填充/描边、图形栈 `q`/`Q`、`cm` CTM、
  `Do` Form XObject（嵌套深度上限 8）、内联图像 `BI`/`ID`/`EI`
+ **结构化输出**：`extractPage` 产出 `PageData`（`chars`/`words`/`rects`/`lines`/`curves`/`images`），
  `buildWords` 按基线（1.0pt）与水平间隙（3.0pt）切词并输出阅读顺序
+ **表格**：`extractTables` 按 pdfplumber 默认策略识别有框线表格（矩形边 + 横竖线 → snap/merge →
  连通分量 → 单元格），单元格文本按行拼接，整页边数上限 4000、单连通分量单元格上限 25000
+ **图片**：`imagePayload` 输出 base64 载荷，`detectImageFormat` 按魔数识别 PNG/JPEG/GIF/WebP/JPX/JBIG2，
  原始采样（Gray/RGB/CMYK/ICCBased，1/8/16-bit，`/Decode` 支持）由手写 PNG 编码器
  （签名 + IHDR + IDAT + IEND + CRC32）转码；JPX/JBIG2 以 `error` 返回不抛异常；
  单张图片按 `MAX_IMAGE_PIXELS`（1 << 26）限制声明尺寸，超限在分配前拒绝
+ **示例与材料**：`example/` 可编译示例（metadata / 页面对象 / 表格 / 图片）、
  `doc/design.md`、`doc/feature_api.md`、`tests/README.md`、`tests/generate_fixtures.py`
  （本地重建语料）、`contrib/` 的 TPC 项目申请材料、`scripts/make-submission-zip.sh`

## Bugfix

+ 无（首个版本）

## Remove

+ 无（首个版本）

## Known Limitations

+ **不解密**：检测到 `/Encrypt` 即失败；`password` 参数只是接口占位，RC4/AES 标准安全处理器未实现
+ **JPX / JBIG2 不解码**：`imagePayload` 返回 `Unsupported image format: jpx` / `jbig2`
+ **`/Rotate` 不应用**：页面尺寸不交换，`chars`/`words`/图形坐标保持未旋转的用户空间
+ **裁剪路径不生效**：`W`/`W*` 只记录不执行
+ **CID 字体无 `/ToUnicode` 时文本为空**：宽度仍按 `/W`/`/DW` 计算
+ **无框线表格不识别**：只支持矩形边与横竖线构成的闭合网格；阈值（snap 2.5、最短边 3.0、
  直线容差 0.5）与 pdfplumber 默认值不完全相同
+ **整文件读入内存**：`open` 一次性 `File.readFrom`，内存下限约等于文件大小；没有增量解析
+ **单词切分是近似**：无 `upright`/方向处理，无 `keep_blank_chars`/`split_at_punctuation` 选项
+ **超大图片不解码**：声明尺寸超过 `MAX_IMAGE_PIXELS`（1 << 26 像素）的图片以
  `Unsupported image format: unknown` 拒绝，而不是尝试分配缓冲区
+ **只验证 Linux x86_64 + Cangjie LTS 1.0.0 + cangjie-stdx 1.0.0.1**

## Tests

`cjpm test`：**77 个用例，PASSED 77，FAILED 0，SKIPPED 0**
（61 个原有单测 + 1 个图片像素上限用例 + 15 个 fixture 语料用例）。

| 文件 | 用例数 | 覆盖 |
|------|--------|------|
| `src/test/content_test.cj` | 10 | 单词切分、格式化辅助、手写内容流的 `extractPage` 端到端 |
| `src/test/document_test.cj` | 8 | 空页面树、截断文档、页树引用环、悬空 `/Contents`、`/Length` 越界与可恢复 |
| `src/test/font_test.cj` | 22 | CMap、编码表、宽度、标准 14 字体、Type0 |
| `src/test/image_test.cj` | 12 | 魔数识别、PNG/JPEG 透传、原始采样转 PNG、`/Decode`、非法布局、声明尺寸超过像素上限 |
| `src/test/table_test.cj` | 10 | 有框线网格、空单元格、多行单元格、分离网格、无线文本 |
| `src/test/fixtures_test.cj` | 15 | 每个 fixture 至少一条端到端断言（页数/单词/表格/图片格式/损坏文件错误消息） |

<br>
