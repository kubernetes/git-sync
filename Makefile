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
REGISTRY ?= gcr.io/k8s-staging-git-sync

# This version-strategy uses git tags to set the version string
VERSION ?= $(shell git describe --tags --always --dirty)
#
# This version-strategy uses a manual value to set the version string
#VERSION ?= 1.2.3

# Set these to cross-compile.
GOOS ?=
GOARCH ?=

# Set this to 1 to build a debugger-friendly binary.
DBG ?=

# These are passed to docker when building and testing.
HTTP_PROXY ?=
HTTPS_PROXY ?=

###
### These variables should not need tweaking.
###

ALL_PLATFORMS := linux/amd64 linux/arm linux/arm64 linux/ppc64le linux/s390x

# Used internally.  Users should pass GOOS and/or GOARCH.
OS := $(if $(GOOS),$(GOOS),$(shell go env GOOS))
ARCH := $(if $(GOARCH),$(GOARCH),$(shell go env GOARCH))

BASEIMAGE ?= registry.k8s.io/build-image/debian-base:bookworm-v1.0.2

IMAGE := $(REGISTRY)/$(BIN)
TAG := $(VERSION)
OS_ARCH_TAG := $(TAG)__$(OS)_$(ARCH)

BUILD_IMAGE ?= golang:1.22

DBG_MAKEFILE ?=
ifneq ($(DBG_MAKEFILE),1)
    # If we're not debugging the Makefile, don't echo recipes.
    MAKEFLAGS += -s
endif

# It's necessary to set this because some environments don't link sh -> bash.
SHELL := /usr/bin/env bash -o errexit -o pipefail -o nounset

# We don't need make's built-in rules.
MAKEFLAGS += --no-builtin-rules
# Be pedantic about undefined variables.
MAKEFLAGS += --warn-undefined-variables
.SUFFIXES:

# If you want to build all binaries, see the 'all-build' rule.
# If you want to build all containers, see the 'all-container' rule.
# If you want to build AND push all containers, see the 'all-push' rule.
all: build

# For the following OS/ARCH expansions, we transform OS/ARCH into OS_ARCH
# because make pattern rules don't match with embedded '/' characters.

build-%:
	$(MAKE) build                         \
	    --no-print-directory              \
	    GOOS=$(firstword $(subst _, ,$*)) \
	    GOARCH=$(lastword $(subst _, ,$*))

container-%:
	$(MAKE) container                     \
	    --no-print-directory              \
	    GOOS=$(firstword $(subst _, ,$*)) \
	    GOARCH=$(lastword $(subst _, ,$*))

push-%:
	$(MAKE) push                          \
	    --no-print-directory              \
	    GOOS=$(firstword $(subst _, ,$*)) \
	    GOARCH=$(lastword $(subst _, ,$*))

all-build: $(addprefix build-, $(subst /,_, $(ALL_PLATFORMS)))

all-container: $(addprefix container-, $(subst /,_, $(ALL_PLATFORMS)))

all-push: $(addprefix push-, $(subst /,_, $(ALL_PLATFORMS)))

build: bin/$(OS)_$(ARCH)/$(BIN)

BUILD_DIRS :=             \
    bin/$(OS)_$(ARCH)     \
    bin/tools             \
    .go/bin/$(OS)_$(ARCH) \
    .go/cache

# The following structure defeats Go's (intentional) behavior to always touch
# result files, even if they have not changed.  This will still run `go` but
# will not trigger further work if nothing has actually changed.
OUTBIN = bin/$(OS)_$(ARCH)/$(BIN)
$(OUTBIN): .go/$(OUTBIN).stamp
	true

# This will build the binary under ./.go and update the real binary iff needed.
.PHONY: .go/$(OUTBIN).stamp
.go/$(OUTBIN).stamp: $(BUILD_DIRS)
	echo "making $(OUTBIN)"
	docker run                                                 \
	    -i                                                     \
	    --rm                                                   \
	    -u $$(id -u):$$(id -g)                                 \
	    -v $$(pwd):/src                                        \
	    -w /src                                                \
	    -v $$(pwd)/.go/bin/$(OS)_$(ARCH):/go/bin               \
	    -v $$(pwd)/.go/bin/$(OS)_$(ARCH):/go/bin/$(OS)_$(ARCH) \
	    -v $$(pwd)/.go/cache:/.cache                           \
	    --env HTTP_PROXY=$(HTTP_PROXY)                         \
	    --env HTTPS_PROXY=$(HTTPS_PROXY)                       \
	    $(BUILD_IMAGE)                                         \
	    /bin/sh -c "                                           \
	        ARCH=$(ARCH)                                       \
	        OS=$(OS)                                           \
	        VERSION=$(VERSION)                                 \
	        BUILD_DEBUG=$(DBG)                                 \
	        ./build/build.sh                                   \
	    "
	if ! cmp -s .go/$(OUTBIN) $(OUTBIN); then  \
	    mv .go/$(OUTBIN) $(OUTBIN);            \
	    date >$@;                              \
	fi

# Used to track state in hidden files.
DOTFILE_IMAGE = $(subst /,_,$(IMAGE))-$(OS_ARCH_TAG)

LICENSES = .licenses

$(LICENSES):
	pushd tools >/dev/null;                                   \
	  export GOOS=$(shell go env GOHOSTOS);                   \
	  export GOARCH=$(shell go env GOHOSTARCH);               \
	  go build -o ../bin/tools github.com/google/go-licenses; \
	  popd >/dev/null
	rm -rf $(LICENSES)
	./bin/tools/go-licenses save ./... --save_path=$(LICENSES)
	chmod -R a+rx $(LICENSES)

# Set this to any value to skip repeating the apt-get steps.  Caution.
ALLOW_STALE_APT ?=

container: .container-$(DOTFILE_IMAGE) container-name
.container-$(DOTFILE_IMAGE): bin/$(OS)_$(ARCH)/$(BIN) $(LICENSES) Dockerfile.in .buildx-initialized
	sed                                  \
	    -e 's|{ARG_BIN}|$(BIN)|g'        \
	    -e 's|{ARG_ARCH}|$(ARCH)|g'      \
	    -e 's|{ARG_OS}|$(OS)|g'          \
	    -e 's|{ARG_FROM}|$(BASEIMAGE)|g' \
	    -e 's|{ARG_STAGING}|/staging|g' \
	    Dockerfile.in > .dockerfile-$(OS)_$(ARCH)
	HASH_LICENSES=$$(find $(LICENSES) -type f                    \
	    | xargs md5sum | md5sum | cut -f1 -d' ');                \
	HASH_BINARY=$$(md5sum bin/$(OS)_$(ARCH)/$(BIN)               \
	    | cut -f1 -d' ');                                        \
	FORCE=0;                                                     \
	if [ -z "$(ALLOW_STALE_APT)" ]; then FORCE=$$(date +%s); fi; \
	docker buildx build                                          \
	    --builder git-sync                                       \
	    --build-arg FORCE_REBUILD="$$FORCE"                      \
	    --build-arg HASH_LICENSES="$$HASH_LICENSES"              \
	    --build-arg HASH_BINARY="$$HASH_BINARY"                  \
	    --progress=plain                                         \
	    --load                                                   \
	    --platform "$(OS)/$(ARCH)"                               \
	    --build-arg HTTP_PROXY=$(HTTP_PROXY)                     \
	    --build-arg HTTPS_PROXY=$(HTTPS_PROXY)                   \
	    -t $(IMAGE):$(OS_ARCH_TAG)                               \
	    -f .dockerfile-$(OS)_$(ARCH)                             \
	    .
	docker images -q $(IMAGE):$(OS_ARCH_TAG) > $@

container-name:
	echo "container: $(IMAGE):$(OS_ARCH_TAG)"
	echo

push: .push-$(DOTFILE_IMAGE) push-name
.push-$(DOTFILE_IMAGE): .container-$(DOTFILE_IMAGE)
	docker push $(IMAGE):$(OS_ARCH_TAG)
	docker images -q $(IMAGE):$(OS_ARCH_TAG) > $@

push-name:
	echo "pushed: $(IMAGE):$(OS_ARCH_TAG)"
	echo

# This depends on github.com/estesp/manifest-tool in $PATH.
manifest-list: all-push
	echo "manifest-list: $(REGISTRY)/$(BIN):$(TAG)"
	pushd tools >/dev/null;                                   \
	  export GOOS=$(shell go env GOHOSTOS);                   \
	  export GOARCH=$(shell go env GOHOSTARCH);               \
	  go build -o ../bin/tools github.com/estesp/manifest-tool/v2/cmd/manifest-tool; \
	  popd >/dev/null
	platforms=$$(echo $(ALL_PLATFORMS) | sed 's/ /,/g');  \
	./bin/tools/manifest-tool                             \
	    --username=oauth2accesstoken                      \
	    --password=$$(gcloud auth print-access-token)     \
	    push from-args                                    \
	    --platforms "$$platforms"                         \
	    --template $(REGISTRY)/$(BIN):$(TAG)__OS_ARCH \
	    --target $(REGISTRY)/$(BIN):$(TAG)

release:
	if [ -z "$(TAG)" ]; then        \
		echo "ERROR: TAG must be set"; \
		false;                  \
	fi
	docker pull "$(BUILD_IMAGE)"
	git tag -am "$(TAG)" "$(TAG)"
	make manifest-list

version:
	echo $(VERSION)

test: $(BUILD_DIRS)
	docker run                                                 \
	    -i                                                     \
	    -u $$(id -u):$$(id -g)                                 \
	    -v $$(pwd):/src                                        \
	    -w /src                                                \
	    -v $$(pwd)/.go/bin/$(OS)_$(ARCH):/go/bin               \
	    -v $$(pwd)/.go/bin/$(OS)_$(ARCH):/go/bin/$(OS)_$(ARCH) \
	    -v $$(pwd)/.go/cache:/.cache                           \
	    --env HTTP_PROXY=$(HTTP_PROXY)                         \
	    --env HTTPS_PROXY=$(HTTPS_PROXY)                       \
	    $(BUILD_IMAGE)                                         \
	    /bin/sh -c "                                           \
	        ./build/test.sh ./...                              \
	    "
	VERBOSE=1 ./test_e2e.sh

TEST_TOOLS := $(shell find _test_tools/* -type d -printf "%f ")
test-tools: $(foreach tool, $(TEST_TOOLS), .container-test_tool.$(tool))

.container-test_tool.%: _test_tools/% _test_tools/%/*
	docker build -t $(REGISTRY)/test/$$(basename $<) $<
	docker images -q $(REGISTRY)/test/$$(basename $<) > $@

# Help set up multi-arch build tools.  This assumes you have the tools
# installed.  If you already have a buildx builder available, you don't need
# this.  See https://medium.com/@artur.klauser/building-multi-architecture-docker-images-with-buildx-27d80f7e2408
# for great context.
.buildx-initialized:
	docker buildx create --name git-sync --node git-sync-0 >/dev/null
	docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null
	date > $@

$(BUILD_DIRS):
	mkdir -p $@

clean: container-clean bin-clean

container-clean:
	rm -rf .container-* .dockerfile-* .push-* .buildx-initialized $(LICENSES)

bin-clean:
	rm -rf .go bin

lint-staticcheck:
	go run honnef.co/go/tools/cmd/staticcheck@2023.1.3

lint-golangci-lint:
	go run github.com/golangci/golangci-lint/cmd/golangci-lint@v1.59.0 run

lint-shellcheck:
	docker run \
	    --rm \
	    -v `pwd`:`pwd` \
	    -w `pwd` \
	    docker.io/koalaman/shellcheck-alpine:v0.9.0 \
	        shellcheck \
	        $$(git ls-files ':!:vendor' '*.sh')

lint: lint-staticcheck lint-golangci-lint lint-shellcheck
