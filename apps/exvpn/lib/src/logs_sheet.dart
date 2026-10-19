// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/client_logs.dart';
import 'app_strings.dart';

class LogsSheet extends StatefulWidget {
  const LogsSheet({
    super.key,
    required this.logs,
    required this.diagnosticsBuilder,
  });
  final ClientLogs logs;
  final String Function() diagnosticsBuilder;

  @override
  State<LogsSheet> createState() => _LogsSheetState();
}

class _LogsSheetState extends State<LogsSheet> {
  bool _copying = false;

  Future<void> _copy() async {
    if (_copying) return;
    setState(() => _copying = true);
    var message = 'Скопировано';
    try {
      final report = widget.logs.buildReport(widget.diagnosticsBuilder());
      await Clipboard.setData(ClipboardData(text: report));
    } catch (_) {
      message = 'Не удалось скопировать логи';
    } finally {
      if (mounted) {
        setState(() => _copying = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.tr(message))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.logs,
    builder: (context, _) {
      String? report;
      try {
        report = widget.logs.buildReport(widget.diagnosticsBuilder());
      } catch (_) {
        // A provider/backend exception is never rendered as a log line.
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(context.tr('Логи')),
          actions: [
            IconButton(
              key: const ValueKey('client-logs-clear'),
              tooltip: context.tr('Очистить логи'),
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () {
                widget.logs.clear();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('Логи очищены'))),
                );
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    report ?? context.tr('Не удалось подготовить логи'),
                    key: const ValueKey('client-logs-report'),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace', height: 1.45),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('client-logs-copy'),
                    onPressed: report == null || _copying ? null : _copy,
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: Text(context.tr('Скопировать')),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
