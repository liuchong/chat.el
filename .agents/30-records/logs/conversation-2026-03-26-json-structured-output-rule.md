# Imported Log

- Type: logs
- Attention: records
- Status: imported
- Scope: legacy-session
- Tags: imported, legacy, ai-context

## Original Record

# JSON Structured Output Rule
## Requirements
用户要求在 `AGENTS.md` 中加入强制规则。
规则需要明确结构化输入输出必须使用 JSON。
规则需要明确 function call 和类似工具调用不得再使用 XML 一类格式。
## Technical Decisions
直接在 `AGENTS.md` 的 `Tooling Safety` 附近新增 `Structured Protocol Format` 小节。
不新建额外规则文件。
规则写成仓库级强制约束。
## Completed Work
更新了 `AGENTS.md`。
新增了 `Structured Protocol Format` 小节。
明确要求结构化输入输出和 function call 一律使用 JSON。
明确禁止使用 XML YAML 自定义标签或自然语言伪结构替代 JSON。
## Pending Work
无额外代码改动。
后续会话中按新规则执行即可。
## Key Code Paths
`AGENTS.md`
## Verification
已检查 `AGENTS.md` 内容。
本次仅修改规则文档 未运行测试。
## Issues Encountered
本次没有新增 `docs/troubleshooting-pitfalls.md` 条目。
