// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/audio_bookmark.dart';
import '../models/audio_playlist.dart';
import '../models/audio_track.dart';
import '../models/volume_range.dart';
import '../services/library_store.dart';
import '../services/folder_library_service.dart';
import '../services/scheduled_playback_service.dart';
import 'volume_automation_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.isDark,
    required this.themeId,
    required this.onToggleTheme,
    required this.onSelectTheme,
  });

  final bool isDark;
  final String themeId;
  final VoidCallback onToggleTheme;
  final ValueChanged<String> onSelectTheme;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // Android audio focus is intentionally not requested so this player can
  // mix with audio from other apps. iOS keeps normal session activation.
  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: !Platform.isAndroid,
  );
  final AudioPlayer _smartPlayer = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: !Platform.isAndroid,
  );
  final LibraryStore _store = LibraryStore();
  final FolderLibraryService _folderService = FolderLibraryService();
  final List<AudioTrack> _tracks = [];
  final List<Map<String, String>> _libraryFolders = [];
  Map<String, String> _lyrics = {};
  int _currentIndex = -1;
  bool _shuffle = false;
  LoopMode _loopMode = LoopMode.off;
  double _speed = 1;
  double _volume = 1;
  double _smartVolume = 1;
  bool _showSmartVolumeSlider = false;
  final Map<String, List<VolumeRange>> _volumeRangesByTrack = {};
  double? _lastAppliedVolume;
  late final TabController _tabController;
  Timer? _lyricsHoldTimer;
  Timer? _themeHoldTimer;
  Timer? _messageTimer;
  int _messageGeneration = 0;
  bool _themeLongPressTriggered = false;
  bool _lyricsEditing = false;
  final List<AudioBookmark> _bookmarks = [];
  int? _pendingTopicStartMs;
  String? _pendingTopicAudioPath;
  final List<AudioPlaylist> _playlists = [];
  String _smartTopicMode = 'manual';
  String _smartOrderMode = 'sequential';
  String? _selectedSmartTopic;
  String? _activeSmartTopic;
  bool _smartQueueReady = false;
  final List<AudioBookmark> _smartQueueBookmarks = [];
  late final AnimationController _smartTopicMarqueeController;
  String? _expandedPlaylistId;
  static const String _favoritesPlaylistId = 'audio_player_favorites_v1';
  static const String _favoritesPlaylistName = 'علاقه‌مندی‌ها';

  AudioTrack? get _currentTrack =>
      _currentIndex >= 0 && _currentIndex < _tracks.length
          ? _tracks[_currentIndex]
          : null;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, initialIndex: 3, vsync: this);
    _smartTopicMarqueeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _configureAudioSession();
    _player.positionStream.listen((position) {
      unawaited(_applyEffectiveVolume(position: position));
    });
    ScheduledPlaybackService.setStopHandler(() async {
      await _player.stop();
      _showMessage('پخش صوت طبق زمان‌بندی متوقف شد.');
    });
    _restoreLibrary();
    _player.currentIndexStream.listen((index) {
      if (!mounted) return;
      final nextIndex = index ?? -1;
      final pendingPath = _pendingTopicAudioPath;
      final pendingWasCanceled = _pendingTopicStartMs != null &&
          (nextIndex < 0 ||
              nextIndex >= _tracks.length ||
              _tracks[nextIndex].path != pendingPath);
      if (pendingWasCanceled) {
        _pendingTopicStartMs = null;
        _pendingTopicAudioPath = null;
      }
      setState(() {
        _currentIndex = nextIndex;
        _lyricsEditing = false;
      });
      if (pendingWasCanceled) {
        _showMessage('با تغییر فایل صوتی، شروعِ ثبت‌نشدهٔ موضوع لغو شد؛ می‌توانی بازهٔ جدیدی ثبت کنی.');
      }
      _lastAppliedVolume = null;
      unawaited(_applyEffectiveVolume(position: Duration.zero));
    });
    _player.shuffleModeEnabledStream.listen((value) {
      if (mounted) setState(() => _shuffle = value);
    });
    _player.loopModeStream.listen((value) {
      if (mounted) setState(() => _loopMode = value);
    });
  }

  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(
        AudioSessionConfiguration.music().copyWith(
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.mixWithOthers,
        ),
      );
    } catch (error) {
      debugPrint('Audio session configuration failed: $error');
    }
  }

  Future<void> _restoreLibrary() async {
    try {
      final savedVolume = await _store.loadVolume();
      final preferences = await SharedPreferences.getInstance();
      final savedSmartVolume = preferences.getDouble('smart_topic_volume_v1') ?? 1.0;
      _smartVolume = savedSmartVolume.clamp(0.0, 1.0).toDouble();
      await _smartPlayer.setVolume(_smartVolume);
      for (final key in preferences.getKeys().where(
        (key) => key.startsWith('volume_ranges_v1_'),
      )) {
        final savedRanges = preferences.getString(key);
        if (savedRanges == null) continue;
        try {
          final ranges = (jsonDecode(savedRanges) as List<dynamic>)
              .map((item) => VolumeRange.fromMap(
                    Map<String, dynamic>.from(item as Map),
                  ))
              .toList()
            ..sort((a, b) => a.startMs.compareTo(b.startMs));
          _volumeRangesByTrack[key.substring('volume_ranges_v1_'.length)] = ranges;
        } catch (error) {
          debugPrint('Saved volume schedule is invalid for $key: $error');
        }
      }
      if (mounted) setState(() => _volume = savedVolume);
      await _applyEffectiveVolume();
      final saved = await _store.loadTracks();
      final savedFolders = await _store.loadFolders();
      final lyrics = await _store.loadLyrics();
      final savedBookmarks = await _store.loadBookmarks();
      final savedPlaylists = await _store.loadPlaylists();
      _smartTopicMode = preferences.getString('smart_topic_mode_v1') ?? 'manual';
      _smartOrderMode = preferences.getString('smart_order_mode_v1') ?? 'sequential';
      _selectedSmartTopic = preferences.getString('smart_selected_topic_v1');
      if (!savedPlaylists.any((item) => item.id == _favoritesPlaylistId)) {
        savedPlaylists.add(const AudioPlaylist(
          id: _favoritesPlaylistId,
          name: _favoritesPlaylistName,
          trackPaths: [],
        ));
        await _store.savePlaylists(savedPlaylists);
      }
      final available = saved
          .where((track) => track.path.startsWith('content://') ||
              File(track.path).existsSync())
          .toList();
      if (!mounted) return;
      setState(() {
        _tracks.addAll(available);
        _libraryFolders
          ..clear()
          ..addAll(savedFolders);
        _lyrics = lyrics;
        _playlists
          ..clear()
          ..addAll(savedPlaylists);
        _bookmarks
          ..clear()
          ..addAll(savedBookmarks);
      });
      if (_tracks.isNotEmpty) {
        await _replacePlaylist(autoplay: false);
      }
      if (available.length != saved.length) {
        await _store.saveTracks(_tracks);
      }
    } catch (error) {
      debugPrint('Library restore failed: $error');
    }
  }

  Future<void> _persistTracks() => _store.saveTracks(_tracks);

  Future<void> _createBackup() async {
    try {
      final contents = await _store.exportBackupJson();
      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final fileName = 'audio_player_backup_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}.json';
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'ذخیره نسخه پشتیبان',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(utf8.encode(contents)),
      );
      if (savedPath == null) return;
      _showMessage('نسخه پشتیبان با موفقیت ذخیره شد.');
    } catch (error) {
      _showMessage('تهیه نسخه پشتیبان ناموفق بود: $error');
    }
  }

  Future<void> _restoreBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) {
        _showMessage('خواندن فایل پشتیبان ممکن نشد.');
        return;
      }
      final contents = utf8.decode(bytes);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('بازیابی نسخه پشتیبان'),
          content: const Text(
            'اطلاعات فعلی متن‌ها، نشانک‌ها و پلی‌لیست‌ها با اطلاعات داخل فایل جایگزین می‌شوند. این عملیات قابل بازگشت نیست. فایل‌های صوتی داخل نسخه پشتیبان نیستند.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('بازیابی اطلاعات'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      await _store.restoreBackupJson(contents);
      final savedTracks = await _store.loadTracks();
      final availableTracks = savedTracks
          .where((track) =>
              track.path.startsWith('content://') || File(track.path).existsSync())
          .toList();
      final restoredLyrics = await _store.loadLyrics();
      final restoredBookmarks = await _store.loadBookmarks();
      final restoredPlaylists = await _store.loadPlaylists();
      if (!restoredPlaylists.any((item) => item.id == _favoritesPlaylistId)) {
        restoredPlaylists.add(const AudioPlaylist(
          id: _favoritesPlaylistId,
          name: _favoritesPlaylistName,
          trackPaths: [],
        ));
        await _store.savePlaylists(restoredPlaylists);
      }

      if (!mounted) return;
      setState(() {
        _tracks
          ..clear()
          ..addAll(availableTracks);
        _lyrics = restoredLyrics;
        _bookmarks
          ..clear()
          ..addAll(restoredBookmarks);
        _playlists
          ..clear()
          ..addAll(restoredPlaylists);
        _currentIndex = -1;
        _expandedPlaylistId = null;
        _lyricsEditing = false;
      });

      if (_tracks.isEmpty) {
        await _player.stop();
      } else {
        await _replacePlaylist(autoplay: false);
      }
      _showMessage(
        'اطلاعات بازیابی شد. ${savedTracks.length - availableTracks.length} فایل صوتی در دسترس نبود؛ در صورت نیاز آن‌ها را دوباره به کتابخانه اضافه کن.',
      );
    } catch (error) {
      _showMessage('بازیابی نسخه پشتیبان ناموفق بود: $error');
    }
  }

  Future<void> _pickAudio() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'flac', 'aac', 'm4a'],
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;

      final added = <AudioTrack>[];
      final existingPaths = _tracks.map((track) => track.path).toSet();
      for (final item in result.files) {
        final sourcePath = item.path;
        if (sourcePath == null) continue;
        final extension = item.extension?.toLowerCase() ?? '';
        if (!['mp3', 'wav', 'flac', 'aac', 'm4a'].contains(extension)) {
          continue;
        }
        final source = File(sourcePath);
        if (!await source.exists() || !existingPaths.add(source.absolute.path)) {
          continue;
        }

        // Keep the selected source file in place. This lets rename operations
        // update the actual filename visible in the device file manager.
        added.add(AudioTrack(
          path: source.absolute.path,
          title: item.name.replaceFirst(RegExp(r'\.[^.]+ {
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

  Future<void> _openFolderManager() async {
    final folders = await _store.loadFolders();
    if (!mounted) return;
    final selected = folders.map((folder) => Map<String, String>.from(folder)).toList();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('پوشه‌های کتابخانه'),
          content: SizedBox(
            width: double.maxFinite,
            height: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text('هنوز پوشه‌ای انتخاب نشده است.'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: selected.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          selected[index]['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'حذف پوشه',
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(
                            () => selected.removeAt(index),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final folder = await _folderService.pickFolder();
                      if (folder == null) return;
                      if (selected.any((item) => item['uri'] == folder['uri'])) return;
                      setDialogState(() => selected.add(folder));
                    } catch (error) {
                      if (mounted) _showMessage('انتخاب پوشه ناموفق بود: $error');
                    }
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('افزودن پوشه'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final result = selected
                          .map((folder) => Map<String, String>.from(folder))
                          .toList();
                      Navigator.pop(dialogContext);
                      unawaited(_scanSelectedFolders(result));
                    },
              icon: const Icon(Icons.sync),
              label: const Text('شروع اسکن'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanSelectedFolders(List<Map<String, String>> folders) async {
    try {
      await _store.saveFolders(folders);
      if (mounted) {
        setState(() {
          _libraryFolders
            ..clear()
            ..addAll(folders.map((folder) => Map<String, String>.from(folder)));
        });
      }
      _showMessage('در حال اسکن پوشه‌ها...');
      final found = await _folderService.scanFolders(
        folders.map((folder) => folder['uri']!).toList(),
      );
      final existing = _tracks.map((track) => track.path).toSet();
      final added = <AudioTrack>[];
      var duplicates = 0;
      for (final item in found) {
        final uri = item['uri']!;
        if (!existing.add(uri)) {
          duplicates++;
          continue;
        }
        final name = item['name']!;
        final dotIndex = name.lastIndexOf('.');
        final title = dotIndex > 0 ? name.substring(0, dotIndex) : name;
        added.add(AudioTrack(path: uri, title: title));
      }
      if (added.isNotEmpty) {
        setState(() => _tracks.addAll(added));
        await _persistTracks();
        await _replacePlaylist(autoplay: false);
      }
      _showMessage(
        'اسکن تمام شد: ${added.length} فایل جدید، '
        '$duplicates فایل تکراری از ${found.length} فایل شناسایی‌شده.',
      );
    } catch (error) {
      _showMessage('اسکن پوشه‌ها ناموفق بود: $error');
    }
  }

  Future<void> _applyEffectiveVolume({Duration? position}) async {
    final positionMs = (position ?? _player.position).inMilliseconds;
    final trackPath = _currentTrack?.path;
    final ranges = trackPath == null
        ? const <VolumeRange>[]
        : (_volumeRangesByTrack[base64Url.encode(utf8.encode(trackPath))] ??
            const <VolumeRange>[]);
    final effective = scheduledVolumeAt(ranges, positionMs, _volume);
    if (_lastAppliedVolume != null &&
        (effective - _lastAppliedVolume!).abs() < 0.0001) {
      return;
    }
    _lastAppliedVolume = effective;
    await _player.setVolume(effective);
  }

  Future<void> _setPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _volume = normalized);
    _lastAppliedVolume = null;
    await _applyEffectiveVolume();
    await _store.saveVolume(normalized);
  }

  Future<void> _openVolumeAutomation() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را انتخاب کن.');
      return;
    }
    final trackKey = base64Url.encode(utf8.encode(track.path));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VolumeAutomationScreen(
          initialRanges: List<VolumeRange>.from(
            _volumeRangesByTrack[trackKey] ?? const <VolumeRange>[],
          ),
          onSave: (ranges) async {
            final preferences = await SharedPreferences.getInstance();
            final key = 'volume_ranges_v1_$trackKey';
            await preferences.setString(
              key,
              jsonEncode(ranges.map((range) => range.toMap()).toList()),
            );
            if (!mounted) return;
            setState(() {
              _volumeRangesByTrack[trackKey] = List<VolumeRange>.from(ranges)
                ..sort((a, b) => a.startMs.compareTo(b.startMs));
              _lastAppliedVolume = null;
            });
            await _applyEffectiveVolume();
          },
        ),
      ),
    );
  }

  Future<void> _showVolumeSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('صدای خروجی پلیر')),
                  Text('${(_volume * 100).round()}%'),
                ],
              ),
              Slider(
                value: _volume,
                min: 0,
                max: 1,
                divisions: 100,
                label: '${(_volume * 100).round()}%',
                onChanged: (value) {
                  setSheetState(() {});
                  _setPlayerVolume(value);
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => _setPlayerVolume(0),
                    child: const Text('بی‌صدا'),
                  ),
                  TextButton(
                    onPressed: () => _setPlayerVolume(1),
                    child: const Text('صدای کامل'),
                  ),
                ],
              ),
              Text(
                'این تنظیم فقط بلندی صدای همین پلیر را تغییر می‌دهد و صدای کلی گوشی را تنظیم نمی‌کند.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _replacePlaylist({required bool autoplay}) async {
    if (_tracks.isEmpty) {
      await _player.stop();
      return;
    }
    final oldIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _tracks.length - 1).toInt();
    final sources = _tracks.map((track) {
      final uri = Uri.parse(track.path);
      return AudioSource.uri(
        uri.scheme == 'content' ? uri : Uri.file(track.path),
      );
    }).toList();
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

  Future<void> _confirmRemoveTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف از کتابخانه'),
        content: Text('«${track.title}» فقط از کتابخانهٔ برنامه حذف می‌شود و فایل اصلی در حافظه باقی می‌ماند. ادامه می‌دهی؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف از کتابخانه'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _removeTrack(index);
  }

  Future<void> _renameTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final controller = TextEditingController(text: track.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ویرایش نام فایل'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(labelText: 'نام جدید'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty || newTitle == track.title) return;
    if (_tracks.any((item) => item.path != track.path && item.title == newTitle)) {
      _showMessage('فایلی با این نام در کتابخانه وجود دارد.');
      return;
    }
    try {
      final renamed = await _folderService.renameItem(track.path, newTitle);
      final newPath = renamed['path'];
      if (newPath == null || newPath.isEmpty) {
        throw StateError('مسیر جدید فایل از سیستم دریافت نشد.');
      }
      final oldPath = track.path;
      final displayTitle = (renamed['name'] ?? newTitle)
          .replaceFirst(RegExp(r'\.[^.]+
      for (var i = 0; i < _bookmarks.length; i++) {
        final bookmark = _bookmarks[i];
        if (bookmark.audioPath != oldPath) continue;
        _bookmarks[i] = AudioBookmark(
          id: bookmark.id,
          audioPath: newPath,
          audioTitle: displayTitle,
          positionMs: bookmark.positionMs,
          createdAt: bookmark.createdAt,
          title: bookmark.title,
          topic: bookmark.topic,
          endPositionMs: bookmark.endPositionMs,
          isTopicRange: bookmark.isTopicRange,
        );
      }
      for (var i = 0; i < _playlists.length; i++) {
        final playlist = _playlists[i];
        _playlists[i] = playlist.copyWith(
          trackPaths: playlist.trackPaths
              .map((path) => path == oldPath ? newPath : path)
              .toList(),
        );
      }
      final savedLyrics = _lyrics.remove(oldPath);
      if (savedLyrics != null) _lyrics[newPath] = savedLyrics;
      if (_pendingTopicAudioPath == oldPath) _pendingTopicAudioPath = newPath;
      await _persistTracks();
      await _store.saveBookmarks(_bookmarks);
      await _store.savePlaylists(_playlists);
      await _store.saveLyrics(_lyrics);
      await _replacePlaylist(autoplay: false);
      if (mounted) setState(() {});
      _showMessage('نام فایل در حافظه و کتابخانه تغییر کرد.');
    } catch (error) {
      _showMessage('تغییر نام فایل ناموفق بود: $error');
    }
  }

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _bookmarks.removeWhere((bookmark) => bookmark.audioPath == removed.path);
    if (_pendingTopicAudioPath == removed.path) {
      _pendingTopicStartMs = null;
      _pendingTopicAudioPath = null;
    }
    for (var i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      _playlists[i] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((path) => path != removed.path).toList(),
      );
    }
    await _store.savePlaylists(_playlists);
    await _store.saveBookmarks(_bookmarks);
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

  Future<void> _addBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }

    final position = _player.position;
    final details = await _showBookmarkDetailsDialog(
      initialTitle: track.title,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: position.inMilliseconds,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
      });
      _showMessage(
        'نشانک معمولی در ${_formatDuration(position)} ذخیره شد. این نشانک وارد پخش هوشمند نمی‌شود.',
      );
    } catch (error) {
      _showMessage('ذخیره نشانک ناموفق بود: $error');
    }
  }

  Future<void> _toggleTopicRangeBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای ثبت موضوع انتخاب کن.');
      return;
    }

    final startMs = _pendingTopicStartMs;
    if (startMs == null) {
      final positionMs = _player.position.inMilliseconds;
      setState(() {
        _pendingTopicStartMs = positionMs;
        _pendingTopicAudioPath = track.path;
      });
      _showMessage('شروع موضوع در ${_formatDuration(Duration(milliseconds: positionMs))} ثبت شد؛ برای ثبت پایان، دوباره همین دکمه را بزن.');
      return;
    }

    if (_pendingTopicAudioPath != track.path) {
      _showMessage('برای ثبت پایان، ابتدا به همان فایل صوتی که شروع موضوع را در آن ثبت کردی برگرد.');
      return;
    }

    final endMs = _player.position.inMilliseconds;
    if (endMs <= startMs) {
      _showMessage('زمان پایان باید بعد از زمان شروع باشد. نشانگر شروع حفظ شد؛ کمی جلوتر برو و دوباره بزن.');
      return;
    }

    final details = await _showBookmarkDetailsDialog(initialTitle: track.title);
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای نشانک موضوعی، نام موضوع را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: startMs,
      endPositionMs: endMs,
      isTopicRange: true,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
        _selectedSmartTopic ??= bookmark.topic;
        _pendingTopicStartMs = null;
        _pendingTopicAudioPath = null;
      });
      await _saveSmartSettings();
      _showMessage('بازه موضوع «${bookmark.topic}» از ${_formatDuration(Duration(milliseconds: startMs))} تا ${_formatDuration(Duration(milliseconds: endMs))} ذخیره شد.');
    } catch (error) {
      _showMessage('ذخیره بازه موضوع ناموفق بود: $error');
    }
  }

  List<String> get _availableSmartTopics {
    final topics = _bookmarks
        .where((bookmark) => bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs)
        .map((bookmark) => bookmark.topic.trim())
        .where((topic) => topic.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return topics;
  }

  Future<Map<String, String>?> _showBookmarkDetailsDialog({
    required String initialTitle,
    String initialTopic = '',
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final topicController = TextEditingController(text: initialTopic);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مشخصات نشانک'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'عنوان نشانک'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              textDirection: TextDirection.rtl,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'موضوع',
                hintText: 'مثلاً تمرکز',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'title': titleController.text.trim(),
              'topic': topicController.text.trim(),
            }),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    titleController.dispose();
    topicController.dispose();
    return result;
  }

  Future<void> _editBookmark(AudioBookmark bookmark) async {
    final details = await _showBookmarkDetailsDialog(
      initialTitle: bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
      initialTopic: bookmark.topic,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }
    final updated = _bookmarks
        .map((item) => item.id == bookmark.id
            ? AudioBookmark(
                id: item.id,
                audioPath: item.audioPath,
                audioTitle: item.audioTitle,
                positionMs: item.positionMs,
                endPositionMs: item.endPositionMs,
                isTopicRange: item.isTopicRange,
                createdAt: item.createdAt,
                title: details['title']!,
                topic: details['topic']!,
              )
            : item)
        .toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('ویرایش نشانک ذخیره نشد: $error');
    }
  }

  Future<void> _deleteBookmark(AudioBookmark bookmark) async {
    final updated = _bookmarks.where((item) => item.id != bookmark.id).toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('حذف نشانک ناموفق بود: $error');
    }
  }

  Future<void> _saveSmartSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('smart_topic_mode_v1', _smartTopicMode);
      await preferences.setString('smart_order_mode_v1', _smartOrderMode);
      if (_selectedSmartTopic == null) {
        await preferences.remove('smart_selected_topic_v1');
      } else {
        await preferences.setString('smart_selected_topic_v1', _selectedSmartTopic!);
      }
    } catch (error) {
      _showMessage('ذخیره تنظیمات پخش هوشمند ناموفق بود: $error');
    }
  }

  Future<void> _startSmartPlayback() async {
    final topics = _availableSmartTopics;
    if (topics.isEmpty) {
      _showMessage('ابتدا در تب نشانک‌ها برای نشانک‌ها موضوع تعیین کن.');
      _tabController.animateTo(1);
      return;
    }

    String topic;
    if (_smartTopicMode == 'random') {
      topic = topics[Random().nextInt(topics.length)];
    } else {
      final selected = _selectedSmartTopic;
      if (selected == null || !topics.contains(selected)) {
        _showMessage('ابتدا یک موضوع برای پخش هوشمند انتخاب کن.');
        _tabController.animateTo(4);
        return;
      }
      topic = selected;
    }

    final matching = _bookmarks
        .where((bookmark) =>
            bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs &&
            bookmark.topic.trim() == topic &&
            _tracks.any((track) => track.path == bookmark.audioPath))
        .toList();
    if (matching.isEmpty) {
      _showMessage('برای این موضوع نشانک قابل پخشی پیدا نشد.');
      return;
    }

    if (_smartOrderMode == 'random') {
      matching.shuffle(Random());
    } else {
      matching.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final sources = <AudioSource>[];
    for (final bookmark in matching) {
      final parsed = Uri.parse(bookmark.audioPath);
      final uri = parsed.scheme == 'content'
          ? parsed
          : Uri.file(bookmark.audioPath);
      sources.add(
        ClippingAudioSource(
          child: AudioSource.uri(uri),
          start: Duration(milliseconds: bookmark.positionMs),
          end: Duration(milliseconds: bookmark.endPositionMs!),
        ),
      );
    }

    try {
      await _player.pause();
      await _smartPlayer.stop();
      await _smartPlayer.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      if (!mounted) return;
      setState(() {
        _activeSmartTopic = topic;
        _smartQueueBookmarks
          ..clear()
          ..addAll(matching);
        _smartQueueReady = true;
      });
      await _smartPlayer.play();
    } catch (error) {
      if (mounted) {
        setState(() {
          _smartQueueReady = false;
          _smartQueueBookmarks.clear();
        });
        _showMessage('شروع پخش هوشمند ناموفق بود: $error');
      }
    }
  }

  Future<void> _setSmartPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _smartVolume = normalized);
    await _smartPlayer.setVolume(normalized);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('smart_topic_volume_v1', normalized);
  }

  Future<void> _toggleSmartPlayback() async {
    if (_smartPlayer.playing) {
      await _smartPlayer.pause();
      return;
    }
    if (_smartQueueReady &&
        _smartPlayer.processingState != ProcessingState.completed) {
      await _smartPlayer.play();
      return;
    }
    await _startSmartPlayback();
  }

  Future<void> _stopSmartPlayback() async {
    await _smartPlayer.stop();
    if (mounted) {
      setState(() {
        _smartQueueReady = false;
        _activeSmartTopic = null;
        _smartQueueBookmarks.clear();
      });
    }
  }

  Future<void> _playBookmark(AudioBookmark bookmark) async {
    final trackIndex =
        _tracks.indexWhere((track) => track.path == bookmark.audioPath);
    if (trackIndex < 0) {
      _showMessage('فایل صوتی این نشانک در کتابخانه موجود نیست.');
      return;
    }

    try {
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      final position = Duration(milliseconds: bookmark.positionMs);
      await _player.seek(position, index: trackIndex);
      await _player.play();
    } catch (error) {
      _showMessage('پخش از نشانک ممکن نشد: $error');
    }
  }

  Widget _buildBookmarksTab(ColorScheme colors) {
    final track = _currentTrack;
    final trackBookmarks = track == null
        ? const <AudioBookmark>[]
        : _bookmarks
            .where((bookmark) => bookmark.audioPath == track.path)
            .toList();

    if (track == null) {
      return const Center(
        child: Text(
          'برای مشاهده نشانک‌ها، ابتدا یک فایل صوتی انتخاب کن.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (trackBookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'برای «${track.title}» هنوز نشانکی ثبت نشده است. هنگام پخش این فایل، دکمه نشانک را لمس کن.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      key: ValueKey('bookmarks-${track.path}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: trackBookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final bookmark = trackBookmarks[index];
        final createdAt = bookmark.createdAt;
        final dateLabel =
            '${createdAt.year}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.day.toString().padLeft(2, '0')}  '
            '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(
              bookmark.isTopicRange
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_rounded,
              color: colors.primary,
            ),
            title: Text(
              bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '${bookmark.isTopicRange ? 'موضوع' : 'نشانک معمولی'}  •  ${bookmark.topic.isEmpty ? 'بدون موضوع' : bookmark.topic}  •  ${_formatDuration(Duration(milliseconds: bookmark.positionMs))}${bookmark.isTopicRange && bookmark.endPositionMs != null ? ' تا ${_formatDuration(Duration(milliseconds: bookmark.endPositionMs!))}' : ''}  •  $dateLabel',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'مدیریت نشانک',
              onSelected: (value) {
                if (value == 'edit') _editBookmark(bookmark);
                if (value == 'delete') _deleteBookmark(bookmark);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('ویرایش عنوان و موضوع')),
                PopupMenuItem(value: 'delete', child: Text('حذف نشانک')),
              ],
            ),
            onTap: () => _playBookmark(bookmark),
          ),
        );
      },
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ساخت پلی‌لیست جدید'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(
            labelText: 'نام پلی‌لیست',
            hintText: 'مثلاً موسیقی آرامش‌بخش',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ساختن'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final playlist = AudioPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      trackPaths: const [],
    );
    setState(() {
      _playlists.add(playlist);
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
  }

  Future<void> _addCurrentTrackToPlaylist(AudioPlaylist playlist) async {
    final track = _currentTrack;
    if (track == null) return;
    if (playlist.trackPaths.contains(track.path)) {
      _showMessage('این فایل از قبل در پلی‌لیست «${playlist.name}» وجود دارد.');
      return;
    }
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: [...playlist.trackPaths, track.path],
      );
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
    _showMessage('«${track.title}» به پلی‌لیست «${playlist.name}» اضافه شد.');
  }

  Future<void> _removeFromPlaylist(AudioPlaylist playlist, String path) async {
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((item) => item != path).toList(),
      );
    });
    await _store.savePlaylists(_playlists);
  }

  bool get _currentTrackIsFavorite {
    final track = _currentTrack;
    if (track == null) return false;
    final index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    return index >= 0 && _playlists[index].trackPaths.contains(track.path);
  }

  Future<void> _toggleCurrentTrackFavorite() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }
    var index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    if (index < 0) {
      _playlists.add(const AudioPlaylist(
        id: _favoritesPlaylistId,
        name: _favoritesPlaylistName,
        trackPaths: [],
      ));
      index = _playlists.length - 1;
    }
    final favorites = _playlists[index];
    final isFavorite = favorites.trackPaths.contains(track.path);
    setState(() {
      _playlists[index] = favorites.copyWith(
        trackPaths: isFavorite
            ? favorites.trackPaths.where((path) => path != track.path).toList()
            : [...favorites.trackPaths, track.path],
      );
      _expandedPlaylistId = _favoritesPlaylistId;
    });
    await _store.savePlaylists(_playlists);
    _showMessage(isFavorite
        ? '«${track.title}» از علاقه‌مندی‌ها حذف شد.'
        : '«${track.title}» به علاقه‌مندی‌ها اضافه شد.');
  }

  Future<void> _deletePlaylist(AudioPlaylist playlist) async {
    if (playlist.id == _favoritesPlaylistId) {
      _showMessage('پلی‌لیست علاقه‌مندی‌ها قابل حذف نیست.');
      return;
    }
    setState(() => _playlists.removeWhere((item) => item.id == playlist.id));
    await _store.savePlaylists(_playlists);
  }

  Widget _buildPlaylistsTab(ColorScheme colors) {
    final current = _currentTrack;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: IconButton.filled(
              tooltip: 'پلی‌لیست جدید',
              onPressed: _createPlaylist,
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? const SizedBox.shrink()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    final expanded = _expandedPlaylistId == playlist.id;
                    final tracks = playlist.trackPaths
                        .map((path) => _tracks.where((track) => track.path == path))
                        .where((matches) => matches.isNotEmpty)
                        .map((matches) => matches.first)
                        .toList();
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: PageStorageKey(playlist.id),
                        initiallyExpanded: expanded,
                        onExpansionChanged: (value) => setState(() {
                          _expandedPlaylistId = value ? playlist.id : null;
                        }),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        children: [
                          if (current != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _addCurrentTrackToPlaylist(playlist),
                                  child: const Text('افزودن آهنگ در حال پخش'),
                                ),
                              ),
                            ),
                          if (playlist.id != _favoritesPlaylistId)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _deletePlaylist(playlist),
                                  child: const Text('حذف پلی‌لیست'),
                                ),
                              ),
                            ),
                          if (tracks.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('این پلی‌لیست هنوز خالی است.'),
                            )
                          else
                            ...tracks.map((track) => ListTile(
                                  dense: true,
                                  title: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final trackIndex = _tracks.indexOf(track);
                                    if (trackIndex >= 0) _playTrack(trackIndex);
                                  },
                                  trailing: TextButton(
                                    onPressed: () => _removeFromPlaylist(
                                      playlist,
                                      track.path,
                                    ),
                                    child: const Text('حذف'),
                                  ),
                                )),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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

  Future<DateTime?> _chooseScheduleDateTime(String title) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: title,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      helpText: 'ساعت اجرا',
    );
    if (time == null) return null;
    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!scheduled.isAfter(DateTime.now())) {
      _showMessage('زمان انتخاب‌شده باید در آینده باشد.');
      return null;
    }
    return scheduled;
  }

  Future<void> _scheduleStartDialog() async {
    if (_tracks.isEmpty) {
      _showMessage('ابتدا یک فایل صوتی به کتابخانه اضافه کن.');
      return;
    }
    String selectedPath = _currentTrack?.path ?? _tracks.first.path;
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('شروع خودکار پخش'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedPath,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'فایل صوتی'),
            items: _tracks.map((track) => DropdownMenuItem<String>(
              value: track.path,
              child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selectedPath = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selectedPath),
              child: const Text('انتخاب زمان'),
            ),
          ],
        ),
      ),
    );
    if (path == null || !mounted) return;
    final at = await _chooseScheduleDateTime('تاریخ شروع پخش');
    if (at == null) return;
    final track = _tracks.firstWhere((item) => item.path == path);
    try {
      await ScheduledPlaybackService.scheduleStart(path: track.path, title: track.title, at: at);
      _showMessage('شروع پخش «${track.title}» برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم شروع خودکار ناموفق بود: $error');
    }
  }

  Future<void> _scheduleStopDialog() async {
    final at = await _chooseScheduleDateTime('تاریخ توقف پخش');
    if (at == null) return;
    try {
      await ScheduledPlaybackService.scheduleStop(at: at);
      _showMessage('توقف پخش برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم توقف خودکار ناموفق بود: $error');
    }
  }

  String _formatScheduleDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.year % 100)}/${two(value.month)}/${two(value.day)} - ${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _cancelScheduledStart() async {
    try {
      await ScheduledPlaybackService.cancelStart();
      _showMessage('شروع خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان شروع ناموفق بود: $error');
    }
  }

  Future<void> _cancelScheduledStop() async {
    try {
      await ScheduledPlaybackService.cancelStop();
      _showMessage('توقف خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان توقف ناموفق بود: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _messageTimer?.cancel();
    final generation = ++_messageGeneration;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          leading: const Icon(Icons.info_outline_rounded),
          content: Dismissible(
            key: ValueKey('app-message-$generation'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _messageTimer?.cancel();
              messenger.hideCurrentMaterialBanner();
            },
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(message),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'بستن پیام',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _messageTimer?.cancel();
                messenger.hideCurrentMaterialBanner();
              },
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || generation != _messageGeneration) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  @override
  void dispose() {
    _lyricsHoldTimer?.cancel();
    _themeHoldTimer?.cancel();
    _messageTimer?.cancel();
    _smartTopicMarqueeController.dispose();
    _tabController.dispose();
    _player.dispose();
    unawaited(_smartPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
        body: Column(
          children: [
            _buildPlayerToolbar(colors),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLyricsTab(colors),
                  _buildBookmarksTab(colors),
                  _buildPlaylistsTab(colors),
                  _buildLibraryTab(colors),
                  _buildSmartTab(colors),
                ],
              ),
            ),
            _buildBottomNavigation(colors),
            _buildPlayerPanel(colors),
          ],
        ),
      );
  }

  Widget _buildBottomNavigation(ColorScheme colors) {
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: false,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                labelPadding: EdgeInsets.zero,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.notes_rounded, size: 26)),
                    ),
                    text: 'متن',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.bookmarks_outlined, size: 26)),
                    ),
                    text: 'نشانک',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.queue_music_rounded, size: 26)),
                    ),
                    text: 'پلی‌لیست',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.library_music_outlined, size: 26)),
                    ),
                    text: 'کتابخانه',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.psychology_rounded, size: 26)),
                    ),
                    text: 'بخش هوشمند',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartTab(ColorScheme colors) {
    final topics = _availableSmartTopics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartTopicMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'انتخاب موضوع',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'manual',
                    child: Text('انتخاب موضوع توسط من', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('انتخاب موضوع تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartTopicMode = value);
                  await _saveSmartSettings();
                  if (value == 'manual' && topics.isNotEmpty && mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('انتخاب موضوع'),
                        content: SizedBox(
                          width: 320,
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final topic in topics)
                                ListTile(
                                  title: Text(topic),
                                  trailing: _selectedSmartTopic == topic
                                      ? const Icon(Icons.check_rounded)
                                      : null,
                                  onTap: () async {
                                    setState(() => _selectedSmartTopic = topic);
                                    await _saveSmartSettings();
                                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartOrderMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'ترتیب پخش نشانک‌ها',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'sequential',
                    child: Text('به ترتیب ثبت', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('به‌صورت تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartOrderMode = value);
                  await _saveSmartSettings();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          textDirection: TextDirection.rtl,
          children: [
            const Text(
              'موضوع در حال پخش:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final topicText = _activeSmartTopic ?? '—';
                  final textPainter = TextPainter(
                    text: TextSpan(
                      text: topicText,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                  )..layout();
                  final textWidth = textPainter.width;
                  final viewportWidth = constraints.maxWidth;
                  if (textWidth <= viewportWidth) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        topicText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  return ClipRect(
                    child: SizedBox(
                      height: 22,
                      child: AnimatedBuilder(
                        animation: _smartTopicMarqueeController,
                        builder: (context, child) {
                          final travel = viewportWidth + textWidth;
                          final offset = viewportWidth -
                              (_smartTopicMarqueeController.value * travel);
                          return Transform.translate(
                            offset: Offset(offset, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: textWidth,
                          child: Text(
                            topicText,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: topics.isEmpty ? null : _toggleSmartPlayback,
                icon: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                label: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Text(
                    snapshot.data == true ? 'مکث' : 'شروع پخش هوشمند',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'توقف پخش هوشمند',
              onPressed: _stopSmartPlayback,
              icon: const Icon(Icons.stop_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'تنظیم صدای پلیر موضوعی',
              onPressed: () => setState(
                () => _showSmartVolumeSlider = !_showSmartVolumeSlider,
              ),
              icon: Icon(
                _smartVolume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
        if (_showSmartVolumeSlider)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 8, top: 2),
            child: Row(
              children: [
                const Icon(Icons.volume_down_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: _smartVolume,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    label: '${(_smartVolume * 100).round()}٪',
                    onChanged: (value) {
                      setState(() => _smartVolume = value);
                      unawaited(_smartPlayer.setVolume(value));
                    },
                    onChangeEnd: (value) async {
                      await _setSmartPlayerVolume(value);
                      if (mounted) setState(() => _showSmartVolumeSlider = false);
                    },
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(_smartVolume * 100).round()}٪',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_smartQueueBookmarks.isNotEmpty)
          StreamBuilder<int?>(
            stream: _smartPlayer.currentIndexStream,
            initialData: _smartPlayer.currentIndex,
            builder: (context, snapshot) {
              final activeIndex = snapshot.data ?? -1;
              return Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  itemCount: _smartQueueBookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _smartQueueBookmarks[index];
                    final isActive = index == activeIndex;
                    final endMs = bookmark.endPositionMs ?? bookmark.positionMs;
                    final duration = Duration(
                      milliseconds: (endMs - bookmark.positionMs).clamp(0, 1 << 31).toInt(),
                    );
                    return Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: isActive
                          ? colors.primary.withValues(alpha: 0.10)
                          : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text(
                              _formatDuration(duration),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isActive ? colors.primary : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            isActive ? Icons.graphic_eq_rounded : Icons.bookmark_outline_rounded,
                            size: 17,
                            color: isActive ? colors.primary : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  bookmark.audioTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  bookmark.topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? colors.primary : colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isActive)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 6),
                              child: Text(
                                'در حال پخش',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          )
        else if (topics.isEmpty)
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded, size: 20),
            title: Text('هنوز موضوعی ثبت نشده است.', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              'در نوار پخش، با دکمه نشانک موضوعی ابتدا و انتهای هر موضوع را ثبت کن.',
              style: TextStyle(fontSize: 11),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'برای نمایش فهرست، پخش یک موضوع را شروع کن.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 12),
        StreamBuilder<Duration>(
          stream: _smartPlayer.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            return StreamBuilder<Duration?>(
              stream: _smartPlayer.durationStream,
              builder: (context, durationSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = durationSnapshot.data ?? Duration.zero;
                final max = duration.inMilliseconds.toDouble();
                return Column(
                  children: [
                    LinearProgressIndicator(
                      value: max <= 0
                          ? 0
                          : (position.inMilliseconds / max).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position)),
                        Text(_formatDuration(duration)),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  void _onThemeButtonDown(PointerDownEvent event) {
    _themeLongPressTriggered = false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _themeLongPressTriggered = true;
      _showPresetThemePicker();
    });
  }

  void _onThemeButtonUp(PointerUpEvent event) {
    final wasLongPress = _themeLongPressTriggered;
    final wasShortPress = _themeHoldTimer?.isActive ?? false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
    if (!wasLongPress && wasShortPress) widget.onToggleTheme();
  }

  void _onThemeButtonCancel(PointerCancelEvent event) {
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
  }

  Future<void> _showPresetThemePicker() async {
    const themes = <({String id, String name, Color color, String description})>[
      (id: 'teal', name: 'فیروزه‌ای', color: Color(0xFF16A6A0), description: 'تم پیش‌فرض فعلی'),
      (id: 'blue', name: 'آبی اقیانوسی', color: Color(0xFF2878D0), description: 'آرام و خنک'),
      (id: 'purple', name: 'بنفش', color: Color(0xFF8764D8), description: 'بنفش مدرن'),
      (id: 'green', name: 'سبز جنگلی', color: Color(0xFF39865A), description: 'طبیعی و ملایم'),
      (id: 'amber', name: 'کهربایی', color: Color(0xFFD28A22), description: 'گرم و پرانرژی'),
      (id: 'rose', name: 'رز', color: Color(0xFFC65D78), description: 'صورتی متمایل به رز'),
      (id: 'slate', name: 'خاکستری', color: Color(0xFF718096), description: 'خنثی و مینیمال'),
    ];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('انتخاب تم برنامه'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'حالت فعلی: ${widget.isDark ? 'شب' : 'روز'}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ),
              for (final theme in themes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: theme.color,
                  ),
                  title: Text(theme.name),
                  subtitle: Text(theme.description),
                  trailing: widget.themeId == theme.id
                      ? const Icon(Icons.check_circle_rounded)
                      : null,
                  onTap: () {
                    widget.onSelectTheme(theme.id);
                    Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerToolbar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              PopupMenuButton<String>(
                tooltip: 'پشتیبان‌گیری و بازیابی',
                icon: const Icon(Icons.backup_outlined, size: 24),
                onSelected: (value) {
                  if (value == 'backup') _createBackup();
                  if (value == 'restore') _restoreBackup();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'backup',
                    child: Row(
                      children: [
                        Icon(Icons.save_alt_rounded),
                        SizedBox(width: 12),
                        Text('تهیه نسخه پشتیبان'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.settings_backup_restore_rounded),
                        SizedBox(width: 12),
                        Text('بازیابی نسخه پشتیبان'),
                      ],
                    ),
                  ),
                ],
              ),
              Tooltip(
                message: 'لمس کوتاه: تغییر شب و روز • نگه‌داشتن ۳ ثانیه: انتخاب تم',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onThemeButtonDown,
                  onPointerUp: _onThemeButtonUp,
                  onPointerCancel: _onThemeButtonCancel,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        widget.isDark ? Icons.light_mode : Icons.dark_mode,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'شروع و پایان خودکار',
                icon: const Icon(Icons.schedule_rounded, size: 24),
                onSelected: (value) {
                  if (value == 'start') _scheduleStartDialog();
                  if (value == 'stop') _scheduleStopDialog();
                  if (value == 'cancel_start') _cancelScheduledStart();
                  if (value == 'cancel_stop') _cancelScheduledStop();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'start', child: Text('تنظیم شروع خودکار')),
                  PopupMenuItem(value: 'stop', child: Text('تنظیم توقف خودکار')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'cancel_start', child: Text('لغو شروع خودکار')),
                  PopupMenuItem(value: 'cancel_stop', child: Text('لغو توقف خودکار')),
                ],
              ),
              IconButton(
                tooltip: 'نقشه تغییرات صدا',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                onPressed: _openVolumeAutomation,
                icon: const Icon(Icons.multiline_chart_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    final hasLibraryItems = _libraryFolders.isNotEmpty || _tracks.isNotEmpty;
    final actions = Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'انتخاب فایل صوتی',
          onPressed: _pickAudio,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.audio_file_rounded, size: 20),
        ),
        const SizedBox(width: 3),
        IconButton.filledTonal(
          tooltip: 'انتخاب پوشه',
          onPressed: _openFolderManager,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.create_new_folder_outlined, size: 20),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final folder in _libraryFolders)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_rounded, size: 18, color: colors.primary),
                        const SizedBox(width: 4),
                        Text(
                          folder['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (!hasLibraryItems) {
      return Center(child: actions);
    }

    final itemCount = _tracks.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: actions,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: itemCount,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            itemBuilder: (context, index) {
              final trackIndex = index;
              final track = _tracks[trackIndex];
              final isCurrent = _currentIndex == trackIndex;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                minVerticalPadding: 0,
                minTileHeight: 30,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                tileColor: isCurrent
                    ? colors.primary.withValues(alpha: 0.10)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: _MarqueeText(
                  text: track.title,
                  style: const TextStyle(fontSize: 14),
                  gap: 28,
                ),
                onTap: () => _playTrack(trackIndex),
                trailing: PopupMenuButton<String>(
                  tooltip: 'گزینه‌های فایل صوتی',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  iconSize: 17,
                  onSelected: (action) {
                    if (action == 'rename') {
                      _renameTrack(trackIndex);
                    } else if (action == 'delete') {
                      _confirmRemoveTrack(trackIndex);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'rename',
                      height: 40,
                      child: Text('ویرایش نام'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      height: 40,
                      child: Text('حذف از کتابخانه'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onLyricsPointerDown(PointerDownEvent event) {
    _lyricsHoldTimer?.cancel();
    _lyricsHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _lyricsEditing = true);
    });
  }

  void _onLyricsPointerEnd(PointerEvent event) {
    _lyricsHoldTimer?.cancel();
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
              Icon(Icons.edit_note, size: 44, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'متن صدا ...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    if (_lyricsEditing) {
      return _LyricsEditor(
        key: ValueKey('edit-${track.path}'),
        track: track,
        initialText: _lyrics[track.path] ?? '',
        onSave: (value) => _saveLyrics(track.path, value),
        onSaveComplete: () {
          if (mounted) setState(() => _lyricsEditing = false);
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Expanded(
            child: Listener(
              onPointerDown: _onLyricsPointerDown,
              onPointerUp: _onLyricsPointerEnd,
              onPointerCancel: _onLyricsPointerEnd,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    (_lyrics[track.path] ?? '').trim().isEmpty
                        ? 'متن صدا ...'
                        : _lyrics[track.path]!,
                    textDirection: TextDirection.rtl,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await _store.saveLyrics(_lyrics);
                  _showMessage('متن ویس ذخیره شد.');
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded, color: colors.primary, size: 21),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _MarqueeText(
                            text: track?.title ?? 'فایلی برای پخش انتخاب نشده',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'در حال پخش',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'ثبت نشانک در زمان فعلی',
                        onPressed: track == null ? null : _addBookmark,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: _pendingTopicStartMs == null
                            ? 'ثبت شروع موضوع'
                            : 'ثبت پایان موضوع (${_formatDuration(Duration(milliseconds: _pendingTopicStartMs!))})',
                        onPressed: track == null ? null : _toggleTopicRangeBookmark,
                        color: _pendingTopicStartMs == null ? null : colors.primary,
                        icon: Icon(
                          _pendingTopicStartMs == null
                              ? Icons.bookmark_add_rounded
                              : Icons.bookmark_added_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: _currentTrack == null
                            ? 'علاقه‌مندی‌ها (ابتدا یک فایل پخش کن)'
                            : _currentTrackIsFavorite
                                ? 'حذف از علاقه‌مندی‌ها'
                                : 'افزودن به علاقه‌مندی‌ها',
                        onPressed: _toggleCurrentTrackFavorite,
                        icon: Icon(
                          _currentTrackIsFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: _currentTrackIsFavorite
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: 'شروع پخش هوشمند',
                        onPressed: _toggleSmartPlayback,
                        icon: const Icon(Icons.auto_awesome_rounded),
                      ),
                      IconButton(
                        tooltip: 'تنظیم صدای پلیر',
                        onPressed: _showVolumeSettings,
                        icon: Icon(
                          _volume == 0
                              ? Icons.volume_off_rounded
                              : _volume < 0.5
                                  ? Icons.volume_down_rounded
                                  : Icons.volume_up_rounded,
                          color: colors.primary,
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
                  final trackRanges = _bookmarks
                      .where((bookmark) =>
                          bookmark.isTopicRange &&
                          bookmark.audioPath == track?.path &&
                          bookmark.endPositionMs != null &&
                          bookmark.endPositionMs! > bookmark.positionMs)
                      .toList();
                  return Column(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final usableWidth =
                              (constraints.maxWidth - 32).clamp(0.0, double.infinity).toDouble();
                          return Stack(
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
                              if (max > 0)
                                ...trackRanges.expand((bookmark) {
                                  final startFraction =
                                      (bookmark.positionMs / max).clamp(0.0, 1.0).toDouble();
                                  final endFraction =
                                      (bookmark.endPositionMs! / max).clamp(0.0, 1.0).toDouble();
                                  return <Widget>[
                                    PositionedDirectional(
                                      start: 16 + usableWidth * startFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.tertiary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                    PositionedDirectional(
                                      start: 16 + usableWidth * endFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                  ];
                                }),
                            ],
                          );
                        },
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
                    icon: const Icon(Icons.shuffle, size: 27),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه عقب',
                    onPressed: track == null ? null : () => _seekRelative(-15),
                    icon: const Icon(Icons.replay_10, size: 27),
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
                    icon: const Icon(Icons.skip_previous_rounded, size: 32),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      final processing = snapshot.data?.processingState;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return SizedBox(
                        width: 60,
                        height: 60,
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
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  size: 34,
                                ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'بعدی',
                    onPressed: track == null ? null : _player.seekToNext,
                    icon: const Icon(Icons.skip_next_rounded, size: 32),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه جلو',
                    onPressed: track == null ? null : () => _seekRelative(15),
                    icon: const Icon(Icons.forward_10, size: 27),
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
                      size: 27,
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
    required this.onSaveComplete,
  });

  final AudioTrack track;
  final String initialText;
  final Future<void> Function(String value) onSave;
  final VoidCallback onSaveComplete;

  @override
  State<_LyricsEditor> createState() => _LyricsEditorState();
}

class _LyricsEditorState extends State<_LyricsEditor> {
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  final FocusNode _lyricsFocusNode = FocusNode();
  Timer? _saveTimer;
  bool _saving = false;
  bool _saved = true;
  bool _hasSearched = false;
  List<int> _matches = [];
  int _activeMatch = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _searchController = TextEditingController();
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
    if (_matches.isNotEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
        _hasSearched = false;
      });
    }
  }

  void _findMatches({bool preservePosition = false}) {
    final query = _searchController.text;
    final text = _controller.text;
    _hasSearched = true;
    if (query.isEmpty || text.isEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
      });
      return;
    }

    final source = text.toLowerCase();
    final needle = query.toLowerCase();
    final found = <int>[];
    var offset = 0;
    while (offset <= source.length - needle.length) {
      final index = source.indexOf(needle, offset);
      if (index < 0) break;
      found.add(index);
      offset = index + needle.length;
    }

    final previousStart = preservePosition && _activeMatch >= 0 &&
            _activeMatch < _matches.length
        ? _matches[_activeMatch]
        : -1;
    var nextActive = found.isEmpty ? -1 : 0;
    if (previousStart >= 0 && found.isNotEmpty) {
      final sameIndex = found.indexOf(previousStart);
      if (sameIndex >= 0) nextActive = sameIndex;
    }
    setState(() {
      _matches = found;
      _activeMatch = nextActive;
    });
    if (found.isNotEmpty) _selectMatch(nextActive);
  }

  void _selectMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final start = _matches[index];
    final end = start + _searchController.text.length;
    _lyricsFocusNode.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    setState(() => _activeMatch = index);
  }

  void _moveMatch(int step) {
    if (_matches.isEmpty) return;
    final next = (_activeMatch + step + _matches.length) % _matches.length;
    _selectMatch(next);
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
    _searchController.dispose();
    _lyricsFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasMatches = _matches.isNotEmpty;
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textDirection: TextDirection.rtl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _findMatches(),
                  onChanged: (_) {
                    setState(() {
                      _matches = [];
                      _activeMatch = -1;
                      _hasSearched = false;
                    });
                  },
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'جست‌وجو در متن همین ویس...',
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    suffixIcon: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      tooltip: 'جست‌وجو',
                      onPressed: _findMatches,
                      icon: const Icon(Icons.search_rounded, size: 17),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه قبلی',
                onPressed: hasMatches ? () => _moveMatch(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ),
              const SizedBox(width: 3),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه بعدی',
                onPressed: hasMatches ? () => _moveMatch(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _searchController.text.isEmpty
                  ? 'جست‌وجو فقط در متن فایل انتخاب‌شده انجام می‌شود.'
                  : hasMatches
                      ? 'نتیجه ${_activeMatch + 1} از ${_matches.length}'
                      : _hasSearched
                          ? 'کلمه‌ای با این عبارت پیدا نشد.'
                          : 'برای شروع، دکمه جست‌وجو را بزن.',
              style: TextStyle(
                fontSize: 11,
                color: hasMatches ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _lyricsFocusNode,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textDirection: TextDirection.rtl,
              onChanged: _scheduleSave,
              style: const TextStyle(fontSize: 14),
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
                onPressed: _saving
                    ? null
                    : () async {
                        _saveTimer?.cancel();
                        await _save(_controller.text);
                        if (mounted) widget.onSaveComplete();
                      },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('ذخیره', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    this.gap = 36,
  });

  final String text;
  final TextStyle style;
  final double gap;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller.stop();
      _controller.value = 0;
      _started = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout();
        final textWidth = painter.width;
        final availableWidth = constraints.maxWidth;

        if (textWidth <= availableWidth || availableWidth <= 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: widget.style,
            ),
          );
        }

        final distance = textWidth + widget.gap;
        if (!_started) {
          _started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final milliseconds =
                (distance / 32 * 1000).round().clamp(1800, 20000).toInt();
            _controller.duration = Duration(milliseconds: milliseconds);
            _controller.repeat();
          });
        }

        return ClipRect(
          child: SizedBox(
            height: painter.height,
            width: availableWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(-distance * _controller.value, 0),
                child: child,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                  SizedBox(width: widget.gap),
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
), ''),
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

  Future<void> _openFolderManager() async {
    final folders = await _store.loadFolders();
    if (!mounted) return;
    final selected = folders.map((folder) => Map<String, String>.from(folder)).toList();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('پوشه‌های کتابخانه'),
          content: SizedBox(
            width: double.maxFinite,
            height: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text('هنوز پوشه‌ای انتخاب نشده است.'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: selected.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          selected[index]['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'حذف پوشه',
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(
                            () => selected.removeAt(index),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final folder = await _folderService.pickFolder();
                      if (folder == null) return;
                      if (selected.any((item) => item['uri'] == folder['uri'])) return;
                      setDialogState(() => selected.add(folder));
                    } catch (error) {
                      if (mounted) _showMessage('انتخاب پوشه ناموفق بود: $error');
                    }
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('افزودن پوشه'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final result = selected
                          .map((folder) => Map<String, String>.from(folder))
                          .toList();
                      Navigator.pop(dialogContext);
                      unawaited(_scanSelectedFolders(result));
                    },
              icon: const Icon(Icons.sync),
              label: const Text('شروع اسکن'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanSelectedFolders(List<Map<String, String>> folders) async {
    try {
      await _store.saveFolders(folders);
      if (mounted) {
        setState(() {
          _libraryFolders
            ..clear()
            ..addAll(folders.map((folder) => Map<String, String>.from(folder)));
        });
      }
      _showMessage('در حال اسکن پوشه‌ها...');
      final found = await _folderService.scanFolders(
        folders.map((folder) => folder['uri']!).toList(),
      );
      final existing = _tracks.map((track) => track.path).toSet();
      final added = <AudioTrack>[];
      var duplicates = 0;
      for (final item in found) {
        final uri = item['uri']!;
        if (!existing.add(uri)) {
          duplicates++;
          continue;
        }
        final name = item['name']!;
        final dotIndex = name.lastIndexOf('.');
        final title = dotIndex > 0 ? name.substring(0, dotIndex) : name;
        added.add(AudioTrack(path: uri, title: title));
      }
      if (added.isNotEmpty) {
        setState(() => _tracks.addAll(added));
        await _persistTracks();
        await _replacePlaylist(autoplay: false);
      }
      _showMessage(
        'اسکن تمام شد: ${added.length} فایل جدید، '
        '$duplicates فایل تکراری از ${found.length} فایل شناسایی‌شده.',
      );
    } catch (error) {
      _showMessage('اسکن پوشه‌ها ناموفق بود: $error');
    }
  }

  Future<void> _applyEffectiveVolume({Duration? position}) async {
    final positionMs = (position ?? _player.position).inMilliseconds;
    final trackPath = _currentTrack?.path;
    final ranges = trackPath == null
        ? const <VolumeRange>[]
        : (_volumeRangesByTrack[base64Url.encode(utf8.encode(trackPath))] ??
            const <VolumeRange>[]);
    final effective = scheduledVolumeAt(ranges, positionMs, _volume);
    if (_lastAppliedVolume != null &&
        (effective - _lastAppliedVolume!).abs() < 0.0001) {
      return;
    }
    _lastAppliedVolume = effective;
    await _player.setVolume(effective);
  }

  Future<void> _setPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _volume = normalized);
    _lastAppliedVolume = null;
    await _applyEffectiveVolume();
    await _store.saveVolume(normalized);
  }

  Future<void> _openVolumeAutomation() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را انتخاب کن.');
      return;
    }
    final trackKey = base64Url.encode(utf8.encode(track.path));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VolumeAutomationScreen(
          initialRanges: List<VolumeRange>.from(
            _volumeRangesByTrack[trackKey] ?? const <VolumeRange>[],
          ),
          onSave: (ranges) async {
            final preferences = await SharedPreferences.getInstance();
            final key = 'volume_ranges_v1_$trackKey';
            await preferences.setString(
              key,
              jsonEncode(ranges.map((range) => range.toMap()).toList()),
            );
            if (!mounted) return;
            setState(() {
              _volumeRangesByTrack[trackKey] = List<VolumeRange>.from(ranges)
                ..sort((a, b) => a.startMs.compareTo(b.startMs));
              _lastAppliedVolume = null;
            });
            await _applyEffectiveVolume();
          },
        ),
      ),
    );
  }

  Future<void> _showVolumeSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('صدای خروجی پلیر')),
                  Text('${(_volume * 100).round()}%'),
                ],
              ),
              Slider(
                value: _volume,
                min: 0,
                max: 1,
                divisions: 100,
                label: '${(_volume * 100).round()}%',
                onChanged: (value) {
                  setSheetState(() {});
                  _setPlayerVolume(value);
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => _setPlayerVolume(0),
                    child: const Text('بی‌صدا'),
                  ),
                  TextButton(
                    onPressed: () => _setPlayerVolume(1),
                    child: const Text('صدای کامل'),
                  ),
                ],
              ),
              Text(
                'این تنظیم فقط بلندی صدای همین پلیر را تغییر می‌دهد و صدای کلی گوشی را تنظیم نمی‌کند.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _replacePlaylist({required bool autoplay}) async {
    if (_tracks.isEmpty) {
      await _player.stop();
      return;
    }
    final oldIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _tracks.length - 1).toInt();
    final sources = _tracks.map((track) {
      final uri = Uri.parse(track.path);
      return AudioSource.uri(
        uri.scheme == 'content' ? uri : Uri.file(track.path),
      );
    }).toList();
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

  Future<void> _confirmRemoveTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف از کتابخانه'),
        content: Text('«${track.title}» فقط از کتابخانهٔ برنامه حذف می‌شود و فایل اصلی در حافظه باقی می‌ماند. ادامه می‌دهی؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف از کتابخانه'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _removeTrack(index);
  }

  Future<void> _renameTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final controller = TextEditingController(text: track.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ویرایش نام فایل'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(labelText: 'نام جدید'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty || newTitle == track.title) return;
    if (_tracks.any((item) => item.path != track.path && item.title == newTitle)) {
      _showMessage('فایلی با این نام در کتابخانه وجود دارد.');
      return;
    }
    try {
      final renamed = await _folderService.renameItem(track.path, newTitle);
      final newPath = renamed['path'];
      if (newPath == null || newPath.isEmpty) {
        throw StateError('مسیر جدید فایل از سیستم دریافت نشد.');
      }
      final oldPath = track.path;
      final oldIndex = _tracks.indexWhere((item) => item.path == oldPath);
      if (oldIndex < 0) return;
      _tracks[oldIndex] = AudioTrack(path: newPath, title: newTitle);
      for (var i = 0; i < _bookmarks.length; i++) {
        final bookmark = _bookmarks[i];
        if (bookmark.audioPath != oldPath) continue;
        _bookmarks[i] = AudioBookmark(
          id: bookmark.id,
          audioPath: newPath,
          audioTitle: newTitle,
          positionMs: bookmark.positionMs,
          createdAt: bookmark.createdAt,
          title: bookmark.title,
          topic: bookmark.topic,
          endPositionMs: bookmark.endPositionMs,
          isTopicRange: bookmark.isTopicRange,
        );
      }
      for (var i = 0; i < _playlists.length; i++) {
        final playlist = _playlists[i];
        _playlists[i] = playlist.copyWith(
          trackPaths: playlist.trackPaths
              .map((path) => path == oldPath ? newPath : path)
              .toList(),
        );
      }
      final savedLyrics = _lyrics.remove(oldPath);
      if (savedLyrics != null) _lyrics[newPath] = savedLyrics;
      if (_pendingTopicAudioPath == oldPath) _pendingTopicAudioPath = newPath;
      await _persistTracks();
      await _store.saveBookmarks(_bookmarks);
      await _store.savePlaylists(_playlists);
      await _store.saveLyrics(_lyrics);
      await _replacePlaylist(autoplay: false);
      if (mounted) setState(() {});
      _showMessage('نام فایل در حافظه و کتابخانه تغییر کرد.');
    } catch (error) {
      _showMessage('تغییر نام فایل ناموفق بود: $error');
    }
  }

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _bookmarks.removeWhere((bookmark) => bookmark.audioPath == removed.path);
    if (_pendingTopicAudioPath == removed.path) {
      _pendingTopicStartMs = null;
      _pendingTopicAudioPath = null;
    }
    for (var i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      _playlists[i] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((path) => path != removed.path).toList(),
      );
    }
    await _store.savePlaylists(_playlists);
    await _store.saveBookmarks(_bookmarks);
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

  Future<void> _addBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }

    final position = _player.position;
    final details = await _showBookmarkDetailsDialog(
      initialTitle: track.title,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: position.inMilliseconds,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
      });
      _showMessage(
        'نشانک معمولی در ${_formatDuration(position)} ذخیره شد. این نشانک وارد پخش هوشمند نمی‌شود.',
      );
    } catch (error) {
      _showMessage('ذخیره نشانک ناموفق بود: $error');
    }
  }

  Future<void> _toggleTopicRangeBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای ثبت موضوع انتخاب کن.');
      return;
    }

    final startMs = _pendingTopicStartMs;
    if (startMs == null) {
      final positionMs = _player.position.inMilliseconds;
      setState(() {
        _pendingTopicStartMs = positionMs;
        _pendingTopicAudioPath = track.path;
      });
      _showMessage('شروع موضوع در ${_formatDuration(Duration(milliseconds: positionMs))} ثبت شد؛ برای ثبت پایان، دوباره همین دکمه را بزن.');
      return;
    }

    if (_pendingTopicAudioPath != track.path) {
      _showMessage('برای ثبت پایان، ابتدا به همان فایل صوتی که شروع موضوع را در آن ثبت کردی برگرد.');
      return;
    }

    final endMs = _player.position.inMilliseconds;
    if (endMs <= startMs) {
      _showMessage('زمان پایان باید بعد از زمان شروع باشد. نشانگر شروع حفظ شد؛ کمی جلوتر برو و دوباره بزن.');
      return;
    }

    final details = await _showBookmarkDetailsDialog(initialTitle: track.title);
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای نشانک موضوعی، نام موضوع را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: startMs,
      endPositionMs: endMs,
      isTopicRange: true,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
        _selectedSmartTopic ??= bookmark.topic;
        _pendingTopicStartMs = null;
        _pendingTopicAudioPath = null;
      });
      await _saveSmartSettings();
      _showMessage('بازه موضوع «${bookmark.topic}» از ${_formatDuration(Duration(milliseconds: startMs))} تا ${_formatDuration(Duration(milliseconds: endMs))} ذخیره شد.');
    } catch (error) {
      _showMessage('ذخیره بازه موضوع ناموفق بود: $error');
    }
  }

  List<String> get _availableSmartTopics {
    final topics = _bookmarks
        .where((bookmark) => bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs)
        .map((bookmark) => bookmark.topic.trim())
        .where((topic) => topic.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return topics;
  }

  Future<Map<String, String>?> _showBookmarkDetailsDialog({
    required String initialTitle,
    String initialTopic = '',
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final topicController = TextEditingController(text: initialTopic);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مشخصات نشانک'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'عنوان نشانک'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              textDirection: TextDirection.rtl,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'موضوع',
                hintText: 'مثلاً تمرکز',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'title': titleController.text.trim(),
              'topic': topicController.text.trim(),
            }),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    titleController.dispose();
    topicController.dispose();
    return result;
  }

  Future<void> _editBookmark(AudioBookmark bookmark) async {
    final details = await _showBookmarkDetailsDialog(
      initialTitle: bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
      initialTopic: bookmark.topic,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }
    final updated = _bookmarks
        .map((item) => item.id == bookmark.id
            ? AudioBookmark(
                id: item.id,
                audioPath: item.audioPath,
                audioTitle: item.audioTitle,
                positionMs: item.positionMs,
                endPositionMs: item.endPositionMs,
                isTopicRange: item.isTopicRange,
                createdAt: item.createdAt,
                title: details['title']!,
                topic: details['topic']!,
              )
            : item)
        .toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('ویرایش نشانک ذخیره نشد: $error');
    }
  }

  Future<void> _deleteBookmark(AudioBookmark bookmark) async {
    final updated = _bookmarks.where((item) => item.id != bookmark.id).toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('حذف نشانک ناموفق بود: $error');
    }
  }

  Future<void> _saveSmartSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('smart_topic_mode_v1', _smartTopicMode);
      await preferences.setString('smart_order_mode_v1', _smartOrderMode);
      if (_selectedSmartTopic == null) {
        await preferences.remove('smart_selected_topic_v1');
      } else {
        await preferences.setString('smart_selected_topic_v1', _selectedSmartTopic!);
      }
    } catch (error) {
      _showMessage('ذخیره تنظیمات پخش هوشمند ناموفق بود: $error');
    }
  }

  Future<void> _startSmartPlayback() async {
    final topics = _availableSmartTopics;
    if (topics.isEmpty) {
      _showMessage('ابتدا در تب نشانک‌ها برای نشانک‌ها موضوع تعیین کن.');
      _tabController.animateTo(1);
      return;
    }

    String topic;
    if (_smartTopicMode == 'random') {
      topic = topics[Random().nextInt(topics.length)];
    } else {
      final selected = _selectedSmartTopic;
      if (selected == null || !topics.contains(selected)) {
        _showMessage('ابتدا یک موضوع برای پخش هوشمند انتخاب کن.');
        _tabController.animateTo(4);
        return;
      }
      topic = selected;
    }

    final matching = _bookmarks
        .where((bookmark) =>
            bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs &&
            bookmark.topic.trim() == topic &&
            _tracks.any((track) => track.path == bookmark.audioPath))
        .toList();
    if (matching.isEmpty) {
      _showMessage('برای این موضوع نشانک قابل پخشی پیدا نشد.');
      return;
    }

    if (_smartOrderMode == 'random') {
      matching.shuffle(Random());
    } else {
      matching.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final sources = <AudioSource>[];
    for (final bookmark in matching) {
      final parsed = Uri.parse(bookmark.audioPath);
      final uri = parsed.scheme == 'content'
          ? parsed
          : Uri.file(bookmark.audioPath);
      sources.add(
        ClippingAudioSource(
          child: AudioSource.uri(uri),
          start: Duration(milliseconds: bookmark.positionMs),
          end: Duration(milliseconds: bookmark.endPositionMs!),
        ),
      );
    }

    try {
      await _player.pause();
      await _smartPlayer.stop();
      await _smartPlayer.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      if (!mounted) return;
      setState(() {
        _activeSmartTopic = topic;
        _smartQueueBookmarks
          ..clear()
          ..addAll(matching);
        _smartQueueReady = true;
      });
      await _smartPlayer.play();
    } catch (error) {
      if (mounted) {
        setState(() {
          _smartQueueReady = false;
          _smartQueueBookmarks.clear();
        });
        _showMessage('شروع پخش هوشمند ناموفق بود: $error');
      }
    }
  }

  Future<void> _setSmartPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _smartVolume = normalized);
    await _smartPlayer.setVolume(normalized);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('smart_topic_volume_v1', normalized);
  }

  Future<void> _toggleSmartPlayback() async {
    if (_smartPlayer.playing) {
      await _smartPlayer.pause();
      return;
    }
    if (_smartQueueReady &&
        _smartPlayer.processingState != ProcessingState.completed) {
      await _smartPlayer.play();
      return;
    }
    await _startSmartPlayback();
  }

  Future<void> _stopSmartPlayback() async {
    await _smartPlayer.stop();
    if (mounted) {
      setState(() {
        _smartQueueReady = false;
        _activeSmartTopic = null;
        _smartQueueBookmarks.clear();
      });
    }
  }

  Future<void> _playBookmark(AudioBookmark bookmark) async {
    final trackIndex =
        _tracks.indexWhere((track) => track.path == bookmark.audioPath);
    if (trackIndex < 0) {
      _showMessage('فایل صوتی این نشانک در کتابخانه موجود نیست.');
      return;
    }

    try {
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      final position = Duration(milliseconds: bookmark.positionMs);
      await _player.seek(position, index: trackIndex);
      await _player.play();
    } catch (error) {
      _showMessage('پخش از نشانک ممکن نشد: $error');
    }
  }

  Widget _buildBookmarksTab(ColorScheme colors) {
    final track = _currentTrack;
    final trackBookmarks = track == null
        ? const <AudioBookmark>[]
        : _bookmarks
            .where((bookmark) => bookmark.audioPath == track.path)
            .toList();

    if (track == null) {
      return const Center(
        child: Text(
          'برای مشاهده نشانک‌ها، ابتدا یک فایل صوتی انتخاب کن.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (trackBookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'برای «${track.title}» هنوز نشانکی ثبت نشده است. هنگام پخش این فایل، دکمه نشانک را لمس کن.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      key: ValueKey('bookmarks-${track.path}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: trackBookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final bookmark = trackBookmarks[index];
        final createdAt = bookmark.createdAt;
        final dateLabel =
            '${createdAt.year}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.day.toString().padLeft(2, '0')}  '
            '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(
              bookmark.isTopicRange
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_rounded,
              color: colors.primary,
            ),
            title: Text(
              bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '${bookmark.isTopicRange ? 'موضوع' : 'نشانک معمولی'}  •  ${bookmark.topic.isEmpty ? 'بدون موضوع' : bookmark.topic}  •  ${_formatDuration(Duration(milliseconds: bookmark.positionMs))}${bookmark.isTopicRange && bookmark.endPositionMs != null ? ' تا ${_formatDuration(Duration(milliseconds: bookmark.endPositionMs!))}' : ''}  •  $dateLabel',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'مدیریت نشانک',
              onSelected: (value) {
                if (value == 'edit') _editBookmark(bookmark);
                if (value == 'delete') _deleteBookmark(bookmark);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('ویرایش عنوان و موضوع')),
                PopupMenuItem(value: 'delete', child: Text('حذف نشانک')),
              ],
            ),
            onTap: () => _playBookmark(bookmark),
          ),
        );
      },
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ساخت پلی‌لیست جدید'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(
            labelText: 'نام پلی‌لیست',
            hintText: 'مثلاً موسیقی آرامش‌بخش',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ساختن'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final playlist = AudioPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      trackPaths: const [],
    );
    setState(() {
      _playlists.add(playlist);
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
  }

  Future<void> _addCurrentTrackToPlaylist(AudioPlaylist playlist) async {
    final track = _currentTrack;
    if (track == null) return;
    if (playlist.trackPaths.contains(track.path)) {
      _showMessage('این فایل از قبل در پلی‌لیست «${playlist.name}» وجود دارد.');
      return;
    }
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: [...playlist.trackPaths, track.path],
      );
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
    _showMessage('«${track.title}» به پلی‌لیست «${playlist.name}» اضافه شد.');
  }

  Future<void> _removeFromPlaylist(AudioPlaylist playlist, String path) async {
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((item) => item != path).toList(),
      );
    });
    await _store.savePlaylists(_playlists);
  }

  bool get _currentTrackIsFavorite {
    final track = _currentTrack;
    if (track == null) return false;
    final index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    return index >= 0 && _playlists[index].trackPaths.contains(track.path);
  }

  Future<void> _toggleCurrentTrackFavorite() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }
    var index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    if (index < 0) {
      _playlists.add(const AudioPlaylist(
        id: _favoritesPlaylistId,
        name: _favoritesPlaylistName,
        trackPaths: [],
      ));
      index = _playlists.length - 1;
    }
    final favorites = _playlists[index];
    final isFavorite = favorites.trackPaths.contains(track.path);
    setState(() {
      _playlists[index] = favorites.copyWith(
        trackPaths: isFavorite
            ? favorites.trackPaths.where((path) => path != track.path).toList()
            : [...favorites.trackPaths, track.path],
      );
      _expandedPlaylistId = _favoritesPlaylistId;
    });
    await _store.savePlaylists(_playlists);
    _showMessage(isFavorite
        ? '«${track.title}» از علاقه‌مندی‌ها حذف شد.'
        : '«${track.title}» به علاقه‌مندی‌ها اضافه شد.');
  }

  Future<void> _deletePlaylist(AudioPlaylist playlist) async {
    if (playlist.id == _favoritesPlaylistId) {
      _showMessage('پلی‌لیست علاقه‌مندی‌ها قابل حذف نیست.');
      return;
    }
    setState(() => _playlists.removeWhere((item) => item.id == playlist.id));
    await _store.savePlaylists(_playlists);
  }

  Widget _buildPlaylistsTab(ColorScheme colors) {
    final current = _currentTrack;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: IconButton.filled(
              tooltip: 'پلی‌لیست جدید',
              onPressed: _createPlaylist,
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? const SizedBox.shrink()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    final expanded = _expandedPlaylistId == playlist.id;
                    final tracks = playlist.trackPaths
                        .map((path) => _tracks.where((track) => track.path == path))
                        .where((matches) => matches.isNotEmpty)
                        .map((matches) => matches.first)
                        .toList();
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: PageStorageKey(playlist.id),
                        initiallyExpanded: expanded,
                        onExpansionChanged: (value) => setState(() {
                          _expandedPlaylistId = value ? playlist.id : null;
                        }),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        children: [
                          if (current != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _addCurrentTrackToPlaylist(playlist),
                                  child: const Text('افزودن آهنگ در حال پخش'),
                                ),
                              ),
                            ),
                          if (playlist.id != _favoritesPlaylistId)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _deletePlaylist(playlist),
                                  child: const Text('حذف پلی‌لیست'),
                                ),
                              ),
                            ),
                          if (tracks.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('این پلی‌لیست هنوز خالی است.'),
                            )
                          else
                            ...tracks.map((track) => ListTile(
                                  dense: true,
                                  title: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final trackIndex = _tracks.indexOf(track);
                                    if (trackIndex >= 0) _playTrack(trackIndex);
                                  },
                                  trailing: TextButton(
                                    onPressed: () => _removeFromPlaylist(
                                      playlist,
                                      track.path,
                                    ),
                                    child: const Text('حذف'),
                                  ),
                                )),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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

  Future<DateTime?> _chooseScheduleDateTime(String title) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: title,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      helpText: 'ساعت اجرا',
    );
    if (time == null) return null;
    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!scheduled.isAfter(DateTime.now())) {
      _showMessage('زمان انتخاب‌شده باید در آینده باشد.');
      return null;
    }
    return scheduled;
  }

  Future<void> _scheduleStartDialog() async {
    if (_tracks.isEmpty) {
      _showMessage('ابتدا یک فایل صوتی به کتابخانه اضافه کن.');
      return;
    }
    String selectedPath = _currentTrack?.path ?? _tracks.first.path;
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('شروع خودکار پخش'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedPath,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'فایل صوتی'),
            items: _tracks.map((track) => DropdownMenuItem<String>(
              value: track.path,
              child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selectedPath = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selectedPath),
              child: const Text('انتخاب زمان'),
            ),
          ],
        ),
      ),
    );
    if (path == null || !mounted) return;
    final at = await _chooseScheduleDateTime('تاریخ شروع پخش');
    if (at == null) return;
    final track = _tracks.firstWhere((item) => item.path == path);
    try {
      await ScheduledPlaybackService.scheduleStart(path: track.path, title: track.title, at: at);
      _showMessage('شروع پخش «${track.title}» برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم شروع خودکار ناموفق بود: $error');
    }
  }

  Future<void> _scheduleStopDialog() async {
    final at = await _chooseScheduleDateTime('تاریخ توقف پخش');
    if (at == null) return;
    try {
      await ScheduledPlaybackService.scheduleStop(at: at);
      _showMessage('توقف پخش برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم توقف خودکار ناموفق بود: $error');
    }
  }

  String _formatScheduleDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.year % 100)}/${two(value.month)}/${two(value.day)} - ${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _cancelScheduledStart() async {
    try {
      await ScheduledPlaybackService.cancelStart();
      _showMessage('شروع خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان شروع ناموفق بود: $error');
    }
  }

  Future<void> _cancelScheduledStop() async {
    try {
      await ScheduledPlaybackService.cancelStop();
      _showMessage('توقف خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان توقف ناموفق بود: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _messageTimer?.cancel();
    final generation = ++_messageGeneration;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          leading: const Icon(Icons.info_outline_rounded),
          content: Dismissible(
            key: ValueKey('app-message-$generation'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _messageTimer?.cancel();
              messenger.hideCurrentMaterialBanner();
            },
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(message),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'بستن پیام',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _messageTimer?.cancel();
                messenger.hideCurrentMaterialBanner();
              },
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || generation != _messageGeneration) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  @override
  void dispose() {
    _lyricsHoldTimer?.cancel();
    _themeHoldTimer?.cancel();
    _messageTimer?.cancel();
    _smartTopicMarqueeController.dispose();
    _tabController.dispose();
    _player.dispose();
    unawaited(_smartPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
        body: Column(
          children: [
            _buildPlayerToolbar(colors),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLyricsTab(colors),
                  _buildBookmarksTab(colors),
                  _buildPlaylistsTab(colors),
                  _buildLibraryTab(colors),
                  _buildSmartTab(colors),
                ],
              ),
            ),
            _buildBottomNavigation(colors),
            _buildPlayerPanel(colors),
          ],
        ),
      );
  }

  Widget _buildBottomNavigation(ColorScheme colors) {
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: false,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                labelPadding: EdgeInsets.zero,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.notes_rounded, size: 26)),
                    ),
                    text: 'متن',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.bookmarks_outlined, size: 26)),
                    ),
                    text: 'نشانک',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.queue_music_rounded, size: 26)),
                    ),
                    text: 'پلی‌لیست',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.library_music_outlined, size: 26)),
                    ),
                    text: 'کتابخانه',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.psychology_rounded, size: 26)),
                    ),
                    text: 'بخش هوشمند',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartTab(ColorScheme colors) {
    final topics = _availableSmartTopics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartTopicMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'انتخاب موضوع',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'manual',
                    child: Text('انتخاب موضوع توسط من', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('انتخاب موضوع تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartTopicMode = value);
                  await _saveSmartSettings();
                  if (value == 'manual' && topics.isNotEmpty && mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('انتخاب موضوع'),
                        content: SizedBox(
                          width: 320,
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final topic in topics)
                                ListTile(
                                  title: Text(topic),
                                  trailing: _selectedSmartTopic == topic
                                      ? const Icon(Icons.check_rounded)
                                      : null,
                                  onTap: () async {
                                    setState(() => _selectedSmartTopic = topic);
                                    await _saveSmartSettings();
                                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartOrderMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'ترتیب پخش نشانک‌ها',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'sequential',
                    child: Text('به ترتیب ثبت', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('به‌صورت تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartOrderMode = value);
                  await _saveSmartSettings();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          textDirection: TextDirection.rtl,
          children: [
            const Text(
              'موضوع در حال پخش:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final topicText = _activeSmartTopic ?? '—';
                  final textPainter = TextPainter(
                    text: TextSpan(
                      text: topicText,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                  )..layout();
                  final textWidth = textPainter.width;
                  final viewportWidth = constraints.maxWidth;
                  if (textWidth <= viewportWidth) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        topicText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  return ClipRect(
                    child: SizedBox(
                      height: 22,
                      child: AnimatedBuilder(
                        animation: _smartTopicMarqueeController,
                        builder: (context, child) {
                          final travel = viewportWidth + textWidth;
                          final offset = viewportWidth -
                              (_smartTopicMarqueeController.value * travel);
                          return Transform.translate(
                            offset: Offset(offset, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: textWidth,
                          child: Text(
                            topicText,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: topics.isEmpty ? null : _toggleSmartPlayback,
                icon: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                label: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Text(
                    snapshot.data == true ? 'مکث' : 'شروع پخش هوشمند',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'توقف پخش هوشمند',
              onPressed: _stopSmartPlayback,
              icon: const Icon(Icons.stop_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'تنظیم صدای پلیر موضوعی',
              onPressed: () => setState(
                () => _showSmartVolumeSlider = !_showSmartVolumeSlider,
              ),
              icon: Icon(
                _smartVolume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
        if (_showSmartVolumeSlider)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 8, top: 2),
            child: Row(
              children: [
                const Icon(Icons.volume_down_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: _smartVolume,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    label: '${(_smartVolume * 100).round()}٪',
                    onChanged: (value) {
                      setState(() => _smartVolume = value);
                      unawaited(_smartPlayer.setVolume(value));
                    },
                    onChangeEnd: (value) async {
                      await _setSmartPlayerVolume(value);
                      if (mounted) setState(() => _showSmartVolumeSlider = false);
                    },
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(_smartVolume * 100).round()}٪',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_smartQueueBookmarks.isNotEmpty)
          StreamBuilder<int?>(
            stream: _smartPlayer.currentIndexStream,
            initialData: _smartPlayer.currentIndex,
            builder: (context, snapshot) {
              final activeIndex = snapshot.data ?? -1;
              return Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  itemCount: _smartQueueBookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _smartQueueBookmarks[index];
                    final isActive = index == activeIndex;
                    final endMs = bookmark.endPositionMs ?? bookmark.positionMs;
                    final duration = Duration(
                      milliseconds: (endMs - bookmark.positionMs).clamp(0, 1 << 31).toInt(),
                    );
                    return Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: isActive
                          ? colors.primary.withValues(alpha: 0.10)
                          : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text(
                              _formatDuration(duration),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isActive ? colors.primary : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            isActive ? Icons.graphic_eq_rounded : Icons.bookmark_outline_rounded,
                            size: 17,
                            color: isActive ? colors.primary : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  bookmark.audioTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  bookmark.topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? colors.primary : colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isActive)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 6),
                              child: Text(
                                'در حال پخش',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          )
        else if (topics.isEmpty)
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded, size: 20),
            title: Text('هنوز موضوعی ثبت نشده است.', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              'در نوار پخش، با دکمه نشانک موضوعی ابتدا و انتهای هر موضوع را ثبت کن.',
              style: TextStyle(fontSize: 11),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'برای نمایش فهرست، پخش یک موضوع را شروع کن.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 12),
        StreamBuilder<Duration>(
          stream: _smartPlayer.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            return StreamBuilder<Duration?>(
              stream: _smartPlayer.durationStream,
              builder: (context, durationSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = durationSnapshot.data ?? Duration.zero;
                final max = duration.inMilliseconds.toDouble();
                return Column(
                  children: [
                    LinearProgressIndicator(
                      value: max <= 0
                          ? 0
                          : (position.inMilliseconds / max).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position)),
                        Text(_formatDuration(duration)),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  void _onThemeButtonDown(PointerDownEvent event) {
    _themeLongPressTriggered = false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _themeLongPressTriggered = true;
      _showPresetThemePicker();
    });
  }

  void _onThemeButtonUp(PointerUpEvent event) {
    final wasLongPress = _themeLongPressTriggered;
    final wasShortPress = _themeHoldTimer?.isActive ?? false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
    if (!wasLongPress && wasShortPress) widget.onToggleTheme();
  }

  void _onThemeButtonCancel(PointerCancelEvent event) {
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
  }

  Future<void> _showPresetThemePicker() async {
    const themes = <({String id, String name, Color color, String description})>[
      (id: 'teal', name: 'فیروزه‌ای', color: Color(0xFF16A6A0), description: 'تم پیش‌فرض فعلی'),
      (id: 'blue', name: 'آبی اقیانوسی', color: Color(0xFF2878D0), description: 'آرام و خنک'),
      (id: 'purple', name: 'بنفش', color: Color(0xFF8764D8), description: 'بنفش مدرن'),
      (id: 'green', name: 'سبز جنگلی', color: Color(0xFF39865A), description: 'طبیعی و ملایم'),
      (id: 'amber', name: 'کهربایی', color: Color(0xFFD28A22), description: 'گرم و پرانرژی'),
      (id: 'rose', name: 'رز', color: Color(0xFFC65D78), description: 'صورتی متمایل به رز'),
      (id: 'slate', name: 'خاکستری', color: Color(0xFF718096), description: 'خنثی و مینیمال'),
    ];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('انتخاب تم برنامه'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'حالت فعلی: ${widget.isDark ? 'شب' : 'روز'}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ),
              for (final theme in themes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: theme.color,
                  ),
                  title: Text(theme.name),
                  subtitle: Text(theme.description),
                  trailing: widget.themeId == theme.id
                      ? const Icon(Icons.check_circle_rounded)
                      : null,
                  onTap: () {
                    widget.onSelectTheme(theme.id);
                    Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerToolbar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              PopupMenuButton<String>(
                tooltip: 'پشتیبان‌گیری و بازیابی',
                icon: const Icon(Icons.backup_outlined, size: 24),
                onSelected: (value) {
                  if (value == 'backup') _createBackup();
                  if (value == 'restore') _restoreBackup();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'backup',
                    child: Row(
                      children: [
                        Icon(Icons.save_alt_rounded),
                        SizedBox(width: 12),
                        Text('تهیه نسخه پشتیبان'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.settings_backup_restore_rounded),
                        SizedBox(width: 12),
                        Text('بازیابی نسخه پشتیبان'),
                      ],
                    ),
                  ),
                ],
              ),
              Tooltip(
                message: 'لمس کوتاه: تغییر شب و روز • نگه‌داشتن ۳ ثانیه: انتخاب تم',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onThemeButtonDown,
                  onPointerUp: _onThemeButtonUp,
                  onPointerCancel: _onThemeButtonCancel,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        widget.isDark ? Icons.light_mode : Icons.dark_mode,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'شروع و پایان خودکار',
                icon: const Icon(Icons.schedule_rounded, size: 24),
                onSelected: (value) {
                  if (value == 'start') _scheduleStartDialog();
                  if (value == 'stop') _scheduleStopDialog();
                  if (value == 'cancel_start') _cancelScheduledStart();
                  if (value == 'cancel_stop') _cancelScheduledStop();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'start', child: Text('تنظیم شروع خودکار')),
                  PopupMenuItem(value: 'stop', child: Text('تنظیم توقف خودکار')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'cancel_start', child: Text('لغو شروع خودکار')),
                  PopupMenuItem(value: 'cancel_stop', child: Text('لغو توقف خودکار')),
                ],
              ),
              IconButton(
                tooltip: 'نقشه تغییرات صدا',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                onPressed: _openVolumeAutomation,
                icon: const Icon(Icons.multiline_chart_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    final hasLibraryItems = _libraryFolders.isNotEmpty || _tracks.isNotEmpty;
    final actions = Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'انتخاب فایل صوتی',
          onPressed: _pickAudio,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.audio_file_rounded, size: 20),
        ),
        const SizedBox(width: 3),
        IconButton.filledTonal(
          tooltip: 'انتخاب پوشه',
          onPressed: _openFolderManager,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.create_new_folder_outlined, size: 20),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final folder in _libraryFolders)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_rounded, size: 18, color: colors.primary),
                        const SizedBox(width: 4),
                        Text(
                          folder['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (!hasLibraryItems) {
      return Center(child: actions);
    }

    final itemCount = _tracks.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: actions,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: itemCount,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            itemBuilder: (context, index) {
              final trackIndex = index;
              final track = _tracks[trackIndex];
              final isCurrent = _currentIndex == trackIndex;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                minVerticalPadding: 0,
                minTileHeight: 30,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                tileColor: isCurrent
                    ? colors.primary.withValues(alpha: 0.10)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: _MarqueeText(
                  text: track.title,
                  style: const TextStyle(fontSize: 14),
                  gap: 28,
                ),
                onTap: () => _playTrack(trackIndex),
                trailing: PopupMenuButton<String>(
                  tooltip: 'گزینه‌های فایل صوتی',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  iconSize: 17,
                  onSelected: (action) {
                    if (action == 'rename') {
                      _renameTrack(trackIndex);
                    } else if (action == 'delete') {
                      _confirmRemoveTrack(trackIndex);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'rename',
                      height: 40,
                      child: Text('ویرایش نام'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      height: 40,
                      child: Text('حذف از کتابخانه'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onLyricsPointerDown(PointerDownEvent event) {
    _lyricsHoldTimer?.cancel();
    _lyricsHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _lyricsEditing = true);
    });
  }

  void _onLyricsPointerEnd(PointerEvent event) {
    _lyricsHoldTimer?.cancel();
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
              Icon(Icons.edit_note, size: 44, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'متن صدا ...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    if (_lyricsEditing) {
      return _LyricsEditor(
        key: ValueKey('edit-${track.path}'),
        track: track,
        initialText: _lyrics[track.path] ?? '',
        onSave: (value) => _saveLyrics(track.path, value),
        onSaveComplete: () {
          if (mounted) setState(() => _lyricsEditing = false);
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Expanded(
            child: Listener(
              onPointerDown: _onLyricsPointerDown,
              onPointerUp: _onLyricsPointerEnd,
              onPointerCancel: _onLyricsPointerEnd,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    (_lyrics[track.path] ?? '').trim().isEmpty
                        ? 'متن صدا ...'
                        : _lyrics[track.path]!,
                    textDirection: TextDirection.rtl,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await _store.saveLyrics(_lyrics);
                  _showMessage('متن ویس ذخیره شد.');
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded, color: colors.primary, size: 21),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _MarqueeText(
                            text: track?.title ?? 'فایلی برای پخش انتخاب نشده',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'در حال پخش',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'ثبت نشانک در زمان فعلی',
                        onPressed: track == null ? null : _addBookmark,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: _pendingTopicStartMs == null
                            ? 'ثبت شروع موضوع'
                            : 'ثبت پایان موضوع (${_formatDuration(Duration(milliseconds: _pendingTopicStartMs!))})',
                        onPressed: track == null ? null : _toggleTopicRangeBookmark,
                        color: _pendingTopicStartMs == null ? null : colors.primary,
                        icon: Icon(
                          _pendingTopicStartMs == null
                              ? Icons.bookmark_add_rounded
                              : Icons.bookmark_added_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: _currentTrack == null
                            ? 'علاقه‌مندی‌ها (ابتدا یک فایل پخش کن)'
                            : _currentTrackIsFavorite
                                ? 'حذف از علاقه‌مندی‌ها'
                                : 'افزودن به علاقه‌مندی‌ها',
                        onPressed: _toggleCurrentTrackFavorite,
                        icon: Icon(
                          _currentTrackIsFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: _currentTrackIsFavorite
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: 'شروع پخش هوشمند',
                        onPressed: _toggleSmartPlayback,
                        icon: const Icon(Icons.auto_awesome_rounded),
                      ),
                      IconButton(
                        tooltip: 'تنظیم صدای پلیر',
                        onPressed: _showVolumeSettings,
                        icon: Icon(
                          _volume == 0
                              ? Icons.volume_off_rounded
                              : _volume < 0.5
                                  ? Icons.volume_down_rounded
                                  : Icons.volume_up_rounded,
                          color: colors.primary,
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
                  final trackRanges = _bookmarks
                      .where((bookmark) =>
                          bookmark.isTopicRange &&
                          bookmark.audioPath == track?.path &&
                          bookmark.endPositionMs != null &&
                          bookmark.endPositionMs! > bookmark.positionMs)
                      .toList();
                  return Column(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final usableWidth =
                              (constraints.maxWidth - 32).clamp(0.0, double.infinity).toDouble();
                          return Stack(
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
                              if (max > 0)
                                ...trackRanges.expand((bookmark) {
                                  final startFraction =
                                      (bookmark.positionMs / max).clamp(0.0, 1.0).toDouble();
                                  final endFraction =
                                      (bookmark.endPositionMs! / max).clamp(0.0, 1.0).toDouble();
                                  return <Widget>[
                                    PositionedDirectional(
                                      start: 16 + usableWidth * startFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.tertiary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                    PositionedDirectional(
                                      start: 16 + usableWidth * endFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                  ];
                                }),
                            ],
                          );
                        },
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
                    icon: const Icon(Icons.shuffle, size: 27),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه عقب',
                    onPressed: track == null ? null : () => _seekRelative(-15),
                    icon: const Icon(Icons.replay_10, size: 27),
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
                    icon: const Icon(Icons.skip_previous_rounded, size: 32),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      final processing = snapshot.data?.processingState;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return SizedBox(
                        width: 60,
                        height: 60,
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
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  size: 34,
                                ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'بعدی',
                    onPressed: track == null ? null : _player.seekToNext,
                    icon: const Icon(Icons.skip_next_rounded, size: 32),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه جلو',
                    onPressed: track == null ? null : () => _seekRelative(15),
                    icon: const Icon(Icons.forward_10, size: 27),
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
                      size: 27,
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
    required this.onSaveComplete,
  });

  final AudioTrack track;
  final String initialText;
  final Future<void> Function(String value) onSave;
  final VoidCallback onSaveComplete;

  @override
  State<_LyricsEditor> createState() => _LyricsEditorState();
}

class _LyricsEditorState extends State<_LyricsEditor> {
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  final FocusNode _lyricsFocusNode = FocusNode();
  Timer? _saveTimer;
  bool _saving = false;
  bool _saved = true;
  bool _hasSearched = false;
  List<int> _matches = [];
  int _activeMatch = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _searchController = TextEditingController();
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
    if (_matches.isNotEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
        _hasSearched = false;
      });
    }
  }

  void _findMatches({bool preservePosition = false}) {
    final query = _searchController.text;
    final text = _controller.text;
    _hasSearched = true;
    if (query.isEmpty || text.isEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
      });
      return;
    }

    final source = text.toLowerCase();
    final needle = query.toLowerCase();
    final found = <int>[];
    var offset = 0;
    while (offset <= source.length - needle.length) {
      final index = source.indexOf(needle, offset);
      if (index < 0) break;
      found.add(index);
      offset = index + needle.length;
    }

    final previousStart = preservePosition && _activeMatch >= 0 &&
            _activeMatch < _matches.length
        ? _matches[_activeMatch]
        : -1;
    var nextActive = found.isEmpty ? -1 : 0;
    if (previousStart >= 0 && found.isNotEmpty) {
      final sameIndex = found.indexOf(previousStart);
      if (sameIndex >= 0) nextActive = sameIndex;
    }
    setState(() {
      _matches = found;
      _activeMatch = nextActive;
    });
    if (found.isNotEmpty) _selectMatch(nextActive);
  }

  void _selectMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final start = _matches[index];
    final end = start + _searchController.text.length;
    _lyricsFocusNode.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    setState(() => _activeMatch = index);
  }

  void _moveMatch(int step) {
    if (_matches.isEmpty) return;
    final next = (_activeMatch + step + _matches.length) % _matches.length;
    _selectMatch(next);
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
    _searchController.dispose();
    _lyricsFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasMatches = _matches.isNotEmpty;
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textDirection: TextDirection.rtl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _findMatches(),
                  onChanged: (_) {
                    setState(() {
                      _matches = [];
                      _activeMatch = -1;
                      _hasSearched = false;
                    });
                  },
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'جست‌وجو در متن همین ویس...',
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    suffixIcon: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      tooltip: 'جست‌وجو',
                      onPressed: _findMatches,
                      icon: const Icon(Icons.search_rounded, size: 17),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه قبلی',
                onPressed: hasMatches ? () => _moveMatch(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ),
              const SizedBox(width: 3),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه بعدی',
                onPressed: hasMatches ? () => _moveMatch(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _searchController.text.isEmpty
                  ? 'جست‌وجو فقط در متن فایل انتخاب‌شده انجام می‌شود.'
                  : hasMatches
                      ? 'نتیجه ${_activeMatch + 1} از ${_matches.length}'
                      : _hasSearched
                          ? 'کلمه‌ای با این عبارت پیدا نشد.'
                          : 'برای شروع، دکمه جست‌وجو را بزن.',
              style: TextStyle(
                fontSize: 11,
                color: hasMatches ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _lyricsFocusNode,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textDirection: TextDirection.rtl,
              onChanged: _scheduleSave,
              style: const TextStyle(fontSize: 14),
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
                onPressed: _saving
                    ? null
                    : () async {
                        _saveTimer?.cancel();
                        await _save(_controller.text);
                        if (mounted) widget.onSaveComplete();
                      },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('ذخیره', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    this.gap = 36,
  });

  final String text;
  final TextStyle style;
  final double gap;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller.stop();
      _controller.value = 0;
      _started = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout();
        final textWidth = painter.width;
        final availableWidth = constraints.maxWidth;

        if (textWidth <= availableWidth || availableWidth <= 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: widget.style,
            ),
          );
        }

        final distance = textWidth + widget.gap;
        if (!_started) {
          _started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final milliseconds =
                (distance / 32 * 1000).round().clamp(1800, 20000).toInt();
            _controller.duration = Duration(milliseconds: milliseconds);
            _controller.repeat();
          });
        }

        return ClipRect(
          child: SizedBox(
            height: painter.height,
            width: availableWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(-distance * _controller.value, 0),
                child: child,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                  SizedBox(width: widget.gap),
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
), ''),
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

  Future<void> _openFolderManager() async {
    final folders = await _store.loadFolders();
    if (!mounted) return;
    final selected = folders.map((folder) => Map<String, String>.from(folder)).toList();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('پوشه‌های کتابخانه'),
          content: SizedBox(
            width: double.maxFinite,
            height: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text('هنوز پوشه‌ای انتخاب نشده است.'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: selected.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          selected[index]['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'حذف پوشه',
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(
                            () => selected.removeAt(index),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final folder = await _folderService.pickFolder();
                      if (folder == null) return;
                      if (selected.any((item) => item['uri'] == folder['uri'])) return;
                      setDialogState(() => selected.add(folder));
                    } catch (error) {
                      if (mounted) _showMessage('انتخاب پوشه ناموفق بود: $error');
                    }
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('افزودن پوشه'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final result = selected
                          .map((folder) => Map<String, String>.from(folder))
                          .toList();
                      Navigator.pop(dialogContext);
                      unawaited(_scanSelectedFolders(result));
                    },
              icon: const Icon(Icons.sync),
              label: const Text('شروع اسکن'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanSelectedFolders(List<Map<String, String>> folders) async {
    try {
      await _store.saveFolders(folders);
      if (mounted) {
        setState(() {
          _libraryFolders
            ..clear()
            ..addAll(folders.map((folder) => Map<String, String>.from(folder)));
        });
      }
      _showMessage('در حال اسکن پوشه‌ها...');
      final found = await _folderService.scanFolders(
        folders.map((folder) => folder['uri']!).toList(),
      );
      final existing = _tracks.map((track) => track.path).toSet();
      final added = <AudioTrack>[];
      var duplicates = 0;
      for (final item in found) {
        final uri = item['uri']!;
        if (!existing.add(uri)) {
          duplicates++;
          continue;
        }
        final name = item['name']!;
        final dotIndex = name.lastIndexOf('.');
        final title = dotIndex > 0 ? name.substring(0, dotIndex) : name;
        added.add(AudioTrack(path: uri, title: title));
      }
      if (added.isNotEmpty) {
        setState(() => _tracks.addAll(added));
        await _persistTracks();
        await _replacePlaylist(autoplay: false);
      }
      _showMessage(
        'اسکن تمام شد: ${added.length} فایل جدید، '
        '$duplicates فایل تکراری از ${found.length} فایل شناسایی‌شده.',
      );
    } catch (error) {
      _showMessage('اسکن پوشه‌ها ناموفق بود: $error');
    }
  }

  Future<void> _applyEffectiveVolume({Duration? position}) async {
    final positionMs = (position ?? _player.position).inMilliseconds;
    final trackPath = _currentTrack?.path;
    final ranges = trackPath == null
        ? const <VolumeRange>[]
        : (_volumeRangesByTrack[base64Url.encode(utf8.encode(trackPath))] ??
            const <VolumeRange>[]);
    final effective = scheduledVolumeAt(ranges, positionMs, _volume);
    if (_lastAppliedVolume != null &&
        (effective - _lastAppliedVolume!).abs() < 0.0001) {
      return;
    }
    _lastAppliedVolume = effective;
    await _player.setVolume(effective);
  }

  Future<void> _setPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _volume = normalized);
    _lastAppliedVolume = null;
    await _applyEffectiveVolume();
    await _store.saveVolume(normalized);
  }

  Future<void> _openVolumeAutomation() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را انتخاب کن.');
      return;
    }
    final trackKey = base64Url.encode(utf8.encode(track.path));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VolumeAutomationScreen(
          initialRanges: List<VolumeRange>.from(
            _volumeRangesByTrack[trackKey] ?? const <VolumeRange>[],
          ),
          onSave: (ranges) async {
            final preferences = await SharedPreferences.getInstance();
            final key = 'volume_ranges_v1_$trackKey';
            await preferences.setString(
              key,
              jsonEncode(ranges.map((range) => range.toMap()).toList()),
            );
            if (!mounted) return;
            setState(() {
              _volumeRangesByTrack[trackKey] = List<VolumeRange>.from(ranges)
                ..sort((a, b) => a.startMs.compareTo(b.startMs));
              _lastAppliedVolume = null;
            });
            await _applyEffectiveVolume();
          },
        ),
      ),
    );
  }

  Future<void> _showVolumeSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('صدای خروجی پلیر')),
                  Text('${(_volume * 100).round()}%'),
                ],
              ),
              Slider(
                value: _volume,
                min: 0,
                max: 1,
                divisions: 100,
                label: '${(_volume * 100).round()}%',
                onChanged: (value) {
                  setSheetState(() {});
                  _setPlayerVolume(value);
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => _setPlayerVolume(0),
                    child: const Text('بی‌صدا'),
                  ),
                  TextButton(
                    onPressed: () => _setPlayerVolume(1),
                    child: const Text('صدای کامل'),
                  ),
                ],
              ),
              Text(
                'این تنظیم فقط بلندی صدای همین پلیر را تغییر می‌دهد و صدای کلی گوشی را تنظیم نمی‌کند.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _replacePlaylist({required bool autoplay}) async {
    if (_tracks.isEmpty) {
      await _player.stop();
      return;
    }
    final oldIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _tracks.length - 1).toInt();
    final sources = _tracks.map((track) {
      final uri = Uri.parse(track.path);
      return AudioSource.uri(
        uri.scheme == 'content' ? uri : Uri.file(track.path),
      );
    }).toList();
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

  Future<void> _confirmRemoveTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف از کتابخانه'),
        content: Text('«${track.title}» فقط از کتابخانهٔ برنامه حذف می‌شود و فایل اصلی در حافظه باقی می‌ماند. ادامه می‌دهی؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف از کتابخانه'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _removeTrack(index);
  }

  Future<void> _renameTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final controller = TextEditingController(text: track.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ویرایش نام فایل'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(labelText: 'نام جدید'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty || newTitle == track.title) return;
    if (_tracks.any((item) => item.path != track.path && item.title == newTitle)) {
      _showMessage('فایلی با این نام در کتابخانه وجود دارد.');
      return;
    }
    try {
      final renamed = await _folderService.renameItem(track.path, newTitle);
      final newPath = renamed['path'];
      if (newPath == null || newPath.isEmpty) {
        throw StateError('مسیر جدید فایل از سیستم دریافت نشد.');
      }
      final oldPath = track.path;
      final oldIndex = _tracks.indexWhere((item) => item.path == oldPath);
      if (oldIndex < 0) return;
      _tracks[oldIndex] = AudioTrack(path: newPath, title: newTitle);
      for (var i = 0; i < _bookmarks.length; i++) {
        final bookmark = _bookmarks[i];
        if (bookmark.audioPath != oldPath) continue;
        _bookmarks[i] = AudioBookmark(
          id: bookmark.id,
          audioPath: newPath,
          audioTitle: newTitle,
          positionMs: bookmark.positionMs,
          createdAt: bookmark.createdAt,
          title: bookmark.title,
          topic: bookmark.topic,
          endPositionMs: bookmark.endPositionMs,
          isTopicRange: bookmark.isTopicRange,
        );
      }
      for (var i = 0; i < _playlists.length; i++) {
        final playlist = _playlists[i];
        _playlists[i] = playlist.copyWith(
          trackPaths: playlist.trackPaths
              .map((path) => path == oldPath ? newPath : path)
              .toList(),
        );
      }
      final savedLyrics = _lyrics.remove(oldPath);
      if (savedLyrics != null) _lyrics[newPath] = savedLyrics;
      if (_pendingTopicAudioPath == oldPath) _pendingTopicAudioPath = newPath;
      await _persistTracks();
      await _store.saveBookmarks(_bookmarks);
      await _store.savePlaylists(_playlists);
      await _store.saveLyrics(_lyrics);
      await _replacePlaylist(autoplay: false);
      if (mounted) setState(() {});
      _showMessage('نام فایل در حافظه و کتابخانه تغییر کرد.');
    } catch (error) {
      _showMessage('تغییر نام فایل ناموفق بود: $error');
    }
  }

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _bookmarks.removeWhere((bookmark) => bookmark.audioPath == removed.path);
    if (_pendingTopicAudioPath == removed.path) {
      _pendingTopicStartMs = null;
      _pendingTopicAudioPath = null;
    }
    for (var i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      _playlists[i] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((path) => path != removed.path).toList(),
      );
    }
    await _store.savePlaylists(_playlists);
    await _store.saveBookmarks(_bookmarks);
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

  Future<void> _addBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }

    final position = _player.position;
    final details = await _showBookmarkDetailsDialog(
      initialTitle: track.title,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: position.inMilliseconds,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
      });
      _showMessage(
        'نشانک معمولی در ${_formatDuration(position)} ذخیره شد. این نشانک وارد پخش هوشمند نمی‌شود.',
      );
    } catch (error) {
      _showMessage('ذخیره نشانک ناموفق بود: $error');
    }
  }

  Future<void> _toggleTopicRangeBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای ثبت موضوع انتخاب کن.');
      return;
    }

    final startMs = _pendingTopicStartMs;
    if (startMs == null) {
      final positionMs = _player.position.inMilliseconds;
      setState(() {
        _pendingTopicStartMs = positionMs;
        _pendingTopicAudioPath = track.path;
      });
      _showMessage('شروع موضوع در ${_formatDuration(Duration(milliseconds: positionMs))} ثبت شد؛ برای ثبت پایان، دوباره همین دکمه را بزن.');
      return;
    }

    if (_pendingTopicAudioPath != track.path) {
      _showMessage('برای ثبت پایان، ابتدا به همان فایل صوتی که شروع موضوع را در آن ثبت کردی برگرد.');
      return;
    }

    final endMs = _player.position.inMilliseconds;
    if (endMs <= startMs) {
      _showMessage('زمان پایان باید بعد از زمان شروع باشد. نشانگر شروع حفظ شد؛ کمی جلوتر برو و دوباره بزن.');
      return;
    }

    final details = await _showBookmarkDetailsDialog(initialTitle: track.title);
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای نشانک موضوعی، نام موضوع را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: startMs,
      endPositionMs: endMs,
      isTopicRange: true,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
        _selectedSmartTopic ??= bookmark.topic;
        _pendingTopicStartMs = null;
        _pendingTopicAudioPath = null;
      });
      await _saveSmartSettings();
      _showMessage('بازه موضوع «${bookmark.topic}» از ${_formatDuration(Duration(milliseconds: startMs))} تا ${_formatDuration(Duration(milliseconds: endMs))} ذخیره شد.');
    } catch (error) {
      _showMessage('ذخیره بازه موضوع ناموفق بود: $error');
    }
  }

  List<String> get _availableSmartTopics {
    final topics = _bookmarks
        .where((bookmark) => bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs)
        .map((bookmark) => bookmark.topic.trim())
        .where((topic) => topic.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return topics;
  }

  Future<Map<String, String>?> _showBookmarkDetailsDialog({
    required String initialTitle,
    String initialTopic = '',
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final topicController = TextEditingController(text: initialTopic);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مشخصات نشانک'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'عنوان نشانک'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              textDirection: TextDirection.rtl,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'موضوع',
                hintText: 'مثلاً تمرکز',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'title': titleController.text.trim(),
              'topic': topicController.text.trim(),
            }),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    titleController.dispose();
    topicController.dispose();
    return result;
  }

  Future<void> _editBookmark(AudioBookmark bookmark) async {
    final details = await _showBookmarkDetailsDialog(
      initialTitle: bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
      initialTopic: bookmark.topic,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }
    final updated = _bookmarks
        .map((item) => item.id == bookmark.id
            ? AudioBookmark(
                id: item.id,
                audioPath: item.audioPath,
                audioTitle: item.audioTitle,
                positionMs: item.positionMs,
                endPositionMs: item.endPositionMs,
                isTopicRange: item.isTopicRange,
                createdAt: item.createdAt,
                title: details['title']!,
                topic: details['topic']!,
              )
            : item)
        .toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('ویرایش نشانک ذخیره نشد: $error');
    }
  }

  Future<void> _deleteBookmark(AudioBookmark bookmark) async {
    final updated = _bookmarks.where((item) => item.id != bookmark.id).toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('حذف نشانک ناموفق بود: $error');
    }
  }

  Future<void> _saveSmartSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('smart_topic_mode_v1', _smartTopicMode);
      await preferences.setString('smart_order_mode_v1', _smartOrderMode);
      if (_selectedSmartTopic == null) {
        await preferences.remove('smart_selected_topic_v1');
      } else {
        await preferences.setString('smart_selected_topic_v1', _selectedSmartTopic!);
      }
    } catch (error) {
      _showMessage('ذخیره تنظیمات پخش هوشمند ناموفق بود: $error');
    }
  }

  Future<void> _startSmartPlayback() async {
    final topics = _availableSmartTopics;
    if (topics.isEmpty) {
      _showMessage('ابتدا در تب نشانک‌ها برای نشانک‌ها موضوع تعیین کن.');
      _tabController.animateTo(1);
      return;
    }

    String topic;
    if (_smartTopicMode == 'random') {
      topic = topics[Random().nextInt(topics.length)];
    } else {
      final selected = _selectedSmartTopic;
      if (selected == null || !topics.contains(selected)) {
        _showMessage('ابتدا یک موضوع برای پخش هوشمند انتخاب کن.');
        _tabController.animateTo(4);
        return;
      }
      topic = selected;
    }

    final matching = _bookmarks
        .where((bookmark) =>
            bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs &&
            bookmark.topic.trim() == topic &&
            _tracks.any((track) => track.path == bookmark.audioPath))
        .toList();
    if (matching.isEmpty) {
      _showMessage('برای این موضوع نشانک قابل پخشی پیدا نشد.');
      return;
    }

    if (_smartOrderMode == 'random') {
      matching.shuffle(Random());
    } else {
      matching.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final sources = <AudioSource>[];
    for (final bookmark in matching) {
      final parsed = Uri.parse(bookmark.audioPath);
      final uri = parsed.scheme == 'content'
          ? parsed
          : Uri.file(bookmark.audioPath);
      sources.add(
        ClippingAudioSource(
          child: AudioSource.uri(uri),
          start: Duration(milliseconds: bookmark.positionMs),
          end: Duration(milliseconds: bookmark.endPositionMs!),
        ),
      );
    }

    try {
      await _player.pause();
      await _smartPlayer.stop();
      await _smartPlayer.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      if (!mounted) return;
      setState(() {
        _activeSmartTopic = topic;
        _smartQueueBookmarks
          ..clear()
          ..addAll(matching);
        _smartQueueReady = true;
      });
      await _smartPlayer.play();
    } catch (error) {
      if (mounted) {
        setState(() {
          _smartQueueReady = false;
          _smartQueueBookmarks.clear();
        });
        _showMessage('شروع پخش هوشمند ناموفق بود: $error');
      }
    }
  }

  Future<void> _setSmartPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _smartVolume = normalized);
    await _smartPlayer.setVolume(normalized);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('smart_topic_volume_v1', normalized);
  }

  Future<void> _toggleSmartPlayback() async {
    if (_smartPlayer.playing) {
      await _smartPlayer.pause();
      return;
    }
    if (_smartQueueReady &&
        _smartPlayer.processingState != ProcessingState.completed) {
      await _smartPlayer.play();
      return;
    }
    await _startSmartPlayback();
  }

  Future<void> _stopSmartPlayback() async {
    await _smartPlayer.stop();
    if (mounted) {
      setState(() {
        _smartQueueReady = false;
        _activeSmartTopic = null;
        _smartQueueBookmarks.clear();
      });
    }
  }

  Future<void> _playBookmark(AudioBookmark bookmark) async {
    final trackIndex =
        _tracks.indexWhere((track) => track.path == bookmark.audioPath);
    if (trackIndex < 0) {
      _showMessage('فایل صوتی این نشانک در کتابخانه موجود نیست.');
      return;
    }

    try {
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      final position = Duration(milliseconds: bookmark.positionMs);
      await _player.seek(position, index: trackIndex);
      await _player.play();
    } catch (error) {
      _showMessage('پخش از نشانک ممکن نشد: $error');
    }
  }

  Widget _buildBookmarksTab(ColorScheme colors) {
    final track = _currentTrack;
    final trackBookmarks = track == null
        ? const <AudioBookmark>[]
        : _bookmarks
            .where((bookmark) => bookmark.audioPath == track.path)
            .toList();

    if (track == null) {
      return const Center(
        child: Text(
          'برای مشاهده نشانک‌ها، ابتدا یک فایل صوتی انتخاب کن.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (trackBookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'برای «${track.title}» هنوز نشانکی ثبت نشده است. هنگام پخش این فایل، دکمه نشانک را لمس کن.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      key: ValueKey('bookmarks-${track.path}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: trackBookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final bookmark = trackBookmarks[index];
        final createdAt = bookmark.createdAt;
        final dateLabel =
            '${createdAt.year}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.day.toString().padLeft(2, '0')}  '
            '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(
              bookmark.isTopicRange
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_rounded,
              color: colors.primary,
            ),
            title: Text(
              bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '${bookmark.isTopicRange ? 'موضوع' : 'نشانک معمولی'}  •  ${bookmark.topic.isEmpty ? 'بدون موضوع' : bookmark.topic}  •  ${_formatDuration(Duration(milliseconds: bookmark.positionMs))}${bookmark.isTopicRange && bookmark.endPositionMs != null ? ' تا ${_formatDuration(Duration(milliseconds: bookmark.endPositionMs!))}' : ''}  •  $dateLabel',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'مدیریت نشانک',
              onSelected: (value) {
                if (value == 'edit') _editBookmark(bookmark);
                if (value == 'delete') _deleteBookmark(bookmark);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('ویرایش عنوان و موضوع')),
                PopupMenuItem(value: 'delete', child: Text('حذف نشانک')),
              ],
            ),
            onTap: () => _playBookmark(bookmark),
          ),
        );
      },
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ساخت پلی‌لیست جدید'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(
            labelText: 'نام پلی‌لیست',
            hintText: 'مثلاً موسیقی آرامش‌بخش',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ساختن'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final playlist = AudioPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      trackPaths: const [],
    );
    setState(() {
      _playlists.add(playlist);
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
  }

  Future<void> _addCurrentTrackToPlaylist(AudioPlaylist playlist) async {
    final track = _currentTrack;
    if (track == null) return;
    if (playlist.trackPaths.contains(track.path)) {
      _showMessage('این فایل از قبل در پلی‌لیست «${playlist.name}» وجود دارد.');
      return;
    }
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: [...playlist.trackPaths, track.path],
      );
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
    _showMessage('«${track.title}» به پلی‌لیست «${playlist.name}» اضافه شد.');
  }

  Future<void> _removeFromPlaylist(AudioPlaylist playlist, String path) async {
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((item) => item != path).toList(),
      );
    });
    await _store.savePlaylists(_playlists);
  }

  bool get _currentTrackIsFavorite {
    final track = _currentTrack;
    if (track == null) return false;
    final index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    return index >= 0 && _playlists[index].trackPaths.contains(track.path);
  }

  Future<void> _toggleCurrentTrackFavorite() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }
    var index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    if (index < 0) {
      _playlists.add(const AudioPlaylist(
        id: _favoritesPlaylistId,
        name: _favoritesPlaylistName,
        trackPaths: [],
      ));
      index = _playlists.length - 1;
    }
    final favorites = _playlists[index];
    final isFavorite = favorites.trackPaths.contains(track.path);
    setState(() {
      _playlists[index] = favorites.copyWith(
        trackPaths: isFavorite
            ? favorites.trackPaths.where((path) => path != track.path).toList()
            : [...favorites.trackPaths, track.path],
      );
      _expandedPlaylistId = _favoritesPlaylistId;
    });
    await _store.savePlaylists(_playlists);
    _showMessage(isFavorite
        ? '«${track.title}» از علاقه‌مندی‌ها حذف شد.'
        : '«${track.title}» به علاقه‌مندی‌ها اضافه شد.');
  }

  Future<void> _deletePlaylist(AudioPlaylist playlist) async {
    if (playlist.id == _favoritesPlaylistId) {
      _showMessage('پلی‌لیست علاقه‌مندی‌ها قابل حذف نیست.');
      return;
    }
    setState(() => _playlists.removeWhere((item) => item.id == playlist.id));
    await _store.savePlaylists(_playlists);
  }

  Widget _buildPlaylistsTab(ColorScheme colors) {
    final current = _currentTrack;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: IconButton.filled(
              tooltip: 'پلی‌لیست جدید',
              onPressed: _createPlaylist,
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? const SizedBox.shrink()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    final expanded = _expandedPlaylistId == playlist.id;
                    final tracks = playlist.trackPaths
                        .map((path) => _tracks.where((track) => track.path == path))
                        .where((matches) => matches.isNotEmpty)
                        .map((matches) => matches.first)
                        .toList();
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: PageStorageKey(playlist.id),
                        initiallyExpanded: expanded,
                        onExpansionChanged: (value) => setState(() {
                          _expandedPlaylistId = value ? playlist.id : null;
                        }),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        children: [
                          if (current != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _addCurrentTrackToPlaylist(playlist),
                                  child: const Text('افزودن آهنگ در حال پخش'),
                                ),
                              ),
                            ),
                          if (playlist.id != _favoritesPlaylistId)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _deletePlaylist(playlist),
                                  child: const Text('حذف پلی‌لیست'),
                                ),
                              ),
                            ),
                          if (tracks.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('این پلی‌لیست هنوز خالی است.'),
                            )
                          else
                            ...tracks.map((track) => ListTile(
                                  dense: true,
                                  title: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final trackIndex = _tracks.indexOf(track);
                                    if (trackIndex >= 0) _playTrack(trackIndex);
                                  },
                                  trailing: TextButton(
                                    onPressed: () => _removeFromPlaylist(
                                      playlist,
                                      track.path,
                                    ),
                                    child: const Text('حذف'),
                                  ),
                                )),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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

  Future<DateTime?> _chooseScheduleDateTime(String title) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: title,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      helpText: 'ساعت اجرا',
    );
    if (time == null) return null;
    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!scheduled.isAfter(DateTime.now())) {
      _showMessage('زمان انتخاب‌شده باید در آینده باشد.');
      return null;
    }
    return scheduled;
  }

  Future<void> _scheduleStartDialog() async {
    if (_tracks.isEmpty) {
      _showMessage('ابتدا یک فایل صوتی به کتابخانه اضافه کن.');
      return;
    }
    String selectedPath = _currentTrack?.path ?? _tracks.first.path;
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('شروع خودکار پخش'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedPath,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'فایل صوتی'),
            items: _tracks.map((track) => DropdownMenuItem<String>(
              value: track.path,
              child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selectedPath = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selectedPath),
              child: const Text('انتخاب زمان'),
            ),
          ],
        ),
      ),
    );
    if (path == null || !mounted) return;
    final at = await _chooseScheduleDateTime('تاریخ شروع پخش');
    if (at == null) return;
    final track = _tracks.firstWhere((item) => item.path == path);
    try {
      await ScheduledPlaybackService.scheduleStart(path: track.path, title: track.title, at: at);
      _showMessage('شروع پخش «${track.title}» برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم شروع خودکار ناموفق بود: $error');
    }
  }

  Future<void> _scheduleStopDialog() async {
    final at = await _chooseScheduleDateTime('تاریخ توقف پخش');
    if (at == null) return;
    try {
      await ScheduledPlaybackService.scheduleStop(at: at);
      _showMessage('توقف پخش برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم توقف خودکار ناموفق بود: $error');
    }
  }

  String _formatScheduleDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.year % 100)}/${two(value.month)}/${two(value.day)} - ${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _cancelScheduledStart() async {
    try {
      await ScheduledPlaybackService.cancelStart();
      _showMessage('شروع خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان شروع ناموفق بود: $error');
    }
  }

  Future<void> _cancelScheduledStop() async {
    try {
      await ScheduledPlaybackService.cancelStop();
      _showMessage('توقف خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان توقف ناموفق بود: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _messageTimer?.cancel();
    final generation = ++_messageGeneration;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          leading: const Icon(Icons.info_outline_rounded),
          content: Dismissible(
            key: ValueKey('app-message-$generation'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _messageTimer?.cancel();
              messenger.hideCurrentMaterialBanner();
            },
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(message),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'بستن پیام',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _messageTimer?.cancel();
                messenger.hideCurrentMaterialBanner();
              },
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || generation != _messageGeneration) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  @override
  void dispose() {
    _lyricsHoldTimer?.cancel();
    _themeHoldTimer?.cancel();
    _messageTimer?.cancel();
    _smartTopicMarqueeController.dispose();
    _tabController.dispose();
    _player.dispose();
    unawaited(_smartPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
        body: Column(
          children: [
            _buildPlayerToolbar(colors),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLyricsTab(colors),
                  _buildBookmarksTab(colors),
                  _buildPlaylistsTab(colors),
                  _buildLibraryTab(colors),
                  _buildSmartTab(colors),
                ],
              ),
            ),
            _buildBottomNavigation(colors),
            _buildPlayerPanel(colors),
          ],
        ),
      );
  }

  Widget _buildBottomNavigation(ColorScheme colors) {
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: false,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                labelPadding: EdgeInsets.zero,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.notes_rounded, size: 26)),
                    ),
                    text: 'متن',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.bookmarks_outlined, size: 26)),
                    ),
                    text: 'نشانک',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.queue_music_rounded, size: 26)),
                    ),
                    text: 'پلی‌لیست',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.library_music_outlined, size: 26)),
                    ),
                    text: 'کتابخانه',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.psychology_rounded, size: 26)),
                    ),
                    text: 'بخش هوشمند',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartTab(ColorScheme colors) {
    final topics = _availableSmartTopics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartTopicMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'انتخاب موضوع',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'manual',
                    child: Text('انتخاب موضوع توسط من', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('انتخاب موضوع تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartTopicMode = value);
                  await _saveSmartSettings();
                  if (value == 'manual' && topics.isNotEmpty && mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('انتخاب موضوع'),
                        content: SizedBox(
                          width: 320,
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final topic in topics)
                                ListTile(
                                  title: Text(topic),
                                  trailing: _selectedSmartTopic == topic
                                      ? const Icon(Icons.check_rounded)
                                      : null,
                                  onTap: () async {
                                    setState(() => _selectedSmartTopic = topic);
                                    await _saveSmartSettings();
                                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartOrderMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'ترتیب پخش نشانک‌ها',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'sequential',
                    child: Text('به ترتیب ثبت', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('به‌صورت تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartOrderMode = value);
                  await _saveSmartSettings();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          textDirection: TextDirection.rtl,
          children: [
            const Text(
              'موضوع در حال پخش:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final topicText = _activeSmartTopic ?? '—';
                  final textPainter = TextPainter(
                    text: TextSpan(
                      text: topicText,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                  )..layout();
                  final textWidth = textPainter.width;
                  final viewportWidth = constraints.maxWidth;
                  if (textWidth <= viewportWidth) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        topicText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  return ClipRect(
                    child: SizedBox(
                      height: 22,
                      child: AnimatedBuilder(
                        animation: _smartTopicMarqueeController,
                        builder: (context, child) {
                          final travel = viewportWidth + textWidth;
                          final offset = viewportWidth -
                              (_smartTopicMarqueeController.value * travel);
                          return Transform.translate(
                            offset: Offset(offset, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: textWidth,
                          child: Text(
                            topicText,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: topics.isEmpty ? null : _toggleSmartPlayback,
                icon: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                label: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Text(
                    snapshot.data == true ? 'مکث' : 'شروع پخش هوشمند',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'توقف پخش هوشمند',
              onPressed: _stopSmartPlayback,
              icon: const Icon(Icons.stop_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'تنظیم صدای پلیر موضوعی',
              onPressed: () => setState(
                () => _showSmartVolumeSlider = !_showSmartVolumeSlider,
              ),
              icon: Icon(
                _smartVolume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
        if (_showSmartVolumeSlider)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 8, top: 2),
            child: Row(
              children: [
                const Icon(Icons.volume_down_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: _smartVolume,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    label: '${(_smartVolume * 100).round()}٪',
                    onChanged: (value) {
                      setState(() => _smartVolume = value);
                      unawaited(_smartPlayer.setVolume(value));
                    },
                    onChangeEnd: (value) async {
                      await _setSmartPlayerVolume(value);
                      if (mounted) setState(() => _showSmartVolumeSlider = false);
                    },
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(_smartVolume * 100).round()}٪',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_smartQueueBookmarks.isNotEmpty)
          StreamBuilder<int?>(
            stream: _smartPlayer.currentIndexStream,
            initialData: _smartPlayer.currentIndex,
            builder: (context, snapshot) {
              final activeIndex = snapshot.data ?? -1;
              return Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  itemCount: _smartQueueBookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _smartQueueBookmarks[index];
                    final isActive = index == activeIndex;
                    final endMs = bookmark.endPositionMs ?? bookmark.positionMs;
                    final duration = Duration(
                      milliseconds: (endMs - bookmark.positionMs).clamp(0, 1 << 31).toInt(),
                    );
                    return Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: isActive
                          ? colors.primary.withValues(alpha: 0.10)
                          : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text(
                              _formatDuration(duration),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isActive ? colors.primary : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            isActive ? Icons.graphic_eq_rounded : Icons.bookmark_outline_rounded,
                            size: 17,
                            color: isActive ? colors.primary : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  bookmark.audioTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  bookmark.topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? colors.primary : colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isActive)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 6),
                              child: Text(
                                'در حال پخش',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          )
        else if (topics.isEmpty)
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded, size: 20),
            title: Text('هنوز موضوعی ثبت نشده است.', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              'در نوار پخش، با دکمه نشانک موضوعی ابتدا و انتهای هر موضوع را ثبت کن.',
              style: TextStyle(fontSize: 11),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'برای نمایش فهرست، پخش یک موضوع را شروع کن.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 12),
        StreamBuilder<Duration>(
          stream: _smartPlayer.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            return StreamBuilder<Duration?>(
              stream: _smartPlayer.durationStream,
              builder: (context, durationSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = durationSnapshot.data ?? Duration.zero;
                final max = duration.inMilliseconds.toDouble();
                return Column(
                  children: [
                    LinearProgressIndicator(
                      value: max <= 0
                          ? 0
                          : (position.inMilliseconds / max).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position)),
                        Text(_formatDuration(duration)),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  void _onThemeButtonDown(PointerDownEvent event) {
    _themeLongPressTriggered = false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _themeLongPressTriggered = true;
      _showPresetThemePicker();
    });
  }

  void _onThemeButtonUp(PointerUpEvent event) {
    final wasLongPress = _themeLongPressTriggered;
    final wasShortPress = _themeHoldTimer?.isActive ?? false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
    if (!wasLongPress && wasShortPress) widget.onToggleTheme();
  }

  void _onThemeButtonCancel(PointerCancelEvent event) {
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
  }

  Future<void> _showPresetThemePicker() async {
    const themes = <({String id, String name, Color color, String description})>[
      (id: 'teal', name: 'فیروزه‌ای', color: Color(0xFF16A6A0), description: 'تم پیش‌فرض فعلی'),
      (id: 'blue', name: 'آبی اقیانوسی', color: Color(0xFF2878D0), description: 'آرام و خنک'),
      (id: 'purple', name: 'بنفش', color: Color(0xFF8764D8), description: 'بنفش مدرن'),
      (id: 'green', name: 'سبز جنگلی', color: Color(0xFF39865A), description: 'طبیعی و ملایم'),
      (id: 'amber', name: 'کهربایی', color: Color(0xFFD28A22), description: 'گرم و پرانرژی'),
      (id: 'rose', name: 'رز', color: Color(0xFFC65D78), description: 'صورتی متمایل به رز'),
      (id: 'slate', name: 'خاکستری', color: Color(0xFF718096), description: 'خنثی و مینیمال'),
    ];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('انتخاب تم برنامه'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'حالت فعلی: ${widget.isDark ? 'شب' : 'روز'}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ),
              for (final theme in themes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: theme.color,
                  ),
                  title: Text(theme.name),
                  subtitle: Text(theme.description),
                  trailing: widget.themeId == theme.id
                      ? const Icon(Icons.check_circle_rounded)
                      : null,
                  onTap: () {
                    widget.onSelectTheme(theme.id);
                    Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerToolbar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              PopupMenuButton<String>(
                tooltip: 'پشتیبان‌گیری و بازیابی',
                icon: const Icon(Icons.backup_outlined, size: 24),
                onSelected: (value) {
                  if (value == 'backup') _createBackup();
                  if (value == 'restore') _restoreBackup();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'backup',
                    child: Row(
                      children: [
                        Icon(Icons.save_alt_rounded),
                        SizedBox(width: 12),
                        Text('تهیه نسخه پشتیبان'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.settings_backup_restore_rounded),
                        SizedBox(width: 12),
                        Text('بازیابی نسخه پشتیبان'),
                      ],
                    ),
                  ),
                ],
              ),
              Tooltip(
                message: 'لمس کوتاه: تغییر شب و روز • نگه‌داشتن ۳ ثانیه: انتخاب تم',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onThemeButtonDown,
                  onPointerUp: _onThemeButtonUp,
                  onPointerCancel: _onThemeButtonCancel,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        widget.isDark ? Icons.light_mode : Icons.dark_mode,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'شروع و پایان خودکار',
                icon: const Icon(Icons.schedule_rounded, size: 24),
                onSelected: (value) {
                  if (value == 'start') _scheduleStartDialog();
                  if (value == 'stop') _scheduleStopDialog();
                  if (value == 'cancel_start') _cancelScheduledStart();
                  if (value == 'cancel_stop') _cancelScheduledStop();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'start', child: Text('تنظیم شروع خودکار')),
                  PopupMenuItem(value: 'stop', child: Text('تنظیم توقف خودکار')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'cancel_start', child: Text('لغو شروع خودکار')),
                  PopupMenuItem(value: 'cancel_stop', child: Text('لغو توقف خودکار')),
                ],
              ),
              IconButton(
                tooltip: 'نقشه تغییرات صدا',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                onPressed: _openVolumeAutomation,
                icon: const Icon(Icons.multiline_chart_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    final hasLibraryItems = _libraryFolders.isNotEmpty || _tracks.isNotEmpty;
    final actions = Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'انتخاب فایل صوتی',
          onPressed: _pickAudio,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.audio_file_rounded, size: 20),
        ),
        const SizedBox(width: 3),
        IconButton.filledTonal(
          tooltip: 'انتخاب پوشه',
          onPressed: _openFolderManager,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.create_new_folder_outlined, size: 20),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final folder in _libraryFolders)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_rounded, size: 18, color: colors.primary),
                        const SizedBox(width: 4),
                        Text(
                          folder['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (!hasLibraryItems) {
      return Center(child: actions);
    }

    final itemCount = _tracks.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: actions,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: itemCount,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            itemBuilder: (context, index) {
              final trackIndex = index;
              final track = _tracks[trackIndex];
              final isCurrent = _currentIndex == trackIndex;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                minVerticalPadding: 0,
                minTileHeight: 30,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                tileColor: isCurrent
                    ? colors.primary.withValues(alpha: 0.10)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: _MarqueeText(
                  text: track.title,
                  style: const TextStyle(fontSize: 14),
                  gap: 28,
                ),
                onTap: () => _playTrack(trackIndex),
                trailing: PopupMenuButton<String>(
                  tooltip: 'گزینه‌های فایل صوتی',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  iconSize: 17,
                  onSelected: (action) {
                    if (action == 'rename') {
                      _renameTrack(trackIndex);
                    } else if (action == 'delete') {
                      _confirmRemoveTrack(trackIndex);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'rename',
                      height: 40,
                      child: Text('ویرایش نام'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      height: 40,
                      child: Text('حذف از کتابخانه'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onLyricsPointerDown(PointerDownEvent event) {
    _lyricsHoldTimer?.cancel();
    _lyricsHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _lyricsEditing = true);
    });
  }

  void _onLyricsPointerEnd(PointerEvent event) {
    _lyricsHoldTimer?.cancel();
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
              Icon(Icons.edit_note, size: 44, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'متن صدا ...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    if (_lyricsEditing) {
      return _LyricsEditor(
        key: ValueKey('edit-${track.path}'),
        track: track,
        initialText: _lyrics[track.path] ?? '',
        onSave: (value) => _saveLyrics(track.path, value),
        onSaveComplete: () {
          if (mounted) setState(() => _lyricsEditing = false);
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Expanded(
            child: Listener(
              onPointerDown: _onLyricsPointerDown,
              onPointerUp: _onLyricsPointerEnd,
              onPointerCancel: _onLyricsPointerEnd,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    (_lyrics[track.path] ?? '').trim().isEmpty
                        ? 'متن صدا ...'
                        : _lyrics[track.path]!,
                    textDirection: TextDirection.rtl,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await _store.saveLyrics(_lyrics);
                  _showMessage('متن ویس ذخیره شد.');
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded, color: colors.primary, size: 21),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _MarqueeText(
                            text: track?.title ?? 'فایلی برای پخش انتخاب نشده',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'در حال پخش',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'ثبت نشانک در زمان فعلی',
                        onPressed: track == null ? null : _addBookmark,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: _pendingTopicStartMs == null
                            ? 'ثبت شروع موضوع'
                            : 'ثبت پایان موضوع (${_formatDuration(Duration(milliseconds: _pendingTopicStartMs!))})',
                        onPressed: track == null ? null : _toggleTopicRangeBookmark,
                        color: _pendingTopicStartMs == null ? null : colors.primary,
                        icon: Icon(
                          _pendingTopicStartMs == null
                              ? Icons.bookmark_add_rounded
                              : Icons.bookmark_added_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: _currentTrack == null
                            ? 'علاقه‌مندی‌ها (ابتدا یک فایل پخش کن)'
                            : _currentTrackIsFavorite
                                ? 'حذف از علاقه‌مندی‌ها'
                                : 'افزودن به علاقه‌مندی‌ها',
                        onPressed: _toggleCurrentTrackFavorite,
                        icon: Icon(
                          _currentTrackIsFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: _currentTrackIsFavorite
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: 'شروع پخش هوشمند',
                        onPressed: _toggleSmartPlayback,
                        icon: const Icon(Icons.auto_awesome_rounded),
                      ),
                      IconButton(
                        tooltip: 'تنظیم صدای پلیر',
                        onPressed: _showVolumeSettings,
                        icon: Icon(
                          _volume == 0
                              ? Icons.volume_off_rounded
                              : _volume < 0.5
                                  ? Icons.volume_down_rounded
                                  : Icons.volume_up_rounded,
                          color: colors.primary,
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
                  final trackRanges = _bookmarks
                      .where((bookmark) =>
                          bookmark.isTopicRange &&
                          bookmark.audioPath == track?.path &&
                          bookmark.endPositionMs != null &&
                          bookmark.endPositionMs! > bookmark.positionMs)
                      .toList();
                  return Column(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final usableWidth =
                              (constraints.maxWidth - 32).clamp(0.0, double.infinity).toDouble();
                          return Stack(
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
                              if (max > 0)
                                ...trackRanges.expand((bookmark) {
                                  final startFraction =
                                      (bookmark.positionMs / max).clamp(0.0, 1.0).toDouble();
                                  final endFraction =
                                      (bookmark.endPositionMs! / max).clamp(0.0, 1.0).toDouble();
                                  return <Widget>[
                                    PositionedDirectional(
                                      start: 16 + usableWidth * startFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.tertiary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                    PositionedDirectional(
                                      start: 16 + usableWidth * endFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                  ];
                                }),
                            ],
                          );
                        },
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
                    icon: const Icon(Icons.shuffle, size: 27),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه عقب',
                    onPressed: track == null ? null : () => _seekRelative(-15),
                    icon: const Icon(Icons.replay_10, size: 27),
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
                    icon: const Icon(Icons.skip_previous_rounded, size: 32),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      final processing = snapshot.data?.processingState;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return SizedBox(
                        width: 60,
                        height: 60,
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
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  size: 34,
                                ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'بعدی',
                    onPressed: track == null ? null : _player.seekToNext,
                    icon: const Icon(Icons.skip_next_rounded, size: 32),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه جلو',
                    onPressed: track == null ? null : () => _seekRelative(15),
                    icon: const Icon(Icons.forward_10, size: 27),
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
                      size: 27,
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
    required this.onSaveComplete,
  });

  final AudioTrack track;
  final String initialText;
  final Future<void> Function(String value) onSave;
  final VoidCallback onSaveComplete;

  @override
  State<_LyricsEditor> createState() => _LyricsEditorState();
}

class _LyricsEditorState extends State<_LyricsEditor> {
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  final FocusNode _lyricsFocusNode = FocusNode();
  Timer? _saveTimer;
  bool _saving = false;
  bool _saved = true;
  bool _hasSearched = false;
  List<int> _matches = [];
  int _activeMatch = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _searchController = TextEditingController();
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
    if (_matches.isNotEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
        _hasSearched = false;
      });
    }
  }

  void _findMatches({bool preservePosition = false}) {
    final query = _searchController.text;
    final text = _controller.text;
    _hasSearched = true;
    if (query.isEmpty || text.isEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
      });
      return;
    }

    final source = text.toLowerCase();
    final needle = query.toLowerCase();
    final found = <int>[];
    var offset = 0;
    while (offset <= source.length - needle.length) {
      final index = source.indexOf(needle, offset);
      if (index < 0) break;
      found.add(index);
      offset = index + needle.length;
    }

    final previousStart = preservePosition && _activeMatch >= 0 &&
            _activeMatch < _matches.length
        ? _matches[_activeMatch]
        : -1;
    var nextActive = found.isEmpty ? -1 : 0;
    if (previousStart >= 0 && found.isNotEmpty) {
      final sameIndex = found.indexOf(previousStart);
      if (sameIndex >= 0) nextActive = sameIndex;
    }
    setState(() {
      _matches = found;
      _activeMatch = nextActive;
    });
    if (found.isNotEmpty) _selectMatch(nextActive);
  }

  void _selectMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final start = _matches[index];
    final end = start + _searchController.text.length;
    _lyricsFocusNode.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    setState(() => _activeMatch = index);
  }

  void _moveMatch(int step) {
    if (_matches.isEmpty) return;
    final next = (_activeMatch + step + _matches.length) % _matches.length;
    _selectMatch(next);
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
    _searchController.dispose();
    _lyricsFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasMatches = _matches.isNotEmpty;
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textDirection: TextDirection.rtl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _findMatches(),
                  onChanged: (_) {
                    setState(() {
                      _matches = [];
                      _activeMatch = -1;
                      _hasSearched = false;
                    });
                  },
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'جست‌وجو در متن همین ویس...',
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    suffixIcon: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      tooltip: 'جست‌وجو',
                      onPressed: _findMatches,
                      icon: const Icon(Icons.search_rounded, size: 17),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه قبلی',
                onPressed: hasMatches ? () => _moveMatch(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ),
              const SizedBox(width: 3),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه بعدی',
                onPressed: hasMatches ? () => _moveMatch(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _searchController.text.isEmpty
                  ? 'جست‌وجو فقط در متن فایل انتخاب‌شده انجام می‌شود.'
                  : hasMatches
                      ? 'نتیجه ${_activeMatch + 1} از ${_matches.length}'
                      : _hasSearched
                          ? 'کلمه‌ای با این عبارت پیدا نشد.'
                          : 'برای شروع، دکمه جست‌وجو را بزن.',
              style: TextStyle(
                fontSize: 11,
                color: hasMatches ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _lyricsFocusNode,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textDirection: TextDirection.rtl,
              onChanged: _scheduleSave,
              style: const TextStyle(fontSize: 14),
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
                onPressed: _saving
                    ? null
                    : () async {
                        _saveTimer?.cancel();
                        await _save(_controller.text);
                        if (mounted) widget.onSaveComplete();
                      },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('ذخیره', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    this.gap = 36,
  });

  final String text;
  final TextStyle style;
  final double gap;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller.stop();
      _controller.value = 0;
      _started = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout();
        final textWidth = painter.width;
        final availableWidth = constraints.maxWidth;

        if (textWidth <= availableWidth || availableWidth <= 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: widget.style,
            ),
          );
        }

        final distance = textWidth + widget.gap;
        if (!_started) {
          _started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final milliseconds =
                (distance / 32 * 1000).round().clamp(1800, 20000).toInt();
            _controller.duration = Duration(milliseconds: milliseconds);
            _controller.repeat();
          });
        }

        return ClipRect(
          child: SizedBox(
            height: painter.height,
            width: availableWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(-distance * _controller.value, 0),
                child: child,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                  SizedBox(width: widget.gap),
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
), ''),
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

  Future<void> _openFolderManager() async {
    final folders = await _store.loadFolders();
    if (!mounted) return;
    final selected = folders.map((folder) => Map<String, String>.from(folder)).toList();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('پوشه‌های کتابخانه'),
          content: SizedBox(
            width: double.maxFinite,
            height: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text('هنوز پوشه‌ای انتخاب نشده است.'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: selected.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          selected[index]['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'حذف پوشه',
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(
                            () => selected.removeAt(index),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final folder = await _folderService.pickFolder();
                      if (folder == null) return;
                      if (selected.any((item) => item['uri'] == folder['uri'])) return;
                      setDialogState(() => selected.add(folder));
                    } catch (error) {
                      if (mounted) _showMessage('انتخاب پوشه ناموفق بود: $error');
                    }
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('افزودن پوشه'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final result = selected
                          .map((folder) => Map<String, String>.from(folder))
                          .toList();
                      Navigator.pop(dialogContext);
                      unawaited(_scanSelectedFolders(result));
                    },
              icon: const Icon(Icons.sync),
              label: const Text('شروع اسکن'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanSelectedFolders(List<Map<String, String>> folders) async {
    try {
      await _store.saveFolders(folders);
      if (mounted) {
        setState(() {
          _libraryFolders
            ..clear()
            ..addAll(folders.map((folder) => Map<String, String>.from(folder)));
        });
      }
      _showMessage('در حال اسکن پوشه‌ها...');
      final found = await _folderService.scanFolders(
        folders.map((folder) => folder['uri']!).toList(),
      );
      final existing = _tracks.map((track) => track.path).toSet();
      final added = <AudioTrack>[];
      var duplicates = 0;
      for (final item in found) {
        final uri = item['uri']!;
        if (!existing.add(uri)) {
          duplicates++;
          continue;
        }
        final name = item['name']!;
        final dotIndex = name.lastIndexOf('.');
        final title = dotIndex > 0 ? name.substring(0, dotIndex) : name;
        added.add(AudioTrack(path: uri, title: title));
      }
      if (added.isNotEmpty) {
        setState(() => _tracks.addAll(added));
        await _persistTracks();
        await _replacePlaylist(autoplay: false);
      }
      _showMessage(
        'اسکن تمام شد: ${added.length} فایل جدید، '
        '$duplicates فایل تکراری از ${found.length} فایل شناسایی‌شده.',
      );
    } catch (error) {
      _showMessage('اسکن پوشه‌ها ناموفق بود: $error');
    }
  }

  Future<void> _applyEffectiveVolume({Duration? position}) async {
    final positionMs = (position ?? _player.position).inMilliseconds;
    final trackPath = _currentTrack?.path;
    final ranges = trackPath == null
        ? const <VolumeRange>[]
        : (_volumeRangesByTrack[base64Url.encode(utf8.encode(trackPath))] ??
            const <VolumeRange>[]);
    final effective = scheduledVolumeAt(ranges, positionMs, _volume);
    if (_lastAppliedVolume != null &&
        (effective - _lastAppliedVolume!).abs() < 0.0001) {
      return;
    }
    _lastAppliedVolume = effective;
    await _player.setVolume(effective);
  }

  Future<void> _setPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _volume = normalized);
    _lastAppliedVolume = null;
    await _applyEffectiveVolume();
    await _store.saveVolume(normalized);
  }

  Future<void> _openVolumeAutomation() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را انتخاب کن.');
      return;
    }
    final trackKey = base64Url.encode(utf8.encode(track.path));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VolumeAutomationScreen(
          initialRanges: List<VolumeRange>.from(
            _volumeRangesByTrack[trackKey] ?? const <VolumeRange>[],
          ),
          onSave: (ranges) async {
            final preferences = await SharedPreferences.getInstance();
            final key = 'volume_ranges_v1_$trackKey';
            await preferences.setString(
              key,
              jsonEncode(ranges.map((range) => range.toMap()).toList()),
            );
            if (!mounted) return;
            setState(() {
              _volumeRangesByTrack[trackKey] = List<VolumeRange>.from(ranges)
                ..sort((a, b) => a.startMs.compareTo(b.startMs));
              _lastAppliedVolume = null;
            });
            await _applyEffectiveVolume();
          },
        ),
      ),
    );
  }

  Future<void> _showVolumeSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('صدای خروجی پلیر')),
                  Text('${(_volume * 100).round()}%'),
                ],
              ),
              Slider(
                value: _volume,
                min: 0,
                max: 1,
                divisions: 100,
                label: '${(_volume * 100).round()}%',
                onChanged: (value) {
                  setSheetState(() {});
                  _setPlayerVolume(value);
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => _setPlayerVolume(0),
                    child: const Text('بی‌صدا'),
                  ),
                  TextButton(
                    onPressed: () => _setPlayerVolume(1),
                    child: const Text('صدای کامل'),
                  ),
                ],
              ),
              Text(
                'این تنظیم فقط بلندی صدای همین پلیر را تغییر می‌دهد و صدای کلی گوشی را تنظیم نمی‌کند.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _replacePlaylist({required bool autoplay}) async {
    if (_tracks.isEmpty) {
      await _player.stop();
      return;
    }
    final oldIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _tracks.length - 1).toInt();
    final sources = _tracks.map((track) {
      final uri = Uri.parse(track.path);
      return AudioSource.uri(
        uri.scheme == 'content' ? uri : Uri.file(track.path),
      );
    }).toList();
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

  Future<void> _confirmRemoveTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف از کتابخانه'),
        content: Text('«${track.title}» فقط از کتابخانهٔ برنامه حذف می‌شود و فایل اصلی در حافظه باقی می‌ماند. ادامه می‌دهی؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف از کتابخانه'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _removeTrack(index);
  }

  Future<void> _renameTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final controller = TextEditingController(text: track.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ویرایش نام فایل'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(labelText: 'نام جدید'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty || newTitle == track.title) return;
    if (_tracks.any((item) => item.path != track.path && item.title == newTitle)) {
      _showMessage('فایلی با این نام در کتابخانه وجود دارد.');
      return;
    }
    try {
      final renamed = await _folderService.renameItem(track.path, newTitle);
      final newPath = renamed['path'];
      if (newPath == null || newPath.isEmpty) {
        throw StateError('مسیر جدید فایل از سیستم دریافت نشد.');
      }
      final oldPath = track.path;
      final oldIndex = _tracks.indexWhere((item) => item.path == oldPath);
      if (oldIndex < 0) return;
      _tracks[oldIndex] = AudioTrack(path: newPath, title: newTitle);
      for (var i = 0; i < _bookmarks.length; i++) {
        final bookmark = _bookmarks[i];
        if (bookmark.audioPath != oldPath) continue;
        _bookmarks[i] = AudioBookmark(
          id: bookmark.id,
          audioPath: newPath,
          audioTitle: newTitle,
          positionMs: bookmark.positionMs,
          createdAt: bookmark.createdAt,
          title: bookmark.title,
          topic: bookmark.topic,
          endPositionMs: bookmark.endPositionMs,
          isTopicRange: bookmark.isTopicRange,
        );
      }
      for (var i = 0; i < _playlists.length; i++) {
        final playlist = _playlists[i];
        _playlists[i] = playlist.copyWith(
          trackPaths: playlist.trackPaths
              .map((path) => path == oldPath ? newPath : path)
              .toList(),
        );
      }
      final savedLyrics = _lyrics.remove(oldPath);
      if (savedLyrics != null) _lyrics[newPath] = savedLyrics;
      if (_pendingTopicAudioPath == oldPath) _pendingTopicAudioPath = newPath;
      await _persistTracks();
      await _store.saveBookmarks(_bookmarks);
      await _store.savePlaylists(_playlists);
      await _store.saveLyrics(_lyrics);
      await _replacePlaylist(autoplay: false);
      if (mounted) setState(() {});
      _showMessage('نام فایل در حافظه و کتابخانه تغییر کرد.');
    } catch (error) {
      _showMessage('تغییر نام فایل ناموفق بود: $error');
    }
  }

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _bookmarks.removeWhere((bookmark) => bookmark.audioPath == removed.path);
    if (_pendingTopicAudioPath == removed.path) {
      _pendingTopicStartMs = null;
      _pendingTopicAudioPath = null;
    }
    for (var i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      _playlists[i] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((path) => path != removed.path).toList(),
      );
    }
    await _store.savePlaylists(_playlists);
    await _store.saveBookmarks(_bookmarks);
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

  Future<void> _addBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }

    final position = _player.position;
    final details = await _showBookmarkDetailsDialog(
      initialTitle: track.title,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: position.inMilliseconds,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
      });
      _showMessage(
        'نشانک معمولی در ${_formatDuration(position)} ذخیره شد. این نشانک وارد پخش هوشمند نمی‌شود.',
      );
    } catch (error) {
      _showMessage('ذخیره نشانک ناموفق بود: $error');
    }
  }

  Future<void> _toggleTopicRangeBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای ثبت موضوع انتخاب کن.');
      return;
    }

    final startMs = _pendingTopicStartMs;
    if (startMs == null) {
      final positionMs = _player.position.inMilliseconds;
      setState(() {
        _pendingTopicStartMs = positionMs;
        _pendingTopicAudioPath = track.path;
      });
      _showMessage('شروع موضوع در ${_formatDuration(Duration(milliseconds: positionMs))} ثبت شد؛ برای ثبت پایان، دوباره همین دکمه را بزن.');
      return;
    }

    if (_pendingTopicAudioPath != track.path) {
      _showMessage('برای ثبت پایان، ابتدا به همان فایل صوتی که شروع موضوع را در آن ثبت کردی برگرد.');
      return;
    }

    final endMs = _player.position.inMilliseconds;
    if (endMs <= startMs) {
      _showMessage('زمان پایان باید بعد از زمان شروع باشد. نشانگر شروع حفظ شد؛ کمی جلوتر برو و دوباره بزن.');
      return;
    }

    final details = await _showBookmarkDetailsDialog(initialTitle: track.title);
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای نشانک موضوعی، نام موضوع را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: startMs,
      endPositionMs: endMs,
      isTopicRange: true,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
        _selectedSmartTopic ??= bookmark.topic;
        _pendingTopicStartMs = null;
        _pendingTopicAudioPath = null;
      });
      await _saveSmartSettings();
      _showMessage('بازه موضوع «${bookmark.topic}» از ${_formatDuration(Duration(milliseconds: startMs))} تا ${_formatDuration(Duration(milliseconds: endMs))} ذخیره شد.');
    } catch (error) {
      _showMessage('ذخیره بازه موضوع ناموفق بود: $error');
    }
  }

  List<String> get _availableSmartTopics {
    final topics = _bookmarks
        .where((bookmark) => bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs)
        .map((bookmark) => bookmark.topic.trim())
        .where((topic) => topic.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return topics;
  }

  Future<Map<String, String>?> _showBookmarkDetailsDialog({
    required String initialTitle,
    String initialTopic = '',
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final topicController = TextEditingController(text: initialTopic);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مشخصات نشانک'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'عنوان نشانک'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              textDirection: TextDirection.rtl,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'موضوع',
                hintText: 'مثلاً تمرکز',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'title': titleController.text.trim(),
              'topic': topicController.text.trim(),
            }),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    titleController.dispose();
    topicController.dispose();
    return result;
  }

  Future<void> _editBookmark(AudioBookmark bookmark) async {
    final details = await _showBookmarkDetailsDialog(
      initialTitle: bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
      initialTopic: bookmark.topic,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }
    final updated = _bookmarks
        .map((item) => item.id == bookmark.id
            ? AudioBookmark(
                id: item.id,
                audioPath: item.audioPath,
                audioTitle: item.audioTitle,
                positionMs: item.positionMs,
                endPositionMs: item.endPositionMs,
                isTopicRange: item.isTopicRange,
                createdAt: item.createdAt,
                title: details['title']!,
                topic: details['topic']!,
              )
            : item)
        .toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('ویرایش نشانک ذخیره نشد: $error');
    }
  }

  Future<void> _deleteBookmark(AudioBookmark bookmark) async {
    final updated = _bookmarks.where((item) => item.id != bookmark.id).toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('حذف نشانک ناموفق بود: $error');
    }
  }

  Future<void> _saveSmartSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('smart_topic_mode_v1', _smartTopicMode);
      await preferences.setString('smart_order_mode_v1', _smartOrderMode);
      if (_selectedSmartTopic == null) {
        await preferences.remove('smart_selected_topic_v1');
      } else {
        await preferences.setString('smart_selected_topic_v1', _selectedSmartTopic!);
      }
    } catch (error) {
      _showMessage('ذخیره تنظیمات پخش هوشمند ناموفق بود: $error');
    }
  }

  Future<void> _startSmartPlayback() async {
    final topics = _availableSmartTopics;
    if (topics.isEmpty) {
      _showMessage('ابتدا در تب نشانک‌ها برای نشانک‌ها موضوع تعیین کن.');
      _tabController.animateTo(1);
      return;
    }

    String topic;
    if (_smartTopicMode == 'random') {
      topic = topics[Random().nextInt(topics.length)];
    } else {
      final selected = _selectedSmartTopic;
      if (selected == null || !topics.contains(selected)) {
        _showMessage('ابتدا یک موضوع برای پخش هوشمند انتخاب کن.');
        _tabController.animateTo(4);
        return;
      }
      topic = selected;
    }

    final matching = _bookmarks
        .where((bookmark) =>
            bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs &&
            bookmark.topic.trim() == topic &&
            _tracks.any((track) => track.path == bookmark.audioPath))
        .toList();
    if (matching.isEmpty) {
      _showMessage('برای این موضوع نشانک قابل پخشی پیدا نشد.');
      return;
    }

    if (_smartOrderMode == 'random') {
      matching.shuffle(Random());
    } else {
      matching.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final sources = <AudioSource>[];
    for (final bookmark in matching) {
      final parsed = Uri.parse(bookmark.audioPath);
      final uri = parsed.scheme == 'content'
          ? parsed
          : Uri.file(bookmark.audioPath);
      sources.add(
        ClippingAudioSource(
          child: AudioSource.uri(uri),
          start: Duration(milliseconds: bookmark.positionMs),
          end: Duration(milliseconds: bookmark.endPositionMs!),
        ),
      );
    }

    try {
      await _player.pause();
      await _smartPlayer.stop();
      await _smartPlayer.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      if (!mounted) return;
      setState(() {
        _activeSmartTopic = topic;
        _smartQueueBookmarks
          ..clear()
          ..addAll(matching);
        _smartQueueReady = true;
      });
      await _smartPlayer.play();
    } catch (error) {
      if (mounted) {
        setState(() {
          _smartQueueReady = false;
          _smartQueueBookmarks.clear();
        });
        _showMessage('شروع پخش هوشمند ناموفق بود: $error');
      }
    }
  }

  Future<void> _setSmartPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _smartVolume = normalized);
    await _smartPlayer.setVolume(normalized);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('smart_topic_volume_v1', normalized);
  }

  Future<void> _toggleSmartPlayback() async {
    if (_smartPlayer.playing) {
      await _smartPlayer.pause();
      return;
    }
    if (_smartQueueReady &&
        _smartPlayer.processingState != ProcessingState.completed) {
      await _smartPlayer.play();
      return;
    }
    await _startSmartPlayback();
  }

  Future<void> _stopSmartPlayback() async {
    await _smartPlayer.stop();
    if (mounted) {
      setState(() {
        _smartQueueReady = false;
        _activeSmartTopic = null;
        _smartQueueBookmarks.clear();
      });
    }
  }

  Future<void> _playBookmark(AudioBookmark bookmark) async {
    final trackIndex =
        _tracks.indexWhere((track) => track.path == bookmark.audioPath);
    if (trackIndex < 0) {
      _showMessage('فایل صوتی این نشانک در کتابخانه موجود نیست.');
      return;
    }

    try {
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      final position = Duration(milliseconds: bookmark.positionMs);
      await _player.seek(position, index: trackIndex);
      await _player.play();
    } catch (error) {
      _showMessage('پخش از نشانک ممکن نشد: $error');
    }
  }

  Widget _buildBookmarksTab(ColorScheme colors) {
    final track = _currentTrack;
    final trackBookmarks = track == null
        ? const <AudioBookmark>[]
        : _bookmarks
            .where((bookmark) => bookmark.audioPath == track.path)
            .toList();

    if (track == null) {
      return const Center(
        child: Text(
          'برای مشاهده نشانک‌ها، ابتدا یک فایل صوتی انتخاب کن.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (trackBookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'برای «${track.title}» هنوز نشانکی ثبت نشده است. هنگام پخش این فایل، دکمه نشانک را لمس کن.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      key: ValueKey('bookmarks-${track.path}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: trackBookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final bookmark = trackBookmarks[index];
        final createdAt = bookmark.createdAt;
        final dateLabel =
            '${createdAt.year}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.day.toString().padLeft(2, '0')}  '
            '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(
              bookmark.isTopicRange
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_rounded,
              color: colors.primary,
            ),
            title: Text(
              bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '${bookmark.isTopicRange ? 'موضوع' : 'نشانک معمولی'}  •  ${bookmark.topic.isEmpty ? 'بدون موضوع' : bookmark.topic}  •  ${_formatDuration(Duration(milliseconds: bookmark.positionMs))}${bookmark.isTopicRange && bookmark.endPositionMs != null ? ' تا ${_formatDuration(Duration(milliseconds: bookmark.endPositionMs!))}' : ''}  •  $dateLabel',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'مدیریت نشانک',
              onSelected: (value) {
                if (value == 'edit') _editBookmark(bookmark);
                if (value == 'delete') _deleteBookmark(bookmark);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('ویرایش عنوان و موضوع')),
                PopupMenuItem(value: 'delete', child: Text('حذف نشانک')),
              ],
            ),
            onTap: () => _playBookmark(bookmark),
          ),
        );
      },
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ساخت پلی‌لیست جدید'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(
            labelText: 'نام پلی‌لیست',
            hintText: 'مثلاً موسیقی آرامش‌بخش',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ساختن'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final playlist = AudioPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      trackPaths: const [],
    );
    setState(() {
      _playlists.add(playlist);
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
  }

  Future<void> _addCurrentTrackToPlaylist(AudioPlaylist playlist) async {
    final track = _currentTrack;
    if (track == null) return;
    if (playlist.trackPaths.contains(track.path)) {
      _showMessage('این فایل از قبل در پلی‌لیست «${playlist.name}» وجود دارد.');
      return;
    }
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: [...playlist.trackPaths, track.path],
      );
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
    _showMessage('«${track.title}» به پلی‌لیست «${playlist.name}» اضافه شد.');
  }

  Future<void> _removeFromPlaylist(AudioPlaylist playlist, String path) async {
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((item) => item != path).toList(),
      );
    });
    await _store.savePlaylists(_playlists);
  }

  bool get _currentTrackIsFavorite {
    final track = _currentTrack;
    if (track == null) return false;
    final index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    return index >= 0 && _playlists[index].trackPaths.contains(track.path);
  }

  Future<void> _toggleCurrentTrackFavorite() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }
    var index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    if (index < 0) {
      _playlists.add(const AudioPlaylist(
        id: _favoritesPlaylistId,
        name: _favoritesPlaylistName,
        trackPaths: [],
      ));
      index = _playlists.length - 1;
    }
    final favorites = _playlists[index];
    final isFavorite = favorites.trackPaths.contains(track.path);
    setState(() {
      _playlists[index] = favorites.copyWith(
        trackPaths: isFavorite
            ? favorites.trackPaths.where((path) => path != track.path).toList()
            : [...favorites.trackPaths, track.path],
      );
      _expandedPlaylistId = _favoritesPlaylistId;
    });
    await _store.savePlaylists(_playlists);
    _showMessage(isFavorite
        ? '«${track.title}» از علاقه‌مندی‌ها حذف شد.'
        : '«${track.title}» به علاقه‌مندی‌ها اضافه شد.');
  }

  Future<void> _deletePlaylist(AudioPlaylist playlist) async {
    if (playlist.id == _favoritesPlaylistId) {
      _showMessage('پلی‌لیست علاقه‌مندی‌ها قابل حذف نیست.');
      return;
    }
    setState(() => _playlists.removeWhere((item) => item.id == playlist.id));
    await _store.savePlaylists(_playlists);
  }

  Widget _buildPlaylistsTab(ColorScheme colors) {
    final current = _currentTrack;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: IconButton.filled(
              tooltip: 'پلی‌لیست جدید',
              onPressed: _createPlaylist,
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? const SizedBox.shrink()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    final expanded = _expandedPlaylistId == playlist.id;
                    final tracks = playlist.trackPaths
                        .map((path) => _tracks.where((track) => track.path == path))
                        .where((matches) => matches.isNotEmpty)
                        .map((matches) => matches.first)
                        .toList();
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: PageStorageKey(playlist.id),
                        initiallyExpanded: expanded,
                        onExpansionChanged: (value) => setState(() {
                          _expandedPlaylistId = value ? playlist.id : null;
                        }),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        children: [
                          if (current != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _addCurrentTrackToPlaylist(playlist),
                                  child: const Text('افزودن آهنگ در حال پخش'),
                                ),
                              ),
                            ),
                          if (playlist.id != _favoritesPlaylistId)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _deletePlaylist(playlist),
                                  child: const Text('حذف پلی‌لیست'),
                                ),
                              ),
                            ),
                          if (tracks.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('این پلی‌لیست هنوز خالی است.'),
                            )
                          else
                            ...tracks.map((track) => ListTile(
                                  dense: true,
                                  title: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final trackIndex = _tracks.indexOf(track);
                                    if (trackIndex >= 0) _playTrack(trackIndex);
                                  },
                                  trailing: TextButton(
                                    onPressed: () => _removeFromPlaylist(
                                      playlist,
                                      track.path,
                                    ),
                                    child: const Text('حذف'),
                                  ),
                                )),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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

  Future<DateTime?> _chooseScheduleDateTime(String title) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: title,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      helpText: 'ساعت اجرا',
    );
    if (time == null) return null;
    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!scheduled.isAfter(DateTime.now())) {
      _showMessage('زمان انتخاب‌شده باید در آینده باشد.');
      return null;
    }
    return scheduled;
  }

  Future<void> _scheduleStartDialog() async {
    if (_tracks.isEmpty) {
      _showMessage('ابتدا یک فایل صوتی به کتابخانه اضافه کن.');
      return;
    }
    String selectedPath = _currentTrack?.path ?? _tracks.first.path;
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('شروع خودکار پخش'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedPath,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'فایل صوتی'),
            items: _tracks.map((track) => DropdownMenuItem<String>(
              value: track.path,
              child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selectedPath = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selectedPath),
              child: const Text('انتخاب زمان'),
            ),
          ],
        ),
      ),
    );
    if (path == null || !mounted) return;
    final at = await _chooseScheduleDateTime('تاریخ شروع پخش');
    if (at == null) return;
    final track = _tracks.firstWhere((item) => item.path == path);
    try {
      await ScheduledPlaybackService.scheduleStart(path: track.path, title: track.title, at: at);
      _showMessage('شروع پخش «${track.title}» برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم شروع خودکار ناموفق بود: $error');
    }
  }

  Future<void> _scheduleStopDialog() async {
    final at = await _chooseScheduleDateTime('تاریخ توقف پخش');
    if (at == null) return;
    try {
      await ScheduledPlaybackService.scheduleStop(at: at);
      _showMessage('توقف پخش برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم توقف خودکار ناموفق بود: $error');
    }
  }

  String _formatScheduleDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.year % 100)}/${two(value.month)}/${two(value.day)} - ${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _cancelScheduledStart() async {
    try {
      await ScheduledPlaybackService.cancelStart();
      _showMessage('شروع خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان شروع ناموفق بود: $error');
    }
  }

  Future<void> _cancelScheduledStop() async {
    try {
      await ScheduledPlaybackService.cancelStop();
      _showMessage('توقف خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان توقف ناموفق بود: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _messageTimer?.cancel();
    final generation = ++_messageGeneration;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          leading: const Icon(Icons.info_outline_rounded),
          content: Dismissible(
            key: ValueKey('app-message-$generation'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _messageTimer?.cancel();
              messenger.hideCurrentMaterialBanner();
            },
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(message),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'بستن پیام',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _messageTimer?.cancel();
                messenger.hideCurrentMaterialBanner();
              },
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || generation != _messageGeneration) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  @override
  void dispose() {
    _lyricsHoldTimer?.cancel();
    _themeHoldTimer?.cancel();
    _messageTimer?.cancel();
    _smartTopicMarqueeController.dispose();
    _tabController.dispose();
    _player.dispose();
    unawaited(_smartPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
        body: Column(
          children: [
            _buildPlayerToolbar(colors),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLyricsTab(colors),
                  _buildBookmarksTab(colors),
                  _buildPlaylistsTab(colors),
                  _buildLibraryTab(colors),
                  _buildSmartTab(colors),
                ],
              ),
            ),
            _buildBottomNavigation(colors),
            _buildPlayerPanel(colors),
          ],
        ),
      );
  }

  Widget _buildBottomNavigation(ColorScheme colors) {
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: false,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                labelPadding: EdgeInsets.zero,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.notes_rounded, size: 26)),
                    ),
                    text: 'متن',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.bookmarks_outlined, size: 26)),
                    ),
                    text: 'نشانک',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.queue_music_rounded, size: 26)),
                    ),
                    text: 'پلی‌لیست',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.library_music_outlined, size: 26)),
                    ),
                    text: 'کتابخانه',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.psychology_rounded, size: 26)),
                    ),
                    text: 'بخش هوشمند',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartTab(ColorScheme colors) {
    final topics = _availableSmartTopics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartTopicMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'انتخاب موضوع',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'manual',
                    child: Text('انتخاب موضوع توسط من', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('انتخاب موضوع تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartTopicMode = value);
                  await _saveSmartSettings();
                  if (value == 'manual' && topics.isNotEmpty && mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('انتخاب موضوع'),
                        content: SizedBox(
                          width: 320,
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final topic in topics)
                                ListTile(
                                  title: Text(topic),
                                  trailing: _selectedSmartTopic == topic
                                      ? const Icon(Icons.check_rounded)
                                      : null,
                                  onTap: () async {
                                    setState(() => _selectedSmartTopic = topic);
                                    await _saveSmartSettings();
                                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartOrderMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'ترتیب پخش نشانک‌ها',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'sequential',
                    child: Text('به ترتیب ثبت', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('به‌صورت تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartOrderMode = value);
                  await _saveSmartSettings();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          textDirection: TextDirection.rtl,
          children: [
            const Text(
              'موضوع در حال پخش:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final topicText = _activeSmartTopic ?? '—';
                  final textPainter = TextPainter(
                    text: TextSpan(
                      text: topicText,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                  )..layout();
                  final textWidth = textPainter.width;
                  final viewportWidth = constraints.maxWidth;
                  if (textWidth <= viewportWidth) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        topicText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  return ClipRect(
                    child: SizedBox(
                      height: 22,
                      child: AnimatedBuilder(
                        animation: _smartTopicMarqueeController,
                        builder: (context, child) {
                          final travel = viewportWidth + textWidth;
                          final offset = viewportWidth -
                              (_smartTopicMarqueeController.value * travel);
                          return Transform.translate(
                            offset: Offset(offset, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: textWidth,
                          child: Text(
                            topicText,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: topics.isEmpty ? null : _toggleSmartPlayback,
                icon: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                label: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Text(
                    snapshot.data == true ? 'مکث' : 'شروع پخش هوشمند',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'توقف پخش هوشمند',
              onPressed: _stopSmartPlayback,
              icon: const Icon(Icons.stop_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'تنظیم صدای پلیر موضوعی',
              onPressed: () => setState(
                () => _showSmartVolumeSlider = !_showSmartVolumeSlider,
              ),
              icon: Icon(
                _smartVolume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
        if (_showSmartVolumeSlider)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 8, top: 2),
            child: Row(
              children: [
                const Icon(Icons.volume_down_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: _smartVolume,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    label: '${(_smartVolume * 100).round()}٪',
                    onChanged: (value) {
                      setState(() => _smartVolume = value);
                      unawaited(_smartPlayer.setVolume(value));
                    },
                    onChangeEnd: (value) async {
                      await _setSmartPlayerVolume(value);
                      if (mounted) setState(() => _showSmartVolumeSlider = false);
                    },
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(_smartVolume * 100).round()}٪',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_smartQueueBookmarks.isNotEmpty)
          StreamBuilder<int?>(
            stream: _smartPlayer.currentIndexStream,
            initialData: _smartPlayer.currentIndex,
            builder: (context, snapshot) {
              final activeIndex = snapshot.data ?? -1;
              return Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  itemCount: _smartQueueBookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _smartQueueBookmarks[index];
                    final isActive = index == activeIndex;
                    final endMs = bookmark.endPositionMs ?? bookmark.positionMs;
                    final duration = Duration(
                      milliseconds: (endMs - bookmark.positionMs).clamp(0, 1 << 31).toInt(),
                    );
                    return Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: isActive
                          ? colors.primary.withValues(alpha: 0.10)
                          : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text(
                              _formatDuration(duration),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isActive ? colors.primary : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            isActive ? Icons.graphic_eq_rounded : Icons.bookmark_outline_rounded,
                            size: 17,
                            color: isActive ? colors.primary : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  bookmark.audioTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  bookmark.topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? colors.primary : colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isActive)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 6),
                              child: Text(
                                'در حال پخش',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          )
        else if (topics.isEmpty)
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded, size: 20),
            title: Text('هنوز موضوعی ثبت نشده است.', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              'در نوار پخش، با دکمه نشانک موضوعی ابتدا و انتهای هر موضوع را ثبت کن.',
              style: TextStyle(fontSize: 11),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'برای نمایش فهرست، پخش یک موضوع را شروع کن.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 12),
        StreamBuilder<Duration>(
          stream: _smartPlayer.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            return StreamBuilder<Duration?>(
              stream: _smartPlayer.durationStream,
              builder: (context, durationSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = durationSnapshot.data ?? Duration.zero;
                final max = duration.inMilliseconds.toDouble();
                return Column(
                  children: [
                    LinearProgressIndicator(
                      value: max <= 0
                          ? 0
                          : (position.inMilliseconds / max).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position)),
                        Text(_formatDuration(duration)),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  void _onThemeButtonDown(PointerDownEvent event) {
    _themeLongPressTriggered = false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _themeLongPressTriggered = true;
      _showPresetThemePicker();
    });
  }

  void _onThemeButtonUp(PointerUpEvent event) {
    final wasLongPress = _themeLongPressTriggered;
    final wasShortPress = _themeHoldTimer?.isActive ?? false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
    if (!wasLongPress && wasShortPress) widget.onToggleTheme();
  }

  void _onThemeButtonCancel(PointerCancelEvent event) {
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
  }

  Future<void> _showPresetThemePicker() async {
    const themes = <({String id, String name, Color color, String description})>[
      (id: 'teal', name: 'فیروزه‌ای', color: Color(0xFF16A6A0), description: 'تم پیش‌فرض فعلی'),
      (id: 'blue', name: 'آبی اقیانوسی', color: Color(0xFF2878D0), description: 'آرام و خنک'),
      (id: 'purple', name: 'بنفش', color: Color(0xFF8764D8), description: 'بنفش مدرن'),
      (id: 'green', name: 'سبز جنگلی', color: Color(0xFF39865A), description: 'طبیعی و ملایم'),
      (id: 'amber', name: 'کهربایی', color: Color(0xFFD28A22), description: 'گرم و پرانرژی'),
      (id: 'rose', name: 'رز', color: Color(0xFFC65D78), description: 'صورتی متمایل به رز'),
      (id: 'slate', name: 'خاکستری', color: Color(0xFF718096), description: 'خنثی و مینیمال'),
    ];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('انتخاب تم برنامه'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'حالت فعلی: ${widget.isDark ? 'شب' : 'روز'}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ),
              for (final theme in themes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: theme.color,
                  ),
                  title: Text(theme.name),
                  subtitle: Text(theme.description),
                  trailing: widget.themeId == theme.id
                      ? const Icon(Icons.check_circle_rounded)
                      : null,
                  onTap: () {
                    widget.onSelectTheme(theme.id);
                    Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerToolbar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              PopupMenuButton<String>(
                tooltip: 'پشتیبان‌گیری و بازیابی',
                icon: const Icon(Icons.backup_outlined, size: 24),
                onSelected: (value) {
                  if (value == 'backup') _createBackup();
                  if (value == 'restore') _restoreBackup();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'backup',
                    child: Row(
                      children: [
                        Icon(Icons.save_alt_rounded),
                        SizedBox(width: 12),
                        Text('تهیه نسخه پشتیبان'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.settings_backup_restore_rounded),
                        SizedBox(width: 12),
                        Text('بازیابی نسخه پشتیبان'),
                      ],
                    ),
                  ),
                ],
              ),
              Tooltip(
                message: 'لمس کوتاه: تغییر شب و روز • نگه‌داشتن ۳ ثانیه: انتخاب تم',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onThemeButtonDown,
                  onPointerUp: _onThemeButtonUp,
                  onPointerCancel: _onThemeButtonCancel,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        widget.isDark ? Icons.light_mode : Icons.dark_mode,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'شروع و پایان خودکار',
                icon: const Icon(Icons.schedule_rounded, size: 24),
                onSelected: (value) {
                  if (value == 'start') _scheduleStartDialog();
                  if (value == 'stop') _scheduleStopDialog();
                  if (value == 'cancel_start') _cancelScheduledStart();
                  if (value == 'cancel_stop') _cancelScheduledStop();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'start', child: Text('تنظیم شروع خودکار')),
                  PopupMenuItem(value: 'stop', child: Text('تنظیم توقف خودکار')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'cancel_start', child: Text('لغو شروع خودکار')),
                  PopupMenuItem(value: 'cancel_stop', child: Text('لغو توقف خودکار')),
                ],
              ),
              IconButton(
                tooltip: 'نقشه تغییرات صدا',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                onPressed: _openVolumeAutomation,
                icon: const Icon(Icons.multiline_chart_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    final hasLibraryItems = _libraryFolders.isNotEmpty || _tracks.isNotEmpty;
    final actions = Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'انتخاب فایل صوتی',
          onPressed: _pickAudio,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.audio_file_rounded, size: 20),
        ),
        const SizedBox(width: 3),
        IconButton.filledTonal(
          tooltip: 'انتخاب پوشه',
          onPressed: _openFolderManager,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.create_new_folder_outlined, size: 20),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final folder in _libraryFolders)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_rounded, size: 18, color: colors.primary),
                        const SizedBox(width: 4),
                        Text(
                          folder['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (!hasLibraryItems) {
      return Center(child: actions);
    }

    final itemCount = _tracks.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: actions,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: itemCount,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            itemBuilder: (context, index) {
              final trackIndex = index;
              final track = _tracks[trackIndex];
              final isCurrent = _currentIndex == trackIndex;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                minVerticalPadding: 0,
                minTileHeight: 30,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                tileColor: isCurrent
                    ? colors.primary.withValues(alpha: 0.10)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: _MarqueeText(
                  text: track.title,
                  style: const TextStyle(fontSize: 14),
                  gap: 28,
                ),
                onTap: () => _playTrack(trackIndex),
                trailing: PopupMenuButton<String>(
                  tooltip: 'گزینه‌های فایل صوتی',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  iconSize: 17,
                  onSelected: (action) {
                    if (action == 'rename') {
                      _renameTrack(trackIndex);
                    } else if (action == 'delete') {
                      _confirmRemoveTrack(trackIndex);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'rename',
                      height: 40,
                      child: Text('ویرایش نام'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      height: 40,
                      child: Text('حذف از کتابخانه'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onLyricsPointerDown(PointerDownEvent event) {
    _lyricsHoldTimer?.cancel();
    _lyricsHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _lyricsEditing = true);
    });
  }

  void _onLyricsPointerEnd(PointerEvent event) {
    _lyricsHoldTimer?.cancel();
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
              Icon(Icons.edit_note, size: 44, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'متن صدا ...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    if (_lyricsEditing) {
      return _LyricsEditor(
        key: ValueKey('edit-${track.path}'),
        track: track,
        initialText: _lyrics[track.path] ?? '',
        onSave: (value) => _saveLyrics(track.path, value),
        onSaveComplete: () {
          if (mounted) setState(() => _lyricsEditing = false);
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Expanded(
            child: Listener(
              onPointerDown: _onLyricsPointerDown,
              onPointerUp: _onLyricsPointerEnd,
              onPointerCancel: _onLyricsPointerEnd,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    (_lyrics[track.path] ?? '').trim().isEmpty
                        ? 'متن صدا ...'
                        : _lyrics[track.path]!,
                    textDirection: TextDirection.rtl,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await _store.saveLyrics(_lyrics);
                  _showMessage('متن ویس ذخیره شد.');
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded, color: colors.primary, size: 21),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _MarqueeText(
                            text: track?.title ?? 'فایلی برای پخش انتخاب نشده',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'در حال پخش',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'ثبت نشانک در زمان فعلی',
                        onPressed: track == null ? null : _addBookmark,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: _pendingTopicStartMs == null
                            ? 'ثبت شروع موضوع'
                            : 'ثبت پایان موضوع (${_formatDuration(Duration(milliseconds: _pendingTopicStartMs!))})',
                        onPressed: track == null ? null : _toggleTopicRangeBookmark,
                        color: _pendingTopicStartMs == null ? null : colors.primary,
                        icon: Icon(
                          _pendingTopicStartMs == null
                              ? Icons.bookmark_add_rounded
                              : Icons.bookmark_added_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: _currentTrack == null
                            ? 'علاقه‌مندی‌ها (ابتدا یک فایل پخش کن)'
                            : _currentTrackIsFavorite
                                ? 'حذف از علاقه‌مندی‌ها'
                                : 'افزودن به علاقه‌مندی‌ها',
                        onPressed: _toggleCurrentTrackFavorite,
                        icon: Icon(
                          _currentTrackIsFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: _currentTrackIsFavorite
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: 'شروع پخش هوشمند',
                        onPressed: _toggleSmartPlayback,
                        icon: const Icon(Icons.auto_awesome_rounded),
                      ),
                      IconButton(
                        tooltip: 'تنظیم صدای پلیر',
                        onPressed: _showVolumeSettings,
                        icon: Icon(
                          _volume == 0
                              ? Icons.volume_off_rounded
                              : _volume < 0.5
                                  ? Icons.volume_down_rounded
                                  : Icons.volume_up_rounded,
                          color: colors.primary,
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
                  final trackRanges = _bookmarks
                      .where((bookmark) =>
                          bookmark.isTopicRange &&
                          bookmark.audioPath == track?.path &&
                          bookmark.endPositionMs != null &&
                          bookmark.endPositionMs! > bookmark.positionMs)
                      .toList();
                  return Column(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final usableWidth =
                              (constraints.maxWidth - 32).clamp(0.0, double.infinity).toDouble();
                          return Stack(
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
                              if (max > 0)
                                ...trackRanges.expand((bookmark) {
                                  final startFraction =
                                      (bookmark.positionMs / max).clamp(0.0, 1.0).toDouble();
                                  final endFraction =
                                      (bookmark.endPositionMs! / max).clamp(0.0, 1.0).toDouble();
                                  return <Widget>[
                                    PositionedDirectional(
                                      start: 16 + usableWidth * startFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.tertiary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                    PositionedDirectional(
                                      start: 16 + usableWidth * endFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                  ];
                                }),
                            ],
                          );
                        },
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
                    icon: const Icon(Icons.shuffle, size: 27),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه عقب',
                    onPressed: track == null ? null : () => _seekRelative(-15),
                    icon: const Icon(Icons.replay_10, size: 27),
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
                    icon: const Icon(Icons.skip_previous_rounded, size: 32),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      final processing = snapshot.data?.processingState;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return SizedBox(
                        width: 60,
                        height: 60,
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
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  size: 34,
                                ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'بعدی',
                    onPressed: track == null ? null : _player.seekToNext,
                    icon: const Icon(Icons.skip_next_rounded, size: 32),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه جلو',
                    onPressed: track == null ? null : () => _seekRelative(15),
                    icon: const Icon(Icons.forward_10, size: 27),
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
                      size: 27,
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
    required this.onSaveComplete,
  });

  final AudioTrack track;
  final String initialText;
  final Future<void> Function(String value) onSave;
  final VoidCallback onSaveComplete;

  @override
  State<_LyricsEditor> createState() => _LyricsEditorState();
}

class _LyricsEditorState extends State<_LyricsEditor> {
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  final FocusNode _lyricsFocusNode = FocusNode();
  Timer? _saveTimer;
  bool _saving = false;
  bool _saved = true;
  bool _hasSearched = false;
  List<int> _matches = [];
  int _activeMatch = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _searchController = TextEditingController();
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
    if (_matches.isNotEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
        _hasSearched = false;
      });
    }
  }

  void _findMatches({bool preservePosition = false}) {
    final query = _searchController.text;
    final text = _controller.text;
    _hasSearched = true;
    if (query.isEmpty || text.isEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
      });
      return;
    }

    final source = text.toLowerCase();
    final needle = query.toLowerCase();
    final found = <int>[];
    var offset = 0;
    while (offset <= source.length - needle.length) {
      final index = source.indexOf(needle, offset);
      if (index < 0) break;
      found.add(index);
      offset = index + needle.length;
    }

    final previousStart = preservePosition && _activeMatch >= 0 &&
            _activeMatch < _matches.length
        ? _matches[_activeMatch]
        : -1;
    var nextActive = found.isEmpty ? -1 : 0;
    if (previousStart >= 0 && found.isNotEmpty) {
      final sameIndex = found.indexOf(previousStart);
      if (sameIndex >= 0) nextActive = sameIndex;
    }
    setState(() {
      _matches = found;
      _activeMatch = nextActive;
    });
    if (found.isNotEmpty) _selectMatch(nextActive);
  }

  void _selectMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final start = _matches[index];
    final end = start + _searchController.text.length;
    _lyricsFocusNode.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    setState(() => _activeMatch = index);
  }

  void _moveMatch(int step) {
    if (_matches.isEmpty) return;
    final next = (_activeMatch + step + _matches.length) % _matches.length;
    _selectMatch(next);
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
    _searchController.dispose();
    _lyricsFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasMatches = _matches.isNotEmpty;
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textDirection: TextDirection.rtl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _findMatches(),
                  onChanged: (_) {
                    setState(() {
                      _matches = [];
                      _activeMatch = -1;
                      _hasSearched = false;
                    });
                  },
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'جست‌وجو در متن همین ویس...',
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    suffixIcon: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      tooltip: 'جست‌وجو',
                      onPressed: _findMatches,
                      icon: const Icon(Icons.search_rounded, size: 17),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه قبلی',
                onPressed: hasMatches ? () => _moveMatch(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ),
              const SizedBox(width: 3),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه بعدی',
                onPressed: hasMatches ? () => _moveMatch(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _searchController.text.isEmpty
                  ? 'جست‌وجو فقط در متن فایل انتخاب‌شده انجام می‌شود.'
                  : hasMatches
                      ? 'نتیجه ${_activeMatch + 1} از ${_matches.length}'
                      : _hasSearched
                          ? 'کلمه‌ای با این عبارت پیدا نشد.'
                          : 'برای شروع، دکمه جست‌وجو را بزن.',
              style: TextStyle(
                fontSize: 11,
                color: hasMatches ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _lyricsFocusNode,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textDirection: TextDirection.rtl,
              onChanged: _scheduleSave,
              style: const TextStyle(fontSize: 14),
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
                onPressed: _saving
                    ? null
                    : () async {
                        _saveTimer?.cancel();
                        await _save(_controller.text);
                        if (mounted) widget.onSaveComplete();
                      },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('ذخیره', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    this.gap = 36,
  });

  final String text;
  final TextStyle style;
  final double gap;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller.stop();
      _controller.value = 0;
      _started = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout();
        final textWidth = painter.width;
        final availableWidth = constraints.maxWidth;

        if (textWidth <= availableWidth || availableWidth <= 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: widget.style,
            ),
          );
        }

        final distance = textWidth + widget.gap;
        if (!_started) {
          _started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final milliseconds =
                (distance / 32 * 1000).round().clamp(1800, 20000).toInt();
            _controller.duration = Duration(milliseconds: milliseconds);
            _controller.repeat();
          });
        }

        return ClipRect(
          child: SizedBox(
            height: painter.height,
            width: availableWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(-distance * _controller.value, 0),
                child: child,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                  SizedBox(width: widget.gap),
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
), '');
      final oldIndex = _tracks.indexWhere((item) => item.path == oldPath);
      if (oldIndex < 0) return;
      _tracks[oldIndex] = AudioTrack(path: newPath, title: displayTitle);
      for (var i = 0; i < _bookmarks.length; i++) {
        final bookmark = _bookmarks[i];
        if (bookmark.audioPath != oldPath) continue;
        _bookmarks[i] = AudioBookmark(
          id: bookmark.id,
          audioPath: newPath,
          audioTitle: newTitle,
          positionMs: bookmark.positionMs,
          createdAt: bookmark.createdAt,
          title: bookmark.title,
          topic: bookmark.topic,
          endPositionMs: bookmark.endPositionMs,
          isTopicRange: bookmark.isTopicRange,
        );
      }
      for (var i = 0; i < _playlists.length; i++) {
        final playlist = _playlists[i];
        _playlists[i] = playlist.copyWith(
          trackPaths: playlist.trackPaths
              .map((path) => path == oldPath ? newPath : path)
              .toList(),
        );
      }
      final savedLyrics = _lyrics.remove(oldPath);
      if (savedLyrics != null) _lyrics[newPath] = savedLyrics;
      if (_pendingTopicAudioPath == oldPath) _pendingTopicAudioPath = newPath;
      await _persistTracks();
      await _store.saveBookmarks(_bookmarks);
      await _store.savePlaylists(_playlists);
      await _store.saveLyrics(_lyrics);
      await _replacePlaylist(autoplay: false);
      if (mounted) setState(() {});
      _showMessage('نام فایل در حافظه و کتابخانه تغییر کرد.');
    } catch (error) {
      _showMessage('تغییر نام فایل ناموفق بود: $error');
    }
  }

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _bookmarks.removeWhere((bookmark) => bookmark.audioPath == removed.path);
    if (_pendingTopicAudioPath == removed.path) {
      _pendingTopicStartMs = null;
      _pendingTopicAudioPath = null;
    }
    for (var i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      _playlists[i] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((path) => path != removed.path).toList(),
      );
    }
    await _store.savePlaylists(_playlists);
    await _store.saveBookmarks(_bookmarks);
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

  Future<void> _addBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }

    final position = _player.position;
    final details = await _showBookmarkDetailsDialog(
      initialTitle: track.title,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: position.inMilliseconds,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
      });
      _showMessage(
        'نشانک معمولی در ${_formatDuration(position)} ذخیره شد. این نشانک وارد پخش هوشمند نمی‌شود.',
      );
    } catch (error) {
      _showMessage('ذخیره نشانک ناموفق بود: $error');
    }
  }

  Future<void> _toggleTopicRangeBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای ثبت موضوع انتخاب کن.');
      return;
    }

    final startMs = _pendingTopicStartMs;
    if (startMs == null) {
      final positionMs = _player.position.inMilliseconds;
      setState(() {
        _pendingTopicStartMs = positionMs;
        _pendingTopicAudioPath = track.path;
      });
      _showMessage('شروع موضوع در ${_formatDuration(Duration(milliseconds: positionMs))} ثبت شد؛ برای ثبت پایان، دوباره همین دکمه را بزن.');
      return;
    }

    if (_pendingTopicAudioPath != track.path) {
      _showMessage('برای ثبت پایان، ابتدا به همان فایل صوتی که شروع موضوع را در آن ثبت کردی برگرد.');
      return;
    }

    final endMs = _player.position.inMilliseconds;
    if (endMs <= startMs) {
      _showMessage('زمان پایان باید بعد از زمان شروع باشد. نشانگر شروع حفظ شد؛ کمی جلوتر برو و دوباره بزن.');
      return;
    }

    final details = await _showBookmarkDetailsDialog(initialTitle: track.title);
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای نشانک موضوعی، نام موضوع را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: startMs,
      endPositionMs: endMs,
      isTopicRange: true,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
        _selectedSmartTopic ??= bookmark.topic;
        _pendingTopicStartMs = null;
        _pendingTopicAudioPath = null;
      });
      await _saveSmartSettings();
      _showMessage('بازه موضوع «${bookmark.topic}» از ${_formatDuration(Duration(milliseconds: startMs))} تا ${_formatDuration(Duration(milliseconds: endMs))} ذخیره شد.');
    } catch (error) {
      _showMessage('ذخیره بازه موضوع ناموفق بود: $error');
    }
  }

  List<String> get _availableSmartTopics {
    final topics = _bookmarks
        .where((bookmark) => bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs)
        .map((bookmark) => bookmark.topic.trim())
        .where((topic) => topic.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return topics;
  }

  Future<Map<String, String>?> _showBookmarkDetailsDialog({
    required String initialTitle,
    String initialTopic = '',
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final topicController = TextEditingController(text: initialTopic);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مشخصات نشانک'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'عنوان نشانک'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              textDirection: TextDirection.rtl,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'موضوع',
                hintText: 'مثلاً تمرکز',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'title': titleController.text.trim(),
              'topic': topicController.text.trim(),
            }),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    titleController.dispose();
    topicController.dispose();
    return result;
  }

  Future<void> _editBookmark(AudioBookmark bookmark) async {
    final details = await _showBookmarkDetailsDialog(
      initialTitle: bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
      initialTopic: bookmark.topic,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }
    final updated = _bookmarks
        .map((item) => item.id == bookmark.id
            ? AudioBookmark(
                id: item.id,
                audioPath: item.audioPath,
                audioTitle: item.audioTitle,
                positionMs: item.positionMs,
                endPositionMs: item.endPositionMs,
                isTopicRange: item.isTopicRange,
                createdAt: item.createdAt,
                title: details['title']!,
                topic: details['topic']!,
              )
            : item)
        .toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('ویرایش نشانک ذخیره نشد: $error');
    }
  }

  Future<void> _deleteBookmark(AudioBookmark bookmark) async {
    final updated = _bookmarks.where((item) => item.id != bookmark.id).toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('حذف نشانک ناموفق بود: $error');
    }
  }

  Future<void> _saveSmartSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('smart_topic_mode_v1', _smartTopicMode);
      await preferences.setString('smart_order_mode_v1', _smartOrderMode);
      if (_selectedSmartTopic == null) {
        await preferences.remove('smart_selected_topic_v1');
      } else {
        await preferences.setString('smart_selected_topic_v1', _selectedSmartTopic!);
      }
    } catch (error) {
      _showMessage('ذخیره تنظیمات پخش هوشمند ناموفق بود: $error');
    }
  }

  Future<void> _startSmartPlayback() async {
    final topics = _availableSmartTopics;
    if (topics.isEmpty) {
      _showMessage('ابتدا در تب نشانک‌ها برای نشانک‌ها موضوع تعیین کن.');
      _tabController.animateTo(1);
      return;
    }

    String topic;
    if (_smartTopicMode == 'random') {
      topic = topics[Random().nextInt(topics.length)];
    } else {
      final selected = _selectedSmartTopic;
      if (selected == null || !topics.contains(selected)) {
        _showMessage('ابتدا یک موضوع برای پخش هوشمند انتخاب کن.');
        _tabController.animateTo(4);
        return;
      }
      topic = selected;
    }

    final matching = _bookmarks
        .where((bookmark) =>
            bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs &&
            bookmark.topic.trim() == topic &&
            _tracks.any((track) => track.path == bookmark.audioPath))
        .toList();
    if (matching.isEmpty) {
      _showMessage('برای این موضوع نشانک قابل پخشی پیدا نشد.');
      return;
    }

    if (_smartOrderMode == 'random') {
      matching.shuffle(Random());
    } else {
      matching.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final sources = <AudioSource>[];
    for (final bookmark in matching) {
      final parsed = Uri.parse(bookmark.audioPath);
      final uri = parsed.scheme == 'content'
          ? parsed
          : Uri.file(bookmark.audioPath);
      sources.add(
        ClippingAudioSource(
          child: AudioSource.uri(uri),
          start: Duration(milliseconds: bookmark.positionMs),
          end: Duration(milliseconds: bookmark.endPositionMs!),
        ),
      );
    }

    try {
      await _player.pause();
      await _smartPlayer.stop();
      await _smartPlayer.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      if (!mounted) return;
      setState(() {
        _activeSmartTopic = topic;
        _smartQueueBookmarks
          ..clear()
          ..addAll(matching);
        _smartQueueReady = true;
      });
      await _smartPlayer.play();
    } catch (error) {
      if (mounted) {
        setState(() {
          _smartQueueReady = false;
          _smartQueueBookmarks.clear();
        });
        _showMessage('شروع پخش هوشمند ناموفق بود: $error');
      }
    }
  }

  Future<void> _setSmartPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _smartVolume = normalized);
    await _smartPlayer.setVolume(normalized);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('smart_topic_volume_v1', normalized);
  }

  Future<void> _toggleSmartPlayback() async {
    if (_smartPlayer.playing) {
      await _smartPlayer.pause();
      return;
    }
    if (_smartQueueReady &&
        _smartPlayer.processingState != ProcessingState.completed) {
      await _smartPlayer.play();
      return;
    }
    await _startSmartPlayback();
  }

  Future<void> _stopSmartPlayback() async {
    await _smartPlayer.stop();
    if (mounted) {
      setState(() {
        _smartQueueReady = false;
        _activeSmartTopic = null;
        _smartQueueBookmarks.clear();
      });
    }
  }

  Future<void> _playBookmark(AudioBookmark bookmark) async {
    final trackIndex =
        _tracks.indexWhere((track) => track.path == bookmark.audioPath);
    if (trackIndex < 0) {
      _showMessage('فایل صوتی این نشانک در کتابخانه موجود نیست.');
      return;
    }

    try {
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      final position = Duration(milliseconds: bookmark.positionMs);
      await _player.seek(position, index: trackIndex);
      await _player.play();
    } catch (error) {
      _showMessage('پخش از نشانک ممکن نشد: $error');
    }
  }

  Widget _buildBookmarksTab(ColorScheme colors) {
    final track = _currentTrack;
    final trackBookmarks = track == null
        ? const <AudioBookmark>[]
        : _bookmarks
            .where((bookmark) => bookmark.audioPath == track.path)
            .toList();

    if (track == null) {
      return const Center(
        child: Text(
          'برای مشاهده نشانک‌ها، ابتدا یک فایل صوتی انتخاب کن.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (trackBookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'برای «${track.title}» هنوز نشانکی ثبت نشده است. هنگام پخش این فایل، دکمه نشانک را لمس کن.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      key: ValueKey('bookmarks-${track.path}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: trackBookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final bookmark = trackBookmarks[index];
        final createdAt = bookmark.createdAt;
        final dateLabel =
            '${createdAt.year}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.day.toString().padLeft(2, '0')}  '
            '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(
              bookmark.isTopicRange
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_rounded,
              color: colors.primary,
            ),
            title: Text(
              bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '${bookmark.isTopicRange ? 'موضوع' : 'نشانک معمولی'}  •  ${bookmark.topic.isEmpty ? 'بدون موضوع' : bookmark.topic}  •  ${_formatDuration(Duration(milliseconds: bookmark.positionMs))}${bookmark.isTopicRange && bookmark.endPositionMs != null ? ' تا ${_formatDuration(Duration(milliseconds: bookmark.endPositionMs!))}' : ''}  •  $dateLabel',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'مدیریت نشانک',
              onSelected: (value) {
                if (value == 'edit') _editBookmark(bookmark);
                if (value == 'delete') _deleteBookmark(bookmark);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('ویرایش عنوان و موضوع')),
                PopupMenuItem(value: 'delete', child: Text('حذف نشانک')),
              ],
            ),
            onTap: () => _playBookmark(bookmark),
          ),
        );
      },
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ساخت پلی‌لیست جدید'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(
            labelText: 'نام پلی‌لیست',
            hintText: 'مثلاً موسیقی آرامش‌بخش',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ساختن'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final playlist = AudioPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      trackPaths: const [],
    );
    setState(() {
      _playlists.add(playlist);
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
  }

  Future<void> _addCurrentTrackToPlaylist(AudioPlaylist playlist) async {
    final track = _currentTrack;
    if (track == null) return;
    if (playlist.trackPaths.contains(track.path)) {
      _showMessage('این فایل از قبل در پلی‌لیست «${playlist.name}» وجود دارد.');
      return;
    }
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: [...playlist.trackPaths, track.path],
      );
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
    _showMessage('«${track.title}» به پلی‌لیست «${playlist.name}» اضافه شد.');
  }

  Future<void> _removeFromPlaylist(AudioPlaylist playlist, String path) async {
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((item) => item != path).toList(),
      );
    });
    await _store.savePlaylists(_playlists);
  }

  bool get _currentTrackIsFavorite {
    final track = _currentTrack;
    if (track == null) return false;
    final index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    return index >= 0 && _playlists[index].trackPaths.contains(track.path);
  }

  Future<void> _toggleCurrentTrackFavorite() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }
    var index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    if (index < 0) {
      _playlists.add(const AudioPlaylist(
        id: _favoritesPlaylistId,
        name: _favoritesPlaylistName,
        trackPaths: [],
      ));
      index = _playlists.length - 1;
    }
    final favorites = _playlists[index];
    final isFavorite = favorites.trackPaths.contains(track.path);
    setState(() {
      _playlists[index] = favorites.copyWith(
        trackPaths: isFavorite
            ? favorites.trackPaths.where((path) => path != track.path).toList()
            : [...favorites.trackPaths, track.path],
      );
      _expandedPlaylistId = _favoritesPlaylistId;
    });
    await _store.savePlaylists(_playlists);
    _showMessage(isFavorite
        ? '«${track.title}» از علاقه‌مندی‌ها حذف شد.'
        : '«${track.title}» به علاقه‌مندی‌ها اضافه شد.');
  }

  Future<void> _deletePlaylist(AudioPlaylist playlist) async {
    if (playlist.id == _favoritesPlaylistId) {
      _showMessage('پلی‌لیست علاقه‌مندی‌ها قابل حذف نیست.');
      return;
    }
    setState(() => _playlists.removeWhere((item) => item.id == playlist.id));
    await _store.savePlaylists(_playlists);
  }

  Widget _buildPlaylistsTab(ColorScheme colors) {
    final current = _currentTrack;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: IconButton.filled(
              tooltip: 'پلی‌لیست جدید',
              onPressed: _createPlaylist,
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? const SizedBox.shrink()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    final expanded = _expandedPlaylistId == playlist.id;
                    final tracks = playlist.trackPaths
                        .map((path) => _tracks.where((track) => track.path == path))
                        .where((matches) => matches.isNotEmpty)
                        .map((matches) => matches.first)
                        .toList();
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: PageStorageKey(playlist.id),
                        initiallyExpanded: expanded,
                        onExpansionChanged: (value) => setState(() {
                          _expandedPlaylistId = value ? playlist.id : null;
                        }),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        children: [
                          if (current != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _addCurrentTrackToPlaylist(playlist),
                                  child: const Text('افزودن آهنگ در حال پخش'),
                                ),
                              ),
                            ),
                          if (playlist.id != _favoritesPlaylistId)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _deletePlaylist(playlist),
                                  child: const Text('حذف پلی‌لیست'),
                                ),
                              ),
                            ),
                          if (tracks.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('این پلی‌لیست هنوز خالی است.'),
                            )
                          else
                            ...tracks.map((track) => ListTile(
                                  dense: true,
                                  title: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final trackIndex = _tracks.indexOf(track);
                                    if (trackIndex >= 0) _playTrack(trackIndex);
                                  },
                                  trailing: TextButton(
                                    onPressed: () => _removeFromPlaylist(
                                      playlist,
                                      track.path,
                                    ),
                                    child: const Text('حذف'),
                                  ),
                                )),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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

  Future<DateTime?> _chooseScheduleDateTime(String title) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: title,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      helpText: 'ساعت اجرا',
    );
    if (time == null) return null;
    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!scheduled.isAfter(DateTime.now())) {
      _showMessage('زمان انتخاب‌شده باید در آینده باشد.');
      return null;
    }
    return scheduled;
  }

  Future<void> _scheduleStartDialog() async {
    if (_tracks.isEmpty) {
      _showMessage('ابتدا یک فایل صوتی به کتابخانه اضافه کن.');
      return;
    }
    String selectedPath = _currentTrack?.path ?? _tracks.first.path;
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('شروع خودکار پخش'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedPath,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'فایل صوتی'),
            items: _tracks.map((track) => DropdownMenuItem<String>(
              value: track.path,
              child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selectedPath = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selectedPath),
              child: const Text('انتخاب زمان'),
            ),
          ],
        ),
      ),
    );
    if (path == null || !mounted) return;
    final at = await _chooseScheduleDateTime('تاریخ شروع پخش');
    if (at == null) return;
    final track = _tracks.firstWhere((item) => item.path == path);
    try {
      await ScheduledPlaybackService.scheduleStart(path: track.path, title: track.title, at: at);
      _showMessage('شروع پخش «${track.title}» برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم شروع خودکار ناموفق بود: $error');
    }
  }

  Future<void> _scheduleStopDialog() async {
    final at = await _chooseScheduleDateTime('تاریخ توقف پخش');
    if (at == null) return;
    try {
      await ScheduledPlaybackService.scheduleStop(at: at);
      _showMessage('توقف پخش برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم توقف خودکار ناموفق بود: $error');
    }
  }

  String _formatScheduleDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.year % 100)}/${two(value.month)}/${two(value.day)} - ${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _cancelScheduledStart() async {
    try {
      await ScheduledPlaybackService.cancelStart();
      _showMessage('شروع خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان شروع ناموفق بود: $error');
    }
  }

  Future<void> _cancelScheduledStop() async {
    try {
      await ScheduledPlaybackService.cancelStop();
      _showMessage('توقف خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان توقف ناموفق بود: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _messageTimer?.cancel();
    final generation = ++_messageGeneration;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          leading: const Icon(Icons.info_outline_rounded),
          content: Dismissible(
            key: ValueKey('app-message-$generation'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _messageTimer?.cancel();
              messenger.hideCurrentMaterialBanner();
            },
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(message),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'بستن پیام',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _messageTimer?.cancel();
                messenger.hideCurrentMaterialBanner();
              },
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || generation != _messageGeneration) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  @override
  void dispose() {
    _lyricsHoldTimer?.cancel();
    _themeHoldTimer?.cancel();
    _messageTimer?.cancel();
    _smartTopicMarqueeController.dispose();
    _tabController.dispose();
    _player.dispose();
    unawaited(_smartPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
        body: Column(
          children: [
            _buildPlayerToolbar(colors),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLyricsTab(colors),
                  _buildBookmarksTab(colors),
                  _buildPlaylistsTab(colors),
                  _buildLibraryTab(colors),
                  _buildSmartTab(colors),
                ],
              ),
            ),
            _buildBottomNavigation(colors),
            _buildPlayerPanel(colors),
          ],
        ),
      );
  }

  Widget _buildBottomNavigation(ColorScheme colors) {
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: false,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                labelPadding: EdgeInsets.zero,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.notes_rounded, size: 26)),
                    ),
                    text: 'متن',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.bookmarks_outlined, size: 26)),
                    ),
                    text: 'نشانک',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.queue_music_rounded, size: 26)),
                    ),
                    text: 'پلی‌لیست',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.library_music_outlined, size: 26)),
                    ),
                    text: 'کتابخانه',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.psychology_rounded, size: 26)),
                    ),
                    text: 'بخش هوشمند',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartTab(ColorScheme colors) {
    final topics = _availableSmartTopics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartTopicMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'انتخاب موضوع',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'manual',
                    child: Text('انتخاب موضوع توسط من', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('انتخاب موضوع تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartTopicMode = value);
                  await _saveSmartSettings();
                  if (value == 'manual' && topics.isNotEmpty && mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('انتخاب موضوع'),
                        content: SizedBox(
                          width: 320,
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final topic in topics)
                                ListTile(
                                  title: Text(topic),
                                  trailing: _selectedSmartTopic == topic
                                      ? const Icon(Icons.check_rounded)
                                      : null,
                                  onTap: () async {
                                    setState(() => _selectedSmartTopic = topic);
                                    await _saveSmartSettings();
                                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartOrderMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'ترتیب پخش نشانک‌ها',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'sequential',
                    child: Text('به ترتیب ثبت', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('به‌صورت تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartOrderMode = value);
                  await _saveSmartSettings();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          textDirection: TextDirection.rtl,
          children: [
            const Text(
              'موضوع در حال پخش:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final topicText = _activeSmartTopic ?? '—';
                  final textPainter = TextPainter(
                    text: TextSpan(
                      text: topicText,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                  )..layout();
                  final textWidth = textPainter.width;
                  final viewportWidth = constraints.maxWidth;
                  if (textWidth <= viewportWidth) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        topicText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  return ClipRect(
                    child: SizedBox(
                      height: 22,
                      child: AnimatedBuilder(
                        animation: _smartTopicMarqueeController,
                        builder: (context, child) {
                          final travel = viewportWidth + textWidth;
                          final offset = viewportWidth -
                              (_smartTopicMarqueeController.value * travel);
                          return Transform.translate(
                            offset: Offset(offset, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: textWidth,
                          child: Text(
                            topicText,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: topics.isEmpty ? null : _toggleSmartPlayback,
                icon: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                label: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Text(
                    snapshot.data == true ? 'مکث' : 'شروع پخش هوشمند',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'توقف پخش هوشمند',
              onPressed: _stopSmartPlayback,
              icon: const Icon(Icons.stop_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'تنظیم صدای پلیر موضوعی',
              onPressed: () => setState(
                () => _showSmartVolumeSlider = !_showSmartVolumeSlider,
              ),
              icon: Icon(
                _smartVolume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
        if (_showSmartVolumeSlider)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 8, top: 2),
            child: Row(
              children: [
                const Icon(Icons.volume_down_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: _smartVolume,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    label: '${(_smartVolume * 100).round()}٪',
                    onChanged: (value) {
                      setState(() => _smartVolume = value);
                      unawaited(_smartPlayer.setVolume(value));
                    },
                    onChangeEnd: (value) async {
                      await _setSmartPlayerVolume(value);
                      if (mounted) setState(() => _showSmartVolumeSlider = false);
                    },
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(_smartVolume * 100).round()}٪',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_smartQueueBookmarks.isNotEmpty)
          StreamBuilder<int?>(
            stream: _smartPlayer.currentIndexStream,
            initialData: _smartPlayer.currentIndex,
            builder: (context, snapshot) {
              final activeIndex = snapshot.data ?? -1;
              return Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  itemCount: _smartQueueBookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _smartQueueBookmarks[index];
                    final isActive = index == activeIndex;
                    final endMs = bookmark.endPositionMs ?? bookmark.positionMs;
                    final duration = Duration(
                      milliseconds: (endMs - bookmark.positionMs).clamp(0, 1 << 31).toInt(),
                    );
                    return Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: isActive
                          ? colors.primary.withValues(alpha: 0.10)
                          : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text(
                              _formatDuration(duration),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isActive ? colors.primary : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            isActive ? Icons.graphic_eq_rounded : Icons.bookmark_outline_rounded,
                            size: 17,
                            color: isActive ? colors.primary : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  bookmark.audioTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  bookmark.topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? colors.primary : colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isActive)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 6),
                              child: Text(
                                'در حال پخش',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          )
        else if (topics.isEmpty)
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded, size: 20),
            title: Text('هنوز موضوعی ثبت نشده است.', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              'در نوار پخش، با دکمه نشانک موضوعی ابتدا و انتهای هر موضوع را ثبت کن.',
              style: TextStyle(fontSize: 11),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'برای نمایش فهرست، پخش یک موضوع را شروع کن.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 12),
        StreamBuilder<Duration>(
          stream: _smartPlayer.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            return StreamBuilder<Duration?>(
              stream: _smartPlayer.durationStream,
              builder: (context, durationSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = durationSnapshot.data ?? Duration.zero;
                final max = duration.inMilliseconds.toDouble();
                return Column(
                  children: [
                    LinearProgressIndicator(
                      value: max <= 0
                          ? 0
                          : (position.inMilliseconds / max).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position)),
                        Text(_formatDuration(duration)),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  void _onThemeButtonDown(PointerDownEvent event) {
    _themeLongPressTriggered = false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _themeLongPressTriggered = true;
      _showPresetThemePicker();
    });
  }

  void _onThemeButtonUp(PointerUpEvent event) {
    final wasLongPress = _themeLongPressTriggered;
    final wasShortPress = _themeHoldTimer?.isActive ?? false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
    if (!wasLongPress && wasShortPress) widget.onToggleTheme();
  }

  void _onThemeButtonCancel(PointerCancelEvent event) {
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
  }

  Future<void> _showPresetThemePicker() async {
    const themes = <({String id, String name, Color color, String description})>[
      (id: 'teal', name: 'فیروزه‌ای', color: Color(0xFF16A6A0), description: 'تم پیش‌فرض فعلی'),
      (id: 'blue', name: 'آبی اقیانوسی', color: Color(0xFF2878D0), description: 'آرام و خنک'),
      (id: 'purple', name: 'بنفش', color: Color(0xFF8764D8), description: 'بنفش مدرن'),
      (id: 'green', name: 'سبز جنگلی', color: Color(0xFF39865A), description: 'طبیعی و ملایم'),
      (id: 'amber', name: 'کهربایی', color: Color(0xFFD28A22), description: 'گرم و پرانرژی'),
      (id: 'rose', name: 'رز', color: Color(0xFFC65D78), description: 'صورتی متمایل به رز'),
      (id: 'slate', name: 'خاکستری', color: Color(0xFF718096), description: 'خنثی و مینیمال'),
    ];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('انتخاب تم برنامه'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'حالت فعلی: ${widget.isDark ? 'شب' : 'روز'}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ),
              for (final theme in themes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: theme.color,
                  ),
                  title: Text(theme.name),
                  subtitle: Text(theme.description),
                  trailing: widget.themeId == theme.id
                      ? const Icon(Icons.check_circle_rounded)
                      : null,
                  onTap: () {
                    widget.onSelectTheme(theme.id);
                    Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerToolbar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              PopupMenuButton<String>(
                tooltip: 'پشتیبان‌گیری و بازیابی',
                icon: const Icon(Icons.backup_outlined, size: 24),
                onSelected: (value) {
                  if (value == 'backup') _createBackup();
                  if (value == 'restore') _restoreBackup();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'backup',
                    child: Row(
                      children: [
                        Icon(Icons.save_alt_rounded),
                        SizedBox(width: 12),
                        Text('تهیه نسخه پشتیبان'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.settings_backup_restore_rounded),
                        SizedBox(width: 12),
                        Text('بازیابی نسخه پشتیبان'),
                      ],
                    ),
                  ),
                ],
              ),
              Tooltip(
                message: 'لمس کوتاه: تغییر شب و روز • نگه‌داشتن ۳ ثانیه: انتخاب تم',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onThemeButtonDown,
                  onPointerUp: _onThemeButtonUp,
                  onPointerCancel: _onThemeButtonCancel,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        widget.isDark ? Icons.light_mode : Icons.dark_mode,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'شروع و پایان خودکار',
                icon: const Icon(Icons.schedule_rounded, size: 24),
                onSelected: (value) {
                  if (value == 'start') _scheduleStartDialog();
                  if (value == 'stop') _scheduleStopDialog();
                  if (value == 'cancel_start') _cancelScheduledStart();
                  if (value == 'cancel_stop') _cancelScheduledStop();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'start', child: Text('تنظیم شروع خودکار')),
                  PopupMenuItem(value: 'stop', child: Text('تنظیم توقف خودکار')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'cancel_start', child: Text('لغو شروع خودکار')),
                  PopupMenuItem(value: 'cancel_stop', child: Text('لغو توقف خودکار')),
                ],
              ),
              IconButton(
                tooltip: 'نقشه تغییرات صدا',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                onPressed: _openVolumeAutomation,
                icon: const Icon(Icons.multiline_chart_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    final hasLibraryItems = _libraryFolders.isNotEmpty || _tracks.isNotEmpty;
    final actions = Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'انتخاب فایل صوتی',
          onPressed: _pickAudio,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.audio_file_rounded, size: 20),
        ),
        const SizedBox(width: 3),
        IconButton.filledTonal(
          tooltip: 'انتخاب پوشه',
          onPressed: _openFolderManager,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.create_new_folder_outlined, size: 20),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final folder in _libraryFolders)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_rounded, size: 18, color: colors.primary),
                        const SizedBox(width: 4),
                        Text(
                          folder['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (!hasLibraryItems) {
      return Center(child: actions);
    }

    final itemCount = _tracks.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: actions,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: itemCount,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            itemBuilder: (context, index) {
              final trackIndex = index;
              final track = _tracks[trackIndex];
              final isCurrent = _currentIndex == trackIndex;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                minVerticalPadding: 0,
                minTileHeight: 30,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                tileColor: isCurrent
                    ? colors.primary.withValues(alpha: 0.10)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: _MarqueeText(
                  text: track.title,
                  style: const TextStyle(fontSize: 14),
                  gap: 28,
                ),
                onTap: () => _playTrack(trackIndex),
                trailing: PopupMenuButton<String>(
                  tooltip: 'گزینه‌های فایل صوتی',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  iconSize: 17,
                  onSelected: (action) {
                    if (action == 'rename') {
                      _renameTrack(trackIndex);
                    } else if (action == 'delete') {
                      _confirmRemoveTrack(trackIndex);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'rename',
                      height: 40,
                      child: Text('ویرایش نام'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      height: 40,
                      child: Text('حذف از کتابخانه'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onLyricsPointerDown(PointerDownEvent event) {
    _lyricsHoldTimer?.cancel();
    _lyricsHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _lyricsEditing = true);
    });
  }

  void _onLyricsPointerEnd(PointerEvent event) {
    _lyricsHoldTimer?.cancel();
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
              Icon(Icons.edit_note, size: 44, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'متن صدا ...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    if (_lyricsEditing) {
      return _LyricsEditor(
        key: ValueKey('edit-${track.path}'),
        track: track,
        initialText: _lyrics[track.path] ?? '',
        onSave: (value) => _saveLyrics(track.path, value),
        onSaveComplete: () {
          if (mounted) setState(() => _lyricsEditing = false);
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Expanded(
            child: Listener(
              onPointerDown: _onLyricsPointerDown,
              onPointerUp: _onLyricsPointerEnd,
              onPointerCancel: _onLyricsPointerEnd,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    (_lyrics[track.path] ?? '').trim().isEmpty
                        ? 'متن صدا ...'
                        : _lyrics[track.path]!,
                    textDirection: TextDirection.rtl,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await _store.saveLyrics(_lyrics);
                  _showMessage('متن ویس ذخیره شد.');
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded, color: colors.primary, size: 21),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _MarqueeText(
                            text: track?.title ?? 'فایلی برای پخش انتخاب نشده',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'در حال پخش',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'ثبت نشانک در زمان فعلی',
                        onPressed: track == null ? null : _addBookmark,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: _pendingTopicStartMs == null
                            ? 'ثبت شروع موضوع'
                            : 'ثبت پایان موضوع (${_formatDuration(Duration(milliseconds: _pendingTopicStartMs!))})',
                        onPressed: track == null ? null : _toggleTopicRangeBookmark,
                        color: _pendingTopicStartMs == null ? null : colors.primary,
                        icon: Icon(
                          _pendingTopicStartMs == null
                              ? Icons.bookmark_add_rounded
                              : Icons.bookmark_added_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: _currentTrack == null
                            ? 'علاقه‌مندی‌ها (ابتدا یک فایل پخش کن)'
                            : _currentTrackIsFavorite
                                ? 'حذف از علاقه‌مندی‌ها'
                                : 'افزودن به علاقه‌مندی‌ها',
                        onPressed: _toggleCurrentTrackFavorite,
                        icon: Icon(
                          _currentTrackIsFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: _currentTrackIsFavorite
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: 'شروع پخش هوشمند',
                        onPressed: _toggleSmartPlayback,
                        icon: const Icon(Icons.auto_awesome_rounded),
                      ),
                      IconButton(
                        tooltip: 'تنظیم صدای پلیر',
                        onPressed: _showVolumeSettings,
                        icon: Icon(
                          _volume == 0
                              ? Icons.volume_off_rounded
                              : _volume < 0.5
                                  ? Icons.volume_down_rounded
                                  : Icons.volume_up_rounded,
                          color: colors.primary,
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
                  final trackRanges = _bookmarks
                      .where((bookmark) =>
                          bookmark.isTopicRange &&
                          bookmark.audioPath == track?.path &&
                          bookmark.endPositionMs != null &&
                          bookmark.endPositionMs! > bookmark.positionMs)
                      .toList();
                  return Column(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final usableWidth =
                              (constraints.maxWidth - 32).clamp(0.0, double.infinity).toDouble();
                          return Stack(
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
                              if (max > 0)
                                ...trackRanges.expand((bookmark) {
                                  final startFraction =
                                      (bookmark.positionMs / max).clamp(0.0, 1.0).toDouble();
                                  final endFraction =
                                      (bookmark.endPositionMs! / max).clamp(0.0, 1.0).toDouble();
                                  return <Widget>[
                                    PositionedDirectional(
                                      start: 16 + usableWidth * startFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.tertiary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                    PositionedDirectional(
                                      start: 16 + usableWidth * endFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                  ];
                                }),
                            ],
                          );
                        },
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
                    icon: const Icon(Icons.shuffle, size: 27),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه عقب',
                    onPressed: track == null ? null : () => _seekRelative(-15),
                    icon: const Icon(Icons.replay_10, size: 27),
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
                    icon: const Icon(Icons.skip_previous_rounded, size: 32),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      final processing = snapshot.data?.processingState;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return SizedBox(
                        width: 60,
                        height: 60,
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
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  size: 34,
                                ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'بعدی',
                    onPressed: track == null ? null : _player.seekToNext,
                    icon: const Icon(Icons.skip_next_rounded, size: 32),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه جلو',
                    onPressed: track == null ? null : () => _seekRelative(15),
                    icon: const Icon(Icons.forward_10, size: 27),
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
                      size: 27,
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
    required this.onSaveComplete,
  });

  final AudioTrack track;
  final String initialText;
  final Future<void> Function(String value) onSave;
  final VoidCallback onSaveComplete;

  @override
  State<_LyricsEditor> createState() => _LyricsEditorState();
}

class _LyricsEditorState extends State<_LyricsEditor> {
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  final FocusNode _lyricsFocusNode = FocusNode();
  Timer? _saveTimer;
  bool _saving = false;
  bool _saved = true;
  bool _hasSearched = false;
  List<int> _matches = [];
  int _activeMatch = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _searchController = TextEditingController();
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
    if (_matches.isNotEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
        _hasSearched = false;
      });
    }
  }

  void _findMatches({bool preservePosition = false}) {
    final query = _searchController.text;
    final text = _controller.text;
    _hasSearched = true;
    if (query.isEmpty || text.isEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
      });
      return;
    }

    final source = text.toLowerCase();
    final needle = query.toLowerCase();
    final found = <int>[];
    var offset = 0;
    while (offset <= source.length - needle.length) {
      final index = source.indexOf(needle, offset);
      if (index < 0) break;
      found.add(index);
      offset = index + needle.length;
    }

    final previousStart = preservePosition && _activeMatch >= 0 &&
            _activeMatch < _matches.length
        ? _matches[_activeMatch]
        : -1;
    var nextActive = found.isEmpty ? -1 : 0;
    if (previousStart >= 0 && found.isNotEmpty) {
      final sameIndex = found.indexOf(previousStart);
      if (sameIndex >= 0) nextActive = sameIndex;
    }
    setState(() {
      _matches = found;
      _activeMatch = nextActive;
    });
    if (found.isNotEmpty) _selectMatch(nextActive);
  }

  void _selectMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final start = _matches[index];
    final end = start + _searchController.text.length;
    _lyricsFocusNode.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    setState(() => _activeMatch = index);
  }

  void _moveMatch(int step) {
    if (_matches.isEmpty) return;
    final next = (_activeMatch + step + _matches.length) % _matches.length;
    _selectMatch(next);
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
    _searchController.dispose();
    _lyricsFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasMatches = _matches.isNotEmpty;
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textDirection: TextDirection.rtl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _findMatches(),
                  onChanged: (_) {
                    setState(() {
                      _matches = [];
                      _activeMatch = -1;
                      _hasSearched = false;
                    });
                  },
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'جست‌وجو در متن همین ویس...',
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    suffixIcon: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      tooltip: 'جست‌وجو',
                      onPressed: _findMatches,
                      icon: const Icon(Icons.search_rounded, size: 17),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه قبلی',
                onPressed: hasMatches ? () => _moveMatch(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ),
              const SizedBox(width: 3),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه بعدی',
                onPressed: hasMatches ? () => _moveMatch(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _searchController.text.isEmpty
                  ? 'جست‌وجو فقط در متن فایل انتخاب‌شده انجام می‌شود.'
                  : hasMatches
                      ? 'نتیجه ${_activeMatch + 1} از ${_matches.length}'
                      : _hasSearched
                          ? 'کلمه‌ای با این عبارت پیدا نشد.'
                          : 'برای شروع، دکمه جست‌وجو را بزن.',
              style: TextStyle(
                fontSize: 11,
                color: hasMatches ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _lyricsFocusNode,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textDirection: TextDirection.rtl,
              onChanged: _scheduleSave,
              style: const TextStyle(fontSize: 14),
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
                onPressed: _saving
                    ? null
                    : () async {
                        _saveTimer?.cancel();
                        await _save(_controller.text);
                        if (mounted) widget.onSaveComplete();
                      },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('ذخیره', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    this.gap = 36,
  });

  final String text;
  final TextStyle style;
  final double gap;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller.stop();
      _controller.value = 0;
      _started = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout();
        final textWidth = painter.width;
        final availableWidth = constraints.maxWidth;

        if (textWidth <= availableWidth || availableWidth <= 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: widget.style,
            ),
          );
        }

        final distance = textWidth + widget.gap;
        if (!_started) {
          _started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final milliseconds =
                (distance / 32 * 1000).round().clamp(1800, 20000).toInt();
            _controller.duration = Duration(milliseconds: milliseconds);
            _controller.repeat();
          });
        }

        return ClipRect(
          child: SizedBox(
            height: painter.height,
            width: availableWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(-distance * _controller.value, 0),
                child: child,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                  SizedBox(width: widget.gap),
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
), ''),
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

  Future<void> _openFolderManager() async {
    final folders = await _store.loadFolders();
    if (!mounted) return;
    final selected = folders.map((folder) => Map<String, String>.from(folder)).toList();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('پوشه‌های کتابخانه'),
          content: SizedBox(
            width: double.maxFinite,
            height: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text('هنوز پوشه‌ای انتخاب نشده است.'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: selected.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          selected[index]['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'حذف پوشه',
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(
                            () => selected.removeAt(index),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final folder = await _folderService.pickFolder();
                      if (folder == null) return;
                      if (selected.any((item) => item['uri'] == folder['uri'])) return;
                      setDialogState(() => selected.add(folder));
                    } catch (error) {
                      if (mounted) _showMessage('انتخاب پوشه ناموفق بود: $error');
                    }
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('افزودن پوشه'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final result = selected
                          .map((folder) => Map<String, String>.from(folder))
                          .toList();
                      Navigator.pop(dialogContext);
                      unawaited(_scanSelectedFolders(result));
                    },
              icon: const Icon(Icons.sync),
              label: const Text('شروع اسکن'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanSelectedFolders(List<Map<String, String>> folders) async {
    try {
      await _store.saveFolders(folders);
      if (mounted) {
        setState(() {
          _libraryFolders
            ..clear()
            ..addAll(folders.map((folder) => Map<String, String>.from(folder)));
        });
      }
      _showMessage('در حال اسکن پوشه‌ها...');
      final found = await _folderService.scanFolders(
        folders.map((folder) => folder['uri']!).toList(),
      );
      final existing = _tracks.map((track) => track.path).toSet();
      final added = <AudioTrack>[];
      var duplicates = 0;
      for (final item in found) {
        final uri = item['uri']!;
        if (!existing.add(uri)) {
          duplicates++;
          continue;
        }
        final name = item['name']!;
        final dotIndex = name.lastIndexOf('.');
        final title = dotIndex > 0 ? name.substring(0, dotIndex) : name;
        added.add(AudioTrack(path: uri, title: title));
      }
      if (added.isNotEmpty) {
        setState(() => _tracks.addAll(added));
        await _persistTracks();
        await _replacePlaylist(autoplay: false);
      }
      _showMessage(
        'اسکن تمام شد: ${added.length} فایل جدید، '
        '$duplicates فایل تکراری از ${found.length} فایل شناسایی‌شده.',
      );
    } catch (error) {
      _showMessage('اسکن پوشه‌ها ناموفق بود: $error');
    }
  }

  Future<void> _applyEffectiveVolume({Duration? position}) async {
    final positionMs = (position ?? _player.position).inMilliseconds;
    final trackPath = _currentTrack?.path;
    final ranges = trackPath == null
        ? const <VolumeRange>[]
        : (_volumeRangesByTrack[base64Url.encode(utf8.encode(trackPath))] ??
            const <VolumeRange>[]);
    final effective = scheduledVolumeAt(ranges, positionMs, _volume);
    if (_lastAppliedVolume != null &&
        (effective - _lastAppliedVolume!).abs() < 0.0001) {
      return;
    }
    _lastAppliedVolume = effective;
    await _player.setVolume(effective);
  }

  Future<void> _setPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _volume = normalized);
    _lastAppliedVolume = null;
    await _applyEffectiveVolume();
    await _store.saveVolume(normalized);
  }

  Future<void> _openVolumeAutomation() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را انتخاب کن.');
      return;
    }
    final trackKey = base64Url.encode(utf8.encode(track.path));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VolumeAutomationScreen(
          initialRanges: List<VolumeRange>.from(
            _volumeRangesByTrack[trackKey] ?? const <VolumeRange>[],
          ),
          onSave: (ranges) async {
            final preferences = await SharedPreferences.getInstance();
            final key = 'volume_ranges_v1_$trackKey';
            await preferences.setString(
              key,
              jsonEncode(ranges.map((range) => range.toMap()).toList()),
            );
            if (!mounted) return;
            setState(() {
              _volumeRangesByTrack[trackKey] = List<VolumeRange>.from(ranges)
                ..sort((a, b) => a.startMs.compareTo(b.startMs));
              _lastAppliedVolume = null;
            });
            await _applyEffectiveVolume();
          },
        ),
      ),
    );
  }

  Future<void> _showVolumeSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('صدای خروجی پلیر')),
                  Text('${(_volume * 100).round()}%'),
                ],
              ),
              Slider(
                value: _volume,
                min: 0,
                max: 1,
                divisions: 100,
                label: '${(_volume * 100).round()}%',
                onChanged: (value) {
                  setSheetState(() {});
                  _setPlayerVolume(value);
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => _setPlayerVolume(0),
                    child: const Text('بی‌صدا'),
                  ),
                  TextButton(
                    onPressed: () => _setPlayerVolume(1),
                    child: const Text('صدای کامل'),
                  ),
                ],
              ),
              Text(
                'این تنظیم فقط بلندی صدای همین پلیر را تغییر می‌دهد و صدای کلی گوشی را تنظیم نمی‌کند.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _replacePlaylist({required bool autoplay}) async {
    if (_tracks.isEmpty) {
      await _player.stop();
      return;
    }
    final oldIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _tracks.length - 1).toInt();
    final sources = _tracks.map((track) {
      final uri = Uri.parse(track.path);
      return AudioSource.uri(
        uri.scheme == 'content' ? uri : Uri.file(track.path),
      );
    }).toList();
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

  Future<void> _confirmRemoveTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف از کتابخانه'),
        content: Text('«${track.title}» فقط از کتابخانهٔ برنامه حذف می‌شود و فایل اصلی در حافظه باقی می‌ماند. ادامه می‌دهی؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف از کتابخانه'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _removeTrack(index);
  }

  Future<void> _renameTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final controller = TextEditingController(text: track.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ویرایش نام فایل'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(labelText: 'نام جدید'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty || newTitle == track.title) return;
    if (_tracks.any((item) => item.path != track.path && item.title == newTitle)) {
      _showMessage('فایلی با این نام در کتابخانه وجود دارد.');
      return;
    }
    try {
      final renamed = await _folderService.renameItem(track.path, newTitle);
      final newPath = renamed['path'];
      if (newPath == null || newPath.isEmpty) {
        throw StateError('مسیر جدید فایل از سیستم دریافت نشد.');
      }
      final oldPath = track.path;
      final oldIndex = _tracks.indexWhere((item) => item.path == oldPath);
      if (oldIndex < 0) return;
      _tracks[oldIndex] = AudioTrack(path: newPath, title: newTitle);
      for (var i = 0; i < _bookmarks.length; i++) {
        final bookmark = _bookmarks[i];
        if (bookmark.audioPath != oldPath) continue;
        _bookmarks[i] = AudioBookmark(
          id: bookmark.id,
          audioPath: newPath,
          audioTitle: newTitle,
          positionMs: bookmark.positionMs,
          createdAt: bookmark.createdAt,
          title: bookmark.title,
          topic: bookmark.topic,
          endPositionMs: bookmark.endPositionMs,
          isTopicRange: bookmark.isTopicRange,
        );
      }
      for (var i = 0; i < _playlists.length; i++) {
        final playlist = _playlists[i];
        _playlists[i] = playlist.copyWith(
          trackPaths: playlist.trackPaths
              .map((path) => path == oldPath ? newPath : path)
              .toList(),
        );
      }
      final savedLyrics = _lyrics.remove(oldPath);
      if (savedLyrics != null) _lyrics[newPath] = savedLyrics;
      if (_pendingTopicAudioPath == oldPath) _pendingTopicAudioPath = newPath;
      await _persistTracks();
      await _store.saveBookmarks(_bookmarks);
      await _store.savePlaylists(_playlists);
      await _store.saveLyrics(_lyrics);
      await _replacePlaylist(autoplay: false);
      if (mounted) setState(() {});
      _showMessage('نام فایل در حافظه و کتابخانه تغییر کرد.');
    } catch (error) {
      _showMessage('تغییر نام فایل ناموفق بود: $error');
    }
  }

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _bookmarks.removeWhere((bookmark) => bookmark.audioPath == removed.path);
    if (_pendingTopicAudioPath == removed.path) {
      _pendingTopicStartMs = null;
      _pendingTopicAudioPath = null;
    }
    for (var i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      _playlists[i] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((path) => path != removed.path).toList(),
      );
    }
    await _store.savePlaylists(_playlists);
    await _store.saveBookmarks(_bookmarks);
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

  Future<void> _addBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }

    final position = _player.position;
    final details = await _showBookmarkDetailsDialog(
      initialTitle: track.title,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: position.inMilliseconds,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
      });
      _showMessage(
        'نشانک معمولی در ${_formatDuration(position)} ذخیره شد. این نشانک وارد پخش هوشمند نمی‌شود.',
      );
    } catch (error) {
      _showMessage('ذخیره نشانک ناموفق بود: $error');
    }
  }

  Future<void> _toggleTopicRangeBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای ثبت موضوع انتخاب کن.');
      return;
    }

    final startMs = _pendingTopicStartMs;
    if (startMs == null) {
      final positionMs = _player.position.inMilliseconds;
      setState(() {
        _pendingTopicStartMs = positionMs;
        _pendingTopicAudioPath = track.path;
      });
      _showMessage('شروع موضوع در ${_formatDuration(Duration(milliseconds: positionMs))} ثبت شد؛ برای ثبت پایان، دوباره همین دکمه را بزن.');
      return;
    }

    if (_pendingTopicAudioPath != track.path) {
      _showMessage('برای ثبت پایان، ابتدا به همان فایل صوتی که شروع موضوع را در آن ثبت کردی برگرد.');
      return;
    }

    final endMs = _player.position.inMilliseconds;
    if (endMs <= startMs) {
      _showMessage('زمان پایان باید بعد از زمان شروع باشد. نشانگر شروع حفظ شد؛ کمی جلوتر برو و دوباره بزن.');
      return;
    }

    final details = await _showBookmarkDetailsDialog(initialTitle: track.title);
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای نشانک موضوعی، نام موضوع را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: startMs,
      endPositionMs: endMs,
      isTopicRange: true,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
        _selectedSmartTopic ??= bookmark.topic;
        _pendingTopicStartMs = null;
        _pendingTopicAudioPath = null;
      });
      await _saveSmartSettings();
      _showMessage('بازه موضوع «${bookmark.topic}» از ${_formatDuration(Duration(milliseconds: startMs))} تا ${_formatDuration(Duration(milliseconds: endMs))} ذخیره شد.');
    } catch (error) {
      _showMessage('ذخیره بازه موضوع ناموفق بود: $error');
    }
  }

  List<String> get _availableSmartTopics {
    final topics = _bookmarks
        .where((bookmark) => bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs)
        .map((bookmark) => bookmark.topic.trim())
        .where((topic) => topic.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return topics;
  }

  Future<Map<String, String>?> _showBookmarkDetailsDialog({
    required String initialTitle,
    String initialTopic = '',
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final topicController = TextEditingController(text: initialTopic);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مشخصات نشانک'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'عنوان نشانک'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              textDirection: TextDirection.rtl,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'موضوع',
                hintText: 'مثلاً تمرکز',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'title': titleController.text.trim(),
              'topic': topicController.text.trim(),
            }),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    titleController.dispose();
    topicController.dispose();
    return result;
  }

  Future<void> _editBookmark(AudioBookmark bookmark) async {
    final details = await _showBookmarkDetailsDialog(
      initialTitle: bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
      initialTopic: bookmark.topic,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }
    final updated = _bookmarks
        .map((item) => item.id == bookmark.id
            ? AudioBookmark(
                id: item.id,
                audioPath: item.audioPath,
                audioTitle: item.audioTitle,
                positionMs: item.positionMs,
                endPositionMs: item.endPositionMs,
                isTopicRange: item.isTopicRange,
                createdAt: item.createdAt,
                title: details['title']!,
                topic: details['topic']!,
              )
            : item)
        .toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('ویرایش نشانک ذخیره نشد: $error');
    }
  }

  Future<void> _deleteBookmark(AudioBookmark bookmark) async {
    final updated = _bookmarks.where((item) => item.id != bookmark.id).toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('حذف نشانک ناموفق بود: $error');
    }
  }

  Future<void> _saveSmartSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('smart_topic_mode_v1', _smartTopicMode);
      await preferences.setString('smart_order_mode_v1', _smartOrderMode);
      if (_selectedSmartTopic == null) {
        await preferences.remove('smart_selected_topic_v1');
      } else {
        await preferences.setString('smart_selected_topic_v1', _selectedSmartTopic!);
      }
    } catch (error) {
      _showMessage('ذخیره تنظیمات پخش هوشمند ناموفق بود: $error');
    }
  }

  Future<void> _startSmartPlayback() async {
    final topics = _availableSmartTopics;
    if (topics.isEmpty) {
      _showMessage('ابتدا در تب نشانک‌ها برای نشانک‌ها موضوع تعیین کن.');
      _tabController.animateTo(1);
      return;
    }

    String topic;
    if (_smartTopicMode == 'random') {
      topic = topics[Random().nextInt(topics.length)];
    } else {
      final selected = _selectedSmartTopic;
      if (selected == null || !topics.contains(selected)) {
        _showMessage('ابتدا یک موضوع برای پخش هوشمند انتخاب کن.');
        _tabController.animateTo(4);
        return;
      }
      topic = selected;
    }

    final matching = _bookmarks
        .where((bookmark) =>
            bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs &&
            bookmark.topic.trim() == topic &&
            _tracks.any((track) => track.path == bookmark.audioPath))
        .toList();
    if (matching.isEmpty) {
      _showMessage('برای این موضوع نشانک قابل پخشی پیدا نشد.');
      return;
    }

    if (_smartOrderMode == 'random') {
      matching.shuffle(Random());
    } else {
      matching.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final sources = <AudioSource>[];
    for (final bookmark in matching) {
      final parsed = Uri.parse(bookmark.audioPath);
      final uri = parsed.scheme == 'content'
          ? parsed
          : Uri.file(bookmark.audioPath);
      sources.add(
        ClippingAudioSource(
          child: AudioSource.uri(uri),
          start: Duration(milliseconds: bookmark.positionMs),
          end: Duration(milliseconds: bookmark.endPositionMs!),
        ),
      );
    }

    try {
      await _player.pause();
      await _smartPlayer.stop();
      await _smartPlayer.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      if (!mounted) return;
      setState(() {
        _activeSmartTopic = topic;
        _smartQueueBookmarks
          ..clear()
          ..addAll(matching);
        _smartQueueReady = true;
      });
      await _smartPlayer.play();
    } catch (error) {
      if (mounted) {
        setState(() {
          _smartQueueReady = false;
          _smartQueueBookmarks.clear();
        });
        _showMessage('شروع پخش هوشمند ناموفق بود: $error');
      }
    }
  }

  Future<void> _setSmartPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _smartVolume = normalized);
    await _smartPlayer.setVolume(normalized);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('smart_topic_volume_v1', normalized);
  }

  Future<void> _toggleSmartPlayback() async {
    if (_smartPlayer.playing) {
      await _smartPlayer.pause();
      return;
    }
    if (_smartQueueReady &&
        _smartPlayer.processingState != ProcessingState.completed) {
      await _smartPlayer.play();
      return;
    }
    await _startSmartPlayback();
  }

  Future<void> _stopSmartPlayback() async {
    await _smartPlayer.stop();
    if (mounted) {
      setState(() {
        _smartQueueReady = false;
        _activeSmartTopic = null;
        _smartQueueBookmarks.clear();
      });
    }
  }

  Future<void> _playBookmark(AudioBookmark bookmark) async {
    final trackIndex =
        _tracks.indexWhere((track) => track.path == bookmark.audioPath);
    if (trackIndex < 0) {
      _showMessage('فایل صوتی این نشانک در کتابخانه موجود نیست.');
      return;
    }

    try {
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      final position = Duration(milliseconds: bookmark.positionMs);
      await _player.seek(position, index: trackIndex);
      await _player.play();
    } catch (error) {
      _showMessage('پخش از نشانک ممکن نشد: $error');
    }
  }

  Widget _buildBookmarksTab(ColorScheme colors) {
    final track = _currentTrack;
    final trackBookmarks = track == null
        ? const <AudioBookmark>[]
        : _bookmarks
            .where((bookmark) => bookmark.audioPath == track.path)
            .toList();

    if (track == null) {
      return const Center(
        child: Text(
          'برای مشاهده نشانک‌ها، ابتدا یک فایل صوتی انتخاب کن.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (trackBookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'برای «${track.title}» هنوز نشانکی ثبت نشده است. هنگام پخش این فایل، دکمه نشانک را لمس کن.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      key: ValueKey('bookmarks-${track.path}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: trackBookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final bookmark = trackBookmarks[index];
        final createdAt = bookmark.createdAt;
        final dateLabel =
            '${createdAt.year}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.day.toString().padLeft(2, '0')}  '
            '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(
              bookmark.isTopicRange
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_rounded,
              color: colors.primary,
            ),
            title: Text(
              bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '${bookmark.isTopicRange ? 'موضوع' : 'نشانک معمولی'}  •  ${bookmark.topic.isEmpty ? 'بدون موضوع' : bookmark.topic}  •  ${_formatDuration(Duration(milliseconds: bookmark.positionMs))}${bookmark.isTopicRange && bookmark.endPositionMs != null ? ' تا ${_formatDuration(Duration(milliseconds: bookmark.endPositionMs!))}' : ''}  •  $dateLabel',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'مدیریت نشانک',
              onSelected: (value) {
                if (value == 'edit') _editBookmark(bookmark);
                if (value == 'delete') _deleteBookmark(bookmark);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('ویرایش عنوان و موضوع')),
                PopupMenuItem(value: 'delete', child: Text('حذف نشانک')),
              ],
            ),
            onTap: () => _playBookmark(bookmark),
          ),
        );
      },
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ساخت پلی‌لیست جدید'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(
            labelText: 'نام پلی‌لیست',
            hintText: 'مثلاً موسیقی آرامش‌بخش',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ساختن'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final playlist = AudioPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      trackPaths: const [],
    );
    setState(() {
      _playlists.add(playlist);
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
  }

  Future<void> _addCurrentTrackToPlaylist(AudioPlaylist playlist) async {
    final track = _currentTrack;
    if (track == null) return;
    if (playlist.trackPaths.contains(track.path)) {
      _showMessage('این فایل از قبل در پلی‌لیست «${playlist.name}» وجود دارد.');
      return;
    }
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: [...playlist.trackPaths, track.path],
      );
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
    _showMessage('«${track.title}» به پلی‌لیست «${playlist.name}» اضافه شد.');
  }

  Future<void> _removeFromPlaylist(AudioPlaylist playlist, String path) async {
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((item) => item != path).toList(),
      );
    });
    await _store.savePlaylists(_playlists);
  }

  bool get _currentTrackIsFavorite {
    final track = _currentTrack;
    if (track == null) return false;
    final index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    return index >= 0 && _playlists[index].trackPaths.contains(track.path);
  }

  Future<void> _toggleCurrentTrackFavorite() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }
    var index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    if (index < 0) {
      _playlists.add(const AudioPlaylist(
        id: _favoritesPlaylistId,
        name: _favoritesPlaylistName,
        trackPaths: [],
      ));
      index = _playlists.length - 1;
    }
    final favorites = _playlists[index];
    final isFavorite = favorites.trackPaths.contains(track.path);
    setState(() {
      _playlists[index] = favorites.copyWith(
        trackPaths: isFavorite
            ? favorites.trackPaths.where((path) => path != track.path).toList()
            : [...favorites.trackPaths, track.path],
      );
      _expandedPlaylistId = _favoritesPlaylistId;
    });
    await _store.savePlaylists(_playlists);
    _showMessage(isFavorite
        ? '«${track.title}» از علاقه‌مندی‌ها حذف شد.'
        : '«${track.title}» به علاقه‌مندی‌ها اضافه شد.');
  }

  Future<void> _deletePlaylist(AudioPlaylist playlist) async {
    if (playlist.id == _favoritesPlaylistId) {
      _showMessage('پلی‌لیست علاقه‌مندی‌ها قابل حذف نیست.');
      return;
    }
    setState(() => _playlists.removeWhere((item) => item.id == playlist.id));
    await _store.savePlaylists(_playlists);
  }

  Widget _buildPlaylistsTab(ColorScheme colors) {
    final current = _currentTrack;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: IconButton.filled(
              tooltip: 'پلی‌لیست جدید',
              onPressed: _createPlaylist,
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? const SizedBox.shrink()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    final expanded = _expandedPlaylistId == playlist.id;
                    final tracks = playlist.trackPaths
                        .map((path) => _tracks.where((track) => track.path == path))
                        .where((matches) => matches.isNotEmpty)
                        .map((matches) => matches.first)
                        .toList();
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: PageStorageKey(playlist.id),
                        initiallyExpanded: expanded,
                        onExpansionChanged: (value) => setState(() {
                          _expandedPlaylistId = value ? playlist.id : null;
                        }),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        children: [
                          if (current != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _addCurrentTrackToPlaylist(playlist),
                                  child: const Text('افزودن آهنگ در حال پخش'),
                                ),
                              ),
                            ),
                          if (playlist.id != _favoritesPlaylistId)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _deletePlaylist(playlist),
                                  child: const Text('حذف پلی‌لیست'),
                                ),
                              ),
                            ),
                          if (tracks.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('این پلی‌لیست هنوز خالی است.'),
                            )
                          else
                            ...tracks.map((track) => ListTile(
                                  dense: true,
                                  title: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final trackIndex = _tracks.indexOf(track);
                                    if (trackIndex >= 0) _playTrack(trackIndex);
                                  },
                                  trailing: TextButton(
                                    onPressed: () => _removeFromPlaylist(
                                      playlist,
                                      track.path,
                                    ),
                                    child: const Text('حذف'),
                                  ),
                                )),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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

  Future<DateTime?> _chooseScheduleDateTime(String title) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: title,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      helpText: 'ساعت اجرا',
    );
    if (time == null) return null;
    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!scheduled.isAfter(DateTime.now())) {
      _showMessage('زمان انتخاب‌شده باید در آینده باشد.');
      return null;
    }
    return scheduled;
  }

  Future<void> _scheduleStartDialog() async {
    if (_tracks.isEmpty) {
      _showMessage('ابتدا یک فایل صوتی به کتابخانه اضافه کن.');
      return;
    }
    String selectedPath = _currentTrack?.path ?? _tracks.first.path;
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('شروع خودکار پخش'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedPath,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'فایل صوتی'),
            items: _tracks.map((track) => DropdownMenuItem<String>(
              value: track.path,
              child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selectedPath = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selectedPath),
              child: const Text('انتخاب زمان'),
            ),
          ],
        ),
      ),
    );
    if (path == null || !mounted) return;
    final at = await _chooseScheduleDateTime('تاریخ شروع پخش');
    if (at == null) return;
    final track = _tracks.firstWhere((item) => item.path == path);
    try {
      await ScheduledPlaybackService.scheduleStart(path: track.path, title: track.title, at: at);
      _showMessage('شروع پخش «${track.title}» برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم شروع خودکار ناموفق بود: $error');
    }
  }

  Future<void> _scheduleStopDialog() async {
    final at = await _chooseScheduleDateTime('تاریخ توقف پخش');
    if (at == null) return;
    try {
      await ScheduledPlaybackService.scheduleStop(at: at);
      _showMessage('توقف پخش برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم توقف خودکار ناموفق بود: $error');
    }
  }

  String _formatScheduleDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.year % 100)}/${two(value.month)}/${two(value.day)} - ${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _cancelScheduledStart() async {
    try {
      await ScheduledPlaybackService.cancelStart();
      _showMessage('شروع خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان شروع ناموفق بود: $error');
    }
  }

  Future<void> _cancelScheduledStop() async {
    try {
      await ScheduledPlaybackService.cancelStop();
      _showMessage('توقف خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان توقف ناموفق بود: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _messageTimer?.cancel();
    final generation = ++_messageGeneration;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          leading: const Icon(Icons.info_outline_rounded),
          content: Dismissible(
            key: ValueKey('app-message-$generation'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _messageTimer?.cancel();
              messenger.hideCurrentMaterialBanner();
            },
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(message),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'بستن پیام',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _messageTimer?.cancel();
                messenger.hideCurrentMaterialBanner();
              },
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || generation != _messageGeneration) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  @override
  void dispose() {
    _lyricsHoldTimer?.cancel();
    _themeHoldTimer?.cancel();
    _messageTimer?.cancel();
    _smartTopicMarqueeController.dispose();
    _tabController.dispose();
    _player.dispose();
    unawaited(_smartPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
        body: Column(
          children: [
            _buildPlayerToolbar(colors),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLyricsTab(colors),
                  _buildBookmarksTab(colors),
                  _buildPlaylistsTab(colors),
                  _buildLibraryTab(colors),
                  _buildSmartTab(colors),
                ],
              ),
            ),
            _buildBottomNavigation(colors),
            _buildPlayerPanel(colors),
          ],
        ),
      );
  }

  Widget _buildBottomNavigation(ColorScheme colors) {
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: false,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                labelPadding: EdgeInsets.zero,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.notes_rounded, size: 26)),
                    ),
                    text: 'متن',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.bookmarks_outlined, size: 26)),
                    ),
                    text: 'نشانک',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.queue_music_rounded, size: 26)),
                    ),
                    text: 'پلی‌لیست',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.library_music_outlined, size: 26)),
                    ),
                    text: 'کتابخانه',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.psychology_rounded, size: 26)),
                    ),
                    text: 'بخش هوشمند',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartTab(ColorScheme colors) {
    final topics = _availableSmartTopics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartTopicMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'انتخاب موضوع',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'manual',
                    child: Text('انتخاب موضوع توسط من', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('انتخاب موضوع تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartTopicMode = value);
                  await _saveSmartSettings();
                  if (value == 'manual' && topics.isNotEmpty && mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('انتخاب موضوع'),
                        content: SizedBox(
                          width: 320,
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final topic in topics)
                                ListTile(
                                  title: Text(topic),
                                  trailing: _selectedSmartTopic == topic
                                      ? const Icon(Icons.check_rounded)
                                      : null,
                                  onTap: () async {
                                    setState(() => _selectedSmartTopic = topic);
                                    await _saveSmartSettings();
                                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartOrderMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'ترتیب پخش نشانک‌ها',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'sequential',
                    child: Text('به ترتیب ثبت', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('به‌صورت تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartOrderMode = value);
                  await _saveSmartSettings();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          textDirection: TextDirection.rtl,
          children: [
            const Text(
              'موضوع در حال پخش:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final topicText = _activeSmartTopic ?? '—';
                  final textPainter = TextPainter(
                    text: TextSpan(
                      text: topicText,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                  )..layout();
                  final textWidth = textPainter.width;
                  final viewportWidth = constraints.maxWidth;
                  if (textWidth <= viewportWidth) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        topicText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  return ClipRect(
                    child: SizedBox(
                      height: 22,
                      child: AnimatedBuilder(
                        animation: _smartTopicMarqueeController,
                        builder: (context, child) {
                          final travel = viewportWidth + textWidth;
                          final offset = viewportWidth -
                              (_smartTopicMarqueeController.value * travel);
                          return Transform.translate(
                            offset: Offset(offset, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: textWidth,
                          child: Text(
                            topicText,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: topics.isEmpty ? null : _toggleSmartPlayback,
                icon: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                label: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Text(
                    snapshot.data == true ? 'مکث' : 'شروع پخش هوشمند',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'توقف پخش هوشمند',
              onPressed: _stopSmartPlayback,
              icon: const Icon(Icons.stop_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'تنظیم صدای پلیر موضوعی',
              onPressed: () => setState(
                () => _showSmartVolumeSlider = !_showSmartVolumeSlider,
              ),
              icon: Icon(
                _smartVolume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
        if (_showSmartVolumeSlider)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 8, top: 2),
            child: Row(
              children: [
                const Icon(Icons.volume_down_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: _smartVolume,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    label: '${(_smartVolume * 100).round()}٪',
                    onChanged: (value) {
                      setState(() => _smartVolume = value);
                      unawaited(_smartPlayer.setVolume(value));
                    },
                    onChangeEnd: (value) async {
                      await _setSmartPlayerVolume(value);
                      if (mounted) setState(() => _showSmartVolumeSlider = false);
                    },
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(_smartVolume * 100).round()}٪',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_smartQueueBookmarks.isNotEmpty)
          StreamBuilder<int?>(
            stream: _smartPlayer.currentIndexStream,
            initialData: _smartPlayer.currentIndex,
            builder: (context, snapshot) {
              final activeIndex = snapshot.data ?? -1;
              return Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  itemCount: _smartQueueBookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _smartQueueBookmarks[index];
                    final isActive = index == activeIndex;
                    final endMs = bookmark.endPositionMs ?? bookmark.positionMs;
                    final duration = Duration(
                      milliseconds: (endMs - bookmark.positionMs).clamp(0, 1 << 31).toInt(),
                    );
                    return Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: isActive
                          ? colors.primary.withValues(alpha: 0.10)
                          : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text(
                              _formatDuration(duration),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isActive ? colors.primary : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            isActive ? Icons.graphic_eq_rounded : Icons.bookmark_outline_rounded,
                            size: 17,
                            color: isActive ? colors.primary : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  bookmark.audioTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  bookmark.topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? colors.primary : colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isActive)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 6),
                              child: Text(
                                'در حال پخش',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          )
        else if (topics.isEmpty)
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded, size: 20),
            title: Text('هنوز موضوعی ثبت نشده است.', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              'در نوار پخش، با دکمه نشانک موضوعی ابتدا و انتهای هر موضوع را ثبت کن.',
              style: TextStyle(fontSize: 11),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'برای نمایش فهرست، پخش یک موضوع را شروع کن.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 12),
        StreamBuilder<Duration>(
          stream: _smartPlayer.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            return StreamBuilder<Duration?>(
              stream: _smartPlayer.durationStream,
              builder: (context, durationSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = durationSnapshot.data ?? Duration.zero;
                final max = duration.inMilliseconds.toDouble();
                return Column(
                  children: [
                    LinearProgressIndicator(
                      value: max <= 0
                          ? 0
                          : (position.inMilliseconds / max).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position)),
                        Text(_formatDuration(duration)),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  void _onThemeButtonDown(PointerDownEvent event) {
    _themeLongPressTriggered = false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _themeLongPressTriggered = true;
      _showPresetThemePicker();
    });
  }

  void _onThemeButtonUp(PointerUpEvent event) {
    final wasLongPress = _themeLongPressTriggered;
    final wasShortPress = _themeHoldTimer?.isActive ?? false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
    if (!wasLongPress && wasShortPress) widget.onToggleTheme();
  }

  void _onThemeButtonCancel(PointerCancelEvent event) {
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
  }

  Future<void> _showPresetThemePicker() async {
    const themes = <({String id, String name, Color color, String description})>[
      (id: 'teal', name: 'فیروزه‌ای', color: Color(0xFF16A6A0), description: 'تم پیش‌فرض فعلی'),
      (id: 'blue', name: 'آبی اقیانوسی', color: Color(0xFF2878D0), description: 'آرام و خنک'),
      (id: 'purple', name: 'بنفش', color: Color(0xFF8764D8), description: 'بنفش مدرن'),
      (id: 'green', name: 'سبز جنگلی', color: Color(0xFF39865A), description: 'طبیعی و ملایم'),
      (id: 'amber', name: 'کهربایی', color: Color(0xFFD28A22), description: 'گرم و پرانرژی'),
      (id: 'rose', name: 'رز', color: Color(0xFFC65D78), description: 'صورتی متمایل به رز'),
      (id: 'slate', name: 'خاکستری', color: Color(0xFF718096), description: 'خنثی و مینیمال'),
    ];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('انتخاب تم برنامه'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'حالت فعلی: ${widget.isDark ? 'شب' : 'روز'}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ),
              for (final theme in themes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: theme.color,
                  ),
                  title: Text(theme.name),
                  subtitle: Text(theme.description),
                  trailing: widget.themeId == theme.id
                      ? const Icon(Icons.check_circle_rounded)
                      : null,
                  onTap: () {
                    widget.onSelectTheme(theme.id);
                    Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerToolbar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              PopupMenuButton<String>(
                tooltip: 'پشتیبان‌گیری و بازیابی',
                icon: const Icon(Icons.backup_outlined, size: 24),
                onSelected: (value) {
                  if (value == 'backup') _createBackup();
                  if (value == 'restore') _restoreBackup();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'backup',
                    child: Row(
                      children: [
                        Icon(Icons.save_alt_rounded),
                        SizedBox(width: 12),
                        Text('تهیه نسخه پشتیبان'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.settings_backup_restore_rounded),
                        SizedBox(width: 12),
                        Text('بازیابی نسخه پشتیبان'),
                      ],
                    ),
                  ),
                ],
              ),
              Tooltip(
                message: 'لمس کوتاه: تغییر شب و روز • نگه‌داشتن ۳ ثانیه: انتخاب تم',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onThemeButtonDown,
                  onPointerUp: _onThemeButtonUp,
                  onPointerCancel: _onThemeButtonCancel,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        widget.isDark ? Icons.light_mode : Icons.dark_mode,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'شروع و پایان خودکار',
                icon: const Icon(Icons.schedule_rounded, size: 24),
                onSelected: (value) {
                  if (value == 'start') _scheduleStartDialog();
                  if (value == 'stop') _scheduleStopDialog();
                  if (value == 'cancel_start') _cancelScheduledStart();
                  if (value == 'cancel_stop') _cancelScheduledStop();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'start', child: Text('تنظیم شروع خودکار')),
                  PopupMenuItem(value: 'stop', child: Text('تنظیم توقف خودکار')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'cancel_start', child: Text('لغو شروع خودکار')),
                  PopupMenuItem(value: 'cancel_stop', child: Text('لغو توقف خودکار')),
                ],
              ),
              IconButton(
                tooltip: 'نقشه تغییرات صدا',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                onPressed: _openVolumeAutomation,
                icon: const Icon(Icons.multiline_chart_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    final hasLibraryItems = _libraryFolders.isNotEmpty || _tracks.isNotEmpty;
    final actions = Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'انتخاب فایل صوتی',
          onPressed: _pickAudio,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.audio_file_rounded, size: 20),
        ),
        const SizedBox(width: 3),
        IconButton.filledTonal(
          tooltip: 'انتخاب پوشه',
          onPressed: _openFolderManager,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.create_new_folder_outlined, size: 20),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final folder in _libraryFolders)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_rounded, size: 18, color: colors.primary),
                        const SizedBox(width: 4),
                        Text(
                          folder['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (!hasLibraryItems) {
      return Center(child: actions);
    }

    final itemCount = _tracks.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: actions,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: itemCount,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            itemBuilder: (context, index) {
              final trackIndex = index;
              final track = _tracks[trackIndex];
              final isCurrent = _currentIndex == trackIndex;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                minVerticalPadding: 0,
                minTileHeight: 30,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                tileColor: isCurrent
                    ? colors.primary.withValues(alpha: 0.10)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: _MarqueeText(
                  text: track.title,
                  style: const TextStyle(fontSize: 14),
                  gap: 28,
                ),
                onTap: () => _playTrack(trackIndex),
                trailing: PopupMenuButton<String>(
                  tooltip: 'گزینه‌های فایل صوتی',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  iconSize: 17,
                  onSelected: (action) {
                    if (action == 'rename') {
                      _renameTrack(trackIndex);
                    } else if (action == 'delete') {
                      _confirmRemoveTrack(trackIndex);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'rename',
                      height: 40,
                      child: Text('ویرایش نام'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      height: 40,
                      child: Text('حذف از کتابخانه'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onLyricsPointerDown(PointerDownEvent event) {
    _lyricsHoldTimer?.cancel();
    _lyricsHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _lyricsEditing = true);
    });
  }

  void _onLyricsPointerEnd(PointerEvent event) {
    _lyricsHoldTimer?.cancel();
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
              Icon(Icons.edit_note, size: 44, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'متن صدا ...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    if (_lyricsEditing) {
      return _LyricsEditor(
        key: ValueKey('edit-${track.path}'),
        track: track,
        initialText: _lyrics[track.path] ?? '',
        onSave: (value) => _saveLyrics(track.path, value),
        onSaveComplete: () {
          if (mounted) setState(() => _lyricsEditing = false);
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Expanded(
            child: Listener(
              onPointerDown: _onLyricsPointerDown,
              onPointerUp: _onLyricsPointerEnd,
              onPointerCancel: _onLyricsPointerEnd,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    (_lyrics[track.path] ?? '').trim().isEmpty
                        ? 'متن صدا ...'
                        : _lyrics[track.path]!,
                    textDirection: TextDirection.rtl,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await _store.saveLyrics(_lyrics);
                  _showMessage('متن ویس ذخیره شد.');
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded, color: colors.primary, size: 21),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _MarqueeText(
                            text: track?.title ?? 'فایلی برای پخش انتخاب نشده',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'در حال پخش',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'ثبت نشانک در زمان فعلی',
                        onPressed: track == null ? null : _addBookmark,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: _pendingTopicStartMs == null
                            ? 'ثبت شروع موضوع'
                            : 'ثبت پایان موضوع (${_formatDuration(Duration(milliseconds: _pendingTopicStartMs!))})',
                        onPressed: track == null ? null : _toggleTopicRangeBookmark,
                        color: _pendingTopicStartMs == null ? null : colors.primary,
                        icon: Icon(
                          _pendingTopicStartMs == null
                              ? Icons.bookmark_add_rounded
                              : Icons.bookmark_added_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: _currentTrack == null
                            ? 'علاقه‌مندی‌ها (ابتدا یک فایل پخش کن)'
                            : _currentTrackIsFavorite
                                ? 'حذف از علاقه‌مندی‌ها'
                                : 'افزودن به علاقه‌مندی‌ها',
                        onPressed: _toggleCurrentTrackFavorite,
                        icon: Icon(
                          _currentTrackIsFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: _currentTrackIsFavorite
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: 'شروع پخش هوشمند',
                        onPressed: _toggleSmartPlayback,
                        icon: const Icon(Icons.auto_awesome_rounded),
                      ),
                      IconButton(
                        tooltip: 'تنظیم صدای پلیر',
                        onPressed: _showVolumeSettings,
                        icon: Icon(
                          _volume == 0
                              ? Icons.volume_off_rounded
                              : _volume < 0.5
                                  ? Icons.volume_down_rounded
                                  : Icons.volume_up_rounded,
                          color: colors.primary,
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
                  final trackRanges = _bookmarks
                      .where((bookmark) =>
                          bookmark.isTopicRange &&
                          bookmark.audioPath == track?.path &&
                          bookmark.endPositionMs != null &&
                          bookmark.endPositionMs! > bookmark.positionMs)
                      .toList();
                  return Column(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final usableWidth =
                              (constraints.maxWidth - 32).clamp(0.0, double.infinity).toDouble();
                          return Stack(
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
                              if (max > 0)
                                ...trackRanges.expand((bookmark) {
                                  final startFraction =
                                      (bookmark.positionMs / max).clamp(0.0, 1.0).toDouble();
                                  final endFraction =
                                      (bookmark.endPositionMs! / max).clamp(0.0, 1.0).toDouble();
                                  return <Widget>[
                                    PositionedDirectional(
                                      start: 16 + usableWidth * startFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.tertiary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                    PositionedDirectional(
                                      start: 16 + usableWidth * endFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                  ];
                                }),
                            ],
                          );
                        },
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
                    icon: const Icon(Icons.shuffle, size: 27),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه عقب',
                    onPressed: track == null ? null : () => _seekRelative(-15),
                    icon: const Icon(Icons.replay_10, size: 27),
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
                    icon: const Icon(Icons.skip_previous_rounded, size: 32),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      final processing = snapshot.data?.processingState;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return SizedBox(
                        width: 60,
                        height: 60,
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
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  size: 34,
                                ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'بعدی',
                    onPressed: track == null ? null : _player.seekToNext,
                    icon: const Icon(Icons.skip_next_rounded, size: 32),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه جلو',
                    onPressed: track == null ? null : () => _seekRelative(15),
                    icon: const Icon(Icons.forward_10, size: 27),
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
                      size: 27,
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
    required this.onSaveComplete,
  });

  final AudioTrack track;
  final String initialText;
  final Future<void> Function(String value) onSave;
  final VoidCallback onSaveComplete;

  @override
  State<_LyricsEditor> createState() => _LyricsEditorState();
}

class _LyricsEditorState extends State<_LyricsEditor> {
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  final FocusNode _lyricsFocusNode = FocusNode();
  Timer? _saveTimer;
  bool _saving = false;
  bool _saved = true;
  bool _hasSearched = false;
  List<int> _matches = [];
  int _activeMatch = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _searchController = TextEditingController();
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
    if (_matches.isNotEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
        _hasSearched = false;
      });
    }
  }

  void _findMatches({bool preservePosition = false}) {
    final query = _searchController.text;
    final text = _controller.text;
    _hasSearched = true;
    if (query.isEmpty || text.isEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
      });
      return;
    }

    final source = text.toLowerCase();
    final needle = query.toLowerCase();
    final found = <int>[];
    var offset = 0;
    while (offset <= source.length - needle.length) {
      final index = source.indexOf(needle, offset);
      if (index < 0) break;
      found.add(index);
      offset = index + needle.length;
    }

    final previousStart = preservePosition && _activeMatch >= 0 &&
            _activeMatch < _matches.length
        ? _matches[_activeMatch]
        : -1;
    var nextActive = found.isEmpty ? -1 : 0;
    if (previousStart >= 0 && found.isNotEmpty) {
      final sameIndex = found.indexOf(previousStart);
      if (sameIndex >= 0) nextActive = sameIndex;
    }
    setState(() {
      _matches = found;
      _activeMatch = nextActive;
    });
    if (found.isNotEmpty) _selectMatch(nextActive);
  }

  void _selectMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final start = _matches[index];
    final end = start + _searchController.text.length;
    _lyricsFocusNode.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    setState(() => _activeMatch = index);
  }

  void _moveMatch(int step) {
    if (_matches.isEmpty) return;
    final next = (_activeMatch + step + _matches.length) % _matches.length;
    _selectMatch(next);
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
    _searchController.dispose();
    _lyricsFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasMatches = _matches.isNotEmpty;
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textDirection: TextDirection.rtl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _findMatches(),
                  onChanged: (_) {
                    setState(() {
                      _matches = [];
                      _activeMatch = -1;
                      _hasSearched = false;
                    });
                  },
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'جست‌وجو در متن همین ویس...',
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    suffixIcon: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      tooltip: 'جست‌وجو',
                      onPressed: _findMatches,
                      icon: const Icon(Icons.search_rounded, size: 17),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه قبلی',
                onPressed: hasMatches ? () => _moveMatch(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ),
              const SizedBox(width: 3),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه بعدی',
                onPressed: hasMatches ? () => _moveMatch(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _searchController.text.isEmpty
                  ? 'جست‌وجو فقط در متن فایل انتخاب‌شده انجام می‌شود.'
                  : hasMatches
                      ? 'نتیجه ${_activeMatch + 1} از ${_matches.length}'
                      : _hasSearched
                          ? 'کلمه‌ای با این عبارت پیدا نشد.'
                          : 'برای شروع، دکمه جست‌وجو را بزن.',
              style: TextStyle(
                fontSize: 11,
                color: hasMatches ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _lyricsFocusNode,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textDirection: TextDirection.rtl,
              onChanged: _scheduleSave,
              style: const TextStyle(fontSize: 14),
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
                onPressed: _saving
                    ? null
                    : () async {
                        _saveTimer?.cancel();
                        await _save(_controller.text);
                        if (mounted) widget.onSaveComplete();
                      },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('ذخیره', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    this.gap = 36,
  });

  final String text;
  final TextStyle style;
  final double gap;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller.stop();
      _controller.value = 0;
      _started = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout();
        final textWidth = painter.width;
        final availableWidth = constraints.maxWidth;

        if (textWidth <= availableWidth || availableWidth <= 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: widget.style,
            ),
          );
        }

        final distance = textWidth + widget.gap;
        if (!_started) {
          _started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final milliseconds =
                (distance / 32 * 1000).round().clamp(1800, 20000).toInt();
            _controller.duration = Duration(milliseconds: milliseconds);
            _controller.repeat();
          });
        }

        return ClipRect(
          child: SizedBox(
            height: painter.height,
            width: availableWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(-distance * _controller.value, 0),
                child: child,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                  SizedBox(width: widget.gap),
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
), ''),
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

  Future<void> _openFolderManager() async {
    final folders = await _store.loadFolders();
    if (!mounted) return;
    final selected = folders.map((folder) => Map<String, String>.from(folder)).toList();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('پوشه‌های کتابخانه'),
          content: SizedBox(
            width: double.maxFinite,
            height: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text('هنوز پوشه‌ای انتخاب نشده است.'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: selected.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          selected[index]['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'حذف پوشه',
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(
                            () => selected.removeAt(index),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final folder = await _folderService.pickFolder();
                      if (folder == null) return;
                      if (selected.any((item) => item['uri'] == folder['uri'])) return;
                      setDialogState(() => selected.add(folder));
                    } catch (error) {
                      if (mounted) _showMessage('انتخاب پوشه ناموفق بود: $error');
                    }
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('افزودن پوشه'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final result = selected
                          .map((folder) => Map<String, String>.from(folder))
                          .toList();
                      Navigator.pop(dialogContext);
                      unawaited(_scanSelectedFolders(result));
                    },
              icon: const Icon(Icons.sync),
              label: const Text('شروع اسکن'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanSelectedFolders(List<Map<String, String>> folders) async {
    try {
      await _store.saveFolders(folders);
      if (mounted) {
        setState(() {
          _libraryFolders
            ..clear()
            ..addAll(folders.map((folder) => Map<String, String>.from(folder)));
        });
      }
      _showMessage('در حال اسکن پوشه‌ها...');
      final found = await _folderService.scanFolders(
        folders.map((folder) => folder['uri']!).toList(),
      );
      final existing = _tracks.map((track) => track.path).toSet();
      final added = <AudioTrack>[];
      var duplicates = 0;
      for (final item in found) {
        final uri = item['uri']!;
        if (!existing.add(uri)) {
          duplicates++;
          continue;
        }
        final name = item['name']!;
        final dotIndex = name.lastIndexOf('.');
        final title = dotIndex > 0 ? name.substring(0, dotIndex) : name;
        added.add(AudioTrack(path: uri, title: title));
      }
      if (added.isNotEmpty) {
        setState(() => _tracks.addAll(added));
        await _persistTracks();
        await _replacePlaylist(autoplay: false);
      }
      _showMessage(
        'اسکن تمام شد: ${added.length} فایل جدید، '
        '$duplicates فایل تکراری از ${found.length} فایل شناسایی‌شده.',
      );
    } catch (error) {
      _showMessage('اسکن پوشه‌ها ناموفق بود: $error');
    }
  }

  Future<void> _applyEffectiveVolume({Duration? position}) async {
    final positionMs = (position ?? _player.position).inMilliseconds;
    final trackPath = _currentTrack?.path;
    final ranges = trackPath == null
        ? const <VolumeRange>[]
        : (_volumeRangesByTrack[base64Url.encode(utf8.encode(trackPath))] ??
            const <VolumeRange>[]);
    final effective = scheduledVolumeAt(ranges, positionMs, _volume);
    if (_lastAppliedVolume != null &&
        (effective - _lastAppliedVolume!).abs() < 0.0001) {
      return;
    }
    _lastAppliedVolume = effective;
    await _player.setVolume(effective);
  }

  Future<void> _setPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _volume = normalized);
    _lastAppliedVolume = null;
    await _applyEffectiveVolume();
    await _store.saveVolume(normalized);
  }

  Future<void> _openVolumeAutomation() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را انتخاب کن.');
      return;
    }
    final trackKey = base64Url.encode(utf8.encode(track.path));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VolumeAutomationScreen(
          initialRanges: List<VolumeRange>.from(
            _volumeRangesByTrack[trackKey] ?? const <VolumeRange>[],
          ),
          onSave: (ranges) async {
            final preferences = await SharedPreferences.getInstance();
            final key = 'volume_ranges_v1_$trackKey';
            await preferences.setString(
              key,
              jsonEncode(ranges.map((range) => range.toMap()).toList()),
            );
            if (!mounted) return;
            setState(() {
              _volumeRangesByTrack[trackKey] = List<VolumeRange>.from(ranges)
                ..sort((a, b) => a.startMs.compareTo(b.startMs));
              _lastAppliedVolume = null;
            });
            await _applyEffectiveVolume();
          },
        ),
      ),
    );
  }

  Future<void> _showVolumeSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('صدای خروجی پلیر')),
                  Text('${(_volume * 100).round()}%'),
                ],
              ),
              Slider(
                value: _volume,
                min: 0,
                max: 1,
                divisions: 100,
                label: '${(_volume * 100).round()}%',
                onChanged: (value) {
                  setSheetState(() {});
                  _setPlayerVolume(value);
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => _setPlayerVolume(0),
                    child: const Text('بی‌صدا'),
                  ),
                  TextButton(
                    onPressed: () => _setPlayerVolume(1),
                    child: const Text('صدای کامل'),
                  ),
                ],
              ),
              Text(
                'این تنظیم فقط بلندی صدای همین پلیر را تغییر می‌دهد و صدای کلی گوشی را تنظیم نمی‌کند.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _replacePlaylist({required bool autoplay}) async {
    if (_tracks.isEmpty) {
      await _player.stop();
      return;
    }
    final oldIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _tracks.length - 1).toInt();
    final sources = _tracks.map((track) {
      final uri = Uri.parse(track.path);
      return AudioSource.uri(
        uri.scheme == 'content' ? uri : Uri.file(track.path),
      );
    }).toList();
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

  Future<void> _confirmRemoveTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف از کتابخانه'),
        content: Text('«${track.title}» فقط از کتابخانهٔ برنامه حذف می‌شود و فایل اصلی در حافظه باقی می‌ماند. ادامه می‌دهی؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف از کتابخانه'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _removeTrack(index);
  }

  Future<void> _renameTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final controller = TextEditingController(text: track.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ویرایش نام فایل'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(labelText: 'نام جدید'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty || newTitle == track.title) return;
    if (_tracks.any((item) => item.path != track.path && item.title == newTitle)) {
      _showMessage('فایلی با این نام در کتابخانه وجود دارد.');
      return;
    }
    try {
      final renamed = await _folderService.renameItem(track.path, newTitle);
      final newPath = renamed['path'];
      if (newPath == null || newPath.isEmpty) {
        throw StateError('مسیر جدید فایل از سیستم دریافت نشد.');
      }
      final oldPath = track.path;
      final oldIndex = _tracks.indexWhere((item) => item.path == oldPath);
      if (oldIndex < 0) return;
      _tracks[oldIndex] = AudioTrack(path: newPath, title: newTitle);
      for (var i = 0; i < _bookmarks.length; i++) {
        final bookmark = _bookmarks[i];
        if (bookmark.audioPath != oldPath) continue;
        _bookmarks[i] = AudioBookmark(
          id: bookmark.id,
          audioPath: newPath,
          audioTitle: newTitle,
          positionMs: bookmark.positionMs,
          createdAt: bookmark.createdAt,
          title: bookmark.title,
          topic: bookmark.topic,
          endPositionMs: bookmark.endPositionMs,
          isTopicRange: bookmark.isTopicRange,
        );
      }
      for (var i = 0; i < _playlists.length; i++) {
        final playlist = _playlists[i];
        _playlists[i] = playlist.copyWith(
          trackPaths: playlist.trackPaths
              .map((path) => path == oldPath ? newPath : path)
              .toList(),
        );
      }
      final savedLyrics = _lyrics.remove(oldPath);
      if (savedLyrics != null) _lyrics[newPath] = savedLyrics;
      if (_pendingTopicAudioPath == oldPath) _pendingTopicAudioPath = newPath;
      await _persistTracks();
      await _store.saveBookmarks(_bookmarks);
      await _store.savePlaylists(_playlists);
      await _store.saveLyrics(_lyrics);
      await _replacePlaylist(autoplay: false);
      if (mounted) setState(() {});
      _showMessage('نام فایل در حافظه و کتابخانه تغییر کرد.');
    } catch (error) {
      _showMessage('تغییر نام فایل ناموفق بود: $error');
    }
  }

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _bookmarks.removeWhere((bookmark) => bookmark.audioPath == removed.path);
    if (_pendingTopicAudioPath == removed.path) {
      _pendingTopicStartMs = null;
      _pendingTopicAudioPath = null;
    }
    for (var i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      _playlists[i] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((path) => path != removed.path).toList(),
      );
    }
    await _store.savePlaylists(_playlists);
    await _store.saveBookmarks(_bookmarks);
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

  Future<void> _addBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }

    final position = _player.position;
    final details = await _showBookmarkDetailsDialog(
      initialTitle: track.title,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: position.inMilliseconds,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
      });
      _showMessage(
        'نشانک معمولی در ${_formatDuration(position)} ذخیره شد. این نشانک وارد پخش هوشمند نمی‌شود.',
      );
    } catch (error) {
      _showMessage('ذخیره نشانک ناموفق بود: $error');
    }
  }

  Future<void> _toggleTopicRangeBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای ثبت موضوع انتخاب کن.');
      return;
    }

    final startMs = _pendingTopicStartMs;
    if (startMs == null) {
      final positionMs = _player.position.inMilliseconds;
      setState(() {
        _pendingTopicStartMs = positionMs;
        _pendingTopicAudioPath = track.path;
      });
      _showMessage('شروع موضوع در ${_formatDuration(Duration(milliseconds: positionMs))} ثبت شد؛ برای ثبت پایان، دوباره همین دکمه را بزن.');
      return;
    }

    if (_pendingTopicAudioPath != track.path) {
      _showMessage('برای ثبت پایان، ابتدا به همان فایل صوتی که شروع موضوع را در آن ثبت کردی برگرد.');
      return;
    }

    final endMs = _player.position.inMilliseconds;
    if (endMs <= startMs) {
      _showMessage('زمان پایان باید بعد از زمان شروع باشد. نشانگر شروع حفظ شد؛ کمی جلوتر برو و دوباره بزن.');
      return;
    }

    final details = await _showBookmarkDetailsDialog(initialTitle: track.title);
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای نشانک موضوعی، نام موضوع را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: startMs,
      endPositionMs: endMs,
      isTopicRange: true,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
        _selectedSmartTopic ??= bookmark.topic;
        _pendingTopicStartMs = null;
        _pendingTopicAudioPath = null;
      });
      await _saveSmartSettings();
      _showMessage('بازه موضوع «${bookmark.topic}» از ${_formatDuration(Duration(milliseconds: startMs))} تا ${_formatDuration(Duration(milliseconds: endMs))} ذخیره شد.');
    } catch (error) {
      _showMessage('ذخیره بازه موضوع ناموفق بود: $error');
    }
  }

  List<String> get _availableSmartTopics {
    final topics = _bookmarks
        .where((bookmark) => bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs)
        .map((bookmark) => bookmark.topic.trim())
        .where((topic) => topic.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return topics;
  }

  Future<Map<String, String>?> _showBookmarkDetailsDialog({
    required String initialTitle,
    String initialTopic = '',
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final topicController = TextEditingController(text: initialTopic);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مشخصات نشانک'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'عنوان نشانک'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              textDirection: TextDirection.rtl,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'موضوع',
                hintText: 'مثلاً تمرکز',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'title': titleController.text.trim(),
              'topic': topicController.text.trim(),
            }),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    titleController.dispose();
    topicController.dispose();
    return result;
  }

  Future<void> _editBookmark(AudioBookmark bookmark) async {
    final details = await _showBookmarkDetailsDialog(
      initialTitle: bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
      initialTopic: bookmark.topic,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }
    final updated = _bookmarks
        .map((item) => item.id == bookmark.id
            ? AudioBookmark(
                id: item.id,
                audioPath: item.audioPath,
                audioTitle: item.audioTitle,
                positionMs: item.positionMs,
                endPositionMs: item.endPositionMs,
                isTopicRange: item.isTopicRange,
                createdAt: item.createdAt,
                title: details['title']!,
                topic: details['topic']!,
              )
            : item)
        .toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('ویرایش نشانک ذخیره نشد: $error');
    }
  }

  Future<void> _deleteBookmark(AudioBookmark bookmark) async {
    final updated = _bookmarks.where((item) => item.id != bookmark.id).toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('حذف نشانک ناموفق بود: $error');
    }
  }

  Future<void> _saveSmartSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('smart_topic_mode_v1', _smartTopicMode);
      await preferences.setString('smart_order_mode_v1', _smartOrderMode);
      if (_selectedSmartTopic == null) {
        await preferences.remove('smart_selected_topic_v1');
      } else {
        await preferences.setString('smart_selected_topic_v1', _selectedSmartTopic!);
      }
    } catch (error) {
      _showMessage('ذخیره تنظیمات پخش هوشمند ناموفق بود: $error');
    }
  }

  Future<void> _startSmartPlayback() async {
    final topics = _availableSmartTopics;
    if (topics.isEmpty) {
      _showMessage('ابتدا در تب نشانک‌ها برای نشانک‌ها موضوع تعیین کن.');
      _tabController.animateTo(1);
      return;
    }

    String topic;
    if (_smartTopicMode == 'random') {
      topic = topics[Random().nextInt(topics.length)];
    } else {
      final selected = _selectedSmartTopic;
      if (selected == null || !topics.contains(selected)) {
        _showMessage('ابتدا یک موضوع برای پخش هوشمند انتخاب کن.');
        _tabController.animateTo(4);
        return;
      }
      topic = selected;
    }

    final matching = _bookmarks
        .where((bookmark) =>
            bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs &&
            bookmark.topic.trim() == topic &&
            _tracks.any((track) => track.path == bookmark.audioPath))
        .toList();
    if (matching.isEmpty) {
      _showMessage('برای این موضوع نشانک قابل پخشی پیدا نشد.');
      return;
    }

    if (_smartOrderMode == 'random') {
      matching.shuffle(Random());
    } else {
      matching.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final sources = <AudioSource>[];
    for (final bookmark in matching) {
      final parsed = Uri.parse(bookmark.audioPath);
      final uri = parsed.scheme == 'content'
          ? parsed
          : Uri.file(bookmark.audioPath);
      sources.add(
        ClippingAudioSource(
          child: AudioSource.uri(uri),
          start: Duration(milliseconds: bookmark.positionMs),
          end: Duration(milliseconds: bookmark.endPositionMs!),
        ),
      );
    }

    try {
      await _player.pause();
      await _smartPlayer.stop();
      await _smartPlayer.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      if (!mounted) return;
      setState(() {
        _activeSmartTopic = topic;
        _smartQueueBookmarks
          ..clear()
          ..addAll(matching);
        _smartQueueReady = true;
      });
      await _smartPlayer.play();
    } catch (error) {
      if (mounted) {
        setState(() {
          _smartQueueReady = false;
          _smartQueueBookmarks.clear();
        });
        _showMessage('شروع پخش هوشمند ناموفق بود: $error');
      }
    }
  }

  Future<void> _setSmartPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _smartVolume = normalized);
    await _smartPlayer.setVolume(normalized);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('smart_topic_volume_v1', normalized);
  }

  Future<void> _toggleSmartPlayback() async {
    if (_smartPlayer.playing) {
      await _smartPlayer.pause();
      return;
    }
    if (_smartQueueReady &&
        _smartPlayer.processingState != ProcessingState.completed) {
      await _smartPlayer.play();
      return;
    }
    await _startSmartPlayback();
  }

  Future<void> _stopSmartPlayback() async {
    await _smartPlayer.stop();
    if (mounted) {
      setState(() {
        _smartQueueReady = false;
        _activeSmartTopic = null;
        _smartQueueBookmarks.clear();
      });
    }
  }

  Future<void> _playBookmark(AudioBookmark bookmark) async {
    final trackIndex =
        _tracks.indexWhere((track) => track.path == bookmark.audioPath);
    if (trackIndex < 0) {
      _showMessage('فایل صوتی این نشانک در کتابخانه موجود نیست.');
      return;
    }

    try {
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      final position = Duration(milliseconds: bookmark.positionMs);
      await _player.seek(position, index: trackIndex);
      await _player.play();
    } catch (error) {
      _showMessage('پخش از نشانک ممکن نشد: $error');
    }
  }

  Widget _buildBookmarksTab(ColorScheme colors) {
    final track = _currentTrack;
    final trackBookmarks = track == null
        ? const <AudioBookmark>[]
        : _bookmarks
            .where((bookmark) => bookmark.audioPath == track.path)
            .toList();

    if (track == null) {
      return const Center(
        child: Text(
          'برای مشاهده نشانک‌ها، ابتدا یک فایل صوتی انتخاب کن.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (trackBookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'برای «${track.title}» هنوز نشانکی ثبت نشده است. هنگام پخش این فایل، دکمه نشانک را لمس کن.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      key: ValueKey('bookmarks-${track.path}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: trackBookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final bookmark = trackBookmarks[index];
        final createdAt = bookmark.createdAt;
        final dateLabel =
            '${createdAt.year}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.day.toString().padLeft(2, '0')}  '
            '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(
              bookmark.isTopicRange
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_rounded,
              color: colors.primary,
            ),
            title: Text(
              bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '${bookmark.isTopicRange ? 'موضوع' : 'نشانک معمولی'}  •  ${bookmark.topic.isEmpty ? 'بدون موضوع' : bookmark.topic}  •  ${_formatDuration(Duration(milliseconds: bookmark.positionMs))}${bookmark.isTopicRange && bookmark.endPositionMs != null ? ' تا ${_formatDuration(Duration(milliseconds: bookmark.endPositionMs!))}' : ''}  •  $dateLabel',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'مدیریت نشانک',
              onSelected: (value) {
                if (value == 'edit') _editBookmark(bookmark);
                if (value == 'delete') _deleteBookmark(bookmark);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('ویرایش عنوان و موضوع')),
                PopupMenuItem(value: 'delete', child: Text('حذف نشانک')),
              ],
            ),
            onTap: () => _playBookmark(bookmark),
          ),
        );
      },
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ساخت پلی‌لیست جدید'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(
            labelText: 'نام پلی‌لیست',
            hintText: 'مثلاً موسیقی آرامش‌بخش',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ساختن'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final playlist = AudioPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      trackPaths: const [],
    );
    setState(() {
      _playlists.add(playlist);
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
  }

  Future<void> _addCurrentTrackToPlaylist(AudioPlaylist playlist) async {
    final track = _currentTrack;
    if (track == null) return;
    if (playlist.trackPaths.contains(track.path)) {
      _showMessage('این فایل از قبل در پلی‌لیست «${playlist.name}» وجود دارد.');
      return;
    }
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: [...playlist.trackPaths, track.path],
      );
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
    _showMessage('«${track.title}» به پلی‌لیست «${playlist.name}» اضافه شد.');
  }

  Future<void> _removeFromPlaylist(AudioPlaylist playlist, String path) async {
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((item) => item != path).toList(),
      );
    });
    await _store.savePlaylists(_playlists);
  }

  bool get _currentTrackIsFavorite {
    final track = _currentTrack;
    if (track == null) return false;
    final index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    return index >= 0 && _playlists[index].trackPaths.contains(track.path);
  }

  Future<void> _toggleCurrentTrackFavorite() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }
    var index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    if (index < 0) {
      _playlists.add(const AudioPlaylist(
        id: _favoritesPlaylistId,
        name: _favoritesPlaylistName,
        trackPaths: [],
      ));
      index = _playlists.length - 1;
    }
    final favorites = _playlists[index];
    final isFavorite = favorites.trackPaths.contains(track.path);
    setState(() {
      _playlists[index] = favorites.copyWith(
        trackPaths: isFavorite
            ? favorites.trackPaths.where((path) => path != track.path).toList()
            : [...favorites.trackPaths, track.path],
      );
      _expandedPlaylistId = _favoritesPlaylistId;
    });
    await _store.savePlaylists(_playlists);
    _showMessage(isFavorite
        ? '«${track.title}» از علاقه‌مندی‌ها حذف شد.'
        : '«${track.title}» به علاقه‌مندی‌ها اضافه شد.');
  }

  Future<void> _deletePlaylist(AudioPlaylist playlist) async {
    if (playlist.id == _favoritesPlaylistId) {
      _showMessage('پلی‌لیست علاقه‌مندی‌ها قابل حذف نیست.');
      return;
    }
    setState(() => _playlists.removeWhere((item) => item.id == playlist.id));
    await _store.savePlaylists(_playlists);
  }

  Widget _buildPlaylistsTab(ColorScheme colors) {
    final current = _currentTrack;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: IconButton.filled(
              tooltip: 'پلی‌لیست جدید',
              onPressed: _createPlaylist,
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? const SizedBox.shrink()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    final expanded = _expandedPlaylistId == playlist.id;
                    final tracks = playlist.trackPaths
                        .map((path) => _tracks.where((track) => track.path == path))
                        .where((matches) => matches.isNotEmpty)
                        .map((matches) => matches.first)
                        .toList();
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: PageStorageKey(playlist.id),
                        initiallyExpanded: expanded,
                        onExpansionChanged: (value) => setState(() {
                          _expandedPlaylistId = value ? playlist.id : null;
                        }),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        children: [
                          if (current != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _addCurrentTrackToPlaylist(playlist),
                                  child: const Text('افزودن آهنگ در حال پخش'),
                                ),
                              ),
                            ),
                          if (playlist.id != _favoritesPlaylistId)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _deletePlaylist(playlist),
                                  child: const Text('حذف پلی‌لیست'),
                                ),
                              ),
                            ),
                          if (tracks.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('این پلی‌لیست هنوز خالی است.'),
                            )
                          else
                            ...tracks.map((track) => ListTile(
                                  dense: true,
                                  title: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final trackIndex = _tracks.indexOf(track);
                                    if (trackIndex >= 0) _playTrack(trackIndex);
                                  },
                                  trailing: TextButton(
                                    onPressed: () => _removeFromPlaylist(
                                      playlist,
                                      track.path,
                                    ),
                                    child: const Text('حذف'),
                                  ),
                                )),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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

  Future<DateTime?> _chooseScheduleDateTime(String title) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: title,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      helpText: 'ساعت اجرا',
    );
    if (time == null) return null;
    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!scheduled.isAfter(DateTime.now())) {
      _showMessage('زمان انتخاب‌شده باید در آینده باشد.');
      return null;
    }
    return scheduled;
  }

  Future<void> _scheduleStartDialog() async {
    if (_tracks.isEmpty) {
      _showMessage('ابتدا یک فایل صوتی به کتابخانه اضافه کن.');
      return;
    }
    String selectedPath = _currentTrack?.path ?? _tracks.first.path;
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('شروع خودکار پخش'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedPath,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'فایل صوتی'),
            items: _tracks.map((track) => DropdownMenuItem<String>(
              value: track.path,
              child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selectedPath = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selectedPath),
              child: const Text('انتخاب زمان'),
            ),
          ],
        ),
      ),
    );
    if (path == null || !mounted) return;
    final at = await _chooseScheduleDateTime('تاریخ شروع پخش');
    if (at == null) return;
    final track = _tracks.firstWhere((item) => item.path == path);
    try {
      await ScheduledPlaybackService.scheduleStart(path: track.path, title: track.title, at: at);
      _showMessage('شروع پخش «${track.title}» برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم شروع خودکار ناموفق بود: $error');
    }
  }

  Future<void> _scheduleStopDialog() async {
    final at = await _chooseScheduleDateTime('تاریخ توقف پخش');
    if (at == null) return;
    try {
      await ScheduledPlaybackService.scheduleStop(at: at);
      _showMessage('توقف پخش برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم توقف خودکار ناموفق بود: $error');
    }
  }

  String _formatScheduleDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.year % 100)}/${two(value.month)}/${two(value.day)} - ${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _cancelScheduledStart() async {
    try {
      await ScheduledPlaybackService.cancelStart();
      _showMessage('شروع خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان شروع ناموفق بود: $error');
    }
  }

  Future<void> _cancelScheduledStop() async {
    try {
      await ScheduledPlaybackService.cancelStop();
      _showMessage('توقف خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان توقف ناموفق بود: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _messageTimer?.cancel();
    final generation = ++_messageGeneration;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          leading: const Icon(Icons.info_outline_rounded),
          content: Dismissible(
            key: ValueKey('app-message-$generation'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _messageTimer?.cancel();
              messenger.hideCurrentMaterialBanner();
            },
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(message),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'بستن پیام',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _messageTimer?.cancel();
                messenger.hideCurrentMaterialBanner();
              },
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || generation != _messageGeneration) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  @override
  void dispose() {
    _lyricsHoldTimer?.cancel();
    _themeHoldTimer?.cancel();
    _messageTimer?.cancel();
    _smartTopicMarqueeController.dispose();
    _tabController.dispose();
    _player.dispose();
    unawaited(_smartPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
        body: Column(
          children: [
            _buildPlayerToolbar(colors),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLyricsTab(colors),
                  _buildBookmarksTab(colors),
                  _buildPlaylistsTab(colors),
                  _buildLibraryTab(colors),
                  _buildSmartTab(colors),
                ],
              ),
            ),
            _buildBottomNavigation(colors),
            _buildPlayerPanel(colors),
          ],
        ),
      );
  }

  Widget _buildBottomNavigation(ColorScheme colors) {
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: false,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                labelPadding: EdgeInsets.zero,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.notes_rounded, size: 26)),
                    ),
                    text: 'متن',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.bookmarks_outlined, size: 26)),
                    ),
                    text: 'نشانک',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.queue_music_rounded, size: 26)),
                    ),
                    text: 'پلی‌لیست',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.library_music_outlined, size: 26)),
                    ),
                    text: 'کتابخانه',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.psychology_rounded, size: 26)),
                    ),
                    text: 'بخش هوشمند',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartTab(ColorScheme colors) {
    final topics = _availableSmartTopics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartTopicMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'انتخاب موضوع',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'manual',
                    child: Text('انتخاب موضوع توسط من', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('انتخاب موضوع تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartTopicMode = value);
                  await _saveSmartSettings();
                  if (value == 'manual' && topics.isNotEmpty && mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('انتخاب موضوع'),
                        content: SizedBox(
                          width: 320,
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final topic in topics)
                                ListTile(
                                  title: Text(topic),
                                  trailing: _selectedSmartTopic == topic
                                      ? const Icon(Icons.check_rounded)
                                      : null,
                                  onTap: () async {
                                    setState(() => _selectedSmartTopic = topic);
                                    await _saveSmartSettings();
                                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartOrderMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'ترتیب پخش نشانک‌ها',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'sequential',
                    child: Text('به ترتیب ثبت', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('به‌صورت تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartOrderMode = value);
                  await _saveSmartSettings();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          textDirection: TextDirection.rtl,
          children: [
            const Text(
              'موضوع در حال پخش:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final topicText = _activeSmartTopic ?? '—';
                  final textPainter = TextPainter(
                    text: TextSpan(
                      text: topicText,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                  )..layout();
                  final textWidth = textPainter.width;
                  final viewportWidth = constraints.maxWidth;
                  if (textWidth <= viewportWidth) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        topicText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  return ClipRect(
                    child: SizedBox(
                      height: 22,
                      child: AnimatedBuilder(
                        animation: _smartTopicMarqueeController,
                        builder: (context, child) {
                          final travel = viewportWidth + textWidth;
                          final offset = viewportWidth -
                              (_smartTopicMarqueeController.value * travel);
                          return Transform.translate(
                            offset: Offset(offset, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: textWidth,
                          child: Text(
                            topicText,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: topics.isEmpty ? null : _toggleSmartPlayback,
                icon: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                label: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Text(
                    snapshot.data == true ? 'مکث' : 'شروع پخش هوشمند',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'توقف پخش هوشمند',
              onPressed: _stopSmartPlayback,
              icon: const Icon(Icons.stop_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'تنظیم صدای پلیر موضوعی',
              onPressed: () => setState(
                () => _showSmartVolumeSlider = !_showSmartVolumeSlider,
              ),
              icon: Icon(
                _smartVolume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
        if (_showSmartVolumeSlider)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 8, top: 2),
            child: Row(
              children: [
                const Icon(Icons.volume_down_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: _smartVolume,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    label: '${(_smartVolume * 100).round()}٪',
                    onChanged: (value) {
                      setState(() => _smartVolume = value);
                      unawaited(_smartPlayer.setVolume(value));
                    },
                    onChangeEnd: (value) async {
                      await _setSmartPlayerVolume(value);
                      if (mounted) setState(() => _showSmartVolumeSlider = false);
                    },
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(_smartVolume * 100).round()}٪',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_smartQueueBookmarks.isNotEmpty)
          StreamBuilder<int?>(
            stream: _smartPlayer.currentIndexStream,
            initialData: _smartPlayer.currentIndex,
            builder: (context, snapshot) {
              final activeIndex = snapshot.data ?? -1;
              return Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  itemCount: _smartQueueBookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _smartQueueBookmarks[index];
                    final isActive = index == activeIndex;
                    final endMs = bookmark.endPositionMs ?? bookmark.positionMs;
                    final duration = Duration(
                      milliseconds: (endMs - bookmark.positionMs).clamp(0, 1 << 31).toInt(),
                    );
                    return Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: isActive
                          ? colors.primary.withValues(alpha: 0.10)
                          : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text(
                              _formatDuration(duration),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isActive ? colors.primary : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            isActive ? Icons.graphic_eq_rounded : Icons.bookmark_outline_rounded,
                            size: 17,
                            color: isActive ? colors.primary : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  bookmark.audioTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  bookmark.topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? colors.primary : colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isActive)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 6),
                              child: Text(
                                'در حال پخش',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          )
        else if (topics.isEmpty)
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded, size: 20),
            title: Text('هنوز موضوعی ثبت نشده است.', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              'در نوار پخش، با دکمه نشانک موضوعی ابتدا و انتهای هر موضوع را ثبت کن.',
              style: TextStyle(fontSize: 11),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'برای نمایش فهرست، پخش یک موضوع را شروع کن.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 12),
        StreamBuilder<Duration>(
          stream: _smartPlayer.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            return StreamBuilder<Duration?>(
              stream: _smartPlayer.durationStream,
              builder: (context, durationSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = durationSnapshot.data ?? Duration.zero;
                final max = duration.inMilliseconds.toDouble();
                return Column(
                  children: [
                    LinearProgressIndicator(
                      value: max <= 0
                          ? 0
                          : (position.inMilliseconds / max).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position)),
                        Text(_formatDuration(duration)),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  void _onThemeButtonDown(PointerDownEvent event) {
    _themeLongPressTriggered = false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _themeLongPressTriggered = true;
      _showPresetThemePicker();
    });
  }

  void _onThemeButtonUp(PointerUpEvent event) {
    final wasLongPress = _themeLongPressTriggered;
    final wasShortPress = _themeHoldTimer?.isActive ?? false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
    if (!wasLongPress && wasShortPress) widget.onToggleTheme();
  }

  void _onThemeButtonCancel(PointerCancelEvent event) {
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
  }

  Future<void> _showPresetThemePicker() async {
    const themes = <({String id, String name, Color color, String description})>[
      (id: 'teal', name: 'فیروزه‌ای', color: Color(0xFF16A6A0), description: 'تم پیش‌فرض فعلی'),
      (id: 'blue', name: 'آبی اقیانوسی', color: Color(0xFF2878D0), description: 'آرام و خنک'),
      (id: 'purple', name: 'بنفش', color: Color(0xFF8764D8), description: 'بنفش مدرن'),
      (id: 'green', name: 'سبز جنگلی', color: Color(0xFF39865A), description: 'طبیعی و ملایم'),
      (id: 'amber', name: 'کهربایی', color: Color(0xFFD28A22), description: 'گرم و پرانرژی'),
      (id: 'rose', name: 'رز', color: Color(0xFFC65D78), description: 'صورتی متمایل به رز'),
      (id: 'slate', name: 'خاکستری', color: Color(0xFF718096), description: 'خنثی و مینیمال'),
    ];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('انتخاب تم برنامه'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'حالت فعلی: ${widget.isDark ? 'شب' : 'روز'}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ),
              for (final theme in themes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: theme.color,
                  ),
                  title: Text(theme.name),
                  subtitle: Text(theme.description),
                  trailing: widget.themeId == theme.id
                      ? const Icon(Icons.check_circle_rounded)
                      : null,
                  onTap: () {
                    widget.onSelectTheme(theme.id);
                    Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerToolbar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              PopupMenuButton<String>(
                tooltip: 'پشتیبان‌گیری و بازیابی',
                icon: const Icon(Icons.backup_outlined, size: 24),
                onSelected: (value) {
                  if (value == 'backup') _createBackup();
                  if (value == 'restore') _restoreBackup();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'backup',
                    child: Row(
                      children: [
                        Icon(Icons.save_alt_rounded),
                        SizedBox(width: 12),
                        Text('تهیه نسخه پشتیبان'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.settings_backup_restore_rounded),
                        SizedBox(width: 12),
                        Text('بازیابی نسخه پشتیبان'),
                      ],
                    ),
                  ),
                ],
              ),
              Tooltip(
                message: 'لمس کوتاه: تغییر شب و روز • نگه‌داشتن ۳ ثانیه: انتخاب تم',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onThemeButtonDown,
                  onPointerUp: _onThemeButtonUp,
                  onPointerCancel: _onThemeButtonCancel,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        widget.isDark ? Icons.light_mode : Icons.dark_mode,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'شروع و پایان خودکار',
                icon: const Icon(Icons.schedule_rounded, size: 24),
                onSelected: (value) {
                  if (value == 'start') _scheduleStartDialog();
                  if (value == 'stop') _scheduleStopDialog();
                  if (value == 'cancel_start') _cancelScheduledStart();
                  if (value == 'cancel_stop') _cancelScheduledStop();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'start', child: Text('تنظیم شروع خودکار')),
                  PopupMenuItem(value: 'stop', child: Text('تنظیم توقف خودکار')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'cancel_start', child: Text('لغو شروع خودکار')),
                  PopupMenuItem(value: 'cancel_stop', child: Text('لغو توقف خودکار')),
                ],
              ),
              IconButton(
                tooltip: 'نقشه تغییرات صدا',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                onPressed: _openVolumeAutomation,
                icon: const Icon(Icons.multiline_chart_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    final hasLibraryItems = _libraryFolders.isNotEmpty || _tracks.isNotEmpty;
    final actions = Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'انتخاب فایل صوتی',
          onPressed: _pickAudio,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.audio_file_rounded, size: 20),
        ),
        const SizedBox(width: 3),
        IconButton.filledTonal(
          tooltip: 'انتخاب پوشه',
          onPressed: _openFolderManager,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.create_new_folder_outlined, size: 20),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final folder in _libraryFolders)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_rounded, size: 18, color: colors.primary),
                        const SizedBox(width: 4),
                        Text(
                          folder['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (!hasLibraryItems) {
      return Center(child: actions);
    }

    final itemCount = _tracks.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: actions,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: itemCount,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            itemBuilder: (context, index) {
              final trackIndex = index;
              final track = _tracks[trackIndex];
              final isCurrent = _currentIndex == trackIndex;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                minVerticalPadding: 0,
                minTileHeight: 30,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                tileColor: isCurrent
                    ? colors.primary.withValues(alpha: 0.10)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: _MarqueeText(
                  text: track.title,
                  style: const TextStyle(fontSize: 14),
                  gap: 28,
                ),
                onTap: () => _playTrack(trackIndex),
                trailing: PopupMenuButton<String>(
                  tooltip: 'گزینه‌های فایل صوتی',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  iconSize: 17,
                  onSelected: (action) {
                    if (action == 'rename') {
                      _renameTrack(trackIndex);
                    } else if (action == 'delete') {
                      _confirmRemoveTrack(trackIndex);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'rename',
                      height: 40,
                      child: Text('ویرایش نام'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      height: 40,
                      child: Text('حذف از کتابخانه'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onLyricsPointerDown(PointerDownEvent event) {
    _lyricsHoldTimer?.cancel();
    _lyricsHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _lyricsEditing = true);
    });
  }

  void _onLyricsPointerEnd(PointerEvent event) {
    _lyricsHoldTimer?.cancel();
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
              Icon(Icons.edit_note, size: 44, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'متن صدا ...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    if (_lyricsEditing) {
      return _LyricsEditor(
        key: ValueKey('edit-${track.path}'),
        track: track,
        initialText: _lyrics[track.path] ?? '',
        onSave: (value) => _saveLyrics(track.path, value),
        onSaveComplete: () {
          if (mounted) setState(() => _lyricsEditing = false);
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Expanded(
            child: Listener(
              onPointerDown: _onLyricsPointerDown,
              onPointerUp: _onLyricsPointerEnd,
              onPointerCancel: _onLyricsPointerEnd,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    (_lyrics[track.path] ?? '').trim().isEmpty
                        ? 'متن صدا ...'
                        : _lyrics[track.path]!,
                    textDirection: TextDirection.rtl,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await _store.saveLyrics(_lyrics);
                  _showMessage('متن ویس ذخیره شد.');
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded, color: colors.primary, size: 21),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _MarqueeText(
                            text: track?.title ?? 'فایلی برای پخش انتخاب نشده',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'در حال پخش',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'ثبت نشانک در زمان فعلی',
                        onPressed: track == null ? null : _addBookmark,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: _pendingTopicStartMs == null
                            ? 'ثبت شروع موضوع'
                            : 'ثبت پایان موضوع (${_formatDuration(Duration(milliseconds: _pendingTopicStartMs!))})',
                        onPressed: track == null ? null : _toggleTopicRangeBookmark,
                        color: _pendingTopicStartMs == null ? null : colors.primary,
                        icon: Icon(
                          _pendingTopicStartMs == null
                              ? Icons.bookmark_add_rounded
                              : Icons.bookmark_added_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: _currentTrack == null
                            ? 'علاقه‌مندی‌ها (ابتدا یک فایل پخش کن)'
                            : _currentTrackIsFavorite
                                ? 'حذف از علاقه‌مندی‌ها'
                                : 'افزودن به علاقه‌مندی‌ها',
                        onPressed: _toggleCurrentTrackFavorite,
                        icon: Icon(
                          _currentTrackIsFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: _currentTrackIsFavorite
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: 'شروع پخش هوشمند',
                        onPressed: _toggleSmartPlayback,
                        icon: const Icon(Icons.auto_awesome_rounded),
                      ),
                      IconButton(
                        tooltip: 'تنظیم صدای پلیر',
                        onPressed: _showVolumeSettings,
                        icon: Icon(
                          _volume == 0
                              ? Icons.volume_off_rounded
                              : _volume < 0.5
                                  ? Icons.volume_down_rounded
                                  : Icons.volume_up_rounded,
                          color: colors.primary,
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
                  final trackRanges = _bookmarks
                      .where((bookmark) =>
                          bookmark.isTopicRange &&
                          bookmark.audioPath == track?.path &&
                          bookmark.endPositionMs != null &&
                          bookmark.endPositionMs! > bookmark.positionMs)
                      .toList();
                  return Column(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final usableWidth =
                              (constraints.maxWidth - 32).clamp(0.0, double.infinity).toDouble();
                          return Stack(
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
                              if (max > 0)
                                ...trackRanges.expand((bookmark) {
                                  final startFraction =
                                      (bookmark.positionMs / max).clamp(0.0, 1.0).toDouble();
                                  final endFraction =
                                      (bookmark.endPositionMs! / max).clamp(0.0, 1.0).toDouble();
                                  return <Widget>[
                                    PositionedDirectional(
                                      start: 16 + usableWidth * startFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.tertiary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                    PositionedDirectional(
                                      start: 16 + usableWidth * endFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                  ];
                                }),
                            ],
                          );
                        },
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
                    icon: const Icon(Icons.shuffle, size: 27),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه عقب',
                    onPressed: track == null ? null : () => _seekRelative(-15),
                    icon: const Icon(Icons.replay_10, size: 27),
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
                    icon: const Icon(Icons.skip_previous_rounded, size: 32),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      final processing = snapshot.data?.processingState;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return SizedBox(
                        width: 60,
                        height: 60,
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
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  size: 34,
                                ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'بعدی',
                    onPressed: track == null ? null : _player.seekToNext,
                    icon: const Icon(Icons.skip_next_rounded, size: 32),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه جلو',
                    onPressed: track == null ? null : () => _seekRelative(15),
                    icon: const Icon(Icons.forward_10, size: 27),
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
                      size: 27,
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
    required this.onSaveComplete,
  });

  final AudioTrack track;
  final String initialText;
  final Future<void> Function(String value) onSave;
  final VoidCallback onSaveComplete;

  @override
  State<_LyricsEditor> createState() => _LyricsEditorState();
}

class _LyricsEditorState extends State<_LyricsEditor> {
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  final FocusNode _lyricsFocusNode = FocusNode();
  Timer? _saveTimer;
  bool _saving = false;
  bool _saved = true;
  bool _hasSearched = false;
  List<int> _matches = [];
  int _activeMatch = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _searchController = TextEditingController();
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
    if (_matches.isNotEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
        _hasSearched = false;
      });
    }
  }

  void _findMatches({bool preservePosition = false}) {
    final query = _searchController.text;
    final text = _controller.text;
    _hasSearched = true;
    if (query.isEmpty || text.isEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
      });
      return;
    }

    final source = text.toLowerCase();
    final needle = query.toLowerCase();
    final found = <int>[];
    var offset = 0;
    while (offset <= source.length - needle.length) {
      final index = source.indexOf(needle, offset);
      if (index < 0) break;
      found.add(index);
      offset = index + needle.length;
    }

    final previousStart = preservePosition && _activeMatch >= 0 &&
            _activeMatch < _matches.length
        ? _matches[_activeMatch]
        : -1;
    var nextActive = found.isEmpty ? -1 : 0;
    if (previousStart >= 0 && found.isNotEmpty) {
      final sameIndex = found.indexOf(previousStart);
      if (sameIndex >= 0) nextActive = sameIndex;
    }
    setState(() {
      _matches = found;
      _activeMatch = nextActive;
    });
    if (found.isNotEmpty) _selectMatch(nextActive);
  }

  void _selectMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final start = _matches[index];
    final end = start + _searchController.text.length;
    _lyricsFocusNode.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    setState(() => _activeMatch = index);
  }

  void _moveMatch(int step) {
    if (_matches.isEmpty) return;
    final next = (_activeMatch + step + _matches.length) % _matches.length;
    _selectMatch(next);
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
    _searchController.dispose();
    _lyricsFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasMatches = _matches.isNotEmpty;
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textDirection: TextDirection.rtl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _findMatches(),
                  onChanged: (_) {
                    setState(() {
                      _matches = [];
                      _activeMatch = -1;
                      _hasSearched = false;
                    });
                  },
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'جست‌وجو در متن همین ویس...',
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    suffixIcon: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      tooltip: 'جست‌وجو',
                      onPressed: _findMatches,
                      icon: const Icon(Icons.search_rounded, size: 17),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه قبلی',
                onPressed: hasMatches ? () => _moveMatch(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ),
              const SizedBox(width: 3),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه بعدی',
                onPressed: hasMatches ? () => _moveMatch(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _searchController.text.isEmpty
                  ? 'جست‌وجو فقط در متن فایل انتخاب‌شده انجام می‌شود.'
                  : hasMatches
                      ? 'نتیجه ${_activeMatch + 1} از ${_matches.length}'
                      : _hasSearched
                          ? 'کلمه‌ای با این عبارت پیدا نشد.'
                          : 'برای شروع، دکمه جست‌وجو را بزن.',
              style: TextStyle(
                fontSize: 11,
                color: hasMatches ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _lyricsFocusNode,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textDirection: TextDirection.rtl,
              onChanged: _scheduleSave,
              style: const TextStyle(fontSize: 14),
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
                onPressed: _saving
                    ? null
                    : () async {
                        _saveTimer?.cancel();
                        await _save(_controller.text);
                        if (mounted) widget.onSaveComplete();
                      },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('ذخیره', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    this.gap = 36,
  });

  final String text;
  final TextStyle style;
  final double gap;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller.stop();
      _controller.value = 0;
      _started = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout();
        final textWidth = painter.width;
        final availableWidth = constraints.maxWidth;

        if (textWidth <= availableWidth || availableWidth <= 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: widget.style,
            ),
          );
        }

        final distance = textWidth + widget.gap;
        if (!_started) {
          _started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final milliseconds =
                (distance / 32 * 1000).round().clamp(1800, 20000).toInt();
            _controller.duration = Duration(milliseconds: milliseconds);
            _controller.repeat();
          });
        }

        return ClipRect(
          child: SizedBox(
            height: painter.height,
            width: availableWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(-distance * _controller.value, 0),
                child: child,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                  SizedBox(width: widget.gap),
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
), ''),
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

  Future<void> _openFolderManager() async {
    final folders = await _store.loadFolders();
    if (!mounted) return;
    final selected = folders.map((folder) => Map<String, String>.from(folder)).toList();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('پوشه‌های کتابخانه'),
          content: SizedBox(
            width: double.maxFinite,
            height: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text('هنوز پوشه‌ای انتخاب نشده است.'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: selected.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          selected[index]['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'حذف پوشه',
                          icon: const Icon(Icons.close),
                          onPressed: () => setDialogState(
                            () => selected.removeAt(index),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final folder = await _folderService.pickFolder();
                      if (folder == null) return;
                      if (selected.any((item) => item['uri'] == folder['uri'])) return;
                      setDialogState(() => selected.add(folder));
                    } catch (error) {
                      if (mounted) _showMessage('انتخاب پوشه ناموفق بود: $error');
                    }
                  },
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('افزودن پوشه'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final result = selected
                          .map((folder) => Map<String, String>.from(folder))
                          .toList();
                      Navigator.pop(dialogContext);
                      unawaited(_scanSelectedFolders(result));
                    },
              icon: const Icon(Icons.sync),
              label: const Text('شروع اسکن'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanSelectedFolders(List<Map<String, String>> folders) async {
    try {
      await _store.saveFolders(folders);
      if (mounted) {
        setState(() {
          _libraryFolders
            ..clear()
            ..addAll(folders.map((folder) => Map<String, String>.from(folder)));
        });
      }
      _showMessage('در حال اسکن پوشه‌ها...');
      final found = await _folderService.scanFolders(
        folders.map((folder) => folder['uri']!).toList(),
      );
      final existing = _tracks.map((track) => track.path).toSet();
      final added = <AudioTrack>[];
      var duplicates = 0;
      for (final item in found) {
        final uri = item['uri']!;
        if (!existing.add(uri)) {
          duplicates++;
          continue;
        }
        final name = item['name']!;
        final dotIndex = name.lastIndexOf('.');
        final title = dotIndex > 0 ? name.substring(0, dotIndex) : name;
        added.add(AudioTrack(path: uri, title: title));
      }
      if (added.isNotEmpty) {
        setState(() => _tracks.addAll(added));
        await _persistTracks();
        await _replacePlaylist(autoplay: false);
      }
      _showMessage(
        'اسکن تمام شد: ${added.length} فایل جدید، '
        '$duplicates فایل تکراری از ${found.length} فایل شناسایی‌شده.',
      );
    } catch (error) {
      _showMessage('اسکن پوشه‌ها ناموفق بود: $error');
    }
  }

  Future<void> _applyEffectiveVolume({Duration? position}) async {
    final positionMs = (position ?? _player.position).inMilliseconds;
    final trackPath = _currentTrack?.path;
    final ranges = trackPath == null
        ? const <VolumeRange>[]
        : (_volumeRangesByTrack[base64Url.encode(utf8.encode(trackPath))] ??
            const <VolumeRange>[]);
    final effective = scheduledVolumeAt(ranges, positionMs, _volume);
    if (_lastAppliedVolume != null &&
        (effective - _lastAppliedVolume!).abs() < 0.0001) {
      return;
    }
    _lastAppliedVolume = effective;
    await _player.setVolume(effective);
  }

  Future<void> _setPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _volume = normalized);
    _lastAppliedVolume = null;
    await _applyEffectiveVolume();
    await _store.saveVolume(normalized);
  }

  Future<void> _openVolumeAutomation() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را انتخاب کن.');
      return;
    }
    final trackKey = base64Url.encode(utf8.encode(track.path));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VolumeAutomationScreen(
          initialRanges: List<VolumeRange>.from(
            _volumeRangesByTrack[trackKey] ?? const <VolumeRange>[],
          ),
          onSave: (ranges) async {
            final preferences = await SharedPreferences.getInstance();
            final key = 'volume_ranges_v1_$trackKey';
            await preferences.setString(
              key,
              jsonEncode(ranges.map((range) => range.toMap()).toList()),
            );
            if (!mounted) return;
            setState(() {
              _volumeRangesByTrack[trackKey] = List<VolumeRange>.from(ranges)
                ..sort((a, b) => a.startMs.compareTo(b.startMs));
              _lastAppliedVolume = null;
            });
            await _applyEffectiveVolume();
          },
        ),
      ),
    );
  }

  Future<void> _showVolumeSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('صدای خروجی پلیر')),
                  Text('${(_volume * 100).round()}%'),
                ],
              ),
              Slider(
                value: _volume,
                min: 0,
                max: 1,
                divisions: 100,
                label: '${(_volume * 100).round()}%',
                onChanged: (value) {
                  setSheetState(() {});
                  _setPlayerVolume(value);
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => _setPlayerVolume(0),
                    child: const Text('بی‌صدا'),
                  ),
                  TextButton(
                    onPressed: () => _setPlayerVolume(1),
                    child: const Text('صدای کامل'),
                  ),
                ],
              ),
              Text(
                'این تنظیم فقط بلندی صدای همین پلیر را تغییر می‌دهد و صدای کلی گوشی را تنظیم نمی‌کند.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _replacePlaylist({required bool autoplay}) async {
    if (_tracks.isEmpty) {
      await _player.stop();
      return;
    }
    final oldIndex = _currentIndex < 0
        ? 0
        : _currentIndex.clamp(0, _tracks.length - 1).toInt();
    final sources = _tracks.map((track) {
      final uri = Uri.parse(track.path);
      return AudioSource.uri(
        uri.scheme == 'content' ? uri : Uri.file(track.path),
      );
    }).toList();
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

  Future<void> _confirmRemoveTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف از کتابخانه'),
        content: Text('«${track.title}» فقط از کتابخانهٔ برنامه حذف می‌شود و فایل اصلی در حافظه باقی می‌ماند. ادامه می‌دهی؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف از کتابخانه'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _removeTrack(index);
  }

  Future<void> _renameTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    final controller = TextEditingController(text: track.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ویرایش نام فایل'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(labelText: 'نام جدید'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.isEmpty || newTitle == track.title) return;
    if (_tracks.any((item) => item.path != track.path && item.title == newTitle)) {
      _showMessage('فایلی با این نام در کتابخانه وجود دارد.');
      return;
    }
    try {
      final renamed = await _folderService.renameItem(track.path, newTitle);
      final newPath = renamed['path'];
      if (newPath == null || newPath.isEmpty) {
        throw StateError('مسیر جدید فایل از سیستم دریافت نشد.');
      }
      final oldPath = track.path;
      final oldIndex = _tracks.indexWhere((item) => item.path == oldPath);
      if (oldIndex < 0) return;
      _tracks[oldIndex] = AudioTrack(path: newPath, title: newTitle);
      for (var i = 0; i < _bookmarks.length; i++) {
        final bookmark = _bookmarks[i];
        if (bookmark.audioPath != oldPath) continue;
        _bookmarks[i] = AudioBookmark(
          id: bookmark.id,
          audioPath: newPath,
          audioTitle: newTitle,
          positionMs: bookmark.positionMs,
          createdAt: bookmark.createdAt,
          title: bookmark.title,
          topic: bookmark.topic,
          endPositionMs: bookmark.endPositionMs,
          isTopicRange: bookmark.isTopicRange,
        );
      }
      for (var i = 0; i < _playlists.length; i++) {
        final playlist = _playlists[i];
        _playlists[i] = playlist.copyWith(
          trackPaths: playlist.trackPaths
              .map((path) => path == oldPath ? newPath : path)
              .toList(),
        );
      }
      final savedLyrics = _lyrics.remove(oldPath);
      if (savedLyrics != null) _lyrics[newPath] = savedLyrics;
      if (_pendingTopicAudioPath == oldPath) _pendingTopicAudioPath = newPath;
      await _persistTracks();
      await _store.saveBookmarks(_bookmarks);
      await _store.savePlaylists(_playlists);
      await _store.saveLyrics(_lyrics);
      await _replacePlaylist(autoplay: false);
      if (mounted) setState(() {});
      _showMessage('نام فایل در حافظه و کتابخانه تغییر کرد.');
    } catch (error) {
      _showMessage('تغییر نام فایل ناموفق بود: $error');
    }
  }

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _bookmarks.removeWhere((bookmark) => bookmark.audioPath == removed.path);
    if (_pendingTopicAudioPath == removed.path) {
      _pendingTopicStartMs = null;
      _pendingTopicAudioPath = null;
    }
    for (var i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      _playlists[i] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((path) => path != removed.path).toList(),
      );
    }
    await _store.savePlaylists(_playlists);
    await _store.saveBookmarks(_bookmarks);
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

  Future<void> _addBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }

    final position = _player.position;
    final details = await _showBookmarkDetailsDialog(
      initialTitle: track.title,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: position.inMilliseconds,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
      });
      _showMessage(
        'نشانک معمولی در ${_formatDuration(position)} ذخیره شد. این نشانک وارد پخش هوشمند نمی‌شود.',
      );
    } catch (error) {
      _showMessage('ذخیره نشانک ناموفق بود: $error');
    }
  }

  Future<void> _toggleTopicRangeBookmark() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای ثبت موضوع انتخاب کن.');
      return;
    }

    final startMs = _pendingTopicStartMs;
    if (startMs == null) {
      final positionMs = _player.position.inMilliseconds;
      setState(() {
        _pendingTopicStartMs = positionMs;
        _pendingTopicAudioPath = track.path;
      });
      _showMessage('شروع موضوع در ${_formatDuration(Duration(milliseconds: positionMs))} ثبت شد؛ برای ثبت پایان، دوباره همین دکمه را بزن.');
      return;
    }

    if (_pendingTopicAudioPath != track.path) {
      _showMessage('برای ثبت پایان، ابتدا به همان فایل صوتی که شروع موضوع را در آن ثبت کردی برگرد.');
      return;
    }

    final endMs = _player.position.inMilliseconds;
    if (endMs <= startMs) {
      _showMessage('زمان پایان باید بعد از زمان شروع باشد. نشانگر شروع حفظ شد؛ کمی جلوتر برو و دوباره بزن.');
      return;
    }

    final details = await _showBookmarkDetailsDialog(initialTitle: track.title);
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای نشانک موضوعی، نام موضوع را وارد کن.');
      return;
    }

    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: startMs,
      endPositionMs: endMs,
      isTopicRange: true,
      createdAt: now,
      title: details['title']!.isEmpty ? track.title : details['title']!,
      topic: details['topic']!,
    );
    final updatedBookmarks = [..._bookmarks, bookmark]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    try {
      await _store.saveBookmarks(updatedBookmarks);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updatedBookmarks);
        _selectedSmartTopic ??= bookmark.topic;
        _pendingTopicStartMs = null;
        _pendingTopicAudioPath = null;
      });
      await _saveSmartSettings();
      _showMessage('بازه موضوع «${bookmark.topic}» از ${_formatDuration(Duration(milliseconds: startMs))} تا ${_formatDuration(Duration(milliseconds: endMs))} ذخیره شد.');
    } catch (error) {
      _showMessage('ذخیره بازه موضوع ناموفق بود: $error');
    }
  }

  List<String> get _availableSmartTopics {
    final topics = _bookmarks
        .where((bookmark) => bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs)
        .map((bookmark) => bookmark.topic.trim())
        .where((topic) => topic.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return topics;
  }

  Future<Map<String, String>?> _showBookmarkDetailsDialog({
    required String initialTitle,
    String initialTopic = '',
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final topicController = TextEditingController(text: initialTopic);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مشخصات نشانک'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'عنوان نشانک'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              textDirection: TextDirection.rtl,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'موضوع',
                hintText: 'مثلاً تمرکز',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'title': titleController.text.trim(),
              'topic': topicController.text.trim(),
            }),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    titleController.dispose();
    topicController.dispose();
    return result;
  }

  Future<void> _editBookmark(AudioBookmark bookmark) async {
    final details = await _showBookmarkDetailsDialog(
      initialTitle: bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
      initialTopic: bookmark.topic,
    );
    if (details == null) return;
    if (details['topic']!.isEmpty) {
      _showMessage('برای استفاده از پخش هوشمند، موضوع نشانک را وارد کن.');
      return;
    }
    final updated = _bookmarks
        .map((item) => item.id == bookmark.id
            ? AudioBookmark(
                id: item.id,
                audioPath: item.audioPath,
                audioTitle: item.audioTitle,
                positionMs: item.positionMs,
                endPositionMs: item.endPositionMs,
                isTopicRange: item.isTopicRange,
                createdAt: item.createdAt,
                title: details['title']!,
                topic: details['topic']!,
              )
            : item)
        .toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('ویرایش نشانک ذخیره نشد: $error');
    }
  }

  Future<void> _deleteBookmark(AudioBookmark bookmark) async {
    final updated = _bookmarks.where((item) => item.id != bookmark.id).toList();
    try {
      await _store.saveBookmarks(updated);
      if (!mounted) return;
      setState(() {
        _bookmarks
          ..clear()
          ..addAll(updated);
      });
    } catch (error) {
      _showMessage('حذف نشانک ناموفق بود: $error');
    }
  }

  Future<void> _saveSmartSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('smart_topic_mode_v1', _smartTopicMode);
      await preferences.setString('smart_order_mode_v1', _smartOrderMode);
      if (_selectedSmartTopic == null) {
        await preferences.remove('smart_selected_topic_v1');
      } else {
        await preferences.setString('smart_selected_topic_v1', _selectedSmartTopic!);
      }
    } catch (error) {
      _showMessage('ذخیره تنظیمات پخش هوشمند ناموفق بود: $error');
    }
  }

  Future<void> _startSmartPlayback() async {
    final topics = _availableSmartTopics;
    if (topics.isEmpty) {
      _showMessage('ابتدا در تب نشانک‌ها برای نشانک‌ها موضوع تعیین کن.');
      _tabController.animateTo(1);
      return;
    }

    String topic;
    if (_smartTopicMode == 'random') {
      topic = topics[Random().nextInt(topics.length)];
    } else {
      final selected = _selectedSmartTopic;
      if (selected == null || !topics.contains(selected)) {
        _showMessage('ابتدا یک موضوع برای پخش هوشمند انتخاب کن.');
        _tabController.animateTo(4);
        return;
      }
      topic = selected;
    }

    final matching = _bookmarks
        .where((bookmark) =>
            bookmark.isTopicRange &&
            bookmark.endPositionMs != null &&
            bookmark.endPositionMs! > bookmark.positionMs &&
            bookmark.topic.trim() == topic &&
            _tracks.any((track) => track.path == bookmark.audioPath))
        .toList();
    if (matching.isEmpty) {
      _showMessage('برای این موضوع نشانک قابل پخشی پیدا نشد.');
      return;
    }

    if (_smartOrderMode == 'random') {
      matching.shuffle(Random());
    } else {
      matching.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final sources = <AudioSource>[];
    for (final bookmark in matching) {
      final parsed = Uri.parse(bookmark.audioPath);
      final uri = parsed.scheme == 'content'
          ? parsed
          : Uri.file(bookmark.audioPath);
      sources.add(
        ClippingAudioSource(
          child: AudioSource.uri(uri),
          start: Duration(milliseconds: bookmark.positionMs),
          end: Duration(milliseconds: bookmark.endPositionMs!),
        ),
      );
    }

    try {
      await _player.pause();
      await _smartPlayer.stop();
      await _smartPlayer.setAudioSources(
        sources,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );
      if (!mounted) return;
      setState(() {
        _activeSmartTopic = topic;
        _smartQueueBookmarks
          ..clear()
          ..addAll(matching);
        _smartQueueReady = true;
      });
      await _smartPlayer.play();
    } catch (error) {
      if (mounted) {
        setState(() {
          _smartQueueReady = false;
          _smartQueueBookmarks.clear();
        });
        _showMessage('شروع پخش هوشمند ناموفق بود: $error');
      }
    }
  }

  Future<void> _setSmartPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _smartVolume = normalized);
    await _smartPlayer.setVolume(normalized);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble('smart_topic_volume_v1', normalized);
  }

  Future<void> _toggleSmartPlayback() async {
    if (_smartPlayer.playing) {
      await _smartPlayer.pause();
      return;
    }
    if (_smartQueueReady &&
        _smartPlayer.processingState != ProcessingState.completed) {
      await _smartPlayer.play();
      return;
    }
    await _startSmartPlayback();
  }

  Future<void> _stopSmartPlayback() async {
    await _smartPlayer.stop();
    if (mounted) {
      setState(() {
        _smartQueueReady = false;
        _activeSmartTopic = null;
        _smartQueueBookmarks.clear();
      });
    }
  }

  Future<void> _playBookmark(AudioBookmark bookmark) async {
    final trackIndex =
        _tracks.indexWhere((track) => track.path == bookmark.audioPath);
    if (trackIndex < 0) {
      _showMessage('فایل صوتی این نشانک در کتابخانه موجود نیست.');
      return;
    }

    try {
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      final position = Duration(milliseconds: bookmark.positionMs);
      await _player.seek(position, index: trackIndex);
      await _player.play();
    } catch (error) {
      _showMessage('پخش از نشانک ممکن نشد: $error');
    }
  }

  Widget _buildBookmarksTab(ColorScheme colors) {
    final track = _currentTrack;
    final trackBookmarks = track == null
        ? const <AudioBookmark>[]
        : _bookmarks
            .where((bookmark) => bookmark.audioPath == track.path)
            .toList();

    if (track == null) {
      return const Center(
        child: Text(
          'برای مشاهده نشانک‌ها، ابتدا یک فایل صوتی انتخاب کن.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (trackBookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'برای «${track.title}» هنوز نشانکی ثبت نشده است. هنگام پخش این فایل، دکمه نشانک را لمس کن.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      key: ValueKey('bookmarks-${track.path}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: trackBookmarks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final bookmark = trackBookmarks[index];
        final createdAt = bookmark.createdAt;
        final dateLabel =
            '${createdAt.year}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.day.toString().padLeft(2, '0')}  '
            '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(
              bookmark.isTopicRange
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_rounded,
              color: colors.primary,
            ),
            title: Text(
              bookmark.title.isEmpty ? bookmark.audioTitle : bookmark.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '${bookmark.isTopicRange ? 'موضوع' : 'نشانک معمولی'}  •  ${bookmark.topic.isEmpty ? 'بدون موضوع' : bookmark.topic}  •  ${_formatDuration(Duration(milliseconds: bookmark.positionMs))}${bookmark.isTopicRange && bookmark.endPositionMs != null ? ' تا ${_formatDuration(Duration(milliseconds: bookmark.endPositionMs!))}' : ''}  •  $dateLabel',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'مدیریت نشانک',
              onSelected: (value) {
                if (value == 'edit') _editBookmark(bookmark);
                if (value == 'delete') _deleteBookmark(bookmark);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('ویرایش عنوان و موضوع')),
                PopupMenuItem(value: 'delete', child: Text('حذف نشانک')),
              ],
            ),
            onTap: () => _playBookmark(bookmark),
          ),
        );
      },
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ساخت پلی‌لیست جدید'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.rtl,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: const InputDecoration(
            labelText: 'نام پلی‌لیست',
            hintText: 'مثلاً موسیقی آرامش‌بخش',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('ساختن'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final playlist = AudioPlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      trackPaths: const [],
    );
    setState(() {
      _playlists.add(playlist);
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
  }

  Future<void> _addCurrentTrackToPlaylist(AudioPlaylist playlist) async {
    final track = _currentTrack;
    if (track == null) return;
    if (playlist.trackPaths.contains(track.path)) {
      _showMessage('این فایل از قبل در پلی‌لیست «${playlist.name}» وجود دارد.');
      return;
    }
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: [...playlist.trackPaths, track.path],
      );
      _expandedPlaylistId = playlist.id;
    });
    await _store.savePlaylists(_playlists);
    _showMessage('«${track.title}» به پلی‌لیست «${playlist.name}» اضافه شد.');
  }

  Future<void> _removeFromPlaylist(AudioPlaylist playlist, String path) async {
    final index = _playlists.indexWhere((item) => item.id == playlist.id);
    if (index < 0) return;
    setState(() {
      _playlists[index] = playlist.copyWith(
        trackPaths: playlist.trackPaths.where((item) => item != path).toList(),
      );
    });
    await _store.savePlaylists(_playlists);
  }

  bool get _currentTrackIsFavorite {
    final track = _currentTrack;
    if (track == null) return false;
    final index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    return index >= 0 && _playlists[index].trackPaths.contains(track.path);
  }

  Future<void> _toggleCurrentTrackFavorite() async {
    final track = _currentTrack;
    if (track == null) {
      _showMessage('ابتدا یک فایل صوتی را برای پخش انتخاب کن.');
      return;
    }
    var index = _playlists.indexWhere((item) => item.id == _favoritesPlaylistId);
    if (index < 0) {
      _playlists.add(const AudioPlaylist(
        id: _favoritesPlaylistId,
        name: _favoritesPlaylistName,
        trackPaths: [],
      ));
      index = _playlists.length - 1;
    }
    final favorites = _playlists[index];
    final isFavorite = favorites.trackPaths.contains(track.path);
    setState(() {
      _playlists[index] = favorites.copyWith(
        trackPaths: isFavorite
            ? favorites.trackPaths.where((path) => path != track.path).toList()
            : [...favorites.trackPaths, track.path],
      );
      _expandedPlaylistId = _favoritesPlaylistId;
    });
    await _store.savePlaylists(_playlists);
    _showMessage(isFavorite
        ? '«${track.title}» از علاقه‌مندی‌ها حذف شد.'
        : '«${track.title}» به علاقه‌مندی‌ها اضافه شد.');
  }

  Future<void> _deletePlaylist(AudioPlaylist playlist) async {
    if (playlist.id == _favoritesPlaylistId) {
      _showMessage('پلی‌لیست علاقه‌مندی‌ها قابل حذف نیست.');
      return;
    }
    setState(() => _playlists.removeWhere((item) => item.id == playlist.id));
    await _store.savePlaylists(_playlists);
  }

  Widget _buildPlaylistsTab(ColorScheme colors) {
    final current = _currentTrack;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: IconButton.filled(
              tooltip: 'پلی‌لیست جدید',
              onPressed: _createPlaylist,
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? const SizedBox.shrink()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: _playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    final expanded = _expandedPlaylistId == playlist.id;
                    final tracks = playlist.trackPaths
                        .map((path) => _tracks.where((track) => track.path == path))
                        .where((matches) => matches.isNotEmpty)
                        .map((matches) => matches.first)
                        .toList();
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: PageStorageKey(playlist.id),
                        initiallyExpanded: expanded,
                        onExpansionChanged: (value) => setState(() {
                          _expandedPlaylistId = value ? playlist.id : null;
                        }),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        children: [
                          if (current != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _addCurrentTrackToPlaylist(playlist),
                                  child: const Text('افزودن آهنگ در حال پخش'),
                                ),
                              ),
                            ),
                          if (playlist.id != _favoritesPlaylistId)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton(
                                  onPressed: () => _deletePlaylist(playlist),
                                  child: const Text('حذف پلی‌لیست'),
                                ),
                              ),
                            ),
                          if (tracks.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('این پلی‌لیست هنوز خالی است.'),
                            )
                          else
                            ...tracks.map((track) => ListTile(
                                  dense: true,
                                  title: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final trackIndex = _tracks.indexOf(track);
                                    if (trackIndex >= 0) _playTrack(trackIndex);
                                  },
                                  trailing: TextButton(
                                    onPressed: () => _removeFromPlaylist(
                                      playlist,
                                      track.path,
                                    ),
                                    child: const Text('حذف'),
                                  ),
                                )),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
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

  Future<DateTime?> _chooseScheduleDateTime(String title) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: title,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      helpText: 'ساعت اجرا',
    );
    if (time == null) return null;
    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!scheduled.isAfter(DateTime.now())) {
      _showMessage('زمان انتخاب‌شده باید در آینده باشد.');
      return null;
    }
    return scheduled;
  }

  Future<void> _scheduleStartDialog() async {
    if (_tracks.isEmpty) {
      _showMessage('ابتدا یک فایل صوتی به کتابخانه اضافه کن.');
      return;
    }
    String selectedPath = _currentTrack?.path ?? _tracks.first.path;
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('شروع خودکار پخش'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedPath,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'فایل صوتی'),
            items: _tracks.map((track) => DropdownMenuItem<String>(
              value: track.path,
              child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            )).toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selectedPath = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selectedPath),
              child: const Text('انتخاب زمان'),
            ),
          ],
        ),
      ),
    );
    if (path == null || !mounted) return;
    final at = await _chooseScheduleDateTime('تاریخ شروع پخش');
    if (at == null) return;
    final track = _tracks.firstWhere((item) => item.path == path);
    try {
      await ScheduledPlaybackService.scheduleStart(path: track.path, title: track.title, at: at);
      _showMessage('شروع پخش «${track.title}» برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم شروع خودکار ناموفق بود: $error');
    }
  }

  Future<void> _scheduleStopDialog() async {
    final at = await _chooseScheduleDateTime('تاریخ توقف پخش');
    if (at == null) return;
    try {
      await ScheduledPlaybackService.scheduleStop(at: at);
      _showMessage('توقف پخش برای ${_formatScheduleDateTime(at)} تنظیم شد.');
    } catch (error) {
      _showMessage('تنظیم توقف خودکار ناموفق بود: $error');
    }
  }

  String _formatScheduleDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.year % 100)}/${two(value.month)}/${two(value.day)} - ${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _cancelScheduledStart() async {
    try {
      await ScheduledPlaybackService.cancelStart();
      _showMessage('شروع خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان شروع ناموفق بود: $error');
    }
  }

  Future<void> _cancelScheduledStop() async {
    try {
      await ScheduledPlaybackService.cancelStop();
      _showMessage('توقف خودکار لغو شد.');
    } catch (error) {
      _showMessage('لغو زمان توقف ناموفق بود: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _messageTimer?.cancel();
    final generation = ++_messageGeneration;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          leading: const Icon(Icons.info_outline_rounded),
          content: Dismissible(
            key: ValueKey('app-message-$generation'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) {
              _messageTimer?.cancel();
              messenger.hideCurrentMaterialBanner();
            },
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(message),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'بستن پیام',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _messageTimer?.cancel();
                messenger.hideCurrentMaterialBanner();
              },
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      );
    _messageTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || generation != _messageGeneration) return;
      messenger.hideCurrentMaterialBanner();
    });
  }

  @override
  void dispose() {
    _lyricsHoldTimer?.cancel();
    _themeHoldTimer?.cancel();
    _messageTimer?.cancel();
    _smartTopicMarqueeController.dispose();
    _tabController.dispose();
    _player.dispose();
    unawaited(_smartPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
        body: Column(
          children: [
            _buildPlayerToolbar(colors),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLyricsTab(colors),
                  _buildBookmarksTab(colors),
                  _buildPlaylistsTab(colors),
                  _buildLibraryTab(colors),
                  _buildSmartTab(colors),
                ],
              ),
            ),
            _buildBottomNavigation(colors),
            _buildPlayerPanel(colors),
          ],
        ),
      );
  }

  Widget _buildBottomNavigation(ColorScheme colors) {
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: false,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                labelPadding: EdgeInsets.zero,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.notes_rounded, size: 26)),
                    ),
                    text: 'متن',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.bookmarks_outlined, size: 26)),
                    ),
                    text: 'نشانک',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.queue_music_rounded, size: 26)),
                    ),
                    text: 'پلی‌لیست',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.library_music_outlined, size: 26)),
                    ),
                    text: 'کتابخانه',
                  ),
                  Tab(
                    height: 68,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(child: Icon(Icons.psychology_rounded, size: 26)),
                    ),
                    text: 'بخش هوشمند',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartTab(ColorScheme colors) {
    final topics = _availableSmartTopics;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartTopicMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'انتخاب موضوع',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'manual',
                    child: Text('انتخاب موضوع توسط من', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('انتخاب موضوع تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartTopicMode = value);
                  await _saveSmartSettings();
                  if (value == 'manual' && topics.isNotEmpty && mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('انتخاب موضوع'),
                        content: SizedBox(
                          width: 320,
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final topic in topics)
                                ListTile(
                                  title: Text(topic),
                                  trailing: _selectedSmartTopic == topic
                                      ? const Icon(Icons.check_rounded)
                                      : null,
                                  onTap: () async {
                                    setState(() => _selectedSmartTopic = topic);
                                    await _saveSmartSettings();
                                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _smartOrderMode,
                isExpanded: true,
                itemHeight: 38,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'ترتیب پخش نشانک‌ها',
                  labelStyle: TextStyle(fontSize: 11),
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'sequential',
                    child: Text('به ترتیب ثبت', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: 'random',
                    child: Text('به‌صورت تصادفی', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _smartOrderMode = value);
                  await _saveSmartSettings();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          textDirection: TextDirection.rtl,
          children: [
            const Text(
              'موضوع در حال پخش:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final topicText = _activeSmartTopic ?? '—';
                  final textPainter = TextPainter(
                    text: TextSpan(
                      text: topicText,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                  )..layout();
                  final textWidth = textPainter.width;
                  final viewportWidth = constraints.maxWidth;
                  if (textWidth <= viewportWidth) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        topicText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  return ClipRect(
                    child: SizedBox(
                      height: 22,
                      child: AnimatedBuilder(
                        animation: _smartTopicMarqueeController,
                        builder: (context, child) {
                          final travel = viewportWidth + textWidth;
                          final offset = viewportWidth -
                              (_smartTopicMarqueeController.value * travel);
                          return Transform.translate(
                            offset: Offset(offset, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: textWidth,
                          child: Text(
                            topicText,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: topics.isEmpty ? null : _toggleSmartPlayback,
                icon: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Icon(
                    snapshot.data == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                label: StreamBuilder<bool>(
                  stream: _smartPlayer.playingStream,
                  initialData: _smartPlayer.playing,
                  builder: (context, snapshot) => Text(
                    snapshot.data == true ? 'مکث' : 'شروع پخش هوشمند',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'توقف پخش هوشمند',
              onPressed: _stopSmartPlayback,
              icon: const Icon(Icons.stop_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'تنظیم صدای پلیر موضوعی',
              onPressed: () => setState(
                () => _showSmartVolumeSlider = !_showSmartVolumeSlider,
              ),
              icon: Icon(
                _smartVolume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
        if (_showSmartVolumeSlider)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 8, top: 2),
            child: Row(
              children: [
                const Icon(Icons.volume_down_rounded, size: 18),
                Expanded(
                  child: Slider(
                    value: _smartVolume,
                    min: 0,
                    max: 1,
                    divisions: 100,
                    label: '${(_smartVolume * 100).round()}٪',
                    onChanged: (value) {
                      setState(() => _smartVolume = value);
                      unawaited(_smartPlayer.setVolume(value));
                    },
                    onChangeEnd: (value) async {
                      await _setSmartPlayerVolume(value);
                      if (mounted) setState(() => _showSmartVolumeSlider = false);
                    },
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(_smartVolume * 100).round()}٪',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_smartQueueBookmarks.isNotEmpty)
          StreamBuilder<int?>(
            stream: _smartPlayer.currentIndexStream,
            initialData: _smartPlayer.currentIndex,
            builder: (context, snapshot) {
              final activeIndex = snapshot.data ?? -1;
              return Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  itemCount: _smartQueueBookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _smartQueueBookmarks[index];
                    final isActive = index == activeIndex;
                    final endMs = bookmark.endPositionMs ?? bookmark.positionMs;
                    final duration = Duration(
                      milliseconds: (endMs - bookmark.positionMs).clamp(0, 1 << 31).toInt(),
                    );
                    return Container(
                      constraints: const BoxConstraints(minHeight: 42),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      color: isActive
                          ? colors.primary.withValues(alpha: 0.10)
                          : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text(
                              _formatDuration(duration),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isActive ? colors.primary : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            isActive ? Icons.graphic_eq_rounded : Icons.bookmark_outline_rounded,
                            size: 17,
                            color: isActive ? colors.primary : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  bookmark.audioTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  bookmark.topic,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isActive ? colors.primary : colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isActive)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(start: 6),
                              child: Text(
                                'در حال پخش',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          )
        else if (topics.isEmpty)
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded, size: 20),
            title: Text('هنوز موضوعی ثبت نشده است.', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              'در نوار پخش، با دکمه نشانک موضوعی ابتدا و انتهای هر موضوع را ثبت کن.',
              style: TextStyle(fontSize: 11),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'برای نمایش فهرست، پخش یک موضوع را شروع کن.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 12),
        StreamBuilder<Duration>(
          stream: _smartPlayer.positionStream,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            return StreamBuilder<Duration?>(
              stream: _smartPlayer.durationStream,
              builder: (context, durationSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                final duration = durationSnapshot.data ?? Duration.zero;
                final max = duration.inMilliseconds.toDouble();
                return Column(
                  children: [
                    LinearProgressIndicator(
                      value: max <= 0
                          ? 0
                          : (position.inMilliseconds / max).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(position)),
                        Text(_formatDuration(duration)),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  void _onThemeButtonDown(PointerDownEvent event) {
    _themeLongPressTriggered = false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _themeLongPressTriggered = true;
      _showPresetThemePicker();
    });
  }

  void _onThemeButtonUp(PointerUpEvent event) {
    final wasLongPress = _themeLongPressTriggered;
    final wasShortPress = _themeHoldTimer?.isActive ?? false;
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
    if (!wasLongPress && wasShortPress) widget.onToggleTheme();
  }

  void _onThemeButtonCancel(PointerCancelEvent event) {
    _themeHoldTimer?.cancel();
    _themeHoldTimer = null;
    _themeLongPressTriggered = false;
  }

  Future<void> _showPresetThemePicker() async {
    const themes = <({String id, String name, Color color, String description})>[
      (id: 'teal', name: 'فیروزه‌ای', color: Color(0xFF16A6A0), description: 'تم پیش‌فرض فعلی'),
      (id: 'blue', name: 'آبی اقیانوسی', color: Color(0xFF2878D0), description: 'آرام و خنک'),
      (id: 'purple', name: 'بنفش', color: Color(0xFF8764D8), description: 'بنفش مدرن'),
      (id: 'green', name: 'سبز جنگلی', color: Color(0xFF39865A), description: 'طبیعی و ملایم'),
      (id: 'amber', name: 'کهربایی', color: Color(0xFFD28A22), description: 'گرم و پرانرژی'),
      (id: 'rose', name: 'رز', color: Color(0xFFC65D78), description: 'صورتی متمایل به رز'),
      (id: 'slate', name: 'خاکستری', color: Color(0xFF718096), description: 'خنثی و مینیمال'),
    ];
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('انتخاب تم برنامه'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'حالت فعلی: ${widget.isDark ? 'شب' : 'روز'}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ),
              for (final theme in themes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: theme.color,
                  ),
                  title: Text(theme.name),
                  subtitle: Text(theme.description),
                  trailing: widget.themeId == theme.id
                      ? const Icon(Icons.check_circle_rounded)
                      : null,
                  onTap: () {
                    widget.onSelectTheme(theme.id);
                    Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('بستن'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerToolbar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              PopupMenuButton<String>(
                tooltip: 'پشتیبان‌گیری و بازیابی',
                icon: const Icon(Icons.backup_outlined, size: 24),
                onSelected: (value) {
                  if (value == 'backup') _createBackup();
                  if (value == 'restore') _restoreBackup();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'backup',
                    child: Row(
                      children: [
                        Icon(Icons.save_alt_rounded),
                        SizedBox(width: 12),
                        Text('تهیه نسخه پشتیبان'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.settings_backup_restore_rounded),
                        SizedBox(width: 12),
                        Text('بازیابی نسخه پشتیبان'),
                      ],
                    ),
                  ),
                ],
              ),
              Tooltip(
                message: 'لمس کوتاه: تغییر شب و روز • نگه‌داشتن ۳ ثانیه: انتخاب تم',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onThemeButtonDown,
                  onPointerUp: _onThemeButtonUp,
                  onPointerCancel: _onThemeButtonCancel,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        widget.isDark ? Icons.light_mode : Icons.dark_mode,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'شروع و پایان خودکار',
                icon: const Icon(Icons.schedule_rounded, size: 24),
                onSelected: (value) {
                  if (value == 'start') _scheduleStartDialog();
                  if (value == 'stop') _scheduleStopDialog();
                  if (value == 'cancel_start') _cancelScheduledStart();
                  if (value == 'cancel_stop') _cancelScheduledStop();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'start', child: Text('تنظیم شروع خودکار')),
                  PopupMenuItem(value: 'stop', child: Text('تنظیم توقف خودکار')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'cancel_start', child: Text('لغو شروع خودکار')),
                  PopupMenuItem(value: 'cancel_stop', child: Text('لغو توقف خودکار')),
                ],
              ),
              IconButton(
                tooltip: 'نقشه تغییرات صدا',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                onPressed: _openVolumeAutomation,
                icon: const Icon(Icons.multiline_chart_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    final hasLibraryItems = _libraryFolders.isNotEmpty || _tracks.isNotEmpty;
    final actions = Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'انتخاب فایل صوتی',
          onPressed: _pickAudio,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.audio_file_rounded, size: 20),
        ),
        const SizedBox(width: 3),
        IconButton.filledTonal(
          tooltip: 'انتخاب پوشه',
          onPressed: _openFolderManager,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.create_new_folder_outlined, size: 20),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final folder in _libraryFolders)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_rounded, size: 18, color: colors.primary),
                        const SizedBox(width: 4),
                        Text(
                          folder['name'] ?? 'پوشه',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (!hasLibraryItems) {
      return Center(child: actions);
    }

    final itemCount = _tracks.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: actions,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: itemCount,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            itemBuilder: (context, index) {
              final trackIndex = index;
              final track = _tracks[trackIndex];
              final isCurrent = _currentIndex == trackIndex;
              return ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                minVerticalPadding: 0,
                minTileHeight: 30,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                tileColor: isCurrent
                    ? colors.primary.withValues(alpha: 0.10)
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                title: _MarqueeText(
                  text: track.title,
                  style: const TextStyle(fontSize: 14),
                  gap: 28,
                ),
                onTap: () => _playTrack(trackIndex),
                trailing: PopupMenuButton<String>(
                  tooltip: 'گزینه‌های فایل صوتی',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  iconSize: 17,
                  onSelected: (action) {
                    if (action == 'rename') {
                      _renameTrack(trackIndex);
                    } else if (action == 'delete') {
                      _confirmRemoveTrack(trackIndex);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'rename',
                      height: 40,
                      child: Text('ویرایش نام'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      height: 40,
                      child: Text('حذف از کتابخانه'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _onLyricsPointerDown(PointerDownEvent event) {
    _lyricsHoldTimer?.cancel();
    _lyricsHoldTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _lyricsEditing = true);
    });
  }

  void _onLyricsPointerEnd(PointerEvent event) {
    _lyricsHoldTimer?.cancel();
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
              Icon(Icons.edit_note, size: 44, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'متن صدا ...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }
    if (_lyricsEditing) {
      return _LyricsEditor(
        key: ValueKey('edit-${track.path}'),
        track: track,
        initialText: _lyrics[track.path] ?? '',
        onSave: (value) => _saveLyrics(track.path, value),
        onSaveComplete: () {
          if (mounted) setState(() => _lyricsEditing = false);
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.primary, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Expanded(
            child: Listener(
              onPointerDown: _onLyricsPointerDown,
              onPointerUp: _onLyricsPointerEnd,
              onPointerCancel: _onLyricsPointerEnd,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    (_lyrics[track.path] ?? '').trim().isEmpty
                        ? 'متن صدا ...'
                        : _lyrics[track.path]!,
                    textDirection: TextDirection.rtl,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await _store.saveLyrics(_lyrics);
                  _showMessage('متن ویس ذخیره شد.');
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded, color: colors.primary, size: 21),
                        const SizedBox(width: 9),
                        Expanded(
                          child: _MarqueeText(
                            text: track?.title ?? 'فایلی برای پخش انتخاب نشده',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'در حال پخش',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'ثبت نشانک در زمان فعلی',
                        onPressed: track == null ? null : _addBookmark,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      ),
                      IconButton(
                        tooltip: _pendingTopicStartMs == null
                            ? 'ثبت شروع موضوع'
                            : 'ثبت پایان موضوع (${_formatDuration(Duration(milliseconds: _pendingTopicStartMs!))})',
                        onPressed: track == null ? null : _toggleTopicRangeBookmark,
                        color: _pendingTopicStartMs == null ? null : colors.primary,
                        icon: Icon(
                          _pendingTopicStartMs == null
                              ? Icons.bookmark_add_rounded
                              : Icons.bookmark_added_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: _currentTrack == null
                            ? 'علاقه‌مندی‌ها (ابتدا یک فایل پخش کن)'
                            : _currentTrackIsFavorite
                                ? 'حذف از علاقه‌مندی‌ها'
                                : 'افزودن به علاقه‌مندی‌ها',
                        onPressed: _toggleCurrentTrackFavorite,
                        icon: Icon(
                          _currentTrackIsFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: _currentTrackIsFavorite
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: 'شروع پخش هوشمند',
                        onPressed: _toggleSmartPlayback,
                        icon: const Icon(Icons.auto_awesome_rounded),
                      ),
                      IconButton(
                        tooltip: 'تنظیم صدای پلیر',
                        onPressed: _showVolumeSettings,
                        icon: Icon(
                          _volume == 0
                              ? Icons.volume_off_rounded
                              : _volume < 0.5
                                  ? Icons.volume_down_rounded
                                  : Icons.volume_up_rounded,
                          color: colors.primary,
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
                  final trackRanges = _bookmarks
                      .where((bookmark) =>
                          bookmark.isTopicRange &&
                          bookmark.audioPath == track?.path &&
                          bookmark.endPositionMs != null &&
                          bookmark.endPositionMs! > bookmark.positionMs)
                      .toList();
                  return Column(
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final usableWidth =
                              (constraints.maxWidth - 32).clamp(0.0, double.infinity).toDouble();
                          return Stack(
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
                              if (max > 0)
                                ...trackRanges.expand((bookmark) {
                                  final startFraction =
                                      (bookmark.positionMs / max).clamp(0.0, 1.0).toDouble();
                                  final endFraction =
                                      (bookmark.endPositionMs! / max).clamp(0.0, 1.0).toDouble();
                                  return <Widget>[
                                    PositionedDirectional(
                                      start: 16 + usableWidth * startFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.tertiary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                    PositionedDirectional(
                                      start: 16 + usableWidth * endFraction - 1.5,
                                      top: 16,
                                      child: Container(
                                        width: 3,
                                        height: 16,
                                        decoration: BoxDecoration(
                                          color: colors.primary,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                  ];
                                }),
                            ],
                          );
                        },
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
                    icon: const Icon(Icons.shuffle, size: 27),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه عقب',
                    onPressed: track == null ? null : () => _seekRelative(-15),
                    icon: const Icon(Icons.replay_10, size: 27),
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
                    icon: const Icon(Icons.skip_previous_rounded, size: 32),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      final processing = snapshot.data?.processingState;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return SizedBox(
                        width: 60,
                        height: 60,
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
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  playing ? Icons.pause : Icons.play_arrow,
                                  size: 34,
                                ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'بعدی',
                    onPressed: track == null ? null : _player.seekToNext,
                    icon: const Icon(Icons.skip_next_rounded, size: 32),
                  ),
                  IconButton(
                    tooltip: '۱۵ ثانیه جلو',
                    onPressed: track == null ? null : () => _seekRelative(15),
                    icon: const Icon(Icons.forward_10, size: 27),
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
                      size: 27,
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
    required this.onSaveComplete,
  });

  final AudioTrack track;
  final String initialText;
  final Future<void> Function(String value) onSave;
  final VoidCallback onSaveComplete;

  @override
  State<_LyricsEditor> createState() => _LyricsEditorState();
}

class _LyricsEditorState extends State<_LyricsEditor> {
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  final FocusNode _lyricsFocusNode = FocusNode();
  Timer? _saveTimer;
  bool _saving = false;
  bool _saved = true;
  bool _hasSearched = false;
  List<int> _matches = [];
  int _activeMatch = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _searchController = TextEditingController();
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
    if (_matches.isNotEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
        _hasSearched = false;
      });
    }
  }

  void _findMatches({bool preservePosition = false}) {
    final query = _searchController.text;
    final text = _controller.text;
    _hasSearched = true;
    if (query.isEmpty || text.isEmpty) {
      setState(() {
        _matches = [];
        _activeMatch = -1;
      });
      return;
    }

    final source = text.toLowerCase();
    final needle = query.toLowerCase();
    final found = <int>[];
    var offset = 0;
    while (offset <= source.length - needle.length) {
      final index = source.indexOf(needle, offset);
      if (index < 0) break;
      found.add(index);
      offset = index + needle.length;
    }

    final previousStart = preservePosition && _activeMatch >= 0 &&
            _activeMatch < _matches.length
        ? _matches[_activeMatch]
        : -1;
    var nextActive = found.isEmpty ? -1 : 0;
    if (previousStart >= 0 && found.isNotEmpty) {
      final sameIndex = found.indexOf(previousStart);
      if (sameIndex >= 0) nextActive = sameIndex;
    }
    setState(() {
      _matches = found;
      _activeMatch = nextActive;
    });
    if (found.isNotEmpty) _selectMatch(nextActive);
  }

  void _selectMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final start = _matches[index];
    final end = start + _searchController.text.length;
    _lyricsFocusNode.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    setState(() => _activeMatch = index);
  }

  void _moveMatch(int step) {
    if (_matches.isEmpty) return;
    final next = (_activeMatch + step + _matches.length) % _matches.length;
    _selectMatch(next);
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
    _searchController.dispose();
    _lyricsFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasMatches = _matches.isNotEmpty;
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textDirection: TextDirection.rtl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _findMatches(),
                  onChanged: (_) {
                    setState(() {
                      _matches = [];
                      _activeMatch = -1;
                      _hasSearched = false;
                    });
                  },
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'جست‌وجو در متن همین ویس...',
                    hintStyle: const TextStyle(fontSize: 12),
                    prefixIcon: const Icon(Icons.search, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    suffixIcon: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      tooltip: 'جست‌وجو',
                      onPressed: _findMatches,
                      icon: const Icon(Icons.search_rounded, size: 17),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه قبلی',
                onPressed: hasMatches ? () => _moveMatch(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ),
              const SizedBox(width: 3),
              IconButton.filledTonal(
                style: IconButton.styleFrom(minimumSize: const Size(32, 32), maximumSize: const Size(32, 32), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                tooltip: 'نتیجه بعدی',
                onPressed: hasMatches ? () => _moveMatch(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _searchController.text.isEmpty
                  ? 'جست‌وجو فقط در متن فایل انتخاب‌شده انجام می‌شود.'
                  : hasMatches
                      ? 'نتیجه ${_activeMatch + 1} از ${_matches.length}'
                      : _hasSearched
                          ? 'کلمه‌ای با این عبارت پیدا نشد.'
                          : 'برای شروع، دکمه جست‌وجو را بزن.',
              style: TextStyle(
                fontSize: 11,
                color: hasMatches ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _lyricsFocusNode,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              textDirection: TextDirection.rtl,
              onChanged: _scheduleSave,
              style: const TextStyle(fontSize: 14),
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
                onPressed: _saving
                    ? null
                    : () async {
                        _saveTimer?.cancel();
                        await _save(_controller.text);
                        if (mounted) widget.onSaveComplete();
                      },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('ذخیره', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    this.gap = 36,
  });

  final String text;
  final TextStyle style;
  final double gap;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller.stop();
      _controller.value = 0;
      _started = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: TextDirection.rtl,
          maxLines: 1,
        )..layout();
        final textWidth = painter.width;
        final availableWidth = constraints.maxWidth;

        if (textWidth <= availableWidth || availableWidth <= 0) {
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: widget.style,
            ),
          );
        }

        final distance = textWidth + widget.gap;
        if (!_started) {
          _started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final milliseconds =
                (distance / 32 * 1000).round().clamp(1800, 20000).toInt();
            _controller.duration = Duration(milliseconds: milliseconds);
            _controller.repeat();
          });
        }

        return ClipRect(
          child: SizedBox(
            height: painter.height,
            width: availableWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(-distance * _controller.value, 0),
                child: child,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                  SizedBox(width: widget.gap),
                  Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    textDirection: TextDirection.rtl,
                    style: widget.style,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
