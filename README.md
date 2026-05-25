# My Redis k8s Lab
---

### Phase 1: Host Preparation and PV Configuration

Before Kubernetes can use the physical 5GB NVMe drive on `k8s-node2`, the host operating system must prepare the filesystem, permissions, and SELinux contexts. Because this is AlmaLinux, SELinux is enforcing by default and will block container writes unless explicitly permitted.

**1. Prepare the Disk on k8s-node2**
SSH into your second worker node and execute these commands.

```bash
ssh adm001@k8s-node2

# Create the dedicated subdirectory on the mounted NVMe drive
sudo mkdir -p /mnt/mydisk/redis-data

# Set ownership to UID 999. The Redis Alpine container runs as UID 999.
# On AlmaLinux, UID 999 is mapped to the 'systemd-oom' user in /etc/passwd, 
# but the Linux kernel enforces permissions via the numeric ID, which is correct.
sudo chown -R 999:999 /mnt/mydisk/redis-data

# Apply the SELinux container file context. Without this, SELinux will silently 
# block the container from writing to the host mount, resulting in a 
# "Permission denied" error inside the pod despite correct chown permissions.
sudo chcon -Rt container_file_t /mnt/mydisk/redis-data

# Verify the setup
ls -ldZ /mnt/mydisk/redis-data
# Expected output: drwxr-xr-x. 2 systemd-oom systemd-oom unconfined_u:object_r:container_file_t:s0 ...

exit
```

**2. Taint the Worker Node**
From your master node, apply a taint to `k8s-node2`. This repels all standard workloads, ensuring only the Redis database (which has a matching toleration) can schedule there.

```bash
kubectl taint nodes k8s-node2 dedicated=redis-db:NoSchedule
```

---

### Phase 2: YAML Architecture and Backend Mechanics

Create a directory named `redis-lab-manifests` and save the following 13 files inside it. Below each file is an explanation of the backend mechanics, followed by the YAML with inline comments.

#### 1. `01-namespace.yaml`
**Backend Mechanics:** The API server creates a logical boundary in etcd. All subsequent resources created with `namespace: redis-lab` are stored under the `/registry/namespaces/redis-lab/` prefix in etcd. NetworkPolicies and RBAC roles use this boundary to restrict access and isolate workloads.

```yaml
# The API server creates a logical boundary in etcd. All subsequent resources 
# created with 'namespace: redis-lab' are stored under the 
# /registry/namespaces/redis-lab/ prefix in etcd. NetworkPolicies and RBAC 
# roles use this boundary to restrict access and isolate workloads.
apiVersion: v1
kind: Namespace
metadata:
  name: redis-lab
  labels:
    project: redis-lab
```

#### 2. `02-secret.yaml`
**Backend Mechanics:** The API server receives the plain text `stringData`, base64-encodes it, and stores it in the `data` field in etcd. When a pod references this secret via environment variables, the kubelet retrieves it from the API server and injects it into the container's environment block before the container process starts.

```yaml
# The API server receives the plain text 'stringData', base64-encodes it, 
# and stores it in the 'data' field in etcd. When a pod references this 
# secret via environment variables, the kubelet retrieves it from the API 
# server and injects it into the container's environment block before the 
# container process starts.
apiVersion: v1
kind: Secret
metadata:
  name: redis-credentials
  namespace: redis-lab
type: Opaque
stringData:
  password: "SuperSecretRedis2026!"
```

#### 3. `03-configmap-nginx.yaml`
**Backend Mechanics:** Stored as plain text in etcd. When mounted as a volume, the kubelet creates a temporary directory on the host node, writes the ConfigMap data to a file, and bind-mounts that file into the container's filesystem.

```yaml
# Stored as plain text in etcd. When mounted as a volume, the kubelet creates 
# a temporary directory on the host node, writes the ConfigMap data to a file, 
# and bind-mounts that file into the container's filesystem.
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-proxy-config
  namespace: redis-lab
data:
  default.conf: |
    upstream redisinsight_backend {
        server redisinsight:80;
    }

    server {
        listen 80;
        server_name myredislab.dev;

        location / {
            proxy_pass http://redisinsight_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # WebSocket headers required for RedisInsight CLI and real-time metrics.
            # Without these, the proxy will drop the connection upgrade request.
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }
    }
```

#### 4. `04-service-redis-headless.yaml`
**Backend Mechanics:** Because `clusterIP: None` is set, the API server does not allocate a virtual IP. kube-proxy ignores this service and creates no iptables/IPVS rules. Instead, the CoreDNS controller watches the endpoints associated with this service and creates individual DNS `A` records for every pod IP.

```yaml
# Because 'clusterIP: None' is set, the API server does not allocate a virtual 
# IP. kube-proxy ignores this service and creates no iptables/IPVS rules. 
# Instead, the CoreDNS controller watches the endpoints associated with this 
# service and creates individual DNS 'A' records for every pod IP.
apiVersion: v1
kind: Service
metadata:
  name: redis-db-headless
  namespace: redis-lab
spec:
  clusterIP: None
  selector:
    app: redis-db
  ports:
    - port: 6379
      targetPort: 6379
```

#### 5. `05-service-redis-db.yaml`
**Backend Mechanics:** The API server allocates a stable virtual IP (ClusterIP) from the service CIDR pool. The Endpoints controller watches for pods matching the selector and populates the Endpoints object. kube-proxy watches the Endpoints object and writes iptables or IPVS rules on every node to DNAT traffic hitting the ClusterIP to the actual pod IPs.

```yaml
# The API server allocates a stable virtual IP (ClusterIP) from the service 
# CIDR pool. The Endpoints controller watches for pods matching 'app: redis-db' 
# and populates the Endpoints object with their IPs. kube-proxy watches the 
# Endpoints object and writes iptables or IPVS rules on every node to DNAT 
# traffic hitting the ClusterIP to the actual pod IPs.
apiVersion: v1
kind: Service
metadata:
  name: redis-db
  namespace: redis-lab
spec:
  selector:
    app: redis-db
  ports:
    - port: 6379
      targetPort: 6379
```

#### 6. `06-service-redisinsight.yaml`
**Backend Mechanics:** Functions identically to the Redis DB service, but maps external port 80 to the container's internal port 5540. kube-proxy handles the port translation via NAT rules.

```yaml
# Functions identically to the Redis DB service, but maps external port 80 
# to the container's internal port 5540. kube-proxy handles the port 
# translation via NAT rules.
apiVersion: v1
kind: Service
metadata:
  name: redisinsight
  namespace: redis-lab
spec:
  selector:
    app: redisinsight
  ports:
    - port: 80
      targetPort: 5540
```

#### 7. `07-service-nginx-proxy.yaml`
**Backend Mechanics:** Provides the internal load-balanced entry point for the NGINX proxy pods. The Ingress Controller will route external traffic to this specific ClusterIP.

```yaml
# Provides the internal load-balanced entry point for the NGINX proxy pods. 
# The Ingress Controller will route external traffic to this specific ClusterIP.
apiVersion: v1
kind: Service
metadata:
  name: nginx-proxy
  namespace: redis-lab
spec:
  selector:
    app: nginx-proxy
  ports:
    - port: 80
      targetPort: 80
```

#### 8. `08-local-pv.yaml`
**Backend Mechanics:** This is a cluster-scoped declaration. Kubernetes does not format the disk or create the directory; it assumes the administrator has already prepared the host path. The PV controller registers this 4Gi block of storage in etcd and marks it as `Available`. The `nodeAffinity` strictly binds this storage definition to `k8s-node2`.

```yaml
# This is a cluster-scoped declaration. Kubernetes does not format the disk 
# or create the directory; it assumes the administrator has already prepared 
# /mnt/mydisk/redis-data on the host (including chown 999:999 and SELinux 
# chcon container_file_t). The PV controller registers this 4Gi block of 
# storage in etcd and marks it as 'Available'. The nodeAffinity strictly 
# binds this storage definition to the node named 'k8s-node2'.
apiVersion: v1
kind: PersistentVolume
metadata:
  name: redis-local-pv
  labels:
    project: redis-lab
spec:
  capacity:
    storage: 4Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-redis
  local:
    path: /mnt/mydisk/redis-data
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - k8s-node2
```

#### 9. `09-statefulset-redis-db.yaml`
**Backend Mechanics:** The StatefulSet controller reads the `volumeClaimTemplates` and dynamically creates a PVC. The PV controller matches this PVC to the local PV because the `storageClassName` and capacity match. The scheduler evaluates the pod: tolerations allow it to bypass the taint, and nodeAffinity forces it to schedule on `k8s-node2`. The kubelet bind-mounts the host path to `/data` inside the container.

```yaml
# The StatefulSet controller reads the volumeClaimTemplates and dynamically 
# creates a PersistentVolumeClaim (PVC). The PV controller matches this PVC 
# to the 'redis-local-pv' because the storageClassName and capacity match. 
# The scheduler evaluates the pod: tolerations allow it to bypass the taint 
# on k8s-node2, and nodeAffinity forces it to schedule specifically on 
# k8s-node2 (aligning with the PV's node affinity).
# Note: No HPA is attached to this StatefulSet because it is bound to a 
# single local PV. Scaling beyond 1 replica would result in Pending pods.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis-db
  namespace: redis-lab
spec:
  serviceName: "redis-db-headless"
  replicas: 1
  selector:
    matchLabels:
      app: redis-db
  template:
    metadata:
      labels:
        app: redis-db
    spec:
      # Permits scheduling on nodes tainted with dedicated=redis-db:NoSchedule
      tolerations:
        - key: "dedicated"
          operator: "Equal"
          value: "redis-db"
          effect: "NoSchedule"
      # Hard requirement to schedule on the exact node holding the local PV
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - k8s-node2
      containers:
        - name: redis
          image: redis:7-alpine
          command: ["redis-server"]
          args: ["--requirepass", "$(REDIS_PASSWORD)"]
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-credentials
                  key: password
          ports:
            - containerPort: 6379
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          # The kubelet executes the readinessProbe via the container runtime.
          # If it fails, the pod is removed from the Service endpoints.
          readinessProbe:
            exec:
              command: ["sh", "-c", "redis-cli -a \"$REDIS_PASSWORD\" ping | grep PONG"]
            initialDelaySeconds: 5
            periodSeconds: 5
          # If the livenessProbe fails, the kubelet kills and restarts the container.
          livenessProbe:
            exec:
              command: ["sh", "-c", "redis-cli -a \"$REDIS_PASSWORD\" ping | grep PONG"]
            initialDelaySeconds: 15
            periodSeconds: 10
          volumeMounts:
            - name: redis-data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: redis-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-redis
        resources:
          requests:
            storage: 4Gi
```

#### 10. `10-deployment-redisinsight.yaml`
**Backend Mechanics:** The Deployment controller creates a ReplicaSet, which creates the pod. Because this is stateless, the pod gets a random hash in its name. The kubelet performs HTTP GET requests to the `/health` endpoint. If it returns a 200 OK, the pod is marked Ready and added to the Service endpoints.

```yaml
# The Deployment controller creates a ReplicaSet, which creates the pod. 
# Because this is stateless, the pod gets a random hash in its name. 
# The kubelet performs HTTP GET requests to the /health endpoint. If it 
# returns a 200 OK, the pod is marked Ready and added to the Service endpoints.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redisinsight
  namespace: redis-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redisinsight
  template:
    metadata:
      labels:
        app: redisinsight
    spec:
      containers:
        - name: redisinsight
          image: redis/redisinsight:latest
          ports:
            - containerPort: 5540
          env:
            - name: RI_REDIS_HOST
              value: "redis-db"
            - name: RI_REDIS_PORT
              value: "6379"
            - name: RI_REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-credentials
                  key: password
            - name: RI_REDIS_NAME
              value: "Lab Redis DB"
          # Resource requests are strictly required for HPA to calculate
          # utilization percentages. Without requests, HPA cannot function.
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          readinessProbe:
            httpGet:
              path: /health
              port: 5540
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 5540
            initialDelaySeconds: 30
            periodSeconds: 10
```

#### 11. `11-deployment-nginx-proxy.yaml`
**Backend Mechanics:** Creates two NGINX pods. The `subPath` volume mount ensures that only the `default.conf` file from the ConfigMap is injected into `/etc/nginx/conf.d/`, leaving the rest of the default NGINX directory structure intact from the base Docker image.

```yaml
# Creates two NGINX pods. The 'subPath' volume mount ensures that only the 
# default.conf file from the ConfigMap is injected into /etc/nginx/conf.d/, 
# leaving the rest of the default NGINX directory structure (like nginx.conf 
# and mime.types) intact from the base Docker image.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-proxy
  namespace: redis-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-proxy
  template:
    metadata:
      labels:
        app: nginx-proxy
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - name: nginx-config-volume
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
      volumes:
        - name: nginx-config-volume
          configMap:
            name: nginx-proxy-config
```

#### 12. `12-ingress.yaml`
**Backend Mechanics:** The core API server simply stores this rule in etcd. The F5 NGINX Ingress Controller watches the API server for Ingress objects. When it sees this object, it dynamically rewrites its internal `nginx.conf` file to add a server block for `myredislab.dev` that proxies traffic to the `nginx-proxy` ClusterIP, and then gracefully reloads its worker processes.

```yaml
# The core API server simply stores this rule in etcd. The F5 NGINX Ingress 
# Controller (running in its own namespace) watches the API server for Ingress 
# objects. When it sees this object, it dynamically rewrites its internal 
# nginx.conf file to add a server block for myredislab.dev that proxies 
# traffic to the nginx-proxy ClusterIP, and then gracefully reloads its 
# worker processes.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: redisinsight-ingress
  namespace: redis-lab
spec:
  ingressClassName: nginx
  rules:
    - host: myredislab.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
```

#### 13. `13-hpa.yaml`
**Backend Mechanics:** The HPA controller runs a reconciliation loop every 15 seconds. It queries the Metrics Server API to get the current CPU and memory usage of the pods. It calculates the average utilization against the `resources.requests` defined in the pod spec. If the average exceeds the target, it updates the `spec.replicas` field of the target Deployment.

```yaml
# The HPA controller runs a reconciliation loop every 15 seconds. It queries 
# the Metrics Server API to get the current CPU and memory usage of the pods 
# in the target Deployment. It calculates the average utilization against the 
# 'resources.requests' defined in the pod spec. If the average exceeds the 
# target, it updates the 'spec.replicas' field of the target Deployment, 
# triggering the Deployment controller to spin up new pods.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: redisinsight-hpa
  namespace: redis-lab
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: redisinsight
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
  behavior:
    scaleDown:
      # Wait 5 minutes before scaling down to prevent premature termination
      stabilizationWindowSeconds: 300
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nginx-proxy-hpa
  namespace: redis-lab
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: nginx-proxy
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 75
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
```

---

### Phase 3: Execution Steps

Apply the manifests from your master node in this exact order. Services are applied before workloads to ensure DNS resolution is ready when pods start.

```bash
cd redis-lab-manifests

# 1. Core Primitives
kubectl apply -f 01-namespace.yaml
kubectl apply -f 02-secret.yaml
kubectl apply -f 03-configmap-nginx.yaml

# 2. Networking (Applied before workloads so DNS is ready)
kubectl apply -f 04-service-redis-headless.yaml
kubectl apply -f 05-service-redis-db.yaml
kubectl apply -f 06-service-redisinsight.yaml
kubectl apply -f 07-service-nginx-proxy.yaml

# 3. Storage and Database
kubectl apply -f 08-local-pv.yaml
kubectl apply -f 09-statefulset-redis-db.yaml

# 4. Application and Proxy
kubectl apply -f 10-deployment-redisinsight.yaml
kubectl apply -f 11-deployment-nginx-proxy.yaml

# 5. External Routing and Scaling
kubectl apply -f 12-ingress.yaml
kubectl apply -f 13-hpa.yaml
```

---

### Phase 4: Verification and PV Testing

Run these commands to validate the backend mechanics, storage binding, and host-level SELinux configurations.

**1. Verify Pod Scheduling and Taints**
```bash
kubectl get pods -n redis-lab -o wide
```
*Expected: `redis-db-0` must be running strictly on `k8s-node2`. The RedisInsight and NGINX pods should be distributed across your other available nodes because they lack the toleration for `k8s-node2`.*

**2. Verify Storage Binding**
```bash
kubectl get pv,pvc -n redis-lab
```
*Expected: `redis-local-pv` shows status `Bound`. `redis-data-redis-db-0` shows status `Bound` and is linked to the PV.*

**3. Test PV Write Permissions (The Ultimate SELinux Validation)**
This step proves that the `chcon` and `chown` commands from Phase 1 successfully bypassed AlmaLinux SELinux restrictions and that the PV is correctly mounted.
```bash
kubectl exec -it redis-db-0 -n redis-lab -- touch /data/test_write_success
kubectl exec -it redis-db-0 -n redis-lab -- ls -l /data/test_write_success
```
*Expected: The commands succeed without a "Permission denied" error. If this fails, the SELinux context `container_file_t` was not applied correctly to `/mnt/mydisk/redis-data` on the host.*

**4. Verify HPA Metrics**
```bash
kubectl get hpa -n redis-lab
```
*Expected: The `TARGETS` column shows actual percentages (e.g., `2%/70%`). If it shows `<unknown>`, your cluster's Metrics Server is not installed or functioning.*

**5. End-to-End Traffic Test**
Ensure your local machine's hosts file contains:
```text
10.0.0.200 myredislab.dev
```
Open your browser and navigate to `http://myredislab.dev`. The request will traverse MetalLB, hit the F5 Ingress Controller, route to the NGINX proxy pods, proxy to the RedisInsight pods, and finally connect to the Redis database writing data directly to the physical NVMe drive attached to `k8s-node2`.