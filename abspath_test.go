/*
Copyright 2015 The Kubernetes Authors All rights reserved.

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
	"testing"
)

func TestAbsPathString(t *testing.T) {
	testCases := []string{
		"",
		"/",
		"//",
		"/dir",
		"/dir/",
		"/dir//",
		"/dir/sub",
		"/dir/sub/",
		"/dir//sub",
		"/dir//sub/",
		"dir",
		"dir/sub",
	}

	for _, tc := range testCases {
		if want, got := tc, absPath(tc).String(); want != got {
			t.Errorf("expected %q, got %q", want, got)
		}
	}
}

func TestAbsPathCanonical(t *testing.T) {
	testCases := []struct {
		in  absPath
		exp absPath
	}{{
		in:  "",
		exp: "",
	}, {
		in:  "/",
		exp: "/",
	}, {
		in:  "/one",
		exp: "/one",
	}, {
		in:  "/one/two",
		exp: "/one/two",
	}, {
		in:  "/one/two/",
		exp: "/one/two",
	}, {
		in:  "/one//two",
		exp: "/one/two",
	}, {
		in:  "/one/two/../three",
		exp: "/one/three",
	}}

	for _, tc := range testCases {
		want := tc.exp
		got, err := tc.in.Canonical()
		if err != nil {
			t.Errorf("%q: unexpected error: %v", tc.in, err)
		} else if want != got {
			t.Errorf("%q: expected %q, got %q", tc.in, want, got)
		}
	}
}

func TestAbsPathJoin(t *testing.T) {
	testCases := []struct {
		base   absPath
		more   []string
		expect absPath
	}{{
		base:   "/dir",
		more:   nil,
		expect: "/dir",
	}, {
		base:   "/dir",
		more:   []string{"one"},
		expect: "/dir/one",
	}, {
		base:   "/dir",
		more:   []string{"one", "two"},
		expect: "/dir/one/two",
	}, {
		base:   "/dir",
		more:   []string{"one", "two", "three"},
		expect: "/dir/one/two/three",
	}, {
		base:   "/dir",
		more:   []string{"with/slash"},
		expect: "/dir/with/slash",
	}, {
		base:   "/dir",
		more:   []string{"with/trailingslash/"},
		expect: "/dir/with/trailingslash",
	}, {
		base:   "/dir",
		more:   []string{"with//twoslash"},
		expect: "/dir/with/twoslash",
	}, {
		base:   "/dir",
		more:   []string{"one/1", "two/2", "three/3"},
		expect: "/dir/one/1/two/2/three/3",
	}}

	for _, tc := range testCases {
		if want, got := tc.expect, tc.base.Join(tc.more...); want != got {
			t.Errorf("(%q, %q): expected %q, got %q", tc.base, tc.more, want, got)
		}
	}
}

func TestAbsPathSplit(t *testing.T) {
	testCases := []struct {
		in      absPath
		expDir  absPath
		expBase string
	}{{
		in:      "",
		expDir:  "",
		expBase: "",
	}, {
		in:      "/",
		expDir:  "/",
		expBase: "",
	}, {
		in:      "//",
		expDir:  "/",
		expBase: "",
	}, {
		in:      "/one",
		expDir:  "/",
		expBase: "one",
	}, {
		in:      "/one/two",
		expDir:  "/one",
		expBase: "two",
	}, {
		in:      "/one/two/",
		expDir:  "/one",
		expBase: "two",
	}, {
		in:      "/one//two",
		expDir:  "/one",
		expBase: "two",
	}}

	for _, tc := range testCases {
		wantDir, wantBase := tc.expDir, tc.expBase
		if gotDir, gotBase := tc.in.Split(); wantDir != gotDir || wantBase != gotBase {
			t.Errorf("%q: expected (%q, %q), got (%q, %q)", tc.in, wantDir, wantBase, gotDir, gotBase)
		}
	}
}

func TestAbsPathDir(t *testing.T) {
	testCases := []struct {
		in  absPath
		exp string
	}{{
		in:  "",
		exp: "",
	}, {
		in:  "/",
		exp: "/",
	}, {
		in:  "/one",
		exp: "/",
	}, {
		in:  "/one/two",
		exp: "/one",
	}, {
		in:  "/one/two/",
		exp: "/one",
	}, {
		in:  "/one//two",
		exp: "/one",
	}}

	for _, tc := range testCases {
		if want, got := tc.exp, tc.in.Dir(); want != got {
			t.Errorf("%q: expected %q, got %q", tc.in, want, got)
		}
	}
}

func TestAbsPathBase(t *testing.T) {
	testCases := []struct {
		in  absPath
		exp string
	}{{
		in:  "",
		exp: "",
	}, {
		in:  "/",
		exp: "",
	}, {
		in:  "/one",
		exp: "one",
	}, {
		in:  "/one/two",
		exp: "two",
	}, {
		in:  "/one/two/",
		exp: "two",
	}, {
		in:  "/one//two",
		exp: "two",
	}}

	for _, tc := range testCases {
		if want, got := tc.exp, tc.in.Base(); want != got {
			t.Errorf("%q: expected %q, got %q", tc.in, want, got)
		}
	}
}
