import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/raven_project.dart';
import '../services/app_preferences.dart';
import '../services/attachment_service.dart';
import '../services/project_archive_service.dart';
import '../services/audio_encryption_service.dart';
import '../services/notes_pdf_service.dart';
import '../services/audio_timeline.dart';
import '../services/project_repository.dart';
import '../services/ai_provider_service.dart';
import '../services/ai_key_vault.dart';
import '../services/audio_merge_service.dart';
import '../services/audio_visibility_service.dart';
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
            await _encryption.decryptFile(input: source, output: temp);
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

  Future<void> _manageAttachments() async {
    final service = AttachmentService(widget.repository);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await service.pickAndAttach(_project.id);
      if (!mounted) return;
      final files = await service.list(_project.id);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.65,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                      tr(widget.preferences, 'Project attachments',
                          'Pièces jointes du projet'),
                      style: Theme.of(sheetContext).textTheme.titleLarge),
                ),
                Expanded(
                  child: files.isEmpty
                      ? Center(
                          child: Text(tr(
                              widget.preferences,
                              'No attachments yet. Use Add files to attach documents or images.',
                              'Aucune pièce jointe. Utilisez Ajouter des fichiers pour joindre des documents ou des images.')))
                      : ListView.builder(
                          itemCount: files.length,
                          itemBuilder: (context, index) => ListTile(
                            leading: const Icon(Icons.attach_file_rounded),
                            title: Text(files[index].uri.pathSegments.last,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle:
                                Text(_formatBytes(files[index].lengthSync())),
                            trailing: IconButton(
                              tooltip: tr(
                                  widget.preferences,
                                  'Remove attachment',
                                  'Supprimer la pièce jointe'),
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () async {
                                await service.remove(files[index]);
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                                if (mounted) await _manageAttachments();
                              },
                            ),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    onPressed: () async {
                      await service.pickAndAttach(_project.id);
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                      if (mounted) {
                        await _manageAttachments();
                      }
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

  Future<void> _exportNotesPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await NotesPdfService().printOrShare(
        _project,
        locale: widget.preferences.isFrench ? 'fr' : 'en',
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('PDF export failed: $error')),
      );
    }
  }

  Future<void> _handleProjectAction(String action) async {
    switch (action) {
      case 'bookmark':
        await _addBookmark();
      case 'attachments':
        await _manageAttachments();
      case 'visibility':
        await _togglePublicCopy();
      case 'export':
        await _exportProjectBundle();
      case 'pdf':
        await _exportNotesPdf();
      case 'rename':
        await _renameProject();
      case 'pin':
        await _toggleProjectPin();
    }
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
          input: original, output: temporaryPlaintext);
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
            format: _project.sessions.last.format,
          );
          await _saveProject(_project.copyWith(masterAudioPath: master.path));
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

  Future<void> _addBookmark() async {
    final session = _session;
    if (session == null) return;
    final controller = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(widget.preferences, 'Add timeline bookmark',
            'Ajouter un repère audio')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
              labelText:
                  tr(widget.preferences, 'Bookmark label', 'Nom du repère')),
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
    if (label == null || label.trim().isEmpty) return;
    final activeIndex = _player.currentIndex ?? 0;
    final globalPosition = _globalPositionMs(activeIndex, _player.position);
    final timelineIndex =
        _project.masterAudioPath != null && !_project.isAudioProtected
            ? AudioTimeline.locate(_project.sessions, globalPosition).index
            : activeIndex;
    final activeSession = timelineIndex < _project.sessions.length
        ? _project.sessions[timelineIndex]
        : session;
    final bookmark = RavenBookmark(
      id: const Uuid().v4(),
      sessionId: activeSession.id,
      positionMs: globalPosition,
      label: label.trim(),
      createdAt: DateTime.now(),
    );
    await _saveProject(_project
        .copyWith(bookmarks: <RavenBookmark>[..._project.bookmarks, bookmark]));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
              widget.preferences, 'Bookmark saved.', 'Repère enregistré.'))));
    }
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
              tooltip: tr(
                  widget.preferences,
                  'Continue recording in this project',
                  'Continuer l’enregistrement dans ce projet'),
              onPressed:
                  _loading || _project.isTrashed ? null : _continueRecording,
              icon: const Icon(Icons.mic_none_rounded)),
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
                  'export',
                  Icons.archive_outlined,
                  tr(widget.preferences, 'Export complete project',
                      'Exporter le projet complet')),
              _projectMenuItem(
                  'pdf',
                  Icons.picture_as_pdf_outlined,
                  tr(widget.preferences, 'Export notes as PDF',
                      'Exporter les notes en PDF')),
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
                    if (_project.bookmarks.isNotEmpty) ...<Widget>[
                      Text(
                          tr(widget.preferences, 'Timeline bookmarks',
                              'Repères audio'),
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      ..._project.bookmarks.map((bookmark) => Card(
                            child: ListTile(
                              leading:
                                  const Icon(Icons.bookmark_outline_rounded),
                              title: Text(bookmark.label),
                              subtitle: Text(
                                  _formatBookmarkTime(bookmark.positionMs)),
                              trailing: IconButton(
                                tooltip: tr(widget.preferences,
                                    'Jump to bookmark', 'Aller au repère'),
                                icon: const Icon(Icons.play_arrow_rounded),
                                onPressed: () async {
                                  await _seekGlobal(bookmark.positionMs);
                                },
                              ),
                            ),
                          )),
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
                                        onPressed: () => _player
                                            .seek(Duration.zero, index: 0),
                                        icon: const Icon(Icons.replay_rounded),
                                        iconSize: 27),
                                    const SizedBox(width: 20),
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
                                    const SizedBox(width: 20),
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

String _formatBookmarkTime(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
}
