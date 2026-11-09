import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cryptography/cryptography.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/raven_project.dart';
import '../services/app_preferences.dart';
import '../services/attachment_service.dart';
import '../services/project_archive_service.dart';
import '../services/audio_encryption_service.dart';
import '../services/audio_timeline.dart';
import '../services/project_repository.dart';
import '../services/ai_provider_service.dart';
import '../services/ai_key_vault.dart';
import '../services/audio_merge_service.dart';
import '../services/audio_visibility_service.dart';
import '../services/audio_share_service.dart';
import '../services/audio_protection_service.dart';
import '../widgets/audio_password_dialog.dart';
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

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioPlayer _player = AudioPlayer();
  final AudioEncryptionService _encryption = AudioEncryptionService();
  final List<String> _temporaryDecryptedPaths = <String>[];
  final TextEditingController _notesController = TextEditingController();
  late RavenProject _project;
  bool _loading = true;
  bool _savingNotes = false;
  SecretKey? _audioKey;
  String? _error;
  String? _securityWarning;

  @override
  void initState() {
    super.initState();
    _project = widget.project;
    _notesController.text = _project.notes;
    _loadSelectedSession();
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.id != widget.project.id) {
      _project = widget.project;
      _audioKey = null;
      _notesController.text = _project.notes;
      _loadSelectedSession();
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    _player.dispose();
    // Best-effort cleanup: the OS may also remove temporary files after exit.
    for (final tempPath in _temporaryDecryptedPaths) {
      File(tempPath)
          .delete()
          .catchError((Object _, StackTrace __) => File(tempPath));
    }
    super.dispose();
  }

  RavenAudioSession? get _session =>
      _project.sessions.isEmpty ? null : _project.sessions.last;

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
        context,
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
      (_project.masterAudioPath != null && !_project.isAudioProtected)
          ? localPosition.inMilliseconds
          : AudioTimeline.offsetOf(_project.sessions, index ?? 0) +
              localPosition.inMilliseconds;

  Future<void> _seekGlobal(int milliseconds) async {
    if (_project.sessions.isEmpty) return;
    if (_project.masterAudioPath != null && !_project.isAudioProtected) {
      await _player.seek(Duration(milliseconds: milliseconds));
      return;
    }
    final target = AudioTimeline.locate(_project.sessions, milliseconds);
    await _player.seek(Duration(milliseconds: target.localMs),
        index: target.index);
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

      // Protected projects must never use a plaintext master. If a stale master
      // exists, attempt cleanup, but keep source sessions as the recovery path.
      if (masterPath != null && (_project.isAudioProtected || !masterExists)) {
        if (_project.isAudioProtected && masterExists) {
          try {
            await File(masterPath).delete();
          } on FileSystemException {
            // A later cleanup may succeed after the player releases old handles.
          }
        }
        final withoutMaster = _project.copyWith(clearMasterAudioPath: true);
        try {
          await _saveProject(withoutMaster);
        } catch (_) {
          // Playback should not be blocked by a failed metadata write. Keep the
          // corrected state in memory and report persistence via later saves.
          _project = withoutMaster;
          widget.onProjectChanged(withoutMaster);
        }
      }

      // Prefer the fast master file, but a present file can still be truncated
      // or corrupt. Validate it through the player and fall back to retained
      // source sessions instead of making the entire project unplayable.
      if (masterPath != null && !_project.isAudioProtected && masterExists) {
        try {
          await _player.setAudioSource(
            AudioSource.uri(Uri.file(masterPath), tag: 'master'),
            initialPosition: Duration.zero,
          );
          loaded = true;
        } catch (_) {
          try {
            await _player.stop();
          } catch (_) {}
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
        final sources = <AudioSource>[];
        for (final session in _project.sessions) {
          final source = File(session.audioPath);
          if (!await source.exists()) {
            throw FileSystemException(
                'An audio segment is missing', source.path);
          }
          var playbackPath = session.audioPath;
          if (_project.isAudioProtected) {
            final extension = session.format == 'wav'
                ? 'wav'
                : session.format == 'flac'
                    ? 'flac'
                    : 'm4a';
            final temp = File(
                '${cache.path}/raven-playback-${_project.id}-${session.id}.$extension');
            if (await temp.exists()) await temp.delete();
            await _encryption.decryptFile(
                input: source, output: temp, key: _audioKey);
            _temporaryDecryptedPaths.add(temp.path);
            playbackPath = temp.path;
          }
          sources.add(AudioSource.uri(Uri.file(playbackPath), tag: session.id));
        }
        await _player.setAudioSource(
          ConcatenatingAudioSource(children: sources, useLazyPreparation: true),
          initialIndex: 0,
          initialPosition: Duration.zero,
        );
        loaded = true;
      }

      // If a previous protection attempt or process crash left plaintext files,
      // retry their cleanup only after the player has switched to safe sources.
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

  /// Opens the attachments manager. Attachments live in their own expandable
  /// panel on the project screen; this sheet adds full multi-select support so
  /// several files can be selected, shared or removed at once.
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
                                    : const Icon(Icons.attach_file_rounded),
                                title: Text(file.uri.pathSegments.last,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(_formatBytes(file.lengthSync())),
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
        continueProject: _project,
        onSaved: () {},
      ),
    ));
    if (!mounted) return;
    final refreshed = widget.repository.projectById(_project.id);
    if (refreshed != null) {
      setState(() {
        _project = refreshed;
      });
      widget.onProjectChanged(refreshed);
      await _loadSelectedSession();
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
    try {
      await _saveProject(_project.copyWith(notes: _notesController.text));
      final directory = Directory(
          '${widget.repository.projectsDirectory.path}/${_project.id}/notes');
      await directory.create(recursive: true);
      final safeTitle = _project.title
          .trim()
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
      final file = File(
          '${directory.path}/${safeTitle.isEmpty ? 'project' : safeTitle}.txt');
      await file.writeAsString(_notesController.text,
          encoding: utf8, flush: true);
      await AudioShareService().shareFile(file);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(tr(widget.preferences, 'Notes saved as a .txt file',
            'Notes enregistrées dans un fichier .txt')),
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
        await _seekGlobal(AudioTimeline.offsetOf(_project.sessions, index));
        await _player.play();
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
      case 'delete':
        await _deleteSession(session, index);
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
    final sessions = List<RavenAudioSession>.of(_project.sessions);
    sessions[index] = session.copyWith(name: name.trim());
    try {
      // Bookmarks store a sessionId; renaming a part must keep those links
      // valid so the bookmark panel still shows the right recording part.
      final validIds = sessions.map((s) => s.id).toSet();
      final bookmarks = _project.bookmarks
          .where((b) => b.sessionId.isEmpty || validIds.contains(b.sessionId))
          .toList();
      await _saveProject(
          _project.copyWith(sessions: sessions, bookmarks: bookmarks));
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

      final previousPublicLocation = _project.publicCopyLocation;
      if (previousPublicLocation != null) {
        await AudioVisibilityService().remove(previousPublicLocation);
        await _saveProject(_project.copyWith(clearPublicCopyLocation: true));
      }
      final oldMasterPath = _project.masterAudioPath;
      final sessions = List<RavenAudioSession>.of(_project.sessions)
        ..removeAt(index);
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

      String? mergeFailure;
      if (sessions.length > 1 && !_project.isAudioProtected) {
        try {
          final merged = await AudioMergeService().mergeProject(
            sessions: sessions,
            outputDirectory: Directory(
                '${widget.repository.projectsDirectory.path}/${_project.id}/sessions'),
            projectId: _project.id,
            format: widget.preferences.recordingFormat,
            bitRate: widget.preferences.bitRate,
            sampleRate: widget.preferences.sampleRate,
          );
          await _saveProject(_project.copyWith(masterAudioPath: merged.path));
        } catch (error) {
          mergeFailure = '$error';
        }
      }
      if (previousPublicLocation != null &&
          sessions.isNotEmpty &&
          !_project.isAudioProtected &&
          !_project.requiresAppPin) {
        var sourcePath = _project.masterAudioPath;
        if (sessions.length == 1) {
          sourcePath = sessions.single.audioPath;
        }
        if (sourcePath != null) {
          try {
            final location = await AudioVisibilityService().publish(
              source: File(sourcePath),
              title: _project.title,
              projectId: _project.id,
            );
            await _saveProject(_project.copyWith(publicCopyLocation: location));
          } catch (error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  'Session deleted, but the public copy was not recreated: $error'),
            ));
            return;
          }
        }
      }
      if (mergeFailure != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Session deleted, but the continuous audio could not be rebuilt: $mergeFailure'),
        ));
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not delete recording session: $error'),
      ));
    }
  }

  Widget _buildSessionsSection(ThemeData theme) {
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: Icon(Icons.multitrack_audio_rounded,
            color: theme.colorScheme.primary),
        title: Text(tr(
          widget.preferences,
          'Recording sessions (${_project.sessions.length})',
          'Sessions d’enregistrement (${_project.sessions.length})',
        )),
        subtitle: Text(tr(
          widget.preferences,
          'Each session stays available separately while the project plays as one.',
          'Chaque session reste disponible séparément tandis que le projet est lu en continu.',
        )),
        children: _project.sessions.asMap().entries.map((entry) {
          final index = entry.key;
          final session = entry.value;
          final title = session.name.isEmpty
              ? tr(widget.preferences, 'Session ${index + 1}',
                  'Session ${index + 1}')
              : session.name;
          return ListTile(
            leading: CircleAvatar(child: Text('${index + 1}')),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${_formatDuration(session.durationMs)} · ${session.format.toUpperCase()} · ${DateFormat('dd MMM yyyy, HH:mm', widget.preferences.isFrench ? 'fr' : 'en').format(session.createdAt)}',
              maxLines: 2,
            ),
            onTap: _loading
                ? null
                : () => _handleSessionAction('play', session, index),
            trailing: PopupMenuButton<String>(
              tooltip: tr(widget.preferences, 'Session actions',
                  'Actions de la session'),
              onSelected: (action) =>
                  _handleSessionAction(action, session, index),
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                PopupMenuItem(
                  value: 'play',
                  child: Text(tr(
                      widget.preferences, 'Play session', 'Lire la session')),
                ),
                PopupMenuItem(
                  value: 'share',
                  child: Text(tr(widget.preferences, 'Share session',
                      'Partager la session')),
                ),
                PopupMenuItem(
                  value: 'details',
                  child: Text(tr(widget.preferences, 'Details', 'Détails')),
                ),
                PopupMenuItem(
                  value: 'rename',
                  child: Text(tr(widget.preferences, 'Rename session',
                      'Renommer la session')),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(tr(
                    widget.preferences,
                    _project.sessions.length == 1
                        ? 'Move recording to Trash'
                        : 'Delete session',
                    _project.sessions.length == 1
                        ? 'Mettre dans la corbeille'
                        : 'Supprimer la session',
                  )),
                ),
              ],
            ),
          );
        }).toList(),
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
    if (newTitle != null &&
        newTitle.trim().isNotEmpty &&
        newTitle.trim() != _project.title) {
      await _saveProject(_project.copyWith(title: newTitle.trim()));
    }
  }

  Future<int> _measureSessionDuration(RavenAudioSession selected) async {
    final original = File(selected.audioPath);
    if (!await original.exists()) {
      throw FileSystemException(
          'The recovered audio file is missing.', original.path);
    }

    var pathToMeasure = original.path;
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
      pathToMeasure = temporaryPlaintext.path;
    }

    final probe = AudioPlayer();
    try {
      // The main player is positioned at the first item of a concatenated
      // playlist; its duration is not necessarily the recovered final segment.
      await probe.setFilePath(pathToMeasure);
      final duration = probe.duration;
      if (duration == null || duration.inMilliseconds <= 0) {
        throw StateError(
            'RAVEN could not determine the recovered audio duration.');
      }
      return duration.inMilliseconds;
    } finally {
      await probe.dispose();
      if (temporaryPlaintext != null && await temporaryPlaintext.exists()) {
        try {
          await temporaryPlaintext.delete();
        } on FileSystemException {/* cleaned on next startup */}
      }
    }
  }

  Future<void> _finalizeRecoveredDraft() async {
    final selected = _session;
    if (selected == null || !_project.isDraft || _loading) return;
    setState(() => _loading = true);
    try {
      // A crash can leave the draft's last session at duration 0. Measure that
      // session individually rather than reading the main playlist's duration,
      // which may refer to the first segment.
      final durationMs = selected.durationMs > 0
          ? selected.durationMs
          : await _measureSessionDuration(selected);
      final updatedSessions = _project.sessions
          .map((item) => item.id == selected.id
              ? item.copyWith(durationMs: durationMs)
              : item)
          .toList();
      await _saveProject(
          _project.copyWith(isDraft: false, sessions: updatedSessions));

      // Rebuild the one-file master where possible. Source sessions remain the
      // durable recovery copy if encoding fails or the platform lacks FFmpeg.
      if (!_project.isAudioProtected) {
        try {
          final master = await AudioMergeService().mergeProject(
            sessions: _project.sessions,
            outputDirectory: Directory(
                '${widget.repository.projectsDirectory.path}/${_project.id}/sessions'),
            projectId: _project.id,
            format: widget.preferences.recordingFormat,
          );
          await _saveProject(_project.copyWith(masterAudioPath: master.path));
          if (_project.requiresAppPin) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(tr(
                  widget.preferences,
                  'Recovered audio remains private because this recording requires a PIN.',
                  'L’audio récupéré reste privé, car cet enregistrement exige un code PIN.',
                )),
              ));
            }
          } else {
            final previousPublicCopy = _project.publicCopyLocation;
            String? newPublicCopy;
            try {
              newPublicCopy = await AudioVisibilityService().publish(
                source: File(master.path),
                title: _project.title,
                projectId: _project.id,
              );
              await _saveProject(_project.copyWith(
                publicCopyLocation: newPublicCopy,
              ));
              if (previousPublicCopy != null &&
                  previousPublicCopy != newPublicCopy) {
                try {
                  await AudioVisibilityService().remove(previousPublicCopy);
                } catch (cleanupError) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(
                          'The new audio was published, but the previous public copy could not be removed: $cleanupError'),
                    ));
                  }
                }
              }
            } catch (publishError) {
              Object failure = publishError;
              if (newPublicCopy != null &&
                  _project.publicCopyLocation != newPublicCopy) {
                try {
                  await AudioVisibilityService().remove(newPublicCopy);
                } catch (cleanupError) {
                  failure = StateError(
                    '$publishError The new public copy could not be cleaned up: $cleanupError',
                  );
                }
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(tr(
                    widget.preferences,
                    'Recovered audio is saved in RAVEN, but could not be published: $failure',
                    'L’audio récupéré est enregistré dans RAVEN, mais n’a pas pu être publié : $failure',
                  )),
                ));
              }
            }
          }
        } catch (mergeError) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(tr(
              widget.preferences,
              'Draft recovered. RAVEN will play its parts in sequence because the master merge failed.',
              'Brouillon récupéré. RAVEN lira les parties à la suite car la fusion principale a échoué.',
            ))));
          }
        }
      }
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

  /// Adds a bookmark at the current playback position. Works even while audio
  /// is paused (uses the paused position) and always records the position on the
  /// single continuous project timeline.
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

    final activeIndex = _player.currentIndex ?? 0;
    final globalPosition = existing?.positionMs ??
        _globalPositionMs(activeIndex, _player.position);
    // Resolve which recording part the position lives in on the single
    // continuous timeline, whether playback uses the master or the sessions.
    final timelineIndex = AudioTimeline.locate(
            _project.sessions, globalPosition)
        .index;
    final activeSession = timelineIndex >= 0 &&
            timelineIndex < _project.sessions.length
        ? _project.sessions[timelineIndex]
        : _project.sessions.last;
    final sessionNumber = _project.sessions.indexWhere(
            (s) => s.id == activeSession.id) +
        1;

    final wasPlaying = _player.playing;
    if (wasPlaying) await _player.pause();

    final controller = TextEditingController(
      text: existing?.label ??
          tr(widget.preferences, 'Bookmark', 'Repère') +
              ' ${_project.bookmarks.length + 1}',
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
        content: Text('${tr(widget.preferences, 'Could not save bookmark', 'Impossible d’enregistrer le repère')}: $error'),
      ));
    }
  }

  Future<void> _deleteBookmark(RavenBookmark bookmark) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(widget.preferences, 'Delete bookmark?',
            'Supprimer le repère ?')),
        content: Text('${bookmark.label}\n${_formatBookmarkTime(bookmark.positionMs)}'),
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
    final remaining = _project.bookmarks
        .where((b) => b.id != bookmark.id)
        .toList();
    try {
      await _saveProject(_project.copyWith(bookmarks: remaining));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${tr(widget.preferences, 'Could not delete bookmark', 'Impossible de supprimer le repère')}: $error'),
      ));
    }
  }

  Future<void> _jumpToBookmark(RavenBookmark bookmark) async {
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
                    content: Text(tr(widget.preferences, 'Copied to clipboard.',
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

  Future<void> _toggleProjectPin() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_loading) return;
    if (!_project.requiresAppPin && _project.publicCopyLocation != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
        widget.preferences,
        'Remove the public copy before locking this recording with a PIN. Public copies can be opened outside RAVEN.',
        'Supprimez la copie publique avant de verrouiller cet enregistrement par code PIN. Les copies publiques peuvent être ouvertes hors de RAVEN.',
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
    final existingLocation = _project.publicCopyLocation;
    final enabling = existingLocation == null;
    if (enabling && (_project.isAudioProtected || _project.requiresAppPin)) {
      final message = _project.isAudioProtected
          ? tr(
              widget.preferences,
              'Decrypt this recording before making a public copy. Protected recordings cannot be published.',
              'Déchiffrez ce projet avant de créer une copie publique. Les enregistrements protégés ne peuvent pas être publiés.')
          : tr(
              widget.preferences,
              'Remove the individual PIN lock before making a public copy. A public copy could bypass RAVEN’s project lock.',
              'Retirez le verrouillage PIN individuel avant de créer une copie publique. Une copie publique contournerait le verrou du projet.');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(
            widget.preferences,
            enabling
                ? 'Show recording in device folders?'
                : 'Hide recording from device folders?',
            enabling
                ? 'Afficher dans les dossiers de l’appareil ?'
                : 'Masquer des dossiers de l’appareil ?')),
        content: Text(tr(
            widget.preferences,
            enabling
                ? 'RAVEN will create a separate copy in Music/RAVEN (Android) or Downloads/RAVEN (Windows). Other apps and people with access to those folders may be able to see it. Your private RAVEN original remains in place. This is not available for encrypted or individually PIN-locked recordings.'
                : 'RAVEN will remove the public copy it created. Your private original and project remain inside RAVEN. If you shared or copied the public file elsewhere, those other copies are not removed.',
            enabling
                ? 'RAVEN créera une copie séparée dans Music/RAVEN (Android) ou Downloads/RAVEN (Windows). D’autres applications ou personnes ayant accès à ces dossiers pourront la voir. L’original privé reste dans RAVEN. Cette option n’est pas disponible pour les enregistrements chiffrés ou verrouillés par un PIN individuel.'
                : 'RAVEN supprimera la copie publique créée par l’application. L’original privé et le projet resteront dans RAVEN. Les copies partagées ou copiées ailleurs ne seront pas supprimées.')),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(
                  widget.preferences,
                  enabling ? 'Continue' : 'Remove public copy',
                  enabling ? 'Continuer' : 'Supprimer la copie publique'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _loading = true);
    final visibility = AudioVisibilityService();
    try {
      if (enabling) {
        var sourcePath = _project.masterAudioPath;
        if (sourcePath == null || !await File(sourcePath).exists()) {
          final master = await AudioMergeService().mergeProject(
            sessions: _project.sessions,
            outputDirectory: Directory(
                '${widget.repository.projectsDirectory.path}/${_project.id}/sessions'),
            projectId: _project.id,
            format: _project.sessions.last.format,
            bitRate: widget.preferences.bitRate,
            sampleRate: widget.preferences.sampleRate,
          );
          sourcePath = master.path;
          await _saveProject(_project.copyWith(masterAudioPath: sourcePath));
        }
        final location = await visibility.publish(
          source: File(sourcePath),
          title: _project.title,
          projectId: _project.id,
        );
        try {
          await _saveProject(_project.copyWith(publicCopyLocation: location));
        } catch (_) {
          try {
            await visibility.remove(location);
          } catch (_) {}
          rethrow;
        }
      } else {
        await visibility.remove(existingLocation);
        await _saveProject(_project.copyWith(clearPublicCopyLocation: true));
      }
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(tr(
              widget.preferences,
              enabling
                  ? 'Public copy created. The private original is unchanged.'
                  : 'Public copy removed. The private original is unchanged.',
              enabling
                  ? 'Copie publique créée. L’original privé est inchangé.'
                  : 'Copie publique supprimée. L’original privé est inchangé.'))));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${tr(widget.preferences, 'Could not update folder visibility', 'Impossible de modifier la visibilité')}: $error')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final createdLabel = DateFormat('EEEE, dd MMM yyyy · HH:mm',
            widget.preferences.isFrench ? 'fr' : 'en')
        .format(_project.createdAt);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(widget.preferences, 'Project', 'Projet')),
        actions: <Widget>[
          IconButton(
              tooltip: tr(widget.preferences, 'Add another recording session',
                  'Ajouter une session d’enregistrement'),
              onPressed:
                  _loading || _project.isTrashed ? null : _continueRecording,
              icon: const Icon(Icons.mic_none_rounded)),
          IconButton(
            tooltip: tr(widget.preferences, 'Add bookmark at current position',
                'Ajouter un repère à la position actuelle'),
            onPressed: _loading || _error != null || _project.sessions.isEmpty
                ? null
                : () => _addBookmark(),
            icon: const Icon(Icons.bookmark_add_rounded),
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
                color: _project.isFavorite ? theme.colorScheme.tertiary : null),
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
                _project.publicCopyLocation == null
                    ? Icons.folder_outlined
                    : Icons.folder_off_outlined,
                tr(
                  widget.preferences,
                  _project.publicCopyLocation == null
                      ? 'Show in device folders'
                      : 'Hide from device folders',
                  _project.publicCopyLocation == null
                      ? 'Afficher dans les dossiers'
                      : 'Masquer des dossiers',
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
                  tr(widget.preferences, 'Save and share notes as .txt',
                      'Enregistrer et partager les notes en .txt')),
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
            final isCompact = constraints.maxWidth < 600;
            final horizontalPadding = isCompact ? 16.0 : 28.0;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    12,
                    horizontalPadding,
                    26,
                  ),
                  children: <Widget>[
                    Text(_project.title,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text(createdLabel,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 12),
                    Card(
                      color: theme.colorScheme.primaryContainer
                          .withValues(alpha: 0.55),
                      child: ListTile(
                        leading: Icon(Icons.mic_none_rounded,
                            color: theme.colorScheme.primary),
                        title: Text(tr(
                          widget.preferences,
                          'Add a session or merge audio',
                          'Ajouter une session ou fusionner l’audio',
                        )),
                        subtitle: Text(tr(
                          widget.preferences,
                          'The microphone button adds a new recording session to this project. Merging combines sessions for continuous playback; the original sessions remain available.',
                          'Le bouton du microphone ajoute une session à ce projet. La fusion assemble les sessions pour une lecture continue ; les sessions originales restent disponibles.',
                        )),
                      ),
                    ),
                    if (_project.sessions.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 12),
                      _buildSessionsSection(theme),
                    ],
                    if (_project.sessions.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 12),
                      _buildBookmarksSection(theme),
                      const SizedBox(height: 18),
                    ],
                    const SizedBox(height: 22),
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        color: theme.colorScheme.surfaceContainerLow,
                        border: Border.all(
                            color: theme.colorScheme.outlineVariant
                                .withValues(alpha: 0.45)),
                      ),
                      child: Column(
                        children: <Widget>[
                          if (_project.sessions.length > 1)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                tr(
                                    widget.preferences,
                                    '${_project.sessions.length} recording parts · played as one audio',
                                    '${_project.sessions.length} parties d’enregistrement · lues comme un seul audio'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ),
                          if (_securityWarning != null)
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 14),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.errorContainer,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                _securityWarning!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onErrorContainer),
                              ),
                            ),
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                                color: theme.colorScheme.primary
                                    .withValues(alpha: 0.12),
                                shape: BoxShape.circle),
                            child: Icon(Icons.graphic_eq_rounded,
                                size: 40, color: theme.colorScheme.primary),
                          ),
                          const SizedBox(height: 15),
                          Text(
                              _project.sessions.isEmpty
                                  ? '—'
                                  : _formatDuration(
                                      AudioTimeline.totalDurationMs(
                                          _project.sessions)),
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 20),
                          if (_loading)
                            const Padding(
                                padding: EdgeInsets.all(18),
                                child: CircularProgressIndicator())
                          else if (_error != null)
                            Text(_error!,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(color: theme.colorScheme.error))
                          else ...<Widget>[
                            StreamBuilder<int?>(
                              stream: _player.currentIndexStream,
                              builder: (context, indexSnapshot) {
                                final index = indexSnapshot.data ??
                                    _player.currentIndex ??
                                    0;
                                return StreamBuilder<Duration>(
                                  stream: _player.positionStream,
                                  builder: (context, positionSnapshot) {
                                    final position = Duration(
                                        milliseconds: _globalPositionMs(
                                            index,
                                            positionSnapshot.data ??
                                                Duration.zero));
                                    final duration = Duration(
                                        milliseconds:
                                            AudioTimeline.totalDurationMs(
                                                _project.sessions));
                                    final maxMs = duration.inMilliseconds > 0
                                        ? duration.inMilliseconds.toDouble()
                                        : 1.0;
                                    return Column(
                                      children: <Widget>[
                                        Slider(
                                          min: 0,
                                          max: maxMs,
                                          value: position.inMilliseconds
                                              .toDouble()
                                              .clamp(0, maxMs)
                                              .toDouble(),
                                          onChanged: (value) =>
                                              _seekGlobal(value.round()),
                                        ),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: <Widget>[
                                            Text(
                                                _formatDuration(
                                                    position.inMilliseconds),
                                                style: theme
                                                    .textTheme.labelSmall
                                                    ?.copyWith(
                                                        color: theme.colorScheme
                                                            .onSurfaceVariant)),
                                            Text(
                                                _formatDuration(
                                                    duration.inMilliseconds),
                                                style: theme
                                                    .textTheme.labelSmall
                                                    ?.copyWith(
                                                        color: theme.colorScheme
                                                            .onSurfaceVariant)),
                                          ],
                                        ),
                                      ],
                                    );
                                  },
                                );
                              },
                            ),
                            const SizedBox(height: 6),
                            StreamBuilder<PlayerState>(
                              stream: _player.playerStateStream,
                              builder: (context, snapshot) {
                                final playing = snapshot.data?.playing ?? false;
                                return Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: <Widget>[
                                    IconButton(
                                      tooltip: tr(
                                          widget.preferences,
                                          'Restart from the beginning',
                                          'Recommencer au début'),
                                      onPressed: () => _seekGlobal(0),
                                      icon: const Icon(Icons.replay_rounded),
                                      iconSize: 27,
                                    ),
                                    const SizedBox(width: 10),
                                    IconButton.filledTonal(
                                      tooltip: tr(
                                          widget.preferences,
                                          'Bookmark this exact moment',
                                          'Repérer ce moment exact'),
                                      onPressed:
                                          _loading || _error != null
                                              ? null
                                              : () => _addBookmark(),
                                      icon: const Icon(
                                          Icons.bookmark_add_rounded),
                                      iconSize: 24,
                                    ),
                                    const SizedBox(width: 10),
                                    SizedBox(
                                      width: 66,
                                      height: 66,
                                      child: FilledButton(
                                        style: FilledButton.styleFrom(
                                            shape: const CircleBorder(),
                                            padding: EdgeInsets.zero),
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
                                            size: 34),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    IconButton(
                                      tooltip: tr(
                                          widget.preferences,
                                          'Show bookmarks',
                                          'Afficher les repères'),
                                      onPressed: () => _showBookmarksSheet(),
                                      icon: const Icon(
                                          Icons.bookmarks_outlined),
                                      iconSize: 25,
                                    ),
                                    const SizedBox(width: 4),
                                    PopupMenuButton<double>(
                                      tooltip: tr(
                                          widget.preferences,
                                          'Playback speed',
                                          'Vitesse de lecture'),
                                      icon: const Icon(Icons.speed_rounded),
                                      onSelected: (speed) =>
                                          _player.setSpeed(speed),
                                      itemBuilder: (_) =>
                                          <PopupMenuEntry<double>>[
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
                                              child: Text('$speed×')),
                                      ],
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (_project.isDraft) ...<Widget>[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              tr(
                                  widget.preferences,
                                  'Recovered recording draft',
                                  'Brouillon d’enregistrement récupéré'),
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              tr(
                                  widget.preferences,
                                  'RAVEN found a project that was not finalised before the app closed. Review playback first, then finalise the draft if the audio is usable.',
                                  'RAVEN a retrouvé un projet qui n’a pas été finalisé avant la fermeture de l’application. Vérifiez la lecture, puis finalisez le brouillon si l’audio est utilisable.'),
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton.tonalIcon(
                                onPressed: _loading || _error != null
                                    ? null
                                    : _finalizeRecoveredDraft,
                                icon: const Icon(
                                    Icons.check_circle_outline_rounded),
                                label: Text(tr(
                                    widget.preferences,
                                    'Finalise draft',
                                    'Finaliser le brouillon')),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    Row(
                      children: <Widget>[
                        Expanded(
                            child: Text(
                                tr(widget.preferences, 'Project notes',
                                    'Notes du projet'),
                                style: theme.textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w800))),
                        PopupMenuButton<String>(
                          tooltip: tr(widget.preferences, 'AI tools for notes',
                              'Outils IA pour les notes'),
                          icon: const Icon(Icons.auto_awesome_rounded),
                          onSelected: (task) => _runAiTask(task),
                          itemBuilder: (context) => <PopupMenuEntry<String>>[
                            PopupMenuItem(
                                value: 'summary',
                                child: Text(tr(widget.preferences,
                                    'Summarize notes', 'Résumer les notes'))),
                            PopupMenuItem(
                                value: 'organize',
                                child: Text(tr(
                                    widget.preferences,
                                    'Organize and polish',
                                    'Organiser et améliorer'))),
                            PopupMenuItem(
                                value: 'translate',
                                child: Text(tr(widget.preferences,
                                    'Translate notes', 'Traduire les notes'))),
                          ],
                        ),
                        TextButton.icon(
                          onPressed: _savingNotes ? null : _saveNotes,
                          icon: _savingNotes
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.save_outlined, size: 18),
                          label: Text(tr(
                              widget.preferences, 'Save notes', 'Enregistrer')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _notesController,
                      minLines: 4,
                      maxLines: 10,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: tr(
                            widget.preferences,
                            'Add context, ideas, timestamps or follow-up notes…',
                            'Ajoutez du contexte, des idées, des repères temporels ou des notes…'),
                        alignLabelWithHint: true,
                        filled: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 15),
                    Container(
                      padding: const EdgeInsets.all(15),
                      decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(18)),
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.lock_outline_rounded,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Text(
                                  tr(
                                      widget.preferences,
                                      'Stored in this app’s private folder. Protected audio is encrypted on this device; keep a backup because losing app data can make protected recordings unrecoverable.',
                                      'Stocké dans le dossier privé de l’application. L’audio protégé est chiffré sur cet appareil ; conservez une sauvegarde, car la perte des données de l’application peut rendre les enregistrements irrécupérables.'),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Full-screen-sized sheet listing every bookmark with jump/edit/delete.
  /// Reached from the player controls so bookmarks are one tap away.
  Future<void> _showBookmarksSheet() async {
    if (_project.sessions.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) {
          final bookmarks = List<RavenBookmark>.of(_project.bookmarks)
            ..sort((a, b) => a.positionMs.compareTo(b.positionMs));
          final colorScheme = Theme.of(sheetContext).colorScheme;
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(sheetContext).size.height * 0.7,
              child: Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.bookmarks_rounded),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            tr(widget.preferences, 'Bookmarks', 'Repères'),
                            style: Theme.of(sheetContext)
                                .textTheme
                                .titleLarge,
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            Navigator.pop(sheetContext);
                            await _addBookmark();
                          },
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: Text(tr(widget.preferences, 'Add here',
                              'Ajouter ici')),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: bookmarks.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                tr(
                                    widget.preferences,
                                    'No bookmarks yet.\nPlay the recording and tap Add here to mark a moment.',
                                    'Aucun repère.\nLancez la lecture et touchez Ajouter ici pour marquer un moment.'),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: bookmarks.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 6),
                            itemBuilder: (context, index) {
                              final bookmark = bookmarks[index];
                              return ListTile(
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                                tileColor: colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.45),
                                leading: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 9, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primary,
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: Text(
                                    _formatBookmarkTime(bookmark.positionMs),
                                    style: TextStyle(
                                      color: colorScheme.onPrimary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                title: Text(bookmark.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  _jumpToBookmark(bookmark);
                                },
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    IconButton(
                                      tooltip: tr(widget.preferences,
                                          'Rename', 'Renommer'),
                                      onPressed: () async {
                                        Navigator.pop(sheetContext);
                                        await _addBookmark(
                                            existing: bookmark);
                                      },
                                      icon: const Icon(Icons.edit_outlined),
                                    ),
                                    IconButton(
                                      tooltip: tr(widget.preferences,
                                          'Delete', 'Supprimer'),
                                      onPressed: () async {
                                        Navigator.pop(sheetContext);
                                        await _deleteBookmark(bookmark);
                                      },
                                      icon: Icon(Icons.delete_outline_rounded,
                                          color: colorScheme.error),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Bookmark panel: visible add button, sorted list, per-marker jump, rename
  /// and delete. Each entry shows its own timestamp and recording part so a
  /// multi-session project never hides where a bookmark really lives.
  Widget _buildBookmarksSection(ThemeData theme) {
    final bookmarks = List<RavenBookmark>.of(_project.bookmarks)
      ..sort((a, b) => a.positionMs.compareTo(b.positionMs));
    final totalMs = AudioTimeline.totalDurationMs(_project.sessions);
    final colorScheme = theme.colorScheme;

    String partLabel(RavenBookmark bookmark) {
      final index = _project.sessions
          .indexWhere((session) => session.id == bookmark.sessionId);
      if (index < 0) return '';
      final session = _project.sessions[index];
      final name =
          session.name.isEmpty ? 'Part ${index + 1}' : session.name;
      return ' · $name';
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: bookmarks.isNotEmpty,
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.bookmarks_rounded,
              size: 22, color: colorScheme.onTertiaryContainer),
        ),
        title: Text(tr(
            widget.preferences,
            'Timeline bookmarks',
            'Repères audio')),
        subtitle: Text(
          bookmarks.isEmpty
              ? tr(
                  widget.preferences,
                  'Mark a moment so you can jump straight back to it.',
                  'Marquez un moment pour y revenir directement.')
              : tr(
                  widget.preferences,
                  '${bookmarks.length} saved · tap to jump',
                  '${bookmarks.length} enregistré(s) · touchez pour accéder'),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton.filledTonal(
              tooltip: tr(widget.preferences, 'Add bookmark here',
                  'Ajouter un repère ici'),
              onPressed: _loading || _error != null
                  ? null
                  : () => _addBookmark(),
              icon: const Icon(Icons.add_rounded),
              visualDensity: VisualDensity.compact,
            ),
            const Icon(Icons.expand_more_rounded),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: <Widget>[
          if (bookmarks.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    tr(
                        widget.preferences,
                        'No bookmarks yet. Play the recording, then tap “Add bookmark” to pin this moment.',
                        'Aucun repère. Lancez la lecture, puis touchez « Ajouter un repère » pour épingler ce moment.'),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: _loading || _error != null
                        ? null
                        : () => _addBookmark(),
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                    label: Text(tr(widget.preferences, 'Add bookmark',
                        'Ajouter un repère')),
                  ),
                ],
              ),
            )
          else ...<Widget>[
            for (final bookmark in bookmarks)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _jumpToBookmark(bookmark),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                      child: Row(
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _formatBookmarkTime(bookmark.positionMs),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  bookmark.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600),
                                ),
                                if (partLabel(bookmark).isNotEmpty)
                                  Text(
                                    partLabel(bookmark).replaceFirst(' · ', ''),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                            color: colorScheme
                                                .onSurfaceVariant),
                                  ),
                              ],
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: tr(widget.preferences,
                                'Bookmark actions', 'Actions du repère'),
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
                            itemBuilder: (context) =>
                                <PopupMenuEntry<String>>[
                              PopupMenuItem<String>(
                                  value: 'play',
                                  child: Text(tr(widget.preferences,
                                      'Play from here', 'Lire à partir d’ici'))),
                              PopupMenuItem<String>(
                                  value: 'rename',
                                  child: Text(tr(widget.preferences,
                                      'Rename bookmark', 'Renommer le repère'))),
                              PopupMenuItem<String>(
                                  value: 'delete',
                                  child: Text(tr(widget.preferences,
                                      'Delete bookmark',
                                      'Supprimer le repère'))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (bookmarks.length > 1 && totalMs > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
                child: _BookmarkTimelineStrip(
                  bookmarks: bookmarks,
                  totalMs: totalMs,
                  onTap: _seekGlobal,
                ),
              ),
          ],
        ],
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

/// Compact visual overview of where bookmarks sit on the project timeline.
/// Tapping a marker seeks to it, so users can see spacing at a glance.
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
