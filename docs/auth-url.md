# Using an Http Auth URL with git-sync

# Step 1: Create Auth Service

First, create a http service which can provide the username and password for the
git repo.

Example of the auth url output:

```
username=xxx@example.com
password=ya29.xxxxyyyyzzzz
```

# Step 2: Configure git-sync container

In your git-sync container configuration, specify the auth url.

The credentials will pass in plain text, make sure the connection between git-sync
and auth server are secure. The recommended way is the auth server running within
the same pod as git-sync.

```
{
    name: "git-sync",
    ...
    env: [
        {
            name: "GIT_SYNC_REPO",
            value: "https://source.developers.google.com/p/[GCP PROJECT ID]/r/[REPO NAME]"
        }, {
            name: "GIT_SYNC_AUTH_URL",
            value: "http://localhost:8080/gce_node_auth",
        },
    ...
    ]
}
```
