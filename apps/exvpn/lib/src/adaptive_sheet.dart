// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import 'tv_presentation.dart';

/// Touch devices keep their draggable sheet; TV uses a centered dialog.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool showDragHandle = false,
  ShapeBorder? shape,
  BoxConstraints? constraints,
}) {
  if (!TvPresentation.of(context)) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      shape: shape,
      constraints: constraints,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      key: const Key('tv-centered-sheet'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: constraints?.maxWidth.isFinite == true
              ? constraints!.maxWidth
              : 640,
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: builder(context),
        ),
      ),
    ),
  );
}
