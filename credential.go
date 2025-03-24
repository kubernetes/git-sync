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
	"encoding/json"
	"fmt"
	"strings"

	"github.com/spf13/pflag"
)

type credential struct {
	URL          string `json:"url"`
	Username     string `json:"username"`
	Password     string `json:"password,omitempty"`
	PasswordFile string `json:"password-file,omitempty"`
}

func (c credential) String() string {
	jb, err := json.Marshal(c)
	if err != nil {
		return fmt.Sprintf("<encoding error: %v>", err)
	}
	return string(jb)
}

// credentialSliceValue is for flags.
type credentialSliceValue struct {
	value   []credential
	changed bool
}

var _ pflag.Value = &credentialSliceValue{}
var _ pflag.SliceValue = &credentialSliceValue{}

// pflagCredentialSlice is like pflag.StringSlice().
func pflagCredentialSlice(name, def, usage string) *[]credential {
	p := &credentialSliceValue{}
	_ = p.Set(def)
	pflag.Var(p, name, usage)
	return &p.value
}

// unmarshal is like json.Unmarshal, but fails on unknown fields.
func (cs credentialSliceValue) unmarshal(val string, out any) error {
	dec := json.NewDecoder(strings.NewReader(val))
	dec.DisallowUnknownFields()
	return dec.Decode(out)
}

// decodeList handles a string-encoded JSON object.
func (cs credentialSliceValue) decodeObject(val string) (credential, error) {
	var cred credential
	if err := cs.unmarshal(val, &cred); err != nil {
		return credential{}, err
	}
	return cred, nil
}

// decodeList handles a string-encoded JSON list.
func (cs credentialSliceValue) decodeList(val string) ([]credential, error) {
	var creds []credential
	if err := cs.unmarshal(val, &creds); err != nil {
		return nil, err
	}
	return creds, nil
}

// decode handles a string-encoded JSON object or list.
func (cs credentialSliceValue) decode(val string) ([]credential, error) {
	s := strings.TrimSpace(val)
	if s == "" {
		return nil, nil
	}
	// If it tastes like an object...
	if s[0] == '{' {
		cred, err := cs.decodeObject(s)
		return []credential{cred}, err
	}
	// If it tastes like a list...
	if s[0] == '[' {
		return cs.decodeList(s)
	}
	// Otherwise, bad
	return nil, fmt.Errorf("not a JSON object or list")
}

func (cs *credentialSliceValue) Set(val string) error {
	v, err := cs.decode(val)
	if err != nil {
		return err
	}

	if !cs.changed {
		cs.value = v
	} else {
		cs.value = append(cs.value, v...)
	}
	cs.changed = true

	return nil
}

func (cs credentialSliceValue) Type() string {
	return "credentialSlice"
}

func (cs credentialSliceValue) String() string {
	if len(cs.value) == 0 {
		return "[]"
	}
	jb, err := json.Marshal(cs.value)
	if err != nil {
		return fmt.Sprintf("<encoding error: %v>", err)
	}
	return string(jb)
}

func (cs *credentialSliceValue) Append(val string) error {
	v, err := cs.decodeObject(val)
	if err != nil {
		return err
	}
	cs.value = append(cs.value, v)
	return nil
}

func (cs *credentialSliceValue) Replace(val []string) error {
	creds := []credential{}
	for _, s := range val {
		v, err := cs.decodeObject(s)
		if err != nil {
			return err
		}
		creds = append(creds, v)
	}
	cs.value = creds
	return nil
}

func (cs credentialSliceValue) GetSlice() []string {
	if len(cs.value) == 0 {
		return nil
	}
	ret := []string{}
	for _, cred := range cs.value {
		ret = append(ret, cred.String())
	}
	return ret
}
