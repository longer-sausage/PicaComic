import 'package:flutter/material.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/components/search_favorites.dart';
import 'package:pica_comic/components/search_query_bar.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/pair.dart';
import 'package:pica_comic/foundation/search_query.dart';
import 'package:pica_comic/foundation/search_query_controller.dart';
import 'package:pica_comic/foundation/ui_mode.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/search_result_page.dart';
import 'package:pica_comic/tools/app_links.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:sliver_tools/sliver_tools.dart';

typedef FilterChip = FilterChipFixedWidth;

class PreSearchController extends StateController {
  String target = '';

  SearchPageData get searchPageData =>
      ComicSource.find(target)!.searchPageData!;

  var options = <String>[];

  var suggestions = <Pair<String, TranslationType>>[];

  int optionsRevision = 0;

  bool limitHistory = true;

  void updateOptions() {
    options =
        ComicSource.find(target)?.searchPageData?.normalizeOptions([]) ?? [];
    optionsRevision++;
  }

  PreSearchController() {
    var searchSource = <String>[];
    for (var source in ComicSource.sources) {
      if (source.searchPageData != null) searchSource.add(source.key);
    }
    if (searchSource.isEmpty) return;
    if (!searchSource.contains(appdata.appSettings.initialSearchTarget)) {
      appdata.appSettings.initialSearchTarget = searchSource.first;
      appdata.updateSettings();
    }
    target = appdata.appSettings.initialSearchTarget;
    updateOptions();
  }
}

class PreSearchPage extends StatefulWidget {
  const PreSearchPage({this.initialValue = '', super.key});

  final String initialValue;

  @override
  State<PreSearchPage> createState() => _PreSearchPageState();
}

class _PreSearchPageState extends State<PreSearchPage> {
  late final SearchQueryController queryController;
  late final PreSearchController searchController;
  TextEditingController get controller => queryController.textController;

  final comicSources =
      ComicSource.sources.where((element) => element.searchPageData != null);

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    searchController = StateController.put(PreSearchController());
    queryController = SearchQueryController(text: widget.initialValue);
    if (comicSources.isNotEmpty) configureLanguage();
    queryController.addListener(queryChanged);
  }

  void queryChanged() => searchController.update(['search-bar', 'mode']);

  void configureLanguage() => queryController.configureLanguageFilter(
        enabled: searchController.searchPageData.enableLanguageFilter,
        defaultLanguage: appdata.defaultSearchLanguage,
      );

  void selectTarget(String target) {
    searchController.target = target;
    searchController.updateOptions();
    configureLanguage();
    findSuggestions();
    searchController.update();
  }

  void restoreSearch(SavedSearch search) {
    searchController.target = search.sourceKey;
    searchController.options =
        searchController.searchPageData.normalizeOptions(search.options);
    searchController.optionsRevision++;
    queryController.restore(search.query);
    configureLanguage();
    searchController.suggestions.clear();
    searchController.update();
  }

  @override
  void dispose() {
    queryController.removeListener(queryChanged);
    queryController.dispose();
    _focusNode.dispose();
    searchController.dispose();
    super.dispose();
  }

  void search([String? s, String? type]) {
    final target = type ?? searchController.target;
    final data = ComicSource.find(target)?.searchPageData;
    if (data == null) return;
    var query = queryController.query;
    if (s != null) {
      final externalQuery = SearchQueryController(text: s);
      externalQuery.configureLanguageFilter(
        enabled: data.enableLanguageFilter,
        defaultLanguage: appdata.defaultSearchLanguage,
      );
      query = externalQuery.query;
      externalQuery.dispose();
    }
    context.to(
      () => SearchResultPage(
        keyword: query.keywordFor(target),
        query: query,
        sourceKey: target,
        options: data.normalizeOptions(
            target == searchController.target ? searchController.options : []),
      ),
    );
  }

  void findSuggestions() {
    var text = queryController.suggestionText;
    var suggestions = searchController.suggestions;

    suggestions.clear();

    if (canHandle(controller.text)) {
      suggestions.add(Pair("**URL**", TranslationType.other));
    } else {
      var text = controller.text;

      for (var comicSource in ComicSource.sources) {
        if (comicSource.idMatcher?.hasMatch(text) ?? false) {
          suggestions
              .add(Pair("**${comicSource.key}**", TranslationType.other));
        }
      }
    }

    if (!searchController.searchPageData.enableTagsSuggestions) return;

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

  @override
  Widget build(BuildContext context) {
    if (comicSources.isEmpty) {
      return Scaffold(
        appBar: Appbar(title: Text('搜索'.tl)),
        body: Center(child: Text('没有可用的搜索目标'.tl)),
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: search,
        child: const Icon(Icons.search),
      ),
      body: Column(
        children: [
          if (UiMode.m1(context))
            SizedBox(
              height: MediaQuery.of(context).padding.top,
            ),
          StateBuilder<PreSearchController>(
            id: 'search-bar',
            builder: (logic) => SearchQueryBar(
              hintText: '${'搜索'.tl} / ${'链接'.tl} / ID',
              onSearch: search,
              sourceKey: logic.target,
              options: logic.options,
              controller: queryController,
              onChanged: (s) {
                findSuggestions();
                searchController.update([1, 100]);
              },
              focusNode: _focusNode,
            ),
          ),
          const SizedBox(
            height: 8,
          ),
          buildBody(context)
        ],
      ),
    );
  }

  Widget buildBody(BuildContext context) {
    var widget = StateBuilder<PreSearchController>(
      id: 100,
      builder: (logic) {
        if (queryController.suggestionText.isEmpty ||
            searchController.suggestions.isEmpty) {
          return buildMainView(context, logic);
        } else {
          return buildSuggestions(context);
        }
      },
    );
    return Expanded(
      child: widget,
    );
  }

  Widget buildMainView(BuildContext context, PreSearchController logic) {
    final showSideBar = MediaQuery.of(context).size.width > 950;
    var addWidth = (MediaQuery.of(context).size.width - 950) * 0.25;
    addWidth = addWidth.clamp(0, 50);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showSideBar)
          SizedBox(
            width: 250 + addWidth,
            height: double.infinity,
            child: buildHistorySideBar(),
          ),
        if (showSideBar)
          const VerticalDivider(
            width: 1,
          ),
        Expanded(
            child: CustomScrollView(
          slivers: [
            if (showSideBar)
              ListTile(
                leading: const Icon(Icons.select_all),
                title: Text("搜索选项".tl),
              ).toSliver(),
            buildTargetSelector(context).toSliver(),
            SearchFavorites(
              key: ValueKey(logic.target),
              sourceKey: logic.target,
              onSelected: restoreSearch,
            ).toSliver(),
            SliverAnimatedPaintExtent(
              duration: const Duration(milliseconds: 180),
              child: buildSearchOptions(context).toSliver(),
            ),
            if (!showSideBar) ...buildHistoryAndFavoritesForMobile(logic),
            SliverPadding(
              padding: EdgeInsets.only(bottom: context.padding.bottom),
            )
          ],
        )),
        if (showSideBar)
          const VerticalDivider(
            width: 1,
          ),
        if (showSideBar)
          SizedBox(
            width: 250 + addWidth,
            height: double.infinity,
            child: buildFavoriteSideBar(),
          ),
      ],
    );
  }

  Widget buildSuggestions(BuildContext context) {
    return StateBuilder<PreSearchController>(
      builder: (logic) {
        void onSelected(String text, TranslationType? type) {
          queryController.selectSuggestion(
            SearchTag(text, namespace: type?.name),
            translation: text.translateTagsToCN,
          );
          logic.suggestions.clear();
          logic.update([1, 100]);
          _focusNode.requestFocus();
        }

        Widget widget;

        if (controller.text.removeAllBlank.isEmpty) {
          widget = buildMainView(context, logic);
        } else {
          bool showMethod = MediaQuery.of(context).size.width < 600;
          bool showTranslation = App.locale.languageCode == "zh";
          Widget buildItem(Pair<String, TranslationType> value) {
            if (value.left == "**URL**") {
              return ListTile(
                leading: const Icon(Icons.link),
                title: Text("打开链接".tl),
                subtitle: Text(
                  controller.text,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                ),
                trailing: const Icon(Icons.arrow_right),
                onTap: () {
                  handleAppLinks(Uri.parse(controller.text));
                },
              );
            }

            if (RegExp(r"^\*\*.*\*\*$").hasMatch(value.left)) {
              var key = value.left.substring(2, value.left.length - 2);
              var comicSource = ComicSource.find(key);
              if (comicSource == null) {
                return const SizedBox();
              }
              return ListTile(
                leading: const Icon(Icons.link),
                title: Text("${"打开漫画".tl}: ${comicSource.name}"),
                subtitle: Text(
                  controller.text,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                ),
                trailing: const Icon(Icons.arrow_right),
                onTap: () {
                  context.to(
                    () => ComicPage(
                      sourceKey: key,
                      id: controller.text,
                    ),
                  );
                },
              );
            }

            var subTitle = TagsTranslation.translationTagWithNamespace(
                value.left, value.right.name);
            return ListTile(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: Text(value.left,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
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

          widget = Column(
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
                        searchController.suggestions.clear();
                        logic.update([100]);
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
                  itemCount: searchController.suggestions.length,
                  itemBuilder: (context, index) =>
                      buildItem(searchController.suggestions[index]),
                ),
              )
            ],
          );
        }
        return widget;
      },
      id: 1,
    );
  }

  Widget buildTargetSelector(BuildContext context) {
    buildItem(PreSearchController logic, String id, String text) => Padding(
          padding: const EdgeInsets.all(4),
          child: FilterChip(
            label: Text(text),
            selected: logic.target == id,
            onSelected: (b) {
              selectTarget(id);
            },
          ),
        );

    return StateBuilder<PreSearchController>(
      builder: (logic) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text("目标".tl)),
            Wrap(
              children: [
                for (var source in comicSources)
                  buildItem(logic, source.key, source.name.tl)
              ],
            ).paddingHorizontal(12),
            const SizedBox(height: 8)
          ],
        );
      },
    );
  }

  Widget buildSearchOptions(BuildContext context) {
    Widget buildLangSelector() {
      const languages = ["chinese", "japanese", "english"];
      return Padding(
        padding: const EdgeInsets.only(top: 8, left: 12, right: 12),
        child: Row(
          children: [
            const SizedBox(
              width: 8,
            ),
            Text("语言".tl),
            const SizedBox(
              width: 16,
            ),
            DropdownButton<String>(
              value: queryController.language ?? '',
              items: [
                DropdownMenuItem(value: '', child: Text('不限'.tl)),
                for (final language in {
                  ...languages,
                  if (queryController.language != null)
                    queryController.language!,
                })
                  DropdownMenuItem(value: language, child: Text(language)),
              ],
              onChanged: (value) => queryController
                  .setLanguage(value == null || value.isEmpty ? null : value),
            ),
          ],
        ),
      );
    }

    return StateBuilder<PreSearchController>(
      id: "mode",
      builder: (logic) {
        var children = <Widget>[];
        if (logic.searchPageData.customOptionsBuilder != null) {
          children.add(
            KeyedSubtree(
              key: ValueKey((logic.target, logic.optionsRevision)),
              child: logic.searchPageData.customOptionsBuilder!(
                  context, List.of(logic.options), (options) {
                logic.options = List.of(options);
                logic.update(['search-bar']);
              }),
            ),
          );
        } else {
          final searchOptions =
              logic.searchPageData.searchOptions ?? <SearchOptions>[];
          for (int i = 0; i < searchOptions.length; i++) {
            final option = searchOptions[i];
            children.add(ListTile(
              title: Text(option.label.tl),
            ));
            children.add(Wrap(
              runSpacing: 8,
              spacing: 8,
              children: option.options.entries.map((e) {
                return OptionChip(
                  text: e.value.tl,
                  isSelected: logic.options[i] == e.key,
                  onTap: () {
                    logic.options[i] = e.key;
                    logic.update();
                  },
                );
              }).toList(),
            ).paddingHorizontal(16));
          }
        }
        if (logic.searchPageData.enableLanguageFilter) {
          children.add(buildLangSelector());
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ).paddingBottom(12);
      },
    );
  }

  Widget buildHistoryItem(String history, PreSearchController logic) {
    return Flyout(
      enableLongPress: true,
      enableSecondaryTap: true,
      navigator: App.navigatorKey.currentState,
      flyoutBuilder: (context) {
        return FlyoutContent(
          title: "要删除此项目吗?".tl,
          actions: [
            FilledButton(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.all(
                  Theme.of(context).colorScheme.error,
                ),
              ),
              onPressed: () {
                appdata.searchHistory.remove(history);
                logic.update(["history"]);
                appdata.writeHistory();
                App.globalBack();
              },
              child: Text("确认".tl),
            )
          ],
        );
      },
      child: InkWell(
        onTap: () => search(history),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                history,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildFavoriteItem(String tag, PreSearchController logic) {
    return Flyout(
      enableLongPress: true,
      enableSecondaryTap: true,
      navigator: App.navigatorKey.currentState,
      flyoutBuilder: (context) {
        return FlyoutContent(
          title: "要删除此项目吗?".tl,
          actions: [
            FilledButton(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.all(
                  Theme.of(context).colorScheme.error,
                ),
              ),
              onPressed: () {
                appdata.favoriteTags.remove(tag);
                searchController.update();
                appdata.writeHistory();
                App.globalBack();
              },
              child: Text("确认".tl),
            )
          ],
        );
      },
      child: ListTile(
        title: Text(tag.substring(tag.indexOf(':') + 1)),
        subtitle: Text(tag.split(':').first),
        onTap: () {
          String type = switch (tag.split(':').first) {
            "Picacg" => 'picacg',
            "EHentai" => 'ehentai',
            "JMComic" => 'jm',
            "hitomi" => 'hitomi',
            "HtComic" => 'htmanga',
            "Nhentai" => 'nhentai',
            _ => tag.split(':').first
          };
          final keyword = tag.substring(tag.indexOf(':') + 1);
          context.to(() => SearchResultPage.forTag(
                tag: keyword,
                sourceKey: type,
              ));
        },
      ),
    );
  }

  Widget buildClearHistoryButton(PreSearchController logic) {
    return FlyoutIconButton(
      navigator: App.navigatorKey.currentState,
      flyoutBuilder: (context) {
        return FlyoutContent(
          title: "要清空历史记录吗?".tl,
          actions: [
            FilledButton(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.all(
                  Theme.of(context).colorScheme.error,
                ),
              ),
              onPressed: () {
                appdata.searchHistory.clear();
                appdata.writeHistory();
                logic.update(["history"]);
                App.globalBack();
              },
              child: Text("确认".tl),
            )
          ],
        );
      },
      icon: const Icon(Icons.delete_forever),
    );
  }

  Widget buildClearFavoriteButton(PreSearchController logic) {
    return FlyoutIconButton(
      navigator: App.navigatorKey.currentState,
      flyoutBuilder: (context) {
        return FlyoutContent(
          title: "要清空收藏吗?".tl,
          actions: [
            FilledButton(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.all(
                  Theme.of(context).colorScheme.error,
                ),
              ),
              onPressed: () {
                appdata.favoriteTags.clear();
                appdata.writeHistory();
                logic.update();
                App.globalBack();
              },
              child: Text("确认".tl),
            )
          ],
        );
      },
      icon: const Icon(Icons.delete_forever),
    );
  }

  Widget buildHistorySideBar() {
    return StateBuilder<PreSearchController>(
      id: "history",
      builder: (logic) {
        return ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: appdata.searchHistory.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return ListTile(
                leading: const Icon(Icons.history),
                title: Text("历史搜索".tl),
                trailing: buildClearHistoryButton(logic),
              );
            } else {
              var history =
                  appdata.searchHistory[appdata.searchHistory.length - index];
              return buildHistoryItem(history, logic);
            }
          },
        );
      },
    );
  }

  Widget buildFavoriteSideBar() {
    return StateBuilder<PreSearchController>(
      builder: (logic) => ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: appdata.favoriteTags.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return ListTile(
              leading: const Icon(Icons.favorite_border),
              title: Text("收藏".tl),
              trailing: buildClearFavoriteButton(logic),
            );
          } else {
            final s = appdata.favoriteTags.elementAt(index - 1);
            return buildFavoriteItem(s, logic);
          }
        },
      ),
    );
  }

  Iterable<Widget> buildHistoryAndFavoritesForMobile(
      PreSearchController logic) sync* {
    yield const Divider().paddingHorizontal(16).toSliver();
    yield ListTile(
      leading: const Icon(Icons.history),
      title: Text("历史搜索".tl),
      trailing: buildClearHistoryButton(logic),
    ).toSliver();
    yield StateBuilder<PreSearchController>(
      id: "history",
      builder: (logic) {
        var length = appdata.searchHistory.length;
        if (length < 10) {
          logic.limitHistory = false;
        }
        if (logic.limitHistory) {
          length = length.clamp(0, 10);
        }
        return SliverList.builder(
          itemCount: length,
          itemBuilder: (context, index) {
            if (index == length - 1 && logic.limitHistory) {
              return TextButton(
                child: Text("查看更多".tl),
                onPressed: () {
                  logic.limitHistory = false;
                  logic.update(["history"]);
                },
              ).toAlign(Alignment.center);
            }
            var history =
                appdata.searchHistory[appdata.searchHistory.length - index - 1];
            return buildHistoryItem(history, logic);
          },
        );
      },
    );
    yield const Divider().paddingHorizontal(16).toSliver();
    yield ListTile(
      leading: const Icon(Icons.favorite_border),
      title: Text("收藏".tl),
      trailing: buildClearFavoriteButton(logic),
    ).toSliver();

    yield StateBuilder<PreSearchController>(
      builder: (logic) => SliverList.builder(
        itemCount: appdata.favoriteTags.length,
        itemBuilder: (context, index) {
          final s = appdata.favoriteTags.elementAt(index);
          return buildFavoriteItem(s, logic);
        },
      ),
    );
  }
}
