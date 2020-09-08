# Using git with proxy

Git-sync supports using a proxy through git-configuration.

## Background

See [issue 180](https://github.com/kubernetes/git-sync/issues/180) for a background.
See [Github documentation](https://docs.github.com/en/github/authenticating-to-github/using-ssh-over-the-https-port) specifically for GitHub.
Lastly, [see similar issue for FluxCD](https://github.com/fluxcd/flux/pull/3152) for configuration.

## Step 1: Create configuration

Create a ConfigMap to store your configuration:

```bash
cat << EOF >> /tmp/ssh-config
Host github.com
    ProxyCommand socat STDIO PROXY:<proxyIP>:%h:%p,proxyport=<proxyport>,proxyauth=<proxyAuth>
    User git
    Hostname ssh.github.com
    Port 443
    IdentityFile /etc/git-secret/ssh
EOF

kubectl create configmap ssh-config --from-file=ssh-config=/tmp/ssh-config
```

then mount this under `~/.ssh/config`, typically `/tmp/.ssh/config`:

```yaml
...
apiVersion: v1
kind: Pod
...
spec:
  containers:
    - name: git-sync
      ...
      volumeMounts:
        - name: ssh-config
          mountPath: /tmp/.ssh/config
          readOnly: true
          subPath: ssh-config
  volumes:
    - name: ssh-config
      configMap:
        name: ssh-config
```