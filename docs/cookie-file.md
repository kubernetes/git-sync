# Using an HTTP cookie file with git-sync

Git-sync supports use of an HTTP cookie file for accessing git content.

## Step 1: Create a Secret

First, create a Kubernetes Secret from the git cookie file you wish to
use.

Example: if the cookie-file is `~/.gitcookies`:

```bash
kubectl create secret generic git-cookie-file --from-file=cookie_file=~/.gitcookies
```

Note that the key is `cookie_file`. This is the filename that git-sync will look
for.

## Step 2: Configure a Pod/Deployment volume

In your Pod or Deployment configuration, specify a volume for mounting the
cookie-file Secret. Make sure to set `secretName` to the same name you used to
create the secret (`git-cookie-file` in the example above).

```yaml
volumes:
  - name: git-secret
    secret:
      secretName: git-cookie-file
      defaultMode: 0440
```

## Step 3: Configure a git-sync container

In your git-sync container configuration, mount your volume at
"/etc/git-secret". Make sure to pass the `--cookie-file` flag or set the
environment variable `GITSYNC_COOKIE_FILE` to "true", and to use a git repo
(`--repo` or `GITSYNC_REPO`) with an HTTP URL.

```yaml
name: "git-sync"
...
env:
  - name: GITSYNC_REPO
    value: https://github.com/kubernetes/kubernetes.git
  - name: GITSYNC_COOKIE_FILE
    value: true
volumeMounts:
  - name: git-secret
    mountPath: /etc/git-secret
    readOnly: true
```
