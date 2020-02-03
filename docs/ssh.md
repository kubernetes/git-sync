# Using SSH with git-sync

Git-sync supports using the SSH protocol for pulling git content.

## Step 1: Create Secret

Create a Secret to store your SSH private key, with the Secret keyed as "ssh".
This can be done one of two ways:

***Method 1:***

Obtain the host keys for your git server:

```bash
ssh-keyscan $YOUR_GIT_HOST > /tmp/known_hosts
```

Use the `kubectl create secret` command and point to the file on your
filesystem that stores the key. Ensure that the file is mapped to "ssh" as
shown (the file can be located anywhere).

```bash
kubectl create secret generic git-creds \
    --from-file=ssh=$HOME/.ssh/id_rsa \
    --from-file=known_hosts=/tmp/known_hosts
```

***Method 2:***

Write a config file for a Secret that holds your SSH private key, with the key
(pasted in base64 encoded plaintext) mapped to the "ssh" field.

```json
{
  "kind": "Secret",
  "apiVersion": "v1",
  "metadata": {
    "name": "git-creds"
  },
  "data": {
    "ssh": <base64 encoded private-key>
    "known_hosts": <base64 encoded known_hosts>
  }
}
```

Create the Secret using `kubectl create -f`.

```bash
kubectl create -f /path/to/secret-config.json
```

## Step 2: Configure Pod/Deployment volume

In your Pod or Deployment configuration, specify a volume for mounting the
Secret. Ensure that secretName matches the name you used when creating the
Secret (e.g. "git-creds" used in both above examples).

```yaml
      # ...
      volumes:
      - name: git-secret
        secret:
          secretName: git-creds
          defaultMode: 0400
      # ...
```

## Step 3: Configure git-sync container

In your git-sync container configuration, mount the Secret volume at
"/etc/git-secret". Ensure that the `-repo` flag (or the GIT_SYNC_REPO
environment variable) is set to use the SSH protocol (e.g.
git@github.com/foo/bar) , and set the `-ssh` flags (or set GIT_SYNC_SSH to
"true").  You will also need to set your container's `securityContext` to run
as user ID "65533" which is created for running git-sync as non-root.

```yaml
      # ...
      containers:
      - name: git-sync
        image: k8s.gcr.io/git-sync:v3.1.5
        args:
         - "-ssh"
         - "-repo=git@github.com:foo/bar"
         - "-dest=bar"
         - "-branch=master"
        volumeMounts:
        - name: git-secret
          mountPath: /etc/git-secret
        securityContext:
          runAsUser: 65533 # git-sync user
      # ...
```

Lastly, you need to tell your Pod to run with the git-sync FS group.  Note
that this is a Pod-wide setting, unlike the container `securityContext` above.

```yaml
      # ...
      securityContext:
        fsGroup: 65533 # to make SSH key readable
      # ...
```

If you want git-sync to run as a different (non-root) UID and GID, you can
change these last blocks to any UID/GID you like.  SSH demands that the current
UID be present in /etc/passwd, so in this case you will need to add the
`--add-user` flag to git-sync's args array.

**Note:** Kubernetes mounts the Secret with permissions 0444 by default (not
restrictive enough to be used as an SSH key), so make sure you set the
`defaultMode`.

## Full example

In case the above YAML snippets are confusing (because whitespace matters in
YAML), here is a full example:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: git-sync
spec:
  selector:
    matchLabels:
      demo: git-sync
  template:
    metadata:
      labels:
        demo: git-sync
    spec:
      volumes:
      - name: git-secret
        secret:
          secretName: git-creds
          defaultMode: 0400
      containers:
      - name: git-sync
        image: k8s.gcr.io/git-sync:v3.1.5
        args:
         - "-ssh"
         - "-repo=git@github.com:torvalds/linux"
         - "-dest=linux"
         - "-branch=master"
         - "-depth=1"
        securityContext:
          runAsUser: 65533 # git-sync user
        volumeMounts:
        - name: git-secret
          mountPath: /etc/git-secret
          readOnly: true
      securityContext:
        fsGroup: 65533 # to make SSH key readable
```
