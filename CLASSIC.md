# Mangayomi Classic — Android 6.0 (API 23) edition

A fork of [kodjodevf/mangayomi](https://github.com/kodjodevf/mangayomi) (Apache-2.0)
rebuilt so it can run on **Android 6.0 (API 23)** devices, which upstream no longer
supports (upstream requires API 24+ and a current Flutter toolchain).

Target reference device: Verizon Ellipsis 8 HD (Snapdragon 617 / Adreno 405,
3 GB RAM, Android 6.0.1, Linux kernel 3.10.84).

All changes live on the `classic` branch and are marked with `// CLASSIC`
comments where practical. Upstream code is otherwise untouched in behaviour.

## Downgrade stack

| Component | Upstream | Classic |
|---|---|---|
| Flutter / Dart | 3.47 / 3.13 | **3.32.8 / 3.8** (last line supporting API 23) |
| AGP / Kotlin / Gradle / JDK | 9.1 / 2.4 / 9.3 / 21 | **8.9.1 / 2.2.20 / 8.12 / 17** |
| compileSdk / targetSdk / minSdk | 36 / 36 / 24 | **36 / 35 / 23** |
| flutter_rust_bridge | 2.13.0 | **2.12.0** (bindings regenerated with codegen 2.12.0) |

## Key adaptations

- **minSdk 23 via an ext variable** (`classicMinSdkVersion`): a literal `23`
  in `build.gradle` is rewritten by Flutter's MinSdkVersionMigration, so the
  value is routed through an `ext` property.
- **Impeller disabled** in the manifest (`EnableImpeller=false`): the Adreno
  405 has no Vulkan; Skia is forced.
- **Dependency pins** (`dependency_overrides` in `pubspec.yaml`, each with a
  comment): hosted `package_info_plus` 9.0.1 / `device_info_plus` 12.3.0
  instead of the upstream git forks (they declare language version 3.10),
  `flutter_secure_storage` 10.2.0 + windows 4.1.0, `flutter_tts` 4.2.3
  (4.2.5 declares minSdk 24), `meta` 1.17.0, plus a Dart-3.8-compatible set
  resolved for the rest.
- **Codegen dev-dependencies dropped** (build_runner / riverpod_generator /
  isar generator / freezed 4.x): generated code is committed; only
  `freezed` 3.2.5 + `build_runner` remain because flutter_rust_bridge_codegen
  checks for their presence when regenerating the Rust bindings.
- **`m_extension_server` vendored** under `packages/` (the upstream git
  package requires Dart ≥ 3.13); its Android minSdk is lowered to 23.
  `flutter_qjs` is pinned to the last Dart-3.8-compatible commit.
- **Dart 3.8 / Flutter 3.32 back-ports**: riverpod `.g.dart` `runBuild`
  patched to the 3.3.2-dev.2 runtime shape, file_picker 11 API shim
  (`lib/classic/file_picker_classic.dart`, `lockParentWindow`, `.files`),
  private named parameters (a Dart 3.10 feature) rewritten with
  initializers, `Matrix4` ByDouble → translate/scale, `ReorderableListView`
  `onReorderItem` → `onReorder` with index adjustment, `RadioGroup` →
  per-tile radios, `desktop_webview_window` 0.3.2 API in the Linux webview
  screen, win32_registry 2.1 API, local_auth 2.3 options, shiori
  `minTileHeight` dropped.
- **Native assets hook removed**: Flutter 3.32 stable cannot enable native
  assets (master-only), so `lib/ffi/image_decoder.cpp` is prebuilt with the
  NDK into `android/app/src/main/jniLibs/` (see the CI workflow).

## The kernel gate patch (required on kernels < 3.16)

Isar's libmdbx refuses to open a database on Linux kernels older than 3.16
(`MDBX_INCOMPATIBLE` from `mdbx_env_create`), and the reference tablet runs
kernel 3.10.84. `tool/patch_isar_kernel_gate.py` NOPs the two version-check
branches inside the APK's `libisar.so` (byte patterns asserted; isar 3.4.1
arm64 only). Apply it to the built APK, then zipalign and re-sign:

```sh
python3 tool/patch_isar_kernel_gate.py app-release.apk mangayomi-classic.apk
zipalign -f 4 mangayomi-classic.apk mangayomi-classic-aligned.apk
apksigner sign --ks <keystore> mangayomi-classic-aligned.apk
```

On devices with kernel ≥ 3.16 the unpatched APK works as-is.

## Building

Either dispatch the **Mangayomi Classic Build** GitHub Actions workflow, or
locally with Flutter 3.32.8 + JDK 17 + Android SDK (platforms 35/36,
build-tools 35, NDK 26.3) + Rust Android targets:

```sh
flutter pub get
# prebuild the subsampling native lib (commands in the workflow file)
# write android/local.properties (sdk.dir, flutter.sdk, buildMode, version)
# write android/key.properties pointing at any keystore (release signing)
cd android && ./gradlew :app:assembleRelease -Ptarget-platform=android-arm,android-arm64
```

## On-device verification (2026-11-11)

The patched release APK was installed on the reference tablet: the app
boots to its UI, Isar opens (library scan runs), and no startup error is
shown. Performance on Snapdragon 617 / 3 GB is usable but heavy.
