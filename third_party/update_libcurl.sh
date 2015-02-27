#!/bin/bash
##
##  Copyright (c) 2015 The WebM project authors. All Rights Reserved.
##
##  Use of this source code is governed by a BSD-style license
##  that can be found in the LICENSE file in the root of the source
##  tree. An additional intellectual property rights grant can be found
##  in the file PATENTS.  All contributing project authors may
##  be found in the AUTHORS file in the root of the source tree.
##
. $(dirname $0)/../common/common.sh

cleanup() {
  local readonly res=$?
  cd "${ORIG_PWD}"

  if [[ $res -ne 0 ]]; then
    elog "cleanup() trapped error"
  fi
  if [[ "${KEEP_WORK_DIR}" != "yes" ]]; then
    if [[ -n "${WORK_DIR}" ]] && [[ -d "${WORK_DIR}" ]]; then
      rm -rf "${WORK_DIR}"
    fi
  fi
}

update_libcurl_usage() {
cat << EOF
  Usage: ${0##*/} [arguments]
    --help: Display this message and exit.
    --git-hash <git hash/ref/tag>: Use this revision instead of HEAD.
    --keep-work-dir: Keep the work directory.
    --show-program-output: Show output from each step.
    --verbose: Show more output.
EOF
}

# Updates cmake vcxproj files to use static MSVC runtimes.
convert_cmake_projects_to_static_runtimes() {
  local readonly vcxproj="libcurl.vcxproj"
  for project_dir in ${CMAKE_PROJECT_DIRS[@]}; do
    eval sed -i \
      -e "s/MultiThreadedDebugDLL/MultiThreadedDebug/" \
      -e "s/MultiThreadedDLL/MultiThreaded/" \
      "${project_dir}/${vcxproj}" ${devnull}
  done
}

# Runs cmake to generate projects for MSVC.
cmake_generate_projects() {
  local readonly cmake_lists_dir="${THIRD_PARTY}/${WORK_DIR}/${LIBCURL}"
  local readonly orig_pwd="$(pwd)"

  vlog "Generating MSVC projects..."

  for (( i = 0; i < ${#CMAKE_MSVC_GENERATORS[@]}; ++i )); do
    mkdir -p "${CMAKE_GENERATION_DIRS[$i]}"
    cd "${CMAKE_GENERATION_DIRS[$i]}"
    eval cmake.exe "${cmake_lists_dir}" -G '"${CMAKE_MSVC_GENERATORS[$i]}"' \
      -DCURL_STATICLIB=ON ${devnull}
    cd "${orig_pwd}"
  done

  convert_cmake_projects_to_static_runtimes

  vlog "Done."
}

# Runs msbuild.exe on projects generated by cmake_generate_projects().
build_libs() {
  local readonly vcxproj="libcurl.vcxproj"
  local readonly orig_pwd="$(pwd)"

  vlog "Building libcurl..."

  for project_dir in ${CMAKE_PROJECT_DIRS[@]}; do
    cd "${project_dir}"

    for config in ${CMAKE_BUILD_CONFIGS[@]}; do
      eval msbuild.exe "${vcxproj}" -m -p:Configuration="${config}" ${devnull}
    done

    cd "${orig_pwd}"
  done

  vlog "Done."
}

# Installs libcurl includes, libraries, and PDB files. Includes come from the
# git repo in $WORK_DIR/$LIBCURL. Libraries and PDB files are picked up from the
# output locations of the projects built by build_libs().
install_libcurl() {
  local readonly target_dir="${THIRD_PARTY}/libcurl"

  vlog "Installing includes..."
  mkdir -p "${target_dir}"
  cp -rp "${THIRD_PARTY}/${WORK_DIR}/${LIBCURL}/include/" "${target_dir}"
  vlog "Done."

  # CMake generated vcxproj files place PDB files in config-named subdirs of
  # projname.dir. Projname.dir (curl.dir here) is a sibling of the actual
  # library build directory: Build an array of paths that can be used alongside
  # $CMAKE_BUILD_DIRS to copy pdb files where they belong.
  local readonly pdb_name="vc120.pdb"
  local readonly cmake_pdb_files=(
    ${CMAKE_PROJECT_DIRS[0]}/libcurl.dir/${CMAKE_BUILD_CONFIGS[0]}/${pdb_name}
    ${CMAKE_PROJECT_DIRS[0]}/libcurl.dir/${CMAKE_BUILD_CONFIGS[1]}/${pdb_name}
    ${CMAKE_PROJECT_DIRS[1]}/libcurl.dir/${CMAKE_BUILD_CONFIGS[0]}/${pdb_name}
    ${CMAKE_PROJECT_DIRS[1]}/libcurl.dir/${CMAKE_BUILD_CONFIGS[1]}/${pdb_name})

  vlog "Installing libraries..."
  local readonly lib_name="libcurl.lib"
  for (( i = 0; i < ${#CMAKE_BUILD_DIRS[@]}; ++i  )); do
    mkdir -p "${target_dir}/${LIBCURL_TARGET_LIB_DIRS[$i]}"
    cp -p "${CMAKE_BUILD_DIRS[$i]}/${lib_name}" \
      "${target_dir}/${LIBCURL_TARGET_LIB_DIRS[$i]}"
    cp -p "${cmake_pdb_files[$i]}" \
      "${target_dir}/${LIBCURL_TARGET_LIB_DIRS[$i]}"
  done
  vlog "Done."
}

# Clones libcurl and then runs cmake_generate_projects(), build_libs(), and
# install_libcurl() to update webmlive's version of the libcurl includes and
# libraries.
update_libcurl() {
  # Clone libcurl and checkout the desired ref.
  vlog "Cloning ${LIBCURL_GIT_URL}..."
  eval git clone "${LIBCURL_GIT_URL}" "${LIBCURL}" ${devnull}
  git_checkout "${GIT_HASH}" "${LIBCURL}"
  vlog "Done."

  # Generate projects using CMake.
  cmake_generate_projects

  # Build generated projects.
  build_libs

  # Install includes and libraries.
  install_libcurl
}

trap cleanup EXIT

# Defaults for command line options.
GIT_HASH="HEAD"
KEEP_WORK_DIR=""
MAKE_JOBS="1"

# Parse the command line.
while [[ -n "$1" ]]; do
  case "$1" in
    --help)
      update_libcurl_usage
      exit
      ;;
    --git-hash)
      GIT_HASH="$2"
      shift
      ;;
    --keep-work-dir)
      KEEP_WORK_DIR="yes"
      ;;
    --show-program-output)
      devnull=
      ;;
    --verbose)
      VERBOSE="yes"
      ;;
    *)
      update_libcurl_usage
      exit 1
      ;;
  esac
  shift
done

readonly CMAKE_BUILD_CONFIGS=(Debug RelWithDebInfo)
readonly CMAKE_MSVC_GENERATORS=("Visual Studio 12 Win64"
                                "Visual Studio 12")
readonly CMAKE_GENERATION_DIRS=(cmake_projects/x64 cmake_projects/x86)
readonly CMAKE_PROJECT_DIRS=(cmake_projects/x64/lib cmake_projects/x86/lib)

readonly CMAKE_BUILD_DIRS=(${CMAKE_PROJECT_DIRS[0]}/${CMAKE_BUILD_CONFIGS[0]}
                           ${CMAKE_PROJECT_DIRS[0]}/${CMAKE_BUILD_CONFIGS[1]}
                           ${CMAKE_PROJECT_DIRS[1]}/${CMAKE_BUILD_CONFIGS[0]}
                           ${CMAKE_PROJECT_DIRS[1]}/${CMAKE_BUILD_CONFIGS[1]})
readonly LIBCURL="libcurl"
readonly LIBCURL_GIT_URL="https://github.com/bagder/curl.git"
readonly LIBCURL_TARGET_LIB_DIRS=(win/x64/debug
                                  win/x64/release
                                  win/x86/debug
                                  win/x86/release)
readonly THIRD_PARTY="$(pwd)"
readonly WORK_DIR="tmp_$$"

if [[ "${VERBOSE}" = "yes" ]]; then
cat << EOF
  KEEP_WORK_DIR=${KEEP_WORK_DIR}
  GIT_HASH=${GIT_HASH}
  MAKE_JOBS=${MAKE_JOBS}
  VERBOSE=${VERBOSE}
  CMAKE_BUILD_CONFIGS=${CMAKE_BUILD_CONFIGS[@]}
  CMAKE_BUILD_DIRS=${CMAKE_BUILD_DIRS[@]}
  CMAKE_MSVC_GENERATORS=${CMAKE_MSVC_GENERATORS[@]}
  CMAKE_GENERATION_DIRS=${CMAKE_GENERATION_DIRS[@]}
  CMAKE_PROJECT_DIRS=${CMAKE_PROJECT_DIRS[@]}
  LIBCURL=${LIBCURL}
  LIBCURL_GIT_URL=${LIBCURL_GIT_URL}
  LIBCURL_TARGET_LIB_DIRS=${LIBCURL_TARGET_LIB_DIRS[@]}
  THIRD_PARTY=${THIRD_PARTY}
  WORK_DIR=${WORK_DIR}
EOF
fi

# Bail out if not running from the third_party directory.
check_dir "third_party"

# cmake.exe, git.exe, and msbuild.exe are ultimately required. Die when
# unavailable.
check_cmake
check_git
check_msbuild

# Make a work directory, and cd into to avoid making a mess.
mkdir "${WORK_DIR}"
cd "${WORK_DIR}"

# Update stuff.
update_libcurl

# Print the new text for README.webmlive.
cat << EOF

Libcurl includes and libraries updated. README.webmlive information follows:

libcurl
Version: $(git_revision ${LIBCURL})
URL: ${LIBCURL_GIT_URL}

EOF

