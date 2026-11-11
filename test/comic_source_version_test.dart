import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/def.dart';

void main() {
  test('upstream sources remain compatible after fork release version reset',
      () {
    for (final version in ['3.1.0', '4.0.0', '4.2.10', comicSourceApiVersion]) {
      expect(() => ComicSourceParser.validateMinAppVersion(version),
          returnsNormally,
          reason: version);
    }
  });

  test('an omitted or empty minimum version imposes no requirement', () {
    for (final version in [null, '', '  \n\t']) {
      expect(() => ComicSourceParser.validateMinAppVersion(version),
          returnsNormally);
    }
  });

  test('whitespace, prereleases and build metadata are accepted', () {
    for (final version in [
      ' 3.1.0 ',
      '3.1.0-beta.2',
      '$comicSourceApiVersion-beta.1',
      '$comicSourceApiVersion+build.7',
      '3.1.0-beta.2+build.7',
    ]) {
      expect(() => ComicSourceParser.validateMinAppVersion(version),
          returnsNormally,
          reason: version);
    }
  });

  test('requirements beyond the implemented API still fail clearly', () {
    for (final version in ['4.2.12', '4.3.0', '5.0.0', '5.0.0-beta.1']) {
      expect(
        () => ComicSourceParser.validateMinAppVersion(version),
        throwsA(isA<ComicSourceParseException>().having(
          (error) => error.message,
          'message',
          allOf(contains('minAppVersion $version is required'),
              contains('supported comic source API: $comicSourceApiVersion')),
        )),
      );
    }
  });

  test('invalid metadata produces a source error instead of a parsing crash',
      () {
    for (final version in <Object>[
      3.1,
      true,
      ['3.1.0'],
      'invalid',
      '3',
      '3.1',
      '3.1.x',
      '5',
      '5.0.0.1',
      '3.1.0-',
      '3.1.0-beta..1',
      '3.1.0+',
      '3.1.0+build..1',
    ]) {
      expect(
        () => ComicSourceParser.validateMinAppVersion(version),
        throwsA(isA<ComicSourceParseException>().having(
          (error) => error.message,
          'message',
          startsWith('Invalid minAppVersion:'),
        )),
        reason: '$version',
      );
    }
  });
}
