#!/bin/bash

# =============================================================================
# Kubernetes High Availability Cluster Configuration
# CentOS 7 Offline Deployment Configuration
# =============================================================================

# 集群基本信息
export CLUSTER_NAME="k8s-ha-cluster"
export K8S_VERSION="1.28.2"
export DOCKER_VERSION="20.10.21"
export ETCD_VERSION="3.5.9"

# 网络配置
export POD_SUBNET="10.244.0.0/16"
export SERVICE_SUBNET="10.96.0.0/12"
export CLUSTER_DNS="10.96.0.10"

# 负载均衡器配置（VIP）
export VIP="192.168.1.100"
export LB_PORT="6443"

# 节点配置 - 请根据实际环境修改
# Master节点（至少3个节点）
export MASTER_NODES=(
    "master1:192.168.1.101"
    "master2:192.168.1.102"
    "master3:192.168.1.103"
)

# Worker节点
export WORKER_NODES=(
    "worker1:192.168.1.111"
    "worker2:192.168.1.112"
    "worker3:192.168.1.113"
)

# ETCD节点（通常与Master节点相同）
export ETCD_NODES=(
    "etcd1:192.168.1.101"
    "etcd2:192.168.1.102"
    "etcd3:192.168.1.103"
)

# 目录配置
export INSTALL_DIR="/opt/k8s"
export PKG_DIR="/opt/k8s/packages"
export CERT_DIR="/etc/kubernetes/pki"
export MANIFEST_DIR="/etc/kubernetes/manifests"
export KUBECONFIG_DIR="/etc/kubernetes"

# 离线包配置
export OFFLINE_PACKAGES_DIR="/opt/k8s/offline-packages"
export DOCKER_IMAGES_TAR="$OFFLINE_PACKAGES_DIR/k8s-images.tar"

# 系统配置
export TIMEZONE="Asia/Shanghai"
export KERNEL_VERSION="4.19.12-1.el7.elrepo.x86_64"

# 证书配置
export CERT_VALIDITY_DAYS="3650"

# Keepalived配置
export KEEPALIVED_INTERFACE="eth0"  # 网卡接口名，请根据实际情况修改
export KEEPALIVED_ROUTER_ID="51"

# HAProxy配置
export HAPROXY_STATS_PORT="9000"
export HAPROXY_STATS_USER="admin"
export HAPROXY_STATS_PASS="admin123"

# 下载地址配置（用于准备离线包）
export K8S_DOWNLOAD_URL="https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/amd64"
export DOCKER_DOWNLOAD_URL="https://download.docker.com/linux/static/stable/x86_64"
export ETCD_DOWNLOAD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}"

# Docker镜像列表
export K8S_IMAGES=(
    "registry.k8s.io/kube-apiserver:v${K8S_VERSION}"
    "registry.k8s.io/kube-controller-manager:v${K8S_VERSION}"
    "registry.k8s.io/kube-scheduler:v${K8S_VERSION}"
    "registry.k8s.io/kube-proxy:v${K8S_VERSION}"
    "registry.k8s.io/pause:3.9"
    "registry.k8s.io/etcd:3.5.9-0"
    "registry.k8s.io/coredns/coredns:v1.10.1"
    "calico/cni:v3.26.1"
    "calico/pod2daemon-flexvol:v3.26.1"
    "calico/node:v3.26.1"
    "calico/kube-controllers:v3.26.1"
    "quay.io/tigera/operator:v1.30.4"
)

# 日志配置
export LOG_DIR="/var/log/k8s-install"
export LOG_FILE="$LOG_DIR/install.log"

# 函数：打印日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 函数：打印错误并退出
error_exit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
    exit 1
}

# 函数：检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        error_exit "命令 $1 不存在，请先安装"
    fi
}

# 函数：检查文件是否存在
check_file() {
    if [ ! -f "$1" ]; then
        error_exit "文件 $1 不存在"
    fi
}

# 函数：检查目录是否存在，不存在则创建
ensure_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
        log "创建目录: $1"
    fi
}

# 函数：获取本机IP
get_local_ip() {
    ip route get 8.8.8.8 | awk '{print $7; exit}'
}

# 函数：检查节点是否可达
check_node_connectivity() {
    local node_ip="$1"
    if ! ping -c 1 -W 3 "$node_ip" &>/dev/null; then
        error_exit "无法连接到节点: $node_ip"
    fi
}

# 初始化日志目录
ensure_dir "$LOG_DIR"

log "配置文件加载完成"