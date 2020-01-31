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

# The binary to build (just the basename).
BIN := git-sync

# Where to push the docker image.
REGISTRY ?= staging-k8s.gcr.io

# This version-strategy uses git tags to set the version string
VERSION := $(shell git describe --tags --always --dirty)
#
# This version-strategy uses a manual value to set the version string
#VERSION := 1.2.3

###
### These variables should not need tweaking.
###

SRC_DIRS := cmd pkg # directories which hold app source (not vendored)

ALL_PLATFORMS := linux/amd64 linux/arm linux/arm64 linux/ppc64le linux/s390x

# Used internally.  Users should pass GOOS and/or GOARCH.
OS := $(if $(GOOS),$(GOOS),$(shell go env GOOS))
ARCH := $(if $(GOARCH),$(GOARCH),$(shell go env GOARCH))

BASEIMAGE ?= k8s.gcr.io/debian-base:v2.0.0

IMAGE := $(REGISTRY)/$(BIN)
TAG := $(VERSION)__$(OS)_$(ARCH)

BUILD_IMAGE ?= golang:1.13-alpine

# If you want to build all binaries, see the 'all-build' rule.
# If you want to build all containers, see the 'all-container' rule.
# If you want to build AND push all containers, see the 'all-push' rule.
all: build

# For the following OS/ARCH expansions, we transform OS/ARCH into OS_ARCH
# because make pattern rules don't match with embedded '/' characters.

build-%:
	@$(MAKE) build                        \
	    --no-print-directory              \
	    GOOS=$(firstword $(subst _, ,$*)) \
	    GOARCH=$(lastword $(subst _, ,$*))

container-%:
	@$(MAKE) container                    \
	    --no-print-directory              \
	    GOOS=$(firstword $(subst _, ,$*)) \
	    GOARCH=$(lastword $(subst _, ,$*))

push-%:
	@$(MAKE) push                         \
	    --no-print-directory              \
	    GOOS=$(firstword $(subst _, ,$*)) \
	    GOARCH=$(lastword $(subst _, ,$*))

all-build: $(addprefix build-, $(subst /,_, $(ALL_PLATFORMS)))

all-container: $(addprefix container-, $(subst /,_, $(ALL_PLATFORMS)))

all-push: $(addprefix push-, $(subst /,_, $(ALL_PLATFORMS)))

build: bin/$(OS)_$(ARCH)/$(BIN)

BUILD_DIRS :=             \
    bin/$(OS)_$(ARCH)     \
    .go/bin/$(OS)_$(ARCH) \
    .go/cache

# The following structure defeats Go's (intentional) behavior to always touch
# result files, even if they have not changed.  This will still run `go` but
# will not trigger further work if nothing has actually changed.
OUTBIN = bin/$(OS)_$(ARCH)/$(BIN)
$(OUTBIN): .go/$(OUTBIN).stamp
	@true

# This will build the binary under ./.go and update the real binary iff needed.
.PHONY: .go/$(OUTBIN).stamp
.go/$(OUTBIN).stamp: $(BUILD_DIRS)
	@echo "making $(OUTBIN)"
	@docker run                                                                  \
	    -ti                                                                      \
	    --rm                                                                     \
	    -u $$(id -u):$$(id -g)                                                   \
	    -v $$(pwd):/src                                                          \
	    -w /src                                                                  \
	    -v $$(pwd)/.go/bin/$(OS)_$(ARCH):/go/bin                                 \
	    -v $$(pwd)/.go/bin/$(OS)_$(ARCH):/go/bin/$(OS)_$(ARCH)                   \
	    -v $$(pwd)/.go/cache:/.cache                                             \
	    --env HTTP_PROXY=$(HTTP_PROXY)                                           \
	    --env HTTPS_PROXY=$(HTTPS_PROXY)                                         \
	    $(BUILD_IMAGE)                                                           \
	    /bin/sh -c "                                                             \
	        ARCH=$(ARCH)                                                         \
	        OS=$(OS)                                                             \
	        VERSION=$(VERSION)                                                   \
	        ./build/build.sh                                                     \
	    "
	@if ! cmp -s .go/$(OUTBIN) $(OUTBIN); then \
	    mv .go/$(OUTBIN) $(OUTBIN);            \
	    date >$@;                              \
	fi

# Used to track state in hidden files.
DOTFILE_IMAGE = $(subst /,_,$(IMAGE))-$(TAG)

container: .container-$(DOTFILE_IMAGE) container-name
.container-$(DOTFILE_IMAGE): bin/$(OS)_$(ARCH)/$(BIN) Dockerfile.in
	@sed \
	    -e 's|{ARG_BIN}|$(BIN)|g' \
	    -e 's|{ARG_ARCH}|$(ARCH)|g' \
	    -e 's|{ARG_OS}|$(OS)|g' \
	    -e 's|{ARG_FROM}|$(BASEIMAGE)|g' \
	    Dockerfile.in > .dockerfile-$(OS)_$(ARCH)
	@docker build \
	    --build-arg HTTP_PROXY=$(HTTP_PROXY) \
	    --build-arg HTTPS_PROXY=$(HTTPS_PROXY) \
	    -t $(IMAGE):$(TAG) \
	    -f .dockerfile-$(OS)_$(ARCH) \
	    .
	@docker images -q $(IMAGE):$(TAG) > $@

container-name:
	@echo "container: $(IMAGE):$(TAG)"

push: .push-$(DOTFILE_IMAGE) push-name
.push-$(DOTFILE_IMAGE): .container-$(DOTFILE_IMAGE)
	@docker push $(IMAGE):$(TAG)
	@docker images -q $(IMAGE):$(TAG) > $@

push-name:
	@echo "pushed: $(IMAGE):$(TAG)"

# This depends on github.com/estesp/manifest-tool in $PATH.
manifest-list: all-push
	platforms=$$(echo $(ALL_PLATFORMS) | sed 's/ /,/g');  \
	manifest-tool                                         \
	    --username=oauth2accesstoken                      \
	    --password=$$(gcloud auth print-access-token)     \
	    push from-args                                    \
	    --platforms "$$platforms"                         \
	    --template $(REGISTRY)/$(BIN):$(VERSION)__OS_ARCH \
	    --target $(REGISTRY)/$(BIN):$(VERSION)

version:
	@echo $(VERSION)

test: $(BUILD_DIRS)
	@docker run                                                                  \
	    -ti                                                                      \
	    -u $$(id -u):$$(id -g)                                                   \
	    -v $$(pwd):/src                                                          \
	    -w /src                                                                  \
	    -v $$(pwd)/.go/bin/$(OS)_$(ARCH):/go/bin                                 \
	    -v $$(pwd)/.go/bin/$(OS)_$(ARCH):/go/bin/$(OS)_$(ARCH)                   \
	    -v $$(pwd)/.go/cache:/.cache                                             \
	    --env HTTP_PROXY=$(HTTP_PROXY)                                           \
	    --env HTTPS_PROXY=$(HTTPS_PROXY)                                         \
	    $(BUILD_IMAGE)                                                           \
	    /bin/sh -c "                                                             \
	        ./build/test.sh $(SRC_DIRS)                                          \
	    "
	@./test_e2e.sh

test-tools:
	@docker build -t $(REGISTRY)/test/test-sshd _test_tools/sshd

$(BUILD_DIRS):
	@mkdir -p $@

clean: container-clean bin-clean

container-clean:
	rm -rf .container-* .dockerfile-* .push-*

bin-clean:
	rm -rf .go bin
