// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/audio_bookmark.dart';
import '../models/audio_playlist.dart';
import '../models/audio_track.dart';
import '../services/library_store.dart';
import '../services/folder_library_service.dart';
import '../services/scheduled_playback_service.dart';

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

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // Android audio focus is intentionally not requested so this player can
  // mix with audio from other apps. iOS keeps normal session activation.
  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: !Platform.isAndroid,
  );
  final LibraryStore _store = LibraryStore();
  final FolderLibraryService _folderService = FolderLibraryService();
  final List<AudioTrack> _tracks = [];
  final List<Map<String, String>> _libraryFolders = [];
  Map<String, String> _lyrics = {};
  int _currentIndex = -1;
  bool _loading = true;
  bool _shuffle = false;
  LoopMode _loopMode = LoopMode.off;
  double _speed = 1;
  double _volume = 1;
  late final TabController _tabController;
  Timer? _lyricsHoldTimer;
  bool _lyricsEditing = false;
  final List<AudioBookmark> _bookmarks = [];
  final List<AudioPlaylist> _playlists = [];
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
    _tabController = TabController(length: 4, initialIndex: 3, vsync: this);
    _configureAudioSession();
    ScheduledPlaybackService.setStopHandler(() async {
      await _player.stop();
      _showMessage('پخش صوت طبق زمان‌بندی متوقف شد.');
    });
    _restoreLibrary();
    _player.currentIndexStream.listen((index) {
      if (!mounted) return;
      setState(() {
        _currentIndex = index ?? -1;
        _lyricsEditing = false;
      });
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
      await _player.setVolume(savedVolume);
      if (mounted) setState(() => _volume = savedVolume);
      final saved = await _store.loadTracks();
      final savedFolders = await _store.loadFolders();
      final lyrics = await _store.loadLyrics();
      final savedBookmarks = await _store.loadBookmarks();
      final savedPlaylists = await _store.loadPlaylists();
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

  Future<void> _setPlayerVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    if (mounted) setState(() => _volume = normalized);
    await _player.setVolume(normalized);
    await _store.saveVolume(normalized);
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

  Future<void> _removeTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final removed = _tracks.removeAt(index);
    _bookmarks.removeWhere((bookmark) => bookmark.audioPath == removed.path);
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
    if (track == null) return;
    final now = DateTime.now();
    final bookmark = AudioBookmark(
      id: now.microsecondsSinceEpoch.toString(),
      audioPath: track.path,
      audioTitle: track.title,
      positionMs: _player.position.inMilliseconds,
      createdAt: now,
    );
    setState(() {
      _bookmarks.add(bookmark);
      _bookmarks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    });
    await _store.saveBookmarks(_bookmarks);
    _showMessage(
      'نشانک در ${_formatDuration(Duration(milliseconds: bookmark.positionMs))} ذخیره شد.',
    );
  }

  Future<void> _removeBookmark(String id) async {
    setState(() => _bookmarks.removeWhere((bookmark) => bookmark.id == id));
    await _store.saveBookmarks(_bookmarks);
  }

  Future<void> _jumpToBookmark(AudioBookmark bookmark) async {
    final trackIndex = _tracks.indexWhere(
      (track) => track.path == bookmark.audioPath,
    );
    if (trackIndex < 0) {
      _showMessage('فایل صوتی این نشانک در کتابخانه پیدا نشد.');
      return;
    }
    try {
      await _player.pause();
      if (_player.sequence.length != _tracks.length) {
        await _replacePlaylist(autoplay: false);
      }
      await _player.seek(
        Duration(milliseconds: bookmark.positionMs),
        index: trackIndex,
      );
      if (mounted) setState(() {});
    } catch (error) {
      _showMessage('رفتن به نشانک ناموفق بود: $error');
    }
  }

  String _formatDateTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}/${two(value.month)}/${two(value.day)}  ${two(value.hour)}:${two(value.minute)}';
  }

  Widget _buildBookmarksTab(ColorScheme colors) {
    if (_bookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.bookmarks_outlined, size: 58, color: colors.primary),
              const SizedBox(height: 12),
              const Text(
                'هنوز نشانکی ثبت نشده است.',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                'هنگام پخش فایل، دکمه ثبت نشانک کنار عنوان فایل را لمس کن.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    final items = List<AudioBookmark>.from(_bookmarks)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 7),
      itemBuilder: (context, index) {
        final bookmark = items[index];
        final trackIndex = _tracks.indexWhere(
          (track) => track.path == bookmark.audioPath,
        );
        final selected = trackIndex == _currentIndex;
        return Card(
          child: ListTile(
            leading: Icon(
              Icons.music_note_rounded,
              color: selected ? colors.primary : colors.onSurfaceVariant,
            ),
            title: Text(
              bookmark.audioTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${_formatDuration(Duration(milliseconds: bookmark.positionMs))}  •  ${_formatDateTime(bookmark.createdAt)}',
            ),
            onTap: trackIndex < 0 ? null : () => _jumpToBookmark(bookmark),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'رفتن به زمان نشانک',
                  onPressed: trackIndex < 0
                ? null
                : () => _jumpToBookmark(bookmark),
                  icon: const Icon(Icons.bookmark_rounded),
                  color: colors.primary,
                ),
                IconButton(
                  tooltip: 'حذف نشانک',
                  onPressed: () => _removeBookmark(bookmark.id),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('پلی‌لیست‌های من',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            )),
                    const SizedBox(height: 3),
                    Text(
                      current == null
                          ? 'برای افزودن فایل، ابتدا یک صوت پخش کن.'
                          : 'فایل فعلی: ${current.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _createPlaylist,
                icon: const Icon(Icons.add),
                label: const Text('پلی‌لیست جدید'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _playlists.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.queue_music_rounded,
                            size: 60, color: colors.primary),
                        const SizedBox(height: 12),
                        const Text('هنوز پلی‌لیستی نساخته‌ای.'),
                        const SizedBox(height: 6),
                        Text(
                          'ابتدا پلی‌لیست بساز، سپس فایل در حال پخش را به آن اضافه کن.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )
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
                        leading: Icon(Icons.queue_music_rounded,
                            color: colors.primary),
                        title: Text(playlist.name,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${tracks.length} فایل صوتی'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'افزودن فایل فعلی به این پلی‌لیست',
                              onPressed: current == null
                                  ? null
                                  : () => _addCurrentTrackToPlaylist(playlist),
                              icon: const Icon(Icons.playlist_add_rounded),
                            ),
                            if (playlist.id != _favoritesPlaylistId)
                              PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'delete') _deletePlaylist(playlist);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('حذف پلی‌لیست'),
                                  ),
                                ],
                              ),
                          ],
                        ),
                        children: [
                          if (current != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: TextButton.icon(
                                  onPressed: () => _addCurrentTrackToPlaylist(playlist),
                                  icon: const Icon(Icons.playlist_add),
                                  label: const Text('افزودن فایل فعلی به این پلی‌لیست'),
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
                                  leading: const Icon(Icons.music_note_outlined),
                                  title: Text(track.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  onTap: () {
                                    final trackIndex = _tracks.indexOf(track);
                                    if (trackIndex >= 0) _playTrack(trackIndex);
                                  },
                                  trailing: IconButton(
                                    tooltip: 'حذف از پلی‌لیست',
                                    onPressed: () => _removeFromPlaylist(
                                        playlist, track.path),
                                    icon: const Icon(Icons.remove_circle_outline),
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _lyricsHoldTimer?.cancel();
    _tabController.dispose();
    _player.dispose();
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
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                labelPadding: EdgeInsets.zero,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(
                    height: 62,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: Icon(Icons.notes_rounded, size: 25),
                    text: 'متن',
                  ),
                  Tab(
                    height: 62,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: Icon(Icons.bookmarks_outlined, size: 25),
                    text: 'نشانک',
                  ),
                  Tab(
                    height: 62,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: Icon(Icons.queue_music_rounded, size: 25),
                    text: 'پلی‌لیست',
                  ),
                  Tab(
                    height: 62,
                    iconMargin: EdgeInsets.only(bottom: 3),
                    icon: Icon(Icons.library_music_outlined, size: 25),
                    text: 'کتابخانه',
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 52,
              height: 62,
              child: IconButton(
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
                  size: 25,
                  color: _currentTrackIsFavorite ? colors.error : colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerToolbar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerLow,
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
              IconButton(
                tooltip: widget.isDark ? 'تم روشن' : 'تم تاریک',
                onPressed: widget.onToggleTheme,
                icon: Icon(
                  widget.isDark ? Icons.light_mode : Icons.dark_mode,
                  size: 24,
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibraryTab(ColorScheme colors) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
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
                          '${_tracks.length} فایل صوتی • ${_libraryFolders.length} پوشه',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _pickAudio,
                    icon: const Icon(Icons.audio_file_rounded),
                    label: const Text('افزودن فایل'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: _openFolderManager,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('افزودن پوشه کتابخانه'),
                ),
              ),
              if (_libraryFolders.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: _libraryFolders.map((folder) => Chip(
                    avatar: const Icon(Icons.folder_outlined, size: 17),
                    label: Text(
                      folder['name'] ?? 'پوشه',
                      overflow: TextOverflow.ellipsis,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  )).toList(),
                ),
              ],
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
    if (_lyricsEditing) {
      return _LyricsEditor(
        key: ValueKey('edit-${track.path}'),
        track: track,
        initialText: _lyrics[track.path] ?? '',
        onSave: (value) => _saveLyrics(track.path, value),
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
                        ? 'هنوز متنی برای این فایل ثبت نشده است. برای نوشتن متن، سه ثانیه روی این قسمت نگه دار.'
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
              Expanded(
                child: Text(
                  'برای ویرایش، سه ثانیه روی متن نگه دار.',
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                ),
              ),
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
                  IconButton(
                    tooltip: 'ثبت نشانک در زمان فعلی',
                    onPressed: track == null ? null : _addBookmark,
                    icon: const Icon(Icons.bookmark_add_outlined),
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
                  decoration: InputDecoration(
                    hintText: 'جست‌وجو در متن همین ویس...',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: 'جست‌وجو',
                      onPressed: _findMatches,
                      icon: const Icon(Icons.search_rounded),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                tooltip: 'نتیجه قبلی',
                onPressed: hasMatches ? () => _moveMatch(-1) : null,
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
              IconButton.filledTonal(
                tooltip: 'نتیجه بعدی',
                onPressed: hasMatches ? () => _moveMatch(1) : null,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
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
                fontSize: 12,
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
                  unawaited(_save(_controller.text));
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
