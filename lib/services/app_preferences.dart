import 'package:shared_preferences/shared_preferences.dart';

class AppPreferences {
  AppPreferences({
    this.isDarkMode = true,
    this.isFrench = false,
    this.sampleRate = 44100,
    this.bitRate = 128000,
    this.recordingFormat = 'm4a',
    this.voiceProcessing = true,
    this.hasCompletedOnboarding = false,
    this.appLockEnabled = false,
    this.defaultPublicAudioVisible = false,
    this.newRecordingsCreateProject = true,
    this.aiProvider = 'openrouter',
    this.aiModel = 'openrouter/free',
  });

  bool isDarkMode;
  bool isFrench;
  int sampleRate;
  int bitRate;
  String recordingFormat;
  bool voiceProcessing;
  bool hasCompletedOnboarding;
  bool appLockEnabled;
  bool defaultPublicAudioVisible;
  bool newRecordingsCreateProject;
  String aiProvider;
  String aiModel;

  static const List<int> supportedSampleRates = <int>[
    16000,
    22050,
    44100,
    48000
  ];
  static const List<int> supportedBitRates = <int>[
    64000,
    96000,
    128000,
    192000,
    256000
  ];
  static const List<String> supportedRecordingFormats = <String>[
    'm4a',
    'mp3',
    'wav',
    'flac'
  ];

  static Future<AppPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedSampleRate = prefs.getInt('raven.sampleRate');
    final savedBitRate = prefs.getInt('raven.bitRate');
    final savedFormat = prefs.getString('raven.recordingFormat');
    return AppPreferences(
      isDarkMode: prefs.getBool('raven.darkMode') ?? true,
      isFrench: prefs.getBool('raven.french') ?? false,
      sampleRate: supportedSampleRates.contains(savedSampleRate)
          ? savedSampleRate!
          : 44100,
      bitRate:
          supportedBitRates.contains(savedBitRate) ? savedBitRate! : 128000,
      recordingFormat: supportedRecordingFormats.contains(savedFormat)
          ? savedFormat!
          : 'm4a',
      voiceProcessing: prefs.getBool('raven.voiceProcessing') ?? true,
      hasCompletedOnboarding:
          prefs.getBool('raven.onboardingCompleted') ?? false,
      appLockEnabled: prefs.getBool('raven.appLockEnabled') ?? false,
      defaultPublicAudioVisible:
          prefs.getBool('raven.defaultPublicAudioVisible') ?? false,
      newRecordingsCreateProject:
          prefs.getBool('raven.newRecordingsCreateProject') ?? true,
      aiProvider: prefs.getString('raven.aiProvider') ?? 'openrouter',
      aiModel: prefs.getString('raven.aiModel') ?? 'openrouter/free',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('raven.darkMode', isDarkMode);
    await prefs.setBool('raven.french', isFrench);
    await prefs.setInt('raven.sampleRate', sampleRate);
    await prefs.setInt('raven.bitRate', bitRate);
    await prefs.setString('raven.recordingFormat', recordingFormat);
    await prefs.setBool('raven.voiceProcessing', voiceProcessing);
    await prefs.setBool('raven.onboardingCompleted', hasCompletedOnboarding);
    await prefs.setBool('raven.appLockEnabled', appLockEnabled);
    await prefs.setBool(
        'raven.defaultPublicAudioVisible', defaultPublicAudioVisible);
    await prefs.setBool(
        'raven.newRecordingsCreateProject', newRecordingsCreateProject);
    await prefs.setString('raven.aiProvider', aiProvider);
    await prefs.setString('raven.aiModel', aiModel);
  }
}

String tr(AppPreferences prefs, String english, String french) =>
    prefs.isFrench ? french : english;
