import 'package:web/web.dart' as web;

import 'storage.dart';

Future<Slots> openSlots() async => BrowserSlots();

class BrowserSlots implements Slots {
  @override
  Future<String?> read(int index) async =>
      web.window.localStorage.getItem('ll-love-learn-journal-$index');

  @override
  Future<void> write(int index, String data) async =>
      web.window.localStorage.setItem('ll-love-learn-journal-$index', data);
}
