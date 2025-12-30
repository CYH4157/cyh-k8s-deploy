#!/bin/bash
set -euo pipefail

### ===== 使用者可自訂區 ===== ###
K8S_VERSION="v1.31"

# ⚠️ 請把 master 上輸出的 join 指令「貼成一行」放這裡（不要含 \ 斷行）
# 例如：
# JOIN_CMD="kubeadm join 140.110.160.122:6443 --token xxx.yyy --discovery-token-ca-cert-hash sha256:aaaa..."
JOIN_CMD=""

# 是否固定 node name（一般不用改）
SET_NODE_NAME=true

# 是否每次都 reset（第一次部署建議 true；成功後重跑可改 false）
DO_RESET=true
### =========================== ###

NODE_NAME="$(hostname)"
PRIVATE_IP="$(hostname -I | awk '{print $1}')"

echo "=== [INFO] Worker Node Name : ${NODE_NAME}"
echo "=== [INFO] Worker Private IP: ${PRIVATE_IP}"

if [[ -z "${JOIN_CMD}" ]]; then
  echo "❌ JOIN_CMD 為空，請把 master 輸出的 join 指令貼到腳本內（一行，不要用 \\ 斷行）。"
  exit 1
fi

echo "[Step 1] 更新系統套件 + 安裝必要工具（含 conntrack）"
sudo apt update -y
sudo apt install -y \
  apt-transport-https ca-certificates curl gnupg lsb-release net-tools \
  conntrack socat ebtables ethtool ipset ipvsadm

echo "[Step 2] 關閉 Swap"
sudo swapoff -a || true
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab || true

echo "[Step 3] 設定 sysctl（Kubernetes networking 必要）"
cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf >/dev/null
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sudo modprobe br_netfilter || true
sudo sysctl --system >/dev/null 2>&1 || true

echo "[Step 4] 安裝/設定 containerd（SystemdCgroup=true）"
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable containerd
sudo systemctl restart containerd

echo "[Step 5] 安裝 kubelet/kubeadm (${K8S_VERSION})"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt update -y
sudo apt install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm

# kubelet 先 enable，但不要在 join 前硬 restart（避免 flags 不存在造成 dead）
sudo systemctl enable kubelet
sudo systemctl daemon-reload

if [[ "${DO_RESET}" == "true" ]]; then
  echo "[Cleanup] 重置舊叢集環境（推薦第一次/失敗後重跑）"
  sudo kubeadm reset -f || true
  sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni /var/lib/cni /root/.kube
  sudo ip link delete cni0 2>/dev/null || true
  sudo ip link delete flannel.1 2>/dev/null || true
  sudo ip link delete cali0 2>/dev/null || true
fi

echo "[Step 6] 加入叢集（kubeadm join，必須 root）"
# 把 JOIN_CMD 切成陣列，避免引號/空白/換行造成 "--node-name: command not found"
read -r -a JOIN_ARR <<< "${JOIN_CMD}"

if [[ "${SET_NODE_NAME}" == "true" ]]; then
  sudo "${JOIN_ARR[@]}" --node-name "${NODE_NAME}"
else
  sudo "${JOIN_ARR[@]}"
fi

echo "[Step 7] 確認 kubelet 狀態"
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager -l || true

echo "✅ Worker join 已完成。請到 master 上執行：kubectl get nodes -o wide"


echo "[Step 8] 暫停kubelet 清除cni存留檔案"
sudo systemctl stop kubelet

sudo rm -rf /etc/cni/net.d
sudo rm -rf /var/lib/cni
sudo rm -rf /var/run/calico
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cali* 2>/dev/null || true

echo "[Step 9] 確保 worker 的 kernel module & sysctl 真正生效"
sudo modprobe br_netfilter
sudo modprobe overlay

cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
