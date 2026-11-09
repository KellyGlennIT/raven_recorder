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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise the background audio service before anything else that
  // touches just_audio. From this point on, playback continues when the app
  // is backgrounded and a media notification appears with play/pause/seek.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.raven.raven.audio',
    androidNotificationChannelName: 'RAVEN audio playback',
    androidNotificationChannelDescription:
        'Playback controls for your RAVEN recordings',
    androidNotificationIcon: 'mipmap/ic_launcher',
    // Hide fast-forward / rewind buttons — recordings aren't skippable
    // tracks. The seek bar is still available in the notification.
    fastForwardInterval: Duration.zero,
    rewindInterval: Duration.zero,
  );

  await initializeDateFormatting('fr');
  try {
    await AudioEncryptionService.cleanupAbandonedPlaybackFiles();
  } catch (_) {/* startup must remain available */}

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

  /// Lazily requests Android's "All files access" permission the first time
  /// the user makes a project public. On non-Android platforms and on
  /// Android 10 and below this is a no-op that returns true.
  ///
  /// The prompt is shown via Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
  /// not the standard runtime permission dialog — MANAGE_EXTERNAL_STORAGE is
  /// a special permission that can only be granted through system settings.
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

  Future<String?> _setProjectVisibility(
    RavenProject project, {
    required bool visible,
    bool refresh = true,
  }) async {
    if (visible && (project.isAudioProtected || project.requiresAppPin)) {
      throw StateError(
          'Protected or PIN-locked recordings cannot be made public.');
    }
    if (visible == project.hasPublicFolder &&
        project.publicCopyLocation == null) {
      if (refresh) await _refreshProjects();
      return project.publicFolderLocation;
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
    if (refresh) await _refreshProjects();
    return updated.publicFolderLocation;
  }

  Future<void> _applyPublicVisibilityToAll({required bool visible}) async {
    final failures = <String>[];
    for (final project in widget.repository.projects) {
      try {
        await _setProjectVisibility(project, visible: visible, refresh: false);
      } catch (error) {
        failures.add('${project.title}: $error');
      }
    }
    await _refreshProjects();
    if (failures.isNotEmpty && mounted) {
      final moreCount = failures.length - 1;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '${visible ? 'Could not make public' : 'Could not make private'}: ${failures.first}${moreCount > 0 ? ' (+$moreCount more)' : ''}',
        ),
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
          await _setProjectVisibility(newProject, visible: true);
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
    var project = recording.copyWith(isStandalone: false);
    await widget.repository.update(project);
    try {
      await widget.repository.ensureProjectFolder(project);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'The project was created, but its folder could not be prepared: $error',
            'Le projet a été créé, mais son dossier n’a pas pu être préparé : $error',
          )),
        ));
      }
    }

    if (widget.preferences.defaultPublicAudioVisible &&
        !project.hasPublicFolder &&
        !project.isAudioProtected &&
        !project.requiresAppPin) {
      try {
        project = await widget.repository.toggleVisibility(
          project,
          makePublic: true,
        );
        await widget.repository.update(project);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(
              widget.preferences,
              'Project kept private — could not publish: $error',
              'Projet conservé en privé — publication impossible : $error',
            )),
          ));
        }
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
        allowMultiple: false,
      );
      if (selection == null || selection.files.isEmpty || !mounted) return;
      final path = selection.files.single.path;
      if (path == null || path.trim().isEmpty) {
        throw const FileSystemException(
            'The selected bundle has no accessible file path.');
      }

      final service = ProjectArchiveService(widget.repository);
      final staged = await service.stageImport(File(path));
      try {
        final imported = await service.installStagedImport(staged);
        if (!mounted) return;
        await _refreshProjects();
        if (mounted) {
          messenger?.showSnackBar(SnackBar(
              content: Text(tr(
            widget.preferences,
            'Imported "${imported.title}" as a new private project.',
            '« ${imported.title} » a été importé comme nouveau projet privé.',
          ))));
        }
      } catch (_) {
        await staged.discard();
        rethrow;
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

  Future<void> _importAudioRecording() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    String? stagedFolderPath;
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['m4a', 'mp3', 'wav', 'flac'],
        allowMultiple: false,
      );
      if (selection == null || selection.files.isEmpty || !mounted) return;
      final sourcePath = selection.files.single.path;
      if (sourcePath == null || sourcePath.trim().isEmpty) {
        throw const FileSystemException(
            'The selected audio file has no accessible path.');
      }

      final source = File(sourcePath);
      if (!await source.exists() || await source.length() == 0) {
        throw FileSystemException(
            'The selected audio file is missing or empty.', sourcePath);
      }
      final sourceName = sourcePath.split(RegExp(r'[\\/]')).last;
      final extension = sourceName.split('.').last.toLowerCase();
      if (!const <String>{'m4a', 'mp3', 'wav', 'flac'}.contains(extension)) {
        throw UnsupportedError('RAVEN does not support .$extension imports.');
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

      if (widget.preferences.defaultPublicAudioVisible) {
        try {
          project = await widget.repository.toggleVisibility(
            project,
            makePublic: true,
          );
        } catch (_) {}
      }

      final folder = await widget.repository.ensureProjectFolder(project);
      stagedFolderPath = folder.path;

      final sessionDirectory = Directory('${folder.path}/sessions');
      await sessionDirectory.create(recursive: true);
      final safeFileTitle = title.replaceAll(RegExp(r'\s+'), '_');
      final destination = File(
          '${sessionDirectory.path}/$safeFileTitle-session-1-$sessionId.$extension');
      await source.copy(destination.path);
      if (await destination.length() != await source.length()) {
        throw StateError('The imported audio copy failed verification.');
      }

      final audioPlayer = AudioPlayer();
      late final int durationMs;
      try {
        await audioPlayer.setFilePath(destination.path);
        final duration = audioPlayer.duration;
        if (duration == null || duration <= Duration.zero) {
          throw StateError('RAVEN could not read the audio duration.');
        }
        durationMs = duration.inMilliseconds;
      } finally {
        await audioPlayer.dispose();
      }

      project = project.copyWith(
        sessions: <RavenAudioSession>[
          RavenAudioSession(
            id: sessionId,
            audioPath: destination.path,
            createdAt: createdAt,
            durationMs: durationMs,
            format: extension,
            name: '$title · Session 1',
          ),
        ],
      );
      await widget.repository.add(project);
      stagedFolderPath = null;
      await _refreshProjects();
      if (mounted) {
        messenger?.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Imported "$title" as a recording.',
            '« $title » a été importé comme enregistrement.',
          )),
        ));
      }
    } catch (error) {
      if (stagedFolderPath != null) {
        final directory = Directory(stagedFolderPath);
        try {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        } catch (_) {}
      }
      if (mounted) {
        messenger?.showSnackBar(SnackBar(
          content: Text('Audio import failed: $error'),
        ));
      }
    }
  }

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
    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => project.isStandalone &&
                !project.isDraft &&
                !project.isAudioProtected
            ? StandaloneRecordingScreen(
                project: project,
                preferences: widget.preferences,
                autoPlay: true,
                onResume: () => _resumeStandaloneFromPlayer(project),
                onOpenDetails: () => _openProjectDetails(project),
                onCreateProject: () => _createProjectFromRecording(
                  project,
                  replaceCurrentRoute: true,
                ),
                onShare: () => _shareRecording(project),
                onRename: (title) => _renameStandalone(project, title),
                onTogglePin: () => _toggleProjectPin(project),
                onToggleEncryption: () => _toggleRecordingProtection(
                  project,
                  closeCurrentScreen: true,
                ),
                onToggleVisibility: () => _toggleRecordingVisibility(project),
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

  /// Batch-share handler for the multi-select action in the Library screen.
  /// Collects every audio file from the selected projects and opens one
  /// system share sheet for the whole batch.
  ///
  /// Encrypted recordings are skipped because they need per-project password
  /// entry, which cannot be batched. A note is shown if any were skipped.
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
    try {
      await widget.repository
          .update(project.copyWith(title: title, updatedAt: DateTime.now()));
      await _refreshProjects();
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${tr(widget.preferences, 'Could not rename recording', 'Impossible de renommer l’enregistrement')}: $error'),
        ));
      }
      return false;
    }
  }

  Future<String?> _toggleRecordingVisibility(RavenProject project) async {
    final enabling = !project.isPublic;

    // No-op silently when the project is already in the target state.
    if (enabling == project.hasPublicFolder &&
        project.publicCopyLocation == null) {
      return project.publicFolderLocation;
    }

    if (enabling && (project.isAudioProtected || project.requiresAppPin)) {
      throw StateError(
          'Decrypt the recording and remove its individual PIN lock before making it public.');
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(
          widget.preferences,
          enabling ? 'Make recording public?' : 'Make recording private?',
          enabling ? 'Rendre l’enregistrement public ?' : 'Rendre privé ?',
        )),
        content: Text(tr(
          widget.preferences,
          enabling
              ? 'RAVEN will move this recording’s folder into the device’s public RAVEN folder so you can browse it with a file manager. The recording stays playable inside RAVEN.'
              : 'RAVEN will move this recording’s folder back into its app-private storage. It will no longer be visible in your file manager, but stays playable inside RAVEN.',
          enabling
              ? 'RAVEN déplacera le dossier de cet enregistrement dans le dossier RAVEN public de l’appareil afin que vous puissiez le parcourir avec un gestionnaire de fichiers. L’enregistrement reste lisible dans RAVEN.'
              : 'RAVEN replacera le dossier de cet enregistrement dans le stockage privé de l’application. Il ne sera plus visible dans votre gestionnaire de fichiers, mais reste lisible dans RAVEN.',
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
    if (confirmed != true) return project.publicFolderLocation;
    return _setProjectVisibility(project, visible: enabling);
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

  Future<void> _openProjectDetails(RavenProject project) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          project: project,
          repository: widget.repository,
          preferences: widget.preferences,
          onProjectChanged: (_) => _refreshProjects(),
        ),
      ),
    );
    await _refreshProjects();
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

  Future<void> _renameProject(RavenProject project) async {
    await widget.repository.update(project.copyWith(updatedAt: DateTime.now()));
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