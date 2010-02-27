#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to sync your checkout, build a Chromium OS image, and test it all
# with one command.  Can also check out a new Chromium OS checkout and
# perform a subset of the above operations.
#
# Here are some example runs:
#
# sync_build_test.sh
#   syncs, recreates local repo and chroot, builds, and masters an
#   image in the checkout based on your current directory, or if you
#   are not in a checkout, based on the top level directory the script
#   is run from.
#
# sync_build_test.sh --image_to_usb=/dev/sdb -i
#   same as above but then images USB device /dev/sdb with the image.
#   Also prompt the user in advance of the steps we'll take to make
#   sure they agrees.
#
# sync_build_test.sh --top=~/foo --nosync --remote 192.168.1.2
#   builds and masters an image in ~/foo, and live updates the machine
#   at 192.168.1.2 with that image.
#
# sync_build_test.sh --top=~/newdir --test "Pam BootPerfServer" \
#      --remote=192.168.1.2
#   creates a new checkout in ~/newdir, builds and masters an image
#   which is live updated to 192.168.1.2 and then runs
#   two tests (Pam and BootPerfServer) against that machine.
#
# sync_build_test.sh --grab_buildbot=LATEST --test Pam --remote=192.168.1.2
#   grabs the latest build from the buildbot, properly modifies it,
#   reimages 192.168.1.2, and runs the given test on it.
#
# Environment variables that may be useful:
#   BUILDBOT_URI - default value for --buildbot_uri
#   CHROMIUM_REPO - default value for --repo
#   CHRONOS_PASSWD - default value for --chronos_passwd
#

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"


DEFINE_string board "x86-generic" "Board setting"
DEFINE_boolean build ${FLAGS_TRUE} \
    "Build all code (but not necessarily master image)"
DEFINE_boolean build_autotest ${FLAGS_FALSE} "Build autotest"
DEFINE_string buildbot_uri "${BUILDBOT_URI}" \
    "Base URI to buildbot build location which contains LATEST file"
DEFINE_string chronos_passwd "${CHRONOS_PASSWD}" \
    "Use this as the chronos user passwd (defaults to \$CHRONOS_PASSWD)"
DEFINE_string chroot "" "Chroot to build/use"
DEFINE_boolean force_make_chroot ${FLAGS_FALSE} "Run make_chroot indep of sync"
DEFINE_string grab_buildbot "" \
    "Instead of building, grab this full image.zip URI generated by the \
buildbot"
DEFINE_boolean image_to_live ${FLAGS_FALSE} \
    "Put the resulting image on live instance (requires --remote)"
DEFINE_string image_to_usb "" \
    "Treat this device as USB and put the image on it after build"
# You can set jobs > 1 but then your build may break and you may need
# to retry.  Setting it to 1 is best for non-interactive sessions.
DEFINE_boolean interactive ${FLAGS_FALSE} \
    "Tell user what we plan to do and wait for input to proceed" i
DEFINE_integer jobs -1 "Concurrent build jobs"
DEFINE_boolean master ${FLAGS_TRUE} "Master an image from built code"
DEFINE_boolean mod_image_for_test ${FLAGS_FALSE} "Modify the image for testing"
DEFINE_string remote "" \
    "Use this hostname/IP for live updating and running tests"
DEFINE_string repo "${CHROMIUMOS_REPO}" "gclient repo for chromiumos"
DEFINE_boolean sync ${FLAGS_TRUE} "Sync the checkout"
DEFINE_string test "" \
    "Test the built image with the given params to run_remote_tests"
DEFINE_string top "" \
    "Root directory of your checkout (defaults to determining from your cwd)"
DEFINE_boolean withdev ${FLAGS_TRUE} "Build development packages"
DEFINE_boolean unittest ${FLAGS_TRUE} "Run unit tests"


# Returns a heuristic indicating if we believe this to be a google internal
# development environment.
# Returns:
#   0 if so, 1 otherwise
function is_google_environment() {
  hostname | egrep -q .google.com\$
  return $?
}


# Validates parameters and sets "intelligent" defaults based on other
# parameters.
function validate_and_set_param_defaults() {
  if [[ -z "${FLAGS_top}" ]]; then
    local test_dir=$(pwd)
    while [[ "${test_dir}" != "/" ]]; do
      if [[ -d "${test_dir}/src/platform/pam_google" ]]; then
        FLAGS_top="${test_dir}"
        break
      fi
      test_dir=$(dirname "${test_dir}")
    done
  fi

  if [[ -z "${FLAGS_top}" ]]; then
    # Use the top directory based on where this script runs from
    FLAGS_top=$(dirname $(dirname $(dirname $0)))
  fi

  # Canonicalize any symlinks
  if [[ -d "${FLAGS_top}" ]]; then
    FLAGS_top=$(readlink -f "${FLAGS_top}")
  fi

  if [[ -z "${FLAGS_chroot}" ]]; then
    FLAGS_chroot="${FLAGS_top}/chroot"
  fi

  # If chroot does not exist, force making it
  if [[ ! -d "${FLAGS_chroot}" ]]; then
    FLAGS_force_make_chroot=${FLAGS_TRUE}
  fi

  if [[ -z "${FLAGS_repo}" ]]; then
    if is_google_environment; then
      FLAGS_repo="ssh://git@chromiumos-git//chromeos"
    else
      FLAGS_repo="http://src.chromium.org/git/chromiumos.git"
    fi
  fi

  if [[ -n "${FLAGS_test}" ]]; then
    # If you specify that tests should be run, we assume the image
    # is modified to run tests.
    FLAGS_mod_image_for_test=${FLAGS_TRUE}
    # If you specify that tests should be run, we assume you want
    # to live update the image.
    FLAGS_image_to_live=${FLAGS_TRUE}
  fi

  # If they gave us a remote host, then we assume they want us to do a live
  # update.
  if [[ -n "${FLAGS_remote}" ]]; then
    FLAGS_image_to_live=${FLAGS_TRUE}
  fi

  # Grabbing a buildbot build is exclusive with building
  if [[ -n "${FLAGS_grab_buildbot}" ]]; then
    if [[ -z "${FLAGS_buildbot_uri}" ]]; then
      echo "--grab_buildbot requires --buildbot_uri"
      exit 1
    fi
    FLAGS_build=${FLAGS_FALSE}
    FLAGS_master=${FLAGS_FALSE}
  fi

  if [[ ${FLAGS_image_to_live} -eq ${FLAGS_TRUE} ]]; then
    if [[ ${FLAGS_mod_image_for_test} -eq ${FLAGS_FALSE} ]]; then
      echo "WARNING: You have specified to live reimage a machine with"
      echo "an image that is not modified for test (so it cannot be"
      echo "later live reimaged)"
    fi
    if [[ -n "${FLAGS_image_to_usb}" ]]; then
      echo "WARNING: You have specified to both live reimage a machine and"
      echo "write a USB image.  Is this what you wanted?"
    fi
    if [[ -z "${FLAGS_remote}" ]]; then
      echo "Please specify --remote with --image_to_live"
      exit 1
    fi
  fi

  if [[ ${FLAGS_mod_image_for_test} -eq ${FLAGS_TRUE} ]]; then
    # Override any specified chronos password with the test one
    local test_file=$(dirname $0)"/mod_for_test_scripts/test_account.passwd"
    FLAGS_chronos_passwd=$(head -1 "${test_file}")
    # Default to building autotests whenever we mod image for test.
    # TODO(kmixter): Make this more efficient by either doing incremental
    # building, or only building if the tests we're running needs to be.
    FLAGS_build_autotest=${FLAGS_TRUE}
    # If you're modding for test, you also want developer packages.
    FLAGS_withdev=${FLAGS_TRUE}
  fi

  if [[ -n "${FLAGS_image_to_usb}" ]]; then
    local device=${FLAGS_image_to_usb#/dev/}
    if [[ -z "${device}" ]]; then
      echo "Expected --image_to_usb option of /dev/* format"
      exit 1
    fi
    local is_removable=$(cat /sys/block/${device}/removable)
    if [[ "${is_removable}" != "1" ]]; then
      echo "Could not verify that ${device} for image_to_usb is removable"
      exit 1
    fi
  fi
}


# Prints a description of what we are doing or did
function describe_steps() {
  if [[ ${FLAGS_sync} -eq ${FLAGS_TRUE} ]]; then
    echo " * Sync client (gclient sync)"
    if is_google_environment; then
      echo " * Create proper src/scripts/.chromeos_dev"
    fi
  fi
  if [[ ${FLAGS_force_make_chroot} -eq ${FLAGS_TRUE} ]]; then
    echo " * Rebuild chroot (make_chroot) in ${FLAGS_chroot}"
  fi
  local set_passwd=${FLAGS_FALSE}
  if [[ ${FLAGS_build} -eq ${FLAGS_TRUE} ]]; then
    local withdev=""
    local jobs=" single job (slow but safe)"
    if [[ ${FLAGS_jobs} -gt 1 ]]; then
      jobs=" ${FLAGS_jobs} jobs (may cause build failure)"
    fi
    if [[ ${FLAGS_withdev} -eq ${FLAGS_TRUE} ]]; then
      withdev=" with dev packages"
    fi
    echo " * Build image${withdev}${jobs}"
    set_passwd=${FLAGS_TRUE}
    if [[ ${FLAGS_build_autotest} -eq ${FLAGS_TRUE} ]]; then
      echo " * Cross-build autotest client tests (build_autotest)"
    fi
  fi
  if [[ ${FLAGS_master} -eq ${FLAGS_TRUE} ]]; then
    echo " * Master image (build_image)"
  fi
  if [[ -n "${FLAGS_grab_buildbot}" ]]; then
    if [[ "${FLAGS_grab_buildbot}" == "LATEST" ]]; then
      echo " * Grab latest buildbot image under ${FLAGS_buildbot_uri}"
    else
      echo " * Grab buildbot image zip at URI ${FLAGS_grab_buildbot}"
    fi
  fi
  if [[ ${FLAGS_mod_image_for_test} -eq ${FLAGS_TRUE} ]]; then
    echo " * Make image able to run tests (mod_image_for_test)"
    set_passwd=${FLAGS_TRUE}
  fi
  if [[ ${set_passwd} -eq ${FLAGS_TRUE} ]]; then
    if [[ -n "${FLAGS_chronos_passwd}" ]]; then
      echo " * Set chronos password to ${FLAGS_chronos_passwd}"
    else
      echo " * Set chronos password randomly"
    fi
  fi
  if [[ -n "${FLAGS_image_to_usb}" ]]; then
    echo " * Write the image to USB device ${FLAGS_image_to_usb}"
  fi
  if [[ ${FLAGS_image_to_live} -eq ${FLAGS_TRUE} ]]; then
    echo " * Reimage live test Chromium OS instance at ${FLAGS_remote}"
  fi
  if [[ -n "${FLAGS_test}" ]]; then
    echo " * Run tests (${FLAGS_test}) on machine at ${FLAGS_remote}"
  fi
}


# Get user's permission on steps to take
function interactive() {
  echo "Planning these steps on ${FLAGS_top}:"
  describe_steps
  read -p "Are you sure (y/N)? " SURE
  # Get just the first character
  if [[ "${SURE:0:1}" != "y" ]]; then
    echo "Ok, better safe than sorry."
    exit 1
  fi
}


# Runs gclient config on a new checkout directory.
function config_new_checkout() {
  # We only know how to check out to a pattern like ~/foo/chromeos so
  # make sure that's the pattern the user has given.
  echo "Checking out ${FLAGS_top}"
  if [[ $(basename "${FLAGS_top}") != "chromeos" ]]; then
    echo "The --top directory does not exist and to check it out requires"
    echo "the name to end in chromeos (try --top=${FLAGS_top}/chromeos)"
    exit 1
  fi
  local top_parent=$(dirname "${FLAGS_top}")
  mkdir -p "${top_parent}"
  cd "${top_parent}"
  gclient config "${FLAGS_repo}"
}


# Changes to a directory relative to the top/root directory of
# the checkout.
# Arguments:
#   $1 - relative path
function chdir_relative() {
  local dir=$1
  echo "+ cd ${dir}"
  # Allow use of .. before the innermost directory of FLAGS_top exists
  if [[ "${dir}" == ".." ]]; then
    dir=$(dirname "${FLAGS_top}")
  else
    dir="${FLAGS_top}/${dir}"
  fi
  cd "${dir}"
}


# Describe to the user that a phase is running (and make it obviously when
# scrolling through lots of output).
# Arguments:
#   $1 - phase description
function describe_phase() {
  local desc="$1"
  echo ""
  echo "#"
  echo "#"
  echo "# ${desc}"
  echo "#"
}


# Runs a phase, describing it first, and also updates the sudo timeout
# afterwards.
# Arguments:
#   $1 - phase description
#   $2.. - command/params to run
function run_phase() {
  local desc="$1"
  shift
  describe_phase "${desc}"
  echo "+ $@"
  "$@"
  sudo -v
}


# Runs a phase, similar to run_phase, but runs within the chroot.
# Arguments:
#   $1 - phase description
#   $2.. - command/params to run in chroot
function run_phase_in_chroot() {
  local desc="$1"
  shift
  run_phase "${desc}" ./enter_chroot.sh "--chroot=${FLAGS_chroot}" -- "$@"
}


# Record start time.
function set_start_time() {
  START_TIME=$(date '+%s')
}


# Display duration
function show_duration() {
  local current_time=$(date '+%s')
  local duration=$((${current_time} - ${START_TIME}))
  local minutes_duration=$((${duration} / 60))
  local seconds_duration=$((${duration} % 60))
  printf "Total time: %d:%02ds\n" "${minutes_duration}" "${seconds_duration}"
}


# Runs gclient sync, setting up .chromeos_dev and preparing for
# local repo setup
function sync() {
  # cd to the directory below
  chdir_relative ..
  run_phase "Synchronizing client" gclient sync
  chdir_relative .
  git cl config "file://$(pwd)/codereview.settings"
  if is_google_environment; then
    local base_dir=$(dirname $(dirname "${FLAGS_top}"))
    echo <<EOF > src/scripts/.chromeos_dev
# Use internal chromeos-deb repository
CHROMEOS_EXT_MIRROR="http://chromeos-deb/ubuntu"
CHROMEOS_EXT_SUITE="karmic"

# Assume Chrome is checked out nearby
CHROMEOS_CHROME_DIR="${base_dir}/chrome"
EOF
  fi
}


function check_rootfs_validity() {
  echo "Checking rootfs validity"
  local device=$(sudo losetup -f)
  local invalid=0
  sudo losetup "${device}" rootfs.image
  sudo mount "${device}" rootfs
  if [[ ! -e rootfs/boot/vmlinuz ]]; then
    echo "This image has no kernel"
    invalid=1
  fi
  sudo umount rootfs
  sudo losetup -d "${device}"
  return ${invalid}
}


# Downloads a buildbot image
function grab_buildbot() {
  if [[ "${FLAGS_grab_buildbot}" == "LATEST" ]]; then
    local latest=$(curl "${FLAGS_buildbot_uri}/LATEST")
    if [[ -z "${latest}" ]]; then
      echo "Error finding latest."
      exit 1
    fi
    FLAGS_grab_buildbot="${FLAGS_buildbot_uri}/${latest}/image.zip"
  fi
  local dl_dir=$(mktemp -d "/tmp/image.XXXX")
  echo "Grabbing image from ${FLAGS_grab_buildbot} to ${dl_dir}"
  run_phase "Downloading image" curl "${FLAGS_grab_buildbot}" \
      -o "${dl_dir}/image.zip"
  cd "${dl_dir}"
  unzip image.zip
  check_rootfs_validity
  echo "Copying in local_repo/local_packages"
  # TODO(kmixter): Make this architecture indep once buildbot is.
  mv -f local_repo/local_packages/* "${FLAGS_top}/src/build/x86/local_packages"
  local image_basename=$(basename $(dirname "${FLAGS_grab_buildbot}"))
  local image_dir="${FLAGS_top}/src/build/images/${image_basename}"
  echo "Copying in build image to ${image_dir}"
  rm -rf "${image_dir}"
  mkdir -p "${image_dir}"
  # Note that if mbr.image does not exist, this image was not successful.
  mv mbr.image rootfs.image "${image_dir}"
  chdir_relative .
  run_phase "Removing downloaded image" rm -rf "${dl_dir}"
}

function main() {
  assert_outside_chroot
  assert_not_root_user

  # Parse command line
  FLAGS "$@" || exit 1
  eval set -- "${FLAGS_ARGV}"

  # Die on any errors.
  set -e

  validate_and_set_param_defaults

  # Cache up sudo status
  sudo -v

  if [[ ${FLAGS_interactive} -eq ${FLAGS_TRUE} ]]; then
    interactive
  fi

  set_start_time

  local withdev_param=""
  if [[ ${FLAGS_withdev} -eq ${FLAGS_TRUE} ]]; then
    withdev_param="--withdev"
  fi

  local jobs_param=""
  if [[ ${FLAGS_jobs} -gt 1 ]]; then
    jobs_param="--jobs=${FLAGS_jobs}"
  fi

  local board_param="--board=${FLAGS_board}"

  if [[ ! -e "${FLAGS_top}" ]]; then
    config_new_checkout
  fi

  if [[ ${FLAGS_sync} -eq ${FLAGS_TRUE} ]]; then
    sync
  fi

  if [[ -n "${FLAGS_grab_buildbot}" ]]; then
    grab_buildbot
  fi

  if [[ ${FLAGS_force_make_chroot} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    run_phase "Replacing chroot" ./make_chroot --replace \
        "--chroot=${FLAGS_chroot}" ${jobs_param}
  fi

  if [[ ${FLAGS_build} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    # Only setup board target if the directory does not exist
    if [[ ! -d "${FLAGS_top}/chroot/build/${FLAGS_board}" ]]; then
      run_phase_in_chroot "Setting up board target" \
          ./setup_board "${board_param}"
    fi
    local build_autotest_param=""
    if [[ ${FLAGS_build_autotest} -eq ${FLAGS_TRUE} ]]; then
      build_autotest_param="--withautotest"
    fi

    run_phase_in_chroot "Building packages" \
        ./build_packages "${board_param}" \
        ${jobs_param} ${withdev_param} ${build_autotest_param}

    # TODO(kmixter): Enable this once build_tests works, but even
    # then only do it when not cross compiling.
    if [[ '' ]]; then
      run_phase_in_chroot "Building and running unit tests" \
        "./build_tests.sh && ./run_tests.sh"
    fi
  fi

  if [[ ${FLAGS_master} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    if [[ -n "${FLAGS_chronos_passwd}" ]]; then
      run_phase_in_chroot "Setting default chronos password" \
      ./enter_chroot.sh "echo '${FLAGS_chronos_passwd}' | \
                        ~/trunk/src/scripts/set_shared_user_password.sh"
    fi
    run_phase_in_chroot "Mastering image" ./build_image \
        "${board_param}" --replace ${withdev_param} \
        ${jobs_param}
  fi

  if [[ ${FLAGS_mod_image_for_test} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    run_phase_in_chroot "Modifying image for test" \
        "./mod_image_for_test.sh" "${board_param}" --yes
  fi

  if [[ -n "${FLAGS_image_to_usb}" ]]; then
    chdir_relative src/scripts
    run_phase "Installing image to USB" \
        ./image_to_usb.sh --yes "--to=${FLAGS_image_to_usb}" "${board_param}"
  fi

  if [[ ${FLAGS_image_to_live} -eq ${FLAGS_TRUE} ]]; then
    chdir_relative src/scripts
    run_phase "Re-imaging live Chromium OS machine ${FLAGS_remote}" \
      ./image_to_live.sh "--remote=${FLAGS_remote}" --update_known_hosts
  fi

  if [[ -n "${FLAGS_test}" ]]; then
    chdir_relative src/scripts
    # We purposefully do not quote FLAGS_test below as we expect it may
    # have multiple parameters
    run_phase "Running tests on Chromium OS machine ${FLAGS_remote}" \
      ./run_remote_tests.sh "--remote=${FLAGS_remote}" ${FLAGS_test} \
      "${board_param}"
  fi

  echo "Successfully used ${FLAGS_top} to:"
  describe_steps
  show_duration
}


main $@
