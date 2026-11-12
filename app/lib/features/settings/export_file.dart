import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/daily_metrics.dart';

String exportFileName(DateTime date) =>
    'wearable-companion-export-${dateKey(date)}.json';

ShareParams exportShareParams(String json, DateTime date, {Rect? origin}) {
  final name = exportFileName(date);
  return ShareParams(
    files: [
      XFile.fromData(Uint8List.fromList(utf8.encode(json)),
        mimeType: 'application/json', name: name),
    ],
    fileNameOverrides: [name],
    sharePositionOrigin: origin,
  );
}
