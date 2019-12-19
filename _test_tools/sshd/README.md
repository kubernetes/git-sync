# An SSHD for tests git-over-ssh

DO NOT USE THIS FOR ANYTHING BUT TESTING GIT OVER SSH!!!

## How to use it

Build yourself a test image.  We use example.com so you can't accidentally push
it.

```
$ docker build -t example.com/test/test-sshd .
...lots of output...
Successfully tagged example.com/test/test-sshd:latest
```

Generate keys for a fake user named "test".

```
$ mkdir -p dot_ssh

$ ssh-keygen -f dot_ssh/id_test -P ""
Generating public/private rsa key pair.
Your identification has been saved in dot_ssh/id_test.
Your public key has been saved in dot_ssh/id_test.pub.
...lots of output...

$ cat dot_ssh/id_test.pub > dot_ssh/authorized_keys
```

Run it.

```
$ docker run -d -v $(pwd)/dot_ssh:/dot_ssh:ro example.com/test/test-sshd
6d05b4111b03c66907031e3cd7587763f0e4fab6c50fac33c4a8284732b448ae
```

Find your IP.

```
$ docker inspect 6d05b4111b03c66907031e3cd7587763f0e4fab6c50fac33c4a8284732b448ae | jq -r .[0].NetworkSettings.IPAddress
192.168.1.2
```

SSH to it.

```
$ ssh -i dot_ssh/id_test -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null test@192.168.9.2
Warning: Permanently added '192.168.9.2' (ECDSA) to the list of known hosts.
fatal: Interactive git shell is not enabled.
hint: ~/git-shell-commands should exist and have read and execute access.
Connection to 192.168.9.2 closed.
```
