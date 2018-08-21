# Usage:
| Command | Environment | Description |
| --- | --- | --- |
| -alsologtostderr | | log to standard error as well as files |
| -branch string | GIT_SYNC_BRANCH | the git branch to check out (default "master") |
| -change-permissions int | GIT_SYNC_PERMISSIONS | the file permissions to apply to the checked-out files |
| -depth int | GIT_SYNC_DEPTH | use a shallow clone with a history truncated to the specified number of commits |
| -dest string | GIT_SYNC_DEST | the name at which to publish the checked-out files under --root (defaults to leaf dir of --root) |
| -log_backtrace_at value | | when logging hits line file:N, emit a stack trace |
| -log_dir string |	| If non-empty, write log files in this directory |
| -logtostderr | | log to standard error instead of files |
| -max-sync-failures int | GIT_SYNC_MAX_SYNC_FAILURES | the number of consecutive failures allowed before aborting (the first pull must succeed) |
| -one-time | GIT_SYNC_ONE_TIME | exit after the initial checkout |
| -password string | GIT_SYNC_PASSWORD | the password to use |
| -repo string | GIT_SYNC_REPO | the git repository to clone |
| -rev string | GIT_SYNC_REV | the git revision (tag or hash) to check out (default "HEAD") |
| -root string  | GIT_SYNC_ROOT | the root directory for git operations (default "/git") |
| -ssh  | GIT_SYNC_SSH | use SSH for git operations (default true) |
| -ssh-known-hosts | GIT_KNOWN_HOSTS | enable SSH known_hosts verification (default true) |
| -stderrthreshold value  | | logs at or above this threshold go to stderr |
| -username string | GIT_SYNC_USERNAME | the username to use |
| -v value | | log level for V logs |
| -vmodule value  | | comma-separated list of pattern=N settings for file-filtered logging |
| -wait float | GIT_SYNC_WAIT | the number of seconds between syncs (default 0) |
