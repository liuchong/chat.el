# Chat.el - 纯 Emacs AI 执行器设计方案

## 1. 项目概述

Chat.el 是一个完全基于 Emacs 的 AI 执行器，类似于 OpenClaw，但完全集成在 Emacs 生态中。它提供了一个类似 `M-x shell` 的简单但功能强大的对话前端，支持多对话管理、上下文智能处理、历史消息追问等高级功能。

与 OpenClaw 不同，Chat.el 不仅是对话工具，更是一个完整的 **Agent Runtime**——支持主动调度、长期记忆、人格定义、**自定义工具持久化**、**多语言工具支持**和自主任务执行。系统能够根据用户需求自我演进，动态扩展能力，并智能管理外部依赖。

## 2. 核心设计理念

- **纯 Emacs**: 零外部依赖，仅使用 Emacs Lisp 和原生 HTTP 客户端
- **Agent Runtime**: 从被动对话工具升级为能主动执行任务的 Agent
- **自我演进**: 用户和 AI 可以共同创造、改进、持久化工具，系统能力不断扩展
- **多语言支持**: 工具不限于 Emacs Lisp，支持 Python、Shell、Node.js 等任何语言
- **智能依赖管理**: 自动检测环境，提醒用户安装缺失的依赖
- **Unix 哲学**: 每个组件只做一件事，做好一件事
- **可组合性**: 各层之间通过清晰的接口解耦
- **渐进式功能**: 核心简洁，功能通过插件/配置扩展

## 3. 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│              Polyglot Tool Forge (多语言工具锻造层)              │  <- ⭐ 新增/扩展
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Language Support: Elisp | Python | Shell | Node | Ruby  │  │
│  │  Dependency Manager | Env Detector | Auto Installer      │  │
│  └──────────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│                      Heartbeat Scheduler                        │
│              (主动任务调度、定时执行、后台 Agent)                   │
├─────────────────────────────────────────────────────────────────┤
│                        User Interface Layer                     │
├─────────────────────────────────────────────────────────────────┤
│                      Conversation Manager                       │
├─────────────────────────────────────────────────────────────────┤
│                    Memory System                                │
├─────────────────────────────────────────────────────────────────┤
│                    Persona Engine                               │
├─────────────────────────────────────────────────────────────────┤
│                    ... 其他层 ...                                │
└─────────────────────────────────────────────────────────────────┘
```

## 4. 分层详细设计

### 4.1 多语言工具锻造层 (chat-tool-forge.el)

#### 4.1.1 多语言支持设计

工具不再局限于 Emacs Lisp，支持任何可执行代码：

```elisp
(defcustom chat-tool-forge-languages
  '((elisp . (:name "Emacs Lisp"
              :extension ".el"
              :interpreter nil              ; 原生执行
              :compiler nil
              :executor chat-tool-forge--exec-elisp
              :template chat-tool-forge--template-elisp))
    (python . (:name "Python"
               :extension ".py"
               :interpreter ("python3" "python")
               :compiler nil
               :executor chat-tool-forge--exec-python
               :template chat-tool-forge--template-python
               :deps-manager "pip"
               :deps-file "requirements.txt"
               :setup-check chat-tool-forge--check-python))
    (shell . (:name "Shell Script"
              :extension ".sh"
              :interpreter ("bash" "zsh" "sh")
              :compiler nil
              :executor chat-tool-forge--exec-shell
              :template chat-tool-forge--template-shell))
    (node . (:name "Node.js"
             :extension ".js"
             :interpreter "node"
             :compiler nil
             :executor chat-tool-forge--exec-node
             :template chat-tool-forge--template-node
             :deps-manager "npm"
             :deps-file "package.json"
             :setup-check chat-tool-forge--check-node))
    (ruby . (:name "Ruby"
             :extension ".rb"
             :interpreter "ruby"
             :compiler nil
             :executor chat-tool-forge--exec-ruby
             :template chat-tool-forge--template-ruby))
    (go . (:name "Go"
           :extension ".go"
           :interpreter nil
           :compiler "go"
           :executor chat-tool-forge--exec-go
           :template chat-tool-forge--template-go
           :compile-cmd "go build -o {output} {input}"))
    (rust . (:name "Rust"
             :extension ".rs"
             :interpreter nil
             :compiler "rustc"
             :executor chat-tool-forge--exec-rust
             :template chat-tool-forge--template-rust
             :compile-cmd "rustc -o {output} {input}")))
  "支持的工具编程语言及其配置")
```

#### 4.1.2 多语言工具元数据

```elisp
(cl-defstruct chat-forged-tool
  id                    ; 唯一标识 (symbol)
  name                  ; 显示名称
  description           ; 功能描述
  author                ; 作者 (user/ai/community)
  version               ; 版本号
  created-at            ; 创建时间
  updated-at            ; 更新时间
  
  ;; ⭐ 多语言支持
  language              ; 编程语言 (elisp/python/shell/node/etc)
  source-code           ; 源代码
  compiled-path         ; 编译后的路径（如果需要编译）
  
  ;; 执行配置
  interpreter-args      ; 解释器参数
  env-vars              ; 环境变量
  working-directory     ; 工作目录
  timeout               ; 超时时间
  
  ;; 依赖管理
  dependencies          ; 依赖列表 ((:name "requests" :type "pip"))
  system-deps           ; 系统依赖 ("curl" "jq")
  
  ;; 其他元数据
  parameters            ; 参数定义 (JSON Schema)
  category
  tags
  usage-count
  rating
  parent-id
  is-active)
```

#### 4.1.3 多语言工具存储结构

```
~/.chat/tools/
├── elisp/
│   ├── git-commit-analyzer.el
│   └── project-deps-graph.el
├── python/
│   ├── data-visualizer.py
│   ├── requirements.txt      # Python 依赖
│   └── pdf-parser/
│       ├── main.py
│       └── requirements.txt
├── node/
│   ├── markdown-converter.js
│   └── package.json          # Node 依赖
├── shell/
│   └── backup-manager.sh
├── go/
│   └── log-analyzer.go
├── .tool-index.el            # 工具索引
└── versions/
    └── ...
```

#### 4.1.4 多语言工具定义示例

**Python 工具示例**:
```python
#!/usr/bin/env python3
# chat-tool: data-visualizer
# version: 1.0.0
# language: python
# description: 使用 matplotlib 生成数据可视化图表
# dependencies:
#   - matplotlib
#   - pandas
# system-deps:
#   - python3

import sys
import json
import argparse

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', required=True, help='JSON 数据')
    parser.add_argument('--type', default='line', choices=['line', 'bar', 'pie'])
    parser.add_argument('--output', required=True, help='输出图片路径')
    args = parser.parse_args()
    
    data = json.loads(args.data)
    
    import matplotlib.pyplot as plt
    import pandas as pd
    
    # 生成图表...
    df = pd.DataFrame(data)
    df.plot(kind=args.type)
    plt.savefig(args.output)
    print(f"图表已保存到: {args.output}")

if __name__ == '__main__':
    main()
```

**Node.js 工具示例**:
```javascript
#!/usr/bin/env node
// chat-tool: markdown-to-pdf
// version: 1.0.0
// language: node
// description: 将 Markdown 转换为 PDF
// dependencies:
//   - puppeteer
//   - marked

const puppeteer = require('puppeteer');
const marked = require('marked');
const fs = require('fs');

async function convert(inputFile, outputFile) {
    const markdown = fs.readFileSync(inputFile, 'utf-8');
    const html = marked.parse(markdown);
    
    const browser = await puppeteer.launch();
    const page = await browser.newPage();
    await page.setContent(html);
    await page.pdf({ path: outputFile, format: 'A4' });
    await browser.close();
    
    console.log(`PDF 已生成: ${outputFile}`);
}

const [,, input, output] = process.argv;
convert(input, output);
```

#### 4.1.5 环境检测与依赖管理 ⭐核心

```elisp
(cl-defstruct chat-tool-env
  language              ; 语言
  interpreter-path      ; 解释器路径
  version               ; 版本
  deps-installed        ; 已安装的依赖
  deps-missing          ; 缺失的依赖
  system-deps-missing   ; 缺失的系统依赖
  setup-commands        ; 建议的安装命令
  is-ready)             ; 是否可用

(defun chat-tool-forge-detect-env (language)
  "检测指定语言的运行环境"
  ;; 1. 检查解释器/编译器是否存在
  ;; 2. 检查版本是否符合要求
  ;; 3. 检查已安装的依赖
  ;; 4. 返回 env 结构
  )

(defun chat-tool-forge-check-tool-deps (tool-id)
  "检查工具的依赖是否满足"
  (let* ((tool (chat-forged-tools-get tool-id))
         (env (chat-tool-forge-detect-env (chat-forged-tool-language tool)))
         (missing-deps (seq-difference 
                        (chat-forged-tool-dependencies tool)
                        (chat-tool-env-deps-installed env)))
         (missing-sys (seq-difference
                       (chat-forged-tool-system-deps tool)
                       (chat-tool-env-deps-installed env))))
    (when (or missing-deps missing-sys)
      (chat-tool-forge--prompt-install tool missing-deps missing-sys))))

(defun chat-tool-forge--prompt-install (tool missing-deps missing-sys)
  "提示用户安装缺失的依赖"
  (let ((commands (chat-tool-forge--generate-install-commands 
                   tool missing-deps missing-sys)))
    (chat-tool-forge-ui-show-install-dialog 
     tool missing-deps missing-sys commands)))
```

**安装提醒界面**:
```
┌─────────────────────────────────────────────────────────────┐
│ ⚠️  工具 'data-visualizer' 需要安装依赖                      │
├─────────────────────────────────────────────────────────────┤
│ 语言环境: Python 3.9 ✓                                       │
│                                                             │
│ 缺失的依赖:                                                  │
│   - matplotlib (pip)                                        │
│   - pandas (pip)                                            │
│                                                             │
│ 建议安装命令:                                                │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ pip3 install matplotlib pandas                      │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                             │
│ [复制命令] [自动安装] [跳过] [查看文档]                       │
└─────────────────────────────────────────────────────────────┘
```

#### 4.1.6 自动安装功能

```elisp
(defun chat-tool-forge-auto-install (tool-id)
  "自动安装工具的依赖"
  (let* ((tool (chat-forged-tools-get tool-id))
         (lang (chat-forged-tool-language tool))
         (deps (chat-forged-tool-dependencies tool)))
    (pcase lang
      ('python (chat-tool-forge--pip-install deps))
      ('node (chat-tool-forge--npm-install deps))
      ('ruby (chat-tool-forge--gem-install deps))
      ;; 等等
      )))

(defun chat-tool-forge--pip-install (packages)
  "使用 pip 安装 Python 包"
  (let ((cmd (format "pip3 install %s" 
                     (mapconcat #'identity packages " "))))
    (async-shell-command cmd)))
```

#### 4.1.7 多语言执行器

```elisp
(defun chat-tool-forge--exec-python (tool args)
  "执行 Python 工具"
  (let* ((source (chat-forged-tool-source-code tool))
         (temp-file (make-temp-file "chat-tool-" nil ".py"))
         (cmd (format "python3 %s %s" 
                      temp-file
                      (chat-tool-forge--args-to-string args))))
    ;; 写入临时文件
    (with-temp-file temp-file
      (insert source))
    ;; 执行
    (let ((output (shell-command-to-string cmd)))
      (delete-file temp-file)
      output)))

(defun chat-tool-forge--exec-node (tool args)
  "执行 Node.js 工具"
  ;; 类似实现
  )

(defun chat-tool-forge--exec-go (tool args)
  "执行 Go 工具（需要编译）"
  (let* ((source (chat-forged-tool-source-code tool))
         (temp-dir (make-temp-file "chat-tool-" t))
         (source-file (expand-file-name "main.go" temp-dir))
         (binary-file (expand-file-name "main" temp-dir)))
    ;; 写入源码
    (with-temp-file source-file
      (insert source))
    ;; 编译
    (shell-command (format "go build -o %s %s" binary-file source-file))
    ;; 执行
    (let ((output (shell-command-to-string 
                   (format "%s %s" binary-file args))))
      ;; 清理
      (delete-directory temp-dir t)
      output)))

(defun chat-tool-forge--exec-elisp (tool args)
  "执行 Emacs Lisp 工具（原生）"
  (let ((func (chat-forged-tool-compiled-function tool)))
    (apply func args)))
```

#### 4.1.8 智能语言选择

```elisp
(defun chat-tool-forge-suggest-language (description)
  "根据需求建议最适合的编程语言"
  ;; 基于需求分析：
  ;; - 数据处理 → Python
  ;; - 系统操作 → Shell
  ;; - 文本处理 → Elisp 或 Perl
  ;; - 网络请求 → Python 或 Node
  ;; - 性能要求 → Go 或 Rust
  )

;; 示例
(chat-tool-forge-suggest-language "分析 CSV 文件并生成图表")
;; => 'python (推荐原因: pandas + matplotlib 生态)

(chat-tool-forge-suggest-language "批量重命名文件")
;; => 'elisp (推荐原因: 原生集成，无需外部依赖)
```

#### 4.1.9 多语言工具生成 Prompt

```elisp
(defvar chat-tool-forge-prompt-templates
  '((elisp . "你是一个 Emacs Lisp 专家。生成符合以下规范的代码:
              - 使用标准库函数
              - 添加 docstring
              - 处理边缘情况
              - 返回结果而非打印")
    (python . "你是一个 Python 专家。生成符合以下规范的代码:
               - 使用 argparse 处理参数
               - 添加类型注解
               - 包含错误处理
               - 输出 JSON 格式结果")
    (shell . "你是一个 Shell 脚本专家。生成符合以下规范的代码:
              - 使用 POSIX 兼容语法
              - 添加错误检查
              - 处理文件名中的空格")
    ;; 等等
    ))
```

---

### 4.2 依赖管理器 (chat-tool-deps.el) ⭐新增

```elisp
(defun chat-tool-deps-check-all ()
  "检查所有常用语言的安装状态"
  (interactive)
  (let ((results (mapcar (lambda (lang)
                           (cons lang (chat-tool-forge-detect-env lang)))
                         '(python node go ruby))))
    (chat-tool-deps-ui-show-status results)))

(defun chat-tool-deps-install-language (language)
  "引导用户安装指定语言的运行时"
  (let ((instructions (pcase language
                        ('python "请访问 https://python.org 下载 Python 3")
                        ('node "请访问 https://nodejs.org 下载 Node.js")
                        ('go "请访问 https://go.dev 下载 Go")
                        ;; 等等
                        )))
    (message "%s" instructions)))

(defun chat-tool-deps-setup-venv (tool-id)
  "为 Python 工具创建虚拟环境"
  ;; 创建 venv
  ;; 安装依赖
  ;; 配置工具使用该 venv
  )
```

**环境状态界面**:
```
┌─────────────────────────────────────────────────────────────┐
│ 🔧 环境状态检查                                               │
├─────────────────────────────────────────────────────────────┤
│ Emacs Lisp    ✓  原生支持                                    │
│ Python        ✓  3.11.2 @ /usr/bin/python3                   │
│ Node.js       ⚠  未安装 (推荐安装用于 JS/TS 工具)             │
│   [安装指南]                                                │
│ Go            ✓  1.21.0 @ /usr/local/go/bin/go               │
│ Rust          ✗  未安装                                      │
│   [安装指南]                                                │
│ Ruby          ✓  3.0.0 @ /usr/bin/ruby                       │
├─────────────────────────────────────────────────────────────┤
│ 提示: 你可以使用未安装的语言，但相关工具将无法运行             │
└─────────────────────────────────────────────────────────────┘
```

---

### 4.3 与其他层的集成

#### 4.3.1 与 Tools Registry 集成
```elisp
(defun chat-tool-forge-register (forged-tool)
  "将锻造的工具注册到 Tools Registry"
  ;; 转换为通用的 tool 结构
  ;; 设置执行函数为对应的 forge executor
  ;; 添加到 registry
  )
```

#### 4.3.2 与 Skill 系统集成
```elisp
;; Skill 可以声明偏好的语言
(chat-define-skill data-analysis
  :name "数据分析"
  :preferred-language 'python
  :fallback-language 'elisp
  :required-tools '(pandas matplotlib numpy))
```

#### 4.3.3 与记忆系统集成
```elisp
;; 记录用户偏好语言
(chat-memory-update 'preferred-tool-language 'python)

;; 记住哪些依赖已安装
(chat-memory-update 'installed-python-packages '(requests pandas numpy))
```

---

## 5. 使用场景示例

### 场景 1: 生成 Python 数据分析工具
```
User: 帮我写一个工具，能分析 Git 提交历史，
      生成提交频率的热力图

AI: 这个工具用 Python 配合 pandas 和 matplotlib 最合适。
    
    [环境检查...]
    ✓ Python 3.11 已安装
    ⚠ matplotlib 未安装 (将自动安装)
    
    [生成代码预览...]
    
    工具 'git-commit-heatmap' 已准备就绪。
    
    [查看代码] [测试] [安装依赖并保存]

User: [点击安装依赖并保存]

System: 正在安装 matplotlib, pandas, gitpython...
        安装完成！
        工具已保存到 ~/.chat/tools/python/git-commit-heatmap.py
```

### 场景 2: 处理环境缺失
```
User: 用 pdf-text-extractor 提取这份 PDF 的文本

AI: [环境检查]
    ✗ 无法执行：Python 依赖 'PyPDF2' 未安装
    
    建议安装命令:
    pip3 install PyPDF2
    
    [自动安装] [手动安装] [使用替代方案]

User: [自动安装]

System: 正在安装 PyPDF2...
        安装成功！
        
        [继续执行工具]
```

### 场景 3: 系统级依赖提醒
```
User: 帮我写一个用 Chrome 截图网页的工具

AI: [环境检查]
    ✓ Python 已安装
    ⚠ puppeteer 需要 Node.js，但 Node.js 未安装
    
    或者，我可以使用 Python 的 selenium 方案。
    但这需要安装 ChromeDriver。
    
    选项:
    1. [安装 Node.js] 使用 puppeteer 方案
    2. [安装 ChromeDriver] 使用 selenium 方案  
    3. [使用外部 API] 使用 screenshotapi.io

User: [安装 Node.js]

AI: 安装指南：
    # macOS
    brew install node
    
    # Ubuntu/Debian
    sudo apt install nodejs npm
    
    [我已安装，刷新检查]
```

---

## 6. 文件结构（更新）

```
chat.el/
├── chat.el
├── chat-scheduler.el
├── chat-session.el
├── chat-ui.el
├── chat-input.el
├── chat-message.el
├── chat-memory.el
├── chat-persona.el
├── chat-prompt.el
├── chat-executor.el
├── chat-llm.el
├── chat-llm-*.el
├── chat-tools.el
├── chat-tool-forge.el           ; ⭐ 工具锻造核心
├── chat-tool-forge-ui.el        ; ⭐ 锻造界面
├── chat-tool-forge-exec.el      ; ⭐ 多语言执行器
├── chat-tool-deps.el            ; ⭐ 依赖管理器
├── chat-skill.el
├── chat-skills/
│   ├── chat-skill-code.el
│   ├── chat-skill-doc.el
│   ├── chat-skill-shell.el
│   ├── chat-skill-emacs.el
│   └── chat-skill-tool-forge.el
├── chat-mcp.el
├── chat-executor-tools.el
├── chat-hub.el
├── chat-utils.el
├── chat-markdown.el
└── chat-completion.el
```

用户目录：
```
~/.chat/
├── config.el
├── SOUL.md
├── MEMORY.md
├── HEARTBEAT.md
├── sessions/
├── skills/
└── tools/                       ; ⭐ 多语言工具目录
    ├── .tool-index.el          ; 工具索引
    ├── elisp/
    ├── python/
    │   ├── requirements.txt    ; 全局 Python 依赖
    │   └── venv/               ; Python 虚拟环境
    ├── node/
    │   └── package.json
    ├── shell/
    ├── go/
    └── ruby/
```

---

## 7. 实现路线图（更新）

### Phase 1: 核心骨架 (MVP)
- [ ] 基础会话管理
- [ ] 简单 UI
- [ ] OpenAI API 支持
- [ ] 基础消息发送/接收
- [ ] Tools 基础框架 + 审批系统

### Phase 2: 功能完善
- [ ] 多提供商支持
- [ ] 流式输出
- [ ] 多会话管理
- [ ] 会话持久化
- [ ] Skills 系统
- [ ] MCP 支持

### Phase 3: Agent Runtime 核心
- [ ] 心跳调度器
- [ ] 记忆系统
- [ ] 人格引擎
- [ ] Self-Healing

### Phase 4: 自我演进系统
- [ ] 工具锻造核心
- [ ] 工具生成工作流
- [ ] 临时代码转正
- [ ] 工具版本管理
- [ ] ⭐ **多语言工具支持** (Elisp/Python/Shell/Node)
- [ ] ⭐ **环境检测与依赖提醒**
- [ ] ⭐ **自动/引导安装**
- [ ] Clawback 验证
- [ ] Skill 市场

---

## 8. 对比（更新）

| 特性 | chat.el | openclaw | copilot-chat | gptel |
|------|---------|----------|--------------|-------|
| 纯 Emacs | ✅ | ❌ | ✅ | ✅ |
| 多提供商 | ✅ | ✅ | ❌ | ✅ |
| 流式输出 | ✅ | ✅ | ❌ | ✅ |
| 多会话管理 | ✅ | ❌ | ❌ | ❌ |
| 上下文策略 | ✅ | ❌ | ❌ | ❌ |
| 分支对话 | ✅ | ❌ | ❌ | ❌ |
| 历史追问 | ✅ | ❌ | ❌ | ❌ |
| 心跳调度 | ✅ | ✅ | ❌ | ❌ |
| 长期记忆 | ✅ | ✅ | ❌ | ❌ |
| 人格定义 | ✅ | ✅ | ❌ | ❌ |
| MCP 支持 | ✅ | ✅ | ❌ | ❌ |
| Tools/Skills 分离 | ✅ | ✅ | ❌ | ❌ |
| Self-Healing | ✅ | ✅ | ❌ | ❌ |
| 自定义工具持久化 | ✅ | ❌ | ❌ | ❌ |
| ⭐ **多语言工具** | ✅ | ⚠️ 有限 | ❌ | ❌ |
| ⭐ **智能依赖管理** | ✅ | ❌ | ❌ | ❌ |

---

*设计版本: 4.0*
*最后更新: 2026-03-24*
