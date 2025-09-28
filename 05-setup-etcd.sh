#!/bin/bash

# =============================================================================
# ETCD Cluster Setup Script for Kubernetes HA Cluster
# CentOS 7 Offline Deployment - Step 5
# =============================================================================

set -euo pipefail

# 获取脚本目录并加载配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

log "开始配置ETCD集群..."

# 获取本机IP
LOCAL_IP=$(get_local_ip)
log "本机IP: $LOCAL_IP"

# 获取本机hostname
LOCAL_HOSTNAME=$(hostname)
log "本机hostname: $LOCAL_HOSTNAME"

# 检查是否为ETCD节点
is_etcd_node() {
    for node in "${ETCD_NODES[@]}"; do
        node_ip=$(echo "$node" | cut -d: -f2)
        if [[ "$node_ip" == "$LOCAL_IP" ]]; then
            return 0
        fi
    done
    return 1
}

# 获取ETCD节点名称
get_etcd_node_name() {
    for node in "${ETCD_NODES[@]}"; do
        node_name=$(echo "$node" | cut -d: -f1)
        node_ip=$(echo "$node" | cut -d: -f2)
        if [[ "$node_ip" == "$LOCAL_IP" ]]; then
            echo "$node_name"
            return 0
        fi
    done
    echo "$LOCAL_HOSTNAME"
}

# 安装ETCD
install_etcd() {
    log "安装ETCD..."
    
    local etcd_pkg_dir="$OFFLINE_PACKAGES_DIR/etcd"
    
    if [ ! -d "$etcd_pkg_dir" ]; then
        error_exit "ETCD离线包目录不存在: $etcd_pkg_dir"
    fi
    
    # 解压ETCD二进制文件
    if [ -f "$etcd_pkg_dir/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz" ]; then
        cd "$etcd_pkg_dir"
        tar -xzf "etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
        
        # 复制ETCD二进制文件
        cp "etcd-v${ETCD_VERSION}-linux-amd64/etcd" /usr/bin/
        cp "etcd-v${ETCD_VERSION}-linux-amd64/etcdctl" /usr/bin/
        
        chmod +x /usr/bin/etcd*
        
        log "ETCD二进制文件安装完成"
    else
        error_exit "ETCD离线包不存在: $etcd_pkg_dir/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
    fi
}

# 创建ETCD用户和目录
create_etcd_user_and_dirs() {
    log "创建ETCD用户和目录..."
    
    # 创建etcd用户
    id etcd &>/dev/null || useradd -r -s /sbin/nologin etcd
    
    # 创建必要目录
    local etcd_dirs=(
        "/etc/etcd"
        "/var/lib/etcd"
        "/etc/etcd/ssl"
    )
    
    for dir in "${etcd_dirs[@]}"; do
        ensure_dir "$dir"
        chown etcd:etcd "$dir"
        chmod 755 "$dir"
    done
    
    log "ETCD用户和目录创建完成"
}

# 生成ETCD证书
generate_etcd_certificates() {
    log "生成ETCD证书..."
    
    local ssl_dir="/etc/etcd/ssl"
    local temp_dir="/tmp/etcd-certs"
    
    ensure_dir "$temp_dir"
    cd "$temp_dir"
    
    # 检查是否已有证书
    if [ -f "$ssl_dir/ca.pem" ] && [ -f "$ssl_dir/etcd.pem" ]; then
        log "ETCD证书已存在，跳过生成"
        return 0
    fi
    
    # 生成CA证书
    if [ ! -f "$ssl_dir/ca.pem" ]; then
        log "生成ETCD CA证书..."
        
        cat > ca-config.json << EOF
{
    "signing": {
        "default": {
            "expiry": "87600h"
        },
        "profiles": {
            "etcd": {
                "expiry": "87600h",
                "usages": [
                    "signing",
                    "key encipherment",
                    "server auth",
                    "client auth"
                ]
            }
        }
    }
}
EOF

        cat > ca-csr.json << EOF
{
    "CN": "etcd CA",
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "L": "Beijing",
            "ST": "Beijing",
            "O": "etcd",
            "OU": "etcd Security"
        }
    ]
}
EOF

        # 如果没有cfssl工具，使用openssl生成证书
        if ! command -v cfssl &> /dev/null; then
            log "使用openssl生成证书..."
            generate_etcd_certs_with_openssl
        else
            cfssl gencert -initca ca-csr.json | cfssljson -bare ca
            cp ca.pem ca-key.pem "$ssl_dir/"
        fi
    fi
    
    # 生成ETCD服务器证书
    if [ ! -f "$ssl_dir/etcd.pem" ]; then
        log "生成ETCD服务器证书..."
        
        # 构建SAN列表
        local sans=""
        for node in "${ETCD_NODES[@]}"; do
            node_name=$(echo "$node" | cut -d: -f1)
            node_ip=$(echo "$node" | cut -d: -f2)
            sans="${sans},\"${node_name}\",\"${node_ip}\""
        done
        sans="\"localhost\",\"127.0.0.1\"${sans}"
        
        if command -v cfssl &> /dev/null; then
            cat > etcd-csr.json << EOF
{
    "CN": "etcd",
    "hosts": [
        ${sans}
    ],
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "L": "Beijing",
            "ST": "Beijing",
            "O": "etcd",
            "OU": "etcd Security"
        }
    ]
}
EOF
            
            cfssl gencert -ca="$ssl_dir/ca.pem" -ca-key="$ssl_dir/ca-key.pem" -config=ca-config.json -profile=etcd etcd-csr.json | cfssljson -bare etcd
            cp etcd.pem etcd-key.pem "$ssl_dir/"
        fi
    fi
    
    # 设置证书权限
    chown -R etcd:etcd "$ssl_dir"
    chmod 600 "$ssl_dir"/*.pem
    
    # 清理临时文件
    rm -rf "$temp_dir"
    
    log "ETCD证书生成完成"
}

# 使用openssl生成ETCD证书
generate_etcd_certs_with_openssl() {
    log "使用openssl生成ETCD证书..."
    
    local ssl_dir="/etc/etcd/ssl"
    
    # 生成CA私钥
    openssl genrsa -out ca-key.pem 2048
    
    # 生成CA证书
    openssl req -new -x509 -days 3650 -key ca-key.pem -out ca.pem -subj "/CN=etcd-ca/O=etcd/C=CN"
    
    # 生成etcd私钥
    openssl genrsa -out etcd-key.pem 2048
    
    # 创建证书签名请求
    openssl req -new -key etcd-key.pem -out etcd.csr -subj "/CN=etcd/O=etcd/C=CN"
    
    # 创建扩展文件
    cat > etcd.ext << EOF
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF
    
    # 添加所有ETCD节点到SAN
    local i=2
    for node in "${ETCD_NODES[@]}"; do
        node_name=$(echo "$node" | cut -d: -f1)
        node_ip=$(echo "$node" | cut -d: -f2)
        echo "DNS.$i = $node_name" >> etcd.ext
        echo "IP.$((i)) = $node_ip" >> etcd.ext
        ((i++))
    done
    
    # 签发etcd证书
    openssl x509 -req -in etcd.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out etcd.pem -days 3650 -extensions v3_req -extfile etcd.ext
    
    # 复制证书到目标目录
    cp ca.pem ca-key.pem etcd.pem etcd-key.pem "$ssl_dir/"
    
    log "使用openssl生成ETCD证书完成"
}

# 创建ETCD配置文件
create_etcd_config() {
    log "创建ETCD配置文件..."
    
    local node_name=$(get_etcd_node_name)
    
    # 构建初始集群字符串
    local initial_cluster=""
    for node in "${ETCD_NODES[@]}"; do
        node_name_tmp=$(echo "$node" | cut -d: -f1)
        node_ip_tmp=$(echo "$node" | cut -d: -f2)
        if [ -z "$initial_cluster" ]; then
            initial_cluster="${node_name_tmp}=https://${node_ip_tmp}:2380"
        else
            initial_cluster="${initial_cluster},${node_name_tmp}=https://${node_ip_tmp}:2380"
        fi
    done
    
    log "初始集群配置: $initial_cluster"
    
    # 创建ETCD配置文件
    cat > /etc/etcd/etcd.conf << EOF
# ETCD Configuration File
# 节点名称
ETCD_NAME="${node_name}"

# 数据目录
ETCD_DATA_DIR="/var/lib/etcd"

# 监听客户端连接的URL
ETCD_LISTEN_CLIENT_URLS="https://${LOCAL_IP}:2379,https://127.0.0.1:2379"

# 通告给其他成员的客户端URL
ETCD_ADVERTISE_CLIENT_URLS="https://${LOCAL_IP}:2379"

# 监听peer连接的URL
ETCD_LISTEN_PEER_URLS="https://${LOCAL_IP}:2380"

# 通告给其他成员的peer URL
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://${LOCAL_IP}:2380"

# 初始集群配置
ETCD_INITIAL_CLUSTER="${initial_cluster}"

# 初始集群状态 (new/existing)
ETCD_INITIAL_CLUSTER_STATE="new"

# 初始集群token
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-k8s"

# SSL证书配置
ETCD_CERT_FILE="/etc/etcd/ssl/etcd.pem"
ETCD_KEY_FILE="/etc/etcd/ssl/etcd-key.pem"
ETCD_TRUSTED_CA_FILE="/etc/etcd/ssl/ca.pem"
ETCD_CLIENT_CERT_AUTH="true"

ETCD_PEER_CERT_FILE="/etc/etcd/ssl/etcd.pem"
ETCD_PEER_KEY_FILE="/etc/etcd/ssl/etcd-key.pem"
ETCD_PEER_TRUSTED_CA_FILE="/etc/etcd/ssl/ca.pem"
ETCD_PEER_CLIENT_CERT_AUTH="true"

# 其他配置
ETCD_LOG_LEVEL="info"
ETCD_AUTO_COMPACTION_RETENTION="1"
ETCD_QUOTA_BACKEND_BYTES="8589934592"
ETCD_HEARTBEAT_INTERVAL="100"
ETCD_ELECTION_TIMEOUT="1000"
EOF

    chown etcd:etcd /etc/etcd/etcd.conf
    
    log "ETCD配置文件创建完成"
}

# 创建ETCD systemd服务
create_etcd_service() {
    log "创建ETCD systemd服务..."
    
    cat > /etc/systemd/system/etcd.service << EOF
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
Group=etcd
WorkingDirectory=/var/lib/etcd/
EnvironmentFile=-/etc/etcd/etcd.conf
ExecStart=/usr/bin/etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    log "ETCD systemd服务创建完成"
}

# 启动ETCD服务
start_etcd_service() {
    log "启动ETCD服务..."
    
    # 重新加载systemd
    systemctl daemon-reload
    
    # 启用并启动ETCD服务
    systemctl enable etcd
    systemctl start etcd
    
    # 等待服务启动
    sleep 10
    
    # 检查服务状态
    if systemctl is-active --quiet etcd; then
        log "ETCD服务启动成功"
    else
        log "ETCD服务启动失败，查看详细日志："
        journalctl -u etcd --no-pager -l
        error_exit "ETCD服务启动失败"
    fi
    
    log "ETCD服务启动完成"
}

# 验证ETCD集群
verify_etcd_cluster() {
    log "验证ETCD集群..."
    
    # 等待集群稳定
    sleep 5
    
    # 设置etcdctl环境变量
    export ETCDCTL_API=3
    export ETCDCTL_ENDPOINTS="https://${LOCAL_IP}:2379"
    export ETCDCTL_CACERT="/etc/etcd/ssl/ca.pem"
    export ETCDCTL_CERT="/etc/etcd/ssl/etcd.pem"
    export ETCDCTL_KEY="/etc/etcd/ssl/etcd-key.pem"
    
    # 检查集群健康状态
    log "检查ETCD集群健康状态..."
    if etcdctl endpoint health; then
        log "ETCD端点健康检查通过"
    else
        log "警告: ETCD端点健康检查失败"
    fi
    
    # 检查集群成员
    log "检查ETCD集群成员..."
    etcdctl member list || log "警告: 无法获取集群成员列表"
    
    # 检查集群状态
    log "检查ETCD集群状态..."
    etcdctl endpoint status --write-out=table || log "警告: 无法获取集群状态"
    
    log "ETCD集群验证完成"
}

# 配置Kubernetes使用的ETCD证书
setup_k8s_etcd_certs() {
    log "配置Kubernetes使用的ETCD证书..."
    
    # 创建Kubernetes PKI目录
    ensure_dir "$CERT_DIR/etcd"
    
    # 复制ETCD证书供Kubernetes使用
    cp /etc/etcd/ssl/ca.pem "$CERT_DIR/etcd/ca.crt"
    cp /etc/etcd/ssl/etcd.pem "$CERT_DIR/etcd/kubernetes.crt"
    cp /etc/etcd/ssl/etcd-key.pem "$CERT_DIR/etcd/kubernetes.key"
    
    # 设置权限
    chmod 644 "$CERT_DIR/etcd/ca.crt"
    chmod 644 "$CERT_DIR/etcd/kubernetes.crt"
    chmod 600 "$CERT_DIR/etcd/kubernetes.key"
    
    log "Kubernetes ETCD证书配置完成"
}

# 创建ETCD备份脚本
create_backup_script() {
    log "创建ETCD备份脚本..."
    
    cat > /usr/local/bin/etcd-backup.sh << 'EOF'
#!/bin/bash

# ETCD备份脚本

BACKUP_DIR="/var/backups/etcd"
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/etcd-snapshot-$DATE.db"

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# 设置etcdctl环境变量
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS="https://127.0.0.1:2379"
export ETCDCTL_CACERT="/etc/etcd/ssl/ca.pem"
export ETCDCTL_CERT="/etc/etcd/ssl/etcd.pem"
export ETCDCTL_KEY="/etc/etcd/ssl/etcd-key.pem"

# 创建快照
echo "开始ETCD备份: $BACKUP_FILE"
etcdctl snapshot save "$BACKUP_FILE"

if [ $? -eq 0 ]; then
    echo "ETCD备份成功: $BACKUP_FILE"
    
    # 保留最近7天的备份
    find "$BACKUP_DIR" -name "etcd-snapshot-*.db" -mtime +7 -delete
    
    # 验证快照
    etcdctl snapshot status "$BACKUP_FILE" -w table
else
    echo "ETCD备份失败"
    exit 1
fi
EOF

    chmod +x /usr/local/bin/etcd-backup.sh
    
    # 创建备份目录
    ensure_dir "/var/backups/etcd"
    chown etcd:etcd "/var/backups/etcd"
    
    log "ETCD备份脚本创建完成"
}

# 显示ETCD配置信息
show_etcd_info() {
    local node_name=$(get_etcd_node_name)
    
    cat << EOF

=============================================================================
ETCD集群配置完成
=============================================================================

节点信息:
- 节点名称: $node_name
- 节点IP: $LOCAL_IP
- 客户端端口: 2379
- 集群通信端口: 2380

ETCD节点列表:
EOF
    for node in "${ETCD_NODES[@]}"; do
        echo "  - $node"
    done
    
    cat << EOF

证书位置:
- CA证书: /etc/etcd/ssl/ca.pem
- 服务器证书: /etc/etcd/ssl/etcd.pem
- 服务器私钥: /etc/etcd/ssl/etcd-key.pem

检查命令:
  systemctl status etcd
  etcdctl --endpoints=https://$LOCAL_IP:2379 --cacert=/etc/etcd/ssl/ca.pem --cert=/etc/etcd/ssl/etcd.pem --key=/etc/etcd/ssl/etcd-key.pem endpoint health
  
备份脚本: /usr/local/bin/etcd-backup.sh

=============================================================================
EOF
}

# 主函数
main() {
    log "=== 开始配置ETCD集群 ==="
    
    # 检查是否为ETCD节点
    if ! is_etcd_node; then
        log "当前节点不是ETCD节点，跳过ETCD配置"
        return 0
    fi
    
    log "当前节点是ETCD节点，开始配置ETCD..."
    
    # 检查是否已安装ETCD
    if command -v etcd >/dev/null 2>&1; then
        local installed_version=$(etcd --version | head -1 | awk '{print $3}')
        log "检测到已安装的ETCD版本: $installed_version"
        
        if systemctl is-active --quiet etcd; then
            log "ETCD服务正在运行"
            read -p "是否重新配置ETCD? (y/n): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "跳过ETCD配置"
                return 0
            fi
            systemctl stop etcd
        fi
    fi
    
    # 执行ETCD配置步骤
    install_etcd
    create_etcd_user_and_dirs
    generate_etcd_certificates
    create_etcd_config
    create_etcd_service
    start_etcd_service
    verify_etcd_cluster
    setup_k8s_etcd_certs
    create_backup_script
    show_etcd_info
    
    log "=== ETCD集群配置完成 ==="
    log "请在所有ETCD节点执行此脚本"
    log "等待所有节点启动后，ETCD集群将自动形成"
}

# 执行主函数
main "$@"