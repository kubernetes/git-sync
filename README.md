# NOTE: THIS DOCUMENT COVERS GIT-SYNC v4

This is the "master" branch, which is under development.  If you are looking 
for docs on older (v3) versions of git-sync, you probably want to use the
[v3.x branch](https://github.com/kubernetes/git-sync/tree/release-3.x).

# git-sync

git-sync is a simple command that pulls a git repository into a local
directory, waits for a while, then repeats.  As the remote repository changes,
those changes will be synced locally.  It is a perfect "sidecar" container in
Kubernetes - it can pull files down from a repository so that an application
can consume them.

git-sync can pull one time, or on a regular interval.  It can pull from the
HEAD of a branch, from a git tag, or from a specific git hash.  It will only
re-pull if the referenced target has changed in the upstream repository (e.g. a
new commit on a branch).  It "publishes" each sync through a worktree and a
named symlink.  This ensures an atomic update - consumers will not see a
partially constructed view of the local repository.

git-sync can pull over HTTP(S) (with authentication or not) or SSH.

git-sync can also be configured to make a webhook call or exec a command upon
successful git repo synchronization. The call is made after the symlink is
updated.

## Major update: v3.x -> v4.x

git-sync has undergone many significant changes between v3.x and v4.x.  [See
here](v3-to-v4.md) for more details.

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

### Flags

git-sync has many flags and optional features (see the manual below).  Most of
those flags can be configured through environment variables, but in most cases
(with the obvious exception of passwords) flags are preferred, because the
program can abort if an invalid flag is specified, but a misspelled environment
variable will just be ignored.  We've tried to stay backwards-compatible across
major versions (by accepting deprecated flags and environment variables), but
some things have evolved, and users are encouraged to use the most recent flags
for their major verion.

### Volumes

The `--root` flag must indicate either a directory that either a) does not
exist (it will be created); or b) exists and is empty; or c) can be emptied by
removing all of the contents.

Why?  Git really wants an empty directory, to avoid any confusion.  If the
directory exists and is not empty, git-sync will try to empty it by removing
everything in it (we can't just `rm -rf` the dir because it might be a mounted
volume).  If that fails, git-sync will abort.

With the above example or with a Kubernetes `emptyDir`, there is usually no
problem.  The problematic case is when the volume is the root of a filesystem,
which sometimes contains metadata (e.g. ext{2,3,4} have a `lost+found` dir).
The only real solution is to use a sub-directory of the volume as the `--root`.

## More docs

More documentation on specific topics can be [found here](./docs).

## Manual

```
GIT-SYNC

NAME
    git-sync - sync a remote git repository

SYNOPSIS
    git-sync --repo=<repo> --root=<path> [OPTIONS]...

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
    repo synchronization.  The call is made after the symlink is updated.

OPTIONS

    Many options can be specified as either a commandline flag or an environment
    variable, but flags are preferred because a misspelled flag is a fatal
    error while a misspelled environment variable is silently ignored.

    --add-user, $GITSYNC_ADD_USER
            Add a record to /etc/passwd for the current UID/GID.  This is
            needed to use SSH with an arbitrary UID (see --ssh).  This assumes
            that /etc/passwd is writable by the current UID.

    --askpass-url <string>, $GITSYNC_ASKPASS_URL
            A URL to query for git credentials.  The query must return success
            (200) and produce a series of key=value lines, including
            "username=<value>" and "password=<value>".

    --cookie-file <string>, $GITSYNC_COOKIE_FILE
            Use a git cookiefile (/etc/git-secret/cookie_file) for
            authentication.

    --depth <int>, $GITSYNC_DEPTH
            Create a shallow clone with history truncated to the specified
            number of commits.  If not specified, this defaults to syncing a
            single commit.  Setting this to 0 will sync the full history of the
            repo.

    --error-file <string>, $GITSYNC_ERROR_FILE
            The path to an optional file into which errors will be written.
            This may be an absolute path or a relative path, in which case it
            is relative to --root.

    --exechook-backoff <duration>, $GITSYNC_EXECHOOK_BACKOFF
            The time to wait before retrying a failed --exechook-command.  If
            not specified, this defaults to 3 seconds ("3s").

    --exechook-command <string>, $GITSYNC_EXECHOOK_COMMAND
            An optional command to be executed after syncing a new hash of the
            remote repository.  This command does not take any arguments and
            executes with the synced repo as its working directory.  The
            $GITSYNC_HASH environment variable will be set to the git hash that
            was synced.  If, at startup, git-sync finds that the --root already
            has the correct hash, this hook will still be invoked.  This means
            that hooks can be invoked more than one time per hash, so they
            must be idempotent.  This flag obsoletes --sync-hook-command, but
            if sync-hook-command is specified, it will take precedence.

    --exechook-timeout <duration>, $GITSYNC_EXECHOOK_TIMEOUT
            The timeout for the --exechook-command.  If not specifid, this
            defaults to 30 seconds ("30s").

    --git <string>, $GITSYNC_GIT
            The git command to run (subject to PATH search, mostly for
            testing).  This defaults to "git".

    --git-config <string>, $GITSYNC_GIT_CONFIG
            Additional git config options in a comma-separated 'key:val'
            format.  The parsed keys and values are passed to 'git config' and
            must be valid syntax for that command.

            Both keys and values can be either quoted or unquoted strings.
            Within quoted keys and all values (quoted or not), the following
            escape sequences are supported:
                '\n' => [newline]
                '\t' => [tab]
                '\"' => '"'
                '\,' => ','
                '\\' => '\'
            To include a colon within a key (e.g. a URL) the key must be
            quoted.  Within unquoted values commas must be escaped.  Within
            quoted values commas may be escaped, but are not required to be.
            Any other escape sequence is an error.

    --git-gc <string>, $GITSYNC_GIT_GC
            The git garbage collection behavior: one of "auto", "always",
            "aggressive", or "off".  If not specified, this defaults to
            "auto".

            - auto: Run "git gc --auto" once per successful sync.  This mode
              respects git's gc.* config params.
            - always: Run "git gc" once per successful sync.
            - aggressive: Run "git gc --aggressive" once per successful sync.
              This mode can be slow and may require a longer --sync-timeout value.
            - off: Disable explicit git garbage collection, which may be a good
              fit when also using --one-time.

    --group-write, $GITSYNC_GROUP_WRITE
            Ensure that data written to disk (including the git repo metadata,
            checked out files, worktrees, and symlink) are all group writable.
            This corresponds to git's notion of a "shared repository".  This is
            useful in cases where data produced by git-sync is used by a
            different UID.  This replaces the older --change-permissions flag.

    -h, --help
            Print help text and exit.

    --http-bind <string>, $GITSYNC_HTTP_BIND
            The bind address (including port) for git-sync's HTTP endpoint.
            The '/' URL of this endpoint is suitable for Kubernetes startup and
            liveness probes, returning a 5xx error until the first sync is
            complete, and a 200 status thereafter. If not specified, the HTTP
            endpoint is not enabled.

            Examples:
              ":1234": listen on any IP, port 1234
              "127.0.0.1:1234": listen on localhost, port 1234

    --http-metrics, $GITSYNC_HTTP_METRICS
            Enable metrics on git-sync's HTTP endpoint at /metrics.  Requires
            --http-bind to be specified.

    --http-pprof, $GITSYNC_HTTP_PPROF
            Enable the pprof debug endpoints on git-sync's HTTP endpoint at
            /debug/pprof.  Requires --http-bind to be specified.

    --link <string>, $GITSYNC_LINK
            The path to at which to create a symlink which points to the
            current git directory, at the currently synced hash.  This may be
            an absolute path or a relative path, in which case it is relative
            to --root.  Consumers of the synced files should always use this
            link - it is updated atomically and should always be valid.  The
            basename of the target of the link is the current hash.  If not
            specified, this defaults to the leaf dir of --repo.

    --man
            Print this manual and exit.

    --max-failures <int>, $GITSYNC_MAX_FAILURES
            The number of consecutive failures allowed before aborting.
            Setting this to a negative value will retry forever.  If not
            specified, this defaults to 0, meaning any sync failure will
            terminate git-sync.

    --one-time, $GITSYNC_ONE_TIME
            Exit after one sync.

    --password <string>, $GITSYNC_PASSWORD
            The password or personal access token (see github docs) to use for
            git authentication (see --username).  NOTE: for security reasons,
            users should prefer --password-file or $GITSYNC_PASSWORD_FILE for
            specifying the password.

    --password-file <string>, $GITSYNC_PASSWORD_FILE
            The file from which the password or personal access token (see
            github docs) to use for git authentication (see --username) will be
            read.

    --period <duration>, $GITSYNC_PERIOD
            How long to wait between sync attempts.  This must be at least
            10ms.  This flag obsoletes --wait, but if --wait is specified, it
            will take precedence.  If not specified, this defaults to 10
            seconds ("10s").

    --ref <string>, $GITSYNC_REF
            The git revision (branch, tag, or hash) to check out.  If not
            specified, this defaults to "HEAD" (of the upstream repo's default
            branch).

    --repo <string>, $GITSYNC_REPO
            The git repository to sync.  This flag is required.

    --root <string>, $GITSYNC_ROOT
            The root directory for git-sync operations, under which --link will
            be created.  This must be a path that either a) does not exist (it
            will be created); b) is an empty directory; or c) is a directory
            which can be emptied by removing all of the contents.  This flag is
            required.

    --sparse-checkout-file <string>, $GITSYNC_SPARSE_CHECKOUT_FILE
            The path to a git sparse-checkout file (see git documentation for
            details) which controls which files and directories will be checked
            out.  If not specified, the default is to check out the entire repo.

    --ssh, $GITSYNC_SSH
            Use SSH for git authentication and operations.

    --ssh-key-file <string>, $GITSYNC_SSH_KEY_FILE
            The SSH key to use when using --ssh.  If not specified, this
            defaults to "/etc/git-secret/ssh".

    --ssh-known-hosts, $GITSYNC_SSH_KNOWN_HOSTS
            Enable SSH known_hosts verification when using --ssh.  If not
            specified, this defaults to true.

    --ssh-known-hosts-file <string>, $GITSYNC_SSH_KNOWN_HOSTS_FILE
            The known_hosts file to use when --ssh-known-hosts is specified.
            If not specified, this defaults to "/etc/git-secret/known_hosts".

    --stale-worktree-timeout <duration>, $GITSYNC_STALE_WORKTREE_TIMEOUT
            The length of time to retain stale (not the current link target)
            worktrees before being removed. Once this duration has elapsed,
            a stale worktree will be removed during the next sync attempt
            (as determined by --sync-timeout). If not specified, this defaults
            to 0, meaning that stale worktrees will be removed immediately.

    --submodules <string>, $GITSYNC_SUBMODULES
            The git submodule behavior: one of "recursive", "shallow", or
            "off".  If not specified, this defaults to "recursive".

    --sync-on-signal <string>, $GITSYNC_SYNC_ON_SIGNAL
            Indicates that a sync attempt should occur upon receipt of the
            specified signal name (e.g. SIGHUP) or number (e.g. 1). If a sync
            is already in progress, another sync will be triggered as soon as
            the current one completes. If not specified, signals will not
            trigger syncs.

    --sync-timeout <duration>, $GITSYNC_SYNC_TIMEOUT
            The total time allowed for one complete sync.  This must be at least
            10ms.  This flag obsoletes --timeout, but if --timeout is specified,
            it will take precedence.  If not specified, this defaults to 120
            seconds ("120s").

    --touch-file <string>, $GITSYNC_TOUCH_FILE
            The path to an optional file which will be touched whenever a sync
            completes.  This may be an absolute path or a relative path, in
            which case it is relative to --root.

    --username <string>, $GITSYNC_USERNAME
            The username to use for git authentication (see --password-file or
            --password).

    -v, --verbose <int>
            Set the log verbosity level.  Logs at this level and lower will be
            printed.  Logs follow these guidelines:

            - 0: Minimal, just log updates
            - 1: More details about updates
            - 2: Log the sync loop
            - 3: More details about the sync loop
            - 4: More details
            - 5: Log all executed commands
            - 6: Log stdout/stderr of all executed commands
            - 9: Tracing and debug messages

    --version
            Print the version and exit.

    --webhook-backoff <duration>, $GITSYNC_WEBHOOK_BACKOFF
            The time to wait before retrying a failed --webhook-url.  If not
            specified, this defaults to 3 seconds ("3s").

    --webhook-method <string>, $GITSYNC_WEBHOOK_METHOD
            The HTTP method for the --webhook-url.  If not specified, this defaults to "POST".

    --webhook-success-status <int>, $GITSYNC_WEBHOOK_SUCCESS_STATUS
            The HTTP status code indicating a successful --webhook-url.  Setting
            this to 0 disables success checks, which makes webhooks
            "fire-and-forget".  If not specified, this defaults to 200.

    --webhook-timeout <duration>, $GITSYNC_WEBHOOK_TIMEOUT
            The timeout for the --webhook-url.  If not specified, this defaults
            to 1 second ("1s").

    --webhook-url <string>, $GITSYNC_WEBHOOK_URL
            A URL for optional webhook notifications when syncs complete.  The
            header 'Gitsync-Hash' will be set to the git hash that was synced.
            If, at startup, git-sync finds that the --root already has the
            correct hash, this hook will still be invoked.  This means that
            hooks can be invoked more than one time per hash, so they must be
            idempotent.

EXAMPLE USAGE

    git-sync \
        --repo=https://github.com/kubernetes/git-sync \
        --ref=HEAD \
        --period=10s \
        --root=/mnt/git

AUTHENTICATION

    Git-sync offers several authentication options to choose from.  If none of
    the following are specified, git-sync will try to access the repo in the
    "natural" manner.  For example, "https://repo" will try to use plain HTTPS
    and "git@example.com:repo" will try to use SSH.

    username/password
            The --username (GITSYNC_USERNAME) and --password-file
            (GITSYNC_PASSWORD_FILE) or --password (GITSYNC_PASSWORD) flags
            will be used.  To prevent password leaks, the --password-file flag
            or GITSYNC_PASSWORD environment variable is almost always
            preferred to the --password flag.

            A variant of this is --askpass-url (GITSYNC_ASKPASS_URL), which
            consults a URL (e.g. http://metadata) to get credentials on each
            sync.

    SSH
            When --ssh (GITSYNC_SSH) is specified, the --ssh-key-file
            (GITSYNC_SSH_KEY_FILE) will be used.  Users are strongly advised
            to also use --ssh-known-hosts (GITSYNC_SSH_KNOWN_HOSTS) and
            --ssh-known-hosts-file (GITSYNC_SSH_KNOWN_HOSTS_FILE) when using
            SSH.

    cookies
            When --cookie-file (GITSYNC_COOKIE_FILE) is specified, the
            associated cookies can contain authentication information.

HOOKS

    Webhooks and exechooks are executed asynchronously from the main git-sync
    process.  If a --webhook-url or --exechook-command is configured, they will
    be invoked whenever a new hash is synced, including when git-sync starts up
    and find that the --root directory already has the correct hash.  For
    exechook, that means the command is exec()'ed, and for webhooks that means
    an HTTP request is sent using the method defined in --webhook-method.
    Git-sync will retry both forms of hooks until they succeed (exit code 0 for
    exechooks, or --webhook-success-status for webhooks).  If unsuccessful,
    git-sync will wait --exechook-backoff or --webhook-backoff (as appropriate)
    before re-trying the hook.  Git-sync does not ensure that hooks are invoked
    exactly once, so hooks must be idempotent.

    Hooks are not guaranteed to succeed on every single hash change.  For example,
    if a hook fails and a new hash is synced during the backoff period, the
    retried hook will fire for the newest hash.
```
