# UI assets

Recorded 2026-10-16. No provider data or real subscription credentials are assets.

- `images/power-disc.png`: generated from the user's selected ExVPN concept with Image Gen; graphite disc only. Transparent margins are accounted for by `PowerButton` without clipping the rim.
- `images/squirrel-mask.png`: generated from the selected outline squirrel. White-on-black luminance mask, tinted amber by Flutter. This avoids the noisy transparency in the earlier generated `squirrel.png`, which is no longer used.
- `fonts/Inter.ttf`: Inter variable font from [Google Fonts](https://github.com/google/fonts/tree/main/ofl/inter). SIL Open Font License 1.1, bundled as `fonts/OFL.txt`. SHA-256: `29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031`.
- `flags/*.png`: unmodified national flags NL/DE/FI/PL/SE/FR from [FlagCDN](https://flagcdn.com/), 160 px sources. Country is only presented when explicitly supplied by the profile name or synthetic demo fixture; no endpoint geolocation is inferred.
- Material Icons: bundled Flutter font, Google attribution; actual pinned SDK license copied to `licenses/MaterialIcons.txt` (CC BY 4.0).
- Cupertino Icons 1.0.9: [Flutter package](https://pub.dev/packages/cupertino_icons), MIT; license copied to `licenses/CupertinoIcons.txt`. Used for the thin settings outline.
- QR import: file_selector 1.1.0 and zxing2 0.2.4 (BSD-3-Clause); installed package licenses preserved as `licenses/FileSelector.txt` and `licenses/ZXing2.txt`. Synthetic QR fixtures contain no provider credentials.

All fonts, icons and flags are packaged locally; the UI does not contact font/image CDNs at runtime. The web verification build uses `--no-web-resources-cdn` to package the Flutter renderer locally as well.
