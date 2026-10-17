import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

@immutable
class SlidingSegment<T> {
  const SlidingSegment({
    required this.value,
    this.icon,
    this.label,
    this.tooltip,
  });

  final T value;
  final IconData? icon;
  final String? label;
  final String? tooltip;
}

/// A shared segmented control. Only the selection moves; labels remain still.
class SlidingSegments<T> extends StatelessWidget {
  const SlidingSegments({
    super.key,
    required this.items,
    required this.value,
    this.onChanged,
    this.width,
    this.height = 36,
    this.showBackground = true,
    this.iconSize = 18,
  }) : assert(items.length > 0),
       assert(height >= 24);

  final List<SlidingSegment<T>> items;
  final T value;
  final ValueChanged<T>? onChanged;
  final double? width;
  final double height;
  final bool showBackground;
  final double iconSize;

  void _move(BuildContext context, int offset) {
    if (onChanged == null) return;
    final current = items.indexWhere((item) => item.value == value);
    final next = (current + offset).clamp(0, items.length - 1);
    if (items[next].value != value) onChanged!(items[next].value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final selection = items.indexWhere((item) => item.value == value);
    final nominalWidth =
        width ??
        items.length * (items.any((item) => item.label != null) ? 88.0 : 32.0);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveWidth = constraints.hasBoundedWidth
            ? nominalWidth.clamp(0.0, constraints.maxWidth).toDouble()
            : nominalWidth;
        const padding = 3.0;
        const gap = 3.0;
        final itemWidth =
            (effectiveWidth - padding * 2 - gap * (items.length - 1)) /
            items.length;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _move(context, rtl ? 1 : -1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _move(context, rtl ? -1 : 1),
            const SingleActivator(LogicalKeyboardKey.home): () {
              if (onChanged != null) onChanged!(items.first.value);
            },
            const SingleActivator(LogicalKeyboardKey.end): () {
              if (onChanged != null) onChanged!(items.last.value);
            },
          },
          child: FocusTraversalGroup(
            child: SizedBox(
              width: effectiveWidth,
              height: height,
              child: Opacity(
                opacity: onChanged == null ? .5 : 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: showBackground
                        ? scheme.onSurface.withValues(alpha: .045)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                    border: showBackground
                        ? Border.all(
                            color: scheme.outlineVariant.withValues(alpha: .65),
                            width: .6,
                          )
                        : null,
                  ),
                  child: Stack(
                    children: [
                      if (selection >= 0)
                        AnimatedPositionedDirectional(
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          start: padding + selection * (itemWidth + gap),
                          top: padding,
                          width: itemWidth,
                          height: height - padding * 2,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: .14),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.all(padding),
                          child: Row(
                            children: [
                              for (
                                var index = 0;
                                index < items.length;
                                index++
                              ) ...[
                                if (index > 0) const SizedBox(width: gap),
                                Expanded(child: _item(context, items[index])),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _item(BuildContext context, SlidingSegment<T> item) {
    final selected = item.value == value;
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    final child = Semantics(
      button: true,
      selected: selected,
      enabled: onChanged != null,
      label: item.label ?? item.tooltip,
      onTap: onChanged == null ? null : () => onChanged!(item.value),
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onChanged == null ? null : () => onChanged!(item.value),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: item.label == null ? 0 : 4,
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.icon != null)
                      Icon(item.icon, size: iconSize, color: color),
                    if (item.icon != null && item.label != null)
                      const SizedBox(width: 5),
                    if (item.label != null)
                      Flexible(
                        child: Text(
                          item.label!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: color,
                            letterSpacing: .3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return item.tooltip == null
        ? child
        : Tooltip(
            message: item.tooltip!,
            excludeFromSemantics: true,
            child: child,
          );
  }
}
