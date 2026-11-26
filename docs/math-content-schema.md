# 数学内容 Schema 草案（v1）

配套样例题：[assets/samples/math_schema_samples.json](../assets/samples/math_schema_samples.json)

这份 schema 只描述**数学题库**，与现有语文字库（`Library` / `Lesson` / `Prompt`）并列，不混用。语文那套围绕「汉字 + 词语 + 位置」建模，数学围绕「题目 + 步骤 + 槽位 + 动画」建模，强行合并会让两边都变形。

## 设计原则

1. **步骤即讲解**。每道题必须能拆成有序的步骤，每一步解决一个小问题。
2. **判定到格**。每个步骤里可以填的格子是 `slot`，逐格判定，才能做到「第二步错了就地提示并只重做那一步」。
3. **动画声明式**。`visual` 只声明「要表达什么关系」，不写时间轴。同一份数据既能渲染动画，也能渲染静态终态。
4. **未知即降级**。渲染器遇到不认识的 `visual.type` 或 `input`，必须静态展示而不是报错。

## 顶层结构

```json
{
  "schema": 1,
  "subject": "math",
  "edition": "sample-math",
  "title": "数学步骤骨架 · 样例题",
  "source": "自编示例……",
  "sample": true,
  "questions": [ ... ]
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `schema` | int | 是 | 固定 `1`，用于未来迁移 |
| `subject` | string | 是 | 固定 `"math"`。校验时用于拒绝把语文库喂给数学渲染器 |
| `edition` | string | 是 | 版本标识，`^[a-zA-Z0-9._-]+$`，同 edition 内 `question.id` 唯一 |
| `title` | string | 是 | 展示名，≤100 字 |
| `source` | string | 是 | 核验来源；自编数据写清楚 |
| `sample` | bool | 是 | 是否为未核验示例 |
| `questions` | array | 是 | 题目列表，1～600 项 |

## question

```json
{
  "id": "sample/add-carry/25+17",
  "grade": 2,
  "volume": "2a",
  "unit": "100 以内的加法和减法",
  "skill": "两位数进位加法",
  "difficulty": 2,
  "stem": {"type": "expression", "text": "25 + 17"},
  "answer": {"type": "number", "value": 42},
  "steps": [ ... ]
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | 是 | 全局唯一，建议 `edition/知识点/题干` 形态 |
| `grade` | int | 是 | 年级 1～6 |
| `volume` | string | 是 | 册次，如 `2a` 表示二年级上册 |
| `unit` | string | 是 | 单元名，用于选题和统计 |
| `skill` | string | 是 | **知识点**。复习调度按它聚合，不按单题 |
| `difficulty` | int | 否 | 1～5，默认 1 |
| `stem` | object | 是 | 题干，见下 |
| `answer` | object | 是 | 最终答案，见下 |
| `steps` | array | 是 | 1～12 个步骤，顺序即讲解顺序 |

### stem

| `type` | 附加字段 | 用途 |
|---|---|---|
| `expression` | `text` | 横式，如 `25 + 17` |
| `vertical` | `operands: [int]`, `operator: string`, `align: "right"` | 竖式 |
| `word` | `text` | 应用题文字 |
| `compare` | `left: string`, `right: string` | 比较大小 |

渲染器按 `type` 选布局；未知 `type` 时退化为显示 `text` 字段（若存在）。

### answer

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | `"number"` \| `"text"` \| `"choice"` | 第一版只实现 `number` |
| `value` | number \| string | 期望值 |
| `choices` | string[] | 仅 `choice` 使用 |
| `tolerance` | number | 仅小数使用，第一版不实现 |

## step

```json
{
  "id": "ones",
  "hint": "先算个位：5 加 7 等于 12，个位写 2，向十位进 1。",
  "slots": [ ... ],
  "visual": { ... },
  "hold": 400
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | 是 | 题内唯一 |
| `hint` | string | 是 | ≤120 字。**先展示 hint，再逐格引导** |
| `slots` | array | 是 | 1～8 个槽位 |
| `visual` | object | 否 | 本步动画。缺省表示不播动画 |
| `hold` | int | 否 | 本步结束后的停顿毫秒数，默认 300，上限 2000 |

## slot

```json
{"id": "sum", "label": "5 + 7", "answer": "12", "input": "number", "width": 3, "optional": false}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | 是 | 步骤内唯一 |
| `label` | string | 是 | 格子左侧的提示文字，如 `5 + 7`、`个位` |
| `answer` | string | 是 | 期望填写内容，归一化后比较 |
| `input` | `"digit"` \| `"number"` \| `"choice"` | 是 | 决定键盘和校验；`choice` 为预留，第一版不实现 |
| `width` | int | 否 | 输入框字符宽度，默认按 `answer` 长度推导 |
| `optional` | bool | 否 | 为 `true` 时留空也算通过（如进位/借位标记） |

### 判定规则

- 输入按 `trim` + 全角转半角 + 去千分位后比较。
- `input` 为 `digit` / `number` 且答案形如整数时，**按数值比较**，因此 `02` 与 `2` 视为同一答案。
- 空输入：`optional` 为 `true` 时通过，否则不通过。
- 不区分「写错」和「不会」：任一槽位不通过，该步骤判为未通过，就地提示并允许重填，不跳到下一步。

## visual

`visual` 是**关系声明**，渲染器负责把它变成动画或静态终态。

| `type` | 关键参数 | 表达的关系 | 覆盖题型 |
|---|---|---|---|
| `carry` | `from`, `to`, `value`, `duration` | 进位数字从低位移到高位 | 进位加法、竖式 |
| `borrow` | `from`, `to`, `value`, `tensAfter`, `onesAfter`, `duration` | 十位拆成 10 个一到个位 | 退位减法 |
| `place-value-sum` | `digits`, `result`, `duration` | 同一位上的几个数相加 | 竖式加 |
| `numberline` | `from`, `to`, `jumps`, `duration` | 在数轴上按步长跳 | 加减法 |
| `array` | `rows`, `cols`, `highlight`, `duration` | 点阵表达乘法的行列意义 | 乘法 |
| `array-count` | `rows`, `cols`, `step`, `duration` | 按行累加数数 | 乘法 |
| `assemble` | `parts`, `result`, `duration` | 各位数字拼成最终得数 | 所有题型收尾 |
| `chant` | `text`, `duration` | 显示口诀（静态或描字） | 表内乘法 |

约定：

- 所有 `*` 动画默认时长在参数里给出，缺省 400ms，**上限 800ms**。
- `duration: 0` 表示只显示终态，不播动画。
- 未知 `type`：跳过动画，直接显示该步骤的 `hint` 与槽位。
- 系统开启「减少动态效果」（Flutter 的 `MediaQuery.disableAnimations`）时，一律按 `duration: 0` 处理。

## 答题记录（对应现有 `Answer`）

现有 `Answer` 只存一个 `ink` 和整体 `verdict`。数学需要逐格结果，建议在 `Answer` 旁增加：

```json
{
  "questionId": "sample/add-carry/25+17",
  "steps": [
    {
      "id": "ones",
      "slots": [
        {"id": "sum", "value": "12", "verdict": "correct"},
        {"id": "ones", "value": "2", "verdict": "correct"},
        {"id": "carry", "value": "", "verdict": "skipped"}
      ],
      "verdict": "correct",
      "guided": true
    }
  ],
  "verdict": "correct"
}
```

| 字段 | 说明 |
|---|---|
| `value` | 学生实际填写内容，原样保留，用于家长查看 |
| `verdict` | `correct` / `wrong` / `skipped` |
| `verdict`（步骤级） | 所有非 `optional` 槽位均 `correct` 时为 `correct` |
| `guided` | 本条是否经过「讲解模式」。首轮独立作答为 `false`，答错后引导重做为 `true` |

`guided: true` 的记录在统计里单独计数，避免把引导后的正确率当成独立掌握程度。

## 校验清单

样例题已通过以下检查（脚本见提交说明，可复用为测试用例）：

1. `question.id` 全局唯一；`step.id` 题内唯一；`slot.id` 步骤内唯一。
2. `stem.text` 求值结果与 `answer.value` 一致。
3. 每个步骤至少一个槽位；槽位 `answer` 为整数或空。
4. 最后一个步骤必须包含 `id == "answer"` 的槽位，且其值与 `answer.value` 一致。
5. 有 `visual` 的步骤必须带 `type`。

## 尚未覆盖的内容

以下明确**不在 v1 范围**，避免过早复杂化：

- 小数与分数（`tolerance`、分数专用 visual 均未实现）。
- 竖式的精细排版（`align`、小数点对齐、空格占位）。
- 应用题的列式判定（需要算式规范化，不是数值判等）。
- 多解题目的分支步骤（当前 steps 是线性的）。
- 自由作答的拍照/手写识别（数学第一版统一用数字键盘）。

## 最小页面（已实现）

第一版只验证交互节奏，刻意不接动画、不存储、不联网。

| 文件 | 作用 |
|---|---|
| `lib/math_question.dart` | schema 解析、输入归一化、逐格判定（纯 Dart，无 Flutter 依赖） |
| `lib/math_step.dart` | 步骤页：槽位输入、数字键盘、逐格判定、自动推进 |
| `lib/math_preview.dart` | 样例题库加载与列表页 |
| `test/math_test.dart` | 解析、判定、动画参数保留的单元测试 |
| `test/math_step_page_test.dart` | 输入 → 判定 → 推进的页面流程测试 |

入口：`练习` 页顶部「数学 · 分步练习」。

已实现的行为：

- 焦点默认落在第一个必填槽位（`optional` 的进位格排在前面但会被跳过）。
- 点「确认这一步」逐格判定；有错就地标红并聚焦第一个出错的格子。
- 全部通过后按 `hold` 毫秒自动进入下一步。
- 全角数字、空格、千分位逗号都归一后再比较，前导零不影响判等。
- 「看讲解」只切换标记，用于验证 `guided` 区分是否有意义。

**尚未实现**：动画渲染（`visual` 只解析不渲染）、作答记录持久化、题库导入、学科切换、按知识点的复习调度。

## 与现有代码的接入点

| 需要改的地方 | 现状 | 计划 |
|---|---|---|
| `lib/domain.dart` `Journal` | 单学科 | 加 `subject` 维度，`schema` 升 2 并迁移 v1 |
| `lib/practice.dart` 整页田字格 | 写死手写交互 | 抽出题型渲染器，数学走步骤页 |
| `stream`/`graderProvider` | 按平台二选一 | 按题型分派；数学本地判等，不联网 |
| `server/app/routers/children.py` `_kind` | 写死两种练习类型 | 增加学科与 `guided` 统计 |
| `assets/` 打包 | 只有语文库 | 加数学题库资源与按需加载 |
