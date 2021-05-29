# Copyright 2016 The Kubernetes Authors.
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

# HOW TO USE THIS CONTAINER:
#
# For most users, the simplest way to use this container is to mount a volume
# on /tmp/git.  The only commandline argument (or env var) that is really
# required is `--repo` ($GIT_SYNC_REPO).  Everything else is optional (run this
# with `--man` for details).
#
# This container will run as UID:GID 65533:65533 by default, and unless you
# change that, you do not need to think about permissions much.  If you run
# into permissions problems, this might help:
#
#  - User does not mount a volume
#    => should work, but limited utility
#
#  - User mounts a new docker volume on /tmp/git
#    => should work
#
#  - User mounts an existing docker volume on /tmp/git
#    => if the volume already exists with compatible permissions it should work
#    => if the volume already exists with different permissions you can either
#       set the container UID or GID(s) or you can chown the volume
#
#  - User mounts an existing dir on /tmp/git
#    => set container UID or GID(s) to be able to access that dir
#
#  - User sets a different UID and git-sync GID
#    => should work
#
#  - User sets a different GID
#    => either add the git-sync GID or else set --root, mount a volume,
#       and manage volume permissions to access that volume

#############################################################################
# First we prepare the image that we want, regardless of build layers.
#############################################################################
FROM {ARG_FROM} as prep

RUN echo "deb http://deb.debian.org/debian/ buster-backports main contrib" > \
        /etc/apt/sources.list.d/backports.list
RUN apt-get update
RUN apt-get -y upgrade
RUN apt-get -y install --no-install-recommends \
        ca-certificates \
        coreutils \
        socat \
        openssh-client \
        git
# We want a newer git than the norm.
RUN apt-get -y -t buster-backports install --no-install-recommends \
        git
RUN apt-get -y autoremove
RUN rm -rf /var/lib/apt/lists/*

# By default we will run as this user...
RUN echo "git-sync:x:65533:65533::/tmp:/sbin/nologin" >> /etc/passwd
# ...but the user might choose a different UID and pass --add-user
# which needs to be able to write to /etc/passwd.
RUN chmod 0666 /etc/passwd

# Add the default GID to /etc/group for completeness.
RUN echo "git-sync:x:65533:git-sync" >> /etc/group

# Make a directory that can be used to mount volumes and make it the default,
# which makes the container image easier to use.  Setting the mode to include
# group-write allows users to run this image as a different user, as long as
# they use our git-sync group.  If the user needs a different group or sets
# $GIT_SYNC_ROOT or --root, their values will override this, and we assume they
# are handling permissions themselves.
RUN mkdir -m 02775 /tmp/git && chown 65533:65533 /tmp/git

# Add the platform-specific binary.
COPY bin/{ARG_OS}_{ARG_ARCH}/{ARG_BIN} /{ARG_BIN}

# Add third-party licenses.
COPY .licenses/ /LICENSES/

#############################################################################
# Now we make a "clean" final image.
#############################################################################
FROM scratch
COPY --from=prep / /

# Run as non-root by default.  There's simply no reason to run as root.
USER 65533:65533

# Setting HOME ensures that whatever UID this ultimately runs as can write to
# files like ~/.gitconfig.
ENV HOME=/tmp
WORKDIR /tmp

# Default values for flags.
ENV GIT_SYNC_ROOT=/tmp/git

ENTRYPOINT ["/{ARG_BIN}"]
