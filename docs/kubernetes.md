# Using git-sync in kubernetes

This document provides a trivialized example of running a multi-container pod
in Kubernetes, with git-sync pulling data and an HTTP server serving it.

## YAML

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: git-sync-example
spec:
  replicas: 1
  selector:
    matchLabels:
      app: git-sync-example
  template:
    metadata:
      labels:
        app: git-sync-example
    spec:
      securityContext:
        # Set this to any valid GID, and two things happen:
        #   1) The volume "content-from-git" is group-owned by this GID.
        #   2) This GID is added to each container.
        fsGroup: 101
      volumes:
        - name: content-from-git
          emptyDir: {}
      containers:
        - name: git-sync
          # This container pulls git data and publishes it into volume
          # "content-from-git".  In that volume you will find a symlink
          # "current" (see -dest below) which points to a checked-out copy of
          # the master branch (see -branch) of the repo (see -repo).
          # NOTE: git-sync already runs as non-root.
          image: k8s.gcr.io/git-sync/git-sync:v4.0.0
          args:
            - --repo=https://github.com/kubernetes/git-sync
            - --branch=master
            - --depth=1
            - --period=60
            - --link=current
            - --root=/git
          volumeMounts:
            - name: content-from-git
              mountPath: /git
        - name: server
          # This container serves the data pulled from git, via the volume
          # "content-from-git".
          # NOTE: apache runs as root to expose port 80, and there's not a
          # trivial flag to change that.  Real servers should not run as root
          # when possible.
          image: httpd:alpine
          volumeMounts:
            - name: content-from-git
              mountPath: /usr/local/apache2/htdocs/
              readOnly: true # no need to ever write to the volume
```
