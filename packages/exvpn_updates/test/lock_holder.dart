// SPDX-License-Identifier: Apache-2.0
// Separate process: POSIX file locks are associated with the owning process.
import 'dart:io';

Future<void> main(List<String> args) async {
  final handle = await File(args.single).open(mode: FileMode.append);
  try {
    await handle.lock(FileLock.exclusive);
    stdout.writeln('locked');
    await stdin.first;
  } finally {
    await handle.close();
  }
}
