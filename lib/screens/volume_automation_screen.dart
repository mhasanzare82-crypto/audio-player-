import 'package:flutter/material.dart';

import '../models/volume_automation_profile.dart';
import '../services/volume_automation_controller.dart';

class VolumeAutomationScreen extends StatefulWidget {
  const VolumeAutomationScreen({
    super.key,
    required this.initialProfile,
    required this.hasSavedProfile,
    required this.patterns,
    required this.sequence,
    required this.audioDurationMs,
    required this.controller,
    required this.onSave,
    required this.onSaveLibrary,
  });

  final VolumeAutomationProfile initialProfile;
  final bool hasSavedProfile;
  final List<VolumeAutomationPattern> patterns;
  final List<VolumeAutomationSequenceItem> sequence;
  final int audioDurationMs;
  final VolumeAutomationController controller;
  final Future<void> Function(VolumeAutomationProfile profile) onSave;
  final Future<void> Function(
    List<VolumeAutomationPattern> patterns,
    List<VolumeAutomationSequenceItem> sequence,
  ) onSaveLibrary;

  @override
  State<VolumeAutomationScreen> createState() => _VolumeAutomationScreenState();
}

class _VolumeAutomationScreenState extends State<VolumeAutomationScreen> {
  late VolumeAutomationProfile _profile;
  late VolumeAutomationProfile _savedProfile;
  late bool _hasSavedProfile;
  late List<VolumeAutomationPattern> _patterns;
  late List<VolumeAutomationSequenceItem> _sequence;
  String? _editingPatternId;
  late final TextEditingController _patternNameController;
  bool _hasUnsavedChanges = false;
  int _selectedPoint = 0;
  final List<Offset> _drawingOffsets = <Offset>[];
  bool _isDrawing = false;
  bool _saving = false;
  late final TextEditingController _hoursController;
  late final TextEditingController _minutesController;
  late final TextEditingController _secondsController;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    _savedProfile = widget.initialProfile;
    _hasSavedProfile = widget.hasSavedProfile;
    _patterns = List<VolumeAutomationPattern>.of(widget.patterns);
    _sequence = List<VolumeAutomationSequenceItem>.of(widget.sequence);
    _patternNameController = TextEditingController();
    final totalSeconds = (_profile.durationMs / 1000).round();
    _hoursController = TextEditingController(text: (totalSeconds ~/ 3600).toString());
    _minutesController = TextEditingController(text: ((totalSeconds % 3600) ~/ 60).toString());
    _secondsController = TextEditingController(text: (totalSeconds % 60).toString());
    widget.controller.isRunning.addListener(_handleRunningChanged);
  }

  void _handleRunningChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.isRunning.removeListener(_handleRunningChanged);
    _hoursController.dispose();
    _minutesController.dispose();
    _secondsController.dispose();
    _patternNameController.dispose();
    super.dispose();
  }

  bool get _isRunning => widget.controller.isRunning.value;

  void _setPoints(List<VolumeAutomationPoint> points) {
    final sorted = [...points]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    setState(() {
      _profile = _profile.copyWith(points: sorted);
      _hasUnsavedChanges = true;
      _selectedPoint = _selectedPoint.clamp(0, sorted.length - 1).toInt();
    });
  }

  Rect _plotRect(Size size) => Rect.fromLTRB(
        42,
        14,
        size.width - 14,
        size.height - 34,
      );

  void _beginFreehand(Offset position, Size size) {
    if (_isRunning) return;
    final plot = _plotRect(size);
    if (!plot.contains(position)) return;
    setState(() {
      _drawingOffsets
        ..clear()
        ..add(position);
      _isDrawing = true;
    });
  }

  void _appendFreehand(Offset position, Size size) {
    if (_isRunning || !_isDrawing) return;
    final plot = _plotRect(size);
    final point = Offset(
      position.dx.clamp(plot.left, plot.right).toDouble(),
      position.dy.clamp(plot.top, plot.bottom).toDouble(),
    );
    if (_drawingOffsets.isNotEmpty &&
        (point - _drawingOffsets.last).distance < 2.0) {
      return;
    }
    setState(() => _drawingOffsets.add(point));
  }

  void _finishFreehand(Size size) {
    if (!_isDrawing) return;
    final plot = _plotRect(size);
    final stroke = List<Offset>.of(_drawingOffsets);
    setState(() {
      _isDrawing = false;
      _drawingOffsets.clear();
    });
    if (stroke.length < 2) return;

    // The horizontal axis is elapsed time. Keep the user's stroke in
    // left-to-right order so the resulting profile is deterministic.
    final raw = <VolumeAutomationPoint>[];
    for (final offset in stroke) {
      final normalizedX =
          ((offset.dx - plot.left) / plot.width).clamp(0.0, 1.0);
      final normalizedY =
          (1 - (offset.dy - plot.top) / plot.height).clamp(0.0, 1.0) * 0.5;
      final timeMs = (normalizedX * _profile.durationMs).round();
      final sample = VolumeAutomationPoint(
        timeMs: timeMs,
        volume: normalizedY.toDouble(),
      );
      if (raw.isNotEmpty && timeMs < raw.last.timeMs) continue;
      if (raw.isNotEmpty && timeMs == raw.last.timeMs) {
        // Preserve the final vertical position when the finger moves without
        // advancing along the time axis.
        raw[raw.length - 1] = sample;
      } else {
        raw.add(sample);
      }
    }
    if (raw.length < 2) return;

    final points = <VolumeAutomationPoint>[
      if (raw.first.timeMs > 0)
        VolumeAutomationPoint(timeMs: 0, volume: raw.first.volume),
      ...raw,
    ];
    if (points.last.timeMs < _profile.durationMs) {
      points.add(VolumeAutomationPoint(
        timeMs: _profile.durationMs,
        volume: points.last.volume,
      ));
    } else if (points.last.timeMs > _profile.durationMs) {
      points[points.length - 1] = VolumeAutomationPoint(
        timeMs: _profile.durationMs,
        volume: points.last.volume,
      );
    }
    if (points.length < 2) return;
    _selectedPoint = 0;
    _setPoints(points);
  }

  void _clearDrawing() {
    if (_isRunning) return;
    _setPoints([
      const VolumeAutomationPoint(timeMs: 0, volume: 0.5),
      VolumeAutomationPoint(timeMs: _profile.durationMs, volume: 0.5),
    ]);
  }

  void _changeDuration() {
    if (_isRunning) return;
    final hours = int.tryParse(_hoursController.text) ?? 0;
    final minutes = int.tryParse(_minutesController.text) ?? 0;
    final seconds = int.tryParse(_secondsController.text) ?? 0;
    if (hours < 0 || hours > 99 ||
        minutes < 0 || minutes > 59 ||
        seconds < 0 || seconds > 59) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('زمان را درست وارد کن؛ دقیقه و ثانیه باید بین ۰ تا ۵۹ باشند.')),
      );
      return;
    }
    final nextDuration = ((hours * 3600) + (minutes * 60) + seconds) * 1000;
    if (nextDuration < 1000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('مدت نمودار باید حداقل یک ثانیه باشد.')),
      );
      return;
    }
    final oldDuration = _profile.durationMs;
    final scaled = _profile.points.map((point) {
      if (point.timeMs == 0) {
        return VolumeAutomationPoint(timeMs: 0, volume: point.volume);
      }
      if (point.timeMs == oldDuration) {
        return VolumeAutomationPoint(timeMs: nextDuration, volume: point.volume);
      }
      return VolumeAutomationPoint(
        timeMs: (point.timeMs / oldDuration * nextDuration).round(),
        volume: point.volume,
      );
    }).toList();
    final points = <VolumeAutomationPoint>[scaled.first];
    for (var i = 1; i < scaled.length - 1; i++) {
      final minimum = points.last.timeMs + 100;
      final maximum = nextDuration - (scaled.length - 1 - i) * 100;
      final time = scaled[i].timeMs.clamp(minimum, maximum).toInt();
      points.add(VolumeAutomationPoint(timeMs: time, volume: scaled[i].volume));
    }
    points.add(scaled.last);
    setState(() {
      _profile = VolumeAutomationProfile(
        durationMs: nextDuration,
        repeat: _profile.repeat,
        points: points,
      );
      _hasUnsavedChanges = true;
    });
  }

  Future<void> _saveProfile() async {
    setState(() => _saving = true);
    try {
      final name = _patternNameController.text.trim().isEmpty
          ? 'الگو ${_patterns.length + 1}'
          : _patternNameController.text.trim();
      final id = _editingPatternId ??
          DateTime.now().microsecondsSinceEpoch.toString();
      final pattern = VolumeAutomationPattern(
        id: id,
        name: name,
        profile: _profile,
      );
      final index = _patterns.indexWhere((item) => item.id == id);
      if (index < 0) {
        _patterns.add(pattern);
      } else {
        _patterns[index] = pattern;
      }
      await widget.onSave(_profile);
      await widget.onSaveLibrary(_patterns, _sequence);
      if (!mounted) return;
      setState(() {
        _editingPatternId = id;
        _savedProfile = _profile;
        _patternNameController.text = name;
        _hasSavedProfile = true;
        _hasUnsavedChanges = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الگو در کتابخانه ذخیره شد.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ذخیره الگو ناموفق بود: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _createNewPattern() {
    if (_isRunning) return;
    final fresh = VolumeAutomationProfile.defaultProfile;
    setState(() {
      _profile = fresh;
      _editingPatternId = null;
      _patternNameController.clear();
      _hoursController.text = '0';
      _minutesController.text = '0';
      _secondsController.text = '30';
      _hasUnsavedChanges = true;
    });
  }

  void _selectPattern(VolumeAutomationPattern pattern) {
    if (_isRunning) return;
    final seconds = (pattern.profile.durationMs / 1000).round();
    setState(() {
      _profile = pattern.profile;
      _savedProfile = pattern.profile;
      _editingPatternId = pattern.id;
      _patternNameController.text = pattern.name;
      _hoursController.text = (seconds ~/ 3600).toString();
      _minutesController.text = ((seconds % 3600) ~/ 60).toString();
      _secondsController.text = (seconds % 60).toString();
      _hasUnsavedChanges = false;
      _hasSavedProfile = true;
    });
  }

  Future<void> _persistLibrary() async {
    await widget.onSaveLibrary(_patterns, _sequence);
    if (mounted) setState(() {});
  }

  Future<void> _addToSequence(VolumeAutomationPattern pattern) async {
    if (widget.audioDurationMs <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ابتدا یک فایل صوتی را در پلیر انتخاب کن.')),
      );
      return;
    }
    setState(() {
      _sequence.add(VolumeAutomationSequenceItem(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        patternId: pattern.id,
      ));
    });
    await _persistLibrary();
  }

  Future<void> _removePattern(VolumeAutomationPattern pattern) async {
    setState(() {
      _patterns.removeWhere((item) => item.id == pattern.id);
      _sequence.removeWhere((item) => item.patternId == pattern.id);
      if (_editingPatternId == pattern.id) {
        _editingPatternId = null;
        _patternNameController.clear();
        _hasUnsavedChanges = true;
      }
      _hasSavedProfile = _patterns.isNotEmpty;
    });
    await _persistLibrary();
  }

  Future<void> _removeSequenceItem(VolumeAutomationSequenceItem item) async {
    setState(() => _sequence.removeWhere((entry) => entry.id == item.id));
    await _persistLibrary();
  }

  Future<void> _moveSequenceItem(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _sequence.length) return;
    setState(() {
      final item = _sequence.removeAt(index);
      _sequence.insert(target, item);
    });
    await _persistLibrary();
  }

  VolumeAutomationPattern? _patternForId(String id) {
    for (final pattern in _patterns) {
      if (pattern.id == id) return pattern;
    }
    return null;
  }

  String _durationLabel(int milliseconds) {
    final totalSeconds = (milliseconds / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes دقیقه و $seconds ثانیه';
  }

  void _setAutomationEnabled(bool enabled) {
    if (enabled) {
      if (!_hasSavedProfile || _hasUnsavedChanges) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ابتدا تغییرات نمودار را ذخیره کن، سپس آن را فعال کن.'),
          ),
        );
        return;
      }
      if (_sequence.isNotEmpty) {
        widget.controller.startSequence(
          sequence: _sequence,
          patterns: _patterns,
          audioDurationMs: widget.audioDurationMs,
        );
      } else {
        widget.controller.start(_savedProfile);
      }
    } else {
      widget.controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('نقشه تغییرات صدا'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              'منحنی دلخواهت را روی نمودار رسم کن',
              textDirection: TextDirection.rtl,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 5),
            Text(
              'محور افقی زمان و محور عمودی درصد صدای خروجی پلیر است.',
              textDirection: TextDirection.rtl,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 270,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) =>
                        _beginFreehand(details.localPosition, size),
                    onPanUpdate: (details) =>
                        _appendFreehand(details.localPosition, size),
                    onPanEnd: (_) => _finishFreehand(size),
                    onPanCancel: () => _finishFreehand(size),
                    child: CustomPaint(
                      size: size,
                      painter: _VolumeCurvePainter(
                        profile: _profile,
                        selectedPoint: -1,
                        drawingOffsets: List<Offset>.of(_drawingOffsets),
                        gridColor: colors.outlineVariant,
                        curveColor: colors.primary,
                        pointColor: colors.primary,
                        textColor: colors.onSurfaceVariant,
                        surfaceColor: colors.surface,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'انگشتت را از سمت چپ به راست روی نمودار بکش؛ مسیر رسم‌شده مستقیماً تغییرات صدا را تعیین می‌کند.',
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 18),
            const Align(
              alignment: Alignment.centerRight,
              child: Text('مدت کل نمودار (حداکثر ۹۹ ساعت و ۵۹ دقیقه و ۵۹ ثانیه)'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hoursController,
                    enabled: !_isRunning,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(labelText: 'ساعت', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _minutesController,
                    enabled: !_isRunning,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(labelText: 'دقیقه', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _secondsController,
                    enabled: !_isRunning,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(labelText: 'ثانیه', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _isRunning ? null : _changeDuration,
                icon: const Icon(Icons.schedule),
                label: const Text('اعمال مدت زمان'),
              ),
            ),
            TextField(
              controller: _patternNameController,
              enabled: !_isRunning,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(
                labelText: 'نام الگو',
                hintText: 'مثلاً شروع آرام یا افزایش تدریجی',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _isRunning ? null : _createNewPattern,
                icon: const Icon(Icons.add),
                label: const Text('ساخت الگوی تازه'),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('تکرار نمودار از ابتدا'),
              subtitle: Text(
                _profile.repeat
                    ? 'پس از پایان، نمودار دوباره اجرا می‌شود.'
                    : 'نمودار فقط یک بار اجرا می‌شود.',
              ),
              value: _profile.repeat,
              onChanged: _isRunning
                  ? null
                  : (value) => setState(() {
                        _profile = _profile.copyWith(repeat: value);
                        _hasUnsavedChanges = true;
                      }),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isRunning ? null : _clearDrawing,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('پاک‌کردن مسیر'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _saveProfile,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('ذخیره الگو'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'الگوهای ذخیره‌شده',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            if (_patterns.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('هنوز الگویی ذخیره نشده است.'),
              )
            else
              ..._patterns.map((pattern) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: IconButton(
                      tooltip: 'ویرایش الگو',
                      onPressed: _isRunning ? null : () => _selectPattern(pattern),
                      icon: Icon(
                        _editingPatternId == pattern.id
                            ? Icons.edit
                            : Icons.show_chart,
                      ),
                    ),
                    title: Text(pattern.name, textDirection: TextDirection.rtl),
                    subtitle: Text(_durationLabel(pattern.profile.durationMs)),
                    trailing: Wrap(
                      spacing: 0,
                      children: [
                        IconButton(
                          tooltip: 'افزودن به ترتیب پخش',
                          onPressed: _isRunning ? null : () => _addToSequence(pattern),
                          icon: const Icon(Icons.playlist_add),
                        ),
                        IconButton(
                          tooltip: 'حذف الگو',
                          onPressed: _isRunning ? null : () => _removePattern(pattern),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  )),
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'ترتیب اجرای الگوها برای این ویس',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            Text(
              widget.audioDurationMs > 0
                  ? 'مدت فایل صوتی: ${_durationLabel(widget.audioDurationMs)}'
                  : 'برای ساخت ترتیب پخش، ابتدا یک فایل صوتی انتخاب کن.',
              textDirection: TextDirection.rtl,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            if (_sequence.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('هنوز الگویی به ترتیب پخش این ویس اضافه نشده است.'),
              )
            else
              ..._sequence.asMap().entries.map((entry) {
                final index = entry.key;
                final item = entry.value;
                final pattern = _patternForId(item.patternId);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 13,
                    child: Text('${index + 1}'),
                  ),
                  title: Text(
                    pattern?.name ?? 'الگوی حذف‌شده',
                    textDirection: TextDirection.rtl,
                  ),
                  subtitle: Text(pattern == null
                      ? 'این الگو در دسترس نیست'
                      : _durationLabel(pattern.profile.durationMs)),
                  trailing: Wrap(
                    spacing: 0,
                    children: [
                      IconButton(
                        tooltip: 'بالا',
                        onPressed: _isRunning || index == 0
                            ? null
                            : () => _moveSequenceItem(index, -1),
                        icon: const Icon(Icons.arrow_upward, size: 19),
                      ),
                      IconButton(
                        tooltip: 'پایین',
                        onPressed: _isRunning || index == _sequence.length - 1
                            ? null
                            : () => _moveSequenceItem(index, 1),
                        icon: const Icon(Icons.arrow_downward, size: 19),
                      ),
                      IconButton(
                        tooltip: 'حذف از ترتیب',
                        onPressed: _isRunning ? null : () => _removeSequenceItem(item),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                );
              }),
            if (_sequence.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'اگر مجموع زمان الگوها از زمان ویس بیشتر باشد، زمان همه الگوها به یک نسبت فشرده می‌شود و شکل منحنی‌ها ثابت می‌ماند.',
                  textDirection: TextDirection.rtl,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ),
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: widget.controller.isRunning,
              builder: (context, running, _) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('اجرای نمودار ذخیره‌شده'),
                subtitle: Text(
                  running
                      ? 'فعال است؛ تغییرات نمودار روی صدای پلیر اعمال می‌شود.'
                      : (!_hasSavedProfile || _hasUnsavedChanges)
                          ? 'برای فعال‌سازی، ابتدا نمودار را ذخیره کن.'
                          : 'غیرفعال است؛ برای اجرای نمودار کلید را روشن کن.',
                ),
                value: running,
                onChanged: (!_hasSavedProfile || _hasUnsavedChanges) && !running
                    ? null
                    : _setAutomationEnabled,
              ),
            ),
            ValueListenableBuilder<double>(
              valueListenable: widget.controller.currentValue,
              builder: (context, value, _) {
                if (widget.controller.isRunning.value ||
                    (value - 1).abs() < 0.001) {
                  return const SizedBox.shrink();
                }
                return TextButton.icon(
                  onPressed: widget.controller.stop,
                  icon: const Icon(Icons.volume_up_rounded),
                  label: const Text('بازگردانی صدای پایه'),
                );
              },
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<double>(
              valueListenable: widget.controller.currentValue,
              builder: (context, value, _) => Text(
                'سطح فعلی نسبت به صدای پایه: ${(value * 100).round()}٪',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'این منحنی فقط صدای خروجی همین پلیر را کنترل می‌کند و صدای سایر برنامه‌های گوشی را تغییر نمی‌دهد.',
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VolumeCurvePainter extends CustomPainter {
  const _VolumeCurvePainter({
    required this.profile,
    required this.selectedPoint,
    required this.gridColor,
    required this.curveColor,
    required this.pointColor,
    required this.textColor,
    required this.surfaceColor,
    required this.drawingOffsets,
  });

  final VolumeAutomationProfile profile;
  final int selectedPoint;
  final Color gridColor;
  final Color curveColor;
  final Color pointColor;
  final Color textColor;
  final Color surfaceColor;
  final List<Offset> drawingOffsets;

  Rect _plotRect(Size size) => Rect.fromLTRB(
        42,
        14,
        size.width - 14,
        size.height - 34,
      );

  @override
  void paint(Canvas canvas, Size size) {
    final plot = _plotRect(size);
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = textColor
      ..strokeWidth = 1.2;

    for (var step = 0; step <= 4; step++) {
      final y = plot.top + plot.height * step / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _drawLabel(
        canvas,
        '${50 - step * 12.5}%',
        Offset(0, y - 8),
        textColor,
        width: 36,
      );
    }

    for (var step = 0; step <= 4; step++) {
      final x = plot.left + plot.width * step / 4;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
      final minutes = (profile.durationMs * step / 4 / 60000);
      final timeLabel = minutes == minutes.roundToDouble()
          ? '${minutes.round()}m'
          : '${minutes.toStringAsFixed(1)}m';
      _drawLabel(
        canvas,
        timeLabel,
        Offset(x - 18, plot.bottom + 8),
        textColor,
        width: 36,
      );
    }

    canvas.drawLine(Offset(plot.left, plot.top), Offset(plot.left, plot.bottom), axisPaint);
    canvas.drawLine(Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom), axisPaint);

    final path = Path();
    for (var i = 0; i < profile.points.length; i++) {
      final point = profile.points[i];
      final offset = Offset(
        plot.left + plot.width * point.timeMs / profile.durationMs,
        plot.bottom - plot.height * (point.volume / 0.5),
      );
      if (i == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = curveColor
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    for (var i = 0; i < profile.points.length; i++) {
      final point = profile.points[i];
      final offset = Offset(
        plot.left + plot.width * point.timeMs / profile.durationMs,
        plot.bottom - plot.height * (point.volume / 0.5),
      );
      canvas.drawCircle(
        offset,
        i == selectedPoint ? 8 : 3,
        Paint()..color = pointColor,
      );
    }

    if (drawingOffsets.isNotEmpty) {
      final preview = Path()..moveTo(drawingOffsets.first.dx, drawingOffsets.first.dy);
      for (final offset in drawingOffsets.skip(1)) {
        preview.lineTo(offset.dx, offset.dy);
      }
      canvas.drawPath(
        preview,
        Paint()
          ..color = curveColor
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset position,
    Color color, {
    required double width,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: width);
    painter.paint(canvas, position);
  }

  @override
  bool shouldRepaint(covariant _VolumeCurvePainter oldDelegate) {
    return oldDelegate.profile != profile ||
        oldDelegate.selectedPoint != selectedPoint ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.curveColor != curveColor ||
        oldDelegate.textColor != textColor ||
        oldDelegate.drawingOffsets != drawingOffsets;
  }
}
