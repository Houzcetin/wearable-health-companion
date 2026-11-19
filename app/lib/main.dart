import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/demo/demo_overrides.dart';
import 'core/env.dart';
import 'core/router.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Demo mode never contacts a backend, even when SUPABASE_* are defined.
  if (Env.hasBackend && !Env.demoMode) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabasePublishableKey,
    );
  }
  runApp(
    ProviderScope(
      overrides: Env.demoMode ? demoOverrides() : const [],
      child: const HealthCompanionApp(),
    ),
  );
}

class HealthCompanionApp extends ConsumerWidget {
  const HealthCompanionApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Wearable Health Companion',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
