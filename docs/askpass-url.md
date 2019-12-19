# Using an Http Auth URL with git-sync

## Step 1: Create a GIT_ASKPASS HTTP Service

The GIT ASKPASS Service is exposed via HTTP and provide the answer to GIT_ASKPASS.

Example of the service's output, see more at <https://git-scm.com/docs/gitcredentials>

```
username=xxx@example.com
password=ya29.mysecret
```

## Step 2: Configure git-sync container

In your git-sync container configuration, specify the GIT_ASKPASS_URL

The credentials will pass in plain text, make sure the connection between git-sync
and GIT ASKPASS Service are secure.

See askpass_url e2e test as an example.

```yaml
name: "git-sync"
...
env:
  - name: "GIT_SYNC_REPO",
    value: "https://source.developers.google.com/p/[GCP PROJECT ID]/r/[REPO NAME]"
  - name: "GIT_ASKPASS_URL",
    value: "http://localhost:9102/git_askpass",
```
