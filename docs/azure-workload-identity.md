# Authenticating to Azure DevOps with Azure Workload Identity Federation

git-sync supports authenticating to Azure DevOps Services (`dev.azure.com`)
without any long-lived secret, by exchanging the pod's projected
ServiceAccount token for a short-lived Microsoft Entra ID (Azure AD)
access token.

This relies on
[Azure Workload Identity for Kubernetes](https://azure.github.io/azure-workload-identity/),
specifically the mutating admission webhook that injects the necessary env
vars and projected token volume into pods that opt in.

When you use this feature, **no PAT or password lives in a Kubernetes
Secret**. The federated SA token is rotated automatically by kubelet, and
git-sync re-mints the Entra access token before it expires.

## When to use this

- Your git repo is on Azure DevOps Services (`https://dev.azure.com/<org>/...`).
- Your cluster has the
  [`azure-workload-identity`](https://azure.github.io/azure-workload-identity/docs/installation.html)
  webhook installed.
- You'd rather not manage a PAT.

If your repo is on Azure DevOps **Server** (self-hosted) or you're using
SSH (`git@ssh.dev.azure.com:...`), this feature does not apply — use a
PAT or SSH key instead.

## Step 1: prerequisites on the Azure side

You need:

1. A Microsoft Entra ID application registration **or** a user-assigned
   managed identity. Note its **client ID** and **tenant ID**.

2. A **federated identity credential** on that app registration / managed
   identity, with:

   - **Issuer:** the OIDC issuer URL of your Kubernetes cluster
     (`kubectl get --raw /.well-known/openid-configuration | jq -r .issuer`).
   - **Subject:** `system:serviceaccount:<namespace>:<serviceaccount-name>`
     (the namespace + name of the ServiceAccount that git-sync's pod will
     run as).
   - **Audience:** `api://AzureADTokenExchange` (the AKS / OIDC default).

3. The application / managed identity must be **granted access to your
   Azure DevOps organization**. The simplest path:

   - In Azure DevOps, go to *Organization settings → Users → Add users*.
   - Add the app registration / managed identity as a member (search by
     its display name).
   - Grant it the necessary access level and at least Reader on the
     project / repo. For a write-back use case you'd want Contributor.

## Step 2: prerequisites on the Kubernetes side

Make sure the
[`azure-workload-identity`](https://azure.github.io/azure-workload-identity/docs/installation.html)
mutating webhook is installed in the cluster.

Then create (or annotate) the ServiceAccount that git-sync runs under:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: git-sync
  namespace: my-namespace
  annotations:
    azure.workload.identity/client-id: "<your-app-or-msi-client-id>"
```

## Step 3: configure the git-sync pod

Two things matter:

1. The **pod must have the label** `azure.workload.identity/use: "true"`.
   This is what tells the webhook to mutate it.
2. **git-sync** must be started with `--azure-workload-identity` (or
   `GITSYNC_AZURE_WORKLOAD_IDENTITY=true`).

A minimal example:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: git-sync
  namespace: my-namespace
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: git-sync
  containers:
    - name: git-sync
      image: registry.k8s.io/git-sync/git-sync:v4
      env:
        - name: GITSYNC_REPO
          value: "https://dev.azure.com/<org>/<project>/_git/<repo>"
        - name: GITSYNC_ROOT
          value: /tmp/git
        - name: GITSYNC_REF
          value: main
        - name: GITSYNC_AZURE_WORKLOAD_IDENTITY
          value: "true"
      volumeMounts:
        - name: out
          mountPath: /tmp/git
  volumes:
    - name: out
      emptyDir: {}
```

You do **not** need to set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_FEDERATED_TOKEN_FILE`, or `AZURE_AUTHORITY_HOST` yourself — the
webhook injects them when it sees the `azure.workload.identity/use: "true"`
label and the SA annotation. If you run without the webhook, or want to
override any of them, set the matching `--azure-*` flag (or `GITSYNC_AZURE_*`
env var) instead.

You also do **not** need `--username` / `--password` / `--password-file` /
`--askpass-url`; git-sync refuses to start if any of those are combined
with `--azure-workload-identity`.

## Flags

| Flag                          | Env var                          | Default                                              | Meaning |
|-------------------------------|----------------------------------|------------------------------------------------------|---------|
| `--azure-workload-identity`   | `GITSYNC_AZURE_WORKLOAD_IDENTITY`| `false`                                              | Opt-in: use AWI for HTTPS auth |
| `--azure-client-id`           | `GITSYNC_AZURE_CLIENT_ID`, `AZURE_CLIENT_ID` | (from webhook)                           | Entra client ID. Falls back to the webhook-injected `AZURE_CLIENT_ID`. |
| `--azure-tenant-id`           | `GITSYNC_AZURE_TENANT_ID`, `AZURE_TENANT_ID` | (from webhook)                           | Entra tenant ID. Falls back to `AZURE_TENANT_ID`. |
| `--azure-federated-token-file`| `GITSYNC_AZURE_FEDERATED_TOKEN_FILE`, `AZURE_FEDERATED_TOKEN_FILE` | (from webhook)      | Path to the projected federated token. Falls back to `AZURE_FEDERATED_TOKEN_FILE`. |
| `--azure-authority-host`      | `GITSYNC_AZURE_AUTHORITY_HOST`, `AZURE_AUTHORITY_HOST` | `https://login.microsoftonline.com/`| Entra authority host. Override only for sovereign clouds. |
| `--azure-scope`               | `GITSYNC_AZURE_SCOPE`            | `499b84ac-1321-427f-aa17-267ca6975798/.default`      | OAuth2 scope. Default is the Azure DevOps resource ID for the public cloud — override only for sovereign clouds or other Entra-protected resources. |

## Troubleshooting

**git-sync fails on startup with** *"--azure-workload-identity requires
--azure-client-id, --azure-tenant-id, and --azure-federated-token-file"*

The webhook didn't mutate the pod (and you didn't set the flags yourself).
Check:

- The pod has label `azure.workload.identity/use: "true"`.
- The ServiceAccount has annotation `azure.workload.identity/client-id`.
- The `azure-workload-identity` webhook is installed and its namespace
  selector (if any) covers the pod's namespace.
- The webhook pod itself is healthy: `kubectl -n azure-workload-identity-system get pods`.

**AADSTS70021: No matching federated identity record found**

The federated identity credential on the Entra app registration doesn't
match. The `subject` must be exactly
`system:serviceaccount:<namespace>:<serviceaccount-name>`, the
`audience` must be `api://AzureADTokenExchange`, and the `issuer` must
be your cluster's actual OIDC issuer URL. Get the issuer with:

```
kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
```

**AADSTS700213: No matching federated identity record found for
presented assertion subject**

Same root cause as AADSTS70021 — the `subject` field in the federated
credential doesn't match the SA. Note the namespace and SA name are
both case-sensitive.

**git fetch fails with TF401019 or 401 from Azure DevOps**

The Entra identity isn't authorized in the ADO org/project. Add it as
a user in *Organization settings → Users* and grant it project
permissions. The token-exchange itself can succeed while the resulting
token still lacks ADO access.

**Token works but expires mid-sync on a long clone**

Entra access tokens are typically valid for ~1 hour. If a single sync
takes longer than that and the connection needs to re-authenticate,
you'll see a mid-clone failure. git-sync refreshes between syncs, not
during a single git operation. Consider `--depth`, `--shallow-since`,
or partial-clone (`--filter`) to keep individual fetches short.

## Caveat: token visibility inside the pod

The Entra access token is stored in git's credential cache for the
duration of its expiry. Anyone with shell access into the git-sync pod
can read it. The pod is the trust boundary; mount no other
untrusted code into it.
