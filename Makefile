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

# This repo's root import path (under GOPATH).
PKG := k8s.io/git-sync

# Where to push the docker image.
REGISTRY ?= staging-k8s.gcr.io

# Which platform to build - see $(ALL_PLATFORMS) for options.
PLATFORM ?= linux/amd64

OS := $(firstword $(subst /, ,$(PLATFORM)))
ARCH := $(lastword $(subst /, ,$(PLATFORM)))

# This version-strategy uses git tags to set the version string
VERSION := $(shell git describe --tags --always --dirty)
#
# This version-strategy uses a manual value to set the version string
#VERSION := 1.2.3

###
### These variables should not need tweaking.
###

SRC_DIRS := cmd pkg # directories which hold app source (not vendored)

ALL_PLATFORMS := linux/amd64

# TODO: get a baseimage that works for other platforms
# linux/arm linux/arm64 linux/ppc64le

# Set default base image dynamically for each arch
ifeq ($(PLATFORM),linux/amd64)
    BASEIMAGE ?= alpine:3.8
#endif
#ifeq ($(PLATFORM),linux/arm)
#    BASEIMAGE ?= armel/busybox
#endif
#ifeq ($(PLATFORM),linux/arm64)
#    BASEIMAGE ?= aarch64/busybox
#endif
#ifeq ($(PLATFORM),linux/ppc64le)
#    BASEIMAGE ?= ppc64le/busybox
else
    $(error Unsupported platform '$(PLATFORM)')
endif

IMAGE := $(REGISTRY)/$(BIN)
TAG := $(VERSION)__$(OS)_$(ARCH)

BUILD_IMAGE ?= golang:1.11-alpine

# If you want to build all binaries, see the 'all-build' rule.
# If you want to build all containers, see the 'all-container' rule.
# If you want to build AND push all containers, see the 'all-push' rule.
all: build

build-%:
	@$(MAKE) --no-print-directory ARCH=$* build

container-%:
	@$(MAKE) --no-print-directory ARCH=$* container

push-%:
	@$(MAKE) --no-print-directory ARCH=$* push

all-build: $(addprefix build-, $(ALL_PLATFORMS))

all-container: $(addprefix container-, $(ALL_PLATFORMS))

all-push: $(addprefix push-, $(ALL_PLATFORMS))

build: bin/$(OS)_$(ARCH)/$(BIN)

bin/$(OS)_$(ARCH)/$(BIN): build-dirs
	@echo "building: $@"
	@docker run                                                                  \
	    -i                                                                       \
	    -u $$(id -u):$$(id -g)                                                   \
	    -v $$(pwd)/.go:/go                                                       \
	    -v $$(pwd):/go/src/$(PKG)                                                \
	    -v $$(pwd)/bin/$(OS)_$(ARCH):/go/bin                                     \
	    -v $$(pwd)/bin/$(OS)_$(ARCH):/go/bin/$(OS)_$(ARCH)                       \
	    -v $$(pwd)/.go/std/$(OS)_$(ARCH):/usr/local/go/pkg/$(OS)_$(ARCH)_static  \
	    -v $$(pwd)/.go/cache:/.cache                                             \
            --env HTTP_PROXY=$(HTTP_PROXY)                                 	     \
            --env HTTPS_PROXY=$(HTTPS_PROXY)                                         \
	    -w /go/src/$(PKG)                                                        \
	    --rm                                                                     \
	    $(BUILD_IMAGE)                                                           \
	    /bin/sh -c "                                                             \
	        ARCH=$(ARCH)                                                         \
	        OS=$(OS)                                                             \
	        VERSION=$(VERSION)                                                   \
	        PKG=$(PKG)                                                           \
	        ./build/build.sh                                                     \
	    "

DOTFILE_IMAGE = $(subst /,_,$(IMAGE))-$(TAG)
container: .container-$(DOTFILE_IMAGE) container-name
.container-$(DOTFILE_IMAGE): bin/$(OS)_$(ARCH)/$(BIN) Dockerfile.in
	@sed \
	    -e 's|{ARG_BIN}|$(BIN)|g' \
	    -e 's|{ARG_ARCH}|$(ARCH)|g' \
	    -e 's|{ARG_OS}|$(OS)|g' \
	    -e 's|{ARG_FROM}|$(BASEIMAGE)|g' \
	    Dockerfile.in > .dockerfile-$(OS)_$(ARCH)
	@docker build --build-arg HTTP_PROXY=$(HTTP_PROXY) --build-arg=$(HTTPS_PROXY) -t $(IMAGE):$(TAG) -f .dockerfile-$(OS)_$(ARCH) .
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
manifest-list: container
	manifest-tool \
	    --username=oauth2accesstoken \
	    --password=$$(gcloud auth print-access-token) \
	    push from-args \
	    --platforms "$(ALL_PLATFORMS)" \
	    --template $(REGISTRY)/$(BIN):$(VERSION)__OS_ARCH \
	    --target $(REGISTRY)/$(BIN):$(VERSION)

version:
	@echo $(VERSION)

test: build-dirs
	@docker run                                                                  \
	    -ti                                                                      \
	    -u $$(id -u):$$(id -g)                                                   \
	    -v $$(pwd)/.go:/go                                                       \
	    -v $$(pwd):/go/src/$(PKG)                                                \
	    -v $$(pwd)/bin/$(OS)_$(ARCH):/go/bin                                     \
	    -v $$(pwd)/.go/std/$(OS)_$(ARCH):/usr/local/go/pkg/$(OS)_$(ARCH)_static  \
	    -v $$(pwd)/.go/cache:/.cache                                             \
            --env HTTP_PROXY=$(HTTP_PROXY)                                 	     \
            --env HTTPS_PROXY=$(HTTPS_PROXY)                               	     \
	    -w /go/src/$(PKG)                                                        \
	    $(BUILD_IMAGE)                                                           \
	    /bin/sh -c "                                                             \
	        ./build/test.sh $(SRC_DIRS)                                          \
	    "
	@./test_e2e.sh

build-dirs:
	@mkdir -p bin/$(OS)_$(ARCH)
	@mkdir -p .go/src/$(PKG) .go/pkg .go/bin .go/std/$(OS)_$(ARCH) .go/cache

clean: container-clean bin-clean

container-clean:
	rm -rf .container-* .dockerfile-* .push-*

bin-clean:
	rm -rf .go bin
