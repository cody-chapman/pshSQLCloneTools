<# 
    .SYNOPSIS 
   Powershell Module that setups and helps orchestrate clones of SQL Server databases - by Cody Chapman
    .VERSIONINFO 1.0.0
       -12/12/2017 - initial Release

    .DESCRIPTION
    The purpose of this module is to utilize Powershell to assist in te orchestration
    of setting up cloned copies of databases that helps reduce the footprint and space utilized
    in making these copies.
    
    You should run this with administrative privileges.
    
  
    - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
    Obligatory Disclaimer
    THE SCRIPT AND PARSER IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE 
    INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY 
    SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA 
    OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION 
    WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
    - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
    
    .LINK
    Fetch pshSQLCloneTools from GitHub at:
    https://github.com/cody-chapman/pshSQLCloneTools

#>

Function Set-Database {
    param(
        [Parameter(Mandatory)]
        [string]$DatabaseName,
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("Online", "Offline")]      
        [string]$DatabaseAction
    )    
    switch ($DatabaseAction) {

        "Online" {
            $SQLAction = "ONLINE"
            $SQLCMD = @"
USE master;
GO

ALTER DATABASE [$DatabaseName] SET $SQLAction
"@ 
            Invoke-Sqlcmd $SQLCMD -QueryTimeout 3600 -ServerInstance .
        }
        "Offline" {
            $SQLAction = "OFFLINE WITH ROLLBACK IMMEDIATE"
            $SQLCMD = @"
USE master;
GO

ALTER DATABASE [$DatabaseName] SET $SQLAction
"@  
        }
    }
    $retval = Invoke-Sqlcmd -Query "select state_desc as IsOnline from sys.databases where name = '$DatabaseName';"
    If ($retval.IsOnline -eq "ONLINE") {
        Write-Host "[$DatabaseName] is ONLINE"
    }
    else {
        Write-Host "[$DatabaseName] is OFFLINE"
    }
}

Function Create-DatabaseImage {
    param(
        [Parameter(Mandatory)]
        [string]$DatabaseName,
        [Parameter(Mandatory)]
        [string]$BaseDirectory,
        [Parameter(Mandatory)]
        [string]$NewDatabaseName
    )
    #setting internal parameters up from parameter input. 
    $VHDFile = (Join-path $BaseDirectory ("\$NewDatabaseName\VHD\" + $NewDatabaseName + '.vhdx'))
    $VHDMountPath = (Join-path $BaseDirectory ("\$NewDatabaseName\Mount\"))
    $BackupDir = (Join-path $BaseDirectory ("\$NewDatabaseName\Backup\"))
    $BackupFile = (Join-path $BaseDirectory ("\$NewDatabaseName\Backup\" + $NewDatabaseName + '.bak'))

    #Making directory structure for cloning
    $garbage = New-Item -ItemType directory -Path $VHDMountPath -ErrorAction SilentlyContinue | Out-Null
    $garbage = New-Item -ItemType directory -Path $BackupDir -ErrorAction SilentlyContinue | Out-Null


    #Creating VHD file for mounting
    Write-Host "Command [New-VHD] is executing [$VHDFile]."
    $garbage = New-VHD -Dynamic -Path $VHDFile -SizeBytes 2040GB

    #Mounting VHD file to a predetermined location
    Write-Host "Command [Mount-VHD] is executing [$VHDFile]."
    $garbage = Mount-VHD -Path $VHDFile

    #Initiaizing, partitioning, and formatting disk
    Write-Host "Command [Initialize-Disk] is executing [$VHDFile]."
    $Disk = Get-VHD -Path $VHDFile 
    $Disk | Initialize-Disk -PartitionStyle MBR | Out-Null
    Write-Host "Command [New-Partition] is executing [$VHDFile]."
    $Disk | New-Partition -UseMaximumSize | Out-Null
    $Partition = Get-Partition -DiskNumber $Disk.Number
    Write-Host "Command [Format-Volume] is executing [$VHDFile]."
    $Partition | Format-Volume -FileSystem NTFS -Confirm:$false | Out-Null
    Write-Host "Command [Add-PartitionAccessPath] is executing [$VHDFile]."
    $Partition | Add-PartitionAccessPath -AccessPath $VHDMountPath | Out-Null

    #Backing up target database and restoring to newly mounted vhd disk image
    Backup-Database -BackupFile $BackupFile -DatabaseName $DatabaseName -BackupName $NewDatabaseName
    Restore-Database -BackupFile $BackupFile -NewLocation $VHDMountPath -NewDatabaseName $NewDatabaseName

    #Cleanup of directories after clone process
    Remove-Directory -Path $BackupDir
    Remove-Directory -Path $VHDMountPath

    #Detaching and dismounting database and then disk image
    Detach-Database -DatabaseName $NewDatabaseName -ErrorAction SilentlyContinue
    Write-Host "Command [Dismount-VHD] is executing [$VHDFile]."
    Dismount-VHD -Path $VHDFile -ErrorAction SilentlyContinue
}
Function Delete-DatabaseImage {
    param(
        [Parameter(Mandatory)]
        [string]$BaseDirectory,
        [Parameter(Mandatory)]
        [string]$NewDatabaseName
    )
    #setting internal parameters up from parameter input. 
    $VHDFile = (Join-path $BaseDirectory ("\$NewDatabaseName\VHD\" + $NewDatabaseName + '.vhdx'))
    $CloneDir = (Join-path $BaseDirectory ("\$NewDatabaseName\"))

    #Detaching and dismounting database and then disk image
    Detach-Database -DatabaseName $NewDatabaseName -ErrorAction SilentlyContinue
    Write-Host "Command [Dismount-VHD] is executing [$VHDFile]."
    Dismount-VHD -Path $VHDFile -ErrorAction SilentlyContinue

    #Cleanup of directories after clone process
    Remove-Directory -Path $CloneDir
}
Function Delete-DatabaseClone {
    param(
        [Parameter(Mandatory)]
        [string]$CloneDatabaseName,
        [Parameter(Mandatory)]
        [string]$BaseDirectory,
        [Parameter(Mandatory)]
        [string]$NewDatabaseName
    )
    #setting internal parameters up from parameter input. 
    $VHDFile = (Join-path $BaseDirectory ("\$NewDatabaseName\VHD\" + $CloneDatabaseName + '.vhdx'))
    $CloneDir = (Join-path $BaseDirectory ("\$NewDatabaseName\" + $CloneDatabaseName))

    #Detaching and dismounting database and then disk image
    Detach-Database -DatabaseName $CloneDatabaseName -ErrorAction SilentlyContinue
    Delete-Database -DatabaseName $CloneDatabaseName -ErrorAction SilentlyContinue
    Write-Host "Command [Dismount-VHD] is executing [$VHDFile]."
    Dismount-VHD -Path $VHDFile -ErrorAction SilentlyContinue

    #Cleanup of directories after clone process
    Remove-Item -path $VHDFile -ErrorAction SilentlyContinue
    Remove-Directory -path $CloneDir -ErrorAction SilentlyContinue
}
Function Create-DatabaseClone {
    param(
        [Parameter(Mandatory)]
        [string]$CloneDatabaseName,
        [Parameter(Mandatory)]
        [string]$BaseDirectory,
        [Parameter(Mandatory)]
        [string]$NewDatabaseName
    )
    $VHDFile = (Join-path $BaseDirectory ("\$NewDatabaseName\VHD\" + $NewDatabaseName + '.vhdx'))
    $VHDCloneMountPath = (Join-path $BaseDirectory ("\$NewDatabaseName\$CloneDatabaseName\Mount\"))
    $ChildVHDFile = (Join-path $BaseDirectory ("\$NewDatabaseName\VHD\" + $CloneDatabaseName + '.vhdx'))

    Write-Host "Command [New-VHD] is executing [$ChildVHDFile] as Child Disk."
    $garbage = New-VHD -ParentPath $VHDFile -Path $ChildVHDFile -Differencing

    Write-Host "Command [Mount-VHD] is executing [$ChildVHDFile]."
    Mount-VHD -Path $ChildVHDFile

    Write-Host "Command [Set-Disk] is executing [$ChildVHDFile]."
    get-disk | set-disk -isOffline $false
    Start-Sleep -Seconds 2
    $Disk = Get-VHD -Path $ChildVHDFile 

    Write-Host "Command [Get-Partition] is executing [$ChildVHDFile]."
    $Partition = Get-Partition -DiskNumber $Disk.Number
    #Making directory structure for cloning
    $garbage = New-Item -ItemType directory -Path $VHDCloneMountPath -ErrorAction SilentlyContinue | Out-Null

    Write-Host "Command [Remove-PartitionAccessPath] is executing [$ChildVHDFile]."
    $drive1 = $Partition.DriveLetter + ":\"
    $garbage = Remove-PartitionAccessPath -AccessPath $drive1 -DiskNumber $Disk.DiskNumber -PartitionNumber $Partition.PartitionNumber -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Command [Add-PartitionAccessPath] is executing [$ChildVHDFile]."
    $Partition | Add-PartitionAccessPath -AccessPath $VHDCloneMountPath | Out-null

    $files = (Get-ChildItem -Path $VHDCloneMountPath -file | % { [PSCustomObject]@{Name = $_.Name } })  

    $b = @()
    foreach ($file in $files) {
        [string]$a = $VHDCloneMountPath + $file.Name
        $b += "$a"
    }
    $DBFiles = $b
    Attach-Database -DatabaseFiles $DBFiles -DatabaseName $CloneDatabaseName

}
Function Remove-Directory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    #Cleanup of directories after clone process
    Remove-Item $Path -Force -Recurse -ErrorAction SilentlyContinue
}
Function Install-pshSQLCloneTools {
    #Code to Check Windows Version
    #Code to Check Powershell version
    #Code to test if Hyper-V Powershell tools can be installed
    #Check to see if user is in the local hyper-v administrators group
    Set-StorageSetting -NewDiskPolicy OnlineAll
    #Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell
    #Install-WindowsFeature -Name Hyper-V-PowerShell

}
#Create-DatabaseImage -DatabaseName "HealthCheck" -NewDatabaseName "HealthCheck1" -BaseDirectory "C:\SQLClone\"
#Delete-DatabaseImage -NewDatabaseName "HealthCheck1" -BaseDirectory "C:\SQLClone\"
#Delete-DatabaseClone -NewDatabaseName "HealthCheck1" -CloneDatabaseName "HealthCheck_clone" -BaseDirectory "C:\SQLClone\"
#Delete-DatabaseClone -NewDatabaseName "HealthCheck1" -CloneDatabaseName "HealthCheck_clone1" -BaseDirectory "C:\SQLClone\"
#Delete-DatabaseClone -NewDatabaseName "HealthCheck1" -CloneDatabaseName "HealthCheck_clone2" -BaseDirectory "C:\SQLClone\"
#Delete-DatabaseClone -NewDatabaseName "HealthCheck1" -CloneDatabaseName "HealthCheck_clone3" -BaseDirectory "C:\SQLClone\"
#Refresh-DatabaseImage -DatabaseName "HealthCheck" -NewDatabaseName "HealthCheck1" -BaseDirectory "C:\SQLClone\"
#Create-DatabaseClone -NewDatabaseName "HealthCheck1" -CloneDatabaseName "HealthCheck_clone" -BaseDirectory "C:\SQLClone\"
#Create-DatabaseClone -NewDatabaseName "HealthCheck1" -CloneDatabaseName "HealthCheck_clone1" -BaseDirectory "C:\SQLClone\"
#Create-DatabaseClone -NewDatabaseName "HealthCheck1" -CloneDatabaseName "HealthCheck_clone2" -BaseDirectory "C:\SQLClone\"
#Create-DatabaseClone -NewDatabaseName "HealthCheck1" -CloneDatabaseName "HealthCheck_clone3" -BaseDirectory "C:\SQLClone\"
#Set this once script is complete.
Export-ModuleMember -Function '*'