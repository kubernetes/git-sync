#!/bin/bash

# Copyright 2022 The Kubernetes Authors.
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

# USAGE: stage-binaries.sh -o <staging-dir> ( -p <package> | -b binary )..."
#
# Stages all the packages or files and their dependencies (+ libraries and
# copyrights) to the staging dir.
#
# This is intended to be used in a multi-stage docker build.

set -o errexit
set -o nounset
set -o pipefail

# Dump the call stack.
#
# $1: frames to skip
function stack() {
  local frame="${1:-0}"
  frame="$((frame+1))" # for this frame
  local indent=""
  while [[ -n "${FUNCNAME["${frame}"]:-}" ]]; do
      if [[ -n "$indent" ]]; then
          echo -ne "  from "
      fi
      indent="true"
      local file
      file="$(basename "${BASH_SOURCE["${frame}"]}")"
      local line="${BASH_LINENO["$((frame-1))"]}" # ???
      local func="${FUNCNAME["${frame}"]:-}"
      echo -e "${func}() ${file}:${line}"
      frame="$((frame+1))"
  done
}

# A handler for when we exit automatically on an error.
# Borrowed from kubernetes, which was borrowed from
# https://gist.github.com/ahendrix/7030300
function errexit() {
  # If the shell we are in doesn't have errexit set (common in subshells) then
  # don't dump stacks.
  set +o | grep -qe "-o errexit" || return

  # Dump stack
  echo -n "FATAL: error at " >&2
  stack 1 >&2 # skip this frame

  # Exit, really, right now.
  local pgid
  pgid="$(awk '{print $5}' /proc/self/stat)"
  kill -- -"${pgid}"
}

# trap ERR to provide an error handler whenever a command exits nonzero  this
# is a more verbose version of set -o errexit
trap 'errexit' ERR

# setting errtrace allows our ERR trap handler to be propagated to functions,
# expansions and subshells
set -o errtrace

function DBG() {
    if [[ -n "${DBG:-}" ]]; then
        echo "$@"
    fi
}

function grep_allow_nomatch() {
    # grep exits 0 on match, 1 on no match, 2 on error
    grep "$@" || [[ $? == 1 ]]
}

function _indent() {
    (
        IFS="" # preserve spaces in `read`
        while read -r X; do
            echo "  ${X}"
        done
    )
}

# run "$@" and indent the output
#
# See the workaround in errexit before you rename this.
function indent() {
    # This lets us process stderr and stdout without merging them, without
    # bash-isms.  This MUST NOT be wrapped in a conditional, or else errexit no
    # longer applies to the executed command.
    { set -o errexit; "$@" 2>&1 1>&3 | _indent; } 3>&1 1>&2 | _indent
}

# Track these globally so we only load it once.
ROOT_FWD_LINKS=()
ROOT_REV_LINKS=()

function load_root_links() {
    local staging="$1"

    while read -r x; do
        if [[ -L "/${x}" ]]; then
            ROOT_FWD_LINKS+=("/${x}")
            ROOT_REV_LINKS+=("$(realpath "/${x}")")
        fi
    done < <(ls /)
}

# file_to_package identifies the debian package(s) that provided the file $1
function file_to_package() {
    local file="$1"

    # Newer versions of debian symlink /lib -> /usr/lib (and others), but dpkg
    # has some files in its DB as "/lib/<whatever>" and others as
    # "/usr/lib/<whatever>".  This causes havoc trying to identify the package
    # for a library discovered via ldd.
    #
    # So, to combat this we build a "map" of root links, and their targets, and
    # try to search for both paths.

    local alt=""
    local i=0
    while (( "${i}" < "${#ROOT_FWD_LINKS[@]}" )); do
        fwd="${ROOT_FWD_LINKS[i]}"
        rev="${ROOT_REV_LINKS[i]}"
        if [[ "${file}" =~ ^"${fwd}/" ]]; then
            alt="${file/#"${fwd}"/"${rev}"}"
            break
        elif [[ "${file}" =~ ^"${rev}/" ]]; then
            alt="${file/#"${rev}"/"${fwd}"}"
            break
        fi
        i=$((i+1))
    done

    local out=""
    local result=""
    out="$(dpkg-query --search "${file}" 2>&1)"
    # shellcheck disable=SC2181
    if [[ $? == 0 ]]; then
        result="${out}"
    elif [[ -n "${alt}" ]]; then
        out="$(dpkg-query --search "${alt}" 2>&1)"
        # shellcheck disable=SC2181
        if [[ $? == 0 ]]; then
            result="${out}"
        fi
    fi

    # If we found no match, let it error out.
    if [[ -z "${result}" ]]; then
        dpkg-query --search "${file}"
        return 1
    fi

    # `dpkg-query --search $file-pattern` outputs lines with the format: "$package: $file-path"
    # where $file-path belongs to $package.  Sometimes it has lines that say
    # "diversion" but there's no documented grammar I can find.  Multiple
    # packages can own one file, in which case multiple lines are output.
    echo "${result}" | (grep -v "diversion" || true) | cut -d':' -f1 | sed 's/,//g'
}

# stage_one_file stages the filepath $2 to $1, respecting symlinks
function stage_one_file() {
    local staging="$1"
    local file="$2"

    if [ -e "${staging}${file}" ]; then
        return
    fi

    # This will break the path into elements, so we can handle symlinks at any
    # level.
    local elems=()
    IFS='/' read -r -a elems <<< "${file}"
    # [0] is empty because of leading /
    if [[ "${elems[0]}" == "" ]]; then
        elems=("${elems[@]:1}")
    fi

    local path=""
    for elem in "${elems[@]}"; do
        path="${path}/${elem}"
        if [[ ! -e "${staging}${path}" ]]; then
            if [[ -d "${path}" && ! -L "${path}" ]]; then
                # strip the leading / and use tar, which preserves everything
                local rel="${path/#\//}"
                tar -C / -c --no-recursion "${rel}" | tar -C "${staging}" -x
            else
                # preserves hardlinks, symlinks, permissions, timestamps
                cp -lpP "${path}" "${staging}${path}"

                # if it is a symlink, also stage the target
                if [[ -L "${path}" ]]; then
                    stage_one_file "${staging}" "$(realpath "${path}")"
                fi
            fi
        fi
    done
}

# stage_file_and_deps stages the filepath $2 to $1, following symlinks and
# library deps, and staging copyrights
function stage_file_and_deps() {
    local staging="$1"
    local file="$2"

    # short circuit if we have done this file before
    if [[ -e "${staging}/${file}" ]]; then
        return
    fi

    # get the package so we can stage package metadata as well
    local packages
    packages="$(file_to_package "${file}")"
    if [[ -z "${packages}" ]]; then
        return 0 # no package(s), but no error either
    fi
    DBG "staging file ${file} from pkg(s) ${packages}"

    stage_one_file "${staging}" "${file}"

    # stage dependencies of binaries
    if [[ -x "${file}" && ! -d "${file}" ]]; then
        DBG "staging deps of file ${file}"
        while read -r lib; do
            indent stage_file_and_deps "${staging}" "${lib}"
        done < <( binary_to_libraries "${file}" )
    fi

    local package
    for package in ${packages}; do
        # stage the copyright for the file, if it exists
        local copyright_src="/usr/share/doc/${package}/copyright"
        local copyright_dst="${staging}/copyright/${package}/copyright.gz"
        if [[ -f "${copyright_src}" && ! -f "${copyright_dst}" ]]; then
            mkdir -p "$(dirname "${copyright_dst}")"
            gzip -9 --to-stdout "${copyright_src}" > "${copyright_dst}"
        fi

        # Since apt is not in the final image, stage the package status
        # (mimicking bazel).  This allows security scanners to run against it.
        # https://github.com/bazelbuild/rules_docker/commit/f5432b813e0a11491cf2bf83ff1a923706b36420
        mkdir -p "${staging}/var/lib/dpkg/status.d/"
        dpkg -s "${package}" > "${staging}/var/lib/dpkg/status.d/${package}"
    done
}

function stage_one_package() {
    local staging="$1"
    local pkg="$2"

    while read -r file; do
        indent stage_file_and_deps "${staging}" "${file}"
    done < <( dpkg -L "${pkg}" \
        | grep_allow_nomatch -vE '(/\.|/usr/share/(man|doc|.*-completion))' )
}

function get_dependent_packages() {
    local pkg="$1"
    # There's no easily found documented grammar for the output of this.
    # Sometimes it says:
    #    Depends: package
    # ...and other times it says:
    #    Depends <package>
    # ...but those don't really seem to be required.
    # There's also "PreDepends" which is like Depends but has semantic
    # differences that don't matter here.
    apt-cache depends "${pkg}" \
        | grep_allow_nomatch '^ *\(Pre\)\?Depends: [a-zA-Z0-9]' \
        | awk -F ':' '{print $2}'
}

# Args:
#   $1: path to staging dir
#   $2+: package names
function stage_packages() {
    local staging="$1"
    shift

    indent apt-get -y -qq -o Dpkg::Use-Pty=0 update

    local pkg
    for pkg; do
        echo "staging package ${pkg}"
        local du_before
        du_before="$(du -sk "${staging}" | cut -f1)"
        indent apt-get -y -qq -o Dpkg::Use-Pty=0 --no-install-recommends install "${pkg}"
        stage_one_package "$staging" "${pkg}"
        while read -r dep; do
            DBG "staging dependent package ${dep}"
            indent stage_one_package "${staging}" "${dep}"
        done < <( get_dependent_packages "${pkg}" )
        local du_after
        du_after="$(du -sk "${staging}" | cut -f1)"
        indent echo "package ${pkg} size: +$(( du_after - du_before )) kB (of ${du_after} kB)"
    done
}

# binary_to_libraries identifies the library files needed by the binary $1 with ldd
function binary_to_libraries() {
    local bin="$1"

    # see: https://man7.org/linux/man-pages/man1/ldd.1.html
    # Each output line looks like:
    #     linux-vdso.so.1 (0x00007fffb11c3000)
    #   or
    #     libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2f52d26000)
    #
    # This is a little funky because ldd treats static binaries as errors ("not
    # a dynamic executable") but static libraries as non-errors ("statically
    # linked").  We want real ldd errors, but static binaries are OK.
    if [[ "$(ldd "${bin}" 2>&1)" =~ "not a dynamic executable" ]]; then
        return
    fi
    ldd "${bin}" \
        `# skip static binaries` \
        | grep_allow_nomatch -v "statically linked" \
        `# linux-vdso is a special virtual shared object from the kernel` \
        `# see: http://man7.org/linux/man-pages/man7/vdso.7.html` \
        | grep_allow_nomatch -v 'linux-vdso' \
        `# strip the leading '${name} => ' if any so only '/lib-foo.so (0xf00)' remains` \
        | sed -E 's#.* => /#/#' \
        `# we want only the path remaining, not the (0x${LOCATION})` \
        | awk '{print $1}'
}

function stage_one_binary() {
    local staging="$1"
    local bin="$2"

    # locate the path to the binary
    local binary_path
    binary_path="$(which "${bin}")"

    # stage the binary itself
    stage_file_and_deps "${staging}" "${binary_path}"
}

function stage_binaries() {
    local staging="$1"
    shift

    local bin
    for bin; do
        echo "staging binary ${bin}"
        local du_before
        du_before="$(du -sk "${staging}" | cut -f1)"
        stage_one_binary "${staging}" "${bin}"
        local du_after
        du_after="$(du -sk "${staging}" | cut -f1)"
        indent echo "binary ${bin} size: +$(( du_after - du_before )) kB (of ${du_after} kB)"
    done
}

function stage_files() {
    local staging="$1"
    shift

    local bin
    for file; do
        echo "staging file ${file}"
        local du_before
        du_before="$(du -sk "${staging}" | cut -f1)"
        stage_one_file "${staging}" "${file}"
        local du_after
        du_after="$(du -sk "${staging}" | cut -f1)"
        indent echo "file ${file} size: +$(( du_after - du_before )) kB (of ${du_after} kB)"
    done
}

function usage() {
    echo "$0 -o <staging-dir> ( -p <package> | -b binary )..."
}

function main() {
    local staging=""
    local pkgs=()
    local bins=()
    local files=()

    while [ "$#" -gt 0 ]; do
    case "$1" in
        "-?")
            usage
            exit 0
            ;;
        "-b")
            if [[ -z "${2:-}" ]]; then
                echo "error: flag '-b' requires an argument" >&2
                usage >&2
                exit 2
            fi
            bins+=("$2")
            shift 2
            ;;
        "-f")
            if [[ -z "${2:-}" ]]; then
                echo "error: flag '-f' requires an argument" >&2
                usage >&2
                exit 2
            fi
            files+=("$2")
            shift 2
            ;;
        "-p")
            if [[ -z "${2:-}" ]]; then
                echo "error: flag '-p' requires an argument" >&2
                usage >&2
                exit 2
            fi
            pkgs+=("$2")
            shift 2
            ;;
        "-o")
            if [[ -z "${2:-}" ]]; then
                echo "error: flag '-o' requires an argument" >&2
                usage >&2
                exit 2
            fi
            staging="$2"
            shift 2
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 3
            ;;
    esac
    done

    if [[ -z "${staging}" ]]; then
        usage >&2
        exit 4
    fi

    # Newer versions of debian symlink /bin -> /usr/bin (and lib, and others).
    # The somewhat naive copying done in this program does not retain that,
    # which causes some files to be duplicated.  Fortunately, these are all in
    # the root dir, or we might have to do something more complicated.
    load_root_links "${staging}"

    if (( "${#pkgs[@]}" > 0 )); then
        stage_packages "${staging}" "${pkgs[@]}"
    fi
    if (( "${#bins[@]}" > 0 )); then
        stage_binaries "${staging}" "${bins[@]}"
    fi
    if (( "${#files[@]}" > 0 )); then
        stage_files "${staging}" "${files[@]}"
    fi

    echo "final staged size: $(du -sk "${staging}" | cut -f1) kB"
    du -xk --max-depth=3 "${staging}" | sort -n | _indent
}

main "$@"
