import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/agent_monitor.dart';
import '../theme/app_theme.dart';

/// How many sessions are waiting on an answer, drawn wherever the dashboard is
/// reachable from.
///
/// This is arguably worth more than the screen it points at: the cost of an
/// agent waiting is the time before you notice, and a count on the drawer entry
/// closes that gap without anyone opening anything.
///
/// Each of these subscribes to [AgentMonitor] on its own — the badge rebuilds,
/// never the rail or the drawer around it.
class AgentWaitingBadge extends StatelessWidget {
  /// Draws a filled count chip (drawer, rail). When false only a dot is drawn,
  /// for places with no room for a number.
  final bool showCount;

  const AgentWaitingBadge({super.key, this.showCount = true});

  @override
  Widget build(BuildContext context) {
    // watch, not select: the monitor is a separate notifier precisely so this
    // subscription is cheap.
    final waiting = context.watch<AgentMonitor>().waitingCount;
    if (waiting == 0) return const SizedBox.shrink();

    if (!showCount) {
      return Container(
        width: 7,
        height: 7,
        decoration:
            BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: AppColors.accent)),
      child: Text('$waiting',
          style: AppText.mono(9, color: AppColors.accent, spacing: 0.5)),
    );
  }
}
