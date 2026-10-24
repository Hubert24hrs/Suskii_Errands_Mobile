# Creates the fixed signing key for the test APK (RB-15 action 32), on your own computer, so the
# key never passes through anyone else's hands. Run it once, put the four values it prints into
# GitHub (Settings -> Secrets and variables -> Actions), and keep the folder it writes somewhere
# safe: lose the key and the next test APK cannot install over the old one.
#
# This is the TEST key for the demo APK only. It is not the Play upload key (RB-15 action 20).
#
#   powershell -ExecutionPolicy Bypass -File apps\mobile\tool\new_test_key.ps1
#
# Needs keytool, which comes with any JDK and with Android Studio (its bundled "jbr" folder).

param(
  [string]$OutDir = (Join-Path $HOME 'suskii-test-key'),
  [string]$Alias = 'suskii-test'
)
$ErrorActionPreference = 'Stop'

function Find-Keytool {
  $onPath = Get-Command keytool -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  $candidates = @()
  if ($env:JAVA_HOME) { $candidates += (Join-Path $env:JAVA_HOME 'bin\keytool.exe') }
  $candidates += @(
    "$env:ProgramFiles\Android\Android Studio\jbr\bin\keytool.exe",
    "$env:ProgramFiles\Android\Android Studio\jre\bin\keytool.exe",
    "$env:LOCALAPPDATA\Programs\Android Studio\jbr\bin\keytool.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  throw 'keytool not found. Install Android Studio or a JDK (for example Temurin 17), then run this again.'
}

$keytool = Find-Keytool
$keystore = Join-Path $OutDir 'suskii-test.jks'
if (Test-Path $keystore) {
  throw "$keystore already exists. Reuse it, or move it away first: a new key means one more uninstall on the phone."
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# One password for the store and the key: a PKCS12 keystore holds a single password for both.
$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = [Convert]::ToBase64String($bytes).Replace('+', 'A').Replace('/', 'B').Replace('=', '')

& $keytool -genkeypair -noprompt -keystore $keystore -storetype PKCS12 -alias $Alias `
  -keyalg RSA -keysize 2048 -validity 10000 -storepass $password -keypass $password `
  -dname 'CN=Suskii Test, O=Suskii Errands, C=NG'
if ($LASTEXITCODE -ne 0) { throw 'keytool could not create the key.' }

$base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($keystore))
$base64File = Join-Path $OutDir 'ANDROID_DEV_KEYSTORE_BASE64.txt'
Set-Content -Path $base64File -Value $base64 -NoNewline
$base64 | Set-Clipboard

$fingerprints = (& $keytool -list -v -keystore $keystore -alias $Alias -storepass $password) -join "`n"
$sha1 = if ($fingerprints -match 'SHA1:\s*([0-9A-F:]+)') { $Matches[1] } else { '(run keytool -list -v to see it)' }

Write-Host ''
Write-Host "Key created in $OutDir. Keep that folder; never put it in the repository." -ForegroundColor Green
Write-Host ''
Write-Host 'Add these four repository secrets in GitHub (Settings -> Secrets and variables -> Actions):'
Write-Host "  ANDROID_DEV_KEYSTORE_BASE64   already on your clipboard (also in $base64File)"
Write-Host "  ANDROID_DEV_KEYSTORE_PASSWORD $password"
Write-Host "  ANDROID_DEV_KEY_ALIAS         $Alias"
Write-Host "  ANDROID_DEV_KEY_PASSWORD      $password"
Write-Host ''
Write-Host 'For the Google Maps key restriction (Android apps):'
Write-Host '  Package name                  com.suskiierrands.app.dev'
Write-Host "  SHA-1 certificate fingerprint $sha1"
