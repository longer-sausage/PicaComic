import 'package:collection/collection.dart';

/// A condition explicitly selected from a suggestion or a filter control.
/// Free-form input is kept separately in [SearchQuery.text].
class SearchTag {
  const SearchTag(this.value, {this.namespace});

  final String value;
  final String? namespace;

  bool get isLanguage => namespace == 'language';

  String get label => namespace == null ? value : '$namespace:$value';

  /// Only used for an explicitly clicked tag, never to parse user input.
  factory SearchTag.fromKeyword(String keyword, {required String sourceKey}) {
    var value = keyword.trim();
    String? namespace;
    final prefix = RegExp(r'^([a-zA-Z_]+):').firstMatch(value);
    if (prefix != null &&
        (const ['ehentai', 'nhentai', 'hitomi'].contains(sourceKey) ||
            prefix.group(1) == 'language')) {
      namespace = prefix.group(1);
      value = value.substring(prefix.end);
    }
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1).replaceAll(r'\"', '"');
    }
    if (sourceKey == 'hitomi') value = value.replaceAll('_', ' ');
    return SearchTag(value, namespace: namespace);
  }

  String keywordFor(String sourceKey) {
    if (sourceKey == 'hitomi') {
      final text = value.replaceAll(RegExp(r'\s+'), '_');
      final prefix = switch (namespace) {
        'parody' => 'series',
        'other' || 'mixed' => 'tag',
        _ => namespace,
      };
      return prefix == null ? text : '$prefix:$text';
    }
    final supportsNamespaces = sourceKey == 'ehentai' || sourceKey == 'nhentai';
    if (!supportsNamespaces && !isLanguage) return value;
    final text = RegExp(r'\s').hasMatch(value)
        ? '"${value.replaceAll('"', r'\"')}"'
        : value;
    if (namespace != null && (supportsNamespaces || isLanguage)) {
      return '$namespace:$text';
    }
    return text;
  }

  Map<String, dynamic> toJson() => {
        'value': value,
        if (namespace != null) 'namespace': namespace,
      };

  factory SearchTag.fromJson(Map<String, dynamic> json) {
    final value = json['value'];
    final namespace = json['namespace'];
    if (value is! String ||
        value.trim().isEmpty ||
        (namespace != null && namespace is! String)) {
      throw const FormatException('Invalid search tag');
    }
    return SearchTag(value, namespace: namespace as String?);
  }

  @override
  bool operator ==(Object other) =>
      other is SearchTag &&
      value == other.value &&
      namespace == other.namespace;

  @override
  int get hashCode => Object.hash(value, namespace);
}

class SearchQuery {
  SearchQuery({this.text = '', Iterable<SearchTag> tags = const []})
      : tags = List.unmodifiable(tags.toSet());

  final String text;
  final List<SearchTag> tags;

  bool get isEmpty => text.trim().isEmpty && tags.isEmpty;

  static final _terms = RegExp(r'(?:[^\s"]+|"(?:\\.|[^"\\])*")+');
  static final _languagePrefix = RegExp(r'^-?language:', caseSensitive: false);

  static Iterable<RegExpMatch> languageTerms(String text) => _terms
      .allMatches(text)
      .where((term) => _languagePrefix.hasMatch(term.group(0)!));

  static bool hasLanguageExpression(String text) =>
      languageTerms(text).isNotEmpty;

  String keywordFor(String sourceKey) => [
        ...tags.map((tag) => tag.keywordFor(sourceKey)),
        if (text.trim().isNotEmpty) text.trim(),
      ].join(' ');

  Map<String, dynamic> toJson() => {
        'text': text,
        'tags': tags.map((tag) => tag.toJson()).toList(),
      };

  factory SearchQuery.fromJson(Map<String, dynamic> json) {
    if (json['text'] is! String || json['tags'] is! List) {
      throw const FormatException('Invalid search query');
    }
    return SearchQuery(
      text: json['text'] as String,
      tags: (json['tags'] as List).map(
        (tag) => SearchTag.fromJson(Map<String, dynamic>.from(tag as Map)),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SearchQuery &&
      text.trim() == other.text.trim() &&
      const SetEquality<SearchTag>().equals(tags.toSet(), other.tags.toSet());

  @override
  int get hashCode => Object.hash(
      text.trim(), const SetEquality<SearchTag>().hash(tags.toSet()));
}

/// A complete, source-specific search snapshot for user data and sync.
class SavedSearch {
  SavedSearch({
    required this.sourceKey,
    required this.query,
    Iterable<String> options = const [],
  }) : options = List.unmodifiable(options);

  final String sourceKey;
  final SearchQuery query;
  final List<String> options;

  Map<String, dynamic> toJson() => {
        'sourceKey': sourceKey,
        'query': query.toJson(),
        'options': options,
      };

  factory SavedSearch.fromJson(Map<String, dynamic> json) {
    final sourceKey = json['sourceKey'];
    if (sourceKey is! String || sourceKey.isEmpty || json['options'] is! List) {
      throw const FormatException('Invalid saved search');
    }
    return SavedSearch(
      sourceKey: sourceKey,
      query:
          SearchQuery.fromJson(Map<String, dynamic>.from(json['query'] as Map)),
      options: List<String>.from(json['options'] as List),
    );
  }

  static List<SavedSearch> decodeList(dynamic data) {
    if (data is! List) return [];
    final searches = <SavedSearch>{};
    for (final item in data) {
      try {
        searches
            .add(SavedSearch.fromJson(Map<String, dynamic>.from(item as Map)));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    return searches.toList();
  }

  @override
  bool operator ==(Object other) =>
      other is SavedSearch &&
      sourceKey == other.sourceKey &&
      query == other.query &&
      const ListEquality<String>().equals(options, other.options);

  @override
  int get hashCode =>
      Object.hash(sourceKey, query, const ListEquality<String>().hash(options));
}
