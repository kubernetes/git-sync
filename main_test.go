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

	"go.uber.org/goleak"
)

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
		res := makeAbsPath(tc.path, absPath(tc.root))
		if res.String() != tc.exp {
			t.Errorf("expected: %q, got: %q", tc.exp, res)
		}
	}
}

func TestWorktreePath(t *testing.T) {
	testCases := []absPath{
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
			defer goleak.VerifyNone(t)

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
	root := absPath(t.TempDir())

	// Brand new should be empty.
	if empty, err := dirIsEmpty(root); err != nil {
		t.Fatalf("unexpected error: %v", err)
	} else if !empty {
		t.Errorf("expected %q to be deemed empty", root)
	}

	// Holding normal files should not be empty.
	dir := root.Join("files")
	if err := os.Mkdir(dir.String(), 0755); err != nil {
		t.Fatalf("failed to make a temp subdir: %v", err)
	}
	for _, file := range []string{"a", "b", "c"} {
		path := filepath.Join(dir.String(), file)
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
	dir = root.Join("dot-files")
	if err := os.Mkdir(dir.String(), 0755); err != nil {
		t.Fatalf("failed to make a temp subdir: %v", err)
	}
	for _, file := range []string{".a", ".b", ".c"} {
		path := dir.Join(file)
		if err := os.WriteFile(path.String(), []byte{}, 0755); err != nil {
			t.Fatalf("failed to write a file: %v", err)
		}
		if empty, err := dirIsEmpty(dir); err != nil {
			t.Fatalf("unexpected error: %v", err)
		} else if empty {
			t.Errorf("expected %q to be deemed not-empty", dir)
		}
	}

	// Holding dirs should not be empty.
	dir = root.Join("dirs")
	if err := os.Mkdir(dir.String(), 0755); err != nil {
		t.Fatalf("failed to make a temp subdir: %v", err)
	}
	for _, subdir := range []string{"a", "b", "c"} {
		path := filepath.Join(dir.String(), subdir)
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
	if _, err := dirIsEmpty(root.Join("does-not-exist")); err == nil {
		t.Errorf("unexpected success for non-existent dir")
	}
}

func TestRemoveDirContents(t *testing.T) {
	root := absPath(t.TempDir())

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
		path := root.Join(file)
		if err := os.WriteFile(path.String(), []byte{}, 0755); err != nil {
			t.Fatalf("failed to write a file: %v", err)
		}
	}
	for _, subdir := range []string{"d1", "d2", "d3"} {
		path := root.Join(subdir)
		if err := os.Mkdir(path.String(), 0755); err != nil {
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
	if err := removeDirContents(root.Join("does-not-exist"), nil); err == nil {
		t.Errorf("unexpected success for non-existent dir")
	}
}

func TestTouch(t *testing.T) {
	root := absPath(t.TempDir())

	// Make a dir and get info.
	dirPath := root.Join("dir")
	if err := os.MkdirAll(dirPath.String(), 0755); err != nil {
		t.Fatalf("can't create dir: %v", err)
	}

	// Make a file and get info.
	filePath := root.Join("file")
	if file, err := os.Create(filePath.String()); err != nil {
		t.Fatalf("can't create file: %v", err)
	} else {
		file.Close()
	}

	// Make sure a newfile does not exist.
	newfilePath := root.Join("newfile")
	if fi, err := os.Stat(newfilePath.String()); err == nil {
		t.Fatalf("unexpected newfile: %v", fi)
	} else if !os.IsNotExist(err) {
		t.Fatalf("can't stat newfile: %v", err)
	}

	time.Sleep(500 * time.Millisecond)
	stamp := time.Now()
	time.Sleep(100 * time.Millisecond)

	if err := touch(dirPath); err != nil {
		t.Fatalf("touch(dir) failed: %v", err)
	}
	if dirInfo, err := os.Stat(dirPath.String()); err != nil {
		t.Fatalf("can't stat dir: %v", err)
	} else if !dirInfo.IsDir() {
		t.Errorf("touch(dir) is no longer a dir: %v", dirInfo)
	} else if !dirInfo.ModTime().After(stamp) {
		t.Errorf("touch(dir) mtime %v is not after %v", dirInfo.ModTime(), stamp)
	}

	if err := touch(filePath); err != nil {
		t.Fatalf("touch(file) failed: %v", err)
	}
	if fileInfo, err := os.Stat(filePath.String()); err != nil {
		t.Fatalf("can't stat file: %v", err)
	} else if fileInfo.IsDir() {
		t.Errorf("touch(file) is no longer a file: %v", fileInfo)
	} else if !fileInfo.ModTime().After(stamp) {
		t.Errorf("touch(file) mtime %v is not after %v", fileInfo.ModTime(), stamp)
	}

	if err := touch(newfilePath); err != nil {
		t.Fatalf("touch(newfile) failed: %v", err)
	}
	if newfileInfo, err := os.Stat(newfilePath.String()); err != nil {
		t.Fatalf("can't stat newfile: %v", err)
	} else if newfileInfo.IsDir() {
		t.Errorf("touch(newfile) is not a file: %v", newfileInfo)
	} else if !newfileInfo.ModTime().After(stamp) {
		t.Errorf("touch(newfile) mtime %v is not after %v", newfileInfo.ModTime(), stamp)
	}
}

func TestHasGitLockFile(t *testing.T) {
	testCases := map[string]struct {
		inputFilePath  []string
		expectLockFile bool
	}{
		"missing .git directory": {
			expectLockFile: false,
		},
		"has git directory but no lock files": {
			inputFilePath:  []string{".git", "HEAD"},
			expectLockFile: false,
		},
		"shallow.lock file": {
			inputFilePath:  []string{".git", "shallow.lock"},
			expectLockFile: true,
		},
	}

	for name, tc := range testCases {
		t.Run(name, func(t *testing.T) {
			root := absPath(t.TempDir())

			if len(tc.inputFilePath) > 0 {
				if err := touch(root.Join(tc.inputFilePath...)); err != nil {
					t.Fatal(err)
				}
			}

			lockFile, err := hasGitLockFile(root)
			if err != nil {
				t.Fatal(err)
			}
			hasLock := len(lockFile) > 0
			if hasLock != tc.expectLockFile {
				t.Fatalf("expected hasGitLockFile to return %v, but got %v", tc.expectLockFile, hasLock)
			}
		})
	}
}
