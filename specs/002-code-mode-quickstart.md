# Code Mode Quickstart Guide

## 快速开始

### 启动 Code Mode

```elisp
;; 方法 1: 从当前项目启动
M-x chat-code-start

;; 方法 2: 针对特定文件
M-x chat-code-for-file

;; 方法 3: 使用当前选中的代码
M-x chat-code-for-selection

;; 方法 4: 从普通聊天切换
M-x chat-code-from-chat
```

### 基本工作流

```
1. 打开你的项目中的一个文件
2. M-x chat-code-start
3. 输入你的需求，例如：
   "帮我把这个函数改成异步的"
   "给这个类添加错误处理"
   "写单元测试覆盖这个函数"
4. 查看 AI 的响应，接受或拒绝修改建议
```

## 命令参考

**窗口管理原则：** 所有命令都在当前窗口操作，不强制分割窗口。预览在独立 buffer 中，按需手动切换。

### 全局命令

| 命令 | 快捷键 | 描述 |
|------|--------|------|
| `chat-code-start` | `C-c c c` | 启动 code mode 会话 |
| `chat-code-for-file` | `C-c c f` | 为当前文件启动 |
| `chat-code-for-selection` | `C-c c s` | 使用选区启动 |
| `chat-code-index-project` | `C-c c i` | 索引项目代码 |

### 代码编辑命令

| 命令 | 快捷键 | 描述 |
|------|--------|------|
| `chat-edit-generate` | `C-c e g` | 生成代码 |
| `chat-edit-complete` | `C-c e c` | 代码补全 |
| `chat-edit-explain` | `C-c e e` | 解释代码 |
| `chat-edit-refactor` | `C-c e r` | 重构代码 |
| `chat-edit-fix` | `C-c e f` | 修复问题 |
| `chat-edit-docs` | `C-c e d` | 生成文档 |
| `chat-edit-tests` | `C-c e t` | 生成测试 |

### 修改处理命令

| 快捷键 | 功能 | 说明 |
|--------|------|------|
| `C-c C-a` | 接受修改 | 直接应用，不看预览 |
| `C-c C-k` | 拒绝修改 | 丢弃 AI 建议 |
| `C-c C-v` | 查看预览 | 切换到 `*chat-preview*` buffer |
| `C-c C-d` | 显示 diff | 在 chat buffer 中显示 diff |

### 预览 buffer 命令 (`*chat-preview*` 中)

| 快捷键 | 功能 |
|--------|------|
| `a` | 接受修改 |
| `r` | 拒绝修改 |
| `q` | 关闭 preview，返回原 buffer |
| `n` | 下一个修改 |
| `p` | 上一个修改 |

**切换 buffer 方法：**
- `C-x b` - 按名称切换 buffer
- `C-x C-b` - 列出所有 buffer
- `C-x <left>` / `C-x <right>` - 切换到前一个/后一个 buffer

## 使用场景示例

### 场景 1: 添加新功能

```python
# 当前代码：src/api.py
def get_user(user_id):
    """Get user by ID."""
    return db.query(User).get(user_id)
```

**操作:**
1. 在 `get_user` 函数上执行 `chat-code-for-selection`
2. 输入："添加缓存支持，使用 Redis"

**预期结果:**
```python
def get_user(user_id):
    """Get user by ID with caching."""
    cache_key = f"user:{user_id}"
    cached = redis.get(cache_key)
    if cached:
        return json.loads(cached)
    
    user = db.query(User).get(user_id)
    if user:
        redis.setex(cache_key, 3600, json.dumps(user.to_dict()))
    return user
```

### 场景 2: 重构代码

```python
# 当前代码：有很多重复代码
def process_order_a(order):
    validate_order(order)
    calculate_tax(order)
    save_order(order)

def process_order_b(order):
    validate_order(order)
    calculate_tax(order)
    save_order(order)
```

**操作:**
1. 选中两个函数
2. 执行 `chat-edit-refactor`
3. 输入："提取公共逻辑，消除重复代码"

**预期结果:**
```python
def _process_order_core(order):
    """Core order processing logic."""
    validate_order(order)
    calculate_tax(order)
    save_order(order)

def process_order_a(order):
    _process_order_core(order)

def process_order_b(order):
    _process_order_core(order)
```

### 场景 3: 理解复杂代码

```elisp
;; 复杂的递归函数
(defun my/complex-recursion (x acc)
  (if (null x)
      acc
      (my/complex-recursion (cdr x) 
                            (cons (transform (car x)) acc))))
```

**操作:**
1. 在函数上执行 `chat-edit-explain`

**预期结果:**
```
这是一个递归函数，它的作用是：

1. 基本情况：当 x 为空列表时，返回累加器 acc
2. 递归情况：
   - 取列表 x 的第一个元素 (car x) 进行 transform
   - 将结果添加到累加器 acc 的前面
   - 对列表的剩余部分 (cdr x) 递归调用

本质上，这是一个 map 操作的递归实现，同时会反转列表顺序。
等价于: (reverse (mapcar 'transform x))
```

### 场景 4: 修复 Bug

```python
# 用户报告：当用户不存在时程序崩溃
def get_user_email(user_id):
    user = db.get_user(user_id)
    return user.email  # <-- 这里可能出错
```

**操作:**
1. 在问题行上执行 `chat-edit-fix`

**预期结果:**
```python
def get_user_email(user_id):
    user = db.get_user(user_id)
    if user is None:
        raise UserNotFoundError(f"User {user_id} not found")
    return user.email
```

### 场景 5: 生成测试

```python
def divide(a, b):
    """Divide two numbers."""
    return a / b
```

**操作:**
1. 在函数上执行 `chat-edit-tests`

**预期结果:**
```python
import pytest

def test_divide_normal():
    assert divide(10, 2) == 5
    assert divide(7, 2) == 3.5

def test_divide_negative():
    assert divide(-10, 2) == -5
    assert divide(10, -2) == -5

def test_divide_by_zero():
    with pytest.raises(ZeroDivisionError):
        divide(10, 0)
```

## 配置示例

### 基本配置

```elisp
;; 启用 code mode
(setq chat-code-enabled t)

;; 默认使用 balanced 策略
(setq chat-code-default-strategy 'balanced)

;; 小修改自动应用（少于 10 行）
(setq chat-code-auto-apply-threshold 10)

;; 最大 token 数
(setq chat-code-max-tokens 16000)
```

### 高级配置

```elisp
;; 自定义上下文源
(setq chat-code-context-sources
      '(file-content
        file-symbols
        imports
        git-status
        open-buffers))

;; 自定义系统提示词
(setq chat-code-system-prompt
      "You are a senior software engineer. 
       Write clean, well-tested code following SOLID principles.")

;; 文件类型映射
(add-to-list 'chat-code-filetype-map '("\.vue$" . vue))
```

### 快捷键配置

```elisp
;; 全局快捷键
(global-set-key (kbd "C-c c c") 'chat-code-start)
(global-set-key (kbd "C-c c f") 'chat-code-for-file)

;; 编程 mode 专用快捷键
(add-hook 'prog-mode-hook
          (lambda ()
            (local-set-key (kbd "C-c e e") 'chat-edit-explain)
            (local-set-key (kbd "C-c e r") 'chat-edit-refactor)
            (local-set-key (kbd "C-c e f") 'chat-edit-fix)
            (local-set-key (kbd "C-c e t") 'chat-edit-tests)))
```

## 提示词技巧

### 有效的提示词模式

| 场景 | 提示词示例 |
|------|-----------|
| 添加功能 | "添加用户认证功能，包括登录、登出和注册" |
| 重构 | "将这个类拆成两个：一个负责数据，一个负责逻辑" |
| 优化 | "优化这个函数的性能，时间复杂度太高" |
| 文档 | "给这个模块添加详细的 docstring" |
| 测试 | "为这个函数写单元测试，覆盖边界情况" |
| 类型 | "给这个 Python 函数添加类型注解" |
| 错误处理 | "给这个函数添加适当的错误处理" |
| 国际化 | "让这个模块支持多语言" |

### 上下文感知的提示

```
"帮我把这个函数改成异步的"
"参考 config.py 中的配置格式，给这个模块添加配置支持"
"按照项目中的错误处理风格，给这个函数添加错误处理"
"看看 test_user.py 的测试风格，给这个新函数写测试"
```

## 故障排除

### 问题：上下文不够

**症状:** AI 不知道项目的其他部分

**解决:**
- 切换到 `comprehensive` 策略
- 手动添加相关文件到上下文
- 先索引整个项目: `chat-code-index-project`

### 问题：修改不准确

**症状:** AI 修改了错误的位置

**解决:**
- 使用更精确的选区
- 在提示词中明确说明目标位置
- 使用行号引用

### 问题：生成的代码风格不一致

**症状:** 生成的代码和项目风格不符

**解决:**
- 在系统提示词中指定代码风格
- 提供风格参考文件
- 使用项目特定的提示词模板

### 问题：Token 限制

**症状:** 上下文被截断

**解决:**
- 使用更聚焦的策略
- 手动选择关键文件
- 增加 `chat-code-max-tokens`

## 窗口管理指南

**核心原则：** code mode 不管理窗口，只管理 buffer。用户完全控制窗口布局。

### 典型工作流程

```
1. 你在编辑 src/main.py
   ┌──────────────────────┐
   │ src/main.py          │
   │                      │
   │  def connect():      │
   │      pass            │
   └──────────────────────┘

2. 执行 chat-code-for-selection
   → 在当前窗口打开 *chat:code:project* buffer
   ┌──────────────────────┐
   │ *chat:code:project*  │
   │                      │
   │  You: 添加错误处理   │
   │  > _                 │
   └──────────────────────┘

3. AI 生成修改后
   → 创建 *chat-preview* buffer（不自动显示）
   → 在 chat buffer 显示: "[Apply: C-c C-a] [Preview: C-c C-v]"

4. 三种处理方式:

   A) 直接接受 (不切换窗口)
      按 C-c C-a，修改应用到 src/main.py
      用 C-x b 切换回 src/main.py 查看

   B) 先看预览 (手动切换 buffer)
      按 C-x b 输入 *chat-preview*
      或按 C-c C-v（自动切换到 preview buffer）
      ┌──────────────────────┐
      │ *chat-preview*       │
      │  @@ -1,3 +1,8 @@     │
      └──────────────────────┘

   C) 自定义窗口布局 (手动分割)
      C-x 3 分割窗口
      C-x o 切换到另一个窗口
      C-x b 选择 *chat-preview*
      ┌──────────┬──────────┐
      │src/main.p│*chat-prev│
      └──────────┴──────────┘
```

### Buffer 命名规则

| Buffer 名称 | 用途 |
|------------|------|
| `*chat:code:project*` | Code mode 主 buffer |
| `*chat-preview*` | 修改预览 diff |
| `*chat-context*` | 当前上下文详情 |

### 常用窗口命令

```elisp
;; 切换 buffer
C-x b    ;; 按名称切换
C-x C-b  ;; 列出所有 buffer
C-x <left>   ;; 上一个 buffer
C-x <right>  ;; 下一个 buffer

;; 窗口管理 (可选，code mode 不强制使用)
C-x 2    ;; 水平分割
C-x 3    ;; 垂直分割
C-x 0    ;; 关闭当前窗口
C-x 1    ;; 只保留当前窗口
C-x o    ;; 切换窗口
```

## 最佳实践

1. **从小处开始**: 先让 AI 处理小任务，逐步建立信任
2. **验证修改**: 始终检查 AI 的修改，尤其是关键代码
3. **使用版本控制**: 在干净的 git 状态下使用 code mode
4. **提供上下文**: 给 AI 足够的背景信息
5. **迭代改进**: 一次只做一件事，逐步完善
6. **控制布局**: 自己管理窗口，不依赖自动布局

---

*Quickstart Version: 0.2*
*For: chat.el Code Mode*
*Change: Single window design principle*
