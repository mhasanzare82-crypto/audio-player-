import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RadioStation {
  const _RadioStation({required this.id, required this.name, required this.url});
  final String id;
  final String name;
  final String url;

  Map<String, String> toJson() => {'id': id, 'name': name, 'url': url};

  factory _RadioStation.fromJson(Map<String, dynamic> json) => _RadioStation(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
      );
}

class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key});

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen>
    with AutomaticKeepAliveClientMixin<RadioScreen> {
  static const String _storageKey = 'internet_radio_stations_v1';
  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: false,
    handleAudioSessionActivation: !Platform.isAndroid,
  );
  final List<_RadioStation> _stations = [];
  String? _selectedStationId;
  bool _loadingStations = true;
  bool _startingPlayback = false;
  String? _playbackError;
  double _volume = 1;

  @override
  bool get wantKeepAlive => true;

  _RadioStation? get _selectedStation {
    for (final station in _stations) {
      if (station.id == _selectedStationId) return station;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _restoreStations();
  }

  Future<void> _restoreStations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _stations
            ..clear()
            ..addAll(decoded.whereType<Map>().map(
              (item) => _RadioStation.fromJson(Map<String, dynamic>.from(item)),
            ).where((station) {
              final uri = Uri.tryParse(station.url);
              return station.id.isNotEmpty &&
                  station.name.trim().isNotEmpty &&
                  uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
            }));
        }
      }
    } catch (error) {
      _playbackError = 'خواندن فهرست ایستگاه‌ها ناموفق بود: $error';
    } finally {
      if (mounted) setState(() => _loadingStations = false);
    }
  }

  Future<void> _saveStations() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _storageKey,
      jsonEncode(_stations.map((station) => station.toJson()).toList()),
    );
    if (!saved) throw StateError('ذخیره ایستگاه‌ها انجام نشد.');
  }

  Future<void> _showStationEditor({_RadioStation? station}) async {
    final nameController = TextEditingController(text: station?.name ?? '');
    final urlController = TextEditingController(text: station?.url ?? '');
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<_RadioStation>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(station == null ? 'افزودن ایستگاه رادیویی' : 'ویرایش ایستگاه'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  autofocus: true,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(
                    labelText: 'نام ایستگاه',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'نام ایستگاه را وارد کن.'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: urlController,
                  keyboardType: TextInputType.url,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'آدرس پخش (HTTPS)',
                    hintText: 'https://example.com/radio.mp3',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final uri = Uri.tryParse((value ?? '').trim());
                    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
                      return 'آدرس معتبر HTTPS وارد کن.';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                _RadioStation(
                  id: station?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
                  name: nameController.text.trim(),
                  url: urlController.text.trim(),
                ),
              );
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    nameController.dispose();
    urlController.dispose();
    if (result == null || !mounted) return;

    final index = _stations.indexWhere((item) => item.id == result.id);
    setState(() {
      if (index < 0) {
        _stations.add(result);
      } else {
        _stations[index] = result;
      }
      if (_selectedStationId == result.id && station?.url != result.url) {
        _selectedStationId = null;
      }
    });
    try {
      await _saveStations();
    } catch (error) {
      _showMessage('ذخیره ایستگاه ناموفق بود: $error');
    }
  }

  Future<void> _deleteStation(_RadioStation station) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف ایستگاه'),
        content: Text('ایستگاه «${station.name}» حذف شود؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_selectedStationId == station.id) await _stopPlayback();
    setState(() => _stations.removeWhere((item) => item.id == station.id));
    try {
      await _saveStations();
    } catch (error) {
      _showMessage('ذخیره تغییرات ناموفق بود: $error');
    }
  }

  Future<void> _playStation(_RadioStation station) async {
    if (_startingPlayback) return;
    setState(() {
      _startingPlayback = true;
      _playbackError = null;
      _selectedStationId = station.id;
    });
    try {
      await _player.stop();
      await _player.setUrl(station.url);
      await _player.setVolume(_volume);
      unawaited(_player.play());
    } catch (error) {
      if (mounted) setState(() => _playbackError = 'پخش این ایستگاه ممکن نشد: $error');
    } finally {
      if (mounted) setState(() => _startingPlayback = false);
    }
  }

  Future<void> _togglePlayback() async {
    if (_player.playing) {
      await _player.pause();
      return;
    }
    final station = _selectedStation;
    if (station == null) {
      _showMessage('ابتدا یک ایستگاه انتخاب کن.');
      return;
    }
    if (_player.processingState == ProcessingState.idle ||
        _player.processingState == ProcessingState.completed) {
      await _playStation(station);
    } else {
      unawaited(_player.play());
    }
  }

  Future<void> _stopPlayback() async {
    await _player.stop();
    if (mounted) {
      setState(() {
        _selectedStationId = null;
        _playbackError = null;
      });
    }
  }

  Future<void> _changeVolume(double value) async {
    setState(() => _volume = value);
    await _player.setVolume(value);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = Theme.of(context).colorScheme;
    final selected = _selectedStation;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'رادیو اینترنتی',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _showStationEditor(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('افزودن ایستگاه'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'رادیو پلیر مستقلی است و می‌تواند هم‌زمان با پلیر اصلی و بخش هوشمند پخش شود.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.radio_rounded, color: colors.primary, size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        selected?.name ?? 'هیچ ایستگاهی انتخاب نشده',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    StreamBuilder<PlayerState>(
                      stream: _player.playerStateStream,
                      builder: (context, snapshot) {
                        final state = snapshot.data;
                        final busy = _startingPlayback ||
                            state?.processingState == ProcessingState.loading ||
                            state?.processingState == ProcessingState.buffering;
                        return IconButton.filled(
                          tooltip: _player.playing ? 'مکث' : 'پخش',
                          onPressed: selected == null || busy ? null : _togglePlayback,
                          icon: busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(_player.playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: 'توقف',
                      onPressed: selected == null ? null : _stopPlayback,
                      icon: const Icon(Icons.stop_rounded),
                    ),
                  ],
                ),
                StreamBuilder<Duration?>(
                  stream: _player.durationStream,
                  builder: (context, durationSnapshot) {
                    return StreamBuilder<Duration>(
                      stream: _player.positionStream,
                      initialData: _player.position,
                      builder: (context, positionSnapshot) {
                        final duration = durationSnapshot.data;
                        final position = positionSnapshot.data ?? Duration.zero;
                        final total = duration?.inMilliseconds.toDouble() ?? 0;
                        final value = position.inMilliseconds
                            .toDouble()
                            .clamp(0.0, total > 0 ? total : 1.0)
                            .toDouble();
                        return Column(
                          children: [
                            Directionality(
                              textDirection: TextDirection.ltr,
                              child: Slider(
                                value: value,
                                min: 0,
                                max: total > 0 ? total : 1,
                                onChanged: duration == null || selected == null
                                    ? null
                                    : (next) => _player.seek(
                                          Duration(milliseconds: next.round()),
                                        ),
                              ),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_formatDuration(position),
                                    style: Theme.of(context).textTheme.labelSmall),
                                Text(
                                  duration == null ? 'پخش زنده' : _formatDuration(duration),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.volume_down_rounded, size: 20),
                    Expanded(
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: Slider(
                          value: _volume,
                          min: 0,
                          max: 1,
                          divisions: 100,
                          onChanged: _changeVolume,
                        ),
                      ),
                    ),
                    const Icon(Icons.volume_up_rounded, size: 20),
                    Text('${(_volume * 100).round()}٪'),
                  ],
                ),
                if (_playbackError != null) ...[
                  const SizedBox(height: 6),
                  Text(_playbackError!,
                      style: TextStyle(color: colors.error, fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(
              child: Text('ایستگاه‌های من',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            Text('${_stations.length} ایستگاه',
                style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: 6),
        if (_loadingStations)
          const Center(child: CircularProgressIndicator())
        else if (_stations.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                Icon(Icons.radio_outlined,
                    size: 42, color: colors.onSurfaceVariant),
                const SizedBox(height: 8),
                const Text('هنوز ایستگاهی اضافه نکرده‌ای.'),
                const SizedBox(height: 4),
                Text(
                  'برای شروع، نام ایستگاه و لینک مستقیم HTTPS آن را وارد کن.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          )
        else
          for (final station in _stations)
            Card(
              child: ListTile(
                leading: Icon(
                  _selectedStationId == station.id && _player.playing
                      ? Icons.graphic_eq_rounded
                      : Icons.radio_outlined,
                  color: _selectedStationId == station.id
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
                title: Text(station.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  station.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.ltr,
                ),
                onTap: () => _playStation(station),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') _showStationEditor(station: station);
                    if (value == 'delete') _deleteStation(station);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('ویرایش')),
                    PopupMenuItem(value: 'delete', child: Text('حذف')),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
