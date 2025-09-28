#!/bin/bash

# =============================================================================
# System Initialization Script for Kubernetes HA Cluster
# CentOS 7 Offline Deployment - Step 1
# =============================================================================

set -euo pipefail

# 获取脚本目录并加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log "开始系统初始化..."

# 关闭SELinux
disable_selinux() {
    log "关闭SELinux..."
    
    # 临时关闭SELinux
    setenforce 0 || true
    
    # 永久关闭SELinux
    sed -i 's/^SELINUX=enforcing$/SELINUX=disabled/' /etc/selinux/config
    sed -i 's/^SELINUX=permissive$/SELINUX=disabled/' /etc/selinux/config
    
    log "SELinux已禁用"
}

# 关闭防火墙
disable_firewall() {
    log "关闭防火墙..."
    
    systemctl stop firewalld || true
    systemctl disable firewalld || true
    
    log "防火墙已关闭"
}

# 关闭swap
disable_swap() {
    log "关闭swap..."
    
    # 临时关闭swap
    swapoff -a
    
    # 永久关闭swap
    sed -i '/swap/s/^/#/' /etc/fstab
    
    log "swap已关闭"
}

# 设置时区
set_timezone() {
    log "设置时区为 $TIMEZONE..."
    
    timedatectl set-timezone "$TIMEZONE"
    
    log "时区设置完成"
}

# 配置内核参数
configure_kernel_params() {
    log "配置内核参数..."
    
    cat > /etc/sysctl.d/k8s.conf << EOF
# Kubernetes required kernel parameters
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
vm.panic_on_oom = 0
vm.overcommit_memory = 1
kernel.panic = 10
kernel.panic_on_oops = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
fs.file-max = 52706963
fs.nr_open = 52706963
net.ipv6.conf.all.disable_ipv6 = 1
net.netfilter.nf_conntrack_max = 2310720
net.core.rmem_default = 8388608
net.core.rmem_max = 134217728
net.core.wmem_default = 8388608
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_rmem = 4096 12582912 134217728
net.ipv4.tcp_wmem = 4096 12582912 134217728
net.ipv4.tcp_max_syn_backlog = 8096
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65000
EOF

    # 加载br_netfilter模块
    modprobe br_netfilter
    echo 'br_netfilter' > /etc/modules-load.d/br_netfilter.conf
    
    # 应用内核参数
    sysctl -p /etc/sysctl.d/k8s.conf
    
    log "内核参数配置完成"
}

# 设置资源限制
configure_limits() {
    log "配置系统资源限制..."
    
    cat >> /etc/security/limits.conf << EOF
# Kubernetes resource limits
* soft nofile 655360
* hard nofile 655360
* soft nproc 655360
* hard nproc 655360
* soft memlock unlimited
* hard memlock unlimited
EOF

    log "系统资源限制配置完成"
}

# 配置hostname和hosts文件
configure_hosts() {
    log "配置hosts文件..."
    
    # 备份原始hosts文件
    cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d)
    
    # 添加集群节点到hosts文件
    echo "# Kubernetes Cluster Nodes" >> /etc/hosts
    
    for node in "${MASTER_NODES[@]}"; do
        node_name=$(echo "$node" | cut -d: -f1)
        node_ip=$(echo "$node" | cut -d: -f2)
        echo "$node_ip $node_name" >> /etc/hosts
    done
    
    for node in "${WORKER_NODES[@]}"; do
        node_name=$(echo "$node" | cut -d: -f1)
        node_ip=$(echo "$node" | cut -d: -f2)
        echo "$node_ip $node_name" >> /etc/hosts
    done
    
    # 添加VIP
    echo "$VIP k8s-api-vip" >> /etc/hosts
    
    log "hosts文件配置完成"
}

# 安装基础软件包
install_base_packages() {
    log "安装基础软件包..."
    
    # 检查是否有离线yum源
    if [ -d "$OFFLINE_PACKAGES_DIR/yum-packages" ]; then
        log "使用离线yum包..."
        cd "$OFFLINE_PACKAGES_DIR/yum-packages"
        rpm -Uvh --force --nodeps *.rpm 2>/dev/null || true
    else
        log "从系统yum源安装基础包..."
        yum install -y \
            wget \
            curl \
            net-tools \
            telnet \
            tree \
            nmap \
            sysstat \
            lsof \
            unzip \
            git \
            bind-utils \
            bash-completion \
            yum-utils \
            device-mapper-persistent-data \
            lvm2 \
            nfs-utils \
            jq \
            socat \
            ipset \
            conntrack \
            ipvsadm
    fi
    
    log "基础软件包安装完成"
}

# 配置SSH免密登录
configure_ssh() {
    log "配置SSH..."
    
    # 生成SSH密钥（如果不存在）
    if [ ! -f /root/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa -N ""
        log "SSH密钥已生成"
    fi
    
    # 配置SSH客户端
    cat > /root/.ssh/config << EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ConnectTimeout 10
EOF
    
    chmod 600 /root/.ssh/config
    
    log "SSH配置完成"
    log "请手动配置SSH免密登录到所有节点"
}

# 升级内核（可选）
upgrade_kernel() {
    log "检查内核版本..."
    
    current_kernel=$(uname -r)
    log "当前内核版本: $current_kernel"
    
    # 如果需要升级内核，可以取消下面的注释
    # if [[ "$current_kernel" < "4.19" ]]; then
    #     log "内核版本过低，建议升级到4.19+版本"
    #     log "请参考文档手动升级内核后重启系统"
    # fi
}

# 配置日志轮转
configure_logrotate() {
    log "配置日志轮转..."
    
    cat > /etc/logrotate.d/k8s << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
    
    log "日志轮转配置完成"
}

# 创建必要目录
create_directories() {
    log "创建必要目录..."
    
    local dirs=(
        "$INSTALL_DIR"
        "$PKG_DIR"
        "$CERT_DIR"
        "$MANIFEST_DIR"
        "/var/lib/etcd"
        "/var/lib/kubelet"
        "/etc/docker"
        "/etc/systemd/system/kubelet.service.d"
    )
    
    for dir in "${dirs[@]}"; do
        ensure_dir "$dir"
    done
    
    log "目录创建完成"
}

# 检查系统要求
check_system_requirements() {
    log "检查系统要求..."
    
    # 检查内存
    total_mem=$(free -m | awk 'NR==2{print $2}')
    if [ "$total_mem" -lt 2048 ]; then
        error_exit "系统内存不足，至少需要2GB内存"
    fi
    
    # 检查磁盘空间
    available_space=$(df / | awk 'NR==2{print $4}')
    if [ "$available_space" -lt 20971520 ]; then  # 20GB in KB
        error_exit "根分区空间不足，至少需要20GB可用空间"
    fi
    
    # 检查CPU核数
    cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 2 ]; then
        error_exit "CPU核数不足，至少需要2核CPU"
    fi
    
    log "系统要求检查通过 (内存: ${total_mem}MB, CPU: ${cpu_cores}核)"
}

# 主函数
main() {
    log "=== 开始系统初始化 ==="
    
    # 检查系统要求
    check_system_requirements
    
    # 执行系统初始化步骤
    disable_selinux
    disable_firewall
    disable_swap
    set_timezone
    configure_kernel_params
    configure_limits
    configure_hosts
    install_base_packages
    configure_ssh
    upgrade_kernel
    configure_logrotate
    create_directories
    
    log "=== 系统初始化完成 ==="
    log "请在所有节点执行此脚本，然后重启系统以确保所有配置生效"
    log "重启命令: reboot"
}

# 执行主函数
main "$@"