### BETA ###

# k8s-exec-bridge

Checkout / checkin scripts for JIT Kubernetes container exec access via the
**Britive Bridge platform**.

On checkout, a temporary RBAC RoleBinding is created granting the user exec
access to pods in a namespace. A short-lived bearer token is obtained (via
EKS `get-token`, a custom command, or a mounted service account) and passed
to Bridge so the k8s exec proxy can authenticate on the user's behalf. The
user receives a browser-accessible URL and never handles the token directly.
On checkin, the Bridge session is terminated and the RoleBinding is deleted.

---

## Files

| File | Purpose |
|---|---|
| `checkout_k8s_bridge.sh` | Create RBAC binding + register Bridge k8sexec session |
| `checkin_k8s_bridge.sh` | Terminate Bridge session + delete RBAC binding |

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
| --- | --- |
| `BRITIVE_USER_EMAIL` | Britive user email — used for RBAC binding subject and username derivation |
| `TRX` | Britive transaction ID for this checkout |
| `BRIDGE_URL` | Public base URL of the Bridge (e.g. `https://bridge.example.com`) — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |
| `KUBE_API_SERVER` | Kubernetes API server URL (e.g. `https://ABCDEF.gr7.us-west-2.eks.amazonaws.com`) — **checkout only** |
| `KUBE_NAMESPACE` | Target namespace for exec access |
| `KUBE_POD` | Target pod name — **checkout only** |

### Optional (with defaults)

| Variable | Default | Description |
| --- | --- | --- |
| `KUBE_CONTAINER` | _(empty — first container)_ | Target container within the pod |
| `KUBE_COMMAND` | `["/bin/sh"]` | Command to exec as a JSON array (e.g. `["/bin/bash"]`) |
| `KUBE_TTY` | `true` | Allocate a TTY for the exec session |
| `KUBE_ROLE` | `britive-exec` | Existing Role to bind to the user (must already exist in the namespace) |
| `KUBE_CONTEXT` | _(empty — current context)_ | kubectl context to use |
| `EKS_CLUSTER` | _(empty)_ | EKS cluster name — if set, uses `aws eks get-token` to obtain the bearer token |
| `AWS_REGION` | _(empty)_ | AWS region for EKS token (e.g. `us-west-2`). Uses default if unset |
| `KUBE_TOKEN_CMD` | _(empty)_ | Custom command to obtain a bearer token (overrides EKS and service account) |
| `BROKER_API` | `/opt/britive-broker/scripts/bridge.sh` | Path to the Bridge CLI |

> **Bearer token priority:** `KUBE_TOKEN_CMD` (custom command) > `EKS_CLUSTER`
> (`aws eks get-token`) > mounted service account token at
> `/var/run/secrets/kubernetes.io/serviceaccount/token`.

---

## How It Works

### Checkout (`checkout_k8s_bridge.sh`)

1. Derives a K8s-safe username from `BRITIVE_USER_EMAIL` (lowercase alphanumeric, max 63 chars).
2. Creates a RoleBinding `britive-<username>-<TRX>` in the target namespace, binding the
   pre-existing `KUBE_ROLE` to the user's email identity.
3. Obtains a bearer token for the K8s API — via `KUBE_TOKEN_CMD`, `aws eks get-token`, or
   a mounted service account token.
4. Calls `bridge.sh checkout-create` with the k8sexec payload including the bearer token,
   pod, namespace, and command.
5. Returns:

   ```json
   {"token": "<token>", "url": "https://bridge.example.com/k8s/#token=<token>&transaction_id=<TRX>"}
   ```

### Checkin (`checkin_k8s_bridge.sh`)

1. Calls `bridge.sh checkout-delete` to terminate the active exec WebSocket session first.
2. Deletes the RoleBinding `britive-<username>-<TRX>` from the namespace.
   Logs a warning (but does not fail) if the binding is already absent.

---

## EKS Cluster Setup

### 1. Create the exec Role in each target namespace

The checkout script binds users to an existing Role. Create it once per namespace:

```yaml
# britive-exec-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: britive-exec
  namespace: <NAMESPACE>
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
```

```sh
kubectl apply -f britive-exec-role.yaml -n <NAMESPACE>
```

To restrict exec to specific pods, add a `resourceNames` field:

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
    resourceNames: ["my-app-pod-xyz"]
```

### 2. Configure EKS authentication

The broker container needs to authenticate to the EKS API. Two approaches:

**Option A: IAM role for the broker (recommended)**

Attach an IAM role to the broker ECS task / EC2 instance with permission to call
`eks:DescribeCluster`. Then map that IAM role to a Kubernetes user in the
`aws-auth` ConfigMap:

```sh
# Get current aws-auth
kubectl get configmap aws-auth -n kube-system -o yaml > aws-auth.yaml
```

Add a `mapRoles` entry:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: arn:aws:iam::123456789012:role/BritivebrokerRole
      username: britivebroker
      groups: []
```

```sh
kubectl apply -f aws-auth.yaml
```

The broker's IAM role maps to `britivebroker` in K8s. The checkout script creates
per-user RoleBindings — `britivebroker` itself only needs the ability to create and
delete RoleBindings:

```yaml
# broker-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: britive-broker-manager
rules:
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["rolebindings"]
    verbs: ["create", "get", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: britive-broker-manager
subjects:
  - kind: User
    name: britivebroker
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: britive-broker-manager
  apiGroup: rbac.authorization.k8s.io
```

```sh
kubectl apply -f broker-rbac.yaml
```

With this setup, set `EKS_CLUSTER` and `AWS_REGION` on the permission, and the
checkout script calls `aws eks get-token` to get a short-lived bearer token.

**Option B: Service account token (non-EKS or custom)**

Create a ServiceAccount with exec privileges and mount its token into the broker
container. The checkout script will read
`/var/run/secrets/kubernetes.io/serviceaccount/token` automatically.

### 3. Network requirements

- The broker container must be able to reach the EKS API server endpoint
  (either the public endpoint or via VPC private endpoint).
- The Bridge container must be able to reach the EKS API server to proxy the
  exec WebSocket connection.
- If using private endpoints, ensure the broker and Bridge security groups allow
  outbound HTTPS (443) to the EKS API server security group.

### 4. Verify connectivity from the broker container

```sh
# Verify kubectl can reach the cluster
kubectl cluster-info

# Verify the broker identity
kubectl auth whoami

# Verify the broker can create rolebindings
kubectl auth can-i create rolebindings --namespace=<NAMESPACE>

# Verify the exec role exists
kubectl get role britive-exec -n <NAMESPACE>

# Test exec manually
kubectl exec -it <POD> -n <NAMESPACE> -- /bin/sh
```

For EKS specifically:

```sh
# Verify aws CLI and EKS token
aws eks get-token --cluster-name <CLUSTER> --region <REGION> --output text --query 'status.token' | head -c 20
echo "..."

# Verify the token works
TOKEN=$(aws eks get-token --cluster-name <CLUSTER> --region <REGION> --output text --query 'status.token')
kubectl --token="$TOKEN" auth whoami
```

---

## Broker Container Requirements

- `kubectl` configured with access to the target cluster (kubeconfig or in-cluster credentials)
- `python3` (for username derivation and JSON encoding)
- `bridge.sh` at the `BROKER_API` path
- For EKS: `aws` CLI with IAM credentials that can call `eks:DescribeCluster`

---

## Britive Platform Setup

1. Create a broker pool connected to your Bridge deployment.
2. Create a `Bridge` resource type with a `k8sexec` permission.
3. Set the following script parameters on the `k8sexec` permission:

   **Always required:** `TRANSACTION_ID`, `PROTOCOL` (set to `k8sexec`), `USERNAME`,
   `EXPIRATION`, `BRIDGE_URL`, `KUBE_API_SERVER`, `KUBE_NAMESPACE`, `KUBE_POD`

   **EKS:** `EKS_CLUSTER`, `AWS_REGION`

   **Optional:** `KUBE_CONTAINER`, `KUBE_COMMAND`, `KUBE_TTY`, `KUBE_ROLE`, `KUBE_CONTEXT`

4. Set the response template to `Bridge Session URL` (uses `{{url}}` from the checkout output).
5. Assign users or tags to the profile policy.

---

## Example: Manual Test Run

```sh
export BRITIVE_USER_EMAIL="alice@corp.com"
export TRX="test-001"
export BRIDGE_URL="https://bridge.corp:8080"
export EXPIRATION="3600"
export KUBE_API_SERVER="https://ABCDEF.gr7.us-west-2.eks.amazonaws.com"
export KUBE_NAMESPACE="dev"
export KUBE_POD="my-app-7b9f5d4c6-x2k9p"
export EKS_CLUSTER="my-eks-cluster"
export AWS_REGION="us-west-2"
export KUBE_ROLE="britive-exec"

sh checkout_k8s_bridge.sh
# {"token": "...", "url": "https://bridge.corp:8080/k8s/#token=...&transaction_id=test-001"}

# To clean up:
export BRITIVE_USER_EMAIL="alice@corp.com"
export TRX="test-001"
export KUBE_NAMESPACE="dev"

sh checkin_k8s_bridge.sh
```
