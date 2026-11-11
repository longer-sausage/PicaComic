import 'package:html/parser.dart';

/// Parsing shared by the website login and the comic requests.
class HtMangaParser {
  static String resolveUrl(String value, String baseUrl) {
    value = value.trim().replaceFirstMapped(
          RegExp(r'^(https?:)/{2,}'),
          (match) => '${match[1]}//',
        );
    if (value.startsWith('//')) {
      value = value.replaceFirst(RegExp(r'^/+'), '//');
    }
    final uri = Uri.parse(baseUrl).resolve(value);
    if (!uri.hasAuthority || !['http', 'https'].contains(uri.scheme)) {
      throw const FormatException('Invalid image URL');
    }
    return uri.toString();
  }

  static bool requiresLogin(String html) {
    final document = parse(html);
    if (document.querySelector('#login_form') != null) return true;
    final notice =
        document.querySelector('.title_c')?.text.replaceAll(RegExp(r'\s+'), '');
    return notice != null &&
        ['需要登錄', '需要登录', '請先登錄', '请先登录'].any(notice.contains);
  }

  static bool isAuthenticated(String html) =>
      parse(html).querySelector('a[href*="users-logout"]') != null;

  static List<String> galleryImages(String source, String baseUrl) {
    // The gallery endpoint returns JavaScript containing document.writeln calls.
    // Decode the string literals first so signatures and escaped '&' survive.
    final writes = _readStrings(
      source,
      RegExp(r'document\.write(?:ln)?\(\s*"'),
      suffix: RegExp(r'\s*\)'),
    ).toList();
    if (writes.isNotEmpty) {
      source = writes.join('\n');
    }
    final list = RegExp(
      r'\bimglist\s*=\s*(\[[\s\S]*?\])\s*;',
    ).firstMatch(source)?[1];
    if (list == null) {
      throw const FormatException('未获取到漫画图片');
    }
    final urls = _readStrings(
      list,
      RegExp(r'''\burl\s*:\s*(?:fast_img_host\s*\+\s*)?["']'''),
    );
    final images = <String>{};
    for (final value in urls) {
      final url = resolveUrl(value, baseUrl);
      final path = Uri.parse(url).path;
      if (RegExp(
            r'\.(?:jpe?g|png|gif|webp|avif)$',
            caseSensitive: false,
          ).hasMatch(path) &&
          !path.startsWith('/themes/') &&
          !path.startsWith('/statics/')) {
        images.add(url);
      }
    }
    if (images.isEmpty) {
      throw const FormatException('未获取到漫画图片');
    }
    return images.toList();
  }

  static Iterable<String> _readStrings(String source, RegExp prefix,
      {RegExp? suffix}) sync* {
    // Prefixes end at the opening quote. Scan the body iteratively: repeated
    // regex alternatives can overflow the AOT regex stack on large galleries.
    var offset = 0;
    for (final match in prefix.allMatches(source)) {
      if (match.start < offset) continue;
      final start = match.end - 1;
      final quote = source.codeUnitAt(start);
      var end = start + 1;
      while (end < source.length && source.codeUnitAt(end) != quote) {
        if (source.codeUnitAt(end) == 0x5c) end++;
        end++;
      }
      if (end >= source.length) {
        throw const FormatException('Unterminated JavaScript string');
      }
      offset = end + 1;
      if (suffix == null || suffix.matchAsPrefix(source, offset) != null) {
        yield _decodeString(source.substring(start, offset));
      }
    }
  }

  static String _decodeString(String literal) {
    // JavaScript permits literal tabs and escapes such as \x26 and \', which
    // are not valid JSON. Decode string literals without executing JS.
    final result = StringBuffer();
    const escapes = {
      'n': '\n',
      'r': '\r',
      't': '\t',
      'b': '\b',
      'f': '\f',
      'v': '\v'
    };
    for (var i = 1; i < literal.length - 1; i++) {
      var character = literal[i];
      if (character == r'\') {
        character = literal[++i];
        if (character == 'x' || character == 'u') {
          final length = character == 'x' ? 2 : 4;
          result.writeCharCode(
              int.parse(literal.substring(i + 1, i + 1 + length), radix: 16));
          i += length;
          continue;
        }
        character = escapes[character] ?? character;
      }
      result.write(character);
    }
    return result.toString();
  }
}
