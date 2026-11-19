import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib has no integer shifts or clamp bounds unsafe on JavaScript', () {
    final unsafeShift = RegExp(r'(?:<<|>>)\s*(?:3[2-9]|[4-9]\d|\d{3,})\b');
    final shiftedClamp = RegExp(r'\.clamp\(\s*0\s*,\s*1\s*<<');
    final violations = <String>[];
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final pattern in [unsafeShift, shiftedClamp]) {
        for (final match in pattern.allMatches(source)) {
          final line =
              '\n'.allMatches(source.substring(0, match.start)).length + 1;
          violations.add('${file.path}:$line: ${match.group(0)}');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
