# SPDX-License-Identifier: Apache-2.0
# Render our existing Inter wordmark as vector paths, with the existing app icon.
# No new font, logo, runtime dependency or system font installation is required.
#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Add-Type -AssemblyName PresentationCore, WindowsBase
$fontDirectory = Join-Path $repository 'apps/exvpn/assets/fonts/'
$family = [Windows.Media.FontFamily]::new([Uri]::new($fontDirectory), './#Inter')
$typeface = [Windows.Media.Typeface]::new($family, [Windows.FontStyles]::Normal,
    [Windows.FontWeights]::Medium, [Windows.FontStretches]::Normal)
$text = [Windows.Media.FormattedText]::new('ExVPN', [Globalization.CultureInfo]::InvariantCulture,
    [Windows.FlowDirection]::LeftToRight, $typeface, 46, [Windows.Media.Brushes]::White, 1.0)
$geometry = $text.BuildGeometry([Windows.Point]::new(121, 59)).GetFlattenedPathGeometry()
$path = $geometry.ToString([Globalization.CultureInfo]::InvariantCulture) -replace '^F[01]\s*', ''
$xml = @"
<!-- SPDX-License-Identifier: Apache-2.0; generated from the app's OFL Inter font. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="160dp" android:height="90dp" android:viewportWidth="320" android:viewportHeight="180">
    <path android:fillColor="#F7F6F3" android:pathData="$path" />
</vector>
"@
$destination = Join-Path $repository 'apps/exvpn/android/app/src/main/res/drawable/tv_banner_wordmark.xml'
[IO.File]::WriteAllText($destination, $xml.Replace("`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
Write-Host 'Generated vector TV wordmark from the existing licensed Inter font.'
