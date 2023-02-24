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
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const (
	testKey = "KEY"
)

func TestEnvBool(t *testing.T) {
	cases := []struct {
		value string
		def   bool
		exp   bool
		err   bool
	}{
		{"true", true, true, false},
		{"true", false, true, false},
		{"", true, true, false},
		{"", false, false, false},
		{"false", true, false, false},
		{"false", false, false, false},
		{"", true, true, false},
		{"", false, false, false},
		{"no true", false, false, true},
		{"no false", false, false, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val, err := envBoolOrError(testCase.def, testKey)
		if err != nil && !testCase.err {
			t.Fatalf("%q: unexpected error: %v", testCase.value, err)
		}
		if err == nil && testCase.err {
			t.Fatalf("%q: unexpected success", testCase.value)
		}
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
		}
	}
}

func TestEnvString(t *testing.T) {
	cases := []struct {
		value string
		def   string
		exp   string
	}{
		{"true", "true", "true"},
		{"true", "false", "true"},
		{"", "true", "true"},
		{"", "false", "false"},
		{"false", "true", "false"},
		{"false", "false", "false"},
		{"", "true", "true"},
		{"", "false", "false"},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val := envString(testCase.def, testKey)
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
		}
	}
}

func TestEnvInt(t *testing.T) {
	cases := []struct {
		value string
		def   int
		exp   int
		err   bool
	}{
		{"0", 1, 0, false},
		{"", 0, 0, false},
		{"-1", 0, -1, false},
		{"abcd", 0, 0, true},
		{"abcd", 0, 0, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val, err := envIntOrError(testCase.def, testKey)
		if err != nil && !testCase.err {
			t.Fatalf("%q: unexpected error: %v", testCase.value, err)
		}
		if err == nil && testCase.err {
			t.Fatalf("%q: unexpected success", testCase.value)
		}
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
		}
	}
}

func TestEnvFloat(t *testing.T) {
	cases := []struct {
		value string
		def   float64
		exp   float64
		err   bool
	}{
		{"0.5", 0, 0.5, false},
		{"", 0.5, 0.5, false},
		{"-0.5", 0, -0.5, false},
		{"abcd", 0, 0, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val, err := envFloatOrError(testCase.def, testKey)
		if err != nil && !testCase.err {
			t.Fatalf("%q: unexpected error: %v", testCase.value, err)
		}
		if err == nil && testCase.err {
			t.Fatalf("%q: unexpected success", testCase.value)
		}
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
		}
	}
}

func TestEnvDuration(t *testing.T) {
	cases := []struct {
		value string
		def   time.Duration
		exp   time.Duration
		err   bool
	}{
		{"1s", 0, time.Second, false},
		{"", time.Minute, time.Minute, false},
		{"1h", 0, time.Hour, false},
		{"abcd", 0, 0, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val, err := envDurationOrError(testCase.def, testKey)
		if err != nil && !testCase.err {
			t.Fatalf("%q: unexpected error: %v", testCase.value, err)
		}
		if err == nil && testCase.err {
			t.Fatalf("%q: unexpected success", testCase.value)
		}
		if val != testCase.exp {
			t.Fatalf("%q: expected %v but %v returned", testCase.value, testCase.exp, val)
		}
	}
}

func TestMakeAbsPath(t *testing.T) {
	cases := []struct {
		path string
		root string
		exp  string
	}{{
		path: "", root: "", exp: "",
	}, {
		path: "", root: "/root", exp: "",
	}, {
		path: "path", root: "/root", exp: "/root/path",
	}, {
		path: "p/a/t/h", root: "/root", exp: "/root/p/a/t/h",
	}, {
		path: "/path", root: "/root", exp: "/path",
	}, {
		path: "/p/a/t/h", root: "/root", exp: "/p/a/t/h",
	}}

	for _, tc := range cases {
		res := makeAbsPath(tc.path, tc.root)
		if res != tc.exp {
			t.Errorf("expected: %q, got: %q", tc.exp, res)
		}
	}
}

func TestWorktreePath(t *testing.T) {
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
		if want, got := tc, worktree(tc).Path(); want != got {
			t.Errorf("expected %q, got %q", want, got)
		}
	}
}

func TestWorktreeHash(t *testing.T) {
	testCases := []struct {
		in  worktree
		exp string
	}{{
		in:  "",
		exp: "",
	}, {
		in:  "/",
		exp: "/",
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
		if want, got := tc.exp, tc.in.Hash(); want != got {
			t.Errorf("%q: expected %q, got %q", tc.in, want, got)
		}
	}
}

func TestManualHasNoTabs(t *testing.T) {
	if strings.Contains(manual, "\t") {
		t.Fatal("the manual text contains a tab")
	}
}

func TestParseGitConfigs(t *testing.T) {
	cases := []struct {
		name   string
		input  string
		expect []keyVal
		fail   bool
	}{{
		name:   "empty",
		input:  ``,
		expect: []keyVal{},
	}, {
		name:   "one-pair",
		input:  `k:v`,
		expect: []keyVal{keyVal{"k", "v"}},
	}, {
		name:   "one-pair-qkey",
		input:  `"k":v`,
		expect: []keyVal{keyVal{"k", "v"}},
	}, {
		name:   "one-pair-qval",
		input:  `k:"v"`,
		expect: []keyVal{keyVal{"k", "v"}},
	}, {
		name:   "one-pair-qkey-qval",
		input:  `"k":"v"`,
		expect: []keyVal{keyVal{"k", "v"}},
	}, {
		name:   "multi-pair",
		input:  `k1:v1,"k2":v2,k3:"v3","k4":"v4"`,
		expect: []keyVal{{"k1", "v1"}, {"k2", "v2"}, {"k3", "v3"}, {"k4", "v4"}},
	}, {
		name:  "garbage",
		input: `abc123`,
		fail:  true,
	}, {
		name:   "key-section-var",
		input:  `sect.var:v`,
		expect: []keyVal{keyVal{"sect.var", "v"}},
	}, {
		name:   "key-section-subsection-var",
		input:  `sect.sub.var:v`,
		expect: []keyVal{keyVal{"sect.sub.var", "v"}},
	}, {
		name:   "key-subsection-with-space",
		input:  `k.sect.sub section:v`,
		expect: []keyVal{keyVal{"k.sect.sub section", "v"}},
	}, {
		name:   "key-subsection-with-escape",
		input:  `k.sect.sub\tsection:v`,
		expect: []keyVal{keyVal{"k.sect.sub\\tsection", "v"}},
	}, {
		name:   "key-subsection-with-comma",
		input:  `k.sect.sub,section:v`,
		expect: []keyVal{keyVal{"k.sect.sub,section", "v"}},
	}, {
		name:   "qkey-subsection-with-space",
		input:  `"k.sect.sub section":v`,
		expect: []keyVal{keyVal{"k.sect.sub section", "v"}},
	}, {
		name:   "qkey-subsection-with-escapes",
		input:  `"k.sect.sub\t\n\\section":v`,
		expect: []keyVal{keyVal{"k.sect.sub\t\n\\section", "v"}},
	}, {
		name:   "qkey-subsection-with-comma",
		input:  `"k.sect.sub,section":v`,
		expect: []keyVal{keyVal{"k.sect.sub,section", "v"}},
	}, {
		name:   "qkey-subsection-with-colon",
		input:  `"k.sect.sub:section":v`,
		expect: []keyVal{keyVal{"k.sect.sub:section", "v"}},
	}, {
		name:  "invalid-qkey",
		input: `"k\xk":v"`,
		fail:  true,
	}, {
		name:   "val-spaces",
		input:  `k1:v 1,k2:v 2`,
		expect: []keyVal{{"k1", "v 1"}, {"k2", "v 2"}},
	}, {
		name:   "qval-spaces",
		input:  `k1:" v 1 ",k2:" v 2 "`,
		expect: []keyVal{{"k1", " v 1 "}, {"k2", " v 2 "}},
	}, {
		name:   "mix-val-qval",
		input:  `k1:v 1,k2:" v 2 "`,
		expect: []keyVal{{"k1", "v 1"}, {"k2", " v 2 "}},
	}, {
		name:  "garbage-after-qval",
		input: `k1:"v1"x,k2:"v2"`,
		fail:  true,
	}, {
		name:   "dangling-comma",
		input:  `k1:"v1",k2:"v2",`,
		expect: []keyVal{{"k1", "v1"}, {"k2", "v2"}},
	}, {
		name:   "val-with-escapes",
		input:  `k1:v\n\t\\\"\,1`,
		expect: []keyVal{{"k1", "v\n\t\\\",1"}},
	}, {
		name:   "qval-with-escapes",
		input:  `k1:"v\n\t\\\"\,1"`,
		expect: []keyVal{{"k1", "v\n\t\\\",1"}},
	}, {
		name:   "qval-with-comma",
		input:  `k1:"v,1"`,
		expect: []keyVal{{"k1", "v,1"}},
	}, {
		name:  "qkey-missing-close",
		input: `"k1:v1`,
		fail:  true,
	}, {
		name:  "qval-missing-close",
		input: `k1:"v1`,
		fail:  true,
	}}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			kvs, err := parseGitConfigs(tc.input)
			if err != nil && !tc.fail {
				t.Errorf("unexpected error: %v", err)
			}
			if err == nil && tc.fail {
				t.Errorf("unexpected success")
			}
			if !reflect.DeepEqual(kvs, tc.expect) {
				t.Errorf("bad result:\n\texpected: %#v\n\t     got: %#v", tc.expect, kvs)
			}
		})
	}
}

func TestDirIsEmpty(t *testing.T) {
	root := t.TempDir()

	// Brand new should be empty.
	if empty, err := dirIsEmpty(root); err != nil {
		t.Fatalf("unexpected error: %v", err)
	} else if !empty {
		t.Errorf("expected %q to be deemed empty", root)
	}

	// Holding normal files should not be empty.
	dir := filepath.Join(root, "files")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatalf("failed to make a temp subdir: %v", err)
	}
	for _, file := range []string{"a", "b", "c"} {
		path := filepath.Join(dir, file)
		if err := os.WriteFile(path, []byte{}, 0755); err != nil {
			t.Fatalf("failed to write a file: %v", err)
		}
		if empty, err := dirIsEmpty(dir); err != nil {
			t.Fatalf("unexpected error: %v", err)
		} else if empty {
			t.Errorf("expected %q to be deemed not-empty", dir)
		}
	}

	// Holding dot-files should not be empty.
	dir = filepath.Join(root, "dot-files")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatalf("failed to make a temp subdir: %v", err)
	}
	for _, file := range []string{".a", ".b", ".c"} {
		path := filepath.Join(dir, file)
		if err := os.WriteFile(path, []byte{}, 0755); err != nil {
			t.Fatalf("failed to write a file: %v", err)
		}
		if empty, err := dirIsEmpty(dir); err != nil {
			t.Fatalf("unexpected error: %v", err)
		} else if empty {
			t.Errorf("expected %q to be deemed not-empty", dir)
		}
	}

	// Holding dirs should not be empty.
	dir = filepath.Join(root, "dirs")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatalf("failed to make a temp subdir: %v", err)
	}
	for _, subdir := range []string{"a", "b", "c"} {
		path := filepath.Join(dir, subdir)
		if err := os.Mkdir(path, 0755); err != nil {
			t.Fatalf("failed to make a subdir: %v", err)
		}
		if empty, err := dirIsEmpty(dir); err != nil {
			t.Fatalf("unexpected error: %v", err)
		} else if empty {
			t.Errorf("expected %q to be deemed not-empty", dir)
		}
	}

	// Test error path.
	if _, err := dirIsEmpty(filepath.Join(root, "does-not-exist")); err == nil {
		t.Errorf("unexpected success for non-existent dir")
	}
}

func TestRemoveDirContents(t *testing.T) {
	root := t.TempDir()

	// Brand new should be empty.
	if empty, err := dirIsEmpty(root); err != nil {
		t.Fatalf("unexpected error: %v", err)
	} else if !empty {
		t.Errorf("expected %q to be deemed empty", root)
	}

	// Test removal.
	if err := removeDirContents(root, nil); err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	// Populate the dir.
	for _, file := range []string{"f1", "f2", ".f3", ".f4"} {
		path := filepath.Join(root, file)
		if err := os.WriteFile(path, []byte{}, 0755); err != nil {
			t.Fatalf("failed to write a file: %v", err)
		}
	}
	for _, subdir := range []string{"d1", "d2", "d3"} {
		path := filepath.Join(root, subdir)
		if err := os.Mkdir(path, 0755); err != nil {
			t.Fatalf("failed to make a subdir: %v", err)
		}
	}

	// It should be deemed not-empty
	if empty, err := dirIsEmpty(root); err != nil {
		t.Fatalf("unexpected error: %v", err)
	} else if empty {
		t.Errorf("expected %q to be deemed not-empty", root)
	}

	// Test removal.
	if err := removeDirContents(root, nil); err != nil {
		t.Errorf("unexpected error: %v", err)
	}

	// Test error path.
	if err := removeDirContents(filepath.Join(root, "does-not-exist"), nil); err == nil {
		t.Errorf("unexpected success for non-existent dir")
	}
}
