import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../env.dart';

/// True when the app runs on built-in sample data: `--dart-define=DEMO_MODE=true`.
final demoModeProvider = Provider<bool>((ref) => Env.demoMode);
