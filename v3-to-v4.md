# Converting from git-sync v3.x to v4.x

Git-sync v4 is a significant change from v3.  It includes several flag changes
(though many of the old flags are kept for backwards compatibility), but more
importantly it fundamentally changes the way the internal sync-loop works.

It should be possible to upgrade a synced repo (e.g. in a volume) from git-sync
v3 to git-sync v4, but appropriate caution should be used for critical
deployments.  We have a test which covers this, but there are many degrees of
config which we simply can't predict.

## The v3 loop

The way git-sync v3.x works is sort of like how a human might work:

  1) `git clone <repo> <branch>`
  2) `git fetch <remote>`
  3) `git checkout <ref>`

This made the code somewhat complicated, since it had to keep track of whether
this was the first pass (clone) or a subsequent pass (fetch).  This led to a
number of bugs related to back-to-back runs of git-sync, and some race
conditions.

## The v4 loop

In v4.x the loop is simpler - every pass is the same.  This takes advantage of
some idempotent behaviors (e.g. `git init` is safe to re-run) and uses git more
efficiently.  Instead of cloning a branch, git-sync will now fetch exactly the
commit (by SHA) it needs.  This transfers less data and closes the race
condition where a symbolic name can change after `git ls-remote` but before
`git fetch`.

### The v4.2+ loop

The v4.2 loop refines the v4 loop even further.  Instead of using ls-remote to
see what the upstream has and then fetching it, git-sync will just fetch it by
ref.  If the local sync already has the corresponding hash, nothing more will
be synced.  If it did not have that hash before, then it does now and can
update the worktree.

## Flags

The flag syntax parsing has changed in v4.  git-sync v3 accept flags in Go's
own style: either `-flag` or `--flag` were accepted.  git-sync v4 only accepts
long flag names in the more common two-dash style (`--flag`), and accepts short
(single-character) flags in the one-dash style (`-v 2`).

The following does not detail every flag available in v4 - just the ones that
existed in v3 and are different in v4.

### Verbosity: `--v` -> `-v` or `--verbose`

The change in flag parsing affects the old `--v` syntax.  To set verbosity
either use `-v` or `--verbose`.  For backwards compatibility, `--v` will be
used if it is specified.

### Sync target: `--branch` and `--rev` -> `--ref`

The old `--branch` and `--rev` flags are deprecated in favor of the new `--ref`
flag.  `--ref` can be either a branch name, a tag name, or a commit hash (aka
SHA).  For backwards compatibility, git-sync will still accept the old flags
and try to set `--ref` from them.

    |----------|---------|---------|------------------------------|
    | --branch |  --rev  |  --ref  |            meaning           |
    |----------|---------|---------|------------------------------|
    |    ""    |   ""    | "HEAD"  | remote repo's default branch |
    |  brname  |   ""    | brname  | remote branch `brname`       |
    |  brname  | "HEAD"  | brname  | remote branch `brname`       |
    |    ""    | tagname | tagname | remote tag `tagname`         |
    |   other  |  other  |   ""    | error                        |
    |----------|---------|---------|------------------------------|

#### Default target

In git-sync v3, if neither `--branch` nor `--rev` were specified, the default
was to sync the HEAD of the branch named "master".  Many git repos have changed
to "main" or something else as the default branch name, so git-sync v4 changes
the default target to be the HEAD of whatever the `--repo`'s default branch is.
If that default branch is not "master", then the default target will be
different in v4 than in v3.

#### Abbreviated hashes

Because of the fetch loop, git-sync v3 allowed a user to specify `--branch` and
`--rev`, where the rev was a shortened hash (aka SHA), which would be locally
expanded to the full hash.  v4 tries hard not to pull extra stuff, which means
we don't have enough information locally to do that resolution, and there no
way to ask the server to do it for us (at least, not as far as we know).

The net result is that, when using a hash for `--ref`, it must be a full hash,
and not an abbreviated form.

### Log-related flags

git-sync v3 exposed a number of log-related flags (e.g. `-logtostderr`).  These
have all been removed.  git-sync v4 always logs to stderr, and the only control
offered is the verbosity level (`-v / --verbose`).

### Symlink: `--dest` -> `--link`

The old `--dest` flag is deprecated in favor of `--link`, which more clearly
conveys what it does.  The allowed values remain the same, and for backwards
compatibility, `--dest` will be used if it is specified.

### Loop: `--wait` -> `--period`

The old `--wait` flag took a floating-point number of seconds as an argument
(e.g. "0.1" = 100ms).  The new `--period` flag takes a Go-style duration string
(e.g. "100ms" or "0.1s" = 100ms).  For backwards compatibility, `--wait` will
be used if it is specified.

### Failures: `--max-sync-failures` -> `--max-failures`

The new name of this flag is shorter and captures the idea that any
non-recoverable error in the sync loop counts as a failure.  For backwards
compatibility, `--max-sync-failures` will be used if it is specified.

git-sync v3 demanded that the first sync succeed, regardless of this flag.
git-sync v4 always allows failures up to this maximum, whether it is the first
sync or any other.

### Timeouts: `--timeout` -> `--sync-timeout`

The old `--timeout` flag took an integer number of seconds as an argument.  The
new `--sync-timeout` flag takes a Go-style duration string (e.g. "30s" or
"0.5m").  For backwards compatibility, `--timeout` will be used if it is
specified.

### Permissions: `--change-permissions` -> `--group-write`

The old `--change-permissions` flag was poorly designed and not able to express
the real intentions (e.g. "allow group write" does not mean "set everything to
0775").  The new `--group-write` flag should cover what most people ACTUALLY
are trying to do.

There is one case where `--change-permissions` was useful and `--group-write`
is not - making non-executable files in the repo executable so they can be run
as exechooks.  The proper solution here is to make the file executable in the
repo, rather than changing it after checkout.

The `--change-permissions` flag is no longer supported.

### SSH: `--ssh` is optional (after v4.0.0)

The old `--ssh` flag is no longer needed - the value of `--repo` determines
when SSH is used.  It is still accepted but does nothing.

NOTE: v4.0.0 still requires `--ssh` but all releases beyond that do not.

### Manual: `--man`

The new `--man` flag prints a man-page style help document and exits.

## Env vars

Most flags can also be configured by environment variables.  In v3 the
variables all start with `GIT_SYNC_`.  In v4 they all start with `GITSYNC_`,
though the old names are still accepted for compatibility.

If both an old (`GIT_SYNC_*`) name and a new (`GITSYNC_*`) name are specified,
the behavior is:
* v4.0.x - v4.3.x: the new name is used
* v4.4.x and up: the old name is used

## Defaults

### Depth

git-sync v3 would sync the entire history of the remote repo by default.  v4
syncs just one commit by default.  This can be a significant performance and
disk-space savings for large repos.  Users who want the full history can
specify `--depth=0`.

## Logs

The logging output for v3 was semi-free-form text.  Log output in v4 is
structured and rendered as strict JSON.

## Root dir

git-sync v3 container images defaulted `--root` to "/tmp/git".  In v4, that has
moved to "/git".  Users who mount a volume and expect to use the default
`--root` must mount it on "/git".

## Hooks

git-sync v3 could "lose" exechook and webhook calls in the face of the app
restarting.  In v4, app startup is treated as a sync, even if the correct hash
was already present, which means that hooks are always called.

## Other changes

git-sync v3 would allow invalidly formatted env vars (e.g. a value that was
expected to be boolean holding an integer) and just ignore them with
a warning.  v4 requires that they parse correctly.
