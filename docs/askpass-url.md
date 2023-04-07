# Using an HTTP auth URL with git-sync

## Step 1: Create a GIT_ASKPASS HTTP Service

The GIT ASKPASS Service is exposed via HTTP and provide the answer to GIT_ASKPASS.

Example of the service's output, see more at <https://git-scm.com/docs/gitcredentials>

```
username=xxx@example.com
password=mysecret
```

## Step 2: Configure git-sync container

In your git-sync container configuration, specify the GIT_ASKPASS URL

The credentials will pass in plain text, so make sure the connection between
git-sync and GIT ASKPASS Service is secure.

See the askpass e2e test as an example.

```yaml
name: "git-sync"
...
env:
  - name: "GITSYNC_REPO",
    value: "https://source.developers.google.com/p/[GCP PROJECT ID]/r/[REPO NAME]"
  - name: "GITSYNC_ASKPASS_URL",
    value: "http://localhost:9102/git_askpass",
```
