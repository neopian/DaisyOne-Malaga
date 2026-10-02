import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/api_service.dart';

final travelDraftStoreProvider = Provider<TravelDraftStore>(
  (ref) =>
      TravelDraftStore(server: ref.watch(apiClientProvider).baseUri.toString()),
);

/// Text-only, device-local storage. Photos and authentication secrets are never
/// stored here. The server and account together define the storage namespace.
class TravelDraftStore {
  TravelDraftStore({
    required this.server,
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final String server;
  final Future<SharedPreferences> Function() _preferences;
  Future<void> _writes = Future<void>.value();

  String _key(String ownerId) =>
      'travel.questionDraft.v1.${sha256.convert(utf8.encode('$server|$ownerId'))}';

  Future<TravelQuestionDraft?> read(String ownerId) async {
    await _writes;
    final prefs = await _preferences().timeout(const Duration(seconds: 4));
    final encoded = prefs.getString(_key(ownerId));
    if (encoded == null) return null;
    return TravelQuestionDraft.fromJson(
      jsonDecode(encoded) as Map<String, dynamic>,
    );
  }

  Future<void> save(String ownerId, TravelQuestionDraft draft) =>
      _serialize(() async {
        final prefs = await _preferences().timeout(const Duration(seconds: 4));
        if (!await prefs
            .setString(_key(ownerId), jsonEncode(draft.toJson()))
            .timeout(const Duration(seconds: 4))) {
          throw StateError('임시 저장 실패');
        }
      });

  Future<void> clear(String ownerId) => _serialize(() async {
    final prefs = await _preferences().timeout(const Duration(seconds: 4));
    if (!await prefs
        .remove(_key(ownerId))
        .timeout(const Duration(seconds: 4))) {
      throw StateError('임시 저장 삭제 실패');
    }
  });

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _writes.then((_) => operation());
    _writes = next.catchError((Object _) {});
    return next;
  }
}

class TravelQuestionDraft {
  const TravelQuestionDraft({
    required this.title,
    required this.body,
    required this.category,
    required this.reward,
    required this.country,
    required this.city,
    required this.region,
    required this.isManualLocation,
    required this.imageCount,
    required this.submissionPending,
    this.requestId,
    this.latitude,
    this.longitude,
  });

  final String? requestId;
  final String title;
  final String body;
  final String category;
  final String reward;
  final String country;
  final String city;
  final String region;
  final double? latitude;
  final double? longitude;
  final bool isManualLocation;
  final int imageCount;
  final bool submissionPending;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'request_id': requestId,
    'title': title,
    'body': body,
    'category': category,
    'reward': reward,
    'country': country,
    'city': city,
    'region': region,
    'latitude': latitude,
    'longitude': longitude,
    'is_manual_location': isManualLocation,
    'image_count': imageCount,
    'submission_pending': submissionPending,
  };

  factory TravelQuestionDraft.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unknown draft version');
    }
    return TravelQuestionDraft(
      requestId: json['request_id'] as String?,
      title: json['title'] as String,
      body: json['body'] as String,
      category: json['category'] as String,
      reward: json['reward'] as String,
      country: json['country'] as String,
      city: json['city'] as String,
      region: json['region'] as String,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      isManualLocation: json['is_manual_location'] as bool,
      imageCount: json['image_count'] as int,
      submissionPending: json['submission_pending'] as bool,
    );
  }
}
