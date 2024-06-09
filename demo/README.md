# git-sync-demo

This demo shows how to use a `git-sync` container alongside an HTTP server to
serve static content.

## How it works

The pod is composed of 2 containers that share a volume.

- The `git-sync` container clones a git repo into the `content` volume
- The `http` container serves that content

For the purposes of this demo, it's about as trivial as it can get.

## Usage

Apply the deployment and the service files:

```
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

Wait for the service to be assigned a LoadBalancer IP, then open that IP in
your browser.
