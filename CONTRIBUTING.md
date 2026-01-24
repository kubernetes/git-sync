# Contributing

Welcome to git-sync!

The [Kubernetes community repo](https://github.com/kubernetes/community) contains information about how to get started, how the community organizes, and more.

## Sign the CLA

We'd love to accept your patches, but before we can do that, you must sign the CNCF [Contributor License Agreement](https://git.k8s.io/community/contributors/guide/README.md#sign-the-cla).


## Contributing A Patch

1. Submit an issue describing your proposed change.
2. If your proposal is accepted, and you haven't already done so, sign the Contributor License Agreement (see details above).
3. Fork the repo, develop and test your code changes.  Don't forget tests!
4. Submit a pull request.

## Building container images with *buildx* locally on your computer

First, please read the following article:
[Building Multi-Architecture Docker Images With Buildx](https://medium.com/@artur.klauser/building-multi-architecture-docker-images-with-buildx-27d80f7e2408).

By default the `Makefile` creates a *buildx* builder dedicated to `git-sync` with a container driver. But it won't work out-of-the-box
if you use private container images registries and *pull* private dependencies, with authentication. You can adapt the *buildx* builder
for a local build.

For example, if you've already got a `default` *buildx* builder with a docker driver (with access to the host engine) you can try
to run a build with the following call to `make`:

```sh
docker login $YOUR_PRIVATE_REGISTRY
docker pull $BUILD_IMAGE_IN_PRIVATE_REGISTRY
docker pull $BASEIMAGE_IN_PRIVATE_REGISTRY
make all-container \
       BUILDX_BUILDER_SKIP_CREATION=skip \
       BUILDX_BUILDER_NAME=default \
       BUILD_IMAGE=$BUILD_IMAGE_IN_PRIVATE_REGISTRY \
       BASEIMAGE=$BASEIMAGE_IN_PRIVATE_REGISTRY
```
