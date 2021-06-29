# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

param([String] $TestParams,
      [object] $AllVmData)

function Main {
    param (
        $VMName,
        $Ipv4,
        $VMPort,
        $VMUserName,
        $VMPassword
    )

    if ($global:detectedDistro -ne "UBUNTU" ) {
        Write-LogInfo "$($global:detectedDistro) is not supported! Test skipped!"
        return "SKIPPED"
    }

    $ubuntuVersion = Run-LinuxCmd -Command "cat /etc/issue" `
        -username $VMUserName -password $VMPassword -ip $Ipv4 -port $VMPort

    if (($ubuntuVersion -imatch "Ubuntu 18.04") -or ($ubuntuVersion -imatch "Ubuntu 16.04") -or ($ubuntuVersion -imatch "Ubuntu 20.04") -or ($ubuntuVersion -imatch "Ubuntu 19.10") -or ($ubuntuVersion -imatch "Ubuntu 21.04")) {
        $retVal = Run-LinuxCmd -Command "lsmod | grep -i intel_sgx || cat /boot/config-`$(uname -r) | grep -i 'CONFIG_X86_SGX=y'" -username $VMUserName -password $VMPassword -ip $Ipv4 -port $VMPort -ignoreLinuxExitCode
        if (!$retVal) {
            Write-LogErr "Module intel_sgx not load automatically."
            return "FAIL"
        } else {
            Write-LogInfo "Module intel_sgx load automatically - $retVal."
        }
    }

    if ($ubuntuVersion -notmatch "Ubuntu 18.04") {
        $shortUbuntuVersion = $ubuntuVersion.replace(" \n \l","")
        Write-LogInfo "$shortUbuntuVersion is not supported! Test skipped!"
        return "SKIPPED"
    }

    $remoteScript = "validate-intel-sgx-driver.sh"
    $logFile = "VALIDATE-INTEL-SGX-DRIVER.log"
    $maxRetryCount = 1
    $timeout = 900

    # Run the guest VM side script
    Run-LinuxCmd -Command "bash ${remoteScript} >> ${logFile} 2>&1" -ignoreLinuxExitCode:$true `
        -username $VMUserName -password $VMPassword -ip $Ipv4 -port $VMPort `
        -maxRetryCount $maxRetryCount -runMaxAllowedTime $timeout

    # Download guest VM script log
    Copy-RemoteFiles -download -downloadFrom $Ipv4 -files "./${logFile}" `
        -downloadTo $LogDir -port $VMPort -username $VMUserName -password $VMPassword

    # Get guest VM script result
    $state = Run-LinuxCmd -Command "cat state.txt" `
        -username $VMUserName -password $VMPassword -ip $Ipv4 -port $VMPort `
        -ignoreLinuxExitCode:$true
    Write-LogInfo "Guest VM script result: ${state}"

    if ($state -eq "TestCompleted") {
        Write-LogInfo "Test passed successfully!"
        return "PASS"
    } else {
        Write-LogErr "Running ${remoteScript} script failed on guest VM ${VMName}"
        return "FAIL"
    }
}

Main -VMName $AllVMData.RoleName -Ipv4 $AllVMData.PublicIP -VMPort $AllVMData.SSHPort `
    -VMUserName $user -VMPassword $password
