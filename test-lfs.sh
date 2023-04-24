#!/bin/sh
#
# Copyright 2020 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Create directory in test tools
mkdir _test_tools/lfs

# Clone lfs-test-server to _test_tools/lfs.
git clone https://github.com/git-lfs/lfs-test-server _test_tools/lfs/lfs-test-server

# Overwrite lfs-test-server Dockerfile.
tee _test_tools/lfs/lfs-test-server/Dockerfile <<EOF
FROM golang:1.18
WORKDIR /go/src/github.com/git-lfs/lfs-test-server
COPY . .
RUN go build
EXPOSE 8080
ENV LFS_ADMINUSER=admin
ENV LFS_ADMINPASS=admin
RUN /go/src/github.com/git-lfs/lfs-test-server/lfs-test-server & \
  sleep 0.5 && \
  curl -s localhost:8080/mgmt/add -u admin:admin -X POST -F name=e2e -F password=e2e
ENTRYPOINT ["/go/src/github.com/git-lfs/lfs-test-server/lfs-test-server"]
EOF

# Build the lfs-test-server image.
docker build _test_tools/lfs/lfs-test-server -t example.com/test/lfs-test-server

# Run the lfs-test-server container.
docker run --name lfs-test-server --rm -d -p 8080:8080/tcp example.com/test/lfs-test-server

# Get lfs-test-server IP address.
LFS_TEST_SERVER_IP=$(docker inspect lfs-test-server | jq -r .[0].NetworkSettings.IPAddress)

# Clone git-server-docker to _test_tools/lfs.
git clone https://github.com/jkarlosb/git-server-docker _test_tools/lfs/git-server-docker

# Make directories for volumes
mkdir -p _test_tools/lfs/git-server/keys
mkdir -p _test_tools/lfs/git-server/repos

# Overwrite git-server-docker Dockerfile.
tee _test_tools/lfs/git-server-docker/Dockerfile <<EOF
FROM alpine:3.4
RUN apk add --no-cache \
  openssh \
  git
RUN ssh-keygen -A
WORKDIR /git-server/
RUN mkdir /git-server/keys \
  && adduser -D -s /usr/bin/git-shell git \
  && echo git:12345 | chpasswd \
  && mkdir /home/git/.ssh
COPY git-shell-commands /home/git/git-shell-commands
COPY sshd_config /etc/ssh/sshd_config
COPY start.sh start.sh
EXPOSE 22
CMD ["sh", "start.sh"]
EOF

# Build the git-server-docker image.
docker build _test_tools/lfs/git-server-docker -t example.com/test/git-server-docker

# Copy your public key to the keys folder.
cp ~/.ssh/id_rsa.pub ~/repos/git-sync/_test_tools/lfs/git-server/keys

# Create a repo and upload to git-server-docker.
mkdir -p /tmp/repo
cd /tmp/repo
git init --shared=true
git config http.sslverify false # MAYBE- This needs to be false so git-sync can connect to test-lfs-server over http.
git lfs update # MAYBE - Update git hooks for LFS.
tee .lfsconfig <<EOF
[lfs]
  url = "http://$LFS_TEST_SERVER_IP:8080/"
EOF
git lfs track "*.jpg"
git add .
git commit -m "Initial commit"
cd ..
git clone --bare repo repo.git
mv repo.git ~/repos/git-sync/_test_tools/lfs/git-server/repos
rm -fr /tmp/repo

# Run the git-server-docker.
docker run --name git-server --rm --detach \
  --volume ~/repos/git-sync/_test_tools/lfs/git-server/keys:/git-server/keys \
  --volume ~/repos/git-sync/_test_tools/lfs/git-server/repos:/git-server/repos example.com/test/git-server-docker

# Get git-server-docker IP address.
GIT_SERVER_IP=$(docker inspect git-server | jq -r .[0].NetworkSettings.IPAddress)

# Clone repo from git-server-docker, commit LFS file, and push to Git/LFS.
git clone "ssh://git@$GIT_SERVER_IP:22/git-server/repos/repo.git" /tmp/cloned-repo
cd /tmp/cloned-repo
cp ~/repos/git-sync/_test_tools/lfs/git-server-docker/git-server-docker.jpg ./
git add .
# https://stackoverflow.com/questions/47199828/how-to-convert-a-file-tracked-by-git-to-git-lfs
# git cat-file blob :0:git-server-docker.jpg # Check LFS metadata.
git commit -m "Add lfs jpg"
git push # Pushing to LFS requires authentication.
cd ..
rm -fr /tmp/cloned-repo

# Copy your public key to the keys folder.
cp ~/.ssh/id_rsa ~/repos/git-sync/_test_tools/lfs/git-server/keys/ssh
chmod 644 ~/repos/git-sync/_test_tools/lfs/git-server/keys/ssh

# Build git-sync image with git-lfs
make container REGISTRY=example.com/test VERSION=latest

# Test the git-sync container: Does not work!
mkdir -p /tmp/git-data
docker run --name git-sync -it \
  --volume ~/repos/git-sync/_test_tools/lfs/git-server/keys/ssh:/etc/git-secret/ssh \
  --volume /tmp/git-data:/tmp/git \
  -one-time \
  -ssh \
  -ssh-known-hosts=false \
  -repo="ssh://git@$GIT_SERVER_IP:22/git-server/repos/repo.git" \
  -root=/tmp/git/root \
  example.com/test/git-sync:latest__linux_amd64

# The authentication works. LFS fails to get the object from localhost rather than the IP. Why?
# https://duckduckgo.com/?q=smudge+filter+lfs+failed&ia=web&iax=qa
# INFO: detected pid 1, running init handler
# I0423 00:52:27.962317      13 main.go:401] "level"=0 "msg"="starting up" "pid"=13 "args"=["/git-sync","-one-time","-ssh","-ssh-known-hosts=false","-repo=ssh://git@172.17.0.3:22/git-server/repos/repo.git"]
# I0423 00:52:27.968205      13 main.go:950] "level"=0 "msg"="cloning repo" "origin"="ssh://git@172.17.0.3:22/git-server/repos/repo.git" "path"="/tmp/git"
# I0423 00:52:28.117929      13 main.go:760] "level"=0 "msg"="syncing git" "rev"="HEAD" "hash"="ad78191f09037b3d0a08fa6c680877140c9e53c1"
# I0423 00:52:28.125026      13 main.go:800] "level"=0 "msg"="adding worktree" "path"="/tmp/git/ad78191f09037b3d0a08fa6c680877140c9e53c1" "branch"="origin/master"
# Username for 'http://172.17.0.2:8080': e2e
# Password for 'http://e2e@172.17.0.2:8080': 
# E0423 00:53:44.936643      13 main.go:547] "msg"="too many failures, aborting" "error"="Run(git reset --hard ad78191f09037b3d0a08fa6c680877140c9e53c1): exit status 128: { stdout: "", stderr: "Downloading git-server-docker.jpg (16 KB)\nError downloading object: git-server-docker.jpg (89519af): Smudge error: Error downloading git-server-docker.jpg (89519af8b75c1c92290c77dab68fb98b722c4e4ede6d45d7b7b1a0ebf24716d2): LFS: Get \"http://localhost:8080/objects/89519af8b75c1c92290c77dab68fb98b722c4e4ede6d45d7b7b1a0ebf24716d2\": dial tcp 127.0.0.1:8080: connect: connection refused\n\nErrors logged to /tmp/git/.git/lfs/logs/20230423T005344.934293209.log\nUse `git lfs logs last` to view the log.\nerror: external filter 'git-lfs filter-process' failed\nfatal: git-server-docker.jpg: smudge filter lfs failed" }" "failCount"=1

# Test git: Works!
git clone "ssh://git@$GIT_SERVER_IP:22/git-server/repos/repo.git" /tmp/test-repo
cd /tmp/test-repo
git config --local --list
# core.repositoryformatversion=0
# core.filemode=true
# core.bare=false
# core.logallrefupdates=true
# remote.origin.url=ssh://git@172.17.0.3:22/git-server/repos/repo.git
# remote.origin.fetch=+refs/heads/*:refs/remotes/origin/*
# branch.master.remote=origin
# branch.master.merge=refs/heads/master
# lfs.repositoryformatversion=0
# lfs.http://172.17.0.2:8080/.access=basic
git cat-file blob :0:git-server-docker.jpg
# version https://git-lfs.github.com/spec/v1
# oid sha256:89519af8b75c1c92290c77dab68fb98b722c4e4ede6d45d7b7b1a0ebf24716d2
# size 16368
