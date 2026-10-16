# Microsoft C++ runtime in the Windows package

ExVPN's own source is Apache-2.0. The three unmodified app-local Microsoft DLLs
are separate proprietary redistributable components and are not relicensed under
Apache-2.0. They are not copied from Windows System32 or from debug/preview tools.

- Files: `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll` (x64).
- File version: **14.51.36247.0**, release toolset directory **14.51.36231**.
- Source: official Visual Studio Community **18.7.11903.348**, `isPrerelease=false`,
  `VC/Redist/MSVC/14.51.36231/x64/Microsoft.VC145.CRT`.
- Each file's SHA-256 is pinned in `scripts/windows/msvc-runtime.lock.json`; the
  builder also checks Microsoft Authenticode and every packaged PE's CRT imports.
- Copyright Microsoft Corporation. All rights reserved.

The [Visual Studio 2026 redistribution list](https://learn.microsoft.com/en-us/visualstudio/releases/2026/redistribution)
lists the release files under `VC/redist`, subject to the software license terms.
The full [Visual Studio Community 2026 terms](https://visualstudio.microsoft.com/license-terms/vs2026-ga-community/)
are preserved in `Microsoft-Visual-Studio-2026-Community.txt`, including the original
DOCX URL and SHA-256. This is a developer test artifact. External distribution must
satisfy those terms, including protection of Distributable Code in distributor/end
user terms; a generic Apache notice does not replace these obligations.

The installer places these files only beside ExVPN in its protected directory.
It does not install, replace, or remove any system-wide Microsoft runtime. Windows
10/11 supplies UCRT/API-set system components. A clean guest UI launch is still
required before claiming the package has all runtime requirements.
