import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:cryptography/cryptography.dart';

import 'models/raven_project.dart';
import 'services/audio_merge_service.dart';
import 'services/background_encode_service.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/player_screen.dart';
import 'screens/standalone_recording_screen.dart';
import 'screens/recorder_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_preferences.dart';
import 'services/app_lock_service.dart';
import 'services/audio_encryption_service.dart';
import 'services/audio_visibility_service.dart';
import 'services/audio_share_service.dart';
import 'services/audio_protection_service.dart';
import 'services/project_repository.dart';
import 'services/project_archive_service.dart';
import 'widgets/audio_password_dialog.dart';
import 'widgets/trim_editor.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.raven.raven.audio',
    androidNotificationChannelName: 'RAVEN audio playback',
    androidNotificationChannelDescription:
        'Playback controls for your RAVEN recordings',
    androidNotificationIcon: 'mipmap/ic_launcher',
    fastForwardInterval: Duration.zero,
    rewindInterval: Duration.zero,
  );

  await initializeDateFormatting('fr');
  try {
    await AudioEncryptionService.cleanupAbandonedPlaybackFiles();
  } catch (_) {}

  final repository = await ProjectRepository.create();
  final preferences = await AppPreferences.load();
  runApp(RavenApp(repository: repository, preferences: preferences));
}

class RavenApp extends StatefulWidget {
  const RavenApp(
      {required this.repository, required this.preferences, super.key});

  final ProjectRepository repository;
  final AppPreferences preferences;

  @override
  State<RavenApp> createState() => _RavenAppState();
}

class _RavenAppState extends State<RavenApp> {
  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF168CFF);
    return MaterialApp(
      title: 'RAVEN',
      debugShowCheckedModeBanner: false,
      themeMode:
          widget.preferences.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      theme: _buildTheme(seed, Brightness.light),
      darkTheme: _buildTheme(seed, Brightness.dark),
      locale: Locale(widget.preferences.isFrench ? 'fr' : 'en'),
      supportedLocales: const <Locale>[Locale('en'), Locale('fr')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: _MainShell(
        repository: widget.repository,
        preferences: widget.preferences,
        onSettingsChanged: () => setState(() {}),
        onProjectsChanged: () => setState(() {}),
      ),
    );
  }

  ThemeData _buildTheme(Color seed, Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF080D17)
          : const Color(0xFFF5F7FB),
      appBarTheme: AppBarThemeData(
        backgroundColor: brightness == Brightness.dark
            ? const Color(0xFF080D17)
            : const Color(0xFFF5F7FB),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: brightness == Brightness.dark
            ? const Color(0xFF111A29)
            : Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: brightness == Brightness.dark
            ? const Color(0xFF111A29)
            : Colors.white,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: scheme.primary, width: 1.5)),
      ),
    );
  }
}

class _MainShell extends StatefulWidget {
  const _MainShell({
    required this.repository,
    required this.preferences,
    required this.onSettingsChanged,
    required this.onProjectsChanged,
  });

  final ProjectRepository repository;
  final AppPreferences preferences;
  final VoidCallback onSettingsChanged;
  final VoidCallback onProjectsChanged;

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> with WidgetsBindingObserver {
  BackgroundEncodeService get _encoder => BackgroundEncodeService.instance;
  int _selectedIndex = 0;
  bool _tourShowing = false;
  late bool _locked;
  final TextEditingController _lockPinController = TextEditingController();
  Timer? _trashTimer;
  bool _recordingRouteActive = false;

  @override
  void initState() {
    super.initState();
    _locked = widget.preferences.appLockEnabled;
    _encoder.onProjectUpdated = (_) => _refreshProjects();
    _encoder.onSuccess = (message) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(message)),
      );
    };
    _encoder.onError = (message) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(message)),
      );
    };
    WidgetsBinding.instance.addObserver(this);
    _trashTimer =
        Timer.periodic(const Duration(hours: 12), (_) => _purgeExpiredTrash());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _purgeExpiredTrash();
      if (!_locked && !widget.preferences.hasCompletedOnboarding) {
        _showGuidedTour();
      }
    });
  }

  Future<void> _purgeExpiredTrash() async {
    try {
      await widget.repository.purgeExpiredTrash(
        retentionDays: widget.preferences.trashRetentionDays,
      );
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          'Some expired trash could not be removed: $error',
          'Certains éléments expirés n’ont pas pu être supprimés : $error',
        )),
      ));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trashTimer?.cancel();
    _lockPinController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _purgeExpiredTrash();
    }
  }

  Future<void> _unlockApp(String pin) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final valid = await AppLockService().verifyPin(pin);
    if (!mounted) return;
    if (valid) {
      _lockPinController.clear();
      setState(() => _locked = false);
      if (!widget.preferences.hasCompletedOnboarding) {
        _showGuidedTour();
      }
    } else {
      messenger?.showSnackBar(
        SnackBar(
            content: Text(tr(
                widget.preferences, 'Incorrect PIN.', 'Code PIN incorrect.'))),
      );
    }
  }

  Widget _buildLockGate() {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(24)),
                    child: Icon(Icons.lock_rounded,
                        size: 38, color: Theme.of(context).colorScheme.primary),
                  ),
                  const SizedBox(height: 22),
                  Text('RAVEN',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(
                              fontWeight: FontWeight.w900, letterSpacing: 3)),
                  const SizedBox(height: 8),
                  Text(tr(widget.preferences, 'Enter your PIN to continue',
                      'Saisissez votre code PIN pour continuer')),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _lockPinController,
                    autofocus: true,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 12,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (value) => _unlockApp(value),
                    decoration: InputDecoration(
                        labelText:
                            tr(widget.preferences, 'App PIN', 'Code PIN'),
                        prefixIcon: const Icon(Icons.password_rounded)),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => _unlockApp(_lockPinController.text),
                        icon: const Icon(Icons.lock_open_rounded),
                        label: Text(tr(widget.preferences, 'Unlock RAVEN',
                            'Déverrouiller RAVEN')),
                      )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showGuidedTour() async {
    if (_tourShowing || !mounted) return;
    _tourShowing = true;
    var page = 0;
    final steps = <({
      IconData icon,
      String titleEn,
      String titleFr,
      String bodyEn,
      String bodyFr,
      String hintEn,
      String hintFr
    })>[
      (
        icon: Icons.mic_rounded,
        titleEn: 'Record first',
        titleFr: 'Enregistrez d’abord',
        bodyEn:
            'Tap Record to start a private standalone take immediately. Create a project later from the recording menu whenever you need notes, files or more sessions.',
        bodyFr:
            'Touchez Enregistrer pour lancer immédiatement une prise autonome privée. Créez ensuite un projet depuis le menu de l’enregistrement si vous avez besoin de notes, de fichiers ou d’autres sessions.',
        hintEn: 'Try the large Record button on Home.',
        hintFr: 'Essayez le grand bouton Enregistrer sur Accueil.'
      ),
      (
        icon: Icons.library_music_rounded,
        titleEn: 'Everything stays together',
        titleFr: 'Tout reste ensemble',
        bodyEn:
            'Find recordings in Library. Rename, search, favourite, add notes and use Trash to recover a project you removed by mistake. Long-press any recording to select several at once.',
        bodyFr:
            'Retrouvez vos enregistrements dans Bibliothèque. Renommez, recherchez, ajoutez des favoris et utilisez la corbeille pour récupérer un projet. Maintenez un enregistrement appuyé pour en sélectionner plusieurs.',
        hintEn: 'Open Library to explore your projects.',
        hintFr: 'Ouvrez Bibliothèque pour explorer vos projets.'
      ),
      (
        icon: Icons.tune_rounded,
        titleEn: 'Settings in plain language',
        titleFr: 'Des réglages expliqués simplement',
        bodyEn:
            'Sample rate affects audio detail; bitrate affects compressed-file size and quality. Voice enhancement asks the device to reduce noise/echo when supported. Start with the defaults.',
        bodyFr:
            'La fréquence d’échantillonnage influence le détail audio ; le débit binaire influence la taille et la qualité des fichiers compressés. L’amélioration vocale demande une réduction du bruit/écho si disponible. Commencez par les réglages par défaut.',
        hintEn: 'Change language or recording quality in Settings.',
        hintFr: 'Changez la langue ou la qualité dans Paramètres.'
      ),
      (
        icon: Icons.shield_rounded,
        titleEn: 'Privacy and control',
        titleFr: 'Confidentialité et contrôle',
        bodyEn:
            'RAVEN stores projects in its private app directory by default. Set an app PIN in Settings and optionally require it for individual recordings. Exported copies are separate from the private original.',
        bodyFr:
            'RAVEN stocke les projets dans le répertoire privé de l’application par défaut. Définissez un code PIN dans Paramètres et exigez-le pour certains enregistrements. Les copies exportées sont séparées de l’original privé.',
        hintEn: 'You are in control; optional AI is not required.',
        hintFr:
            'Vous gardez le contrôle ; l’IA facultative n’est pas nécessaire.'
      ),
    ];
    while (mounted) {
      final current = steps[page];
      final isFrench = widget.preferences.isFrench;
      final result = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          icon: Icon(current.icon,
              size: 38, color: Theme.of(context).colorScheme.primary),
          title: Text(isFrench ? current.titleFr : current.titleEn),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isFrench ? current.bodyFr : current.bodyEn),
                const SizedBox(height: 14),
                Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12)),
                    child: Text(isFrench ? current.hintFr : current.hintEn)),
                const SizedBox(height: 12),
                Text('${page + 1} / ${steps.length}',
                    style: Theme.of(context).textTheme.labelMedium),
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'skip'),
                child: Text(isFrench ? 'Passer' : 'Skip tour')),
            FilledButton(
                onPressed: () => Navigator.pop(
                    dialogContext, page == steps.length - 1 ? 'done' : 'next'),
                child: Text(isFrench
                    ? (page == steps.length - 1 ? 'Terminer' : 'Suivant')
                    : (page == steps.length - 1 ? 'Finish' : 'Next'))),
          ],
        ),
      );
      if (result == 'next' && page < steps.length - 1) {
        page++;
        continue;
      }
      break;
    }
    widget.preferences.hasCompletedOnboarding = true;
    await widget.preferences.save();
    _tourShowing = false;
  }

  Future<void> _refreshProjects() async {
    if (mounted) setState(() {});
    widget.onProjectsChanged();
  }

  Future<bool> _ensureAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    const channel = MethodChannel('raven/storage_permission');
    try {
      final has = await channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
      if (has) return true;
      final granted =
          await channel.invokeMethod<bool>('requestAllFilesAccess') ?? false;
      return granted;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _applyVisibilitySilently(
    RavenProject project, {
    required bool visible,
  }) async {
    if (visible && (project.isAudioProtected || project.requiresAppPin)) {
      throw StateError(
          'Protected or PIN-locked recordings cannot be made public.');
    }

    if (project.publicCopyLocation != null) {
      try {
        await AudioVisibilityService().remove(project.publicCopyLocation!);
      } catch (_) {}
      project = project.copyWith(clearPublicCopyLocation: true);
      await widget.repository.update(project);
    }
    if (project.isStandalone) {
      final legacyFolder = project.publicFolderLocation;
      if (legacyFolder != null &&
          AudioVisibilityService.isContentUri(legacyFolder)) {
        try {
          await AudioVisibilityService().removeFolder(legacyFolder);
        } catch (_) {}
        project = project.copyWith(clearPublicFolderLocation: true);
        await widget.repository.update(project);
      }
    }

    if (visible == project.hasPublicFolder) {
      return;
    }
    if (visible) {
      final allowed = await _ensureAllFilesAccess();
      if (!allowed) {
        throw StateError(tr(
          widget.preferences,
          'RAVEN needs "All files access" to move project folders into your Music/RAVEN folder. Open Settings and allow it, then try again.',
          'RAVEN a besoin de « Accès à tous les fichiers » pour déplacer les dossiers de projet vers votre dossier Music/RAVEN. Ouvrez les paramètres, autorisez l\'accès, puis réessayez.',
        ));
      }
    }
    var updated = await widget.repository.toggleVisibility(
      project,
      makePublic: visible,
    );
    if (project.publicCopyLocation != null) {
      try {
        await AudioVisibilityService().remove(project.publicCopyLocation!);
        updated = updated.copyWith(clearPublicCopyLocation: true);
      } catch (_) {}
    }
    await widget.repository.update(updated);
  }

  Future<void> _applyPublicVisibilityToAll({required bool visible}) async {
    if (visible) {
      final allowed = await _ensureAllFilesAccess();
      if (!allowed) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(
              widget.preferences,
              'All files access is required to move recordings into Music/RAVEN. Please allow it in Settings.',
              'L’accès à tous les fichiers est requis pour déplacer les enregistrements vers Music/RAVEN. Veuillez l’autoriser dans les paramètres.',
            )),
          ));
        }
        return;
      }
    }

    final failures = <String>[];
    var updatedCount = 0;
    var skippedProtected = 0;

    for (final project in widget.repository.projects) {
      if (project.isTrashed) continue;
      if (project.isAudioProtected || project.requiresAppPin) {
        if (visible) skippedProtected++;
        continue;
      }
      if (project.hasPublicFolder == visible) continue;
      try {
        await _applyVisibilitySilently(project, visible: visible);
        updatedCount++;
      } catch (error) {
        failures.add('${project.title}: $error');
      }
    }

    await _refreshProjects();
    if (!mounted) return;

    if (failures.isNotEmpty) {
      final moreCount = failures.length - 1;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '${visible ? 'Could not make public' : 'Could not make private'}: ${failures.first}${moreCount > 0 ? ' (+$moreCount more)' : ''}',
        ),
      ));
    } else if (updatedCount > 0) {
      final message = visible
          ? tr(
              widget.preferences,
              'Made $updatedCount recording(s) public in Music/RAVEN.',
              '$updatedCount enregistrement(s) rendu(s) public(s) dans Music/RAVEN.')
          : tr(
              widget.preferences,
              'Moved $updatedCount recording(s) to private storage.',
              '$updatedCount enregistrement(s) déplacé(s) vers le stockage privé.');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(skippedProtected > 0
            ? '$message (${tr(widget.preferences, 'Skipped $skippedProtected protected recording(s)', '$skippedProtected enregistrement(s) protégé(s) ignoré(s)')})'
            : message),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          visible
              ? 'All eligible recordings are already public.'
              : 'All recordings are already private.',
          visible
              ? 'Tous les enregistrements éligibles sont déjà publics.'
              : 'Tous les enregistrements sont déjà privés.',
        )),
      ));
    }
  }

  Future<void> _startRecording() async {
    if (_recordingRouteActive || !mounted) return;
    _recordingRouteActive = true;
    final existingProjectIds =
        widget.repository.projects.map((project) => project.id).toSet();
    try {
      final navigator = Navigator.of(context);
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RecorderScreen(
            repository: widget.repository,
            preferences: widget.preferences,
            onSaved: _refreshProjects,
            createProject: false,
          ),
        ),
      );
    } finally {
      _recordingRouteActive = false;
    }

    await _refreshProjects();
    if (widget.preferences.defaultPublicAudioVisible) {
      final newProjects = widget.repository.projects
          .where((project) => !existingProjectIds.contains(project.id));
      final newProject = newProjects.isEmpty ? null : newProjects.first;
      if (newProject != null) {
        try {
          await _encoder.waitForProject(newProject.id);
        } catch (_) {}
        try {
          await _applyVisibilitySilently(newProject, visible: true);
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(tr(
                widget.preferences,
                'Recording saved privately — could not publish: $error',
                'Enregistrement sauvegardé en privé — publication impossible : $error',
              )),
            ));
          }
        }
      }
    }
  }

  Future<void> _createProjectFromRecording(
    RavenProject recording, {
    bool replaceCurrentRoute = false,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final wasPublic = recording.hasPublicFolder;

    var current = recording;
    if (wasPublic) {
      try {
        current = await widget.repository.toggleVisibility(
          current,
          makePublic: false,
        );
        await widget.repository.update(current);
      } catch (error) {
        messenger?.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Could not prepare the recording for project creation: $error',
            'Impossible de préparer l\'enregistrement pour créer le projet : $error',
          )),
        ));
        return;
      }
    }

    final projectPreview = current.copyWith(isStandalone: false);
    Directory projectFolder;
    try {
      projectFolder =
          await widget.repository.ensureProjectFolder(projectPreview);
      if (!await projectFolder.exists()) {
        throw StateError('The project folder was not created.');
      }
    } catch (error) {
      messenger?.showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          'Could not create the project folder: $error',
          'Impossible de créer le dossier du projet : $error',
        )),
      ));
      return;
    }

    final sessionsFolder = Directory('${projectFolder.path}/sessions');
    await sessionsFolder.create(recursive: true);
    final newSessions = <RavenAudioSession>[];
    for (final session in projectPreview.sessions) {
      final source = File(session.audioPath);
      if (!await source.exists()) {
        newSessions.add(session);
        continue;
      }
      if (source.parent.path == sessionsFolder.path) {
        newSessions.add(session);
        continue;
      }
      final fileName = source.uri.pathSegments.last;
      final destination = File('${sessionsFolder.path}/$fileName');
      try {
        await source.rename(destination.path);
        newSessions.add(session.copyWith(audioPath: destination.path));
      } on FileSystemException {
        try {
          await source.copy(destination.path);
          await source.delete();
          newSessions.add(session.copyWith(audioPath: destination.path));
        } on FileSystemException {
          newSessions.add(session);
        }
      }
    }

    var project = projectPreview.copyWith(
      sessions: newSessions,
      clearMasterAudioPath: true,
      updatedAt: DateTime.now(),
    );
    try {
      await widget.repository.update(project);
    } catch (error) {
      messenger?.showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          'Project folder was created but the index could not be updated: $error',
          'Le dossier a été créé mais l\'index n\'a pas pu être mis à jour : $error',
        )),
      ));
      return;
    }

    final shouldPublish = wasPublic ||
        (widget.preferences.defaultPublicAudioVisible &&
            !project.isAudioProtected &&
            !project.requiresAppPin);
    if (shouldPublish) {
      try {
        await _applyVisibilitySilently(project, visible: true);
        final refreshed = widget.repository.projectById(project.id);
        if (refreshed != null) project = refreshed;
      } catch (error) {
        messenger?.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Project created but could not be made public: $error',
            'Projet créé mais publication impossible : $error',
          )),
        ));
      }
    }

    await _refreshProjects();
    if (!mounted) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        project: project,
        repository: widget.repository,
        preferences: widget.preferences,
        onProjectChanged: (_) => _refreshProjects(),
      ),
    );
    final navigator = Navigator.of(context);
    if (replaceCurrentRoute) {
      await navigator.pushReplacement<void, void>(route);
    } else {
      await navigator.push<void>(route);
    }
    await _refreshProjects();
  }

  Future<void> _importProjectBundle() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['zip'],
        allowMultiple: true,
      );
      if (selection == null || selection.files.isEmpty || !mounted) return;

      final service = ProjectArchiveService(widget.repository);
      final importedTitles = <String>[];
      final failures = <String>[];

      for (final picked in selection.files) {
        var path = picked.path;
        if (path == null || path.trim().isEmpty) {
          failures.add(picked.name);
          continue;
        }
        File bundle = File(path);
        try {
          if (!await bundle.exists() || await bundle.length() == 0) {
            throw FileSystemException('Bundle is missing or empty.', path);
          }

          StagedProjectImport staged;
          try {
            staged = await service.stageImport(bundle);
          } on FormatException {
            final nested = await service.extractNestedBundle(bundle);
            if (nested == null) rethrow;
            bundle = nested;
            try {
              staged = await service.stageImport(bundle);
            } finally {
              try {
                await nested.delete();
              } catch (_) {}
            }
          }

          try {
            final imported = await service.installStagedImport(staged);
            importedTitles.add(imported.title);
            if (widget.preferences.defaultPublicAudioVisible &&
                !imported.isAudioProtected &&
                !imported.requiresAppPin) {
              try {
                await _applyVisibilitySilently(
                    _fresh(imported), visible: true);
              } catch (_) {}
            }
          } catch (_) {
            await staged.discard();
            rethrow;
          }
        } catch (error) {
          failures.add('${picked.name} ($error)');
        }
      }

      if (!mounted) return;
      await _refreshProjects();
      if (!mounted) return;
      if (importedTitles.isNotEmpty) {
        messenger?.showSnackBar(SnackBar(
          content: Text(importedTitles.length == 1
              ? tr(
                  widget.preferences,
                  'Imported "${importedTitles.single}" as a new project.',
                  '« ${importedTitles.single} » a été importé comme nouveau projet.',
                )
              : tr(
                  widget.preferences,
                  '${importedTitles.length} projects imported successfully.',
                  '${importedTitles.length} projets importés avec succès.',
                )),
        ));
      }
      if (failures.isNotEmpty) {
        messenger?.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Could not import: ${failures.join(', ')}',
            'Importation impossible : ${failures.join(', ')}',
          )),
        ));
      }
    } catch (error) {
      if (mounted) {
        messenger?.showSnackBar(SnackBar(
            content: Text('${tr(
          widget.preferences,
          'Project import failed',
          'Échec de l’importation du projet',
        )}: $error')));
      }
    }
  }

  static const Set<String> _supportedImportAudio = <String>{
    'm4a',
    'mp3',
    'wav',
    'flac',
    'ogg',
    'opus',
    'aac',
    'm4b',
    'wma',
    'amr',
  };

  Future<void> _importAudioRecording() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _supportedImportAudio.toList(),
        allowMultiple: true,
      );
      if (selection == null || selection.files.isEmpty || !mounted) return;

      final importedTitles = <String>[];
      final failures = <String>[];

      for (final picked in selection.files) {
        final sourcePath = picked.path;
        if (sourcePath == null || sourcePath.trim().isEmpty) {
          failures.add(picked.name);
          continue;
        }
        try {
          final title = await _importOneAudioFile(File(sourcePath));
          importedTitles.add(title);
        } catch (error) {
          failures.add('${picked.name} ($error)');
        }
      }

      if (!mounted) return;
      await _refreshProjects();
      if (!mounted) return;
      if (importedTitles.isNotEmpty) {
        messenger?.showSnackBar(SnackBar(
          content: Text(importedTitles.length == 1
              ? tr(
                  widget.preferences,
                  'Imported "${importedTitles.single}" as a recording.',
                  '« ${importedTitles.single} » a été importé comme enregistrement.',
                )
              : tr(
                  widget.preferences,
                  '${importedTitles.length} recordings imported successfully.',
                  '${importedTitles.length} enregistrements importés avec succès.',
                )),
        ));
      }
      if (failures.isNotEmpty) {
        messenger?.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Could not import: ${failures.join(', ')}',
            'Importation impossible : ${failures.join(', ')}',
          )),
        ));
      }
    } catch (error) {
      if (mounted) {
        messenger?.showSnackBar(SnackBar(
          content: Text('${tr(
            widget.preferences,
            'Audio import failed',
            'Échec de l’importation de l’audio',
          )}: $error'),
        ));
      }
    }
  }

  Future<String> _importOneAudioFile(File source) async {
    if (!await source.exists() || await source.length() == 0) {
      throw FileSystemException(
          'The selected audio file is missing or empty.', source.path);
    }
    final sourceName = source.path.split(RegExp(r'[\\/]')).last;
    final extension = sourceName.contains('.')
        ? sourceName.split('.').last.toLowerCase()
        : '';
    if (!_supportedImportAudio.contains(extension)) {
      throw UnsupportedError(
          extension.isEmpty
              ? 'RAVEN could not detect the audio format.'
              : 'RAVEN does not support .$extension imports.');
    }
    var title = sourceName.contains('.')
        ? sourceName.substring(0, sourceName.lastIndexOf('.')).trim()
        : sourceName.trim();
    title = title.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    if (title.isEmpty) title = 'Imported recording';
    if (title.length > 80) title = title.substring(0, 80).trim();

    final projectId = widget.repository.newId();
    final sessionId = widget.repository.newId();
    final createdAt = DateTime.now();

    var project = RavenProject(
      id: projectId,
      title: title,
      createdAt: createdAt,
      updatedAt: createdAt,
      sessions: const <RavenAudioSession>[],
      isStandalone: true,
    );

    Directory? folder;
    File? destinationFile;
    try {
      final resolvedFolder =
          await widget.repository.ensureProjectFolder(project);
      folder = resolvedFolder;
      await resolvedFolder.create(recursive: true);
      final safeFileTitle = title.replaceAll(RegExp(r'\s+'), '_');
      final destination = File(
          '${resolvedFolder.path}/$safeFileTitle-session-1-$sessionId.$extension');
      destinationFile = destination;
      await source.copy(destination.path);
      if (await destination.length() != await source.length()) {
        throw StateError('The imported audio copy failed verification.');
      }

      final durationMs = await _probeAudioDuration(destination, sessionId,
          title: title);

      project = project.copyWith(
        sessions: <RavenAudioSession>[
          RavenAudioSession(
            id: sessionId,
            audioPath: destination.path,
            createdAt: createdAt,
            durationMs: durationMs,
            format: extension,
            name: '$title · Session 1',
            sampleRate: widget.preferences.sampleRate,
            bitRate: widget.preferences.bitRate,
          ),
        ],
        isDraft: false,
      );
      await widget.repository.add(project);

      if (widget.preferences.defaultPublicAudioVisible) {
        try {
          await _applyVisibilitySilently(_fresh(project), visible: true);
        } catch (_) {}
      }
      return title;
    } catch (_) {
      if (destinationFile != null) {
        try {
          if (await destinationFile.exists()) {
            await destinationFile.delete();
          }
        } catch (_) {}
      }
      if (folder != null && !project.isStandalone) {
        try {
          if (await folder.exists()) await folder.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<int> _probeAudioDuration(File file, String sessionId,
      {required String title}) async {
    // First try just_audio (fastest, and gives the most accurate duration
    // for formats the platform natively decodes).
    final audioPlayer = AudioPlayer();
    try {
      await audioPlayer
          .setAudioSource(
            AudioSource.uri(
              Uri.file(file.path),
              tag: MediaItem(id: 'import-probe-$sessionId', title: title),
            ),
          )
          .timeout(const Duration(seconds: 15));
      final duration = audioPlayer.duration;
      if (duration != null && duration > Duration.zero) {
        return duration.inMilliseconds;
      }
    } catch (_) {
      // Fall through to FFprobe below.
    } finally {
      try {
        await audioPlayer.dispose();
      } catch (_) {}
    }
    // Fallback: FFprobe reads almost any audio format that FFmpeg can decode.
    return AudioMergeService().probeDurationMs(file);
  }

  RavenProject _fresh(RavenProject fallback) =>
      widget.repository.projectById(fallback.id) ?? fallback;

  Future<void> _openProject(RavenProject project) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    if (project.requiresAppPin) {
      final pinController = TextEditingController();
      final entered = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.lock_rounded, size: 32),
          title: Text(tr(
              widget.preferences, 'Private recording', 'Enregistrement privé')),
          content: TextField(
            controller: pinController,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 12,
            onSubmitted: (_) => Navigator.pop(dialogContext, true),
            decoration: InputDecoration(
                labelText:
                    tr(widget.preferences, 'RAVEN PIN', 'Code PIN RAVEN')),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(tr(
                    widget.preferences, 'Unlock recording', 'Déverrouiller'))),
          ],
        ),
      );
      final valid = entered == true &&
          await AppLockService().verifyPin(pinController.text);
      pinController.dispose();
      if (!valid) {
        if (entered == true && mounted) {
          messenger?.showSnackBar(SnackBar(
              content: Text(tr(
                  widget.preferences,
                  'Incorrect PIN. Recording was not opened.',
                  'Code PIN incorrect. L’enregistrement n’a pas été ouvert.'))));
        }
        return;
      }
    }
    if (!mounted) return;

    final isStandalone = project.isStandalone && !project.isDraft;

    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => isStandalone
            ? StandaloneRecordingScreen(
                project: project,
                preferences: widget.preferences,
                autoPlay: true,
                onResume: () => _resumeStandaloneFromPlayer(_fresh(project)),
                onCreateProject: () {
                  _createProjectFromRecording(_fresh(project),
                      replaceCurrentRoute: true);
                },
                onShare: () async {
                  await _shareRecording(_fresh(project));
                },
                onRename: (title) => _renameStandalone(_fresh(project), title),
                onTogglePin: () async {
                  await _toggleProjectPin(_fresh(project));
                },
                onToggleEncryption: () async {
                  await _toggleRecordingProtection(_fresh(project),
                      closeCurrentScreen: true);
                },
                onToggleVisibility: () async {
                  return _toggleRecordingVisibility(_fresh(project));
                },
                onSaveAmplified: (RavenProject updated) async {
                  try {
                    await widget.repository.update(updated);
                    await _refreshProjects();
                    return true;
                  } catch (_) {
                    return false;
                  }
                },
                onTrim: () => _trimStandalone(_fresh(project)),
                onOpenDetails: () {},
              )
            : PlayerScreen(
                project: project,
                repository: widget.repository,
                preferences: widget.preferences,
                onProjectChanged: (_) => _refreshProjects(),
              ),
      ),
    );
    await _refreshProjects();
  }

  Future<void> _shareRecording(RavenProject project) async {
    try {
      SecretKey? key;
      if (project.isAudioProtected && project.audioProtectionSalt != null) {
        final password = await showAudioPasswordDialog(
          context,
          preferences: widget.preferences,
          createPassword: false,
        );
        if (password == null || !mounted) return;
        key = await AudioEncryptionService().derivePasswordKey(
          password,
          project.audioProtectionSalt!,
        );
      }
      await AudioShareService().shareRecording(project, key: key);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not share recording', 'Impossible de partager l’enregistrement')}: $error'),
      ));
    }
  }

  Future<void> _shareProjects(List<RavenProject> projects) async {
    if (projects.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final files = <File>[];
    var skippedEncrypted = 0;
    for (final project in projects) {
      if (project.isAudioProtected) {
        skippedEncrypted++;
        continue;
      }
      for (final session in project.sessions) {
        final file = File(session.audioPath);
        if (await file.exists()) files.add(file);
      }
    }
    if (!mounted) return;
    if (files.isEmpty) {
      final message = skippedEncrypted > 0
          ? tr(
              widget.preferences,
              'Encrypted recordings cannot be batch-shared. Open one to share it individually.',
              'Les enregistrements chiffrés ne peuvent pas être partagés en lot. Ouvrez-en un pour le partager individuellement.')
          : tr(widget.preferences,
              'No audio files to share.', 'Aucun fichier audio à partager.');
      messenger?.showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    try {
      await AudioShareService().shareFiles(files);
      if (skippedEncrypted > 0 && mounted) {
        messenger?.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Shared ${files.length} file(s). $skippedEncrypted encrypted recording(s) skipped.',
            '${files.length} fichier(s) partagé(s). $skippedEncrypted enregistrement(s) chiffré(s) ignoré(s).',
          )),
        ));
      }
    } catch (error) {
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not share', 'Impossible de partager')}: $error'),
      ));
    }
  }

  Future<bool> _renameStandalone(RavenProject project, String title) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final trimmed = title.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed == project.title) return true;
    try {
      final renamed =
          await widget.repository.renameProject(project, trimmed);
      await widget.repository.update(renamed);
      await _refreshProjects();
      return true;
    } catch (error) {
      messenger?.showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          'Could not rename recording: $error',
          'Renommage de l’enregistrement impossible : $error',
        )),
      ));
      return false;
    }
  }

  Future<String?> _toggleRecordingVisibility(RavenProject project) async {
    final enabling = !project.isPublic;

    if (enabling == project.isPublic) {
      return project.publicCopyLocation ?? project.publicFolderLocation;
    }

    if (enabling && (project.isAudioProtected || project.requiresAppPin)) {
      throw StateError(
          'Decrypt the recording and remove its individual PIN lock before making it public.');
    }

    final isStandalone = project.isStandalone;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(
          widget.preferences,
          enabling
              ? (isStandalone
                  ? 'Make recording public?'
                  : 'Make project public?')
              : (isStandalone
                  ? 'Make recording private?'
                  : 'Make project private?'),
          enabling
              ? (isStandalone
                  ? 'Rendre l’enregistrement public ?'
                  : 'Rendre le projet public ?')
              : (isStandalone
                  ? 'Rendre l’enregistrement privé ?'
                  : 'Rendre le projet privé ?'),
        )),
        content: Text(tr(
          widget.preferences,
          enabling
              ? (isStandalone
                  ? 'RAVEN will move this recording’s folder into Music/RAVEN so you can play it in other apps. No duplicate copy is created — the recording simply lives in the public folder.'
                  : 'RAVEN will move this project’s folder into Music/RAVEN so you can browse it with a file manager. The project stays playable inside RAVEN. No duplicate copy is created.')
              : (isStandalone
                  ? 'RAVEN will move this recording’s folder back into private app storage. It stays playable inside RAVEN.'
                  : 'RAVEN will move this project’s folder back into private app storage. It stays playable inside RAVEN.'),
          enabling
              ? (isStandalone
                  ? 'RAVEN déplacera le dossier de cet enregistrement dans Music/RAVEN pour que vous puissiez le lire dans d’autres applications. Aucune copie n’est créée — l’enregistrement vit simplement dans le dossier public.'
                  : 'RAVEN déplacera le dossier de ce projet dans Music/RAVEN afin que vous puissiez le parcourir avec un gestionnaire de fichiers. Le projet reste lisible dans RAVEN. Aucune copie n’est créée.')
              : (isStandalone
                  ? 'RAVEN replacera le dossier de cet enregistrement dans le stockage privé de l’application. Il reste lisible dans RAVEN.'
                  : 'RAVEN replacera le dossier de ce projet dans le stockage privé de l’application. Il reste lisible dans RAVEN.'),
        )),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(widget.preferences, 'Continue', 'Continuer')),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return project.publicCopyLocation ?? project.publicFolderLocation;
    }
    await _applyVisibilitySilently(project, visible: enabling);
    await _refreshProjects();
    final refreshed = widget.repository.projectById(project.id);
    return refreshed?.publicCopyLocation ?? refreshed?.publicFolderLocation;
  }

  Future<void> _toggleRecordingProtection(
    RavenProject project, {
    bool closeCurrentScreen = false,
  }) async {
    final enabling = !project.isAudioProtected;
    String? password;
    SecretKey? key;
    if (enabling) {
      password = await showAudioPasswordDialog(
        context,
        preferences: widget.preferences,
        createPassword: true,
      );
      if (password == null || !mounted) return;
    } else if (project.audioProtectionSalt != null) {
      password = await showAudioPasswordDialog(
        context,
        preferences: widget.preferences,
        createPassword: false,
      );
      if (password == null || !mounted) return;
      key = await AudioEncryptionService().derivePasswordKey(
        password,
        project.audioProtectionSalt!,
      );
    }
    try {
      final service = AudioProtectionService(repository: widget.repository);
      if (enabling) {
        await service.encrypt(project, password!);
      } else {
        await service.decrypt(project, password: password, key: key);
      }
      if (!mounted) return;
      if (closeCurrentScreen) {
        await Navigator.of(context).maybePop();
      }
      await _refreshProjects();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not change audio encryption', 'Impossible de modifier le chiffrement audio')}: $error'),
      ));
    }
  }

  Future<void> _toggleProjectPin(RavenProject project) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final enabling = !project.requiresAppPin;
    if (enabling && (project.hasPublicFolder || project.hasPublicCopy)) {
      messenger?.showSnackBar(SnackBar(
          content: Text(tr(
        widget.preferences,
        'Make this recording private first. Public copies can be opened outside RAVEN.',
        'Rendez d’abord cet enregistrement privé. Les copies publiques peuvent être ouvertes hors de RAVEN.',
      ))));
      return;
    }
    if (enabling && !widget.preferences.appLockEnabled) {
      final pin = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          final controller = TextEditingController();
          return AlertDialog(
            icon: const Icon(Icons.lock_rounded, size: 32),
            title: Text(tr(widget.preferences, 'Set RAVEN PIN first',
                'Définir un code PIN RAVEN')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(tr(
                  widget.preferences,
                  'To protect individual recordings, create your 4–12 digit app PIN.',
                  'Pour protéger des enregistrements individuels, créez votre code PIN (4 à 12 chiffres).',
                )),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 12,
                  decoration: InputDecoration(
                    labelText:
                        tr(widget.preferences, 'New PIN', 'Nouveau code PIN'),
                    prefixIcon: const Icon(Icons.password_rounded),
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, controller.text.trim()),
                child: Text(tr(widget.preferences, 'Save PIN', 'Enregistrer')),
              ),
            ],
          );
        },
      );
      if (pin == null || pin.length < 4 || !mounted) {
        if (pin != null && pin.length < 4) {
          messenger?.showSnackBar(SnackBar(
            content: Text(tr(
                widget.preferences,
                'PIN must be at least 4 digits.',
                'Le code PIN doit comporter au moins 4 chiffres.')),
          ));
        }
        return;
      }
      await AppLockService().setPin(pin);
      widget.preferences.appLockEnabled = true;
      await widget.preferences.save();
    }
    try {
      final updated = project.copyWith(requiresAppPin: enabling);
      await widget.repository.update(updated);
      await _refreshProjects();
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(
        content: Text(tr(
            widget.preferences,
            enabling
                ? 'This recording now requires your RAVEN PIN.'
                : 'PIN requirement removed for this recording.',
            enabling
                ? 'Cet enregistrement nécessite maintenant votre code PIN RAVEN.'
                : 'Le code PIN n’est plus requis pour cet enregistrement.')),
      ));
    } catch (error) {
      if (!mounted) return;
      messenger?.showSnackBar(
          SnackBar(content: Text('Could not update recording lock: $error')));
    }
  }

  Future<void> _resumeStandalone(
    RavenProject project, {
    bool alreadyUnlocked = false,
  }) async {
    if (project.sessions.isEmpty) {
      await _addRecordingToProject(project);
      return;
    }
    if (project.sessions.length > 1 ||
        project.isDraft ||
        project.isAudioProtected) {
      await _openProject(project);
      return;
    }
    await _resumeSessionInProject(
      project,
      project.sessions.first.id,
      alreadyUnlocked: alreadyUnlocked,
    );
  }

  Future<void> _resumeSessionInProject(
    RavenProject project,
    String sessionId, {
    bool alreadyUnlocked = false,
  }) async {
    if (_recordingRouteActive || project.isAudioProtected) return;
    if (project.requiresAppPin && !alreadyUnlocked) {
      await _openProject(project);
      return;
    }
    _recordingRouteActive = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RecorderScreen(
            repository: widget.repository,
            preferences: widget.preferences,
            onSaved: _refreshProjects,
            existingProject: project,
            resumeSessionId: sessionId,
            createProject: false,
          ),
        ),
      );
    } finally {
      _recordingRouteActive = false;
      await _refreshProjects();
    }
  }

  Future<void> _addRecordingToProject(RavenProject project) async {
    if (_recordingRouteActive || project.isAudioProtected) return;
    _recordingRouteActive = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RecorderScreen(
            repository: widget.repository,
            preferences: widget.preferences,
            onSaved: _refreshProjects,
            existingProject: project,
            createProject: false,
          ),
        ),
      );
    } finally {
      _recordingRouteActive = false;
      await _refreshProjects();
    }
  }

  Future<void> _resumeStandaloneFromPlayer(RavenProject project) async {
    Navigator.of(context).pop();
    await _resumeStandalone(project, alreadyUnlocked: true);
  }

  Future<void> _trimStandalone(RavenProject project) async {
    if (project.sessions.isEmpty || project.isAudioProtected) return;
    final session = project.sessions.first;
    final source = File(session.audioPath);
    if (!await source.exists()) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(tr(widget.preferences, 'The recording file is missing.',
              'Le fichier audio est absent.')),
        ));
      }
      return;
    }

    // Imported files sometimes have durationMs == 0 because just_audio could
    // not decode them. Probe via FFmpeg now so the trim timeline is real.
    var effectiveDurationMs = session.durationMs;
    if (effectiveDurationMs <= 0) {
      final probed = await AudioMergeService().probeDurationMs(source);
      if (probed > 0) {
        effectiveDurationMs = probed;
        try {
          final updatedSessions = project.sessions
              .map((s) =>
                  s.id == session.id ? s.copyWith(durationMs: probed) : s)
              .toList();
          await widget.repository
              .update(project.copyWith(sessions: updatedSessions));
          await _refreshProjects();
        } catch (_) {
          // Best-effort — trim still works with the in-memory value.
        }
      }
    }
    if (effectiveDurationMs <= 0) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'RAVEN could not read this audio file. Try importing a WAV, MP3, M4A, or FLAC file.',
            'RAVEN n’a pas pu lire ce fichier audio. Essayez d’importer un fichier WAV, MP3, M4A ou FLAC.',
          )),
        ));
      }
      return;
    }

    // ignore: use_build_context_synchronously
    final result = await Navigator.of(context).push<TrimEditorResult>(
      MaterialPageRoute<TrimEditorResult>(
        fullscreenDialog: true,
        builder: (_) => TrimEditor(
          source: source,
          format: session.format,
          durationMs: effectiveDurationMs,
          bitRate: session.bitRate,
          sampleRate: session.sampleRate > 0 ? session.sampleRate : 44100,
          title: project.title,
          isFrench: widget.preferences.isFrench,
          isStandalone: true,
        ),
      ),
    );
    if (result == null || !mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final fresh = widget.repository.projectById(project.id);
      if (fresh == null || fresh.sessions.isEmpty) return;

      // The trim service preserves standard formats (wav/flac/mp3/m4a) but
      // falls back to AAC/m4a for exotic inputs (ogg, opus, wma, amr…). Use
      // the actual output extension so the record matches the disk.
      final actualFormat = result.file.path.split('.').last.toLowerCase();

      if (result.replacedOriginal) {
        final target = fresh.sessions.first;
        final trimmedSession = target.copyWith(
          audioPath: result.file.path,
          durationMs: result.durationMs,
          format: actualFormat,
          recoverablePcm16: false,
        );
        final sessions = List<RavenAudioSession>.of(fresh.sessions);
        sessions[0] = trimmedSession;

        final publicSingleFile = fresh.isStandalone &&
            fresh.hasPublicFolder &&
            fresh.sessions.isNotEmpty;
        final updated = fresh.copyWith(
          sessions: sessions,
          clearMasterAudioPath: true,
          publicFolderLocation:
              (publicSingleFile && result.replacedOriginal)
                  ? result.file.path
                  : fresh.publicFolderLocation,
        );
        await widget.repository.update(updated);

        try {
          final old = File(target.audioPath);
          if (await old.exists() && old.path != result.file.path) {
            await old.delete();
          }
        } catch (_) {}

        await _refreshProjects();
        messenger?.showSnackBar(SnackBar(
          content: Text(tr(widget.preferences,
              'Recording trimmed in place.', 'Enregistrement rogné.')),
        ));
      } else {
        // Create a brand-new standalone recording with the trimmed audio.
        // The original stays untouched as its own recording with one session.
        final target = fresh.sessions.first;
        final newSession = RavenAudioSession(
          id: widget.repository.newId(),
          audioPath: result.file.path,
          createdAt: DateTime.now(),
          durationMs: result.durationMs,
          format: actualFormat,
          name:
              '${target.name.isEmpty ? fresh.title : target.name} · ${tr(widget.preferences, 'trimmed', 'rogné')}',
          sampleRate: target.sampleRate,
          bitRate: target.bitRate,
        );
        final newProject = RavenProject(
          id: widget.repository.newId(),
          title:
              '${fresh.title} · ${tr(widget.preferences, 'trimmed', 'rogné')}',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          sessions: <RavenAudioSession>[newSession],
          isStandalone: true,
          category: fresh.category,
        );
        await widget.repository.add(newProject);

        await _refreshProjects();
        messenger?.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Trimmed copy saved as a new recording.',
            'Copie rognée enregistrée comme nouvel enregistrement.',
          )),
        ));
      }
    } catch (error) {
      messenger?.showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not save the trim', 'Impossible d’enregistrer le rognage')}: $error'),
      ));
    }
  }

  Future<void> _renameProject(RavenProject project) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final stored = widget.repository.projectById(project.id);
    if (stored == null) {
      await widget.repository
          .update(project.copyWith(updatedAt: DateTime.now()));
      await _refreshProjects();
      return;
    }
    final newTitle = project.title.trim();
    if (newTitle.isEmpty || newTitle == stored.title) {
      await widget.repository
          .update(project.copyWith(updatedAt: DateTime.now()));
      await _refreshProjects();
      return;
    }
    try {
      final renamed = await widget.repository.renameProject(stored, newTitle);
      await widget.repository.update(renamed);
    } catch (error) {
      try {
        await widget.repository
            .update(project.copyWith(updatedAt: DateTime.now()));
      } catch (_) {}
      messenger?.showSnackBar(SnackBar(
        content: Text(tr(
          widget.preferences,
          'Title updated, but the folder on disk could not be renamed: $error',
          'Titre mis à jour, mais le dossier sur le disque n’a pas pu être renommé : $error',
        )),
      ));
    }
    await _refreshProjects();
  }

  Future<void> _assignCategory(RavenProject project) async {
    await widget.repository.update(project);
    await _refreshProjects();
  }

  Future<void> _toggleFavorite(RavenProject project) async {
    await widget.repository
        .update(project.copyWith(isFavorite: !project.isFavorite));
    await _refreshProjects();
  }

  Future<void> _moveToTrash(RavenProject project) async {
    await widget.repository.moveToTrash(project);
    await _refreshProjects();
  }

  Future<void> _restore(RavenProject project) async {
    await widget.repository.restore(project);
    await _refreshProjects();
  }

  Future<void> _deleteForever(RavenProject project) async {
    await widget.repository.deleteForever(project);
    await _refreshProjects();
  }

  Future<void> _createCategory(String name) async {
    await widget.repository.createCategory(name);
    await _refreshProjects();
  }

  Future<void> _renameCategory(String currentName, String newName) async {
    await widget.repository.renameCategory(currentName, newName);
    await _refreshProjects();
  }

  Future<void> _deleteCategory(String name) async {
    await widget.repository.deleteCategory(name);
    await _refreshProjects();
  }

  @override
  Widget build(BuildContext context) {
    final preferences = widget.preferences;
    final projects = widget.repository.projects;
    final destinations = <NavigationDestination>[
      NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home_rounded),
          label: tr(preferences, 'Home', 'Accueil')),
      NavigationDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music_rounded),
          label: tr(preferences, 'Library', 'Bibliothèque')),
      NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings_rounded),
          label: tr(preferences, 'Settings', 'Paramètres')),
    ];

    final pages = <Widget>[
      HomeScreen(
        projects: projects,
        categories: widget.repository.categories,
        preferences: preferences,
        onRecord: _startRecording,
        onOpenProject: _openProject,
        onViewLibrary: () => setState(() => _selectedIndex = 1),
      ),
      LibraryScreen(
        projects: projects,
        categories: widget.repository.categories,
        preferences: preferences,
        onOpenProject: _openProject,
        onFavorite: _toggleFavorite,
        onRename: _renameProject,
        onTrash: _moveToTrash,
        onRestore: _restore,
        onDelete: _deleteForever,
        onImportProject: _importProjectBundle,
        onImportAudio: _importAudioRecording,
        onResumeProject: _resumeStandalone,
        onCreateCategory: _createCategory,
        onRenameCategory: _renameCategory,
        onDeleteCategory: _deleteCategory,
        onAssignCategory: _assignCategory,
        onCreateProject: (project) => _createProjectFromRecording(project),
        onShareProject: _shareRecording,
        onShareProjects: _shareProjects,
        onToggleVisibility: (project) async {
          await _toggleRecordingVisibility(project);
        },
        onToggleProtection: (project) async {
          await _toggleRecordingProtection(project);
        },
        onTogglePin: (project) async {
          await _toggleProjectPin(project);
        },
      ),
      SettingsScreen(
        preferences: preferences,
        onSettingsChanged: widget.onSettingsChanged,
        onShowTour: _showGuidedTour,
        onApplyPublicVisibility: _applyPublicVisibilityToAll,
        onRequestStoragePermission: _ensureAllFilesAccess,
        onTrashRetentionChanged: _purgeExpiredTrash,
      ),
    ];

    if (_locked && widget.preferences.appLockEnabled) return _buildLockGate();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 850;
        if (isWide) {
          return Scaffold(
            body: Row(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 20, 0, 20),
                  child: NavigationRail(
                    selectedIndex: _selectedIndex,
                    onDestinationSelected: (index) =>
                        setState(() => _selectedIndex = index),
                    labelType: NavigationRailLabelType.all,
                    leading: Padding(
                      padding: const EdgeInsets.only(bottom: 28, top: 8),
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(15),
                          gradient: LinearGradient(colors: <Color>[
                            Theme.of(context).colorScheme.primary,
                            Theme.of(context).colorScheme.tertiary
                          ]),
                        ),
                        child: Icon(Icons.graphic_eq_rounded,
                            color: Theme.of(context).colorScheme.onPrimary),
                      ),
                    ),
                    destinations: <NavigationRailDestination>[
                      NavigationRailDestination(
                          icon: const Icon(Icons.home_outlined),
                          selectedIcon: const Icon(Icons.home_rounded),
                          label: Text(tr(preferences, 'Home', 'Accueil'))),
                      NavigationRailDestination(
                          icon: const Icon(Icons.library_music_outlined),
                          selectedIcon: const Icon(Icons.library_music_rounded),
                          label:
                              Text(tr(preferences, 'Library', 'Bibliothèque'))),
                      NavigationRailDestination(
                          icon: const Icon(Icons.settings_outlined),
                          selectedIcon: const Icon(Icons.settings_rounded),
                          label:
                              Text(tr(preferences, 'Settings', 'Paramètres'))),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child:
                          IndexedStack(index: _selectedIndex, children: pages),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          body: IndexedStack(index: _selectedIndex, children: pages),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) =>
                setState(() => _selectedIndex = index),
            destinations: destinations,
          ),
        );
      },
    );
  }
}