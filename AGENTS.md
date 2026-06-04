# AGENTS.md

本文件适用于仓库根目录及所有子目录。后续由 Codex 或其他 coding agent 修改本项目时，优先遵守这里的约定。

## 项目背景

- 这是一个 Linux 服务器配置优化脚本集合，主入口是 `server-setup.sh`。
- 用户常用方式是远程执行：`/bin/bash <(wget -qO - bit.ly/ls-set)`。
- 脚本会修改系统配置，很多操作需要 root 权限，改动必须保守、可验证、尽量可回滚。

## 开发原则

- 保持 Bash 脚本简单直接，不引入不必要的框架或复杂抽象。
- 优先沿用现有函数、菜单风格、中文提示和文件组织方式。
- 不要把交互式脚本改成需要额外参数才能使用的形式；已有交互体验要保留。
- 修改系统配置前应尽量备份原文件，并在失败时恢复关键配置。
- 不使用 `eval` 拼命令；需要动态命令时用数组或明确的分支函数。
- 变量展开要加引号，路径、容器名、服务名都不要假设没有空格或特殊字符。
- 不要使用破坏性 git 命令，不要回滚用户未要求回滚的改动。

## Docker Tools 约定

- Docker 工具源文件在 `docker_tools/`，安装后通常位于 `/root/.docker_tools/`。
- `dlogs` 和 `dexec` 必须同时支持容器编号和容器名。
- `dlogs` / `dexec` 的补全候选应显示为 `1. container-name` 格式。
- 补全列表顺序应保持 `docker ps --format '{{.Names}}'` 的输出顺序，不要被 Bash 自动排序打乱。
- 容器名补全应支持按容器名前缀匹配，例如 `dlogs nginx<Tab>`。
- Docker Compose 检测保留当前快速方式：`command -v docker compose`。不要替换为较慢的 `docker compose version`，除非用户明确要求。

## Shell 脚本要求

- 目标 shell 是 Bash，脚本头保持 `#!/bin/bash`。
- 新增数组、`mapfile`、进程替换等 Bash 特性时，确认所有目标发行版可接受。
- 避免 `local var=$(cmd)`，优先拆成声明和赋值，避免掩盖命令失败。
- 对用户输入做范围校验，特别是端口、编号、带宽、延迟等数值。
- 服务名不要写死为单一值；例如 SSH 服务要兼容 `ssh` 和 `sshd`。
- 修改 SSH、DNS、防火墙、sysctl、swap 等配置时，要考虑远程服务器断连风险。

## 验证命令

改动脚本后至少运行：

```bash
find . -name '*.sh' -print0 | xargs -0 bash -n
find . -name '*.sh' -print0 | xargs -0 shellcheck -S warning
git diff --check
```

修改 Docker tools 补全或容器选择逻辑时，还应做 mock 测试，确认：

- `dlogs <Tab><Tab>` 显示 `1. container-name` 格式。
- `dlogs 1` 映射到补全列表中的第一个容器。
- `dlogs '1. container-name'` 也能映射到同一个容器。
- 按容器名前缀补全仍可用。

## 文档约定

- README 面向最终用户，保持中文、直接、可执行。
- 代码注释只在有助于理解复杂逻辑时添加，不写空泛注释。
- 修复 Bug 时优先说明行为变化和验证结果，不需要写长篇背景。
