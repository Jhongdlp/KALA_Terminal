import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../theme/app_theme.dart';
import '../widgets/media_playback_bar.dart';

/// Embedded video player for the editor tab, backed by media_kit/libmpv.
/// [path] is a local filesystem path — remote (SFTP) files are downloaded to
/// a temp copy by AppState before this view is shown.
class VideoView extends StatefulWidget {
  final String path;

  const VideoView({super.key, required this.path});

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> {
  late final Player _player;
  late final VideoController _controller;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
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
            child: Video(
              controller: _controller,
              controls: NoVideoControls,
              fill: AppColors.ink,
            ),
          ),
          MediaPlaybackBar(player: _player),
        ],
      ),
    );
  }
}
