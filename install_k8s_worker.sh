#!/bin/bash
set -euo pipefail

### ===== 使用者可自訂區 =====
K8S_VERSION="v1.31"
# 把 master 上輸出的 join 指令貼到這裡（必須「一行」）
JOIN_CMD=""
DO_RESET=true         # 失敗重跑建議 true
SET_NODE_NAME=true    # 一般 true
### =========================

NODE_NAME="$(hostname)"
PRIVATE_IP="$(hostname -I | awk '{print $1}')"

if [[ -z "${JOIN_CMD}" ]]; then
  echo "❌ JOIN_CMD 為空：請把 master 上 kubeadm token create --print-join-command 的輸出貼進來（單行）。"
  exit 1
fi

echo "=== [INFO] Worker Node Name : ${NODE_NAME}"
echo "=== [INFO] Worker Private IP: ${PRIVATE_IP}"
echo "=== [INFO] K8S_VERSION      : ${K8S_VERSION}"

echo "[Step 1] 安裝必要套件（含 conntrack / socat）"
sudo apt update -y
sudo apt install -y \
  apt-transport-https ca-certificates curl gnupg lsb-release net-tools \
  conntrack socat ebtables ethtool ipset ipvsadm

echo "[Step 2] 關閉 swap"
sudo swapoff -a || true
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab || true

echo "[Step 3] Kernel modules + sysctl（K8s networking 必要）"
sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<EOF
overlay
br_netfilter
EOF
sudo modprobe overlay || true
sudo modprobe br_netfilter || true

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

echo "[Step 4] 安裝/設定 containerd（SystemdCgroup=true）"
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable containerd
sudo systemctl restart containerd

echo "[Step 5] 安裝 kubelet/kubeadm (${K8S_VERSION})"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt update -y
sudo apt install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm

sudo systemctl enable kubelet
sudo systemctl daemon-reload

if [[ "${DO_RESET}" == "true" ]]; then
  echo "[Cleanup] reset 舊叢集 + 清掉舊 CNI（注意：只做在 join 前）"
  sudo kubeadm reset -f || true
  sudo systemctl stop kubelet || true

  sudo rm -rf /etc/cni/net.d /var/lib/cni /var/run/calico /var/lib/kubelet /etc/kubernetes /root/.kube
  sudo ip link delete cni0 2>/dev/null || true
  sudo ip link delete flannel.1 2>/dev/null || true
  sudo ip link delete cali0 2>/dev/null || true
  sudo ip link delete tunl0 2>/dev/null || true
fi

echo "[Step 6] kubeadm join（必須 root）"
# 避免你之前遇到的 --node-name: command not found
read -r -a JOIN_ARR <<< "${JOIN_CMD}"

if [[ "${SET_NODE_NAME}" == "true" ]]; then
  sudo "${JOIN_ARR[@]}" --node-name "${NODE_NAME}"
else
  sudo "${JOIN_ARR[@]}"
fi

echo "[Step 7] 啟動 kubelet"
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager -l || true

echo "✅ Done. 到 master 檢查：kubectl get nodes -o wide"
echo "👉 若 node 仍 NotReady，master 上跑：kubectl -n kube-system delete pod -l k8s-app=calico-node"
