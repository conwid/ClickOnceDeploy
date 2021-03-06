#Do not forget to configure the ClickOnce deploy options on the project in Visual Studio first!!

# Set the desired build config; must be one of the valid build config values that you define in your project
$DeploymentConfig="" 

# The folder where the *.csproj can be found
$SourceDir="" 

# Full path to the *.csproj file
$ProjectFile=""

# Name of your assembly as specified in the project properties (without path or extension!!)
$AsmName=""

# Full path to the AssemblyInfo.cs file of the project
$VersionFile=""

# Output working directory
$Outdir=""

# This will be the folder which MSBuild generates the deployment package into - do not modify!
$PublishDir=Join-Path $Outdir "app.publish"

# The created packaged will be also zipped and put into this folder
$ZipRepository=""

# The path to the code-signing certificate
$CertificatePath=""

# The password of the authenticode certificate
$CertificatePassword=""


# Set these based on your deployment configuration
$InstallUrl=""
$DestBlob=""
$DestBlobKey=""


# Process path list - double check
$MsBuild = "C:\Program Files (x86)\MSBuild\14.0\Bin\msbuild.exe"
$SignTool="C:\Program Files (x86)\Windows Kits\8.1\bin\x64\signtool.exe"
$Mage="C:\Program Files (x86)\Microsoft SDKs\Windows\v8.1A\bin\NETFX 4.5.1 Tools\mage.exe"
$AzCopy =  "C:\Program Files (x86)\Microsoft SDKs\Azure\AzCopy\AzCopy.exe"
$TFExe="C:\Program Files (x86)\Microsoft Visual Studio 14.0\Common7\IDE\TF.exe"



Write-Host "Starting build. Current configuration: $DeploymentConfig"
Read-Host "Press enter to continue"

Set-Location $SourceDir

# Get current version
$Version = get-content $VersionFile | select-string "^\[assembly: AssemblyVersion(.*)" | %{$_.line.Split('"')[1];}
$VersionUnderscore = $Version -replace "\.","_"

# Get latest version using tf.exe
# Don't forget to supply your login
Write-Host "Getting latest version..."
$process = Start-Process $TFExe -ArgumentList "get $SourceDir /noprompt /recursive"  -PassThru -Wait 
if ($process.ExitCode -ne 0) 
{
    throw "Getting latest version failed"
}	
Write-Host "Getting latest version done."

Write-Host "Current version: $Version"

# Truncate working folder		
Write-Host "Truncating $Outdir..."
try
{
    Remove-Item "$Outdir\*" -recurse
}
catch
{    	
    throw "Failed truncating $Outdir"
}
Write-Host "$Outdir truncated"							

# Do a clean on the project 
Write-Host "Cleaning project $ProjectFile..."
$process = Start-Process $MsBuild -ArgumentList "$ProjectFile /t:clean  /v:minimal" -PassThru -Wait
if ($process.ExitCode -ne 0) 
{
    throw "Failed to clean project $ProjectFile"
}
Write-Host "Project $ProjectFile cleaned"


# Do the actual ClickOnce publish
Write-Host "Building project $ProjectFile..."
$process = Start-Process $MsBuild -ArgumentList "$ProjectFile /target:publish /p:Configuration=$DeploymentConfig /p:Platform=AnyCPU /p:OutputPath=$Outdir /v:minimal /p:ApplicationVersion=$Version /p:MinimumRequiredVersion=$Version /p:InstallUrl=$InstallUrl" -PassThru -Wait
if ($process.ExitCode -ne 0) 
{
    throw "Building project $ProjectFile failed"
}
Write-Host "Project $ProjectFile built."

# Build full assembly name
$AssemblyName="$PublishDir\Application Files\"+$AsmName+"_$VersionUnderscore\$AsmName.exe"


# Obfuscate your assembly here using your favorite obfusactor
# You can use the pattern that is used everywhere else; Write-Host, $process=Start-Process..., if $proces.ExitCode -ne 0 etc.


# Sign the assembly
Write-Host "Signing assembly $AssemblyName..."
$process = Start-Process $SignTool -ArgumentList "sign /f `"$CertificatePath`" /p $CertificatePassword `"$AssemblyName`""  -PassThru -Wait 
if ($process.ExitCode -ne 0) 
{
    throw "Signing assembly $AssemblyName failed"
}
Write-Host "Assembly $AssemblyName signed"

# Build the ClickOnce application manifest name and use mage to update it, then do the same for the deployment manifest
$ManifestName="$PublishDir\Application Files\"+$AsmName+"_$VersionUnderscore\"+$AsmName+".exe.manifest"

# Update and sign the appmanifest
Write-Host "Updating and signing application manifest..."
$process = Start-Process $Mage -ArgumentList "-Update `"$ManifestName`" -CertFile `"$CertificatePath`" -Password $CertificatePassword"  -PassThru -Wait  
if ($process.ExitCode -ne 0) 
{
    throw "Failed to update and sign application manifest"
}	
Write-Host "Application manifest updated and signed"

$DeployManifestName="$PublishDir\$AsmName.application"

Write-Host "Updating and signing deployment manifest..."
$process = Start-Process $Mage -ArgumentList "-Update `"$DeployManifestName`" -AppManifest `"$ManifestName`" -CertFile `"$CertificatePath`" -Password $CertificatePassword" -PassThru -Wait
if ($process.ExitCode -ne 0) 
{
    throw "Failed to update and sign deployment manifest"
}	
Write-Host "Deployment manifest updated and signed."	


# Also don't forget to sign the generate setup.exe
$Bootstrapper="$Publishdir\setup.exe";

Write-Host "Signing bootstrapper..."
$process = Start-Process $SignTool -ArgumentList "sign /f `"$CertificatePath`" /p $CertificatePassword `"$Bootstrapper`""  -PassThru -Wait 
if ($process.ExitCode -ne 0) 
{
    throw "Signing bootstrapper failed"
}
Write-Host "Bootstrapper signed"


# Copy everything to a blob storage
Write-Host "Transfering to blob storage $DestBlob..."
$process = Start-Process $AzCopy -ArgumentList "/Source:`"$Publishdir`" /Dest:$DestBlob /DestKey:$DestBlobKey /destType:blob  /S /V /XO /Y"  -PassThru -Wait 
if ($process.ExitCode -ne 0) 
{
    throw "Failed transfering to blob storage"
}	
Write-Host "Transfer completed."

# Archive the created package
Write-Host "Archiving..."
try
{
    $ZipFile=Join-Path $ZipRepository "$VersionUnderscore`_$DeploymentConfig.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $CompressionLevel    = [System.IO.Compression.CompressionLevel]::"Fastest"  
    [System.IO.Compression.ZipFile]::CreateFromDirectory($PublishDir, $ZipFile, $CompressionLevel, $False)
}
catch 
{
    throw "Archiving could not be done "+$_.Exception.Message
}
Write-Host "Archiving done".


# Update version in the AssemblyVersion.cs
$splitted=$Version.Split(".") 
$splitted[3]=1+$splitted[3]
$NextVersion=($splitted -join "`." | Out-String).Trim()
Write-Host "Next version: $NextVersion"

Write-Host "Updating version..."
$filecontent=get-content $VersionFile 
$filecontent | % { $_ -replace $Version, $NextVersion } | set-content $VersionFile -Encoding UTF8
Write-Host "Version updated"


# Don't forget to supply your login
Write-Host "Checking in new version info..."
$process = Start-Process $TFExe -ArgumentList "checkin $VersionFile /comment: `"Auto-version increment after deployment`" /noprompt"  -PassThru -Wait 
if ($process.ExitCode -ne 0) 
{
    throw "Failed to check in new version info"
}	
Write-Host "New version info checked in."

							
Read-Host 'Press enter to continue'
