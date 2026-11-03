# Location-only launcher. The selected SDK owns build and component policy.
$ErrorActionPreference='Stop'
$settings=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Settings.R4S'))
$match=[regex]::Match($settings,'(?m)^SDK_ROOT=([^\r\n]+)')
if(!$match.Success){throw 'SDK_ROOT is missing.'}
$sdk=[IO.Path]::GetFullPath($match.Groups[1].Value.Replace('\','/'),$PSScriptRoot)
$forward=@{ModuleRoot=$PSScriptRoot;BuildArguments=@($args)}
& (Join-Path $sdk 'Tools/BuildModule.ps1') @forward
exit $LASTEXITCODE
