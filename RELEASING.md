# Cutting a release

## Tags

First, see what has been tagged:

```
git tag
```

Pick the next release number and tag it.

```
git tag -am v3.3.2 v3.3.2
```

## Build and push to staging

To build git-sync you need [docker buildx](https://github.com/docker/buildx)
and to cut a release you need
[manifest-tool](https://github.com/estesp/manifest-tool).  At the time of this
writing Go is functionally broken (see below) wrt modules and `go install`, so you have to
build it manually:

```
(
  set -o errexit
  WD=$(pwd)
  DIR=/tmp/manifest-tool-$RANDOM
  mkdir $DIR
  git clone https://github.com/estesp/manifest-tool -b v2.0.3 $DIR
  cd $DIR/v2
  go build -o $WD ./cmd/manifest-tool
)
```

Make sure you are logged into Google Cloud (to push to GCR).

```
gcloud auth login
```

The following step will build for all platforms and push the container images
to our staging repo (gcr.io/k8s-staging-git-sync).

```
# Set PATH to find the `manifest-list` binary.
PATH=".:$PATH" make manifest-list
```

This will produce output like:
```
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
https://github.com/kubernetes/k8s.io to edit the file
k8s.gcr.io/images/k8s-staging-git-sync/images.yaml and add the sha256 and tag
name from above.  For example:

```
 - name: git-sync
   dmap:
+    "sha256:853ae812df916e59a7b27516f791ea952d503ad26bc8660deced8cd528f128ae": ["v3.3.2"]
     "sha256:95bfb980d3b640f6015f0d1ec25c8c0161d0babcf83d31d4c0453dd2b59923db": ["v3.3.1"]
     "sha256:5f3d12cb753c6cd00c3ef9cc6f5ce4e584da81d5210c15653644ece675f19ec6": ["v3.3.0"]
     "sha256:6a543fb2d1e92008aad697da2672478dcfac715e3dddd33801d772da6e70cf24": ["v3.2.2"]
```

When that PR is merged, the promoter bot will copy the images from staging to
the final prod location (e.g. `k8s.gcr.io/git-sync/git-sync:v3.3.2`).

## Make a GitHub release

Lastly, make a release through the [github UI](https://github.com/kubernetes/git-sync/releases).
Include all the notable changes since the last release and the final container
image location.  The "Auto-generate release notes" button is a great starting
place.

# Appendix: `go install` vs modules

This section is added for future reference.

As of Go 1.17, it does not seem possible to `go install` or `go get` a repo
which uses `replace directives`.  https://github.com/golang/go/issues/44840 is
not getting traction.

```
$ go get github.com/estesp/manifest-tool/v2/cmd/manifest-tool@v2.0.0
go get: installing executables with 'go get' in module mode is deprecated.
	Use 'go install pkg@version' instead.
	For more information, see https://golang.org/doc/go-get-install-deprecation
	or run 'go help get' or 'go help install'.

$ go install github.com/estesp/manifest-tool/v2/cmd/manifest-tool@v2.0.0
go install: github.com/estesp/manifest-tool/v2/cmd/manifest-tool@v2.0.0 (in github.com/estesp/manifest-tool/v2@v2.0.0):
	The go.mod file for the module providing named packages contains one or
	more replace directives. It must not contain directives that would cause
	it to be interpreted differently than if it were the main module.
```
