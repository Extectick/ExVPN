// SPDX-License-Identifier: Apache-2.0
import 'package:exvpn_domain/exvpn_domain.dart';

/// A reviewed starter set, not a complete or live registry of blocked sites.
/// Domain facts adapted from MIT domain-list-community, pinned to this revision.
const sitePresetRevision = '2026-10-21';
const sitePresetSourceCommit = '497bef95124ac98a70ed865bb8aaaa8e9a4ff66e';

final builtInSitePresets = <SiteRoutingPreset>[
  _preset('russia-basic', 'Россия · основные сервисы', {
    ..._video,
    ..._messengers,
    ..._social,
    ..._ai,
  }),
  _preset('video', 'Видео', _video),
  _preset('messengers', 'Мессенджеры', _messengers),
  _preset('social', 'Соцсети', _social),
  _preset('ai', 'ИИ-сервисы', _ai),
];

SiteRoutingPreset _preset(String id, String name, Set<String> rules) =>
    SiteRoutingPreset(
      id: id,
      name: name,
      policy: SiteRoutingPolicy(mode: SiteRoutingMode.include, rules: rules),
    );

const _video = {
  'youtube.com',
  'youtu.be',
  'googlevideo.com',
  'ytimg.com',
  'ggpht.com',
  'youtube-nocookie.com',
  'youtubekids.com',
  'youtubei.googleapis.com',
  'youtubeembeddedplayer.googleapis.com',
  'yt3.googleusercontent.com',
  'yt.be',
};
const _messengers = {
  'telegram.org', 't.me', 'telegram.me', 'telegra.ph', 'tdesktop.com',
  'telegram-cdn.org', 'cdn-telegram.org', 'telesco.pe',
  'whatsapp.com', 'whatsapp.net', 'wa.me',
  'signal.org', 'signal.art', 'signal.group', 'signal.link',
  'discord.com',
  'discord.gg',
  'discordapp.com',
  'discordapp.net',
  'discord.media',
  'discord-activities.com',
  'discordactivities.com',
  'discordstatus.com',
  'dis.gd',
  // Telegram's published networks: https://core.telegram.org/resources/cidr.txt
  '91.108.56.0/22', '91.108.4.0/22', '91.108.8.0/22', '91.108.16.0/22',
  '91.108.12.0/22', '149.154.160.0/20', '91.105.192.0/23', '91.108.20.0/22',
  '185.76.151.0/24', '2001:b28:f23d::/48', '2001:b28:f23f::/48',
  '2001:67c:4e8::/48', '2001:b28:f23c::/48', '2a0a:f280::/32',
};
const _social = {
  'instagram.com',
  'cdninstagram.com',
  'facebook.com',
  'facebook.net',
  'fbcdn.net',
  'fbsbx.com',
  'fb.com',
  'messenger.com',
  'm.me',
  'threads.net',
  'threads.com',
  'x.com',
  'twitter.com',
  't.co',
  'twimg.com',
  'tiktok.com',
  'tiktokcdn.com',
  'tiktokv.com',
};
const _ai = {
  'chatgpt.com',
  'openai.com',
  'oaistatic.com',
  'oaiusercontent.com',
  'chat.com',
  'sora.com',
  'anthropic.com',
  'claude.ai',
  'claudeusercontent.com',
  'gemini.google.com',
  'ai.google.dev',
  'generativelanguage.googleapis.com',
  'aistudio.google.com',
  'deepmind.google',
  'makersuite.google.com',
};
