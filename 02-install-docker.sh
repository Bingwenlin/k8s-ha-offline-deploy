#!/bin/bash

# =============================================================================
# Docker Installation Script for Kubernetes HA Cluster
# CentOS 7 Offline Deployment - Step 2
# =============================================================================

set -euo pipefail

# 获取脚本目录并加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log "开始安装Docker..."

# 卸载旧版本Docker
remove_old_docker() {
    log "卸载旧版本Docker..."
    
    yum remove -y \
        docker \
        docker-client \
        docker-client-latest \
        docker-common \
        docker-latest \
        docker-latest-logrotate \
        docker-logrotate \
        docker-engine \
        containerd \
        runc 2>/dev/null || true
    
    log "旧版本Docker已卸载"
}

# 安装Docker
install_docker() {
    log "安装Docker $DOCKER_VERSION..."
    
    local docker_pkg_dir="$OFFLINE_PACKAGES_DIR/docker"
    
    if [ -d "$docker_pkg_dir" ]; then
        log "使用离线Docker包安装..."
        
        # 解压Docker二进制文件
        if [ -f "$docker_pkg_dir/docker-${DOCKER_VERSION}.tgz" ]; then
            cd "$docker_pkg_dir"
            tar -xzf "docker-${DOCKER_VERSION}.tgz"
            
            # 复制Docker二进制文件
            cp docker/* /usr/bin/
            chmod +x /usr/bin/docker*
            
            log "Docker二进制文件安装完成"
        else
            error_exit "Docker离线包不存在: $docker_pkg_dir/docker-${DOCKER_VERSION}.tgz"
        fi
        
        # 安装containerd
        if [ -f "$docker_pkg_dir/containerd.tar.gz" ]; then
            cd "$docker_pkg_dir"
            tar -xzf containerd.tar.gz -C /usr/bin/ --strip-components=1
            chmod +x /usr/bin/containerd*
            log "containerd安装完成"
        fi
        
        # 安装runc
        if [ -f "$docker_pkg_dir/runc" ]; then
            cp "$docker_pkg_dir/runc" /usr/bin/
            chmod +x /usr/bin/runc
            log "runc安装完成"
        fi
        
    else
        error_exit "Docker离线包目录不存在: $docker_pkg_dir"
    fi
}

# 配置Docker
configure_docker() {
    log "配置Docker..."
    
    # 创建Docker配置目录
    ensure_dir "/etc/docker"
    
    # 配置Docker daemon
    cat > /etc/docker/daemon.json << EOF
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "10"
    },
    "storage-driver": "overlay2",
    "storage-opts": [
        "overlay2.override_kernel_check=true"
    ],
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com",
        "https://registry.docker-cn.com"
    ],
    "insecure-registries": [
        "127.0.0.1/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16"
    ],
    "live-restore": true,
    "max-concurrent-downloads": 10,
    "max-concurrent-uploads": 5,
    "data-root": "/var/lib/docker"
}
EOF
    
    log "Docker配置文件创建完成"
}

# 创建Docker systemd服务
create_docker_service() {
    log "创建Docker systemd服务..."
    
    cat > /etc/systemd/system/docker.service << EOF
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service containerd.service
Wants=network-online.target
Requires=containerd.service

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

    log "Docker服务文件创建完成"
}

# 创建containerd systemd服务
create_containerd_service() {
    log "创建containerd systemd服务..."
    
    cat > /etc/systemd/system/containerd.service << EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

    log "containerd服务文件创建完成"
}

# 配置containerd
configure_containerd() {
    log "配置containerd..."
    
    # 创建containerd配置目录
    ensure_dir "/etc/containerd"
    
    # 生成默认配置
    containerd config default > /etc/containerd/config.toml
    
    # 修改配置以使用systemd cgroup driver
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    
    # 配置镜像加速
    sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry.mirrors\]/a\        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]\n          endpoint = ["https://mirror.ccs.tencentyun.com", "https://registry-1.docker.io"]' /etc/containerd/config.toml
    
    log "containerd配置完成"
}

# 启动Docker服务
start_docker_services() {
    log "启动Docker相关服务..."
    
    # 重新加载systemd
    systemctl daemon-reload
    
    # 启动containerd服务
    systemctl enable containerd
    systemctl start containerd
    
    # 等待containerd启动
    sleep 5
    
    # 启动Docker服务
    systemctl enable docker
    systemctl start docker
    
    # 等待Docker启动
    sleep 5
    
    log "Docker服务启动完成"
}

# 验证Docker安装
verify_docker_installation() {
    log "验证Docker安装..."
    
    # 检查Docker版本
    if docker version >/dev/null 2>&1; then
        local docker_version=$(docker version --format '{{.Server.Version}}')
        log "Docker版本: $docker_version"
    else
        error_exit "Docker启动失败"
    fi
    
    # 检查containerd状态
    if systemctl is-active --quiet containerd; then
        log "containerd服务运行正常"
    else
        error_exit "containerd服务启动失败"
    fi
    
    # 检查Docker服务状态
    if systemctl is-active --quiet docker; then
        log "Docker服务运行正常"
    else
        error_exit "Docker服务启动失败"
    fi
    
    # 运行测试容器（如果有离线镜像）
    local test_image_tar="$OFFLINE_PACKAGES_DIR/hello-world.tar"
    if [ -f "$test_image_tar" ]; then
        log "加载测试镜像..."
        docker load -i "$test_image_tar"
        
        log "运行测试容器..."
        if docker run --rm hello-world >/dev/null 2>&1; then
            log "Docker测试通过"
        else
            log "警告: Docker测试失败，但Docker服务正常运行"
        fi
    else
        log "跳过容器测试（无测试镜像）"
    fi
    
    log "Docker安装验证完成"
}

# 加载K8s镜像
load_k8s_images() {
    log "加载Kubernetes镜像..."
    
    local images_tar="$OFFLINE_PACKAGES_DIR/k8s-images.tar"
    
    if [ -f "$images_tar" ]; then
        log "加载K8s镜像包: $images_tar"
        docker load -i "$images_tar"
        
        # 显示已加载的镜像
        log "已加载的镜像:"
        docker images | grep -E "(k8s|calico|coredns|etcd|pause)" || true
        
        log "Kubernetes镜像加载完成"
    else
        log "警告: K8s镜像包不存在: $images_tar"
        log "请确保已准备好所需的镜像"
    fi
}

# 配置Docker用户组
configure_docker_group() {
    log "配置Docker用户组..."
    
    # 创建docker用户组
    groupadd -f docker
    
    # 将当前用户添加到docker组（如果不是root用户）
    if [ "$USER" != "root" ] && [ -n "$USER" ]; then
        usermod -aG docker "$USER"
        log "用户 $USER 已添加到docker组"
    fi
    
    log "Docker用户组配置完成"
}

# 优化Docker性能
optimize_docker() {
    log "优化Docker性能..."
    
    # 创建Docker日志轮转配置
    cat > /etc/logrotate.d/docker << EOF
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    size=1M
    missingok
    delaycompress
    copytruncate
}
EOF
    
    # 设置Docker数据目录权限
    chmod 700 /var/lib/docker
    
    log "Docker性能优化完成"
}

# 主函数
main() {
    log "=== 开始安装Docker ==="
    
    # 检查是否已安装Docker
    if command -v docker >/dev/null 2>&1; then
        local installed_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        log "检测到已安装的Docker版本: $installed_version"
        
        read -p "是否重新安装Docker? (y/n): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "跳过Docker安装"
            return 0
        fi
    fi
    
    # 执行Docker安装步骤
    remove_old_docker
    install_docker
    configure_docker
    create_containerd_service
    configure_containerd
    create_docker_service
    start_docker_services
    configure_docker_group
    optimize_docker
    verify_docker_installation
    load_k8s_images
    
    log "=== Docker安装完成 ==="
    log "Docker版本: $(docker version --format '{{.Server.Version}}')"
    log "请在所有节点执行此脚本"
}

# 执行主函数
main "$@"