# PDF Inspector MCP — 仓颉版（CangjieMagic）

这是 `pdf-inspector-mcp` 的**仓颉语言重写**：用仓颉 + [CangjieMagic](https://gitcode.com/Cangjie-TPC/CangjieMagic) 实现同一套 MCP 服务，对外仍然是 **6 个工具、stdio 传输、JSON 文本结果**，解析与导出逻辑不再依赖 Python、pdfplumber 或 Pillow。

代码位于仓库的 `cangjie/` 子项目；根目录的 Python 版仍是默认实现与**行为基线**，两边的差异在「[与 Python 版的已知差异](#与-python-版的已知差异)」中逐条列出。

- 分支：`feat/cangjie-magic-rewrite`
- 上游 Python 版：[`../README.md`](../README.md)
- 工具名、参数名、参数顺序、`Option` 语义与 Python 版保持一致；改这些等于改公开 MCP 接口

## 定位

| 维度 | Python 版 | 仓颉版 |
|------|-----------|--------|
| 解析内核 | pdfplumber / pdfminer / Pillow | 独立库 [`../pdf4cj`](../pdf4cj)（package `pdf4cj`，纯仓颉实现） |
| 导出 | `export.py` | `src/export/`（JSON / CSV / 文件名） |
| 工具层 | `server.py` + MCP SDK | `src/mcp/`，CangjieMagic `@tool` + 自写 stdio JSON-RPC 循环 |
| 传输 | stdio | stdio（仍是一行一条 JSON-RPC 消息） |
| 对外工具 | 6 个 | 同样 6 个，名称/参数/返回结构一致 |
| 默认实现 | 是 | 否（对照与探索实现） |

解析流程完全是仓颉代码：对象模型 → 交叉引用表 / 对象流 → 流过滤器 → 页面树 → 字体与 CMap → 内容流解释器 → 字符/单词/图形/图片 → 表格 → JSON/CSV。**没有 C 源码、没有手写 FFI**；除 CangjieMagic 本身外只用到 `stdx` 的 `compress.zlib`、`encoding.json`、`encoding.base64`。

## 为什么不直接用 CangjieMagic 的 `StdioMCPServer`

CangjieMagic 自带的 `magic.mcp.StdioMCPServer` 能启动，但作为面向客户端的 MCP 服务有三个实测缺陷（对应其 `AbsMCPServer` 的实现）：

1. **把所有参数都标成 required**：`convertTool2MCP()` 遍历 `tool.parameters` 时无条件把每个参数加入 `required`，完全忽略 `ToolParameter.required`。于是 `pdf_export` 的 9 个参数、`pdf_get_metadata` 的 `password` 都会被客户端当成必填——`Option<T>` 在 schema 里失去意义。
2. **工具抛异常会杀死 server**：`handleCallTool()` 直接调用 `tool.invoke(args)`，没有 `try`。一次坏路径、坏页码或坏口令就会让异常冒到 `loop()` 之外，整个进程退出，后续请求全部丢失。
3. **永远返回 `isError: false`**：`CallToolResult` 中的 `isError` 被硬编码为 `false`，即使工具失败，客户端也只能从文本里猜。

因此本项目**复用** CangjieMagic 的两样东西：

- `@tool[description: ..., parameters: ...]` 声明工具；
- `magic.core.tool.Tool` 接口与 `ToolResponse`。

**自写** stdio JSON-RPC 循环（`src/mcp/server.cj`）：

- 方法：`initialize`、`tools/list`、`tools/call`、`ping`；
- `initialize` 只回显服务端真正支持的协议版本：`2024-11-05` 或 `2025-06-18`；其它版本（包括更新的 `9999-01-01`）一律回退到 `2024-11-05`，不假装支持；
- 通知（`notifications/*`）与无 `id` 的请求不回复；
- JSON-RPC 2.0 错误码：`-32700` parse error、`-32600` invalid request、`-32601` method not found、`-32602` invalid params（含未知工具名）、`-32603` internal error；
- 每行一条消息；stdx 的 `JsonValue` 只会 pretty-print，所以序列化时按行 trim 后拼成单行；
- 诊断只写 stderr，stdout 只允许 JSON-RPC 响应。

`tools/list` 不直接回传 CangjieMagic 的内部形状：`tool.toJsonValue()` 给出的 `{name, description, parameters}` 会被重排成 MCP 的 **`{name, description, inputSchema}`**，`parameters` 键不会出现在响应里（官方 MCP SDK 的 `ListToolsResult` 能解析；`scripts/smoke-mcp.sh` 与 `e2e-smoke.sh` 都有断言）。`inputSchema` 本身仍来自 `Tool.parameters`，所以 `required` 由 `Option<T>` 推导——客户端看到 `pdf_export` 只要求 `path`，`pdf_extract_page` 要求 `path` 和 `page`。

工具调用失败的处理在 `invokeTool()`：

| 异常 | 对客户端 |
|------|----------|
| `PdfToolError`（本项目的可读错误） | `isError: true`，文本原样返回 |
| `ToolException`（CangjieMagic 参数转换等） | `isError: true`，文本原样返回 |
| 其它 `Exception`（程序 bug） | `isError: true`，只返回 `Internal error while executing tool '<name>'.`，具体消息写 stderr |

> 注意：这个工具链对异常类做动态 `toString()` 会导致进程崩溃，所以 stderr 只打印 `error.message`，不打印堆栈（见「开发提示」）。

## 工具链与构建

### 必须使用 Cangjie LTS 1.0.0

CangjieMagic 的 `dev` 分支当前**无法在 1.2.0 工具链下编译**（语言/标准库不兼容），必须用 **LTS 1.0.0**。`cjpm.toml` 也把 `cjc-version` 固定为 `1.0.0`。

```bash
# 安装/确认 1.0.0（已安装会提示）
~/.cjv/bin/cjv install lts-1.0.0
~/.cjv/bin/cjv show          # 确认输出里有 lts-1.0.0
```

下面所有命令都显式用 `cjv run lts-1.0.0 ...`，不依赖默认工具链（默认工具链可能已切换到别的版本）。

### 准备 stdx

CangjieMagic 依赖 cangjie-stdx 的预编译二进制；`scripts/setup-stdx.sh` 会下载并解压 **`cangjie-stdx-linux-x64-1.0.0.1`** 到 `cangjie/libs/`，同时调用 `../pdf4cj/scripts/setup-stdx.sh` 准备好解析库自己的那份（`pdf4cj/stdx/`）：

```bash
cd cangjie
bash scripts/setup-stdx.sh
```

构建前还必须导出 `pdf4cj` 使用的 stdx 路径——`pdf4cj/cjpm.toml` 用 `${CANGJIE_STDX_PATH}` 指向它，path 依赖一旦参与编译就会读取这个变量：

```bash
export CANGJIE_STDX_PATH="$(cd ../pdf4cj/stdx/cangjie-stdx-linux-x64-1.0.0.1 && pwd)"
```

（`scripts/` 下的脚本都会自己设好这个变量，只有手工执行 `cjpm` 时才需要手动 export。）

脚本目前只覆盖 **x86_64 Linux**，本仓库的构建/测试也只在该平台实测过。`cjpm.toml` 里虽然也写了 aarch64-linux / aarch64-darwin 的 `bin-dependencies` 路径，但这些平台的 stdx 包需要自行下载到对应目录；脚本不会代劳，也没有对应的验证结果。

### 构建、测试、运行

```bash
cd cangjie

# 构建（默认包配置）
~/.cjv/bin/cjv run lts-1.0.0 cjpm build

# 单元测试
~/.cjv/bin/cjv run lts-1.0.0 cjpm test

# 以 MCP server 运行（stdio）
~/.cjv/bin/cjv run lts-1.0.0 cjpm run --name pdf_inspector_mcp
```

`cjpm test` 会覆盖 `target/release/bin/`（测试构建与默认配置共用该目录）；跑完测试后如果要**直接运行** `target/release/bin/pdf_inspector_mcp`，需要再执行一次 `cjpm build`，确保拿到的是默认配置的 server 可执行文件。`test-all.sh` 的 e2e 阶段会自己重新构建并直接校验该二进制，所以按脚本顺序执行不受影响。

依赖版本：

- CangjieMagic 以 git 依赖形式引入，`cjpm.lock` 固定到 commit `bc4624fac86ad8498b61d7e5f3b1168659bc72b5`（`dev` 分支）。升级 magic 时要同步验证工具链兼容性。
- `pdf4cj` 以 **path 依赖**（`{ path = "../pdf4cj" }`）引入，库本身是 `output-type = "dynamic"`，所以构建产物 `libpdf4cj.so` 会落在 `cangjie/target/release/pdf4cj/`，运行时需要它在 `LD_LIBRARY_PATH` 里（见下文）。path 依赖不写进 `cjpm.lock`，改库代码后直接重新 `cjpm build` 即可。
- cangjie-stdx 固定 `1.0.0.1`。
- `libs/`、`target/`、`build-script-cache/` 都在 `cangjie/.gitignore` 里，不入库。

#### 构建时的两个实际情况

1. **会顺带构建 CangjieMagic 的示例程序**。magic 的 `cjpm.toml` 把 `magic.examples.*` 都声明为 executable，`cjpm build` 会把它们一并链接。这使本机一次构建约需 40 秒（`cjpm test` 也会先重建，耗时相近），与本项目代码规模无关。
2. **同一 `target/` 目录的并发构建会互相破坏**。如果另一个终端或并行 worker 正在同一个 `cangjie/` 里跑 `cjpm build`/`cjpm test`，magic 示例的链接会偶发失败，典型输出：

   ```
   libmagic.rag.retriever.so, needed by target/release/magic/libmagic.prelude.so, not found
   undefined reference to `magic.rag.retriever:...`
   libmagic.core.agent.so: file format not recognized
   Error: failed to compile package `magic.examples.mcp_server`
   ```

   测试阶段还可能因为测试二进制被同时改写而报 `ProcessException: Created process failed, errMessage: "Permission denied"`。这些都不是本项目源码错误。确认没有其他 `cjpm` 进程后重跑即可；必要时先 `cjpm clean`。串行构建 `-j 1` 只降低单个进程内部的并行度，不能解决两个进程同时写 `target/` 的问题，而且本机耗时约 2.5 分钟。

编译器还会报告两条良性警告：`server.cj` 的 `possibly confusing line terminator`（字符串字面量跨行拼接），以及 `tools.cj` 里 `std.posix.chmod` 在 LTS 1.0.0 被标记 deprecated（功能正常；导出临时文件的 `0600` 权限已由 e2e 断言的 `stat` 检查覆盖）。

### 让 MCP 客户端连接仓颉版

**不要**让真实 MCP 客户端直接执行 `cjpm run`。实测 `cjpm run` 在服务器退出后会把下面两行写到 **stdout**：

```
（空行）
cjpm run finished
```

它们不是 JSON-RPC 消息，严格的客户端会因此报协议错误。`scripts/smoke-mcp.sh` 与 `e2e-smoke.sh` 是通过“忽略非 JSON 行”来容忍这一点的；真实客户端不应如此。

推荐直接运行构建产物，并为它设置动态库搜索路径（下面以本仓库的 x86_64 Linux 布局为例）：

```bash
cd cangjie

export LD_LIBRARY_PATH="$PWD/target/release/magic:\
$PWD/target/release/pdf4cj:\
$PWD/libs/cangjie-stdx-linux-x64-1.0.0.1/linux_x86_64_llvm/dynamic/stdx:\
$HOME/.cjv/toolchains/lts-1.0.0/runtime/lib/linux_x86_64_llvm:\
$HOME/.cjv/toolchains/lts-1.0.0/tools/lib"

exec ./target/release/bin/pdf_inspector_mcp
```

对应到 MCP 客户端配置（把路径换成你自己的绝对路径；`env` 的 `LD_LIBRARY_PATH` 用一行写）：

```json
{
  "mcpServers": {
    "pdf-inspector-cangjie": {
      "command": "/absolute/path/to/pdf-inspector-mcp/cangjie/target/release/bin/pdf_inspector_mcp",
      "args": [],
      "env": {
        "LD_LIBRARY_PATH": "/absolute/path/to/pdf-inspector-mcp/cangjie/target/release/magic:/absolute/path/to/pdf-inspector-mcp/cangjie/target/release/pdf4cj:/absolute/path/to/pdf-inspector-mcp/cangjie/libs/cangjie-stdx-linux-x64-1.0.0.1/linux_x86_64_llvm/dynamic/stdx:/home/you/.cjv/toolchains/lts-1.0.0/runtime/lib/linux_x86_64_llvm:/home/you/.cjv/toolchains/lts-1.0.0/tools/lib"
      }
    }
  }
}
```

服务器启动时会向 **stderr** 打一行：

```
pdf-inspector-mcp 0.1.0-cangjie: stdio JSON-RPC server ready, 6 tools registered
```

stdout 不输出任何启动信息。客户端把 stderr 当日志即可。

## 架构与文件地图

```
cangjie/
  cjpm.toml             包配置：cjc 1.0.0、magic git 依赖、pdf4cj path 依赖、stdx bin-dependencies
  cjpm.lock             锁定 magic commit
  scripts/              构建/冒烟/e2e/调试脚本
  src/
    main.cj             入口：runServer()
    mcp/                MCP 协议、工具、会话缓存、JSON 小工具
    export/             JSON / CSV / 文件名
    debug/              手工调试驱动（pdf_inspector_mcp.debug）
    extractdebug/       内容流调试驱动（pdf_inspector_mcp.extractdebug）
    tests/              单元测试 + golden 集成测试（package pdf_inspector_mcp.tests）
  tests/
    fixtures/           15 个 PDF fixture（由 Python 生成，入库）
    goldens/            72 个 Python 基线 JSON/CSV（入库）
    generate_fixtures.py
    generate_goldens.py

../pdf4cj/              独立库（package pdf4cj，被 cangjie/ 以 path 依赖引用）
  cjpm.toml             output-type = dynamic；stdx 走 ${CANGJIE_STDX_PATH}
  stdx/                 pdf4cj 自己的 cangjie-stdx（由 scripts/setup-stdx.sh 下载）
  src/                  PDF 解析与提取内核（见下节）
    test/               库自身单元测试（package pdf4cj.test，61 个用例）
```

### `src/mcp/`

| 文件 | 职责 |
|------|------|
| `server.cj` | stdio 读/分发/写循环；`initialize` / `tools/list` / `tools/call` / `ping`；JSON-RPC 错误；`isError` 包装；stderr 日志 |
| `tools.cj` | 6 个 `@tool` 函数；参数校验、页码/范围、1 MB 内联限制、图片 `stream_id`、字体统计、导出落盘/临时文件 |
| `errors.cj` | `PdfToolError`：可直接展示给客户端的失败 |
| `session.cj` | 路径校验（`~` 展开、符号链接解析、必须是普通文件）；按 `(规范路径, password, mtime, size)` 缓存已打开文档的 LRU（默认 8，`PDF_INSPECTOR_MCP_MAX_DOCS`） |
| `jsonutil.cj` | JSON 字符串转义、整数/字符串数组、Python 风格浮点文本、字体统计的颜色文本 |

会话缓存与 Python 版的关键语义一致：

- 键是 `(规范化的绝对路径, password)`；同一文件不同口令是两个会话；
- 文件 mtime 或大小变化 → 关闭旧文档并重新打开，绝不读到旧解析；
- 超出上限按 LRU 淘汰，淘汰前 `close()`；
- 服务器是单线程逐条处理消息，因此**没有锁**（Python 版每会话有锁是因为它可能被多线程调用）。

### PDF 解析库（`../pdf4cj`）

解析内核已抽成独立库 `pdf4cj`（package `pdf4cj`，`output-type = "dynamic"`），本节描述的文件都在 `../pdf4cj/src/` 下；`cangjie/` 里通过 `import pdf4cj.*` 使用它。库有独立的 `cjpm.toml`、`stdx/`、测试与文档，改动内核时请在该库内构建/测试（见其 README）。

| 文件 | 职责 |
|------|------|
| `object.cj` | `PdfValue`（null/bool/int/real/string/name/array/dict/ref/stream）、`PdfStream`、`PdfError` |
| `lexer.cj` | 字节级词法与值读取（对象、对象流、xref 流共用） |
| `parser.cj` | 经典 xref（多 subsection + `/Prev`）、混合引用（`/XRefStm`）、xref 流（`/W`、`/Index`、Flate、PNG predictor）、对象流（`/ObjStm`）；xref 不可用时扫描 `n g obj` 与最后一个带 `/Root` 的 trailer |
| `filters.cj` | FlateDecode（zlib/raw）、LZW、ASCIIHex、ASCII85、RunLength，以及 PNG/TIFF predictor；图片 codec（DCT/JPX/JBIG2/CCITT）与 `/Crypt` 原样透传 |
| `document.cj` | 整文件读入、`/Root`、trailer、`/Encrypt` 检测、页面树遍历、元数据、字体名收集、字符串解码（UTF-16BE/LE、PDFDocEncoding） |
| `page.cj` | 页面对象；`/CropBox` 优先、否则 `/MediaBox`、默认 `[0 0 612 792]`；内容流拼接；`/Rotate` 只暴露不应用 |
| `data.cj` | `CharObj` / `WordObj` / `RectObj` / `LineObj` / `CurveObj` / `ImageObj` / `TableObj` / `PageData` / `PdfMetadata` / `PdfColor` |
| `font.cj` | 简单字体（Type1/TrueType/MMType1/Type3）与 Type0 复合字体；编码 + `/Differences` + `/ToUnicode`；宽度、ascent/descent；标准 14 字体 |
| `cmap.cj` | `/ToUnicode` CMap 与内嵌 encoding CMap；codespace、bfchar/bfrange、cidchar/cidrange |
| `metrics_data.cj` | **生成文件**：标准 14 字体宽度与 ascent/descent |
| `encoding_data.cj` | **生成文件**：WinAnsi/MacRoman/Standard/PDFDoc 等 256 项编码表 |
| `content.cj` | 内容流解释器：图形状态、文本状态、`Tj/TJ/'/"`、路径/填充/描边/Bezier、Form XObject、内联图像、颜色；输出用户空间对象 |
| `text.cj` | 按基线分行、按空白和水平间隙切词；词框为字符框并集 |
| `table.cj` | 有框线表格检测（矩形边 + 横竖线 → 吸附合并 → 连通分量 → 单元格 → 按字符中心填充文本） |
| `image.cj` | 图片格式识别（PNG/JPEG/GIF/WebP/JPX/JBIG2）；原始采样转 PNG（自写 PNG 编码器，含 CRC32/Adler-32） |

坐标约定：

- `chars` / `words` / `rects` / `lines` / `curves` / `images` 使用 PDF 用户空间：原点在页面框左下角，y 向上；与 pdfplumber 的 `x0`/`y0` 在它做 top-flip 之前一致。
- `tables` 使用 pdfplumber 的 top-based 坐标：`y0 = pageHeight - yMaxPdf`，`y1 = pageHeight - yMinPdf`。
- `/Rotate` 不参与坐标变换（见差异列表）。

### `src/export/`

| 文件 | 职责 |
|------|------|
| `types.cj` | 7 种对象类型的规范顺序与过滤（未知值忽略、去重、固定顺序） |
| `json.cj` | 有序 JSON 树与渲染器；`pdf_export` / `pdf_get_metadata` / `pdf_extract_page` / `pdf_extract_document` 的载荷 |
| `csv.cj` | 以 `# <type>` 分段的 CSV、UTF-8 BOM、RFC 4180 引号规则、JS `String()` 单元格格式 |
| `filename.cj` | `<stem>-all.<ext>` / `<stem>-p<N>.<ext>` 的 suggested filename |

JSON 之所以不用 `stdx.encoding.json` 直接构造，有两个原因：`JsonObject` 是哈希表、键顺序会丢；`JsonFloat` 固定打印 6 位小数（`612.000000`）。所以 `json.cj` 用有序 `JNode` 树 + 自写渲染器，数字走 `jsNumberText`（JavaScript `String()` 风格）。

`src/debug/` 与 `src/extractdebug/` 是两个手工排查入口：

```bash
bash scripts/debug-dump.sh /path/to/file.pdf
bash scripts/extract-dump.sh /path/to/file.pdf 2
```

它们分别打印文档级事实与某页的提取计数/前几个词/图片放置，便于和 pdfplumber 对照。

## 六个工具

六个工具都是同步的，返回 JSON 文本（MCP `content[0].text`）。`page`、`first_page`、`last_page`、`start_page`、`end_page` 都是 **1-based**；`password` 均可选。

| 工具 | 参数 | 返回 |
|------|------|------|
| `pdf_get_metadata` | `path`、`password?` | `{pages, version, encrypted, page_w, page_h, title, author, producer, fonts}` |
| `pdf_extract_page` | `path`、`page`、`password?` | 单页：`{width, height, chars, words, rects, lines, curves, images, tables}` |
| `pdf_extract_document` | `path`、`first_page?`、`last_page?`、`password?` | `{metadata, pageCount, pages}`；`pageCount` 是**实际返回的页数** |
| `pdf_analyze_fonts` | `path`、`start_page?`、`end_page?`、`password?` | `{fonts:[{fontname, pages, charCount, sizeMin, sizeMax, colors}]}`，按 `charCount` 降序 |
| `pdf_get_image` | `path`、`stream_id`、`password?` | 成功 `{base64, format, mime_type, byte_length}`；失败 `{error}`（`isError:false`） |
| `pdf_export` | `path`、`format?`、`scope?`、`page?`、`first_page?`、`last_page?`、`object_types?`、`output_path?`、`password?` | 见下 |

`tools/list` 的每个条目是 `{name, description, inputSchema}`；`inputSchema` 是 `type: "object"`，包含 `properties` 与 `required`。必填项只有：

- `pdf_get_metadata` / `pdf_extract_document` / `pdf_analyze_fonts` / `pdf_export`：`path`
- `pdf_extract_page`：`path`、`page`
- `pdf_get_image`：`path`、`stream_id`

`Option<T>` 参数在 `inputSchema` 中表示为 `{"anyOf": [<原 schema>, {"type": "null"}], "default": null}`，并且不会出现在 `required` 里。

### 页面与范围

- `pdf_extract_page` 的 `page` 超出 `1..pageCount` → `Invalid page number: N (document has M pages)`。
- `pdf_extract_document` 省略两端 = 整档；允许只给一端；范围非法 → `Invalid page range: A-B (document has M pages)`。
- 0 页文档：两个范围参数都省略时返回 `pages: []`（不报错）；显式给范围才会报范围错误。
- `pdf_analyze_fonts` 省略两端 = 整档，0 页文档返回 `{"fonts":[]}`。

### 1 MB 内联限制

`MAX_INLINE_BYTES = 1_000_000`（UTF-8 字节数）。

- `pdf_extract_page` / `pdf_extract_document`：超过限制直接抛 `PdfToolError`（`isError:true`），提示改用 `pdf_export` + `output_path` 或缩小范围；**不会**自动落盘。
- `pdf_export` 未给 `output_path` 且内容超限：写入系统临时目录（`TMPDIR` 或 `/tmp`），文件名 `pdf-inspector-<16位十六进制>-<suggested_filename>`，写入后立即 `chmod 0600`（失败只在 stderr 警告）；返回 `path`、`inline:false` 和 `note`，不返回 `content`。名字是“先 `exists` 再写入”预留的，不是 `mkstemp`/`O_EXCL` 原子创建，仍存在已记录的 TOCTOU 窗口（见下方差异）。
- `pdf_get_image` 是唯一**永不**受 1 MB 限制的工具：图片本身就是要传的内容，base64 完整返回。

### `pdf_get_image` 与 `stream_id`

`pdf_extract_page` / `pdf_extract_document` 返回的 image 对象带 `stream_id`，格式固定 `p<page>_img_<index>`（页内索引从 0 开始，例如 `p1_img_0`）。仓颉版要求**整串**匹配 `p<digits>_img_<digits>`；`p1_img_0xyz` 不会被当作前缀解析，而是返回 `Invalid stream_id`（Python 的 `re.match` 允许尾部多余字符）。

- `stream_id` 不匹配、页码越界 → `{"error":"Invalid stream_id: ..."}`
- 页内索引越界 → `{"error":"Image index N out of range"}`
- 图片无法展示（JPX/JBIG2、Indexed 等）→ `{"error":"Unsupported image format: ..."}`
- 以上都是**成功响应**（`isError:false`）里的 `error` 字段，与 Python 版一致；客户端不应把过期 `stream_id` 当成服务器故障。

浏览器可直接显示的格式（PNG/JPEG/GIF/WebP）原样返回；PDF 原始采样会转成 PNG。`mime_type` 由格式映射，未知为 `application/octet-stream`。`byte_length` 是解码后字节数。

### `pdf_export` 参数与返回

| 参数 | 语义 |
|------|------|
| `format` | `json`（默认）/ `csv`，trim + 小写后匹配 |
| `scope` | `document`（默认）/ `page` |
| `page` | `scope='page'` 时必填；`scope='document'` 下忽略（限定范围用 `first_page`/`last_page`） |
| `first_page` / `last_page` | document 范围的 1-based 闭区间，可只给一端 |
| `object_types` | `char`/`word`/`rect`/`line`/`curve`/`image`/`table` 的子集；省略 = 全部；显式空数组 = 不带任何对象数组；未知值忽略、重复去重、输出按固定顺序 |
| `output_path` | 落盘路径；父目录必须已存在；`~`/`~/...` 会展开；写入不做换行转换 |
| `password` | 加密文档口令（仓颉版目前不接受任何加密文档，见差异） |

返回三种形态：

```json
// 落盘
{"path":"/abs/out/report-all.json","bytes":18234,"format":"json","scope":"document",
 "object_types":["char","word","rect","line","curve","image","table"],
 "suggested_filename":"report-all.json"}
```

```json
// 内联
{"content":"{\n  \"metadata\": {...}","bytes":18234,"format":"json","scope":"document",
 "object_types":["char","word","rect","line","curve","image","table"],
 "suggested_filename":"report-all.json","inline":true}
```

```json
// 超限 → 临时文件
{"path":"/tmp/pdf-inspector-4f2c9a1b3d5e6f70-report-all.json","bytes":4120357,"format":"json",
 "scope":"document","object_types":["char","word","rect","line","curve","image","table"],
 "suggested_filename":"report-all.json","inline":false,
 "note":"The export is 4120357 bytes, over the 1000000-byte inline limit, so it was written to /tmp/... "}
```

`bytes` 是 UTF-8 编码后的字节数。`suggested_filename` 去掉原文件名末尾的 `.pdf`（大小写不敏感），document 用 `-all`、page 用 `-p<N>`。

JSON 结构（`pdf_export`）：

```json
{
  "metadata": {"pages":1,"version":"1.3","encrypted":false,"page_w":612,"page_h":792,
               "title":"untitled","author":"anonymous","producer":"...","fonts":["Helvetica"]},
  "exportedAt": "2026-01-01T00:00:00.000Z",
  "pageCount": 1,
  "objectTypes": ["word","table"],
  "pages": [{"width":612,"height":792,"chars":[],"words":[...],"rects":[],
             "lines":[],"curves":[],"images":[],"tables":[]}]
}
```

CSV 结构：UTF-8 BOM 开头，按 `# chars`、`# words`、`# rects`、`# lines`、`# curves`、`# images`、`# tables` 分段；每段先标题行再表头；`# tables` 每行一个单元格 `page,table_index,row,col,text`。单元格按 JS `String()` 语义格式化（整数浮点去掉 `.0`），颜色按数组 `join(',')`。这些规则与 Python 版相同，由 `src/export/csv.cj` 的注释与测试固定。

### `pdf_analyze_fonts` 的聚合规则

与 Python 版的 `_accumulate_font_stats` 对齐：

- 忽略 `fontname` 为空的字符；
- `pages` 按首次出现顺序（因此升序）、去重；
- `charCount` 统计的是**字符数**，不是不同字符串数；
- `sizeMin`/`sizeMax` 扩展；
- `colors` 按首次出现顺序、去重（格式见差异第 2 条）；
- 结果按 `charCount` 降序，稳定排序（相同计数保持首次出现顺序）。

## 错误语义

可预期的用户错误抛 `PdfToolError`，服务器转成 `isError:true`，消息原样给客户端。四类典型情况：

| 情况 | 消息特征 |
|------|----------|
| 路径为空 / 不存在 / 不是普通文件 / 无法解析 | `Invalid PDF path: '<path>' (the path is empty)`、`(resolved to '<abs>', which does not exist)`、`(resolved to '<abs>', which is not a regular file)`、`(cannot resolve it: ...)`、`(cannot stat it: ...)` |
| 打开失败（不是 PDF、结构损坏、页面树截断） | `Cannot open '<path>': not a valid PDF. Underlying error: <reason>`；页面树损坏时 reason 形如 `cannot read the page tree: page-tree object 6 0 R is missing or unreadable` |
| 加密文档（缺口令或给了口令都一样） | 含 `password required or incorrect (pass the 'password' argument for encrypted PDFs)`；Cangjie 版随后说明引擎不支持解密 |
| 结构可读、页内容损坏或 `/Length` 不可信 | `Failed to read '<path>': <reason> (the document opened, but its page content is damaged or unsupported)`；例如 `the /Contents stream is missing or unreadable: stream at byte 251 declares /Length 9223372036854775807, ... no 'endstream' marker was found` |

参数与导出错误：

| 情况 | 消息 |
|------|------|
| 页码越界 | `Invalid page number: 99 (document has 1 pages)` |
| 范围非法 | `Invalid page range: 2-1 (document has 3 pages)` |
| 参数 JSON 类型错误 | CangjieMagic 转换层给出 `Convert to Int error. Value: "1"`、`Convert to String error. Value: 123`、`Convert to Array error. Value: "word"`（`isError:true`；与 Python 的 `Invalid page number` / `Invalid format` / `Invalid object_types` 文案不同） |
| 格式非法 | `Invalid format: 'xml' (expected one of 'json', 'csv')` |
| scope 非法 | `Invalid scope: '...' (expected one of 'document', 'page')` |
| `scope='page'` 没给 `page` | `Missing page: scope='page' requires the 1-based 'page' argument (or use scope='document' to export a page range).` |
| `output_path` 为空 | `Invalid output_path: '   ' (expected a file path)` |
| 父目录不存在 | `Invalid output_path: '<path>' (directory <dir> does not exist; create it first or choose another location)` |
| `output_path` 是目录 | `Invalid output_path: '<path>' (it is a directory, not a file)` |
| 写文件失败 | `Invalid output_path: '<path>' (cannot write it: <reason>)` |
| 结果超 1 MB | `<tool>: the result is N bytes, over the 1000000-byte inline limit. <建议>` |

损坏 PDF 的边界（回归测试 `document_test.cj` 固定）：

- 页面树截断/引用消失 → **打开阶段**失败，形如 `Cannot open '...': not a valid PDF. Underlying error: cannot read the page tree: ...`；不会再像旧实现那样静默返回 0 页。
- 页树引用环 → 打开阶段失败，reason 含 `page tree: reference cycle at ...`（Python/pdfplumber 可能截断为 1 页）。
- 悬空 `/Contents` 引用 → 读取该页内容时失败，消息含 `the /Contents stream is missing or unreadable`（Python/pdfplumber 可能返回空白页）。
- 合法空页树（`/Kids []` 或 `/Type /Pages /Count 0`）→ 正常打开，`pages: 0`，不是错误。
- 页对象可读但 `/Contents` 的 `/Length` 不可信且没有 `endstream` → 提取阶段 `Failed to read ...`；`/Length` 只是偏大但真实 `endstream` 存在时，仍会回退到关键字扫描并成功读取（Python 可能报 `byte string is too large`，容差方向不同）。

协议层错误：

- 未知工具：JSON-RPC `-32602`，`Unknown tool: '<name>'`（不是 `isError` 结果）；
- 未知方法：`-32601`，`Method not found: '<method>'`；
- 非法 JSON：`-32700`，`Parse error`；
- 非对象请求：`-32600`，`Invalid Request: expected a JSON object`；
- 缺少字符串 `method`：`-32600`，`Invalid Request: missing string 'method'`；
- 分发过程意外异常：`-32603`，`Internal error`，详情写 stderr。

未预期异常（真正的 bug）不会伪装成用户错误：客户端只看到 `Internal error while executing tool '<name>'.`，不会收到 traceback。

> 与 Python 版的一个文案差异：Python 的口令错误是 `Cannot open '<path>': password required or incorrect ...`；仓颉版以 `password required or incorrect ...` 开头。两者都包含关键短语，但客户端如果做整串匹配需要注意。

## 与 Python 版的已知差异

以下差异是**有意保留或明确未实现**的，不是“已经支持但没说”。判断兼容性时以这一节为准。

1. **JSON 数字表示不同。** Cangjie 版按 JavaScript `String()`/`JSON.stringify` 风格输出，整数值没有 `.0`：`612`、`12`；Python 的 `json.dumps` 输出 `612.0`、`12.0`。小数的指数形式也跟随 JS：`1e-7`，而 Python 是 `1e-07`。`NaN`/`Infinity` 两边都是文本 token（非标准 JSON）。键顺序、两空格缩进、`null` 与非 ASCII 不转义保持一致。
2. **`pdf_analyze_fonts.colors` 的整数分量。** 仓颉的颜色模型把所有数值分量存成 `Float64`，丢了“操作数是整数还是浮点”的信息，再用规则模拟 Python 的 `str(tuple)`：灰度整数值打印成 `(0,)`（匹配 Python 的整数操作数；如果 Python 那边的操作数写成 `0.0 g`，它可能打印 `(0.0,)`）；RGB/CMYK 始终打印浮点形式，例如 `(1.0, 0.0, 0.0)`，而 Python 在操作数写成整数时可能是 `(1, 0, 0)`。本仓库的 reportlab fixture 两边都输出 `(1.0, 0.0, 0.0)`。
3. **加密 PDF：能检测，但不支持解密。** 只要 trailer 有 `/Encrypt`，`PdfDocument.open` 一律失败；**传不传 `password` 都一样**，错误都包含 `password required or incorrect`。因此仓颉版无法读取任何加密文档，`password` 参数目前只是接口占位。Python 版可以用口令打开。
4. **JPEG2000 / JBIG2 图片不转码。** 识别到 `jpx` 或 `jbig2` 直接返回 `{"error":"Unsupported image format: jpx"}`（或 `jbig2`）；Python 会尝试用 Pillow 转成 PNG。DCTDecode 的 JPEG 两边都原样返回。
5. **`/Rotate` 不应用。** 页面 `width`/`height` 不交换，`chars`/`words`/图形坐标都保持在**未旋转**的用户空间；`/Rotate` 只在内部页面对象上暴露。依赖旋转后坐标的客户端需要自行变换。
6. **Type0/CID 字体没有 `/ToUnicode` 时文本为空。** 没有内嵌字体程序就无法可靠地从 CID 得到 Unicode，所以 `text` 是空串；宽度仍然按 `/W`/`/DW` 正确计算。
7. **裁剪路径 `W`/`W*` 只记录不执行。** 被裁剪区域外的对象仍会出现在结果里；需要裁剪后可见性的客户端必须自行按路径过滤，不要依赖本实现。
8. **内联图像 `EI` 是启发式。** 只有 `EI` 前后都是 PDF 空白（或流结束）才认作结束标记，能避免常见“二进制数据里出现 EI”导致的截断；但极端数据仍可能被误判，这是启发式的固有风险。
9. **表格只识别有框线的。** 与 pdfplumber 默认策略一致：矩形边和横竖线组成闭合网格才识别，纯空白对齐的“无框线表格”不识别。实现使用固定容差（snap 2.5、最短边 3.0、直线容差 0.5），并对单页合并边数（4000）和每个连通分量的单元格数（25000）设上限，防止矢量图页面拖垮提取；这些阈值与 pdfplumber 的默认值不完全相同，边界情况可能得到不同表格。
10. **字体/坐标可能有浮点噪声。** `size` 由映射后的字形框高度反推，可能得到 `12.000000000000002` 这类值；坐标也因运算顺序不同而在末位与 Python 有差异。对比 golden 时应使用容差，不要逐位比较。
11. **`pdf_export` 落盘返回绝对路径。** Cangjie 版返回 `absolutePath(expandUser(output_path))`（规范化后的绝对路径）；Python 版回显 `str(Path(output_path).expanduser())`，相对路径仍是相对路径。
12. **`pdf_analyze_fonts` 每次重算。** 仓颉版没有 Python 的整档记忆化缓存：同一文档重复调用会重新遍历页面并提取字符。会话缓存只避免重复打开/解析文档结构，不缓存页数据或字体统计。
13. **原始像素转 PNG 的支持范围有限。** 支持 `DeviceGray` / `DeviceRGB` / `DeviceCMYK`（转 RGB）/ `ICCBased`（N=1/3/4），1/8/16-bit 采样，支持 `/Decode` 反转/线性映射；`Indexed`、`Separation`、`DeviceN`、`Lab`、`Pattern`、非法位深或仍带 codec filter 的流不会强行解码，而是返回 `{"error":"Unsupported image format: unknown"}`。Python 走 Pillow，能处理其中一部分。
14. **PNG 字节不保证与 Python 相同。** 即使像素一致，Cangjie 自写编码器的压缩/过滤策略也与 Pillow 不同，所以 `base64` 的字节、哈希以及 `byte_length`（返回数据的长度）都可能不同；`format` 和 `mime_type` 一致。原样透传的 JPEG/PNG 不受影响。
15. **单词切分是 pdfplumber 的近似，词序也不同。** 按基线（容差 1.0）分行、按空白和水平间隙（3.0）切词；没有 `upright`/方向处理（旋转文本按水平处理）、没有 `keep_blank_chars`/`split_at_punctuation` 选项，词层也不做额外的连字处理（字形文本由字体层决定）。Cangjie 的 `buildWords` 按阅读顺序（基线降序、`x0` 升序）输出；pdfplumber 在内容流绘制顺序与阅读顺序不一致时保留内容流顺序。已实测 12 个 fixture 中 11 个词序完全一致，只有 `quoted-table.pdf` 不同：内容流先画 y=710 的 `a,"b`，再画 y=698 的 `c`，最后画 y=700 的 `plain`，Python 得到 `['a,"b','c','plain']`，Cangjie 得到 `['a,"b','plain','c']`。这是顺序差异，文本集合与表格单元格不受影响；边界排版下切分本身也可能不同。
16. **字体层的其他限制。** 竖排（`Identity-V`、`/W2`）按横排读取（码和 Unicode 对，advance 用横排值）；`/CIDToGIDMap` 忽略；Type3 只通过 encoding 和 `/ToUnicode` 映射，不执行 glyph 过程；Symbol/ZapfDingbats 的 ascent/descent 为 0。
17. **整份 PDF 一次性读入内存。** `PdfDocument.open` 用 `File.readFrom` 读全文件，内存占用下限约等于文件大小；Python/pdfplumber 由库按需读取。超大 PDF 需要相应内存。
18. **`~user` 不展开。** 只展开 `~` 和 `~/...`（基于 `HOME`）；Python 的 `Path.expanduser()` 还支持 `~user`。
19. **启动时 stderr 多一行 ready 信息。** Python 版启动无输出；仓颉版向 stderr 打印版本与工具数，stdout 仍然只有 JSON-RPC。
20. **`rects[].fill` 的判定不同。** Python 版 `extractor.py` 用 `non_stroking_color is not None` 推导 `fill`，导致任何 `rect` 都报 `fill: true`——即使内容流是 `re S` 仅描边，pdfplumber 自己的 `rect["fill"]` 其实是 `false`。Cangjie 按实际绘制操作符报告（`S` → `false`，`f`/`B` → `true`），因此 `table.pdf` / `quoted-table.pdf` 的 `rect.fill` 是 `false`。这是有意的语义修正（更接近 pdfplumber 的原始 `fill` 字段），但 JSON 与 CSV 的 `fill` 列会与 Python 版不同；集成测试跳过该字段的通用比较，另有一个用例显式固定 Cangjie 的值。
21. **参数 JSON 类型错误的文案来自 CangjieMagic 转换层。** 例如 `page: "1"`、`format: 123`、`object_types: "word"` 分别返回 `Convert to Int error. Value: "1"`、`Convert to String error. Value: 123`、`Convert to Array error. Value: "word"`，仍是 `isError:true`，但不是 Python 版的 `Invalid page number` / `Invalid format` / `Invalid object_types` 文案。客户端应优先看 `isError`，不要依赖逐字匹配这些转换错误。
22. **`stream_id` 更严格。** 仓颉版要求整串匹配 `p<digits>_img_<digits>`；Python 的 `re.match` 接受前缀，所以 `p1_img_0xyz` 在 Python 可解析，在仓颉版返回 `{"error":"Invalid stream_id: p1_img_0xyz"}`。合法 `stream_id` 的行为一致。
23. **损坏/截断 PDF 的失败方式。** 页面树截断、引用消失或 `/Kids` 不可读时，仓颉版在**打开阶段**报 `Cannot open ... not a valid PDF. Underlying error: cannot read the page tree: ...`，不会再静默返回 0 页；合法空页树（`/Kids []`、`/Type /Pages /Count 0`）仍正常返回 0 页。页对象可读但 `/Contents` 的 `/Length` 不可信且没有 `endstream` 时，在提取阶段报 `Failed to read ...`。客户端必须检查 `isError`，不能只凭 `pages == 0` 判断文件是否损坏。
24. **页树引用环 / 悬空 `/Contents` 引用：仓颉更严格。** 页树引用环在打开阶段报 `PdfError`（`page tree: reference cycle at ...`）；悬空 `/Contents` 引用在读取该页内容时抛 `the /Contents stream is missing or unreadable`（最终以 `Failed to read ...` 返回）。Python/pdfplumber 对前者会截断为 1 页、对后者返回空白页。这是有意的健壮性收紧：宁可显式失败，也不静默给出半份数据。
25. **错误但可恢复的 `/Length`：容差方向不同。** 当 `/Length` 明显错误、但文件中存在真实 `endstream` 时，仓颉版回退到 `endstream` 关键字扫描并成功读取；Python 可能报 `Failed to read ... byte string is too large`。反向的“声明长度超过文件末尾且没有 `endstream`”两边都失败。注意这是**容差方向不同**，不是说仓颉版对任意坏 `/Length` 都能恢复。
26. **超大导出的临时文件权限与原子性。** 仓颉版写入 `pdf-inspector-<16 位十六进制>-<name>` 后立即 `chmod 0600`；Python 的 `tempfile.mkstemp` 从创建起就是 `0600` 且带 `O_EXCL`。仓颉版仍是“先 `exists` 再写入”，**不是原子创建**，存在已记录的 TOCTOU 窗口（名字需要被抢先猜中，且写入后立刻收紧权限）；这是当前工具链没有 `mkstemp`/`O_EXCL` 绑定下的折中。

除此之外，工具名、参数、返回字段、JSON/CSV 结构、1 MB 策略、合法 `stream_id` 的形制与错误分类都与 Python 版对齐。

## 测试与验证

### 单元测试（`cjpm test`）

解析内核与 MCP 层现在是两个工程，测试分开统计：

```bash
# 1) 解析库
cd pdf4cj
~/.cjv/bin/cjv run lts-1.0.0 cjpm test

# 2) MCP 工程（会连带构建 path 依赖 pdf4cj）
cd ../cangjie
~/.cjv/bin/cjv run lts-1.0.0 cjpm test
```

当前检出：库 **61 个用例，PASSED 61，SKIPPED 0，FAILED 0**；MCP **89 个用例，PASSED 89，SKIPPED 0，FAILED 0**（61 个单测 + 28 个 golden 集成用例）。两者合计 150。

库的测试在 `../pdf4cj/src/test/`（package `pdf4cj.test`），MCP 的测试在 `cangjie/src/tests/`：

| 文件 | 覆盖 |
|------|------|
| `pdf4cj/src/test/content_test.cj` | 词切分、格式辅助、手写内容流的 `extractPage` 端到端 |
| `pdf4cj/src/test/document_test.cj` | 损坏/截断文档、页面树引用环、悬空 `/Contents`、无 `/Contents`、`/Length` 越界与合法空页树（8 个回归用例） |
| `pdf4cj/src/test/font_test.cj` | CMap、编码、宽度、标准 14 字体等 |
| `pdf4cj/src/test/image_test.cj` | 格式识别、原始采样转 PNG、`/Decode`、非法布局 |
| `pdf4cj/src/test/table_test.cj` | 有框线网格、空单元格、多行单元格、分离网格、无线文本 |
| `src/tests/export_test.cj` | JSON/CSV 结构、数字/颜色格式、文件名、对象类型过滤 |
| `src/tests/tools_test.cj` | JSON 转义、浮点格式、路径校验、`DocumentManager` LRU/失效 |
| `src/tests/integration_test.cj` | 28 个用例：逐 fixture 对比 Python golden（metadata/page/document/fonts/export JSON+CSV），并通过工具层验证错误文案 |

> 测试数量会随本分支的并行工作变化；以上是本文写作时 `cjpm test` 的实际统计，最终以命令输出为准。

### 协议冒烟（`scripts/smoke-mcp.sh`）

```bash
cd cangjie
bash scripts/smoke-mcp.sh
```

它会构建、用一个进程喂入多个 `initialize`（`2024-11-05`、`2025-06-18`、不支持的 `9999-01-01`）、`notifications/initialized`、`tools/list`、`ping` 和一次失败的工具调用，运行时断言 **73 项**：协议版本只回显支持的值、6 个工具齐全、每个工具是 `{name, description, inputSchema}`（不出现内部的 `parameters` 键）、`inputSchema.required` 正确、`Option` 参数是 `anyOf [schema, null]` 且带 `default: null`、`object_types` 的底层类型是数组、通知不回复、失败调用 `isError:true` 等。早期版本里的“占位工具/占位提示”已移除：现在用真实的 `pdf_get_metadata` 缺失路径触发失败，并断言 `isError:true` 与 `Invalid PDF path`。

### 端到端（`scripts/e2e-smoke.sh`）

```bash
cd cangjie
bash scripts/e2e-smoke.sh
```

它做五件事：

1. 用仓库根的 `.venv/bin/python` + `tests/pdf_fixtures.py` 生成 fixtures，另加脚本内生成的大页、加密文档和非 PDF 样本；主对话请求表共 32 条（其中 1 条是通知）；
2. 用 LTS 1.0.0 构建；
3. 在**同一个 server 进程**里跑完整对话：三个 `initialize`（支持的两个版本 + 一个不支持版本）、`tools/list`、六个工具的正常与错误路径；
4. 对真实载荷断言：`tools/list` 的 `{name, description, inputSchema}` 形状、文本、表格、字体统计、图片字节、内联/落盘/临时文件三种导出、临时文件 `0600`、10 类错误文案、错误之后服务器仍能回答；
5. 再**直接运行** `target/release/bin/pdf_inspector_mcp`，发 3 条请求，验证 stdout 每一行都是 JSON-RPC、启动 banner 只在 stderr。

当前检出：**206 项检查全部通过**；主对话 31 条 JSON-RPC 响应（32 条请求中有 1 条通知），另 3 条直接运行构建产物的请求全部有响应，0 失败。需要 `cangjie/libs` 与 `pdf4cj/stdx` 两份 stdx 与仓库根 `.venv`（reportlab）；可用 `CJV`、`CJ_TOOLCHAIN`、`PDF_INSPECTOR_CJ_WORKDIR`、`PYTHON` 覆盖默认值。临时目录默认 `/tmp/pdf-inspector-cj`。直接运行构建产物那一步会自己把 `target/release/pdf4cj`（`libpdf4cj.so`）加进 `LD_LIBRARY_PATH`。

### golden 与 fixtures

`cangjie/tests/` 是**Python 基线**：

```bash
# 在仓库根执行
.venv/bin/python cangjie/tests/generate_fixtures.py
.venv/bin/python cangjie/tests/generate_goldens.py
```

- `fixtures/`：**15 个 PDF**（text、multipage、table、image、styled、blank、zero、mediabox、jpeg、quoted-table、xref-stream、xref-stream-flate、garbage、encrypted、corrupt-stream）。前 12 个可读，后 3 个分别覆盖“不是 PDF”“加密”“结构可读但页内容损坏”。
- fixture 的生成分两路：常规文档复用仓库根 `tests/pdf_fixtures.py` 的辅助函数（与 Python 测试同一批字节），特殊样本（jpeg、quoted-table、xref-stream/ObjStm、garbage、encrypted、corrupt-stream）由 `generate_fixtures.py` 手写或 reportlab/Pillow 生成。
- `goldens/`：**72 个文件** = 12 个可读 fixture × 6 类输出（metadata/page1/document/fonts/export.json/export.csv）− `zero.page1.json`（0 页无第 1 页）+ `errors.json`。全部由 Python 版的 `PdfExtractor` 与 `export.py` 生成，不是手写的期望值。
- `errors.json` 记录 9 个错误场景的关键片段（不是完整消息，避免路径/临时目录造成机器相关）。
- 生成是确定性的：reportlab 用 invariant 模式，PNG/JPEG 无时间戳，手写 PDF 固定对象号；本次实际重跑两个脚本，15 个 fixture 与 72 个 golden 的 sha256 全部未变。
- **改 fixture 必须重跑两个脚本**；golden 过期应当让对比失败，而不是被静默接受。这条约定与每个 fixture 固定了什么的完整清单写在 [`tests/README.md`](tests/README.md) 里。

golden 的意义是“同一批字节上，Python 版的输出是什么”。`src/tests/integration_test.cj` 逐个读取这些文件，把 Cangjie 引擎的输出与 Python 基线对比。

对比容差（与测试代码一致）：

| 字段 | 容差 |
|------|------|
| bbox（`x0/y0/x1/y1`） | ±1.0 |
| 尺寸/宽度/字号（`size`、`*_w`、`*_h`、`width`、`height`、`sizeMin/Max`） | ±0.01 |
| 颜色分量 | ±0.001 |
| 文本、计数、页码、表格单元格、JSON 形状、CSV 分段 | 精确相等 |

有两处**有意不比较**的已知偏差（测试文件头有说明）：

1. `rects[].fill`：Python 版 extractor 用 `non_stroking_color is not None` 推导，导致任何 `rect` 都报 `fill:true`（即使 `re S` 仅描边，pdfplumber 自己的 `rect["fill"]` 也是 `false`）；Cangjie 按实际绘制操作符（`S` → false，`f`/`B` → true），所以 `table.pdf`/`quoted-table.pdf` 的 `rect.fill` 是 `false`。集成测试跳过该字段，另有一个用例显式固定 Cangjie 的值；JSON/CSV 的 `fill` 列会与 Python 版不同。
2. `words` 顺序：Cangjie `buildWords` 按基线降序、`x0` 升序的阅读顺序输出，pdfplumber 在内容流绘制顺序与阅读顺序不一致时保留内容流顺序。12 个 fixture 中 11 个完全一致；`quoted-table.pdf` 先画 y=710 的 `a,"b`，再画 y=698 的 `c`，最后画 y=700 的 `plain`，Python 是 `['a,"b','c','plain']`，Cangjie 是 `['a,"b','plain','c']`。该 fixture 的 CSV 对比因此跳过词 `text` 列（字符与表格文本仍精确比较）。

这两点也列在「[与 Python 版的已知差异](#与-python-版的已知差异)」中。

### 一次完整验证（`scripts/test-all.sh`）

```bash
cd cangjie
bash scripts/test-all.sh
```

它按顺序跑四个阶段，任一失败即停止并打印汇总：

| 阶段 | 内容 |
|------|------|
| `pdf4cj cjpm test` | 在 `../pdf4cj` 里跑解析库自己的 61 个用例（MCP 导入的就是它） |
| `cjpm build` | 编译 server 与调试驱动（连带构建 path 依赖 pdf4cj，产出 `libpdf4cj.so`） |
| `cjpm test` | 单测 + golden 集成测试（89 个用例） |
| `e2e-smoke` | 真实 stdio JSON-RPC 对话（206 项检查） |

本机最新实测（`cjpm clean` 后的一次完整运行）：`pdf4cj cjpm test PASS (11s)`、`build PASS (42s)`、`test PASS (45s)`、`e2e PASS (44s)`，最终 `All stages passed.`，退出码 0。任一阶段失败时脚本会打印汇总并以该阶段的**非 0 状态**退出（不会再把失败吞成 0）。`libs/` 或 `pdf4cj/stdx/` 不存在时会先自动执行 `setup-stdx.sh`；脚本自己 `export CANGJIE_STDX_PATH`（指向 `pdf4cj/stdx/cangjie-stdx-linux-x64-1.0.0.1`），`CJV`/`CJ_TOOLCHAIN` 可覆盖默认工具链。

**不要同时运行两个构建/测试进程**：它们共享 `cangjie/target/`，会互相覆盖 magic 的 `.so`，产生 `file format not recognized`、`DSO missing from command line` 或 `Permission denied` 之类的链接/启动错误。上面的失败大多不是源码问题；等另一个进程结束后重跑即可（必要时 `cjpm clean` 再构建）。

## 安全提示

与 Python 版相同，仓颉版**不是**一个可以暴露给不可信客户端的服务：

- **无认证、无访问控制**：任何能连上 stdio 的客户端都可以调用全部工具。
- **可读本地任意文件**：`path` 就是文件系统路径，按服务器进程权限打开；不要求 `.pdf` 后缀，解析失败才报错。不要把它交给不可信 Agent 或多人共享环境。
- **调用方决定落盘位置**：`pdf_export` 的 `output_path` 可以写到进程有权限的任何位置；父目录必须存在，但不会做沙箱校验。
- **临时文件不自动清理**：超限导出写入 `TMPDIR`/`/tmp`，进程退出后仍保留；需要调用方自行清理。文件写入后会被 `chmod 0600`，但名字是“先检查再写入”预留的，不是原子 `mkstemp`/`O_EXCL`，仍有已记录的 TOCTOU 窗口。
- **加密文档无法读取**：不要把它当成“支持口令的 PDF 服务”；它只能识别并拒绝。
- **只监听 stdio**：不开放网络端口。不要把它改成对外监听而不加防护。
- **stdout 只用于协议**：诊断在 stderr。用 `cjpm run` 启动时 `cjpm` 自己会污染 stdout（见上文），真实客户端应直接运行构建产物。

## 开发提示（Cangjie 1.0.0 踩坑）

1. **工具链必须是 LTS 1.0.0**。CangjieMagic dev 在 1.2.0 下编译失败；所有命令都写 `cjv run lts-1.0.0`。
2. **不要对 `Exception` 调用 `toString()`**。在这个工具链上，异常类的动态 `toString()` 会直接终止进程；只打印 `e.message`（参见 `server.cj` 的 `logFailure`）。同理，不要对 `JsonValue`/数组依赖 `toString()` 拼 JSON：`JsonValue` 用 `toJsonString()`，数组自己 join。
3. **`JsonValue` 的访问器是 unchecked cast**。`asString()`/`asObject()`/`asArray()` 在 kind 不匹配时不是返回 `None`，所以先 `value.kind()` 再取；`server.cj` 的 `readString`/`readObject` 就是这个模式。
4. **`@tool` 的 `parameters` 是裸标识符 map**：写 `parameters: {path: "...", password: "..."}`，不是 JSON 字符串、不是 `{"path": ...}`。参数名、顺序、`Option` 性都是公开 schema 的一部分，不要改。
5. **`cjpm run` 要带 `--name`**：项目有多个 package configuration（`pdf_inspector_mcp`、`.debug`、`.extractdebug`），用 `--name pdf_inspector_mcp` 明确入口；调试驱动用 `--name pdf_inspector_mcp.debug` / `.extractdebug`。
6. **`--run-args` 接收一个 shell 转义后的字符串**，不是 `--` 分隔的列表。`scripts/debug-dump.sh` 用 `printf '%q ' "$@"` 拼参数。
7. **`Float64.toString()` 固定 6 位小数**（`0.500000`），不能用于 JSON/CSV。需要两套格式化：`jsNumberText`（JS 风格，用于坐标/尺寸）和 `formatFloatPy`（Python `repr(float)` 风格，用于字体统计），分别见 `export/json.cj` 与 `mcp/jsonutil.cj`。
8. **`stdx.encoding.json.JsonObject` 是哈希表**，键顺序不可控；需要固定字段顺序时用有序树（`export/json.cj` 的 `JNode`）。
9. **`stdx` 的 `JsonFloat` 固定 6 位小数**（`612.000000`），所以数字必须自己渲染，不能直接用 `JsonFloat`。
10. **`@tool` 函数返回 `String`（JSON 文本）**，不是对象；MCP 层只把它塞进 `content[0].text`。这样工具 schema 与 Python 版一致，也避免依赖 magic 的结构化输出。
11. **`Option<T>` 决定 required**：`tools/list` 先取 `tool.toJsonValue()` 的内部 schema，再把其中的 `parameters` 放到 MCP 的 `inputSchema` 下；它读的是 `ToolParameter.required`。不要直接把 `toJsonValue()` 原样返回——magic 的 `{name, description, parameters}` 不是 MCP 的 `{name, description, inputSchema}`。
12. **生成文件不要手改**：`../pdf4cj/src/metrics_data.cj` 与 `../pdf4cj/src/encoding_data.cj` 由 `cangjie/scripts/gen_font_data.py` 生成（数据源：reportlab、pdfminer、Adobe Glyph List，输出 `package pdf4cj`），需要更新时跑脚本并在 `pdf4cj/` 里重新测试。
13. **构建慢/并发构建互相破坏**：`cjpm` 会构建 magic 的示例可执行文件；两个 `cjpm` 进程同时写 `cangjie/target/` 时会出现 `.so` 找不到、格式不认识或 `Permission denied`，等另一个进程结束再重跑（必要时 `cjpm clean`）。`cjpm test` 每次会先重建依赖，约 40–60 秒。
14. **编译器警告**：`server.cj` 的字符串跨行 `+` 会报 `possibly confusing line terminator`；`tools.cj` 的 `std.posix.chmod` 在 LTS 1.0.0 是 deprecated。两条都可忽略；不要为了消警告改协议字符串，也不要因此去掉临时文件的权限收紧。

## 许可证

与仓库一致，MIT。解析与导出行为参照同一作者的 [pdf-inspector](https://github.com/EthanCheung-gh/pdf-inspector) 与 Python 版 `pdf-inspector-mcp`。
