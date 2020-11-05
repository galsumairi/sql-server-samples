#!/bin/bash

# Get controller username and password as input. It is used as default for the controller.
#
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Prompt for private preview repository username and password provided by Microsoft
#
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
export LOG_FILE="aadatacontroller.log"
export DEBIAN_FRONTEND=noninteractive

# Requirements file.
export OSCODENAME=$(lsb_release -cs)
export AZDATA_PRIVATE_PREVIEW_DEB_PACKAGE="https://aka.ms/azdata-"$OSCODENAME

# Kube version.
#
KUBE_DPKG_VERSION=1.16.3-00
KUBE_VERSION=1.16.3

# Wait for 5 minutes for the cluster to be ready.
#
TIMEOUT=600
RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"

# Make a directory for installing the scripts and logs.
#
rm -f -r $AZUREARCDATACONTROLLER_DIR
mkdir -p $AZUREARCDATACONTROLLER_DIR
cd $AZUREARCDATACONTROLLER_DIR/
touch $LOG_FILE

{
# Install all necessary packages: kuberenetes, docker, request, azdata.
#
echo ""
echo "######################################################################################"
echo "Starting installing packages..." 

# Install docker.
#
sudo apt-get update -q

sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    curl

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

sudo usermod --append --groups docker $USER

# Create working directory
#
rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
echo "Downloading azdata installer from" $AZDATA_PRIVATE_PREVIEW_DEB_PACKAGE 
curl --location $AZDATA_PRIVATE_PREVIEW_DEB_PACKAGE --output azdata_setup.deb
sudo dpkg -i azdata_setup.deb
cd -

azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
echo "###########################################################################"
echo "Starting to setup pre-requisites for kubernetes..." 

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
"SAS"
deb http://apt.kubernetes.io/ kubernetes-xenial main

EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
sudo apt-get update -q

sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
sudo systemctl daemon-reload
sudo systemctl restart docker

sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
    modprobe br_netfilter
fi

# Disable Ipv6 for cluster endpoints.
#
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  sudo mkdir -p /mnt/local-storage/$vol

  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed." 

# Setup kubernetes cluster including remove taint on master.
#
echo ""
echo "#############################################################################"
echo "Starting to setup Kubernetes master..." 

# Initialize a kubernetes cluster on the current node.
#
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
master_node=`kubectl get nodes --no-headers=true --output=custom-columns=NAME:.metadata.name`
kubectl taint nodes ${master_node} node-role.kubernetes.io/master:NoSchedule-

# Local storage provisioning.
#
kubectl apply -f https://raw.githubusercontent.com/microsoft/sql-server-samples/master/samples/features/azure-arc/deployment/kubeadm/ubuntu/local-storage-provisioner.yaml

# Set local-storage as the default storage class
#
kubectl patch storageclass local-storage -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Install the software defined network.
#
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# helm init
#
kubectl apply -f https://raw.githubusercontent.com/microsoft/sql-server-samples/master/samples/features/azure-arc/deployment/kubeadm/ubuntu/rbac.yaml

# Verify that the cluster is ready to be used.
#
echo "Verifying that the cluster is ready for use..."
while true ; do

    if [[ "$TIMEOUT" -le 0 ]]; then
        echo "Cluster node failed to reach the 'Ready' state. Kubeadm setup failed."
        exit 1
    fi

    status=`kubectl get nodes --no-headers=true | awk '{print $2}'`

    if [ "$status" == "Ready" ]; then
        break
    fi

    sleep "$RETRY_INTERVAL"

    TIMEOUT=$(($TIMEOUT-$RETRY_INTERVAL))

    echo "Cluster not ready. Retrying..."
done


# Install the dashboard for Kubernetes.
#
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v1.10.1/src/deploy/recommended/kubernetes-dashboard.yaml

kubectl create clusterrolebinding kubernetes-dashboard --clusterrole=cluster-admin --serviceaccount=kube-system:kubernetes-dashboard
echo "Kubernetes master setup done."

# Deploy azdata Azure Arc Data Cotnroller create cluster.
#
echo ""
echo "############################################################################"
echo "Starting to deploy azdata cluster..." 

# Command to create cluster for single node cluster.
#
azdata control create -n $CLUSTER_NAME -c azure-arc-kubeadm-private-preview-acr --accept-eula $ACCEPT_EULA
echo "Azure Arc Data Controller cluster created." 

# Setting context to cluster.
#
kubectl config set-context --current --namespace $CLUSTER_NAME

# Login and get endpoint list for the cluster.
#
azdata login -n $CLUSTER_NAME

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE




nhio0i8kpi0
@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FILE@@ -1,25 +1,46 @@
#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
# Get controller username and password as input. It is used as default for the controller.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller
if [ -z "$CONTROLLER_USERNAME" ]
then
    read -p "Create Username for Azure Arc Data Controller: " username
    echo
    export CONTROLLER_USERNAME=$username
fi
if [ -z "$CONTROLLER_PASSWORD" ]
then
    while true; do
        read -s -p "Create Password for Azure Arc Data Controller: " password
        echo
        read -s -p "Confirm your Password: " password2
        echo
        [ "$password" = "$password2" ] && break
        echo "Password mismatch. Please try again."
    done
    export CONTROLLER_PASSWORD=$password
fi

# Get password as input. It is used as default for controller, SQL Server Master instance (sa account).
# Prompt for private preview repository username and password provided by Microsoft
#
while true; do
    read -s -p "Create Password for Azure Arc Data Controller: " password
if [ -z "$DOCKER_USERNAME" ]
then
    read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
    echo
    read -s -p "Confirm your Password: " password2
    export DOCKER_USERNAME=$AADC_USERNAME
fi
if [ -z "$DOCKER_PASSWORD" ]
then
    read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
    echo
    [ "$password" = "$password2" ] && break
    echo "Password mismatch. Please try again."
done
    export DOCKER_PASSWORD=$AADC_PASSWORD
fi

set -Eeuo pipefail

# This is a script to create single-node Kubernetes cluster and deploy Azure Arc Data Controller on it.
#
export AZUREARCDATACONTROLLER_DIR=aadatacontroller

# Name of virtualenv variable used.
#
@ -42,9 +63,6 @@ RETRY_INTERVAL=5

# Variables used for azdata cluster creation.
#
export CONTROLLER_USERNAME=controlleradmin
export CONTROLLER_PASSWORD=$password

export ACCEPT_EULA=yes
export CLUSTER_NAME=azure-arc-system
export PV_COUNT="40"
@ -65,9 +83,9 @@ echo "Starting installing packages..."

# Install docker.
#
apt-get update -q
sudo apt-get update -q

apt --yes install \
sudo apt --yes install \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
@ -75,21 +93,14 @@ apt --yes install \

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

add-apt-repository \
sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

apt update -q
apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
apt-mark hold docker-ce
sudo apt update -q
sudo apt-get install -q --yes docker-ce=18.06.2~ce~3-0~ubuntu --allow-downgrades
sudo apt-mark hold docker-ce

usermod --append --groups docker $USER

# Prompt for private preview repository username and password provided by Microsoft
#
read -p 'Enter Azure Arc Data Controller repo username provided by Microsoft:' AADC_USERNAME
read -sp 'Enter Azure Arc Data Controller repo password provided by Microsoft:' AADC_PASSWORD
export DOCKER_USERNAME=$AADC_USERNAME
export DOCKER_PASSWORD=$AADC_PASSWORD
sudo usermod --append --groups docker $USER

# Create working directory
#
@ -97,6 +108,10 @@ rm -f -r setupscript
mkdir -p setupscript
cd setupscript/

# Download and install azdata prerequisites
#
sudo apt install -y libodbc1 odbcinst odbcinst1debian2 unixodbc

# Download and install azdata package
#
echo ""
@ -108,6 +123,9 @@ cd -
azdata --version
echo "Azdata has been successfully installed."

# Install Azure CLI
#
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Load all pre-requisites for Kubernetes.
#
@ -116,14 +134,14 @@ echo "Starting to setup pre-requisites for kubernetes..."

# Setup the kubernetes preprequisites.
#
echo $(hostname -i) $(hostname) >> /etc/hosts
echo $(hostname -i) $(hostname) >> sudo tee -a /etc/hosts

swapoff -a
sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
sudo sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list

deb http://apt.kubernetes.io/ kubernetes-xenial main

@ -131,17 +149,17 @@ EOF

# Install docker and packages to allow apt to use a repository over HTTPS.
#
apt-get update -q
sudo apt-get update -q

apt-get install -q -y ebtables ethtool
sudo apt-get install -q -y ebtables ethtool

#apt-get install -y docker.ce

apt-get install -q -y apt-transport-https
sudo apt-get install -q -y apt-transport-https

# Setup daemon.
#
cat > /etc/docker/daemon.json <<EOF
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
@ -152,19 +170,19 @@ cat > /etc/docker/daemon.json <<EOF
}
EOF

mkdir -p /etc/systemd/system/docker.service.d
sudo mkdir -p /etc/systemd/system/docker.service.d

# Restart docker.
#
systemctl daemon-reload
systemctl restart docker
sudo systemctl daemon-reload
sudo systemctl restart docker

apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION
sudo apt-get install -q -y kubelet=$KUBE_DPKG_VERSION kubeadm=$KUBE_DPKG_VERSION kubectl=$KUBE_DPKG_VERSION

# Holding the version of kube packages.
#
apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash
sudo apt-mark hold kubelet kubeadm kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | sudo bash

. /etc/os-release
if [ "$UBUNTU_CODENAME" == "bionic" ]; then
@ -177,12 +195,12 @@ sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1

echo net.ipv6.conf.all.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 >> /etc/sysctl.conf
echo net.ipv6.conf.all.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.default.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf
echo net.ipv6.conf.lo.disable_ipv6=1 | sudo tee -a /etc/sysctl.conf


sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-iptables=1

# Setting up the persistent volumes for the kubernetes.
#
@ -190,9 +208,9 @@ for i in $(seq 1 $PV_COUNT); do

  vol="vol$i"

  mkdir -p /mnt/local-storage/$vol
  sudo mkdir -p /mnt/local-storage/$vol

  mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol
  sudo mount --bind /mnt/local-storage/$vol /mnt/local-storage/$vol

done
echo "Kubernetes pre-requisites have been completed."
@ -208,10 +226,9 @@ echo "Starting to setup Kubernetes master..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=$KUBE_VERSION

mkdir -p $HOME/.kube
mkdir -p /home/$SUDO_USER/.kube

sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.kube/config
sudo chown $(id -u $USER):$(id -g $USER) $HOME/.kube/config

# To enable a single node cluster remove the taint that limits the first node to master only service.
#
@ -280,9 +297,5 @@ kubectl config set-context --current --namespace $CLUSTER_NAME
#
azdata login -n $CLUSTER_NAME

if [ -d "$HOME/.azdata/" ]; then
        sudo chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $HOME/.azdata/
fi

echo "Cluster successfully setup. Run 'azdata --help' to see all available options."
}| tee $LOG_FI
@#$@ediesjfo cc wno es

seedfcwa
AZDATA_PRIVATE_PREVIEW_DEB_PACKAGE





