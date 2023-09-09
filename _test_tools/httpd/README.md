# A server for tests git-over-http

DO NOT USE THIS FOR ANYTHING BUT TESTING GIT OVER HTTP!!!

## How to use it

Build yourself a test image.  We use example.com so you can't accidentally push
it.

```
$ docker build -t example.com/test/test-httpd .
...lots of output...
Successfully tagged example.com/test/test-httpd:latest
```

Run it.

```
$ docker run -d -v /tmp/repo:/git/repo:ro example.com/test/test-httpd
60d5b41110bc669037031e3cd758763f0e4fb6c50fac33c4a8a28432b448ae
```

Find your IP.

```
$ docker inspect 60d5b41110bc669037031e3cd758763f0e4fb6c50fac33c4a8a28432b448ae7 | jq -r .[0].NetworkSettings.IPAddress
192.168.1.2
```

Now you can git clone from it.

```
$ git clone testuser:testpass@192.168.9.2/repo
```
