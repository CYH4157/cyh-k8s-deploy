#!/bin/bash
set -euo pipefail

### ====== 使用者可調參數 ====== ###
K8S_VERSION="v1.31"
CALICO_VERSION="v3.27.2"
MASTER_PUBLIC_IP="140.110.160.14"   # master 對外可連 IP
### ============================ ###

log(){ echo -e "\e[1;32m[+] $*\e[0m"; }
warn(){ echo -e "\e[1;33m[!] $*\e[0m"; }
err(){ echo -e "\e[1;31m[-] $*\e[0m"; }

detect_ips() {
  PRIVATE_IP=$(hostname -I | awk '{print $1}')
  PUBLIC_IP="${PUBLIC_IP:-$(curl -s --max-time 3 ifconfig.me || true)}"
  NODE_NAME=$(hostname)
  log "Private IP = ${PRIVATE_IP}"
  log "Public  IP = ${PUBLIC_IP:-'(未偵測)'}"
}

cleanup_old() {
  log "清理舊叢集環境"
  sudo kubeadm reset -f || true
  sudo systemctl stop kubelet containerd 2>/dev/null || true
  sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/* /etc/cni /var/lib/cni /root/.kube
  sudo ip link delete cni0 2>/dev/null || true
  sudo ip link delete flannel.1 2>/dev/null || true
  sudo ip link delete cali0 2>/dev/null || true
}

install_prereqs() {
  log "安裝基本套件與 containerd"
  sudo apt update -y
  sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release net-tools containerd

  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl enable --now containerd

  log "關閉 swap 與設定 sysctl"
  sudo swapoff -a
  sudo sed -i '/ swap / s/^/#/' /etc/fstab
  cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf >/dev/null
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
  sudo sysctl --system >/dev/null 2>&1 || true
}

install_k8s() {
  log "安裝 Kubernetes ${K8S_VERSION}"
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
  sudo apt update -y
  sudo apt install -y kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl
  sudo systemctl enable kubelet
}

join_cluster() {
  log "準備加入叢集 (${MASTER_PUBLIC_IP}:6443)"
  echo
  echo "請確認 master 已執行："
  echo "  kubeadm token create --print-join-command"
  echo
  echo "可將該指令存入 /tmp/join.sh 或手動貼上。"
  echo

  if [ -f /tmp/join.sh ]; then
    log "偵測到 /tmp/join.sh，自動執行"
    chmod +x /tmp/join.sh
    bash /tmp/join.sh --apiserver-endpoint ${MASTER_PUBLIC_IP}:6443 --v=5
  else
    read -rp "請貼上 kubeadm join 指令: " JOIN_CMD
    eval "sudo ${JOIN_CMD} --apiserver-endpoint ${MASTER_PUBLIC_IP}:6443 --v=5"
  fi
}

post_checks() {
  log "等待節點註冊到 Master (最多 2 分鐘)"
  for i in {1..12}; do
    if sudo systemctl is-active kubelet >/dev/null; then
      log "kubelet 已啟動，等待叢集認證..."
      sleep 10
    fi
  done
  log "完成加入程序，可在 master 上查看：kubectl get nodes -o wide"
}

# === 主流程 ===
detect_ips
cleanup_old
install_prereqs
install_k8s

post_checks
