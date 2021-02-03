#!/bin/sh

if [ -z "$1" -o -z "$2" ]; then
    echo "usage: $0 <port> <shell-command>"
    exit 1
fi

while true; do
    sh -c "$2" | nc -l -p "$1" -N -w0 >/dev/null
    date >> /var/log/hits
done
