#!/bin/bash

# =============================================================================
# Offline Packages Download Script for Kubernetes HA Cluster
# CentOS 7 Offline Deployment - Package Preparation
# =============================================================================

set -euo pipefail

# 获取脚本目录并加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log "开始准备离线安装包..."

# 创建下载目录结构
create_download_directories() {
    log "创建下载目录结构..."
    
    local dirs=(
        "$OFFLINE_PACKAGES_DIR"
        "$OFFLINE_PACKAGES_DIR/kubernetes"
        "$OFFLINE_PACKAGES_DIR/docker"
        "$OFFLINE_PACKAGES_DIR/etcd"
        "$OFFLINE_PACKAGES_DIR/calico"
        "$OFFLINE_PACKAGES_DIR/cni"
        "$OFFLINE_PACKAGES_DIR/crictl"
        "$OFFLINE_PACKAGES_DIR/haproxy"
        "$OFFLINE_PACKAGES_DIR/keepalived"
        "$OFFLINE_PACKAGES_DIR/yum-packages"
        "$OFFLINE_PACKAGES_DIR/worker-tools"
    )
    
    for dir in "${dirs[@]}"; do
        ensure_dir "$dir"
    done
    
    log "下载目录结构创建完成"
}

# 下载Kubernetes二进制文件
download_kubernetes_binaries() {
    log "下载Kubernetes二进制文件..."
    
    local k8s_dir="$OFFLINE_PACKAGES_DIR/kubernetes"
    cd "$k8s_dir"
    
    local binaries=("kubeadm" "kubelet" "kubectl")
    
    for binary in "${binaries[@]}"; do
        if [ ! -f "$binary" ]; then
            log "下载 $binary v$K8S_VERSION..."
            wget -O "$binary" "$K8S_DOWNLOAD_URL/$binary" || curl -L -o "$binary" "$K8S_DOWNLOAD_URL/$binary"
            chmod +x "$binary"
        else
            log "$binary 已存在，跳过下载"
        fi
    done
    
    log "Kubernetes二进制文件下载完成"
}

# 下载Docker二进制文件
download_docker_binaries() {
    log "下载Docker二进制文件..."
    
    local docker_dir="$OFFLINE_PACKAGES_DIR/docker"
    cd "$docker_dir"
    
    # 下载Docker静态二进制包
    local docker_package="docker-${DOCKER_VERSION}.tgz"
    if [ ! -f "$docker_package" ]; then
        log "下载Docker $DOCKER_VERSION..."
        wget "$DOCKER_DOWNLOAD_URL/$docker_package" || curl -L -O "$DOCKER_DOWNLOAD_URL/$docker_package"
    else
        log "Docker包已存在，跳过下载"
    fi
    
    # 下载containerd
    local containerd_version="1.6.24"
    local containerd_package="containerd-${containerd_version}-linux-amd64.tar.gz"
    if [ ! -f "containerd.tar.gz" ]; then
        log "下载containerd $containerd_version..."
        wget -O containerd.tar.gz "https://github.com/containerd/containerd/releases/download/v${containerd_version}/$containerd_package" || \
        curl -L -o containerd.tar.gz "https://github.com/containerd/containerd/releases/download/v${containerd_version}/$containerd_package"
    else
        log "containerd包已存在，跳过下载"
    fi
    
    # 下载runc
    local runc_version="1.1.9"
    if [ ! -f "runc" ]; then
        log "下载runc $runc_version..."
        wget -O runc "https://github.com/opencontainers/runc/releases/download/v${runc_version}/runc.amd64" || \
        curl -L -o runc "https://github.com/opencontainers/runc/releases/download/v${runc_version}/runc.amd64"
        chmod +x runc
    else
        log "runc已存在，跳过下载"
    fi
    
    log "Docker相关文件下载完成"
}

# 下载ETCD二进制文件
download_etcd_binaries() {
    log "下载ETCD二进制文件..."
    
    local etcd_dir="$OFFLINE_PACKAGES_DIR/etcd"
    cd "$etcd_dir"
    
    local etcd_package="etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
    if [ ! -f "$etcd_package" ]; then
        log "下载ETCD $ETCD_VERSION..."
        wget "$ETCD_DOWNLOAD_URL/$etcd_package" || curl -L -O "$ETCD_DOWNLOAD_URL/$etcd_package"
    else
        log "ETCD包已存在，跳过下载"
    fi
    
    log "ETCD二进制文件下载完成"
}

# 下载CNI插件
download_cni_plugins() {
    log "下载CNI插件..."
    
    local cni_dir="$OFFLINE_PACKAGES_DIR/cni"
    cd "$cni_dir"
    
    local cni_version="1.3.0"
    local cni_package="cni-plugins-linux-amd64-v${cni_version}.tgz"
    
    if [ ! -f "cni-plugins.tgz" ]; then
        log "下载CNI插件 $cni_version..."
        wget -O cni-plugins.tgz "https://github.com/containernetworking/plugins/releases/download/v${cni_version}/$cni_package" || \
        curl -L -o cni-plugins.tgz "https://github.com/containernetworking/plugins/releases/download/v${cni_version}/$cni_package"
    else
        log "CNI插件包已存在，跳过下载"
    fi
    
    log "CNI插件下载完成"
}

# 下载crictl工具
download_crictl() {
    log "下载crictl工具..."
    
    local crictl_dir="$OFFLINE_PACKAGES_DIR/crictl"
    cd "$crictl_dir"
    
    local crictl_version="1.28.0"
    local crictl_package="crictl-v${crictl_version}-linux-amd64.tar.gz"
    
    if [ ! -f "crictl" ]; then
        log "下载crictl $crictl_version..."
        wget "https://github.com/kubernetes-sigs/cri-tools/releases/download/v${crictl_version}/$crictl_package" || \
        curl -L -O "https://github.com/kubernetes-sigs/cri-tools/releases/download/v${crictl_version}/$crictl_package"
        
        # 解压crictl
        tar -xzf "$crictl_package"
        rm "$crictl_package"
    else
        log "crictl已存在，跳过下载"
    fi
    
    log "crictl工具下载完成"
}

# 下载Calico配置文件
download_calico_manifests() {
    log "下载Calico配置文件..."
    
    local calico_dir="$OFFLINE_PACKAGES_DIR/calico"
    cd "$calico_dir"
    
    # 下载Calico operator
    if [ ! -f "tigera-operator.yaml" ]; then
        log "下载Calico Operator配置..."
        wget -O tigera-operator.yaml "https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml" || \
        curl -L -o tigera-operator.yaml "https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml"
    fi
    
    # 下载Calico custom resources
    if [ ! -f "custom-resources.yaml" ]; then
        log "下载Calico自定义资源配置..."
        wget -O custom-resources.yaml "https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/custom-resources.yaml" || \
        curl -L -o custom-resources.yaml "https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/custom-resources.yaml"
    fi
    
    # 下载完整的Calico配置
    if [ ! -f "calico.yaml" ]; then
        log "下载完整Calico配置..."
        wget -O calico.yaml "https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml" || \
        curl -L -o calico.yaml "https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
    fi
    
    log "Calico配置文件下载完成"
}

# 拉取并保存Docker镜像
pull_and_save_images() {
    log "拉取并保存Docker镜像..."
    
    # 检查Docker是否可用
    if ! command -v docker >/dev/null 2>&1; then
        log "警告: Docker未安装，跳过镜像下载"
        return 0
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log "警告: Docker服务未运行，跳过镜像下载"
        return 0
    fi
    
    cd "$OFFLINE_PACKAGES_DIR"
    
    log "拉取Kubernetes核心镜像..."
    for image in "${K8S_IMAGES[@]}"; do
        log "拉取镜像: $image"
        docker pull "$image" || log "警告: 拉取镜像失败 $image"
    done
    
    # 拉取测试镜像
    log "拉取测试镜像..."
    docker pull hello-world:latest || log "警告: 拉取hello-world镜像失败"
    docker pull busybox:1.28 || log "警告: 拉取busybox镜像失败"
    docker pull nicolaka/netshoot:latest || log "警告: 拉取netshoot镜像失败"
    
    # 保存所有K8s相关镜像
    log "保存Kubernetes镜像到tar文件..."
    local all_images=("${K8S_IMAGES[@]}" "hello-world:latest" "busybox:1.28" "nicolaka/netshoot:latest")
    docker save "${all_images[@]}" -o k8s-images.tar || log "警告: 保存镜像失败"
    
    # 单独保存Calico镜像
    log "保存Calico镜像到tar文件..."
    local calico_images=()
    for image in "${K8S_IMAGES[@]}"; do
        if [[ "$image" == *"calico"* ]] || [[ "$image" == *"tigera"* ]]; then
            calico_images+=("$image")
        fi
    done
    
    if [ ${#calico_images[@]} -gt 0 ]; then
        docker save "${calico_images[@]}" -o calico-images.tar || log "警告: 保存Calico镜像失败"
    fi
    
    # 保存测试镜像
    docker save hello-world:latest -o hello-world.tar || log "警告: 保存hello-world镜像失败"
    
    log "Docker镜像保存完成"
}

# 下载YUM包
download_yum_packages() {
    log "下载YUM软件包..."
    
    local yum_dir="$OFFLINE_PACKAGES_DIR/yum-packages"
    cd "$yum_dir"
    
    # 基础软件包列表
    local packages=(
        "wget"
        "curl"
        "net-tools"
        "telnet"
        "tree"
        "nmap"
        "sysstat"
        "lsof"
        "unzip"
        "git"
        "bind-utils"
        "bash-completion"
        "yum-utils"
        "device-mapper-persistent-data"
        "lvm2"
        "nfs-utils"
        "jq"
        "socat"
        "ipset"
        "conntrack"
        "ipvsadm"
    )
    
    # 使用yumdownloader下载包
    if command -v yumdownloader >/dev/null 2>&1; then
        for package in "${packages[@]}"; do
            log "下载软件包: $package"
            yumdownloader --resolve --destdir="$yum_dir" "$package" || log "警告: 下载失败 $package"
        done
    else
        log "警告: yumdownloader不可用，请手动下载YUM包"
        log "安装命令: yum install -y yum-utils"
        log "然后重新运行此脚本"
    fi
    
    log "YUM软件包下载完成"
}

# 下载HAProxy和Keepalived RPM包
download_lb_packages() {
    log "下载负载均衡软件包..."
    
    # HAProxy
    local haproxy_dir="$OFFLINE_PACKAGES_DIR/haproxy"
    cd "$haproxy_dir"
    
    if command -v yumdownloader >/dev/null 2>&1; then
        log "下载HAProxy包..."
        yumdownloader --resolve --destdir="$haproxy_dir" haproxy || log "警告: HAProxy下载失败"
    fi
    
    # Keepalived
    local keepalived_dir="$OFFLINE_PACKAGES_DIR/keepalived"
    cd "$keepalived_dir"
    
    if command -v yumdownloader >/dev/null 2>&1; then
        log "下载Keepalived包..."
        yumdownloader --resolve --destdir="$keepalived_dir" keepalived || log "警告: Keepalived下载失败"
    fi
    
    log "负载均衡软件包下载完成"
}

# 下载Worker节点工具
download_worker_tools() {
    log "下载Worker节点工具..."
    
    local tools_dir="$OFFLINE_PACKAGES_DIR/worker-tools"
    cd "$tools_dir"
    
    local tools=(
        "htop"
        "iotop"
        "iftop"
        "tcpdump"
        "strace"
        "nc"
    )
    
    if command -v yumdownloader >/dev/null 2>&1; then
        for tool in "${tools[@]}"; do
            log "下载工具: $tool"
            yumdownloader --resolve --destdir="$tools_dir" "$tool" || log "警告: 下载失败 $tool"
        done
    fi
    
    log "Worker节点工具下载完成"
}

# 创建离线包清单
create_package_manifest() {
    log "创建离线包清单..."
    
    local manifest_file="$OFFLINE_PACKAGES_DIR/package-manifest.txt"
    
    cat > "$manifest_file" << EOF
Kubernetes高可用集群离线安装包清单
=============================================================================
生成时间: $(date)
Kubernetes版本: $K8S_VERSION
Docker版本: $DOCKER_VERSION
ETCD版本: $ETCD_VERSION

目录结构:
EOF

    # 遍历所有目录并统计文件
    find "$OFFLINE_PACKAGES_DIR" -type f | while read -r file; do
        local size=$(du -h "$file" | cut -f1)
        echo "  $file ($size)" >> "$manifest_file"
    done
    
    cat >> "$manifest_file" << EOF

使用说明:
1. 将整个 offline-packages 目录复制到目标环境
2. 修改 config.sh 中的节点配置
3. 在目标环境执行部署脚本

验证命令:
  du -sh $OFFLINE_PACKAGES_DIR
  find $OFFLINE_PACKAGES_DIR -name "*.tar" -exec ls -lh {} \;

=============================================================================
EOF

    log "离线包清单创建完成: $manifest_file"
}

# 验证下载的包
verify_packages() {
    log "验证下载的包..."
    
    # 检查必要的二进制文件
    local required_files=(
        "$OFFLINE_PACKAGES_DIR/kubernetes/kubeadm"
        "$OFFLINE_PACKAGES_DIR/kubernetes/kubelet"
        "$OFFLINE_PACKAGES_DIR/kubernetes/kubectl"
        "$OFFLINE_PACKAGES_DIR/docker/docker-${DOCKER_VERSION}.tgz"
        "$OFFLINE_PACKAGES_DIR/etcd/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
    )
    
    local missing_files=0
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log "警告: 缺少必要文件 $file"
            ((missing_files++))
        fi
    done
    
    # 检查镜像文件
    if [ -f "$OFFLINE_PACKAGES_DIR/k8s-images.tar" ]; then
        local image_size=$(du -h "$OFFLINE_PACKAGES_DIR/k8s-images.tar" | cut -f1)
        log "镜像包大小: $image_size"
    else
        log "警告: 缺少镜像包 k8s-images.tar"
        ((missing_files++))
    fi
    
    # 显示总体统计
    local total_size=$(du -sh "$OFFLINE_PACKAGES_DIR" | cut -f1)
    log "离线包总大小: $total_size"
    
    if [ $missing_files -eq 0 ]; then
        log "✓ 所有必要文件验证通过"
    else
        log "⚠ 发现 $missing_files 个缺失文件，请检查网络连接后重新下载"
    fi
    
    log "包验证完成"
}

# 打包离线安装包
create_offline_bundle() {
    log "创建离线安装包..."
    
    local bundle_name="k8s-ha-offline-$(date +%Y%m%d).tar.gz"
    local bundle_path="$(dirname "$OFFLINE_PACKAGES_DIR")/$bundle_name"
    
    cd "$(dirname "$OFFLINE_PACKAGES_DIR")"
    
    log "正在压缩离线包，这可能需要几分钟..."
    tar -czf "$bundle_path" "$(basename "$OFFLINE_PACKAGES_DIR")" "$SCRIPT_DIR"/*.sh
    
    if [ -f "$bundle_path" ]; then
        local bundle_size=$(du -h "$bundle_path" | cut -f1)
        log "离线安装包创建完成: $bundle_path ($bundle_size)"
        log "传输到目标环境后解压: tar -xzf $bundle_name"
    else
        log "警告: 离线安装包创建失败"
    fi
}

# 显示下载摘要
show_download_summary() {
    cat << EOF

=============================================================================
离线安装包准备完成
=============================================================================

下载目录: $OFFLINE_PACKAGES_DIR
总大小: $(du -sh "$OFFLINE_PACKAGES_DIR" | cut -f1)

包含内容:
- Kubernetes v$K8S_VERSION 二进制文件
- Docker v$DOCKER_VERSION 相关文件
- ETCD v$ETCD_VERSION 集群组件
- Calico网络插件配置文件
- 系统基础软件包
- Docker镜像包

下一步操作:
1. 将 $OFFLINE_PACKAGES_DIR 目录复制到目标环境
2. 修改 config.sh 配置文件中的节点信息
3. 在目标环境执行部署: bash install-k8s-ha.sh install-all

离线传输建议:
- 压缩包: 使用 tar -czf 命令创建压缩包
- U盘传输: 分割大文件 split -b 4G
- 网络传输: 使用 rsync 或 scp 命令

=============================================================================
EOF
}

# 主函数
main() {
    log "=== 开始准备Kubernetes高可用集群离线安装包 ==="
    
    # 检查网络连接
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log "警告: 网络连接不可用，某些下载可能失败"
    fi
    
    # 检查必要工具
    local required_tools=("wget" "curl" "tar" "gzip")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error_exit "缺少必要工具: $tool，请先安装"
        fi
    done
    
    # 执行下载任务
    create_download_directories
    download_kubernetes_binaries
    download_docker_binaries
    download_etcd_binaries
    download_cni_plugins
    download_crictl
    download_calico_manifests
    pull_and_save_images
    download_yum_packages
    download_lb_packages
    download_worker_tools
    create_package_manifest
    verify_packages
    
    # 可选：创建压缩包
    read -p "是否创建压缩的离线安装包? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        create_offline_bundle
    fi
    
    show_download_summary
    
    log "=== 离线安装包准备完成 ==="
    log "请将离线包传输到目标环境后开始部署"
}

# 执行主函数
main "$@"