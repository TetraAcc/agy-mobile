class AppFontOption {
  final String id;
  final String name;
  final String description;
  final String? fontFamily;
  final String? remoteFile;
  final List<String> fallbacks;

  const AppFontOption({
    required this.id,
    required this.name,
    required this.description,
    required this.fontFamily,
    required this.remoteFile,
    this.fallbacks = const [],
  });
}

class AppFonts {
  static const AppFontOption system = AppFontOption(
    id: 'system',
    name: '默认无衬线',
    description: '清爽现代 · 零加载',
    fontFamily: null,
    remoteFile: null,
    fallbacks: [],
  );

  static const AppFontOption wenkai = AppFontOption(
    id: 'wenkai',
    name: '霞鹜文楷',
    description: '温润楷韵 · 长文护眼',
    fontFamily: 'AgyWenkai',
    remoteFile: 'LXGWWenKaiLite-Regular.ttf',
    fallbacks: ['serif'],
  );

  static const AppFontOption serif = AppFontOption(
    id: 'serif',
    name: '人文宋体',
    description: '思源宋体 · 书卷阅读感',
    fontFamily: 'AgySerif',
    remoteFile: 'NotoSerifSC-Regular.ttf',
    fallbacks: ['serif'],
  );

  static const AppFontOption mono = AppFontOption(
    id: 'mono',
    name: '极客等宽',
    description: 'JetBrains Mono · 工程风',
    fontFamily: 'AgyMono',
    remoteFile: 'JetBrainsMono-Regular.ttf',
    fallbacks: ['monospace'],
  );

  static const List<AppFontOption> options = [
    system,
    wenkai,
    serif,
    mono,
  ];

  static AppFontOption getById(String? id) {
    if (id == null || id.isEmpty) return system;
    for (final opt in options) {
      if (opt.id == id) return opt;
    }
    return system;
  }
}
