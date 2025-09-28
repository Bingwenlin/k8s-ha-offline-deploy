#!/bin/bash

# =============================================================================
# CNI Network Plugin Installation Script
# CentOS 7 Offline Deployment - Step 8
# =============================================================================

set -euo pipefail

# 获取脚本目录并加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log "开始安装CNI网络插件..."

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

# 检查集群状态
check_cluster_status() {
    log "检查集群状态..."
    
    # 检查kubectl可用性
    if ! kubectl get nodes >/dev/null 2>&1; then
        error_exit "无法连接到Kubernetes集群，请确保集群已正确初始化"
    fi
    
    # 检查节点状态
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c " Ready " || echo "0")
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    
    log "集群节点状态: $ready_nodes/$total_nodes 节点就绪"
    
    # 如果没有就绪节点，可能是网络插件未安装
    if [ "$ready_nodes" -eq 0 ]; then
        log "没有就绪节点，这可能是因为CNI插件未安装"
    fi
    
    # 显示节点详细状态
    kubectl get nodes -o wide
}

# 加载Calico镜像
load_calico_images() {
    log "加载Calico镜像..."
    
    local calico_images_tar="$OFFLINE_PACKAGES_DIR/calico-images.tar"
    
    if [ -f "$calico_images_tar" ]; then
        log "加载Calico镜像包: $calico_images_tar"
        docker load -i "$calico_images_tar"
        
        # 显示已加载的Calico镜像
        log "已加载的Calico镜像:"
        docker images | grep -i calico || log "警告: 未找到Calico镜像"
        
    elif [ -f "$OFFLINE_PACKAGES_DIR/k8s-images.tar" ]; then
        log "从K8s镜像包中查找Calico镜像..."
        docker load -i "$OFFLINE_PACKAGES_DIR/k8s-images.tar"
        
    else
        log "警告: 未找到Calico镜像包，请确保已准备好离线镜像"
        log "尝试使用现有镜像..."
    fi
    
    log "Calico镜像加载完成"
}

# 创建Calico配置文件
create_calico_config() {
    log "创建Calico配置文件..."
    
    local calico_dir="$INSTALL_DIR/calico"
    ensure_dir "$calico_dir"
    
    # 创建Calico operator配置
    cat > "$calico_dir/tigera-operator.yaml" << EOF
# Calico Operator配置
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  # Configures Calico networking.
  calicoNetwork:
    # Note: The ipPools section cannot be modified post-install.
    ipPools:
    - blockSize: 26
      cidr: ${POD_SUBNET}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
  registry: quay.io/
---
# This section configures the Calico API server.
# For more information, see: https://projectcalico.docs.tigera.io/master/reference/installation/api#operator.tigera.io/v1.APIServer
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

    # 创建自定义资源配置
    cat > "$calico_dir/custom-resources.yaml" << EOF
# Custom resources for Calico
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  # Configures Calico networking.
  calicoNetwork:
    # Note: The ipPools section cannot be modified post-install.
    ipPools:
    - blockSize: 26
      cidr: ${POD_SUBNET}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
  # Configures general installation parameters for Calico. Schema is based
  # on the operator.tigera.io/v1 API.
  registry: quay.io/
  # Image and registry configuration for the tigera/operator pod.
  imagePullSecrets:
    - name: tigera-pull-secret
EOF

    # 如果有离线配置文件，使用离线版本
    local offline_calico_dir="$OFFLINE_PACKAGES_DIR/calico"
    if [ -d "$offline_calico_dir" ]; then
        log "使用离线Calico配置文件..."
        
        if [ -f "$offline_calico_dir/calico.yaml" ]; then
            cp "$offline_calico_dir/calico.yaml" "$calico_dir/"
            log "复制离线Calico配置文件"
        fi
        
        if [ -f "$offline_calico_dir/tigera-operator.yaml" ]; then
            cp "$offline_calico_dir/tigera-operator.yaml" "$calico_dir/"
            log "复制离线Operator配置文件"
        fi
    fi
    
    log "Calico配置文件创建完成"
}

# 安装Calico Operator
install_calico_operator() {
    log "安装Calico Operator..."
    
    local operator_yaml="$INSTALL_DIR/calico/tigera-operator.yaml"
    local offline_operator="$OFFLINE_PACKAGES_DIR/calico/tigera-operator.yaml"
    
    # 优先使用离线配置
    if [ -f "$offline_operator" ]; then
        log "使用离线Operator配置..."
        kubectl apply -f "$offline_operator"
    elif [ -f "$operator_yaml" ]; then
        log "使用生成的Operator配置..."
        kubectl apply -f "$operator_yaml"
    else
        log "创建基础Operator配置..."
        
        # 创建命名空间
        kubectl create namespace tigera-operator --dry-run=client -o yaml | kubectl apply -f -
        
        # 应用基础Operator配置
        cat << EOF | kubectl apply -f -
# Calico基础配置
apiVersion: v1
kind: Namespace
metadata:
  name: tigera-operator
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tigera-operator
  namespace: tigera-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      name: tigera-operator
  template:
    metadata:
      labels:
        name: tigera-operator
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
      - effect: NoExecute
        operator: Exists
      - effect: NoSchedule
        operator: Exists
      serviceAccountName: tigera-operator
      containers:
      - name: tigera-operator
        image: quay.io/tigera/operator:v1.30.4
        imagePullPolicy: IfNotPresent
        command:
        - operator
        volumeMounts:
        - name: var-lib-calico
          readOnly: true
          mountPath: /var/lib/calico
        env:
        - name: WATCH_NAMESPACE
          value: ""
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: OPERATOR_NAME
          value: "tigera-operator"
        - name: TIGERA_OPERATOR_INIT_IMAGE_VERSION
          value: "v1.30.4"
      volumes:
      - name: var-lib-calico
        hostPath:
          path: /var/lib/calico
EOF
    fi
    
    # 等待Operator启动
    log "等待Calico Operator启动..."
    kubectl wait --for=condition=Available --timeout=300s deployment/tigera-operator -n tigera-operator || log "警告: Operator启动超时"
    
    log "Calico Operator安装完成"
}

# 安装Calico
install_calico() {
    log "安装Calico网络插件..."
    
    local calico_yaml="$INSTALL_DIR/calico/custom-resources.yaml"
    local offline_calico="$OFFLINE_PACKAGES_DIR/calico/calico.yaml"
    
    # 优先使用离线配置
    if [ -f "$offline_calico" ]; then
        log "使用离线Calico配置..."
        
        # 修改Pod网段配置
        sed -i "s|192.168.0.0/16|${POD_SUBNET}|g" "$offline_calico"
        
        kubectl apply -f "$offline_calico"
        
    elif [ -f "$calico_yaml" ]; then
        log "使用生成的Calico配置..."
        kubectl apply -f "$calico_yaml"
        
    else
        log "创建基础Calico配置..."
        
        cat << EOF | kubectl apply -f -
# Calico Installation
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_SUBNET}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF
    fi
    
    log "Calico配置已应用"
}

# 等待Calico就绪
wait_for_calico() {
    log "等待Calico网络插件就绪..."
    
    local timeout=600
    local start_time=$(date +%s)
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $timeout ]; then
            log "警告: Calico启动超时"
            break
        fi
        
        # 检查Calico节点状态
        local calico_nodes=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -o True | wc -l)
        local total_nodes=$(kubectl get nodes --no-headers | wc -l)
        
        if [ "$calico_nodes" -eq "$total_nodes" ] && [ "$total_nodes" -gt 0 ]; then
            log "所有节点网络就绪"
            break
        fi
        
        log "等待网络就绪... ($elapsed/$timeout) - 就绪节点: $calico_nodes/$total_nodes"
        sleep 15
    done
    
    # 检查Calico Pod状态
    log "检查Calico Pod状态..."
    kubectl get pods -n calico-system -o wide || kubectl get pods -n kube-system -o wide | grep calico || true
    
    log "Calico网络插件等待完成"
}

# 验证网络连通性
verify_network() {
    log "验证网络连通性..."
    
    # 检查节点状态
    log "检查节点状态:"
    kubectl get nodes -o wide
    
    # 检查网络组件状态
    log "检查网络组件状态:"
    kubectl get pods -n calico-system || kubectl get pods -n kube-system | grep -E "(calico|flannel|weave)" || true
    
    # 创建测试Pod进行网络测试
    log "创建网络测试Pod..."
    
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: network-test
  namespace: default
spec:
  containers:
  - name: test
    image: busybox:1.28
    command: ['sh', '-c', 'sleep 3600']
  restartPolicy: Never
EOF

    # 等待测试Pod就绪
    kubectl wait --for=condition=Ready --timeout=120s pod/network-test || log "警告: 测试Pod启动超时"
    
    # 测试DNS解析
    if kubectl get pod network-test >/dev/null 2>&1; then
        log "测试DNS解析..."
        kubectl exec network-test -- nslookup kubernetes.default.svc.cluster.local || log "警告: DNS解析测试失败"
        
        # 测试网络连接
        log "测试网络连接..."
        kubectl exec network-test -- ping -c 3 8.8.8.8 || log "警告: 外网连接测试失败"
        
        # 清理测试Pod
        kubectl delete pod network-test --grace-period=0 --force || true
    else
        log "警告: 网络测试Pod未就绪，跳过网络测试"
    fi
    
    log "网络验证完成"
}

# 配置网络策略（可选）
configure_network_policies() {
    log "配置默认网络策略..."
    
    # 创建默认拒绝策略（谨慎使用）
    if [ "${ENABLE_DEFAULT_DENY_POLICY:-false}" = "true" ]; then
        cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
        log "默认拒绝网络策略已创建"
    else
        log "跳过默认网络策略配置"
    fi
}

# 安装网络监控工具
install_network_tools() {
    log "安装网络监控和调试工具..."
    
    # 创建网络调试DaemonSet
    cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: network-debug
  namespace: kube-system
  labels:
    app: network-debug
spec:
  selector:
    matchLabels:
      app: network-debug
  template:
    metadata:
      labels:
        app: network-debug
    spec:
      hostNetwork: true
      hostPID: true
      containers:
      - name: network-debug
        image: nicolaka/netshoot:latest
        command: ['sh', '-c', 'sleep infinity']
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /host
          readOnly: true
      volumes:
      - name: host-root
        hostPath:
          path: /
      tolerations:
      - operator: Exists
EOF

    log "网络调试工具已安装"
    log "使用方法: kubectl exec -it -n kube-system ds/network-debug -- bash"
}

# 生成网络配置报告
generate_network_report() {
    log "生成网络配置报告..."
    
    local report_file="$INSTALL_DIR/network-report-$(date +%Y%m%d).txt"
    
    cat > "$report_file" << EOF
Kubernetes网络插件配置报告
=============================================================================
生成时间: $(date)
配置节点: $LOCAL_IP

网络配置:
- Pod网段: $POD_SUBNET
- Service网段: $SERVICE_SUBNET
- 集群DNS: $CLUSTER_DNS

节点状态:
$(kubectl get nodes -o wide 2>/dev/null || echo "无法获取节点信息")

网络组件状态:
$(kubectl get pods -n calico-system 2>/dev/null || kubectl get pods -n kube-system | grep -E "(calico|flannel|weave)" 2>/dev/null || echo "无法获取网络组件状态")

网络接口信息:
$(ip addr show | grep -E "(UP|inet)" | head -20)

路由信息:
$(ip route | head -10)

配置文件:
- Calico配置: $INSTALL_DIR/calico/
- CNI配置: /etc/cni/net.d/

网络测试命令:
  kubectl get nodes -o wide
  kubectl get pods -n calico-system
  kubectl run test-pod --image=busybox:1.28 --restart=Never -- sleep 3600
  kubectl exec test-pod -- ping 8.8.8.8

=============================================================================
EOF

    log "网络配置报告已生成: $report_file"
}

# 主函数
main() {
    log "=== 开始安装CNI网络插件 ==="
    
    # 只在Master节点执行网络插件安装
    if ! is_master_node; then
        log "当前节点不是Master节点，网络插件安装请在Master节点执行"
        return 0
    fi
    
    log "当前节点是Master节点，开始安装网络插件..."
    
    # 检查前置条件
    check_cluster_status
    
    # 检查是否已安装网络插件
    if kubectl get pods -n calico-system >/dev/null 2>&1 || kubectl get pods -n kube-system | grep -q calico; then
        log "检测到已安装网络插件"
        local ready_nodes=$(kubectl get nodes --no-headers | grep -c " Ready " || echo "0")
        
        if [ "$ready_nodes" -gt 0 ]; then
            log "网络插件运行正常，跳过安装"
            verify_network
            return 0
        else
            log "网络插件异常，将重新安装"
            read -p "是否重新安装网络插件? (y/n): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "跳过网络插件安装"
                return 0
            fi
        fi
    fi
    
    # 执行网络插件安装
    load_calico_images
    create_calico_config
    install_calico_operator
    
    # 等待一下Operator就绪
    sleep 10
    
    install_calico
    wait_for_calico
    verify_network
    configure_network_policies
    install_network_tools
    generate_network_report
    
    log "=== CNI网络插件安装完成 ==="
    log "网络插件: Calico"
    log "Pod网段: $POD_SUBNET"
    log ""
    log "验证命令:"
    log "  kubectl get nodes"
    log "  kubectl get pods -n calico-system"
    log "  kubectl run test-pod --image=busybox:1.28 --restart=Never -- sleep 3600"
    log ""
    log "集群已完全就绪，可以开始部署应用！"
}

# 执行主函数
main "$@"