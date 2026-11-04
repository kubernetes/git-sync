# A simple git-lfs server for tests

DO NOT USE THIS FOR ANYTHING BUT TESTING!!!

This wraps https://github.com/git-lfs/lfs-test-server in an empty (`scratch`)
image.  The server is not downloaded at image-build time: the version is pinned
(and checksummed) in `tools/go.mod` / `tools/go.sum`, and `make test-tools`
compiles it into `lfs-test-server` here before `docker build`.

It runs in "public" mode, so there are no users or passwords.

## How to use it

```
$ make test-tools
$ docker run --rm --network=host \
    --env LFS_LISTEN=tcp://:9377 --env LFS_HOST=localhost:9377 \
    example.com/test/lfs-server
```

`LFS_HOST` is what the server puts in the download/upload URLs it hands to
clients, so it must be an address the client can reach.

To use it from a git repo, put the URL in `.lfsconfig`, and upload objects
without needing any git server:

```
$ git lfs install --local
$ git lfs track '*.bin'
$ printf '[lfs]\n\turl = "http://localhost:9377/"\n' > .lfsconfig
$ git lfs push --all http://localhost:9377/
```
