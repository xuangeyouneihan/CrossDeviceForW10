<#
.SYNOPSIS
    Install the "Cross Device Experience Host" (MicrosoftWindows.CrossDevice)
    on Windows 10 LTSC 2021 / any Windows 10 build >= 19041.

.DESCRIPTION
    Microsoft's Store listing declares MinVersion="10.0.19045.0" (Windows 10
    22H2) for the last Windows 10 build of this package, so LTSC 2021
    (build 19044) cannot install it through the Store. That gate is a
    manifest declaration, not a real API dependency: the package's own
    runtime check (CrossDevice.Core!IsUnsupportedReleaseVersion) only
    requires Windows.Foundation.UniversalApiContract v10, i.e. build 19041.

    This script lowers MinVersion and registers the package in place, the
    same technique a manifest-gate patch uses, with two deliberate
    differences:

      * The package Identity is NOT renamed. PC-side hosts reference
        "MicrosoftWindows.CrossDevice" by name (Phone Link's
        YourPhone.Utilities.dll, and SettingsHandlers_ManagePhone.dll which
        hardcodes ms-crossdevice-settings:?scenarioId=Settings plus both
        publisher hashes), so renaming would break the integration.
      * No binaries are patched. There is no native Windows 11 gate to
        remove; the only version checks present are 22621/23H2 data gates
        that evaluate identically on 19044 and 19045.

    NOTE ON LANGUAGE: MSIX resource packages cannot be registered in
    DevelopmentMode, and signed resource packages are blocked by the same
    MinVersion gate. The UI therefore falls back to the neutral (English)
    strings. See the output of this script for details.

.PARAMETER BundlePath
    Path to a MicrosoftWindows.CrossDevice_*.AppxBundle / .msixbundle, or an
    already-extracted package folder, or a single .msix. If omitted the
    script searches for a suitable bundle next to itself, in the parent
    directory, and in Downloads, then falls back to resolving one from
    Microsoft's delivery servers.

.PARAMETER InstallDir
    Where to place the patched, unpacked package.
    Default: %LOCALAPPDATA%\Programs\CrossDevice

.PARAMETER MinOs
    MinVersion to write into the manifest. Default 10.0.19041.0, which is
    the real floor the app itself enforces.

.PARAMETER Uninstall
    Unregister the package and delete InstallDir, then exit.

.PARAMETER KeepData
    With -Uninstall, keep the per-user data folder
    (%LOCALAPPDATA%\Packages\MicrosoftWindows.CrossDevice_cw5n1h2txyewy),
    which holds the "allow this PC to access your mobile devices" toggle and
    other settings.

.PARAMETER Launch
    Open the Cross Device settings page after a successful install.

.PARAMETER PreferOnline
    Try to resolve the newest Windows 10 compatible build from Microsoft's
    delivery servers before looking at local files.

.PARAMETER SkipDependencyCheck
    Do not abort when a declared PackageDependency is missing.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -BundlePath '.\MicrosoftWindows.CrossDevice_1.25072.59.0_neutral_~_cw5n1h2txyewy.AppxBundle' -Launch

.EXAMPLE
    .\install.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [string]$BundlePath,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\CrossDevice'),
    [string]$MinOs = '10.0.19041.0',
    [switch]$Uninstall,
    [switch]$KeepData,
    [switch]$Launch,
    [switch]$PreferOnline,
    [switch]$SkipDependencyCheck
)

$ErrorActionPreference = 'Stop'

# --- Constants -------------------------------------------------------------

$PackageName    = 'MicrosoftWindows.CrossDevice'
$BundlePattern  = 'MicrosoftWindows.CrossDevice_*.AppxBundle'
$BundlePattern2 = 'MicrosoftWindows.CrossDevice_*.msixbundle'
$StoreProductId = '9NTXGKQ8P7N0'
$SignatureFiles = @(
    'AppxSignature.p7x'
    'AppxBlockMap.xml'
    '[Content_Types].xml'
    'AppxMetadata\CodeIntegrity.cat'
)
$SettingsUri = 'ms-crossdevice-settings:?scenarioId=Settings'

# Used only in the PowerShell 7 hint, so the suggested command is copy-pasteable.
$RepoRawUrl = 'https://raw.githubusercontent.com/xuangeyouneihan/CrossDeviceForW10/master/install.ps1'

# --- Helpers ---------------------------------------------------------------

function Write-Step  { param([string]$m) Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "    [+] $m" -ForegroundColor Green }
function Write-Note  { param([string]$m) Write-Host "    [=] $m" -ForegroundColor DarkGray }
function Write-Warn2 { param([string]$m) Write-Host "    [!] $m" -ForegroundColor Yellow }

function Get-OsBuild {
    [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
}

function Get-OsCaption {
    $os = Get-CimInstance Win32_OperatingSystem
    "$($os.Caption) $($os.Version)"
}

function Test-DevModeEnabled {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    if (-not (Test-Path $k)) { return $false }
    $v = Get-ItemProperty -Path $k -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue
    return ($null -ne $v -and $v.AllowDevelopmentWithoutDevLicense -eq 1)
}

function Get-VersionFromName {
    # AppleInc.X_1.2.3.4_neutral_~_hash.AppxBundle  ->  [version]1.2.3.4
    param([string]$Name)
    if ($Name -match '_(\d+(?:\.\d+){1,3})_') {
        try { return [version]$Matches[1] } catch { return $null }
    }
    return $null
}

function Expand-ZipTo {
    param([string]$ZipPath, [string]$Destination)
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

# Reads the bundle manifest and the embedded x64 application package manifest
# without installing anything, so we can decide whether a candidate is usable
# *before* spending time on a download or a deployment.
function Get-BundleInfo {
    param([string]$Path)

    $info = [pscustomobject]@{
        Path          = $Path
        Version       = $null
        IdentityName  = $null
        Architectures = @()
        X64Package    = $null
        MinVersion    = $null
        Error         = $null
    }

    $info.Version = Get-VersionFromName (Split-Path $Path -Leaf)
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("cdprobe_" + [guid]::NewGuid().ToString('N'))
    try {
        Expand-ZipTo -ZipPath $Path -Destination $work

        $bundleManifest = Join-Path $work 'AppxMetadata\AppxBundleManifest.xml'
        if (-not (Test-Path $bundleManifest)) {
            $info.Error = 'no AppxMetadata\AppxBundleManifest.xml (not an app bundle?)'
            return $info
        }

        [xml]$bm = Get-Content $bundleManifest -Raw

        # A bundle lists "stub" packages first, under AppxMetadata\Stub\, and
        # they are also Type="application". Their version is 0.x, so they look
        # valid but contain none of the real payload. Exclude them explicitly.
        $appPkgs = @($bm.Bundle.Packages.Package | Where-Object {
            $_.Type -eq 'application' -and $_.FileName -and ($_.FileName -notlike '*Stub*')
        })
        $info.Architectures = @($appPkgs | ForEach-Object { $_.Architecture } | Sort-Object -Unique)
        $x64All = @($appPkgs | Where-Object { $_.Architecture -eq 'x64' })
        $x64 = $x64All | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
        if (-not $x64) {
            $info.Error = "no x64 application package in bundle (found: $($info.Architectures -join ', '))"
            return $info
        }
        if (([version]$x64.Version).Major -lt 1) {
            $info.Error = "x64 package $($x64.FileName) looks like a stub (version $($x64.Version))"
            return $info
        }
        $info.X64Package = $x64.FileName
        if (-not $info.Version) { $info.Version = [version]$x64.Version }

        # Dig one level deeper: the app manifest inside the x64 .msix.
        $inner = Join-Path $work $x64.FileName
        if (-not (Test-Path $inner)) {
            $info.Error = "bundle manifest references $($x64.FileName) but it is not present"
            return $info
        }
        $innerWork = Join-Path $work '_inner'
        Expand-ZipTo -ZipPath $inner -Destination $innerWork
        $appManifest = Join-Path $innerWork 'AppxManifest.xml'
        if (-not (Test-Path $appManifest)) {
            $info.Error = 'x64 package has no AppxManifest.xml'
            return $info
        }
        [xml]$am = Get-Content $appManifest -Raw
        $info.IdentityName = $am.Package.Identity.Name
        $tdf = $am.Package.Dependencies.TargetDeviceFamily | Select-Object -First 1
        if ($tdf) { $info.MinVersion = $tdf.MinVersion }
    }
    catch {
        $info.Error = $_.Exception.Message
    }
    finally {
        if (Test-Path $work) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
    }
    return $info
}

# Only builds that declare a Windows 10 reachable floor are useful here.
function Test-Win10Compatible {
    param([pscustomobject]$Info)
    if ($Info.Error) { return $false }
    if (-not $Info.MinVersion) { return $false }
    try { $mv = [version]$Info.MinVersion } catch { return $false }
    # 19045 = Windows 10 22H2, the newest Windows 10 build. Anything above
    # that (22000/22621/22631/26100) is Windows 11 only.
    return ($mv.Build -le 19045)
}

function Find-LocalBundle {
    param([string]$Hint)

    $searchDirs = @()
    if ($Hint) { $searchDirs += (Split-Path -Parent ([System.IO.Path]::GetFullPath($Hint))) }
    if ($PSScriptRoot)        { $searchDirs += $PSScriptRoot }
    if ($PSScriptRoot)        { $searchDirs += (Split-Path -Parent $PSScriptRoot) }
    else {
        # Empty when the script is piped in as text (irm ... | iex). In that
        # case the current directory is the most likely place people keep the
        # bundle, since there is no script folder to look next to.
        try { $searchDirs += (Get-Location).Path } catch { }
    }
    if ($env:USERPROFILE)     { $searchDirs += (Join-Path $env:USERPROFILE 'Downloads') }
    $searchDirs = $searchDirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $candidates = @()
    foreach ($d in $searchDirs) {
        $candidates += Get-ChildItem -Path $d -Filter $BundlePattern  -File -ErrorAction SilentlyContinue
        $candidates += Get-ChildItem -Path $d -Filter $BundlePattern2 -File -ErrorAction SilentlyContinue
    }
    $candidates = $candidates | Sort-Object FullName -Unique
    if (-not $candidates) { return @() }

    Write-Note "扫描到 $($candidates.Count) 个候选 bundle，正在校验哪个是 Win10 可用的…"
    $usable = @()
    foreach ($c in $candidates) {
        $i = Get-BundleInfo -Path $c.FullName
        $ver = if ($i.Version) { $i.Version.ToString() } else { '?' }
        if ($i.Error) {
            Write-Note ("  {0}  v{1}  -> 跳过（{2}）" -f $c.Name, $ver, $i.Error)
            continue
        }
        if ($i.IdentityName -ne $PackageName) {
            Write-Note ("  {0}  v{1}  -> 跳过（Identity 是 {2}）" -f $c.Name, $ver, $i.IdentityName)
            continue
        }
        if (-not (Test-Win10Compatible $i)) {
            Write-Note ("  {0}  v{1}  -> 跳过（MinVersion={2}，仅 Win11）" -f $c.Name, $ver, $i.MinVersion)
            continue
        }
        Write-Note ("  {0}  v{1}  -> 可用（MinVersion={2}）" -f $c.Name, $ver, $i.MinVersion)
        $usable += $i
    }
    return $usable
}

# --- Microsoft delivery-server resolution (mirrors install.ps1) -------------
# install.ps1's approach: Store product id -> WuCategoryId -> FE3 SOAP
# GetCookie + SyncUpdates -> UpdateIdentity -> GetExtendedUpdateInfo2(FileUrl).
# Kept here so the script degrades gracefully, but note that at the time of
# writing Microsoft's catalog no longer returns a <Files> element or any
# FileLocation for this product, so expect this path to find nothing.

$script:WuServiceUrl = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$script:WuSecuredUrl = "$script:WuServiceUrl/secured"
$script:DeviceAttributes = 'BranchReadinessLevel=CB;CurrentBranch=rs_prerelease;OEMModel=Virtual Machine;FlightRing=Retail;AttrDataVer=21;SystemManufacturer=Microsoft Corporation;InstallLanguage=en-US;OSUILocale=en-US;InstallationType=Client;FlightingBranchName=external;FirmwareVersion=Hyper-V UEFI Release v2.5;SystemProductName=Virtual Machine;OSSkuId=48;FlightContent=Branch;App=WU;OEMName_Uncleaned=Microsoft Corporation;AppVer=10.0.22621.900;OSArchitecture=AMD64;SystemSKU=None;UpdateManagementGroup=2;IsFlightingEnabled=1;IsDeviceRetailDemo=0;TelemetryLevel=3;OSVersion=10.0.22621.900;DeviceFamily=Windows.Desktop;'

function New-SoapTimestamps {
    [pscustomobject]@{
        Created   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Expires   = [DateTime]::UtcNow.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        MessageId = [guid]::NewGuid().ToString()
    }
}

function Get-SecurityHeaderXml {
    param([pscustomobject]$Timestamps)
    @"
<o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
<Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
<Created>$($Timestamps.Created)</Created><Expires>$($Timestamps.Expires)</Expires>
</Timestamp>
<WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
<TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"></TicketType>
</WindowsUpdateTicketsToken>
</o:Security>
"@
}

function Get-WuCategoryId {
    param([string]$ProductId)
    $url = "https://storeedgefd.dsx.mp.microsoft.com/v9.0/products/$ProductId`?market=US&locale=en-us&deviceFamily=Windows.Desktop"
    $resp = Invoke-RestMethod -Uri $url -Method Get
    $sku = $resp.Payload.Skus | Where-Object { $_.FulfillmentData } | Select-Object -First 1
    if (-not $sku) { throw "Store 未返回含 FulfillmentData 的 SKU（产品 $ProductId）" }
    return ($sku.FulfillmentData | ConvertFrom-Json).WuCategoryId
}

function Get-WuCookie {
    $ts = New-SoapTimestamps
    $body = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
<s:Header>
<a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie</a:Action>
<a:MessageID>urn:uuid:$($ts.MessageId)</a:MessageID>
<a:To s:mustUnderstand="1">$script:WuServiceUrl</a:To>
$(Get-SecurityHeaderXml $ts)
</s:Header>
<s:Body>
<GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
<oldCookie></oldCookie>
<lastChange>2015-10-21T17:01:07.1472913Z</lastChange>
<currentTime>$($ts.Created)</currentTime>
<protocolVersion>1.40</protocolVersion>
</GetCookie>
</s:Body>
</s:Envelope>
"@
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $script:WuServiceUrl -Method Post -Body $body -ContentType 'application/soap+xml; charset=utf-8'
    [xml]$xml = $resp.Content
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('wu', 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService')
    $r = $xml.SelectSingleNode('//wu:GetCookieResult', $ns)
    [pscustomobject]@{ EncryptedData = $r.EncryptedData; Expiration = $r.Expiration }
}

function Get-SyncUpdatesXml {
    param([string]$CategoryId, [pscustomobject]$Cookie)
    $ts = New-SoapTimestamps
    $body = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
<s:Header>
<a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates</a:Action>
<a:MessageID>urn:uuid:$($ts.MessageId)</a:MessageID>
<a:To s:mustUnderstand="1">$script:WuServiceUrl</a:To>
$(Get-SecurityHeaderXml $ts)
</s:Header>
<s:Body>
<SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
<cookie><Expiration>$($Cookie.Expiration)</Expiration><EncryptedData>$($Cookie.EncryptedData)</EncryptedData></cookie>
<parameters>
<ExpressQuery>false</ExpressQuery>
<InstalledNonLeafUpdateIDs><int>1</int><int>2</int><int>3</int><int>11</int><int>19</int><int>544</int><int>549</int></InstalledNonLeafUpdateIDs>
<OtherCachedUpdateIDs></OtherCachedUpdateIDs>
<SkipSoftwareSync>false</SkipSoftwareSync>
<NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
<FilterAppCategoryIds><CategoryIdentifier><Id>$CategoryId</Id></CategoryIdentifier></FilterAppCategoryIds>
<TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
<AlsoPerformRegularSync>false</AlsoPerformRegularSync>
<ComputerSpec></ComputerSpec>
<ExtendedUpdateInfoParameters>
<XmlUpdateFragmentTypes><XmlUpdateFragmentType>Extended</XmlUpdateFragmentType></XmlUpdateFragmentTypes>
<Locales><string>en-US</string><string>en</string></Locales>
</ExtendedUpdateInfoParameters>
<ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages>
<ProductsParameters>
<SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
<DeviceAttributes>$script:DeviceAttributes</DeviceAttributes>
<CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes>
<Products></Products>
</ProductsParameters>
</parameters>
</SyncUpdates>
</s:Body>
</s:Envelope>
"@
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $script:WuServiceUrl -Method Post -Body $body -ContentType 'application/soap+xml; charset=utf-8'
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    [xml]$xml = [System.Web.HttpUtility]::HtmlDecode($resp.Content)
    return $xml
}

function Get-FileLocationsXml {
    param([object[]]$UpdateIds)
    $ts = New-SoapTimestamps
    $sb = New-Object System.Text.StringBuilder
    foreach ($u in $UpdateIds) {
        [void]$sb.Append("<UpdateIdentity><UpdateID>$($u.UpdateId)</UpdateID><RevisionNumber>$($u.Revision)</RevisionNumber></UpdateIdentity>")
    }
    $body = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
<s:Header>
<a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2</a:Action>
<a:MessageID>urn:uuid:$($ts.MessageId)</a:MessageID>
<a:To s:mustUnderstand="1">$script:WuSecuredUrl</a:To>
$(Get-SecurityHeaderXml $ts)
</s:Header>
<s:Body>
<GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
<updateIDs>$($sb.ToString())</updateIDs>
<infoTypes><XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType><XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType></infoTypes>
<deviceAttributes>$script:DeviceAttributes</deviceAttributes>
</GetExtendedUpdateInfo2>
</s:Body>
</s:Envelope>
"@
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $script:WuSecuredUrl -Method Post -Body $body -ContentType 'application/soap+xml; charset=utf-8'
    [xml]$resp.Content
}

function Resolve-BundleFromMicrosoft {
    <#
        Returns the best download URL that yields a Windows 10 compatible
        bundle, or $null. Deliberately re-validates whatever it downloads by
        reading the manifest, because the catalog can start returning a
        Windows 11 only build at any time.
    #>
    param([string]$WorkDir)

    Write-Step '正在尝试从 Microsoft 交付服务器解析安装包'
    try {
        $categoryId = Get-WuCategoryId -ProductId $StoreProductId
        Write-Note "WuCategoryId = $categoryId"
    }
    catch {
        Write-Warn2 "取 WuCategoryId 失败：$($_.Exception.Message)"
        return $null
    }

    try {
        $cookie = Get-WuCookie
        $sync   = Get-SyncUpdatesXml -CategoryId $categoryId -Cookie $cookie
    }
    catch {
        Write-Warn2 "FE3 会话建立失败：$($_.Exception.Message)"
        return $null
    }

    $ns = New-Object System.Xml.XmlNamespaceManager($sync.NameTable)
    $ns.AddNamespace('wu', 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService')

    # Catalog entries carry PackageIdentityName on the Extended side and the
    # UpdateIdentity on the NewUpdates side; join them on the numeric ID.
    $numericIds = @()
    foreach ($e in $sync.SelectNodes('//wu:ExtendedUpdateInfo/wu:Updates/wu:Update', $ns)) {
        if ($e.OuterXml -match ('PackageIdentityName="' + [regex]::Escape($PackageName) + '"')) {
            $numericIds += [string]$e.ID
        }
    }
    if (-not $numericIds) {
        Write-Warn2 '目录里没有该应用的条目'
        return $null
    }
    Write-Note "目录条目数：$($numericIds.Count)"

    $identities = @()
    foreach ($n in $sync.SelectNodes('//wu:NewUpdates/wu:UpdateInfo', $ns)) {
        if ($numericIds -notcontains [string]$n.ID) { continue }
        $x = $n.Xml.InnerXml
        if (-not $x) { continue }
        if ($x -match 'UpdateID="([0-9a-fA-F\-]{36})"') {
            $uid = $Matches[1]
            $rev = if ($x -match 'RevisionNumber="(\d+)"') { $Matches[1] } else { '1' }
            $identities += [pscustomobject]@{ UpdateId = $uid; Revision = $rev }
        }
    }
    if (-not $identities) {
        Write-Warn2 '无法把目录条目映射到 UpdateIdentity'
        return $null
    }

    try {
        $locs = Get-FileLocationsXml -UpdateIds $identities
    }
    catch {
        Write-Warn2 "GetExtendedUpdateInfo2 失败：$($_.Exception.Message)"
        return $null
    }

    $ns2 = New-Object System.Xml.XmlNamespaceManager($locs.NameTable)
    $ns2.AddNamespace('wu', 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService')
    $urls = @()
    foreach ($fl in $locs.SelectNodes('//wu:FileLocations/wu:FileLocation', $ns2)) {
        $u = $fl.SelectSingleNode('wu:Url', $ns2).InnerText
        if ($u) { $urls += $u }
    }

    # Prefer bundles, and prefer the signed CDN edge host like install.ps1 does.
    $urls = $urls | Where-Object { $_ -match '\.(msixbundle|appxbundle)' }
    $urls = $urls | Sort-Object @{ Expression = { if ($_ -match '^https?://tlu\.') { 0 } else { 1 } } }

    if (-not $urls) {
        Write-Warn2 '服务器没有返回任何 bundle 下载地址（Microsoft 目前的目录响应不含文件清单，属于已知情况）'
        return $null
    }

    foreach ($u in $urls) {
        $name = ($u -split '\?')[0]
        $name = $name.Substring($name.LastIndexOf('/') + 1)
        $dest = Join-Path $WorkDir $name
        Write-Note "下载 $name …"
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $dest -TimeoutSec 600
        }
        catch {
            Write-Warn2 "下载失败：$($_.Exception.Message)"
            continue
        }
        $i = Get-BundleInfo -Path $dest
        if (Test-Win10Compatible $i) {
            Write-Ok "可用：v$($i.Version)，MinVersion=$($i.MinVersion)"
            return $i
        }
        Write-Warn2 "$name 不适用于 Windows 10（MinVersion=$($i.MinVersion)），丢弃"
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
    }
    return $null
}

function Resolve-Bundle {
    param([string]$Hint, [string]$WorkDir, [switch]$PreferOnline)

    if ($PreferOnline) {
        $online = Resolve-BundleFromMicrosoft -WorkDir $WorkDir
        if ($online) { return $online }
        Write-Note '在线解析未取得可用包，回退到本地文件'
    }

    $local = @(Find-LocalBundle -Hint $Hint)
    if ($local.Count -gt 0) {
        $best = $local | Sort-Object { $_.Version } -Descending | Select-Object -First 1
        Write-Ok "选用最高可用版本 v$($best.Version)：$(Split-Path $best.Path -Leaf)"
        return $best
    }

    if (-not $PreferOnline) {
        $online = Resolve-BundleFromMicrosoft -WorkDir $WorkDir
        if ($online) { return $online }
    }
    return $null
}

# --- Uninstall -------------------------------------------------------------

if ($Uninstall) {
    Write-Step '卸载'
    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if ($pkg) {
        $removeParams = @{ ErrorAction = 'Stop' }
        if ($KeepData -and (Get-Command Remove-AppxPackage).Parameters.ContainsKey('PreserveApplicationData')) {
            $removeParams['PreserveApplicationData'] = $true
            Write-Note '保留应用数据目录'
        }
        foreach ($p in $pkg) {
            Remove-AppxPackage -Package $p.PackageFullName @removeParams
            Write-Ok "已注销 $($p.PackageFullName)"
        }
    }
    else { Write-Note '包未注册' }

    if (Test-Path $InstallDir) {
        Remove-Item -Recurse -Force $InstallDir
        Write-Ok "已删除 $InstallDir"
    }
    Write-Ok '完成'
    return
}

# --- Preflight -------------------------------------------------------------

Write-Step '环境检查'

if ($PSVersionTable.PSVersion.Major -ge 6) {
    throw @"
Appx 模块在 PowerShell 7 下不可用，请改用 Windows PowerShell 5.1 运行。

  本地脚本：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

  一行命令（在 cmd 或「运行」对话框中）：
    powershell -NoProfile -Command "irm $RepoRawUrl | iex"

当前会话版本：$($PSVersionTable.PSVersion)
"@
}

$osBuild = Get-OsBuild
Write-Note "系统：$(Get-OsCaption)（build $osBuild）"

try { $minOsVersion = [version]$MinOs } catch { throw "-MinOs 不是有效版本号：$MinOs" }
if ($minOsVersion.Build -lt 19041) {
    throw '-MinOs 低于 19041；该应用自身要求 UniversalApiContract v10，即 19041 起。'
}
if ($osBuild -lt 19041) {
    throw "当前系统 build $osBuild 低于应用可运行的最低要求 19041，无法安装。"
}
if ($osBuild -lt $minOsVersion.Build) {
    throw "当前系统 build $osBuild 低于 -MinOs 指定的 $($minOsVersion.Build)。请把 -MinOs 降到不高于本机版本。"
}

$arch = $env:PROCESSOR_ARCHITECTURE
Write-Note "架构：$arch"
if ($arch -ne 'AMD64') {
    Write-Warn2 '本脚本针对 x64 编写；arm64/x86 需另行调整。'
}

if (-not (Test-DevModeEnabled)) {
    throw @'
开发者模式（或"旁加载应用"）未启用，Add-AppxPackage -Register 会失败。
请以管理员身份运行下列命令之一，然后重试：

  # 仅允许松散注册（推荐）
  New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Force | Out-Null
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord

  # 或在"设置 > 更新和安全 > 开发者选项"里打开"开发人员模式 / 旁加载应用"
'@
}
Write-Ok '开发者模式已启用'

$existing = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
if ($existing) {
    foreach ($e in $existing) { Write-Note "已存在：$($e.PackageFullName)" }
    Write-Note '将按原地重新注册处理（等同一次更新）'
}

# --- Resolve the bundle ----------------------------------------------------

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cdinstall_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

try {
    Write-Step '定位安装包'
    if ($BundlePath) {
        if (-not (Test-Path $BundlePath)) { throw "找不到指定的 -BundlePath：$BundlePath" }
        $resolved = Get-BundleInfo -Path ([System.IO.Path]::GetFullPath($BundlePath))
        if ($resolved.Error) { throw "不是可用的 bundle：$($resolved.Error)" }
        if ($resolved.IdentityName -ne $PackageName) {
            throw "Identity 不符：期望 $PackageName，实际 $($resolved.IdentityName)"
        }
        if (-not (Test-Win10Compatible $resolved)) {
            throw "该包 MinVersion=$($resolved.MinVersion)，不是面向 Windows 10 的构建。请在 bundle 列表里挑 MinVersion <= 10.0.19045.0 的那个。"
        }
        Write-Ok "使用 $($resolved.Path)（v$($resolved.Version)）"
    }
    else {
        $resolved = Resolve-Bundle -Hint $BundlePath -WorkDir $workRoot -PreferOnline:$PreferOnline
        if (-not $resolved) {
            throw @'
没有找到可用的安装包。

Microsoft 的 Store/WU 目录目前只提供当前版本（它的 MinVersion 指向 Windows 11），
本文提到的最后一个 Windows 10 构建需要手动提供。

请下载 MicrosoftWindows.CrossDevice_1.25072.59.0_neutral_~_cw5n1h2txyewy.AppxBundle
并用 -BundlePath 指定：

  .\install.ps1 -BundlePath 'C:\path\to\MicrosoftWindows.CrossDevice_1.25072.59.0_neutral_~_cw5n1h2txyewy.AppxBundle'

说明：面向 Windows 10 的最后构建是 1.25072.59.0（MinVersion 10.0.19045.0）。
之后的 1.25092 / 1.26082 / 1.26092 分别是 22631/22631，仅 Windows 11。
'@
        }
    }

    # --- Unpack ------------------------------------------------------------

    Write-Step '解包'
    $bundleDir = Join-Path $workRoot 'bundle'
    Expand-ZipTo -ZipPath $resolved.Path -Destination $bundleDir
    Write-Ok 'bundle 已展开'

    $bundleManifest = Join-Path $bundleDir 'AppxMetadata\AppxBundleManifest.xml'
    if (-not (Test-Path $bundleManifest)) { throw 'bundle 缺少 AppxMetadata\AppxBundleManifest.xml' }
    [xml]$bm = Get-Content $bundleManifest -Raw
    # Skip the AppxMetadata\Stub\* entries: they are Type="application" too,
    # but carry version 0.x and no payload.
    $x64Pkg = @($bm.Bundle.Packages.Package | Where-Object {
                   $_.Type -eq 'application' -and $_.Architecture -eq 'x64' -and $_.FileName -notlike '*Stub*'
               }) | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $x64Pkg) { throw 'bundle 中没有 x64 应用程序包' }
    if (([version]$x64Pkg.Version).Major -lt 1) { throw "选中的 $($x64Pkg.FileName) 看起来是 stub 包" }
    $x64Path = Join-Path $bundleDir $x64Pkg.FileName
    if (-not (Test-Path $x64Path)) { throw "缺少 $($x64Pkg.FileName)" }
    Write-Ok "选定 $($x64Pkg.FileName)"

    $stage = Join-Path $workRoot 'stage'
    Expand-ZipTo -ZipPath $x64Path -Destination $stage
    Write-Ok 'x64 包已展开'

    # --- Patch the manifest ------------------------------------------------

    Write-Step '修补 AppxManifest.xml'
    $manifestPath = Join-Path $stage 'AppxManifest.xml'
    if (-not (Test-Path $manifestPath)) { throw 'x64 包缺少 AppxManifest.xml' }

    $text = [System.IO.File]::ReadAllText($manifestPath)

    $identityName = $null
    if ($text -match '<Identity\s+[^>]*Name="([^"]+)"') { $identityName = $Matches[1] }
    if ($identityName -ne $PackageName) {
        throw "Identity Name 不是 $PackageName（实际 $identityName）。本脚本刻意不改包名：Phone Link 与设置页按名字引用它，改名会导致对接失效。"
    }
    Write-Note "Identity 保持 $identityName（不改名）"

    $minVersionPattern = 'MinVersion="10\.0\.\d+\.\d+"'
    $hits = ([regex]::Matches($text, $minVersionPattern)).Count
    if ($hits -eq 0) { throw '清单里找不到 MinVersion，格式可能已变化' }
    $text = [regex]::Replace($text, $minVersionPattern, ('MinVersion="' + $minOsVersion.ToString() + '"'))
    [System.IO.File]::WriteAllText($manifestPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "MinVersion -> $($minOsVersion.ToString())（替换 $hits 处）"

    # --- Strip signature metadata -----------------------------------------

    Write-Step '移除签名相关文件'
    $removedAny = $false
    foreach ($rel in $SignatureFiles) {
        $p = Join-Path $stage $rel
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force
            Write-Ok "删除 $rel"
            $removedAny = $true
        }
    }
    if (-not $removedAny) { Write-Note '没有可删的签名文件（可能已是松散包）' }

    # --- Dependency check --------------------------------------------------

    Write-Step '检查依赖'
    $depIssues = @()
    try {
        [xml]$patched = Get-Content $manifestPath -Raw
        $deps = @($patched.Package.Dependencies.PackageDependency)
        if ($deps.Count -eq 0) { Write-Note '清单未声明 PackageDependency' }
        foreach ($d in $deps) {
            $installed = Get-AppxPackage -Name $d.Name -ErrorAction SilentlyContinue
            if (-not $installed) {
                $depIssues += "缺少 $($d.Name)（需要 >= $($d.MinVersion)）"
                continue
            }
            $best = ($installed | Sort-Object Version -Descending | Select-Object -First 1).Version
            $ok = $true
            try { $ok = ([version]$best -ge [version]$d.MinVersion) } catch { }
            if ($ok) { Write-Ok "$($d.Name) $best >= $($d.MinVersion)" }
            else { $depIssues += "$($d.Name) 版本过低：$best < $($d.MinVersion)" }
        }
    }
    catch { Write-Warn2 "依赖解析失败：$($_.Exception.Message)" }

    if ($depIssues.Count -gt 0) {
        foreach ($m in $depIssues) { Write-Warn2 $m }
        if (-not $SkipDependencyCheck) {
            throw '依赖不满足，已中止。补齐依赖后重试，或用 -SkipDependencyCheck 强行继续。'
        }
    }

    # --- Deploy ------------------------------------------------------------

    Write-Step '部署到安装目录'
    $backupDir = $null
    if (Test-Path $InstallDir) {
        $procs = Get-Process -ErrorAction SilentlyContinue |
                 Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, 'OrdinalIgnoreCase') }
        if ($procs) {
            foreach ($pr in $procs) { Write-Warn2 "正在结束 $($pr.ProcessName)（$($pr.Id)）" ; Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 500
        }
        # Keep the previous contents until the new registration is confirmed,
        # so a failed deploy can be rolled back instead of leaving a package
        # registered against a half-replaced directory.
        $backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cdbackup_' + [guid]::NewGuid().ToString('N'))
        Move-Item -Path $InstallDir -Destination $backupDir
        Write-Note "旧目录已暂存到 $backupDir"
    }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $stage '*') -Destination $InstallDir -Recurse -Force
    Write-Ok "已复制到 $InstallDir"

    Write-Step '注册包'
    $registeredManifest = Join-Path $InstallDir 'AppxManifest.xml'
    $registerError = $null

    try {
        Add-AppxPackage -Register $registeredManifest -ErrorAction Stop
        Write-Ok '注册成功'
    }
    catch {
        $registerError = $_
        # 0x80073CFB: the exact same version is already registered and Windows
        # refuses to re-register it in place. That is the normal case when the
        # script is re-run to repair an install, so unregister (keeping the
        # per-user data folder) and register again.
        if ($_.Exception.Message -match '0x80073CFB') {
            Write-Note '检测到同版本已注册，先注销再注册（保留应用数据）'
            $removeParams = @{ ErrorAction = 'Stop' }
            if ((Get-Command Remove-AppxPackage).Parameters.ContainsKey('PreserveApplicationData')) {
                $removeParams['PreserveApplicationData'] = $true
            }
            try {
                foreach ($e in @(Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue)) {
                    Remove-AppxPackage -Package $e.PackageFullName @removeParams
                    Write-Ok "已注销 $($e.PackageFullName)"
                }
                Add-AppxPackage -Register $registeredManifest -ErrorAction Stop
                Write-Ok '注册成功'
                $registerError = $null
            }
            catch {
                $registerError = $_
            }
        }
    }

    if ($registerError) {
        $msg = ("注册失败：0x{0:X8} {1}" -f $registerError.Exception.HResult, (($registerError.Exception.Message -split "`r?`n")[0]))
        if ($backupDir) {
            Write-Warn2 '回滚安装目录'
            Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
            Move-Item -Path $backupDir -Destination $InstallDir -ErrorAction SilentlyContinue
            $backupDir = $null
            Write-Note '旧文件已还原；若包已被注销，重跑一次即可恢复注册。'
        }
        throw ($msg + "`n提示：确认开发者模式已启用；若提示已安装更高版本，说明所选 bundle 版本低于当前已注册版本。")
    }

    if ($backupDir -and (Test-Path $backupDir)) {
        Remove-Item -Recurse -Force $backupDir -ErrorAction SilentlyContinue
    }

    # --- Verify ------------------------------------------------------------

    Write-Step '校验'
    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if (-not $pkg) { throw '注册后查不到该包' }
    foreach ($p in $pkg) {
        Write-Ok "$($p.PackageFullName)  Status=$($p.Status)"
    }

    $pfn = (@($pkg) | Select-Object -First 1).PackageFamilyName
    $providers = @()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId')) {
        $providers = Get-ChildItem $root -ErrorAction SilentlyContinue |
                     ForEach-Object { Get-ItemProperty $_.PSPath } |
                     Where-Object { $_.DllPath -and $_.DllPath -like "*$InstallDir*" }
    }
    if ($providers) { Write-Ok "已注册 WinRT 激活类 $($providers.Count) 个" }
    else { Write-Note '未在注册表看到本包的 WinRT 激活类（部分条目按包代理注册，属正常）' }

    # --- Summary -----------------------------------------------------------

    Write-Host ''
    Write-Host '完成。' -ForegroundColor Green
    Write-Host ''
    Write-Host '  包            : ' -NoNewline; Write-Host $pfn
    Write-Host '  版本          : ' -NoNewline; Write-Host "$((@($pkg)|Select-Object -First 1).Version)"
    Write-Host '  安装位置      : ' -NoNewline; Write-Host $InstallDir
    Write-Host '  系统要求      : ' -NoNewline; Write-Host "改为 $($minOsVersion.ToString())（本机 build $osBuild）"
    Write-Host ''
    Write-Host '  验证方式：设置 > 蓝牙和其他设备 > 移动设备' -ForegroundColor DarkGray
    Write-Host '  （打开"允许此电脑访问你的移动设备"，"管理设备"按钮应可用）' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  界面语言为英文：MSIX 资源包无法在开发模式下注册，而带签名的产品包' -ForegroundColor DarkGray
    Write-Host '  又被同一个 MinVersion 门槛拦下，因此只能使用包内中性（英文）字符串。' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  卸载：.\install.ps1 -Uninstall' -ForegroundColor DarkGray
    Write-Host ''

    if ($Launch) {
        Write-Step '打开跨设备设置页'
        try { Start-Process $SettingsUri; Write-Ok $SettingsUri }
        catch { Write-Warn2 "启动失败：$($_.Exception.Message)" }
    }
}
finally {
    if (Test-Path $workRoot) { Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue }
}
