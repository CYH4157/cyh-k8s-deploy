#!/bin/bash
set -euo pipefail

### === 使用者可自訂區 === ###
K8S_VERSION="v1.31"

# 把 master 上輸出的 join 指令整行貼到這裡（含 token + ca-cert-hash）
# 範例：
# JOIN_CMD='kubeadm join 140.110.160.122:6443 --token xxx.yyy --discovery-token-ca-cert-hash sha256:aaaa...'
JOIN_CMD=''
### ====================== ###

NODE_NAME=$(hostname)
PRIVATE_IP=$(hostname -I | awk '{print $1}')

echo "=== [INFO] Node Name : ${NODE_NAME}"
echo "=== [INFO] Private IP: ${PRIVATE_IP}"

echo "[Step 1] 更新系統套件"
sudo apt update -y
sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release net-tools

echo "[Step 2] 安裝 Containerd"
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable containerd
sudo systemctl restart containerd

echo "[Step 3] 關閉 Swap 與設定 sysctl"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system 2>/dev/null

echo "[Step 4] 安裝 Kubernetes ${K8S_VERSION}（kubelet/kubeadm）"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update -y
sudo apt install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm

echo "[Step 5] 啟用服務（但不手動 restart kubelet）"
sudo systemctl enable kubelet
sudo systemctl daemon-reload

echo "[Cleanup] 清理舊叢集環境（避免 kubelet flags 遺失問題）"
sudo kubeadm reset -f || true
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni /var/lib/cni /root/.kube
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cali0 2>/dev/null || true

# 讓 kubeadm join 自己產生 /var/lib/kubelet/kubeadm-flags.env 後再把 kubelet 拉起來
echo "[Step 6] 加入叢集（kubeadm join）"
if [[ -z "${JOIN_CMD}" ]]; then
  echo "kubeadm join 140.110.160.122:6443 --token 91fzre.ije05ojmxivm91gs --discovery-token-ca-cert-hash sha256:20541f496aca203375527a28cbfffceeeb30e8c527aa3b5307cbda87f5f07425"
  exit 1
fi

sudo bash -lc "${JOIN_CMD} --node-name ${NODE_NAME}"

echo "[Step 7] 檢查 kubelet 是否 Running"
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager -l || true

echo "✅ Worker join 指令已完成。請到 master 執行：kubectl get nodes -o wide"
