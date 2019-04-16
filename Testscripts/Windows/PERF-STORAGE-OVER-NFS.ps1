# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
param(
    [object] $AllVmData,
    [object] $CurrentTestData
)
function Main {
    # Create test result
    $currentTestResult = Create-TestResultObject
    $resultArr = @()

    try {
        $noClient = $true
        $noServer = $true
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "client") {
                $clientVMData = $vmData
                $noClient = $false
            } elseif ($vmData.RoleName -imatch "server") {
                $noServer = $false
                $serverVMData = $vmData
            }
        }
        if ($noClient) {
            Throw "No any master VM defined. Be sure that, Client VM role name matches with the pattern `"*master*`". Aborting Test."
        }
        if ($noServer) {
            Throw "No any slave VM defined. Be sure that, Server machine role names matches with pattern `"*slave*`" Aborting Test."
        }
        #region CONFIGURE VM FOR TERASORT TEST
        Write-LogInfo "NFS Client details :"
        Write-LogInfo "  RoleName : $($clientVMData.RoleName)"
        Write-LogInfo "  Public IP : $($clientVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($clientVMData.SSHPort)"
        Write-LogInfo "NSF SERVER details :"
        Write-LogInfo "  RoleName : $($serverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($serverVMData.PublicIP)"
        Write-LogInfo "  SSH Port : $($serverVMData.SSHPort)"

        $testVMData = $clientVMData

        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"

        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
            Write-LogInfo "$param added to constants.sh"
            if ($param -imatch "startThread") {
                $startThread = [int]($param.Replace("startThread=",""))
            }
            if ($param -imatch "maxThread") {
                $maxThread = [int]($param.Replace("maxThread=",""))
            }
        }
        Write-LogInfo "constants.sh created successfully..."
        #endregion

        #region EXECUTE TEST
        $myString = @"
chmod +x perf_fio_nfs.sh
./perf_fio_nfs.sh &> fioConsoleLogs.txt
. utils.sh
collect_VM_properties
"@

        $myString2 = @"
chmod +x *.sh
cp fio_jason_parser.sh gawk JSON.awk utils.sh /root/FIOLog/jsonLog/
cd /root/FIOLog/jsonLog/
./fio_jason_parser.sh
cp perf_fio.csv /root
chmod 666 /root/perf_fio.csv
"@
        Set-Content "$LogDir\StartFioTest.sh" $myString
        Set-Content "$LogDir\ParseFioTestLogs.sh" $myString2
        Copy-RemoteFiles -uploadTo $testVMData.PublicIP -port $testVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload

        Copy-RemoteFiles -uploadTo $testVMData.PublicIP -port $testVMData.SSHPort -files "$constantsFile,$LogDir\StartFioTest.sh,$LogDir\ParseFioTestLogs.sh" -username "root" -password $password -upload

        $null = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh" -runAsSudo
        $testJob = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "./StartFioTest.sh" -RunInBackground -runAsSudo
        #endregion

        #region MONITOR TEST
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "tail -1 runlog.txt"-runAsSudo
            Write-LogInfo "Current Test Status : $currentStatus"
            Wait-Time -seconds 20
        }

        $finalStatus = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "cat state.txt"
        Copy-RemoteFiles -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "FIOTest-*.tar.gz"
        Copy-RemoteFiles -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"

        $testSummary = $null
        #endregion
        #>

        $finalStatus = "TestCompleted"
        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        } elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        } elseif ($finalStatus -imatch "TestCompleted") {
            $null = Run-LinuxCmd -ip $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -command "/root/ParseFioTestLogs.sh"
            Copy-RemoteFiles -downloadFrom $testVMData.PublicIP -port $testVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "perf_fio.csv"
            Write-LogInfo "Test Completed."
            $testResult = "PASS"
        } elseif ($finalStatus -imatch "TestRunning") {
            Write-LogInfo "Powershell background job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
            Write-LogInfo "Content of summary.log : $testSummary"
            $testResult = "PASS"
        }
        try {
            foreach ($line in (Get-Content "$LogDir\perf_fio.csv")) {
                if ($line -imatch "Max IOPS of each mode") {
                    $maxIOPSforMode = $true
                    $maxIOPSforBlockSize = $false
                    $fioData = $false
                }
                if ($line -imatch "Max IOPS of each BlockSize") {
                    $maxIOPSforMode = $false
                    $maxIOPSforBlockSize = $true
                    $fioData = $false
                }
                if ($line -imatch "Iteration,TestType,BlockSize") {
                    $maxIOPSforMode = $false
                    $maxIOPSforBlockSize = $false
                    $fioData = $true
                }
                if ($maxIOPSforMode) {
                    Add-Content -Value $line -Path $LogDir\maxIOPSforMode.csv
                }
                if ($maxIOPSforBlockSize) {
                    Add-Content -Value $line -Path $LogDir\maxIOPSforBlockSize.csv
                }
                if ($fioData) {
                    Add-Content -Value $line -Path $LogDir\fioData.csv
                }
            }
            $fioDataCsv = Import-Csv -Path $LogDir\fioData.csv
            $TestDate = $(Get-Date -Format yyyy-MM-dd)
            $TestCaseName = $GlobalConfig.Global.$TestPlatform.ResultsDatabase.testTag
            if (!$TestCaseName) {
                $TestCaseName = $CurrentTestData.testName
            }
            for ($QDepth = $startThread; $QDepth -le $maxThread; $QDepth *= 2) {
                if ($testResult -eq "PASS") {
                    Write-LogInfo "Collected performance data for $QDepth QDepth."
                    $resultMap = @{}
                    $resultMap["TestCaseName"] = $TestCaseName
                    $resultMap["TestDate"] = $TestDate
                    $resultMap["HostType"] = "Azure"
                    $resultMap["HostBy"] = ($global:TestLocation).Replace('"','')
                    $resultMap["HostOS"] = cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
                    $resultMap["GuestOSType"] = "Linux"
                    $resultMap["GuestDistro"] = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
                    $resultMap["GuestSize"] = $testVMData.InstanceSize
                    $resultMap["KernelVersion"] = cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
                    $resultMap["DiskSetup"] = 'RAID0:12xP30'
                    $resultMap["BlockSize_KB"] = [Int]((($fioDataCsv |  where { $_.Threads -eq "$QDepth"} | Select BlockSize)[0].BlockSize).Replace("K",""))
                    $resultMap["QDepth"] = $QDepth
                    $resultMap["seq_read_iops"] = [Float](($fioDataCsv |  where { $_.TestType -eq "read" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS)
                    $resultMap["seq_read_lat_usec"] = [Float](($fioDataCsv |  where { $_.TestType -eq "read" -and  $_.Threads -eq "$QDepth"} | Select MaxOfReadMeanLatency).MaxOfReadMeanLatency)
                    $resultMap["rand_read_iops"] = [Float](($fioDataCsv |  where { $_.TestType -eq "randread" -and  $_.Threads -eq "$QDepth"} | Select ReadIOPS).ReadIOPS)
                    $resultMap["rand_read_lat_usec"] = [Float](($fioDataCsv |  where { $_.TestType -eq "randread" -and  $_.Threads -eq "$QDepth"} | Select MaxOfReadMeanLatency).MaxOfReadMeanLatency)
                    $resultMap["seq_write_iops"] = [Float](($fioDataCsv |  where { $_.TestType -eq "write" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS)
                    $resultMap["seq_write_lat_usec"] = [Float](($fioDataCsv |  where { $_.TestType -eq "write" -and  $_.Threads -eq "$QDepth"} | Select MaxOfWriteMeanLatency).MaxOfWriteMeanLatency)
                    $resultMap["rand_write_iops"] = [Float](($fioDataCsv |  where { $_.TestType -eq "randwrite" -and  $_.Threads -eq "$QDepth"} | Select WriteIOPS).WriteIOPS)
                    $resultMap["rand_write_lat_usec"] = [Float](($fioDataCsv |  where { $_.TestType -eq "randwrite" -and  $_.Threads -eq "$QDepth"} | Select MaxOfWriteMeanLatency).MaxOfWriteMeanLatency)
                    $resultMap["TestType"] = "NFS"
                    $currentTestResult.TestResultData += $resultMap
                }
            }
        } catch {
            $ErrorMessage =  $_.Exception.Message
            $ErrorLine = $_.InvocationInfo.ScriptLineNumber
            Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
        }
    } catch {
        $ErrorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
    } finally {
        if (!$testResult) {
            $testResult = "Aborted"
        }
        $resultArr += $testResult
    }
    $currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
    return $currentTestResult
}

Main
