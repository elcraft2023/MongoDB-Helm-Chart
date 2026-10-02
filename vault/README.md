# HashiCorp Vault integration (demo)

This setup uses Vault KV v2 and the Vault Secrets Operator (VSO). VSO syncs Vault values into Kubernetes Secrets consumed by the existing MongoDB chart. Vault is the source of truth, but the values still exist as Kubernetes Secrets and are readable by Kubernetes identities that have permission to read those Secrets.

## Prerequisites

- A `mongodb` namespace and the MongoDB Helm release named `mongodb`.
- Vault reachable as `vault.vault.svc.cluster.local:8200` from the cluster.
- Vault Kubernetes authentication enabled and configured, plus VSO installed.
- A Vault Kubernetes auth role named `mongodb-reader`, bound to service account `mongodb-vault-reader` in namespace `mongodb`.
- The policy in `mongodb-read.hcl` attached to that role.
- KV v2 mounted at `secret`.

The versions used in the local demo were Vault Helm chart `0.34.1` and VSO `1.6.0`. For a fresh disposable Minikube demo, install them with:

```sh
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm upgrade --install vault hashicorp/vault --version 0.34.1 \
  --namespace vault --create-namespace \
  --set server.dev.enabled=true --set injector.enabled=false --wait --timeout 5m
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --version 1.6.0 --namespace vault-secrets-operator --create-namespace \
  --wait --timeout 5m
```

Configure Kubernetes auth, the read-only policy, and its role in the demo Vault. The commands use Vault's dev-only `root` token inside the Vault pod; never reuse this pattern for a persistent or production Vault:

```sh
kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault --dry-run=client -o yaml | kubectl apply -f -

kubectl exec -n vault vault-0 -- sh -ec '
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
  vault auth list -format=json | grep -q kubernetes/ || vault auth enable kubernetes
  vault write auth/kubernetes/config \
    kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:443" \
    token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
'

kubectl exec -i -n vault vault-0 -- sh -ec '
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
  vault policy write mongodb-read -
' < vault/mongodb-read.hcl

kubectl exec -n vault vault-0 -- sh -ec '
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
  vault write auth/kubernetes/role/mongodb-reader \
    bound_service_account_names=mongodb-vault-reader \
    bound_service_account_namespaces=mongodb \
    policies=mongodb-read ttl=1h
'
```

The three prerequisites above create the auth backend, policy, and role; the manifest creates the service account. Populate the KV paths below from the local ignored files using an authenticated Vault CLI session. Do not put secret values directly in shell commands or commit them.

The working local test used a Vault dev server with in-memory storage and a root token. That is suitable only for this disposable Minikube demo: restarting/recreating Vault loses the stored data and root token. Use persistent storage, TLS, and a proper initialization/unseal or auto-unseal setup before relying on it. Never commit a Vault token, initialized Vault data, password, private key, certificate, or Kubernetes Secret export.

## Vault secret layout

Populate these KV v2 paths with the listed fields. Import the existing local credentials and certificates without printing their contents or putting them in chart values:

| Vault path | Fields |
| --- | --- |
| `secret/mongodb/auth` | `username`, `password` |
| `secret/mongodb/internal-auth` | `keyfile` |
| `secret/mongodb/tls/mongo-0` | `tls.crt`, `tls.key`, `ca.crt` |
| `secret/mongodb/tls/mongo-1` | `tls.crt`, `tls.key`, `ca.crt` |
| `secret/mongodb/tls/mongo-2` | `tls.crt`, `tls.key`, `ca.crt` |

The source files belong in the ignored local `certs/` directory. The MongoDB chart continues to reference the destination Kubernetes Secrets by name; it does not place secret values in `values.yaml`.

## Apply and verify

From the repository root, apply `vault/vso-mongodb.yaml` after Vault, VSO, the KV values, and the Kubernetes auth role are ready:

```sh
kubectl apply -f vault/vso-mongodb.yaml
kubectl get vaultstaticsecrets -n mongodb
kubectl get pods -n mongodb
```

Each `VaultStaticSecret` should show `SYNCED`, `HEALTHY`, and `READY` as `True`. The three TLS resources request a StatefulSet rollout when their source values change, so the init containers copy the updated certificates into the pod. If the Helm release or namespace uses different names, update the destination names and `rolloutRestartTargets` accordingly.

## Rotation notes

- The smoke-test secret used to verify VSO refresh was removed after the rotation test passed.
- A Vault password update only updates the destination Kubernetes Secret. It does not change the password stored in MongoDB. Coordinate a MongoDB user password change with the Vault update; do not rotate this value by changing Vault alone.
- TLS updates trigger a StatefulSet rollout through the three TLS `VaultStaticSecret` resources.
- The replica-set keyfile is shared by all members. Its rotation requires a planned, coordinated MongoDB procedure; this manifest deliberately does not automatically restart the set when that key changes.

## Scope

This is a working local integration guide and manifest set, not a production Vault deployment. Vault bootstrap, policy/role creation, certificate provisioning, storage durability, TLS to Vault, disaster recovery, and a complete automated credential-rotation workflow still need environment-specific configuration.
