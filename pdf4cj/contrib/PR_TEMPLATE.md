# PR 模板（Cangjie-TPC 格式）

提交 PR 时请把下面的内容作为 PR 描述。标题必须是
`[pdf4cj][需求/缺陷]：<一句话描述>`，其中 `需求` 用于新功能/改进，`缺陷` 用于修 bug。

---

## 标题

```text
[pdf4cj][需求]：支持 /Rotate 页面旋转变换
[pdf4cj][缺陷]：修复 xref stream 在 /W 第二列为 0 时越界读取
```

## 正文

```markdown
### 需求或缺陷
- 关联 issue：<#编号 或 issue 链接>
- 类型：需求 / 缺陷
- 影响版本：0.1.0

### 影响文件
- `src/<file>.cj`
- `src/test/<file>_test.cj`
- `doc/<file>.md`（如涉及接口/行为变化）

### 描述
<!-- 需求：说明场景、期望行为、设计方案与取舍；缺陷：说明触发条件、根因、修复方式 -->

### 测试
<!-- 说明如何验证：新增/修改了哪些用例、是否跑过全量 cjpm test、是否影响既有语料 -->

- [ ] `~/.cjv/bin/cjv run lts-1.0.0 cjpm build` 通过
- [ ] `~/.cjv/bin/cjv run lts-1.0.0 cjpm test` 通过（当前基线 77 个用例）
- [ ] 新增用例覆盖本次改动（缺陷需有回归用例）
- [ ] 涉及 public API 变化时同步更新 `doc/feature_api.md` 与 `CHANGELOG.md`
- [ ] 涉及 fixtures 变化时用 `tests/README.md` 的脚本重新生成，未手改二进制
```

---

## 填写示例

### 需求示例

```markdown
### 需求或缺陷
- 关联 issue：https://gitcode.com/Cangjie-TPC/pdf4cj/issues/12
- 类型：需求
- 影响版本：0.2.0

### 影响文件
- `src/content.cj`（`extractPage` 尾部新增变换阶段）
- `src/test/content_test.cj`（新增 2 个用例）
- `doc/design.md`（坐标约定章节补充 /Rotate 行为）

### 描述
`/Rotate` 目前只暴露在 `PdfPage.rotate`，不参与坐标变换。本 PR 在内容流解释完成后按
`rotate % 360` 对 chars/rects/lines/curves/images 做 90/180/270 度变换，并交换
`PageData.width/height`（90/270 时）。tables 仍在其后由 `extractTables` 计算，因此自动跟随。
取值范围外的角度保持原行为，不抛异常。

### 测试
新增 `extractPageAppliesQuarterTurn`（90 度顺时针后的字符框位置）与
`extractPageKeepsZeroRotation`（0 度不变），并手工核对 `mediabox.pdf` 的坐标平移不受影响。
```

### 缺陷示例

> 下面只是一个**格式示例**：其中的 `/W [1 0 2]` 场景**不是当前缺陷**——`src/parser.cj` 已经按每列
> 实际宽度累加（宽度为 0 的列按 0 值处理），并有对应测试覆盖。写真实 PR 时请替换成实际 issue。

```markdown
### 需求或缺陷
- 关联 issue：https://gitcode.com/Cangjie-TPC/pdf4cj/issues/18
- 类型：缺陷
- 影响版本：0.1.0

### 影响文件
- `src/parser.cj`
- `src/test/document_test.cj`

### 描述
（示例）当 xref stream 的 `/W [1 0 2]`（第二列宽度为 0）时，行解析若按固定段数累加偏移，
会导致后续行错位并读到垃圾对象号。修复方式：按每段实际宽度累加，宽度为 0 的列直接视为 0 值。
触发条件：手工构造的 xref stream，报告中附最小复现文件。

### 测试
新增回归用例 `xrefStreamWithZeroWidthColumnStillResolves`，用 4 字节行宽的 xref stream
断言页面数为 1 且能取到内容；其余 77 个用例仍全部通过。
```
