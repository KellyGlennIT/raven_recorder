import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/app_preferences.dart';
import '../services/scheduled_recording_service.dart';

class ScheduledRecordingsScreen extends StatefulWidget {
  const ScheduledRecordingsScreen({required this.preferences, super.key});

  final AppPreferences preferences;

  @override
  State<ScheduledRecordingsScreen> createState() => _ScheduledRecordingsScreenState();
}

class _ScheduledRecordingsScreenState extends State<ScheduledRecordingsScreen> {
  final ScheduledRecordingService _service = ScheduledRecordingService();
  final TextEditingController _titleController = TextEditingController();
  List<ScheduledRecording> _schedules = <ScheduledRecording>[];
  DateTime _selected = DateTime.now().add(const Duration(hours: 1));
  bool _busy = false;

  bool get _fr => widget.preferences.isFrench;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await _service.list();
    if (mounted) setState(() => _schedules = entries);
  }

  Future<void> _chooseDate() async {
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: _selected.isBefore(DateTime.now()) ? DateTime.now() : _selected,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
      helpText: _fr ? 'Choisir la date' : 'Choose date',
    );
    if (selectedDate == null || !mounted) return;
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_selected),
      helpText: _fr ? 'Choisir l’heure' : 'Choose time',
    );
    if (selectedTime == null || !mounted) return;
    final combined = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );
    setState(() => _selected = combined);
  }

  Future<void> _schedule() async {
    if (_busy) return;
    if (!_selected.isAfter(DateTime.now().add(const Duration(seconds: 10)))) {
      _message(_fr ? 'Choisissez une heure future.' : 'Choose a future date and time.');
      return;
    }
    setState(() => _busy = true);
    try {
      final title = _titleController.text.trim().isEmpty
          ? '${_fr ? 'Enregistrement programmé' : 'Scheduled recording'} · ${DateFormat('yyyy-MM-dd HH:mm').format(_selected)}'
          : _titleController.text.trim();
      await _service.create(title: title, at: _selected);
      _titleController.clear();
      await _load();
      if (mounted) _message(_fr ? 'Programmation enregistrée.' : 'Recording schedule saved.');
    } on ExactAlarmPermissionRequired {
      if (mounted) _message(_fr
          ? 'Activez « Alarmes et rappels » dans les paramètres Android, revenez ici, puis réessayez.'
          : 'Enable “Alarms & reminders” in Android settings, return here, and schedule again.');
    } catch (error) {
      if (mounted) _message(error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(ScheduledRecording entry) async {
    await _service.cancel(entry.id);
    await _load();
    if (mounted) _message(_fr ? 'Programmation annulée.' : 'Schedule cancelled.');
  }

  void _message(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateText = DateFormat('EEEE, d MMMM yyyy', _fr ? 'fr' : 'en').format(_selected);
    final timeText = DateFormat('HH:mm').format(_selected);
    return Scaffold(
      appBar: AppBar(title: Text(_fr ? 'Enregistrements programmés' : 'Scheduled recordings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(children: <Widget>[
                      Icon(Icons.event_available_rounded, size: 28, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_fr ? 'Programmer un enregistrement' : 'Schedule a recording', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
                    ]),
                    const SizedBox(height: 8),
                    Text(_fr
                        ? 'Choisissez une date et une heure. Si RAVEN est ouvert et déverrouillé à ce moment-là, il démarre automatiquement.'
                        : 'Choose a date and time. If RAVEN is open and unlocked at that moment, recording starts automatically.'),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _titleController,
                      maxLength: 80,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: _fr ? 'Nom de l’enregistrement (facultatif)' : 'Recording name (optional)',
                        prefixIcon: const Icon(Icons.edit_note_rounded),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _chooseDate,
                      icon: const Icon(Icons.calendar_month_rounded),
                      label: Text('$dateText  ·  $timeText'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _busy ? null : _schedule,
                      icon: _busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.alarm_add_rounded),
                      label: Text(_fr ? 'Enregistrer la programmation' : 'Save schedule'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(Icons.visibility_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(_fr
                          ? 'Important : Android limite le démarrage du microphone depuis une application inactive. Si RAVEN est en arrière-plan ou fermé, une notification visible et silencieuse apparaîtra à l’heure prévue ; touchez-la pour ouvrir RAVEN et démarrer. L’enregistrement reste clairement indiqué dans l’application. Les notifications doivent être autorisées.'
                          : 'Important: Android limits microphone starts from an inactive app. If RAVEN is in the background or closed, a visible, silent notification appears at the scheduled time; tap it to open RAVEN and start. Recording remains clearly indicated in the app. Notifications must be allowed.'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(_fr ? 'À venir' : 'Upcoming', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            if (_schedules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(children: <Widget>[
                  Icon(Icons.event_busy_rounded, size: 38, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 10),
                  Text(_fr ? 'Aucun enregistrement programmé.' : 'No scheduled recordings.', style: theme.textTheme.bodyLarge),
                ]),
              )
            else
              ..._schedules.map((entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.mic_none_rounded)),
                        title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(DateFormat('EEE, d MMM yyyy · HH:mm', _fr ? 'fr' : 'en').format(entry.scheduledAt)),
                        trailing: IconButton(
                          tooltip: _fr ? 'Annuler la programmation' : 'Cancel schedule',
                          onPressed: () => _cancel(entry),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    ),
                  )),
            if (!Platform.isAndroid)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _fr ? 'Sur cette plateforme, RAVEN doit rester ouvert pour déclencher l’enregistrement programmé.' : 'On this platform, RAVEN must remain open for a scheduled recording to trigger.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
