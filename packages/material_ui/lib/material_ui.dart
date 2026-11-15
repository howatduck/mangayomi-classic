// CLASSIC shim: upstream Mangayomi 0.9.96+ builds its UI on the material_ui
// package (Flutter 3.47+). The Classic toolchain (Flutter 3.32.8) ships the
// same Material library built into the SDK, so this package simply
// re-exports it. Every upstream file importing package:material_ui keeps
// working unchanged, on the previous UI structure.
export "package:flutter/material.dart";
export "package:flutter_localizations/flutter_localizations.dart";

import "package:flutter/material.dart" as _sdk;

/// In the real material_ui world this bridges old-material packages into
/// material_ui themes. Under the Classic shim there is only one Material
/// library, so the bridge is a passthrough.
class MaterialUiCompatibilityBridge extends _sdk.StatelessWidget {
  const MaterialUiCompatibilityBridge({super.key, required this.child});

  final _sdk.Widget child;

  @override
  _sdk.Widget build(_sdk.BuildContext context) => child;
}
