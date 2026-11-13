# 测试语料（fixtures）

`tests/fixtures/` 下是本库的 PDF 回归语料。`src/test/fixtures_test.cj` 对每个文件都有端到端断言；
`src/test/document_test.cj` 里的损坏文档用例也直接读这里的文件。其余单测用**写临时文件**的方式
在运行时构造 PDF（`content_test.cj`、`table_test.cj`、`image_test.cj`），这样边界输入
（未闭合字符串、坏 `/Length`、页树引用环）不必污染语料目录。

## 清单

| 文件 | 字节 | 生成方式 | 用于验证 |
|------|------|----------|----------|
| `text.pdf` | 1341 | reportlab（`tests/pdf_fixtures.py::make_text_pdf`） | 单页文本、Helvetica、`alphaword`、`/Info` 的 Title/Author/Producer |
| `multipage.pdf` | 2244 | reportlab（`make_multipage_pdf`） | 3 页、页树遍历与按页码取页 |
| `table.pdf` | 1421 | reportlab（`make_table_pdf`） | 2x2 有框线表格（矩形 + 两条线）、`rects`/`lines` 计数 |
| `styled.pdf` | 2419 | reportlab（`make_styled_multipage_pdf`） | 多页多字体多颜色，字体/颜色聚合 |
| `image.pdf` | 1660 | reportlab + Pillow（`make_image_pdf`） | 嵌入 PNG 图片、`ImageObj` 的位置与尺寸（重生成有路径依赖，见「来源」） |
| `jpeg.pdf` | 1307 | reportlab + Pillow（`make_single_image_pdf(..., 'DCTDecode')`） | `DCTDecode` JPEG 原样透传 |
| `blank.pdf` | 414 | reportlab（`make_blank_pdf`） | 空白页：`/Contents` 是 `/Length 0` 的空流 |
| `mediabox.pdf` | 589 | reportlab（`make_mediabox_text_pdf`，`/MediaBox [0 100 612 892]`） | 页面框原点非零时的坐标平移 |
| `zero.pdf` | 233 | reportlab（`make_zero_page_pdf`，生成 `/Kids [] /Count 0`） | 合法空页树 → 0 页而不是报错 |
| `quoted-table.pdf` | 1418 | reportlab（本仓库脚本内构造） | 单元格含引号与换行的表格；也用于固定"内容流绘制顺序 ≠ 阅读顺序"的场景 |
| `xref-stream.pdf` | 621 | 手写（本仓库脚本内构造） | xref stream（`/Type /XRef`、`/W [1 4 2]`）+ 未压缩 `/ObjStm` |
| `xref-stream-flate.pdf` | 607 | 手写（同上，FlateDecode + PNG Up predictor 12） | 压缩对象流 + 带 predictor 的 xref stream |
| `encrypted.pdf` | 1814 | reportlab `StandardEncryption('userpw', ownerPassword='ownerpw')` | 加密检测：`open` 必须失败且消息含 `password required or incorrect` |
| `corrupt-stream.pdf` | 1342 | reportlab 后把内容流载荷逐字节替换为 `0xFF` | 结构可读、内容流损坏；读取该页内容时抛错 |
| `garbage.pdf` | 184 | 纯文本（`b'this file is not a PDF\n' * 8`） | 非 PDF 文件必须被拒绝 |

合计 **15 个文件，约 17 KB**。

## 来源

全部语料由 Python 的 **reportlab**（`rl_config.invariant = 1`，固定 `/ID` 与 1980-01-01 时间戳）
与 **Pillow** 生成，另加几个手写 PDF（xref stream / ObjStm / 空页树）。生成器随库提供：
`tests/generate_fixtures.py` 与它调用的 `tests/pdf_fixtures.py`，只写本目录，不读取本库之外的
任何路径。开发期依赖见 [`tests/requirements.txt`](./requirements.txt)（reportlab + Pillow）。

生成结果基本是确定性的：**15 个文件里 14 个**，无论重复生成还是在任意目录生成，都会得到逐字节
相同的文件（前提是 reportlab / Pillow 大版本与提交时一致——reportlab 决定内部对象布局，升级小版本
也可能改变字节，见 `tests/requirements.txt` 的说明）。

唯一例外是 `image.pdf`，原因在 reportlab 的资源命名：它把传给 `Canvas.drawImage` 的
**文件路径字符串**做 md5，用作 Form XObject 的资源名 `FormXob.<md5>`。本目录提交的
`image.pdf`（1660 字节）是在别的目录生成的，换成当前目录重新生成会得到 1658 字节的文件：

- 唯一的语义差异就是这个资源名（例如 `FormXob.101aa79e…` → `FormXob.4868d931…`，都是 32 位十六
  进制，长度不变）；
- 这个名字出现在页面内容流里，压缩后长度变了 2 字节，于是该对象的 `/Length` 与整个 xref 的偏移
  一起平移 2 字节；
- 解码后的内容流文本、嵌入的像素、其它所有对象都完全一致，用本库抽取的结果（图片尺寸、位置、
  PNG 载荷）也不变。

也就是说：**不要期待 `image.pdf` 在任何机器上都逐字节可复现**；需要与提交版本完全一致的字节时，
请直接使用仓库里的文件，或按上面的目录重新生成一次后接受这点差异。其余 14 个文件是稳定的。

## 如何重新生成

生成器随本库提供，不依赖任何外部仓库：

```shell
# 在 pdf4cj/ 目录下执行
pip install -r tests/requirements.txt   # reportlab + Pillow，仅开发期需要
python3 tests/generate_fixtures.py
```

脚本会先删掉 `tests/fixtures/*.pdf`，再重新生成 15 个文件，最后打印每个文件的字节数与
sha256 前缀，便于和提交版本对照（注意上面 `image.pdf` 的例外）。

`generate_fixtures.py` 的头部注释说明了每个文件的构造细节（包括 `xref-stream*.pdf` 的对象布局、
`corrupt-stream.pdf` 的破坏方式、`encrypted.pdf` 的口令、`image.pdf` 的路径依赖）。如果脚本有变化，
请同步更新本文件的「清单」表。

## 注意事项

- **不要手改二进制**：PDF 里的 xref 是**字节偏移**，任何插入/删除（包括换行符转换）都会让偏移
  失效。修改语料请走生成脚本。
- **不要让 Git 改变行尾**：本目录的 `.gitattributes` 把 `tests/fixtures/*.pdf` 标记为
  `binary`，避免 `core.autocrlf` / `text=auto` 把 CRLF 换成 LF 而破坏偏移。克隆后若发现
  `text.pdf` 打不开，先检查 `git config core.autocrlf` 与 `.gitattributes` 是否生效。
- **期望值要带容差**：坐标和 `size` 由浮点运算反推，末位可能与其它实现不同（例如
  `12.000000000000002`）。新用例请用容差比较，不要逐位相等。
- **坐标约定**：`chars`/`words`/`rects`/`lines`/`curves`/`images` 是 PDF 用户空间（y 向上，
  原点平移到页面框左下角）；`TableObj` 用自上而下的 y。`mediabox.pdf` 就是用来固定这条约定的：
  `/MediaBox [0 100 612 892]` 时报告出来的坐标与 `text.pdf` 应落在同一视觉位置。
- **加密语料只验证"拒绝"**：`encrypted.pdf` 的口令是 `userpw`，但 v0.1.0 不支持解密，用例断言
  的是失败消息，而不是解密后的内容。
- **`image.pdf` 的重生成有路径依赖**：见上文「来源」——换目录重新生成只改变 `FormXob.<md5>`
  资源名与由此产生的 2 字节长度差，像素和抽取结果不变；提交版本固定使用仓库里的这份文件。
- **每个 fixture 都有用例**：`src/test/fixtures_test.cj` 对 15 个文件各给出至少一条端到端断言
  （页数、单词、表格单元格、图片格式、损坏文件的错误消息）。新增 fixture 时请在那里补一条，
  否则下次重构容易漏掉——一个没人读的语料等于没有。
