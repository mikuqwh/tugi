/// The feature catalog: one list that drives the home screen.
///
/// Before S4 the home was a hard-coded list of records plus a switch on the
/// label inside `_navigateToFeature`; adding a feature meant touching three
/// places and a typo in a label silently produced "coming soon". This file is
/// the single source: the grid, the search index and the routes all read it.
// SPDX-License-Identifier: GPL-3.0-or-later

library feature_catalog;

import 'package:flutter/material.dart';

import '../screens/add_watermark_screen.dart';
import '../screens/compress_gif_screen.dart';
import '../screens/edit_gif_screen.dart';
import '../screens/edit_image_screen.dart';
import '../screens/extract_audio_screen.dart';
import '../screens/format_convert_screen.dart';
import '../screens/gif_to_images_screen.dart';
import '../screens/gif_to_video_screen.dart';
import '../screens/images_to_gif_screen.dart';
import '../screens/images_to_video_screen.dart';
import '../screens/scramble_screen.dart';
import '../screens/video_to_gif_screen.dart';
import 'app_palette.dart';

/// The four groups the home screen sorts features into (brand spec §9.4).
///
/// A category with no features is not rendered, so 工具 can exist in the model
/// before it has content instead of showing an empty header.
enum FeatureCategory {
  convert('转换', 'Convert files between formats', Accents.cyan),
  gif('GIF', 'Create and edit animated GIFs', Accents.rose),
  image('图片', 'Image editing and watermarking', Accents.indigo),
  tools('工具', 'Small utilities', Accents.tools);

  const FeatureCategory(this.title, this.blurb, this.accent);

  final String title;
  final String blurb;
  final Accent accent;
}

/// One screen, as the home screen knows it.
@immutable
class FeatureEntry {
  const FeatureEntry({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.category,
    required this.builder,
    this.keywords = const [],
  });

  /// Stable id for favourites/recents persistence. Never change it casually:
  /// a renamed id looks like a deleted favourite to every existing user.
  final String id;

  final String label;

  /// One line under the label; also searched.
  final String subtitle;

  final IconData icon;
  final FeatureCategory category;
  final WidgetBuilder builder;

  /// This feature's own colour pair; within one category these differ by hue
  /// and share a family, so a group reads as a group without its members
  /// looking like the same tile repeated.
  FeatureAccent get accent => FeaturePalette.of(id);

  /// Extra search terms (Chinese labels, synonyms, file extensions).
  final List<String> keywords;
}

/// Everything Tugi can do, in display order within each category.
final List<FeatureEntry> featureCatalog = [
  // ---- 转换 -------------------------------------------------------------
  FeatureEntry(
    id: 'format_convert',
    label: 'Format Convert',
    subtitle: '图片、动图、视频、音频互转；常用格式一键选，其余收在「更多格式」',
    icon: Icons.swap_horiz,
    category: FeatureCategory.convert,
    builder: (_) => const FormatConvertScreen(),
    keywords: const [
      '转换',
      '格式',
      '格式转换',
      'mp4',
      'webp',
      'avif',
      'png',
      'jpg',
      '转码'
    ],
  ),
  FeatureEntry(
    id: 'extract_audio',
    label: 'Extract Audio',
    subtitle: '从视频里取出音轨；编码一致时直接复制，无损且瞬间完成',
    icon: Icons.audiotrack,
    category: FeatureCategory.convert,
    builder: (_) => const ExtractAudioScreen(),
    keywords: const ['音频', '提取', '转音频', 'mp3', 'm4a', 'flac', 'wav', '视频转音频'],
  ),
  FeatureEntry(
    id: 'images_to_video',
    label: 'Images to Video',
    subtitle: '多张图片合成视频；时长、帧率可调，输出 MP4 / WebM / MKV',
    icon: Icons.movie_filter,
    category: FeatureCategory.convert,
    builder: (_) => const ImagesToVideoScreen(),
    keywords: const ['图片转视频', '合成', '幻灯片', 'mp4', 'webm'],
  ),

  FeatureEntry(
    id: 'scramble',
    label: 'Scramble 混淆',
    subtitle: '把图片打乱成噪点，用一个密码再还原；混淆和还原都是无损的',
    icon: Icons.blur_on,
    category: FeatureCategory.convert,
    builder: (_) => const ScrambleScreen(),
    keywords: const ['混淆', '加密', '打乱', '还原', '解密', '噪点', 'scramble'],
  ),

  // ---- GIF --------------------------------------------------------------
  FeatureEntry(
    id: 'video_to_gif',
    label: 'Video to GIF',
    subtitle: '截取视频转成 GIF 或 APNG；帧率、宽度、去重压缩都能调',
    icon: Icons.videocam,
    category: FeatureCategory.gif,
    builder: (_) => const VideoToGifScreen(),
    keywords: const ['视频转gif', '录屏', '截取', 'apng'],
  ),
  FeatureEntry(
    id: 'images_to_gif',
    label: 'Images to GIF',
    subtitle: '多张图片合成动图；每张停留时长与输出宽度可调',
    icon: Icons.photo_library,
    category: FeatureCategory.gif,
    builder: (_) => const ImagesToGifScreen(),
    keywords: const ['图片转gif', '合成', '动图', 'apng'],
  ),
  FeatureEntry(
    id: 'edit_gif',
    label: 'Edit GIF',
    subtitle: '变速与倒放；保留原帧时长，不会重新量化',
    icon: Icons.edit,
    category: FeatureCategory.gif,
    builder: (_) => const EditGifScreen(),
    keywords: const ['编辑gif', '倒放', '变速', '反转'],
  ),
  FeatureEntry(
    id: 'gif_to_video',
    label: 'GIF to Video',
    subtitle: 'GIF 转 MP4 / WebM / MKV；变成能上传的视频',
    icon: Icons.movie_outlined,
    category: FeatureCategory.gif,
    builder: (_) => const GifToVideoScreen(),
    keywords: const ['gif转视频', 'mp4', 'webm'],
  ),
  FeatureEntry(
    id: 'gif_to_images',
    label: 'GIFs to Images',
    subtitle: '按帧拆成图片；整段帧序列可以一次保存',
    icon: Icons.photo,
    category: FeatureCategory.gif,
    builder: (_) => const GifToImagesScreen(),
    keywords: const ['gif拆帧', '抽帧', '图片序列', 'png', 'jpg'],
  ),
  FeatureEntry(
    id: 'compress_gif',
    label: 'Compress GIFs',
    subtitle: '缩放或抽帧压缩；保存前就能看到预估体积',
    icon: Icons.compress,
    category: FeatureCategory.gif,
    builder: (_) => const CompressGifScreen(),
    keywords: const ['压缩gif', '抽帧', '减小体积'],
  ),

  // ---- 图片 -------------------------------------------------------------
  FeatureEntry(
    id: 'add_watermark',
    label: 'Add watermark',
    subtitle: '文字 / 图片 / GIF 水印，可叠多层，也支持批量',
    icon: Icons.text_fields,
    category: FeatureCategory.image,
    builder: (_) => const AddWatermarkScreen(),
    keywords: const ['水印', '加水印', 'logo'],
  ),
  FeatureEntry(
    id: 'edit_image',
    label: 'Edit Image',
    subtitle: '裁剪、旋转、调色与压缩；PNG / JPEG / WebP',
    icon: Icons.image,
    category: FeatureCategory.image,
    builder: (_) => const EditImageScreen(),
    keywords: const ['图片编辑', '裁剪', '滤镜', '压缩图片', '旋转'],
  ),
];

/// Features in [category], in catalog order.
List<FeatureEntry> featuresIn(FeatureCategory category) =>
    featureCatalog.where((f) => f.category == category).toList();

/// Categories that actually have something in them.
List<FeatureCategory> get populatedCategories =>
    FeatureCategory.values.where((c) => featuresIn(c).isNotEmpty).toList();

FeatureEntry? featureById(String id) {
  for (final f in featureCatalog) {
    if (f.id == id) return f;
  }
  return null;
}

/// Case-insensitive search over label, subtitle and keywords.
///
/// Chinese has no word boundaries, so this is a substring match rather than
/// tokenised search: typing 「水印」 must find Add watermark, and 「mp4」 must
/// find every feature that writes one.
List<FeatureEntry> searchFeatures(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  return featureCatalog.where((f) {
    if (f.label.toLowerCase().contains(q)) return true;
    if (f.subtitle.toLowerCase().contains(q)) return true;
    return f.keywords.any((k) => k.toLowerCase().contains(q));
  }).toList();
}
