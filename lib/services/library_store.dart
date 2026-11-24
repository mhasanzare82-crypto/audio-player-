import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/audio_track.dart';

class LibraryStore {
  static const _tracksKey = 'audio_library_v1';
  static const _lyricsKey = 'audio_lyrics_v1';

  Future<List<AudioTrack>> loadTracks() async {
    final prefs = await SharedPreferences.getInstance();
    return AudioTrack.decodeList(prefs.getString(_tracksKey));
  }

  Future<void> saveTracks(List<AudioTrack> tracks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tracksKey, AudioTrack.encodeList(tracks));
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
