import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:win32_registry/win32_registry.dart';

import 'protocol.dart';

// CLASSIC: adapted to win32_registry 2.1 API (createKey/createValue/deleteKey).
final _hive = Registry.currentUser;

class WindowsProtocolHandler extends ProtocolHandler {
  @override
  void register(String scheme, {String? executable, List<String>? arguments}) {
    if (defaultTargetPlatform != TargetPlatform.windows) return;

    final prefix = _regPrefix(scheme);
    final capitalized = scheme[0].toUpperCase() + scheme.substring(1);
    final cmd =
        '${executable ?? Platform.resolvedExecutable} ${getArguments(arguments).map(_sanitize).join(' ')}';

    final rootKey = _hive.createKey(prefix);
    rootKey.createValue(RegistryValue.string('', 'URL:$capitalized'));
    rootKey.createValue(RegistryValue.string('URL Protocol', ''));
    rootKey
        .createKey(r'shell\open\command')
        .createValue(RegistryValue.string('', cmd));
  }

  @override
  void unregister(String scheme) {
    if (defaultTargetPlatform != TargetPlatform.windows) return;

    _hive.deleteKey(_regPrefix(scheme));
  }

  String _regPrefix(String scheme) => r'SOFTWARE\Classes\$scheme';

  String _sanitize(String value) {
    value = value.replaceAll(r'%s', '%1').replaceAll(r'"', '\\"');
    return '"$value"';
  }
}
