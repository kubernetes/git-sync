/*
Copyright 2014 The Kubernetes Authors All rights reserved.

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

package main

import (
	"os"
	"path/filepath"
	"strings"
)

// absPath is an absolute path string.  This type is intended to make it clear
// when strings are absolute paths vs something else.  This does not verify or
// mutate the input, so careless callers could make instances of this type that
// are not actually absolute paths, or even "".
type absPath string

// String returns abs as a string.
func (abs absPath) String() string {
	return string(abs)
}

// Canonical returns a canonicalized form of abs, similar to filepath.Abs
// (including filepath.Clean).  Unlike filepath.Clean, this preserves "" as a
// special case.
func (abs absPath) Canonical() (absPath, error) {
	if abs == "" {
		return abs, nil
	}

	result, err := filepath.Abs(abs.String())
	if err != nil {
		return "", err
	}
	return absPath(result), nil
}

// Join appends more path elements to abs, like filepath.Join. This will clean
// the final path (e.g. resolve ".." elements).
func (abs absPath) Join(elems ...string) absPath {
	all := make([]string, 0, 1+len(elems))
	all = append(all, abs.String())
	all = append(all, elems...)
	return absPath(filepath.Join(all...))
}

// Split breaks abs into stem and leaf parts (often directory and file, but not
// necessarily), similar to filepath.Split.  Unlike filepath.Split, the
// resulting stem part does not have any trailing path separators.
func (abs absPath) Split() (absPath, string) {
	if abs == "" {
		return "", ""
	}

	// filepath.Split promises that dir+base == input, but trailing slashes on
	// the dir is confusing and ugly.
	pathSep := string(os.PathSeparator)
	dir, base := filepath.Split(strings.TrimRight(abs.String(), pathSep))
	dir = strings.TrimRight(dir, pathSep)
	if len(dir) == 0 {
		dir = string(os.PathSeparator)
	}

	return absPath(dir), base
}

// Dir returns the stem part of abs without the leaf, like filepath.Dir.
func (abs absPath) Dir() string {
	dir, _ := abs.Split()
	return string(dir)
}

// Base returns the leaf part of abs without the stem, like filepath.Base.
func (abs absPath) Base() string {
	_, base := abs.Split()
	return base
}
