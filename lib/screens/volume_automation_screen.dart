import 'package:flutter/material.dart';

import '../models/volume_automation_profile.dart';
import '../services/volume_automation_controller.dart';

class VolumeAutomationScreen extends StatefulWidget {
  const VolumeAutomationScreen({
    super.key,
    required this.initialProfile,
    required this.controller,
    required this.onSave,
  });

  final VolumeAutomationProfile initialProfile;
  final VolumeAutomationController controller;
  final Future<void> Function(VolumeAutomationProfile profile) onSave;

  @override
  State<VolumeAutomationScreen> createState() => _VolumeAutomationScreenState();
}

class _VolumeAutomationScreenState extends State<VolumeAutomationScreen> {
  late VolumeAutomationProfile _profile;
  int _selectedPoint = 0;
  int? _draggingPoint;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    widget.controller.isRunning.addListener(_handleRunningChanged);
  }

  void _handleRunningChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.isRunning.removeListener(_handleRunningChanged);
    super.dispose();
  }

  bool get _isRunning => widget.controller.isRunning.value;

  void _setPoints(List<VolumeAutomationPoint> points) {
    final sorted = [...points]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    setState(() {
      _profile = _profile.copyWith(points: sorted);
      _selectedPoint = _selectedPoint.clamp(0, sorted.length - 1).toInt();
    });
  }

  Rect _plotRect(Size size) => Rect.fromLTRB(
        42,
        14,
        size.width - 14,
        size.height - 34,
      );

  int _nearestPoint(Offset position, Size size) {
    final plot = _plotRect(size);
    var nearest = -1;
    var distance = 26.0;
    for (var i = 0; i < _profile.points.length; i++) {
      final point = _profile.points[i];
      final pointOffset = Offset(
        plot.left + (point.timeMs / _profile.durationMs) * plot.width,
        plot.bottom - point.volume * plot.height,
      );
      final candidate = (pointOffset - position).distance;
      if (candidate < distance) {
        distance = candidate;
        nearest = i;
      }
    }
    return nearest;
  }

  void _addPoint(Offset position, Size size) {
    if (_isRunning || _profile.points.length >= 10) return;
    final plot = _plotRect(size);
    final x = ((position.dx - plot.left) / plot.width).clamp(0.0, 1.0);
    final y = (1 - (position.dy - plot.top) / plot.height).clamp(0.0, 1.0);
    final time = (x * _profile.durationMs).round();
    if (time <= 0 || time >= _profile.durationMs) return;
    if (_profile.points.any((point) => (point.timeMs - time).abs() < 250)) return;

    final points = [..._profile.points, VolumeAutomationPoint(
      timeMs: time,
      volume: y.toDouble(),
    )]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    _selectedPoint = points.indexWhere((point) => point.timeMs == time);
    _setPoints(points);
  }

  void _movePoint(Offset position, Size size) {
    final index = _draggingPoint;
    if (_isRunning || index == null) return;
    final plot = _plotRect(size);
    final old = _profile.points[index];
    var time = old.timeMs;
    if (index != 0 && index != _profile.points.length - 1) {
      final x = ((position.dx - plot.left) / plot.width).clamp(0.0, 1.0);
      final minimum = _profile.points[index - 1].timeMs + 100;
      final maximum = _profile.points[index + 1].timeMs - 100;
      time = (x * _profile.durationMs).round().clamp(minimum, maximum).toInt();
    }
    final volume = (1 - (position.dy - plot.top) / plot.height)
        .clamp(0.0, 1.0)
        .toDouble();
    final points = [..._profile.points];
    points[index] = VolumeAutomationPoint(timeMs: time, volume: volume);
    _setPoints(points);
  }

  void _removeSelectedPoint() {
    if (_isRunning ||
        _selectedPoint <= 0 ||
        _selectedPoint >= _profile.points.length - 1) {
      return;
    }
    final points = [..._profile.points]..removeAt(_selectedPoint);
    _selectedPoint = (_selectedPoint - 1).clamp(0, points.length - 1).toInt();
    _setPoints(points);
  }

  void _changeDuration(double seconds) {
    if (_isRunning) return;
    final nextDuration = seconds.round() * 1000;
    final oldDuration = _profile.durationMs;
    final scaled = _profile.points.map((point) {
      if (point.timeMs == 0) {
        return VolumeAutomationPoint(timeMs: 0, volume: point.volume);
      }
      if (point.timeMs == oldDuration) {
        return VolumeAutomationPoint(
          timeMs: nextDuration,
          volume: point.volume,
        );
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
      points.add(VolumeAutomationPoint(
        timeMs: time,
        volume: scaled[i].volume,
      ));
    }
    points.add(scaled.last);
    setState(() {
      _profile = VolumeAutomationProfile(
        durationMs: nextDuration,
        repeat: _profile.repeat,
        points: points,
      );
    });
  }

  Future<void> _saveProfile() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(_profile);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الگوی تغییرات صدا ذخیره شد.')),
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

  void _togglePlayback() {
    if (_isRunning) {
      widget.controller.stop();
    } else {
      widget.controller.start(_profile);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final durationSeconds = _profile.durationMs / 1000;
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
                    onTapDown: (details) {
                      if (_isRunning) return;
                      final nearest = _nearestPoint(details.localPosition, size);
                      if (nearest >= 0) {
                        setState(() => _selectedPoint = nearest);
                      } else {
                        _addPoint(details.localPosition, size);
                      }
                    },
                    onPanStart: (details) {
                      if (_isRunning) return;
                      var nearest = _nearestPoint(details.localPosition, size);
                      if (nearest < 0) {
                        _addPoint(details.localPosition, size);
                        nearest = _nearestPoint(details.localPosition, size);
                      }
                      if (nearest >= 0) {
                        setState(() {
                          _selectedPoint = nearest;
                          _draggingPoint = nearest;
                        });
                      }
                    },
                    onPanUpdate: (details) => _movePoint(
                      details.localPosition,
                      size,
                    ),
                    onPanEnd: (_) => setState(() => _draggingPoint = null),
                    onLongPressStart: (details) {
                      if (_isRunning) return;
                      final nearest = _nearestPoint(details.localPosition, size);
                      if (nearest > 0 &&
                          nearest < _profile.points.length - 1) {
                        setState(() => _selectedPoint = nearest);
                        _removeSelectedPoint();
                      }
                    },
                    child: CustomPaint(
                      size: size,
                      painter: _VolumeCurvePainter(
                        profile: _profile,
                        selectedPoint: _selectedPoint,
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
              'برای افزودن نقطه لمس کن؛ برای جابه‌جایی آن را بکش و برای حذف، چند لحظه نگه دار.',
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(child: Text('مدت کل نمودار')),
                Text('${durationSeconds.round()} ثانیه'),
              ],
            ),
            Slider(
              value: durationSeconds.clamp(1, 600).toDouble(),
              min: 1,
              max: 600,
              divisions: 599,
              label: '${durationSeconds.round()} ثانیه',
              onChanged: _isRunning ? null : _changeDuration,
            ),
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
                  : (value) => setState(
                        () => _profile = _profile.copyWith(repeat: value),
                      ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isRunning || _selectedPoint == 0 ||
                            _selectedPoint == _profile.points.length - 1
                        ? null
                        : _removeSelectedPoint,
                    icon: const Icon(Icons.remove_circle_outline),
                    label: const Text('حذف نقطه انتخابی'),
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
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: widget.controller.isRunning,
              builder: (context, running, _) => FilledButton.tonalIcon(
                onPressed: _togglePlayback,
                icon: Icon(running ? Icons.stop_rounded : Icons.play_arrow_rounded),
                label: Text(running ? 'توقف اجرای نمودار' : 'شروع پیش‌نمایش و اجرا'),
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<double>(
              valueListenable: widget.controller.currentValue,
              builder: (context, value, _) => Text(
                'ضریب فعلی منحنی: ${(value * 100).round()}٪',
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
  });

  final VolumeAutomationProfile profile;
  final int selectedPoint;
  final Color gridColor;
  final Color curveColor;
  final Color pointColor;
  final Color textColor;
  final Color surfaceColor;

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
        '${100 - step * 25}%',
        Offset(0, y - 8),
        textColor,
        width: 36,
      );
    }

    for (var step = 0; step <= 4; step++) {
      final x = plot.left + plot.width * step / 4;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
      final seconds = (profile.durationMs * step / 4 / 1000).round();
      _drawLabel(
        canvas,
        '${seconds}s',
        Offset(x - 18, plot.bottom + 8),
        textColor,
        width: 36,
      );
    }

    canvas.drawLine(Offset(plot.left, plot.top), Offset(plot.left, plot.bottom), axisPaint);
    canvas.drawLine(Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom), axisPaint);

    final path = Path();
    const samples = 180;
    for (var i = 0; i <= samples; i++) {
      final time = (profile.durationMs * i / samples).round();
      final value = profile.valueAt(time);
      final point = Offset(
        plot.left + plot.width * time / profile.durationMs,
        plot.bottom - plot.height * value,
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
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
        plot.bottom - plot.height * point.volume,
      );
      canvas.drawCircle(
        offset,
        i == selectedPoint ? 8 : 6,
        Paint()..color = pointColor,
      );
      canvas.drawCircle(
        offset,
        i == selectedPoint ? 3 : 2,
        Paint()..color = surfaceColor,
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
        oldDelegate.textColor != textColor;
  }
}
