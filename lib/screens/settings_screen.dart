import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_preferences.dart';
import '../services/ai_key_vault.dart';
import '../services/app_lock_service.dart';
import '../services/ai_provider_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.preferences,
    required this.onSettingsChanged,
    required this.onShowTour,
    required this.onApplyPublicVisibility,
    required this.onTrashRetentionChanged,
    super.key,
  });

  final AppPreferences preferences;
  final VoidCallback onSettingsChanged;
  final VoidCallback onShowTour;
  final Future<void> Function({required bool visible}) onApplyPublicVisibility;
  final VoidCallback onTrashRetentionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
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
                  isCompact ? 16 : 28,
                  horizontalPadding,
                  32,
                ),
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.tune_rounded,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              tr(preferences, 'Settings', 'Paramètres'),
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              tr(
                                preferences,
                                'Tune your recording workspace.',
                                'Personnalisez votre espace d’enregistrement.',
                              ),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  _SectionHeading(
                      title: tr(preferences, 'Appearance', 'Apparence')),
                  Card(
                    child: Column(
                      children: <Widget>[
                        SwitchListTile.adaptive(
                          secondary: const Icon(Icons.dark_mode_outlined),
                          title: Text(tr(preferences, 'Dark appearance',
                              'Apparence sombre')),
                          subtitle: Text(tr(
                              preferences,
                              'A low-glare workspace for recording and listening.',
                              'Une interface reposante pour enregistrer et écouter.')),
                          value: preferences.isDarkMode,
                          onChanged: (value) async {
                            preferences.isDarkMode = value;
                            await preferences.save();
                            onSettingsChanged();
                          },
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.language_rounded),
                          title: Text(tr(preferences, 'Interface language',
                              'Langue de l’interface')),
                          subtitle: Text(
                              preferences.isFrench ? 'Français' : 'English'),
                          trailing: DropdownButton<bool>(
                            value: preferences.isFrench,
                            underline: const SizedBox.shrink(),
                            items: const <DropdownMenuItem<bool>>[
                              DropdownMenuItem(
                                  value: false, child: Text('English')),
                              DropdownMenuItem(
                                  value: true, child: Text('Français')),
                            ],
                            onChanged: (value) async {
                              if (value == null) return;
                              preferences.isFrench = value;
                              await preferences.save();
                              onSettingsChanged();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _SectionHeading(
                      title: tr(preferences, 'Library & trash',
                          'Bibliothèque et corbeille')),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.delete_sweep_outlined),
                      title: Text(tr(preferences, 'Trash retention',
                          'Durée de conservation')),
                      subtitle: Text(tr(
                        preferences,
                        'Items are permanently deleted after this many days in Trash. Choose Never to keep them until you delete them yourself.',
                        'Les éléments sont définitivement supprimés après ce nombre de jours dans la corbeille. Choisissez Jamais pour les conserver jusqu’à leur suppression manuelle.',
                      )),
                      trailing: DropdownButton<int>(
                        value: preferences.trashRetentionDays,
                        underline: const SizedBox.shrink(),
                        items: AppPreferences.supportedTrashRetentionDays
                            .map((days) => DropdownMenuItem<int>(
                                  value: days,
                                  child: Text(days == 0
                                      ? tr(preferences, 'Never', 'Jamais')
                                      : tr(preferences, '$days days',
                                          '$days jours')),
                                ))
                            .toList(),
                        onChanged: (days) async {
                          if (days == null) return;
                          preferences.trashRetentionDays = days;
                          await preferences.save();
                          onSettingsChanged();
                          onTrashRetentionChanged();
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _SectionHeading(
                      title: tr(preferences, 'Recording quality',
                          'Qualité d’enregistrement')),
                  Card(
                    child: Column(
                      children: <Widget>[
                        ListTile(
                          leading: const Icon(Icons.graphic_eq_rounded),
                          title: Text(tr(preferences, 'Sample rate',
                              'Fréquence d’échantillonnage')),
                          subtitle: Text(
                              '${(preferences.sampleRate / 1000).toStringAsFixed(preferences.sampleRate == 22050 ? 2 : 1)} kHz · ${tr(preferences, 'More samples capture more high-frequency detail; 44.1/48 kHz are good general-purpose choices.', 'Plus d’échantillons capturent plus de détails aigus ; 44,1/48 kHz conviennent à la plupart des usages.')}'),
                          trailing: DropdownButton<int>(
                            value: preferences.sampleRate,
                            underline: const SizedBox.shrink(),
                            items: const <DropdownMenuItem<int>>[
                              DropdownMenuItem(
                                  value: 16000, child: Text('16 kHz')),
                              DropdownMenuItem(
                                  value: 22050, child: Text('22.05 kHz')),
                              DropdownMenuItem(
                                  value: 44100, child: Text('44.1 kHz')),
                              DropdownMenuItem(
                                  value: 48000, child: Text('48 kHz')),
                            ],
                            onChanged: (value) async {
                              if (value == null) return;
                              preferences.sampleRate = value;
                              await preferences.save();
                              onSettingsChanged();
                            },
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.tune_rounded),
                          title: Text(
                              tr(preferences, 'Bit rate', 'Débit binaire')),
                          subtitle: Text(
                              '${preferences.bitRate ~/ 1000} kbps · ${tr(preferences, 'Higher bitrate usually means larger files and better compressed-audio quality. WAV/FLAC are not controlled by this setting on every platform.', 'Un débit plus élevé produit généralement des fichiers plus volumineux et une meilleure qualité compressée. WAV/FLAC ne dépendent pas toujours de ce réglage.')}'),
                          trailing: DropdownButton<int>(
                            value: preferences.bitRate,
                            underline: const SizedBox.shrink(),
                            items: const <DropdownMenuItem<int>>[
                              DropdownMenuItem(
                                  value: 64000, child: Text('64 kbps')),
                              DropdownMenuItem(
                                  value: 96000, child: Text('96 kbps')),
                              DropdownMenuItem(
                                  value: 128000, child: Text('128 kbps')),
                              DropdownMenuItem(
                                  value: 192000, child: Text('192 kbps')),
                              DropdownMenuItem(
                                  value: 256000, child: Text('256 kbps')),
                            ],
                            onChanged: (value) async {
                              if (value == null) return;
                              preferences.bitRate = value;
                              await preferences.save();
                              onSettingsChanged();
                            },
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.audiotrack_rounded),
                          title: Text(tr(preferences, 'Recording format',
                              'Format d’enregistrement')),
                          subtitle: Text(tr(
                              preferences,
                              'Choose the format for new recordings',
                              'Choisissez le format des nouveaux enregistrements')),
                          trailing: DropdownButton<String>(
                            value: preferences.recordingFormat,
                            underline: const SizedBox.shrink(),
                            items: const <DropdownMenuItem<String>>[
                              DropdownMenuItem(
                                  value: 'm4a', child: Text('M4A / AAC')),
                              DropdownMenuItem(
                                  value: 'mp3', child: Text('MP3')),
                              DropdownMenuItem(
                                  value: 'wav', child: Text('WAV / PCM')),
                              DropdownMenuItem(
                                  value: 'flac', child: Text('FLAC')),
                            ],
                            onChanged: (value) async {
                              if (value == null) return;
                              preferences.recordingFormat = value;
                              await preferences.save();
                              onSettingsChanged();
                            },
                          ),
                        ),
                        const Divider(height: 1),
                        SwitchListTile.adaptive(
                          secondary: const Icon(Icons.graphic_eq_outlined),
                          title: Text(tr(preferences, 'Voice enhancement',
                              'Amélioration de la voix')),
                          subtitle: Text(tr(
                              preferences,
                              'Request automatic gain, echo cancellation and noise suppression when the device supports them.',
                              'Demander le gain automatique, la réduction de l’écho et du bruit si l’appareil les prend en charge.')),
                          value: preferences.voiceProcessing,
                          onChanged: (value) async {
                            preferences.voiceProcessing = value;
                            await preferences.save();
                            onSettingsChanged();
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _SectionHeading(
                      title: tr(preferences, 'AI tools (optional)',
                          'Outils IA (facultatifs)')),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: Text(tr(preferences, 'Your AI provider key',
                          'Votre clé de fournisseur IA')),
                      subtitle: Text(
                          '${preferences.aiProvider} · ${preferences.aiModel}\n${tr(preferences, 'Your key is stored securely. AI is optional and runs only when you request it.', 'Votre clé est stockée en sécurité. L’IA est facultative et ne fonctionne que sur demande.')}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _configureAiKey(
                          context, preferences, onSettingsChanged),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _SectionHeading(
                      title: tr(preferences, 'Privacy & storage',
                          'Confidentialité et stockage')),
                  Card(
                    child: Column(
                      children: <Widget>[
                        ListTile(
                          leading: const Icon(Icons.shield_outlined),
                          title: Text(tr(preferences, 'Private app storage',
                              'Stockage privé de l’application')),
                          subtitle: Text(tr(
                              preferences,
                              'Recordings are stored in the app’s private directory by default.',
                              'Les enregistrements sont stockés par défaut dans le dossier privé de l’application.')),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.lock_outline_rounded),
                          title: Text(tr(preferences, 'Audio encryption',
                              'Chiffrement audio')),
                          subtitle: Text(tr(
                              preferences,
                              'Use a recording’s three-dot menu → Lock audio with a password. The password is not stored; forgetting it means the audio cannot be recovered. This is separate from the RAVEN app PIN.',
                              'Utilisez le menu à trois points d’un enregistrement → Verrouiller l’audio avec un mot de passe. Le mot de passe n’est pas enregistré ; si vous l’oubliez, l’audio ne pourra pas être récupéré. Cette protection est indépendante du code PIN de RAVEN.')),
                        ),
                        const Divider(height: 1),
                        SwitchListTile.adaptive(
                          secondary: const Icon(Icons.public_rounded),
                          title: Text(tr(preferences, 'Public audio by default',
                              'Audio public par défaut')),
                          subtitle: Text(tr(
                              preferences,
                              'New recordings can be visible in music folders unless you switch them back to private.',
                              'Les nouveaux enregistrements peuvent apparaître dans les dossiers musicaux, sauf si vous les repassez en privé.')),
                          value: preferences.defaultPublicAudioVisible,
                          onChanged: (value) async {
                            preferences.defaultPublicAudioVisible = value;
                            await preferences.save();
                            onSettingsChanged();
                          },
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.sync_rounded),
                          title: Text(tr(
                              preferences,
                              'Apply visibility to all recordings',
                              'Appliquer la visibilité à tous les enregistrements')),
                          subtitle: Text(tr(
                              preferences,
                              'Make every recording private or visible in device folders at once.',
                              'Rendre tous les enregistrements privés ou visibles dans les dossiers de l’appareil d’un coup.')),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: Text(tr(
                                    preferences,
                                    'Update visibility for all recordings?',
                                    'Mettre à jour la visibilité pour tous les enregistrements ?')),
                                content: Text(tr(
                                    preferences,
                                    'This will make every recording private or public based on your default visibility setting.',
                                    'Cela rendra tous les enregistrements privés ou visibles selon le réglage par défaut.')),
                                actions: <Widget>[
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, false),
                                      child: Text(tr(
                                          preferences, 'Cancel', 'Annuler'))),
                                  FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, true),
                                      child: Text(tr(
                                          preferences, 'Apply', 'Appliquer'))),
                                ],
                              ),
                            );
                            if (confirmed == true) {
                              await onApplyPublicVisibility(
                                  visible:
                                      preferences.defaultPublicAudioVisible);
                              onSettingsChanged();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _SectionHeading(
                      title: tr(preferences, 'Privacy', 'Confidentialité')),
                  Card(
                    child: SwitchListTile.adaptive(
                      secondary: const Icon(Icons.lock_outline_rounded),
                      title: Text(tr(preferences, 'Lock RAVEN with a PIN',
                          'Verrouiller RAVEN avec un code PIN')),
                      subtitle: Text(tr(
                          preferences,
                          'Require a 4–12 digit PIN when RAVEN starts after being closed. The app stays unlocked when you switch away and return; this does not encrypt audio files.',
                          'Demander un code PIN de 4 à 12 chiffres au redémarrage de RAVEN après sa fermeture. L’application reste déverrouillée lorsque vous la mettez en arrière-plan ; cela ne chiffre pas les fichiers audio.')),
                      value: preferences.appLockEnabled,
                      onChanged: (enabled) async {
                        final changed = await _configureAppLock(
                            context, preferences,
                            enable: enabled);
                        if (changed) onSettingsChanged();
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  _SectionHeading(
                      title: tr(preferences, 'Help & learning',
                          'Aide et découverte')),
                  Card(
                      child: ListTile(
                          leading: const Icon(Icons.explore_outlined),
                          title: Text(tr(preferences, 'Replay the guided tour',
                              'Revoir la visite guidée')),
                          subtitle: Text(tr(
                              preferences,
                              'A short walkthrough of recording, the library, settings and privacy.',
                              'Une courte présentation de l’enregistrement, de la bibliothèque, des réglages et de la confidentialité.')),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: onShowTour)),
                  const SizedBox(height: 24),
                  _SectionHeading(
                      title:
                          tr(preferences, 'About RAVEN', 'À propos de RAVEN')),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.asset('assets/images/raven_logo.png',
                                width: 78, height: 78, fit: BoxFit.cover),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text('RAVEN',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 2.2)),
                                const SizedBox(height: 4),
                                Text(
                                    'Record · Archive · Visualise · Edit · Notes',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.primary)),
                                const SizedBox(height: 8),
                                Text(
                                    tr(
                                        preferences,
                                        'Flutter conversion baseline · 0.1.0',
                                        'Base de conversion Flutter · 0.1.0'),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                        preferences,
                        'RAVEN keeps recordings in its private app storage by default, so they do not normally appear in public music folders. The PIN protects access to the app interface; it is not file encryption. Exporting a recording creates a separate copy outside RAVEN.',
                        'Par défaut, RAVEN conserve les enregistrements dans le stockage privé de l’application : ils n’apparaissent normalement pas dans les dossiers musicaux publics. Le code PIN protège l’accès à l’interface, pas les fichiers par chiffrement. Exporter un enregistrement crée une copie distincte hors de RAVEN.'),
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant, height: 1.5),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 3, bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}

Future<bool> _configureAppLock(
  BuildContext context,
  AppPreferences preferences, {
  required bool enable,
}) async {
  final service = AppLockService();
  final currentController = TextEditingController();
  final pinController = TextEditingController();
  final confirmController = TextEditingController();
  final wasEnabled = preferences.appLockEnabled;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr(preferences, enable ? 'Set app PIN' : 'Turn off app lock',
          enable ? 'Définir le code PIN' : 'Désactiver le verrouillage')),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (wasEnabled) ...<Widget>[
              TextField(
                  controller: currentController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 12,
                  decoration: InputDecoration(
                      labelText:
                          tr(preferences, 'Current PIN', 'Code PIN actuel'))),
              const SizedBox(height: 8),
            ],
            if (enable) ...<Widget>[
              Text(tr(
                  preferences,
                  'Choose 4 to 12 digits. If you forget this PIN, you may need to clear app data to regain access; keep your recordings backed up.',
                  'Choisissez 4 à 12 chiffres. Si vous oubliez ce code, il peut être nécessaire d’effacer les données de l’application pour retrouver l’accès ; sauvegardez vos enregistrements.')),
              const SizedBox(height: 12),
              TextField(
                  controller: pinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 12,
                  decoration: InputDecoration(
                      labelText:
                          tr(preferences, 'New PIN', 'Nouveau code PIN'))),
              TextField(
                  controller: confirmController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 12,
                  decoration: InputDecoration(
                      labelText: tr(preferences, 'Confirm PIN',
                          'Confirmer le code PIN'))),
            ] else
              Text(tr(
                  preferences,
                  'Enter your current PIN to disable the app lock.',
                  'Saisissez votre code PIN actuel pour désactiver le verrouillage.')),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(preferences, 'Cancel', 'Annuler'))),
        FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(preferences, enable ? 'Save PIN' : 'Disable lock',
                enable ? 'Enregistrer' : 'Désactiver'))),
      ],
    ),
  );
  var changed = false;
  if (result == true) {
    try {
      if (wasEnabled && !await service.verifyPin(currentController.text)) {
        throw StateError(tr(preferences, 'The current PIN is incorrect.',
            'Le code PIN actuel est incorrect.'));
      }
      if (enable) {
        if (pinController.text != confirmController.text) {
          throw StateError(tr(preferences, 'The PIN entries do not match.',
              'Les codes PIN ne correspondent pas.'));
        }
        await service.setPin(pinController.text);
        preferences.appLockEnabled = true;
      } else {
        // Keep the verifier so individually PIN-locked projects remain accessible.
        preferences.appLockEnabled = false;
      }
      await preferences.save();
      changed = true;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(
                preferences,
                enable ? 'App lock enabled.' : 'App lock disabled.',
                enable ? 'Verrouillage activé.' : 'Verrouillage désactivé.'))));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
  currentController.dispose();
  pinController.dispose();
  confirmController.dispose();
  return changed;
}

Future<void> _configureAiKey(
  BuildContext context,
  AppPreferences preferences,
  VoidCallback onSettingsChanged,
) async {
  var provider = RavenAiProvider.values.firstWhere(
    (item) => item.id == preferences.aiProvider,
    orElse: () => RavenAiProvider.openRouter,
  );
  final keyController = TextEditingController();
  final modelController = TextEditingController(
      text: preferences.aiModel.isNotEmpty
          ? preferences.aiModel
          : provider.defaultModel);
  final vault = AiKeyVault();
  final ai = RavenAiProviderService(vault: vault);
  var busy = false;
  String? status;
  bool statusIsError = false;
  var keyExists = false;
  try {
    keyExists = await vault.hasKey(provider.id);
  } catch (_) {
    status = tr(
        preferences,
        'RAVEN could not access secure storage. Check your device configuration and try again.',
        'RAVEN n’a pas pu accéder au stockage sécurisé. Vérifiez la configuration de l’appareil et réessayez.');
    statusIsError = true;
  }

  if (!context.mounted) {
    keyController.dispose();
    modelController.dispose();
    ai.close();
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        final help = provider.keyInstructions;
        final url = switch (provider) {
          RavenAiProvider.openRouter => 'https://openrouter.ai/keys',
          RavenAiProvider.openAi => 'https://platform.openai.com/api-keys',
          RavenAiProvider.gemini => 'https://aistudio.google.com/app/apikey',
        };
        return AlertDialog(
          title: Text(tr(preferences, 'Configure your AI assistant',
              'Configurer votre assistant IA')),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(tr(
                      preferences,
                      'AI is optional and uses your own provider account. RAVEN does not pay for API usage. A ChatGPT subscription is separate from OpenAI API billing. Check each provider’s pricing and limits before sending requests.',
                      'L’IA est facultative et utilise votre propre compte fournisseur. RAVEN ne paie pas les appels API. Un abonnement ChatGPT est distinct de la facturation API OpenAI. Vérifiez les tarifs et limites avant d’envoyer des requêtes.')),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<RavenAiProvider>(
                    initialValue: provider,
                    decoration: InputDecoration(
                        labelText:
                            tr(preferences, 'AI provider', 'Fournisseur IA')),
                    items: RavenAiProvider.values
                        .map((item) => DropdownMenuItem(
                            value: item, child: Text(item.label)))
                        .toList(),
                    onChanged: busy
                        ? null
                        : (value) async {
                            if (value == null) return;
                            setDialogState(() {
                              busy = true;
                              provider = value;
                              modelController.text = value.defaultModel;
                              keyController.clear();
                              status = null;
                              statusIsError = false;
                            });
                            try {
                              keyExists = await vault.hasKey(value.id);
                            } catch (_) {
                              keyExists = false;
                              status = tr(
                                  preferences,
                                  'RAVEN could not access secure storage. Check your device configuration and try again.',
                                  'RAVEN n’a pas pu accéder au stockage sécurisé. Vérifiez la configuration de l’appareil et réessayez.');
                              statusIsError = true;
                            } finally {
                              if (dialogContext.mounted) {
                                setDialogState(() => busy = false);
                              }
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  Text(help,
                      style: Theme.of(dialogContext).textTheme.bodySmall),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.content_copy_rounded, size: 17),
                      label: Text(tr(preferences, 'Copy official API-key page',
                          'Copier la page officielle de clé API')),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: url));
                        if (dialogContext.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(tr(
                                  preferences,
                                  'Official page address copied.',
                                  'Adresse de la page officielle copiée.'))));
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: modelController,
                    enabled: !busy,
                    decoration: InputDecoration(
                      labelText: tr(preferences, 'Model identifier',
                          'Identifiant du modèle'),
                      helperText: tr(
                          preferences,
                          'Use the exact model ID shown by your provider. Model availability and prices can change.',
                          'Utilisez l’identifiant exact du modèle indiqué par le fournisseur. Disponibilité et tarifs peuvent changer.'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: keyController,
                    enabled: !busy,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: keyExists
                          ? tr(
                              preferences,
                              'API key (leave blank to keep saved key)',
                              'Clé API (laisser vide pour conserver la clé)')
                          : tr(preferences, 'Paste your API key',
                              'Collez votre clé API'),
                      helperText: keyExists
                          ? tr(
                              preferences,
                              'A key is saved securely for this provider.',
                              'Une clé est enregistrée en sécurité pour ce fournisseur.')
                          : tr(
                              preferences,
                              'The key is stored in OS secure storage, never in project notes.',
                              'La clé est stockée dans le coffre sécurisé du système, jamais dans les notes du projet.'),
                    ),
                  ),
                  if (status != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(status!,
                        style: TextStyle(
                            color: statusIsError
                                ? Theme.of(dialogContext).colorScheme.error
                                : Theme.of(dialogContext).colorScheme.primary)),
                  ],
                  if (busy)
                    const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator()),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialogContext),
              child: Text(tr(preferences, 'Close', 'Fermer')),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDialogState(() {
                        busy = true;
                        status = null;
                      });
                      try {
                        if (modelController.text.trim().isEmpty) {
                          throw StateError(tr(
                              preferences,
                              'Enter a model identifier.',
                              'Saisissez l’identifiant du modèle.'));
                        }
                        if (keyController.text.trim().isNotEmpty) {
                          await vault.saveKey(provider.id, keyController.text);
                          keyExists = true;
                        }
                        await ai.testConnection(
                            provider: provider, model: modelController.text);
                        preferences.aiProvider = provider.id;
                        preferences.aiModel = modelController.text.trim();
                        await preferences.save();
                        onSettingsChanged();
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            status = tr(
                                preferences,
                                'Connection successful. Your provider and model are ready.',
                                'Connexion réussie. Le fournisseur et le modèle sont prêts.');
                            statusIsError = false;
                          });
                        }
                      } catch (error) {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            status = error.toString();
                            statusIsError = true;
                          });
                        }
                      } finally {
                        if (dialogContext.mounted) {
                          setDialogState(() => busy = false);
                        }
                      }
                    },
              child: Text(
                  tr(preferences, 'Test connection', 'Tester la connexion')),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      try {
                        if (modelController.text.trim().isEmpty) {
                          throw StateError(tr(
                              preferences,
                              'Enter a model identifier.',
                              'Saisissez l’identifiant du modèle.'));
                        }
                        if (keyController.text.trim().isNotEmpty) {
                          await vault.saveKey(provider.id, keyController.text);
                          keyExists = true;
                        }
                        if (!keyExists) {
                          throw StateError(tr(
                              preferences,
                              'Paste and save an API key first.',
                              'Collez et enregistrez d’abord une clé API.'));
                        }
                        preferences.aiProvider = provider.id;
                        preferences.aiModel = modelController.text.trim();
                        await preferences.save();
                        onSettingsChanged();
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(tr(
                                  preferences,
                                  'AI settings saved. Test the connection before use.',
                                  'Paramètres IA enregistrés. Testez la connexion avant utilisation.'))));
                        }
                      } catch (error) {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            status = error.toString();
                            statusIsError = true;
                          });
                        }
                      }
                    },
              child: Text(tr(preferences, 'Save settings', 'Enregistrer')),
            ),
            if (keyExists)
              IconButton(
                tooltip: tr(preferences, 'Delete saved key',
                    'Supprimer la clé enregistrée'),
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          await vault.deleteKey(provider.id);
                          keyExists = false;
                          keyController.clear();
                          if (dialogContext.mounted) {
                            setDialogState(() {
                              status = tr(
                                  preferences,
                                  'Saved key deleted from secure storage.',
                                  'Clé supprimée du stockage sécurisé.');
                              statusIsError = false;
                            });
                          }
                        } catch (error) {
                          if (dialogContext.mounted) {
                            setDialogState(() {
                              status = error.toString();
                              statusIsError = true;
                            });
                          }
                        }
                      },
                icon: const Icon(Icons.delete_outline_rounded),
              ),
          ],
        );
      },
    ),
  );
  keyController.dispose();
  modelController.dispose();
  ai.close();
}
