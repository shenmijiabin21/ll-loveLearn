import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'storage.dart';

Future<Slots> openSlots() async =>
    NativeSlots(await getApplicationSupportDirectory());

class NativeSlots implements Slots {
  NativeSlots(this.directory);
  final Directory directory;

  File _slot(int index) =>
      File('${directory.path}${Platform.pathSeparator}journal-$index.json');

  @override
  Future<String?> read(int index) async {
    final file = _slot(index);
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> write(int index, String data) async {
    await directory.create(recursive: true);
    final destination = _slot(index);
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsString(data, flush: true);
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
  }
}
