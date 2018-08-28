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

# run the container
docker run -d \
    -v /tmp/git-data:/git \
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

## Env

| Name | Desc |
| --- | --- |
| GIT_SYNC_REPO | the git repository to clone |
| GIT_SYNC_BRANCH | the git branch to check out |
| GIT_SYNC_REV | the git revision (tag or hash) to check out |
| GIT_SYNC_DEPTH | use a shallow clone with a history truncated to the specified number of commits |
| GIT_SYNC_ROOT | the root directory for git operations |
| GIT_SYNC_DEST | the name at which to publish the checked-out files under --root (defaults to leaf dir of --repo) |
| GIT_SYNC_WAIT | the number of seconds between syncs |
| GIT_SYNC_ONE_TIME | exit after the initial checkout |
| GIT_SYNC_MAX_SYNC_FAILURES | the number of consecutive failures allowed before aborting (the first pull must succeed) |
| GIT_SYNC_PERMISSIONS | the file permissions to apply to the checked-out files |
| GIT_SYNC_USERNAME | the username to use |
| GIT_SYNC_PASSWORD | the password to use |
| GIT_SYNC_SSH | use SSH for git operations |
| GIT_KNOWN_HOSTS | enable SSH known_hosts verification |
| GIT_COOKIE_FILE | use git cookiefile |
