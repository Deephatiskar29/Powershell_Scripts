# Configuration for Email
$strSMTPRelay = "bbsmtp1.mydomain.com"
$strSubject = "Automatic Service Onprem Server Report"
$strSMTPFrom = "OnpremAutomaticService@domain.com"
$strSMTPTo = "abc@gmail.com"
$strTextBody = @"
Hi Team,<br><br>
Please check the attached Automatic Service reports for on-prem servers.<br><br>
Thank you
"@
# Input and Output Files
$InputFile = "C:\Scripts_DO_NOT_DELETE\AutomaticServiceCheckReport\Servers-Copy.txt" # Path to text file with server names
$OutputHTML = "C:\Scripts_DO_NOT_DELETE\AutomaticServiceCheckReport\Output\AutomaticServiceReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"

# Define Exception List (Services to Skip)
$ServiceExceptions = @(
    "Microsoft Edge Update Service (edgeupdate)",
    "Remote Registry",
    "Software Protection"
)
# Initialize HTML Report
$htmlHeader = @"
<html>
<head>
<style>
body { font-family: Arial, sans-serif; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid black; padding: 8px; text-align: left; }
th { background-color: #f2f2f2; }
.started { background-color: #FFD700; } /* Yellow */
.failed { background-color: #FFA500; } /* Orange */
.running { background-color: #90EE90; } /* Green */
.summary { background-color: #90EE90; } /* Green */
</style>
</head>
<body>
<h2>Automatic Services Report</h2>
<table>
<tr>
<th>Server Name</th>
<th>Service Name</th>
<th>Status</th>
<th>Timestamp</th>
</tr>
"@
$htmlFooter = @"
</table>
</body>
</html>
"@
$htmlContent = ""
 
# Read Servers from Input File
$servers = Get-Content -Path $InputFile
 
# Create a list to store jobs
$jobs = @()
 
# Start jobs for each server
foreach ($server in $servers) {
    $jobs += Start-Job -ScriptBlock {
        param($server, $ServiceExceptions)
 
        $resultHtml = ""
 
        Write-Host "Processing server: $server" -ForegroundColor Cyan
        try {
            $services = Get-Service -ComputerName $server | Where-Object {
                $_.StartType -eq 'Automatic' -and $ServiceExceptions -notcontains $_.DisplayName
            }
            $runningServices = $services | Where-Object { $_.Status -eq 'Running' }
            $stoppedServices = $services | Where-Object { $_.Status -eq 'Stopped' }
            # For running services, log a summary that all other services are running
            if ($runningServices.Count -gt 0) {
                $resultHtml += "<tr class='running'><td>$server</td><td>All other services are in running state</td><td>Running</td><td>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</td></tr>"
            }
            foreach ($service in $stoppedServices) {
                # Only attempt to start automatic services that are stopped
                $tryCount = 0
                $maxRetries = 3
                $started = $false
                while ($tryCount -lt $maxRetries -and !$started) {
                    try {
                        Write-Host "Attempting to start $($service.DisplayName) on $server" -ForegroundColor Yellow
                        # Ensure the service is running with elevated privileges
                        Invoke-Command -ComputerName $server -ScriptBlock {
                            param ($serviceName)
                            Start-Service -Name $serviceName -ErrorAction Stop
                        } -ArgumentList $service.Name
                        # Check service status after attempt
                        $service = Get-Service -Name $service.Name -ComputerName $server
                        if ($service.Status -eq 'Running') {
                            $resultHtml += "<tr class='started'><td>$server</td><td>$($service.DisplayName)</td><td>Started</td><td>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</td></tr>"
                            $started = $true
                        }
                    } catch {
                        $tryCount++
                        Write-Host "Failed to start $($service.DisplayName) on $server (Attempt $tryCount of $maxRetries)" -ForegroundColor Red
                        if ($tryCount -eq $maxRetries) {
                            $resultHtml += "<tr class='failed'><td>$server</td><td>$($service.DisplayName)</td><td>Failed to Start after $maxRetries attempts</td><td>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</td></tr>"
                        }
                    }
                }
            }
            # If no services were stopped, log a message indicating everything is running
            if ($runningServices.Count -eq $services.Count) {
                $resultHtml += "<tr class='running'><td>$server</td><td>All services are in running state</td><td>Running</td><td>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</td></tr>"
            }
        } catch {
            Write-Host "Failed to connect to server: $server. Error: $($_.Exception.Message)" -ForegroundColor Red
            $resultHtml += "<tr class='failed'><td>$server</td><td colspan='3'>Connection Failed</td><td>$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</td></tr>"
        }
 
        return $resultHtml
    } -ArgumentList $server, $ServiceExceptions
}
 
# Wait for all jobs to complete and collect results
$jobs | ForEach-Object {
    $result = Receive-Job -Job $_ -Wait
    $htmlContent += $result
    Remove-Job -Job $_
}
 
# Create the HTML Report
$htmlReport = $htmlHeader + $htmlContent + $htmlFooter
Set-Content -Path $OutputHTML -Value $htmlReport
 
# Send Email with the HTML Report as Attachment
try {
    Send-MailMessage -SmtpServer $strSMTPRelay -From $strSMTPFrom -To $strSMTPTo `
        -Subject $strSubject -BodyAsHtml $strTextBody -Attachments $OutputHTML
    Write-Host "Email sent successfully." -ForegroundColor Green
} catch {
    Write-Host "Failed to send email." -ForegroundColor Red
}
