import 'dart:async';
import 'dart:convert';

import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/pages/webview.dart';
import 'package:pica_comic/tools/translations.dart';

class HtMangaWebSession {
  const HtMangaWebSession(this.cookies, this.userAgent);

  final Map<String, String> cookies;
  final String userAgent;
}

/// Let the website perform its own slider verification and login submission.
Future<HtMangaWebSession?> htMangaWebLogin(
  String baseUrl,
  String account,
  String password,
) async {
  await setNetworkProxy();
  final origin = Uri.parse(baseUrl);
  final loginUrl = origin.resolve('/users-login.html').toString();
  final logoutUrl = origin.resolve('/users-logout.html').toString();
  final favoritesUrl = origin.resolve('/users-users_fav.html').toString();
  final result = Completer<HtMangaWebSession?>();
  Timer? timer;
  var checking = false;
  var loginOpened = false;

  void cancel() {
    timer?.cancel();
    if (!result.isCompleted) result.complete(null);
  }

  Future<void> check(
    Future<dynamic> Function(String) evaluate,
    Future<Map<String, String>> Function() getCookies,
    void Function() close,
  ) async {
    if (checking || result.isCompleted) return;
    checking = true;
    try {
      dynamic state = await evaluate('''
        ({url: location.href, ready: document.readyState,
          authenticated: !!document.querySelector('a[href*="users-logout"]'),
          userAgent: navigator.userAgent})
      ''');
      // Desktop WebView returns JSON; the mobile plugin returns an object.
      if (state is String) state = jsonDecode(state);
      if (state is! Map ||
          !['interactive', 'complete'].contains(state['ready'])) {
        return;
      }
      final uri = Uri.tryParse(state['url'] as String? ?? '');
      if (uri?.origin != origin.origin) return;
      if (!loginOpened) {
        // Clear the previous browser account before accepting a new login.
        loginOpened = true;
        await evaluate('location.replace(${jsonEncode(loginUrl)});');
        return;
      }
      if (state['authenticated'] == true) {
        final cookies = await getCookies();
        if (result.isCompleted) return;
        if (cookies.isEmpty) return;
        result.complete(
          HtMangaWebSession(cookies, state['userAgent'] as String),
        );
        close();
        return;
      }
      if (uri?.path != '/users-login.html') return;
      await evaluate('''
        (function() {
          var form = document.getElementById('login_form');
          if (!form || form.dataset.picaLogin || !window.Mui || !Mui.box ||
              !Mui.form || !Mui.form.sendAuto) return;
          // The website normally submits from a popup. Give its successful
          // login callback a destination when opened as a standalone page.
          Mui.box.callback = function() {
            location.replace(${jsonEncode(favoritesUrl)});
          };
          form.dataset.picaLogin = '1';
          form.querySelector('[name="login_name"]').value = ${jsonEncode(account)};
          form.querySelector('[name="login_pass"]').value = ${jsonEncode(password)};
          form.querySelector('[type="submit"]').click();
        })();
      ''');
    } catch (_) {
      // Navigation can destroy the JavaScript context. Retry on the next page.
    } finally {
      checking = false;
    }
  }

  try {
    if (App.isDesktop && await DesktopWebview.isAvailable()) {
      final webview = DesktopWebview(
        initialUrl: logoutUrl,
        onTitleChange: (_, controller) => check(
          controller.evaluateJavascript,
          () => controller.getCookies('$baseUrl/'),
          controller.close,
        ),
        onClose: cancel,
      );
      await webview.open();
    } else if (App.isMobile) {
      final route = App.globalTo(
        () => AppWebview(
          initialUrl: logoutUrl,
          singlePage: true,
          // The app parses desktop HTML and checks its authenticated menu.
          // Keep the browser and subsequent HTTP requests on that template.
          userAgent: webUA,
          onStarted: (controller) {
            if (result.isCompleted) return;
            timer = Timer.periodic(const Duration(seconds: 1), (_) {
              check(
                (source) => controller.evaluateJavascript(source: source),
                () async => await controller.getCookies('$baseUrl/') ?? {},
                () => App.globalBack(),
              );
            });
          },
        ),
      );
      unawaited(route.whenComplete(cancel));
    } else {
      throw UnsupportedError('当前设备不支持'.tl);
    }
    showToast(message: '请在网页中完成滑块验证'.tl);
    return await result.future;
  } finally {
    timer?.cancel();
  }
}
