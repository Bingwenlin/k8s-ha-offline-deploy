# Kubernetes 高可用集群离线部署指南

## 概述

本项目提供了一套完整的脚本，用于在CentOS 7环境下离线部署Kubernetes高可用集群。该方案采用外部ETCD集群、HAProxy+Keepalived负载均衡，以及Calico网络插件。

## 架构设计

### 高可用架构
```
                    ┌─────────────────┐
                    │   VIP (Keepalived)   │
                    │   192.168.1.100      │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │   HAProxy (LB)      │
                    │   Port: 6443        │
                    └─────────┬───────────┘
                              │
            ┌─────────────────┼─────────────────┐
            │                 │                 │
      ┌─────▼─────┐     ┌─────▼─────┐     ┌─────▼─────┐
      │  Master1  │     │  Master2  │     │  Master3  │
      │192.168.1.101│   │192.168.1.102│   │192.168.1.103│
      └───────────┘     └───────────┘     └───────────┘
            │                 │                 │
      ┌─────▼─────┐     ┌─────▼─────┐     ┌─────▼─────┐
      │   ETCD1   │     │   ETCD2   │     │   ETCD3   │
      │Port: 2379 │     │Port: 2379 │     │Port: 2379 │
      └───────────┘     └───────────┘     └───────────┘
            │                 │                 │
            └─────────────────┼─────────────────┘
                              │
            ┌─────────────────┼─────────────────┐
            │                 │                 │
      ┌─────▼─────┐     ┌─────▼─────┐     ┌─────▼─────┐
      │  Worker1  │     │  Worker2  │     │  Worker3  │
      │192.168.1.111│   │192.168.1.112│   │192.168.1.113│
      └───────────┘     └───────────┘     └───────────┘
```

### 组件版本
- **Kubernetes**: 1.28.2
- **Docker**: 20.10.21
- **ETCD**: 3.5.9
- **Calico**: 3.26.1
- **HAProxy**: 最新版本
- **Keepalived**: 最新版本

## 环境要求

### 硬件要求
- **Master节点**: 2核CPU, 4GB内存, 20GB硬盘
- **Worker节点**: 2核CPU, 4GB内存, 20GB硬盘
- **网络**: 所有节点需要在同一网段，能够相互通信

### 操作系统要求
- **操作系统**: CentOS 7.x
- **内核版本**: 3.10+ (建议4.19+)
- **时间同步**: 所有节点时间同步

### 网络规划
- **节点网络**: 192.168.1.0/24 (示例)
- **Pod网络**: 10.244.0.0/16
- **Service网络**: 10.96.0.0/12
- **VIP地址**: 192.168.1.100

## 快速开始

### 1. 准备阶段

#### 1.1 修改配置文件
编辑 `config.sh` 文件，修改以下配置：

```bash
# 修改节点信息
export MASTER_NODES=(
    "master1:192.168.1.101"
    "master2:192.168.1.102"
    "master3:192.168.1.103"
)

export WORKER_NODES=(
    "worker1:192.168.1.111"
    "worker2:192.168.1.112"
    "worker3:192.168.1.113"
)

# 修改VIP地址
export VIP="192.168.1.100"

# 修改网卡接口名
export KEEPALIVED_INTERFACE="eth0"
```

#### 1.2 准备离线安装包（在有网络的机器上执行）
```bash
# 下载所有必要的离线包
bash download-packages.sh

# 打包传输到目标环境
tar -czf k8s-ha-offline.tar.gz k8s-ha-offline-deploy/
```

### 2. 部署阶段

#### 2.1 一键部署（推荐）
```bash
# 在第一个Master节点执行
bash install-k8s-ha.sh install-all
```

#### 2.2 分步部署

**步骤1: 系统初始化（所有节点）**
```bash
bash install-k8s-ha.sh install-step system-init
reboot  # 重启系统
```

**步骤2: 安装Docker（所有节点）**
```bash
bash install-k8s-ha.sh install-step install-docker
```

**步骤3: 安装K8s组件（所有节点）**
```bash
bash install-k8s-ha.sh install-step install-k8s
```

**步骤4: 配置负载均衡（Master节点）**
```bash
bash install-k8s-ha.sh install-step setup-lb
```

**步骤5: 配置ETCD集群（Master节点）**
```bash
bash install-k8s-ha.sh install-step setup-etcd
```

**步骤6: 初始化Master节点**
```bash
# 第一个Master节点
bash install-k8s-ha.sh install-step init-masters

# 其他Master节点（复制tokens目录后执行）
bash install-k8s-ha.sh install-step init-masters
```

**步骤7: 加入Worker节点**
```bash
# 在Worker节点执行（复制tokens目录后）
bash install-k8s-ha.sh install-step join-workers
```

**步骤8: 安装网络插件（Master节点）**
```bash
bash install-k8s-ha.sh install-step install-cni
```

## 详细配置说明

### 配置文件详解 (config.sh)

```bash
# 集群基本信息
export CLUSTER_NAME="k8s-ha-cluster"        # 集群名称
export K8S_VERSION="1.28.2"                 # K8s版本
export DOCKER_VERSION="20.10.21"            # Docker版本

# 网络配置
export POD_SUBNET="10.244.0.0/16"          # Pod网段
export SERVICE_SUBNET="10.96.0.0/12"       # Service网段
export VIP="192.168.1.100"                 # 虚拟IP

# 节点配置（根据实际环境修改）
export MASTER_NODES=(
    "master1:192.168.1.101"
    "master2:192.168.1.102"
    "master3:192.168.1.103"
)

export WORKER_NODES=(
    "worker1:192.168.1.111"
    "worker2:192.168.1.112"
    "worker3:192.168.1.113"
)

# Keepalived配置
export KEEPALIVED_INTERFACE="eth0"          # 网卡接口名
export KEEPALIVED_ROUTER_ID="51"            # 路由器ID
```

### 目录结构

```
k8s-ha-offline-deploy/
├── config.sh                    # 配置文件
├── install-k8s-ha.sh           # 主安装脚本
├── 01-system-init.sh           # 系统初始化
├── 02-install-docker.sh        # Docker安装
├── 03-install-k8s.sh          # K8s组件安装
├── 04-setup-loadbalancer.sh   # 负载均衡配置
├── 05-setup-etcd.sh           # ETCD集群配置
├── 06-init-masters.sh         # Master节点初始化
├── 07-join-workers.sh         # Worker节点加入
├── 08-install-cni.sh          # 网络插件安装
├── download-packages.sh       # 离线包下载
├── README.md                   # 说明文档
└── offline-packages/           # 离线安装包目录
    ├── kubernetes/             # K8s二进制文件
    ├── docker/                 # Docker相关文件
    ├── etcd/                   # ETCD二进制文件
    ├── calico/                 # Calico配置文件
    ├── k8s-images.tar         # K8s镜像包
    └── ...                     # 其他离线包
```

## 故障排除

### 常见问题

#### 1. 网络连接问题
```bash
# 检查节点连通性
ping 192.168.1.101

# 检查端口连通性
telnet 192.168.1.101 6443
telnet 192.168.1.101 2379
```

#### 2. 服务状态检查
```bash
# 检查Docker状态
systemctl status docker

# 检查kubelet状态
systemctl status kubelet

# 检查ETCD状态
systemctl status etcd

# 检查HAProxy状态
systemctl status haproxy

# 检查Keepalived状态
systemctl status keepalived
```

#### 3. 集群状态检查
```bash
# 检查节点状态
kubectl get nodes -o wide

# 检查Pod状态
kubectl get pods -A

# 检查集群组件
kubectl get cs

# 检查ETCD集群
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ssl/ca.pem \
  --cert=/etc/etcd/ssl/etcd.pem \
  --key=/etc/etcd/ssl/etcd-key.pem \
  endpoint health
```

#### 4. 日志查看
```bash
# 查看kubelet日志
journalctl -u kubelet -f

# 查看Docker日志
journalctl -u docker -f

# 查看ETCD日志
journalctl -u etcd -f

# 查看系统日志
tail -f /var/log/messages
```

### 重置集群

如果需要重置集群，可以使用以下命令：

```bash
# 在所有节点执行
kubeadm reset -f
systemctl stop kubelet docker
rm -rf /etc/kubernetes/
rm -rf /var/lib/kubelet/
rm -rf /var/lib/etcd/
rm -rf /etc/cni/net.d/

# 重新开始部署
bash install-k8s-ha.sh install-all
```

## 验证部署

### 1. 检查集群状态
```bash
kubectl get nodes
kubectl get pods -A
kubectl cluster-info
```

### 2. 创建测试应用
```bash
# 创建测试Pod
kubectl run test-pod --image=nginx:latest --port=80

# 创建Service
kubectl expose pod test-pod --port=80 --target-port=80 --type=NodePort

# 检查访问
kubectl get svc test-pod
curl http://节点IP:NodePort
```

### 3. 测试高可用
```bash
# 停止一个Master节点
systemctl stop kubelet

# 检查集群是否仍然可用
kubectl get nodes

# 重新启动节点
systemctl start kubelet
```

## 维护操作

### 备份

#### ETCD备份
```bash
# 执行备份脚本
/usr/local/bin/etcd-backup.sh

# 手动备份
etcdctl snapshot save /var/backups/etcd/snapshot.db
```

#### 配置备份
```bash
# 备份Kubernetes配置
tar -czf k8s-config-backup.tar.gz /etc/kubernetes/

# 备份证书
tar -czf k8s-pki-backup.tar.gz /etc/kubernetes/pki/
```

### 扩容

#### 添加Master节点
1. 准备新节点，执行系统初始化
2. 安装Docker和K8s组件
3. 复制证书和加入令牌
4. 执行Master加入命令

#### 添加Worker节点
1. 准备新节点，执行系统初始化
2. 安装Docker和K8s组件
3. 执行Worker加入命令

### 升级

升级Kubernetes集群需要谨慎操作，建议：
1. 先备份ETCD和配置
2. 逐个升级节点
3. 验证集群功能

## 安全配置

### 网络策略
```bash
# 启用默认拒绝策略（可选）
export ENABLE_DEFAULT_DENY_POLICY=true
```

### RBAC配置
```bash
# 查看RBAC配置
kubectl get clusterrolebindings
kubectl get rolebindings -A
```

### 证书管理
```bash
# 检查证书有效期
kubeadm certs check-expiration

# 更新证书
kubeadm certs renew all
```

## 监控告警

建议安装以下监控组件：
- **Prometheus**: 监控指标收集
- **Grafana**: 监控可视化
- **AlertManager**: 告警管理

## 总结

本部署方案提供了完整的Kubernetes高可用集群离线部署解决方案。通过模块化的脚本设计，支持一键部署和分步部署两种方式，满足不同场景的需求。

主要特性：
- ✅ 完全离线部署
- ✅ 高可用架构
- ✅ 模块化脚本
- ✅ 详细日志记录
- ✅ 错误处理和回滚
- ✅ 完整的验证流程

如有问题，请检查日志文件：`/var/log/k8s-install/install.log`

---

**注意**: 在生产环境部署前，请务必在测试环境充分验证！