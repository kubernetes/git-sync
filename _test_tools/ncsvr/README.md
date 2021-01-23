# A simple server for tests

DO NOT USE THIS FOR ANYTHING BUT TESTING!!!

## How to use it

Build yourself a test image.  We use example.com so you can't accidentally push
it.

```
$ docker build -t example.com/test/test-ncvsr .
...lots of output...
Successfully tagged example.com/test/test-ncsvr:latest
```

Run it.

```
$ docker run -d example.com/test/test-ncsvr 9376 "echo hello"
6d05b4111b03c66907031e3cd7587763f0e4fab6c50fac33c4a8284732b448ae
```

Find your IP.

```
$ docker inspect 6d05b4111b03c66907031e3cd7587763f0e4fab6c50fac33c4a8284732b448ae | jq -r .[0].NetworkSettings.IPAddress
192.168.1.2
```

Connect to it.

```
$ echo "" | nc 192.168.9.2 9376
hello
```

If you want to know how many times it was accessed, mount a file on
/var/log/hits.  This will log one line per hit.
