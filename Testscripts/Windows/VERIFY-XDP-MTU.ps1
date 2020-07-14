# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

<#
.Description
    This script deploys the VM and verify XDP working with various MTU sizes (1500, 2000, 3506) which are easily configurable in XML.
    Also, it will verify error caught by kernel "hv_netvsc" for MTU greater than Maximum MTU on Azure.
#>

param([object] $AllVmData,
    [object] $CurrentTestData)

$MIN_KERNEL_VERSION = "5.6"
$RHEL_MIN_KERNEL_VERSION = "4.18.0-213"
$iFaceName = "eth1"

function Main {
    try {
        $noReceiver = $true
        $noSender = $true
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "receiver") {
                $receiverVMData = $vmData
                $noReceiver = $false
            } elseif ($vmData.RoleName -imatch "sender") {
                $noSender = $false
                $senderVMData = $vmData
            }
        }
        if ($noReceiver) {
            Throw "No Receiver VM defined. Aborting Test."
        }
        if ($noSender) {
            Throw "No Sender VM defined. Aborting Test."
        }

        #CONFIGURE VM Details
        Write-LogInfo "CLIENT VM details :"
        Write-LogInfo "  RoleName : $($receiverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($receiverVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($receiverVMData.SSHPort)"
        Write-LogInfo "  Internal IP : $($receiverVMData.InternalIP)"
        Write-LogInfo "SERVER VM details :"
        Write-LogInfo "  RoleName : $($senderVMData.RoleName)"
        Write-LogInfo "  Public IP : $($senderVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($senderVMData.SSHPort)"
        Write-LogInfo "  Internal IP : $($senderVMData.InternalIP)"

        # Check for compatible kernel
        $currentKernelVersion = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -username $user -password $password -command "uname -r"
        # ToDo: Update Minimum kernel version check once patches are in downstream distro.
        if ($global:DetectedDistro -eq "UBUNTU"){
            if ((Compare-KernelVersion $currentKernelVersion $MIN_KERNEL_VERSION) -lt 0){
                Write-LogInfo "Unsupported kernel version: $currentKernelVersion"
                return $global:ResultSkipped
            }
        } elseif ($global:DetectedDistro -eq "REDHAT"){
            if ((Compare-KernelVersion $currentKernelVersion $RHEL_MIN_KERNEL_VERSION) -lt 0){
                Write-LogInfo "Unsupported kernel version: $currentKernelVersion"
                return $global:ResultSkipped
            }
        } else {
            Write-LogInfo "Unsupported distro: $($global:DetectedDistro)."
            return $global:ResultSkipped
        }

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS.
        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"

        # Generate constants.sh and write all VM info into it
        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "# Generated by Azure Automation." -Path $constantsFile
        Add-Content -Value "ip=$($receiverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "client=$($receiverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "server=$($senderVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "clientSecondIP=$($receiverVMData.SecondInternalIP)" -Path $constantsFile
        Add-Content -Value "serverSecondIP=$($senderVMData.SecondInternalIP)" -Path $constantsFile
        Add-Content -Value "nicName=$iFaceName" -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
        }
        Write-LogInfo "constants.sh created successfully..."
        Write-LogInfo (Get-Content -Path $constantsFile)
        $installXDPCommand = @"
bash ./XDP-MTUVerify.sh 2>&1 > ~/xdpConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        Set-Content "$LogDir\StartXDPTest.sh" $installXDPCommand
        Copy-RemoteFiles -uploadTo $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -files "$constantsFile,$LogDir\StartXDPTest.sh" `
            -username $user -password $password -upload -runAsSudo

        $testJob = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -username $user -password $password -command "bash ./StartXDPTest.sh" `
            -RunInBackground -runAsSudo
        # Terminate process if ran more than 5 mins
        # TODO: Check max installation time for other distros when added
        $timer = 0
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
                -username $user -password $password -command "tail -2 ~/xdpConsoleLogs.txt | head -1" -runAsSudo
            Write-LogInfo "Current Test Status: $currentStatus"
            Wait-Time -seconds 20
            $timer += 1
            if ($timer -gt 15) {
                Throw "XDPSetup did not stop after 5 mins. Please check xdpConsoleLogs."
            }
        }

        $currentState = Run-LinuxCmd -ip $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -username $user -password $password -command "cat state.txt" -runAsSudo
        if ($currentState -imatch "TestCompleted") {
            Write-LogInfo "Test Completed"
            $testResult = "PASS"
        }   elseif ($currentState -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status: $currentStatus."
            $testResult = "ABORTED"
        }   elseif ($currentState -imatch "TestSkipped") {
            Write-LogErr "Test Skipped. Last known status: $currentStatus"
            $testResult = "SKIPPED"
        }   elseif ($currentState -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status: $currentStatus."
            $testResult = "FAIL"
        }   else {
            Write-LogErr "Test execution is not successful, check test logs in VM."
            $testResult = "ABORTED"
        }
        Copy-RemoteFiles -downloadFrom $receiverVMData.PublicIP -port $receiverVMData.SSHPort `
            -username $user -password $password -download `
            -downloadTo $LogDir -files "*.csv, *.txt, *.log" -runAsSudo
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