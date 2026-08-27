;;; chat-i18n-zh-cn.el --- Simplified Chinese catalog -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: convenience, i18n

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The Simplified Chinese catalog.
;;
;; The help text is the reason this file exists.  Someone who cannot tell
;; what the surface does will not go looking through the source for it,
;; and a command list they cannot read is the same as no command list.
;;
;; Command names get aliases rather than a translated command table, so
;; `/auto' and `/自动' reach the same handler and every property of that
;; command is still declared once.  The ASCII names keep working: a
;; bilingual user types whichever comes to hand, and a Chinese help that
;; described commands the program did not answer to would be worse than
;; an English one.
;;
;; Key sequences stay in ASCII.  They are what you press, not what you
;; read.  A test asserts that this help names exactly the keys and slash
;; commands the English one does.
;;
;; The prompt catalog at the end is a different thing from the rest of
;; this file, and it is switched separately by `chat-prompt-language'.
;; What the user reads is cosmetic; what the model reads is not.

;;; Code:

(require 'chat-i18n)

(chat-i18n-register-aliases
 'zh-CN
 '(("帮助" . "help")
   ("取消" . "cancel")
   ("模型" . "model")
   ("发送" . "send")
   ("快问" . "quick")
   ("命令" . "cmd")
   ("暂存" . "queue")
   ("发出" . "flush")
   ("撤回" . "drop")
   ("目录" . "cd")
   ("当前目录" . "pwd")
   ("新建" . "new")
   ("列表" . "list")
   ("保存" . "save")
   ("清理" . "clear")
   ("知识库" . "wiki")
   ("审批" . "approve")
   ("自动" . "auto")))

(chat-i18n-register
 'zh-CN
 '((help-text . "与模型对话：
  /send <消息>          - 发送并记入会话；模型可以调工具、分多步完成。
                          等同于不带前缀直接输入。
  /send                 - 把 /queue 攒下的内容一次发出
  /quick <问题>         - 只问一次，不记入会话、不调工具。
                          也可写 /? 或简写 ?<问题>
  /queue <条目>         - 攒一条，等下次 /flush 一起发出
  /queue                - 列出已攒的内容
  /flush [条目]         - 把攒下的内容合成一条消息发出
  /drop [all]           - 丢掉最后一条已攒内容，或全部丢掉
  /cancel               - 取消当前 AI 请求
  /help [关键词]        - 本帮助，或只看含关键词的行
  /model <名称>         - 切换本会话的模型（C-c C-m，不给名称则提示选择）

/send 和 /quick 是两种问法，区别在于留下什么：/send 是对话本身，会写进
记录，由一次可以读文件、可以分步推进的运行来回答。/quick 是搭在对话旁边
问一句 —— 什么都不记录，也不调工具，这既是它便宜的原因，也是它转头就没
了的原因。

会话：
  /new                  - 新建会话
  /list                 - 列出所有会话
  /save                 - 保存当前会话
  /clear                - 丢掉本会话的对话内容，会话本身保留
  M-x chat-session-tree-open - 以树形浏览已保存会话

快捷 Shell（混合模式）：
  !<命令>               - 直接执行 shell 命令
  /cmd <命令>           - 同 !<命令>。也可写 /!
  !!                    - 重复上一条 shell 命令
  !cd <目录>            - 切换工作目录（单独 cd 回到家目录）
  /cd [目录]            - 切换工作目录（不给目录则提示选择）
  /pwd                  - 显示当前工作目录
  \\<文本>              - 原样发送，即使开头是 ! 或 /

工作目录属于会话，重开会话时会恢复，AI 工具也在该目录下运行。

命令语法处的全角标点一律有效：！ ？ ／ 和全角空格都能走到同一个命令。
命令参数不会被改写，所以 shell 命令体和问题内容保留你自己的标点。

按键：
  RET                   - 发送
  S-RET                 - 换行但不发送
  C-g                   - 取消当前请求
  C-c C-n / C-c C-l     - 新建会话 / 列出会话
  C-c C-m               - 切换模型
  C-c C-e / C-c C-g     - 编辑上一条消息 / 重新生成上一条回复
  C-c C-s / C-c C-p     - 请求状态 / 请求面板
  C-c C-t               - 切换本会话的自动批准
  C-c C-q / C-c C-SPC   - 引用选区 / 就选区提问
  C-c C-d               - 展开或折叠全部细节
  C-c C-u               - 显示或隐藏 Markdown 标记
  M-p / M-n             - 召回更早 / 更晚的输入
  C-a                   - 跳到你输入内容的开头（不是行首）
  TAB                   - 补全：/ 之后补命令，其余补路径
  C-c C-h               - 本帮助

Auto（默认命令）：
  直接输入会走某一个命令，默认是 /send。成串出现的活儿会把它抢过去：
  `!ls' 会把 /cmd 设为默认，于是下一行也当 shell 命令；/queue 对攒条目
  同理。而任何问模型的动作都会把它交还给 /send —— 所以问一句就能从
  shell 模式里出来。
  /auto            - 说明当前直接输入会走哪个命令
  /auto cmd        - 直接输入走 shell
  /auto off        - 直接输入回到问模型
  \\<文本>         - 不管 auto 如何，这一行直接给模型
  只要当前不是 /send，输入提示符上就会写着是哪个命令占着它，状态栏也会
  显示 `auto: /cmd'。显式写出的 /命令 永远是它自己；有回复正在跑时，
  直接输入是给那次运行补充信息，而不是走默认命令。

审批（谁来决定工具调用能不能跑）：
  /approve            - 说明当前是哪种模式，以及是全局设的还是本会话设的
  /approve manual     - 白名单直接放行，其余逐次问你（默认）
  /approve guarded    - 由一个 guard 模型裁决，不问你；被拒时会把理由告诉
                        助手，助手可以换个路子。旧名 auto 仍然接受。
  /approve dangerous  - 一切都跑，命令闸门也一并关掉；切换时需要确认
  人工审批时可以选一次允许、本会话允许、以后都允许；后两种会记成授权，
  用 M-x chat-approval-list-grants 查看，M-x chat-approval-clear-runtime-grants
  清掉程序自己记下的那份。

语言：
  用 `chat-language' 设置界面语言，保持 `auto' 则跟随 Emacs 的语言环境。
  命令名有对应的中文写法：/auto 和 /自动 是同一个命令，补全会给出当前
  语言的写法。任何语言的命令名都始终接受。
  `chat-reply-language' 是告诉模型用什么语言回答，`chat-prompt-language'
  是发给模型的指令本身用什么语言。两者默认都跟随 `chat-language'。如果
  中文提示词的效果不如英文，把 `chat-prompt-language' 固定为 `en'。

看懂一次回复：
  一次运行会推理、调工具、读结果，最后才回答，这些全部保留下来。
  推理和工具调用默认折叠在一行摘要后面，在摘要行上按 RET 或点一下就
  展开。运行过程中产生的文字用斜体显示，方便阅读又不会被当成答案。
  C-c C-d 一次展开或折叠全部。

编程会话：
  M-x chat-code-start        - 新建带项目上下文的会话
  M-x chat-code-from-chat    - 给当前会话加上代码能力
  C-c C-a / C-c C-k          - 接受 / 拒绝一处修改建议
  C-c C-v                    - 以 diff 形式查看修改建议
  C-c C-f                    - 聚焦某个文件
  C-c C-r                    - 重建项目上下文

代码能力是会话的属性，不是另一个缓冲区：它给同一个聊天加上项目上下文、
编程规则和修改建议。没有该能力的会话里，修改和上下文相关按键不做任何事。

使用要点：
  - 引用类命令把内容填进输入区，方便你继续补充；提问类命令直接发送。
  - 请求面板显示执行细节，不把这些细节堆进对话正文。
  - 接受修改前，可以先在 *chat-preview* 里预览。
  - 文件写入的审批可以一次放行一个目录子树。
  - 在输入区输入路径样式的内容会自动补全文件名。
  - 长文档按段推进，不要一次要一大篇；已有文件用定向修改，
    整体写入只留给新文件。

阅读工作流：
  M-x chat-quote-region       - 把选区引用进聊天
  M-x chat-quote-defun        - 把光标处的函数引用进聊天
  M-x chat-quote-near-point   - 把光标附近的上下文引用进聊天
  M-x chat-quote-current-file - 把当前文件引用进聊天
  M-x chat-ask-region         - 就选区提问
  M-x chat-ask-defun          - 就光标处的函数提问
  M-x chat-ask-near-point     - 就光标附近的上下文提问
  M-x chat-ask-current-file   - 就当前文件提问

Wiki（/wiki <子命令>）：
  /wiki index             - 打开生成的索引
  /wiki log               - 打开操作日志
  /wiki lint              - 报告孤儿页、坏链、空页
  /wiki search <文本>     - 列出匹配的页面
  /wiki find              - 挑一个页面打开
  /wiki new <类型> <名称> - 新建页面
  /wiki ingest <文件>     - 导入文档并让模型写摘要
  /wiki ask <问题>        - 用 wiki 回答

在聊天缓冲区里输入消息，按 RET 发送。")

   ;; Auto, the default command.
   (auto-claimed . "直接输入现在会走 /%s。/auto off 可以停掉。")
   (auto-released . "直接输入又回到问模型了。")
   (auto-state-on . "Auto：直接输入会走 /%s。/auto off 可以停掉。")
   (auto-state-off . "Auto：关闭 —— 直接输入会给模型。可作为默认的命令：%s")
   (auto-turned-off . "Auto：关闭 —— 直接输入会给模型。")
   (auto-not-repeatable . "/%s 不能作为默认命令。可作为默认的命令：%s")

   ;; Help.
   (help-topic-heading . "关于 %s 的帮助：")
   (help-topic-missing . "帮助里没有提到 %s。用 /help 看全部。")
   (help-buffer-footer . "这里是帮助缓冲区：SPC 和 DEL 翻页，q 关闭。")

   ;; Roles and labels in the transcript.
   (role-you . "你")
   (role-assistant . "助手")
   (role-assistant-quick . "助手（快问）")
   (role-system . "系统")
   (detail-label . "细节")
   (detail-shown . "已展开全部细节")
   (detail-folded . "已折叠细节")
   (fold-echo-open . "按 RET 或点击展开")
   (fold-echo-close . "按 RET 或点击折叠")
   (channel-thinking . "推理")
   (channel-tool-work . "工具调用")
   (channel-interim . "过程")
   (channel-system . "系统")
   (part-thinking . "推理")
   (part-tool-call . "调用工具")
   (part-tool-result . "工具结果")
   (part-progress . "过程")
   (tools-used . "用到的工具：%s")
   (tool-loop-stopped . "工具调用达到安全上限，已停止。")

   ;; Status line.
   (status-model . "模型：%s")
   (status-auto . "auto：/%s")
   (status-queued . "已攒：%d")

   ;; The prompt, and switching provider from it.
   (prompt-model-switch . "%s —— 鼠标左键切换模型")
   (switch-model-title . "模型")
   (only-one-provider . "只配置了一个模型")

   ;; Completion annotations.
   (command-annotation-sticky . "可接管直接输入")
   (command-annotation-while-busy . "忙时也能用")

   ;; Shell and directory.
   (shell-usage . "用法：!<命令>")
   (shell-nothing-to-repeat . "⚠️ 还没有可重复的 shell 命令")
   (no-output . "（无输出）")
   (directory-changed . "📁 工作目录已切换到：%s")
   (directory-missing . "❌ 找不到目录：%s")
   (shell-no-previous-directory . "cd：还没有上一个目录")
   (shell-empty-directory-stack . "popd：目录栈是空的")
   (shell-bad-assignment . "export：变量名不合法")
   (shell-unset . "已取消 %s")

   ;; Sending.
   (empty-message . "不能发送空消息")
   (input-history-empty . "还没有输入历史")
   (input-history-oldest . "已经是最早的输入")
   (send-usage . "用法：/send <消息>；单独写 /send 则把攒下的内容发出。\n\
运行中再发送：/send insert|queue|interrupt <消息>；只写模式名则改默认。")
   (send-mode-set . "运行中再发送，现在是：%s")
   (send-queued-count . "已排队，等这次回复跑完再发（%d 条在等）。")
   (send-interrupted . "已打断，保留了已经生成的部分。")
   (request-in-progress . "已有回复正在生成。先取消它再发送新消息。")
   (request-cancelled . "请求已取消。")
   (message-queued . "消息已排入正在进行的回复。")
   (response-starting . "正在获取 AI 回复……")
   (query-asking . "🤖 正在问 AI……")
   (error-note . "❌ 出错：%s")

   ;; The queue.
   (queue-added . "已攒第 %d 条：%s（/flush 发出，/queue 查看）")
   (queue-empty . "还没有攒任何内容。/queue <条目> 可以攒起来一起发。")
   (queue-heading . "已攒 %d 条，/flush 发出：")
   (queue-dropped . "已丢掉：%s")
   (queue-dropped-all . "已丢掉全部 %d 条。")

   ;; Sessions.
   (no-session . "这里没有会话。")
   (session-saved . "已保存：%s")
   (clear-confirm . "确定丢掉这段对话吗？")
   (clear-cancelled . "对话保留了。")
   (conversation-cleared . "对话已清空。")

   ;; Tool forge.
   (tool-forge-creating . "🔨 正在根据你的描述创建工具……")
   (tool-forge-created . "✅ 工具 '%s'（%s）已创建并注册！")
   (tool-forge-failed . "❌ 创建工具失败。请把描述写得更清楚一些再试。")

   ;; Wiki.  The subcommand names themselves stay as typed; these are the
   ;; sentences around them.
   (wiki-usage . "用法：/wiki <子命令>
  index             打开生成的索引
  log               打开操作日志
  lint              报告孤儿页、坏链、空页
  search <文本>     列出匹配的页面
  find              挑一个页面打开
  new <类型> <名称> 新建页面
  ingest <文件>     导入文档并让模型写摘要
  ask <问题>        用 wiki 回答")
   (wiki-unknown-subcommand . "没有叫 %s 的 /wiki 子命令。")
   (wiki-lint-clean . "Wiki：没有问题。")
   (wiki-lint-found . "Wiki：%d 个问题。")
   (wiki-search-usage . "用法：/wiki search <文本>")
   (wiki-search-none . "Wiki：没有页面匹配 %s。")
   (wiki-search-found . "Wiki：%d 个页面匹配 %s。")
   (wiki-new-usage . "用法：/wiki new <%s> <名称>")
   (wiki-new-bad-type . "没有这种页面类型：%s。可选：%s。")
   (wiki-created . "Wiki：已新建 %s。")
   (wiki-ingest-usage . "用法：/wiki ingest <文件>")
   (wiki-ingest-missing . "读不了 %s。")
   (wiki-ingested . "Wiki：已导入 %s。")
   (wiki-ingest-request . "请读 wiki 页面「%s」，用 wiki 工具，依据它的 Full Content 补全 Summary、Extracted Entities 和 Related Concepts。实体和概念用 [[双链]] 标注，并把链到的页面建出来。")
   (wiki-ask-usage . "用法：/wiki ask <问题>")
   (wiki-ask-note . "（回答前请用 wiki_search 和 wiki_read 查一下 wiki。）")
   (wiki-no-surface . "请在聊天缓冲区里用。")))

;; Prompt text.  Switched by `chat-prompt-language', not by
;; `chat-language': translated guidance changes what the model does, and
;; whether it does it better cannot be measured from inside Emacs.  Only
;; prose is here.  Tool names, JSON keys, patch envelopes and file names
;; like AGENTS.md are matched literally by a parser and never translated.
(chat-i18n-register-prompts
 'zh-CN
 '((assistant-persona . "你是一个有帮助的 AI 助手。")
   (reply-language . "用%s回答。标识符、文件路径、命令、报错文本和引用的代码
一律保持原样 —— 把这些翻译过去会让它们再也搜不到。如果用户改用其他语言
提问，就跟随用户。")
   (output-format . "回答用 Markdown 写。它会在编辑器里被渲染，所以只用渲染
效果好的这个子集：
- 标题用 ATX 形式（`## 标题`），从二级起，最深到四级。不要用下划线式标题：
  那种形式要等下一行才能判定，而那时它已经画完了。
- 段落不要手动折行。文本按窗口宽度换行，手折过的段落在任何别的宽度下都参差。
- 围栏代码块一律标明语言。语言决定语法高亮，不写就没有高亮。
- 列表最多嵌两层。
- 表格只用于数据确实是表格的场合，最多四列，单元格保持短。宽表格放不进窗口。
- 标识符、路径、命令用行内代码。
- 粗体省着用，不要拿它当标题。
- 不要 HTML、不要 LaTeX 数学、不要图片、不要脚注：这几样都不渲染。")
   (code-persona . "你是一名资深程序员。帮助用户编写、理解和修改代码。

修改代码时：
- 遵循现有的代码风格和约定
- 在合适的地方加上错误处理
- 为新功能补上测试
- 用清晰的 docstring 说明公开 API
- 优先小而集中的改动，而不是大规模重写
- 只通过 JSON 工具调用协议使用可用工具
- 生成代码时，考虑项目里已有的模式
- 把当前项目根目录当作默认工作目录
- 先用文件类工具查看，再考虑 shell 命令
- 只在文件类工具不够用时，才用 shell 做轻量的只读查看
- 除非用户明确要求，不要离开当前项目
- 遇到访问被拒、审批被拒或命令不允许之后，不要重复同一种被挡住的调用方式
- 一旦证据足够回答问题，就停止调用工具
- 工具调用要高效、有目的、达到生产质量，而不是为了探索而探索")))

(provide 'chat-i18n-zh-cn)
;;; chat-i18n-zh-cn.el ends here
