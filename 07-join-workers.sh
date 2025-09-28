#!/bin/bash

# =============================================================================
# Kubernetes Worker Nodes Join Script
# CentOS 7 Offline Deployment - Step 7
# =============================================================================

set -euo pipefail

# 获取脚本目录并加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log "开始配置Kubernetes Worker节点..."

# 获取本机IP
LOCAL_IP=$(get_local_ip)
log "本机IP: $LOCAL_IP"

# 检查是否为Worker节点
is_worker_node() {
    for node in "${WORKER_NODES[@]}"; do
        node_ip=$(echo "$node" | cut -d: -f2)
        if [[ "$node_ip" == "$LOCAL_IP" ]]; then
            return 0
        fi
    done
    return 1
}

# 获取Worker节点名称
get_worker_node_name() {
    for node in "${WORKER_NODES[@]}"; do
        node_name=$(echo "$node" | cut -d: -f1)
        node_ip=$(echo "$node" | cut -d: -f2)
        if [[ "$node_ip" == "$LOCAL_IP" ]]; then
            echo "$node_name"
            return 0
        fi
    done
    echo "$(hostname)"
}

# 准备kubeadm加入配置
prepare_kubeadm_join_config() {
    log "准备kubeadm加入配置..."
    
    # 检查是否存在加入令牌
    local token_file="$INSTALL_DIR/tokens/cluster-info.conf"
    if [ ! -f "$token_file" ]; then
        error_exit "集群令牌文件不存在: $token_file，请从Master节点复制此文件"
    fi
    
    # 加载令牌信息
    source "$token_file"
    
    # 检查必要变量
    if [ -z "${JOIN_TOKEN:-}" ] || [ -z "${CA_CERT_HASH:-}" ]; then
        error_exit "令牌信息不完整，请检查 $token_file"
    fi
    
    # 创建Worker节点加入配置文件
    cat > "/tmp/kubeadm-join-worker-${LOCAL_IP}.yaml" << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    token: "${JOIN_TOKEN}"
    apiServerEndpoint: "${CLUSTER_ENDPOINT}"
    caCertHashes:
    - "${CA_CERT_HASH}"
nodeRegistration:
  name: "$(get_worker_node_name)"
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    cgroup-driver: systemd
    node-labels: "node-role.kubernetes.io/worker="
    fail-swap-on: "false"
EOF

    log "kubeadm加入配置文件准备完成: /tmp/kubeadm-join-worker-${LOCAL_IP}.yaml"
}

# 加入Worker节点到集群
join_worker_node() {
    log "将Worker节点加入到Kubernetes集群..."
    
    # 检查集群连接
    if ! nc -z "$VIP" "$LB_PORT"; then
        error_exit "无法连接到集群端点: $VIP:$LB_PORT，请检查网络和负载均衡器"
    fi
    
    # 测试API服务器连接
    log "测试API服务器连接..."
    if ! curl -k "https://$VIP:$LB_PORT/version" >/dev/null 2>&1; then
        log "警告: 无法直接访问API服务器，但将尝试加入集群"
    else
        log "API服务器连接正常"
    fi
    
    # 执行加入命令
    log "执行Worker节点加入命令..."
    
    if [ -f "/tmp/kubeadm-join-worker-${LOCAL_IP}.yaml" ]; then
        # 使用配置文件方式加入
        kubeadm join --config="/tmp/kubeadm-join-worker-${LOCAL_IP}.yaml"
    else
        # 使用命令行方式加入
        source "$INSTALL_DIR/tokens/cluster-info.conf"
        kubeadm join "$CLUSTER_ENDPOINT" \
            --token "$JOIN_TOKEN" \
            --discovery-token-ca-cert-hash "$CA_CERT_HASH"
    fi
    
    if [ $? -ne 0 ]; then
        error_exit "Worker节点加入失败"
    fi
    
    log "Worker节点加入成功"
}

# 配置Worker节点
configure_worker_node() {
    log "配置Worker节点..."
    
    # 配置kubectl（可选，Worker节点通常不需要）
    if [ "${INSTALL_KUBECTL_ON_WORKER:-false}" = "true" ]; then
        log "在Worker节点配置kubectl..."
        
        # 从Master节点复制kubeconfig（需要手动操作或通过其他方式获取）
        if [ -f "$INSTALL_DIR/admin.conf" ]; then
            mkdir -p /root/.kube
            cp "$INSTALL_DIR/admin.conf" /root/.kube/config
            chown root:root /root/.kube/config
            log "kubectl配置完成"
        else
            log "警告: 未找到kubeconfig文件，跳过kubectl配置"
        fi
    fi
    
    # 配置节点标签（如果需要）
    log "准备节点标签配置..."
    cat > "/tmp/label-worker-${LOCAL_IP}.sh" << EOF
#!/bin/bash
# Worker节点标签配置脚本
# 请在Master节点执行此脚本

NODE_NAME="\$(kubectl get nodes | grep '$LOCAL_IP' | awk '{print \$1}')"

if [ -n "\$NODE_NAME" ]; then
    echo "为节点 \$NODE_NAME 添加标签..."
    
    # 添加Worker角色标签
    kubectl label node "\$NODE_NAME" node-role.kubernetes.io/worker= --overwrite
    
    # 添加其他自定义标签（可选）
    # kubectl label node "\$NODE_NAME" environment=production --overwrite
    # kubectl label node "\$NODE_NAME" workload=general --overwrite
    
    echo "节点标签配置完成"
    kubectl get node "\$NODE_NAME" --show-labels
else
    echo "未找到节点: $LOCAL_IP"
fi
EOF
    
    chmod +x "/tmp/label-worker-${LOCAL_IP}.sh"
    log "节点标签配置脚本已生成: /tmp/label-worker-${LOCAL_IP}.sh"
    log "请将此脚本复制到Master节点执行"
}

# 验证Worker节点状态
verify_worker_node() {
    log "验证Worker节点状态..."
    
    # 检查kubelet服务
    if systemctl is-active --quiet kubelet; then
        log "kubelet服务运行正常"
    else
        error_exit "kubelet服务未运行"
    fi
    
    # 检查容器运行时
    if systemctl is-active --quiet docker; then
        log "Docker服务运行正常"
    else
        log "警告: Docker服务未运行"
    fi
    
    if systemctl is-active --quiet containerd; then
        log "containerd服务运行正常"
    else
        log "警告: containerd服务未运行"
    fi
    
    # 检查网络配置
    log "检查网络配置..."
    if ip route | grep -q "$POD_SUBNET"; then
        log "Pod网络路由已配置"
    else
        log "警告: Pod网络路由未配置，等待CNI插件安装"
    fi
    
    # 检查节点资源
    log "检查节点资源..."
    free -h
    df -h /
    
    log "Worker节点状态验证完成"
}

# 生成节点信息报告
generate_node_report() {
    log "生成节点信息报告..."
    
    local report_file="$INSTALL_DIR/worker-node-report-${LOCAL_IP}-$(date +%Y%m%d).txt"
    
    cat > "$report_file" << EOF
Kubernetes Worker节点部署报告
=============================================================================
生成时间: $(date)
节点IP: $LOCAL_IP
节点名称: $(get_worker_node_name)

系统信息:
$(uname -a)

资源信息:
内存: $(free -h | grep '^Mem:')
磁盘: $(df -h / | tail -1)
CPU: $(nproc) 核

服务状态:
- kubelet: $(systemctl is-active kubelet)
- docker: $(systemctl is-active docker)
- containerd: $(systemctl is-active containerd)

网络配置:
$(ip addr show | grep -E "(inet|UP)" | head -10)

容器运行时信息:
Docker版本: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "未安装")
containerd版本: $(containerd --version 2>/dev/null || echo "未安装")

配置文件位置:
- kubelet配置: /var/lib/kubelet/config.yaml
- 容器运行时配置: /etc/containerd/config.toml

下一步操作:
1. 在Master节点验证此节点是否成功加入: kubectl get nodes
2. 为节点添加标签: bash /tmp/label-worker-${LOCAL_IP}.sh
3. 安装CNI网络插件（如果还未安装）

=============================================================================
EOF

    log "节点信息报告已生成: $report_file"
}

# 安装Worker节点常用工具
install_worker_tools() {
    log "安装Worker节点常用工具..."
    
    # 安装基础监控工具
    local tools_pkg_dir="$OFFLINE_PACKAGES_DIR/worker-tools"
    
    if [ -d "$tools_pkg_dir" ]; then
        log "安装离线工具包..."
        cd "$tools_pkg_dir"
        rpm -Uvh --force --nodeps *.rpm 2>/dev/null || true
    else
        log "使用yum安装基础工具..."
        yum install -y \
            htop \
            iotop \
            iftop \
            tcpdump \
            strace \
            lsof \
            nc \
            telnet \
            curl \
            wget 2>/dev/null || log "部分工具安装失败"
    fi
    
    log "Worker节点工具安装完成"
}

# 配置日志轮转
configure_worker_logrotate() {
    log "配置Worker节点日志轮转..."
    
    cat > /etc/logrotate.d/kubernetes-worker << EOF
# Kubernetes Worker节点日志轮转配置

/var/log/pods/*/*/*.log {
    daily
    missingok
    rotate 5
    compress
    delaycompress
    notifempty
    copytruncate
    maxsize 100M
}

/var/lib/kubelet/logs/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF

    log "Worker节点日志轮转配置完成"
}

# 主函数
main() {
    log "=== 开始配置Kubernetes Worker节点 ==="
    
    # 检查是否为Worker节点
    if ! is_worker_node; then
        log "当前节点不是Worker节点，跳过Worker配置"
        log "当前IP: $LOCAL_IP"
        log "配置的Worker节点："
        for node in "${WORKER_NODES[@]}"; do
            log "  - $node"
        done
        return 0
    fi
    
    log "当前节点是Worker节点: $(get_worker_node_name)"
    
    # 检查前置条件
    log "检查前置条件..."
    
    # 检查Docker
    if ! systemctl is-active --quiet docker; then
        error_exit "Docker服务未运行，请先启动Docker"
    fi
    
    # 检查kubelet
    if ! systemctl is-enabled --quiet kubelet; then
        error_exit "kubelet服务未启用，请先安装Kubernetes组件"
    fi
    
    # 检查是否已加入集群
    if [ -f /etc/kubernetes/kubelet.conf ]; then
        log "检测到节点已加入集群"
        if systemctl is-active --quiet kubelet && kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get nodes >/dev/null 2>&1; then
            log "节点运行正常，跳过加入操作"
            verify_worker_node
            return 0
        else
            log "节点配置异常，需要重新加入"
            read -p "是否重新加入集群? (y/n): " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                kubeadm reset -f
            else
                log "跳过重新加入操作"
                return 0
            fi
        fi
    fi
    
    log "前置条件检查通过"
    
    # 执行Worker节点配置
    prepare_kubeadm_join_config
    join_worker_node
    configure_worker_node
    install_worker_tools
    configure_worker_logrotate
    verify_worker_node
    generate_node_report
    
    log "=== Kubernetes Worker节点配置完成 ==="
    log "节点名称: $(get_worker_node_name)"
    log "节点IP: $LOCAL_IP"
    log ""
    log "下一步操作:"
    log "1. 在Master节点执行以下命令验证节点状态:"
    log "   kubectl get nodes"
    log "   kubectl get nodes $LOCAL_IP -o wide"
    log ""
    log "2. 为节点添加标签（在Master节点执行）:"
    log "   bash /tmp/label-worker-${LOCAL_IP}.sh"
    log ""
    log "3. 如果所有节点都已配置完成，可以安装CNI网络插件:"
    log "   bash 08-install-cni.sh"
}

# 执行主函数
main "$@"