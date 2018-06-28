# Using an Http Cookie File with git-sync

Git-sync supports use of an HTTP Cookie File for accessing git content.

# Step 1: Create Secret

First, create a secret file from the git cookie file you wish to
use.
```
kubectl create secret generic git-cookie-file --from-file=cookie_file=~/.gitcookies
```

# Step 2: Configure Pod/Deployment Volume

In your Pod or Deployment configuration, specify a Volume for mounting the
cookie-file Secret. Make sure to use the same name you used to create the
secret (`git-cookie-file` in the example above).
```
volumes: [
    {
        "name": "git-secret",
        "secret": {
          "secretName": "git-cookie-file",
        }
    },
    ...
],
```

# Step 2: Configure git-sync container

In your git-sync container configuration, mount your cookiefile at
"/etc/git-secret". Ensure that the environment variable GIT_COOKIE_FILE
is set to true, and that GIT_SYNC_REPO is set to use a URL with the HTTP
protocol.
```
{
    name: "git-sync",
    ...
    env: [
        {
            name: "GIT_SYNC_REPO",
            value: "https://github.com/kubernetes/kubernetes.git"
        }, {
            name: "GIT_COOKIE_FILE",
            value: "true",
        },
    ...
    ]
    volumeMounts: [
        {
            "name": "git-secret",
            "mountPath": "/etc/git-secret"
        },
        ...
    ],
}
```
