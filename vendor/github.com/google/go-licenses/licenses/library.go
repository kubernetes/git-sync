// Copyright 2019 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package licenses

import (
	"context"
	"fmt"
	"go/build"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/golang/glog"
	"github.com/google/go-licenses/internal/third_party/pkgsite/source"
	"golang.org/x/tools/go/packages"
)

// Library is a collection of packages covered by the same license file.
type Library struct {
	// LicensePath is the path of the file containing the library's license.
	LicensePath string
	// Packages contains import paths for Go packages in this library.
	// It may not be the complete set of all packages in the library.
	Packages []string
	// Parent go module.
	module *Module
}

// PackagesError aggregates all Packages[].Errors into a single error.
type PackagesError struct {
	pkgs []*packages.Package
}

func (e PackagesError) Error() string {
	var str strings.Builder
	str.WriteString(fmt.Sprintf("errors for %q:", e.pkgs))
	packages.Visit(e.pkgs, nil, func(pkg *packages.Package) {
		for _, err := range pkg.Errors {
			str.WriteString(fmt.Sprintf("\n%s: %s", pkg.PkgPath, err))
		}
	})
	return str.String()
}

// Libraries returns the collection of libraries used by this package, directly or transitively.
// A library is a collection of one or more packages covered by the same license file.
// Packages not covered by a license will be returned as individual libraries.
// Standard library packages will be ignored.
func Libraries(ctx context.Context, classifier Classifier, ignoredPaths []string, importPaths ...string) ([]*Library, error) {
	cfg := &packages.Config{
		Context: ctx,
		Mode:    packages.NeedImports | packages.NeedDeps | packages.NeedFiles | packages.NeedName | packages.NeedModule,
	}

	rootPkgs, err := packages.Load(cfg, importPaths...)
	if err != nil {
		return nil, err
	}

	pkgs := map[string]*packages.Package{}
	pkgsByLicense := make(map[string][]*packages.Package)
	pkgErrorOccurred := false
	otherErrorOccurred := false
	packages.Visit(rootPkgs, func(p *packages.Package) bool {
		if len(p.Errors) > 0 {
			pkgErrorOccurred = true
			return false
		}
		if isStdLib(p) {
			// No license requirements for the Go standard library.
			return false
		}
		for _, i := range ignoredPaths {
			if strings.HasPrefix(p.PkgPath, i) {
				// Marked to be ignored.
				return true
			}
		}

		if len(p.OtherFiles) > 0 {
			glog.Warningf("%q contains non-Go code that can't be inspected for further dependencies:\n%s", p.PkgPath, strings.Join(p.OtherFiles, "\n"))
		}
		var pkgDir string
		switch {
		case len(p.GoFiles) > 0:
			pkgDir = filepath.Dir(p.GoFiles[0])
		case len(p.CompiledGoFiles) > 0:
			pkgDir = filepath.Dir(p.CompiledGoFiles[0])
		case len(p.OtherFiles) > 0:
			pkgDir = filepath.Dir(p.OtherFiles[0])
		default:
			// This package is empty - nothing to do.
			return true
		}
		if p.Module == nil {
			otherErrorOccurred = true
			glog.Errorf("Package %s does not have module info. Non go modules projects are no longer supported. For feedback, refer to https://github.com/google/go-licenses/issues/128.", p.PkgPath)
			return false
		}
		licensePath, err := Find(pkgDir, p.Module.Dir, classifier)
		if err != nil {
			glog.Errorf("Failed to find license for %s: %v", p.PkgPath, err)
		}
		pkgs[p.PkgPath] = p
		pkgsByLicense[licensePath] = append(pkgsByLicense[licensePath], p)
		return true
	}, nil)
	if pkgErrorOccurred {
		return nil, PackagesError{
			pkgs: rootPkgs,
		}
	}
	if otherErrorOccurred {
		return nil, fmt.Errorf("some errors occurred when loading direct and transitive dependency packages")
	}

	var libraries []*Library
	for licensePath, pkgs := range pkgsByLicense {
		if licensePath == "" {
			// No license for these packages - return each one as a separate library.
			for _, p := range pkgs {
				libraries = append(libraries, &Library{
					Packages: []string{p.PkgPath},
					module:   newModule(p.Module),
				})
			}
			continue
		}
		lib := &Library{
			LicensePath: licensePath,
		}
		for _, pkg := range pkgs {
			lib.Packages = append(lib.Packages, pkg.PkgPath)
			if lib.module == nil && pkg.Module != nil {
				// All the sub packages should belong to the same module.
				lib.module = newModule(pkg.Module)
			}
		}
		if lib.module != nil && lib.module.Path != "" && lib.module.Dir == "" {
			// A known cause is that the module is vendored, so some information is lost.
			splits := strings.SplitN(lib.LicensePath, "/vendor/", 2)
			if len(splits) != 2 {
				glog.Warningf("module %s does not have dir and it's not vendored, cannot discover the license URL. Report to go-licenses developer if you see this.", lib.module.Path)
			} else {
				// This is vendored. Handle this known special case.

				// Extra note why we identify a vendored package like this.
				//
				// For a normal package:
				// * if it's not in a module, lib.module == nil
				// * if it's in a module, lib.module.Dir != ""
				// Only vendored modules will have lib.module != nil && lib.module.Path != "" && lib.module.Dir == "" as far as I know.
				// So the if condition above is already very strict for vendored packages.
				// On top of it, we checked the lib.LicensePath contains a vendor folder in it.
				// So it's rare to have a false positive for both conditions at the same time, although it may happen in theory.
				//
				// These assumptions may change in the future,
				// so we need to keep this updated with go tooling changes.
				parentModDir := splits[0]
				var parentPkg *packages.Package
				for _, rootPkg := range rootPkgs {
					if rootPkg.Module != nil && rootPkg.Module.Dir == parentModDir {
						parentPkg = rootPkg
						break
					}
				}
				if parentPkg == nil {
					glog.Warningf("cannot find parent package of vendored module %s", lib.module.Path)
				} else {
					// Vendored modules should be commited in the parent module, so it counts as part of the
					// parent module.
					lib.module = newModule(parentPkg.Module)
				}
			}
		}
		libraries = append(libraries, lib)
	}
	// Sort libraries to produce a stable result for snapshot diffing.
	sort.Slice(libraries, func(i, j int) bool {
		return libraries[i].Name() < libraries[j].Name()
	})
	return libraries, nil
}

// Name is the common prefix of the import paths for all of the packages in this library.
func (l *Library) Name() string {
	return commonAncestor(l.Packages)
}

func commonAncestor(paths []string) string {
	if len(paths) == 0 {
		return ""
	}
	if len(paths) == 1 {
		return paths[0]
	}
	sort.Strings(paths)
	min, max := paths[0], paths[len(paths)-1]
	lastSlashIndex := 0
	for i := 0; i < len(min) && i < len(max); i++ {
		if min[i] != max[i] {
			return min[:lastSlashIndex]
		}
		if min[i] == '/' {
			lastSlashIndex = i
		}
	}
	return min
}

func (l *Library) String() string {
	return l.Name()
}

// FileURL attempts to determine the URL for a file in this library using
// go module name and version.
func (l *Library) FileURL(ctx context.Context, filePath string) (string, error) {
	if l == nil {
		return "", fmt.Errorf("library is nil")
	}
	wrap := func(err error) error {
		return fmt.Errorf("getting file URL in library %s: %w", l.Name(), err)
	}
	m := l.module
	if m == nil {
		return "", wrap(fmt.Errorf("empty go module info"))
	}
	if m.Dir == "" {
		return "", wrap(fmt.Errorf("empty go module dir"))
	}
	client := source.NewClient(time.Second * 20)
	remote, err := source.ModuleInfo(ctx, client, m.Path, m.Version)
	if err != nil {
		return "", wrap(err)
	}
	if m.Version == "" {
		// This always happens for the module in development.
		// Note#1 if we pass version=HEAD to source.ModuleInfo, github tag for modules not at the root
		// of the repo will be incorrect, because there's a convention that:
		// * I have a module at github.com/google/go-licenses/submod.
		// * The module is of version v1.0.0.
		// Then the github tag should be submod/v1.0.0.
		// In our case, if we pass HEAD as version, the result commit will be submod/HEAD which is incorrect.
		// Therefore, to workaround this problem, we directly set the commit after getting module info.
		//
		// Note#2 repos have different branches as default, some use the
		// master branch and some use the main branch. However, HEAD
		// always refers to the default branch, so it's better than
		// both of master/main when we do not know which branch is default.
		// Examples:
		// * https://github.com/google/go-licenses/blob/HEAD/LICENSE
		// points to latest commit of master branch.
		// * https://github.com/google/licenseclassifier/blob/HEAD/LICENSE
		// points to latest commit of main branch.
		remote.SetCommit("HEAD")
		glog.Warningf("module %s has empty version, defaults to HEAD. The license URL may be incorrect. Please verify!", m.Path)
	}
	relativePath, err := filepath.Rel(m.Dir, filePath)
	if err != nil {
		return "", wrap(err)
	}
	// TODO: there are still rare cases this may result in an incorrect URL.
	// https://github.com/google/go-licenses/issues/73#issuecomment-1005587408
	return remote.FileURL(relativePath), nil
}

// isStdLib returns true if this package is part of the Go standard library.
func isStdLib(pkg *packages.Package) bool {
	if pkg.Name == "unsafe" {
		// Special case unsafe stdlib, because it does not contain go files.
		return true
	}
	if len(pkg.GoFiles) == 0 {
		return false
	}
	return strings.HasPrefix(pkg.GoFiles[0], build.Default.GOROOT)
}
