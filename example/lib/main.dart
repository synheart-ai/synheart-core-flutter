import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/consent_screen.dart';
import 'screens/diagnostics_screen.dart';
import 'screens/host_screen.dart';
import 'screens/session_screen.dart';
import 'screens/setup_screen.dart';
import 'sdk/synheart_controller.dart';

/// Synheart Core SDK — reference example.
///
/// Five tabs, one per step of the SDK lifecycle, in the order a host app
/// performs them:
///
///   Setup       → build a config and initialize
///   Consent     → the runtime editable-form flow
///   Session     → start collection, watch HSI arrive
///   Host        → what the host has to keep DOING once a session is live:
///                 the tick loop, rest declaration, snapshots, daily loop
///   Diagnostics → native runtime health
///
/// The Host tab is the one that is easy to skip and shouldn't be. Everything
/// before it is configuration; a host that stops there gets a session that
/// emits no windows from interaction, scores every break as engaged, and
/// re-warms its baselines from cold on every launch.
///
/// All SDK calls live in [SynheartController]. Screens only read state from it
/// and call its methods, so the integration is legible in one file.
///
/// This example is local-only: no cloud credentials, no device attestation.
/// See SETUP.md to enable cloud upload.
void main() {
  runApp(const SynheartExampleApp());
}

class SynheartExampleApp extends StatelessWidget {
  const SynheartExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SynheartController()..loadIdentity(),
      child: MaterialApp(
        title: 'Synheart Core Example',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3E5C76)),
          useMaterial3: true,
          cardTheme: CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
            ),
          ),
        ),
        home: const _HomeShell(),
      ),
    );
  }
}

class _HomeShell extends StatefulWidget {
  const _HomeShell();

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _index = 0;

  static const _screens = <Widget>[
    SetupScreen(),
    ConsentScreen(),
    SessionScreen(),
    HostScreen(),
    DiagnosticsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // Gate the later tabs on initialization: consent, session, and diagnostics
    // all read through the native runtime, which does not exist until
    // initialize() has run. Showing them as tappable-but-broken would teach the
    // wrong lifecycle.
    final ready = context.select<SynheartController, bool>(
      (c) => c.isInitialized,
    );

    return Scaffold(
      // The behavior gesture detector wraps the CONTENT, below this shell.
      //
      // Declaring `behaviorConfig` and granting behavior consent is not enough
      // on its own — the SDK cannot observe taps and typing rhythm without
      // sitting above the widget tree it should watch.
      //
      // It must go here rather than above MaterialApp: the SDK returns the
      // child unchanged until behavior consent is granted, so the wrapper
      // appears the moment consent flips. Higher up that changes the tree
      // shape above this State, remounting it and silently resetting the
      // selected tab. Below the shell, only the page subtree remounts.
      body: context.read<SynheartController>().wrapWithBehaviorDetector(
        _screens[ready ? _index : 0],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: ready ? _index : 0,
        onDestinationSelected: (i) {
          // Read at tap time rather than closing over the `ready` captured
          // during build: the captured value can be stale if this element
          // has not rebuilt since initialize() completed, which left the
          // later tabs unreachable with a "initialize first" toast even
          // though the SDK was ready.
          final isReady = context.read<SynheartController>().isInitialized;
          if (!isReady && i != 0) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                const SnackBar(
                  content: Text('Initialize the SDK first (Setup tab).'),
                ),
              );
            return;
          }
          setState(() => _index = i);
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'Setup',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.privacy_tip_outlined,
              color: ready ? null : Theme.of(context).disabledColor,
            ),
            selectedIcon: const Icon(Icons.privacy_tip),
            label: 'Consent',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.play_circle_outline,
              color: ready ? null : Theme.of(context).disabledColor,
            ),
            selectedIcon: const Icon(Icons.play_circle),
            label: 'Session',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.settings_input_antenna_outlined,
              color: ready ? null : Theme.of(context).disabledColor,
            ),
            selectedIcon: const Icon(Icons.settings_input_antenna),
            label: 'Host',
          ),
          NavigationDestination(
            icon: Icon(
              Icons.monitor_heart_outlined,
              color: ready ? null : Theme.of(context).disabledColor,
            ),
            selectedIcon: const Icon(Icons.monitor_heart),
            label: 'Runtime',
          ),
        ],
      ),
    );
  }
}
