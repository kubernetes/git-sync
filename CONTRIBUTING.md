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

## Running end-to-end tests using fully-qualified base images

By default the `_test_tools/*/Dockerfile` images used by the end-to-end tests are built in the `Makefile`'s `.container-test_tool.%` goals
using an unqualified `alpine` image.

In order to pull the `alpine` image from a private registry and/or with a fully-qualified name, and run the tests, you can
use for example:

```sh
docker login $YOUR_PRIVATE_REGISTRY
ALPINE_REGISTRY_PREFIX=$YOUR_PRIVATE_REGISTRY/$YOUR_ALPINE_NAMESPACE_PREFIX/ # Please note the final '/'
docker pull ${ALPINE_REGISTRY_PREFIX}alpine
make test ALPINE_REGISTRY_PREFIX=$ALPINE_REGISTRY_PREFIX
```

## Running end-to-end tests locally with docker configured behind a proxy

If you are using proxy configurations in your `~/.docker/config` file, you must add the `docker0` subnet (created by the
*bridge* network) as an exception in order for the containers executed by the tests to be able to call each other. 

For example to get the subnets associated with the *bridge* network in a default Docker configuration you can run:

```bash
docker network ls # you can verify that a network called bridge is present
docker network inspect bridge --format '{{ range .IPAM.Config }}{{ .Subnet }}{{ end }}'
```

If for example your *bridge* subnet is `172.16.0.0/12`, then you'd want your `~/.docker/config.json` to look like this:

```json
{
        "proxies": {
                "default": {
                        "httpProxy": "...",
                        "httpsProxy": "...",
                        "noProxy": "...,172.16.0.0/12"
                }
        }
}
```

And you'd want to run the tests like this:

```bash
make test HTTP_PROXY="..." HTTPS_PROXY="..." NO_PROXY"...,172.16.0.0/12"
```

Or manually:

```bash
export HTTP_PROXY="..."
export HTTPS_PROXY="..."
export NO_PROXY"...,172.16.0.0/12"
VERBOSE=1 ./test_e2e.sh
```