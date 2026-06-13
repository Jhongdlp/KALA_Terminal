import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import '../theme/app_theme.dart';
import '../widgets/media_playback_bar.dart';

/// Embedded audio player for the editor tab, backed by media_kit. [path] is a
/// local filesystem path — remote (SFTP) files are downloaded to a temp copy
/// by AppState before this view is shown. [filename] is shown above the
/// playback controls.
class AudioView extends StatefulWidget {
  final String path;
  final String filename;

  const AudioView({super.key, required this.path, required this.filename});

  @override
  State<AudioView> createState() => _AudioViewState();
}

class _AudioViewState extends State<AudioView> {
  late final Player _player;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _player.open(Media(widget.path));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.ink,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.audiotrack, size: 64, color: AppColors.faint),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      widget.filename,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.mono(12, color: AppColors.bone),
                    ),
                  ),
                ],
              ),
            ),
          ),
          MediaPlaybackBar(player: _player),
        ],
      ),
    );
  }
}
