#!/bin/bash

# =============================================================================
# Kubernetes High Availability Cluster Installer
# CentOS 7 Offline Deployment Main Script
# =============================================================================

set -euo pipefail

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载配置文件
source "$SCRIPT_DIR/config.sh"

# 显示帮助信息
show_help() {
    cat << EOF
Kubernetes高可用集群离线部署脚本

用法: $0 [选项] [动作]

动作:
  prepare-offline     准备离线安装包（在有网络的机器上执行）
  check-env          检查环境准备情况
  install-all        完整安装（推荐）
  install-step       分步安装
  
分步安装选项:
  system-init        系统初始化
  install-docker     安装Docker
  install-k8s        安装K8s组件
  setup-lb           配置负载均衡
  setup-etcd         配置ETCD集群
  init-masters       初始化Master节点
  join-workers       加入Worker节点
  install-cni        安装网络插件
  
选项:
  -h, --help         显示此帮助信息
  -v, --verbose      详细输出
  --skip-check       跳过环境检查
  --force           强制执行（谨慎使用）

示例:
  $0 prepare-offline              # 准备离线包
  $0 check-env                    # 检查环境
  $0 install-all                  # 完整安装
  $0 install-step system-init     # 仅执行系统初始化

EOF
}

# 检查运行权限
check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本需要root权限运行，请使用sudo"
    fi
}

# 检查环境准备情况
check_environment() {
    log "开始环境检查..."
    
    # 检查操作系统
    if [ ! -f /etc/redhat-release ] || ! grep -q "CentOS Linux release 7" /etc/redhat-release; then
        error_exit "此脚本仅支持CentOS 7"
    fi
    
    # 检查必要目录
    ensure_dir "$INSTALL_DIR"
    ensure_dir "$PKG_DIR"
    ensure_dir "$OFFLINE_PACKAGES_DIR"
    
    # 检查离线安装包
    if [ ! -d "$OFFLINE_PACKAGES_DIR" ] || [ -z "$(ls -A $OFFLINE_PACKAGES_DIR)" ]; then
        error_exit "离线安装包目录为空，请先执行 prepare-offline 准备离线包"
    fi
    
    # 检查节点连通性
    log "检查节点连通性..."
    for node in "${MASTER_NODES[@]}" "${WORKER_NODES[@]}"; do
        node_ip=$(echo "$node" | cut -d: -f2)
        check_node_connectivity "$node_ip"
    done
    
    log "环境检查完成"
}

# 准备离线安装包
prepare_offline_packages() {
    log "开始准备离线安装包..."
    
    if [ ! -f "$SCRIPT_DIR/download-packages.sh" ]; then
        error_exit "下载脚本不存在: $SCRIPT_DIR/download-packages.sh"
    fi
    
    bash "$SCRIPT_DIR/download-packages.sh"
    
    log "离线安装包准备完成"
}

# 执行分步安装
execute_step() {
    local step="$1"
    local script_file=""
    
    case "$step" in
        system-init)
            script_file="01-system-init.sh"
            ;;
        install-docker)
            script_file="02-install-docker.sh"
            ;;
        install-k8s)
            script_file="03-install-k8s.sh"
            ;;
        setup-lb)
            script_file="04-setup-loadbalancer.sh"
            ;;
        setup-etcd)
            script_file="05-setup-etcd.sh"
            ;;
        init-masters)
            script_file="06-init-masters.sh"
            ;;
        join-workers)
            script_file="07-join-workers.sh"
            ;;
        install-cni)
            script_file="08-install-cni.sh"
            ;;
        *)
            error_exit "未知的安装步骤: $step"
            ;;
    esac
    
    local script_path="$SCRIPT_DIR/$script_file"
    if [ ! -f "$script_path" ]; then
        error_exit "脚本文件不存在: $script_path"
    fi
    
    log "执行安装步骤: $step ($script_file)"
    
    if ! bash "$script_path"; then
        error_exit "安装步骤 $step 执行失败"
    fi
    
    log "安装步骤 $step 执行完成"
}

# 完整安装
install_all() {
    log "开始Kubernetes高可用集群完整安装..."
    
    local steps=(
        "system-init"
        "install-docker"
        "install-k8s"
        "setup-lb"
        "setup-etcd"
        "init-masters"
        "join-workers"
        "install-cni"
    )
    
    for step in "${steps[@]}"; do
        execute_step "$step"
    done
    
    log "Kubernetes高可用集群安装完成！"
    log "可以通过以下命令验证集群状态:"
    log "  kubectl get nodes"
    log "  kubectl get pods -A"
    log "  kubectl cluster-info"
}

# 显示集群信息
show_cluster_info() {
    cat << EOF

=============================================================================
Kubernetes高可用集群部署完成
=============================================================================

集群信息:
- 集群名称: $CLUSTER_NAME
- K8s版本: $K8S_VERSION
- VIP地址: $VIP:$LB_PORT

Master节点:
EOF
    for node in "${MASTER_NODES[@]}"; do
        echo "  - $node"
    done
    
    cat << EOF

Worker节点:
EOF
    for node in "${WORKER_NODES[@]}"; do
        echo "  - $node"
    done
    
    cat << EOF

验证命令:
  kubectl get nodes
  kubectl get pods -A
  kubectl cluster-info

配置文件位置:
  kubeconfig: /etc/kubernetes/admin.conf
  
日志文件: $LOG_FILE

=============================================================================
EOF
}

# 主函数
main() {
    local action=""
    local step=""
    local skip_check=false
    local force=false
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                set -x
                shift
                ;;
            --skip-check)
                skip_check=true
                shift
                ;;
            --force)
                force=true
                shift
                ;;
            prepare-offline|check-env|install-all|install-step)
                action="$1"
                shift
                if [[ "$action" == "install-step" && $# -gt 0 ]]; then
                    step="$1"
                    shift
                fi
                ;;
            *)
                error_exit "未知参数: $1"
                ;;
        esac
    done
    
    # 检查必要参数
    if [[ -z "$action" ]]; then
        show_help
        exit 1
    fi
    
    # 检查运行权限
    if [[ "$action" != "prepare-offline" ]]; then
        check_privileges
    fi
    
    # 初始化日志
    log "开始执行: $action $step"
    log "脚本目录: $SCRIPT_DIR"
    
    # 执行对应动作
    case "$action" in
        prepare-offline)
            prepare_offline_packages
            ;;
        check-env)
            check_environment
            ;;
        install-all)
            if [[ "$skip_check" != true ]]; then
                check_environment
            fi
            install_all
            show_cluster_info
            ;;
        install-step)
            if [[ -z "$step" ]]; then
                error_exit "install-step 需要指定步骤名称"
            fi
            if [[ "$skip_check" != true ]]; then
                check_environment
            fi
            execute_step "$step"
            ;;
        *)
            error_exit "未知动作: $action"
            ;;
    esac
    
    log "脚本执行完成"
}

# 捕获信号，清理环境
trap 'echo "脚本被中断"; exit 1' INT TERM

# 执行主函数
main "$@"