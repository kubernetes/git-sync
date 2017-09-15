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

$ make container
<...lots of output...>
container: gcr.io/google-containers/git-sync-amd64:v2.0.5

$ gcloud docker push -- gcr.io/google-containers/git-sync-amd64:v2.0.5
<...lots of output...>
v2.0.5: digest: sha256:904833aedf3f14373e73296240ed44d54aecd4c02367b004452dfeca2465e5bf size: 950
```

Lastly, make a release through the [github UI](https://github.com/kubernetes/git-sync/releases).
