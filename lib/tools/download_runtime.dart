import 'dart:async';

import 'package:flutter/services.dart';

/// Keeps the download process running without requiring the screen to stay on.
/// Platform calls are ordered so a late stop cannot undo a subsequent start.
class DownloadRuntime {
  static const channel =
      MethodChannel('com.github.pacalini.pica_comic/download');

  final Future<void> Function() onExpired;
  final void Function(Object, StackTrace) onError;
  Future<void> _pending = Future.value();

  DownloadRuntime({required this.onExpired, required this.onError}) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'expired') {
        await onExpired();
      }
    });
  }

  Future<void> start({required String title, required String content}) =>
      _invoke('start', {'title': title, 'content': content});

  Future<void> stop({Future<void>? after}) => _invoke('stop', null, after);

  Future<void> _invoke(String method,
      [Map<String, Object>? arguments, Future<void>? after]) {
    return _pending = _pending.then((_) async {
      if (after != null) {
        try {
          await after;
        } catch (e, s) {
          onError(e, s);
        }
      }
      try {
        await channel.invokeMethod<void>(method, arguments);
      } catch (e, s) {
        // A denied power-management request must not prevent downloading.
        onError(e, s);
      }
    });
  }
}
