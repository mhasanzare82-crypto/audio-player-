import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/audio_track.dart';
import '../models/audio_bookmark.dart';
import '../models/audio_playlist.dart';

class LibraryStore {
  static const _tracksKey = 'audio_library_v1';
  static const _lyricsKey = 'audio_lyrics_v1';
  static const _foldersKey = 'audio_library_folders_v1';
  static const _bookmarksKey = 'audio_bookmarks_v1';
  static const _playlistsKey = 'audio_playlists_v1';
  static const _volumeKey = 'audio_player_volume_v1';

  Future<String> exportBackupJson() async {
    final tracks = await loadTracks();
    final lyrics = await loadLyrics();
    final bookmarks = await loadBookmarks();
    final playlists = await loadPlaylists();
    return jsonEncode({
      'format': 'audio_player_backup',
      'version': 1,
      'createdAt': DateTime.now().toIso8601String(),
      'tracks': tracks.map((track) => track.toJson()).toList(),
      'lyrics': lyrics,
      'bookmarks': bookmarks.map((bookmark) => bookmark.toJson()).toList(),
      'playlists': playlists.map((playlist) => playlist.toJson()).toList(),
    });
  }

  Future<void> restoreBackupJson(String source) async {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'audio_player_backup' ||
        decoded['version'] != 1) {
      throw const FormatException('ساختار یا نسخه فایل پشتیبان معتبر نیست.');
    }

    final tracksData = decoded['tracks'];
    final lyricsData = decoded['lyrics'];
    final bookmarksData = decoded['bookmarks'];
    final playlistsData = decoded['playlists'];
    if (tracksData is! List ||
        lyricsData is! Map ||
        bookmarksData is! List ||
        playlistsData is! List) {
      throw const FormatException('بخشی از اطلاعات فایل پشتیبان ناقص است.');
    }

    // Decode every section before writing anything, so invalid files cannot
    // partially overwrite the current library.
    final tracks = AudioTrack.decodeList(jsonEncode(tracksData));
    final lyrics = lyricsData.map((key, value) {
      if (key is! String || value is! String) {
        throw const FormatException('ساختار متن‌های ذخیره‌شده معتبر نیست.');
      }
      return MapEntry(key, value);
    });
    final bookmarks = bookmarksData
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException('ساختار نشانک‌ها معتبر نیست.');
          }
          return AudioBookmark.fromJson(item);
        })
        .toList();
    final playlists = AudioPlaylist.decodeList(jsonEncode(playlistsData));

    final prefs = await SharedPreferences.getInstance();
    final values = <String, String>{
      _tracksKey: AudioTrack.encodeList(tracks),
      _lyricsKey: jsonEncode(lyrics),
      _bookmarksKey: jsonEncode(
        bookmarks.map((bookmark) => bookmark.toJson()).toList(),
      ),
      _playlistsKey: AudioPlaylist.encodeList(playlists),
    };
    for (final entry in values.entries) {
      final saved = await prefs.setString(entry.key, entry.value);
      if (!saved) {
        throw StateError('ذخیره اطلاعات ${entry.key} ناموفق بود.');
      }
    }
  }

  Future<double> loadVolume() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getDouble(_volumeKey) ?? 1.0).clamp(0.0, 1.0);
  }

  Future<void> saveVolume(double volume) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_volumeKey, volume.clamp(0.0, 1.0));
  }

  Future<List<AudioTrack>> loadTracks() async {
    final prefs = await SharedPreferences.getInstance();
    return AudioTrack.decodeList(prefs.getString(_tracksKey));
  }

  Future<void> saveTracks(List<AudioTrack> tracks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tracksKey, AudioTrack.encodeList(tracks));
  }

  Future<List<AudioBookmark>> loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_bookmarksKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(AudioBookmark.fromJson)
        .toList();
  }

  Future<void> saveBookmarks(List<AudioBookmark> bookmarks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _bookmarksKey,
      jsonEncode(bookmarks.map((bookmark) => bookmark.toJson()).toList()),
    );
  }

  Future<List<AudioPlaylist>> loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    return AudioPlaylist.decodeList(prefs.getString(_playlistsKey));
  }

  Future<void> savePlaylists(List<AudioPlaylist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playlistsKey, AudioPlaylist.encodeList(playlists));
  }

  Future<List<Map<String, String>>> loadFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_foldersKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map((item) => {
              'uri': item['uri'].toString(),
              'name': item['name'].toString(),
            })
        .toList();
  }

  Future<void> saveFolders(List<Map<String, String>> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_foldersKey, jsonEncode(folders));
  }

  Future<Map<String, String>> loadLyrics() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lyricsKey);
    if (raw == null || raw.isEmpty) return {};
    return (jsonDecode(raw) as Map<String, dynamic>)
        .map((key, value) => MapEntry(key, value.toString()));
  }

  Future<void> saveLyrics(Map<String, String> lyrics) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lyricsKey, jsonEncode(lyrics));
  }
}
