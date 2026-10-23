// SPDX-License-Identifier: GPL-3.0-or-later

/// Tugi — creation and layer data models.
/// Schema reverse-engineered from真机 creations.db (49 columns + 143-field layers).

// ============================================================
// A layer carries 143 fields.
// Encoding: base64url (no padding) → gzip → JSON.
// ============================================================

// SPDX-License-Identifier: GPL-3.0-or-later

class FrameLayer {
  final String key; // frame_layer_{uid}_{frameIndex}
  final String type; // image | text | sticker
  final double dx, dy;
  final double width, height;
  final double dxForCurved, dyForCurved;
  final double widthForCurved, heightForCurved;
  final double ratio;
  final double rotateAngle;
  final int startFrameIndex, endFrameIndex;
  final String? text;
  final String? imagePath;
  final double imageX, imageY;
  final double imageWidth, imageHeight;
  final int fps; // layer-level fps (12), distinct from creation.fps (1.0)
  final int imageTransparency;
  // Four-layer strokes
  final bool imageInnerStroke,
      imageOuterStroke,
      imageThirdStroke,
      imageFourthStroke;
  final bool imageInnerStrokeGradient, imageOuterStrokeGradient;
  final List<int> imageInnerStrokeGradientColors;
  final int imageInnerStrokeGradientDirection;
  final double imageInnerStrokeGradientOffset, imageInnerStrokeGradientBlur;
  final double imageInnerStrokeWidth, imageOuterStrokeWidth;
  final int imageInnerStrokeColor, imageOuterStrokeColor;
  final int imageInnerStrokeColorFrom, imageOuterStrokeColorFrom;
  final bool imageInnerStrokeFromImage, imageOuterStrokeFromImage;
  final String? imageInnerStrokeFromImagePath, imageOuterStrokeFromImagePath;
  // Third & fourth stroke
  final double imageThirdStrokeWidth, imageFourthStrokeWidth;
  final int imageThirdStrokeColor, imageFourthStrokeColor;
  final bool imageThirdStrokeFromImage, imageFourthStrokeFromImage;
  // Shadow
  final bool imageShadow;
  final double imageShadowWidth, imageShadowDistanceX, imageShadowDistanceY;
  final int imageShadowColor, imageShadowColorFrom;
  // State
  final bool initDxDy, editingText, underFrames;
  final bool showOperations, showFrames, chosen, frame;
  final bool flip, hide, locked, erased;
  final Map<String, dynamic> keyFrames;
  final bool markingKeyFrames;
  final List<dynamic> erasePointsList;
  final bool eraseFirstForAll;
  final List<dynamic> eraserSizes, eraseOffsets, eraseScales;
  final String? blendMode, foreGroundImageBlendMode;
  final String? foreGround;
  final String? animateType;
  final int animateSpeed, animateDiff;
  final double animateStartSize, centerPointDiffX, centerPointDiffY;
  final bool editingForeground, changeImageColor;
  final int imageColor, imageColorFrom;
  final List<dynamic> warpOffests;
  // Emboss & frosted
  final bool emboss, frosted;
  final double embossOffset, embossAngle, embossSoftlight;
  final int embossTransparency;
  final double frostedStrength;
  // Paint (brush)
  final List<dynamic> paintedPoints, painterSizes, paintedColors;
  final List<double> paintedBlurRates, paintedWidths, paintedHeights;
  final List<double> paintedOffsets, paintedScales;
  // Paint for strokes
  final List<dynamic> paintedPointsForInnerStroke, painterSizesForInnerStroke;
  final List<int> paintedColorsForInnerStroke;
  final List<double> paintedBlurRatesForInnerStroke,
      paintedWidthsForInnerStroke;
  final List<double> paintedHeightsForInnerStroke, paintedOffsetsForInnerStroke;
  final List<double> paintedScalesForInnerStroke;
  // Paint for outer stroke
  final List<dynamic> paintedPointsForOuterStroke, painterSizesForOuterStroke;
  final List<int> paintedColorsForOuterStroke;
  final List<double> paintedBlurRatesForOuterStroke,
      paintedWidthsForOuterStroke;
  final List<double> paintedHeightsForOuterStroke, paintedOffsetsForOuterStroke;
  final List<double> paintedScalesForOuterStroke;
  // Paint for third stroke
  final List<dynamic> paintedPointsForThirdStroke, painterSizesForThirdStroke;
  final List<int> paintedColorsForThirdStroke;
  final List<double> paintedBlurRatesForThirdStroke,
      paintedWidthsForThirdStroke;
  final List<double> paintedHeightsForThirdStroke, paintedOffsetsForThirdStroke;
  final List<double> paintedScalesForThirdStroke;

  const FrameLayer({
    required this.key,
    required this.type,
    required this.dx,
    required this.dy,
    required this.width,
    required this.height,
    this.dxForCurved = 0.0,
    this.dyForCurved = 0.0,
    this.widthForCurved = 128.0,
    this.heightForCurved = 128.0,
    this.ratio = 0.45,
    this.rotateAngle = 0.0,
    this.startFrameIndex = 0,
    this.endFrameIndex = 0,
    this.text,
    this.imagePath,
    this.imageX = 0.0,
    this.imageY = 0.0,
    this.imageWidth = 1080.0,
    this.imageHeight = 2400.0,
    this.fps = 12,
    this.imageTransparency = 255,
    this.imageInnerStroke = false,
    this.imageOuterStroke = false,
    this.imageThirdStroke = false,
    this.imageFourthStroke = false,
    this.imageInnerStrokeGradient = false,
    this.imageOuterStrokeGradient = false,
    this.imageInnerStrokeGradientColors = const [],
    this.imageInnerStrokeGradientDirection = 2,
    this.imageInnerStrokeGradientOffset = 8.0,
    this.imageInnerStrokeGradientBlur = 0.1,
    this.imageInnerStrokeWidth = 3.0,
    this.imageOuterStrokeWidth = 6.0,
    this.imageInnerStrokeColor = 0,
    this.imageOuterStrokeColor = 0,
    this.imageInnerStrokeColorFrom = 2,
    this.imageOuterStrokeColorFrom = 2,
    this.imageInnerStrokeFromImage = false,
    this.imageOuterStrokeFromImage = false,
    this.imageInnerStrokeFromImagePath,
    this.imageOuterStrokeFromImagePath,
    this.imageThirdStrokeWidth = 9.0,
    this.imageFourthStrokeWidth = 12.0,
    this.imageThirdStrokeColor = 0,
    this.imageFourthStrokeColor = 0,
    this.imageThirdStrokeFromImage = false,
    this.imageFourthStrokeFromImage = false,
    this.imageShadow = false,
    this.imageShadowWidth = 5.0,
    this.imageShadowDistanceX = 5.0,
    this.imageShadowDistanceY = 5.0,
    this.imageShadowColor = 0,
    this.imageShadowColorFrom = 2,
    this.initDxDy = true,
    this.editingText = false,
    this.underFrames = false,
    this.showOperations = true,
    this.showFrames = true,
    this.chosen = false,
    this.frame = true,
    this.flip = false,
    this.hide = false,
    this.locked = false,
    this.erased = false,
    this.keyFrames = const {},
    this.markingKeyFrames = false,
    this.erasePointsList = const [],
    this.eraseFirstForAll = false,
    this.eraserSizes = const [],
    this.eraseOffsets = const [],
    this.eraseScales = const [],
    this.blendMode,
    this.foreGroundImageBlendMode,
    this.foreGround,
    this.animateType,
    this.animateSpeed = 1,
    this.animateDiff = 0,
    this.animateStartSize = 0.0,
    this.centerPointDiffX = 0.0,
    this.centerPointDiffY = 0.0,
    this.editingForeground = false,
    this.changeImageColor = false,
    this.imageColor = 0,
    this.imageColorFrom = 2,
    this.warpOffests = const [],
    this.emboss = false,
    this.frosted = false,
    this.embossOffset = 0.7,
    this.embossAngle = 70.0,
    this.embossSoftlight = 0,
    this.embossTransparency = 100,
    this.frostedStrength = 15.0,
    this.paintedPoints = const [],
    this.painterSizes = const [],
    this.paintedColors = const [],
    this.paintedBlurRates = const [],
    this.paintedWidths = const [],
    this.paintedHeights = const [],
    this.paintedOffsets = const [],
    this.paintedScales = const [],
    this.paintedPointsForInnerStroke = const [],
    this.painterSizesForInnerStroke = const [],
    this.paintedColorsForInnerStroke = const [],
    this.paintedBlurRatesForInnerStroke = const [],
    this.paintedWidthsForInnerStroke = const [],
    this.paintedHeightsForInnerStroke = const [],
    this.paintedOffsetsForInnerStroke = const [],
    this.paintedScalesForInnerStroke = const [],
    this.paintedPointsForOuterStroke = const [],
    this.painterSizesForOuterStroke = const [],
    this.paintedColorsForOuterStroke = const [],
    this.paintedBlurRatesForOuterStroke = const [],
    this.paintedWidthsForOuterStroke = const [],
    this.paintedHeightsForOuterStroke = const [],
    this.paintedOffsetsForOuterStroke = const [],
    this.paintedScalesForOuterStroke = const [],
    this.paintedPointsForThirdStroke = const [],
    this.painterSizesForThirdStroke = const [],
    this.paintedColorsForThirdStroke = const [],
    this.paintedBlurRatesForThirdStroke = const [],
    this.paintedWidthsForThirdStroke = const [],
    this.paintedHeightsForThirdStroke = const [],
    this.paintedOffsetsForThirdStroke = const [],
    this.paintedScalesForThirdStroke = const [],
  });

  /// Default single-image layer (for Images to GIF default 10-frame expansion)
  factory FrameLayer.defaultImageLayer({
    required String key,
    required double canvasWidth,
    required double canvasHeight,
    String? imagePath,
  }) {
    final ratio = canvasWidth / canvasHeight;
    return FrameLayer(
      key: key,
      type: 'image',
      dx: canvasWidth * 0.5 - (185.14 / 2),
      dy: 0.0,
      width: 185.14,
      height: 411.43,
      widthForCurved: 128.0,
      heightForCurved: 128.0,
      ratio: ratio,
      imagePath: imagePath,
      imageWidth: 1080.0,
      imageHeight: 2400.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key, 'type': type,
        'dx': dx, 'dy': dy, 'width': width, 'height': height,
        'fps': fps, 'imagePath': imagePath,
        'imageWidth': imageWidth, 'imageHeight': imageHeight,
        // ... full serialization
      };
}

// ============================================================
// A creation carries 49 fields.
// ============================================================

class Creation {
  final String id;
  final int noMaterials;
  final String name;
  final String type; // gif | image | video
  final String? cover;
  final String folderId;
  final String time;
  final double fps; // playback fps (1.0 for GIF)
  final Map<String, dynamic> fileFrameIndexOrderMap;
  final int reversedFrames;
  final double dstWidth, dstHeight;
  final String dstAspectRatioType;
  final double dstAspectRatio;
  final int useBgImageRatioAsAspectRatio;
  final int dstBackgroundColor;
  final int dstBackgroundBlur;
  final double dstBackgroundBlurRate;
  final String? dstBackgroundImagePath;
  final String dstForeground;
  final int dstForegroundBlendMode;
  final int cropped;
  final double croppedAreaDx, croppedAreaDy;
  final double croppedAreaWidth, croppedAreaHeight;
  final int flip, rotate, rotateRadian;
  final Map<String, FrameLayer> layers;
  final Map<String, dynamic> layerGroups;
  final String? audioPath;
  final int audioDuration;
  final int emptyGIFFramesLenth; // default 10
  final Map<String, dynamic> uploadedImages;
  final double fromDeviceWidth;
  // Four-layer stroke source
  final int imageInnerStrokeFromImage, imageOuterStrokeFromImage;
  final int imageThirdStrokeFromImage, imageFourthStrokeFromImage;
  final String? imageInnerStrokeFromImagePath;
  final String? imageOuterStrokeFromImagePath;
  final String? imageThirdStrokeFromImagePath;
  final String? imageFourthStrokeFromImagePath;
  final int changeTextOnly, encrypted;
  final int updatedTime;
  final int deleted, deletedTime;

  const Creation({
    required this.id,
    this.noMaterials = 0,
    required this.name,
    required this.type,
    this.cover,
    this.folderId = '0',
    required this.time,
    this.fps = 1.0,
    this.fileFrameIndexOrderMap = const {},
    this.reversedFrames = 0,
    this.dstWidth = 0,
    this.dstHeight = 0,
    this.dstAspectRatioType = 'original',
    this.dstAspectRatio = 0.45,
    this.useBgImageRatioAsAspectRatio = 0,
    this.dstBackgroundColor = 0,
    this.dstBackgroundBlur = 0,
    this.dstBackgroundBlurRate = 0.0,
    this.dstBackgroundImagePath,
    this.dstForeground = '{}',
    this.dstForegroundBlendMode = 0,
    this.cropped = 0,
    this.croppedAreaDx = 0,
    this.croppedAreaDy = 0,
    this.croppedAreaWidth = 0,
    this.croppedAreaHeight = 0,
    this.flip = 0,
    this.rotate = 0,
    this.rotateRadian = 0,
    this.layers = const {},
    this.layerGroups = const {},
    this.audioPath,
    this.audioDuration = 0,
    this.emptyGIFFramesLenth = 10,
    this.uploadedImages = const {},
    this.fromDeviceWidth = 411.42857142857144,
    this.imageInnerStrokeFromImage = 0,
    this.imageOuterStrokeFromImage = 0,
    this.imageThirdStrokeFromImage = 0,
    this.imageFourthStrokeFromImage = 0,
    this.imageInnerStrokeFromImagePath,
    this.imageOuterStrokeFromImagePath,
    this.imageThirdStrokeFromImagePath,
    this.imageFourthStrokeFromImagePath,
    this.changeTextOnly = 0,
    this.encrypted = 0,
    required this.updatedTime,
    this.deleted = 0,
    this.deletedTime = 0,
  });

  /// Default canvas size from device width (used for DP coordinate scaling, NOT output size)
  static const double defaultDeviceWidth = 411.42857142857144;

  /// Default aspect ratio
  static const double defaultAspectRatio = 0.45;

  /// Default frame count for single-image expansion
  static const int defaultFrameCount = 10;

  /// Layer-level fps (distinct from playback fps)
  static const int layerFps = 12;

  static const Map<String, double> widthPresets = {
    'original': 0, // 0 = use source width
    '1080': 1080.0,
  };

  /// ASSUMPTION: exact thresholds need真机 verification; values from strings.
  static const List<double> volumeThresholdsMB = [30, 20, 100, 90];

  /// Derive output dimensions — width-driven model.
  ///            based on the aspect ratio"
  /// ASSUMPTION: all 3 creations satisfy height = width / ratio.
  /// [outputWidth] defaults to source width (keep_resolution / :original:).
  static ({double w, double h}) deriveOutputSize(
    double srcW,
    double srcH, {
    double? outputWidth,
    bool keepResolution = true,
  }) {
    final ratio = srcW / srcH;
    // widthPresets['original'] = 0 sentinel: treat 0 as "use source width"
    final w = (keepResolution || outputWidth == null || outputWidth <= 0)
        ? srcW
        : outputWidth;
    return (w: w, h: w / ratio);
  }

  /// Recommend a width based on file size (volume constraint).
  ///            recommended width: —
  /// ASSUMPTION: exact mapping needs真机 verification.
  static double? recommendWidthForSize(double fileSizeMB, double srcWidth) {
    if (fileSizeMB <= 20) return null;
    if (fileSizeMB <= 30) return srcWidth * 0.75;
    if (fileSizeMB <= 90) return srcWidth * 0.5;
    if (fileSizeMB <= 100) return srcWidth * 0.35;
    return srcWidth * 0.2;
  }

  /// Create a default creation for Video to GIF.
  /// Width-driven: user sets width, height = width / ratio.
  /// [outputWidth] defaults to source width (:original: preset).
  factory Creation.videoToGif({
    required String videoPath,
    required double videoWidth,
    required double videoHeight,
    double? outputWidth,
    bool keepResolution = true,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final aspectRatio = videoWidth / videoHeight;
    final (:w, :h) = deriveOutputSize(
      videoWidth,
      videoHeight,
      outputWidth: outputWidth,
      keepResolution: keepResolution,
    );

    return Creation(
      id: '$now',
      name: DateTime.now()
          .toString()
          .replaceAll(':', '')
          .replaceAll('.', '')
          .substring(0, 8),
      type: 'gif',
      time: DateTime.now().toString(),
      fps: 1.0,
      dstWidth: w,
      dstHeight: h,
      dstAspectRatioType: 'original',
      dstAspectRatio: aspectRatio,
      fromDeviceWidth: 411.42857142857144,
      updatedTime: now,
    );
  }

  /// Create a default creation for Images to GIF (one image → N frames).
  /// Width-driven model; [outputWidth] defaults to source width.
  factory Creation.imagesToGif({
    required String imagePath,
    required double imageWidth,
    required double imageHeight,
    int frameCount = 10,
    double? outputWidth,
    bool keepResolution = true,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final aspectRatio = imageWidth / imageHeight;
    final (:w, :h) = deriveOutputSize(
      imageWidth,
      imageHeight,
      outputWidth: outputWidth,
      keepResolution: keepResolution,
    );

    return Creation(
      id: '$now',
      name: DateTime.now()
          .toString()
          .replaceAll(':', '')
          .replaceAll('.', '')
          .substring(0, 8),
      type: 'gif',
      time: DateTime.now().toString(),
      fps: 1.0,
      dstWidth: w,
      dstHeight: h,
      dstAspectRatioType: 'original',
      dstAspectRatio: aspectRatio,
      emptyGIFFramesLenth: frameCount,
      fromDeviceWidth: 411.42857142857144,
      updatedTime: now,
    );
  }
}
