# The script sets the sa password and start the SQL Service
# Also it attaches additional database from the disk
# The format for attach_dbs

param(
[Parameter(Mandatory=$false)]
[string]$sa_password,

[Parameter(Mandatory=$false)]
[string]$ACCEPT_EULA,

[Parameter(Mandatory=$false)]
[string]$attach_dbs,

[Parameter(Mandatory=$false)]
[ValidateScript({ Test-Path $_ -PathType Container })]
[string]$DataDirectory=$env:DATA_PATH
)

Write-Host "Data directory for dbs: $DataDirectory"

if($ACCEPT_EULA -ne "Y" -And $ACCEPT_EULA -ne "y")
{
Write-Verbose "ERROR: You must accept the End User License Agreement before this container can start."
Write-Verbose "Set the environment variable ACCEPT_EULA to 'Y' if you accept the agreement."

    exit 1
}
# start the service
Write-Verbose "Starting SQL Server"
start-service MSSQLSERVER


Write-Host "Set default directory for new databases"
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer' -Name DefaultData -Value $DataDirectory
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer' -Name DefaultLog -Value $DataDirectory

restart-service MSSQLSERVER
Write-Verbose "SQL Server restarted"

Write-Verbose "Enable contained databases"
$sqlCmd = "EXEC sp_configure 'show advanced', 1 `
GO `
RECONFIGURE `
GO `
EXEC sp_configure 'contained database authentication', 1 `
GO `
RECONFIGURE `
GO"
sqlcmd -Query $sqlCmd


if($sa_password -eq "_") {
    if (Test-Path $env:sa_password_path) {
        $sa_password = Get-Content -Raw $secretPath
    }
    else {
        Write-Verbose "WARN: Using default SA password, secret file not found at: $secretPath"
    }
}

if($sa_password -ne "_")
{
    Write-Verbose "Changing SA login credentials"
    $sqlcmd = "ALTER LOGIN sa with password=" +"'" + $sa_password + "'" + ";ALTER LOGIN sa ENABLE;"
    & sqlcmd -Q $sqlcmd
}

#Attach databases in data directory
Get-ChildItem -Path $DataDirectory -Filter "*.mdf" | ForEach-Object {
    $databaseName = $_.BaseName.Replace("_Primary", "")
    $mdfPath = $_.FullName

    $primaryDbEnding = $_.Name.Replace(".mdf", ".ldf")
    $logDbEnding = $databaseName + "_log.ldf"
    
    $ldfPath = Get-ChildItem -Path $DataDirectory | Where-Object {$_.Name -eq $primaryDbEnding -or $_.Name -eq $logDbEnding}
    $ldfPath = $ldfPath.FullName
    $sqlcmd = "IF EXISTS (SELECT 1 FROM SYS.DATABASES WHERE NAME = '$databaseName') BEGIN EXEC sp_detach_db [$databaseName] END;CREATE DATABASE [$databaseName] ON (FILENAME = N'$mdfPath'), (FILENAME = N'$ldfPath') FOR ATTACH;"

    Write-Host "INFO: Attaching '$databaseName'..."

    & sqlcmd -Q $sqlcmd
}

#attach additional databases from parameter
$attach_dbs_cleaned = $attach_dbs.TrimStart('\\').TrimEnd('\\')

$dbs = $attach_dbs_cleaned | ConvertFrom-Json

if ($null -ne $dbs -And $dbs.Length -gt 0)
{
    Write-Verbose "Attaching $($dbs.Length) database(s)"
    
    Foreach($db in $dbs) 
    {            
        $files = @();
        Foreach($file in $db.dbFiles)
        {
            $files += "(FILENAME = N'$($file)')";           
        }

        $files = $files -join ","
        $sqlcmd = "IF EXISTS (SELECT 1 FROM SYS.DATABASES WHERE NAME = '" + $($db.dbName) + "') BEGIN EXEC sp_detach_db [$($db.dbName)] END;CREATE DATABASE [$($db.dbName)] ON $($files) FOR ATTACH;"

        Write-Verbose "Invoke-Sqlcmd -Query $($sqlcmd)"
        & sqlcmd -Q $sqlcmd
}
}

Write-Verbose "Started SQL Server."

$lastCheck = (Get-Date).AddSeconds(-2) 
while ($true) 
{ 
    Get-EventLog -LogName Application -Source "MSSQL*" -After $lastCheck | Select-Object TimeGenerated, EntryType, Message 
    $lastCheck = Get-Date 
    Start-Sleep -Seconds 2 
}