import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/search_query_bar.dart';
import 'package:pica_comic/foundation/search_query.dart';
import 'package:pica_comic/foundation/search_query_controller.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_main_network.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:shimmer_animation/shimmer_animation.dart';

import '../../network/res.dart';

class SearchPageComicList extends StatefulWidget {
  const SearchPageComicList(
      {super.key, required this.keyword, required this.head});

  final String keyword;

  final Widget head;

  @override
  State<SearchPageComicList> createState() => _SearchPageComicListState();
}

class _SearchPageComicListState
    extends LoadingState<SearchPageComicList, List<int>> {
  @override
  Widget buildContent(BuildContext context, List<int> data) {
    return SmoothCustomScrollView(
      slivers: [
        widget.head,
        SliverGrid(
          delegate: SliverChildBuilderDelegate(
            (context, index) => HitomiComicTileDynamicLoading(data[index]),
            childCount: data.length,
          ),
          gridDelegate: SliverGridDelegateWithComics(),
        ),
      ],
    );
  }

  @override
  Future<Res<List<int>>> loadData() {
    return HiNetwork().search(widget.keyword);
  }
}

class HitomiSearchPage extends StatefulWidget {
  const HitomiSearchPage(this.keyword, {this.query, Key? key})
      : super(key: key);
  final String keyword;
  final SearchQuery? query;

  @override
  State<HitomiSearchPage> createState() => _HitomiSearchPageState();
}

class _HitomiSearchPageState extends State<HitomiSearchPage> {
  late String keyword;
  late final SearchQueryController controller;

  @override
  void initState() {
    super.initState();
    controller =
        SearchQueryController(text: widget.keyword, query: widget.query);
    controller.configureLanguageFilter(
      enabled: true,
      defaultLanguage: appdata.defaultSearchLanguage,
    );
    keyword = controller.query.keywordFor('hitomi');
    controller.addListener(queryChanged);
  }

  void queryChanged() => setState(() {});

  @override
  void dispose() {
    controller.removeListener(queryChanged);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SearchQueryBar(
              sourceKey: 'hitomi',
              options: const [],
              onSearch: () {
                setState(() {
                  keyword = controller.query.keywordFor('hitomi');
                });
              },
              controller: controller,
            ),
            Expanded(
              child: SearchPageComicList(
                keyword: keyword,
                key: Key(keyword),
                head: const SliverToBoxAdapter(child: SizedBox.shrink()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HitomiComicTileDynamicLoading extends StatefulWidget {
  const HitomiComicTileDynamicLoading(this.id,
      {Key? key, this.addonMenuOptions})
      : super(key: key);
  final int id;

  final List<ComicTileMenuOption>? addonMenuOptions;

  @override
  State<HitomiComicTileDynamicLoading> createState() =>
      _HitomiComicTileDynamicLoadingState();
}

class _HitomiComicTileDynamicLoadingState
    extends State<HitomiComicTileDynamicLoading> {
  HitomiComicBrief? comic;
  bool onScreen = true;

  static List<HitomiComicBrief> cache = [];

  @override
  void dispose() {
    onScreen = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (var cachedComic in cache) {
      var id = RegExp(r"\d+(?=\.html)").firstMatch(cachedComic.link)![0]!;
      if (id == widget.id.toString()) {
        comic = cachedComic;
      }
    }
    if (comic == null) {
      HiNetwork().getComicInfoBrief(widget.id.toString()).then((c) {
        if (c.error) {
          showToast(message: c.errorMessage!);
          return;
        }
        cache.add(c.data);
        if (onScreen) {
          setState(() {
            comic = c.data;
          });
        }
      });

      return buildLoadingWidget();
    } else {
      return buildComicTile(context, comic!, 'hitomi');
    }
  }

  Widget buildPlaceHolder() {
    return const ComicTilePlaceholder();
  }

  Widget buildLoadingWidget() {
    return Shimmer(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: buildPlaceHolder(),
    );
  }
}
