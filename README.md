# PDF Inspector MCP

把 [pdf-inspector](../pdf-inspector) 的 PDF 结构解析与导出能力，以 [Model Context Protocol](https://modelcontextprotocol.io) 工具的形式提供给任意 MCP 客户端（Claude Desktop、IDE 插件、自研 Agent 等）。

服务本身没有界面：客户端传入 PDF 路径，就能拿到与上游 Inspector 一致的对象级数据——字符、单词、矩形、线段、曲线、图片、表格——以及字体统计和 JSON/CSV 导出。

## 与上游的关系

本项目的解析与导出逻辑是 [pdf-inspector](https://github.com/EthanCheung-gh/pdf-inspector) **v0.2.0 的内联移植**，不是重新实现：

| 本仓库文件 | 上游来源 | 改动 |
|------------|----------|------|
| `src/pdf_inspector_mcp/extractor.py` | `sidecar/extractor.py` | 逐行移植；额外加了 `page_count()` 与 `extract_pages()` 两个方法（工具层需要，侧车原本由请求循环完成） |
| `src/pdf_inspector_mcp/objects.py` | `src/renderer/types/pdf-objects.ts` | TypeScript 类型改为 `TypedDict` / `Literal`，字段名与顺序保持一致 |
| `src/pdf_inspector_mcp/export.py` | `src/renderer/services/export-data.ts` | 逐行移植；JSON 结构、CSV 分段、文件名规则与上游一致 |

移植时做的**行为收紧**（上游是给渲染进程用的，这里要直接面对任意客户端输入，坏输入不能变成崩溃或错误数据）：

| 场景 | 上游 | 本仓库 |
|------|------|--------|
| `metadata.version` | 直接读 pdfminer 的 `pdf_version` 属性（新版 pdfplumber 已移除该属性，上游路径会拿到空值） | 真实版本号：pdfplumber 属性 → 文件头 `%PDF-x.y`（在前 1024 字节内搜索，容忍头部前的垃圾字节）→ `unknown`（仅当文件头确实不可读） |
| `extract_page(0)` / 负数页 | 当作负索引，返回末页等错误数据 | 抛 `ValueError`（`Invalid page number: 0 (document has N pages)`） |
| `get_image_data('p9_img_0')`（页越界） | 抛 `IndexError` | 返回 `{'error': 'Invalid stream_id: ...'}` |
| 解析失败（打开与提取两阶段） | 侧车对**任何**异常都回传 `str(e)`（`sidecar/main.py`），客户端能读到原始原因 | 已知的 pdfminer/pdfplumber 解析异常同样转成带原因的用户错误：打开阶段 `Cannot open '<path>': ...`，提取阶段 `Failed to read '<path>': <原因>`；只有**未预期**的内部错误才退回通用提示（traceback 留在日志） |

`src/pdf_inspector_mcp/document.py`（文档会话缓存）与 `src/pdf_inspector_mcp/server.py`（MCP 工具层）是本项目新增的部分——上游是 Electron/IPC，这里换成 MCP 的 stdio 传输。

由于是内联移植，上游的字段命名、坐标语义、错误文案与导出格式就是本项目的兼容基线；两者不会各自漂移。

### 未移植：上游的页级缓存

上游侧车的 `sidecar/cache.py` 有一个**页级 LRU 缓存**（缓存已提取的页面数据），本项目**没有移植**：

- `pdf_extract_page` 对同一页重复调用会重新执行版面分析（pdfplumber 的 char/word 提取），不会命中页级缓存；
- 跨页、跨工具复用靠的是本项目的 `DocumentManager`：它按 `(绝对路径, password, mtime_ns, size)` 缓存**已打开的 PDF 句柄**（不是页数据），因此重复调用省掉的是"打开/解析文档结构"这一步，而不是"提取页对象"这一步；
- 唯一的内置记忆化是整档 `pdf_analyze_fonts` 的字体统计结果（按文档缓存，随文件变化而失效）。

需要反复读取同一批页面的客户端，应把结果自行缓存，或一次性用 `pdf_export` 导出。

## 环境要求

- **Python ≥ 3.10**
- 依赖：`mcp` ≥ 2.3、`pdfplumber` ≥ 0.11、`Pillow` ≥ 10（见 `pyproject.toml`）
- 运行测试另需 `pytest`、`reportlab`

## 安装

```bash
python3 -m venv .venv
.venv/bin/pip install -e .

# 运行测试时
.venv/bin/pip install -e ".[dev]"
```

Windows 下把 `.venv/bin/python` 换成 `.venv\Scripts\python`，`pdf-inspector-mcp` 对应 `.venv\Scripts\pdf-inspector-mcp.exe`。

安装后会得到两个等价的入口：

```bash
.venv/bin/python -m pdf_inspector_mcp.server   # 以模块方式启动
.venv/bin/pdf-inspector-mcp                    # console script
```

两者都通过 **stdio** 传输与客户端通信，启动后不打印任何内容，只等待 JSON-RPC 消息。

## 在 MCP 客户端中配置

本服务是 stdio 服务器：客户端负责启动子进程，并通过 stdin/stdout 收发消息。把下面的配置加入 MCP 客户端的配置文件（例如 Claude Desktop 的 `claude_desktop_config.json`），**把路径换成你自己的绝对路径**：

```json
{
  "mcpServers": {
    "pdf-inspector": {
      "command": "/absolute/path/to/pdf-inspector-mcp/.venv/bin/python",
      "args": ["-m", "pdf_inspector_mcp.server"]
    }
  }
}
```

也可以直接指向 console script（此时 `args` 留空）：

```json
{
  "mcpServers": {
    "pdf-inspector": {
      "command": "/absolute/path/to/pdf-inspector-mcp/.venv/bin/pdf-inspector-mcp",
      "args": []
    }
  }
}
```

注意事项：

- `command` 必须是该虚拟环境里的解释器（或 console script）。用系统 `python` 会因为找不到 `pdf_inspector_mcp` 而启动失败。
- 相对路径参数以**服务器进程的工作目录**为基准解析；多数客户端不保证工作目录，建议传绝对路径。
- 想限制缓存文档数，可在配置里加 `"env": {"PDF_INSPECTOR_MCP_MAX_DOCS": "4"}`（默认 8，非法值回退 8）。

## 工具一览

六个工具全部是同步工具，返回 JSON 可序列化的对象；`password` 均为可选参数，仅加密文档需要。`page`、`first_page`、`last_page`、`start_page`、`end_page` 都是 **1-based**。

参数、路径或文档本身不可用时，工具以 `isError=true` 的结果返回一条可读的错误信息（例如 `Invalid format: 'xml' (expected one of 'json', 'csv')`），不会把 traceback 塞进回复；调用方可以据此修正参数后重试。四类常见失败的错误文案：

| 情况 | 消息特征 |
|------|----------|
| 参数/路径非法 | `Invalid format: ...`、`Invalid PDF path: '<path>' (... does not exist)`、`Invalid page number: ...` |
| 加密文档缺少或输错口令 | 含 `password required or incorrect (pass the 'password' argument for encrypted PDFs)`，并以 `Underlying error: PDFPasswordIncorrect` 结尾 |
| 不是 PDF / 文件损坏（打开失败） | 含 `not a valid PDF`，并以原始解析错误结尾（如 `No /Root object! - Is this really a PDF?`） |
| 结构可读、但页内容流损坏（提取失败） | 以 `Failed to read '<path>':` 开头，带上原始解析原因（如 `Non-Ascii85 digit found: ...`），并说明 `the document opened` |

口令失败、"文件损坏"与"页内容损坏"是三种不同的消息：客户端据此可以决定是补 `password`、换文件，还是只换一页/缩小范围再试。未预期的内部错误（真正的程序 bug）不会伪装成用户错误：客户端只看到通用失败提示，堆栈留在服务器日志里。

| 工具 | 参数 | 返回 |
|------|------|------|
| `pdf_get_metadata` | `path`、`password=None` | `{pages, version, encrypted, page_w, page_h, title, author, producer, fonts}` |
| `pdf_extract_page` | `path`、`page`、`password=None` | 单页 PageData：`{width, height, chars, words, rects, lines, curves, images, tables}` |
| `pdf_extract_document` | `path`、`first_page=None`、`last_page=None`、`password=None` | `{metadata, pageCount, pages}`，`pageCount` 是**实际导出的页数** |
| `pdf_analyze_fonts` | `path`、`start_page=None`、`end_page=None`、`password=None` | `{fonts: [{fontname, pages, charCount, sizeMin, sizeMax, colors}]}`，按 `charCount` 降序 |
| `pdf_get_image` | `path`、`stream_id`、`password=None` | 成功 `{base64, format, mime_type, byte_length}`；失败 `{error}`。**唯一不受 1 MB 内联阈值约束的工具** |
| `pdf_export` | `path`、`format='json'`、`scope='document'`、`page=None`、`first_page=None`、`last_page=None`、`object_types=None`、`output_path=None`、`password=None` | 见下方「导出」章节 |

### 典型调用顺序

1. `pdf_get_metadata` 拿到页数、版本与页面尺寸；
2. 用 `pdf_extract_page` 单页细看，或用 `pdf_analyze_fonts` 找主要字体；
3. 需要大量数据时用 `pdf_export` 导出到文件，而不是把大对象塞进对话。

### `stream_id` 与图片

`pdf_extract_page`/`pdf_extract_document` 返回的 image 对象带 `stream_id`，格式固定为 `p<page>_img_<index>`（页内索引从 0 开始，如 `p1_img_0`）。把它交给 `pdf_get_image` 就能取回图片：

- 浏览器可直接显示的格式（png/jpeg/gif/webp）原样返回；
- 其它格式（JPEG2000、JBIG2 等）会尽力转成 PNG；
- 无法解码时返回 `{"error": "..."}`。

`base64` 永远是完整数据，不会截断；`mime_type` 由 `format` 映射，未知格式为 `application/octet-stream`。

**体量例外**：`pdf_get_image` 是唯一不检查内联阈值的工具——图片预览本身就是它的用途，因此 20 MB 的 JPEG 会返回约 27 MB 的 base64 文本。其余工具统一遵守 `MAX_INLINE_BYTES = 1_000_000`。

## 导出：`pdf_export`

### 参数语义

| 参数 | 说明 |
|------|------|
| `format` | `json`（默认）或 `csv`，大小写不敏感 |
| `scope` | `document`（默认，整档或页范围）或 `page`（单页，必须给 `page`） |
| `page` | `scope='page'` 时必填的 1-based 页码；**仅在 `scope='page'` 时有效，`scope='document'` 下被忽略**（限定范围请用 `first_page`/`last_page`） |
| `first_page` / `last_page` | `scope='document'` 时的页范围，均省略即整份文档 |
| `object_types` | `char`/`word`/`rect`/`line`/`curve`/`image`/`table` 的子集；省略 = 全部；未知值忽略、重复去重、顺序规范化为固定顺序；显式空列表表示「不带任何对象数组」 |
| `output_path` | 落盘路径，父目录必须已存在（不会自动创建）；写入时不做换行转换，磁盘字节与序列化结果完全一致 |

### 返回结构

落盘（给了 `output_path`）：

```json
{
  "path": "/data/exports/report-all.json",
  "bytes": 18234,
  "format": "json",
  "scope": "document",
  "object_types": ["char", "word", "rect", "line", "curve", "image", "table"],
  "suggested_filename": "report-all.json"
}
```

内联（未给 `output_path` 且结果不超过 `MAX_INLINE_BYTES = 1_000_000` 字节）：

```json
{
  "content": "{\n  \"metadata\": {...}",
  "bytes": 18234,
  "format": "json",
  "scope": "document",
  "object_types": ["char", "word", "rect", "line", "curve", "image", "table"],
  "suggested_filename": "report-all.json",
  "inline": true
}
```

超限（未给 `output_path` 且结果超过 1 MB）：改为写入系统临时目录，文件名沿用 `suggested_filename` 并加随机前缀，返回 `path`、`inline: false` 和一条 `note`，**不返回 `content`**：

```json
{
  "path": "/tmp/pdf-inspector-4f2c9a1b-report-all.json",
  "bytes": 4120357,
  "format": "json",
  "scope": "document",
  "object_types": ["char", "word", "rect", "line", "curve", "image", "table"],
  "suggested_filename": "report-all.json",
  "inline": false,
  "note": "The export is 4120357 bytes, over the 1000000-byte inline limit, so it was written to /tmp/... "
}
```

`pdf_extract_page` 与 `pdf_extract_document` 有同一套体量保护，但它们不会落盘：超过 1 MB 直接返回错误，提示改用 `pdf_export`（配 `output_path`）或缩小页范围。

### 示例：JSON（整档 + 类型过滤）

```json
// 调用
{"path": "/tmp/report.pdf", "format": "json", "object_types": ["word", "table"]}

// 返回的 content（节选，reportlab 生成的单页示例）
{
  "metadata": {
    "pages": 1,
    "version": "1.3",
    "encrypted": false,
    "page_w": 612.0,
    "page_h": 792.0,
    "title": "untitled",
    "author": "anonymous",
    "producer": "ReportLab PDF Library - (opensource)",
    "fonts": ["Helvetica"]
  },
  "exportedAt": "2025-05-01T09:41:07.512Z",
  "pageCount": 1,
  "objectTypes": ["word", "table"],
  "pages": [
    {
      "width": 612.0,
      "height": 792.0,
      "chars": [],
      "words": [
        {"type": "word", "x0": 72.0, "y0": 697.723, "x1": 96.464, "y1": 708.723,
         "text": "page", "fontname": "Helvetica", "size": 11.0, "page": 1}
      ],
      "rects": [],
      "lines": [],
      "curves": [],
      "images": [],
      "tables": []
    }
  ]
}
```

### 示例：CSV（单页）

```json
// 调用
{"path": "/tmp/table.pdf", "format": "csv", "scope": "page", "page": 1,
 "object_types": ["char", "table"], "output_path": "/tmp/table-p1.csv"}
```

写出的文件（`# <type>` 分段的纯文本 CSV，首个字节是 UTF-8 BOM）：

```csv
# chars
page,x0,y0,x1,y1,text,fontname,size,color
1,60,697.93,67.22,707.93,H,Helvetica,10,0
1,67.22,697.93,72.78,707.93,e,Helvetica,10,0
…
# tables
page,table_index,row,col,text
1,0,0,0,Header A
1,0,0,1,Header B
1,0,1,0,
1,0,1,1,Row B1
```

## 输出格式说明

### JSON

- 顶层字段固定且有序：`metadata`、`exportedAt`、`pageCount`、`objectTypes`、`pages`。
- 两空格缩进、`null` 表示缺失的元数据、非 ASCII 字符不转义（CJK 文本保持可读）。
- `objectTypes` 是**规范化后**的类型列表，按 `char, word, rect, line, curve, image, table` 的固定顺序；未选中的类型对应的页面数组为空数组（不是缺失字段）。
- 单页导出与整档导出共用同一结构，单页时 `pages` 只有一个元素。

### CSV

- 文件以 UTF-8 **BOM**（`\uFEFF`）开头，保证 Excel 正确识别编码。
- 按对象类型分段，每段以 `# <type>` 行开头，紧跟一行表头；段顺序同样是规范顺序。段内无数据时只保留标题与表头。
- `# tables` 每行一个单元格：`page,table_index,row,col,text`；`table_index` 在页内从 0 重新计数。
- 单元格按 JavaScript `String()` 语义格式化：布尔为 `true`/`false`，整数值浮点去掉 `.0`（`12.0` → `12`）。
- **数组值**按 JavaScript `Array.prototype.toString`（等价于 `join(',')`）渲染，而不是 Python 的 repr：char/rect 的 `color` 从 pdfplumber 拿到的可能是元组，`(0,)` → `0`，`(0.1, 0.2, 0.3)` → `0.1,0.2,0.3`，空数组 → 空字段（无内容）。因此 CSV 里的颜色列是 `0` 而不是 `"(0,)"`。
- 仅含逗号、双引号、CR、LF 的单元格才会加引号（RFC 4180）；单元格内部的换行保持 `\n`（写入磁盘时不做 CRLF 转换）。
- `suggest_filename` 的 URL 分支按 WHATWG URL 规范化处理：`.`/`..` 段会被折叠，非法百分号转义（如 `%E0%A4%A`）会使该 URL 段不可用并回退到本地文件名。

### 已知偏差（相对上游 JS 实现）

内联移植无法做到字节级一致，以下两点是**有意保留**的差异：

1. **数字表示**：`JSON.stringify` 把整数输出为 `612`，Python 的 `json.dumps` 输出 `612.0`——坐标与字号来自 pdfplumber，本来就是浮点。除尾随 `.0` 外，键顺序、缩进、`null` 与转义行为一致。
2. **`exportedAt`**：形如 `2025-05-01T09:41:07.512Z`，UTC、毫秒精度、带 `Z` 后缀（对应 `Date.toISOString()`）；Python 默认的 `+00:00` 时区写法不会出现。

## 文件缓存与并发

- 打开过的文档按 `(解析后的绝对路径, password, st_mtime_ns, st_size)` 缓存在内存里；**文件被改写（mtime/大小变化）或口令不同都会重新打开**，不会读到旧内容。
- 缓存的是**已打开的 PDF 句柄**，不是页数据：重复调用省掉"打开/解析文档结构"，同一页的版面分析仍会重跑（上游 `sidecar/cache.py` 的页级 LRU 未移植，见「未移植：上游的页级缓存」）。
- 缓存上限默认 8 份（`PDF_INSPECTOR_MCP_MAX_DOCS` 可改）。超出时按 LRU 淘汰，淘汰时先 `close()` 再丢弃文件句柄。
- 同一个文档的多个调用会**串行执行**：pdfplumber 的 page/extractor 不是线程安全的，每个会话有一把锁，`session()` 在 `with` 期间持有它。不同文档之间互不阻塞。
- 正在被其他线程使用的会话本轮不参与淘汰，宁可短暂超出上限，也不会把别人手里的文件句柄关掉。
- 路径校验：`~` 会展开、符号链接会解析，必须是**存在的普通文件**，否则报错并说明收到的是什么路径、为什么不接受。不强制 `.pdf` 后缀。

## 开发与测试

```bash
# 全仓测试
.venv/bin/python -m pytest -q

# 只跑工具层
.venv/bin/python -m pytest tests/test_server.py -q

# 手动验证 stdio 启动（无输出、等待 stdin 即为正常）
printf '' | .venv/bin/python -m pdf_inspector_mcp.server
```

`tests/test_server.py` 里有一个**真实端到端**用例：用 `stdio_client` 以子进程方式启动服务，依次完成 `initialize()` → `list_tools()`（断言六个工具齐全）→ `call_tool()`：正常元数据、非法参数、加密文档缺口令、越界页码、以及「能打开但页内容流损坏」五类调用都会校验返回文本。若运行环境无法启动子进程，该用例会显式 `skip` 并给出原因，不会静默通过。

「页内容流损坏」的样本不用桩：测试先让 reportlab 生成正常 PDF，再把该页内容流的载荷整段替换为等长的 `0xFF` 字节（`/Length` 与所有 xref 偏移保持不变），于是文档仍能打开、页树与字体可读，但解析该页时 pdfminer 抛出真实异常（`Non-Ascii85 digit found`）。另有两条 `monkeypatch` 用例分别覆盖"未包装的 `PDFSyntaxError`"与"提取阶段的 `AttributeError` 必须保持为崩溃"。

测试用 PDF 由 `tests/pdf_fixtures.py` 在 `tmp_path` 里现场生成（reportlab + 手写 PDF），不依赖仓库里的二进制样本。

## 安全提示

- **没有认证与访问控制**：任何能连上该 stdio 通道的客户端都可以调用全部工具。
- **可读本地任意文件**：`path` 参数就是文件系统路径，工具会按进程权限打开它（解析失败才报错）。只应把本服务交给**可信客户端**使用，不要在多人共享或可被注入的 Agent 环境里随意启用。
- **调用方决定落盘位置**：`pdf_export` 的 `output_path` 会把文件写到进程有权限的任何位置；临时文件（超限导出）不会被自动清理。
- 服务只监听 stdio，不开放网络端口；不要把 `mcp.run()` 改成对外监听而不加防护。

## 项目结构

```
src/pdf_inspector_mcp/
  __init__.py     版本号；保持无副作用导入
  objects.py      对象类型契约（TypedDict / Literal）
  extractor.py    pdfplumber 封装：页面、字体、图片（移植自 sidecar/extractor.py）
  export.py       JSON/CSV 序列化与文件名（移植自 export-data.ts）
  document.py     文档会话缓存、LRU、每文档锁
  server.py       MCP 工具层与 stdio 入口
tests/
  pdf_fixtures.py 测试 PDF 生成器
  conftest.py     公共 fixture
  test_extractor.py / test_export.py / test_document.py / test_server.py
```

## 已知限制

- 一次只能处理一个工具调用内的单份文档；跨文档的比较需要客户端多次调用。
- 加密 PDF 只支持「把口令作为 `password` 传进来」这一条路径，不支持证书解锁、权限位校验或交互式提示。
- 字体分析需要逐字符遍历；超大文档的整档分析耗时与页数成正比（没有上游那种分批进度反馈）。整档 `pdf_analyze_fonts` 的结果会在会话内缓存直到文档变化。
- 表格检测使用 pdfplumber 的默认策略，只对**有框线**的表格稳定；无线表格不会被识别。
- `metadata.version` 依赖文件头是否可读：pdfplumber 的版本属性已移除，因此实际取到的是文件头 `%PDF-x.y`（在前 1024 字节内搜索）；只有连文件头都读不到时才返回 `"unknown"`。
- 图片解码依赖 Pillow 的编解码器；缺少 JPEG2000 等支持时对应图片返回 `{"error": ...}` 而不是转码结果。
- **体量策略的两处例外**：`pdf_get_image` 永远返回完整 base64（不受 1 MB 限制）；其余工具（`pdf_extract_page`、`pdf_extract_document`、`pdf_export` 的内联分支）在超过 `MAX_INLINE_BYTES = 1_000_000` 字节时或报错、或改为落盘。客户端应预期单张图片的响应可能远大于其他工具。
- 未预期的内部错误（程序 bug，如 `AttributeError`/`TypeError`/`KeyError`）不会转成可读消息：客户端只看到通用失败提示，堆栈留在服务器日志里。**已知的** pdfminer/pdfplumber 解析异常在打开与提取两个阶段都会转成带原因的用户错误（`Cannot open ...` / `Failed to read ...`）；同样可见的还有路径非法、口令缺失/错误与非法参数。
- 超限导出写入系统临时目录的文件没有自动清理机制。

## 许可证

本项目以 [MIT 协议](LICENSE)发布，版权归 EthanCheung 所有；解析与导出逻辑移植自同一作者的 [pdf-inspector](https://github.com/EthanCheung-gh/pdf-inspector)，同样在此协议下使用。
