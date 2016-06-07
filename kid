#!/bin/bash
EXECUTABLE=${0##*/}
EXECUTABLE_VERSION=0.0.1

KUBERNETES_VERSION=1.2.4
KUBERNETES_API_PORT=8080
KUBERNETES_DASHBOARD_NODEPORT=31999
DNS_DOMAIN=cluster.local
DNS_SERVER_IP=10.0.0.10

set -e

function print_usage {
  cat << EOF
NAME:
  ${EXECUTABLE} - an utility for launching Kubernetes in Docker.

VERSION:
  ${EXECUTABLE_VERSION}

USAGE:
  ${EXECUTABLE} [command]

COMMANDS:
  up       Start Kubernetes in the Docker host currently configured with your local docker command.
  down     Tear down a previously started Kubernetes.
  restart  Restart Kubernetes.
  version  Show version.
  help     Show usage information.
EOF
}

function active_docker_machine {
  if [ "$(command -v docker-machine)" ]; then
    docker-machine active
  fi
}

function check_prerequisites {
  INSTALL_PATH=/usr/local/bin
  if uname -r | grep -q "coreos"; then
    INSTALL_PATH=/opt/bin
  fi

  SUPPORTED="linux-amd64 linux-i386 darwin-amd64 darwin-i386"
  PLATFORM=$(uname | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  if [ "${ARCH}" == "x86_64" ]; then
    ARCH=amd64
  fi

  function get_kubectl {
    curl -Ls http://storage.googleapis.com/kubernetes-release/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl -O
    chmod +x kubectl
    sudo mkdir -p ${INSTALL_PATH}
    sudo mv -f kubectl ${INSTALL_PATH}/kubectl
  }

  if ! echo "${SUPPORTED}" | tr ' ' '\n' | grep -q "${PLATFORM}-${ARCH}"; then
    echo ${EXECUTABLE} is not currently supported on ${PLATFORM}-${ARCH}!
    exit 1
  fi

  if ! [ "$(command -v docker)" ]; then
    echo Docker is not installed!
    exit 1
  fi

  docker info > /dev/null
  if [ "${?}" != 0 ]; then
    echo Docker Engine is not running!
    exit 1
  fi

  if ! [ "$(command -v kubectl)" ]; then
    echo kubectl is not installed yet. Installing now...
    get_kubectl
  else
    local kubectl_version=$(kubectl version --client | grep -Po '(?<=GitVersion:"v).*(?=",)' | grep -Po "(\d+\.)+\d+")
    if [ "${KUBERNETES_VERSION}" != "${kubectl_version}" ]; then
      echo kubectl v${kubectl_version} found, but we need v${KUBERNETES_VERSION}. Updating now...
      get_kubectl
    fi
  fi

  local machine=$(active_docker_machine)
  if [ -n "${machine}" ]; then
    local cluster_ip=$(docker-machine ip ${machine})
  else
    local cluster_ip=127.0.0.1
  fi
  kubectl config set-cluster k8s --server=http://${cluster_ip}:${KUBERNETES_API_PORT} &> /dev/null
  kubectl config set-context k8s --cluster=k8s &> /dev/null
  kubectl config use-context k8s &> /dev/null
}

function mount_filesystem_shared_if_necessary {
  local machine=$(active_docker_machine)
  if [ -n "${machine}" ]; then
    docker-machine ssh ${machine} sudo mount --make-shared /
  else
    if grep -q "MountFlags=slave" /etc/systemd/system/docker.service /usr/lib64/systemd/system/docker.service &> /dev/null; then
      sudo mkdir -p /etc/systemd/system/docker.service.d/
sudo tee /etc/systemd/system/docker.service.d/clear_mount_propagtion_flags.conf > /dev/null << EOF
[Service]
MountFlags=shared
EOF
      sudo systemctl daemon-reload
      sudo systemctl restart docker.service
    fi
  fi
}

function wait_for_kubernetes {
  until $(kubectl cluster-info &> /dev/null); do
    sleep 1
  done
}

function create_kube_system_namespace {
  kubectl create -f - << EOF > /dev/null
kind: Namespace
apiVersion: v1
metadata:
  name: kube-system
  labels:
    name: kube-system
EOF
}

function activate_kubernetes_dashboard {
  local dashboard_service_nodeport=${1}
  kubectl create -f - << EOF > /dev/null
# Source: https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/kubernetes-dashboard-canary.yaml
kind: List
apiVersion: v1
items:
- kind: ReplicationController
  apiVersion: v1
  metadata:
    labels:
      app: kubernetes-dashboard-canary
      version: canary
    name: kubernetes-dashboard-canary
    namespace: kube-system
  spec:
    replicas: 1
    selector:
      app: kubernetes-dashboard-canary
      version: canary
    template:
      metadata:
        labels:
          app: kubernetes-dashboard-canary
          version: canary
      spec:
        containers:
        - name: kubernetes-dashboard-canary
          image: gcr.io/google_containers/kubernetes-dashboard-amd64:canary
          imagePullPolicy: Always
          ports:
          - containerPort: 9090
            protocol: TCP
          args:
            # Uncomment the following line to manually specify Kubernetes API server Host
            # If not specified, Dashboard will attempt to auto discover the API server and connect
            # to it. Uncomment only if the default does not work.
            # - --apiserver-host=http://my-address:port
          livenessProbe:
            httpGet:
              path: /
              port: 9090
            initialDelaySeconds: 30
            timeoutSeconds: 30
- kind: Service
  apiVersion: v1
  metadata:
    labels:
      app: kubernetes-dashboard-canary
    name: dashboard-canary
    namespace: kube-system
  spec:
    type: NodePort
    ports:
    - port: 80
      targetPort: 9090
      nodePort: ${dashboard_service_nodeport}  # Addition. Not present in upstream definition.
    selector:
      app: kubernetes-dashboard-canary
    type: NodePort
EOF
}

function start_dns {
  local dns_domain=${1}
  local dns_server_ip=${2}
  local kubernetes_api_port=${3}

  kubectl create -f - << EOF > /dev/null
apiVersion: v1
kind: ReplicationController
metadata:
  name: kube-dns-v10
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    version: v10
    kubernetes.io/cluster-service: "true"
spec:
  replicas: 1
  selector:
    k8s-app: kube-dns
    version: v10
  template:
    metadata:
      labels:
        k8s-app: kube-dns
        version: v10
        kubernetes.io/cluster-service: "true"
    spec:
      containers:
      - name: etcd
        image: gcr.io/google_containers/etcd-amd64:2.2.1
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 100m
            memory: 50Mi
          requests:
            cpu: 100m
            memory: 50Mi
        command:
        - /usr/local/bin/etcd
        - -data-dir
        - /var/etcd/data
        - -listen-client-urls
        - http://127.0.0.1:2379,http://127.0.0.1:4001
        - -advertise-client-urls
        - http://127.0.0.1:2379,http://127.0.0.1:4001
        - -initial-cluster-token
        - skydns-etcd
        volumeMounts:
        - name: etcd-storage
          mountPath: /var/etcd/data
      - name: kube2sky
        image: gcr.io/google_containers/kube2sky:1.12
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 100m
            memory: 50Mi
          requests:
            cpu: 100m
            memory: 50Mi
        args:
        # command = "/kube2sky"
        - --domain=${dns_domain}
      - name: skydns
        image: gcr.io/google_containers/skydns:2015-10-13-8c72f8c
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 100m
            memory: 50Mi
          requests:
            cpu: 100m
            memory: 50Mi
        args:
        # command = "/skydns"
        - -machines=http://127.0.0.1:4001
        - -addr=0.0.0.0:53
        - -ns-rotate=false
        - -domain=${dns_domain}.
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /healthz
            port: ${kubernetes_api_port}
            scheme: HTTP
          initialDelaySeconds: 30
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /healthz
            port: ${kubernetes_api_port}
            scheme: HTTP
          initialDelaySeconds: 1
          timeoutSeconds: 5
      - name: healthz
        image: gcr.io/google_containers/exechealthz:1.0
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 10m
            memory: 20Mi
          requests:
            cpu: 10m
            memory: 20Mi
        args:
        - -cmd=nslookup kubernetes.default.svc.${dns_domain} 127.0.0.1 >/dev/null
        - -port=${kubernetes_api_port}
        ports:
        - containerPort: ${kubernetes_api_port}
          protocol: TCP
      volumes:
      - name: etcd-storage
        emptyDir: {}
      dnsPolicy: Default  # Don't use cluster DNS.
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: ${dns_server_ip}
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
EOF
}

function start_kubernetes {
  local kubernetes_version=${1}
  local kubernetes_api_port=${2}
  local dashboard_service_nodeport=${3}
  local dns_domain=${4}
  local dns_server_ip=${5}
  check_prerequisites

  if kubectl cluster-info 2> /dev/null; then
    echo kubectl is already configured to use an existing cluster.
    exit 1
  fi

  mount_filesystem_shared_if_necessary

  docker run \
    --name=kubelet \
    --volume=/:/rootfs:ro \
    --volume=/sys:/sys:ro \
    --volume=/var/lib/docker/:/var/lib/docker:rw \
    --volume=/var/lib/kubelet/:/var/lib/kubelet:rw,shared \
    --volume=/var/run:/var/run:rw \
    --net=host \
    --pid=host \
    --privileged=true \
    -d \
    gcr.io/google_containers/hyperkube-amd64:v${kubernetes_version} \
    /hyperkube kubelet \
        --containerized \
        --hostname-override="127.0.0.1" \
        --address="0.0.0.0" \
        --api-servers=http://localhost:${kubernetes_api_port} \
        --config=/etc/kubernetes/manifests \
        --cluster-dns=${DNS_SERVER_IP} \
        --cluster-domain=${DNS_DOMAIN} \
        --read-only-port=0 \
        --cadvisor-port=0 \
        --allow-privileged=true --v=2 \
        > /dev/null

  echo Waiting for Kubernetes cluster to become available...
  wait_for_kubernetes
  create_kube_system_namespace
  start_dns ${dns_domain} ${dns_server_ip} ${kubernetes_api_port}
  activate_kubernetes_dashboard ${dashboard_service_nodeport}
  echo Kubernetes cluster is up. The Kubernetes dashboard can be accessed via HTTP at port ${dashboard_service_nodeport} of your Docker host.
}

function delete_kubernetes_resources {
  kubectl delete replicationcontrollers,services,pods,secrets --all > /dev/null 2>&1 || :
  kubectl delete replicationcontrollers,services,pods,secrets --all --namespace=kube-system > /dev/null 2>&1 || :
  kubectl delete namespace kube-system > /dev/null 2>&1 || :
}

function delete_docker_containers {
  docker stop kubelet > /dev/null 2>&1
  docker rm -fv kubelet > /dev/null 2>&1

  k8s_containers=$(docker ps -aqf "name=k8s_")
  if [ ! -z "${k8s_containers}" ]; then
    docker stop ${k8s_containers} > /dev/null 2>&1
    docker wait ${k8s_containers} > /dev/null 2>&1
    docker rm -fv ${k8s_containers} > /dev/null 2>&1
  fi

  local machine=$(active_docker_machine)
  if [ -n "${machine}" ]; then
    docker-machine ssh ${machine} sudo rm -rf /var/lib/kubelet
  else
    sudo rm -rf /var/lib/kubelet > /dev/null 2>&1
  fi
}

function stop_kubernetes {
  local kubernetes_api_port=${1}
  check_prerequisites

  if ! kubectl cluster-info 2> /dev/null; then
    echo kubectl could not find any existing cluster. Continuing anyway...
  else
    delete_kubernetes_resources
  fi

  delete_docker_containers
}

if [ "${1}" == "up" ]; then
  start_kubernetes ${KUBERNETES_VERSION} \
    ${KUBERNETES_API_PORT} \
    ${KUBERNETES_DASHBOARD_NODEPORT} \
    ${DNS_DOMAIN} ${DNS_SERVER_IP}
elif [ "${1}" == "down" ]; then
  stop_kubernetes ${KUBERNETES_API_PORT}
elif [ "${1}" == "restart" ]; then
  ${EXECUTABLE} down && ${EXECUTABLE} up
elif [ "${1}" == "version" ]; then
  echo ${EXECUTABLE_VERSION}
elif [ "${1}" == "help" ]; then
  print_usage
elif [ "${1}" != "" ]; then
  echo Unknown command: ${1}
  echo For usage information type: ${EXECUTABLE} help
  exit 1
else
  print_usage
fi
