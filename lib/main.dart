import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'l10n/l10n.dart';
import 'providers/app_state.dart';
import 'services/agent_monitor.dart';
import 'services/tunnel_manager.dart';
import 'services/window_geometry.dart';
import 'theme/app_theme.dart';
import 'views/home_view.dart';
import 'views/host_key_dialog.dart';
import 'views/lock_screen.dart';
import 'views/shell/window_title_bar.dart';

/// Lets code outside the widget tree (host key confirmation) reach a
/// BuildContext.
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the media_kit/libmpv backend used by the video/audio viewers.
  MediaKit.ensureInitialized();

  // Restore the window box before the first frame, so the app doesn't appear
  // at the GTK default and then jump. Also installs a minimum size, which the
  // stock runner never set — the window could be shrunk to nothing.
  if (isDesktopPlatform) {
    await windowManager.ensureInitialized();
    final geometry = await WindowGeometry.load();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: geometry.size,
        minimumSize: WindowGeometry.minimumSize,
        title: 'KAMMEL SSH',
        // The app draws its own title bar (WindowTitleBar). Applied here,
        // inside waitUntilReadyToShow, so the GTK header bar is gone before
        // the window is ever put on screen instead of flashing first.
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        if (geometry.position != null) {
          await windowManager.setPosition(geometry.position!);
        }
        if (geometry.maximized) await windowManager.maximize();
        await windowManager.show();
      },
    );
    geometry.attach();
  }

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
        // Same split, same reason: the agent watch loop re-reads a session's
        // screen several times a second, and only the dashboard and its badge
        // care. AppState owns it — do not dispose it here.
        ChangeNotifierProvider<AgentMonitor>.value(value: appState.agents),
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
    // nothing to notify: the tree has to be remounted for every tr() call to
    // re-run. That remount happens *inside* the navigator (see `_LockGate`),
    // not by keying MaterialApp — `navigatorKey` is a GlobalKey, so a new key
    // here only re-parents the existing Navigator into the new app instead of
    // rebuilding it, and everything that doesn't depend on an InheritedWidget
    // (a plain `Text(tr(…))`, a const panel) would keep the old language.
    // Sessions and settings live in AppState, so the remount loses nothing.
    return ValueListenableBuilder<AppLang>(
      valueListenable: L10n.notifier,
      builder: (context, lang, _) => MaterialApp(
        title: 'KAMMEL SSH',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        locale: Locale(lang.code),
        supportedLocales: AppLang.values.map((l) => Locale(l.code)),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: AppTheme.themeFor(themeChoice, platformBrightness,
            accentColorHex: accentColorHex),
        // The custom title bar goes above the navigator, so it stays put over
        // every route — dialogs and sheets render below it, which is what the
        // native bar did too. Rebuilt with MaterialApp on a language change,
        // so its tooltips follow the language like everything else.
        // Text scaling and, on desktop, the custom title bar. The scaler wraps
        // *everything* including routes, which is the only place it can go: a
        // MediaQuery override inside HomeView would leave dialogs and sheets
        // (their own routes, siblings of the shell) unscaled.
        builder: (context, child) {
          final scaled = _TextScaleGate(child: child ?? const SizedBox());
          if (!isDesktopPlatform) return scaled;
          return Column(
            children: [
              const WindowTitleBar(),
              Expanded(child: scaled),
            ],
          );
        },
        home: const _LockGate(),
      ),
    );
  }
}


/// Applies the app's own text-size preference on top of the system's, and caps
/// the product.
///
/// The cap is not paternalism: the shell is built from fixed-height bars (46px
/// terminal toolbar, 42px explorer path bar, 30px panel titles) whose labels
/// simply stop fitting past it. Growing text until the controls it labels are
/// unreadable helps nobody, so it stops there — and the app multiplier means a
/// user who wants bigger text still gets it without touching the system.
class _TextScaleGate extends StatelessWidget {
  final Widget child;
  const _TextScaleGate({required this.child});

  @override
  Widget build(BuildContext context) {
    final appScale = context.select<AppState, double>((s) => s.textScale);
    final media = MediaQuery.of(context);
    // TextScaler is non-linear on newer Androids, so ask it what it does to a
    // reference size rather than assuming a factor.
    final systemScale = media.textScaler.scale(14) / 14;
    final effective =
        (systemScale * appScale).clamp(0.8, AppState.maxEffectiveTextScale);

    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.linear(effective)),
      child: child,
    );
  }
}

/// Decides between the lock screen and the app shell. Until settings have
/// loaded it shows a blank ink screen so the shell never flashes behind the
/// lock on a locked launch.
///
/// Also the anchor for the language remount: this sits below the navigator, so
/// listening to [L10n.notifier] here is the one place guaranteed to rebuild on
/// a language change (routes above don't necessarily rebuild when MaterialApp
/// does). The [KeyedSubtree] key change is what unmounts the whole app content
/// and inflates it again, so every `tr()` call re-runs — including the ones in
/// `const` widgets, which are otherwise never rebuilt.
class _LockGate extends StatelessWidget {
  const _LockGate();

  @override
  Widget build(BuildContext context) {
    final settingsLoaded =
        context.select<AppState, bool>((s) => s.settingsLoaded);
    final requiresUnlock =
        context.select<AppState, bool>((s) => s.requiresUnlock);

    return ValueListenableBuilder<AppLang>(
      valueListenable: L10n.notifier,
      builder: (context, lang, _) => KeyedSubtree(
        key: ValueKey(lang),
        child: !settingsLoaded
            ? Scaffold(backgroundColor: AppColors.ink, body: const SizedBox())
            : requiresUnlock
                ? const LockScreen()
                : const HomeView(),
      ),
    );
  }
}
