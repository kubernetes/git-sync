#!/bin/sh

KEYS=$(find /etc/ssh -name 'ssh_host_*_key')
[ -z "$KEYS" ] && ssh-keygen -A >/dev/null 2>/dev/null

# Copy creds for the test user, so we don't have to bake them into the image
# and so users don't have to manage permissions.
mkdir -p /home/test/.ssh
cp -a /dot_ssh/* /home/test/.ssh
chown -R test /home/test/.ssh
chmod 0700 /home/test/.ssh
chmod 0600 /home/test/.ssh/*

exec /usr/sbin/sshd -D -e
