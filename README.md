# git-sync

git-sync is a simple command that pulls a git repository into a local directory.
It is a perfect "sidecar" container in Kubernetes - it can periodically pull
files down from a repository so that an application can consume them.

git-sync can pull one time, or on a regular interval.  It can pull from the
HEAD of a branch, from a git tag, or from a specific git hash.  It will only
re-pull if the target of the run has changed in the upstream repository.  When
it re-pulls, it updates the destination directory atomically.  In order to do
this, it uses a git worktree in a subdirectory of the `--root` and flips a
symlink.

git-sync can pull over HTTP(S) (with authentication or not) or SSH.

git-sync can also be configured to make a webhook call upon successful git repo
synchronization. The call is made after the symlink is updated.

## Building it

```
# build the container
make container REGISTRY=registry VERSION=tag
```

```
# build the container behind a proxy
make container REGISTRY=registry VERSION=tag \
    HTTP_PROXY=http://<proxy_address>:<proxy_port> \
    HTTPS_PROXY=https://<proxy_address>:<proxy_port>
```

```
# build the container for an OS/arch other than the current (e.g. you are on
# MacOS and want to run on Linux)
make container REGISTRY=registry VERSION=tag \
    GOOS=linux GOARCH=amd64
```

## Usage

```
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

## Webhooks

Webhooks are executed asynchronously from the main git-sync process. If a `webhook-url` is configured,
when a change occurs to the local git checkout a call is sent using the method defined in `webhook-method`
(default to `POST`). git-sync will continually attempt this webhook call until it succeeds (based on `webhook-success-status`).
If unsuccessful, git-sync will wait `webhook-backoff` (default `3s`) before re-attempting the webhook call.

**Usage**

A webhook is configured using a set of CLI flags. At its most basic only `webhook-url` needs to be set.

```
docker run -d \
    -v /tmp/git-data:/git \
    registry/git-sync:tag \
        --repo=https://github.com/kubernetes/git-sync
        --branch=master
        --wait=30
        --webhook-url="http://localhost:9090/-/reload"
```

[![Analytics](https://kubernetes-site.appspot.com/UA-36037335-10/GitHub/git-sync/README.md?pixel)]()
