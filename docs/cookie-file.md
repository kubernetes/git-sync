# Using an Http Cookie File with git-sync

Git-sync supports use of an HTTP Cookie File for accessing git content.

## Step 1: Create Secret

First, create a secret file from the git cookie file you wish to
use.

Example: if the cookie-file is `~/.gitcookies`:

```bash
kubectl create secret generic git-cookie-file --from-file=cookie_file=~/.gitcookies
```

Note that the key is `cookie_file`. This is the filename that git-sync will look
for.

## Step 2: Configure Pod/Deployment Volume

In your Pod or Deployment configuration, specify a Volume for mounting the
cookie-file Secret. Make sure to set `secretName` to the same name you used to
create the secret (`git-cookie-file` in the example above).

```yaml
volumes:
  - name: git-secret
    secret:
      secretName: git-cookie-file
      defaultMode: 0440
```

## Step 3: Configure git-sync container

In your git-sync container configuration, mount your volume at
"/etc/git-secret". Make sure to pass the `--cookie-file` flag or set the
environment variable `GIT_COOKIE_FILE` to "true", and to use a git repo
(`--repo` flag or `GIT_SYNC_REPO` env) is set to use a URL with the HTTP
protocol.

```yaml
name: "git-sync"
...
env:
  - name: GIT_SYNC_REPO
    value: https://github.com/kubernetes/kubernetes.git
  - name: GIT_COOKIE_FILE
    value: true
volumeMounts:
  - name: git-secret
    mountPath: /etc/git-secret
    readOnly: true
```
