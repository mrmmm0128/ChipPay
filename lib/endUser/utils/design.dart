import 'package:flutter/material.dart';

/// ===============================================================
/// スタイル一元管理
/// ===============================================================
class AppPalette {
  // ベース
  static const Color black = Color(0xFF000000);
  static const Color white = Color(0xFFFFFFFF);

  // ブランド黄色（画像のトーンに近い少し濃いめ）:
  // 必要ならここを差し替えるだけで全体が変わります
  static const Color yellow = Color(0xFFFCC400);
  //static const Color yellow = Color.fromRGBO(255, 218, 78, 1);

  // 背景
  static const Color pageBg = Color(0xFFF7F7F7);

  // 枠色・線
  static const Color border = black;

  // 補助
  static const Color textPrimary = Colors.black87;
  static const Color textSecondary = Colors.black38;
}

class AppDims {
  static const double border = 5; // 黒太枠
  static const double border2 = 3; // 黒太枠
  static const double radius = 14.0;
  static const double radius2 = 18.0;
  static const double pad = 16.0;
}

class AppTypography {
  // ここを変えるだけでフォント全体を差し替えできます
  static const String fontFamily = 'LINEseed';

  static TextStyle headlineHuge({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 54,
    fontWeight: FontWeight.w900,
    height: 1.1,
    color: color ?? AppPalette.black,
  );

  static TextStyle headlineHuge0({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 70,
    fontWeight: FontWeight.w900,
    height: 1.1,
    color: color ?? AppPalette.black,
  );

  static TextStyle headlineLarge({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 32,
    fontWeight: FontWeight.w900,
    color: AppPalette.textPrimary,
  );

  static TextStyle label({Color? color, FontWeight weight = FontWeight.w700}) =>
      TextStyle(
        fontFamily: fontFamily,
        fontSize: 22,
        fontWeight: weight,
        color: color ?? AppPalette.textPrimary,
      );

  static TextStyle label2({
    Color? color,
    FontWeight weight = FontWeight.w700,
  }) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 18,
    fontWeight: weight,
    color: color ?? AppPalette.textPrimary,
  );

  static TextStyle body({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    color: color ?? AppPalette.textPrimary,
  );

  static TextStyle small({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    color: color ?? AppPalette.textPrimary,
  );
}
