import 'dart:convert';

import 'domain.dart';
import 'storage_native.dart'
    if (dart.library.js_interop) 'storage_web.dart'
    as platform;

abstract interface class Slots {
  Future<String?> read(int index);
  Future<void> write(int index, String data);
}

abstract interface class JournalRepository {
  Future<Journal?> load();
  Future<void> save(Journal journal);
}

class JournalStore implements JournalRepository {
  JournalStore(this.slots);

  final Slots slots;
  int _revision = 0;
  Future<void> _writes = Future.value();

  static Future<JournalStore> open() async =>
      JournalStore(await platform.openSlots());

  Future<Journal?> load() async {
    Journal? result;
    var found = false;
    for (var index = 0; index < 2; index++) {
      final raw = await slots.read(index);
      if (raw == null) continue;
      found = true;
      try {
        final envelope = object(jsonDecode(raw));
        final revision = integer(envelope['revision'], 1, 9007199254740991);
        if (revision <= _revision) continue;
        result = Journal.fromJson(envelope['journal']);
        _revision = revision;
      } on Exception {
        continue;
      } on TypeError {
        continue;
      } on ArgumentError {
        continue;
      }
    }
    if (found && result == null) throw const FormatException('本地记录无法读取');
    return result;
  }

  Future<void> save(Journal journal) {
    final snapshot = jsonEncode(journal);
    final write = _writes.then((_) async {
      final revision = _revision + 1;
      final envelope = '{"revision":$revision,"journal":$snapshot}';
      await slots.write(revision % 2, envelope);
      _revision = revision;
    });
    _writes = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace trace) {},
    );
    return write;
  }
}
