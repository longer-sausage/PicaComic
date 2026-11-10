import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/components/search_query_bar.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/pair.dart';
import 'package:pica_comic/foundation/search_query.dart';
import 'package:pica_comic/foundation/search_query_controller.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:pica_comic/tools/translations.dart';

class _SearchPageComicList extends ComicsPage<BaseComic> {
  const _SearchPageComicList({
    super.key,
    required this.keyword,
    required this.options,
    required this.header,
    required this.sourceKey,
  });

  final String keyword;

  final List<String> options;

  @override
  final String sourceKey;

  @override
  final Widget header;

  @override
  Future<Res<List<BaseComic>>> getComics(int i) async {
    var loader = ComicSource.find(sourceKey)!.searchPageData!.loadPage!;
    return await loader(keyword, i, options);
  }

  @override
  String? get tag => "$sourceKey search page with $keyword";

  @override
  String? get title => null;
}

class SearchResultPage extends StatelessWidget {
  const SearchResultPage({
    super.key,
    required this.keyword,
    this.options = const [],
    required this.sourceKey,
    this.query,
    this.initialTags = const [],
  });

  factory SearchResultPage.forTag({
    Key? key,
    required String tag,
    required String sourceKey,
    List<String> options = const [],
  }) =>
      SearchResultPage(
        key: key,
        keyword: '',
        initialTags: [SearchTag.fromKeyword(tag, sourceKey: sourceKey)],
        options: options,
        sourceKey: sourceKey,
      );

  final String keyword;

  final List<String> options;

  final String sourceKey;

  final SearchQuery? query;
  final List<SearchTag> initialTags;

  @override
  Widget build(BuildContext context) {
    var comicSource =
        ComicSource.find(sourceKey) ?? (throw "source $sourceKey not found");
    final data = comicSource.searchPageData!;
    final options = data.normalizeOptions(this.options);
    final editor = SearchQueryController(
        text: keyword, query: query, initialTags: initialTags);
    editor.configureLanguageFilter(
      enabled: data.enableLanguageFilter,
      defaultLanguage: appdata.defaultSearchLanguage,
    );
    final initialQuery = editor.query;
    editor.dispose();
    if (comicSource.searchPageData?.overrideSearchResultBuilder != null) {
      return comicSource.searchPageData!.overrideSearchResultBuilder!(
        initialQuery,
        options,
      );
    } else {
      return _SearchResultPage(
        query: initialQuery,
        options: options,
        sourceKey: sourceKey,
      );
    }
  }
}

class _SearchResultPage extends StatefulWidget {
  const _SearchResultPage({
    required this.query,
    required this.options,
    required this.sourceKey,
  });

  final SearchQuery query;

  final List<String> options;

  final String sourceKey;

  @override
  State<_SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends State<_SearchResultPage> {
  late final SearchQueryController queryController;
  final focusNode = FocusNode();
  bool _showFab = true;
  late String keyword;

  OverlayEntry? get suggestionOverlay => suggestionsController.entry;
  late _SuggestionsController suggestionsController;
  late var sourceKey = widget.sourceKey;
  late var options = widget.options;

  @override
  void initState() {
    super.initState();
    queryController = SearchQueryController(query: widget.query);
    queryController.configureLanguageFilter(
      enabled:
          ComicSource.find(sourceKey)!.searchPageData!.enableLanguageFilter,
    );
    keyword = queryController.query.keywordFor(sourceKey);
    suggestionsController = _SuggestionsController(queryController, focusNode);
    queryController.addListener(queryChanged);
  }

  void queryChanged() {
    setState(() {});
    suggestionOverlay?.markNeedsBuild();
  }

  @override
  void dispose() {
    suggestionsController.remove();
    queryController.removeListener(queryChanged);
    queryController.dispose();
    focusNode.dispose();
    super.dispose();
  }

  void onChanged(String s) {
    if (!ComicSource.find(sourceKey)!.searchPageData!.enableTagsSuggestions) {
      suggestionsController.remove();
      return;
    }
    suggestionsController.findSuggestions();
    if (suggestionOverlay != null) {
      if (suggestionsController.suggestions.isEmpty) {
        suggestionsController.remove();
      } else {
        suggestionsController.updateWidget();
      }
    } else if (suggestionsController.suggestions.isNotEmpty) {
      suggestionsController.entry = OverlayEntry(
        builder: (context) {
          return Positioned(
            top:
                context.padding.top + SearchQueryBar.heightFor(queryController),
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              child: _Suggestions(
                controller: suggestionsController,
              ),
            ),
          );
        },
      );
      Overlay.of(context).insert(suggestionOverlay!);
    }
  }

  void search() {
    suggestionsController.suggestions.clear();
    suggestionsController.remove();
    focusNode.unfocus();
    final query = queryController.query.keywordFor(sourceKey);
    if (keyword == query) return;
    setState(() => keyword = query);
  }

  @override
  Widget build(BuildContext context) {
    Widget trailing;
    if (context.width < 600) {
      trailing = Button.icon(
        icon: const Icon(Icons.more_horiz),
        onPressed: more,
      );
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(
            icon: const Icon(Icons.dataset_outlined),
            onPressed: changeSource,
          ),
          const SizedBox(
            width: 4,
          ),
          Button.icon(
            icon: const Icon(Icons.tune),
            onPressed: showSearchOptions,
          ),
        ],
      );
    }

    return Scaffold(
      floatingActionButton: _showFab
          ? FloatingActionButton(
              onPressed: search,
              child: const Icon(Icons.search),
            )
          : null,
      body: NotificationListener<ScrollUpdateNotification>(
        onNotification: (notification) {
          if (notification.depth != 0 ||
              notification.metrics.axis != Axis.vertical ||
              notification.scrollDelta == null ||
              notification.scrollDelta == 0) {
            return false;
          }
          if (suggestionsController.entry != null) {
            suggestionsController.remove();
          }
          final ScrollDirection direction = notification.scrollDelta! < 0
              ? ScrollDirection.forward
              : ScrollDirection.reverse;
          var showFab = _showFab;
          if (direction == ScrollDirection.reverse) {
            _showFab = false;
          } else if (direction == ScrollDirection.forward) {
            _showFab = true;
          }
          if (_showFab == showFab) return true;
          setState(() {});
          return false;
        },
        child: _SearchPageComicList(
          keyword: keyword,
          sourceKey: sourceKey,
          key: Key(keyword + options.toString() + sourceKey),
          header: SliverPersistentHeader(
            pinned: _showFab && SmoothScrollProvider.isMouseScroll,
            floating: !SmoothScrollProvider.isMouseScroll,
            delegate: _SliverAppBarDelegate(
              minHeight: SearchQueryBar.heightFor(queryController),
              maxHeight: SearchQueryBar.heightFor(queryController),
              child: SearchQueryBar(
                onSearch: search,
                controller: queryController,
                focusNode: focusNode,
                sourceKey: sourceKey,
                options: options,
                onChanged: onChanged,
                trailing: trailing,
              ),
            ),
          ),
          options: options,
        ),
      ),
    );
  }

  void more() {
    showMenu(
      context: context,
      elevation: 2,
      color: context.colorScheme.surface,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 48,
        56,
        0,
        0,
      ),
      items: [
        PopupMenuItem(
          value: 0,
          child: Text("切换源".tl),
        ),
        PopupMenuItem(
          value: 1,
          child: Text("搜索选项".tl),
        ),
      ],
    ).then((value) {
      if (value == 0) {
        changeSource();
      } else if (value == 1) {
        showSearchOptions();
      }
    });
  }

  void changeSource() {
    var sources = ComicSource.sources.where((e) => e.searchPageData != null);
    String? sourceKey = this.sourceKey;
    showDialog(
      useSafeArea: false,
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "切换源".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var source in sources)
                  RadioListTile<String>(
                    title: Text(source.name),
                    value: source.key,
                    groupValue: sourceKey,
                    onChanged: (value) {
                      setState(() {
                        sourceKey = value;
                      });
                    },
                  )
              ],
            ),
            actions: [
              Button.filled(
                child: Text("确认".tl),
                onPressed: () {
                  if (sourceKey != null) {
                    context.pop();
                    var searchData =
                        ComicSource.find(sourceKey!)!.searchPageData!;
                    options = searchData.normalizeOptions([]);
                    suggestionsController.remove();
                    queryController.configureLanguageFilter(
                      enabled: searchData.enableLanguageFilter,
                      defaultLanguage: appdata.defaultSearchLanguage,
                    );
                    final query = queryController.query;
                    final newKeyword = query.keywordFor(sourceKey!);
                    if (searchData.overrideSearchResultBuilder != null) {
                      this.context.off(() {
                        return SearchResultPage(
                          keyword: newKeyword,
                          query: query,
                          options: options,
                          sourceKey: sourceKey!,
                        );
                      });
                    } else {
                      this.setState(() {
                        this.sourceKey = sourceKey!;
                        keyword = newKeyword;
                      });
                    }
                  }
                },
              )
            ],
          );
        });
      },
    );
  }

  void showSearchOptions() {
    showDialog(
      context: context,
      useSafeArea: false,
      builder: (context) => _SearchOptions(
        current: options,
        sourceKey: sourceKey,
        onChanged: (options) {
          setState(() {
            this.options = options;
          });
        },
      ),
    );
  }
}

class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverAppBarDelegate(
      {required this.child, required this.maxHeight, required this.minHeight});

  final double minHeight;
  final double maxHeight;
  final Widget child;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox.expand(
      child: child,
    );
  }

  @override
  double get maxExtent => minHeight;

  @override
  double get minExtent => max(maxHeight, minHeight);

  @override
  bool shouldRebuild(SliverPersistentHeaderDelegate oldDelegate) {
    return oldDelegate is! _SliverAppBarDelegate ||
        child != oldDelegate.child ||
        maxHeight != oldDelegate.maxExtent ||
        minHeight != oldDelegate.minExtent;
  }
}

class _SuggestionsController {
  _SuggestionsState? _state;

  final SearchQueryController controller;
  final FocusNode focusNode;

  OverlayEntry? entry;

  void updateWidget() {
    _state?.update();
  }

  void remove() {
    entry?.remove();
    entry?.dispose();
    entry = null;
  }

  var suggestions = <Pair<String, TranslationType>>[];

  void findSuggestions() {
    var text = controller.suggestionText;
    var suggestions = this.suggestions;

    suggestions.clear();

    void find(Map<String, String> map, TranslationType type) {
      for (var element in map.entries) {
        if (suggestions.length > 200) {
          break;
        }
        if (SearchQueryController.matchesSuggestion(
            text, element.key, element.value)) {
          suggestions.add(Pair(element.key, type));
        }
      }
    }

    find(TagsTranslation.femaleTags, TranslationType.female);
    find(TagsTranslation.maleTags, TranslationType.male);
    find(TagsTranslation.parodyTags, TranslationType.parody);
    find(TagsTranslation.characterTranslations, TranslationType.character);
    find(TagsTranslation.otherTags, TranslationType.other);
    find(TagsTranslation.mixedTags, TranslationType.mixed);
    find(TagsTranslation.languageTranslations, TranslationType.language);
    find(TagsTranslation.artistTags, TranslationType.artist);
    find(TagsTranslation.groupTags, TranslationType.group);
    find(TagsTranslation.cosplayerTags, TranslationType.cosplayer);
  }

  _SuggestionsController(this.controller, this.focusNode);
}

class _Suggestions extends StatefulWidget {
  const _Suggestions({required this.controller});

  final _SuggestionsController controller;

  @override
  State<_Suggestions> createState() => _SuggestionsState();
}

class _SuggestionsState extends State<_Suggestions> {
  void update() {
    setState(() {});
  }

  @override
  void initState() {
    widget.controller._state = this;
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _Suggestions oldWidget) {
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._state = null;
      widget.controller._state = this;
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    widget.controller._state = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return buildSuggestions(context);
  }

  Widget buildSuggestions(BuildContext context) {
    bool showMethod = MediaQuery.of(context).size.width < 600;
    bool showTranslation = App.locale.languageCode == "zh";

    Widget buildItem(Pair<String, TranslationType> value) {
      var subTitle = TagsTranslation.translationTagWithNamespace(
          value.left, value.right.name);
      return ListTile(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: Text(
                value.left,
                maxLines: 2,
              ),
            ),
            if (!showMethod)
              const SizedBox(
                width: 12,
              ),
            if (!showMethod && showTranslation)
              Flexible(
                child: Text(
                  subTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.outline),
                ),
              )
          ],
        ),
        subtitle: (showMethod && showTranslation) ? Text(subTitle) : null,
        trailing: Text(
          value.right.name,
          style: const TextStyle(fontSize: 13),
        ),
        onTap: () => onSelected(value.left, value.right),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              const SizedBox(
                width: 32,
              ),
              Text("建议".tl),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  widget.controller.suggestions.clear();
                  widget.controller.remove();
                },
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(
                width: 36,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: widget.controller.suggestions.length,
            itemBuilder: (context, index) =>
                buildItem(widget.controller.suggestions[index]),
          ),
        )
      ],
    );
  }

  void onSelected(String text, TranslationType? type) {
    widget.controller.controller.selectSuggestion(
      SearchTag(text, namespace: type?.name),
      translation: text.translateTagsToCN,
    );
    widget.controller.suggestions.clear();
    widget.controller.remove();
    widget.controller.focusNode.requestFocus();
  }
}

class _SearchOptions extends StatefulWidget {
  const _SearchOptions({
    required this.current,
    required this.sourceKey,
    required this.onChanged,
  });

  final List<String> current;

  final String sourceKey;

  final void Function(List<String>) onChanged;

  @override
  State<_SearchOptions> createState() => _SearchOptionsState();
}

class _SearchOptionsState extends State<_SearchOptions> {
  late SearchPageData data;

  var options = <String>[];

  @override
  void initState() {
    data = ComicSource.find(widget.sourceKey)!.searchPageData!;
    options = data.normalizeOptions(widget.current);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "搜索选项".tl,
      content: buildSearchOptions(context),
      actions: [
        Button.filled(
          child: Text("确认".tl),
          onPressed: () {
            context.pop();
            widget.onChanged(options);
          },
        )
      ],
    );
  }

  Widget buildSearchOptions(BuildContext context) {
    var children = <Widget>[];
    if (data.customOptionsBuilder != null) {
      children.add(
        data.customOptionsBuilder!(context, options, (options) {
          this.options = options;
        }),
      );
    } else {
      final searchOptions = data.searchOptions ?? <SearchOptions>[];
      for (int i = 0; i < searchOptions.length; i++) {
        final option = searchOptions[i];
        children.add(ListTile(
          title: Text(option.label),
        ));
        children.add(Wrap(
          runSpacing: 8,
          spacing: 8,
          children: option.options.entries.map((e) {
            return InkWell(
              onTap: () {
                setState(() {
                  options[i] = e.key;
                });
              },
              borderRadius: BorderRadius.circular(8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  color: options[i] == e.key
                      ? context.colorScheme.primaryContainer
                      : context.colorScheme.primaryContainer.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(e.value.tl),
                ),
              ),
            );
          }).toList(),
        ).paddingHorizontal(16));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ).paddingBottom(12);
  }
}
