# Using SSH with git-sync

Git-sync supports using the SSH protocol for pulling git content.

## Step 1: Create Secret
Create a Secret to store your SSH private key, with the Secret keyed as "ssh". This can be done one of two ways:

***Method 1:***

Use the ``kubectl create secret`` command and point to the file on your filesystem that stores the key. Ensure that the file is mapped to "ssh" as shown (the file can be located anywhere).
```
kubectl create secret generic git-creds --from-file=ssh=~/.ssh/id_rsa
```

***Method 2:***

Write a config file for a Secret that holds your SSH private key, with the key (pasted as plaintext) mapped to the "ssh" field.
```
{
  "kind": "Secret",
  "apiVersion": "v1",
  "metadata": {
    "name": "git-creds"
  },
  "data": {
    "ssh": <private-key>
}
```

Create the Secret using ``kubectl create -f``.
```
kubectl create -f /path/to/secret-config.json
```

## Step 2: Configure Pod/Deployment Volume

In your Pod or Deployment configuration, specify a Volume for mounting the Secret. Ensure that secretName matches the name you used when creating the Secret (e.g. "git-creds" used in both above examples).
```
volumes: [
    {
        "name": "git-secret",
        "secret": {
          "secretName": "git-creds"
        }
    },
    ...
],
```

## Step 3: Configure git-sync container

In your git-sync container configuration, mount the Secret Volume at "/etc/git-secret". Ensure that the environment variable GIT_SYNC_REPO is set to use a URL with the SSH protocol, and set GIT_SYNC_SSH to true.
```
{
    name: "git-sync",
    ...
    env: [
        {
            name: "GIT_SYNC_REPO",
            value:  "git@github.com:kubernetes/kubernetes.git",
        }, {
            name: "GIT_SYNC_SSH",
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
**Note: Do not mount the Secret Volume with "readOnly: true".** Kubernetes mounts the Secret with permissions 0444 by default (not restrictive enough to be used as an SSH key), so the container runs a chmod command on the Secret. Mounting the Secret Volume as a read-only filesystem prevents chmod and thus prevents the use of the Secret as an SSH key.

***TODO***: Remove the chmod command once Kubernetes allows for specifying permissions for a Secret Volume. See https://github.com/kubernetes/kubernetes/pull/28936.
