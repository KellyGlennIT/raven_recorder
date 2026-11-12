import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:cryptography/cryptography.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/raven_project.dart';
import '../services/app_preferences.dart';
import '../services/attachment_service.dart';
import '../services/project_archive_service.dart';
import '../services/audio_encryption_service.dart';
import '../services/project_repository.dart';
import '../services/ai_provider_service.dart';
import '../services/ai_key_vault.dart';
import '../services/audio_visibility_service.dart';
import '../services/audio_share_service.dart';
import '../services/audio_protection_service.dart';
import '../services/document_export_service.dart';
import '../services/playback_service.dart';
import '../widgets/audio_password_dialog.dart';
import '../widgets/trim_editor.dart';
import 'recorder_screen.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    required this.project,
    required this.repository,
    required this.preferences,
    required this.onProjectChanged,
    super.key,
  });

  final RavenProject project;
  final ProjectRepository repository;
  final AppPreferences preferences;
  final ValueChanged<RavenProject> onProjectChanged;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  // Shared, app-wide player — playback survives navigating away from this
  // screen and backgrounding the app. Do NOT dispose here.
  AudioPlayer get _player => PlaybackService().player;

  final AudioEncryptionService _encryption = AudioEncryptionService();
  final TextEditingController _notesController = TextEditingController();
  late TabController _tabController;
  late RavenProject _project;
  bool _loading = true;
  bool _savingNotes = false;
  SecretKey? _audioKey;
  String? _error;
  String? _securityWarning;

  List<File> _attachments = const <File>[];

  int _activeIndex = 0;

  // --- Amplify -------------------------------------------------------------
  // Mirrors the standalone recording player: render a boosted copy of the
  // ACTIVE take with FFmpeg, play it in place, and let the user commit it as
  // that take's audio. Nothing touches the original file until "Save".
  bool _boostProcessing = false;
  bool _savingAmplified = false;
  double _volumeBoost = 1.0;
  String? _boostedPath;
  String? _boostedSessionId;

  bool get _canAmplify =>
      !_loading &&
      _error == null &&
      !_project.isTrashed &&
      !_project.isAudioProtected &&
      _session != null;

  @override
  void initState() {
    super.initState();
    _project = widget.project;
    _notesController.text = _project.notes;
    _notesController.addListener(_onNotesChanged);
    _tabController = TabController(length: 4, vsync: this);
    _activeIndex = _project.sessions.isEmpty ? 0 : _project.sessions.length - 1;
    _loadSelectedSession();
    _loadAttachments();
  }

  void _onNotesChanged() {
    if (mounted) setState(() {});
  }

  int get _notesWordCount {
    final text = _notesController.text.trim();
    if (text.isEmpty) return 0;
    return text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length;
  }

  int get _totalProjectDurationMs {
    return _project.sessions.fold<int>(0, (sum, s) => sum + s.durationMs);
  }

  Future<void> _seekRelative(int seconds) async {
    if (_project.sessions.isEmpty) return;
    final current = _player.position;
    final target = current + Duration(seconds: seconds);
    final maxDuration = Duration(milliseconds: _activeDurationMs);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > maxDuration ? maxDuration : target);
    await _player.seek(clamped);
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.id != widget.project.id) {
      _project = widget.project;
      _audioKey = null;
      _notesController.text = _project.notes;
      _activeIndex =
          _project.sessions.isEmpty ? 0 : _project.sessions.length - 1;
      _loadSelectedSession();
      _loadAttachments();
    }
  }

  @override
  void dispose() {
    _notesController.removeListener(_onNotesChanged);
    _notesController.dispose();
    _tabController.dispose();
    // Boosted audio lives only in the temp cache and is never committed unless
    // the user taps Save, so it is always safe to drop on the way out.
    unawaited(_deleteBoostedFile());
    // NOTE: do NOT dispose `_player` here — it's global and used for
    // background playback. `AudioEncryptionService.cleanupAbandonedPlaybackFiles()`
    // on next launch cleans any leftover temp decrypted files.
    super.dispose();
  }

  RavenAudioSession? get _session => _project.sessions.isEmpty
      ? null
      : _project.sessions[_activeIndex.clamp(0, _project.sessions.length - 1)];

  /// Album art for the media notification:
  /// 1. The project's first image attachment, if any.
  /// 2. Otherwise the RAVEN logo, cached to a temp file.
  Future<Uri?> _artUriForSession(RavenAudioSession session) async {
    final images = _attachments.where(_isImageAttachment);
    if (images.isNotEmpty) {
      return Uri.file(images.first.path);
    }
    try {
      final temp = await getTemporaryDirectory();
      final cached = File('${temp.path}/raven_notification_logo.png');
      if (!await cached.exists()) {
        final bytes = await rootBundle.load('assets/images/raven_logo.png');
        await cached.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      }
      return Uri.file(cached.path);
    } catch (_) {
      return null;
    }
  }

  /// Builds the [MediaItem] shown in the notification for [session].
  Future<MediaItem> _mediaItemFor(
    RavenAudioSession session, {
    String? overrideTitle,
  }) async {
    final sessionNumber =
        _project.sessions.indexWhere((s) => s.id == session.id) + 1;
    final title = overrideTitle ??
        (session.name.isEmpty
            ? tr(widget.preferences, 'Recording $sessionNumber',
                'Enregistrement $sessionNumber')
            : session.name);
    return MediaItem(
      id: session.id,
      title: title,
      album: _project.title,
      duration: Duration(milliseconds: session.durationMs),
      artUri: await _artUriForSession(session),
    );
  }

  Future<void> _loadAttachments() async {
    try {
      final files = await AttachmentService(widget.repository).list(_project.id);
      if (!mounted) return;
      setState(() => _attachments = files);
    } catch (_) {
      if (mounted) setState(() => _attachments = const <File>[]);
    }
  }

  Future<void> _playRecording(int index) async {
    if (_project.sessions.isEmpty) return;
    final target = index.clamp(0, _project.sessions.length - 1);
    if (target == _activeIndex && !_loading && _error == null) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    setState(() => _activeIndex = target);
    final loaded = await _loadSelectedSession();
    if (loaded && mounted) await _player.play();
  }

  Future<void> _toggleAudioEncryption() async {
    if (_loading) return;
    final enabling = !_project.isAudioProtected;
    String? password;
    SecretKey? key;
    if (enabling) {
      password = await showAudioPasswordDialog(
        context,
        preferences: widget.preferences,
        createPassword: true,
      );
      if (password == null || !mounted) return;
    } else if (_project.audioProtectionSalt != null) {
      key = await _requestAudioKey();
      if (key == null || !mounted) return;
    }

    setState(() => _loading = true);
    try {
      await _player.stop();
      final service = AudioProtectionService(repository: widget.repository);
      final updated = enabling
          ? await service.encrypt(_project, password!)
          : await service.decrypt(_project, key: key);
      if (enabling) {
        key = await _encryption.derivePasswordKey(
            password!, updated.audioProtectionSalt!);
      }
      if (!mounted) return;
      setState(() {
        _project = updated;
        _audioKey = enabling ? key : null;
      });
      widget.onProjectChanged(updated);
      await _loadSelectedSession();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          enabling
              ? 'Audio locked with your password. RAVEN did not store it.'
              : 'Audio unlocked. The app PIN was not changed.',
          enabling
              ? 'Audio verrouillé avec votre mot de passe. RAVEN ne l’a pas enregistré.'
              : 'Audio déverrouillé. Le code PIN de l’application est inchangé.',
        )),
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not change audio encryption', 'Impossible de modifier le chiffrement audio')}: $error'),
      ));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<SecretKey?> _requestAudioKey() async {
    final existingKey = _audioKey;
    if (existingKey != null) return existingKey;
    final salt = _project.audioProtectionSalt;
    if (salt == null) return null;
    while (mounted) {
      final password = await showAudioPasswordDialog(
        context, // ignore: use_build_context_synchronously
        preferences: widget.preferences,
        createPassword: false,
      );
      if (password == null || !mounted) return null;
      final key = await _encryption.derivePasswordKey(password, salt);
      final session = _project.sessions.first;
      final source = File(session.audioPath);
      final directory = await getTemporaryDirectory();
      final temporary = File(
          '${directory.path}/raven-password-check-${_project.id}-${session.id}.${session.format}');
      try {
        await _encryption.decryptFile(
            input: source, output: temporary, key: key);
        return key;
      } on AudioPasswordException {
        if (!mounted) return null;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'That audio password is incorrect. Try again.',
            'Mot de passe incorrect. Réessayez.',
          )),
        ));
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    return null;
  }

  int _globalPositionMs(int? index, Duration localPosition) =>
      localPosition.inMilliseconds;

  Future<void> _seekGlobal(int milliseconds) async {
    if (_project.sessions.isEmpty) return;
    await _player.seek(Duration(milliseconds: milliseconds));
  }

  int get _activeDurationMs {
    final session = _session;
    if (session == null) return 0;
    final playerDuration = _player.duration?.inMilliseconds ?? 0;
    return playerDuration > 0 ? playerDuration : session.durationMs;
  }

  Future<bool> _loadSelectedSession() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _securityWarning = null;
      });
    }
    var loaded = false;
    try {
      if (_project.sessions.isEmpty) {
        _error = tr(
            widget.preferences,
            'This project has no audio session yet.',
            'Ce projet ne contient pas encore de session audio.');
        return false;
      }

      if (_project.isAudioProtected && _project.audioProtectionSalt != null) {
        _audioKey ??= await _requestAudioKey();
        if (_audioKey == null) {
          _error = tr(
            widget.preferences,
            'Enter the audio password to play this recording.',
            'Saisissez le mot de passe audio pour lire cet enregistrement.',
          );
          return false;
        }
      }

      final cache = await getTemporaryDirectory();
      final masterPath = _project.masterAudioPath;
      final masterExists =
          masterPath != null && await File(masterPath).exists();

      if (masterPath != null && (_project.isAudioProtected || !masterExists)) {
        if (_project.isAudioProtected && masterExists) {
          try {
            await File(masterPath).delete();
          } on FileSystemException {
            // A later cleanup may succeed after the player releases handles.
          }
        }
        final withoutMaster = _project.copyWith(clearMasterAudioPath: true);
        try {
          await _saveProject(withoutMaster);
        } catch (_) {
          _project = withoutMaster;
          widget.onProjectChanged(withoutMaster);
        }
      }

      final selected = _session;
      if (selected == null) {
        _error = tr(
            widget.preferences,
            'This project has no audio session yet.',
            'Ce projet ne contient pas encore de session audio.');
        return false;
      }

      final useMaster = masterPath != null &&
          !_project.isAudioProtected &&
          masterExists &&
          _project.sessions.length == 1;
      if (useMaster) {
        try {
          final mediaItem = await _mediaItemFor(
            selected,
            overrideTitle: _project.title,
          );
          await _player.setAudioSource(
            AudioSource.uri(Uri.file(masterPath), tag: mediaItem),
            initialPosition: Duration.zero,
          );
          loaded = true;
        } catch (_) {
          try {
            await _player.stop();
          } catch (_) {
            // Best-effort: a failed stop leaves the player in an
            // inconsistent state but the fallback session path works.
          }
          final withoutMaster = _project.copyWith(clearMasterAudioPath: true);
          try {
            await _saveProject(withoutMaster);
          } catch (_) {
            _project = withoutMaster;
            widget.onProjectChanged(withoutMaster);
          }
        }
      }

      if (!loaded) {
        final source = File(selected.audioPath);
        if (!await source.exists()) {
          throw FileSystemException(
              'The selected recording is missing', source.path);
        }
        var playbackPath = selected.audioPath;
        if (_project.isAudioProtected) {
          final extension = selected.format == 'wav'
              ? 'wav'
              : selected.format == 'flac'
                  ? 'flac'
                  : 'm4a';
          final temp = File(
              '${cache.path}/raven-playback-${_project.id}-${selected.id}.$extension');
          if (await temp.exists()) await temp.delete();
          await _encryption.decryptFile(
              input: source, output: temp, key: _audioKey);
          PlaybackService().registerTemp(temp.path);
          playbackPath = temp.path;
        }
        final mediaItem = await _mediaItemFor(selected);
        await _player.setAudioSource(
          AudioSource.uri(Uri.file(playbackPath), tag: mediaItem),
          initialPosition: Duration.zero,
        );
        loaded = true;
      }

      if (loaded && _project.isAudioProtected) {
        var cleanupFailed = false;
        for (final audioSession in _project.sessions) {
          if (!audioSession.audioPath.endsWith('.ravenenc')) continue;
          final plaintextPath = audioSession.audioPath.substring(
            0,
            audioSession.audioPath.length - '.ravenenc'.length,
          );
          try {
            final plaintext = File(plaintextPath);
            if (await plaintext.exists()) await plaintext.delete();
            if (await plaintext.exists()) cleanupFailed = true;
          } catch (_) {
            cleanupFailed = true;
          }
        }
        if (masterPath != null && masterExists) {
          try {
            final plaintextMaster = File(masterPath);
            if (await plaintextMaster.exists()) await plaintextMaster.delete();
            if (await plaintextMaster.exists()) cleanupFailed = true;
          } catch (_) {
            cleanupFailed = true;
          }
        }
        if (cleanupFailed) {
          _securityWarning = tr(
            widget.preferences,
            'Protection is enabled, but RAVEN could not remove every old plaintext file. Check the private project folder and remove any unencrypted copies after backing up your data.',
            'La protection est activée, mais RAVEN n’a pas pu supprimer tous les anciens fichiers non chiffrés. Vérifiez le dossier privé et supprimez les copies non chiffrées après avoir sauvegardé vos données.',
          );
        }
      }
      return true;
    } catch (error) {
      _error =
          '${tr(widget.preferences, 'Could not open audio', 'Impossible d’ouvrir l’audio')}: $error';
      return false;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _manageAttachments() async {
    final service = AttachmentService(widget.repository);
    final messenger = ScaffoldMessenger.of(context);
    try {
      var files = await service.list(_project.id);
      if (!mounted) return;
      var selection = <String>{};
      var selecting = false;

      Future<void> reload(StateSetter refresh) async {
        files = await service.list(_project.id);
        selection.retainWhere((path) => files.any((file) => file.path == path));
        if (selection.isEmpty) selecting = false;
        refresh(() {});
      }

      Future<void> removeSelected(StateSetter refresh) async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(tr(widget.preferences, 'Remove attachments?',
                'Supprimer les pièces jointes ?')),
            content: Text(tr(
                widget.preferences,
                '${selection.length} attachment(s) will be permanently removed from this project.',
                '${selection.length} pièce(s) jointe(s) seront définitivement supprimées de ce projet.')),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(tr(widget.preferences, 'Remove', 'Supprimer')),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        for (final file in List<File>.from(files)) {
          if (selection.contains(file.path)) await service.remove(file);
        }
        selection.clear();
        selecting = false;
        await reload(refresh);
        if (!mounted) return;
        messenger.showSnackBar(SnackBar(
            content: Text(tr(widget.preferences, 'Attachments removed',
                'Pièces jointes supprimées'))));
      }

      Future<void> shareSelected() async {
        final chosen = files.where((f) => selection.contains(f.path)).toList();
        try {
          await AudioShareService().shareFiles(chosen);
        } catch (error) {
          if (!mounted) return;
          messenger.showSnackBar(SnackBar(
            content: Text(
                '${tr(widget.preferences, 'Could not share files', 'Impossible de partager les fichiers')}: $error'),
          ));
        }
      }

      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => StatefulBuilder(
          builder: (sheetContext, refresh) => SafeArea(
            child: SizedBox(
              height: MediaQuery.of(sheetContext).size.height * 0.72,
              child: Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                              tr(widget.preferences, 'Project attachments',
                                  'Pièces jointes du projet'),
                              style:
                                  Theme.of(sheetContext).textTheme.titleLarge),
                        ),
                        if (files.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => refresh(() {
                              if (!selecting) {
                                selecting = true;
                                selection = files.map((f) => f.path).toSet();
                              } else {
                                selecting = false;
                                selection.clear();
                              }
                            }),
                            icon: Icon(selecting
                                ? Icons.deselect_rounded
                                : Icons.select_all_rounded),
                            label: Text(selecting
                                ? tr(widget.preferences, 'Clear', 'Effacer')
                                : tr(widget.preferences, 'Select all',
                                    'Tout sélectionner')),
                          ),
                      ],
                    ),
                  ),
                  if (selection.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: <Widget>[
                          Text(tr(
                              widget.preferences,
                              '${selection.length} selected',
                              '${selection.length} sélectionné(s)')),
                          const Spacer(),
                          IconButton(
                            tooltip: tr(widget.preferences, 'Share selected',
                                'Partager la sélection'),
                            onPressed: shareSelected,
                            icon: const Icon(Icons.share_rounded),
                          ),
                          IconButton(
                            tooltip: tr(widget.preferences, 'Remove selected',
                                'Supprimer la sélection'),
                            onPressed: () => removeSelected(refresh),
                            icon: Icon(Icons.delete_outline_rounded,
                                color:
                                    Theme.of(sheetContext).colorScheme.error),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: files.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                tr(
                                    widget.preferences,
                                    'No attachments yet. Use Add files to attach documents or images.',
                                    'Aucune pièce jointe. Utilisez Ajouter des fichiers pour joindre des documents ou des images.'),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: files.length,
                            itemBuilder: (context, index) {
                              final file = files[index];
                              final isSelected = selection.contains(file.path);
                              return ListTile(
                                leading: _isImageAttachment(file)
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.file(
                                          file,
                                          width: 52,
                                          height: 52,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              const Icon(
                                                  Icons.broken_image_outlined),
                                        ),
                                      )
                                    : Icon(_iconForFile(file)),
                                title: Text(file.uri.pathSegments.last,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle:
                                    Text(_formatBytes(file.lengthSync())),
                                selected: isSelected,
                                onTap: () {
                                  if (selecting) {
                                    refresh(() {
                                      if (isSelected) {
                                        selection.remove(file.path);
                                      } else {
                                        selection.add(file.path);
                                      }
                                      if (selection.isEmpty) {
                                        selecting = false;
                                      }
                                    });
                                  } else if (_isImageAttachment(file)) {
                                    _previewAttachment(sheetContext, file);
                                  } else {
                                    refresh(() {
                                      selecting = true;
                                      selection.add(file.path);
                                    });
                                  }
                                },
                                onLongPress: () => refresh(() {
                                  selecting = true;
                                  selection.add(file.path);
                                }),
                                trailing: isSelected
                                    ? const Icon(Icons.check_circle_rounded)
                                    : PopupMenuButton<String>(
                                        tooltip: tr(
                                            widget.preferences,
                                            'File actions',
                                            'Actions du fichier'),
                                        onSelected: (action) async {
                                          if (action == 'share') {
                                            try {
                                              await AudioShareService()
                                                  .shareFile(file);
                                            } catch (error) {
                                              if (!mounted) return;
                                              messenger.showSnackBar(SnackBar(
                                                content: Text(
                                                    '${tr(widget.preferences, 'Could not share file', 'Impossible de partager le fichier')}: $error'),
                                              ));
                                            }
                                          } else if (action == 'remove') {
                                            selection = {file.path};
                                            await removeSelected(refresh);
                                          }
                                        },
                                        itemBuilder: (context) =>
                                            <PopupMenuEntry<String>>[
                                          PopupMenuItem<String>(
                                            value: 'share',
                                            child: Text(tr(
                                                widget.preferences,
                                                'Share file',
                                                'Partager le fichier')),
                                          ),
                                          PopupMenuItem<String>(
                                            value: 'remove',
                                            child: Text(tr(
                                                widget.preferences,
                                                'Remove attachment',
                                                'Supprimer la pièce jointe')),
                                          ),
                                        ],
                                      ),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      onPressed: () async {
                        await service.pickAndAttach(_project.id);
                        await reload(refresh);
                      },
                      icon: const Icon(Icons.add_rounded),
                      label: Text(tr(widget.preferences, 'Add files',
                          'Ajouter des fichiers')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await _loadAttachments();
    } catch (error) {
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr(widget.preferences, 'Could not manage attachments', 'Impossible de gérer les pièces jointes')}: $error')));
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  bool _isImageAttachment(File file) {
    final path = file.path.toLowerCase();
    return path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.png') ||
        path.endsWith('.gif') ||
        path.endsWith('.webp') ||
        path.endsWith('.bmp');
  }

  IconData _iconForFile(File file) {
    final p = file.path.toLowerCase();
    if (p.endsWith('.pdf')) return Icons.picture_as_pdf_rounded;
    if (p.endsWith('.mp3') ||
        p.endsWith('.m4a') ||
        p.endsWith('.wav') ||
        p.endsWith('.flac') ||
        p.endsWith('.ogg')) {
      return Icons.audiotrack_rounded;
    }
    if (p.endsWith('.mp4') || p.endsWith('.mov') || p.endsWith('.mkv')) {
      return Icons.videocam_rounded;
    }
    if (p.endsWith('.txt') || p.endsWith('.md')) {
      return Icons.description_rounded;
    }
    if (p.endsWith('.doc') || p.endsWith('.docx')) return Icons.article_rounded;
    if (p.endsWith('.xls') || p.endsWith('.xlsx')) {
      return Icons.table_chart_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  Future<void> _previewAttachment(BuildContext context, File file) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        child: SafeArea(
          child: Stack(
            children: <Widget>[
              Center(
                child: InteractiveViewer(
                  child: Image.file(
                    file,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Center(
                      child: Text(tr(
                          widget.preferences,
                          'Image could not be opened',
                          'Impossible d’ouvrir l’image')),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton.filledTonal(
                  tooltip: tr(widget.preferences, 'Close', 'Fermer'),
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAttachment(File file) async {
    if (_isImageAttachment(file)) {
      await _previewAttachment(context, file);
    } else {
      await _manageAttachments();
    }
  }

  Future<void> _continueRecording() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (_project.isAudioProtected) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr(
              widget.preferences,
              'Decrypt this project before continuing its recording.',
              'Déchiffrez ce projet avant de poursuivre son enregistrement.'))));
      return;
    }
    await _player.pause();
    await navigator.push<void>(MaterialPageRoute<void>(
      builder: (_) => RecorderScreen(
        repository: widget.repository,
        preferences: widget.preferences,
        existingProject: _project,
        createProject: true,
        onSaved: () {},
      ),
    ));
    if (!mounted) return;
    final refreshed = widget.repository.projectById(_project.id);
    if (refreshed != null) {
      setState(() {
        _project = refreshed;
        _activeIndex = refreshed.sessions.isEmpty
            ? 0
            : refreshed.sessions.length - 1;
      });
      widget.onProjectChanged(refreshed);
      await _loadSelectedSession();
      await _loadAttachments();
    }
  }

  Future<void> _resumeSession(RavenAudioSession session) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (_project.isAudioProtected) {
      messenger.showSnackBar(SnackBar(
          content: Text(tr(
              widget.preferences,
              'Decrypt this project before resuming its recording.',
              'Déchiffrez ce projet avant de reprendre son enregistrement.'))));
      return;
    }
    await _player.pause();
    await navigator.push<void>(MaterialPageRoute<void>(
      builder: (_) => RecorderScreen(
        repository: widget.repository,
        preferences: widget.preferences,
        existingProject: _project,
        resumeSessionId: session.id,
        createProject: true,
        onSaved: () {},
      ),
    ));
    if (!mounted) return;
    final refreshed = widget.repository.projectById(_project.id);
    if (refreshed != null) {
      setState(() {
        _project = refreshed;
        if (_activeIndex >= refreshed.sessions.length) {
          _activeIndex = refreshed.sessions.length - 1;
        }
      });
      widget.onProjectChanged(refreshed);
      await _loadSelectedSession();
      await _loadAttachments();
    }
  }

  Future<void> _exportProjectBundle() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ProjectArchiveService(widget.repository).shareProject(_project);
    } catch (error) {
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr(widget.preferences, 'Project export failed', 'Échec de l’exportation du projet')}: $error')));
    }
  }

  Future<void> _shareRecordingAudio() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await AudioShareService().shareRecording(_project, key: _audioKey);
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not share recording audio', 'Impossible de partager l’audio')}: $error'),
      ));
    }
  }

  Future<void> _exportNotesTxt() async {
    final messenger = ScaffoldMessenger.of(context);
    final notes = _notesController.text;
    if (notes.trim().isEmpty) {
      messenger.showSnackBar(SnackBar(
        content: Text(tr(
            widget.preferences,
            'There are no notes to save yet. Write something first.',
            'Aucune note à enregistrer. Écrivez d’abord quelque chose.')),
      ));
      return;
    }
    try {
      await _saveProject(_project.copyWith(notes: notes));
      final fileName = DocumentExportService.safeFileName(
          '${_project.title.trim()} notes');

      final projectFolder =
          await widget.repository.ensureProjectFolder(_project);
      final notesDirectory = Directory('${projectFolder.path}/notes');
      await notesDirectory.create(recursive: true);
      final notesFile = File('${notesDirectory.path}/$fileName.txt');
      await notesFile.writeAsBytes(
          DocumentExportService.utf8WithBom(notes), flush: true);
      if (!mounted) return;

      messenger.showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          'Notes saved as “$fileName.txt” inside this project’s folder.',
          'Notes enregistrées dans « $fileName.txt » dans le dossier de ce projet.',
        )),
        action: SnackBarAction(
          label: tr(widget.preferences, 'Share', 'Partager'),
          onPressed: () => AudioShareService().shareFile(notesFile),
        ),
      ));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save notes as a .txt file: $error')),
      );
    }
  }

  Future<void> _handleProjectAction(String action) async {
    switch (action) {
      case 'bookmark':
        await _addBookmark();
      case 'attachments':
        await _manageAttachments();
      case 'share_audio':
        await _shareRecordingAudio();
      case 'visibility':
        await _togglePublicCopy();
      case 'export':
        await _exportProjectBundle();
      case 'notes_txt':
        await _exportNotesTxt();
      case 'rename':
        await _renameProject();
      case 'pin':
        await _toggleProjectPin();
      case 'encryption':
        await _toggleAudioEncryption();
    }
  }

  Future<void> _handleSessionAction(
      String action, RavenAudioSession session, int index) async {
    switch (action) {
      case 'play':
        await _playRecording(index);
      case 'resume':
        await _resumeSession(session);
      case 'share':
        try {
          await AudioShareService()
              .shareSession(_project, session, key: _audioKey);
        } catch (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not share recording session: $error'),
          ));
        }
      case 'details':
        await _showSessionDetails(session, index);
      case 'rename':
        await _renameSession(session, index);
      case 'trim':
        await _trimSession(session, index);
      case 'delete':
        await _deleteSession(session, index);
    }
  }

  /// Opens the trim editor for one take. The editor asks the user whether to
  /// replace the take's audio or keep both; either way the project record is
  /// updated here with the real new duration and path.
  Future<void> _trimSession(
      RavenAudioSession session, int index) async {
    if (_loading || _project.isAudioProtected) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    final source = File(session.audioPath);
    if (!await source.exists()) {
      messenger?.showSnackBar(SnackBar(
        content: Text(tr(widget.preferences,
            'The recording file is missing.', 'Le fichier audio est absent.')),
      ));
      return;
    }
    try {
      await _player.stop();
    } catch (_) {}
    if (!mounted) return;

    final result = await navigator.push<TrimEditorResult>(
      MaterialPageRoute<TrimEditorResult>(
        fullscreenDialog: true,
        builder: (_) => TrimEditor(
          source: source,
          format: session.format,
          durationMs: session.durationMs > 0
              ? session.durationMs
              : _activeDurationMs,
          bitRate: session.bitRate,
          sampleRate: session.sampleRate > 0 ? session.sampleRate : 44100,
          title: session.name.isEmpty
              ? tr(widget.preferences, 'Take ${index + 1}',
                  'Prise ${index + 1}')
              : session.name,
          isFrench: widget.preferences.isFrench,
        ),
      ),
    );
    if (result == null || !mounted) return;

    try {
      // copyWith has no `id`, so a new take gets a fresh session object.
      final trimmedSession = result.replacedOriginal
          ? session.copyWith(
              audioPath: result.file.path,
              durationMs: result.durationMs,
              // Format never changes: the trim preserves the source container.
              recoverablePcm16: false,
            )
          : RavenAudioSession(
              id: const Uuid().v4(),
              audioPath: result.file.path,
              createdAt: DateTime.now(),
              durationMs: result.durationMs,
              format: session.format,
              name:
                  '${session.name.isEmpty ? tr(widget.preferences, 'Take ${index + 1}', 'Prise ${index + 1}') : session.name} · ${tr(widget.preferences, 'trimmed', 'rogné')}',
              sampleRate: session.sampleRate,
              bitRate: session.bitRate,
            );

      final sessions = List<RavenAudioSession>.of(_project.sessions);
      if (result.replacedOriginal) {
        sessions[index] = trimmedSession;
        try {
          final old = File(session.audioPath);
          if (await old.exists() && old.path != result.file.path) {
            await old.delete();
          }
        } catch (_) {}
      } else {
        // Keep the original untouched and add the trimmed copy as a new take.
        sessions.insert(index + 1, trimmedSession);
      }

      await _saveProject(_project.copyWith(
        sessions: sessions,
        clearMasterAudioPath: true,
      ));
      messenger?.showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          result.replacedOriginal
              ? 'Recording trimmed in place.'
              : 'Trimmed copy saved as a new take.',
          result.replacedOriginal
              ? 'Enregistrement rogné.'
              : 'Copie rognée enregistrée comme nouvelle prise.',
        )),
      ));
    } catch (error) {
      messenger?.showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not save the trim', 'Impossible d’enregistrer le rognage')}: $error'),
      ));
    }
  }

  Future<void> _showSessionDetails(RavenAudioSession session, int index) async {
    final file = File(session.audioPath);
    final exists = await file.exists();
    final size = exists ? await file.length() : null;
    if (!mounted) return;
    final createdAt = DateFormat(
      'dd MMM yyyy, HH:mm',
      widget.preferences.isFrench ? 'fr' : 'en',
    ).format(session.createdAt);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(session.name.isEmpty
            ? tr(widget.preferences, 'Session ${index + 1}',
                'Session ${index + 1}')
            : session.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _detailRow(tr(widget.preferences, 'Created', 'Créé'), createdAt),
            _detailRow(
              tr(widget.preferences, 'Duration', 'Durée'),
              _formatDuration(session.durationMs),
            ),
            _detailRow(
              tr(widget.preferences, 'Format', 'Format'),
              session.format.toUpperCase(),
            ),
            _detailRow(
              tr(widget.preferences, 'Sample rate', 'Fréquence'),
              '${session.sampleRate} Hz',
            ),
            _detailRow(
              tr(widget.preferences, 'File size', 'Taille du fichier'),
              size == null
                  ? tr(widget.preferences, 'Missing', 'Manquant')
                  : _formatBytes(size),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr(widget.preferences, 'Close', 'Fermer')),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(width: 104, child: Text(label)),
            Expanded(child: Text(value)),
          ],
        ),
      );

  Future<void> _renameSession(RavenAudioSession session, int index) async {
    final controller = TextEditingController(
        text: session.name.isEmpty ? 'Session ${index + 1}' : session.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
            tr(widget.preferences, 'Rename session', 'Renommer la session')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(tr(widget.preferences, 'Save', 'Enregistrer')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    final trimmed = name.trim();
    final messenger = ScaffoldMessenger.of(context);
    try {
      var project = _project;
      // Rename the physical audio file on disk first (fails soft if the file
      // is missing or locked), then update the record with the new name + path.
      if (trimmed != session.name.trim()) {
        project = await widget.repository
            .renameSessionFile(_project, session, trimmed);
      }
      final sessions = List<RavenAudioSession>.of(project.sessions);
      sessions[index] = session.copyWith(
        name: trimmed,
        audioPath: project.sessions.firstWhere((s) => s.id == session.id).audioPath,
      );
      final validIds = sessions.map((s) => s.id).toSet();
      final bookmarks = project.bookmarks
          .where((b) => b.sessionId.isEmpty || validIds.contains(b.sessionId))
          .toList();
      await _saveProject(
          project.copyWith(sessions: sessions, bookmarks: bookmarks));
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          'Take renamed, including its audio file on disk.',
          'Prise renommée, y compris son fichier audio sur le disque.',
        )),
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not rename recording session: $error'),
      ));
    }
  }

  Future<void> _deleteSession(RavenAudioSession session, int index) async {
    final deletesProject = _project.sessions.length == 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(
          widget.preferences,
          deletesProject ? 'Move recording to Trash?' : 'Delete this session?',
          deletesProject
              ? 'Déplacer dans la corbeille ?'
              : 'Supprimer cette session ?',
        )),
        content: Text(tr(
          widget.preferences,
          deletesProject
              ? 'The recording will remain recoverable in Trash.'
              : 'This removes this session from the project. Other sessions remain available.',
          deletesProject
              ? 'L’enregistrement pourra être restauré depuis la corbeille.'
              : 'Cette session sera supprimée du projet. Les autres sessions resteront disponibles.',
        )),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(
              widget.preferences,
              deletesProject ? 'Move to Trash' : 'Delete session',
              deletesProject ? 'Mettre à la corbeille' : 'Supprimer la session',
            )),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _player.stop();
      if (deletesProject) {
        await widget.repository.moveToTrash(_project);
        widget.onProjectChanged(
            widget.repository.projectById(_project.id) ?? _project);
        if (mounted) Navigator.of(context).pop();
        return;
      }

      final oldMasterPath = _project.masterAudioPath;
      final sessions = List<RavenAudioSession>.of(_project.sessions)
        ..removeAt(index);
      final nextActive = sessions.isEmpty
          ? 0
          : (_activeIndex > index ? _activeIndex - 1 : _activeIndex)
              .clamp(0, sessions.length - 1);
      if (mounted) setState(() => _activeIndex = nextActive);
      await _saveProject(_project.copyWith(
        sessions: sessions,
        clearMasterAudioPath: true,
      ));

      final sourceFile = File(session.audioPath);
      if (await sourceFile.exists()) await sourceFile.delete();
      if (oldMasterPath != null && oldMasterPath != session.audioPath) {
        final oldMaster = File(oldMasterPath);
        if (await oldMaster.exists()) await oldMaster.delete();
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not delete recording session: $error'),
      ));
    }
  }

  Widget _buildSessionsTab(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final count = _project.sessions.length;

    if (_project.sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.mic_none_rounded,
                  size: 52,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 14),
              Text(
                tr(widget.preferences, 'No recordings in this project yet',
                    'Aucun enregistrement dans ce projet'),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                tr(widget.preferences, 'Tap below to record the first take.',
                    'Touchez ci-dessous pour enregistrer la première prise.'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _loading || _project.isTrashed
                    ? null
                    : _continueRecording,
                icon: const Icon(Icons.mic_rounded),
                label: Text(tr(widget.preferences, 'Record take',
                    'Enregistrer une prise')),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 10, left: 4, right: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                count == 1
                    ? tr(widget.preferences, '1 Take', '1 Prise')
                    : '$count ${tr(widget.preferences, 'Takes', 'Prises')}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                tr(widget.preferences, 'Tap to play · Tap mic to resume',
                    'Touchez pour lire · Micro pour reprendre'),
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        ..._project.sessions.asMap().entries.map((entry) {
          final index = entry.key;
          final session = entry.value;
          final isActive = index == _activeIndex;
          final title = session.name.isEmpty
              ? tr(widget.preferences, 'Take ${index + 1}',
                  'Prise ${index + 1}')
              : session.name;
          final dateStr =
              DateFormat('dd MMM yyyy · HH:mm', widget.preferences.isFrench ? 'fr' : 'en')
                  .format(session.createdAt);

          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            elevation: isActive ? 2 : 0,
            color: isActive
                ? colorScheme.primaryContainer.withValues(alpha: 0.45)
                : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isActive
                    ? colorScheme.primary
                    : colorScheme.outlineVariant.withValues(alpha: 0.4),
                width: isActive ? 1.5 : 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _loading
                  ? null
                  : () => _handleSessionAction('play', session, index),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: <Widget>[
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: isActive
                          ? colorScheme.primary
                          : colorScheme.surfaceContainerHighest,
                      foregroundColor: isActive
                          ? colorScheme.onPrimary
                          : colorScheme.onSurfaceVariant,
                      child: isActive
                          ? const Icon(Icons.graphic_eq_rounded, size: 20)
                          : Text('${index + 1}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontWeight: isActive
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                    color: isActive
                                        ? colorScheme.primary
                                        : colorScheme.onSurface,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  session.format.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_formatDuration(session.durationMs)}  ·  $dateStr',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: tr(widget.preferences,
                          'Resume recording this take',
                          'Reprendre cet enregistrement'),
                      onPressed: _loading || _project.isTrashed
                          ? null
                          : () => _resumeSession(session),
                      icon: const Icon(Icons.mic_rounded, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                    PopupMenuButton<String>(
                      tooltip: tr(widget.preferences, 'Recording actions',
                          'Actions de l’enregistrement'),
                      onSelected: (action) =>
                          _handleSessionAction(action, session, index),
                      itemBuilder: (context) => <PopupMenuEntry<String>>[
                        PopupMenuItem(
                          value: 'play',
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.play_arrow_rounded, size: 18),
                              const SizedBox(width: 10),
                              Text(tr(widget.preferences, 'Play', 'Lire')),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'resume',
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.mic_rounded, size: 18),
                              const SizedBox(width: 10),
                              Text(tr(widget.preferences, 'Resume take',
                                  'Reprendre la prise')),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'share',
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.share_outlined, size: 18),
                              const SizedBox(width: 10),
                              Text(tr(widget.preferences, 'Share audio',
                                  'Partager l’audio')),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'rename',
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.edit_outlined, size: 18),
                              const SizedBox(width: 10),
                              Text(tr(widget.preferences, 'Rename take',
                                  'Renommer la prise')),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'trim',
                          enabled: !_project.isAudioProtected,
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.content_cut_rounded, size: 18),
                              const SizedBox(width: 10),
                              Text(tr(widget.preferences, 'Trim audio',
                                  'Rogner l’audio')),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'details',
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.info_outline_rounded, size: 18),
                              const SizedBox(width: 10),
                              Text(tr(widget.preferences, 'Details', 'Détails')),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.delete_outline_rounded,
                                  size: 18, color: colorScheme.error),
                              const SizedBox(width: 10),
                              Text(
                                tr(
                                  widget.preferences,
                                  _project.sessions.length == 1
                                      ? 'Move project to Trash'
                                      : 'Delete this take',
                                  _project.sessions.length == 1
                                      ? 'Mettre dans la corbeille'
                                      : 'Supprimer cette prise',
                                ),
                                style: TextStyle(color: colorScheme.error),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed:
              _loading || _project.isTrashed ? null : _continueRecording,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
          ),
          icon: const Icon(Icons.add_rounded),
          label: Text(
            tr(widget.preferences, 'Add another take to this project',
                'Ajouter une autre prise à ce projet'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _buildAttachmentsTab(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 12, left: 4, right: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                _attachments.isEmpty
                    ? tr(widget.preferences, 'No files attached',
                        'Aucun fichier joint')
                    : '${_attachments.length} ${tr(widget.preferences, _attachments.length == 1 ? 'attachment' : 'attachments', _attachments.length == 1 ? 'pièce jointe' : 'pièces jointes')}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _loading ? null : _manageAttachments,
                icon: Icon(
                    _attachments.isEmpty
                        ? Icons.add_rounded
                        : Icons.tune_rounded,
                    size: 18),
                label: Text(
                  _attachments.isEmpty
                      ? tr(widget.preferences, 'Add files', 'Ajouter')
                      : tr(widget.preferences, 'Manage', 'Gérer'),
                ),
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),
        if (_attachments.isEmpty)
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            color: colorScheme.surfaceContainerLowest,
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: <Widget>[
                  Icon(Icons.attachment_rounded,
                      size: 48,
                      color: colorScheme.primary.withValues(alpha: 0.6)),
                  const SizedBox(height: 12),
                  Text(
                    tr(widget.preferences,
                        'Keep reference materials together',
                        'Gardez vos documents de référence ensemble'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr(
                      widget.preferences,
                      'Attach lyrics, photos of whiteboards, sheet music, interview outlines, or reference audio to this project workspace.',
                      'Joignez des paroles, des photos de tableau, des partitions, des plans d’interview ou des références audio à cet espace de projet.',
                    ),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: _loading ? null : _manageAttachments,
                    child: Text(tr(widget.preferences,
                        'Choose files or photos',
                        'Choisir des fichiers ou photos')),
                  ),
                ],
              ),
            ),
          )
        else
          for (final file in _attachments) _buildAttachmentRow(theme, file),
      ],
    );
  }

  Widget _buildAttachmentRow(ThemeData theme, File file) {
    final colorScheme = theme.colorScheme;
    final isImage = _isImageAttachment(file);
    int? size;
    try {
      size = file.lengthSync();
    } on FileSystemException {
      size = null;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: ListTile(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        leading: isImage
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  file,
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(_iconForFile(file),
                      color: colorScheme.primary),
                ),
              )
            : Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_iconForFile(file),
                    color: colorScheme.primary, size: 22),
              ),
        title: Text(
          file.uri.pathSegments.last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: size == null
            ? null
            : Text(_formatBytes(size), style: theme.textTheme.bodySmall),
        onTap: () => _openAttachment(file),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: tr(widget.preferences, 'Share file',
                  'Partager le fichier'),
              onPressed: () async {
                try {
                  await AudioShareService().shareFile(file);
                } catch (error) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                        '${tr(widget.preferences, 'Could not share file', 'Impossible de partager le fichier')}: $error'),
                  ));
                }
              },
              icon: const Icon(Icons.share_outlined, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameProject() async {
    final controller = TextEditingController(text: _project.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
            tr(widget.preferences, 'Rename project', 'Renommer le projet')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
              labelText:
                  tr(widget.preferences, 'Project title', 'Titre du projet')),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: Text(tr(widget.preferences, 'Save', 'Enregistrer'))),
        ],
      ),
    );
    controller.dispose();
    if (newTitle == null || newTitle.trim().isEmpty) return;
    final trimmed = newTitle.trim();
    if (trimmed == _project.title) return;

    setState(() => _loading = true);
    // ignore: use_build_context_synchronously
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _player.stop();
      // Rename the physical folder + rewrite audio/master paths; the returned
      // record already points at the new locations.
      final updated =
          await widget.repository.renameProject(_project, trimmed);
      await _saveProject(updated);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          'Project renamed on this device, including its folder and audio files.',
          'Projet renommé sur cet appareil, y compris son dossier et ses fichiers audio.',
        )),
      ));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not rename project', 'Impossible de renommer le projet')}: $error'),
      ));
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        await _loadSelectedSession();
      }
    }
  }

  /// Reads duration from a recovered draft's file WITHOUT touching the global
  /// player (which would briefly show stale data in the notification).
  /// Recovered drafts are always PCM16 WAV because the recorder captures WAV.
  Future<int> _measureSessionDuration(RavenAudioSession selected) async {
    final original = File(selected.audioPath);
    if (!await original.exists()) {
      throw FileSystemException(
          'The recovered audio file is missing.', original.path);
    }

    var fileToMeasure = original;
    File? temporaryPlaintext;
    if (_project.isAudioProtected) {
      final cache = await getTemporaryDirectory();
      final extension = selected.format == 'wav'
          ? 'wav'
          : selected.format == 'flac'
              ? 'flac'
              : 'm4a';
      temporaryPlaintext = File(
          '${cache.path}/raven-probe-${_project.id}-${selected.id}.$extension');
      if (await temporaryPlaintext.exists()) await temporaryPlaintext.delete();
      await _encryption.decryptFile(
          input: original, output: temporaryPlaintext, key: _audioKey);
      fileToMeasure = temporaryPlaintext;
    }

    try {
      final ms = await PlaybackService.readWavDurationMs(fileToMeasure);
      if (ms > 0) return ms;
      throw StateError(
          'RAVEN could not determine the recovered audio duration.');
    } finally {
      if (temporaryPlaintext != null && await temporaryPlaintext.exists()) {
        try {
          await temporaryPlaintext.delete();
        } on FileSystemException {
          // Best-effort: the encryption service cleans stale probe files
          // on next app launch if this delete fails.
        }
      }
    }
  }

  Future<void> _finalizeRecoveredDraft() async {
    final selected = _session;
    if (selected == null || !_project.isDraft || _loading) return;
    setState(() => _loading = true);
    try {
      final durationMs = selected.durationMs > 0
          ? selected.durationMs
          : await _measureSessionDuration(selected);
      final updatedSessions = _project.sessions
          .map((item) => item.id == selected.id
              ? item.copyWith(durationMs: durationMs)
              : item)
          .toList();
      await _saveProject(_project.copyWith(
        isDraft: false,
        sessions: updatedSessions,
        clearMasterAudioPath: true,
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(tr(
                  widget.preferences,
                  'Recovered project finalised.',
                  'Le projet récupéré a été finalisé.'))),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${tr(widget.preferences, 'Could not finalise recovered draft', 'Impossible de finaliser le brouillon récupéré')}: $error')));
      }
    } finally {
      if (mounted) await _loadSelectedSession();
    }
  }

  Future<void> _addBookmark({RavenBookmark? existing}) async {
    if (_project.sessions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
            widget.preferences,
            'Add or record audio before creating a bookmark.',
            'Ajoutez ou enregistrez de l’audio avant de créer un repère.')),
      ));
      return;
    }

    final activeSession = _session ?? _project.sessions.last;
    final globalPosition = existing?.positionMs ??
        _globalPositionMs(_activeIndex, _player.position);
    final sessionNumber = _project.sessions
            .indexWhere((s) => s.id == activeSession.id) +
        1;

    final wasPlaying = _player.playing;
    if (wasPlaying) await _player.pause();
    if (!mounted) return;

    final controller = TextEditingController(
      text: existing?.label ??
          '${tr(widget.preferences, 'Bookmark', 'Repère')} ${_project.bookmarks.length + 1}',
    );
    controller.selection = TextSelection(
        baseOffset: 0, extentOffset: controller.text.length);

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.bookmark_add_rounded),
        title: Text(
            tr(
                widget.preferences,
                existing == null ? 'New bookmark' : 'Edit bookmark',
                existing == null ? 'Nouveau repère' : 'Modifier le repère'),
            textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(dialogContext)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.schedule_rounded, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    _formatBookmarkTime(globalPosition),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    tr(
                      widget.preferences,
                      '· Part $sessionNumber',
                      '· Partie $sessionNumber',
                    ),
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText:
                    tr(widget.preferences, 'Bookmark label', 'Nom du repère'),
                hintText: tr(widget.preferences, 'e.g. Chorus starts',
                    'ex. Début du refrain'),
              ),
              onSubmitted: (value) {
                final trimmed = value.trim();
                if (trimmed.isNotEmpty) Navigator.pop(dialogContext, trimmed);
              },
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
          FilledButton.icon(
              onPressed: () {
                final trimmed = controller.text.trim();
                if (trimmed.isEmpty) return;
                Navigator.pop(dialogContext, trimmed);
              },
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(existing == null
                  ? tr(widget.preferences, 'Save bookmark', 'Enregistrer')
                  : tr(widget.preferences, 'Update', 'Mettre à jour'))),
        ],
      ),
    );
    controller.dispose();
    if (wasPlaying && mounted) unawaited(_player.play());
    if (result == null || result.isEmpty) return;

    final bookmark = RavenBookmark(
      id: existing?.id ?? const Uuid().v4(),
      sessionId: activeSession.id,
      positionMs: globalPosition,
      label: result,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
    final bookmarks = List<RavenBookmark>.of(_project.bookmarks);
    if (existing == null) {
      bookmarks.add(bookmark);
    } else {
      final index = bookmarks.indexWhere((b) => b.id == existing.id);
      if (index >= 0) bookmarks[index] = bookmark;
    }
    bookmarks.sort((a, b) => a.positionMs.compareTo(b.positionMs));
    try {
      await _saveProject(_project.copyWith(bookmarks: bookmarks));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(existing == null
            ? tr(widget.preferences,
                'Bookmark added at ${_formatBookmarkTime(globalPosition)}.',
                'Repère ajouté à ${_formatBookmarkTime(globalPosition)}.')
            : tr(widget.preferences, 'Bookmark updated.',
                'Repère mis à jour.')),
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not save bookmark', 'Impossible d’enregistrer le repère')}: $error'),
      ));
    }
  }

  Future<void> _deleteBookmark(RavenBookmark bookmark) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(widget.preferences, 'Delete bookmark?',
            'Supprimer le repère ?')),
        content: Text(
            '${bookmark.label}\n${_formatBookmarkTime(bookmark.positionMs)}'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(widget.preferences, 'Delete', 'Supprimer'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final remaining =
        _project.bookmarks.where((b) => b.id != bookmark.id).toList();
    try {
      await _saveProject(_project.copyWith(bookmarks: remaining));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not delete bookmark', 'Impossible de supprimer le repère')}: $error'),
      ));
    }
  }

  Future<void> _jumpToBookmark(RavenBookmark bookmark) async {
    final index = _project.sessions
        .indexWhere((session) => session.id == bookmark.sessionId);
    if (index >= 0 && index != _activeIndex) {
      setState(() => _activeIndex = index);
      final loaded = await _loadSelectedSession();
      if (!loaded || !mounted) return;
    }
    await _seekGlobal(bookmark.positionMs);
    if (mounted) await _player.play();
  }

  Future<void> _runAiTask(String task) async {
    final sourceText = _notesController.text.trim();
    if (sourceText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
              widget.preferences,
              'Add or save some notes first. RAVEN does not upload audio in this AI action.',
              'Ajoutez ou enregistrez d’abord des notes. Cette action IA n’envoie pas l’audio.'))));
      return;
    }
    final provider = RavenAiProvider.values.firstWhere(
      (item) => item.id == widget.preferences.aiProvider,
      orElse: () => RavenAiProvider.openRouter,
    );
    final vault = AiKeyVault();
    bool keyExists;
    try {
      keyExists = await vault.hasKey(provider.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
        widget.preferences,
        'RAVEN could not access secure storage. Check your device configuration and try again.',
        'RAVEN n’a pas pu accéder au stockage sécurisé. Vérifiez la configuration de l’appareil et réessayez.',
      ))));
      return;
    }
    if (!mounted) return;
    if (!keyExists) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
              widget.preferences,
              'Configure an AI provider and API key in Settings first.',
              'Configurez d’abord un fournisseur IA et une clé API dans les paramètres.'))));
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(widget.preferences, 'Send notes to AI?',
            'Envoyer les notes à l’IA ?')),
        content: Text(tr(
            widget.preferences,
            'RAVEN will send the text currently in this notes field to ${provider.label} using your saved API key. The provider processes it under its own terms and may charge your account. Audio files are not sent by this action. Continue?',
            'RAVEN enverra le texte de ce champ de notes à ${provider.label} avec votre clé API enregistrée. Le fournisseur le traite selon ses conditions et peut facturer votre compte. Les fichiers audio ne sont pas envoyés par cette action. Continuer ?')),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                  tr(widget.preferences, 'Send notes', 'Envoyer les notes'))),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final model = widget.preferences.aiModel.trim().isNotEmpty
        ? widget.preferences.aiModel
        : provider.defaultModel;
    final messenger = ScaffoldMessenger.of(context);
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final prompt = switch (task) {
      'summary' =>
        'Summarize these user notes faithfully. Keep important names, facts, dates, and uncertainties. Do not invent details. Use clear headings and concise bullets.\n\nProject: ${_project.title}\nNotes:\n$sourceText',
      'organize' =>
        'Organize and polish these notes without changing their meaning. Keep the original language. Use headings and bullets where helpful. Mark ambiguities instead of guessing.\n\nProject: ${_project.title}\nNotes:\n$sourceText',
      _ =>
        'Translate these notes into ${widget.preferences.isFrench ? 'English' : 'French'}, preserving names, facts, formatting, and uncertainty. Return only the translation.\n\n$sourceText',
    };
    if (context.mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(children: <Widget>[
              CircularProgressIndicator(),
              SizedBox(width: 18),
              Expanded(child: Text('Working with your AI provider…')),
            ]),
          ),
        ),
      );
    }
    final service = RavenAiProviderService(vault: vault);
    try {
      final result = await service.generate(
          provider: provider, model: model, prompt: prompt);
      if (!mounted) return;
      rootNavigator.pop();
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr(widget.preferences, 'AI result · review before saving',
              'Résultat IA · vérifier avant d’enregistrer')),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(child: SelectableText(result)),
          ),
          actions: <Widget>[
            TextButton.icon(
              onPressed: () async {
                final clipboardMessenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: result));
                if (!dialogContext.mounted) return;
                clipboardMessenger.showSnackBar(SnackBar(
                    content: Text(tr(widget.preferences,
                        'Copied to clipboard.',
                        'Copié dans le presse-papiers.'))));
              },
              icon: const Icon(Icons.copy_rounded),
              label: Text(tr(widget.preferences, 'Copy', 'Copier')),
            ),
            TextButton(
              onPressed: () async {
                try {
                  final savedResults =
                      Map<String, String>.from(_project.aiGeneratedContent);
                  final resultKey =
                      '${task}_${DateTime.now().toUtc().toIso8601String()}';
                  savedResults[resultKey] = result;
                  await _saveProject(
                      _project.copyWith(aiGeneratedContent: savedResults));
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (error) {
                  if (!dialogContext.mounted) return;
                  ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(
                      content: Text(
                          '${tr(widget.preferences, 'Could not save the AI result', 'Impossible d’enregistrer le résultat IA')}: $error')));
                }
              },
              child: Text(tr(widget.preferences, 'Save separately',
                  'Enregistrer séparément')),
            ),
            TextButton(
              onPressed: () {
                _notesController.text = result;
                Navigator.pop(dialogContext);
              },
              child: Text(tr(
                  widget.preferences, 'Replace notes', 'Remplacer les notes')),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(tr(widget.preferences, 'Close', 'Fermer'))),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      rootNavigator.maybePop();
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr(widget.preferences, 'AI request failed', 'Échec de la requête IA')}: $error')));
    } finally {
      service.close();
    }
  }

  Future<void> _saveNotes() async {
    setState(() => _savingNotes = true);
    try {
      await _saveProject(_project.copyWith(notes: _notesController.text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  tr(widget.preferences, 'Notes saved', 'Notes enregistrées'))),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${tr(widget.preferences, 'Could not save notes', 'Impossible d’enregistrer les notes')}: $error')));
      }
    } finally {
      if (mounted) setState(() => _savingNotes = false);
    }
  }

  Future<void> _saveProject(RavenProject updated) async {
    await widget.repository.update(updated);
    if (!mounted) return;
    setState(() => _project = updated);
    widget.onProjectChanged(updated);
  }

  // ---------------------------------------------------------------------------
  // Amplify (project player)
  // ---------------------------------------------------------------------------

  /// Container extension matching [session]'s format; used for boost output.
  String _boostExt(String format) => switch (format.toLowerCase()) {
        'wav' => 'wav',
        'flac' => 'flac',
        'mp3' => 'mp3',
        _ => 'm4a',
      };

  /// Codec arguments for the FFmpeg amplify pass at the take's own bitrate, so
  /// committing an amplified take never changes its quality tier.
  String _boostCodec(String ext, int bitRate) {
    final clamped = bitRate.clamp(64000, 320000);
    return switch (ext) {
      'wav' => '-c:a pcm_s16le',
      'flac' => '-c:a flac',
      'mp3' => '-c:a libmp3lame -b:a $clamped',
      _ => '-c:a aac -b:a $clamped -movflags +faststart',
    };
  }

  Future<void> _deleteBoostedFile() async {
    final path = _boostedPath;
    _boostedPath = null;
    _boostedSessionId = null;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Temp cache cleanup is best-effort.
    }
  }

  /// Renders a volume-boosted copy of the ACTIVE take into the temp cache and
  /// plays it. Level 1.0 restores the original, unmodified audio.
  Future<void> _applyBoost(double level) async {
    if (_boostProcessing || _savingAmplified) return;
    final session = _session;
    if (session == null) return;
    if (level == _volumeBoost && _boostedSessionId == session.id) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _boostProcessing = true);
    final wasPlaying = _player.playing;
    final position = _player.position;
    final previousBoost = _boostedPath;

    try {
      await _player.pause();

      if (level <= 1.0) {
        await _loadSessionForPlayback(session, boosted: false);
        if (previousBoost != null) {
          try {
            final file = File(previousBoost);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
        _boostedPath = null;
        _boostedSessionId = null;
        if (position > Duration.zero) {
          try {
            await _player.seek(position);
          } catch (_) {}
        }
        if (wasPlaying) unawaited(_player.play());
        if (mounted) {
          setState(() {
            _volumeBoost = 1.0;
            _boostProcessing = false;
          });
        }
        return;
      }

      final source = File(session.audioPath);
      if (!await source.exists()) {
        throw FileSystemException('The take audio file is missing', source.path);
      }

      final cache = await getTemporaryDirectory();
      final ext = _boostExt(session.format);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath =
          '${cache.path}/raven-boost-${_project.id}-${session.id}-$stamp.$ext';
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        try {
          await outputFile.delete();
        } catch (_) {}
      }

      final codec = _boostCodec(ext, session.bitRate);
      final sampleRate = session.sampleRate > 0 ? session.sampleRate : 44100;
      final command = '-hide_banner -nostdin -y '
          '-i "${source.path}" '
          '-ar $sampleRate '
          '-af "volume=${level.toStringAsFixed(2)},alimiter=limit=0.95:attack=5:release=50" '
          '$codec "$outputPath"';

      final ffSession = await FFmpegKit.execute(command);
      final returnCode = await ffSession.getReturnCode();
      final succeeded =
          returnCode != null && ReturnCode.isSuccess(returnCode);
      if (!succeeded) {
        final logs = await ffSession.getOutput();
        try {
          if (await outputFile.exists()) await outputFile.delete();
        } catch (_) {}
        throw StateError(
            'FFmpeg failed: ${logs ?? returnCode?.getValue() ?? 'unknown'}');
      }
      if (!await outputFile.exists() || await outputFile.length() < 64) {
        try {
          if (await outputFile.exists()) await outputFile.delete();
        } catch (_) {}
        throw StateError('Amplify produced empty output');
      }

      await _loadSessionForPlayback(session, boosted: true, path: outputPath);
      _boostedPath = outputPath;
      _boostedSessionId = session.id;

      if (previousBoost != null) {
        try {
          final file = File(previousBoost);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      if (position > Duration.zero) {
        try {
          await _player.seek(position);
        } catch (_) {}
      }
      if (wasPlaying) unawaited(_player.play());
      if (mounted) {
        setState(() {
          _volumeBoost = level;
          _boostProcessing = false;
        });
      }
    } catch (error) {
      // Restore the untouched original so a failed boost never leaves the
      // player pointing at a temp file that is about to be deleted.
      try {
        await _loadSessionForPlayback(session, boosted: false);
      } catch (_) {}
      await _deleteBoostedFile();
      if (previousBoost != null && previousBoost != _boostedPath) {
        try {
          final file = File(previousBoost);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _volumeBoost = 1.0;
          _boostProcessing = false;
        });
        messenger.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Could not amplify audio: $error',
            'Impossible d’amplifier l’audio : $error',
          )),
        ));
      }
    }
  }

  /// Loads [session] into the shared player, optionally from an explicit
  /// [path] (a temp amplified copy) instead of its committed audio file.
  Future<void> _loadSessionForPlayback(RavenAudioSession session,
      {required bool boosted, String? path}) async {
    final playbackPath = path ?? session.audioPath;
    final file = File(playbackPath);
    if (!await file.exists()) {
      throw FileSystemException('The take audio file is missing', playbackPath);
    }
    final mediaItem = await _mediaItemFor(
      session,
      overrideTitle: boosted
          ? '${session.name.isEmpty ? _project.title : session.name} · amplified'
          : null,
    );
    await _player
        .setAudioSource(
          AudioSource.uri(Uri.file(playbackPath), tag: mediaItem),
          initialPosition: Duration.zero,
        )
        .timeout(const Duration(seconds: 15));
  }

  /// Commits the amplified render as the active take's audio. The original file
  /// is deleted only after the project record is durably updated.
  Future<void> _saveAmplifiedTake() async {
    if (_savingAmplified || _boostProcessing) return;
    final boostedPath = _boostedPath;
    final session = _session;
    if (boostedPath == null || session == null) return;
    if (_boostedSessionId != session.id) return;
    if (_project.isAudioProtected) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _savingAmplified = true);

    final index = _activeIndex.clamp(0, _project.sessions.length - 1);
    final oldPath = session.audioPath;
    final ext = _boostExt(session.format);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    File? committed;
    var updatedProject = _project;

    try {
      await _player.pause();

      final boostFile = File(boostedPath);
      if (!await boostFile.exists()) {
        throw StateError('The amplified audio is no longer available.');
      }

      // Write the result beside the take so it lives in the project folder.
      final originalFile = File(oldPath);
      final parent = originalFile.parent;
      await parent.create(recursive: true);
      final target = File('${parent.path}/amplified-$stamp.$ext');
      await boostFile.copy(target.path);
      committed = target;
      if (!await target.exists() || await target.length() < 64) {
        throw StateError('The amplified audio copy failed verification.');
      }

      var durationMs = session.durationMs;
      if (durationMs <= 0) {
        try {
          final probe = AudioPlayer();
          try {
            await probe.setAudioSource(AudioSource.uri(Uri.file(target.path)));
            durationMs = probe.duration?.inMilliseconds ?? 0;
          } finally {
            await probe.dispose();
          }
        } catch (_) {
          // Duration stays unknown; playback still reports the real length.
        }
      }

      final updatedSession = session.copyWith(
        audioPath: target.path,
        durationMs: durationMs > 0 ? durationMs : session.durationMs,
        format: ext,
      );
      final sessions = List<RavenAudioSession>.of(_project.sessions);
      sessions[index] = updatedSession;
      updatedProject = _project.copyWith(
        sessions: sessions,
        updatedAt: DateTime.now(),
        // A committed re-encode invalidates any cached merged master.
        clearMasterAudioPath: true,
      );

      await _saveProject(updatedProject);

      _boostedPath = null;
      _boostedSessionId = null;
      _volumeBoost = 1.0;

      try {
        await _player.stop().timeout(const Duration(seconds: 2));
      } catch (_) {}
      await _loadSessionForPlayback(updatedSession, boosted: false);

      // Old audio and the temp render are dead weight once the swap is committed.
      try {
        final old = File(oldPath);
        if (old.path != target.path && await old.exists()) await old.delete();
      } catch (_) {}
      try {
        if (await boostFile.exists()) await boostFile.delete();
      } catch (_) {}

      if (mounted) {
        setState(() => _savingAmplified = false);
        messenger.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Amplified audio saved to this take.',
            'Audio amplifié enregistré dans cette prise.',
          )),
        ));
      }
    } catch (error) {
      // Only remove the new file if the project record never committed.
      final created = committed;
      if (created != null &&
          !updatedProject.sessions.any((s) => s.audioPath == created.path)) {
        try {
          if (await created.exists()) await created.delete();
        } catch (_) {}
      }
      if (mounted) {
        setState(() => _savingAmplified = false);
        messenger.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Could not save amplified audio: $error',
            'Impossible d’enregistrer l’audio amplifié : $error',
          )),
        ));
      }
    }
  }

  /// Opens the amplify sheet: a level slider, a live preview, and the save
  /// action. Previewing swaps only the temp render; nothing is committed until
  /// the user taps Save.
  Future<void> _showAmplifySheet() async {
    if (!_canAmplify) return;
    final session = _session;
    if (session == null) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) {
          final theme = Theme.of(sheetContext);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.graphic_eq_rounded,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          tr(widget.preferences, 'Amplify take',
                              'Amplifier la prise'),
                          style: theme.textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (_boostProcessing)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr(
                      widget.preferences,
                      'Processes this take through a limiter so quiet audio gets louder without clipping. The file keeps the take\'s format and quality tier. Preview changes are temporary until you save.',
                      'Traite cette prise via un limiteur : l’audio discret devient plus fort sans saturation. Le fichier garde le format et la qualité de la prise. La prévisualisation est temporaire jusqu’à l’enregistrement.',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Text(tr(widget.preferences, 'Original', 'Original'),
                          style: theme.textTheme.labelMedium),
                      Expanded(
                        child: Slider(
                          min: 1.0,
                          max: 3.0,
                          divisions: 8,
                          value: _volumeBoost.clamp(1.0, 3.0),
                          label: '${_volumeBoost.toStringAsFixed(2)}×',
                          onChanged: _boostProcessing
                              ? null
                              : (value) => refresh(() {
                                    setState(() => _volumeBoost = value);
                                  }),
                          onChangeEnd: _boostProcessing
                              ? null
                              : (value) async {
                                  await _applyBoost(value);
                                  if (sheetContext.mounted) refresh(() {});
                                },
                        ),
                      ),
                      Text('${_volumeBoost.toStringAsFixed(2)}×',
                          style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  FilledButton.icon(
                    onPressed: (_volumeBoost > 1.0 &&
                            _boostedPath != null &&
                            !_boostProcessing &&
                            !_savingAmplified)
                        ? () async {
                            Navigator.of(sheetContext).pop();
                            await _saveAmplifiedTake();
                          }
                        : null,
                    icon: _savingAmplified
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_alt_rounded),
                    label: Text(tr(
                      widget.preferences,
                      'Save amplified audio to this take',
                      'Enregistrer l’audio amplifié dans cette prise',
                    )),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: _boostProcessing
                        ? null
                        : () async {
                            await _applyBoost(1.0);
                            if (sheetContext.mounted) refresh(() {});
                          },
                    child: Text(tr(widget.preferences, 'Reset to original',
                        'Revenir à l’original')),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _toggleProjectPin() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_loading) return;
    if (!_project.requiresAppPin &&
        (_project.hasPublicFolder || _project.hasPublicCopy)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
        widget.preferences,
        'Make this project private first. Public copies can be opened outside RAVEN.',
        'Rendez d’abord ce projet privé. Les copies publiques peuvent être ouvertes hors de RAVEN.',
      ))));
      return;
    }
    if (!_project.requiresAppPin && !widget.preferences.appLockEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
            widget.preferences,
            'First enable the RAVEN PIN in Settings. Then you can lock individual recordings.',
            'Activez d’abord le code PIN de RAVEN dans Paramètres. Vous pourrez ensuite verrouiller des enregistrements individuels.')),
      ));
      return;
    }
    try {
      await _saveProject(
          _project.copyWith(requiresAppPin: !_project.requiresAppPin));
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(tr(
            widget.preferences,
            _project.requiresAppPin
                ? 'This recording now requires your RAVEN PIN.'
                : 'PIN requirement removed for this recording.',
            _project.requiresAppPin
                ? 'Cet enregistrement nécessite maintenant votre code PIN RAVEN.'
                : 'Le code PIN n’est plus requis pour cet enregistrement.')),
      ));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
          SnackBar(content: Text('Could not update recording lock: $error')));
    }
  }

  Future<void> _togglePublicCopy() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_loading) return;
    if (_project.sessions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
              widget.preferences,
              'There is no saved audio to show in device folders yet.',
              'Aucun audio enregistré à afficher dans les dossiers pour le moment.'))));
      return;
    }

    final enabling = !_project.isPublic;
    if (enabling && (_project.isAudioProtected || _project.requiresAppPin)) {
      final message = _project.isAudioProtected
          ? tr(
              widget.preferences,
              'Decrypt this recording before making it public. Protected recordings cannot be published.',
              'Déchiffrez ce projet avant de le rendre public. Les enregistrements protégés ne peuvent pas être publiés.')
          : tr(
              widget.preferences,
              'Remove the individual PIN lock before making it public. A public folder could bypass RAVEN’s project lock.',
              'Retirez le verrouillage PIN individuel avant de rendre ce projet public. Un dossier public contournerait le verrou du projet.');
      messenger.showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(
            widget.preferences,
            enabling ? 'Make project public?' : 'Make project private?',
            enabling
                ? 'Rendre le projet public ?'
                : 'Rendre le projet privé ?')),
        content: Text(tr(
            widget.preferences,
            enabling
                ? 'RAVEN will move this project’s folder (audio, notes and attachments) into the device’s public RAVEN folder so it can be browsed with a file manager. The project stays playable inside RAVEN.'
                : 'RAVEN will move this project’s folder back into its private app storage. It stays playable inside RAVEN.',
            enabling
                ? 'RAVEN déplacera le dossier de ce projet (audio, notes et pièces jointes) dans le dossier RAVEN public de l’appareil afin qu’il soit visible dans un gestionnaire de fichiers. Le projet reste lisible dans RAVEN.'
                : 'RAVEN replacera le dossier de ce projet dans le stockage privé de l’application. Il reste lisible dans RAVEN.')),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(widget.preferences, 'Continue', 'Continuer'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _loading = true);
    try {
      final legacyFolder = _project.publicFolderLocation;
      if (legacyFolder != null &&
          AudioVisibilityService.isContentUri(legacyFolder)) {
        try {
          await AudioVisibilityService().removeFolder(legacyFolder);
        } catch (_) {
          // Legacy content:// folders are orphaned at worst; the real
          // audio lives in the private canonical folder and remains safe.
        }
        final cleared = _project.copyWith(clearPublicFolderLocation: true);
        await _saveProject(cleared);
      }
      final legacyCopy = _project.publicCopyLocation;
      if (!enabling && legacyCopy != null) {
        try {
          await AudioVisibilityService().remove(legacyCopy);
        } catch (_) {
          // Best-effort: an orphaned public file is disk waste, not loss.
        }
        await _saveProject(_project.copyWith(clearPublicCopyLocation: true));
      }

      final updated = await widget.repository.toggleVisibility(
        _project,
        makePublic: enabling,
      );
      await _saveProject(updated);

      await _loadAttachments();

      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(tr(
              widget.preferences,
              enabling
                  ? 'Project folder moved to your device’s public RAVEN folder.'
                  : 'Project folder moved back into RAVEN’s private storage.',
              enabling
                  ? 'Dossier du projet déplacé dans le dossier RAVEN public de l’appareil.'
                  : 'Dossier du projet replacé dans le stockage privé de RAVEN.'))));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr(widget.preferences, 'Could not update folder visibility', 'Impossible de modifier la visibilité')}: $error')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildWorkspaceHeader(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final createdLabel = DateFormat(
      'dd MMM yyyy · HH:mm',
      widget.preferences.isFrench ? 'fr' : 'en',
    ).format(_project.createdAt);
    final totalDuration = _formatDuration(_totalProjectDurationMs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: InkWell(
                onTap: _renameProject,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          _project.title,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.6),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: _loading || _project.isTrashed
                  ? null
                  : _continueRecording,
              icon: const Icon(Icons.mic_rounded, size: 18),
              label: Text(
                  tr(widget.preferences, 'New take', 'Nouvelle prise')),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color:
                    colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.folder_outlined,
                      size: 13, color: colorScheme.primary),
                  const SizedBox(width: 5),
                  Text(
                    _project.category,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color:
                    colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.timer_outlined,
                      size: 13, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 5),
                  Text(
                    '$totalDuration · ${_project.sessions.length} ${tr(widget.preferences, _project.sessions.length == 1 ? 'take' : 'takes', _project.sessions.length == 1 ? 'prise' : 'prises')}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _project.isPublic
                    ? colorScheme.primaryContainer.withValues(alpha: 0.6)
                    : colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    _project.isPublic
                        ? Icons.public_rounded
                        : Icons.lock_outline_rounded,
                    size: 13,
                    color: _project.isPublic
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _project.isPublic
                        ? tr(widget.preferences, 'Public · Music/RAVEN',
                            'Public · Musique/RAVEN')
                        : tr(widget.preferences, 'App private',
                            'Privé application'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _project.isPublic
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (_project.isAudioProtected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.enhanced_encryption_rounded,
                        size: 13, color: colorScheme.onTertiaryContainer),
                    const SizedBox(width: 5),
                    Text(
                      tr(widget.preferences, 'Encrypted', 'Chiffré'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            if (_project.requiresAppPin)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.pin_rounded,
                        size: 13, color: colorScheme.onSecondaryContainer),
                    const SizedBox(width: 5),
                    Text(
                      tr(widget.preferences, 'PIN locked',
                          'Verrouillé PIN'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              createdLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHeroAudioConsole(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final session = _session;

    return Card(
      elevation: 2,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      color: theme.brightness == Brightness.dark
          ? colorScheme.surfaceContainerHigh
          : colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Flexible(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color:
                          colorScheme.primaryContainer.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.graphic_eq_rounded,
                            size: 16, color: colorScheme.primary),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            _project.sessions.isEmpty
                                ? tr(widget.preferences, 'No recording yet',
                                    'Aucun enregistrement')
                                : '${session?.name.isNotEmpty == true ? session!.name : tr(widget.preferences, 'Take ${_activeIndex + 1}', 'Prise ${_activeIndex + 1}')} (${_activeIndex + 1}/${_project.sessions.length})',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: colorScheme.primary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (session != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            '· ${session.format.toUpperCase()}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_project.sessions.length > 1)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(Icons.skip_previous_rounded),
                        iconSize: 22,
                        visualDensity: VisualDensity.compact,
                        tooltip: tr(widget.preferences, 'Previous take',
                            'Prise précédente'),
                        onPressed: _loading || _activeIndex <= 0
                            ? null
                            : () => _playRecording(_activeIndex - 1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next_rounded),
                        iconSize: 22,
                        visualDensity: VisualDensity.compact,
                        tooltip: tr(widget.preferences, 'Next take',
                            'Prise suivante'),
                        onPressed: _loading ||
                                _activeIndex >= _project.sessions.length - 1
                            ? null
                            : () => _playRecording(_activeIndex + 1),
                      ),
                    ],
                  ),
              ],
            ),
            if (_securityWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _securityWarning!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onErrorContainer),
                  ),
                ),
              ),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: colorScheme.error),
                ),
              )
            else ...<Widget>[
              StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (context, positionSnapshot) {
                  final position = positionSnapshot.data ?? Duration.zero;
                  final duration = Duration(milliseconds: _activeDurationMs);
                  final maxMs = duration.inMilliseconds > 0
                      ? duration.inMilliseconds.toDouble()
                      : 1.0;
                  final currentMs =
                      position.inMilliseconds.toDouble().clamp(0.0, maxMs);

                  return Column(
                    children: <Widget>[
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 5,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7),
                          overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 16),
                          activeTrackColor: colorScheme.primary,
                          inactiveTrackColor:
                              colorScheme.primary.withValues(alpha: 0.15),
                          thumbColor: colorScheme.primary,
                        ),
                        child: Slider(
                          min: 0,
                          max: maxMs,
                          value: currentMs,
                          onChanged: (value) => _seekGlobal(value.round()),
                        ),
                      ),
                      if (_project.bookmarks.isNotEmpty &&
                          _activeDurationMs > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: _BookmarkTimelineStrip(
                            bookmarks: _project.bookmarks,
                            totalMs: _activeDurationMs,
                            onTap: _seekGlobal,
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            Text(
                              _formatDuration(position.inMilliseconds),
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                                color: colorScheme.onSurface,
                              ),
                            ),
                            Text(
                              _formatDuration(duration.inMilliseconds),
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      IconButton(
                        tooltip: tr(widget.preferences, 'Restart',
                            'Recommencer'),
                        onPressed: () => _seekGlobal(0),
                        icon: const Icon(Icons.replay_rounded),
                        iconSize: 24,
                      ),
                      IconButton(
                        tooltip: '-10s',
                        onPressed: () => _seekRelative(-10),
                        icon: const Icon(Icons.replay_10_rounded),
                        iconSize: 26,
                      ),
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: EdgeInsets.zero,
                            elevation: 3,
                            shadowColor: colorScheme.primary
                                .withValues(alpha: 0.35),
                          ),
                          onPressed: _loading || _error != null
                              ? null
                              : () async {
                                  if (playing) {
                                    await _player.pause();
                                  } else {
                                    unawaited(_player.play());
                                  }
                                },
                          child: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 34,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '+10s',
                        onPressed: () => _seekRelative(10),
                        icon: const Icon(Icons.forward_10_rounded),
                        iconSize: 26,
                      ),
                      IconButton.filledTonal(
                        tooltip: tr(widget.preferences, 'Amplify audio',
                            'Amplifier l’audio'),
                        onPressed: _canAmplify ? _showAmplifySheet : null,
                        icon: _boostProcessing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : Icon(
                                Icons.graphic_eq_rounded,
                                color: _volumeBoost > 1.0
                                    ? colorScheme.primary
                                    : null,
                              ),
                        iconSize: 22,
                      ),
                      IconButton.filledTonal(
                        tooltip: tr(widget.preferences, 'Add bookmark',
                            'Ajouter un repère'),
                        onPressed: _loading || _error != null
                            ? null
                            : () => _addBookmark(),
                        icon: const Icon(Icons.bookmark_add_rounded),
                        iconSize: 22,
                      ),
                      PopupMenuButton<double>(
                        tooltip: tr(widget.preferences, 'Playback speed',
                            'Vitesse de lecture'),
                        onSelected: (speed) => _player.setSpeed(speed),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: StreamBuilder<double>(
                            stream: _player.speedStream,
                            builder: (context, speedSnap) {
                              final currentSpeed = speedSnap.data ?? 1.0;
                              return Text(
                                '$currentSpeed×',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              );
                            },
                          ),
                        ),
                        itemBuilder: (_) => <PopupMenuEntry<double>>[
                          for (final speed in <double>[
                            0.5,
                            0.75,
                            1,
                            1.25,
                            1.5,
                            2
                          ])
                            PopupMenuItem<double>(
                              value: speed,
                              child: Text('$speed×'),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
            if (_project.isDraft) ...<Widget>[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.warning_amber_rounded,
                        color: colorScheme.onTertiaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tr(
                          widget.preferences,
                          'Recovered draft — verify audio before finalising.',
                          'Brouillon récupéré — vérifiez l’audio avant de finaliser.',
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onTertiaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: _loading || _error != null
                          ? null
                          : _finalizeRecoveredDraft,
                      child: Text(tr(
                          widget.preferences, 'Finalise', 'Finaliser')),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNotesTab(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final wordCount = _notesWordCount;
    final charCount = _notesController.text.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
      children: <Widget>[
        Card(
          elevation: 0,
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              children: <Widget>[
                PopupMenuButton<String>(
                  tooltip: tr(widget.preferences, 'AI tools for notes',
                      'Outils IA pour les notes'),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.auto_awesome_rounded,
                            size: 18, color: colorScheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          'AI Tools',
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(Icons.arrow_drop_down_rounded,
                            size: 18, color: colorScheme.primary),
                      ],
                    ),
                  ),
                  onSelected: (task) => _runAiTask(task),
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    PopupMenuItem(
                      value: 'summary',
                      child: Row(
                        children: <Widget>[
                          const Icon(Icons.summarize_outlined, size: 18),
                          const SizedBox(width: 10),
                          Text(tr(widget.preferences, 'Summarize notes',
                              'Résumer les notes')),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'organize',
                      child: Row(
                        children: <Widget>[
                          const Icon(Icons.auto_fix_high_rounded, size: 18),
                          const SizedBox(width: 10),
                          Text(tr(widget.preferences, 'Organize and polish',
                              'Organiser et améliorer')),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'translate',
                      child: Row(
                        children: <Widget>[
                          const Icon(Icons.translate_rounded, size: 18),
                          const SizedBox(width: 10),
                          Text(tr(widget.preferences, 'Translate notes',
                              'Traduire les notes')),
                        ],
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  '$wordCount ${tr(widget.preferences, wordCount == 1 ? 'word' : 'words', wordCount == 1 ? 'mot' : 'mots')} · $charCount ${tr(widget.preferences, 'chars', 'car.')}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: tr(widget.preferences, 'Save .txt file',
                      'Enregistrer .txt'),
                  icon: const Icon(Icons.description_outlined, size: 20),
                  visualDensity: VisualDensity.compact,
                  onPressed: _exportNotesTxt,
                ),
                FilledButton.tonalIcon(
                  onPressed: _savingNotes ? null : _saveNotes,
                  icon: _savingNotes
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 16),
                  label: Text(tr(widget.preferences, 'Save', 'Sauvegarder')),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notesController,
          minLines: 8,
          maxLines: 25,
          textCapitalization: TextCapitalization.sentences,
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          decoration: InputDecoration(
            hintText: tr(
              widget.preferences,
              'Add project notes, context, ideas, lyrics, timestamps or follow-up tasks…\n\nNotes stay inside this project and can be exported as real .txt files.',
              'Ajoutez des notes de projet, contexte, idées, paroles, repères temporels ou tâches…\n\nLes notes restent dans ce projet et s’exportent en vrais fichiers .txt.',
            ),
            hintStyle: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              height: 1.5,
            ),
            alignLabelWithHint: true,
            filled: true,
            fillColor: colorScheme.surfaceContainerLowest,
            contentPadding: const EdgeInsets.all(18),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
            ),
          ),
        ),
        if (_project.aiGeneratedContent.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            color: colorScheme.surfaceContainerLow,
            child: ExpansionTile(
              initiallyExpanded: false,
              leading: Icon(Icons.auto_awesome_rounded,
                  color: colorScheme.primary),
              title: Text(
                tr(widget.preferences, 'Saved AI insights',
                    'Résultats IA enregistrés'),
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${_project.aiGeneratedContent.length} ${tr(widget.preferences, 'item(s) saved', 'élément(s) sauvegardé(s)')}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: _project.aiGeneratedContent.entries.map((entry) {
                return Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Text(
                            entry.key.split('_').first.toUpperCase(),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: colorScheme.primary,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            visualDensity: VisualDensity.compact,
                            onPressed: () async {
                              final messenger =
                                  ScaffoldMessenger.of(context);
                              await Clipboard.setData(
                                  ClipboardData(text: entry.value));
                              messenger.showSnackBar(SnackBar(
                                content: Text(tr(widget.preferences,
                                    'Copied to clipboard.', 'Copié.')),
                              ));
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        entry.value,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.shield_outlined,
                  size: 20, color: colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  tr(
                    widget.preferences,
                    'Project notes and recordings stay together in your project workspace. Private by default; exported copies are separate.',
                    'Les notes et prises restent ensemble dans votre espace de projet. Privé par défaut ; les exports sont distincts.',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBookmarksTab(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final bookmarks = List<RavenBookmark>.of(_project.bookmarks)
      ..sort((a, b) => a.positionMs.compareTo(b.positionMs));
    final totalMs = _activeDurationMs;

    String partLabel(RavenBookmark bookmark) {
      final index = _project.sessions
          .indexWhere((session) => session.id == bookmark.sessionId);
      if (index < 0) return '';
      final session = _project.sessions[index];
      return session.name.isEmpty ? 'Part ${index + 1}' : session.name;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 12, left: 4, right: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                bookmarks.isEmpty
                    ? tr(widget.preferences, 'No bookmarks', 'Aucun repère')
                    : '${bookmarks.length} ${tr(widget.preferences, bookmarks.length == 1 ? 'bookmark' : 'bookmarks', bookmarks.length == 1 ? 'repère' : 'repères')}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed:
                    _loading || _error != null || _project.sessions.isEmpty
                        ? null
                        : () => _addBookmark(),
                icon: const Icon(Icons.bookmark_add_rounded, size: 18),
                label: Text(tr(widget.preferences, 'Add bookmark here',
                    'Ajouter ici')),
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),
        if (bookmarks.isEmpty)
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            color: colorScheme.surfaceContainerLowest,
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: <Widget>[
                  Icon(Icons.bookmarks_outlined,
                      size: 48,
                      color: colorScheme.primary.withValues(alpha: 0.6)),
                  const SizedBox(height: 12),
                  Text(
                    tr(widget.preferences,
                        'Pin key moments in the audio timeline',
                        'Épingler des moments clés dans la timeline'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr(
                      widget.preferences,
                      'While listening, tap Add bookmark to save timestamps for solos, chorus, important quotes, or discussion points.',
                      'Pendant l’écoute, touchez Ajouter un repère pour marquer les moments importants, refrains, citations ou solos.',
                    ),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: _loading ||
                            _error != null ||
                            _project.sessions.isEmpty
                        ? null
                        : () => _addBookmark(),
                    child: Text(tr(widget.preferences,
                        'Add first bookmark', 'Ajouter un premier repère')),
                  ),
                ],
              ),
            ),
          )
        else ...<Widget>[
          if (bookmarks.length > 1 && totalMs > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                color: colorScheme.surfaceContainerLowest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                      color: colorScheme.outlineVariant
                          .withValues(alpha: 0.3)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        tr(widget.preferences, 'Timeline map',
                            'Carte temporelle'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _BookmarkTimelineStrip(
                        bookmarks: bookmarks,
                        totalMs: totalMs,
                        onTap: _seekGlobal,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          for (final bookmark in bookmarks)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
              ),
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _jumpToBookmark(bookmark),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  child: Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Icon(Icons.play_arrow_rounded,
                                size: 14, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(
                              _formatBookmarkTime(bookmark.positionMs),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              bookmark.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            if (partLabel(bookmark).isNotEmpty)
                              Text(
                                partLabel(bookmark),
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant),
                              ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: tr(widget.preferences, 'Bookmark actions',
                            'Actions du repère'),
                        onSelected: (action) {
                          switch (action) {
                            case 'play':
                              _jumpToBookmark(bookmark);
                            case 'rename':
                              _addBookmark(existing: bookmark);
                            case 'delete':
                              _deleteBookmark(bookmark);
                          }
                        },
                        itemBuilder: (context) => <PopupMenuEntry<String>>[
                          PopupMenuItem(
                            value: 'play',
                            child: Row(
                              children: <Widget>[
                                const Icon(Icons.play_arrow_rounded, size: 18),
                                const SizedBox(width: 8),
                                Text(tr(widget.preferences,
                                    'Play from here',
                                    'Lire à partir d’ici')),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'rename',
                            child: Row(
                              children: <Widget>[
                                const Icon(Icons.edit_outlined, size: 18),
                                const SizedBox(width: 8),
                                Text(tr(widget.preferences, 'Rename',
                                    'Renommer')),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: <Widget>[
                                Icon(Icons.delete_outline_rounded,
                                    size: 18, color: colorScheme.error),
                                const SizedBox(width: 8),
                                Text(tr(widget.preferences, 'Delete',
                                    'Supprimer'),
                                    style:
                                        TextStyle(color: colorScheme.error)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(widget.preferences, 'Project Workspace', 'Espace projet')),
        actions: <Widget>[
          IconButton(
            tooltip: tr(
              widget.preferences,
              'Add a new take to this project',
              'Ajouter une nouvelle prise à ce projet',
            ),
            onPressed:
                _loading || _project.isTrashed ? null : _continueRecording,
            icon: const Icon(Icons.mic_rounded),
          ),
          IconButton(
            tooltip: _project.isFavorite
                ? tr(widget.preferences, 'Remove favourite',
                    'Retirer des favoris')
                : tr(
                    widget.preferences, 'Add favourite', 'Ajouter aux favoris'),
            onPressed: () => _saveProject(
                _project.copyWith(isFavorite: !_project.isFavorite)),
            icon: Icon(
              _project.isFavorite
                  ? Icons.star_rounded
                  : Icons.star_border_rounded,
              color: _project.isFavorite ? colorScheme.tertiary : null,
            ),
          ),
          PopupMenuButton<String>(
            tooltip:
                tr(widget.preferences, 'Project actions', 'Actions du projet'),
            onSelected: _handleProjectAction,
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              _projectMenuItem(
                  'bookmark',
                  Icons.bookmark_add_outlined,
                  tr(widget.preferences, 'Add timeline bookmark',
                      'Ajouter un repère audio')),
              _projectMenuItem(
                  'attachments',
                  Icons.attach_file_rounded,
                  tr(widget.preferences, 'Project attachments',
                      'Pièces jointes du projet')),
              _projectMenuItem(
                  'share_audio',
                  Icons.share_outlined,
                  tr(widget.preferences, 'Share recording audio',
                      'Partager l’audio du projet'),
                  enabled: !_loading),
              _projectMenuItem(
                'visibility',
                _project.isPublic
                    ? Icons.folder_off_outlined
                    : Icons.folder_outlined,
                tr(
                  widget.preferences,
                  _project.isPublic
                      ? 'Make project private'
                      : 'Make project public',
                  _project.isPublic
                      ? 'Rendre le projet privé'
                      : 'Rendre le projet public',
                ),
                enabled: !_loading,
              ),
              _projectMenuItem(
                'encryption',
                _project.isAudioProtected
                    ? Icons.no_encryption_rounded
                    : Icons.enhanced_encryption_rounded,
                tr(
                  widget.preferences,
                  _project.isAudioProtected
                      ? 'Unlock audio'
                      : 'Lock audio with a password',
                  _project.isAudioProtected
                      ? 'Déverrouiller l’audio'
                      : 'Verrouiller l’audio avec un mot de passe',
                ),
                enabled: !_loading,
              ),
              _projectMenuItem(
                  'export',
                  Icons.archive_outlined,
                  tr(widget.preferences, 'Export complete project',
                      'Exporter le projet complet')),
              _projectMenuItem(
                  'notes_txt',
                  Icons.description_outlined,
                  tr(widget.preferences, 'Save notes as .txt file',
                      'Enregistrer les notes en fichier .txt')),
              _projectMenuItem(
                  'rename',
                  Icons.edit_outlined,
                  tr(widget.preferences, 'Rename project',
                      'Renommer le projet')),
              _projectMenuItem(
                'pin',
                _project.requiresAppPin
                    ? Icons.lock_rounded
                    : Icons.lock_open_rounded,
                tr(
                  widget.preferences,
                  _project.requiresAppPin
                      ? 'Remove recording PIN lock'
                      : 'Require PIN to open this recording',
                  _project.requiresAppPin
                      ? 'Retirer le verrouillage PIN'
                      : 'Exiger un PIN pour ouvrir cet enregistrement',
                ),
                enabled: !_loading,
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 850;

            final tabBar = Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color:
                    colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: TabBar(
                controller: _tabController,
                splashBorderRadius: BorderRadius.circular(14),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                indicator: BoxDecoration(
                  color: colorScheme.primary,
                  borderRadius: BorderRadius.circular(14),
                ),
                labelColor: colorScheme.onPrimary,
                unselectedLabelColor: colorScheme.onSurfaceVariant,
                labelStyle: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13),
                tabs: <Widget>[
                  Tab(
                    icon: const Icon(Icons.mic_rounded, size: 18),
                    text:
                        '${tr(widget.preferences, 'Takes', 'Prises')} (${_project.sessions.length})',
                  ),
                  Tab(
                    icon: const Icon(Icons.notes_rounded, size: 18),
                    text:
                        '${tr(widget.preferences, 'Notes', 'Notes')} (${_notesWordCount}w)',
                  ),
                  Tab(
                    icon: const Icon(Icons.bookmarks_rounded, size: 18),
                    text:
                        '${tr(widget.preferences, 'Marks', 'Repères')} (${_project.bookmarks.length})',
                  ),
                  Tab(
                    icon: const Icon(Icons.attach_file_rounded, size: 18),
                    text:
                        '${tr(widget.preferences, 'Files', 'Fichiers')} (${_attachments.length})',
                  ),
                ],
              ),
            );

            if (isWide) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 380,
                      child: ListView(
                        children: <Widget>[
                          _buildWorkspaceHeader(theme),
                          const SizedBox(height: 16),
                          _buildHeroAudioConsole(theme),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: BorderSide(
                              color: colorScheme.outlineVariant
                                  .withValues(alpha: 0.4)),
                        ),
                        color: colorScheme.surface,
                        child: Column(
                          children: <Widget>[
                            const SizedBox(height: 8),
                            tabBar,
                            const Divider(height: 12),
                            Expanded(
                              child: TabBarView(
                                controller: _tabController,
                                children: <Widget>[
                                  _buildSessionsTab(theme),
                                  _buildNotesTab(theme),
                                  _buildBookmarksTab(theme),
                                  _buildAttachmentsTab(theme),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            return NestedScrollView(
              headerSliverBuilder: (context, innerBoxIsScrolled) => <Widget>[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _buildWorkspaceHeader(theme),
                        const SizedBox(height: 14),
                        _buildHeroAudioConsole(theme),
                      ],
                    ),
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _SliverTabBarDelegate(
                    tabBar: tabBar,
                    color: theme.scaffoldBackgroundColor,
                  ),
                ),
              ],
              body: TabBarView(
                controller: _tabController,
                children: <Widget>[
                  _buildSessionsTab(theme),
                  _buildNotesTab(theme),
                  _buildBookmarksTab(theme),
                  _buildAttachmentsTab(theme),
                ],
              ),
            );
          },
        ),
      ),
    );
  }


  PopupMenuItem<String> _projectMenuItem(
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
  }) {
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Flexible(child: Text(label)),
        ],
      ),
    );
  }

  String _formatDuration(int milliseconds) {
    final d = Duration(milliseconds: milliseconds);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverTabBarDelegate({required this.tabBar, required this.color});

  final Widget tabBar;
  final Color color;

  @override
  double get minExtent => 56;
  @override
  double get maxExtent => 56;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: color,
      child: Center(child: tabBar),
    );
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return tabBar != oldDelegate.tabBar || color != oldDelegate.color;
  }
}

class _BookmarkTimelineStrip extends StatelessWidget {
  const _BookmarkTimelineStrip({
    required this.bookmarks,
    required this.totalMs,
    required this.onTap,
  });

  final List<RavenBookmark> bookmarks;
  final int totalMs;
  final Future<void> Function(int milliseconds) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: 34,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                right: 0,
                top: 15,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              for (final bookmark in bookmarks)
                Positioned(
                  left: ((bookmark.positionMs / totalMs).clamp(0.0, 1.0) *
                              (width - 22))
                          .clamp(0.0, width - 22)
                          .toDouble(),
                  top: 0,
                  child: Tooltip(
                    message:
                        '${bookmark.label} · ${_formatBookmarkTime(bookmark.positionMs)}',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => onTap(bookmark.positionMs),
                      child: Icon(Icons.bookmark_rounded,
                          size: 20, color: colorScheme.primary),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

String _formatBookmarkTime(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
}