#!/bin/bash

# ==============================================================================
# 脚本名称: fail2ban.sh
# 脚本功能: 完整的 Fail2ban 管理工具 - 配置、查看、封禁、解封
# 适用系统: 主要适配 Debian 12，兼容 Ubuntu, CentOS, Fedora
# 版本: 2.0 (完整管理版本)
# ==============================================================================

# 检查操作系统类型
get_os_info() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        case $ID in
            debian|ubuntu)
                echo "Debian/Ubuntu"
                ;;
            centos)
                echo "CentOS"
                ;;
            fedora)
                echo "Fedora"
                ;;
            arch)
                echo "Arch"
                ;;
            *)
                echo "Unknown"
                ;;
        esac
    elif [ -f /etc/centos-release ]; then
        echo "CentOS"
    elif [ -f /etc/fedora-release ]; then
        echo "Fedora"
    elif [ -f /etc/arch-release ]; then
        echo "Arch"
    else
        echo "Unknown"
    fi
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "错误：此脚本需要管理员权限，请使用 'sudo' 或以 'root' 用户身份运行。"
        exit 1
    fi
}

# 检查 Fail2ban 是否安装和运行
check_fail2ban_available() {
    if ! command -v fail2ban-client &>/dev/null; then
        echo "❌ 错误：Fail2ban 未安装。请先运行配置功能安装 Fail2ban。"
        return 1
    fi
    
    if ! systemctl is-active --quiet fail2ban; then
        echo "❌ 错误：Fail2ban 服务未运行。"
        read -p "🤔 是否要启动 Fail2ban 服务？(y/n): " start_service
        if [[ "${start_service,,}" == "y" ]]; then
            systemctl start fail2ban
            sleep 2
            if systemctl is-active --quiet fail2ban; then
                echo "✅ Fail2ban 服务已启动。"
                return 0
            else
                echo "❌ 启动失败。"
                return 1
            fi
        else
            return 1
        fi
    fi
    
    return 0
}

# 检测并修复日志配置
setup_logging() {
    local os_type
    os_type=$(get_os_info)
    
    echo "🔍 正在检查系统日志配置..."
    
    case $os_type in
        "Debian/Ubuntu")
            # 检查 rsyslog 是否安装和运行
            if ! command -v rsyslogd &>/dev/null; then
                echo "📦 正在安装 rsyslog..."
                apt update -y
                apt install -y rsyslog
            fi
            
            # 启动并启用 rsyslog
            systemctl enable rsyslog
            systemctl start rsyslog
            
            # 确保 auth.log 存在
            if [ ! -f /var/log/auth.log ]; then
                echo "📝 创建 auth.log 文件..."
                touch /var/log/auth.log
                chmod 640 /var/log/auth.log
                chown syslog:adm /var/log/auth.log
            fi
            
            # 重启 rsyslog 以确保日志记录正常
            systemctl restart rsyslog
            echo "✅ 系统日志配置完成"
            ;;
        "CentOS"|"Fedora")
            # 对于 CentOS/Fedora，通常使用 rsyslog 和 /var/log/secure
            if ! systemctl is-active --quiet rsyslog; then
                systemctl enable rsyslog
                systemctl start rsyslog
            fi
            ;;
    esac
}

# 检测 SSH 日志文件路径
detect_ssh_log_path() {
    local os_type
    local possible_logs=()
    os_type=$(get_os_info)
    
    case $os_type in
        "Debian/Ubuntu")
            possible_logs=("/var/log/auth.log" "/var/log/syslog")
            ;;
        "CentOS"|"Fedora")
            possible_logs=("/var/log/secure" "/var/log/messages")
            ;;
        *)
            possible_logs=("/var/log/auth.log" "/var/log/secure" "/var/log/messages")
            ;;
    esac
    
    for log_file in "${possible_logs[@]}"; do
        if [ -f "$log_file" ]; then
            echo "$log_file"
            return 0
        fi
    done
    
    # 如果没有找到传统日志文件，返回空字符串（将使用 systemd backend）
    echo ""
}

# 安装 Fail2ban
install_fail2ban() {
    local os_type
    os_type=$(get_os_info)
    
    echo "正在检查 Fail2ban 是否已安装..."
    
    if command -v fail2ban-server &>/dev/null; then
        echo "✅ Fail2ban 已安装。"
        return 0
    fi
    
    echo "📦 Fail2ban 未安装，正在安装..."
    
    case $os_type in
        "Debian/Ubuntu")
            apt update -y
            apt install -y fail2ban
            ;;
        "CentOS")
            # CentOS 7/8 需要 EPEL 源
            if ! rpm -qa | grep -q epel-release; then
                yum install -y epel-release
            fi
            yum install -y fail2ban
            ;;
        "Fedora")
            dnf install -y fail2ban
            ;;
        "Arch")
            pacman -Sy --noconfirm fail2ban
            ;;
        *)
            echo "❌ 错误：不支持的操作系统类型。"
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        echo "✅ Fail2ban 安装成功。"
        return 0
    else
        echo "❌ 错误：Fail2ban 安装失败。"
        return 1
    fi
}

dump_effective_ssh_config() {
    if command -v sshd &>/dev/null; then
        sshd -T
    elif [ -x /usr/sbin/sshd ]; then
        /usr/sbin/sshd -T
    else
        return 1
    fi
}

read_ssh_port_from_file() {
    local config_file=$1
    awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$config_file"
}

# 自动检测 SSH 生效端口
get_ssh_port() {
    local ssh_port
    local config_file

    ssh_port=$(dump_effective_ssh_config 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ { print $2; exit }')
    if [ -n "$ssh_port" ]; then
        echo "$ssh_port"
        return 0
    fi

    for config_file in /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config; do
        if [ ! -f "$config_file" ]; then
            continue
        fi
        ssh_port=$(read_ssh_port_from_file "$config_file")
        if [ -n "$ssh_port" ]; then
            echo "$ssh_port"
            return 0
        fi
    done

    echo "22"
}

# 检查 Fail2ban 状态
check_fail2ban_status() {
    echo "🔍 正在检查当前 Fail2ban 状态..."
    echo "=================================================="
    
    if systemctl is-active --quiet fail2ban; then
        echo "📊 Fail2ban 服务状态: ✅ 运行中"
        
        # 显示当前的 jail 状态
        if command -v fail2ban-client &>/dev/null; then
            echo ""
            echo "📋 当前活跃的保护规则 (jails):"
            fail2ban-client status 2>/dev/null || echo "   无法获取详细状态"
            
            # 检查是否有 SSH 相关的 jail
            if fail2ban-client status | grep -q "sshd\|ssh"; then
                echo ""
                echo "🛡️  SSH 保护状态:"
                fail2ban-client status sshd 2>/dev/null || fail2ban-client status ssh 2>/dev/null || echo "   SSH jail 未找到"
            fi
        fi
    else
        echo "📊 Fail2ban 服务状态: ❌ 未运行"
    fi
    
    echo "=================================================="
}

# 生成 Fail2ban 配置文件
generate_fail2ban_config() {
    local ssh_port=$1
    local max_retry=$2
    local ban_time_hours=$3
    
    local ban_time_seconds=$((ban_time_hours * 3600))
    local jail_local="/etc/fail2ban/jail.d/sshd-linux-setup.local"
    local custom_comment="# SSH protection configured by fail2ban.sh script"
    local log_path
    log_path=$(detect_ssh_log_path)
    
    echo "🔧 正在生成 Fail2ban 配置..."
    
    mkdir -p /etc/fail2ban/jail.d

    # 只备份脚本管理的配置（如果存在），避免覆盖用户自己的 jail.local。
    if [ -f "$jail_local" ]; then
        local backup_file
        backup_file="${jail_local}.bak.$(date +%Y%m%d_%H%M%S)"
        echo "📦 备份现有配置到: $backup_file"
        cp "$jail_local" "$backup_file"
    fi
    
    # 检测是否应该使用 systemd backend
    local use_systemd=false
    if [ -z "$log_path" ] && command -v journalctl &>/dev/null; then
        echo "🔍 未找到传统日志文件，将使用 systemd journal"
        use_systemd=true
    fi
    
    # 生成新的配置文件
    cat > "$jail_local" << EOF
$custom_comment
# Generated on: $(date)
# SSH Port: $ssh_port
# Max Retry: $max_retry
# Ban Time: $ban_time_hours hours ($ban_time_seconds seconds)
# Log detection: $(if [ "$use_systemd" = true ]; then echo "systemd journal"; else echo "$log_path"; fi)

[DEFAULT]
# 忽略的IP地址（本地地址）
ignoreip = 127.0.0.1/8 ::1

# 默认封禁时间（秒）
bantime = $ban_time_seconds

# 查找时间窗口（秒）- 10分钟内
findtime = 600

# 最大重试次数
maxretry = $max_retry

# 后端日志监控方式
EOF

    if [ "$use_systemd" = true ]; then
        cat >> "$jail_local" << EOF
backend = systemd

[sshd]
# SSH 服务保护 (使用 systemd journal)
enabled = true
port = $ssh_port
filter = sshd
backend = systemd
maxretry = $max_retry
bantime = $ban_time_seconds
findtime = 600
EOF
    else
        cat >> "$jail_local" << EOF
backend = auto

[sshd]
# SSH 服务保护
enabled = true
port = $ssh_port
filter = sshd
logpath = $log_path
maxretry = $max_retry
bantime = $ban_time_seconds
findtime = 600
EOF
    fi
    
    echo "✅ 配置文件已生成: $jail_local"
    echo "🔍 使用的日志监控方式: $(if [ "$use_systemd" = true ]; then echo "systemd journal"; else echo "传统日志文件 ($log_path)"; fi)"
}

# 启动并启用 Fail2ban 服务
start_fail2ban_service() {
    echo "🚀 正在启动 Fail2ban 服务..."
    
    # 重新加载配置并重启服务
    systemctl daemon-reload
    
    # 启用开机自启
    systemctl enable fail2ban
    
    # 重启服务
    systemctl restart fail2ban
    
    # 等待服务完全启动
    sleep 5
    
    # 检查服务状态
    if systemctl is-active --quiet fail2ban; then
        echo "✅ Fail2ban 服务启动成功！"
        return 0
    else
        echo "❌ 错误：Fail2ban 服务启动失败。"
        echo "🔍 查看服务状态:"
        systemctl status fail2ban --no-pager -l
        echo ""
        echo "🔍 查看详细日志:"
        journalctl -u fail2ban --no-pager -l -n 20
        return 1
    fi
}

# 验证配置是否生效
verify_configuration() {
    local ssh_port=$1
    
    echo ""
    echo "🔍 正在验证配置是否生效..."
    echo "=================================================="
    
    # 检查服务状态
    if systemctl is-active --quiet fail2ban; then
        echo "✅ Fail2ban 服务运行正常"
        
        # 等待一下让 jail 完全加载
        sleep 3
        
        # 显示 SSH jail 状态
        if fail2ban-client status sshd &>/dev/null; then
            echo "✅ SSH 保护规则 (sshd jail) 已激活"
            echo ""
            echo "📊 SSH 保护详细状态:"
            fail2ban-client status sshd
        else
            echo "⚠️  警告：SSH 保护规则可能未正确加载"
            echo "🔍 尝试查看所有可用的 jail:"
            fail2ban-client status
        fi
        
        echo ""
        echo "📋 所有活跃的保护规则:"
        fail2ban-client status
        
    else
        echo "❌ Fail2ban 服务未运行"
        return 1
    fi
    
    echo "=================================================="
    echo "🎉 配置验证完成！"
    echo ""
    echo "📝 重要提醒:"
    echo "   • SSH 端口 $ssh_port 现在受到 Fail2ban 保护"
    echo "   • 请确保您的 IP 地址不会被误封"
    echo "   • 可以使用 'fail2ban-client status sshd' 查看状态"
    echo "   • 可以使用 'fail2ban-client unban IP地址' 解封特定IP"
    echo "   • 配置文件位置: /etc/fail2ban/jail.d/sshd-linux-setup.local"
    echo "   • 查看日志: journalctl -u fail2ban -f"
}

# 配置 Fail2ban 保护
configure_fail2ban() {
    echo "========================================"
    echo "  🛡️  配置 Fail2ban SSH 保护"
    echo "========================================"
    
    # 检查权限
    check_root
    
    # 自动检测 SSH 端口
    local ssh_port
    ssh_port=$(get_ssh_port)
    echo "🔍 检测到当前 SSH 端口: $ssh_port"
    
    # 显示当前状态
    check_fail2ban_status
    
    # 询问是否启用保护
    echo ""
    read -p "🤔 是否要启用 Fail2ban 保护 SSH 服务？(y/n): " enable_protection
    
    case "${enable_protection,,}" in
        y|yes)
            echo "✅ 确认启用 SSH 保护"
            ;;
        *)
            echo "❌ 操作已取消。"
            return 0
            ;;
    esac
    
    # 安装 Fail2ban（如果未安装）
    if ! install_fail2ban; then
        echo "❌ 无法继续：Fail2ban 安装失败。"
        return 1
    fi
    
    # 设置系统日志（重要！）
    setup_logging
    
    # 获取用户配置参数
    echo ""
    echo "📝 请配置保护参数："
    echo ""
    
    # 最大重试次数
    local max_retry
    read -p "🔢 允许的最大失败尝试次数 [默认: 5]: " max_retry
    max_retry=${max_retry:-5}
    
    # 验证输入
    if ! [[ "$max_retry" =~ ^[0-9]+$ ]] || [ "$max_retry" -lt 1 ] || [ "$max_retry" -gt 20 ]; then
        echo "⚠️  无效输入，使用默认值: 5"
        max_retry=5
    fi
    
    # 封禁时长（小时）
    local ban_time_hours
    read -p "⏱️  封禁时长（小时）[默认: 1]: " ban_time_hours
    ban_time_hours=${ban_time_hours:-1}
    
    # 验证输入
    if ! [[ "$ban_time_hours" =~ ^[0-9]+$ ]] || [ "$ban_time_hours" -lt 1 ] || [ "$ban_time_hours" -gt 168 ]; then
        echo "⚠️  无效输入，使用默认值: 1 小时"
        ban_time_hours=1
    fi
    
    # 确认配置
    echo ""
    echo "📋 配置确认："
    echo "   SSH 端口: $ssh_port"
    echo "   最大重试: $max_retry 次"
    echo "   封禁时长: $ban_time_hours 小时"
    echo ""
    read -p "🤔 确认应用以上配置？(y/n): " confirm_config
    
    case "${confirm_config,,}" in
        y|yes)
            echo "✅ 开始应用配置..."
            ;;
        *)
            echo "❌ 配置已取消。"
            return 0
            ;;
    esac
    
    # 生成配置文件
    if ! generate_fail2ban_config "$ssh_port" "$max_retry" "$ban_time_hours"; then
        echo "❌ 配置文件生成失败。"
        return 1
    fi
    
    # 启动服务
    if ! start_fail2ban_service; then
        echo "❌ 服务启动失败。请检查上述错误信息。"
        return 1
    fi
    
    # 验证配置
    verify_configuration "$ssh_port"
    
    echo ""
    echo "🎉 Fail2ban SSH 保护配置完成！"
}

# 查看当前封禁的 IP
view_banned_ips() {
    echo "========================================"
    echo "  🔍 查看当前封禁的 IP 地址"
    echo "========================================"
    
    if ! check_fail2ban_available; then
        return 1
    fi
    
    # 获取所有活跃的 jail
    local jails
    jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    
    if [ -z "$jails" ]; then
        echo "📋 当前没有活跃的保护规则 (jails)。"
        return 0
    fi
    
    local total_banned=0
    
    echo "📋 所有活跃的保护规则及其封禁状态："
    echo "=================================================="
    
    for jail in $jails; do
        echo ""
        echo "🛡️  Jail: $jail"
        echo "----------------------------------------"
        
        # 获取封禁的 IP 列表
        local banned_ips
        banned_ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | cut -d: -f2 | xargs)
        
        if [ -n "$banned_ips" ]; then
            local count
            count=$(echo "$banned_ips" | wc -w)
            total_banned=$((total_banned + count))
            
            echo "❌ 封禁的 IP ($count 个):"
            for ip in $banned_ips; do
                echo "   • $ip"
            done
        else
            echo "✅ 当前没有封禁的 IP"
        fi
        
        # 显示详细统计
        local stats
        stats=$(fail2ban-client status "$jail" 2>/dev/null)
        if [ $? -eq 0 ]; then
            local currently_failed
            currently_failed=$(echo "$stats" | grep "Currently failed:" | cut -d: -f2 | xargs)
            local total_failed
            total_failed=$(echo "$stats" | grep "Total failed:" | cut -d: -f2 | xargs)
            
            echo "📊 统计信息:"
            echo "   • 当前失败连接: ${currently_failed:-0}"
            echo "   • 总失败连接数: ${total_failed:-0}"
        fi
    done
    
    echo ""
    echo "=================================================="
    echo "📊 总结:"
    echo "   • 活跃的保护规则: $(echo "$jails" | wc -w) 个"
    echo "   • 总封禁 IP 数量: $total_banned 个"
    echo ""
    
    if [ $total_banned -gt 0 ]; then
        echo "💡 提示:"
        echo "   • 查看特定 jail 详情: fail2ban-client status <jail名称>"
        echo "   • 解封特定 IP: fail2ban-client unban <IP地址>"
        echo "   • 解封所有 IP: fail2ban-client unban --all"
    fi
}

# 手动封禁 IP
ban_ip() {
    echo "========================================"
    echo "  🚫 手动封禁 IP 地址"
    echo "========================================"
    
    if ! check_fail2ban_available; then
        return 1
    fi
    
    # 获取所有活跃的 jail
    local jails
    jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    
    if [ -z "$jails" ]; then
        echo "❌ 错误：没有活跃的保护规则 (jails)。请先配置 Fail2ban。"
        return 1
    fi
    
    echo "📋 当前可用的保护规则 (jails)："
    local jail_array=()
    local i=1
    for jail in $jails; do
        echo "$i. $jail"
        jail_array+=("$jail")
        ((i++))
    done
    
    echo ""
    read -p "🤔 请选择要使用的 jail (输入数字): " jail_choice
    
    # 验证选择
    if ! [[ "$jail_choice" =~ ^[0-9]+$ ]] || [ "$jail_choice" -lt 1 ] || [ "$jail_choice" -gt ${#jail_array[@]} ]; then
        echo "❌ 无效的选择。"
        return 1
    fi
    
    local selected_jail="${jail_array[$((jail_choice-1))]}"
    echo "✅ 选择的 jail: $selected_jail"
    
    echo ""
    echo "📝 请输入要封禁的 IP 地址或网段："
    echo "   • 单个 IP: 192.168.1.100"
    echo "   • IP 网段: 192.168.1.0/24"
    echo "   • 多个 IP: 用空格分隔"
    echo ""
    read -p "🎯 要封禁的 IP/网段: " ip_input
    
    if [ -z "$ip_input" ]; then
        echo "❌ 错误：未输入任何 IP 地址。"
        return 1
    fi
    
    # 询问封禁时长
    echo ""
    read -p "⏱️  封禁时长（小时，直接回车使用默认配置）: " ban_duration
    
    local ban_success=0
    local ban_failed=0
    
    echo ""
    echo "🚫 开始封禁操作..."
    
    for ip in $ip_input; do
        # 验证 IP 地址格式（简单验证）
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
            echo "⚠️  跳过无效的 IP 格式: $ip"
            ((ban_failed++))
            continue
        fi
        
        # 执行封禁
        if [ -n "$ban_duration" ]; then
            # 带时长的封禁
            local ban_seconds=$((ban_duration * 3600))
            if fail2ban-client set "$selected_jail" bantime "$ban_seconds" && fail2ban-client set "$selected_jail" banip "$ip"; then
                echo "✅ 成功封禁 $ip (时长: ${ban_duration}小时)"
                ((ban_success++))
            else
                echo "❌ 封禁失败: $ip"
                ((ban_failed++))
            fi
        else
            # 使用默认配置封禁
            if fail2ban-client set "$selected_jail" banip "$ip"; then
                echo "✅ 成功封禁 $ip (使用默认时长)"
                ((ban_success++))
            else
                echo "❌ 封禁失败: $ip"
                ((ban_failed++))
            fi
        fi
    done
    
    echo ""
    echo "📊 封禁操作完成："
    echo "   • 成功封禁: $ban_success 个"
    echo "   • 失败: $ban_failed 个"
    
    if [ $ban_success -gt 0 ]; then
        echo ""
        echo "🔍 当前 $selected_jail 的封禁状态："
        fail2ban-client status "$selected_jail"
    fi
}

# 解封 IP
unban_ip() {
    echo "========================================"
    echo "  ✅ 解封 IP 地址"
    echo "========================================"
    
    if ! check_fail2ban_available; then
        return 1
    fi
    
    # 先显示当前封禁的 IP
    view_banned_ips
    
    echo ""
    echo "🛠️  解封选项："
    echo "1. 解封指定 IP 地址"
    echo "2. 解封所有 IP 地址"
    echo "3. 返回主菜单"
    
    read -p "🤔 请选择操作: " unban_choice
    
    case $unban_choice in
        1)
            # 解封指定 IP
            echo ""
            read -p "🎯 请输入要解封的 IP 地址 (多个IP用空格分隔): " ip_input
            
            if [ -z "$ip_input" ]; then
                echo "❌ 错误：未输入任何 IP 地址。"
                return 1
            fi
            
            local unban_success=0
            local unban_failed=0
            
            echo ""
            echo "✅ 开始解封操作..."
            
            for ip in $ip_input; do
                if fail2ban-client unban "$ip"; then
                    echo "✅ 成功解封: $ip"
                    ((unban_success++))
                else
                    echo "❌ 解封失败: $ip (可能未被封禁或IP格式错误)"
                    ((unban_failed++))
                fi
            done
            
            echo ""
            echo "📊 解封操作完成："
            echo "   • 成功解封: $unban_success 个"
            echo "   • 失败: $unban_failed 个"
            ;;
            
        2)
            # 解封所有 IP
            echo ""
            echo "⚠️  警告：此操作将解封所有被 Fail2ban 封禁的 IP 地址！"
            read -p "🤔 确认要解封所有 IP 吗？(y/n): " confirm_unban_all
            
            if [[ "${confirm_unban_all,,}" == "y" ]]; then
                echo "✅ 正在解封所有 IP..."
                
                # 获取所有 jail 并逐个解封
                local jails
                jails=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                
                local total_unbanned=0
                
                for jail in $jails; do
                    echo "🔄 处理 jail: $jail"
                    local banned_ips
                    banned_ips=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | cut -d: -f2 | xargs)
                    
                    if [ -n "$banned_ips" ]; then
                        for ip in $banned_ips; do
                            if fail2ban-client set "$jail" unbanip "$ip"; then
                                echo "   ✅ 解封: $ip"
                                ((total_unbanned++))
                            else
                                echo "   ❌ 解封失败: $ip"
                            fi
                        done
                    else
                        echo "   ℹ️  该 jail 没有封禁的 IP"
                    fi
                done
                
                echo ""
                echo "🎉 全部解封操作完成，共解封 $total_unbanned 个 IP 地址。"
            else
                echo "❌ 操作已取消。"
            fi
            ;;
            
        3)
            return 0
            ;;
            
        *)
            echo "❌ 无效的选择。"
            return 1
            ;;
    esac
}

# 显示主菜单
show_main_menu() {
    local GREEN='\033[0;32m'
    local BOLD='\033[1m'
    local RESET='\033[0m'
    
    clear
    echo -e "${BOLD}=========================================="
    echo -e "  🛡️  Fail2ban 完整管理工具"
    echo -e "==========================================${RESET}"
    
    # 显示服务状态
    if command -v fail2ban-client &>/dev/null && systemctl is-active --quiet fail2ban; then
        echo -e "📊 服务状态: ${GREEN}✅ 运行中${RESET}"
        
        # 显示简要统计
        local jails
        jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | tr ',' '\n' | wc -w)
        
        local total_banned=0
        if [ "$jails" -gt 0 ]; then
            local jail_list
            jail_list=$(fail2ban-client status | grep "Jail list:" | cut -d: -f2 | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            
            for jail in $jail_list; do
                local banned_count
                banned_count=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | cut -d: -f2 | wc -w)
                total_banned=$((total_banned + banned_count))
            done
        fi
        
        echo -e "📋 活跃规则: ${GREEN}$jails${RESET} 个 | 封禁 IP: ${GREEN}$total_banned${RESET} 个"
    else
        echo -e "📊 服务状态: ${BOLD}❌ 未运行或未安装${RESET}"
    fi
    
    echo -e "------------------------------------------"
    echo -e "${BOLD}请选择操作：${RESET}"
    echo ""
    echo -e "${GREEN}1${RESET}. 🔧 配置 Fail2ban 保护 SSH"
    echo -e "${GREEN}2${RESET}. 🔍 查看当前封禁的 IP"
    echo -e "${GREEN}3${RESET}. 🚫 手动封禁 IP 地址"
    echo -e "${GREEN}4${RESET}. ✅ 解封 IP 地址"
    echo -e "${GREEN}5${RESET}. 📊 查看 Fail2ban 状态"
    echo -e "${GREEN}6${RESET}. 📜 查看 Fail2ban 日志"
    echo -e "${GREEN}q${RESET}. 🚪 退出"
    echo ""
}

# 查看 Fail2ban 日志
view_fail2ban_logs() {
    echo "========================================"
    echo "  📜 查看 Fail2ban 日志"
    echo "========================================"
    
    if ! check_fail2ban_available; then
        return 1
    fi
    
    echo "📋 日志查看选项："
    echo "1. 查看最近的日志 (最新 50 行)"
    echo "2. 实时监控日志"
    echo "3. 查看特定时间段的日志"
    echo "4. 返回主菜单"
    
    read -p "🤔 请选择: " log_choice
    
    case $log_choice in
        1)
            echo ""
            echo "📜 最近的 Fail2ban 日志："
            echo "----------------------------------------"
            journalctl -u fail2ban --no-pager -n 50
            ;;
            
        2)
            echo ""
            echo "📡 实时监控 Fail2ban 日志 (按 Ctrl+C 退出)："
            echo "----------------------------------------"
            journalctl -u fail2ban -f
            ;;
            
        3)
            echo ""
            read -p "📅 请输入开始时间 (格式: YYYY-MM-DD HH:MM): " start_time
            read -p "📅 请输入结束时间 (格式: YYYY-MM-DD HH:MM): " end_time
            
            if [ -n "$start_time" ] && [ -n "$end_time" ]; then
                echo ""
                echo "📜 指定时间段的 Fail2ban 日志："
                echo "----------------------------------------"
                journalctl -u fail2ban --since="$start_time" --until="$end_time" --no-pager
            else
                echo "❌ 时间格式输入错误。"
            fi
            ;;
            
        4)
            return 0
            ;;
            
        *)
            echo "❌ 无效的选择。"
            ;;
    esac
}

# 主程序循环
main_loop() {
    while true; do
        show_main_menu
        read -p "请输入选项: " choice
        
        case $choice in
            1)
                configure_fail2ban
                ;;
            2)
                view_banned_ips
                ;;
            3)
                ban_ip
                ;;
            4)
                unban_ip
                ;;
            5)
                check_fail2ban_status
                ;;
            6)
                view_fail2ban_logs
                ;;
            [qQ])
                echo "👋 感谢使用 Fail2ban 管理工具！"
                exit 0
                ;;
            *)
                echo "❌ 无效的选项，请重新选择。"
                ;;
        esac
        
        echo ""
        read -p "按 Enter 键继续..."
    done
}

# 如果脚本被直接执行，则运行主程序
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 检查权限
    check_root
    
    # 如果有命令行参数，直接执行对应功能
    case "$1" in
        "configure"|"config")
            configure_fail2ban
            ;;
        "status")
            check_fail2ban_status
            ;;
        "view"|"list")
            view_banned_ips
            ;;
        "ban")
            if [ -n "$2" ]; then
                # 命令行模式封禁
                echo "🚫 命令行模式封禁 IP: $2"
                # 这里可以添加命令行封禁逻辑
            else
                ban_ip
            fi
            ;;
        "unban")
            if [ -n "$2" ]; then
                # 命令行模式解封
                echo "✅ 命令行模式解封 IP: $2"
                if fail2ban-client unban "$2"; then
                    echo "✅ 成功解封: $2"
                else
                    echo "❌ 解封失败: $2"
                fi
            else
                unban_ip
            fi
            ;;
        "logs")
            view_fail2ban_logs
            ;;
        *)
            # 默认进入交互模式
            main_loop
            ;;
    esac
fi
