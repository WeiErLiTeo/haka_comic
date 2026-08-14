import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FRB proxy bridge stays crate-owned and does not expose sysproxy', () {
    final yaml = File('flutter_rust_bridge.yaml').readAsStringSync();
    final generatedDart = Directory('lib/rust')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    expect(yaml, contains('rust_input: crate::api'));
    expect(yaml, isNot(contains('sysproxy')));
    expect(generatedDart, isNot(contains('sysproxy')));
    expect(File('lib/rust/api/proxy.dart').existsSync(), isFalse);
  });
}
