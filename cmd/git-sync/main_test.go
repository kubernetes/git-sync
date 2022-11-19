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
	"reflect"
	"testing"
)

const (
	testKey = "KEY"
)

func TestEnvBool(t *testing.T) {
	cases := []struct {
		value string
		def   bool
		exp   bool
	}{
		{"true", true, true},
		{"true", false, true},
		{"", true, true},
		{"", false, false},
		{"false", true, false},
		{"false", false, false},
		{"", true, true},
		{"", false, false},
		{"no true", true, true},
		{"no false", true, true},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val := envBool(testKey, testCase.def)
		if val != testCase.exp {
			t.Fatalf("expected %v but %v returned", testCase.exp, val)
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
		val := envString(testKey, testCase.def)
		if val != testCase.exp {
			t.Fatalf("expected %v but %v returned", testCase.exp, val)
		}
	}
}

func TestEnvInt(t *testing.T) {
	cases := []struct {
		value string
		def   int
		exp   int
	}{
		{"0", 1, 0},
		{"", 0, 0},
		{"-1", 0, -1},
		{"abcd", 0, 0},
		{"abcd", 1, 1},
	}

	for _, testCase := range cases {
		os.Setenv(testKey, testCase.value)
		val := envInt(testKey, testCase.def)
		if val != testCase.exp {
			t.Fatalf("expected %v but %v returned", testCase.exp, val)
		}
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
