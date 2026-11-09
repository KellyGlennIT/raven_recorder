import 'package:flutter/material.dart';

import '../services/app_preferences.dart';

Future<String?> showAudioPasswordDialog(
  BuildContext context, {
  required AppPreferences preferences,
  required bool createPassword,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _AudioPasswordDialog(
      preferences: preferences,
      createPassword: createPassword,
    ),
  );
}

class _AudioPasswordDialog extends StatefulWidget {
  const _AudioPasswordDialog({
    required this.preferences,
    required this.createPassword,
  });

  final AppPreferences preferences;
  final bool createPassword;

  @override
  State<_AudioPasswordDialog> createState() => _AudioPasswordDialogState();
}

class _AudioPasswordDialogState extends State<_AudioPasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmationController = TextEditingController();
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _passwordController.text;
    if (widget.createPassword && password.length < 8) {
      setState(() => _error = tr(
            widget.preferences,
            'Use at least 8 characters.',
            'Utilisez au moins 8 caractères.',
          ));
      return;
    }
    if (widget.createPassword && password != _confirmationController.text) {
      setState(() => _error = tr(
            widget.preferences,
            'The passwords do not match.',
            'Les mots de passe ne correspondent pas.',
          ));
      return;
    }
    if (!widget.createPassword && password.isEmpty) {
      setState(() => _error = tr(
            widget.preferences,
            'Enter your audio password.',
            'Saisissez le mot de passe audio.',
          ));
      return;
    }
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) {
    final preferences = widget.preferences;
    return AlertDialog(
      icon: Icon(widget.createPassword
          ? Icons.lock_outline_rounded
          : Icons.lock_open_rounded),
      title: Text(tr(
        preferences,
        widget.createPassword ? 'Create an audio password' : 'Unlock audio',
        widget.createPassword
            ? 'Créer un mot de passe audio'
            : 'Déverrouiller l’audio',
      )),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              tr(
                preferences,
                widget.createPassword
                    ? 'This password encrypts only this recording, not the whole app. RAVEN does not save it. If you forget it, the audio cannot be recovered.'
                    : 'Enter the password used to lock this audio. RAVEN does not save your password.',
                widget.createPassword
                    ? 'Ce mot de passe chiffre uniquement cet enregistrement, pas toute l’application. RAVEN ne le conserve pas. Si vous l’oubliez, l’audio ne pourra pas être récupéré.'
                    : 'Saisissez le mot de passe utilisé pour verrouiller cet audio. RAVEN ne le conserve pas.',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              autofocus: true,
              obscureText: _obscurePassword,
              textInputAction: widget.createPassword
                  ? TextInputAction.next
                  : TextInputAction.done,
              onSubmitted: (_) {
                if (widget.createPassword) {
                  FocusScope.of(context).nextFocus();
                } else {
                  _submit();
                }
              },
              decoration: InputDecoration(
                labelText: tr(
                  preferences,
                  'Audio password',
                  'Mot de passe audio',
                ),
                suffixIcon: IconButton(
                  tooltip: tr(
                    preferences,
                    _obscurePassword ? 'Show password' : 'Hide password',
                    _obscurePassword ? 'Afficher' : 'Masquer',
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(_obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                ),
              ),
            ),
            if (widget.createPassword) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                controller: _confirmationController,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: tr(
                    preferences,
                    'Confirm password',
                    'Confirmer le mot de passe',
                  ),
                ),
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(preferences, 'Cancel', 'Annuler')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(tr(
            preferences,
            widget.createPassword ? 'Lock audio' : 'Unlock',
            widget.createPassword ? 'Verrouiller l’audio' : 'Déverrouiller',
          )),
        ),
      ],
    );
  }
}
