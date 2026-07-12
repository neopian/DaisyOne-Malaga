import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../shared/models/question.dart';

final questionRepositoryProvider = Provider<QuestionRepository>((ref) {
  return QuestionRepository(ref.watch(supabaseClientProvider));
});

final questionsProvider = FutureProvider<List<Question>>((ref) {
  return ref.watch(questionRepositoryProvider).fetchVisibleQuestions();
});

final helperOpenQuestionsProvider = FutureProvider<List<Question>>((ref) {
  return ref.watch(questionRepositoryProvider).fetchOpenQuestions();
});

final questionProvider = FutureProvider.family<Question, String>((ref, id) {
  return ref.watch(questionRepositoryProvider).fetchQuestion(id);
});

class QuestionRepository {
  const QuestionRepository(this._client);

  final SupabaseClient _client;

  static const _requestTimeout = Duration(seconds: 12);

  static const _questionListSelect = '''
    *,
    question_images(image_url),
    question_comments!question_comments_question_id_fkey(body),
    answers!answers_question_id_fkey(
      *,
      answer_evidence_links(*)
    )
  ''';

  static const _questionSelect = '''
    *,
    question_images(image_url),
    question_comments!question_comments_question_id_fkey(
      *,
      commenter:users!question_comments_user_id_fkey(name, avatar_url)
    ),
    answers!answers_question_id_fkey(
      *,
      answer_evidence_links(*)
    )
  ''';

  Future<List<Question>> fetchVisibleQuestions() async {
    final rows = await _withTimeout(
      _client
          .from('questions')
          .select(_questionListSelect)
          .eq('country', 'Spain')
          .order('created_at', ascending: false),
    );
    return (rows as List)
        .map((row) => Question.fromMap(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  Future<List<Question>> fetchOpenQuestions() async {
    final rows = await _withTimeout(
      _client
          .from('questions')
          .select(_questionListSelect)
          .eq('country', 'Spain')
          .eq('status', 'open')
          .order('created_at', ascending: false),
    );
    return (rows as List)
        .map((row) => Question.fromMap(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  Future<Question> fetchQuestion(String questionId) async {
    try {
      final row = await _withTimeout(
        _client
            .from('questions')
            .select(_questionSelect)
            .eq('id', questionId)
            .single(),
      );
      return Question.fromMap(Map<String, dynamic>.from(row));
    } on PostgrestException catch (error) {
      if (_isQuestionCommentsMigrationError(error)) {
        throw const QuestionCommentsMigrationRequiredException();
      }
      rethrow;
    }
  }

  Future<String> createQuestion({
    required String title,
    required String body,
    required String country,
    required String city,
    required String? regionName,
    required String category,
    required String urgency,
    required int rewardPoints,
    required double latitude,
    required double longitude,
    required List<XFile> images,
  }) async {
    final String questionId;
    try {
      questionId =
          await _withTimeout(
                _client.rpc(
                  'create_question_with_hold',
                  params: {
                    'p_country': country,
                    'p_city': city,
                    'p_region_name': regionName,
                    'p_category': category,
                    'p_urgency': urgency,
                    'p_title': title,
                    'p_body': body,
                    'p_reward_points': rewardPoints,
                    'p_latitude': latitude,
                    'p_longitude': longitude,
                  },
                ),
              )
              as String;
    } on PostgrestException catch (error) {
      if (error.code == 'PGRST202' &&
          error.message.contains('create_question_with_hold')) {
        throw const SpainMapMigrationRequiredException();
      }
      rethrow;
    }

    for (final image in images) {
      final bytes = await image.readAsBytes();
      final safeName = image.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final path =
          'questions/$questionId/${DateTime.now().microsecondsSinceEpoch}_$safeName';
      await _client.storage
          .from('question-images')
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(upsert: true),
          );
      final url = _client.storage.from('question-images').getPublicUrl(path);
      await _client.from('question_images').insert({
        'question_id': questionId,
        'image_url': url,
      });
    }

    return questionId;
  }

  Future<void> acceptQuestion(String questionId) async {
    await _client.rpc('accept_question', params: {'p_question_id': questionId});
  }

  Future<void> addComment({
    required String questionId,
    required String body,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('로그인이 필요합니다.');
    }

    try {
      await _withTimeout(
        _client.from('question_comments').insert({
          'question_id': questionId,
          'user_id': user.id,
          'body': body.trim(),
        }),
      );
    } on PostgrestException catch (error) {
      if (_isQuestionCommentsMigrationError(error)) {
        throw const QuestionCommentsMigrationRequiredException();
      }
      rethrow;
    }
  }

  Future<T> _withTimeout<T>(Future<T> request) {
    return request.timeout(
      _requestTimeout,
      onTimeout: () => throw TimeoutException(
        'Supabase 응답이 지연되고 있습니다. 네트워크 상태와 Supabase 프로젝트 설정을 확인한 뒤 다시 시도해 주세요.',
        _requestTimeout,
      ),
    );
  }

  bool _isQuestionCommentsMigrationError(PostgrestException error) {
    final details = '${error.message} ${error.details ?? ''}';
    return error.code == 'PGRST200' ||
        error.code == '42P01' ||
        details.contains('question_comments');
  }
}

class SpainMapMigrationRequiredException implements Exception {
  const SpainMapMigrationRequiredException();

  @override
  String toString() {
    return 'Supabase SQL Editor에서 202607070001_spain_map_coordinates.sql을 실행한 뒤 다시 시도해주세요.';
  }
}

class QuestionCommentsMigrationRequiredException implements Exception {
  const QuestionCommentsMigrationRequiredException();

  @override
  String toString() {
    return 'Supabase SQL Editor에서 202607070002_question_comments.sql을 실행한 뒤 다시 시도해주세요.';
  }
}
