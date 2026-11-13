# 【项目创建申请】pdf4cj：纯仓颉 PDF 结构解析库

> 用途：按 [Cangjie-TPC 社区贡献指南](https://gitcode.com/Cangjie-TPC) 的
> **STEP 1** 在 Cangjie-TPC 社区提交「项目创建申请」issue。正文可直接粘贴下面的内容，
> 尖括号 `<...>` 处需申请人填写。

## 一、基本信息

| 项 | 内容 |
|----|------|
| 项目名称 | `pdf4cj` |
| 项目类型 | 基础库（纯仓颉实现，非 FFI 封装） |
| 领域分类 | Data / Document |
| 申请人 | `<GitCode 昵称>`（`<GitHub/GitCode 主页>`） |
| 联系邮箱 | `<邮箱>` |
| GitCode 账号 | `<gitcode.com/<账号>>` |
| 拟建仓库地址 | `https://gitcode.com/Cangjie-TPC/pdf4cj` |
| 上游/来源仓库 | `https://github.com/EthanCheung-gh/pdf-inspector-mcp`（子目录 `pdf4cj/`） |
| 许可证 | MIT（见 `LICENSE`，版权人 EthanCheung） |
| 当前版本 | 0.1.0 |
| 目标 Cangjie 版本 | LTS 1.0.0（`cjc` 1.0.0）+ cangjie-stdx 1.0.0.1 |
| 代码规模 | 约 9 300 行实现代码（15 个 `.cj` 文件）+ 约 2 100 行测试代码 |
| 测试状态 | `cjpm test`：77 / 77 通过 |

## 二、背景与价值

仓颉生态目前**没有可用的 PDF 解析库**。在 TPC 现有项目中，与文档格式相关的能力集中在
`markit`（Markdown 解析 → **输出** PDF/Typst）、`xlsx4cj`（Excel 读写）、`docx4cj` 一类
"写入/转换"工具上，而"**读取**一份已有 PDF 里的文字、表格、图片"这一侧是空白。

现实需求很明确：

- AI/Agent 场景里，PDF 是最常见的知识载体。RAG 预处理、文档问答、合同/发票抽取都需要先把
  PDF 变成结构化文本；
- 仓颉应用若要做 PDF 预览、报表核对、档案检索，要么自己写解析器，要么接 C 库（mupdf/poppler）
  并维护 FFI 绑定与跨平台构建；
- 现有 C 库在仓颉侧的绑定尚无官方维护，且引入原生依赖会破坏"纯仓颉、单命令构建"的体验。

`pdf4cj` 提供的是**纯仓颉、零 FFI** 的第三条路：`cjpm build` 即可用，只依赖 `std` 与
`stdx.compress.zlib`、`stdx.encoding.base64`。它不做渲染，只做**结构解析与内容抽取**，
因此规模可控（约 9.3k 行）、边界清晰、易于社区分工维护。

## 三、功能范围

### 已实现（v0.1.0）

1. **对象模型与交叉引用**
   - `PdfValue`（null / bool / int / real / string / name / array / dict / ref / stream）；
   - 经典 xref 表、`/Prev` 增量更新链、xref stream（`/Type /XRef`、`/W`、`/Index`、
     PNG predictor）、对象流 `/ObjStm`；
   - xref 损坏时回退全文件扫描 `N G obj`；间接引用解析带深度上限。
2. **流过滤器**：`FlateDecode`（zlib/raw deflate/gzip 三种壳，predictor 1/2/10..15）、
   `LZWDecode`（`/EarlyChange` 0/1）、`ASCII85Decode`、`ASCIIHexDecode`、
   `RunLengthDecode`，支持过滤器数组串联。
3. **文档与页面**：页面树遍历与可继承属性（`/Resources`、`/MediaBox`、`/CropBox`、`/Rotate`）、
   文档元数据（页数、版本、`/Info`、全部 `/BaseFont` 名）、值访问器、字符串解码
   （UTF-16BE/LE BOM + PDFDocEncoding）。
4. **字体**：简单字体（`/Type1`、`/TrueType`、`/MMType1`、`/Type3`）的 `/Widths`、
   `/Differences`、base encoding；复合字体（`/Type0`）的 `/W`、`/DW`、`Identity-H/V`、
   内嵌 CMap 码空间；`/ToUnicode` CMap（`bfchar`/`bfrange`/`codespacerange`）；
   标准 14 字体宽度表与 WinAnsi/MacRoman/Standard/PDFDoc 编码表。
5. **内容流解释**：文本状态与显示算子（`Tf`/`Td`/`TD`/`Tm`/`T*`/`Tz`/`Ts`/`Tc`/`Tw`/`TL`、
   `Tj`/`TJ`/`'`/`"`）、路径与填充描边（`re`/`m`/`l`/`c`/`v`/`y`/`h`、`f`/`S`/`B` 系列）、
   图形栈 `q`/`Q`、CTM `cm`、Form XObject `Do`（深度上限 8）、内联图像 `BI`/`ID`/`EI`。
6. **结构化输出**：`extractPage` 产出 `PageData`（`chars`/`words`/`rects`/`lines`/`curves`/
   `images`）；`buildWords` 按基线（1.0pt）与水平间隙（3.0pt）切词并输出阅读顺序。
7. **表格**：`extractTables` 按 pdfplumber 默认策略识别**有框线**表格（矩形边 + 横竖线 →
   snap/merge → 连通分量 → 单元格），带边数与单元格数上限。
8. **图片**：`imagePayload` 输出 base64 载荷；`detectImageFormat` 按魔数识别
   PNG/JPEG/GIF/WebP/JPX/JBIG2；原始采样（Gray/RGB/CMYK/ICCBased，1/8/16-bit，支持
   `/Decode`）由**手写 PNG 编码器**转码；JPX/JBIG2 以 `error` 明确拒答。
9. **文档与工程化**：`README.md`、`CHANGELOG.md`、`README.OpenSource`、`LICENSE`、
   `doc/design.md`、`doc/feature_api.md`、可编译示例 `example/`、15 个 PDF 回归语料、
   `scripts/setup-stdx.sh`。

### 明确不做（v0.1.0 范围外）

渲染/光栅化、加密解密、PDF 写入与编辑、JPX/JBIG2 解码、数字签名/表单语义、增量读取。

## 四、架构

```
数据模型层  data.cj                     CharObj/WordObj/.../PageData/PdfMetadata
抽取层      content.cj text.cj table.cj image.cj
字体层      font.cj cmap.cj metrics_data.cj encoding_data.cj
文档层      document.cj page.cj
解析层      parser.cj lexer.cj filters.cj object.cj
```

依赖方向严格单向向下；无全局可变状态（除按流解码缓存）。数据流：
`bytes → PdfValue 树 → 页面树 → 字体/内容流 → PageData → tables/images`。
细节见 `doc/design.md`（含坐标约定、错误模型、性能与安全护栏表格、扩展点清单）。

## 五、依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| Cangjie 工具链 | LTS 1.0.0 | 编译与测试 |
| cangjie-stdx | 1.0.0.1 | `compress.zlib`（Flate/IDAT）、`encoding.base64`（图片载荷） |
| `std.collection` / `std.fs` / `std.io` | 随工具链 | 容器、读文件、字节缓冲 |

**无第三方 C 库、无 FFI、无网络依赖。**

## 六、维护者

| 角色 | 姓名/账号 | 职责 |
|------|-----------|------|
| Maintainer | `<姓名>` / `<GitCode 账号>` | 总体设计、解析内核、发版 |
| Committer | `<待定>` | 字体/内容流/表格方向 |
| Committer | `<待定>` | 测试与回归语料、文档 |

申请人承诺按 TPC 要求响应 issue、评审 PR、维护版本与 CHANGELOG。

## 七、许可证

MIT。仓库内 `LICENSE` 为完整 MIT 文本，`README.OpenSource` 已按 TPC 格式声明
`Name / License / License File / Version Number / Owner / Upstream URL / Description`。
项目不包含任何第三方代码，所有实现均为原创，因此不存在许可证传染问题。

## 八、初始内容

提交的 zip（`pdf4cj.zip`，根目录为 `pdf4cj/`）包含：

```
pdf4cj/
├── README.md              # 中文介绍、徽章、路线图、示例、约束
├── README.OpenSource      # TPC 开源合规 JSON
├── CHANGELOG.md           # 0.1.0 版本记录（含已知限制与测试统计）
├── LICENSE                # MIT
├── cjpm.toml              # cjc 1.0.0，dynamic 库，stdx 路径
├── .gitattributes         # fixtures 标为 binary，避免行尾转换破坏 xref
├── .gitignore             # 排除 target/、stdx/、dist/、cjpm.lock、__pycache__ 等产物
├── doc/design.md          # 设计文档
├── doc/feature_api.md     # 全部 public API 文档
├── src/*.cj               # 15 个实现文件 + src/test/*.cj 6 个测试文件
├── example/               # 独立 cjpm 模块，可编译运行的 CLI 示例
├── tests/                 # 15 个 PDF 语料 + 语料说明 + 生成脚本
├── scripts/               # setup-stdx.sh 与 make-submission-zip.sh
└── contrib/               # 本申请材料与 PR 模板
```

压缩包不包含 `stdx/`、`target/`、`dist/`、`.git/`、`*.log`、`cjpm.lock`、`__pycache__`。
本库除 `std`/`stdx` 外没有第三方依赖，`cjpm.lock` 永远是空的 `version = 0` 存根，因此既不提交
也不打包。实际成员清单以 `bash scripts/make-submission-zip.sh` 生成后用
`unzip -l dist/pdf4cj.zip` 的结果为准。

## 九、路线图

| 版本 | 内容 |
|------|------|
| 0.1.0 | 本文「功能范围」所列内容（已完成） |
| 0.2.0 | 标准安全处理器（RC4 40/128、AES-128/256）解密 |
| 0.2.x | JPX / JBIG2 支持（自带解码或可插拔外置解码接口） |
| 0.3.0 | `/Rotate` 坐标变换、裁剪路径 `W`/`W*` 生效 |
| 0.3.x | 无框线表格（空白/文字对齐推断网格） |
| 0.4.0 | 增量/按需读取、对象缓存与内存上限、性能基准 |
| 持续 | 扩充真实 PDF 回归语料、异常样本、文档完善 |

## 十、测试证据

`cjpm test`（Cangjie LTS 1.0.0、cangjie-stdx 1.0.0.1、Linux x86_64）：

```text
Summary: TOTAL: 77
    PASSED: 77, SKIPPED: 0, ERROR: 0
    FAILED: 0
cjpm test success
```

| 测试文件 | 用例数 | 覆盖 |
|----------|--------|------|
| `src/test/content_test.cj` | 10 | 单词切分、格式化辅助、手写内容流的 `extractPage` 端到端 |
| `src/test/document_test.cj` | 8 | 空页树、截断文档、页树引用环、悬空 `/Contents`、`/Length` 越界与可恢复 |
| `src/test/font_test.cj` | 22 | CMap、编码表、宽度、标准 14 字体、Type0 |
| `src/test/image_test.cj` | 12 | 魔数识别、PNG/JPEG 透传、原始采样转 PNG、`/Decode`、非法布局、声明尺寸超过像素上限 |
| `src/test/table_test.cj` | 10 | 有框线网格、空单元格、多行单元格、分离网格、无线文本 |
| `src/test/fixtures_test.cj` | 15 | 每个 fixture 至少一条端到端断言（页数/单词/表格/图片格式/损坏文件错误消息） |

（61 个原有单测 + 1 个图片像素上限用例 + 15 个 fixture 语料用例 = 77。）

`cjpm build`：成功产出 `target/release/pdf4cj/libpdf4cj.so`。
`example/`：`cjpm build` 与 `cjpm run --run-args "../tests/fixtures/table.pdf 1"` 均通过，
输出见 `example/README.md`。

> 本库**不提供**覆盖率数字，因此 README 中没有 cjcov 徽章。

## 十一、与 TPC 现有项目的差异

| 项目 | 与本项目的关系 |
|------|----------------|
| `markit` | 它解析 Markdown 并**输出** PDF/Typst；`pdf4cj` **读取**已有 PDF，方向相反，无功能重叠 |
| `xlsx4cj` / `docx4cj` | 面向 Office Open XML 的读写；PDF 是另一套（xref + 内容流 + 字体编码）完全不同的格式 |
| `avif-ffi` 等 FFI 项目 | `pdf4cj` 是纯仓颉实现，不引入原生依赖，构建方式就是 `cjpm build` |

结论：TPC 目前**没有 PDF 解析库**，`pdf4cj` 填补的是"文档读取"这一空白，与现有项目互补而非重复。

## 十二、申请事项

- [ ] 请在 `Cangjie-TPC` 组织下创建仓库 `pdf4cj`（`https://gitcode.com/Cangjie-TPC/pdf4cj`）
- [ ] 赋予申请人 Maintainer 权限
- [ ] 确认许可证（MIT）与仓库描述
- [ ] 确认是否需要同步在 TPC 索引页/README 列表中登记

申请人已签署 CLA：`<是/否，签署账号>`。
