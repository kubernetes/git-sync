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

# run the container
docker run -d \
    -v $DIR:/tmp/git \
    -u$(id -u):$(id -g) \
    registry/git-sync:tag \
        --repo=https://github.com/kubernetes/git-sync \
        --root=/tmp/git/root \
        --period=30s

# run an nginx container to serve the content
docker run -d \
    -p 8080:80 \
    -v $DIR:/usr/share/nginx/html \
    nginx
```

## Manual

```
GIT-SYNC

NAME
    git-sync - sync a remote git repository

SYNOPSIS
    git-sync --repo=<repo> [OPTION]...

DESCRIPTION

    Fetch a remote git repository to a local directory, poll the remote for
    changes, and update the local copy.

    This is a perfect "sidecar" container in Kubernetes.  For example, it can
    periodically pull files down from a repository so that an application can
    consume them.

    git-sync can pull one time, or on a regular interval.  It can read from the
    HEAD of a branch, from a git tag, or from a specific git hash.  It will only
    re-pull if the target has changed in the remote repository.  When it
    re-pulls, it updates the destination directory atomically.  In order to do
    this, it uses a git worktree in a subdirectory of the --root and flips a
    symlink.

    git-sync can pull over HTTP(S) (with authentication or not) or SSH.

    git-sync can also be configured to make a webhook call upon successful git
    repo synchronization. The call is made after the symlink is updated.

OPTIONS

    Many options can be specified as either a commandline flag or an environment
    variable.

    --add-user, $GIT_SYNC_ADD_USER
            Add a record to /etc/passwd for the current UID/GID.  This is needed
            to use SSH (see --ssh) with an arbitrary UID.  This assumes that
            /etc/passwd is writable by the current UID.

    --askpass-url <string>, $GIT_ASKPASS_URL
            A URL to query for git credentials. The query must return success
            (200) and produce a series of key=value lines, including
            "username=<value>" and "password=<value>".

    --branch <string>, $GIT_SYNC_BRANCH
            The git branch to check out. (default: <repo's default branch>)

    --change-permissions <int>, $GIT_SYNC_PERMISSIONS
            Optionally change permissions on the checked-out files to the
            specified mode.

    --cookie-file, $GIT_COOKIE_FILE
            Use a git cookiefile (/etc/git-secret/cookie_file) for
            authentication.

    --error-file, $GIT_SYNC_ERROR_FILE
            The name of a file (under --root) into which errors will be
            written. This must be a filename, not a path, and may not start
            with a period. (default: "", which means error reporting will be
            disabled)

    --depth <int>, $GIT_SYNC_DEPTH
            Create a shallow clone with history truncated to the specified
            number of commits.

    --git <string>, $GIT_SYNC_GIT
            The git command to run (subject to PATH search, mostly for testing).
            (default: git)

    --git-config <string>, $GIT_SYNC_GIT_CONFIG
            Additional git config options in 'key1:val1,key2:val2' format.  The
            key parts are passed to 'git config' and must be valid syntax for
            that command.  The val parts can be either quoted or unquoted
            values.  For all values the following escape sequences are
            supported: '\n' => [newline], '\t' => [tab], '\"' => '"', '\,' =>
            ',', '\\' => '\'.  Within unquoted values, commas MUST be escaped.
            Within quoted values, commas MAY be escaped, but are not required
            to be.  Any other escape sequence is an error. (default: "")

    -h, --help
            Print help text and exit.

    --http-bind <string>, $GIT_SYNC_HTTP_BIND
            The bind address (including port) for git-sync's HTTP endpoint.
            (default: none)

    --http-metrics, $GIT_SYNC_HTTP_METRICS
            Enable metrics on git-sync's HTTP endpoint (see --http-bind).
            (default: true)

    --http-pprof, $GIT_SYNC_HTTP_PPROF
            Enable the pprof debug endpoints on git-sync's HTTP endpoint (see
            --http-bind). (default: false)

    --link <string>, $GIT_SYNC_LINK
            The name of the final symlink (under --root) which will point to the
            current git worktree. This must be a filename, not a path, and may
            not start with a period. The destination of this link (i.e.
            readlink()) is the currently checked out SHA. (default: the leaf
            dir of --repo)

    --man
            Print this manual and exit.

    --max-sync-failures <int>, $GIT_SYNC_MAX_SYNC_FAILURES
            The number of consecutive failures allowed before aborting (the
            first sync must succeed), Setting this to -1 will retry forever
            after the initial sync. (default: 0)

    --one-time, $GIT_SYNC_ONE_TIME
            Exit after the first sync.

    --password <string>, $GIT_SYNC_PASSWORD
            The password or personal access token (see github docs) to use for
            git authentication (see --username).  NOTE: for security reasons,
            users should prefer using a file for specifying the password (see
            --password-file).

    --password-file <string>, $GIT_SYNC_PASSWORD_FILE
            The path to password file which contains password or personal access
            token (see --password).

    --period <duration>, $GIT_SYNC_PERIOD
            How long to wait between sync attempts.  This must be at least
            10ms.  This flag obsoletes --wait, but if --wait is specified, it
            will take precedence. (default: 10s)

    --repo <string>, $GIT_SYNC_REPO
            The git repository to sync.

    --rev <string>, $GIT_SYNC_REV
            The git revision (tag or hash) to check out. (default: HEAD)

    --root <string>, $GIT_SYNC_ROOT
            The root directory for git-sync operations, under which --link will
            be created. This flag is required.

    --sparse-checkout-file, $GIT_SYNC_SPARSE_CHECKOUT_FILE
            The path to a git sparse-checkout file (see git documentation for
            details) which controls which files and directories will be checked
            out.

    --ssh, $GIT_SYNC_SSH
            Use SSH for git authentication and operations.

    --ssh-key-file <string>, $GIT_SSH_KEY_FILE
            The SSH key to use when using --ssh. (default: /etc/git-secret/ssh)

    --ssh-known-hosts, $GIT_KNOWN_HOSTS
            Enable SSH known_hosts verification when using --ssh.
            (default: true)

    --ssh-known-hosts-file <string>, $GIT_SSH_KNOWN_HOSTS_FILE
            The known_hosts file to use when --ssh-known-hosts is specified.
            (default: /etc/git-secret/known_hosts)

    --submodules <string>, $GIT_SYNC_SUBMODULES
            The git submodule behavior: one of 'recursive', 'shallow', or 'off'.
            (default: recursive)

    --sync-hook-command <string>, $GIT_SYNC_HOOK_COMMAND
            An optional command to be executed after syncing a new hash of the
            remote repository.  This command does not take any arguments and
            executes with the synced repo as its working directory.  The
            execution is subject to the overall --sync-timeout flag and will
            extend the effective period between sync attempts.

    --sync-timeout <duration>, $GIT_SYNC_SYNC_TIMEOUT
            The total time allowed for one complete sync.  This must be at least
            10ms.  This flag obsoletes --timeout, but if --timeout is specified,
            it will take precedence. (default: 120s)

    --username <string>, $GIT_SYNC_USERNAME
            The username to use for git authentication (see --password).

    -v, --verbose <int>
            Set the log verbosity level.  Logs at this level and lower will be
            printed. (default: 0)

    --version
            Print the version and exit.

    --webhook-backoff <duration>, $GIT_SYNC_WEBHOOK_BACKOFF
            The time to wait before retrying a failed --webhook-url).
            (default: 3s)

    --webhook-method <string>, $GIT_SYNC_WEBHOOK_METHOD
            The HTTP method for the --webhook-url (default: POST)

    --webhook-success-status <int>, $GIT_SYNC_WEBHOOK_SUCCESS_STATUS
            The HTTP status code indicating a successful --webhook-url.  Setting
            this to -1 disables success checks to make webhooks fire-and-forget.
            (default: 200)

    --webhook-timeout <duration>, $GIT_SYNC_WEBHOOK_TIMEOUT
            The timeout for the --webhook-url. (default: 1s)

    --webhook-url <string>, $GIT_SYNC_WEBHOOK_URL
            A URL for optional webhook notifications when syncs complete.

EXAMPLE USAGE

    git-sync \
        --repo=https://github.com/kubernetes/git-sync \
        --branch=main \
        --rev=HEAD \
        --period=10s \
        --root=/mnt/git

AUTHENTICATION

    Git-sync offers several authentication options to choose from.  If none of
    the following are specified, git-sync will try to access the repo in the
    "natural" manner.  For example, "https://repo" will try to use plain HTTPS
    and "git@example.com:repo" will try to use SSH.

    username/password
            The --username (GIT_SYNC_USERNAME) and --password
            (GIT_SYNC_PASSWORD) flags will be used.  To prevent password
            leaks, the GIT_SYNC_PASSWORD environment variable is almost always
            preferred to the flag.

            A variant of this is --askpass-url (GIT_ASKPASS_URL), which
            consults a URL (e.g. http://metadata) to get credentials on each
            sync.

    SSH
            When --ssh (GIT_SYNC_SSH) is specified, the --ssh-key-file
            (GIT_SSH_KEY_FILE) will be used.  Users are strongly advised to
            also use --ssh-known-hosts (GIT_KNOWN_HOSTS) and
            --ssh-known-hosts-file (GIT_SSH_KNOWN_HOSTS_FILE) when using SSH.

    cookies
            When --cookie-file (GIT_COOKIE_FILE) is specified, the associated
            cookies can contain authentication information.

WEBHOOKS

    Webhooks are executed asynchronously from the main git-sync process. If a
    --webhook-url is configured, whenever a new hash is synced a call is sent
    using the method defined in --webhook-method. Git-sync will retry this
    webhook call until it succeeds (based on --webhook-success-status).  If
    unsuccessful, git-sync will wait --webhook-backoff (default 3s) before
    re-attempting the webhook call.
```
