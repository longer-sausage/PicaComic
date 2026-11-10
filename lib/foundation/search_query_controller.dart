import 'package:flutter/widgets.dart';
import 'package:pica_comic/foundation/search_query.dart';

class SearchQueryController extends ChangeNotifier {
  SearchQueryController({
    String text = '',
    SearchQuery? query,
    Iterable<SearchTag> initialTags = const [],
  })  : textController = TextEditingController(text: query?.text ?? text),
        _tags = [...(query?.tags ?? initialTags)],
        _languageConfigured = query != null {
    _preferredLanguage = _languageTag?.value;
    if (_preferredLanguage != null) _languageConfigured = true;
    textController.addListener(_textChanged);
  }

  final TextEditingController textController;
  final List<SearchTag> _tags;
  bool _languageConfigured;
  bool _languageEnabled = false;
  String? _preferredLanguage;

  List<SearchTag> get tags => List.unmodifiable(_tags);
  SearchQuery get query => SearchQuery(text: textController.text, tags: _tags);

  SearchTag? get _languageTag {
    for (final tag in _tags) {
      if (tag.isLanguage) return tag;
    }
    return null;
  }

  String? get language => _languageTag?.value;

  void _textChanged() {
    // A typed language expression stays ordinary text and takes precedence
    // over a language supplied by the filter control.
    if (_languageTag != null &&
        SearchQuery.hasLanguageExpression(textController.text)) {
      _tags.removeWhere((tag) => tag.isLanguage);
      _preferredLanguage = null;
    }
    notifyListeners();
  }

  void configureLanguageFilter(
      {required bool enabled, String? defaultLanguage}) {
    _languageEnabled = enabled;
    if (enabled && !_languageConfigured) {
      _preferredLanguage =
          SearchQuery.hasLanguageExpression(textController.text)
              ? null
              : defaultLanguage;
      _languageConfigured = true;
    }
    if (enabled && _preferredLanguage != null) {
      final tag = SearchTag(_preferredLanguage!, namespace: 'language');
      if (!_tags.contains(tag)) {
        _tags.removeWhere((tag) => tag.isLanguage);
        _tags.add(tag);
      }
    } else {
      _tags.removeWhere((tag) => tag.isLanguage);
    }
    notifyListeners();
  }

  void setLanguage(String? language) {
    _preferredLanguage = language;
    _languageConfigured = true;
    _tags.removeWhere((tag) => tag.isLanguage);
    if (language != null && _languageEnabled) {
      _tags.add(SearchTag(language, namespace: 'language'));
      _setValue(_withoutTypedLanguage(textController.value));
    } else {
      notifyListeners();
    }
  }

  void removeTag(SearchTag tag) {
    if (tag.isLanguage) {
      setLanguage(null);
    } else {
      _tags.remove(tag);
      notifyListeners();
    }
  }

  void restore(SearchQuery query) {
    _tags
      ..clear()
      ..addAll(query.tags);
    _preferredLanguage = _languageTag?.value;
    _languageConfigured = true;
    _setValue(TextEditingValue(
      text: query.text,
      selection: TextSelection.collapsed(offset: query.text.length),
    ));
  }

  void clear() => restore(SearchQuery());

  int get _cursor {
    final selection = textController.selection;
    return selection.isValid ? selection.end : textController.text.length;
  }

  String get suggestionText {
    final value = textController.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return '';
    if (value.selection.isValid && !value.selection.isCollapsed) {
      return value.selection.textInside(value.text);
    }
    final before = value.text.substring(0, _cursor);
    return RegExp(r'[^\s]+$').firstMatch(before)?.group(0) ?? '';
  }

  static bool matchesSuggestion(
      String input, String value, String translation) {
    input = input.trim().toLowerCase();
    value = value.toLowerCase();
    if (input.isEmpty) return false;
    return value.startsWith(input) ||
        value.split(' ').last.startsWith(input) ||
        translation.toLowerCase().contains(input);
  }

  /// Replace only the suggestion fragment at the caret, preserving other input.
  void selectSuggestion(SearchTag tag, {String translation = ''}) {
    final text = textController.text;
    final selection = textController.selection;
    var start = selection.isValid ? selection.start : _cursor;
    var end = selection.isValid ? selection.end : _cursor;
    if (!selection.isValid || selection.isCollapsed) {
      final before = text.substring(0, _cursor);
      final words = RegExp(r'\S+').allMatches(before).toList();
      if (words.isNotEmpty && words.last.end == before.length) {
        start = words.last.start;
        for (final word in words) {
          final fragment = before.substring(word.start);
          if (matchesSuggestion(fragment, tag.value, translation)) {
            start = word.start;
            break;
          }
        }
        end += RegExp(r'^\S*').firstMatch(text.substring(end))!.end;
      }
    }
    if (tag.isLanguage) {
      _preferredLanguage = tag.value;
      _languageConfigured = true;
      _tags.removeWhere((tag) => tag.isLanguage);
    }
    if (!_tags.contains(tag)) _tags.add(tag);
    final value = TextEditingValue(
      text: text.replaceRange(start, end, ''),
      selection: TextSelection.collapsed(offset: start),
    );
    _setValue(tag.isLanguage ? _withoutTypedLanguage(value) : value);
  }

  TextEditingValue _withoutTypedLanguage(TextEditingValue value) {
    var text = value.text;
    var cursor = value.selection.isValid ? value.selection.end : text.length;
    for (final term in SearchQuery.languageTerms(text).toList().reversed) {
      text = text.replaceRange(term.start, term.end, '');
      if (cursor > term.start) {
        cursor -= cursor.clamp(term.start, term.end) - term.start;
      }
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  void _setValue(TextEditingValue value) {
    if (textController.value == value) {
      _textChanged();
    } else {
      textController.value = value;
    }
  }

  @override
  void dispose() {
    textController.removeListener(_textChanged);
    textController.dispose();
    super.dispose();
  }
}
