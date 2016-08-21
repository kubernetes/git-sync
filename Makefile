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

.PHONY: all push push-legacy container clean

REGISTRY ?= gcr.io/google_containers
IMAGE = $(REGISTRY)/git-sync-$(ARCH)
LEGACY_AMD64_IMAGE = $(REGISTRY)/git-sync

TAG = 1.0

# Architectures supported: amd64, arm, arm64 and ppc64le
ARCH ?= amd64

# TODO: get a base image for non-x86 archs
#       arm arm64 ppc64le
ALL_ARCH = amd64

KUBE_CROSS_IMAGE ?= gcr.io/google_containers/kube-cross
KUBE_CROSS_VERSION ?= v1.6.3-2

GO_PKG = k8s.io/git-sync
BIN = git-sync
SRCS = main.go

# If you want to build all containers, see the 'all-container' rule.
# If you want to build AND push all containers, see the 'all-push' rule.
all: all-build

sub-container-%:
	$(MAKE) ARCH=$* container

sub-push-%:
	$(MAKE) ARCH=$* push

all-build: $(addprefix bin/$(BIN)-,$(ALL_ARCH))

all-container: $(addprefix sub-container-,$(ALL_ARCH))

all-push: $(addprefix sub-push-,$(ALL_ARCH))

build: bin/$(BIN)-$(ARCH)

bin/$(BIN)-$(ARCH): $(SRCS)
	mkdir -p bin
	docker run                                      \
	    -u $$(id -u):$$(id -g)                      \
	    -v $$(pwd):/go/src/$(GO_PKG)                \
	    $(KUBE_CROSS_IMAGE):$(KUBE_CROSS_VERSION)   \
	    /bin/bash -c "                              \
	        cd /go/src/$(GO_PKG) &&                 \
	        CGO_ENABLED=0 godep go build            \
	        -installsuffix cgo                      \
	        -ldflags '-w'                           \
	        -o $@"

container: .container-$(ARCH)
.container-$(ARCH): bin/$(BIN)-$(ARCH)
	docker build -t $(IMAGE):$(TAG) --build-arg ARCH=$(ARCH) .
ifeq ($(ARCH),amd64)
	docker tag -f $(IMAGE):$(TAG) $(LEGACY_AMD64_IMAGE):$(TAG)
endif
	touch $@

push: .push-$(ARCH)
.push-$(ARCH): .container-$(ARCH)
	gcloud docker push $(IMAGE):$(TAG)
	touch $@

push-legacy: .push-legacy-$(ARCH)
.push-legacy-$(ARCH): .container-$(ARCH)
ifeq ($(ARCH),amd64)
	gcloud docker push $(LEGACY_AMD64_IMAGE):$(TAG)
endif
	touch $@

clean:
	rm -rf .container-* .push-* bin/
