// lib/pdf/jp_font.dart
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

class JpPdfFont {
  static pw.Font? _font;

  /// 日本語可変フォントを一度だけロードしてキャッシュ
  static Future<pw.Font> load() async {
    if (_font != null) return _font!;
    final data = await rootBundle.load(
      'assets/fonts/NotoSansJP-VariableFont_wght.ttf',
    );
    _font = pw.Font.ttf(data.buffer.asByteData());
    return _font!;
  }

  /// すぐ使える ThemeData（base / bold とも同じフォントを指定）
  static Future<pw.ThemeData> theme() async {
    final f = await load();
    return pw.ThemeData.withFont(
      base: f,
      bold: f, // 可変フォント1本なので見た目は同じ
      italic: f,
      boldItalic: f,
    );
  }
}
