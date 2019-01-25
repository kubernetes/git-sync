# Cutting a release

```
$ git tag
v2.0.0
v2.0.1
v2.0.2
v2.0.3
v2.0.4

# Pick the next release number

$ git tag -am "v2.0.5" v2.0.5

$ make manifest-list
<...lots of output...>
Successfully tagged staging-k8s.gcr.io/git-sync:v2.0.5__linux_amd64
<...lots of output...>
v2.0.5__linux_amd64: digest: sha256:74cd8777ba08c7b725cd2f6de34a638ba50b48cde59f829e1dc982c8c8c9959a size: 951
pushed: staging-k8s.gcr.io/git-sync:v2.0.5__linux_amd64
<...lots of output...>
Digest: sha256:4d338888373809661b5a29314ca8024379b77c0afb53fd66d6821cf628f75438 433
```

Lastly, make a release through the [github UI](https://github.com/kubernetes/git-sync/releases).
