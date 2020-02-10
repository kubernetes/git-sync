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

## Parameters

| Environment Variable            | Flag                       | Description                                                                                                                            | Default                       |
|---------------------------------|----------------------------|----------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|
| GIT_SYNC_REPO                   | `--repo`                   | the git repository to clone                                                                                                            | ""                            |
| GIT_SYNC_BRANCH                 | `--branch`                 | the git branch to check out                                                                                                            | "master"                      |
| GIT_SYNC_REV                    | `--rev`                    | the git revision (tag or hash) to check out                                                                                            | "HEAD"                        |
| GIT_SYNC_DEPTH                  | `--depth`                  | use a shallow clone with a history truncated to the specified number of commits                                                        | 0                             |
| GIT_SYNC_ROOT                   | `--root`                   | the root directory for git-sync operations, under which --dest will be created                                                         | "$HOME/git"                   |
| GIT_SYNC_DEST                   | `--dest`                   | the name of (a symlink to) a directory in which to check-out files under --root (defaults to the leaf dir of --repo)                   | ""                            |
| GIT_SYNC_WAIT                   | `--wait`                   | the number of seconds between syncs                                                                                                    | 0                             |
| GIT_SYNC_TIMEOUT                | `--timeout`                | the max number of seconds allowed for a complete sync                                                                                  | 120                           |
| GIT_SYNC_ONE_TIME               | `--one-time`               | exit after the first sync                                                                                                              | false                         |
| GIT_SYNC_MAX_SYNC_FAILURES      | `--max-sync-failures`      | the number of consecutive failures allowed before aborting (the first sync must succeed, -1 will retry forever after the initial sync) | 0                             |
| GIT_SYNC_PERMISSIONS            | `--change-permissions`     | the file permissions to apply to the checked-out files (0 will not change permissions at all)                                          | 0                             |
| GIT_SYNC_WEBHOOK_URL            | `--webhook-url`            | the URL for a webook notification when syncs complete                                                                                  | ""                            |
| GIT_SYNC_WEBHOOK_METHOD         | `--webhook-method`         | the HTTP method for the webhook                                                                                                        | "POST"                        |
| GIT_SYNC_WEBHOOK_SUCCESS_STATUS | `--webhook-success-status` | the HTTP status code indicating a successful webhook (-1 disables success checks to make webhooks fire-and-forget)                     | 200                           |
| GIT_SYNC_WEBHOOK_TIMEOUT        | `--webhook-timeout`        | the timeout for the webhook                                                                                                            | 1 (second)                    |
| GIT_SYNC_WEBHOOK_BACKOFF        | `--webhook-backoff`        | the time to wait before retrying a failed webhook                                                                                      | 3 (seconds)                   |
| GIT_SYNC_USERNAME               | `--username`               | the username to use for git auth                                                                                                       | ""                            |
| GIT_SYNC_PASSWORD               | `--password`               | the password to use for git auth (users should prefer env vars for passwords)                                                          | ""                            |
| GIT_SYNC_SSH                    | `--ssh`                    | use SSH for git operations                                                                                                             | false                         |
| GIT_SSH_KEY_FILE                | `--ssh-key-file`           | the SSH key to use                                                                                                                     | "/etc/git-secret/ssh"         |
| GIT_KNOWN_HOSTS                 | `--ssh-known-hosts`        | enable SSH known_hosts verification                                                                                                    | true                          |
| GIT_SSH_KNOWN_HOSTS_FILE        | `--ssh-known-hosts-file`   | the known_hosts file to use                                                                                                            | "/etc/git-secret/known_hosts" |
| GIT_SYNC_ADD_USER               | `--add-user`               | add a record to /etc/passwd for the current UID/GID (needed to use SSH with a different UID)                                           | false                         |
| GIT_COOKIE_FILE                 | `--cookie-file`            | use git cookiefile                                                                                                                     | false                         |
| GIT_ASKPASS_URL                 | `--askpass-url`            | the URL for GIT_ASKPASS callback                                                                                                       | ""                            |
| GIT_SYNC_GIT                    | `--git`                    | the git command to run (subject to PATH search, mostly for testing                                                                     | "git"                         |
| GIT_SYNC_HTTP_BIND              | `--http-bind`              | the bind address (including port) for git-sync's HTTP endpoint                                                                         | ""                            |
| GIT_SYNC_HTTP_METRICS           | `--http-metrics`           | enable metrics on git-sync's HTTP endpoint                                                                                             | true                          |
| GIT_SYNC_HTTP_PPROF             | `--http-pprof`             | enable the pprof debug endpoints on git-sync's HTTP endpoint                                                                           | false                         |

[![Analytics](https://kubernetes-site.appspot.com/UA-36037335-10/GitHub/git-sync/README.md?pixel)]()
