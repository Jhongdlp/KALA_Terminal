import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'l10n/l10n.dart';
import 'providers/app_state.dart';
import 'services/tunnel_manager.dart';
import 'theme/app_theme.dart';
import 'views/home_view.dart';
import 'views/host_key_dialog.dart';
import 'views/lock_screen.dart';

/// Lets code outside the widget tree (host key confirmation) reach a
/// BuildContext.
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the media_kit/libmpv backend used by the video/audio viewers.
  MediaKit.ensureInitialized();

  // Resolve the UI language before the first frame, otherwise the app would
  // flash in Spanish and then swap.
  await L10n.load();

  final appState = AppState();

  // Host key confirmation needs a dialog, and connections start from AppState
  // (which has no BuildContext) — so the UI plugs itself in here. If no context
  // is available the handler returns false, i.e. an unverified server is
  // refused rather than silently trusted.
  appState.hostKeyConfirm = (challenge) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    return showHostKeyDialog(ctx, challenge);
  };

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        // Tunnels notify on every traffic tick; exposing the manager on its own
        // keeps those rebuilds inside the tunnels UI instead of the whole app.
        // AppState owns it, so it must not be disposed twice.
        ChangeNotifierProvider<TunnelManager>.value(value: appState.tunnels),
      ],
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
    final accentColorHex =
        context.select<AppState, String>((s) => s.accentColorHex);
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    // Keep the static palette in sync with the active theme before the tree
    // builds, since widgets read AppColors.* directly.
    AppColors.apply(themeChoice, platformBrightness, accentColorHex: accentColorHex);

    // `tr()` reads a global, not an InheritedWidget, so a language change has
    // nothing to notify. Rebuilding MaterialApp under a new key remounts the
    // tree and re-runs every tr() call; sessions and settings live in AppState,
    // so nothing the user cares about is lost.
    return ValueListenableBuilder<AppLang>(
      valueListenable: L10n.notifier,
      builder: (context, lang, _) => MaterialApp(
        key: ValueKey(lang),
        title: 'KAMMEL SSH',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        locale: Locale(lang.code),
        supportedLocales: AppLang.values.map((l) => Locale(l.code)),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: AppTheme.themeFor(themeChoice, platformBrightness,
            accentColorHex: accentColorHex),
        home: const _LockGate(),
      ),
    );
  }
}

/// Decides between the lock screen and the app shell. Until settings have
/// loaded it shows a blank ink screen so the shell never flashes behind the
/// lock on a locked launch.
class _LockGate extends StatelessWidget {
  const _LockGate();

  @override
  Widget build(BuildContext context) {
    final settingsLoaded =
        context.select<AppState, bool>((s) => s.settingsLoaded);
    final requiresUnlock =
        context.select<AppState, bool>((s) => s.requiresUnlock);

    if (!settingsLoaded) {
      return Scaffold(backgroundColor: AppColors.ink, body: const SizedBox());
    }
    if (requiresUnlock) return const LockScreen();
    return const HomeView();
  }
}
