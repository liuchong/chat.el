# 005: Markdown Display Engine Spec

## Overview

大模型的回答事实上是 Markdown。这不是我们选的，是整个生态选的：所有主流模型都被
训练成用 Markdown 组织回答，换任何别的格式都要靠提示词逆着训练分布拧，拧不稳。
所以格式这一侧不必再讨论——**确认 Markdown**，并在系统提示词里把它从"惯例"升级成
"要求"，同时把子集收窄到 Emacs 能显示好的范围。

真正的问题在显示这一侧。Emacs 长期没有自己的 Markdown 引擎：主流插件的做法是调
一个外部渲染器（`pandoc`、`marked`、浏览器组件），把结果当成"预览"另开一个图形化
窗口。这是本末倒置——它放弃了 Emacs 的长处（缓冲区就是文本、文本属性即样式、
一切可折叠可搜索可 kill-ring），去模仿浏览器的短处。

我们要的是 **org-mode 那种展现形式**：文档还是那份纯文本，缓冲区里就地变好看。
`#` 隐掉、标题分级、`**` 隐掉留粗体、代码块用真正的 major mode 上色、表格按列宽
对齐、列表符号换成圆点、链接只留文字。org 用文本属性做到了这一切，没有外部渲染器，
没有图形 widget。用 Markdown 的语法拿到 org 的观感，这件事本身就值得单独做一份
spec。

## Division Of Responsibility

这两件事必须分清，否则模块会长成一个既管格式又管显示的东西：

- **Markdown 这个格式**承担完整文档的输入输出。模型写出来的是它，会话记录里存的
  是它，从缓冲区复制出去的是它，下一轮送回模型的还是它。它是唯一的事实来源
- **`chat-markdown.el`** 只承担这份文档在 Emacs 里的渲染美化。它是显示层，
  不是 Markdown 的实现，也不是格式的定义者

由此得出一条贯穿全文的硬约束：**渲染结果永远不回流成数据**。缓冲区里的样式是
文档的一个视图，不是文档。任何需要文档内容的地方——重绘、复制、送回模型、
落盘——取的都是那份原始 Markdown，不是渲染后的产物。Requirement 1.1 的纯函数
和 2.1 的"隐藏必须可逆"都是这条约束的推论，不是独立的偏好。

## Status: Implemented

引擎已落地为 `lisp/core/chat-markdown.el`，列宽对齐拆到
`lisp/core/chat-align.el`（5.1.1 的那一份，spec 006 require 的是同一个）。
下面这节记录的是施工前的状况，保留下来是因为验收项里有好几条是"当前会丢"
"当前写超了"这种对照式写法，删掉对照就读不出验收在验什么。

施工中改的和原计划不同的地方，两处：

- **6.1 的稳定前缀替换了原来的围栏计数，语义变了。** 原来
  `chat-ui--fence-safe-prefix-length` 数 ` ``` ` 出现次数，且不要求围栏在行首；
  现在按块判定，且围栏必须在行首（最多 3 个前导空格）。行首这条是对的——模型写
  `text ```el` 并不是在开代码块——但它让流式快路径从"只追加增量"变成"重画尾部
  未完成块"。这不是退步而是必要代价：只追加增量意味着块在剩余部分到达之前就已经
  按段落画完了，表格永远拿不到列宽、列表项永远拿不到悬挂缩进。代价由 6.2 的
  `chat-markdown-streaming-tail-max-chars` 兜住
- **系统提示词那部分（Requirement 3）在本 spec 落成之前就已经实现了**
  （`chat-tool-caller--output-format-note`），本次只是补齐渲染侧

## Superseded Status（施工前）

**现在没有 Markdown 引擎。** 有的是两处互不相干的薄涂层。

已经存在：

- 闭合围栏上色。`chat-ui--insert-formatted-response`
  （`lisp/ui/chat-ui.el:2023`）找出闭合的 ` ``` ` 块，整块（含围栏本身）涂一个
  常量 face。走的是每次插入和每次重绘
- finalize 时的 lite 上色。`chat-ui--fontify-markdown-lite`
  （`lisp/ui/chat-ui.el:2347`）给围栏行、ATX 标题行、`**bold**` 的内文加 face
- 流式安全切点。`chat-ui--fence-safe-prefix-length`
  （`lisp/ui/chat-ui.el:2004`）数 ` ``` ` 出现次数，保证增量追加不会切在未闭合的
  围栏中间

确认存在的缺口：

- **绝大多数构造根本没处理。** 行内代码、`~~~` 围栏、setext 标题、斜体、粗斜体、
  删除线、链接、裸 URL、图片、无序列表、有序列表、嵌套列表、任务列表、引用块、
  表格、水平线、脚注、HTML、数学公式——全部作为字面文本原样躺在缓冲区里
- **标记全部裸露。** 没有任何一处用 `invisible`。`**` 只给内文上色，两侧星号照旧
  可见；`#` 整行加粗，井号照旧可见。屏幕上看到的是源码，不是文档
- **代码块内没有语法高亮。** ` ``` ` 后面的语言标签被解析出来了
  （`lisp/ui/chat-ui.el:2031`），但只用来二选一挑 face，没有任何地方拿它去找
  major mode。所有语言的代码都是同一个颜色
- **重绘会丢样式。** lite 上色只在 finalize 调一次
  （`lisp/ui/chat-ui.el:2449`）。之后任何一次 `chat-ui--redraw-conversation`
  （折叠、重开、`message-appended`）都不会重跑它，标题和粗体的样式就此消失。
  流式路径和重绘路径产出的样式本来就不一致
- **两个重复的代码块 face。** `chat-code-block-face`（`lisp/ui/chat-ui.el:1874`）
  与 `chat-ui-code-block-face`（`lisp/ui/chat-ui.el:2342`）定义相同，插入路径用
  前者、finalize 路径用后者，把同一个显示面切成了两半
- **不换词换行。** `chat-mode` 设了 `truncate-lines` 为 `nil`
  （`chat.el:646`），但没设 `word-wrap`，所以长段落在窗口边缘断在词中间，中英混排
  尤其难看
- **有几条路径完全不过格式化。** 即席问答的答案是裸 `insert`
  （`lisp/ui/chat-ui.el:2863`），错误信息也是（`:2464`）
- **系统提示词一个字都没提格式。** `chat-tool-caller-build-system-prompt`
  （`lisp/tools/chat-tool-caller.el:237`）约束了工具、预算、回答语言、存储，
  没有任何一条关于输出格式。模型用 Markdown 纯属它自己的习惯
- **文档写超了。** `docs/index.html:104` 宣传"markdown-lite styling for code
  blocks, headers, and emphasis"随差分流式生效，实际上标题和强调只在 finalize
  跑一次；`docs/architecture/design.md:711` 列了一个并不存在的
  `chat-markdown.el`

## Goals

1. Markdown 在缓冲区里就地显示成文档，不开预览窗口，不调外部渲染器
2. 一个渲染器，一个入口。流式、重绘、折叠、重开产出完全一致的样式
3. 标记该隐的隐掉，但缓冲区文本不变，复制出去还是原始 Markdown
4. 代码块用真正的 major mode 上色
5. 表格按显示宽度对齐，中日韩双宽字符算对
6. 系统提示词把 Markdown 从惯例变成要求，并把子集收窄到能显示好的范围
7. 流式期间的渲染代价与新增内容成正比，不随全文长度增长

## Non-Goals

1. 不做浏览器式预览，不开第二个窗口，不调 `pandoc` / `marked` / 任何外部进程
2. 不内联渲染图片，不渲染 LaTeX 数学公式，不渲染 HTML
3. 不做 Markdown **编辑**支持（补全、表格编辑命令、大纲跳转）。这是显示引擎，
   不是通用 Markdown 编辑器
4. 不追求 CommonMark 完全合规。目标是把模型实际会写的东西显示好，
   不是通过一致性测试集
5. 不改 `chat-mode` 的 major mode 归属，不引入 `visual-line-mode`
   （它会重绑 `C-a`，与 `chat-ui-beginning-of-input` 冲突）

## Requirement 1: One Renderer

### 1.1 纯函数

新模块 `lisp/core/chat-markdown.el`（`docs/architecture/design.md:711` 已经预留了
这个名字）。

放在 core 而不是 ui，依据是仓库自己的先例：`lisp/core/chat-transcript.el` 也定义
face、也决定排版，它在 core，因为它是纯的——算样式，不碰缓冲区和窗口。
`chat-markdown.el` 是同一类东西。而 `lisp/ui/` 里的模块碰缓冲区、窗口和键盘。

这个位置还有一个必须满足的约束：本仓库的依赖方向是严格的 ui → core，
core 从不 require ui（可核实：`lisp/core/` 里没有一处 require `chat-ui`）。
`lisp/core/chat-mdp.el`（spec 006）需要用到这里的列宽对齐，如果渲染器在 ui，
那就得由 core 去依赖 ui，把方向倒过来。放 core 就没有这个问题。

核心是一个纯函数：

```
chat-markdown-render (source &optional base-face) → propertized string
```

- 同样的 `source` MUST 产出同样的结果，不依赖缓冲区状态、窗口宽度或时间
- 所有插入路径 MUST 经由它，包括流式、重绘、即席问答和错误信息
- 任何路径 MUST NOT 从缓冲区里已渲染的文本再渲染一次；渲染永远以会话记录里的
  原始 Markdown 为输入。这是"两条路径样式不一致"的结构性解法：不是让两条路径
  各自记得调同一个函数，而是让它们只有同一个输入

### 1.2 与频道排版共存

spec 004 的 `chat-transcript-*` face 决定**频道**（推理、工具、中间说明、最终
答案），本 spec 的 `chat-markdown-*` face 决定**频道内部的结构**。两者 MUST 叠加
而不是互相覆盖：

- `face` 文本属性存成 face 列表，Markdown 的 face 追加在频道 face 之后
- 中间说明是斜体（`chat-transcript-interim`），它里面的行内代码 MUST 同时是斜体
  和代码 face
- `base-face` 参数就是频道 face，由调用方传入

### 1.3 一份 face 家族

`chat-code-block-face` 与 `chat-ui-code-block-face` MUST 合并为一个。保留
`chat-code-block-face` 作为别名以免破坏已有的 customize 设置，新代码只用新名字。

## Requirement 2: Display Rules

Emacs 手段，不是浏览器手段。下表的"手段"一列是硬要求。

| 构造 | 显示 | 手段 |
| --- | --- | --- |
| ATX 标题 `##`..`######` | 井号隐藏，按层级不同 face，层级越浅越显眼 | `invisible` + 分级 face |
| 一级标题 `#` | 同上，但见 3.2：提示词里不让模型用 | |
| setext 标题 | 当普通段落，不识别 | 见 3.2 |
| `**粗体**` | 星号隐藏，内文加粗 | `invisible` + `bold` |
| `*斜体*` `_斜体_` | 标记隐藏，内文斜体 | `invisible` + `italic` |
| `***粗斜***` | 标记隐藏，内文粗斜 | `invisible` + 复合 face |
| `~~删除~~` | 标记隐藏，内文删除线 | `invisible` + `:strike-through` |
| 行内代码 | 反引号隐藏，内文等宽 + face | `invisible` + `fixed-pitch` |
| 围栏代码块 | 源围栏显示成带语言的上下边框，块内带左轨并按语言上色；复制仍是原围栏 | 见 Requirement 4 |
| 无序列表 `-` `*` `+` | 符号按层级换成 `•` `◦` `▪`，缓冲区文本不变 | `display` 属性 |
| 有序列表 `1.` | 数字保留，编号 face 淡化 | face |
| 嵌套列表 | 按缩进层级换符号，续行悬挂缩进对齐 | `display` + `wrap-prefix` |
| 任务列表 `- [ ]` `- [x]` | 换成 `☐` `☑` | `display` |
| 引用块 `>` | 源标记显示成 `▎` 左轨，正文加引用 face | `display` + face |
| 表格 | 最终可见文本按显示宽度对齐，统一等宽 metric，管道显示成 Unicode 边框 | 见 Requirement 5 |
| 水平线 `---` `***` | 整行换成一条横线 | `display` |
| 链接 `[文字](地址)` | 只留文字，可点开 | `invisible` + link face + keymap |
| 裸 URL | 加 link face，可点开 | face + keymap |
| 图片 `![alt](url)` | 显示成 `[图片: alt]`，可点开，不内联 | non-goal 1 已排除内联 |
| HTML 块 | 原样保留，整体淡化 | face |
| 数学 `$...$` | 原样保留，不处理 | — |
| 脚注 | 原样保留，不处理 | — |

表格、代码块与机器视图 MUST 继承当前缓冲区背景，MUST NOT 在 face 中硬编码浅色或
深色背景。它们的层级来自字体、前景色、边框和留白，不来自铺满整行的面板。

### 2.1 隐藏必须可逆

隐藏标记是这份 spec 里唯一有真实风险的动作，所以约束写死：

- MUST 用 `invisible` 文本属性，MUST NOT 用 `display` 属性替换成空串，
  MUST NOT 从缓冲区里删掉标记字符
- 理由是复制。`invisible` 只影响显示，字符还在缓冲区里，所以 `kill-region`、
  `copy-region-as-kill`、鼠标选中复制拿到的都是**原始 Markdown**。
  删掉或用 `display` 抹掉就再也复原不回来了
- MUST 提供一个开关命令，一键显示全部标记，用于需要看源码的时候
- 表格对齐是唯一会改动缓冲区文本的例外（见 5.3）

### 2.2 换行

- `word-wrap` 设为 `t`，在词边界换行而不是窗口边缘断词
- `truncate-lines` 保持 `nil`
- MUST NOT 启用 `visual-line-mode`：它把 `C-a` 重绑到
  `beginning-of-visual-line`，会盖掉 `chat-ui-beginning-of-input`
- 列表项、引用块的续行用 `wrap-prefix` 文本属性做悬挂缩进，效果等同
  `adaptive-wrap` 但不引入依赖
- MUST NOT 硬折行。段落在缓冲区里保持单行，换行交给显示层，这样窗口改宽窄
  不需要重排

## Requirement 3: Output Format In The System Prompt

### 3.1 明确要求 Markdown

`chat-tool-caller-build-system-prompt`（`lisp/tools/chat-tool-caller.el:237`）
MUST 加一段输出格式约定，与已有的回答语言约定（`:218`）并列。要求 Markdown，
不是建议。

### 3.2 收窄子集

只要求"用 Markdown"是不够的——模型会写出显示不好的 Markdown。子集按"Emacs 里
显示得好"这一条标准收窄，每条都要给出理由，因为提示词里的规则不解释就会被模型
当成可选项：

- 标题用 ATX（行首 `#`），不用 setext（下划线式）。setext 要回看上一行才能判定，
  流式渲染时它已经画完了
- 标题从 `##` 起，不用 `#`。会话里每条消息已经有角色标签，一级标题会和它抢
  视觉层级
- 标题最多到 `####`。再深就分不出层级了
- 段落不要硬折行。Emacs 按窗口宽度软换行，硬折过的段落在任何别的宽度下都是
  参差的
- 围栏代码块必须带语言标签。没有标签就没法上色
- 列表最多嵌两层
- 表格只在数据确实是表格时用，控制在 4 列以内、单元格保持短。宽表格在窗口里
  没法读，会横向溢出
- 标识符、路径、命令用行内代码
- 不要 HTML、不要 LaTeX 数学、不要图片、不要脚注。这几样都不渲染
- 粗体省着用，不要用粗体代替标题

### 3.3 提示词不是渲染器的前提

渲染器 MUST NOT 假设模型守规矩。收窄子集是为了显示得更好，不是渲染的前提条件：
子集外的构造照样要有合理的落地样式（原样 + 淡化），不能崩、不能吞内容、
不能把后面的文本连带带歪。

## Requirement 4: Code Blocks

### 4.1 用真正的 major mode 上色

闭合围栏的块内内容，在临时缓冲区里跑对应 major mode 的 font-lock，把 face
属性搬回来。这是 org 的 `org-src-fontify-natively` 的做法。

### 4.2 安全边界

在临时缓冲区里跑任意 major mode 是这份 spec 里第二个有真实风险的动作：

- MUST 用 `delay-mode-hooks`。用户的 mode hook 可能起 LSP、连服务器、开进程
- MUST 用 `condition-case` 包住，出错就退回纯 face，MUST NOT 让一段坏代码
  搞掉整条回答的渲染
- 语言标签到 major mode 的映射 MUST 走显式映射表。MUST NOT 直接
  `(intern (concat lang "-mode"))` 然后调用——那等于让模型的输出决定加载哪个包
- 映射表之外的语言，只有当 `LANG-mode` 这个符号**已经**被加载过
  （`fboundp` 为真、且不是 autoload）才用。不因为一段代码块去触发加载
- 单块大小上限。超过上限只上纯 face
- 按（语言 + 内容）缓存结果。流式期间同一个块会被反复渲染

### 4.3 未闭合的围栏不上色

正在流入的代码块是不完整的代码，拿去跑 font-lock 既会出错也会白费功夫。
未闭合的围栏 MUST 只上纯代码 face，等闭合了再上语法色。

## Requirement 5: Tables

### 5.1 按显示宽度对齐

- 列宽 MUST 用 `string-width` 计算，MUST NOT 用 `length`。中日韩字符是双宽的，
  用字符个数算列宽会让任何含中文的表格错位。`chat-ui--expand-tabs`
  （`lisp/ui/chat-ui.el:2610`）已经踩过并记下了这一条
- 计宽对象 MUST 是经过行内渲染后的最终可见文本，不是 Markdown 源码。隐藏的反引号、
  方括号和链接地址不占屏幕宽度；把它们算进去会让含行内代码或链接的那一行错位
- 表头、正文、行内代码与边框 MUST 共同继承等宽 face。这里的列宽是字符格宽，若让
  正文或粗体表头使用比例字体，即使字符数相等，像素边界仍会漂移
- 表格结构 face MUST 位于频道 face 与行内 face 之前。只把等宽 face 追加到属性
  列表末尾并不能约束字体；前面的比例字体仍会赢，代码与普通文本的边界照样分叉
- 单靠补普通空格仍不足以保证像素边界：macOS 的中日韩 fallback 字体未必恰好等于
  两个拉丁等宽字形。每个列分隔符 MUST 用 `(space :align-to ...)` 放到绝对显示列，
  空格只维持可复制源码的合法性，不再承担最终视觉对齐
- 每列取该列所有最终可见单元格宽度的最大值，补空格对齐

### 5.1.1 对齐只有一份实现

按显示宽度排版列，在本仓库里有三个调用方：本 spec 的表格、spec 006 的 MDP
机器视图、以及已有的 shell 输出制表位展开。所以它 MUST 是一个独立的纯函数，
放在 core 且不依赖任何显示模块，两份 spec 都 require 同一个它。

理由是这份 spec 存在的同一个理由：同样的东西有两份实现，就一定会分叉。一个中文
表格在文档视图里对齐、在机器视图里错位，比两边都不对齐更难查。

`chat-ui--expand-tabs` 是它未来的第三个调用方，但把那处改过来不在本 spec 范围内，
不为了整齐去动一段正在正常工作的代码。

### 5.2 分隔行

`| --- | --- |` 那一行显示成 `├──┼──┤`，普通管道显示成 `│`，并与列宽对齐。
全部用 `display` 属性，源文本仍是合法 Markdown。

### 5.3 对齐是唯一改动文本的地方

补空格会让缓冲区文本与源码不同。这条例外可以接受，因为**补过空格的表格仍然是
合法且等价的 Markdown**——复制出去照样能用。除此之外的任何构造 MUST NOT 改动
缓冲区文本。

### 5.4 太宽的表格

超过窗口宽度的表格 MUST NOT 横向溢出到看不见。落地行为：按窗口宽度截断并在行尾
给出可见的截断标记，或整表退化为不对齐的原样文本；二者择一，但必须是确定的、
写进验收的行为。

**已定行为**：选第一种，按 `chat-markdown-table-max-width`（默认 100 列）等比
压缩各列，超宽单元格截断并以 `…` 结尾。不丢列——只剩三列的表格看起来像本来就
只有三列，比看起来窄一点更难发现。宽度是配置值而不是窗口宽度，因为
`chat-markdown-render` 是纯函数：读窗口宽度会让同一段文本在两个窗口里渲染出
不同结果，破坏"流式与重绘产出完全一致"这条。

## Requirement 6: Streaming

### 6.1 稳定前缀

把 `chat-ui--fence-safe-prefix-length` 的思路从"围栏"推广到"块"：

```
chat-markdown-stable-prefix-length (source) → integer
```

返回 `source` 里只由**已完成的块**组成的那段前缀的长度。已完成的判定：

- 围栏代码块：闭合围栏到了
- 段落：后面跟了空行
- 列表：后面跟了空行或非列表行
- 表格：后面跟了非表格行或空行
- 引用块：后面跟了非引用行

### 6.2 增量代价

- 稳定前缀渲染一次，结果留着
- 每次新块到达，只重渲染尾部那个未完成的块
- 单次渲染代价 MUST 与尾部未完成块的大小成正比，MUST NOT 与全文长度成正比
- 尾部块超过行数上限（比如一个还在流入的大代码块）时，退化为纯 face，
  等它完成再正式渲染

### 6.3 不阻塞

渲染在主循环里跑，所以它 MUST 快。spec 004 Requirement 5 的不阻塞约束在此继续
适用：渲染路径上不许有 `sit-for`、`sleep-for`、`accept-process-output`，
不许起子进程。

## Acceptance

### 职责边界

- [ ] 渲染结果不回流成数据：重绘、复制、送回模型、落盘取的都是原始 Markdown
- [ ] `chat-markdown.el` 在 `lisp/core/`，且不 require `lisp/ui/` 下任何模块
      （静态断言，保证 spec 006 的 core 模块能 require 它而不倒置方向）

### 渲染一致性

- [ ] 同一段 Markdown，流式接收后与关闭重开后，缓冲区的文本属性完全相同
- [ ] finalize 之后触发一次折叠再展开，标题与粗体的样式仍在（当前会丢）
- [ ] 即席问答的答案与错误信息也过渲染器，不再是裸 `insert`
- [ ] 渲染函数对同一输入两次调用返回 `equal-including-properties` 的结果

### 标记与复制

- [ ] `**粗**` 显示为粗体且看不到星号
- [ ] 选中该段复制，kill-ring 里拿到的是带 `**` 的原始 Markdown
- [ ] 开关命令打开后，全部标记可见；关掉后回到隐藏
- [ ] 除表格补空格外，渲染前后缓冲区文本（去掉 `invisible`/`display` 影响）
      与源码逐字相同

### 频道叠加

- [ ] 中间说明段落里的行内代码同时是斜体和代码 face
- [ ] 推理内容里的代码块不会因为 Markdown face 而丢掉 `shadow` 底色

### 代码块

- [ ] ` ```elisp ` 块内的关键字、字符串、注释各自上色
- [ ] 未闭合的围栏在流入期间只有纯代码 face，闭合后立刻转为语法色
- [ ] 语言标签是映射表外且对应 mode 未加载时，不触发任何包加载，退回纯 face
- [ ] 让映射到的 mode 抛错，只有这一个块退回纯 face，整条回答其余部分照常
- [ ] 同一个块在流式期间被反复渲染，font-lock 只跑一次（缓存命中）

### 表格

- [ ] 含中文单元格的表格竖线对齐（`string-width`，不是 `length`）
- [ ] 分隔行显示为横线
- [ ] 复制出来的表格是合法 Markdown
- [ ] 超宽表格不横向溢出，落地为写进本 spec 的那一种确定行为
- [ ] 按显示宽度排版列只有一处实现，放在 core 且不依赖任何显示模块，
      spec 006 的机器视图 require 的是同一个它

### 换行

- [ ] 长段落在词边界换行，不在词中间断开
- [ ] 列表项续行与首行文字左边缘对齐
- [ ] `C-a` 仍然是 `chat-ui-beginning-of-input`，没有被换行相关的 minor mode
      抢走

### 提示词

- [ ] 系统提示词包含输出格式约定，且与回答语言约定并存不互相覆盖
- [ ] 子集里每条限制都带理由
- [ ] 模型写出子集外的构造（HTML、数学、五级标题、超宽表格）时，渲染器不崩、
      不吞内容、不影响后续文本

### 性能

- [ ] 流式追加一个块的渲染耗时不随已有内容长度增长
- [ ] 渲染路径上没有 `sit-for` / `sleep-for` / `accept-process-output` /
      子进程（静态断言，与 spec 004 同款）

### 文档

- [ ] `docs/index.html:104` 改成与实际一致（当前写超了）
- [ ] `docs/architecture/design.md:711` 的 `chat-markdown.el` 从"计划"变成
      "存在"

## Behavior Boundaries

- **格式与显示分属两层。** Markdown 这个格式承担完整文档的输入输出，是事实来源；
  这个引擎只承担它在 Emacs 里的显示。渲染结果永远不回流成数据
- **只管显示，不管编辑。** 这个引擎把 Markdown 显示成文档。它不提供 Markdown
  的编辑命令、补全、大纲跳转、表格编辑。`chat-mode` 仍然是 `chat-mode`，
  不会变成通用 Markdown 编辑模式
- **图片不内联。** 显示成一行可点开的占位。真要看图交给外部程序
- **数学不渲染。** 原样显示。渲染 LaTeX 需要外部进程或图片，两者都在 non-goals
- **HTML 原样。** 淡化显示，不解释
- **不追求 CommonMark 合规。** 覆盖面按"模型实际会写什么"决定，不按一致性测试集
  决定。子集外的构造有确定的落地行为，但不保证符合 CommonMark 的判定
- **提示词收窄是软约束。** 它改善显示效果，不构成渲染器的前提。渲染器对任何输入
  都要有确定行为

## Notes

`markdown.el` 这个名字在本仓库落成 `lisp/core/chat-markdown.el`：仓库里所有模块都是
`chat-` 前缀，而且 `docs/architecture/design.md:711` 早就以这个名字预留了位置。
放 core 而不是 ui 的两条依据见 Requirement 1.1——它是纯函数（先例是同样定义 face
的 `lisp/core/chat-transcript.el`），而且 spec 006 的 core 模块要能 require 它。

相关 spec：

- **004** 拥有频道排版（推理、工具、中间说明、答案的前缀、字形、折叠）。
  本 spec 只管频道**内部**的结构，两者叠加而非覆盖，见 Requirement 1.2
- **006** 拥有 MDP 的编解码与机器视图。MDP 报文是合法 Markdown，
  所以它的文档视图由本 spec 免费提供；反过来本 spec 不知道 MDP 存在，
  也不该知道
