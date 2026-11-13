# pdf4cj 示例

一个最小可运行程序，演示 `pdf4cj` 的四个公开入口：

- `PdfDocument.open` + `metadata()`：文档级信息（页数、版本、首页尺寸、字体、`/Info`）；
- `extractPage`：页面对象统计（chars / words / rects / lines / curves / images）；
- `extractTables`：有框线表格的行列与单元格文本；
- `imagePayload`：把页面上的图片转成可显示的 MIME + base64 载荷。

源码：[`src/main.cj`](./src/main.cj)（约 150 行，含注释）。

## 依赖

本模块通过 `path` 依赖上层库：

```toml
[dependencies]
  pdf4cj = { path = ".." }
```

因此需要先让 `CANGJIE_STDX_PATH` 指向 cangjie-stdx 1.0.0.1（`pdf4cj` 用它的
`compress.zlib` 与 `encoding.base64`）：

```shell
# 在 pdf4cj/ 目录下执行一次即可（幂等）
bash ../scripts/setup-stdx.sh

# 每个新 shell 都要设；路径按实际解压位置调整
export CANGJIE_STDX_PATH="$(cd .. && pwd)/stdx/cangjie-stdx-linux-x64-1.0.0.1"
```

## 构建

```shell
cd pdf4cj/example
~/.cjv/bin/cjv run lts-1.0.0 cjpm build
```

产物：`target/release/bin/main`（cjpm 的默认产品名就是 `main`）。

> 想给产物一个有意义的名字，用 `-o`：`cjpm build -o pdf4cj-example`
> 会生成 `target/release/bin/pdf4cj-example`。

## 运行

```shell
# 语法：pdf4cj-example <file.pdf> [page]
~/.cjv/bin/cjv run lts-1.0.0 cjpm run --run-args "../tests/fixtures/table.pdf 1"
```

`cjpm run` 会自动把仓颉运行时、`libpdf4cj.so` 与 stdx 的 `.so` 加进运行期库路径。
**直接执行产物**时需要自己补上后两者（仓颉运行时用 `cjv run` 注入），否则会报
`libpdf4cj.so: cannot open shared object file`：

```shell
LD_LIBRARY_PATH="target/release/pdf4cj:${CANGJIE_STDX_PATH}/linux_x86_64_llvm/dynamic/stdx" \
  ~/.cjv/bin/cjv run lts-1.0.0 ./target/release/bin/main ../tests/fixtures/table.pdf 1
```

用命名产物时：

```shell
~/.cjv/bin/cjv run lts-1.0.0 cjpm build -o pdf4cj-example
~/.cjv/bin/cjv run lts-1.0.0 cjpm run --name pdf4cj-example --skip-build --run-args "../tests/fixtures/table.pdf 1"
```

## 实际输出

`../tests/fixtures/table.pdf 1`（reportlab 生成的 2x2 有框线表格）：

```text
file: ../tests/fixtures/table.pdf
document: pages=1 version=1.3 encrypted=false size=612.00x792.00pt
title: 'untitled'
author: 'anonymous'
producer: 'ReportLab PDF Library - (opensource)'
fonts: Helvetica
page 1/1: box=[0.00, 0.00, 612.00, 792.00] rotate=0
counts: chars=22 words=6 rects=1 lines=2 curves=0 images=0 tables=1
word[0]: 'Header' bbox=(60.00, 697.93, 92.79, 707.93) font=Helvetica size=10.00
word[1]: 'A' bbox=(95.57, 697.93, 102.24, 707.93) font=Helvetica size=10.00
word[2]: 'Header' bbox=(210.00, 697.93, 242.79, 707.93) font=Helvetica size=10.00
word[3]: 'B' bbox=(245.57, 697.93, 252.24, 707.93) font=Helvetica size=10.00
word[4]: 'Row' bbox=(210.00, 657.93, 230.00, 667.93) font=Helvetica size=10.00
table[0]: 2x2 bbox=(50.00, 62.00, 350.00, 142.00)
  | Header A | Header B |
  |  | Row B1 |
```

其它 fixture：

```text
$ ... "../tests/fixtures/image.pdf 1"
page 1/1: box=[0.00, 0.00, 612.00, 792.00] rotate=0
counts: chars=0 words=0 rects=0 lines=0 curves=0 images=1 tables=0
image[0]: p1_img_0 format=unknown bbox=(50.00, 50.00, 150.00, 150.00) image/png bytes=72

$ ... "../tests/fixtures/encrypted.pdf 1"
error: password required or incorrect (pass the 'password' argument for encrypted PDFs): '../tests/fixtures/encrypted.pdf' is encrypted and the Cangjie engine does not support PDF decryption yet
```

## 说明

- 输出里的 `bbox` 是 PDF 用户空间坐标（y 向上），`table[].bbox` 是自上而下的坐标，
  两者不能直接混用，见 [../doc/design.md](../doc/design.md#坐标约定)。
- `image[0] format=unknown` 表示内容层没从流里认出文件格式（原始像素采样），
  随后 `imagePayload` 已把它转成 PNG，所以显示的是 `image/png`。
- 出错时只打印 `e.message`：本工具链对异常调用 `toString()` 会让进程中止。
