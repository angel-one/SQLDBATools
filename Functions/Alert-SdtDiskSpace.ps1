﻿function Alert-SdtDiskSpace
{
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)]
        [Alias('ServerName','MachineName')]
        [string[]]$ComputerName,
        [Parameter(Mandatory=$false)]
        [string[]]$ExcludeDrive,
        [Parameter(Mandatory=$false)]
        [decimal]$WarningThresholdPercent = 80.0,
        [Parameter(Mandatory=$false)]
        [decimal]$CriticalThresholdPercent = 90.0,
        [Parameter(Mandatory=$false)]
        [string]$ThresholdTable = 'dbo.sdt_disk_space_threshold',
        [Parameter(Mandatory=$false)]
        [string[]]$EmailTo = @($SdtDBAMailId)
    )

    # Start Actual Work
    $blockDbaDiskSpace = {
        $ComputerName = $_
        $FriendlyName = $ComputerName.Split('.')[0]
        $r = Get-DbaDiskSpace -ComputerName $ComputerName
        $r | Add-Member -NotePropertyName FriendlyName -NotePropertyValue $FriendlyName
        $r | Add-Member -MemberType ScriptProperty -Name "PercentUsed" -Value {[math]::Round((100.00 - $this.PercentFree), 2)}
        $r
    }

    $jobs = @()
    $jobs += $ComputerName | Start-RSJob -Name {$_} -ScriptBlock $blockDbaDiskSpace -Throttle $SdtDOP
    "{0} {1,-10} {2}" -f "($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))","(INFO)","Waiting for RSJobs to complete.." | Write-Verbose
    $jobs | Wait-RSJob -ShowProgress -Timeout 1200 -Verbose:$false | Out-Null

    $jobs_timedout = @()
    $jobs_timedout += $jobs | Where-Object {$_.State -in ('NotStarted','Running','Stopping')}
    $jobs_success = @()
    $jobs_success += $jobs | Where-Object {$_.State -eq 'Completed' -and $_.HasErrors -eq $false}
    $jobs_fail = @()
    $jobs_fail += $jobs | Where-Object {$_.HasErrors -or $_.State -in @('Disconnected')}

    $jobsResult = @()
    $jobsResult += $jobs_success | Receive-RSJob -Verbose:$false
    
    if($jobs_success.Count -gt 0) {
        "{0} {1,-10} {2}" -f "($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))","(INFO)","Below jobs finished without error.." | Write-Output
        $jobs_success | Select-Object Name, State, HasErrors | Format-Table -AutoSize | Out-String | Write-Output
    }

    if($jobs_timedout.Count -gt 0)
    {
        "{0} {1,-10} {2}" -f "($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))","(ERROR)","Some jobs timed out. Could not completed in 20 minutes." | Write-Output
        $jobs_timedout | Format-Table -AutoSize | Out-String | Write-Output
        "{0} {1,-10} {2}" -f "($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))","(INFO)","Stop timedout jobs.." | Write-Output
        $jobs_timedout | Stop-RSJob
    }

    if($jobs_fail.Count -gt 0)
    {
        "{0} {1,-10} {2}" -f "($((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))","(ERROR)","Some jobs failed." | Write-Output
        $jobs_fail | Format-Table -AutoSize | Out-String | Write-Output
        "--"*20 | Write-Output
    }

    $jobs_exception = @()
    $jobs_exception += $jobs_timedout + $jobs_fail
    if($jobs_exception.Count -gt 0 ) {   
        $alertHost = $jobs_exception | Select-Object -ExpandProperty Name -First 1
        $isCustomError = $true
        $errMessage = "`nBelow jobs either timed or failed-`n$($jobs_exception | Select-Object Name, State, HasErrors | Out-String)"
        [System.Collections.ArrayList]$jobErrMessages = @()
        $failCount = $jobs_fail.Count
        $failCounter = 0
        foreach($job in $jobs_fail) {
            $failCounter += 1
            $jobErrMessage = ''
            if($failCounter -eq 1) {
                $jobErrMessage = "`n$("_"*20)`n" | Write-Output
            }
            $jobErrMessage += "`nError Message for server [$($job.Name)] => `n`n$($job.Error | Out-String)"
            $jobErrMessage += "$("_"*20)`n`n" | Write-Output
            $jobErrMessages.Add($jobErrMessage) | Out-Null;
        }
        $errMessage += ($jobErrMessages -join '')
        #throw $errMessage
    }
    $jobs | Remove-RSJob -Verbose:$false

    if($isCustomError) {
        throw $errMessage
    }

    $jobsResultFiltered = @()
    $jobsResultFiltered += $jobsResult | Where-Object {$_.PercentUsed -ge $WarningThresholdPercent}

    if($jobsResultFiltered.Count -gt 0)
    {
        $jobsResultFiltered | Add-Member -MemberType ScriptProperty -Name "Severity" -Value { if($this.PercentUsed -ge $CriticalThresholdPercent) {'CRITICAL'} else {'WARNING'} }
    
        $alertResult = @()
        $alertResult += $jobsResultFiltered | Select-Object @{l='Server';e={$_.FriendlyName}}, @{l='DiskVolume';e={$_.Name}}, Severity, `
                                            @{l='FreePercent';e={"$($_.PercentFree) ($($_.Free)/$($_.Capacity))"}}, `
                                            @{l='DashboardURL';e={$SdtInventoryInstance+':3000'}} 
        #$alertResult | ft -AutoSize

        $alertServers = @()
        $alertServers += $alertResult | Select-Object -ExpandProperty Server -Unique
        $serverCounts = $alertServers.Count

        $criticalDisks = @()
        $criticalDisks += $alertResult | Where-Object {$_.Severity -eq 'CRITICAL'}
        $criticalDisksCount = $criticalDisks.Count

        $warningDisks = @()
        $warningDisks += $alertResult | Where-Object {$_.Severity -eq 'WARNING'}        
        $warningDisksCount = $warningDisks.Count

        #$alertResult | select * | ogv
        #Write-Debug "Got the result"

        $subject = "Alert-SdtDiskSpace - $(if($serverCounts -gt 1){"$serverCounts Servers"}else{"[$alertServers]"}) $(if($criticalDisksCount -gt 0){"- $criticalDisksCount CRITICAL"}) $(if($warningDisksCount -gt 0){"- $warningDisksCount WARNINGS"})"
        $css = $Header = @"
        <style>
        TABLE {border-width: 1px; border-style: solid; border-color: black; border-collapse: collapse;}
        TD {border-width: 1px; padding: 3px; border-style: solid; border-color: black;}
        </style>
"@
        $style = @"
<style>
body {
    color:#333333;
    font-family:Calibri,Tahoma;
    font-size: 10pt;
}
h1 {
    text-align:center;
}
h2 {
    border-top:1px solid #666666;
}
th {
    font-weight:bold;
    color:#eeeeee;
    background-color:#333333;
    cursor:pointer;
}
.odd  { background-color:#ffffff; }
.even { background-color:#dddddd; }
.paginate_enabled_next, .paginate_enabled_previous {
    cursor:pointer; 
    border:1px solid #222222; 
    background-color:#dddddd; 
    padding:2px; 
    margin:4px;
    border-radius:2px;
}
.paginate_disabled_previous, .paginate_disabled_next {
    color:#666666; 
    cursor:pointer;
    background-color:#dddddd; 
    padding:2px; 
    margin:4px;
    border-radius:2px;
}
.dataTables_info { margin-bottom:4px; }
.sectionheader { cursor:pointer; }
.sectionheader:hover { color:red; }
.grid { width:100% }
.red {
    color:red;
    font-weight:bold;
}
.yellow {
    color:yellow;
}
.blue {
    color:blue;
}
</style>
"@
        
        $title = "<h2>$subject</h2>"
        $content = $alertResult | Sort-Object -Property Severity, Server |  ConvertTo-Html -Fragment
        $params = @{
                    'As'='Table';
                    'PreContent'= '<h3 class="blue">Disk Space Utilization</h3>';
                    'EvenRowCssClass' = 'even';
                    'OddRowCssClass' = 'odd';
                    'MakeTableDynamic' = $true;
                    'TableCssClass' = 'grid';
                    'Properties' = 'Server', 'DiskVolume', 'Severity', @{n='Severity';e={$_.Severity};css={if ($_.Severity -eq 'CRITICAL') { 'red' }}},
                                    'FreePercent', 'DashboardURL'
                }
        $content = $alertResult | Sort-Object -Property Severity, Server | ConvertTo-EnhancedHTMLFragment @params

        $footer = "<p>Report Generated @ $(Get-Date -format 'yyyy-MM-dd HH.mm.ss')</p>"

        $body = "$style $title $content $footer" | Out-String

        if($criticalDisksCount -gt 0) { $priority = 'High' } else { $priority = 'Normal' }
        Raise-SdtAlert -To $EmailTo -Subject $subject -Body $body -Priority $priority -BodyAsHtml
    }
<#
.SYNOPSIS 
    Check Disk Space on Computer, and send Alert 
.DESCRIPTION
    This function analyzes disk space on Computer, and send an email alert for CRITICAL & WARNING state.
.PARAMETER ComputerName
    Server name where disk space has to be analyzed.
.PARAMETER ExcludeDrive
    List of drives that should not be part of alert
.PARAMETER WarningThresholdPercent 
    Used space warning threshold. Default 80 percent.
.PARAMETER CriticalThresholdPercent
    Used space critical threshold. Default 90 percent.
.PARAMETER ThresholdTable
    Table containing more specific threshold for server & disk drive at percentage & size level.
.PARAMETER EmailTo
    Email ids that should receive alert email.
.EXAMPLE
    Alert-SdtDiskSpace -ComputerName 'SqlProd1','SqlDr1' -WarningThresholdPercent 70 -CriticalThresholdPercent 85
      
    Analyzes SqlProd1 & SqlDr1 servers for disk drives having used space above 70 percent.
.LINK
    https://github.com/imajaydwivedi/SQLDBATools
#>
}