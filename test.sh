docker run \
    -v /tmp/git-data:/git \
    registry/git-sync:v2.0.5-22-g3897ab3-dirty \
        --repo=https://github.com/kubernetes/git-sync \
        --dest=test \
	--branch=master \
        --wait=30 \
        --webhook-url=http://localhost:80/test

