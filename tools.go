//go:build tools
// +build tools

/*
Copyright 2021 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// This is sort of hacky, but it serves to vendor build-related tools into our
// tree.  One day, Go may handle this more cleanly.  Until then, this works.
//
// TO ADD A NEW TOOL:
//   1) add an import line below
//   2) go mod vendor
//   3) go mod tidy
//   4) go mod vendor  # yes, again
package tools

import (
	_ "github.com/estesp/manifest-tool/v2/cmd/manifest-tool"
	_ "github.com/google/go-licenses"
)
