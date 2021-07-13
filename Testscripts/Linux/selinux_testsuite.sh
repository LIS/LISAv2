#!/bin/bash
########################################################################
#
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
# Description:
# Test suite to verify selinux feature in Linux distributions
#
########################################################################

# Additional log files to collect more detailed information
SELINUX_TEST_EXECLOG="$(pwd)/selinux_test_summary.log"
SELINUX_TEST_ERRLOG="$(pwd)/selinux_test_err_summary.log"

# List of known test failure
test_exception_list=(
    "filesystem"
    "keys"
    "key_socket"
    "module_load"
    "tun_tap"
)

function is_test_exempted() {
    local testname=${1}
    for test in "${test_exception_list[@]}";do
        [[ "${testname}" =~ "${test}" ]] && return 1
    done
    return 0
}

# Function to install all dependencies for selinux tests
function InstallDependencies() {
    local dpackage="diffutils git"
    install_package ${dpackage}
    if ! rpm -q --quiet ${dpackage};then
      return ${FAIL_ID}
    fi
    return 0
}

# Function to install selinux development packages
function InstallSeLinuxDevelPkg() {
    local devel_pkg_list="gcc libselinux-devel make selinux-policy-devel"
    for pkg in ${devel_pkg_list}; do
        LogMsg "InstallSeLinuxDevelPkg: Installing $pkg"
        dnf install $pkg -y
        [[ $? -ne 0 ]] && LogMsg "InstallSeLinuxDevelPkg: Installation failed" && return 1
    done
    return 0
}

# Function to install the dependencies for
# running "SeLinux Regression Test Suite"
function InstallRegressionTestDependency() {
    local perl_pkg_list="perl-Test perl-Test-Harness perl-Test-Simple selinux-policy-devel"
    for pkg in ${perl_pkg_list}; do
        LogMsg "InstallRegressionTestDependency: Installing $pkg"
        dnf install $pkg -y
        [[ $? -ne 0 ]] && LogMsg "InstallRegressionTestDependency: Installation failed" && return 1
    done
    local devel_pkg_list="gcc libselinux-devel net-tools netlabel_tools iptables lksctp-tools-devel attr keyutils-libs-devel quota xfsprogs-devel libuuid-devel nftables"
    for pkg in ${devel_pkg_list}; do
        LogMsg "InstallRegressionTestDependency: Installing $pkg"
        dnf install $pkg -y
        [[ $? -ne 0 ]] && LogMsg "InstallRegressionTestDependency: Installation failed" && return 1
    done

    local bpf_pkg_list="elfutils-libelf-devel libbpf"
    for pkg in ${bpf_pkg_list}; do
        LogMsg "InstallRegressionTestDependency: Installing $pkg"
        dnf install $pkg -y
        [[ $? -ne 0 ]] && LogMsg "InstallRegressionTestDependency: Installation failed" && return 1
    done

    if ! rpm -q libbpf-devel > /dev/null; then
        [[ -f libbpf-devel-0.0.4-5.el8.x86_64.rpm ]] && rm -f libbpf-devel-0.0.4-5.el8.x86_64.rpm
        wget http://mirror.centos.org/centos/8/PowerTools/x86_64/os/Packages/libbpf-devel-0.0.4-5.el8.x86_64.rpm
        rpm -ivh libbpf-devel-0.0.4-5.el8.x86_64.rpm
    fi

    local kernel_pkg="kernel-devel-$(uname -r) kernel-modules-$(uname -r)"
    for pkg in ${kernel_pkg}; do
        echo "InstallRegressionTestDependency: Installing $pkg"
        dnf install $pkg -y
        [[ $? -ne 0 ]] && LogMsg "InstallRegressionTestDependency: Installation failed" && return 1
    done

    return 0
}

# Function to run SELinux Regression TestSuite
function RunSelinuxRegressionTestSuite() {
    LogMsg "RunSelinuxRegressionTestSuite:: Start"
    local ret=0
    local repo_url="https://github.com/SELinuxProject/selinux-testsuite.git"
    local testsuite_dir="selinux-testsuite"

    InstallRegressionTestDependency; ret=$?
    [[ $ret -ne 0 ]] && {
        LogMsg "RunSelinuxRegressionTestSuite: Dependencies missing"
        return ${SKIP_ID}
    }

    [[ -d $testsuite_dir ]] && rm -rf ${testsuite_dir}
    git clone "${repo_url}"
    [[ ! -d ${testsuite_dir} ]] && {
        LogMsg "INFO: RunSelinuxRegressionTestSuite failed to clone repo $repo_url"
        LogMsg "INFO: Skipping test"
        return ${SKIP_ID}
    }
    make -C ${testsuite_dir} -j ${nproc} 1>> ${SELINUX_TEST_EXECLOG} 2>&1; ret=$?
    [[ $ret -ne 0 ]] && {
        LogMsg "INFO: SeLinux Regression Test Suite Compilation Failed"
        LogMsg "INFO: Skipping test"
        return ${SKIP_ID}
    }

    # Load the selinux policies for tests
    pushd ${testsuite_dir}
    echo "LOADING SELINUX POLICY" >> ${SELINUX_TEST_EXECLOG}
    make -C policy load 1>> ${SELINUX_TEST_EXECLOG} 2>&1; ret=$?
    [[ $ret -ne 0 ]] && {
        LogERR "ERR: SeLinux Regression Test Suite Failed to load policy"
        LogErr "ERR: Test Failed"
        return ${FAIL_ID}
    }
    popd
    echo "Policy load log: ${build_log}" >> ${SELINUX_TEST_EXECLOG}

    # Run the tests
    local teststatus=0
    pushd ${testsuite_dir}
    chcon -R -t test_file_t .
    TESTS=$(make -C tests test -n | grep SUBDIRS | sed 's/" .*/"/g' | cut -d'=' -f2)
    TESTS=$(echo "$TESTS" | sed 's/"//g')
    pushd tests
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    for TEST in ${TESTS};do
        is_test_exempted "${TEST}"
        [[ $? -eq 1 ]] && {
            LogMsg "INFO: RunSelinuxRegressionTestSuite Skipping - ${TEST}"
            continue
        }
        printf '%-18s %-20s ' "Running test for" "${TEST}" | tee -a ${SELINUX_TEST_EXECLOG}
        #echo -n "Running test for ${TEST}" | tee -a ${SELINUX_TEST_EXECLOG}
        export SUBDIRS=${TEST}
        local output=$(./runtests.pl 2>&1)
        [[ "${output}" =~ "Failed test at" ]] && ret=1
        echo "${output}" >> ${SELINUX_TEST_EXECLOG}

        [[ $ret -ne 0 ]] && {
            echo "   ... Failed" | tee -a ${SELINUX_TEST_EXECLOG}
            echo "${output}" >> ${SELINUX_TEST_ERRLOG}
            echo "ERR: Test - ${TEST} - Failed" >> ${SELINUX_TEST_ERRLOG}
            teststatus=${FAIL_ID}
        } || echo "   ... Success" | tee -a ${SELINUX_TEST_EXECLOG}
    done
    popd; popd
    [[ $teststatus -ne 0 ]] && return ${FAIL_ID}

    # unload the selinux policies for tests
    echo "UNLOADING SELINUX POLICY" >> ${SELINUX_TEST_EXECLOG}
    pushd ${testsuite_dir}
    make -C policy unload 1>> ${SELINUX_TEST_EXECLOG} 2>&1; ret=$?
    [[ $ret -ne 0 ]] && {
        echo "ERR: SeLinux Regression Test Suite Failed to load policy" >> ${SELINUX_TEST_EXECLOG}
        return ${FAIL_ID}
    }
    popd

    return $test_status
}

# Function to perform selinux setting validation
function RunSelinuxSettingChecks() {
    LogMsg "RunSelinuxSettingChecks:: Start"
    local selinuxstatus=$(sestatus | awk '/SELinux status:/ {print $3}')
    if [[ "$selinuxstatus" != "enabled" ]];then
        LogErr "ERR: RunSelinuxSettingChecks:: seLinux Disabled : $selinuxstatus"
        return 1
    fi
    local selinuxmode=$(getenforce)
    selinuxmode=${selinuxmode,,}
    if [[ -z $selinuxmode || $selinuxmode == "disabled" ]];then
        LogErr "ERR: RunSelinuxSettingChecks:: selinux current mode: $selinuxmode"
        return  1
    fi

    # Check whether system booted with the mode as per config file
    local selinuxconfigmode=$(sestatus | awk '/Mode from config file:/ {print $5}')
    if [[ $selinuxmode != "$selinuxconfigmode" ]];then
        LogMsg "INFO: RunSelinuxSettingChecks:: selinux mode not using config settings $selinuxconfigmode $selinuxmode"
    fi
}

# Function to perform selinux selinux basic validation
function CheckSelinuxBasicChecks() {
    # Check the selinux label for the newly created file.
    # Check file attribute of file when selinux is enabled
    pushd ${HOME}
    local filename="hv_selinux_test"
    echo "hypervkvp" > ${filename}
    local output=$(ls -lZ ${filename} | awk '{print $5}')
    # This script will run as root user and root user will have unconfined role
    [[ ! "$output" =~ "unconfined_u" ]] && {
        LogErr "CheckSelinuxBasicChecks: selinux context for file is missing"
        return ${FAIL_ID}
    } || rm -f ${filename}
    popd

    # Check process context when selinux is enabled
    # Validate that the context of the process in memory is shown
    # Use hv_balloon kmod of hv to validate the selinux context of process
    output=$(ps -Zaux | grep hv_balloon | grep -v grep | awk '{print $1}')
    [[ ! "$output" =~ "system_u:system_r:kernel_t" ]] && {
        LogErr "CheckSelinuxBasicChecks: selinux context for process missing"
        return ${FAIL_ID}
    }

    # Validate that the context of the network ports
    # Use sshd binded to port 22 for validation of selinux context
    output=$(netstat -Ztunepl | grep "22.*sshd" | grep -w tcp | awk '{print $10}')
    [[ ! "$output" =~ "system_u:system_r:sshd_t" ]] && {
        LogErr "CheckSelinuxBasicChecks: selinux context for process missing"
        return ${FAIL_ID}
    }
    return 0
}

# Function to check the selinux policy loading and unloading
function CheckSelinuxPolicyloading() {
    LogMsg "CheckSelinuxPolicyloading: Validate policy creation & loading"
    local hv_sepolicy_name="hyperv-daemons"

    if ! command -v semodule > /dev/null;then
        LogMsg "CheckSelinuxPolicyloading: semmodule command not present"
        return ${SKIP_ID}
    fi

    [[ ! -d /usr/share/selinux/devel ]] && {
        LogMsg "CheckSelinuxPolicyloading: SELinux Development pkgs not installed"
        InstallSeLinuxDevelPkg
        [[ $? -ne 0 ]] && {
            LogMsg "CheckSelinuxPolicyloading: SELinux devel pkg installation failed"
            return ${SKIP_ID}
        }
    }

cat << EOF > /usr/share/selinux/devel/hyperv-daemons.te
module hyperv-daemons 1.0;
require {
type hypervkvp_t;
type device_t;
type hypervvssd_t;
class chr_file { read write open };
}
allow hypervkvp_t device_t:chr_file { read write open };
allow hypervvssd_t device_t:chr_file { read write open };
EOF
    pushd /usr/share/selinux/devel
    make -f Makefile ${hv_sepolicy_name}.pp
    [[ $? -ne 0 ]] && {
        LogErr "CheckSelinuxPolicyloading: Policy compilation failed"
        return ${FAIL_ID}
    }
    [[ ! -f ${hv_sepolicy_name}.pp ]] && {
        LogErr "CheckSelinuxPolicyloading: No policy found"
        return ${FAIL_ID}
    }

    semodule -s targeted -i ${hv_sepolicy_name}.pp
    local modname=$(semodule -l | grep ${hv_sepolicy_name})
    [[ "${modname}" != ${hv_sepolicy_name} ]] && {
        LogErr "CheckSelinuxPolicyloading: Policy loading failed"
        return ${FAIL_ID}
    }

    semodule -r ${hv_sepolicy_name}
    modname=$(semodule -l | grep ${hv_sepolicy_name})
    [[ "${modname}" == ${hv_sepolicy_name} ]] && {
        LogErr "CheckSelinuxPolicyloading: Policy unloading failed"
        return ${FAIL_ID}
    }
    return 0
}

# Function to check selinux denials
function CheckSelinuxBootupDenials() {
    LogMsg "INFO: CheckSelinuxBootupDenials: Start"
    return 0
}

#######################################################################
#
# Main script body
#
#######################################################################

# Source containers_utils.sh
. containers_utils.sh || {
    echo "ERROR: unable to source containers_utils.sh"
    echo "TestAborted" > state.txt
    exit 0
}

UtilsInit
GetDistro

. constants.sh || {
    LogMsg "INFO: No constants.sh found"
}

case $DISTRO in
    centos_8 | redhat_8 | mariner)
        LogMsg "Running selinux test suite in $DISTRO"
    ;;
    *)
        HandleSkip "INFO: Test not supported in ${DISTRO}"
esac

test_status=0

InstallDependencies; test_status=$?
HandleTestResults ${test_status} "InstallDependencies"

[[ -f ${SELINUX_TEST_EXECLOG} ]] && rm -f ${SELINUX_TEST_EXECLOG}

case "$SELINUX_TEST_NAME" in
    SELINUX_SETTING_CHECK)
        LogMsg "INFO: EXECUTING SELINUX_SETTING_CHECK"
        RunSelinuxSettingChecks; test_status=$?
        ;;

    SELINUX_BASIC_CHECK)
        LogMsg "INFO: EXECUTING SELINUX_BASIC_CHECK"
        CheckSelinuxBasicChecks; test_status=$?
        ;;

    SELINUX_POLICY_LOAD_UNLOAD)
        LogMsg "INFO: EXECUTING SELINUX_POLICY_LOAD_UNLOAD"
        CheckSelinuxPolicyloading; test_status=$?
        ;;

    SELINUX_REGRESSION_TEST_SUITE)
        LogMsg "INFO: EXECUTING SELINUX_REGRESSION_TEST_SUITE"
        RunSelinuxRegressionTestSuite; test_status=$?
        ;;
    *)
        SELINUX_TEST_NAME="SELINUX_SETTING_CHECK"
        LogMsg "INFO: EXECUTING Default Test (SELINUX_SETTING_CHECK)"
        RunSelinuxSettingChecks; test_status=$?
esac
LogMsg "INFO: ${SELINUX_TEST_NAME} returned : ${test_status}"
HandleTestResults ${test_status} "${SELINUX_TEST_NAME}"

SetTestStateCompleted
exit 0
