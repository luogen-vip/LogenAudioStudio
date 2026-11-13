import 'dart:convert';

/// 单段区间编辑：这一段单独用一套参数，段外还是全轨的那套
class RegionEdit {
  double start;
  double end;
  double gainDb;
  double lowCut;
  double bassDb;
  double trebleDb;
  double reverb;
  bool compress;

  RegionEdit({
    required this.start,
    required this.end,
    this.gainDb = 0,
    this.lowCut = 0,
    this.bassDb = 0,
    this.trebleDb = 0,
    this.reverb = 0,
    this.compress = false,
  });

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'gainDb': gainDb,
        'lowCut': lowCut,
        'bassDb': bassDb,
        'trebleDb': trebleDb,
        'reverb': reverb,
        'compress': compress,
      };

  factory RegionEdit.fromJson(Map<String, dynamic> j) => RegionEdit(
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        gainDb: (j['gainDb'] as num?)?.toDouble() ?? 0,
        lowCut: (j['lowCut'] as num?)?.toDouble() ?? 0,
        bassDb: (j['bassDb'] as num?)?.toDouble() ?? 0,
        trebleDb: (j['trebleDb'] as num?)?.toDouble() ?? 0,
        reverb: (j['reverb'] as num?)?.toDouble() ?? 0,
        compress: j['compress'] == true,
      );

  bool get isEmpty =>
      gainDb == 0 && lowCut == 0 && bassDb == 0 && trebleDb == 0 && reverb == 0 && !compress;

  RegionEdit copyWith({double? start, double? end}) => RegionEdit(
        start: start ?? this.start,
        end: end ?? this.end,
        gainDb: gainDb,
        lowCut: lowCut,
        bassDb: bassDb,
        trebleDb: trebleDb,
        reverb: reverb,
        compress: compress,
      );
}

/// 一整轨的处理参数（全局生效）
class TrackSettings {
  double gainDb; // -24 .. +24
  double lowCut; // Hz，0 表示不切
  double bassDb; // 低频 +-12dB
  double trebleDb; // 高频 +-12dB
  double reverb; // 0..100
  int pitch; // -12..+12 半音
  double speed; // 0.5 .. 2.0
  bool compress;
  List<RegionEdit> regions;

  TrackSettings({
    this.gainDb = 0,
    this.lowCut = 0,
    this.bassDb = 0,
    this.trebleDb = 0,
    this.reverb = 0,
    this.pitch = 0,
    this.speed = 1,
    this.compress = false,
    List<RegionEdit>? regions,
  }) : regions = regions ?? [];

  bool get hasGlobalFx =>
      gainDb != 0 ||
      lowCut > 0 ||
      bassDb != 0 ||
      trebleDb != 0 ||
      reverb > 0 ||
      pitch != 0 ||
      speed != 1 ||
      compress;

  bool get isPristine => !hasGlobalFx && regions.every((r) => r.isEmpty);

  String get signature => jsonEncode(toJson());

  Map<String, dynamic> toJson() => {
        'gainDb': gainDb,
        'lowCut': lowCut,
        'bassDb': bassDb,
        'trebleDb': trebleDb,
        'reverb': reverb,
        'pitch': pitch,
        'speed': speed,
        'compress': compress,
        'regions': regions.map((e) => e.toJson()).toList(),
      };

  factory TrackSettings.fromJson(Map<String, dynamic> j) => TrackSettings(
        gainDb: (j['gainDb'] as num?)?.toDouble() ?? 0,
        lowCut: (j['lowCut'] as num?)?.toDouble() ?? 0,
        bassDb: (j['bassDb'] as num?)?.toDouble() ?? 0,
        trebleDb: (j['trebleDb'] as num?)?.toDouble() ?? 0,
        reverb: (j['reverb'] as num?)?.toDouble() ?? 0,
        pitch: (j['pitch'] as num?)?.toInt() ?? 0,
        speed: (j['speed'] as num?)?.toDouble() ?? 1,
        compress: j['compress'] == true,
        regions: (j['regions'] as List?)?.map((e) => RegionEdit.fromJson(e as Map<String, dynamic>)).toList() ?? [],
      );

  void reset() {
    gainDb = 0;
    lowCut = 0;
    bassDb = 0;
    trebleDb = 0;
    reverb = 0;
    pitch = 0;
    speed = 1;
    compress = false;
    regions.clear();
  }
}

class Track {
  String id;
  String name;
  String path;
  double duration;
  int sampleRate;
  int channels;
  double volume; // 混音时的轨道音量 0..2
  double offsetMs; // 合成时的起点偏移（毫秒，可负）
  bool muted;
  TrackSettings settings;
  List<double> peaks; // 归一化 0..1
  String role; // song / vocal / inst

  Track({
    required this.id,
    required this.name,
    required this.path,
    required this.duration,
    this.sampleRate = 44100,
    this.channels = 2,
    this.volume = 1.0,
    this.offsetMs = 0,
    this.muted = false,
    TrackSettings? settings,
    List<double>? peaks,
    this.role = 'song',
  })  : settings = settings ?? TrackSettings(),
        peaks = peaks ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'duration': duration,
        'sampleRate': sampleRate,
        'channels': channels,
        'volume': volume,
        'offsetMs': offsetMs,
        'muted': muted,
        'settings': settings.toJson(),
        'peaks': peaks,
        'role': role,
      };

  factory Track.fromJson(Map<String, dynamic> j) => Track(
        id: j['id'] as String,
        name: j['name'] as String,
        path: j['path'] as String,
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
        sampleRate: (j['sampleRate'] as num?)?.toInt() ?? 44100,
        channels: (j['channels'] as num?)?.toInt() ?? 2,
        volume: (j['volume'] as num?)?.toDouble() ?? 1.0,
        offsetMs: (j['offsetMs'] as num?)?.toDouble() ?? 0,
        muted: j['muted'] == true,
        settings: j['settings'] == null
            ? TrackSettings()
            : TrackSettings.fromJson(j['settings'] as Map<String, dynamic>),
        peaks: (j['peaks'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? [],
        role: j['role'] as String? ?? 'song',
      );
}

class AudioTask {
  String id;
  String title;
  DateTime createdAt;
  String status; // draft / ready
  List<Track> tracks;
  double trimStart;
  double trimEnd;
  String? lastExportPath;
  String? lastExportLabel;

  AudioTask({
    required this.id,
    required this.title,
    required this.createdAt,
    this.status = 'ready',
    List<Track>? tracks,
    this.trimStart = 0,
    this.trimEnd = 0,
    this.lastExportPath,
    this.lastExportLabel,
  }) : tracks = tracks ?? [];

  double get duration {
    if (tracks.isEmpty) return 0;
    return tracks.map((t) => t.duration).reduce((a, b) => a > b ? a : b);
  }

  double get effectiveEnd => (trimEnd <= 0 || trimEnd > duration) ? duration : trimEnd;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'status': status,
        'tracks': tracks.map((e) => e.toJson()).toList(),
        'trimStart': trimStart,
        'trimEnd': trimEnd,
        'lastExportPath': lastExportPath,
        'lastExportLabel': lastExportLabel,
      };

  factory AudioTask.fromJson(Map<String, dynamic> j) => AudioTask(
        id: j['id'] as String,
        title: j['title'] as String,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        status: j['status'] as String? ?? 'ready',
        tracks: (j['tracks'] as List?)?.map((e) => Track.fromJson(e as Map<String, dynamic>)).toList() ?? [],
        trimStart: (j['trimStart'] as num?)?.toDouble() ?? 0,
        trimEnd: (j['trimEnd'] as num?)?.toDouble() ?? 0,
        lastExportPath: j['lastExportPath'] as String?,
        lastExportLabel: j['lastExportLabel'] as String?,
      );
}
