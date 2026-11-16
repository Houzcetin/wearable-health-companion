import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each upper bound is added NOT VALID before explicit validation', () {
    final sql = File(
      '../supabase/migrations/20261116010000_workout_bounds.sql',
    ).readAsStringSync().toLowerCase();
    for (final (column, bound) in [
      ('distance_m', 1000000),
      ('calories', 50000),
      ('steps', 500000),
    ]) {
      final name = 'workouts_${column}_upper_bound';
      final addition = RegExp(
        'add constraint $name\\s+check\\s*\\(\\s*$column\\s*<=\\s*$bound\\s*\\)\\s+not valid',
      ).firstMatch(sql);
      expect(addition, isNotNull, reason: '$column must use NOT VALID');
      final validation = sql.indexOf('validate constraint $name');
      expect(validation, greaterThan(addition!.end));
      expect(sql.indexOf(';', addition.end), lessThan(validation));
    }
  });
}
