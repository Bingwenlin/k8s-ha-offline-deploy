#!/bin/bash

# =============================================================================
# Kubernetes Components Installation Script
# CentOS 7 Offline Deployment - Step 3
# =============================================================================

set -euo pipefail

# 获取脚本目录并加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log "开始安装Kubernetes组件..."

# 安装K8s二进制文件
install_k8s_binaries() {
    log "安装Kubernetes二进制文件..."
    
    local k8s_pkg_dir="$OFFLINE_PACKAGES_DIR/kubernetes"
    
    if [ ! -d "$k8s_pkg_dir" ]; then
        error_exit "Kubernetes离线包目录不存在: $k8s_pkg_dir"
    fi
    
    # 安装kubeadm
    if [ -f "$k8s_pkg_dir/kubeadm" ]; then
        cp "$k8s_pkg_dir/kubeadm" /usr/bin/
        chmod +x /usr/bin/kubeadm
        log "kubeadm安装完成"
    else
        error_exit "kubeadm二进制文件不存在"
    fi
    
    # 安装kubelet
    if [ -f "$k8s_pkg_dir/kubelet" ]; then
        cp "$k8s_pkg_dir/kubelet" /usr/bin/
        chmod +x /usr/bin/kubelet
        log "kubelet安装完成"
    else
        error_exit "kubelet二进制文件不存在"
    fi
    
    # 安装kubectl
    if [ -f "$k8s_pkg_dir/kubectl" ]; then
        cp "$k8s_pkg_dir/kubectl" /usr/bin/
        chmod +x /usr/bin/kubectl
        log "kubectl安装完成"
    else
        error_exit "kubectl二进制文件不存在"
    fi
    
    log "Kubernetes二进制文件安装完成"
}

# 配置kubelet
configure_kubelet() {
    log "配置kubelet..."
    
    # 创建kubelet配置目录
    ensure_dir "/etc/systemd/system/kubelet.service.d"
    ensure_dir "/var/lib/kubelet"
    
    # 创建kubelet systemd服务文件
    cat > /etc/systemd/system/kubelet.service << EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # 创建kubelet服务配置文件
    cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf << EOF
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
Environment="KUBELET_SYSTEM_PODS_ARGS=--pod-manifest-path=/etc/kubernetes/manifests"
Environment="KUBELET_NETWORK_ARGS=--network-plugin=cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin"
Environment="KUBELET_DNS_ARGS=--cluster-dns=${CLUSTER_DNS} --cluster-domain=cluster.local"
Environment="KUBELET_AUTHZ_ARGS=--authorization-mode=Webhook --client-ca-file=/etc/kubernetes/pki/ca.crt"
Environment="KUBELET_CADVISOR_ARGS=--cadvisor-port=0"
Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=systemd"
Environment="KUBELET_CERTIFICATE_ARGS=--rotate-certificates=true --cert-dir=/var/lib/kubelet/pki"
Environment="KUBELET_EXTRA_ARGS=--node-labels=node.kubernetes.io/exclude-from-external-load-balancers=true"
ExecStart=
ExecStart=/usr/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_SYSTEM_PODS_ARGS \$KUBELET_NETWORK_ARGS \$KUBELET_DNS_ARGS \$KUBELET_AUTHZ_ARGS \$KUBELET_CADVISOR_ARGS \$KUBELET_CGROUP_ARGS \$KUBELET_CERTIFICATE_ARGS \$KUBELET_EXTRA_ARGS
EOF

    log "kubelet配置完成"
}

# 安装CNI插件
install_cni_plugins() {
    log "安装CNI插件..."
    
    local cni_pkg_dir="$OFFLINE_PACKAGES_DIR/cni"
    
    if [ ! -d "$cni_pkg_dir" ]; then
        log "警告: CNI插件目录不存在: $cni_pkg_dir"
        return 0
    fi
    
    # 创建CNI目录
    ensure_dir "/opt/cni/bin"
    ensure_dir "/etc/cni/net.d"
    
    # 解压CNI插件
    if [ -f "$cni_pkg_dir/cni-plugins.tgz" ]; then
        tar -xzf "$cni_pkg_dir/cni-plugins.tgz" -C /opt/cni/bin/
        chmod +x /opt/cni/bin/*
        log "CNI插件安装完成"
    else
        log "警告: CNI插件包不存在"
    fi
}

# 安装crictl工具
install_crictl() {
    log "安装crictl工具..."
    
    local crictl_pkg_dir="$OFFLINE_PACKAGES_DIR/crictl"
    
    if [ -f "$crictl_pkg_dir/crictl" ]; then
        cp "$crictl_pkg_dir/crictl" /usr/bin/
        chmod +x /usr/bin/crictl
        
        # 配置crictl
        cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF
        
        log "crictl安装完成"
    else
        log "警告: crictl二进制文件不存在"
    fi
}

# 配置bash自动补全
configure_bash_completion() {
    log "配置bash自动补全..."
    
    # 为kubectl配置自动补全
    if command -v kubectl >/dev/null 2>&1; then
        kubectl completion bash > /etc/bash_completion.d/kubectl
        echo 'source <(kubectl completion bash)' >> /root/.bashrc
        echo 'alias k=kubectl' >> /root/.bashrc
        echo 'complete -F __start_kubectl k' >> /root/.bashrc
    fi
    
    # 为kubeadm配置自动补全
    if command -v kubeadm >/dev/null 2>&1; then
        kubeadm completion bash > /etc/bash_completion.d/kubeadm
    fi
    
    log "bash自动补全配置完成"
}

# 启用kubelet服务
enable_kubelet_service() {
    log "启用kubelet服务..."
    
    # 重新加载systemd
    systemctl daemon-reload
    
    # 启用kubelet服务（但不启动，等待kubeadm初始化）
    systemctl enable kubelet
    
    log "kubelet服务已启用"
}

# 验证安装
verify_installation() {
    log "验证Kubernetes组件安装..."
    
    # 检查kubeadm版本
    if command -v kubeadm >/dev/null 2>&1; then
        local kubeadm_version=$(kubeadm version -o short)
        log "kubeadm版本: $kubeadm_version"
    else
        error_exit "kubeadm安装失败"
    fi
    
    # 检查kubelet版本
    if command -v kubelet >/dev/null 2>&1; then
        local kubelet_version=$(kubelet --version | cut -d' ' -f2)
        log "kubelet版本: $kubelet_version"
    else
        error_exit "kubelet安装失败"
    fi
    
    # 检查kubectl版本
    if command -v kubectl >/dev/null 2>&1; then
        local kubectl_version=$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')
        log "kubectl版本: $kubectl_version"
    else
        error_exit "kubectl安装失败"
    fi
    
    # 检查crictl
    if command -v crictl >/dev/null 2>&1; then
        local crictl_version=$(crictl version 2>/dev/null | grep 'Version:' | head -1 | awk '{print $2}' || echo "unknown")
        log "crictl版本: $crictl_version"
    fi
    
    # 检查CNI插件
    if [ -d "/opt/cni/bin" ] && [ "$(ls -A /opt/cni/bin)" ]; then
        local cni_plugins=$(ls /opt/cni/bin | wc -l)
        log "CNI插件数量: $cni_plugins"
    else
        log "警告: CNI插件未安装"
    fi
    
    # 检查kubelet服务状态
    if systemctl is-enabled kubelet >/dev/null 2>&1; then
        log "kubelet服务已启用"
    else
        error_exit "kubelet服务启用失败"
    fi
    
    log "Kubernetes组件验证完成"
}

# 创建kubeadm配置文件
create_kubeadm_config() {
    log "创建kubeadm配置文件..."
    
    # 创建kubeadm初始化配置文件
    cat > "$INSTALL_DIR/kubeadm-init.yaml" << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "__MASTER_IP__"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    cgroup-driver: systemd
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
clusterName: ${CLUSTER_NAME}
controlPlaneEndpoint: "${VIP}:${LB_PORT}"
networking:
  podSubnet: ${POD_SUBNET}
  serviceSubnet: ${SERVICE_SUBNET}
  dnsDomain: cluster.local
apiServer:
  certSANs:
  - "${VIP}"
  - "k8s-api-vip"
  - "localhost"
  - "127.0.0.1"
  extraArgs:
    authorization-mode: Node,RBAC
    enable-admission-plugins: NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,ResourceQuota
    audit-log-maxage: "30"
    audit-log-maxbackup: "3"
    audit-log-maxsize: "100"
    audit-log-path: /var/log/audit.log
controllerManager:
  extraArgs:
    bind-address: 0.0.0.0
scheduler:
  extraArgs:
    bind-address: 0.0.0.0
etcd:
  external:
    endpoints:
__ETCD_ENDPOINTS__
    caFile: /etc/kubernetes/pki/etcd/ca.crt
    certFile: /etc/kubernetes/pki/etcd/kubernetes.crt
    keyFile: /etc/kubernetes/pki/etcd/kubernetes.key
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: false
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
authorization:
  mode: Webhook
serverTLSBootstrap: true
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  scheduler: rr
iptables:
  masqueradeAll: true
EOF

    # 创建worker节点加入配置文件
    cat > "$INSTALL_DIR/kubeadm-join.yaml" << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    token: "__TOKEN__"
    apiServerEndpoint: "${VIP}:${LB_PORT}"
    caCertHashes:
    - "__CA_CERT_HASH__"
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    cgroup-driver: systemd
EOF

    log "kubeadm配置文件创建完成"
}

# 配置IPVS模块
configure_ipvs() {
    log "配置IPVS模块..."
    
    # 加载IPVS相关模块
    local ipvs_modules=(
        "ip_vs"
        "ip_vs_rr"
        "ip_vs_wrr"
        "ip_vs_sh"
        "nf_conntrack"
    )
    
    for module in "${ipvs_modules[@]}"; do
        modprobe "$module"
        echo "$module" >> /etc/modules-load.d/ipvs.conf
    done
    
    log "IPVS模块配置完成"
}

# 主函数
main() {
    log "=== 开始安装Kubernetes组件 ==="
    
    # 检查Docker是否已安装
    if ! command -v docker >/dev/null 2>&1; then
        error_exit "Docker未安装，请先安装Docker"
    fi
    
    # 检查是否已安装K8s组件
    if command -v kubeadm >/dev/null 2>&1; then
        local installed_version=$(kubeadm version -o short 2>/dev/null || echo "unknown")
        log "检测到已安装的kubeadm版本: $installed_version"
        
        read -p "是否重新安装Kubernetes组件? (y/n): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "跳过Kubernetes组件安装"
            return 0
        fi
    fi
    
    # 执行安装步骤
    install_k8s_binaries
    configure_kubelet
    install_cni_plugins
    install_crictl
    configure_bash_completion
    configure_ipvs
    enable_kubelet_service
    create_kubeadm_config
    verify_installation
    
    log "=== Kubernetes组件安装完成 ==="
    log "kubeadm版本: $(kubeadm version -o short)"
    log "kubelet版本: $(kubelet --version | cut -d' ' -f2)"
    log "kubectl版本: $(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')"
    log "请在所有节点执行此脚本"
}

# 执行主函数
main "$@"