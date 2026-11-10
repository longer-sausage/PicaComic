import 'package:flutter/material.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart' show showToast;
import 'package:pica_comic/foundation/search_query.dart';
import 'package:pica_comic/foundation/search_query_controller.dart';
import 'package:pica_comic/tools/translations.dart';

/// The same query editor is used before searching and on every result page.
class SearchQueryBar extends StatelessWidget {
  const SearchQueryBar({
    super.key,
    required this.controller,
    required this.sourceKey,
    required this.options,
    required this.onSearch,
    this.onChanged,
    this.focusNode,
    this.trailing,
    this.hintText,
  });

  final SearchQueryController controller;
  final String sourceKey;
  final List<String> options;
  final VoidCallback onSearch;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final Widget? trailing;
  final String? hintText;

  static double heightFor(SearchQueryController controller) =>
      controller.tags.isEmpty ? 60 : 104;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, appdata.favoriteSearches]),
      builder: (context, _) {
        final savedSearch = SavedSearch(
          sourceKey: sourceKey,
          query: controller.query,
          options: options,
        );
        final isSaved = appdata.favoriteSearches.value.contains(savedSearch);
        final colors = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Material(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        _button(
                          icon: Icons.arrow_back,
                          tooltip: '返回'.tl,
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        Expanded(
                          child: TextField(
                            controller: controller.textController,
                            focusNode: focusNode,
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: hintText ?? '搜索'.tl,
                            ),
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) => onSearch(),
                            onChanged: onChanged,
                          ),
                        ),
                        if (!controller.query.isEmpty)
                          _button(
                            icon: Icons.clear_rounded,
                            tooltip: '清除'.tl,
                            onPressed: () {
                              controller.clear();
                              onChanged?.call('');
                              focusNode?.requestFocus();
                            },
                          ),
                        _button(
                          icon: isSaved ? Icons.star : Icons.star_border,
                          tooltip: (isSaved ? '取消收藏搜索组合' : '收藏搜索组合').tl,
                          onPressed: () async {
                            try {
                              await appdata.toggleFavoriteSearch(savedSearch);
                            } catch (_) {
                              showToast(message: '保存失败'.tl);
                            }
                          },
                        ),
                        _button(
                          icon: Icons.search,
                          tooltip: '搜索'.tl,
                          onPressed: onSearch,
                        ),
                        if (trailing != null) trailing!,
                      ],
                    ),
                  ),
                ),
                if (controller.tags.isNotEmpty)
                  _SearchTags(
                    tags: controller.tags,
                    onDeleted: (tag) {
                      controller.removeTag(tag);
                      focusNode?.requestFocus();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _button({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) =>
      IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      );
}

class _SearchTags extends StatefulWidget {
  const _SearchTags({required this.tags, required this.onDeleted});

  final List<SearchTag> tags;
  final ValueChanged<SearchTag> onDeleted;

  @override
  State<_SearchTags> createState() => _SearchTagsState();
}

class _SearchTagsState extends State<_SearchTags> {
  final scrollController = ScrollController();

  void revealLastTag() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    revealLastTag();
  }

  @override
  void didUpdateWidget(covariant _SearchTags oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tags.length > oldWidget.tags.length ||
        widget.tags.last != oldWidget.tags.last) {
      revealLastTag();
    }
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 44,
        child: SingleChildScrollView(
          controller: scrollController,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              for (final tag in widget.tags)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * 0.7),
                    child: Tooltip(
                      message: tag.label,
                      child: InputChip(
                        key: ValueKey(tag),
                        label: Text(tag.label,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        deleteButtonTooltipMessage: '删除标签'.tl,
                        onDeleted: () => widget.onDeleted(tag),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}
