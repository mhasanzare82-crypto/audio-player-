import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/audio_track.dart';
import '../models/audio_bookmark.dart';

class LibraryStore {
  static const _tracksKey = 'audio_library_v1';
  static const _lyricsKey = 'audio_lyrics_v1';
  static const _foldersKey = 'audio_library_folders_v1';
  static const _bookmarksKey = 'audio_bookmarks_v1';

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
