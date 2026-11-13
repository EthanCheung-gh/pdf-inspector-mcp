# 项目申请邮件模板

按 [Cangjie-TPC 社区贡献指南](https://gitcode.com/Cangjie-TPC) 的流程，
在提交「项目创建申请」issue 之后，把申请材料与代码包发给社区邮箱。
把 `<>` 里的内容替换成实际信息后发送。

---

**收件人**：`cangjie@huawei.com`
**抄送**：`<如已在 issue 中 @ 相关负责人，可抄送其邮箱>`

**主题**：

```text
【项目申请】pdf4cj - 纯仓颉 PDF 结构解析库（附代码包与项目创建申请）
```

**正文**：

```text
您好，

我是 <姓名>（GitCode 账号：<gitcode.com/<账号>>），希望向 Cangjie-TPC 组织申请创建一个新的
开源项目，随信附上代码包与项目申请材料，请审阅。

一、项目基本信息
  项目名称：pdf4cj
  项目地址（拟）：https://gitcode.com/Cangjie-TPC/pdf4cj
  上游前身：https://github.com/EthanCheung-gh/pdf-inspector-mcp（子目录 pdf4cj/）
  许可证：MIT
  当前版本：0.1.0
  目标工具链：Cangjie LTS 1.0.0 + cangjie-stdx 1.0.0.1

二、项目简介
  pdf4cj 是一个纯仓颉实现的 PDF 结构解析库：解析对象模型与交叉引用、解释页面内容流，
  输出字符、单词、矩形、线段、曲线、图片与表格等结构化数据。它不含 C 源码、没有手写 FFI、
  没有外部动态库，只依赖 std 与 stdx 的 compress.zlib、encoding.base64，`cjpm build` 即可构建。
  适用的场景包括 PDF 预览、文档分析、RAG 预处理与 Agent 工具后端。

三、主要功能
  1. 交叉引用：经典 xref 表、/Prev 增量链、xref stream（含 PNG predictor）、对象流 /ObjStm；
     损坏时回退全文件扫描
  2. 流过滤器：Flate（zlib/raw deflate/gzip + predictor）、LZW、ASCII85、ASCIIHex、RunLength
  3. 字体：简单字体与 /Type0 复合字体、/ToUnicode CMap、标准 14 字体度量、
     WinAnsi/MacRoman/Standard/PDFDoc 编码表
  4. 内容流：文本状态与显示算子、路径与填充描边、图形栈、Form XObject、内联图像
  5. 结构化输出：PageData（chars/words/rects/lines/curves/images）、有框线表格检测
  6. 图片：PNG/JPEG/GIF/WebP 透传，原始采样由手写 PNG 编码器转码（JPX/JBIG2 明确拒答）

四、依赖
  Cangjie LTS 1.0.0；cangjie-stdx 1.0.0.1（compress.zlib、encoding.base64）；无第三方 C 库。

五、测试情况
  cjpm test：77 个用例全部通过（PASSED 77 / FAILED 0 / SKIPPED 0）；
  cjpm build 成功产出 libpdf4cj.so；example/ 示例可编译运行（Linux x86_64）。

六、申请事项
  1. 在 Cangjie-TPC 下创建仓库 pdf4cj；
  2. 授予申请人 Maintainer 权限；
  3. 确认许可证（MIT）与仓库描述；
  4. 如需同步登记到 TPC 项目列表，请告知格式。

七、附件
  pdf4cj.zip —— 完整代码包，根目录为 pdf4cj/，包含：
    README.md、README.OpenSource、CHANGELOG.md、LICENSE、cjpm.toml、
    doc/（design.md、feature_api.md）、src/（15 个实现文件 + 6 个测试文件）、
    example/（可编译示例）、tests/（15 个 PDF 回归语料）、scripts/、contrib/
  压缩包已排除 stdx/、target/、dist/、.git/ 与日志文件。

关于贡献者许可协议：本人<已签署 / 将按指引签署> Cangjie 社区 CLA（签署账号：<账号>）。
对应的「项目创建申请」issue 见：<issue 链接>

如材料需要补充或调整，请随时告知，感谢审阅。

顺祝工作顺利
<姓名>
<邮箱> / <GitCode 账号>
<日期>
```

---

## 发送前检查清单

- [ ] 主题包含项目名 `pdf4cj`，便于归档检索
- [ ] 正文里的申请人、账号、邮箱、CLA 状态已替换，没有残留 `<...>` 占位
- [ ] `pdf4cj.zip` 由 `bash scripts/make-submission-zip.sh` 生成，且 `unzip -l` 结构与正文「附件」
      描述一致
- [ ] 已先在 Cangjie-TPC 提交「项目创建申请」issue，并把链接填进正文
- [ ] 压缩包内不含 `stdx/`（约 30 MB 的二进制）与 `target/`（构建产物）
