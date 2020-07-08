# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
<#
.Synopsis
	CPU offline-online functional and stress testing
	with vmbus interrupt channel reassignment via VM reboot
	Also it can invoke the script for offline cpu handle test script.

.Description
	Set CPU offline and online.
	Assign cpu to vmbus channels
	Reboot VM and repeat above steps for a few times, if this is stress mode.
	Handle the offline cpu assignment to the vmbus channel in negative test.
	It's optional to have no VM reboot.
	TODO: Find utilization, throughput or latency values parsing from workload output
	and compare those results during CPU offline/vmbus interrupt change.
#>

param([object] $AllVmData, [string]$TestParams)
# Set default Iteration value of the Stress test
# Set 1 for functional test. New value can be overwritten.
$max_stress_count = 1
# Set yes for VM reboot. New value can be overwritten.
$vm_reboot = "yes"
$isStorageWorkloadEnable = 0

function Main {
	param($AllVMData, $TestParams)
	$currentTestResult = Create-TestResultObject
	$local_script="channel_change.sh"

	try {
		$testResult = $resultFail
		$isStorageWorkloadEnable = 0
		$azureSyncSecond = 30

		# Find the local test script
		foreach ($TestScript in $CurrentTestData.files) {
			if ($TestParam -imatch "handle_offline_cpu.sh") {
				local_script="handle_offline_cpu.sh"
			}
		}
		#region Generate constants.sh
		# We need to add extra parameters to constants.sh file apart from parameter properties defined in XML.
		# Hence, we are generating constants.sh file again in test script.
		Write-LogInfo "Generating constants.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		foreach ($TestParam in $CurrentTestData.TestParameters.param) {
			Add-Content -Value "$TestParam" -Path $constantsFile
			Write-LogInfo "$TestParam added to constants.sh"
			if ($TestParam -imatch "maxIteration") {
				# Overwrite new max Iteration of CPU offline and online stress test
				$max_stress_count = [int]($TestParam.Replace("maxIteration=", "").Trim('"'))
			}
			if ($TestParam -imatch "vm_reboot") {
				# Overwrite if vm_reboot parameter is set
				$vm_reboot = [string]($TestParam.Replace("vm_reboot=", "").Trim('"'))
			}
			if ($TestParam -imatch "storage=yes") {
				# Overwrite if storage is set
				$isStorageWorkloadEnable = 1
			}
		}
		Write-LogInfo "constants.sh created successfully..."
		#endregion

		if ($isStorageWorkloadEnable -eq 1) {
			Write-LogDbg "Prepare a disk space for VM $($AllVMData[0].RoleName) in RG $($AllVMData[0].ResourceGroupName)."
			# region Prepare the disk space in the target VM
			$rgName = $AllVMData[0].ResourceGroupName
			$vmName = $AllVMData[0].RoleName
			$location = $AllVMData[0].Location
			$storageType = 'StandardSSD_LRS'
			$dataDiskName = $vmName + '_datadisk1'
			#endregion

			#region Add a new swap disk to Azure VM
			$diskConfig = New-AzDiskConfig -SkuName $storageType -Location $location -CreateOption Empty -DiskSizeGB 1024
			$dataDisk1 = New-AzDisk -DiskName $dataDiskName -Disk $diskConfig -ResourceGroupName $rgName

			$vm = Get-AzVM -Name $AllVMData[0].RoleName -ResourceGroupName $rgName
			Start-Sleep -s $azureSyncSecond
			$vm = Add-AzVMDataDisk -VM $vm -Name $dataDiskName -CreateOption Attach -ManagedDiskId $dataDisk1.Id -Lun 1
			Start-Sleep -s $azureSyncSecond

			$ret_val = Update-AzVM -VM $vm -ResourceGroupName $rgName
			Write-LogInfo "Updated the VM with a new data disk"
			Write-LogInfo "Waiting for $azureSyncSecond seconds for configuration sync"
			# Wait for disk sync with Azure host
			Start-Sleep -s $azureSyncSecond

			# Verify the new data disk addition
			if ($ret_val.IsSuccessStatusCode) {
				Write-LogInfo "Successfully add a new disk to the Resource Group, $rgName"
			} else {
				Write-LogErr "Failed to add a new disk to the Resource Group, $rgname"
				throw "Failed to add a new disk"
			}
			#endregion
		}

		#region Upload files to master VM
		foreach ($VMData in $AllVMData) {
			Copy-RemoteFiles -uploadTo $VMData.PublicIP -port $VMData.SSHPort -files "$constantsFile,$($CurrentTestData.files)" -username $user -password $password -upload
			Write-LogInfo "Copied the script files to the VM"
		}
		#endregion

		# ##################################################################################
		# New kernel build for CPU channel change and vmbus interrupt re-assignment
		Run-LinuxCmd -ip $AllVMData.PublicIP -port $AllVMData.SSHPort -username $user -password $password -command "./CPUOfflineKernelBuild.sh" -RunInBackground -runAsSudo -ignoreLinuxExitCode:$true | Out-Null
		Write-LogInfo "Executing CPUOfflineKernelBuild script inside VM"

		# Wait for kernel compilation completion. 60 min timeout
		$timeout = New-Timespan -Minutes 60
		$sw = [diagnostics.stopwatch]::StartNew()
		while ($sw.elapsed -lt $timeout){
			$vmCount = $AllVMData.Count
			Wait-Time -seconds 15
			$state = Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $user -password $password -command "cat ~/state.txt"
			if ($state -eq "TestCompleted") {
				$kernelCompileCompleted = Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $user -password $password -command "cat ~/constants.sh | grep setup_completed=0" -runAsSudo
				if ($kernelCompileCompleted -ne "setup_completed=0") {
					Write-LogErr "CPUOfflineKernelBuild.sh finished on $($VMData.RoleName) but setup was not successful!"
				} else {
					Write-LogInfo "CPUOfflineKernelBuild.sh finished on $($VMData.RoleName)"
					$vmCount--
				}
				break
			} elseif ($state -eq "TestSkipped") {
				$resultArr = $resultSkipped
				throw "CPUOfflineKernelBuild.sh finished with SKIPPED state!"
			} elseif ($state -eq "TestFailed") {
				$resultArr = $resultFail
				throw "CPUOfflineKernelBuild.sh finished with FAILED state!"
			} elseif ($state -eq "TestAborted") {
				$resultArr = $resultAborted
				throw "CPUOfflineKernelBuild.sh finished with ABORTED state!"
			} else {
				Write-LogInfo "CPUOfflineKernelBuild.sh is still running in the VM!"
			}
		}
		if ($vmCount -le 0){
			Write-LogInfo "CPUOfflineKernelBuild.sh is done successfully"
		} else {
			throw "CPUOfflineKernelBuild.sh didn't finish in the VM!"
		}

		# Load the target VM
		Write-LogInfo "Rebooting VM!"
		$TestProvider.RestartAllDeployments($AllVMData)

		# Run the workload if defined
		# setting up the storage workload script
		if ($isStorageWorkloadEnable -eq 1) {
			$workCommand = @"
source utils.sh
SetTestStateRunning
for jn in 1 2 3 4 5 6 7 8 9 10
do
fio --size=1G --name=workload --direct=1 --ioengine=libaio --filename=./data/fiodata --overwrite=1 --readwrite=readwrite --bs=1M --iodepth=128 --numjobs=`$jn --runtime=300 --output-format=json+ --output=./data/workload.json
rm -f ./data/fiodata
sync
echo 3 > /proc/sys/vm/drop_caches
done
SetTestStateCompleted
"@
			Set-Content "$LogDir\workCommand.sh" $workCommand

			$setupcommand = @"
source utils.sh
update_repos
install_package "fio"
"@
			Set-Content "$LogDir\setup.sh" $setupcommand
			#endregion

			#region Upload files to VM
			foreach ($VMData in $AllVMData) {
				Copy-RemoteFiles -uploadTo $VMData.PublicIP -port $VMData.SSHPort -files "$constantsFile,$($CurrentTestData.files),$LogDir\*.sh" -username $user -password $password -upload
				Write-LogInfo "Copied the script files to the VM"
				Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $user -password $password -command "bash ./setup.sh" -runAsSudo
			}
			#endregion
		}

		for ($loopCount = 1;$loopCount -le $max_stress_count;$loopCount++) {
			if ($isStorageWorkloadEnable -eq 1) {
				Write-LogInfo "Running workload command in the background job"
				Run-LinuxCmd -ip $AllVMData[0].PublicIP -port $AllVMData[0].SSHPort -username $user -password $password -command "bash ./workCommand.sh" -RunInBackground -runAsSudo -ignoreLinuxExitCode:$true | Out-Null
			}
			# Feature test and stress test case with $local_script
			# Running the local test script
			Run-LinuxCmd -ip $AllVMData[0].PublicIP -port $AllVMData[0].SSHPort -username $user -password $password -command "./$local_script" -RunInBackground -runAsSudo -ignoreLinuxExitCode:$true | Out-Null
			Write-LogInfo "Executed $local_script script inside VM"

			# Wait for kernel compilation completion. 60 min timeout
			$timeout = New-Timespan -Minutes 60
			$sw = [diagnostics.stopwatch]::StartNew()
			while ($sw.elapsed -lt $timeout){
				$vmCount = $AllVMData.Count
				Wait-Time -seconds 30
				$state = Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $user -password $password -command "cat ~/state.txt"
				if ($state -eq "TestCompleted") {
					$channelChangeCompleted = Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $user -password $password -command "cat ~/constants.sh | grep job_completed=0" -runAsSudo
					if ($channelChangeCompleted -ne "job_completed=0") {
						throw "$local_script finished on $($VMData.RoleName) but job was not successful!"
					} else {
						Write-LogInfo "$local_script finished on $($VMData.RoleName)"
						$vmCount--
					}
					break
				} elseif ($state -eq "TestSkipped") {
					$resultArr = $resultSkipped
					throw "$local_script finished with SKIPPED state!"
				} elseif ($state -eq "TestFailed") {
					$resultArr = $resultFail
					throw "$local_script finished with FAILED state!"
				} elseif ($state -eq "TestAborted") {
					$resultArr = $resultAborted
					throw "$local_script finished with ABORTED state!"
				} else {
					Write-LogInfo "$local_script is still running in the VM!"
				}
			}
			if ($vmCount -le 0){
				Write-LogInfo "$local_script is done"
			} else {
				Throw "$local_script didn't finish in the VM!"
			}

			if ($vm_reboot -eq "yes") {
				# ##################################################################################
				# Reboot VM
				Write-LogInfo "Rebooting VM! - Loop Count: $loopCount"
				$TestProvider.RestartAllDeployments($AllVMData)
			} else {
				# ##################################################################################
				# No reboot but wait for 60 seconds for settling down
				Write-LogInfo "Loop Count: $loopCount"
				Start-Sleep -second 60
			}

			# Revert state.txt and remove job_completed=0
			$state = Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $user -password $password -command "cat /dev/null > ~/state.txt" -runAsSudo
			$state = Run-LinuxCmd -ip $VMData.PublicIP -port $VMData.SSHPort -username $user -password $password -command "sed -i -e 's/job_completed=0//g' ~/constants.sh" -runAsSudo
		}
		$testResult = $resultPass
	} catch {
		$ErrorMessage =  $_.Exception.Message
		$ErrorLine = $_.InvocationInfo.ScriptLineNumber
		Write-LogErr "EXCEPTION : $ErrorMessage at line: $ErrorLine"
	} finally {
		if (!$testResult) {
			$testResult = $resultAborted
		}
		$resultArr = $testResult
	}

	$currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
	return $currentTestResult
}

Main -AllVmData $AllVmData -CurrentTestData $CurrentTestData