#!/bin/bash

# =============================================================================
# Kubernetes Master Nodes Initialization Script
# CentOS 7 Offline Deployment - Step 6
# =============================================================================

set -euo pipefail

# 获取脚本目录并加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log "开始初始化Kubernetes Master节点..."

# 获取本机IP
LOCAL_IP=$(get_local_ip)
log "本机IP: $LOCAL_IP"

# 检查是否为Master节点
is_master_node() {
    for node in "${MASTER_NODES[@]}"; do
        node_ip=$(echo "$node" | cut -d: -f2)
        if [[ "$node_ip" == "$LOCAL_IP" ]]; then
            return 0
        fi
    done
    return 1
}

# 检查是否为第一个Master节点
is_first_master() {
    local first_master_ip=$(echo "${MASTER_NODES[0]}" | cut -d: -f2)
    [[ "$LOCAL_IP" == "$first_master_ip" ]]
}

# 准备kubeadm配置文件
prepare_kubeadm_config() {
    log "准备kubeadm配置文件..."
    
    local config_file="$INSTALL_DIR/kubeadm-init.yaml"
    
    if [ ! -f "$config_file" ]; then
        error_exit "kubeadm配置文件不存在: $config_file"
    fi
    
    # 替换配置文件中的变量
    cp "$config_file" "/tmp/kubeadm-init-${LOCAL_IP}.yaml"
    
    # 替换Master IP
    sed -i "s/__MASTER_IP__/$LOCAL_IP/g" "/tmp/kubeadm-init-${LOCAL_IP}.yaml"
    
    # 构建ETCD endpoints
    local etcd_endpoints=""
    for node in "${ETCD_NODES[@]}"; do
        node_ip=$(echo "$node" | cut -d: -f2)
        if [ -z "$etcd_endpoints" ]; then
            etcd_endpoints="    - https://${node_ip}:2379"
        else
            etcd_endpoints="${etcd_endpoints}\n    - https://${node_ip}:2379"
        fi
    done
    
    # 替换ETCD endpoints
    sed -i "s/__ETCD_ENDPOINTS__/$etcd_endpoints/g" "/tmp/kubeadm-init-${LOCAL_IP}.yaml"
    
    log "kubeadm配置文件准备完成: /tmp/kubeadm-init-${LOCAL_IP}.yaml"
}

# 初始化第一个Master节点
init_first_master() {
    log "初始化第一个Master节点..."
    
    # 检查负载均衡器是否可用
    if ! nc -z "$VIP" "$LB_PORT"; then
        log "警告: 负载均衡器 $VIP:$LB_PORT 不可用，请检查HAProxy和Keepalived配置"
    fi
    
    # 执行kubeadm初始化
    log "执行kubeadm初始化..."
    kubeadm init --config="/tmp/kubeadm-init-${LOCAL_IP}.yaml" --upload-certs
    
    if [ $? -ne 0 ]; then
        error_exit "kubeadm初始化失败"
    fi
    
    log "第一个Master节点初始化完成"
}

# 配置kubectl
configure_kubectl() {
    log "配置kubectl..."
    
    # 为root用户配置kubectl
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config
    chown root:root /root/.kube/config
    
    # 为普通用户配置kubectl（如果存在）
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home=$(eval echo ~$SUDO_USER)
        mkdir -p "$user_home/.kube"
        cp -f /etc/kubernetes/admin.conf "$user_home/.kube/config"
        chown $SUDO_USER:$SUDO_USER "$user_home/.kube/config"
        log "为用户 $SUDO_USER 配置kubectl"
    fi
    
    # 测试kubectl连接
    if kubectl get nodes >/dev/null 2>&1; then
        log "kubectl配置成功"
    else
        error_exit "kubectl配置失败"
    fi
    
    log "kubectl配置完成"
}

# 获取加入令牌
get_join_tokens() {
    log "获取集群加入令牌..."
    
    # 创建tokens目录
    ensure_dir "$INSTALL_DIR/tokens"
    
    # 获取Master节点加入令牌和证书密钥
    local master_token=$(kubeadm token create --print-join-command)
    local cert_key=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
    
    # 获取CA证书哈希
    local ca_cert_hash=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
    
    # 保存令牌信息
    cat > "$INSTALL_DIR/tokens/master-join.sh" << EOF
#!/bin/bash
# Master节点加入命令
# 在其他Master节点执行此命令加入集群

# 基础加入命令
${master_token} \\
  --control-plane \\
  --certificate-key ${cert_key}

# 手动构造的完整命令
kubeadm join ${VIP}:${LB_PORT} \\
  --token $(echo "$master_token" | grep -o 'token [^ ]*' | cut -d' ' -f2) \\
  --discovery-token-ca-cert-hash sha256:${ca_cert_hash} \\
  --control-plane \\
  --certificate-key ${cert_key}
EOF

    cat > "$INSTALL_DIR/tokens/worker-join.sh" << EOF
#!/bin/bash
# Worker节点加入命令
# 在Worker节点执行此命令加入集群

${master_token}

# 手动构造的完整命令
kubeadm join ${VIP}:${LB_PORT} \\
  --token $(echo "$master_token" | grep -o 'token [^ ]*' | cut -d' ' -f2) \\
  --discovery-token-ca-cert-hash sha256:${ca_cert_hash}
EOF

    # 保存令牌和哈希信息到配置文件
    cat > "$INSTALL_DIR/tokens/cluster-info.conf" << EOF
# 集群信息
CLUSTER_ENDPOINT="${VIP}:${LB_PORT}"
CA_CERT_HASH="sha256:${ca_cert_hash}"
JOIN_TOKEN="$(echo "$master_token" | grep -o 'token [^ ]*' | cut -d' ' -f2)"
CERTIFICATE_KEY="${cert_key}"
EOF

    chmod +x "$INSTALL_DIR/tokens/"*.sh
    
    log "集群加入令牌已保存到 $INSTALL_DIR/tokens/"
    log "Master节点加入命令: $INSTALL_DIR/tokens/master-join.sh"
    log "Worker节点加入命令: $INSTALL_DIR/tokens/worker-join.sh"
}

# 加入其他Master节点
join_master_node() {
    log "将当前节点加入到Kubernetes集群..."
    
    # 检查是否存在加入令牌
    local token_file="$INSTALL_DIR/tokens/cluster-info.conf"
    if [ ! -f "$token_file" ]; then
        error_exit "集群令牌文件不存在: $token_file，请先在第一个Master节点初始化集群"
    fi
    
    # 加载令牌信息
    source "$token_file"
    
    # 检查必要变量
    if [ -z "${JOIN_TOKEN:-}" ] || [ -z "${CA_CERT_HASH:-}" ] || [ -z "${CERTIFICATE_KEY:-}" ]; then
        error_exit "令牌信息不完整，请检查 $token_file"
    fi
    
    # 检查集群连接
    if ! nc -z "$VIP" "$LB_PORT"; then
        error_exit "无法连接到集群端点: $VIP:$LB_PORT"
    fi
    
    # 执行加入命令
    log "执行Master节点加入命令..."
    kubeadm join "$CLUSTER_ENDPOINT" \
        --token "$JOIN_TOKEN" \
        --discovery-token-ca-cert-hash "$CA_CERT_HASH" \
        --control-plane \
        --certificate-key "$CERTIFICATE_KEY"
    
    if [ $? -ne 0 ]; then
        error_exit "Master节点加入失败"
    fi
    
    log "Master节点加入成功"
}

# 验证集群状态
verify_cluster() {
    log "验证集群状态..."
    
    # 等待节点就绪
    log "等待节点就绪..."
    local timeout=300
    local start_time=$(date +%s)
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log "警告: 节点就绪超时"
            break
        fi
        
        if kubectl get nodes | grep -q "Ready"; then
            log "节点已就绪"
            break
        fi
        
        log "等待节点就绪... ($elapsed/$timeout)"
        sleep 10
    done
    
    # 显示节点状态
    log "集群节点状态:"
    kubectl get nodes -o wide || true
    
    # 显示系统Pod状态
    log "系统Pod状态:"
    kubectl get pods -n kube-system || true
    
    # 检查集群组件状态
    log "检查集群组件状态:"
    kubectl get cs || kubectl get componentstatuses || true
    
    log "集群状态验证完成"
}

# 备份集群配置
backup_cluster_config() {
    log "备份集群配置..."
    
    local backup_dir="/var/backups/kubernetes"
    ensure_dir "$backup_dir"
    
    # 备份kubeconfig
    cp /etc/kubernetes/admin.conf "$backup_dir/admin.conf.$(date +%Y%m%d)"
    
    # 备份PKI证书
    if [ -d /etc/kubernetes/pki ]; then
        tar -czf "$backup_dir/pki-backup-$(date +%Y%m%d).tar.gz" -C /etc/kubernetes pki/
    fi
    
    # 备份etcd配置（如果本机是etcd节点）
    if [ -d /etc/etcd ]; then
        tar -czf "$backup_dir/etcd-config-$(date +%Y%m%d).tar.gz" -C /etc etcd/
    fi
    
    log "集群配置备份完成: $backup_dir"
}

# 生成集群信息报告
generate_cluster_report() {
    log "生成集群信息报告..."
    
    local report_file="$INSTALL_DIR/cluster-report-$(date +%Y%m%d).txt"
    
    cat > "$report_file" << EOF
Kubernetes高可用集群部署报告
=============================================================================
生成时间: $(date)
部署节点: $LOCAL_IP

集群信息:
- 集群名称: $CLUSTER_NAME
- Kubernetes版本: $K8S_VERSION
- 集群端点: $VIP:$LB_PORT

节点信息:
$(kubectl get nodes -o wide 2>/dev/null || echo "无法获取节点信息")

系统组件状态:
$(kubectl get pods -n kube-system 2>/dev/null || echo "无法获取Pod状态")

集群健康检查:
$(kubectl get cs 2>/dev/null || kubectl get componentstatuses 2>/dev/null || echo "无法获取组件状态")

配置文件位置:
- kubeconfig: /etc/kubernetes/admin.conf
- 证书目录: /etc/kubernetes/pki/
- 加入令牌: $INSTALL_DIR/tokens/

=============================================================================
EOF

    log "集群信息报告已生成: $report_file"
}

# 主函数
main() {
    log "=== 开始初始化Kubernetes Master节点 ==="
    
    # 检查是否为Master节点
    if ! is_master_node; then
        log "当前节点不是Master节点，跳过Master初始化"
        return 0
    fi
    
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
    
    # 检查ETCD连接
    local etcd_available=false
    for node in "${ETCD_NODES[@]}"; do
        node_ip=$(echo "$node" | cut -d: -f2)
        if nc -z "$node_ip" 2379; then
            etcd_available=true
            break
        fi
    done
    
    if [ "$etcd_available" = false ]; then
        error_exit "无法连接到任何ETCD节点，请先配置ETCD集群"
    fi
    
    log "前置条件检查通过"
    
    # 准备配置文件
    prepare_kubeadm_config
    
    # 根据节点类型执行不同操作
    if is_first_master; then
        log "当前节点是第一个Master节点"
        
        # 检查是否已初始化
        if [ -f /etc/kubernetes/admin.conf ]; then
            log "检测到集群已初始化"
            if kubectl get nodes >/dev/null 2>&1; then
                log "集群运行正常，跳过初始化"
            else
                log "集群配置异常，需要重新初始化"
                read -p "是否重新初始化集群? (y/n): " -r
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    kubeadm reset -f
                    init_first_master
                fi
            fi
        else
            init_first_master
        fi
        
        configure_kubectl
        get_join_tokens
        
    else
        log "当前节点是其他Master节点"
        
        # 检查是否已加入集群
        if [ -f /etc/kubernetes/admin.conf ]; then
            log "检测到节点已加入集群"
            if kubectl get nodes >/dev/null 2>&1; then
                log "节点运行正常，跳过加入操作"
            else
                log "节点配置异常，需要重新加入"
                read -p "是否重新加入集群? (y/n): " -r
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    kubeadm reset -f
                    join_master_node
                fi
            fi
        else
            join_master_node
        fi
        
        configure_kubectl
    fi
    
    # 验证和备份
    verify_cluster
    backup_cluster_config
    generate_cluster_report
    
    log "=== Kubernetes Master节点初始化完成 ==="
    
    # 显示下一步操作提示
    if is_first_master; then
        log "下一步操作:"
        log "1. 在其他Master节点执行此脚本"
        log "2. 使用 $INSTALL_DIR/tokens/worker-join.sh 在Worker节点加入集群"
        log "3. 安装网络插件: bash 08-install-cni.sh"
    else
        log "Master节点已成功加入集群"
        log "可以继续配置Worker节点或安装网络插件"
    fi
}

# 执行主函数
main "$@"