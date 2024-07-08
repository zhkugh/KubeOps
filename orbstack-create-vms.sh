#!/bin/bash

# orb 创建虚拟机的镜像需要从外网拉去，注意网络环境

# 默认的 master 和 worker 节点数量
DEFAULT_NUM_MASTERS=1
DEFAULT_NUM_WORKERS=2

# 从参数获取 master 和 worker 节点数量
NUM_MASTERS=${1:-$DEFAULT_NUM_MASTERS}
NUM_WORKERS=${2:-$DEFAULT_NUM_WORKERS}

# 检查 orb 状态
ORB_STATUS=$(orb status)
if [ "$ORB_STATUS" != "Running" ]; then
  echo "Orb 当前状态不是 Running（当前状态: $ORB_STATUS），脚本退出..."
  exit 1
fi

echo "Orb 当前状态是 Running，继续创建虚拟机..."

# 创建 master 节点
for i in $(seq 1 $NUM_MASTERS); do
  echo "正在创建 master-$i..."
  orb create ubuntu:noble master-$i
  if [ $? -ne 0 ]; then
    echo "创建 master-$i 失败"
    exit 1
  fi
done

# 创建 worker 节点
for i in $(seq 1 $NUM_WORKERS); do
  echo "正在创建 worker-$i..."
  orb create ubuntu:noble worker-$i
  if [ $? -ne 0 ]; then
    echo "创建 worker-$i 失败"
    exit 1
  fi
done

echo "所有虚拟机创建成功！"

# 获取 Master 节点的 IP 地址
MASTER_IP=$(ssh root@master-1@orb "hostname -I | cut -d' ' -f1")

# 在 Master 节点上安装 Docker 和 k3s
echo "正在 master-1 上安装 Docker 和 k3s..."
ssh root@master-1@orb <<EOF
apt-get update
apt-get install -y docker.io
systemctl enable docker
systemctl start docker
echo '{
  "registry-mirrors" : [
    "https://hub.uuuadc.top",
    "https://docker.anyhub.us.kg",
    "https://dockerhub.jobcher.com",
    "https://dockerhub.icu",
    "https://docker.ckyl.me",
    "https://docker.awsl9527.cn"
  ]
}' > /etc/docker/daemon.json
systemctl restart docker
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server' sh -

# 设置 containerd 国内加速源
mkdir -p /etc/systemd/system/k3s.service.d
cat <<EOT > /etc/systemd/system/k3s.service.d/override.conf
[Service]
Environment="K3S_CONTAINER_RUNTIME_ENDPOINT=unix:///run/k3s/containerd/containerd.sock"
Environment="K3S_CONTAINER_RUNTIME_ARGS=--config /var/lib/rancher/k3s/agent/etc/containerd/config.toml"
EOT

mkdir -p /etc/rancher/k3s
cat <<EOT > /etc/rancher/k3s/registries.yaml
mirrors:
  "docker.io":
    endpoint:
      - "https://hub.uuuadc.top"
      - "https://docker.anyhub.us.kg"
      - "https://dockerhub.jobcher.com"
      - "https://dockerhub.icu"
      - "https://docker.ckyl.me"
      - "https://docker.awsl9527.cn"
EOT

systemctl daemon-reload
systemctl restart k3s
EOF

# 在 config.toml.tmpl 文件中添加
[plugins.cri.registry.mirrors]
  [plugins.cri.registry.mirrors."docker.io"]
    endpoint = ["https://hub.uuuadc.top","https://docker.anyhub.us.kg","https://dockerhub.jobcher.com"]

# 获取 Master 节点的 token
echo "正在从 master-1 获取 k3s token..."
TOKEN=$(ssh root@master-1@orb "cat /var/lib/rancher/k3s/server/node-token")
if [ -z "$TOKEN" ]; then
  echo "从 master-1 获取 token 失败"
  exit 1
fi

# 在 Worker 节点上安装 Docker 和 k3s 并加入集群
for i in $(seq 1 $NUM_WORKERS); do
  echo "正在 worker-$i 上安装 Docker 和 k3s..."
  ssh root@worker-$i@orb <<EOF
apt-get update
apt-get install -y docker.io
systemctl enable docker
systemctl start docker
echo '{
  "registry-mirrors" : [
    "https://hub.uuuadc.top",
    "https://docker.anyhub.us.kg",
    "https://dockerhub.jobcher.com",
    "https://dockerhub.icu",
    "https://docker.ckyl.me",
    "https://docker.awsl9527.cn"
  ]
}' > /etc/docker/daemon.json
systemctl restart docker
curl -sfL https://get.k3s.io | K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$TOKEN sh -

# 设置 containerd 国内加速源
mkdir -p /etc/systemd/system/k3s.service.d
cat <<EOT > /etc/systemd/system/k3s.service.d/override.conf
[Service]
Environment="K3S_CONTAINER_RUNTIME_ENDPOINT=unix:///run/k3s/containerd/containerd.sock"
Environment="K3S_CONTAINER_RUNTIME_ARGS=--config /var/lib/rancher/k3s/agent/etc/containerd/config.toml"
EOT

mkdir -p /etc/rancher/k3s
cat <<EOT > /etc/rancher/k3s/registries.yaml
mirrors:
  "docker.io":
    endpoint:
      - "https://hub.uuuadc.top"
      - "https://docker.anyhub.us.kg"
      - "https://dockerhub.jobcher.com"
      - "https://dockerhub.icu"
      - "https://docker.ckyl.me"
      - "https://docker.awsl9527.cn"
EOT

systemctl daemon-reload
systemctl restart k3s
EOF
done

echo "所有节点已成功加入 k3s 集群！"

# 部署 nginx 和 portainer 应用
echo "正在部署 nginx 和 portainer 应用..."
kubectl create -f deployments/nginx-deployment.yaml
kubectl create -f deployments/portainer-deployment.yaml

echo "所有应用部署完成！"