import 'package:flutter/material.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart' show showToast;
import 'package:pica_comic/foundation/search_query.dart';
import 'package:pica_comic/tools/translations.dart';

class SearchFavorites extends StatelessWidget {
  const SearchFavorites({
    super.key,
    required this.sourceKey,
    required this.onSelected,
  });

  final String sourceKey;
  final ValueChanged<SavedSearch> onSelected;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<SavedSearch>>(
      valueListenable: appdata.favoriteSearches,
      builder: (context, searches, _) {
        final favorites =
            searches.where((search) => search.sourceKey == sourceKey).toList();
        final data = ComicSource.find(sourceKey)?.searchPageData;
        return ExpansionTile(
          key: PageStorageKey('search-favorites-$sourceKey'),
          leading: const Icon(Icons.folder_special_outlined),
          title: Text('${'收藏夹'.tl} (${favorites.length})'),
          children: [
            if (favorites.isEmpty) ListTile(title: Text('暂无收藏的搜索组合'.tl)),
            for (final search in favorites)
              ListTile(
                title: Text(
                  search.query.isEmpty
                      ? '全部'.tl
                      : search.query.keywordFor(sourceKey),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: search.options.isEmpty
                    ? null
                    : Text([
                        for (var i = 0; i < search.options.length; i++)
                          if (data?.searchOptions != null &&
                              i < data!.searchOptions!.length)
                            '${data.searchOptions![i].label.tl}: '
                                '${(data.searchOptions![i].options[search.options[i]] ?? search.options[i]).tl}'
                          else
                            search.options[i],
                      ].join(' · ')),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '删除搜索组合'.tl,
                  onPressed: () async {
                    try {
                      await appdata.removeFavoriteSearch(search);
                    } catch (_) {
                      showToast(message: '保存失败'.tl);
                    }
                  },
                ),
                onTap: () => onSelected(search),
              ),
          ],
        );
      },
    );
  }
}
