# Documentation Refresh

## Requirements

全面更新项目文档
优化根 README
补齐 docs 目录导航
补齐 ai-context 说明文档
优化 `AGENTS.md` 的结构和可读性

## Technical Decisions

用根 README 负责项目入口和快速上手
新增 `docs/README.md` 作为文档导航页
新增 `docs/ai-contexts/README.md` 作为会话记录规范
重写 `docs/PROJECT_STATUS.md` 反映当前真实基线
重写 `AGENTS.md` 为更短更清晰的执行规范

## Completed Work

重写了 `README.md`
新增了 `docs/README.md`
新增了 `docs/ai-contexts/README.md`
重写了 `docs/PROJECT_STATUS.md`
重写了 `AGENTS.md`
重排了 `docs/troubleshooting-pitfalls.md`
新增了 `.cursor/rules/documentation-maintenance.mdc`
为 `AGENTS.md` 增加了禁止向 git 内容泄露敏感信息的规则
统一了文档中的测试入口和当前能力描述
补上了许可证说明
为 troubleshooting 文档定义了固定字段顺序和主题归档规则

## Pending Work

本轮没有新增待办

## Key Code Paths

`README.md`
`docs/README.md`
`docs/PROJECT_STATUS.md`
`docs/troubleshooting-pitfalls.md`
`docs/ai-contexts/README.md`
`AGENTS.md`
`.cursor/rules/documentation-maintenance.mdc`

## Verification

检查了文档引用关系和目录结构
确认 `docs/ai-contexts/README.md` 已存在并与 `AGENTS.md` 引用一致
确认 `.cursor/rules/documentation-maintenance.mdc` 已创建
本次没有涉及代码逻辑改动 所以没有跑单元测试

## Issues Encountered

本次无新增产品级避坑条目
本次新增的是文档结构维护规则
