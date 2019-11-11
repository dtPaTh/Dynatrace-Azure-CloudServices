# ==================================================
# dynatrace installation script
# ==================================================
# configuration section
# ==================================================


# ==================================================
# function section
# ==================================================

$nl = [Environment]::NewLine
function Log($content, $level) {
    if ($level -eq $null) {
        $level="LOG"
    }
    Write-Host ("{0} {1} {2} {3}" -f (Get-Date), $level, $content, $nl)
}

function LogDebug($content) {
    #Uncomment following line if you want so see extended debug log information
	#Log $content "DBG"  
}

function LogInfo($content) {
	Log $content "INF"
}

function LogWarning($content) {
	Log $content "WRN"
}

function LogError($content) {
	if ($_.Exception -ne $null) {
		Log ("Exception.Message = {0}" -f $_.Exception.Message) "ERROR"
	}
	Log $content "ERR"
}

#Never Exit with an error, as this prevents cloud-service to not start up
#function ExitFailed() {
#	Log "ABORT" "Installation failed. See log.txt for more information."
#	Exit 1
#}

function ExitSuccess() {
	Exit 0
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
function Unzip
{
    param([string]$zipfile, [string]$outpath)

    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipfile, $outpath)
}

# ==================================================
# main section
# ==================================================

$ret = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.WindowsAzure.ServiceRuntime")

# Only run within an Azure Cloud Service 
try
{
  if (![Microsoft.WindowsAzure.ServiceRuntime.RoleEnvironment]::IsAvailable)
  {
    LogError "RoleEnvironment is not available"
    ExitSuccess
  }
}
catch
{
  LogError "RoleEnvironment is not available"
  ExitSuccess
}

# Don't install in emulated mode
if ([Microsoft.WindowsAzure.ServiceRuntime.RoleEnvironment]::IsEmulated)
{
    LogError "Do not install in emulator"
    ExitSuccess
}

$roleRoot = [System.Environment]::GetEnvironmentVariable('RoleRoot', 'Process');
$startupTempPath = "$roleRoot\oneagent-deployment-temp"
if(!(Test-Path $startupTempPath)){
    $newdir = New-Item -ItemType Directory -Force -Path $startupTempPath
}

$globalTemp = [System.Environment]::GetEnvironmentVariable('TEMP','Machine');
$taskStateFile = "$globalTemp\InstallDynatraceStatus.txt"
LogDebug "TaskStateFile: $taskStateFile"
if (Test-Path $taskStateFile) { #skip on inplace updates
    LogDebug "Skip startup task as it is an inplace update or reboot"
    ExitSuccess
}

"Executed" | Out-File -filepath $taskStateFile

LogInfo "-------------------------------------------"
LogInfo "Installing Dynatrace OneAgent"
LogInfo "-------------------------------------------"

LogInfo "Reading Configuration..."

try { $cfgEnvironmentID = [Microsoft.WindowsAzure.ServiceRuntime.RoleEnvironment]::GetConfigurationSettingValue("Dynatrace.EnvironmentID") }
catch 
{ 
    LogInfo "Failed to read 'Dynatrace.EnvironmentID'" 
    ExitSuccess
}
LogDebug "EnvironmentID $cfgEnvironmentID"

try { $cfgApiToken = [Microsoft.WindowsAzure.ServiceRuntime.RoleEnvironment]::GetConfigurationSettingValue("Dynatrace.APIToken") }
catch 
{ 
    LogInfo "Failed to read 'Dynatrace.ApiToken'" 
    ExitSuccess 
}
LogDebug "Api-Token $cfgApiToken"

$cfgConnectionPoint = "https://{0}.live.dynatrace.com" -f $cfgEnvironmentID
try { $cfgConnectionPoint = [Microsoft.WindowsAzure.ServiceRuntime.RoleEnvironment]::GetConfigurationSettingValue("Dynatrace.ConnectionPoint") }
catch 
{ 
    LogInfo "Unable to read 'Dynatrace.ConnectionPoint', using default endpoint for SaaS" 
}
LogDebug "ConnectionPoint $cfgConnectionPoint"

LogInfo "Configuration Complete."

$authHeader = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$authHeader.Add('Authorization',"Api-Token {0}" -f $cfgApiToken)

# Read connectioninfo
try {
    LogInfo "Reading Manifest..."
    
    $manifestDownloadQuery = "{0}/api/v1/deployment/installer/agent/connectioninfo" -f $cfgConnectionPoint

    $manifest = Invoke-WebRequest $manifestDownloadQuery -Headers $authHeader -UseBasicParsing | ConvertFrom-Json
    $tenantToken = $manifest.tenantToken
    LogDebug "Tenant-Token: $tenantToken"

    $agentConnectionPoint = ""
    if ($manifest.communicationEndpoints -ne $null) {
        foreach ($cp in $manifest.communicationEndpoints) {
            LogDebug "Connectionpoint: $cp"
            if ($agentConnectionPoint -ne "") {
                $agentConnectionPoint = $agentConnectionPoint + ";"
            }
            $agentConnectionPoint = $agentConnectionPoint + $cp
        }	
    } elseif ($env:DT_CONNECTION_POINT -ne $null){
        $agentConnectionPoint = $env:DT_CONNECTION_POINT
    }

    if ($tenantToken -eq $null) {
        throw "Invalid Tenant-Token"
    }

    if ($agentConnectionPoint -eq "") {
        throw "Invalid connection point"
    }

} catch {
    LogError "Failed to read manifest"
    ExitSuccess
}

# Download

try {
    $agentDownloadTarget =  "$startupTempPath\oneagent-installer.exe"
    $agentDownloadQuery = "{0}/api/v1/deployment/installer/agent/windows/default/latest" -f $cfgConnectionPoint

	
    LogInfo "Downloading OneAgent..."
    LogDebug "$agentDownloadQuery -> $agentDownloadTarget"
    Invoke-WebRequest $agentDownloadQuery -OutFile $agentDownloadTarget -Headers $authHeader

} catch {
	LogError "Failed to download OneAgent"
	ExitSuccess
}

$agentInstallerTargetPath = $startupTempPath
$agentInstaller = $null
try {
    LogInfo "Extracting .msi..."
    $exitCode =(Start-Process -FilePath $agentDownloadTarget -ArgumentList "--unpack-msi" -WorkingDirectory $agentInstallerTargetPath -NoNewWindow -Wait -Passthru).ExitCode
    LogInfo "Installer finished with exit code: $exitCode"
}
catch {
    LogError "Unable to extract .msi"
	ExitSuccess
}

$agentInstaller = Get-ChildItem -Path $agentInstallerTargetPath -Filter *.msi  | %{$_.FullName}
if (!(Test-Path $agentInstaller)) {
    LogError "Couldn't find agent installer"
	ExitSuccess
}

try {
    
    $exitCode =(Start-Process -FilePath "msiexec" -ArgumentList "/i $agentInstaller /qn SERVER=$agentConnectionPoint TENANT=$cfgEnvironmentID TENANT_TOKEN=$tenantToken PROCESSHOOKING=1 APP_LOG_CONTENT_ACCESS=1" -NoNewWindow -Wait -Passthru).ExitCode
    
    LogInfo "Installer finished with exit code: $exitCode"

} catch {
    LogError "Failed to run OneAgent installer"
}

ExitSuccess

