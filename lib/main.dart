import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'providers/app_state.dart';
import 'theme/app_theme.dart';
import 'views/home_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the media_kit/libmpv backend used by the video/audio viewers.
  MediaKit.ensureInitialized();

  runApp(
    ChangeNotifierProvider(
      create: (context) => AppState(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // Re-resolve the theme when the OS switches light/dark while we are in
    // "system" mode.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Watch only the theme choice, not the whole AppState. Otherwise every
    // notifyListeners() (file loads, editor edits, session changes…) would
    // rebuild MaterialApp and reallocate ThemeData for the entire app.
    final themeChoice =
        context.select<AppState, AppThemeChoice>((s) => s.themeChoice);
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    // Keep the static palette in sync with the active theme before the tree
    // builds, since widgets read AppColors.* directly.
    AppColors.apply(themeChoice, platformBrightness);

    return MaterialApp(
      title: 'KALA',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(themeChoice, platformBrightness),
      home: const HomeView(),
    );
  }
}
