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

We use [docker buildx](https://github.com/docker/buildx) to build images.

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
# make a directory (owned by you) for the volume
export DIR="/tmp/git-data"
mkdir -p $DIR

# run the container (as your own UID)
docker run -d \
    -v $DIR:/tmp/git \
    -u$(id -u):$(id -g) \
    registry/git-sync:tag \
        --repo=https://github.com/kubernetes/git-sync \
        --branch=master \
        --wait=30

# run an nginx container to serve the content
docker run -d \
    -p 8080:80 \
    -v $DIR:/usr/share/nginx/html \
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
    -v $DIR:/tmp/git \
    registry/git-sync:tag \
        --repo=https://github.com/kubernetes/git-sync \
        --branch=master \
        --wait=30 \
        --webhook-url="http://localhost:9090/-/reload"
```

## Primary flags

| Flag                       | Environment Variable            | Default                       | Description |
|----------------------------|---------------------------------|-------------------------------|-------------|
| `--repo`                   | GIT_SYNC_REPO                   | (required)                    | the git repository to clone |
| `--branch`                 | GIT_SYNC_BRANCH                 | "master"                      | the git branch to check out |
| `--rev`                    | GIT_SYNC_REV                    | "HEAD"                        | the git revision (tag or hash) to check out |
| `--root`                   | GIT_SYNC_ROOT                   | "$HOME/git"                   | the root directory for git-sync operations, under which --dest will be created |
| `--dest`                   | GIT_SYNC_DEST                   | ""                            | the name of (a symlink to) a directory in which to check-out files under --root (defaults to the leaf dir of --repo) |
| `--wait`                   | GIT_SYNC_WAIT                   | 1 (second)                    | the number of seconds between syncs |
| `--one-time`               | GIT_SYNC_ONE_TIME               | false                         | exit after the first sync |
| `--max-sync-failures`      | GIT_SYNC_MAX_SYNC_FAILURES      | 0                             | the number of consecutive failures allowed before aborting (the first sync must succeed, -1 will retry forever after the initial sync) |
| `-v`                       | (none)                          | ""                            | log level for V logs |


## Flags which control how git runs

| Flag                       | Environment Variable            | Default                       | Description |
|----------------------------|---------------------------------|-------------------------------|-------------|
| `--depth`                  | GIT_SYNC_DEPTH                  | 0                             | use a shallow clone with a history truncated to the specified number of commits |
| `--submodules`             | GIT_SYNC_SUBMODULES             | recursive                     | git submodule behavior: one of 'recursive', 'shallow', or 'off' |
| `--timeout`                | GIT_SYNC_TIMEOUT                | 120                           | the max number of seconds allowed for a complete sync |
| `--sparse-checkout-file`   | GIT_SYNC_SPARSE_CHECKOUT_FILE   | ""                             | the location of an optional [sparse-checkout](https://git-scm.com/docs/git-sparse-checkout#_sparse_checkout) file, same syntax as a .gitignore file. |
| `--git-config`             | GIT_SYNC_GIT_CONFIG             | ""                            | additional git config options in 'key1:val1,key2:val2' format |
| `--git-gc`                 | GIT_SYNC_GIT_GC                 | "auto"                        | git garbage collection behavior: one of 'auto', 'always', 'aggressive', or 'off' |
| `--git`                    | GIT_SYNC_GIT                    | "git"                         | the git command to run (subject to PATH search, mostly for testing |

## Flags which configure authentication

| Flag                       | Environment Variable            | Default                       | Description |
|----------------------------|---------------------------------|-------------------------------|-------------|
| `--username`               | GIT_SYNC_USERNAME               | ""                            | the username to use for git auth |
| `--password`               | GIT_SYNC_PASSWORD               | ""                            | the password or [personal access token](https://docs.github.com/en/free-pro-team@latest/github/authenticating-to-github/creating-a-personal-access-token) to use for git auth. (users should prefer --password-file or env vars for passwords) |
| `--password-file`          | GIT_SYNC_PASSWORD_FILE          | ""                            | the path to password file which contains password or personal access token (see --password) |
| `--ssh`                    | GIT_SYNC_SSH                    | false                         | use SSH for git operations |
| `--ssh-key-file`           | GIT_SSH_KEY_FILE                | "/etc/git-secret/ssh"         | the SSH key to use |
| `--ssh-known-hosts`        | GIT_KNOWN_HOSTS                 | true                          | enable SSH known_hosts verification |
| `--ssh-known-hosts-file`   | GIT_SSH_KNOWN_HOSTS_FILE        | "/etc/git-secret/known_hosts" | the known_hosts file to use |
| `--add-user`               | GIT_SYNC_ADD_USER               | false                         | add a record to /etc/passwd for the current UID/GID (needed to use SSH with a different UID) |
| `--cookie-file`            | GIT_COOKIE_FILE                 | false                         | use git cookiefile |
| `--askpass-url`            | GIT_ASKPASS_URL                 | ""                            | the URL for GIT_ASKPASS callback |

## Flags which configure hooks

| Flag                       | Environment Variable            | Default                       | Description |
|----------------------------|---------------------------------|-------------------------------|-------------|
| `--exechook-command`       | GIT_SYNC_EXECHOOK_COMMAND       | ""                            | the command executed with the syncing repository as its working directory after syncing a new hash of the remote repository. it is subject to the sync time out and will extend period between syncs. (doesn't support the command arguments) |
| `--exechook-timeout`       | GIT_SYNC_EXECHOOK_TIMEOUT       | 30 (seconds)                  | the timeout for the sync hook command |
| `--exechook-backoff`       | GIT_SYNC_EXECHOOK_BACKOFF       | 3 (seconds)                   | the time to wait before retrying a failed sync hook command |
| `--webhook-url`            | GIT_SYNC_WEBHOOK_URL            | ""                            | the URL for a webhook notification when syncs complete |
| `--webhook-method`         | GIT_SYNC_WEBHOOK_METHOD         | "POST"                        | the HTTP method for the webhook |
| `--webhook-success-status` | GIT_SYNC_WEBHOOK_SUCCESS_STATUS | 200                           | the HTTP status code indicating a successful webhook (-1 disables success checks to make webhooks fire-and-forget) |
| `--webhook-timeout`        | GIT_SYNC_WEBHOOK_TIMEOUT        | 1 (second)                    | the timeout for the webhook |
| `--webhook-backoff`        | GIT_SYNC_WEBHOOK_BACKOFF        | 3 (seconds)                   | the time to wait before retrying a failed webhook |

## Flags which configure observability

| Flag                       | Environment Variable            | Default                       | Description |
|----------------------------|---------------------------------|-------------------------------|-------------|
| `--http-bind`              | GIT_SYNC_HTTP_BIND              | ""                            | the bind address (including port) for git-sync's HTTP endpoint |
| `--http-metrics`           | GIT_SYNC_HTTP_METRICS           | true                          | enable metrics on git-sync's HTTP endpoint |
| `--http-pprof`             | GIT_SYNC_HTTP_PPROF             | false                         | enable the pprof debug endpoints on git-sync's HTTP endpoint |

## Other flags

| Flag                       | Environment Variable            | Default                       | Description |
|----------------------------|---------------------------------|-------------------------------|-------------|
| `--change-permissions`     | GIT_SYNC_PERMISSIONS            | 0                             | the file permissions to apply to the checked-out files (0 will not change permissions at all) |
| `--error-file`             | GIT_SYNC_ERROR_FILE             | ""                            | the name of a file into which errors will be written under --root |
