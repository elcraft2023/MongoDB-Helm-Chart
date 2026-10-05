# HashiCorp Vault integration

The integration uses Vault KV v2, Vault Agent Injector, and Vault Secrets
Operator (VSO):

- Vault Agent reads the MongoDB administrator password directly from Vault and
  renders it as `/vault/secrets/admin-password` in MongoDB, bootstrap, backup,
  and restore pods. The password is not a Helm value or Kubernetes Secret.
- VSO synchronizes only the internal replica-set keyfile and TLS material to
  Kubernetes Secrets consumed by the chart.

## Prerequisites

- A `mongodb` namespace and a Vault service reachable from the cluster.
- Vault KV v2 mounted at `secret`.
- Vault Kubernetes authentication configured.
- Vault Agent Injector enabled and its mutating webhook ready.
- Vault Secrets Operator installed for the keyfile and TLS secrets.
- A Kubernetes auth role `mongodb-reader`, bound to service account
  `mongodb-vault-reader` in namespace `mongodb`, with the policy in
  `mongodb-read.hcl`.

The optional disposable Minikube setup uses Vault chart `0.34.1` and VSO
`1.6.0`. The injector must be enabled:

```sh
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm upgrade --install vault hashicorp/vault --version 0.34.1 \
  --namespace vault --create-namespace \
  --set server.dev.enabled=true --set injector.enabled=true --wait --timeout 5m
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --version 1.6.0 --namespace vault-secrets-operator --create-namespace \
  --wait --timeout 5m
```

The dev server uses in-memory storage and a demo root token. It is only for a
disposable local cluster, not production.

## Kubernetes authentication and policy

Configure the Kubernetes auth backend, write the restricted policy, and bind
the role. These example commands use the dev-only `root` token inside the Vault
pod; never use that pattern for a persistent or production Vault.

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

The Vault Agent Injector authenticates pods using the
`mongodb-vault-reader` ServiceAccount. The chart references this account by
default through `auth.serviceAccountName`.

## Store values in Vault

Use the Vault UI or another authenticated Vault client. In KV v2, create these
paths and fields:

| Vault path | Fields | Consumer |
| --- | --- | --- |
| `secret/mongodb/auth` | `password` | Vault Agent file; not a Kubernetes Secret |
| `secret/mongodb/internal-auth` | `keyfile` | VSO creates `mongodb-internal-auth` |
| `secret/mongodb/tls/mongo-0` | `tls.crt`, `tls.key`, `ca.crt` | VSO creates `mongo-0-tls` |
| `secret/mongodb/tls/mongo-1` | `tls.crt`, `tls.key`, `ca.crt` | VSO creates `mongo-1-tls` |
| `secret/mongodb/tls/mongo-2` | `tls.crt`, `tls.key`, `ca.crt` | VSO creates `mongo-2-tls` |

Enter the administrator password directly into Vault at `secret/mongodb/auth`,
field `password`. Do not create or retain a local admin-password file, place the
value in Helm Values, or put it in a command line.

For the KV v2 mount `secret`, the Vault Agent annotation reads API path
`secret/data/mongodb/auth`. Its template extracts `.Data.data.password` and
writes the file `/vault/secrets/admin-password` inside the selected container.
The Vault Agent runs in pre-population-only mode: it writes the file before the
application starts and does not continuously refresh it.

Keyfile and TLS values are still synchronized to Kubernetes Secrets by VSO.
Never commit Vault tokens, certificates, private keys, passwords, Vault data,
or Kubernetes Secret exports.

## Apply and verify

Apply the VSO resources after Vault, KV values, Kubernetes auth, and the policy
are ready:

```sh
kubectl apply -f vault/vso-mongodb.yaml
kubectl get vaultstaticsecrets -n mongodb
```

Wait until each `VaultStaticSecret` is synchronized and healthy. Ensure the
Vault Agent Injector webhook is ready before creating MongoDB pods. Install or
upgrade the MongoDB chart without supplying a password value:

```sh
helm lint ./mongodb-chart
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb --wait --timeout 10m
kubectl get pods -n mongodb
kubectl rollout status statefulset/mongodb -n mongodb --timeout=5m
```

Each MongoDB, bootstrap, backup, and restore pod template uses Vault Agent
annotations and the `mongodb-vault-reader` ServiceAccount. The agent renders
the password only into the application's injected file volume. The application
container checks that the file exists before starting or running a job.

For an existing installation that previously synchronized `mongodb-auth`,
write the currently valid MongoDB password into Vault first and apply the
updated policy and VSO manifest. Build a values file containing only the
non-secret overrides required by the deployment, then upgrade with
`--reset-values` (not `--reuse-values`) so a previously stored
`auth.password` value is not copied into the new Helm release:

```sh
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb --reset-values -f production-values.yaml \
  --wait --timeout 10m
```

Do not put the password in `production-values.yaml`. After verifying the new
pods and authentication, remove the obsolete password synchronizer and Secret
only after confirming no other workload uses them:

```sh
kubectl delete vaultstaticsecret mongodb-auth-from-vault -n mongodb --ignore-not-found
kubectl delete secret mongodb-auth -n mongodb --ignore-not-found
```

An older Helm release revision may still contain the password in its stored
values. `--reset-values` cleans the new revision; it does not automatically
rewrite all previous release history. If policy requires purging that history,
plan an explicit Helm-history cleanup or uninstall/reinstall procedure with the
platform owner. Removing rollback history has operational consequences.

## Password rotation

Vault Agent uses a startup-only file, so a Vault KV update by itself does not
change the password already stored in MongoDB and does not refresh existing pod
files. Coordinate rotation:

1. Change the MongoDB admin user's password on the current Primary using the
   existing valid credentials.
2. Update `secret/mongodb/auth`, field `password`, in Vault to the same value.
3. Restart the StatefulSet so MongoDB pods fetch the new file:

   ```sh
   kubectl rollout restart statefulset/mongodb -n mongodb
   kubectl rollout status statefulset/mongodb -n mongodb --timeout=5m
   ```
4. Verify MongoDB authentication and the replica-set status. Newly created
   bootstrap, backup, and restore pods will also read the current Vault value.

Use a planned, coordinated procedure; restarting members can affect availability.
The replica-set keyfile is a separate credential and needs its own coordinated
rotation procedure.

## Scope

This is an integration example, not a production Vault deployment. Persistent
Vault storage, TLS to Vault, secure initialization/unseal, restricted RBAC,
external backups, monitoring, and a fully automated credential-rotation
workflow need environment-specific configuration.
