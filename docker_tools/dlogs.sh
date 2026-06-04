#!/bin/bash

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# 引用docker_utils脚本
source "${SCRIPT_DIR}/docker_utils.sh"

# 选择容器；支持命令行参数传入编号或容器名。
container=$(container_arg_or_select "$1" "请选择要查看日志的容器：") || exit 1

# 执行docker命令查看日志
docker logs -f -n10 "${container}"
