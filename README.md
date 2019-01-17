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

git-sync can also be configured to make webhook call upon sucessful git repo syncronisation. The call is made when right after the symlink is updated.

## Usage

```
# build the container
make container REGISTRY=registry VERSION=tag

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

## Example of webhooks usage
**Webhook config example**
A webhook config must be valid JSON. If `success` is not specified in the config, git-sync will continue regardless of response code (including errors).

```json
{   
    "url": "http://localhost:9090/-/reload", 
    "method": "POST",
    "success": 200
}
```
**Usage**

```
docker run -d \
    -v /tmp/git-data:/git \
    registry/git-sync:tag \
        --repo=https://github.com/kubernetes/git-sync
        --branch=master
        --wait=30
        --webhook='[{"url": "http://localhost:9090/-/reload", "method": "POST", "success": 200}]'
        --webhook='[{"url": "http://1.2.3.4:9090/-/reload", "method": "POST"}]'
```
[![Analytics](https://kubernetes-site.appspot.com/UA-36037335-10/GitHub/git-sync/README.md?pixel)]()
