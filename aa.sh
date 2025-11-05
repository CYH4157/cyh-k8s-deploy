#!/bin/bash
set -euo pipefail

### ====== 使用者可調參數 ====== ###
K8S_VERSION="v1.31"
POD_CIDR="10.244.0.0/16"
SVC_CIDR="10.96.0.0/12"
CALICO_VERSION="v3.27.2"
ALLOW_SCHEDULE_ON_MASTER=true   # 單節點要跑 Pod 請設 true
# 若你不想自動偵測 Public IP，可手動設定：export PUBLIC_IP="140.110.xxx.xxx"
### ============================ ###

log(){ echo -e "\e[1;32m[+] $*\e[0m"; }
warn(){ echo -e "\e[1;33m[!] $*\e[0m"; }
err(){ echo -e "\e[1;31m[-] $*\e[0m"; }

detect_ips() {
  PRIVATE_IP=$(hostname -I | awk '{print $1}')
  PUBLIC_IP="${PUBLIC_IP:-$(curl -s --max-time 3 ifconfig.me || true)}"
  if [[ -z "${PUBLIC_IP}" ]]; then
    warn "無法自動偵測 Public IP，後續會僅以 Private IP 寫 SAN。"
  fi
  NODE_NAME=$(hostname)
  log "Private IP = ${PRIVATE_IP}"
  log "Public  IP = ${PUBLIC_IP:-'(未偵測/未設定)'}"
}

cleanup_old() {
  log "清理舊叢集（先清再建）"
  sudo kubeadm reset -f || true
  sudo systemctl stop kubelet 2>/dev/null || true
  sudo systemctl stop containerd 2>/dev/null || true

  sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/* /etc/cni /var/lib/cni /root/.kube
  sudo ip link delete cni0 2>/dev/null || true
  sudo ip link delete flannel.1 2>/dev/null || true
  sudo ip link delete cali0 2>/dev/null || true
}

install_prereqs() {
  log "安裝基本套件、containerd"
  sudo apt update -y
  sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release net-tools containerd

  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl enable --now containerd

  log "關閉 swap 與 sysctl"
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

kubeadm_init() {
  log "初始化 kubeadm（NAT + Public IP 友善）"
  local sans="${PRIVATE_IP}"
  local endpoint="${PRIVATE_IP}:6443"
  if [[ -n "${PUBLIC_IP:-}" ]]; then
    sans="${PUBLIC_IP},${PRIVATE_IP}"
    endpoint="${PUBLIC_IP}:6443"
  fi

  sudo kubeadm init \
    --apiserver-advertise-address="${PRIVATE_IP}" \
    --apiserver-cert-extra-sans="${sans}" \
    --control-plane-endpoint="${endpoint}" \
    --pod-network-cidr="${POD_CIDR}" \
    --service-cidr="${SVC_CIDR}" \
    --node-name="${NODE_NAME}" \
    --ignore-preflight-errors=FileAvailable,Port-10250,Port-10251,Port-10252,Port-10257,Port-10259

  log "設定 kubectl kubeconfig"
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  # 讓 apiserver 對外位址更友善
  if [[ -n "${PUBLIC_IP:-}" ]]; then
    sudo sed -i "/--bind-address/c\    - --bind-address=0.0.0.0" /etc/kubernetes/manifests/kube-apiserver.yaml
    if ! grep -q -- "--external-hostname=${PUBLIC_IP}" /etc/kubernetes/manifests/kube-apiserver.yaml; then
      sudo sed -i "/--service-account-key-file/a\    - --external-hostname=${PUBLIC_IP}" /etc/kubernetes/manifests/kube-apiserver.yaml
    fi
  fi
}

install_calico_vxlan() {
  log "安裝 Calico ${CALICO_VERSION}（VXLAN、停用 IPIP、MTU 1440、Public IP 自動偵測）"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

  # 等 calico-node DaemonSet 出現再 patch
  for i in {1..30}; do
    kubectl get ds -n kube-system calico-node >/dev/null 2>&1 && break
    sleep 2
  done

  # 1) 調整 MTU（避免 NAT/封裝造成過大）
  kubectl -n kube-system get cm calico-config -o yaml | \
    sed 's/veth_mtu: *"0"/veth_mtu: "1440"/' | kubectl apply -f -

  # 2) 將預設池改為 VXLAN Always、IPIP Never（以 env 覆寫）
  kubectl -n kube-system set env daemonset/calico-node \
    CALICO_IPV4POOL_VXLAN=Always \
    CALICO_IPV4POOL_IPIP=Never \
    FELIX_VXLANENABLED=true \
    FELIX_IPINIPENABLED=false

  # 3) 自動挑選能 reach 公網的 IP（NAT 情境常用）
  kubectl -n kube-system set env daemonset/calico-node \
    IP_AUTODETECTION_METHOD=can-reach=8.8.8.8

  # 重新啟動 calico-node 以套用
  kubectl -n kube-system rollout restart ds/calico-node
}

post_tune_and_checks() {
  if [[ "${ALLOW_SCHEDULE_ON_MASTER}" == "true" ]]; then
    log "解除 control-plane 預設 taint（單節點可調度）"
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
  fi

  log "檢查 API Server 6443"
  sudo ss -ltnp | grep 6443 || warn "未看到 6443 LISTEN，可能仍在啟動中"

  log "等待 Node 轉為 Ready（最多 5 分鐘）"
  for i in {1..30}; do
    STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
    [[ "${STATUS}" == "Ready" ]] && { log "✅ Node Ready"; break; }
    sleep 10
  done

  log "檢查 kube-system pods"
  kubectl get pods -n kube-system -o wide

  log "列出 Join 指令（給 worker 用）"
  kubeadm token create --print-join-command
}

### Main
detect_ips
cleanup_old
install_prereqs
install_k8s
kubeadm_init
install_calico_vxlan
post_tune_and_checks
