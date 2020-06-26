# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

param([String] $TestParams,
      [object] $AllVmData)

$MIN_KERNEL_VERSION = "5.7"

function Main {
    try {
        $noReceiver = $true
        $noSender = $true
        foreach ($vmData in $AllVmData){
            if ($vmData.Rolename.Contains("role-0") -or $vmData.RoleName.Contains("sender")){
                $senderVMData = $vmData
                $noSender = $false
            } elseif ($vmData.Rolename.Contains("role-1") -or $vmData.RoleName.Contains("receiver")) {
                $receiverVMData = $vmData
                $noReceiver = $false
            }
        }
        if ($noReceiver) {
            Throw "No Receiver VM defined. Aborting Test."
        }
        if ($noSender) {
            Throw "No Sender VM defined. Aborting Test."
        }

        #CONFIGURE VM Details
        Write-LogInfo "RECEIVER VM details :"
        Write-LogInfo "  RoleName : $($receiverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($receiverVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($receiverVMData.SSHPort)"
        Write-LogInfo "  Internal IP : $($receiverVMData.InternalIP)"
        Write-LogInfo "SENDER VM details :"
        Write-LogInfo "  RoleName : $($senderVMData.RoleName)"
        Write-LogInfo "  Public IP : $($senderVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($senderVMData.SSHPort)"
        Write-LogInfo "  Internal IP : $($senderVMData.InternalIP)"

        # Check for compatible kernel
        $currentKernelVersion = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "uname -r"
        if ((Compare-KernelVersion $currentKernelVersion $MIN_KERNEL_VERSION) -le 0){
            Write-LogInfo "Minimum kernel version required for SSH over KDUMP: $MIN_KERNEL_VERSION."`
                "Unsupported kernel version: $currentKernelVersion"
            return $global:ResultSkipped
        }

        Provision-VMsForLisa -allVMData $AllVmData -installPackagesOnRoleNames "none"

        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "# Generated by Azure Automation." -Path $constantsFile
        Add-Content -Value "sshIP=$($senderVMData.InternalIP)" -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
        }
        Copy-RemoteFiles -uploadTo $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -files "$constantsFile" -username $user -password $password -upload -runAsSudo

        Copy-RemoteFiles -uploadTo $senderVMData.PublicIP -port $senderVMData.SSHPort `
            -files "$constantsFile" -username $user -password $password -upload -runAsSudo

        Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "export HOME=``pwd``; bash ./KDUMP-Config.sh" -runAsSudo
        $state = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "cat state.txt" -runAsSudo
        if (($state -eq "TestAborted") -or ($state -eq "TestFailed")) {
            Write-LogErr "Running KDUMP-Config.sh script failed on VM!"
            return "ABORTED"
        } elseif ($state -eq "TestSkipped") {
            Write-LogWarn "Distro is not supported or kernel config does not allow auto"
            return "SKIPPED"
        }
        # restart receiver VM
        Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "sync; reboot" -runAsSudo `
                -RunInBackGround | Out-Null
        Write-LogInfo "Rebooting VM $($receiverVMData.RoleName) after kdump configuration..."
        Start-Sleep -Seconds 10 # Wait for kvp & ssh services stop

        # Wait for VM boot up and update ip address
        Wait-ForVMToStartSSH -Ipv4addr $receiverVMData.PublicIP -PortNumber $receiverVMData.SSHPort -StepTimeout 360 | Out-Null
        # prepare kdump
        Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password `
                -command "./KDUMP-Execute.sh > ~/kdumpExecute.log" -runAsSudo
        Write-LogInfo "Executed KDUMP-Execute.sh in the VM"
        $state = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "cat state.txt" -runAsSudo
        if (($state -eq "TestAborted") -or ($state -eq "TestFailed")) {
            Write-LogErr "Running KDUMP-Execute.sh script failed on VM!"
            return "ABORTED"
        } elseif ($state -eq "TestSkipped") {
            Write-LogWarn "Distro is not supported or kernel Execute does not allow auto"
            return "SKIPPED"
        }

        # generate sysrq
        Write-LogInfo "Set /proc/sysrq-trigger"
        Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "sync; echo c > /proc/sysrq-trigger" `
                -RunInBackGround -runAsSudo | Out-Null

        # Give the host a few seconds to record the event
        Write-LogInfo "Waiting 60 seconds to record the event..."
        Start-Sleep -Seconds 60
        # Wait for VM boot up and update ip address
        Wait-ForVMToStartSSH -Ipv4addr $receiverVMData.PublicIP -PortNumber $receiverVMData.SSHPort -StepTimeout 360 | Out-Null

        # Verify
        Run-LinuxCmd -username $user -password $password -ip $senderVMData.PublicIP -port $senderVMData.SSHPort `
            -command "export HOME=``pwd``;chmod u+x KDUMP-Results.sh && ./KDUMP-Results.sh $sshIP" -runAsSudo

        $state = Run-LinuxCmd -username $user -password $password -ip $senderVMData.PublicIP -port $senderVMData.SSHPort`
            -command "cat state.txt" -runAsSudo
        if ($currentState -imatch "TestCompleted") {
            Write-LogInfo "KDUMP was successfully copied over ssh."
            $testResult = "PASS"
        }   elseif ($currentState -imatch "TestAborted") {
            Write-LogErr "Test Aborted."
            $testResult = "ABORTED"
        }   elseif ($currentState -imatch "TestSkipped") {
            Write-LogErr "Test Skipped."
            $testResult = "SKIPPED"
        }   elseif ($currentState -imatch "TestFailed") {
            Write-LogErr "Test failed."
            $testResult = "FAIL"
        }   else {
            Write-LogErr "Test execution is not successful, check test logs in VM."
            $testResult = "ABORTED"
        }
    } catch {
        $ErrorMessage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
    } finally {
        if (!$testResult) {
            $testResult = "ABORTED"
        }
        $resultArr += $testResult
    }
    Write-LogInfo "Test result: $testResult"
    return $testResult

}

Main
