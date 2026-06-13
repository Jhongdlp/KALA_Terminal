import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import '../theme/app_theme.dart';

/// Play/pause + seek bar + time readout shared by the video and audio
/// viewers, styled to match the flat IDE theme rather than the default
/// Material slider chrome.
class MediaPlaybackBar extends StatefulWidget {
  final Player player;

  const MediaPlaybackBar({super.key, required this.player});

  @override
  State<MediaPlaybackBar> createState() => _MediaPlaybackBarState();
}

class _MediaPlaybackBarState extends State<MediaPlaybackBar> {
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  late final List<StreamSubscription<dynamic>> _subscriptions;

  @override
  void initState() {
    super.initState();
    final player = widget.player;
    _playing = player.state.playing;
    _position = player.state.position;
    _duration = player.state.duration;
    _subscriptions = [
      player.stream.playing.listen((v) => setState(() => _playing = v)),
      player.stream.position.listen((v) => setState(() => _position = v)),
      player.stream.duration.listen((v) => setState(() => _duration = v)),
    ];
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds.clamp(0, totalMs == 0 ? 0 : totalMs);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.hairline, width: 1)),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: () =>
                _playing ? widget.player.pause() : widget.player.play(),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(_playing ? Icons.pause : Icons.play_arrow,
                  color: AppColors.bone, size: 20),
            ),
          ),
          Text(_format(_position),
              style: AppText.mono(10, color: AppColors.muted)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: AppColors.bone,
                inactiveTrackColor: AppColors.hairline,
                thumbColor: AppColors.bone,
              ),
              child: Slider(
                value: totalMs == 0 ? 0 : posMs.toDouble(),
                min: 0,
                max: totalMs == 0 ? 1 : totalMs.toDouble(),
                onChanged: totalMs == 0
                    ? null
                    : (v) =>
                        widget.player.seek(Duration(milliseconds: v.round())),
              ),
            ),
          ),
          Text(_format(_duration),
              style: AppText.mono(10, color: AppColors.muted)),
        ],
      ),
    );
  }
}
