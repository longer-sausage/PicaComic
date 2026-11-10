import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/search_query.dart';
import 'package:pica_comic/foundation/search_query_controller.dart';
import 'package:pica_comic/network/hitomi_network/search.dart';

void main() {
  const hair = SearchTag('long hair', namespace: 'female');
  const glasses = SearchTag('glasses', namespace: 'male');

  test('typing search syntax never turns it into tags', () {
    final editor =
        SearchQueryController(text: 'female:glasses language:english');
    addTearDown(editor.dispose);
    editor.configureLanguageFilter(enabled: true, defaultLanguage: 'chinese');
    expect(editor.tags, isEmpty);
    expect(editor.query.text, 'female:glasses language:english');
    expect(editor.query.keywordFor('ehentai'), editor.query.text);
  });

  test('a suggestion replaces a multiword fragment and preserves free text',
      () {
    final editor = SearchQueryController(text: 'ordinary words long ha');
    addTearDown(editor.dispose);
    editor.selectSuggestion(hair, translation: '长发');
    expect(editor.textController.text, 'ordinary words ');
    expect(editor.tags, [hair]);
    expect(editor.query.keywordFor('ehentai'),
        'female:"long hair" ordinary words');
    editor.removeTag(hair);
    expect(editor.query.text, 'ordinary words ');
    expect(editor.tags, isEmpty);
  });

  test('suggestions replace the token at the caret without losing later words',
      () {
    final editor = SearchQueryController(text: 'before glasse after');
    addTearDown(editor.dispose);
    editor.textController.selection = const TextSelection.collapsed(offset: 9);
    expect(editor.suggestionText, 'gl');
    editor.selectSuggestion(glasses);
    expect(editor.query.text, 'before  after');
    expect(editor.tags, [glasses]);
    expect(editor.textController.selection.baseOffset, 7);
  });

  test('a selected fragment and Chinese suggestions preserve surrounding input',
      () {
    final editor = SearchQueryController(text: 'before 长发 after');
    addTearDown(editor.dispose);
    editor.textController.selection =
        const TextSelection(baseOffset: 7, extentOffset: 9);
    editor.selectSuggestion(hair, translation: '长发');
    expect(editor.query.text, 'before  after');
    expect(editor.tags, [hair]);
  });

  test('IME composing text does not generate suggestions', () {
    final editor = SearchQueryController();
    addTearDown(editor.dispose);
    editor.textController.value = const TextEditingValue(
      text: 'changfa',
      selection: TextSelection.collapsed(offset: 7),
      composing: TextRange(start: 0, end: 7),
    );
    expect(editor.suggestionText, isEmpty);
  });

  test('default language is visible, replaceable, and stays removed on submit',
      () {
    final editor = SearchQueryController(text: 'words');
    addTearDown(editor.dispose);
    editor.configureLanguageFilter(enabled: true, defaultLanguage: 'chinese');
    expect(editor.tags, [const SearchTag('chinese', namespace: 'language')]);
    editor.setLanguage('japanese');
    expect(editor.query.keywordFor('nhentai'), 'language:japanese words');
    editor.removeTag(editor.tags.single);
    editor.configureLanguageFilter(enabled: true, defaultLanguage: 'chinese');
    expect(editor.tags, isEmpty);
    final results = SearchQueryController(query: editor.query);
    addTearDown(results.dispose);
    results.configureLanguageFilter(enabled: true, defaultLanguage: 'chinese');
    expect(results.query.keywordFor('ehentai'), 'words');
  });

  test('unsupported sources have no hidden language filter', () {
    final editor = SearchQueryController();
    addTearDown(editor.dispose);
    editor.configureLanguageFilter(enabled: false, defaultLanguage: 'chinese');
    expect(editor.tags, isEmpty);
    editor.configureLanguageFilter(enabled: true, defaultLanguage: 'chinese');
    editor.configureLanguageFilter(enabled: false);
    expect(editor.tags, isEmpty);
    editor.configureLanguageFilter(enabled: true);
    expect(editor.language, 'chinese');
    editor.setLanguage(null);
    editor.configureLanguageFilter(enabled: false);
    editor.configureLanguageFilter(enabled: true, defaultLanguage: 'chinese');
    expect(editor.tags, isEmpty);
  });

  test('typed language replaces the system filter while remaining plain text',
      () {
    final editor = SearchQueryController();
    addTearDown(editor.dispose);
    editor.configureLanguageFilter(enabled: true, defaultLanguage: 'chinese');
    editor.textController.text = 'language:english';
    expect(editor.tags, isEmpty);
    expect(editor.query.text, 'language:english');
  });

  test(
      'the language selector replaces typed filters without consuming other input',
      () {
    final editor = SearchQueryController(text: 'words language:english more');
    addTearDown(editor.dispose);
    editor.configureLanguageFilter(enabled: true, defaultLanguage: 'chinese');
    editor.setLanguage('japanese');
    expect(editor.query.text, 'words  more');
    expect(editor.language, 'japanese');
    editor.textController.selection = const TextSelection.collapsed(offset: 0);
    expect(editor.language, 'japanese');
    expect(editor.query.keywordFor('ehentai'), 'language:japanese words  more');
  });

  test('a language suggestion replaces an earlier typed language condition',
      () {
    final editor = SearchQueryController(text: 'words language:english jap');
    addTearDown(editor.dispose);
    editor.configureLanguageFilter(enabled: true);
    editor.selectSuggestion(const SearchTag('japanese', namespace: 'language'));
    expect(editor.query.text, 'words  ');
    expect(editor.language, 'japanese');
  });

  test('language-like words inside quoted phrases are still ordinary text', () {
    final editor = SearchQueryController(text: '"words language:english more"');
    addTearDown(editor.dispose);
    editor.configureLanguageFilter(enabled: true, defaultLanguage: 'chinese');
    expect(editor.language, 'chinese');
    editor.setLanguage('japanese');
    expect(editor.query.text, '"words language:english more"');
  });

  test('restoring tags notifies even when the editable text has not changed',
      () {
    final editor = SearchQueryController(query: SearchQuery());
    addTearDown(editor.dispose);
    editor.restore(SearchQuery());
    var updates = 0;
    editor.addListener(() => updates++);
    editor.restore(SearchQuery(tags: [hair]));
    expect(updates, 1);
    editor.selectSuggestion(glasses);
    expect(updates, 2);
    expect(editor.tags, [hair, glasses]);
    editor.selectSuggestion(glasses);
    expect(editor.tags, [hair, glasses]);
  });

  test('queries use the target source syntax', () {
    final query = SearchQuery(
        tags: [hair, const SearchTag('chinese', namespace: 'language')]);
    expect(query.keywordFor('ehentai'), 'female:"long hair" language:chinese');
    expect(query.keywordFor('nhentai'), 'female:"long hair" language:chinese');
    expect(query.keywordFor('hitomi'), 'female:long_hair language:chinese');
    expect(hair.keywordFor('jm'), 'long hair');
    expect(
        const SearchTag('test series', namespace: 'parody')
            .keywordFor('hitomi'),
        'series:test_series');
  });

  test('clicked source tags retain namespace and quoted values', () {
    expect(SearchTag.fromKeyword('female:"long hair"', sourceKey: 'ehentai'),
        hair);
    expect(
        SearchTag.fromKeyword('female:long_hair', sourceKey: 'hitomi'), hair);
    final plain = SearchTag.fromKeyword('text:literal', sourceKey: 'jm');
    expect(plain.namespace, isNull);
    expect(plain.keywordFor('jm'), 'text:literal');
  });

  test('Hitomi language searches keep the full gender tag', () async {
    final search = _RecordingHitomiSearch();
    await search.getGalleryIdsForTermAndLanguage('female:long hair', 'chinese');
    expect(search.request, ('tag', 'female:long hair', 'chinese'));
    await search.getGalleryIdsForTermAndLanguage('male:glasses', 'japanese');
    expect(search.request, ('tag', 'male:glasses', 'japanese'));
  });

  test('favorites retain text, tag metadata and independent option snapshots',
      () {
    final options = ['recent'];
    final editor = SearchQueryController(text: 'manual long ha');
    addTearDown(editor.dispose);
    editor.selectSuggestion(hair);
    final saved = SavedSearch(
        sourceKey: 'ehentai', query: editor.query, options: options);
    options[0] = 'popular';
    editor.clear();
    final restored = SavedSearch.fromJson(jsonDecode(jsonEncode(saved)));
    expect(restored, saved);
    expect(restored.query.tags, [hair]);
    expect(restored.query.text, 'manual ');
    expect(restored.options, ['recent']);
    expect(() => restored.query.tags.clear(), throwsUnsupportedError);
    expect(() => restored.options.clear(), throwsUnsupportedError);
  });

  test('deduplication is source- and option-specific and ignores tag order',
      () {
    final query = SearchQuery(text: ' words ', tags: [hair, glasses]);
    final a =
        SavedSearch(sourceKey: 'ehentai', query: query, options: ['recent']);
    final same = SavedSearch(
        sourceKey: 'ehentai',
        query: SearchQuery(text: 'words', tags: [glasses, hair]),
        options: ['recent']);
    final b =
        SavedSearch(sourceKey: 'nhentai', query: query, options: ['recent']);
    final c =
        SavedSearch(sourceKey: 'ehentai', query: query, options: ['popular']);
    expect(a, same);
    expect(a.hashCode, same.hashCode);
    expect(a, isNot(b));
    expect(a, isNot(c));
    expect(
        SavedSearch.decodeList(
            [a.toJson(), same.toJson(), b.toJson(), c.toJson()]),
        [a, b, c]);
  });

  test('a malformed favorite does not hide valid favorites', () {
    final saved =
        SavedSearch(sourceKey: 'ehentai', query: SearchQuery(text: 'words'));
    expect(
        SavedSearch.decodeList([
          null,
          {},
          {'sourceKey': 12},
          saved.toJson()
        ]),
        [saved]);
  });
}

class _RecordingHitomiSearch extends HitomiSearch {
  _RecordingHitomiSearch() : super('');

  (String?, String, String)? request;

  @override
  Future<List<int>> getGalleryIdsFromNozomi(
      String? area, String tag, String language) async {
    request = (area, tag, language);
    return [];
  }
}
