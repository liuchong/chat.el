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
;; Key sequences, command names and slash names stay in ASCII: they are
;; what you type, not what you read, and translating them would make the
;; help describe a program that does not exist.  A test asserts that this
;; help names exactly the keys and slash commands the English one does.

;;; Code:

(require 'chat-i18n)

(chat-i18n-register
 'zh-CN
 '((help-text . "聊天命令：
  /help [关键词]        - 本帮助，或只看含关键词的行
  /cancel               - 取消当前 AI 请求
  /new                  - 新建会话
  /list                 - 列出所有会话
  M-x chat-session-tree-open - 以树形浏览已保存会话
  /save                 - 保存当前会话
  /clear                - 清空对话
  /model <名称>         - 切换本会话的模型（C-c C-m，不给名称则提示选择）

快捷 Shell（混合模式）：
  !<命令>               - 直接执行 shell 命令
  /cmd <命令>           - 同 !<命令>
  !!                    - 重复上一条 shell 命令
  !cd <目录>            - 切换工作目录（单独 cd 回到家目录）
  /cd [目录]            - 切换工作目录（不给目录则提示选择）
  /pwd                  - 显示当前工作目录
  ?<问题>               - 直接问 AI（不写入历史）
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
  C-a                   - 跳到你输入内容的开头（不是行首）
  TAB                   - 补全：/ 之后补命令，其余补路径
  C-c C-h               - 本帮助

Auto（默认命令）：
  shell 活儿总是一串一串来的，所以 `!ls' 同时会把 /cmd 设为默认命令：
  之后直接输入就走 shell，直到你另行指定。开着的时候状态栏显示
  `auto: /cmd'。
  /auto            - 说明当前直接输入会走哪个命令
  /auto cmd        - 直接输入走 shell
  /auto off        - 直接输入回到问模型
  \\<文本>         - 不管 auto 如何，这一行直接给模型
  显式写出的 /命令 永远是它自己；有回复正在跑时，直接输入是给那次运行
  补充信息，而不是走默认命令。

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

Wiki 命令：
  /wiki-ingest <路径>   - 导入源文档
  /wiki-query <问题>    - 查询 wiki 知识
  /wiki-lint            - 运行 wiki 健康检查
  /wiki-index           - 打开 wiki 索引
  /wiki-log             - 打开 wiki 日志

输入你的消息，按 RET 发送。")

   ;; Auto, the default command.
   (auto-claimed . "直接输入现在会走 /%s。/auto off 可以停掉。")
   (auto-state-on . "Auto：直接输入会走 /%s。/auto off 可以停掉。")
   (auto-state-off . "Auto：关闭 —— 直接输入会给模型。可作为默认的命令：%s")
   (auto-turned-off . "Auto：关闭 —— 直接输入会给模型。")
   (auto-not-repeatable . "/%s 不能作为默认命令。可作为默认的命令：%s")

   ;; Help.
   (help-topic-heading . "关于 %s 的帮助：")
   (help-topic-missing . "帮助里没有提到 %s。用 /help 看全部。")

   ;; Shell and directory.
   (shell-usage . "用法：!<命令>")
   (no-output . "（无输出）")

   ;; Sending.
   (empty-message . "不能发送空消息")
   (request-in-progress . "已有回复正在生成。先取消它再发送新消息。")
   (request-cancelled . "请求已取消。")
   (message-queued . "消息已排入正在进行的回复。")))

(provide 'chat-i18n-zh-cn)
;;; chat-i18n-zh-cn.el ends here
