#!/bin/bash

# =============================================================================
# Load Balancer Setup Script for Kubernetes HA Cluster
# CentOS 7 Offline Deployment - Step 4
# =============================================================================

set -euo pipefail

# 获取脚本目录并加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log "开始配置负载均衡器..."

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

# 安装HAProxy
install_haproxy() {
    log "安装HAProxy..."
    
    local haproxy_pkg_dir="$OFFLINE_PACKAGES_DIR/haproxy"
    
    if [ -d "$haproxy_pkg_dir" ] && [ -f "$haproxy_pkg_dir/haproxy.rpm" ]; then
        log "使用离线HAProxy包安装..."
        rpm -ivh "$haproxy_pkg_dir/haproxy.rpm" --force --nodeps
    else
        log "从系统源安装HAProxy..."
        yum install -y haproxy || error_exit "HAProxy安装失败"
    fi
    
    log "HAProxy安装完成"
}

# 配置HAProxy
configure_haproxy() {
    log "配置HAProxy..."
    
    # 备份原配置文件
    if [ -f /etc/haproxy/haproxy.cfg ]; then
        cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.$(date +%Y%m%d)
    fi
    
    # 创建HAProxy配置文件
    cat > /etc/haproxy/haproxy.cfg << EOF
#---------------------------------------------------------------------
# HAProxy configuration for Kubernetes API Server HA
#---------------------------------------------------------------------

global
    log         127.0.0.1:514 local0
    chroot      /var/lib/haproxy
    stats socket /var/lib/haproxy/stats
    user        haproxy
    group       haproxy
    daemon
    
    # SSL/TLS configuration
    ssl-default-bind-ciphers ECDHE+AESGCM:ECDHE+AES256:ECDHE+AES128:!aNULL:!MD5:!DSS
    ssl-default-bind-options no-sslv3

defaults
    mode                    http
    log                     global
    option                  httplog
    option                  dontlognull
    option                  http-server-close
    option                  forwardfor       except 127.0.0.0/8
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m
    timeout http-keep-alive 10s
    timeout check           10s
    maxconn                 3000

#---------------------------------------------------------------------
# Statistics page
#---------------------------------------------------------------------
listen stats
    bind *:${HAPROXY_STATS_PORT}
    stats enable
    stats uri /stats
    stats refresh 5s
    stats realm HAProxy\ Statistics
    stats auth ${HAPROXY_STATS_USER}:${HAPROXY_STATS_PASS}
    stats admin if TRUE

#---------------------------------------------------------------------
# Kubernetes API Server Load Balancer
#---------------------------------------------------------------------
frontend k8s-api-frontend
    bind *:${LB_PORT}
    mode tcp
    option tcplog
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check connect port 6443
EOF

    # 添加Master节点到后端
    local backend_servers=""
    for node in "${MASTER_NODES[@]}"; do
        node_name=$(echo "$node" | cut -d: -f1)
        node_ip=$(echo "$node" | cut -d: -f2)
        backend_servers+="\n    server $node_name $node_ip:6443 check inter 2000 rise 2 fall 3"
    done
    
    echo -e "$backend_servers" >> /etc/haproxy/haproxy.cfg
    
    log "HAProxy配置完成"
}

# 安装Keepalived
install_keepalived() {
    log "安装Keepalived..."
    
    local keepalived_pkg_dir="$OFFLINE_PACKAGES_DIR/keepalived"
    
    if [ -d "$keepalived_pkg_dir" ] && [ -f "$keepalived_pkg_dir/keepalived.rpm" ]; then
        log "使用离线Keepalived包安装..."
        rpm -ivh "$keepalived_pkg_dir/keepalived.rpm" --force --nodeps
    else
        log "从系统源安装Keepalived..."
        yum install -y keepalived || error_exit "Keepalived安装失败"
    fi
    
    log "Keepalived安装完成"
}

# 配置Keepalived
configure_keepalived() {
    log "配置Keepalived..."
    
    # 备份原配置文件
    if [ -f /etc/keepalived/keepalived.conf ]; then
        cp /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.backup.$(date +%Y%m%d)
    fi
    
    # 确定节点优先级
    local priority=100
    local state="BACKUP"
    
    # 第一个Master节点设为MASTER
    local first_master_ip=$(echo "${MASTER_NODES[0]}" | cut -d: -f2)
    if [[ "$LOCAL_IP" == "$first_master_ip" ]]; then
        state="MASTER"
        priority=110
    else
        # 其他节点根据IP确定优先级
        for i in "${!MASTER_NODES[@]}"; do
            node_ip=$(echo "${MASTER_NODES[$i]}" | cut -d: -f2)
            if [[ "$node_ip" == "$LOCAL_IP" ]]; then
                priority=$((105 - i))
                break
            fi
        done
    fi
    
    log "节点状态: $state, 优先级: $priority"
    
    # 创建Keepalived配置文件
    cat > /etc/keepalived/keepalived.conf << EOF
! Configuration File for keepalived

global_defs {
    router_id LVS_DEVEL_${KEEPALIVED_ROUTER_ID}
    vrrp_skip_check_adv_addr
    vrrp_strict
    vrrp_garp_interval 0
    vrrp_gna_interval 0
    script_user root
    enable_script_security
}

# 健康检查脚本
vrrp_script chk_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 3
    weight -2
    fall 2
    rise 1
}

vrrp_instance VI_1 {
    state ${state}
    interface ${KEEPALIVED_INTERFACE}
    virtual_router_id ${KEEPALIVED_ROUTER_ID}
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k8s-ha-pass
    }
    virtual_ipaddress {
        ${VIP}
    }
    track_script {
        chk_haproxy
    }
}
EOF

    log "Keepalived配置完成"
}

# 创建HAProxy健康检查脚本
create_health_check_script() {
    log "创建HAProxy健康检查脚本..."
    
    cat > /etc/keepalived/check_haproxy.sh << 'EOF'
#!/bin/bash

# HAProxy健康检查脚本
# 检查HAProxy进程是否运行，以及是否能正常处理请求

# 检查HAProxy进程
if ! pgrep -x haproxy > /dev/null; then
    echo "HAProxy进程未运行"
    exit 1
fi

# 检查HAProxy统计接口
if ! curl -s "http://localhost:__HAPROXY_STATS_PORT__/stats" > /dev/null; then
    echo "HAProxy统计接口不可访问"
    exit 1
fi

# 检查HAProxy是否监听API端口
if ! netstat -tlnp | grep -q ":__LB_PORT__.*haproxy"; then
    echo "HAProxy未监听API端口"
    exit 1
fi

echo "HAProxy健康检查通过"
exit 0
EOF

    # 替换变量
    sed -i "s/__HAPROXY_STATS_PORT__/$HAPROXY_STATS_PORT/g" /etc/keepalived/check_haproxy.sh
    sed -i "s/__LB_PORT__/$LB_PORT/g" /etc/keepalived/check_haproxy.sh
    
    chmod +x /etc/keepalived/check_haproxy.sh
    
    log "健康检查脚本创建完成"
}

# 配置rsyslog（用于HAProxy日志）
configure_rsyslog() {
    log "配置rsyslog..."
    
    # 添加HAProxy日志配置
    cat >> /etc/rsyslog.conf << EOF

# HAProxy log configuration
\$ModLoad imudp
\$UDPServerRun 514
\$UDPServerAddress 127.0.0.1
local0.*    /var/log/haproxy.log
& stop
EOF

    # 重启rsyslog服务
    systemctl restart rsyslog
    
    log "rsyslog配置完成"
}

# 启动服务
start_services() {
    log "启动负载均衡服务..."
    
    # 重新加载systemd
    systemctl daemon-reload
    
    # 启动HAProxy
    systemctl enable haproxy
    systemctl start haproxy
    
    # 等待HAProxy启动
    sleep 3
    
    # 检查HAProxy状态
    if systemctl is-active --quiet haproxy; then
        log "HAProxy服务启动成功"
    else
        error_exit "HAProxy服务启动失败"
    fi
    
    # 启动Keepalived
    systemctl enable keepalived
    systemctl start keepalived
    
    # 等待Keepalived启动
    sleep 3
    
    # 检查Keepalived状态
    if systemctl is-active --quiet keepalived; then
        log "Keepalived服务启动成功"
    else
        error_exit "Keepalived服务启动失败"
    fi
    
    log "负载均衡服务启动完成"
}

# 验证负载均衡配置
verify_loadbalancer() {
    log "验证负载均衡配置..."
    
    # 检查HAProxy进程
    if pgrep -x haproxy > /dev/null; then
        log "HAProxy进程运行正常"
    else
        error_exit "HAProxy进程未运行"
    fi
    
    # 检查Keepalived进程
    if pgrep -x keepalived > /dev/null; then
        log "Keepalived进程运行正常"
    else
        error_exit "Keepalived进程未运行"
    fi
    
    # 检查端口监听
    if netstat -tlnp | grep -q ":$LB_PORT"; then
        log "HAProxy正在监听端口 $LB_PORT"
    else
        error_exit "HAProxy未监听端口 $LB_PORT"
    fi
    
    if netstat -tlnp | grep -q ":$HAPROXY_STATS_PORT"; then
        log "HAProxy统计页面监听端口 $HAPROXY_STATS_PORT"
    else
        log "警告: HAProxy统计页面端口未监听"
    fi
    
    # 检查VIP状态
    if ip addr show | grep -q "$VIP"; then
        log "VIP $VIP 已绑定到本机"
        log "当前节点为MASTER节点"
    else
        log "VIP $VIP 未绑定到本机"
        log "当前节点为BACKUP节点"
    fi
    
    log "负载均衡配置验证完成"
}

# 显示配置信息
show_loadbalancer_info() {
    cat << EOF

=============================================================================
负载均衡配置完成
=============================================================================

配置信息:
- VIP地址: $VIP
- API端口: $LB_PORT
- 统计页面: http://$LOCAL_IP:$HAPROXY_STATS_PORT/stats
- 统计页面用户: $HAPROXY_STATS_USER/$HAPROXY_STATS_PASS

Master节点:
EOF
    for node in "${MASTER_NODES[@]}"; do
        echo "  - $node"
    done
    
    cat << EOF

服务状态:
- HAProxy: $(systemctl is-active haproxy)
- Keepalived: $(systemctl is-active keepalived)

检查命令:
  systemctl status haproxy
  systemctl status keepalived
  ip addr show | grep $VIP

配置文件:
  HAProxy: /etc/haproxy/haproxy.cfg
  Keepalived: /etc/keepalived/keepalived.conf

=============================================================================
EOF
}

# 主函数
main() {
    log "=== 开始配置负载均衡器 ==="
    
    # 检查是否为Master节点
    if ! is_master_node; then
        log "当前节点不是Master节点，跳过负载均衡配置"
        return 0
    fi
    
    log "当前节点是Master节点，开始配置负载均衡..."
    
    # 检查网络接口
    if ! ip link show "$KEEPALIVED_INTERFACE" >/dev/null 2>&1; then
        error_exit "网络接口 $KEEPALIVED_INTERFACE 不存在，请检查config.sh中的配置"
    fi
    
    # 执行配置步骤
    install_haproxy
    configure_haproxy
    install_keepalived
    configure_keepalived
    create_health_check_script
    configure_rsyslog
    start_services
    verify_loadbalancer
    show_loadbalancer_info
    
    log "=== 负载均衡器配置完成 ==="
    log "请在所有Master节点执行此脚本"
    log "等待所有Master节点配置完成后，其中一台会获得VIP"
}

# 执行主函数
main "$@"