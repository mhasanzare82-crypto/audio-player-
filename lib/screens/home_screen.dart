import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/audio_track.dart';
import '../services/library_store.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
  });

  final bool isDark;
  final VoidCallback onToggleTheme;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioPlayer _player = AudioPlayer();
  final LibraryStore _store = LibraryStore();
  final List<AudioTrack> _tracks = [];
  Map<String, String> _lyrics = {};
  int _currentIndex = -1;
  bool _loading = true;
  bool _shuffle = false;
  LoopMode _loopMode = LoopMode.off;
  double _speed = 1;

  AudioTrack? get _currentTrack =>
      _currentIndex >= 0 && _currentIndex < _tracks.length
          ? _tracks[_currentIndex]
          : null;

  @override
  void initState() {
    super.initState();
    _restoreLibrary();
    _player.currentIndexStream.listen((index) {
      if (!mounted) return;
      setState(() => _currentIndex = index ?? -1);
    });
    _player.shuffleModeEnabledStream.listen((value) {
      if (mounted) setState(() => _shuffle = value);
    });
    _player.loopModeStream.listen((value) {
      if (mounted) setState(() => _loopMode = value);
    });
  }

  Future<void> _restoreLibrary() async {
    try {
      final saved = await _store.loadTracks();
      final lyrics = await _store.loadLyrics();
      final available = saved.where((track) => File(track.path).existsSync()).toList();
      if (!mounted) return;
      setState(() {
        _tracks.addAll(available);
        _lyrics = lyrics;
        _loading = false;
      });
      if (_tracks.isNotEmpty) {
        await _replacePlaylist(autoplay: false);
      }
      if (available.length != saved.length) {
        await _store.saveTracks(_tracks);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _persistTracks() => _store.saveTracks(_tracks);

  Future<void> _pickAudio() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'flac', 'aac', 'm4a'],
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;

      final directory = await getApplicationDocumentsDirectory();
      final added = <AudioTrack>[];
      for (final item in result.files) {
        final sourcePath = item.path;
        if (sourcePath == null) continue;
        final extension = item.extension?.toLowerCase() ?? '';
        if (!['mp3', 'wav', 'flac', 'aac', 'm4a'].contains(extension)) {
          continue;
        }
        final source = File(sourcePath);
        if (!await source.exists()) continue;

        final safeName = item.name.replaceAll(RegExp(r'[^\w.\- ]'), '_');
        final destination = File(
          '${directory.path}/${DateTime.now().microsecondsSinceEpoch}_$safeName',
        );
        await source.copy(destination.path);
        added.add(AudioTrack(
          path: destination.path,
          title: item.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        ));
      }

      if (added.isEmpty) {
        _showMessage('فایل قابل استفاده‌ای انتخاب نشد.');
        return;
      }
      setState(() => _tracks.addAll(added));
      await _persistTracks();
      await _replacePlaylist(autoplay: _currentIndex < 0);
      _showMessage('${added.length} فایل به کتابخانه اضافه شد.');
    } catch (error) {
      _showMessage('افزودن فایل ناموفق بود: $error');
    }
  }

  Future<void> _replacePlaylist({required bool autoplay}) async {
    if (_tracks.isEmpty) {
      await _player.stop();
      return;
    }
    final oldIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _tracks.length - 1).toInt();
    final sources = _tracks
        .map((track) => AudioSource.uri(Uri.file(track.path)))
        .toList();
    await _player.setAudioSources(
      sources,
      initialIndex: oldIndex,
      initialPosition: Duration.zero,
    );
    if (autoplay) await _player.play();
  }

  Future<void> _playTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    try {
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      await _player.seek(Duration.zero, index: index);
      await _player.play();
    } catch (error) {
      _showMessage('پخش این فایل ممکن نشد: $error');
    }
  }

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _lyrics.remove(removed.path);
    await _store.saveLyrics(_lyrics);
    await _persistTracks();
    if (_tracks.isEmpty) {
      await _player.stop();
      setState(() => _currentIndex = -1);
    } else {
      await _replacePlaylist(autoplay: false);
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveLyrics(String path, String value) async {
    _lyrics[path] = value;
    await _store.saveLyrics(_lyrics);
  }

  Future<void> _toggleShuffle() async {
    await _player.setShuffleModeEnabled(!_shuffle);
  }

  Future<void> _cycleRepeat() async {
    final next = switch (_loopMode) {
      LoopMode.off => LoopMode.one,
      LoopMode.one => LoopMode.all,
      LoopMode.all => LoopMode.off,
    };
    await _player.setLoopMode(next);
  }

  Future<void> _seekRelative(int seconds) async {
    final duration = _player.duration ?? Duration.zero;
    final next = _player.position + Duration(seconds: seconds);
    final bounded = next < Duration.zero
        ? Duration.zero
        : next > duration
            ? duration
            : next;
    await _player.seek(bounded);
  }

  String _formatDuration(Duration value) {
    String two(int n) => n.toString().padLeft(2, '0');
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    return hours > 0
        ? '${two(hours)}:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'پلیر صوتی',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          actions: [
            IconButton(
              tooltip: widget.isDark ? 'تم روشن' : 'تم تاریک',
              onPressed: widget.onToggleTheme,
              icon: Icon(widget.isDark ? Icons.light_mode : Icons.dark_mode),
            ),
            const SizedBox(width: 6),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.library_music_outlined), text: 'کتابخانه صوتی'),
              Tab(icon: Icon(Icons.notes_rounded), text: 'متن ویس'),
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: TabBarView(
                children: [
                  _buildLibraryTab(colors),
                  _buildLyricsTab(colors),
                ],
              ),
            ),
            _buildPlayerPanel(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'کتابخانه من',
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_tracks.length} فایل صوتی',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _pickAudio,
                icon: const Icon(Icons.add),
                label: const Text('افزودن فایل'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _tracks.isEmpty
              ? _emptyLibrary(colors)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  itemCount: _tracks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 7),
                  itemBuilder: (context, index) {
                    final track = _tracks[index];
                    final selected = index == _currentIndex;
                    final extension = track.path.split('.').last.toUpperCase();
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 5,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: selected
                              ? colors.primaryContainer
                              : colors.surfaceContainerHighest,
                          child: Icon(
                            selected ? Icons.equalizer : Icons.music_note,
                            color: selected
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                        ),
                        title: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(extension),
                        onTap: () => _playTrack(index),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'play') _playTrack(index);
                            if (value == 'remove') _removeTrack(index);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'play', child: Text('پخش')),
                            PopupMenuItem(value: 'remove', child: Text('حذف از کتابخانه')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _emptyLibrary(ColorScheme colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.audio_file_outlined, size: 68, color: colors.primary),
            const SizedBox(height: 16),
            const Text(
              'هنوز فایلی اضافه نکرده‌ای',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'فایل‌های MP3، WAV، FLAC، AAC و M4A را از حافظه گوشی انتخاب کن.',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _pickAudio,
              icon: const Icon(Icons.add),
              label: const Text('انتخاب فایل صوتی'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLyricsTab(ColorScheme colors) {
    final track = _currentTrack;
    if (track == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.edit_note, size: 64, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'برای نوشتن متن، ابتدا یک ویس انتخاب کن.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'متن هر فایل جداگانه ذخیره می‌شود.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return _LyricsEditor(
      key: ValueKey(track.path),
      track: track,
      initialText: _lyrics[track.path] ?? '',
      onSave: (value) => _saveLyrics(track.path, value),
    );
  }

  Widget _buildPlayerPanel(ColorScheme colors) {
    final track = _currentTrack;
    return Material(
      color: colors.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.graphic_eq, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      track?.title ?? 'فایلی برای پخش انتخاب نشده',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  PopupMenuButton<double>(
                    tooltip: 'سرعت پخش',
                    initialValue: _speed,
                    onSelected: (value) async {
                      setState(() => _speed = value);
                      await _player.setSpeed(value);
                    },
                    itemBuilder: (_) => <double>[
                      0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0,
                    ].map((value) => PopupMenuItem<double>(
                          value: value,
                          child: Text('${value}x'),
                        )).toList(),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        '${_speed}x',
                        style: TextStyle(
                          color: colors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              StreamBuilder<Duration>(
                stream: _player.positionStream,
                initialData: Duration.zero,
                builder: (context, snapshot) {
                  final position = snapshot.data ?? Duration.zero;
                  final duration = _player.duration ?? Duration.zero;
                  final max = duration.inMilliseconds.toDouble();
                  final value = position.inMilliseconds
                      .toDouble()
                      .clamp(0.0, max > 0 ? max : 1.0)
                      .toDouble();
                  return Column(
                    children: [
                      Slider(
                        value: value,
                        max: max > 0 ? max : 1,
                        onChanged: track == null
                            ? null
                            : (next) => _player.seek(
                                  Duration(milliseconds: next.round()),
                                ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_formatDuration(position),
                              style: Theme.of(context).textTheme.labelSmall),
                          Text(_formatDuration(duration),
                              style: Theme.of(context).textTheme.labelSmall),
                        ],
                      ),
                    ],
                  );
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: 'پخش تصادفی',
                    onPressed: track == null ? null : _toggleShuffle,
                    color: _shuffle ? colors.primary : colors.onSurfaceVariant,
                    icon: const Icon(Icons.shuffle),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه عقب',
                    onPressed: track == null ? null : () => _seekRelative(-15),
                    icon: const Icon(Icons.replay_10),
                  ),
                  IconButton(
                    tooltip: 'قبلی',
                    onPressed: track == null
                        ? null
                        : () async {
                            if (_player.position > const Duration(seconds: 3)) {
                              await _player.seek(Duration.zero);
                            } else {
                              await _player.seekToPrevious();
                            }
                          },
                    icon: const Icon(Icons.skip_previous_rounded, size: 30),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      final processing = snapshot.data?.processingState;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return SizedBox(
                        width: 54,
                        height: 54,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: EdgeInsets.zero,
                          ),
                          onPressed: track == null
                              ? null
                              : () => playing ? _player.pause() : _player.play(),
                          child: busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  size: 30,
                                ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'بعدی',
                    onPressed: track == null ? null : _player.seekToNext,
                    icon: const Icon(Icons.skip_next_rounded, size: 30),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه جلو',
                    onPressed: track == null ? null : () => _seekRelative(15),
                    icon: const Icon(Icons.forward_10),
                  ),
                  IconButton(
                    tooltip: 'حالت تکرار',
                    onPressed: track == null ? null : _cycleRepeat,
                    color: _loopMode == LoopMode.off
                        ? colors.onSurfaceVariant
                        : colors.primary,
                    icon: Icon(
                      _loopMode == LoopMode.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                    ),
                  ),
                ],
              ),
              Text(
                _loopMode == LoopMode.one
                    ? 'تکرار همین آهنگ'
                    : _loopMode == LoopMode.all
                        ? 'تکرار فهرست'
                        : 'بدون تکرار',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LyricsEditor extends StatefulWidget {
  const _LyricsEditor({
    super.key,
    required this.track,
    required this.initialText,
    required this.onSave,
  });

  final AudioTrack track;
  final String initialText;
  final Future<void> Function(String value) onSave;

  @override
  State<_LyricsEditor> createState() => _LyricsEditorState();
}

class _LyricsEditorState extends State<_LyricsEditor> {
  late final TextEditingController _controller;
  Timer? _saveTimer;
  bool _saving = false;
  bool _saved = true;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  void _scheduleSave(String value) {
    _saveTimer?.cancel();
    setState(() {
      _saved = false;
      _saving = false;
    });
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_save(value));
    });
  }

  Future<void> _save(String value) async {
    if (!mounted) return;
    setState(() => _saving = true);
    await widget.onSave(value);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saved = true;
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (!_saved) {
      unawaited(widget.onSave(_controller.text));
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'متن ویس',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 5),
          Text(
            widget.track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: TextField(
              controller: _controller,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textDirection: TextDirection.rtl,
              onChanged: _scheduleSave,
              decoration: const InputDecoration(
                hintText: 'متن این ویس را اینجا بنویس...',
                contentPadding: EdgeInsets.all(16),
                alignLabelWithHint: true,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                _saving
                    ? Icons.sync
                    : _saved
                        ? Icons.check_circle_outline
                        : Icons.edit_note,
                size: 18,
                color: _saved ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Text(
                _saving
                    ? 'در حال ذخیره...'
                    : _saved
                        ? 'متن ذخیره شده است'
                        : 'ذخیره خودکار فعال است',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  _saveTimer?.cancel();
                  _save(_controller.text);
                },
                icon: const Icon(Icons.save_outlined),
                label: const Text('ذخیره'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
