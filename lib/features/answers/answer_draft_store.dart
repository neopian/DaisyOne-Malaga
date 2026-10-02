import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/api_service.dart';
import '../../shared/models/evidence_link.dart';

final answerDraftStoreProvider = Provider<AnswerDraftStore>(
  (ref) =>
      AnswerDraftStore(server: ref.watch(apiClientProvider).baseUri.toString()),
);

/// Only answer text and evidence links live here. Keys isolate the API, account
/// and question. Raw storage operations stay serialized even after a caller's
/// timeout, preventing a delayed old write from overwriting a later draft.
class AnswerDraftStore {
  AnswerDraftStore({
    required this.server,
    Future<SharedPreferences> Function()? preferences,
    this.timeout = const Duration(seconds: 4),
  }) : _preferences = preferences ?? SharedPreferences.getInstance;
  final String server;
  final Future<SharedPreferences> Function() _preferences;
  final Duration timeout;
  Future<void> _writes = Future<void>.value();
  final _removedOwners = <String>{};

  String _prefix(String owner) =>
      'answer.draft.v1.${sha256.convert(utf8.encode('$server|$owner'))}.';
  String _key(String owner, String question) =>
      '${_prefix(owner)}${sha256.convert(utf8.encode(question))}';

  Future<AnswerDraft?> read(String owner, String question) => (() async {
    await _writes;
    final prefs = await _preferences();
    final raw = prefs.getString(_key(owner, question));
    if (raw == null) return null;
    if (raw.length > 250000) {
      throw const FormatException('Answer draft is too large');
    }
    final draft = AnswerDraft.fromJson(ApiClient.asMap(jsonDecode(raw)));
    if (draft.questionId != question) {
      throw const FormatException('Question mismatch');
    }
    return draft;
  })().timeout(timeout);

  Future<void> save(String owner, AnswerDraft draft) => _serialize(() async {
    if (_removedOwners.contains(owner)) throw StateError('Deleted account');
    final raw = jsonEncode(draft.toJson());
    if (raw.length > 250000) {
      throw const FormatException('Answer draft is too large');
    }
    final prefs = await _preferences();
    if (_removedOwners.contains(owner)) throw StateError('Deleted account');
    if (!await prefs.setString(_key(owner, draft.questionId), raw)) {
      throw StateError('Draft save failed');
    }
  });

  Future<void> clear(String owner, String question) => _serialize(() async {
    if (!await (await _preferences()).remove(_key(owner, question))) {
      throw StateError('Draft removal failed');
    }
  });

  Future<void> completeAttempt(
    String owner,
    String question,
    String requestId,
  ) => _serialize(() async {
    final prefs = await _preferences();
    final key = _key(owner, question);
    final raw = prefs.getString(key);
    if (raw == null) return;
    final draft = AnswerDraft.fromJson(ApiClient.asMap(jsonDecode(raw)));
    if (draft.pending?.requestId != requestId) return;
    if (!await prefs.remove(key)) throw StateError('Draft removal failed');
  });

  Future<void> releaseAttempt(
    String owner,
    AnswerDraft draft,
    String requestId,
  ) => _serialize(() async {
    if (_removedOwners.contains(owner)) return;
    final prefs = await _preferences();
    final key = _key(owner, draft.questionId);
    final raw = prefs.getString(key);
    if (raw == null) return;
    final current = AnswerDraft.fromJson(ApiClient.asMap(jsonDecode(raw)));
    if (current.pending?.requestId != requestId) return;
    if (!await prefs.setString(key, jsonEncode(draft.toJson()))) {
      throw StateError('Draft save failed');
    }
  });

  Future<void> clearOwner(String owner) {
    _removedOwners.add(owner);
    return _serialize(() async {
      final prefs = await _preferences();
      for (final key in prefs.getKeys().where(
        (key) => key.startsWith(_prefix(owner)),
      )) {
        if (!await prefs.remove(key)) throw StateError('Draft removal failed');
      }
    });
  }

  Future<void> _serialize(Future<void> Function() action) {
    final raw = _writes.then((_) => action());
    _writes = raw.catchError((Object _) {});
    return raw.timeout(timeout);
  }
}

class AnswerSubmission {
  AnswerSubmission({
    required this.requestId,
    required this.body,
    required this.evidenceSummary,
    required this.verificationMethod,
    required List<EvidenceLink> links,
    required this.confirmedEvidence,
    required this.confirmedNoAi,
    required this.confirmedNoGuess,
  }) : links = List.unmodifiable(links);
  final String requestId;
  final String body;
  final String evidenceSummary;
  final String verificationMethod;
  final List<EvidenceLink> links;
  final bool confirmedEvidence;
  final bool confirmedNoAi;
  final bool confirmedNoGuess;

  Map<String, dynamic> toJson() => {
    'request_id': requestId,
    'body': body,
    'evidence_summary': evidenceSummary,
    'verification_method': verificationMethod,
    'links': links.map((link) => link.toPayload()).toList(),
    'confirmed_evidence': confirmedEvidence,
    'confirmed_no_ai': confirmedNoAi,
    'confirmed_no_guess': confirmedNoGuess,
  };
  factory AnswerSubmission.fromJson(Map<String, dynamic> map) {
    final id = map['request_id'] as String;
    if (!RegExp(r'^[A-Za-z0-9_.:-]{16,128}$').hasMatch(id) ||
        map['confirmed_evidence'] != true ||
        map['confirmed_no_ai'] != true ||
        map['confirmed_no_guess'] != true) {
      throw const FormatException('Invalid pending answer');
    }
    return AnswerSubmission(
      requestId: id,
      body: map['body'] as String,
      evidenceSummary: map['evidence_summary'] as String,
      verificationMethod: map['verification_method'] as String,
      links: (map['links'] as List)
          .map((link) => EvidenceLink.fromMap(ApiClient.asMap(link)))
          .toList(),
      confirmedEvidence: true,
      confirmedNoAi: true,
      confirmedNoGuess: true,
    );
  }
}

class AnswerDraft {
  AnswerDraft({
    required this.questionId,
    required this.body,
    required this.evidenceSummary,
    required this.verificationMethod,
    required this.linkUrl,
    required this.linkTitle,
    required this.linkDescription,
    required this.sourceType,
    required List<EvidenceLink> links,
    this.pending,
  }) : links = List.unmodifiable(links);
  final String questionId;
  final String body;
  final String evidenceSummary;
  final String verificationMethod;
  final String linkUrl;
  final String linkTitle;
  final String linkDescription;
  final String sourceType;
  final List<EvidenceLink> links;
  final AnswerSubmission? pending;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'question_id': questionId,
    'body': body,
    'evidence_summary': evidenceSummary,
    'verification_method': verificationMethod,
    'link_url': linkUrl,
    'link_title': linkTitle,
    'link_description': linkDescription,
    'source_type': sourceType,
    'links': links.map((link) => link.toPayload()).toList(),
    'pending': pending?.toJson(),
  };
  factory AnswerDraft.fromJson(Map<String, dynamic> map) {
    if (map['version'] != 1) {
      throw const FormatException('Unsupported answer draft');
    }
    return AnswerDraft(
      questionId: map['question_id'] as String,
      body: map['body'] as String,
      evidenceSummary: map['evidence_summary'] as String,
      verificationMethod: map['verification_method'] as String,
      linkUrl: map['link_url'] as String,
      linkTitle: map['link_title'] as String,
      linkDescription: map['link_description'] as String,
      sourceType: map['source_type'] as String,
      links: (map['links'] as List)
          .map((link) => EvidenceLink.fromMap(ApiClient.asMap(link)))
          .toList(),
      pending: map['pending'] == null
          ? null
          : AnswerSubmission.fromJson(ApiClient.asMap(map['pending'])),
    );
  }
}
