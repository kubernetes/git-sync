# Cutting a release

## Tags

First, see what has been tagged:

```
$ git tag
v3.2.0
v3.2.1
v3.2.2
v3.3.0
v3.3.1
```

Pick the next release number and tag it.

```
$ git tag -am v3.3.2 v3.3.2
```

## Build and push to staging

To build git-sync you need [docker buildx](https://github.com/docker/buildx)
and to cut a release you need
[manifest-tool](https://github.com/estesp/manifest-tool).  At the time of this
writing, manifest-tool is broken at head and doesn't support go modules yet:

```
$ GO111MODULE=off go get github.com/estesp/manifest-tool/cmd/manifest-tool

$ cd "$(go env GOPATH)/src/github.com/estesp/manifest-tool"

$ git checkout v1.0.3
Note: switching to 'v1.0.3'.

You are in 'detached HEAD' state. You can look around, make experimental
changes and commit them, and you can discard any commits you make in this
state without impacting any branches by switching back to a branch.

If you want to create a new branch to retain commits you create, you may
do so (now or later) by using -c with the switch command. Example:

  git switch -c <new-branch-name>

Or undo this operation with:

  git switch -

Turn off this advice by setting config variable advice.detachedHead to false

HEAD is now at 505479b Merge pull request #101 from estesp/prep-1.0.3

$ GO111MODULE=off go install .
```

The following step will build for all platforms and push the container images
to our staging repo (gcr.io/k8s-staging-git-sync).

```
$ make manifest-list
<...lots of output...>
Successfully tagged gcr.io/k8s-staging-git-sync/git-sync:v3.3.2__linux_amd64
<...lots of output...>
v3.3.2__linux_amd64: digest: sha256:74cd8777ba08c7b725cd2f6de34a638ba50b48cde59f829e1dc982c8c8c9959a size: 951
pushed: gcr.io/k8s-staging-git-sync/git-sync:v3.3.2__linux_amd64
<...lots of output...>
Digest: sha256:853ae812df916e59a7b27516f791ea952d503ad26bc8660deced8cd528f128ae 433
```

Take note of this final sha256.

## Promote the images

Make a PR against
https://github.com/kubernetes/k8s.io/blob/main/k8s.gcr.io/images/k8s-staging-git-sync/images.yaml
and add the sha256 and tag name from above.  For example:

```
 - name: git-sync
   dmap:
+    "sha256:853ae812df916e59a7b27516f791ea952d503ad26bc8660deced8cd528f128ae": ["v3.3.2"]
     "sha256:95bfb980d3b640f6015f0d1ec25c8c0161d0babcf83d31d4c0453dd2b59923db": ["v3.3.1"]
     "sha256:5f3d12cb753c6cd00c3ef9cc6f5ce4e584da81d5210c15653644ece675f19ec6": ["v3.3.0"]
     "sha256:6a543fb2d1e92008aad697da2672478dcfac715e3dddd33801d772da6e70cf24": ["v3.2.2"]
```

When that PR is merged, the promoter bot will copy the images from staging to
the final prod location (e.g. k8s.gcr.io/git-sync/git-sync:v3.3.2).

## Make a GitHub release

Lastly, make a release through the [github UI](https://github.com/kubernetes/git-sync/releases).
Include all the notable changes since the last release and the final container
image location.
