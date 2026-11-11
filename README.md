# Pica Comic

[![flutter](https://img.shields.io/badge/flutter-3.41.6-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/longer-sausage/PicaComic)](https://github.com/longer-sausage/PicaComic/blob/master/LICENSE)
[![Download](https://img.shields.io/github/v/release/longer-sausage/PicaComic)](https://github.com/longer-sausage/PicaComic/releases)
[![stars](https://img.shields.io/github/stars/longer-sausage/PicaComic)](https://github.com/longer-sausage/PicaComic/stargazers)

A comic app with multiple sources built with flutter.

**Forked from [nyne](https://github.com/wgh136), provide extended support & fix, no guaranteed roadmap.**

## Download

<a href="https://github.com/longer-sausage/PicaComic/releases">
<img src="https://user-images.githubusercontent.com/69304392/148696068-0cfea65d-b18f-4685-82b5-329a330b1c0d.png"
alt="Get it on GitHub" align="center" height="80" /></a>

<a href="https://github.com/longer-sausage/PicaComic/blob/master/INSTALL.md#obtainium">
<img src="https://github.com/ImranR98/Obtainium/blob/main/assets/graphics/badge_obtainium.png"
alt="Get it on Obtainium" align="center" height="54" />
</a>

An [AUR package](https://aur.archlinux.org/packages/pica-comic-bin) is packed by [Lilinzta](https://github.com/Lilinzta):
```shell
paru -S pica-comic-bin
```

## Build

1. Clone the repository
```shell
git clone https://github.com/longer-sausage/PicaComic
```
2. Install flutter: https://docs.flutter.dev/get-started/install
3. Build Application: https://docs.flutter.dev/deployment

### Automated releases

Pushing a new or updated Git tag runs `.github/workflows/release.yml`. It builds
Android APKs (arm64, x86_64 and universal), a Windows x64 ZIP, a Linux x64 tarball,
an unsigned iOS IPA, and a macOS ZIP with Flutter 3.41.6. Once every build succeeds,
the packages are published to the tag's GitHub Release with an empty body.
Re-running the workflow or updating the same tag replaces the generated packages,
removes obsolete package filenames, and clears the release body. Deleting a tag
does not publish a release.
The tag is the source of the application version on every platform. Use
`vMAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH`, for example `v1.0.1`. Before building,
the workflow synchronizes `pubspec.yaml`, the in-app version display and update
checker, native application metadata, and every package filename with the tag
(without its optional `v` prefix). Invalid version tags fail before compilation.
The separate numeric build number after `+` in `pubspec.yaml` is preserved.

Configure these repository secrets under **Settings > Secrets and variables >
Actions** before the first release, using the same Android signing key as local
release builds:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded contents of the release keystore |
| `ANDROID_STORE_PASSWORD` | Keystore password (`storePassword`) |
| `ANDROID_KEY_ALIAS` | Signing key alias (`keyAlias`) |
| `ANDROID_KEY_PASSWORD` | Signing key password (`keyPassword`) |

After committing the changes, publish a version tag; no manual version edits are
needed for automated releases:

```shell
git tag v1.0.1
git push origin v1.0.1
```

For a local build at the same version, run
`python .github/scripts/set_release_version.py v1.0.1` before building.

## Introduction

### Built-in Comic Source

Pica Comic has 6 built-in comic sources:
- picacg
- e-hentai/exhentai
- jmcomic
- hitomi
- htcomic
- nhentai

### Features

- Browse manga
- Online reading
- Download manga
- Manage local favorites and network favorites
- Data sync(using webdav)
- Reading history

### History

This project initially started as an unofficial app for picacg
and later evolved into an app that supports multiple comic sources.

## Thanks

### Projects
[![Readme Card](https://github-readme-stats.vercel.app/api/pin/?username=tonquer&repo=JMComic-qt)](https://github.com/tonquer/JMComic-qt)

The image restructuring algorithm used to display jm images is from this project.

### Tags Translation
[![Readme Card](https://github-readme-stats.vercel.app/api/pin/?username=EhTagTranslation&repo=Database)](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.
