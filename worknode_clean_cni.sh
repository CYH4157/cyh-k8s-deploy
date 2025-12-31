sudo systemctl stop kubelet
sudo systemctl stop containerd

sudo rm -rf /var/lib/cni/*
sudo rm -rf /var/lib/calico/*
sudo rm -rf /run/calico/* 2>/dev/null || true
sudo rm -rf /var/run/calico/* 2>/dev/null || true

sudo systemctl start containerd
sudo systemctl start kubelet
