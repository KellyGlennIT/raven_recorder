import 'package:flutter/material.dart';

import '../services/background_encode_service.dart';

/// Small progress chip that appears next to a recording in the library while
/// the background encoder is converting its WAV capture to MP3 / FLAC.
///
/// Disappears instantly when the encode finishes or fails. The recording is
/// fully playable during encoding, so the chip is informational — it never
/// blocks interaction.
class EncodingStatusChip extends StatelessWidget {
  const EncodingStatusChip({
    required this.projectId,
    this.isFrench = false,
    super.key,
  });

  final String projectId;
  final bool isFrench;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: BackgroundEncodeService.instance.progressByJob,
      builder: (context, progressMap, _) {
        double? progress;
        for (final entry in progressMap.entries) {
          if (entry.key.startsWith('$projectId/')) {
            progress = entry.value;
            break;
          }
        }
        if (progress == null) return const SizedBox.shrink();
        final pct = (progress * 100).round();
        final label = isFrench ? 'Encodage' : 'Encoding';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  value: progress,
                  color: scheme.onPrimaryContainer,
                  backgroundColor:
                      scheme.onPrimaryContainer.withValues(alpha: 0.2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$label · $pct%',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Full-width banner shown at the top of a recording while its background
/// encode is running. Includes a linear progress bar and a hint that the
/// recording is already playable as its original WAV capture.
class EncodingStatusBanner extends StatelessWidget {
  const EncodingStatusBanner({
    required this.projectId,
    this.isFrench = false,
    super.key,
  });

  final String projectId;
  final bool isFrench;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: BackgroundEncodeService.instance.progressByJob,
      builder: (context, progressMap, _) {
        double? progress;
        for (final entry in progressMap.entries) {
          if (entry.key.startsWith('$projectId/')) {
            progress = entry.value;
            break;
          }
        }
        if (progress == null) return const SizedBox.shrink();
        final pct = (progress * 100).round();
        final headline = isFrench
            ? 'Encodage en arrière-plan · $pct%'
            : 'Encoding in background · $pct%';
        final hint = isFrench
            ? 'Cet enregistrement est déjà lisible en WAV pendant l’encodage.'
            : 'This recording is already playable as WAV while it encodes.';
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.graphic_eq_rounded,
                      size: 16, color: scheme.onPrimaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      headline,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor:
                      scheme.onPrimaryContainer.withValues(alpha: 0.15),
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                hint,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}