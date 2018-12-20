# git-sync

git-sync is a simple command that pulls a git repository into a local directory.
It is a perfect "sidecar" container in Kubernetes - it can periodically pull
files down from a repository so that an application can consume them.

git-sync can pull one time, or on a regular interval.  It can pull from the HEAD
of a branch, or from a git tag, or from a specific git hash.  It will only
re-pull if the target of the run has changed in the upstream repository.  When
it re-pulls, it updates the destination directory atomically.  In order to do
this, it uses a git worktree in a subdirectory of the `--root` and flips a
symlink.

## Usage

```
# build the container
make container REGISTRY=registry VERSION=tag

# build the container behind a proxy
make container REGISTRY=registry VERSION=tag HTTP_PROXY=http://<proxy_address>:<proxy_port> HTTPS_PROXY=https://<proxy_address>:<proxy_port>

# run the container
docker run -d \
    -v /tmp/git-data:/tmp/git \
    registry/git-sync:tag \
        --repo=https://github.com/kubernetes/git-sync
        --branch=master
        --wait=30

# run an nginx container to serve the content
docker run -d \
    -p 8080:80 \
    -v /tmp/git-data:/usr/share/nginx/html \
    nginx
```

[![Analytics](https://kubernetes-site.appspot.com/UA-36037335-10/GitHub/git-sync/README.md?pixel)]()
